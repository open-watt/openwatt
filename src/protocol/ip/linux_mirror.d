module protocol.ip.linux_mirror;

version (KernelMirror):

// Mirror OpenWatt's IP tables (addresses, routes) into the
// Linux kernel via rtnetlink -- event-driven, not polled. See
// docs/LINUX_DATAPLANE.md. OpenWatt is the control plane; the kernel is the
// data plane. Routes are tagged RTPROT_OPENWATT so we only ever delete what we
// added.
//
//   * Addresses / routes are collection-managed BaseObjects. We hook the global
//     object create/destroy handlers, and attach a property-delta slot to each
//     (BaseObject.attach_delta_slot) so every property edit fans into the
//     mirror's dirty mask -- the same machinery sync uses for remotes; the
//     mirror is just another delta subscriber, tracked by slot index. drain()
//     pushes the deltas once per tick (only over tracked objects, only on a
//     non-zero mask -- not a scan of the collections).
//
// The handlers are methods of a __gshared instance so &g_mirror.handler is a
// delegate (the registries want delegates, not free-function pointers). The
// class downcasts below are the type-checked kind, not reinterprets.

import urt.array;
import urt.inet;

import manager.base;
import manager.collection;

import router.iface;

import protocol.ip.address;
import protocol.ip.route;

import driver.linux.ethernet : LinuxRawEthernet;
import driver.linux.netlink_write;

nothrow @nogc:


void mirror_init()
{
    register_object_lifecycle_handler(&g_mirror.on_object_lifecycle);
}

void mirror_drain()
{
    g_mirror.drain();
}

// Re-push every tracked address/route bound to `iface`. The mirror is otherwise
// event/delta-driven (push on create or on a property edit); when a platform
// backend assigns an interface its kernel ifindex after its addresses already
// exist -- e.g. the bridge offload setting br-<name> on engage -- nothing would
// otherwise re-trigger the push. The offload module calls this on engage and
// disengage so bridge IPs land/withdraw against the right netdev.
void mirror_refresh_interface(BaseInterface iface)
{
    g_mirror.refresh_interface(iface);
}


private:


__gshared LinuxMirror g_mirror;


struct Tracked
{
    BaseObject obj;
    ushort     slot;
    bool       is_route;
    bool       pushed;          // currently present in the kernel
    // The exact key we last pushed, so we can withdraw it on change/destroy even
    // after the object's current values have moved on.
    int        ifindex;         // address: the iface; route: out-interface (0 = via gateway only)
    ubyte[4]   addr;            // address: host address; route: destination network
    ubyte      prefix;
    ubyte[4]   gateway;         // route only
}


struct LinuxMirror
{
nothrow @nogc:

    Array!Tracked tracked;

    // Per-tick: flush property-edit deltas. Walks only tracked objects and acts
    // only on a non-zero dirty mask -- adds/removes/neighbours are fully
    // event-driven below; this batches netlink writes off the hot path.
    void drain()
    {
        foreach (ref t; tracked[])
        {
            if (sync_state(t.slot).props_dirty != 0)
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
            BaseInterface bound;
            if (auto a = cast(IPAddress)t.obj)
                bound = a.iface;
            else if (auto r = cast(IPRoute)t.obj)
                bound = r.out_interface;
            if (bound is iface)
                push(&t);
        }
    }

    void on_object_created(BaseObject obj)
    {
        bool is_route;
        if (cast(IPAddress)obj)
            is_route = false;
        else if (cast(IPRoute)obj)
            is_route = true;
        else
            return;

        Tracked t;
        t.obj      = obj;
        t.is_route = is_route;
        t.slot     = obj.attach_delta_slot(null);   // local delta subscriber; we hold the slot index
        tracked ~= t;
        push(&tracked[$ - 1]);
    }

    void on_object_destroyed(BaseObject obj)
    {
        foreach (i, ref t; tracked[])
        {
            if (t.obj is obj)
            {
                withdraw(&t);
                obj.detach_delta_slot(t.slot);
                tracked.removeSwapLast(i);
                return;
            }
        }
    }

    void push(Tracked* t)
    {
        if (t.is_route)
            push_route(t);
        else
            push_address(t);
    }

    void push_address(Tracked* t)
    {
        IPAddress a = cast(IPAddress)t.obj;
        int idx = kernel_ifindex(a.iface);
        if (idx == 0)
        {
            withdraw(t);
            return;
        }

        IPNetworkAddress na = a.address;
        ubyte[4] addr = na.addr.b;
        ubyte prefix = na.prefix_len;

        if (t.pushed && (t.ifindex != idx || t.addr != addr || t.prefix != prefix))
            netlink_del_address(t.ifindex, t.addr, t.prefix);

        netlink_add_address(idx, addr, prefix);
        t.ifindex = idx;
        t.addr = addr;
        t.prefix = prefix;
        t.pushed = true;
    }

    void push_route(Tracked* t)
    {
        IPRoute r = cast(IPRoute)t.obj;
        if (r.blackhole)
        {
            withdraw(t);
            return;     // TODO: mirror as RTN_BLACKHOLE
        }

        bool has_gw = r.gateway != IPAddr.any;
        int oif = r.out_interface ? kernel_ifindex(r.out_interface) : 0;
        if (!has_gw && oif == 0)
        {
            withdraw(t);
            return;     // connected route on an interface with no kernel netdev
        }

        IPNetworkAddress dst = r.destination;
        ubyte[4] dnet = dst.addr.b;
        ubyte prefix = dst.prefix_len;
        ubyte[4] gw;
        if (has_gw)
            gw = r.gateway.b;

        if (t.pushed && (t.addr != dnet || t.prefix != prefix || t.gateway != gw || t.ifindex != oif))
            netlink_del_route(t.addr, t.prefix, t.gateway, t.ifindex);

        netlink_add_route(dnet, prefix, gw, oif);
        t.addr = dnet;
        t.prefix = prefix;
        t.gateway = gw;
        t.ifindex = oif;
        t.pushed = true;
    }

    void withdraw(Tracked* t)
    {
        if (!t.pushed)
            return;
        if (t.is_route)
            netlink_del_route(t.addr, t.prefix, t.gateway, t.ifindex);
        else
            netlink_del_address(t.ifindex, t.addr, t.prefix);
        t.pushed = false;
    }
}


int kernel_ifindex(const(BaseInterface) iface)
{
    // null covers both an unset property and a destroyed ObjectRef target
    if (iface is null)
        return 0;
    if (auto e = cast(const(LinuxRawEthernet))iface)
        return netlink_ifindex(e.adapter);
    // A platform backend (e.g. the kernel-bridge offload) may have bound this
    // interface to an OS netdev directly -- a BridgeInterface resolves to its
    // br-<name> ifindex this way.
    if (int idx = iface.kernel_ifindex())
        return idx;
    return 0;
}
