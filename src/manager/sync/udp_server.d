module manager.sync.udp_server;

// /sync/udp-server: the datagram listener from SYNC_TRANSPORTS.draft.md. Owns a wildcard
// multi-drop UDPInterface on the configured port and spawns a dynamic SyncPeer for the
// first datagram from each unknown source. The server holds the transport's only packet
// subscription and routes frames to peers by source address; spawned peers are bound to
// their source (bind_remote) so their tx is UDPFrame-addressed back to it.
// Datagram links have no death signal: peers whose source goes quiet are swept after the
// idle timeout, and a re-appearing source simply spawns a fresh peer.

import urt.array;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.sync.encoder;
import manager.sync.peer;

import router.iface;
import router.iface.packet;
import router.iface.udp;

nothrow @nogc:


alias log = Log!"sync.udp-server";


class UDPSyncServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("port",       port),
                                 Prop!("local-host", local_host),
                                 Prop!("encoder",    encoder),
                                 Prop!("timeout",    timeout));
nothrow @nogc:

    enum type_name = "sync-udp";
    enum path = "/sync/udp-server";
    enum collection_id = CollectionType.sync_udp_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!UDPSyncServer, id, flags);
    }

    // Properties

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

    // The bind address selects the family: empty is the IP wildcard, the zero mac
    // ("00:00:00:00:00:00") is ether's any-station, hearing OW-ethertype datagrams.
    final ref const(String) local_host() const pure
        => _local_host;
    final void local_host(String value)
    {
        if (value == _local_host)
            return;
        _local_host = value.move;
        mark_set!(typeof(this), "local-host")();
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
        => _port != 0;

    override CompletionStatus startup()
    {
        _iface = Collection!UDPInterface().create(tconcat(name[], "-udp"), ObjectFlags.dynamic);
        if (!_iface)
            return CompletionStatus.error;

        if (!_local_host.empty)
            _iface.local_host(_local_host);
        _iface.local_port(_port);
        _iface.subscribe(&on_packet, PacketFilter(PacketType.udp, PacketDirection.incoming));

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        // transport dies first: its offline signal reaches still-live peers, which handle
        // it with a restart; sweeping them first would fire the signal into destroyed objects
        if (_iface)
        {
            _iface.unsubscribe(&on_packet);
            _iface.destroy();
            _iface = null;
        }

        sweep_peers(true);

        return CompletionStatus.complete;
    }

    override void update()
    {
        sweep_peers(false);
    }

private:
    ushort          _port = 4712;
    String          _local_host;
    SyncEncoderKind _encoder = SyncEncoderKind.binary;
    Duration        _timeout = 300.seconds;
    UDPInterface    _iface;
    uint            _next_conn_id;

    struct Spawned
    {
        InetAddress addr;
        SyncPeer peer;
        MonoTime last_rx;
    }
    Array!Spawned _peers;

    void on_packet(ref const Packet p, BaseInterface, PacketDirection, void*) nothrow @nogc
    {
        InetAddress src = p.hdr!UDPFrame.address;
        foreach (ref s; _peers[])
        {
            if (s.addr == src)
            {
                s.last_rx = getTime();
                s.peer.deliver_frame(cast(const(ubyte)[])p.data);
                return;
            }
        }

        const(char)[] peer_name = tconcat(name[], ++_next_conn_id);
        SyncPeer peer = Collection!SyncPeer().create(peer_name, ObjectFlags.dynamic);
        if (!peer)
        {
            log.warning("failed to create sync peer for ", src);
            return;
        }
        peer.encoder(_encoder);
        // transport() clears the binding; its initial hello retries once bound.
        peer.transport(_iface);
        peer.bind_remote(src);
        peer.subscribe(&on_peer_state);
        _peers ~= Spawned(src, peer, getTime());

        debug log.info("peer appeared from ", src, " -> ", peer.name[]);

        peer.deliver_frame(cast(const(ubyte)[])p.data);
    }

    void sweep_peers(bool all)
    {
        MonoTime now = getTime();
        size_t i = 0;
        while (i < _peers.length)
        {
            if (all || now - _peers[i].last_rx >= _timeout)
            {
                debug log.info("removing peer ", _peers[i].peer.name[]);
                _peers[i].peer.destroy();   // on_peer_state drops the entry
            }
            else
                ++i;
        }
    }

    // whoever destroys a spawned peer, the source table follows
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
}


unittest
{
    import urt.mem;

    UDPSyncServer server = alloc!UDPSyncServer(CID(1));
    scope(exit) free(server);
    SyncPeer p1 = alloc!SyncPeer(CID(2));
    scope(exit) free(p1);
    SyncPeer p2 = alloc!SyncPeer(CID(3));
    scope(exit) free(p2);

    MonoTime now = getTime();
    server._peers ~= UDPSyncServer.Spawned(InetAddress(IPAddr(10, 0, 0, 1), 1), p1, now);
    server._peers ~= UDPSyncServer.Spawned(InetAddress(IPAddr(10, 0, 0, 2), 2), p2, now);

    // destruction drops the right entry, whoever destroyed the peer
    server.on_peer_state(p1, StateSignal.destroyed);
    assert(server._peers.length == 1 && server._peers[0].peer is p2);

    // a repeat signal for a gone peer is a no-op
    server.on_peer_state(p1, StateSignal.destroyed);
    assert(server._peers.length == 1 && server._peers[0].peer is p2);
}
