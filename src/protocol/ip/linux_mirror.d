module protocol.ip.linux_mirror;

version (KernelMirror):

// Mirror OpenWatt's IP tables (addresses and routes, both families) into the Linux kernel via
// rtnetlink -- event-driven, not polled. OpenWatt is the control plane; the kernel is the data
// plane. Routes and addresses are tagged RTPROT_OPENWATT so we only ever delete what we added.
//
//   * Addresses / routes are collection-managed BaseObjects. We hook the global object
//     create/destroy handlers, and attach a property-delta slot to each
//     (BaseObject.attach_delta_slot) so every property edit fans into the mirror's dirty mask --
//     the same machinery sync uses for remotes; the mirror is just another delta subscriber,
//     tracked by slot index. drain() pushes the deltas once per tick (only over tracked objects,
//     only on a non-zero mask -- not a scan of the collections).
//   * A write the kernel rejects, or that never round-trips, leaves the kernel-side record as it
//     was and marks the entry pending. One backoff timer re-attempts pending entries (1s doubling
//     to 60s) until the kernel accepts them, so an ordering hazard such as a gateway route
//     submitted before the connected route that makes it reachable resolves itself. That covers
//     withdrawals too: an edit installs its new key only once the old one is gone, and a destroyed
//     object's entry outlives it until the kernel confirms the delete.
//   * Entries are reconciled by kernel key. An accepted install claims its key from any other entry
//     still recording it (an orphan awaiting deletion, or a live object whose edit away from that
//     key could not withdraw yet), so a pending delete never removes a recreated entry.
//   * Leftovers of a previous run are adopted as orphans, at init or whenever the kernel can next
//     be enumerated, skipping any key a tracked entry already holds; withdrawing them then goes
//     through the same retry path as everything else.
//
// The handlers are methods of a __gshared instance so &g_mirror.handler is a delegate (the
// registries want delegates, not free-function pointers).

import urt.array;
import urt.inet;
import urt.log;
import urt.meta : AliasSeq;
import urt.time;
import urt.util : min;

import manager;
import manager.base;
import manager.collection;
import manager.features : has_ipv6;

import router.iface;

import protocol.ip.address;
import protocol.ip.route;

import driver.linux.ethernet : LinuxRawEthernet;
import driver.linux.netlink_dump : netlink_dump_owned, OwnedEntry;
import driver.linux.netlink_write;

nothrow @nogc:


void mirror_init()
{
    g_mirror.sweep();
    register_object_lifecycle_handler(&g_mirror.on_object_lifecycle);
}

void mirror_drain()
{
    g_mirror.drain();
}

// Re-push every tracked address/route bound to `iface`. The mirror is otherwise event/delta-driven
// (push on create or on a property edit); when a platform backend assigns an interface its kernel
// ifindex after its addresses already exist -- e.g. the bridge offload setting br-<name> on engage
// -- nothing would otherwise re-trigger the push. The offload module calls this on engage and
// disengage so bridge IPs land/withdraw against the right netdev.
void mirror_refresh_interface(BaseInterface iface)
{
    g_mirror.refresh_interface(iface);
}


private:


__gshared LinuxMirror g_mirror;
__gshared Netlink nl;

enum Duration retry_base = 1.seconds;
enum Duration retry_max  = 60.seconds;

enum ESRCH         = 3;
enum ENODEV        = 19;
enum EADDRNOTAVAIL = 99;

static if (has_ipv6)
    alias Mirrored = AliasSeq!(IPAddress, IPRoute, IPv6Address, IPv6Route);
else
    alias Mirrored = AliasSeq!(IPAddress, IPRoute);

enum is_route(T) = __traits(hasMember, T, "destination");

template AddrOf(T)
{
    static if (is_route!T)
        alias AddrOf = typeof(T.init.gateway());
    else
        alias AddrOf = typeof(T.init.address().addr);
}

enum addr_len(T) = is(AddrOf!T == IPAddr) ? 4 : 16;

enum Form : ubyte
{
    address,
    route,
}

// The kernel-facing calls, so a unittest can stand in a fake kernel and timer.
struct Netlink
{
    int function(const(ubyte)[] dst, ubyte prefix, const(ubyte)[] gateway, int oif, ubyte type, uint metric) nothrow @nogc add_route = &netlink_add_route;
    int function(const(ubyte)[] dst, ubyte prefix, const(ubyte)[] gateway, int oif, ubyte type, uint metric) nothrow @nogc del_route = &netlink_del_route;
    int function(int ifindex, const(ubyte)[] addr, ubyte prefix) nothrow @nogc add_address = &netlink_add_address;
    int function(int ifindex, const(ubyte)[] addr, ubyte prefix) nothrow @nogc del_address = &netlink_del_address;
    bool function(scope void delegate(ref const OwnedEntry) nothrow @nogc dg) nothrow @nogc dump_owned = &netlink_dump_owned;
    int function(const(BaseInterface) iface) nothrow @nogc ifindex = &kernel_ifindex;
    void function(Duration delay) nothrow @nogc schedule = &schedule_retry;
}

void schedule_retry(Duration delay)
{
    g_app.schedule(getTime() + delay, &g_mirror.retry);
}


struct Tracked
{
    BaseObject obj;             // null once destroyed, or for a leftover of a previous run: kept until withdrawn
    int        ifindex;         // address: the iface; route: out-interface (0 = via gateway only)
    uint       metric;          // route only
    ushort     slot;
    ubyte      kind;            // index into Mirrored (live objects only)
    ubyte      prefix;
    ubyte      type;            // route only: RTN_UNICAST or RTN_BLACKHOLE
    Form       form;
    ubyte      family;          // AF_INET / AF_INET6
    bool       pushed;          // present in the kernel under the key recorded here
    bool       pending;         // last write failed; the backoff timer re-attempts it
    ubyte[16]  addr;            // address: host address; route: destination network
    ubyte[16]  gateway;         // route only

    // Still wants a kernel write: a failed one to redo, or a leftover not yet withdrawn.
    bool outstanding() const nothrow @nogc
        => pending || (obj is null && pushed);

    // The kernel reports a gateway-only route with the egress it resolved, so a recorded 0 matches
    // whatever interface a dump names for it.
    bool same_key(ref const Tracked o) const nothrow @nogc
    {
        bool egress = ifindex == o.ifindex || (form == Form.route && (ifindex == 0 || o.ifindex == 0));
        return form == o.form && family == o.family && egress && prefix == o.prefix && type == o.type && metric == o.metric && addr == o.addr && gateway == o.gateway;
    }
}


struct LinuxMirror
{
nothrow @nogc:

    Array!Tracked tracked;
    Duration retry_delay;       // zero while no retry is armed
    bool sweep_pending;         // the kernel could not be enumerated; retried by the timer

    // Per-tick: flush property-edit deltas. Walks only tracked objects and acts only on a
    // non-zero dirty mask; creates and destroys are handled at the event below.
    void drain()
    {
        foreach (ref t; tracked[])
        {
            if (t.obj && sync_state(t.slot).props_dirty != 0)
            {
                sync_state(t.slot).props_dirty = 0;
                push(&t);
            }
        }
    }

    void on_object_lifecycle(BaseObject obj, ObjectLifecycleEvent event)
    {
        final switch (event)
        {
            case ObjectLifecycleEvent.created:
                on_object_created(obj);
                break;
            case ObjectLifecycleEvent.destroyed:
                on_object_destroyed(obj);
                break;
        }
    }

    void refresh_interface(BaseInterface iface)
    {
        foreach (ref t; tracked[])
        {
            if (t.obj && dispatch!interface_of(&t) is iface)
                push(&t);
        }
    }

    void on_object_created(BaseObject obj)
    {
        ubyte kind = ubyte.max;
        static foreach (i, T; Mirrored)
        {
            if (dyn_cast!T(obj))
                kind = i;
        }
        if (kind == ubyte.max)
            return;

        Tracked t;
        t.obj  = obj;
        t.kind = kind;
        t.slot = obj.attach_delta_slot(null);   // local delta subscriber; we hold the slot index
        tracked ~= t;
        push(&tracked[$ - 1]);
    }

    void on_object_destroyed(BaseObject obj)
    {
        foreach (i, ref t; tracked[])
        {
            if (t.obj is obj)
            {
                obj.detach_delta_slot(t.slot);
                t.obj = null;
                if (write(&t))
                    tracked.removeSwapLast(i);
                else
                    arm_retry();
                return;
            }
        }
    }

    void push(Tracked* t)
    {
        if (!write(t))
            arm_retry();
    }

    // Init: adopt what a previous run left in the kernel and start withdrawing it.
    void sweep()
    {
        sweep_pending = !adopt_stale();
        bool failed = sweep_pending;
        for (size_t i = tracked.length; i > 0; --i)
        {
            Tracked* t = &tracked[i - 1];
            if (!t.outstanding)
                continue;
            if (write(t))
                tracked.removeSwapLast(i - 1);
            else
                failed = true;
        }
        if (failed)
            arm_retry();
    }

    // Enumerate the kernel's entries under our tag and adopt, as orphans, those no tracked entry
    // owns: a live object may have installed that very key since. False when the kernel could
    // not be enumerated.
    bool adopt_stale()
    {
        uint stale = 0;
        bool ok = nl.dump_owned((ref const OwnedEntry e) {
            Tracked t;
            t.form    = e.route ? Form.route : Form.address;
            t.family  = e.family;
            t.ifindex = e.ifindex;
            t.prefix  = e.prefix;
            t.type    = e.type;
            t.metric  = e.metric;
            t.addr    = e.addr;
            t.gateway = e.gateway;
            t.pushed  = true;
            foreach (ref o; tracked[])
            {
                if (o.pushed && o.same_key(t))
                    return;
            }
            tracked ~= t;
            ++stale;
        });
        if (!ok)
        {
            if (!sweep_pending)
                log_warning("ip.mirror", "could not enumerate kernel state; will retry");
        }
        else if (stale)
            log_info("ip.mirror", "withdrawing ", stale, " stale kernel entries from a previous run");
        return ok;
    }

    // `live` was just accepted under its key: no other entry owns that kernel record any more.
    void claim_key(ref const Tracked live)
    {
        foreach (ref t; tracked[])
        {
            if (&t !is &live && t.pushed && t.same_key(live))
            {
                t.pushed = false;
                if (!t.obj)
                    t.pending = false;
            }
        }
    }

    void arm_retry()
    {
        if (retry_delay != Duration.zero)
            return;
        retry_delay = retry_base;
        nl.schedule(retry_delay);
    }

    // Bring the kernel to the entry's current state: install for a live object, withdraw for a
    // destroyed one. True once the kernel matches.
    bool write(Tracked* t)
    {
        int r = t.obj ? dispatch!push_entry(t) : withdraw(t);
        const(char)[] name = t.obj ? t.obj.name[] : "orphaned kernel entry";
        if (r == 0)
        {
            if (t.pending)
                log_info("ip.mirror", name, ": kernel accepted on retry");
            t.pending = false;
            return true;
        }
        if (!t.pending)
        {
            if (r == TRANSPORT_ERROR)
                log_warning("ip.mirror", name, ": netlink transport error, will retry");
            else
                log_warning("ip.mirror", name, ": kernel rejected write (errno=", -r, "), will retry");
        }
        t.pending = true;
        return false;
    }

    // One pass over everything outstanding; schedules exactly one further pass if any remains.
    void retry(MonoTime)
    {
        if (sweep_pending)
            sweep_pending = !adopt_stale();

        bool remaining = sweep_pending;
        for (size_t i = tracked.length; i > 0; --i)
        {
            Tracked* t = &tracked[i - 1];
            if (t.outstanding && !write(t))
            {
                remaining = true;
                continue;
            }
            if (!t.obj && !t.pushed)
                tracked.removeSwapLast(i - 1);      // withdrawn, or claimed by a live entry
        }
        if (!remaining)
        {
            retry_delay = Duration.zero;
            return;
        }
        retry_delay = min(retry_delay + retry_delay, retry_max);
        nl.schedule(retry_delay);
    }
}


auto dispatch(alias fn)(Tracked* t)
{
    switch (t.kind)
    {
        static foreach (i, T; Mirrored)
        {
            case i:
                return fn!T(t);
        }
        default:
            assert(false, "untracked kind");
    }
}

BaseInterface interface_of(T)(Tracked* t)
{
    T o = dyn_cast!T(t.obj);
    static if (is_route!T)
        return o.out_interface;
    else
        return o.iface;
}

// Returns the netlink result; 0 also when the entry has no kernel form (no netdev) and nothing
// remains installed. The recorded key only moves once the kernel has both dropped the old entry
// and accepted the new one, so a failure leaves an exact record of what the kernel still holds.
int push_entry(T)(Tracked* t)
{
    enum n = addr_len!T;
    T o = dyn_cast!T(t.obj);
    ubyte[n] addr;
    ubyte prefix;
    int r;

    static if (is_route!T)
    {
        ubyte[n] gw;
        int oif;
        ubyte type = o.blackhole ? RTN_BLACKHOLE : RTN_UNICAST;
        if (!o.blackhole)
        {
            if (o.gateway != AddrOf!T.any)
                gw = wire(o.gateway);
            oif = nl.ifindex(o.out_interface);
            if (oif == 0 && gw == ubyte[n].init)
                return withdraw(t);     // connected route on an interface with no kernel netdev
        }

        addr = wire(o.destination.addr);
        prefix = o.destination.prefix_len;
        uint metric = o.distance + 1u;      // 0 would take the kernel default, 1024 for IPv6, and outrank distance 1
        if (t.pushed && (t.addr[0 .. n] != addr[] || t.prefix != prefix || t.gateway[0 .. n] != gw[] || t.ifindex != oif || t.type != type || t.metric != metric))
        {
            r = withdraw(t);
            if (r != 0)
                return r;
        }

        r = nl.add_route(addr[], prefix, gw[], oif, type, metric);
        if (r != 0)
            return r;
        t.form = Form.route;
        t.ifindex = oif;
        t.type = type;
        t.metric = metric;
        t.gateway[0 .. n] = gw[];
    }
    else
    {
        int idx = nl.ifindex(o.iface);
        if (idx == 0)
            return withdraw(t);

        addr = wire(o.address.addr);
        prefix = o.address.prefix_len;
        if (t.pushed && (t.ifindex != idx || t.addr[0 .. n] != addr[] || t.prefix != prefix))
        {
            r = withdraw(t);
            if (r != 0)
                return r;
        }

        r = nl.add_address(idx, addr[], prefix);
        if (r != 0)
            return r;
        t.form = Form.address;
        t.ifindex = idx;
    }

    t.family = n == 16 ? AF_INET6 : AF_INET;
    t.addr[0 .. n] = addr[];
    t.prefix = prefix;
    t.pushed = true;
    g_mirror.claim_key(*t);
    return 0;
}

// 0 once nothing of this entry remains in the kernel; otherwise the netlink result, with the
// recorded key kept so the withdrawal can be retried. Keyed by form and family alone, so a
// leftover from a build with types this one lacks (an IPv6 entry under IPV6=0) still withdraws.
int withdraw(Tracked* t)
{
    if (!t.pushed)
        return 0;
    size_t n = t.family == AF_INET6 ? 16 : 4;
    int r = t.form == Form.route ? nl.del_route(t.addr[0 .. n], t.prefix, t.gateway[0 .. n], t.ifindex, t.type, t.metric)
                                 : nl.del_address(t.ifindex, t.addr[0 .. n], t.prefix);
    // ESRCH/EADDRNOTAVAIL/ENODEV: the kernel already dropped it (netdev gone, operator removed it)
    if (r != 0 && r != -ESRCH && r != -EADDRNOTAVAIL && r != -ENODEV)
        return r;
    t.pushed = false;
    return 0;
}

ubyte[4] wire(IPAddr a)
    => a.b;

ubyte[16] wire(IPv6Addr a)
    => ipv6_to_wire(a);

int kernel_ifindex(const(BaseInterface) iface)
{
    // null covers both an unset property and a destroyed ObjectRef target
    if (iface is null)
        return 0;
    if (auto e = dyn_cast!LinuxRawEthernet(iface))
        return netlink_ifindex(e.adapter);
    // A platform backend (e.g. the kernel-bridge offload) may have bound this interface to an OS
    // netdev directly -- a BridgeInterface resolves to its br-<name> ifindex this way.
    if (int idx = iface.kernel_ifindex())
        return idx;
    return 0;
}


version (unittest)
{
    // A kernel that holds routes only, with switches for the failures the mirror must survive. Like
    // Linux, it resolves the egress of a gateway-only route (to ifindex 2 here) and reports that,
    // and a delete without an interface matches regardless of it. Seeded leftovers carry the
    // resolved egress, as a real dump would.
    struct FakeKernel
    {
    nothrow @nogc:
        Array!OwnedEntry routes;
        uint schedules;
        bool refuse_delete;
        bool refuse_dump;

        enum int resolved_oif = 2;

        static OwnedEntry key(const(ubyte)[] dst, ubyte prefix, const(ubyte)[] gateway, int oif, ubyte type, uint metric)
        {
            OwnedEntry e;
            e.route = true;
            e.family = dst.length == 16 ? AF_INET6 : AF_INET;
            e.ifindex = oif;
            e.prefix = prefix;
            e.type = type;
            e.metric = metric;
            e.addr[0 .. dst.length] = dst[];
            e.gateway[0 .. gateway.length] = gateway[];
            return e;
        }

        ptrdiff_t find(ref const OwnedEntry k)
        {
            foreach (i, ref e; routes[])
            {
                if (e.family == k.family && e.prefix == k.prefix && e.type == k.type && e.metric == k.metric && e.addr == k.addr && e.gateway == k.gateway && (k.ifindex == 0 || e.ifindex == k.ifindex))
                    return i;
            }
            return -1;
        }
    }

    __gshared FakeKernel fake;

    int fake_add_route(const(ubyte)[] dst, ubyte prefix, const(ubyte)[] gateway, int oif, ubyte type, uint metric)
    {
        OwnedEntry k = FakeKernel.key(dst, prefix, gateway, oif, type, metric);
        if (oif == 0 && gateway != ubyte[16].init[0 .. gateway.length])
            k.ifindex = FakeKernel.resolved_oif;
        ptrdiff_t i = fake.find(k);
        if (i < 0)
            fake.routes ~= k;
        else
            fake.routes[][i] = k;
        return 0;
    }

    int fake_del_route(const(ubyte)[] dst, ubyte prefix, const(ubyte)[] gateway, int oif, ubyte type, uint metric)
    {
        if (fake.refuse_delete)
            return -1;
        ptrdiff_t i = fake.find(FakeKernel.key(dst, prefix, gateway, oif, type, metric));
        if (i < 0)
            return -ESRCH;
        fake.routes.removeSwapLast(i);
        return 0;
    }

    int fake_add_address(int, const(ubyte)[], ubyte) => -1;
    int fake_del_address(int, const(ubyte)[], ubyte) => -1;
    int fake_ifindex(const(BaseInterface)) => 0;

    bool fake_dump_owned(scope void delegate(ref const OwnedEntry) nothrow @nogc dg)
    {
        if (fake.refuse_dump)
            return false;
        foreach (ref e; fake.routes[])
            dg(e);
        return true;
    }

    void fake_schedule(Duration)
    {
        ++fake.schedules;
    }

    void fake_reset()
    {
        fake = FakeKernel.init;
        g_mirror.tracked.clear();
        g_mirror.retry_delay = Duration.zero;
        g_mirror.sweep_pending = false;
        nl.add_route = &fake_add_route;
        nl.del_route = &fake_del_route;
        nl.add_address = &fake_add_address;
        nl.del_address = &fake_del_address;
        nl.dump_owned = &fake_dump_owned;
        nl.ifindex = &fake_ifindex;
        nl.schedule = &fake_schedule;
    }

    IPRoute make_route(const(char)[] name, IPAddr gateway, ubyte distance = 0)
    {
        IPRoute r = Collection!IPRoute().alloc(name);
        r.destination = IPNetworkAddress(IPAddr(10, 90, 0, 0), 16);
        r.gateway = gateway;
        r.distance = distance;
        return r;
    }

    static immutable ubyte[4] dst = [10, 90, 0, 0];
    static immutable ubyte[4] gw1 = [10, 99, 1, 11];
    static immutable ubyte[4] gw2 = [10, 99, 1, 12];
}

// A leftover whose delete the kernel refuses is retried, then dropped once accepted.
unittest
{
    fake_reset();
    fake.routes ~= FakeKernel.key(dst, 16, gw1, FakeKernel.resolved_oif, RTN_UNICAST, 1);
    fake.refuse_delete = true;

    g_mirror.sweep();
    assert(g_mirror.tracked.length == 1 && g_mirror.tracked[0].pending && g_mirror.tracked[0].pushed);
    assert(fake.schedules == 1 && g_mirror.retry_delay == retry_base);

    fake.refuse_delete = false;
    g_mirror.retry(MonoTime.init);
    assert(fake.routes.length == 0);
    assert(g_mirror.tracked.length == 0);
    assert(g_mirror.retry_delay == Duration.zero && fake.schedules == 1);
}

// A failed enumeration is retried by the one timer, backing off, and never resets the backoff.
unittest
{
    fake_reset();
    fake.routes ~= FakeKernel.key(dst, 16, gw1, FakeKernel.resolved_oif, RTN_UNICAST, 1);
    fake.refuse_dump = true;

    g_mirror.sweep();
    assert(g_mirror.sweep_pending && fake.schedules == 1 && g_mirror.retry_delay == retry_base);

    g_mirror.retry(MonoTime.init);
    assert(g_mirror.sweep_pending && fake.schedules == 2 && g_mirror.retry_delay == retry_base + retry_base);

    fake.refuse_dump = false;
    g_mirror.retry(MonoTime.init);
    assert(!g_mirror.sweep_pending && fake.routes.length == 0 && g_mirror.tracked.length == 0);
    assert(fake.schedules == 2 && g_mirror.retry_delay == Duration.zero);
}

// A configured object that installs the leftover's own key while enumeration is still failing
// owns that record: the delayed sweep must not adopt and delete it.
unittest
{
    fake_reset();
    fake.routes ~= FakeKernel.key(dst, 16, gw1, FakeKernel.resolved_oif, RTN_UNICAST, 1);
    fake.refuse_dump = true;
    g_mirror.sweep();

    IPRoute r = make_route("mirror-test-r1", IPAddr(10, 99, 1, 11));
    g_mirror.on_object_created(r);
    assert(g_mirror.tracked.length == 1 && g_mirror.tracked[0].pushed && fake.routes.length == 1);

    fake.refuse_dump = false;
    g_mirror.retry(MonoTime.init);
    assert(g_mirror.tracked.length == 1 && g_mirror.tracked[0].obj is r && g_mirror.tracked[0].pushed);
    assert(fake.routes.length == 1 && !g_mirror.sweep_pending && g_mirror.retry_delay == Duration.zero);

    g_mirror.on_object_destroyed(r);
    assert(fake.routes.length == 0 && g_mirror.tracked.length == 0);
}

// An orphan awaiting a refused delete is claimed by a recreated object with the same key; the
// later retry must not delete the replacement.
unittest
{
    fake_reset();
    fake.routes ~= FakeKernel.key(dst, 16, gw1, FakeKernel.resolved_oif, RTN_UNICAST, 1);
    fake.refuse_delete = true;
    g_mirror.sweep();
    assert(g_mirror.tracked.length == 1 && g_mirror.tracked[0].pending);

    IPRoute r = make_route("mirror-test-r2", IPAddr(10, 99, 1, 11));
    g_mirror.on_object_created(r);
    assert(g_mirror.tracked.length == 2);
    assert(!g_mirror.tracked[0].pushed && !g_mirror.tracked[0].pending);

    fake.refuse_delete = false;
    g_mirror.retry(MonoTime.init);
    assert(fake.routes.length == 1 && g_mirror.tracked.length == 1 && g_mirror.tracked[0].obj is r);

    g_mirror.on_object_destroyed(r);
    assert(fake.routes.length == 0 && g_mirror.tracked.length == 0);
}

// A live edit whose withdrawal is refused keeps its old key; a second object taking that key
// claims it, and the first then installs its new key without deleting the second's.
unittest
{
    fake_reset();
    IPRoute a = make_route("mirror-test-a", IPAddr(10, 99, 1, 11));
    g_mirror.on_object_created(a);
    assert(fake.routes.length == 1);

    fake.refuse_delete = true;
    a.gateway = IPAddr(10, 99, 1, 12);
    g_mirror.push(&g_mirror.tracked[0]);
    assert(g_mirror.tracked[0].pending && g_mirror.tracked[0].pushed && g_mirror.tracked[0].gateway[0 .. 4] == gw1);
    assert(fake.routes.length == 1);

    IPRoute b = make_route("mirror-test-b", IPAddr(10, 99, 1, 11));
    g_mirror.on_object_created(b);
    assert(!g_mirror.tracked[0].pushed && g_mirror.tracked[0].pending);
    assert(fake.routes.length == 1);

    fake.refuse_delete = false;
    g_mirror.retry(MonoTime.init);
    assert(fake.routes.length == 2);
    assert(g_mirror.tracked[0].pushed && g_mirror.tracked[0].gateway[0 .. 4] == gw2);
    assert(fake.find(FakeKernel.key(dst, 16, gw1, 0, RTN_UNICAST, 1)) >= 0);

    g_mirror.on_object_destroyed(a);
    g_mirror.on_object_destroyed(b);
    assert(fake.routes.length == 0 && g_mirror.tracked.length == 0);
}

// The kernel reports a gateway-only route with its resolved egress: a delayed sweep must recognise
// the live route under that identity, and a leftover carrying it is claimed by a recreation.
unittest
{
    fake_reset();
    fake.refuse_dump = true;
    g_mirror.sweep();

    IPRoute r = make_route("mirror-test-oif", IPAddr(10, 99, 1, 11));
    g_mirror.on_object_created(r);
    assert(g_mirror.tracked[0].ifindex == 0 && fake.routes[0].ifindex == FakeKernel.resolved_oif);

    fake.refuse_dump = false;
    g_mirror.retry(MonoTime.init);
    assert(g_mirror.tracked.length == 1 && g_mirror.tracked[0].obj is r && g_mirror.tracked[0].pushed);
    assert(fake.routes.length == 1 && g_mirror.retry_delay == Duration.zero);
    g_mirror.on_object_destroyed(r);
    assert(fake.routes.length == 0 && g_mirror.tracked.length == 0);

    fake_reset();
    fake.routes ~= FakeKernel.key(dst, 16, gw1, FakeKernel.resolved_oif, RTN_UNICAST, 1);
    fake.refuse_delete = true;
    g_mirror.sweep();
    assert(g_mirror.tracked.length == 1 && g_mirror.tracked[0].ifindex == FakeKernel.resolved_oif);

    IPRoute r2 = make_route("mirror-test-oif2", IPAddr(10, 99, 1, 11));
    g_mirror.on_object_created(r2);
    assert(!g_mirror.tracked[0].pushed && !g_mirror.tracked[0].pending);

    fake.refuse_delete = false;
    g_mirror.retry(MonoTime.init);
    assert(fake.routes.length == 1 && g_mirror.tracked.length == 1 && g_mirror.tracked[0].obj is r2);
    g_mirror.on_object_destroyed(r2);
    assert(fake.routes.length == 0 && g_mirror.tracked.length == 0);
}

// A leftover of a family this build may not carry as a collection type still withdraws.
unittest
{
    fake_reset();
    ubyte[16] dst6 = [0xfd, 0, 0, 0x90, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    ubyte[16] gw6;
    fake.routes ~= FakeKernel.key(dst6, 32, gw6, 0, RTN_BLACKHOLE, 1);

    g_mirror.sweep();
    assert(fake.routes.length == 0 && g_mirror.tracked.length == 0 && fake.schedules == 0);
}
