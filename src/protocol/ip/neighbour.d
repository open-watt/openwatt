module protocol.ip.neighbour;

import urt.array;
import urt.inet;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.time;

import manager.base;
import manager.collection;
import manager.expression : NamedArgument;
import manager.features : has_ipv6;

import router.iface;
import router.iface.mac : MACAddress;
import router.iface.packet;

private alias log = Log!"neighbour";

// TODO: replace fixed-slot pending queue with byte-budget buffer (cf. Linux unres_qlen_bytes).
private enum pending_queue_depth = 3;

nothrow @nogc:


enum NeighbourState : ubyte
{
    incomplete,     // resolution in flight (ARP request / NS sent)
    reachable,      // confirmed within reachable_time
    stale,          // unconfirmed, use but probe on next send
    failed,         // resolution gave up -> drop queued packets
    permanent,      // configured; never aged or probed
}

// The neighbour table. Learned entries are dynamic objects published by whichever stack resolves
// (the in-tree cache, or the kernel on mirror builds); configured entries are static and are
// pushed down to it.
class IPNeighbour : BaseObject
{
nothrow @nogc:

    enum type_name = "ip-neighbour";
    enum path = "/protocol/ip/neighbour";
    enum collection_id = CollectionType.ip_neighbour;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPNeighbour, id, flags);
        _state = (flags & ObjectFlags.dynamic) ? NeighbourState.incomplete : NeighbourState.permanent;
    }

    mixin NeighbourImpl!IPAddr;
}

static if (has_ipv6)
class IPv6Neighbour : BaseObject
{
nothrow @nogc:

    enum type_name = "ipv6-neighbour";
    enum path = "/protocol/ip/neighbour6";
    enum collection_id = CollectionType.ip_neighbour6;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPv6Neighbour, id, flags);
        _state = (flags & ObjectFlags.dynamic) ? NeighbourState.incomplete : NeighbourState.permanent;
    }

    mixin NeighbourImpl!IPv6Addr;
}

mixin template NeighbourImpl(IP)
{
    alias Properties = AliasSeq!(Prop!("address", address, null, "d"),
                                 Prop!("mac", mac, null, "d"),
                                 Prop!("interface", iface, null, "d"),
                                 Prop!("state", state, null, "d"));
nothrow @nogc:

    IP address() const pure
        => _address;
    const(char)[] address(IP value)
    {
        if (value == IP.any)
            return is(IP == IPv6Addr) ? "address cannot be ::" : "address cannot be 0.0.0.0";
        _address = value;
        mark_set!(typeof(this), "address")();
        return null;
    }

    MACAddress mac() const pure
        => _mac;
    const(ubyte)[] link_address() const pure
        => _mac.b[];
    void mac(MACAddress value)
    {
        _mac = value;
        mark_set!(typeof(this), "mac")();
    }

    inout(BaseInterface) iface() inout pure
        => _iface;
    const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        _iface = value;
        mark_set!(typeof(this), "interface")();
        return null;
    }

    NeighbourState state() const pure
        => _state;

    // Learned entries only: whatever resolves on this build reports what it observed.
    void learned(NeighbourState state, MACAddress mac)
    {
        if (_state != state)
        {
            _state = state;
            mark_set!(typeof(this), "state")();
        }
        if (_mac != mac)
        {
            _mac = mac;
            mark_set!(typeof(this), "mac")();
        }
    }

protected:

    override bool validate() const pure nothrow @nogc
        => _iface !is null && _address != IP.any && (_state != NeighbourState.permanent || _mac != MACAddress());

private:
    IP _address;
    MACAddress _mac;
    ObjectRef!BaseInterface _iface;
    NeighbourState _state;
}

// Reflect one learned entry into the collection: update or create its dynamic object, or destroy it
// when the resolver dropped it. A configured entry for the same key owns it; no dynamic twin then.
void publish_neighbour(T, IP)(BaseInterface iface, IP address, NeighbourState state, MACAddress mac, bool removed)
{
    T twin;
    foreach (n; Collection!T().values)
    {
        if (n.iface !is iface || n.address != address)
            continue;
        if (n.flags & ObjectFlags.dynamic)
            twin = n;
        else
            removed = true;
    }
    if (twin)
    {
        if (removed)
            twin.destroy();
        else
            twin.learned(state, mac);
        return;
    }
    if (removed)
        return;

    T n = Collection!T().create(Collection!T().generate_name(tconcat(address)), ObjectFlags.dynamic, NamedArgument("address", address), NamedArgument("interface", iface));
    if (n)
        n.learned(state, mac);
}


version (UseInternalIPStack):


struct NeighbourEntry(IP)
{
    IP ip;
    BaseInterface iface;
    ubyte[16] link_addr;        // MAC (6) or EUI-64 (8) etc.
    MonoTime last_confirmed;
    MonoTime last_request;
    Packet*[pending_queue_depth] pending;
    ubyte link_addr_len;
    NeighbourState state;
    ubyte retry_count;
    ubyte pending_count;
    bool is_router;
}

struct NeighbourCache(IP)
{
nothrow @nogc:

    alias SendRequestDg  = void delegate(IP target, BaseInterface iface) nothrow @nogc;
    alias DrainDg        = void delegate(ref Packet pkt, BaseInterface iface, const(ubyte)[] link_addr) nothrow @nogc;
    alias StaticLookupDg = const(ubyte)[] delegate(IP target, BaseInterface iface) nothrow @nogc;
    alias ChangedDg      = void delegate(ref const NeighbourEntry!IP e, bool removed) nothrow @nogc;

    enum uint  retry_interval_ms       = 1000;
    enum ubyte max_retries             = 3;
    enum uint  reachable_time_ms       = 30_000;
    enum uint  stale_probe_interval_ms = 5_000;
    enum ubyte max_stale_probes        = 3;
    enum uint  failed_lifetime_ms      = 60_000;

    SendRequestDg  send_request;
    DrainDg        drain;
    StaticLookupDg static_lookup;   // configured entries win over anything learned
    ChangedDg      changed;         // publishes learned entries to the neighbour collection

    void learn(IP ip, BaseInterface iface, const(ubyte)[] link_addr)
    {
        if (link_addr.length == 0 || link_addr.length > 16 || is_static(ip, iface))
            return;

        MonoTime now = getTime();

        foreach (ref e; _entries[])
        {
            if (e.iface is iface && e.ip == ip)
            {
                e.link_addr[0 .. link_addr.length] = link_addr[];
                e.link_addr_len  = cast(ubyte)link_addr.length;
                e.state          = NeighbourState.reachable;
                e.last_confirmed = now;
                e.retry_count    = 0;
                touch(e);
                drain_pending(e);
                return;
            }
        }

        NeighbourEntry!IP n;
        n.ip                       = ip;
        n.iface                    = iface;
        n.link_addr[0..link_addr.length] = link_addr[];
        n.link_addr_len            = cast(ubyte)link_addr.length;
        n.state                    = NeighbourState.reachable;
        n.last_confirmed           = now;
        _entries ~= n;
        touch(_entries[$ - 1]);
    }

    void observe(IP ip, BaseInterface iface, const(ubyte)[] link_addr)
    {
        if (link_addr.length == 0 || link_addr.length > 16 || is_static(ip, iface))
            return;

        if (auto e = find(ip, iface))
        {
            bool changed = e.link_addr_len != link_addr.length || e.link_addr[0 .. e.link_addr_len] != link_addr;
            if (changed || e.state == NeighbourState.incomplete || e.state == NeighbourState.failed)
            {
                e.link_addr[0 .. link_addr.length] = link_addr[];
                e.link_addr_len = cast(ubyte)link_addr.length;
                e.state = NeighbourState.stale;
                e.retry_count = 0;
                touch(*e);
            }
            drain_pending(*e);
            return;
        }

        NeighbourEntry!IP entry;
        entry.ip = ip;
        entry.iface = iface;
        entry.link_addr[0 .. link_addr.length] = link_addr[];
        entry.link_addr_len = cast(ubyte)link_addr.length;
        entry.state = NeighbourState.stale;
        entry.last_request = getTime();
        _entries ~= entry;
        touch(_entries[$ - 1]);
    }

    bool advertise(IP ip, BaseInterface iface, const(ubyte)[] link_addr, bool router, bool solicited, bool override_)
    {
        if (is_static(ip, iface))
            return true;
        NeighbourEntry!IP* entry = find(ip, iface);
        if (!entry)
            return false;
        if (entry.state == NeighbourState.incomplete)
        {
            if (link_addr.length == 0 || link_addr.length > entry.link_addr.length)
                return false;
            entry.link_addr[0 .. link_addr.length] = link_addr[];
            entry.link_addr_len = cast(ubyte)link_addr.length;
            entry.state = solicited ? NeighbourState.reachable : NeighbourState.stale;
        }
        else if (link_addr.length)
        {
            if (link_addr.length > entry.link_addr.length)
                return false;
            bool changed = entry.link_addr_len != link_addr.length || entry.link_addr[0 .. entry.link_addr_len] != link_addr;
            if (changed && !override_)
            {
                if (entry.state == NeighbourState.reachable)
                    entry.state = NeighbourState.stale;
                entry.is_router = router;
                touch(*entry);
                return true;
            }
            if (changed)
            {
                entry.link_addr[0 .. link_addr.length] = link_addr[];
                entry.link_addr_len = cast(ubyte)link_addr.length;
                entry.state = solicited ? NeighbourState.reachable : NeighbourState.stale;
            }
            else if (solicited)
                entry.state = NeighbourState.reachable;
        }
        else if (solicited)
            entry.state = NeighbourState.reachable;

        entry.is_router = router;
        entry.retry_count = 0;
        if (solicited)
            entry.last_confirmed = getTime();
        touch(*entry);
        drain_pending(*entry);
        return true;
    }

    NeighbourEntry!IP* find(IP ip, BaseInterface iface)
    {
        foreach (ref e; _entries[])
            if (e.iface is iface && e.ip == ip)
                return &e;
        return null;
    }

    // Lookup; returns link_addr if reachable, null otherwise.
    // On miss, creates an incomplete entry, queues `pending`, kicks off resolution.
    // On in-flight, replaces the queued packet (single-slot).
    const(ubyte)[] resolve(IP ip, BaseInterface iface, ref Packet pending)
    {
        if (static_lookup)
        {
            if (const(ubyte)[] link = static_lookup(ip, iface))
                return link;
        }

        if (auto e = find(ip, iface))
        {
            final switch (e.state) with (NeighbourState)
            {
                case reachable:
                case stale:
                    return e.link_addr[0 .. e.link_addr_len];
                case failed:
                    // peer may have come back -- restart resolution
                    e.state        = NeighbourState.incomplete;
                    e.last_request = getTime();
                    e.retry_count  = 1;
                    touch(*e);
                    queue_pending(*e, pending);
                    if (send_request)
                        send_request(ip, iface);
                    return null;
                case incomplete:
                    queue_pending(*e, pending);
                    return null;
                case permanent:
                    assert(false, "permanent entries live in the collection, not the cache");
            }
        }

        NeighbourEntry!IP n;
        n.ip            = ip;
        n.iface         = iface;
        n.state         = NeighbourState.incomplete;
        n.last_request  = getTime();
        n.retry_count   = 1;
        queue_pending(n, pending);
        _entries ~= n;
        touch(_entries[$ - 1]);

        if (send_request)
            send_request(ip, iface);

        return null;
    }

    void tick(MonoTime now)
    {
        foreach (ref e; _entries[])
        {
            final switch (e.state) with (NeighbourState)
            {
                case incomplete:
                    if (now - e.last_request < retry_interval_ms.msecs)
                        break;
                    if (e.retry_count >= max_retries)
                    {
                        e.state = NeighbourState.failed;
                        e.last_confirmed = now;     // repurposed as failure timestamp
                        free_pending(e);
                        touch(e);
                        break;
                    }
                    ++e.retry_count;
                    e.last_request = now;
                    if (send_request)
                        send_request(e.ip, e.iface);
                    break;

                case reachable:
                    if (now - e.last_confirmed >= reachable_time_ms.msecs)
                    {
                        e.state        = NeighbourState.stale;
                        e.last_request = now;       // arm probe interval
                        e.retry_count  = 0;
                        touch(e);
                    }
                    break;

                case stale:
                    if (now - e.last_request < stale_probe_interval_ms.msecs)
                        break;
                    if (e.retry_count >= max_stale_probes)
                    {
                        e.state          = NeighbourState.failed;
                        e.last_confirmed = now;
                        touch(e);
                        break;
                    }
                    ++e.retry_count;
                    e.last_request = now;
                    if (send_request)
                        send_request(e.ip, e.iface);
                    break;

                case failed:
                case permanent:
                    break;
            }
        }

        // GC failed entries past their lifetime; iterate in reverse for swap-remove safety
        for (size_t i = _entries.length; i > 0; --i)
        {
            size_t idx = i - 1;
            auto e = &_entries[idx];
            if (e.state == NeighbourState.failed
                && now - e.last_confirmed >= failed_lifetime_ms.msecs)
            {
                free_pending(*e);
                if (changed)
                    changed(*e, true);
                _entries.removeSwapLast(idx);
            }
        }
    }

    auto entries() inout pure
        => _entries[];

private:
    bool is_static(IP ip, BaseInterface iface)
        => static_lookup && static_lookup(ip, iface) !is null;

    void touch(ref NeighbourEntry!IP e)
    {
        if (changed)
            changed(e, false);
    }

    void queue_pending(ref NeighbourEntry!IP e, ref Packet pkt)
    {
        if (e.pending_count == pending_queue_depth)
        {
            // evict oldest to make room for newest
            e.pending[0].free_clone();
            foreach (i; 1 .. pending_queue_depth)
                e.pending[i - 1] = e.pending[i];
            --e.pending_count;

            ++_pending_overflow;
            if (_pending_overflow == 1 || (_pending_overflow & 0xFF) == 0)
                log.warning("pending-queue overflow #", _pending_overflow,
                            ": dropping queued packet for ", e.ip,
                            " on ", e.iface.name, " (state=", e.state, ")");
        }
        Packet* queued = pkt.clone();
        if (!queued)
            return;
        e.pending[e.pending_count] = queued;
        ++e.pending_count;
    }

    void free_pending(ref NeighbourEntry!IP e)
    {
        foreach (i; 0 .. e.pending_count)
            e.pending[i].free_clone();
        e.pending_count = 0;
    }

    void drain_pending(ref NeighbourEntry!IP e)
    {
        if (!drain)
        {
            free_pending(e);
            return;
        }
        foreach (i; 0 .. e.pending_count)
        {
            drain(*e.pending[i], e.iface, e.link_addr[0 .. e.link_addr_len]);
            e.pending[i].free_clone();
        }
        e.pending_count = 0;
    }

    Array!(NeighbourEntry!IP) _entries;
    ulong _pending_overflow;
}


// The collection-facing halves of the cache delegates.
const(ubyte)[] static_link(T, IP)(IP ip, BaseInterface iface)
{
    foreach (n; Collection!T().values)
    {
        if (!(n.flags & ObjectFlags.dynamic) && n.iface is iface && n.address == ip)
            return n.link_address;
    }
    return null;
}

void publish_entry(T, IP)(ref const NeighbourEntry!IP e, bool removed)
{
    MACAddress mac;
    if (e.link_addr_len == 6)
        mac.b[] = e.link_addr[0 .. 6];
    IP address = e.ip;
    publish_neighbour!T(cast(BaseInterface)e.iface, address, e.state, mac, removed);
}


unittest
{
    NeighbourCache!IPv6Addr cache;
    IPv6Addr address = IPv6Addr(0xFE80, 0, 0, 0, 0, 0, 0, 1);
    ubyte[6] first = [ 0, 1, 2, 3, 4, 5 ];
    ubyte[6] second = [ 6, 7, 8, 9, 10, 11 ];

    assert(!cache.advertise(address, null, first[], false, true, true));
    cache.observe(address, null, first[]);
    assert(cache.entries[0].state == NeighbourState.stale);

    assert(cache.advertise(address, null, first[], true, true, true));
    assert(cache.entries[0].state == NeighbourState.reachable);
    assert(cache.entries[0].is_router);

    assert(cache.advertise(address, null, second[], false, false, false));
    assert(cache.entries[0].state == NeighbourState.stale);
    assert(cache.entries[0].link_addr[0 .. first.length] == first[]);

    assert(cache.advertise(address, null, second[], false, false, true));
    assert(cache.entries[0].state == NeighbourState.stale);
    assert(cache.entries[0].link_addr[0 .. second.length] == second[]);
}
