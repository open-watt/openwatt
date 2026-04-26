module manager.sync.ws_server;

// WebSocketSyncServer - binds a URI on an HTTPServer and spawns one SyncPeer
// per accepted WebSocket connection. Each peer's transport is the WebSocket
// itself (now a BaseInterface emitting raw packets); the encoder is whatever
// kind this server was configured with (JSON by default).
//
// Peers are destroyed when their WebSocket transport dies, either via the
// client disconnecting (ObjectRef detaches) or shutdown.

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.sync.encoder;
import manager.sync.peer;

import protocol.http.server;
import protocol.http.websocket;


nothrow @nogc:


alias log = Log!"sync.ws-server";


class WebSocketSyncServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri",         uri),
                                 Prop!("encoder",     encoder));
nothrow @nogc:

    enum type_name = "sync-ws";
    enum path = "/sync/ws-server";
    enum collection_id = CollectionType.sync_ws_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocketSyncServer, id, flags);
    }

    // Properties

    final inout(HTTPServer) http_server() inout pure
        => _http_server;
    final void http_server(HTTPServer value)
    {
        if (_http_server is value)
            return;
        _http_server = value;
        restart();
    }

    final const(char)[] uri() const pure
        => _uri[];
    final void uri(const(char)[] value)
    {
        if (_uri[] == value)
            return;
        _uri = value.makeString(g_app.allocator);
        restart();
    }

    final SyncEncoderKind encoder() const pure
        => _encoder;
    final void encoder(SyncEncoderKind value)
    {
        if (_encoder == value)
            return;
        _encoder = value;
        restart();
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _http_server !is null
        && _uri.length > 0;

    override CompletionStatus startup()
    {
        _ws_server = Collection!WebSocketServer().create(tconcat(name[], "-ws"), ObjectFlags.dynamic);
        if (!_ws_server)
            return CompletionStatus.error;

        _ws_server.http_server(_http_server);
        _ws_server.uri(_uri[]);
        _ws_server.set_connection_callback(&on_ws_connect);

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        sweep_peers(true);

        if (_ws_server)
        {
            _ws_server.destroy();
            _ws_server = null;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        sweep_peers(false);
    }

private:
    ObjectRef!HTTPServer _http_server;
    String               _uri;
    SyncEncoderKind      _encoder;
    WebSocketServer      _ws_server;
    Array!SyncPeer       _peers;
    uint                 _next_conn_id;

    void on_ws_connect(WebSocket ws, void*)
    {
        const(char)[] peer_name = tconcat(name[], ++_next_conn_id);
        SyncPeer peer = Collection!SyncPeer().create(peer_name, ObjectFlags.dynamic);
        if (!peer)
        {
            log.warning("failed to create sync peer for new connection");
            return;
        }
        peer.transport(ws);
        peer.encoder(_encoder);
        _peers ~= peer;

        debug log.info("client connected -> ", peer.name[]);
    }

    void sweep_peers(bool all)
    {
        size_t i = 0;
        while (i < _peers.length)
        {
            SyncPeer peer = _peers[i];
            if (all || peer.transport is null)
            {
                debug log.info("removing peer ", peer.name[]);
                peer.destroy();
                _peers.remove(i);
            }
            else
                ++i;
        }
    }
}
