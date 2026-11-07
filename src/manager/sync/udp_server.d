module manager.sync.udp_server;

import urt.array;
import urt.inet;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;

import manager;
import manager.base;
import manager.collection;
import manager.sync.encoder;
import manager.sync.peer;
import manager.sync.udp_bind;

import router.iface;
import router.iface.endpoint : UDPReceiveInfo;
import router.iface.rdp : RDPEndpoint, RDPEvent;

nothrow @nogc:


alias log = Log!"sync.udp-server";

final class UDPSyncServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("bind", bind),
                                 Prop!("interface", interfaces),
                                 Prop!("port", port),
                                 Prop!("encoder", encoder));
nothrow @nogc:

    ~this() {}

    enum type_name = "sync-udp";
    enum path = "/sync/udp-server";
    enum collection_id = CollectionType.sync_udp_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!UDPSyncServer, id, flags);
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

    final SyncEncoderKind encoder() const pure
        => _encoder;
    final void encoder(SyncEncoderKind value)
    {
        if (_encoder == value)
            return;
        _encoder = value;
        mark_set!(typeof(this), "encoder")();
        restart();
    }

protected:

    override bool validate() const pure
        => (_bind.length || _interfaces.length) && _port != 0;

    override CompletionStatus startup()
    {
        if (_slave && !_accepting)
            return CompletionStatus.complete;
        bool refreshed = refresh_endpoints();
        if (!refreshed && !_endpoint_set.endpoints.length)
            return CompletionStatus.error;
        if (!_endpoint_set.any_open())
            return CompletionStatus.continue_;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        close_endpoints();
        sweep_peers(true);
        return CompletionStatus.complete;
    }

    override void update()
    {
        sweep_peers(false);
        if (_slave && !_accepting)
            return;
        refresh_endpoints();
        if (!_endpoint_set.any_open())
            restart();
    }

package:

    void configure_slave(const(InetAddress)[] bind, ObjectRef!BaseInterface[] interfaces, ushort port)
    {
        _slave = true;
        _port = port;
        _bind.clear();
        foreach (address; bind)
        {
            InetAddress local = address;
            local.port = 0;
            _bind ~= local;
        }
        _interfaces.clear();
        foreach (ref iface; interfaces)
            _interfaces.emplaceBack(iface.get);
    }

    void accepting(bool value)
    {
        assert(_slave);
        if (_accepting == value)
            return;
        _accepting = value;
        if (value)
            return restart();
        sweep_peers(true);
        close_endpoints();
    }

    // a domain announces the port only where this server would receive: the same family and address, a wildcard
    // covering its family, and an ether listener bound to a station only on that station
    ushort serving_port(ref const InetAddress source, BaseInterface station) const
    {
        if (!_accepting)
            return 0;
        ObjectRef!BaseInterface from = station;
        foreach (ref e; _endpoint_set.endpoints[])
        {
            ref const local = e.binding.local;
            if (local.family != source.family)
                continue;
            if (local.family == AddressFamily.ether && e.binding.iface && e.binding.iface != from)
                continue;
            if (local.addr_any || local.same_addr(source))
                return _port;
        }
        return 0;
    }

private:

    enum max_inbound_peers = 16;

    struct Spawned
    {
        RDPEndpoint* endpoint;
        InetAddress addr;
        SyncPeer peer;
    }

    Array!InetAddress _bind;
    Array!(ObjectRef!BaseInterface) _interfaces;
    RDPEndpointSet _endpoint_set;
    Array!Spawned _peers;
    bool _slave;
    bool _accepting = true;
    uint _next_conn_id;
    ushort _port = default_sync_port;
    SyncEncoderKind _encoder = SyncEncoderKind.binary;

    bool refresh_endpoints()
    {
        RDPEndpointHooks hooks = endpoint_hooks();
        return _endpoint_set.refresh(_bind[], _interfaces[], _port, hooks);
    }

    void close_endpoints()
    {
        RDPEndpointHooks hooks = endpoint_hooks();
        _endpoint_set.close(hooks);
    }

    RDPEndpointHooks endpoint_hooks()
        => RDPEndpointHooks(null, null, null, &remove_endpoint, &on_message, &on_event);

    void remove_endpoint(RDPEndpoint* endpoint)
    {
        for (size_t i = _peers.length; i-- > 0; )
            if (_peers[i].endpoint is endpoint)
                retire(i, false, true);
    }

    void on_message(RDPEndpoint* endpoint, const(void)[] message, PCP lane, ref UDPReceiveInfo info)
    {
        if (Spawned* spawned = find_peer(endpoint, info.source))
            spawned.peer.on_rdp_message(endpoint, message, lane, info);
    }

    void on_event(RDPEndpoint* endpoint, ref const InetAddress addr, RDPEvent event)
    {
        Spawned* spawned = find_peer(endpoint, addr);
        if (event == RDPEvent.established)
        {
            if (!spawned)
                spawn(endpoint, addr);
        }
        else if (event == RDPEvent.closed)
        {
            if (spawned)
                retire(spawned - _peers.ptr, false, true);
        }
        else if (spawned)
            spawned.peer.on_rdp_event(endpoint, addr, event);
    }

    void spawn(RDPEndpoint* endpoint, ref const InetAddress addr)
    {
        // a refused opener hears nothing, and its handshake backoff paces the next try
        if (!running || !_accepting || _peers.length >= max_inbound_peers)
            return endpoint.close_session(addr, false);
        const(char)[] peer_name = tconcat(name[], ++_next_conn_id);
        SyncPeer peer = Collection!SyncPeer().create(peer_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
        if (!peer)
        {
            log.warning("failed to create sync peer for ", addr);
            return endpoint.close_session(addr, false);
        }
        peer.encoder(_encoder);
        peer.bind_rdp_session(endpoint, addr);
        peer.subscribe(&on_peer_state);
        _peers ~= Spawned(endpoint, addr, peer);
        debug log.info("peer appeared from ", addr, " -> ", peer.name[]);
    }

    Spawned* find_peer(RDPEndpoint* endpoint, ref const InetAddress addr)
    {
        foreach (ref peer; _peers[])
            if (peer.endpoint is endpoint && peer.addr == addr)
                return &peer;
        return null;
    }

    void sweep_peers(bool all)
    {
        for (size_t i = _peers.length; i-- > 0; )
            if (all || _peers[i].peer.disabled)
                retire(i, true, true);
    }

    // the mapping goes first, so the closed this raises finds nothing and a reborn session at the address is new
    void retire(size_t index, bool close, bool destroy)
    {
        Spawned s = _peers[index];
        _peers.remove(index);
        debug log.info("removing peer ", s.peer.name[]);
        if (close)
            s.endpoint.close_session(s.addr);
        if (!destroy)
            return;
        s.peer.unsubscribe(&on_peer_state);
        s.peer.destroy();
    }

    // a temporary peer that ends, by restart or by an outside destroy, takes its RDP session with it
    void on_peer_state(ActiveObject peer, StateSignal signal)
    {
        if (signal != StateSignal.destroyed)
            return;
        foreach (i, ref s; _peers[])
        {
            if (s.peer is peer)
                return retire(i, true, false);
        }
    }
}


unittest
{
    import urt.mem;
    import router.iface.bridge : BridgeInterface;

    UDPSyncServer server = alloc!UDPSyncServer(CID(1));
    scope(exit) free(server);
    SyncPeer p1 = alloc!SyncPeer(CID(2));
    scope(exit) free(p1);
    SyncPeer p2 = alloc!SyncPeer(CID(3));
    scope(exit) free(p2);

    BridgeInterface i1 = alloc!BridgeInterface(CID(4));
    scope(exit) free(i1);
    BridgeInterface i2 = alloc!BridgeInterface(CID(5));
    scope(exit) free(i2);
    UDPSyncServer child = alloc!UDPSyncServer(CID(6));
    scope(exit) free(child);
    InetAddress[3] bindings = [InetAddress(IPAddr.any, 0), InetAddress(IPAddr.any, 0), InetAddress(IPv6Addr.loopback, 4826)];
    server.bind(bindings[]);
    assert(server.bind.length == 2);
    assert(server.validate());
    server.interfaces(i1, i2, i1);
    assert(server._interfaces.length == 2);

    child.configure_slave(server._bind[], server._interfaces[], 4900);
    assert(child._slave && child.validate() && child._port == 4900);
    assert(child._bind.length == 2 && child._bind[1] == InetAddress(IPv6Addr.loopback, 0) && child._interfaces.length == 2);
    {
        InetAddress served = InetAddress(IPAddr(10, 0, 0, 2), 4900);
        RDPEndpoint* listener = alloc!RDPEndpoint();
        scope(exit) free(listener);
        child._endpoint_set.endpoints.emplaceBack(UDPBindEndpoint(ObjectRef!BaseInterface(), served), listener);
        scope(exit) child._endpoint_set.endpoints.clear();
        assert(child.serving_port(InetAddress(IPAddr(10, 0, 0, 2), 4826), null) == 4900);
        assert(child.serving_port(InetAddress(IPAddr(10, 0, 0, 3), 4826), null) == 0, "no listener at that address, no dialable port");

        InetAddress any4 = InetAddress(IPAddr.any, 4900);
        child._endpoint_set.endpoints.emplaceBack(UDPBindEndpoint(ObjectRef!BaseInterface(), any4), listener);
        ubyte[6] mac = [0x02, 0, 0, 0, 0, 0x0E];
        BridgeInterface s1 = Collection!BridgeInterface().create("sync-srv-s1");
        BridgeInterface s2 = Collection!BridgeInterface().create("sync-srv-s2");
        scope(exit)
        {
            s1.destroy();
            s2.destroy();
            Collection!BridgeInterface().table.free_pending();
        }
        assert(child.serving_port(InetAddress(IPAddr(10, 0, 0, 3), 4826), null) == 4900, "an IPv4 wildcard covers IPv4");
        assert(child.serving_port(InetAddress(mac, 4826), s1) == 0, "but not an ether beacon");
        child._endpoint_set.endpoints.emplaceBack(UDPBindEndpoint(ObjectRef!BaseInterface(s1), InetAddress(mac, 4900)), listener);
        assert(child.serving_port(InetAddress(mac, 4826), s1) == 4900);
        assert(child.serving_port(InetAddress(mac, 4826), s2) == 0, "another station with the same MAC is not served");

        child._endpoint_set.endpoints.clear();
        child._endpoint_set.endpoints.emplaceBack(UDPBindEndpoint(ObjectRef!BaseInterface(), InetAddress(mac, 4900)), listener);
        assert(child.serving_port(InetAddress(mac, 4826), s2) == 4900, "a stationless listener on the MAC serves it on any station");
        ubyte[6] other = [0x02, 0, 0, 0, 0, 0x0F];
        assert(child.serving_port(InetAddress(other, 4826), s2) == 0);
        child._endpoint_set.endpoints.emplaceBack(UDPBindEndpoint(ObjectRef!BaseInterface(), InetAddress(MACAddress().b, 4900)), listener);
        assert(child.serving_port(InetAddress(other, 4826), s2) == 4900, "an ether wildcard serves every MAC");
    }
    child.accepting(false);

    InetAddress remote = InetAddress(IPAddr(10, 0, 0, 1), 1);
    RDPEndpoint* e1 = alloc!RDPEndpoint();
    scope(exit) free(e1);
    RDPEndpoint* e2 = alloc!RDPEndpoint();
    scope(exit) free(e2);
    server._peers ~= UDPSyncServer.Spawned(e1, remote, p1);
    server._peers ~= UDPSyncServer.Spawned(e2, remote, p2);
    assert(server.find_peer(e1, remote).peer is p1);
    assert(server.find_peer(e2, remote).peer is p2);

    server.on_peer_state(p1, StateSignal.destroyed);
    assert(server._peers.length == 1 && server._peers[0].peer is p2);

    server.on_peer_state(p1, StateSignal.destroyed);
    assert(server._peers.length == 1 && server._peers[0].peer is p2);
}
