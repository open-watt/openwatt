module manager.sync_ws;

import urt.array;
import urt.format.json;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.meta.enuminfo;
import urt.string;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;
import manager.sync;

import protocol.http.server;
import protocol.http.websocket;

import router.iface;

//version = DebugSyncWS;

nothrow @nogc:


class WebSocketSyncChannel : SyncChannel
{
    alias Properties = AliasSeq!();
nothrow @nogc:

    enum type_name = "ws";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocketSyncChannel, id, flags);
    }

    void bind(WebSocket ws)
    {
        _ws = ws;
        PacketFilter filter;
        filter.type = PacketType.raw;
        filter.direction = PacketDirection.incoming;
        ws.subscribe(&on_ws_packet, filter);
        ws.subscribe(&on_ws_state_change);
    }

    void unbind()
    {
        if (_ws)
        {
            _ws.unsubscribe(&on_ws_packet);
            _ws.unsubscribe(&on_ws_state_change);
            _ws = null;
        }
    }

    bool ws_alive() const pure
        => _ws !is null;

    override void send(ref const SyncMessage msg)
    {
        if (!_ws || !_ws.running)
            return;

        Array!char buf;
        buf.reserve(256);
        encode(msg, buf);

        debug version (DebugSyncWS)
            log.trace("send: ", buf[]);

        Packet p;
        ref hdr = p.init!RawFrame(cast(const(ubyte)[])buf[]);
        hdr.is_text = true;
        _ws.forward(p);
    }

private:
    WebSocket _ws;

    void on_ws_state_change(ActiveObject, StateSignal signal)
    {
        if (signal != StateSignal.online)
            unbind();
    }

    void on_ws_packet(ref const Packet p, BaseInterface, PacketDirection, void*)
    {
        ref const hdr = p.hdr!RawFrame();
        if (!hdr.is_text)
            return;

        const(char)[] message = cast(const(char)[])p.data;

        debug version (DebugSyncWS)
            log.trace("recv: ", message);

        SyncMessage msg;
        if (!decode(message, msg))
            return;

        apply_inbound(msg);
    }

    void encode(ref const SyncMessage msg, ref Array!char buf)
    {
        const(char)[] kind = enum_key_from_value!SyncMessageKind(msg.kind);
        buf.append("{\"kind\":\"", kind, "\"");

        if (msg.target)
            buf.append(",\"target\":", msg.target.raw);

        final switch (msg.kind)
        {
            case SyncMessageKind.bind:
                buf.append(",\"type\":\"", msg.type[], "\"");
                if (msg.seq)
                    buf.append(",\"seq\":", msg.seq);
                if (msg.props.length)
                {
                    buf ~= ",\"props\":{";
                    foreach (i, ref kv; msg.props)
                    {
                        if (i)
                            buf ~= ',';
                        buf.append("\"", kv.name[], "\":");
                        size_t n = kv.value.write_json(null);
                        kv.value.write_json(buf.extend(n));
                    }
                    buf ~= '}';
                }
                break;
            case SyncMessageKind.unbind:
                break;
            case SyncMessageKind.create:
                buf.append(",\"seq\":", msg.seq, ",\"type\":\"", msg.type[], "\"");
                if (msg.props.length)
                {
                    buf ~= ",\"props\":{";
                    foreach (i, ref kv; msg.props)
                    {
                        if (i)
                            buf ~= ',';
                        buf.append("\"", kv.name[], "\":");
                        size_t n = kv.value.write_json(null);
                        kv.value.write_json(buf.extend(n));
                    }
                    buf ~= '}';
                }
                break;
            case SyncMessageKind.destroy:
                break;
            case SyncMessageKind.set:
                buf.append(",\"prop\":\"", msg.prop[], "\"");
                buf ~= ",\"value\":";
                size_t bytes = msg.value.write_json(null);
                msg.value.write_json(buf.extend(bytes));
                break;
            case SyncMessageKind.reset:
                buf.append(",\"prop\":\"", msg.prop[], "\"");
                if (!msg.value.isNull)
                {
                    buf ~= ",\"value\":";
                    size_t rb = msg.value.write_json(null);
                    msg.value.write_json(buf.extend(rb));
                }
                break;
            case SyncMessageKind.state:
                buf.append(",\"signal\":\"", enum_key_from_value!StateSignal(msg.signal), "\"");
                break;
            case SyncMessageKind.cmd:
                buf.append(",\"seq\":", msg.seq, ",\"text\":");
                {
                    const vt = Variant(msg.text[]);
                    size_t nt = vt.write_json(null);
                    vt.write_json(buf.extend(nt));
                }
                break;
            case SyncMessageKind.result:
                buf.append(",\"seq\":", msg.seq);
                if (!msg.value.isNull)
                {
                    buf ~= ",\"value\":";
                    size_t nv = msg.value.write_json(null);
                    msg.value.write_json(buf.extend(nv));
                }
                buf ~= ",\"text\":";
                {
                    const vt = Variant(msg.text[]);
                    size_t nt = vt.write_json(null);
                    vt.write_json(buf.extend(nt));
                }
                break;
            case SyncMessageKind.sub:
            case SyncMessageKind.unsub:
                buf.append(",\"pattern\":\"", msg.pattern[], "\"");
                break;
            case SyncMessageKind.error:
                buf.append(",\"seq\":", msg.seq, ",\"text\":");
                const vt = Variant(msg.text[]);
                size_t nt = vt.write_json(null);
                vt.write_json(buf.extend(nt));
                break;
            case SyncMessageKind.enum_req:
                buf.append(",\"type\":\"", msg.type[], "\",\"seq\":", msg.seq);
                break;
            case SyncMessageKind.enum_:
                buf.append(",\"type\":\"", msg.type[], "\",\"seq\":", msg.seq);
                if (!msg.value.isNull)
                {
                    buf ~= ",\"members\":";
                    size_t n = msg.value.write_json(null);
                    msg.value.write_json(buf.extend(n));
                }
                break;
        }

        buf ~= '}';
    }

    bool decode(const(char)[] text, out SyncMessage msg)
    {
        Variant json = parse_json(cast(char[])text);
        if (!json.isObject)
            return false;

        const(char)[] kind_str = json.getMember("kind").asString();
        const(SyncMessageKind)* kind = enum_from_key!SyncMessageKind(kind_str);
        if (!kind)
            return false;
        msg.kind = *kind;

        const(Variant)* target_var = json.getMember("target");
        if (target_var && !target_var.isNull)
            msg.target = CID(cast(uint)target_var.asLong());

        final switch (msg.kind)
        {
            case SyncMessageKind.bind:
                msg.type = json.getMember("type").asString().makeString(defaultAllocator);
                if (const(Variant)* sv = json.getMember("seq"))
                    msg.seq = cast(uint)sv.asLong();
                decode_props(json, msg);
                break;
            case SyncMessageKind.unbind:
                break;
            case SyncMessageKind.create:
                msg.seq = cast(uint)json.getMember("seq").asLong();
                msg.type = json.getMember("type").asString().makeString(defaultAllocator);
                decode_props(json, msg);
                break;
            case SyncMessageKind.destroy:
                break;
            case SyncMessageKind.set:
                msg.prop = json.getMember("prop").asString().makeString(defaultAllocator);
                if (const(Variant)* v = json.getMember("value"))
                    msg.value = *v;
                break;
            case SyncMessageKind.reset:
                msg.prop = json.getMember("prop").asString().makeString(defaultAllocator);
                break;
            case SyncMessageKind.state:
                const(char)[] sig_str = json.getMember("signal").asString();
                const(StateSignal)* sig = enum_from_key!StateSignal(sig_str);
                if (!sig)
                    return false;
                msg.signal = *sig;
                break;
            case SyncMessageKind.cmd:
                msg.seq = cast(uint)json.getMember("seq").asLong();
                msg.text = json.getMember("text").asString().makeString(defaultAllocator);
                break;
            case SyncMessageKind.result:
                msg.seq = cast(uint)json.getMember("seq").asLong();
                if (const(Variant)* v = json.getMember("value"))
                    msg.value = *v;
                msg.text = json.getMember("text").asString().makeString(defaultAllocator);
                break;
            case SyncMessageKind.sub:
            case SyncMessageKind.unsub:
                msg.pattern = json.getMember("pattern").asString().makeString(defaultAllocator);
                break;
            case SyncMessageKind.error:
                msg.seq = cast(uint)json.getMember("seq").asLong();
                msg.text = json.getMember("text").asString().makeString(defaultAllocator);
                break;
            case SyncMessageKind.enum_req:
                msg.type = json.getMember("type").asString().makeString(defaultAllocator);
                if (const(Variant)* sv = json.getMember("seq"))
                    msg.seq = cast(uint)sv.asLong();
                break;
            case SyncMessageKind.enum_:
                msg.type = json.getMember("type").asString().makeString(defaultAllocator);
                if (const(Variant)* sv = json.getMember("seq"))
                    msg.seq = cast(uint)sv.asLong();
                if (const(Variant)* mv = json.getMember("members"))
                    msg.value = *mv;
                break;
        }
        return true;
    }

    static void decode_props(ref Variant json, ref SyncMessage msg)
    {
        Variant* pv = json.getMember("props");
        if (!pv || !pv.isObject)
            return;
        foreach (k, ref v; *pv)
        {
            SyncProperty kv;
            kv.name = k.makeString(defaultAllocator);
            kv.value = v;
            msg.props ~= kv.move;
        }
    }
}


class WebSocketSyncServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri));
nothrow @nogc:

    enum type_name = "ws-sync";
    enum path = "/sync/channel/websocket";
    enum collection_id = CollectionType.sync_ws_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocketSyncServer, id, flags);
    }

    HTTPServer http_server() const
        => _server_id.get_item!HTTPServer;
    void http_server(HTTPServer value) pure
    {
        _server_id = value.id;
    }

    const(char)[] uri() const pure
        => _uri[];
    void uri(const(char)[] value)
    {
        _uri = value.makeString(g_app.allocator);
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _server_id.get_item!HTTPServer !is null && _uri.length > 0;

    override CompletionStatus startup()
    {
        HTTPServer server = _server_id.get_item!HTTPServer;

        _ws_server = Collection!WebSocketServer().create(tconcat(name[], "-ws"), ObjectFlags.dynamic);
        if (!_ws_server)
            return CompletionStatus.error;

        _ws_server.http_server(server);
        _ws_server.uri(_uri[]);
        _ws_server.set_connection_callback(&on_ws_connect);

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        sweep_channels(true);

        if (_ws_server)
        {
            _ws_server.destroy();
            _ws_server = null;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        sweep_channels(false);
    }

private:
    CID _server_id;
    String _uri;
    WebSocketServer _ws_server;
    Array!WebSocketSyncChannel _channels;
    uint _next_conn_id;

    void on_ws_connect(WebSocket ws, void*)
    {
        WebSocketSyncChannel ch = Collection!WebSocketSyncChannel().create(tconcat(name[], ++_next_conn_id), ObjectFlags.dynamic);
        if (!ch)
        {
            log.warning("failed to create channel for new connection");
            return;
        }

        ch.bind(ws);
        _channels ~= ch;

        debug version (DebugSyncWS)
            log.info("client connected -> ", ch.name[]);
    }

    void sweep_channels(bool all)
    {
        size_t i = 0;
        while (i < _channels.length)
        {
            WebSocketSyncChannel ch = _channels[i];
            if (all || !ch.ws_alive())
            {
                debug version (DebugSyncWS)
                    log.info("client disconnected, removing ", ch.name[]);

                ch.unbind();
                ch.detach_all();
                Collection!WebSocketSyncChannel().remove(ch);
                _channels.remove(i);
                defaultAllocator.freeT(ch);
            }
            else
                ++i;
        }
    }
}


class SyncWSModule : Module
{
    mixin DeclareModule!"sync_ws";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!WebSocketSyncServer();
    }

    override void update()
    {
        Collection!WebSocketSyncServer().update_all();
    }
}
