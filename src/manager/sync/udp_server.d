module manager.sync.udp_server;

import urt.array;
import urt.endian : loadLittleEndian, storeLittleEndian;
import urt.format.json : parse_json;
import urt.inet;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.sync.binary_encoder : Verb;
import manager.sync.encoder;
import manager.sync.peer;
import manager.sync.udp_bind;

import router.iface;
import router.iface.endpoint : UDPEndpoint;

nothrow @nogc:


alias log = Log!"sync.udp-server";


class UDPSyncServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("bind", bind),
                                 Prop!("interface", interfaces),
                                 Prop!("port", port),
                                 Prop!("encoder", encoder),
                                 Prop!("timeout", timeout));
nothrow @nogc:

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

    final Duration timeout() const pure
        => _timeout;
    final void timeout(Duration value)
    {
        if (_timeout == value)
            return;
        _timeout = value;
        mark_set!(typeof(this), "timeout")();
    }

protected:

    override bool validate() const pure
        => _slave || ((_bind.length || _interfaces.length) && _port != 0);

    override CompletionStatus startup()
    {
        if (_slave)
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
        if (!_slave)
        {
            refresh_endpoints();
            if (!_endpoint_set.any_open())
            {
                restart();
                return;
            }
        }
        sweep_peers(false);
    }

package:

    void configure_slave()
    {
        _slave = true;
    }

    void accepting(bool value)
    {
        assert(_slave);
        if (_accepting == value)
            return;
        _accepting = value;
        if (!value)
            sweep_peers(true);
    }

    void receive(UDPEndpoint* endpoint, const(void)[] data, ref const InetAddress src, MonoTime rx_time)
    {
        assert(_slave);
        if (_accepting && running)
            on_datagram(endpoint, data, src, rx_time);
    }

    void remove_endpoint(UDPEndpoint* endpoint)
    {
        assert(_slave);
        size_t i;
        while (i < _peers.length)
        {
            if (_peers[i].endpoint is endpoint)
                _peers[i].peer.destroy();
            else
                ++i;
        }
    }

private:

    enum max_inbound_peers = 16;

    struct Spawned
    {
        UDPEndpoint* endpoint;
        InetAddress addr;
        SyncPeer peer;
        MonoTime last_rx;
    }

    Array!InetAddress _bind;
    Array!(ObjectRef!BaseInterface) _interfaces;
    UDPEndpointSet _endpoint_set;
    Array!Spawned _peers;
    Duration _timeout = 300.seconds;
    bool _slave;
    bool _accepting = true;
    uint _next_conn_id;
    ushort _port = default_sync_port;
    SyncEncoderKind _encoder = SyncEncoderKind.binary;

    bool refresh_endpoints()
    {
        UDPEndpointHooks hooks = endpoint_hooks();
        return _endpoint_set.refresh(_bind[], _interfaces[], _port, hooks);
    }

    void close_endpoints()
    {
        UDPEndpointHooks hooks = endpoint_hooks();
        _endpoint_set.close(hooks);
    }

    UDPEndpointHooks endpoint_hooks()
    {
        return UDPEndpointHooks(null, null, &remove_endpoint, &on_datagram);
    }

    void on_datagram(UDPEndpoint* endpoint, const(void)[] data, ref const InetAddress src, MonoTime rx_time)
    {
        if (Spawned* spawned = find_peer(endpoint, src))
        {
            spawned.last_rx = rx_time;
            spawned.peer.deliver_frame(cast(const(ubyte)[])data);
            return;
        }
        if (_peers.length >= max_inbound_peers || !is_initial_sync_datagram(cast(const(ubyte)[])data))
            return;

        const(char)[] peer_name = tconcat(name[], ++_next_conn_id);
        ObjectFlags peer_flags = cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary);
        SyncPeer peer = Collection!SyncPeer().create(peer_name, peer_flags);
        if (!peer)
        {
            log.warning("failed to create sync peer for ", src);
            return;
        }
        peer.encoder(_encoder);
        peer.bind_udp_endpoint(endpoint, src);
        peer.subscribe(&on_peer_state);
        _peers ~= Spawned(endpoint, src, peer, rx_time);

        debug log.info("peer appeared from ", src, " -> ", peer.name[]);

        peer.deliver_frame(cast(const(ubyte)[])data);
    }

    Spawned* find_peer(UDPEndpoint* endpoint, ref const InetAddress addr)
    {
        foreach (ref peer; _peers[])
            if (peer.endpoint is endpoint && peer.addr == addr)
                return &peer;
        return null;
    }

    void sweep_peers(bool all)
    {
        MonoTime now = getTime();
        size_t i = 0;
        while (i < _peers.length)
        {
            if (all || now - _peers[i].last_rx >= _timeout || _peers[i].peer.disabled)
            {
                debug log.info("removing peer ", _peers[i].peer.name[]);
                _peers[i].peer.destroy();
            }
            else
                ++i;
        }
    }

    void on_peer_state(ActiveObject peer, StateSignal signal)
    {
        if (signal != StateSignal.destroyed)
            return;
        foreach (i, ref s; _peers[])
        {
            if (s.peer is peer)
            {
                _peers.remove(i);
                return;
            }
        }
    }

    bool is_initial_sync_datagram(scope const(ubyte)[] data) const
    {
        if (data.length < 12)
            return false;
        const(uint)* sessions = cast(const(uint)*)data.ptr;
        if (loadLittleEndian(sessions) == 0 || loadLittleEndian(sessions + 1) != 0 || data[8] != TxQueue.control || data[9] != 1 || data[10] != 0)
            return false;

        if (_encoder == SyncEncoderKind.binary)
            return data[11] == ubyte(Verb.hello);
        Variant json = parse_json(cast(const(char)[])data[11 .. $]);
        Variant* kind = json.isObject ? json.getMember("kind") : null;
        return kind && kind.isString && kind.asString == "hello";
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

    child.configure_slave();
    assert(child._slave && child.validate());
    child.accepting(false);

    align(size_t.sizeof) ubyte[64] initial = void;
    initial[] = 0;
    assert(!server.is_initial_sync_datagram(initial));
    storeLittleEndian(cast(uint*)initial.ptr, uint(1));
    initial[9] = 1;
    initial[11] = ubyte(Verb.hello);
    assert(server.is_initial_sync_datagram(initial));
    initial[11] = ubyte(Verb.val);
    assert(!server.is_initial_sync_datagram(initial));

    server._encoder = SyncEncoderKind.json;
    enum hello = `{"ver":1, "kind" : "hello"}`;
    initial[11 .. 11 + hello.length] = cast(const(ubyte)[])hello;
    assert(server.is_initial_sync_datagram(initial[0 .. 11 + hello.length]));

    MonoTime now = getTime();
    InetAddress remote = InetAddress(IPAddr(10, 0, 0, 1), 1);
    UDPEndpoint* e1 = alloc!UDPEndpoint();
    scope(exit) free(e1);
    UDPEndpoint* e2 = alloc!UDPEndpoint();
    scope(exit) free(e2);
    server._peers ~= UDPSyncServer.Spawned(e1, remote, p1, now);
    server._peers ~= UDPSyncServer.Spawned(e2, remote, p2, now);
    assert(server.find_peer(e1, remote).peer is p1);
    assert(server.find_peer(e2, remote).peer is p2);

    server.on_peer_state(p1, StateSignal.destroyed);
    assert(server._peers.length == 1 && server._peers[0].peer is p2);

    server.on_peer_state(p1, StateSignal.destroyed);
    assert(server._peers.length == 1 && server._peers[0].peer is p2);
}
