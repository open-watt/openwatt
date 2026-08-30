module manager.sync.discovery;

import urt.array;
import urt.conv : format_uint;
import urt.endian;
import urt.inet;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.features;
import manager.plugin;
import manager.sync.udp_bind;
import manager.sync.udp_server;

import router.iface;
import router.iface.endpoint : UDPEndpoint, UDPReceiveInfo;
import router.iface.ethernet;
import router.iface.mac;

static if (has_ip)
    import protocol.ip.address : IPAddress, interface_has_address;

nothrow @nogc:


alias log = Log!"discovery";

enum PeerRole : ubyte
{
    none,
    member,
    authority,
}

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


class UDPDiscovery : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("bind", bind),
                                 Prop!("interface", interfaces),
                                 Prop!("port", port),
                                 Prop!("multicast", multicast),
                                 Prop!("interval", interval));
nothrow @nogc:

    enum type_name = "udp-discovery";
    enum path = "/sync/discover/udp";
    enum collection_id = CollectionType.sync_discovery;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!UDPDiscovery, id, flags);
    }

    final inout(InetAddress)[] bind() inout pure
        => _bind[];
    final void bind(const(InetAddress)[] value)
    {
        replace_udp_bind(_bind, value);
        mark_set!(typeof(this), "bind")();
        restart();
    }

    final inout(ObjectRef!BaseInterface)[] interfaces() inout pure
        => _interfaces[];
    final void interfaces(BaseInterface[] value...)
    {
        replace_udp_interfaces(_interfaces, value);
        mark_set!(typeof(this), "interface")();
        restart();
    }

    final ushort port() const pure
        => _port;
    final void port(ushort value)
    {
        if (_port == value)
            return;
        _port = value;
        mark_set!(typeof(this), "port")();
        restart();
    }

    final bool multicast() const pure
        => _multicast;
    final void multicast(bool value)
    {
        if (_multicast == value)
            return;
        _multicast = value;
        mark_set!(typeof(this), "multicast")();
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
    {
        bool source = _interfaces.length != 0;
        foreach (ref address; _bind[])
            source = source || supports_family(address.family);
        return source && _port != 0 && _interval > Duration.zero;
    }

    override CompletionStatus startup()
    {
        bool refreshed = refresh_endpoints();
        if (!refreshed && !_endpoint_set.any_open())
            return CompletionStatus.error;
        if (!_endpoint_set.any_open())
            return CompletionStatus.continue_;
        if (!ensure_server())
            return CompletionStatus.error;
        send_announce();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        close_server();
        close_endpoints();
        return super.shutdown();
    }

    override void update()
    {
        refresh_endpoints();
        if (!_endpoint_set.any_open())
        {
            restart();
            return;
        }
        if (ensure_server())
            _server.accepting(get_module!SyncDiscoveryModule.local_role == PeerRole.authority);
        if (getTime() >= _next_announce)
            send_announce();
    }

private:
    static if (has_ip)
        enum IPAddr discovery_ipv4_group = IPAddr(239, 255, 79, 87);

    Array!InetAddress _bind;
    Array!(ObjectRef!BaseInterface) _interfaces;
    Array!UDPBindEndpoint _multicast_bindings;
    UDPEndpointSet _endpoint_set;
    UDPSyncServer _server;
    bool _multicast = true;
    ushort _port = default_discovery_port;
    Duration _interval = 30.seconds;
    MonoTime _next_announce;

    static if (has_ip)
    {
        static InetAddress discovery_destination(ref const UDPBindEndpoint binding)
        {
            if (binding.local.addr_any)
                return InetAddress(IPAddr.broadcast, binding.local.port);
            const(BaseInterface) bound_iface = binding.iface.get;
            foreach (configured; Collection!IPAddress().values)
            {
                if (configured.address.addr != binding.local._a.ipv4.addr ||
                    (bound_iface && configured.iface !is bound_iface))
                    continue;
                if (configured.address.prefix_len >= 31)
                    return InetAddress();
                return InetAddress(configured.address.get_network() | ~configured.address.net_mask(),
                                   binding.local.port);
            }
            return InetAddress(IPAddr.broadcast, binding.local.port);
        }
    }

    void send_announce()
    {
        _next_announce = getTime() + _interval;
        align(size_t.sizeof) ubyte[192] buf = void;
        ubyte[] tlv = get_module!SyncDiscoveryModule.build_local_announce(buf);
        if (!tlv)
            return;

        foreach (ref endpoint; _endpoint_set.endpoints[])
        {
            if (endpoint.binding.local.family == AddressFamily.ether)
            {
                endpoint.endpoint.sendto(tlv, InetAddress(MACAddress.broadcast.b, endpoint.binding.local.port));
                continue;
            }
            static if (has_ip)
            {
                if (endpoint.binding.local.family != AddressFamily.ipv4)
                    continue;
                if (_multicast)
                {
                    InetAddress destination = InetAddress(discovery_ipv4_group, endpoint.binding.local.port);
                    foreach_multicast_local(endpoint.binding.local.port, (IPAddr local)
                    {
                        if (local == IPAddr.any || endpoint.endpoint.outbound_interface(local))
                            endpoint.endpoint.sendto(tlv, destination);
                    });
                    continue;
                }
                InetAddress destination = discovery_destination(endpoint.binding);
                if (destination.family == AddressFamily.ipv4)
                    endpoint.endpoint.sendto(tlv, destination);
            }
        }
    }

    bool refresh_endpoints()
    {
        UDPEndpointHooks hooks = endpoint_hooks();
        return _endpoint_set.refresh(_bind[], _interfaces[], _port, hooks);
    }

    bool include_endpoint(ref const UDPBindEndpoint binding)
        => supports_family(binding.local.family);

    static bool supports_family(AddressFamily family) pure
    {
        if (family == AddressFamily.ether)
            return true;
        static if (has_ip)
            return family == AddressFamily.ipv4;
        else
            return false;
    }

    bool configure_endpoint(UDPEndpoint* endpoint, ref const UDPBindEndpoint binding)
    {
        static if (has_ip)
            if (binding.local.family == AddressFamily.ipv4)
            {
                if (_multicast)
                {
                    bool joined;
                    bool success = true;
                    foreach_multicast_local(binding.local.port, (IPAddr local)
                    {
                        joined = true;
                        success = endpoint.join(discovery_ipv4_group, local) && success;
                    });
                    return joined && success;
                }
                return endpoint.enable_broadcast();
            }
        return true;
    }

    static if (has_ip)
    {
        bool prepare_multicast_bindings(ref Array!UDPBindEndpoint bindings)
        {
            size_t i;
            while (i < bindings.length)
            {
                UDPBindEndpoint binding = bindings[i];
                if (!supports_family(binding.local.family))
                {
                    bindings.remove(i);
                    continue;
                }
                if (binding.local.family != AddressFamily.ipv4 || !binding.local.addr_any)
                {
                    ++i;
                    continue;
                }
                bool expanded;
                foreach (configured; Collection!IPAddress().values)
                {
                    BaseInterface iface = configured.iface;
                    if (!iface || !iface.running)
                        continue;
                    UDPBindEndpoint candidate = UDPBindEndpoint(ObjectRef!BaseInterface(iface), InetAddress(configured.address.addr, binding.local.port));
                    if (expanded)
                        bindings ~= candidate;
                    else
                    {
                        bindings[i].iface = candidate.iface;
                        bindings[i].local = candidate.local;
                    }
                    expanded = true;
                }
                ++i;
            }

            deduplicate_bindings(bindings);

            bool changed = bindings[] != _multicast_bindings[];
            if (changed)
            {
                _multicast_bindings.clear();
                foreach (binding; bindings[])
                    _multicast_bindings ~= binding;
            }
            foreach (ref binding; bindings[])
            {
                if (binding.local.family == AddressFamily.ipv4)
                {
                    binding.iface = ObjectRef!BaseInterface();
                    binding.local._a.ipv4.addr = IPAddr.any;
                }
            }
            deduplicate_bindings(bindings);
            return changed;
        }

        static void deduplicate_bindings(ref Array!UDPBindEndpoint bindings)
        {
            for (size_t i = bindings.length; i-- > 0; )
                foreach (ref earlier; bindings[0 .. i])
                    if (bindings[i] == earlier)
                    {
                        bindings.remove(i);
                        break;
                    }
        }

        void foreach_multicast_local(ushort port, scope void delegate(IPAddr) nothrow @nogc sink)
        {
            foreach (ref binding; _multicast_bindings[])
                if (binding.local.family == AddressFamily.ipv4 && binding.local.port == port)
                    sink(binding.local._a.ipv4.addr);
        }

        InetAddress selected_local(IPAddr destination, BaseInterface ingress, ushort port, bool group)
        {
            foreach (ref binding; _multicast_bindings[])
            {
                if (binding.local.family != AddressFamily.ipv4 || binding.local.port != port)
                    continue;
                IPAddr local = binding.local._a.ipv4.addr;
                if (group)
                {
                    if (local == IPAddr.any || (binding.iface && binding.iface.get is ingress) || interface_has_address(ingress, local))
                        return InetAddress(local, port);
                }
                else if (local == IPAddr.any || local == destination)
                    return InetAddress(destination, port);
            }
            return InetAddress();
        }
    }

    void close_endpoints()
    {
        UDPEndpointHooks hooks = endpoint_hooks();
        _endpoint_set.close(hooks);
    }

    UDPEndpointHooks endpoint_hooks()
    {
        static if (has_ip)
            UDPBindingsPrepare prepare = _multicast ? &prepare_multicast_bindings : null;
        else
            UDPBindingsPrepare prepare;
        return UDPEndpointHooks(prepare, &include_endpoint, &configure_endpoint, &remove_endpoint, &on_datagram);
    }

    void remove_endpoint(UDPEndpoint* endpoint)
    {
        if (_server)
            _server.remove_endpoint(endpoint);
    }

    bool ensure_server()
    {
        if (_server)
            return true;
        auto servers = Collection!UDPSyncServer();
        const(char)[] server_name = servers.generate_name(tconcat(name[], "-sync"));
        UDPSyncServer server = servers.create(server_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
        if (!server)
        {
            log.error("failed to create sync server for discovery domain '", name, "'");
            return false;
        }
        server.configure_slave();
        server.accepting(get_module!SyncDiscoveryModule.local_role == PeerRole.authority);
        server.subscribe(&server_state_change);
        _server = server;
        return true;
    }

    void close_server()
    {
        if (!_server)
            return;
        UDPSyncServer server = _server;
        _server = null;
        server.unsubscribe(&server_state_change);
        server.destroy();
    }

    void server_state_change(ActiveObject server, StateSignal signal)
    {
        if (signal == StateSignal.destroyed && server is _server)
            _server = null;
    }

    void on_datagram(UDPEndpoint* endpoint, const(void)[] data, ref UDPReceiveInfo info)
    {
        foreach (ref bound; _endpoint_set.endpoints[])
        {
            if (bound.endpoint !is endpoint)
                continue;
            BaseInterface iface = info.ingress ? info.ingress : bound.binding.iface.get;
            const(ubyte)[] datagram = cast(const(ubyte)[])data;
            bool announce = is_announce_datagram(datagram);
            static if (has_ip)
            {
                if (_multicast && bound.binding.local.family == AddressFamily.ipv4)
                {
                    IPAddr destination = info.destination._a.ipv4.addr;
                    bool group = destination == discovery_ipv4_group;
                    InetAddress local = selected_local(destination, iface, bound.binding.local.port, group);
                    if (announce && local.family == AddressFamily.ipv4)
                        get_module!SyncDiscoveryModule.receive_announce(iface, local, info.source, datagram, info.rx_time);
                    else if (!announce && !group && local.family == AddressFamily.ipv4 && _server)
                        _server.receive(endpoint, data, info);
                    return;
                }
            }
            if (announce)
                get_module!SyncDiscoveryModule.receive_announce(iface, bound.binding.local, info.source, datagram, info.rx_time);
            else if (_server)
                _server.receive(endpoint, data, info);
            return;
        }
    }

}


class SyncDiscoveryModule : Module
{
    mixin DeclareModule!"sync.discovery";
nothrow @nogc:

    Map!(ulong, Neighbor) neighbors;

    PeerRole local_role;
    String   local_cluster;
    bool     local_claimed;
    bool     local_adopted;

    override void init()
    {
        g_app.console.register_collection!UDPDiscovery();
        g_app.console.register_command!(neighbor_print, "print")("/sync/neighbor", this);
    }

    override void update()
    {
        Collection!UDPDiscovery().update_all();

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
            session.write_line(id[], "  ", n.name[], "  role=", role_name(n.role), n.cluster.length ? " cluster=" : "", n.cluster[], " state=", n.claimed ? "claimed" : "unbound", " age=", now - n.last_seen);
            foreach (ref l; n.links[])
            {
                BaseInterface iface = l.iface.get;
                const(char)[] via = iface ? iface.name[] : l.remote.family == AddressFamily.ether ? "(gone)" : "ip";
                session.write_line("    via=", via, " remote=", l.remote, " age=", now - l.last_seen);
            }
        }
    }

private:

    void receive_announce(BaseInterface iface, InetAddress local, InetAddress from, scope const(ubyte)[] tlv, MonoTime rx_time)
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
            log.info("node '", a.name, "' appeared via ", iface ? iface.name[] : "ip", " (", from, ")");
        }
        if (n.name[] != a.name)
            n.name = a.name.make_string();
        if (n.cluster[] != a.cluster)
            n.cluster = a.cluster.make_string();
        n.role = a.role;
        n.flags = a.flags;
        n.last_seen = rx_time;

        size_t known = n.links.length;
        n.touch_link(iface, local, from, n.last_seen);
        if (known && n.links.length > known)
            log.debug_("node '", a.name, "' also reachable via ", iface ? iface.name[] : "ip", " (", from, ")");
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


private:

enum AnnounceTag : ubyte
{
    node_id = 1,
    name = 2,
    role = 3,
    cluster = 4,
    flags = 5,
}

enum AnnounceFlags : ubyte
{
    claimed = 1 << 0,
    adopted = 1 << 1,
}

enum neighbor_max_age = 600.seconds;

alias default_discovery_port = default_sync_port;

struct NodeAnnounce
{
    ulong node_id;
    const(char)[] name;
    const(char)[] cluster;
    PeerRole role;
    ubyte flags;
}

// Byte 8 cannot be a sync queue, so the shared port can distinguish announcements without parsing them.
static immutable ubyte[10] announce_magic = [ 'O', 'W', 'D', 'I', 'S', 'C', 1, 0, 0xFF, 0 ];

ubyte[] encode_announce(ref const NodeAnnounce a, ubyte[] buffer)
{
    if (buffer.length < announce_magic.length)
        return null;
    buffer[0 .. announce_magic.length] = announce_magic[];
    size_t offset = announce_magic.length;
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

    if (offset + 10 > buffer.length)
        return null;
    buffer[offset++] = AnnounceTag.node_id;
    buffer[offset++] = 8;
    buffer[offset .. offset + 4] = uint(a.node_id >> 32).nativeToBigEndian;
    buffer[offset + 4 .. offset + 8] = (cast(uint)a.node_id).nativeToBigEndian;
    offset += 8;
    if (!put(AnnounceTag.name, cast(const(ubyte)[])a.name))
        return null;
    if (a.role != PeerRole.none)
    {
        ubyte role = a.role;
        if (!put(AnnounceTag.role, (&role)[0 .. 1]))
            return null;
    }
    if (a.cluster.length && !put(AnnounceTag.cluster, cast(const(ubyte)[])a.cluster))
        return null;
    if (a.flags && !put(AnnounceTag.flags, (&a.flags)[0 .. 1]))
        return null;
    return buffer[0 .. offset];
}

bool decode_announce(scope return const(ubyte)[] tlv, out NodeAnnounce a)
{
    if (!is_announce_datagram(tlv))
        return false;
    tlv = tlv[announce_magic.length .. $];
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
                a.node_id = value[0 .. 8].bigEndianToNative!ulong;
                break;
            case AnnounceTag.name:
                a.name = cast(const(char)[])value;
                break;
            case AnnounceTag.role:
                if (len != 1 || value[0] > PeerRole.max)
                    return false;
                a.role = cast(PeerRole)value[0];
                break;
            case AnnounceTag.cluster:
                a.cluster = cast(const(char)[])value;
                break;
            case AnnounceTag.flags:
                if (len != 1)
                    return false;
                a.flags = value[0];
                break;
            default:
                break;
        }
    }
    return tlv.empty && a.node_id != 0;
}

bool is_announce_datagram(scope const(ubyte)[] data) pure
    => data.length >= announce_magic.length && data[0 .. announce_magic.length] == announce_magic[];


unittest
{
    MonoTime t0 = MonoTime() + 1000.seconds;
    MACAddress mac_a = MACAddress(0x02, 0, 0, 0, 0, 1);
    MACAddress mac_b = MACAddress(0x02, 0, 0, 0, 0, 2);
    InetAddress remote_a = InetAddress(mac_a.b, default_discovery_port);

    Neighbor n;
    InetAddress local = InetAddress(mac_b.b, default_discovery_port);
    n.touch_link(null, local, remote_a, t0);
    assert(n.links.length == 1);

    local.port = 7001;
    remote_a.port = 7002;
    n.touch_link(null, local, remote_a, t0 + 10.seconds);
    assert(n.links.length == 1);
    assert(n.links[0].local.port == 7001 && n.links[0].remote.port == 7002);
    assert(n.links[0].last_seen == t0 + 10.seconds);

    n.touch_link(null, local, InetAddress(mac_b.b, default_discovery_port), t0 + 100.seconds);
    assert(n.links.length == 2);

    n.links[0].failures = 3;
    n.links[0].retry_at = t0 + 500.seconds;
    n.clear_link_demotion();
    assert(n.links[0].failures == 0 && n.links[0].retry_at == MonoTime());

    n.prune_links(t0 + 10.seconds + neighbor_max_age);
    assert(n.links.length == 1 && n.links[0].remote.same_addr(InetAddress(mac_b.b, 0)));

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
        l.remote = InetAddress(mac_a.b, default_discovery_port);
        ObjectRef!BaseInterface r1 = s1;
        ObjectRef!BaseInterface r2 = s2;
        ObjectRef!BaseInterface r_none;
        InetAddress remote_link_a = InetAddress(mac_a.b, default_discovery_port);
        InetAddress remote_link_b = InetAddress(mac_b.b, default_discovery_port);
        assert(r1.get is null && r2.get is null);   // neither is in the collection table
        assert(l.is_link(r1, local, remote_link_a));
        assert(!l.is_link(r2, local, remote_link_a));
        assert(!l.is_link(r1, local, remote_link_b));
        assert(!l.is_link(r_none, local, remote_link_a));
    }

    assert(Neighbor.link_prefers(1000, t0, 100, t0 + 50.seconds));
    assert(!Neighbor.link_prefers(100, t0 + 50.seconds, 1000, t0));
    assert(Neighbor.link_prefers(100, t0 + 50.seconds, 100, t0));
    assert(!Neighbor.link_prefers(100, t0, 100, t0 + 50.seconds));

    {
        NodeAnnounce sent;
        sent.node_id = 0x0102030405060708;
        sent.name = "peer";
        sent.role = PeerRole.authority;
        align(size_t.sizeof) ubyte[64] buffer = void;
        ubyte[] encoded = encode_announce(sent, buffer);
        assert(is_announce_datagram(encoded));
        NodeAnnounce received;
        assert(decode_announce(encoded, received));
        assert(received.node_id == sent.node_id && received.name == sent.name && received.role == sent.role);
        encoded[0] ^= 1;
        assert(!is_announce_datagram(encoded));
        assert(!decode_announce(encoded, received));

        encoded = encode_announce(sent, buffer);
        assert(!decode_announce(encoded[0 .. $ - 1], received));
        buffer[encoded.length] = 0;
        assert(!decode_announce(buffer[0 .. encoded.length + 1], received));

        ubyte[12] short_buffer = void;
        assert(!encode_announce(sent, short_buffer));
    }

    {
        import urt.mem;
        import router.iface.bridge : BridgeInterface;

        UDPDiscovery domain = alloc!UDPDiscovery(CID(3));
        BridgeInterface s1 = alloc!BridgeInterface(CID(4));
        BridgeInterface s2 = alloc!BridgeInterface(CID(5));
        scope(exit)
        {
            free(s2);
            free(s1);
            free(domain);
        }

        assert(s1.prop_element(prop_index!(EthernetStation, "mac")).try_write(mac_a) is null);
        assert(s2.prop_element(prop_index!(EthernetStation, "mac")).try_write(mac_a) is null);

        Variant ether = Variant("02:00:00:00:00:01");
        assert(domain.set("bind", ether));
        assert(domain._bind[0] == InetAddress(mac_a.b, 0));
        assert(bind_port(domain._bind[0], domain.port) == default_discovery_port);

        domain.port(1234);
        assert(bind_port(domain._bind[0], domain.port) == 1234);
        domain.port(default_discovery_port);

        InetAddress wildcard = InetAddress(MACAddress().b, 1234);
        domain.bind((&wildcard)[0 .. 1]);
        assert(bind_port(domain._bind[0], domain.port) == 1234);

        const(char)[][2] bind_text = ["192.168.1.1", "[::1]"];
        Variant ip_bind = Variant(bind_text[]);
        assert(domain.set("bind", ip_bind));
        assert(domain.bind.length == 2);
        assert(domain.bind[1] == InetAddress(IPv6Addr.loopback, 0));
        static if (has_ip)
        {
            Array!UDPBindEndpoint bindings;
            collect_udp_bindings(domain._bind[], domain._interfaces[], domain.port, bindings);
            assert(bindings.length == 2);
            assert(bindings[0].local == InetAddress(IPAddr(192, 168, 1, 1), default_discovery_port));
            assert(bindings[1].local == InetAddress(IPv6Addr.loopback, default_discovery_port));
            assert(domain.multicast);
            assert(domain.include_endpoint(bindings[0]));
            assert(!domain.include_endpoint(bindings[1]));
            assert(domain.prepare_multicast_bindings(bindings));
            assert(domain._multicast_bindings.length == 1);
            assert(domain._multicast_bindings[0].local == InetAddress(IPAddr(192, 168, 1, 1), default_discovery_port));
            assert(bindings.length == 1);
            assert(bindings[0].local == InetAddress(IPAddr.any, default_discovery_port));
            collect_udp_bindings(domain._bind[], domain._interfaces[], domain.port, bindings);
            assert(!domain.prepare_multicast_bindings(bindings));

            InetAddress[3] multicast_bind = [InetAddress(IPAddr(192, 168, 1, 1), 0),
                                             InetAddress(IPAddr(192, 168, 1, 2), 0),
                                             InetAddress(IPAddr(192, 168, 1, 3), 1234)];
            domain.bind(multicast_bind[]);
            collect_udp_bindings(domain._bind[], domain._interfaces[], domain.port, bindings);
            assert(domain.prepare_multicast_bindings(bindings));
            assert(domain._multicast_bindings.length == 3);
            assert(bindings.length == 2);

            domain.multicast(false);
            assert(domain.include_endpoint(bindings[0]));

            UDPBindEndpoint wildcard_binding = UDPBindEndpoint(ObjectRef!BaseInterface(), InetAddress(IPAddr.any, 6667));
            assert(UDPDiscovery.discovery_destination(wildcard_binding) == InetAddress(IPAddr.broadcast, 6667));
        }

        InetAddress[1] only_ipv6 = [InetAddress(IPv6Addr.loopback, 0)];
        domain.bind(only_ipv6[]);
        assert(!domain.validate());

        const(InetAddress)[] no_addresses;
        domain.bind(no_addresses);
        domain.interfaces(s1, s2, s1);
        assert(domain._interfaces.length == 2);
    }
}
