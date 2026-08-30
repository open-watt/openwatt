module manager.sync.discovery;

// Peering discovery (docs/PEERING.draft.md): per-medium beacon domains announce this
// node's identity and populate a node-id-keyed neighbour table. The ether domain rides
// the OW announce control frame; other media (udp multicast, modbus) register their own
// domain collections later. The peering agent feeds the local announce state (role,
// cluster, claim) and consumes the table to find claim candidates.

import urt.array;
import urt.conv : format_uint;
import urt.endian;
import urt.inet;
import urt.log;
import urt.map;
import urt.mem;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;

nothrow @nogc:


alias log = Log!"discovery";

enum PeerRole : ubyte
{
    none,
    member,
    authority,
}

enum AnnounceTag : ubyte
{
    node_id   = 1,  // u64 BE, mandatory
    name      = 2,  // utf8
    role      = 3,  // u8 PeerRole
    cluster   = 4,  // utf8
    flags     = 5,  // u8 AnnounceFlags
    sync_port = 6,  // u16 BE, sync channel reach on this medium
}

enum AnnounceFlags : ubyte
{
    claimed = 1 << 0,
    adopted = 1 << 1,   // holds fleet allegiance (cluster + key); claims must prove the key
}

struct NodeAnnounce
{
    ulong node_id;
    const(char)[] name;
    const(char)[] cluster;
    PeerRole role;
    ubyte flags;
    ushort sync_port;
}

ubyte[] encode_announce(ref const NodeAnnounce a, ubyte[] buffer)
{
    size_t offset;
    bool put(AnnounceTag tag, scope const(ubyte)[] value)
    {
        if (value.length > 255 || offset + 2 + value.length > buffer.length)
            return false;
        buffer[offset++] = tag;
        buffer[offset++] = cast(ubyte)value.length;
        buffer[offset .. offset + value.length] = value[];
        offset += value.length;
        return true;
    }

    ubyte[8] id = void;
    storeBigEndian(cast(ulong*)id.ptr, a.node_id);
    if (!put(AnnounceTag.node_id, id))
        return null;
    put(AnnounceTag.name, cast(const(ubyte)[])a.name);
    if (a.role != PeerRole.none)
    {
        ubyte role = a.role;
        put(AnnounceTag.role, (&role)[0 .. 1]);
    }
    if (a.cluster.length)
        put(AnnounceTag.cluster, cast(const(ubyte)[])a.cluster);
    if (a.flags)
        put(AnnounceTag.flags, (&a.flags)[0 .. 1]);
    if (a.sync_port)
    {
        ubyte[2] port = void;
        storeBigEndian(cast(ushort*)port.ptr, a.sync_port);
        put(AnnounceTag.sync_port, port);
    }
    return buffer[0 .. offset];
}

bool decode_announce(scope return const(ubyte)[] tlv, out NodeAnnounce a)
{
    while (tlv.length >= 2)
    {
        AnnounceTag tag = cast(AnnounceTag)tlv[0];
        size_t len = tlv[1];
        if (tlv.length < 2 + len)
            return false;
        const(ubyte)[] value = tlv[2 .. 2 + len];
        tlv = tlv[2 + len .. $];

        switch (tag)
        {
            case AnnounceTag.node_id:
                if (len != 8)
                    return false;
                a.node_id = loadBigEndian(cast(const(ulong)*)value.ptr);
                break;
            case AnnounceTag.name:
                a.name = cast(const(char)[])value;
                break;
            case AnnounceTag.role:
                if (len == 1 && value[0] <= PeerRole.max)
                    a.role = cast(PeerRole)value[0];
                break;
            case AnnounceTag.cluster:
                a.cluster = cast(const(char)[])value;
                break;
            case AnnounceTag.flags:
                if (len == 1)
                    a.flags = value[0];
                break;
            case AnnounceTag.sync_port:
                if (len == 2)
                    a.sync_port = loadBigEndian(cast(const(ushort)*)value.ptr);
                break;
            default:
                break;  // unknown tags are forward compatibility, skip
        }
    }
    return a.node_id != 0;
}


enum neighbor_max_age = 600.seconds;

struct NeighborLink
{
nothrow @nogc:
    ObjectRef!BaseInterface iface;
    InetAddress local;
    InetAddress remote;
    ubyte failures;     // claim failures through this link; drives retry_at
    MonoTime retry_at;
    MonoTime last_seen;

    bool is_link(ref const ObjectRef!BaseInterface iface, ref const InetAddress local, ref const InetAddress remote) const pure
        => this.iface == iface && this.local.same_addr(local) && this.remote.same_addr(remote);
}

struct Neighbor
{
    this(this) @disable;
nothrow @nogc:
    ulong node_id;
    String name;
    String cluster;
    PeerRole role;
    ubyte flags;
    MonoTime last_seen;
    Array!NeighborLink links;

    bool claimed() const pure
        => (flags & AnnounceFlags.claimed) != 0;

    bool adopted() const pure
        => (flags & AnnounceFlags.adopted) != 0;

    NeighborLink* touch_link(BaseInterface iface, InetAddress local, InetAddress remote, MonoTime now)
    {
        ObjectRef!BaseInterface iface_ref = iface;
        foreach (ref l; links[])
        {
            if (l.iface == iface_ref && l.local.same_addr(local) && l.remote.same_addr(remote))
            {
                l.local.port = local.port;
                l.remote.port = remote.port;
                l.last_seen = now;
                return &l;
            }
        }
        links ~= NeighborLink(iface_ref, local, remote);
        links[links.length - 1].last_seen = now;
        return &links[links.length - 1];
    }

    // not pruned on station death: the ref self-heals if the name returns, and without beacons it ages out anyway
    void prune_links(MonoTime now)
    {
        for (size_t i = links.length; i-- > 0; )
        {
            if (now - links[i].last_seen >= neighbor_max_age)
                links.removeSwapLast(i);
        }
    }

    void clear_link_demotion()
    {
        foreach (ref l; links[])
        {
            l.failures = 0;
            l.retry_at = MonoTime();
        }
    }

    NeighborLink* best_link(MonoTime now)
    {
        NeighborLink* best = null;
        ulong best_speed = 0;
        foreach (ref l; links[])
        {
            BaseInterface iface = l.iface.get;
            if (!l.remote.port)
                continue;
            if (l.remote.family == AddressFamily.ether && (!iface || !iface.running))
                continue;
            if (now - l.last_seen >= neighbor_max_age || now < l.retry_at)
                continue;
            ulong speed = iface && iface.running ? iface.tx_link_speed : 0;
            if (!best || link_prefers(speed, l.last_seen, best_speed, best.last_seen))
            {
                best = &l;
                best_speed = speed;
            }
        }
        return best;
    }

    // TODO: operator cost override and link-class rank ahead of speed (see PEERING.draft.md)
    static bool link_prefers(ulong speed_a, MonoTime seen_a, ulong speed_b, MonoTime seen_b) pure
        => speed_a > speed_b || (speed_a == speed_b && seen_a > seen_b);
}


class EtherDiscovery : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("interval",  interval));
nothrow @nogc:

    enum type_name = "ether-discovery";
    enum path = "/sync/discover/ether";
    enum collection_id = CollectionType.sync_discovery;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!EtherDiscovery, id, flags);
    }

    // Properties

    final inout(EthernetStation) iface() inout pure
        => _iface;
    final void iface(EthernetStation value)
    {
        if (_iface.get is value)
            return;
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    final Duration interval() const pure
        => _interval;
    final void interval(Duration value)
    {
        if (_interval == value)
            return;
        _interval = value;
        mark_set!(typeof(this), "interval")();
    }

protected:

    override bool validate() const pure
        => _iface !is null && _interval > Duration.zero;

    override CompletionStatus startup()
    {
        EthernetStation i = _iface.get;
        if (!i || !i.running)
            return CompletionStatus.continue_;

        i.subscribe(&iface_state_change);
        _subscribed = true;
        send_announce();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        return super.shutdown();
    }

    override void update()
    {
        if (getTime() >= _next_announce)
            send_announce();
    }

private:
    ObjectRef!EthernetStation _iface;
    bool     _subscribed;
    Duration _interval = 30.seconds;
    MonoTime _next_announce;

    void send_announce()
    {
        _next_announce = getTime() + _interval;
        EthernetStation i = _iface.get;
        if (!i || !i.running)
            return;
        ubyte[192] buf = void;
        ubyte[] tlv = get_module!SyncDiscoveryModule.build_local_announce(buf);
        if (tlv)
            i.announce(tlv);
    }

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }
}


class SyncDiscoveryModule : Module
{
    mixin DeclareModule!"sync.discovery";
nothrow @nogc:

    Map!(ulong, Neighbor) neighbors;

    // Local announce state; fed by the peering agent, identity comes from /system.
    PeerRole local_role;
    String   local_cluster;
    bool     local_claimed;
    bool     local_adopted;
    ushort   local_sync_port;

    override void init()
    {
        g_app.console.register_collection!EtherDiscovery();
        g_app.console.register_command!(neighbor_print, "print")("/sync/neighbor", this);
        set_announce_sink(&on_announce);
    }

    override void update()
    {
        Collection!EtherDiscovery().update_all();

        MonoTime now = getTime();
        ulong[8] expired = void;
        size_t num_expired = 0;
        foreach (kvp; neighbors[])
        {
            ref n = kvp.value;
            n.prune_links(now);
            if (now - n.last_seen >= neighbor_max_age && num_expired < expired.length)
                expired[num_expired++] = kvp.key;
        }
        foreach (k; expired[0 .. num_expired])
            neighbors.remove(k);
    }

    ubyte[] build_local_announce(ubyte[] buffer)
    {
        import manager.system : hostname, node_id;

        NodeAnnounce a;
        a.node_id = node_id();
        a.name = hostname[];
        a.cluster = local_cluster[];
        a.role = local_role;
        a.flags = cast(ubyte)((local_claimed ? AnnounceFlags.claimed : 0) | (local_adopted ? AnnounceFlags.adopted : 0));
        a.sync_port = local_sync_port;
        return encode_announce(a, buffer);
    }

    void neighbor_print(Session session)
    {
        MonoTime now = getTime();
        foreach (kvp; neighbors[])
        {
            ref n = kvp.value;
            char[16] id = void;
            format_uint(n.node_id, id[], 16, 16, '0');
            session.write_line(id[], "  ", n.name[], "  role=", role_name(n.role),
                               n.cluster.length ? " cluster=" : "", n.cluster[],
                               " state=", n.claimed ? "claimed" : "unbound",
                               " age=", now - n.last_seen);
            foreach (ref l; n.links[])
            {
                BaseInterface iface = l.iface.get;
                const(char)[] via = iface ? iface.name[] : l.remote.family == AddressFamily.ether ? "(gone)" : "ip";
                session.write_line("    via=", via, " remote=", l.remote, " age=", now - l.last_seen);
            }
        }
    }

private:

    void on_announce(EthernetStation station, MACAddress src, scope const(ubyte)[] tlv)
    {
        import manager.system : node_id;

        NodeAnnounce a;
        if (!decode_announce(tlv, a))
            return;
        if (a.node_id == node_id())
            return;     // our own beacon reflected on a multi-homed segment

        Neighbor* n = a.node_id in neighbors;
        if (!n)
        {
            n = neighbors.insert(a.node_id, Neighbor(a.node_id));
            log.info("node '", a.name, "' appeared via ", station.name[], " (", src, ")");
        }
        if (n.name[] != a.name)
            n.name = a.name.make_string();
        if (n.cluster[] != a.cluster)
            n.cluster = a.cluster.make_string();
        n.role = a.role;
        n.flags = a.flags;
        n.last_seen = getTime();

        size_t known = n.links.length;
        InetAddress local = InetAddress(station.mac.b, local_sync_port);
        InetAddress remote = InetAddress(src.b, a.sync_port);
        n.touch_link(station, local, remote, n.last_seen);
        if (known && n.links.length > known)
            log.debug_("node '", a.name, "' also reachable via ", station.name[], " (", src, ")");
    }
}


const(char)[] role_name(PeerRole role)
{
    final switch (role)
    {
        case PeerRole.none:      return "none";
        case PeerRole.member:    return "member";
        case PeerRole.authority: return "authority";
    }
}

bool role_from_name(const(char)[] s, out PeerRole role)
{
    static foreach (m; __traits(allMembers, PeerRole))
    {
        if (s[] == role_name(__traits(getMember, PeerRole, m))[])
        {
            role = __traits(getMember, PeerRole, m);
            return true;
        }
    }
    return false;
}


unittest
{
    MonoTime t0 = MonoTime() + 1000.seconds;
    MACAddress mac_a = MACAddress(0x02, 0, 0, 0, 0, 1);
    MACAddress mac_b = MACAddress(0x02, 0, 0, 0, 0, 2);
    InetAddress local = InetAddress(mac_b.b, 7000);
    InetAddress remote_a = InetAddress(mac_a.b, 7000);
    InetAddress remote_b = InetAddress(mac_b.b, 7000);

    Neighbor n;
    n.touch_link(null, local, remote_a, t0);
    assert(n.links.length == 1);

    local.port = 7001;
    remote_a.port = 7002;
    n.touch_link(null, local, remote_a, t0 + 10.seconds);
    assert(n.links.length == 1);
    assert(n.links[0].local.port == 7001 && n.links[0].remote.port == 7002);
    assert(n.links[0].last_seen == t0 + 10.seconds);

    n.touch_link(null, local, remote_b, t0 + 100.seconds);
    assert(n.links.length == 2);

    n.links[0].failures = 3;
    n.links[0].retry_at = t0 + 500.seconds;
    n.clear_link_demotion();
    assert(n.links[0].failures == 0 && n.links[0].retry_at == MonoTime());

    n.prune_links(t0 + 10.seconds + neighbor_max_age);
    assert(n.links.length == 1 && n.links[0].remote.same_addr(remote_b));

    assert(n.best_link(t0 + 200.seconds) is null);

    {
        import urt.mem;
        import router.iface.bridge : BridgeInterface;

        BridgeInterface s1 = alloc!BridgeInterface(CID(1));
        BridgeInterface s2 = alloc!BridgeInterface(CID(2));
        scope(exit)
        {
            free(s2);
            free(s1);
        }

        NeighborLink l;
        l.iface = s1;
        l.local = local;
        l.remote = remote_a;
        ObjectRef!BaseInterface r1 = s1;
        ObjectRef!BaseInterface r2 = s2;
        ObjectRef!BaseInterface r_none;
        assert(r1.get is null && r2.get is null);   // neither is in the collection table
        assert(l.is_link(r1, local, remote_a));
        assert(!l.is_link(r2, local, remote_a));
        assert(!l.is_link(r1, local, remote_b));
        assert(!l.is_link(r_none, local, remote_a));
    }

    assert(Neighbor.link_prefers(1000, t0, 100, t0 + 50.seconds));
    assert(!Neighbor.link_prefers(100, t0 + 50.seconds, 1000, t0));
    assert(Neighbor.link_prefers(100, t0 + 50.seconds, 100, t0));
    assert(!Neighbor.link_prefers(100, t0, 100, t0 + 50.seconds));
}
