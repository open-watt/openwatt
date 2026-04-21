module protocol.http.websocket;

import urt.array;
import urt.digest.sha;
import urt.encoding;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem : memmove;
import urt.mem.allocator;
import urt.rand;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.http;
import protocol.http.message;
import protocol.http.server;

import router.iface;
import router.stream;

//version = DebugWebSocket;

nothrow @nogc:


// Outstanding improvements:
//  - Subprotocol negotiation: `protocols` property on both sides. Client sends
//    `Sec-WebSocket-Protocol: a, b, c`; server picks the first it supports and
//    echoes back. Needed for layered protocols (MQTT-over-WS, graphql-ws, etc.).
//  - permessage-deflate (RFC 7692): negotiate via `Sec-WebSocket-Extensions`;
//    per-frame RSV1 signals a compressed payload. Use urt.zip for deflate.
//  - UTF-8 validation for text frames: spec requires valid UTF-8; currently unchecked.
//  - Periodic ping + pong-timeout tracking for liveness. We reply to pings but
//    never send them, so half-open TCP connections go undetected.
//  - Fragmentation on send: transmit() always emits a single frame. Split large
//    payloads across continuation frames if a peer/proxy has frame-size limits.
//  - Error-path cleanup: the remaining `assert(false, "TODO")` / "What to do?!"
//    sites around stream-read failures and unknown extensions in the handshake.


enum WSExtensions : ubyte
{
    None = 0,
    PerMessageCompression = 1 << 0,
    ClientMaxWindowBits = 1 << 1,
//    PerMessageCompression = "permessage-deflate",
//    ServerPush = "server-push",
//    ClientPush = "client-push",
//    ChannelId = "channel-id",
//    ChannelIdClient = "channel-id-client",
//    ChannelIdServer = "channel-id-server",
//    ChannelIdClientServer = "channel-id-client-server"
}


class WebSocket : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("stream", stream));
nothrow @nogc:

    enum type_name = "websocket";
    enum path = "/interface/websocket";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocket, id, flags);
    }

    // Properties...

    ref const(String) remote() const pure
        => _host;
    void remote(InetAddress value)
    {
        _host = null;
        if (value == _remote)
            return;
        _remote = value;
        restart();
    }
    const(char)[] remote(String value)
    {
        if (value.empty)
            return "remote cannot be empty";
        if (value == _host)
            return null;
        _host = value.move;
        _remote = InetAddress();
        restart();
        return null;
    }

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream stream)
    {
        if (_stream is stream)
            return;
        if (_subscribed)
        {
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
        _stream = stream;
        restart();
    }

    // API...

protected:
    mixin RekeyHandler;

    override bool validate() const pure
    {
        if (_is_server)
            return _stream !is null;
        // client: URL xor stream
        return (!_host.empty || _remote != InetAddress()) != !!_stream;
    }

    override CompletionStatus startup()
    {
        if (!_stream)
        {
            // Only client-mode reaches here; server-mode objects always have _stream set.
            const(char)[] stream_name = Collection!Stream().generate_name(name[]);
            _stream = create_http_stream(stream_name, _host[], _remote, _resource);
            if (!_stream)
                return CompletionStatus.error;
        }

        if (!_stream.running)
            return CompletionStatus.continue_;

        if (!_is_server && _handshake_parser is null && !_subscribed)
        {
            // Generate a 16-byte random nonce, base64-encoded, as the Sec-WebSocket-Key.
            ubyte[16] nonce = void;
            foreach (i; 0 .. 4)
                (cast(uint*)nonce.ptr)[i] = rand();
            char[base64_encode_length(16)] key_b64 = void;
            base64_encode(nonce[], key_b64[]);
            _handshake_key = key_b64[].makeString(defaultAllocator);

            HTTPMessage req;
            req.http_version = HTTPVersion.V1_1;
            req.method = HTTPMethod.GET;
            req.flags = HTTPFlags.NoDefaults;
            req.request_target = (_resource.length ? _resource : "/").makeString(defaultAllocator);
            req.url = req.request_target;
            req.headers ~= HTTPParam(StringLit!"User-Agent", StringLit!"OpenWatt");
            req.headers ~= HTTPParam(StringLit!"Upgrade", StringLit!"websocket");
            req.headers ~= HTTPParam(StringLit!"Connection", StringLit!"Upgrade");
            req.headers ~= HTTPParam(StringLit!"Sec-WebSocket-Key", _handshake_key);
            req.headers ~= HTTPParam(StringLit!"Sec-WebSocket-Version", StringLit!"13");

            Array!char msg = req.format_message(http_host_header(_host[]));
            if (msg.empty || _stream.write(msg[]) != msg.length)
                return CompletionStatus.error;

            _handshake_parser = defaultAllocator().allocT!HTTPParser(&handshake_response);
        }

        if (_handshake_parser)
        {
            int r = _handshake_parser.update(_stream);
            if (r < 0)
                return CompletionStatus.error;
            if (r == 0)
                return CompletionStatus.continue_;
            // r > 0: upgrade handler claimed the connection
            defaultAllocator().freeT(_handshake_parser);
            _handshake_parser = null;
            _handshake_key = String();
        }

        _stream.subscribe(&stream_state_change);
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
            send_close(1001); // going away
        if (_subscribed)
        {
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
        if (_handshake_parser)
        {
            defaultAllocator().freeT(_handshake_parser);
            _handshake_parser = null;
            _handshake_key = String();
        }
        if (!_is_server && (!_host.empty || _remote != InetAddress()) && _stream)
        {
            _stream.destroy();
            _stream = null;
        }
        _resource = null;
        _close_sent = false;
        _message.clear();
        _decoded_bytes = 0;
        _rx_overhead = 0;
        _pending_message_type = WSMessageType.unknown;
        return CompletionStatus.complete;
    }

    final override void update()
    {
        super.update();

        ubyte[1024] tmp = void;
        ubyte[] buf = _message.empty ? tmp[] : _message[];
        size_t read = _message.empty ? 0 : _message.length;
        size_t frame_start = _decoded_bytes;

        MonoTime timestamp = getTime();

        while (true)
        {
            // shuffle tail bytes to the start of the buffer
            if (frame_start > _decoded_bytes)
            {
                size_t tail = read - frame_start;
                memmove(buf.ptr + _decoded_bytes, buf.ptr + frame_start, tail);
                read = _decoded_bytes + tail;
                frame_start = _decoded_bytes;
            }

            // parse any complete frames already in the buffer — important on the
            // first iteration after an HTTP→WS upgrade, where _message was seeded
            // with leftover bytes from the HTTP parser before any stream.read.
            while (frame_start + 2 < read)
            {
                ubyte[] msg = buf[frame_start .. read];

                ubyte opcode = msg[0] & 0xF; // OPCODE
                bool rsv3 = (msg[0] >> 4) & 1; // RSV3
                bool rsv2 = (msg[0] >> 5) & 1; // RSV2
                bool rsv1 = (msg[0] >> 6) & 1; // RSV1
                bool fin = msg[0] >> 7; // FIN
                bool mask = msg[1] >> 7; // MASK
                ubyte[4] mask_key;

                // work out payload length
                size_t payload_len = msg[1] & 0x7F;
                size_t offset = 2;
                if (payload_len == 0x7E)
                {
                    if (msg.length < offset + 2)
                        break;
                    payload_len = msg[offset .. offset + 2][0..2].bigEndianToNative!ushort;
                    offset += 2;
                }
                else if (payload_len == 0x7F)
                {
                    if (msg.length < offset + 8)
                        break;
                    ulong len = msg[offset .. offset + 8][0..8].bigEndianToNative!ulong;
                    offset += 8;

                    if (len > size_t.sizeof) // we can't handle payloads larger than size_t!
                    {
                        add_rx_drop();
                        restart();
                        return;
                    }
                    payload_len = cast(size_t)len;
                }

                // if a mask was included
                if (mask)
                {
                    if (msg.length < offset + 4)
                        break;
                    mask_key = msg[offset .. offset + 4];
                    offset += 4;
                }

                // incomplete frame — break out; the outer loop reads more and the
                // end-of-function stash persists buf into _message across update calls.
                size_t msg_len = offset + payload_len;
                if (read < frame_start + msg_len)
                    break;

                switch (opcode)
                {
                    case 0: // continuation frame
                        if (_pending_message_type == WSMessageType.unknown)
                        {
                            // continuation frame without a prior frame
                            add_rx_drop();
                            restart();
                            return;
                        }
                        break;

                    case 1: // text frame
                    case 2: // binary frame
                        if (_pending_message_type != WSMessageType.unknown)
                        {
                            // must be the first frame in a series
                            add_rx_drop();
                            restart();
                            return;
                        }
                        _pending_message_type = opcode == 1 ? WSMessageType.text : WSMessageType.binary;
                        break;

                    case 9: // ping
                        // Control frames can't be fragmented and MUST be <= 125 bytes.
                        if (!fin || payload_len > 125)
                        {
                            add_rx_drop();
                            restart();
                            return;
                        }
                        // Unmask the ping payload into a local buffer and echo it in the pong.
                        ubyte[125] ping_payload = void;
                        if (mask)
                        {
                            foreach (i; 0 .. payload_len)
                                ping_payload[i] = cast(ubyte)(msg[offset + i] ^ mask_key[i & 3]);
                        }
                        else
                            ping_payload[0 .. payload_len] = cast(const(ubyte)[])msg[offset .. offset + payload_len];
                        send_control_frame(10, ping_payload[0 .. payload_len]);
                        frame_start += msg_len;
                        continue;

                    case 10: // pong
                        // TODO: record ping time...
                        frame_start += msg_len;
                        continue;

                    case 8: // connection close
                        send_close(1000); // echo a normal-closure frame before tearing down
                        restart();
                        return;

                    default:
                        // "If an unknown opcode is received, the receiving endpoint MUST _Fail the WebSocket Connection_"
                        add_rx_drop();
                        restart();
                        return;
                }

                // Accumulate per-fragment framing overhead; applied at dispatch below.
                // Drop paths (close/default, and the orphan/mid-series cases above) have
                // already returned without bumping this.
                _rx_overhead += offset;

                if (mask)
                {
                    for (size_t i = 0; i < payload_len; ++i)
                        buf[_decoded_bytes + i] = msg[offset + i] ^ mask_key[i & 3];
                }
                else
                {
                    if (_decoded_bytes == 0)
                    {
                        // shortcus for whole, self-contained frames.
                        version (DebugWebSocket)
                        {
                            size_t plen = msg_len - offset;
                            log.trace("dispatch ", _pending_message_type == WSMessageType.text ? "text" : "binary",
                                      " (", plen, " bytes): ",
                                      cast(void[])msg[offset .. offset + (plen <= 200 ? plen : 200)],
                                      plen > 200 ? ", ..." : "");
                        }

                        Packet p;
                        ref hdr = p.init!RawFrame(msg[offset .. msg_len], cast(SysTime)timestamp);
                        hdr.is_text = _pending_message_type == WSMessageType.text;
                        _status.rx_bytes += _rx_overhead; // dispatch() counts the payload; we add framing
                        _rx_overhead = 0;
                        dispatch(p);

                        frame_start += msg_len;
                        _pending_message_type = WSMessageType.unknown;
                        continue;
                    }
                    else
                        memmove(buf.ptr + _decoded_bytes, msg.ptr + offset, payload_len);
                }
                _decoded_bytes += payload_len;
                frame_start += msg_len;

                if (fin)
                {
                    version (DebugWebSocket)
                        log.trace("dispatch ", _pending_message_type == WSMessageType.text ? "text" : "binary",
                                  " (", _decoded_bytes, " bytes, reassembled): ",
                                  cast(void[])buf[0 .. _decoded_bytes <= 200 ? _decoded_bytes : 200],
                                  _decoded_bytes > 200 ? ", ..." : "");

                    Packet p;
                    ref hdr = p.init!RawFrame(buf[0 .. _decoded_bytes], cast(SysTime)timestamp);
                    hdr.is_text = _pending_message_type == WSMessageType.text;
                    _status.rx_bytes += _rx_overhead;
                    _rx_overhead = 0;
                    dispatch(p);

                    _pending_message_type = WSMessageType.unknown;
                    _decoded_bytes = 0;
                }
            }

            // fetch more data from the stream
            size_t available = _stream.pending();
            if (available == 0)
                break;
            if (available > buf.length - read)
            {
                _message.resize(read + available);
                if (buf.ptr is tmp.ptr)
                    _message[0 .. read] = tmp[0 .. read];
                buf = _message[];
            }

            ptrdiff_t r = _stream.read(buf[read .. read + available]);
            if (r < 0)
            {
                assert(false, "TODO: handle errors?");
                return;
            }
            timestamp = getTime();
            version (DebugWebSocket)
                log.trace("recv: (", r, ")[ ", cast(void[])buf[read .. read + (r <= 200 ? r : 200)], r > 200 ? ", ... ]" : " ]");
            read += r;
        }

        // shuffle any undispatched tail back down before stashing — the outer loop
        // may have exited via `pending == 0` right after parsing, before the top-of-loop
        // shuffle reclaims the gap between _decoded_bytes and frame_start.
        if (frame_start > _decoded_bytes)
        {
            size_t tail = read - frame_start;
            memmove(buf.ptr + _decoded_bytes, buf.ptr + frame_start, tail);
            read = _decoded_bytes + tail;
            frame_start = _decoded_bytes;
        }

        // stash any remaining bytes...
        _message.resize(read);
        if (read > 0 && buf.ptr is tmp.ptr)
            _message[] = tmp[0 .. read];
    }

    override int transmit(ref Packet packet, MessageCallback)
    {
        if (packet.type != PacketType.raw)
        {
            add_tx_drop();
            return -1;
        }

        ref hdr = packet.hdr!RawFrame();
        const(void)[] data = packet.data;

        // TODO: if hdr.is_text, confirm valid utf8 and fail if not

        ubyte[16] header; // max header size
        size_t header_len = 2;
        header[0] = 0x80 | (hdr.is_text ? 1 : 2); // FIN + opcode
        header[1] = _is_server ? 0 : 0x80; // MASK bit

        size_t payload_len = data.length;
        if (payload_len < 126)
            header[1] |= cast(ubyte)payload_len;
        else if (payload_len <= ushort.max)
        {
            header[1] |= 126;
            header[2 .. 4][0..2] = (cast(ushort)payload_len).nativeToBigEndian;
            header_len += 2;
        }
        else
        {
            header[1] |= 127;
            header[2 .. 10][0..8] = ulong(payload_len).nativeToBigEndian;
            header_len += 8;
        }

        ubyte[4] mask_key = 0;
        if (!_is_server)
        {
            *cast(uint*)mask_key.ptr = rand();
            header[header_len .. header_len + 4][0..4] = mask_key[];
            header_len += 4;
        }

        version (DebugWebSocket)
            log.trace("send ", hdr.is_text ? "text" : "binary", " (", data.length, ")[ ",
                      cast(void[])data[0 .. data.length <= 200 ? data.length : 200], data.length > 200 ? ", ... ]" : " ]");

        if (_stream.write(header[0 .. header_len]) != header_len)
        {
            add_tx_drop();
            restart();
            return -1;
        }

        if (_is_server)
        {
            size_t written = 0;
            while (written < data.length)
            {
                ptrdiff_t r = _stream.write(data[written .. $]);
                if (r < 0)
                {
                    add_tx_drop();
                    restart();
                    return -1;
                }
                written += r;
            }
        }
        else
        {
            ubyte[1024] scratch = void;
            const(ubyte)[] src = cast(const(ubyte)[])data;
            size_t i = 0;
            while (i < src.length)
            {
                size_t chunk = src.length - i;
                if (chunk > scratch.length)
                    chunk = scratch.length;
                foreach (j; 0 .. chunk)
                    scratch[j] = src[i + j] ^ mask_key[(i + j) & 3];
                size_t w = 0;
                while (w < chunk)
                {
                    ptrdiff_t r = _stream.write(scratch[w .. chunk]);
                    if (r < 0)
                    {
                        add_tx_drop();
                        restart();
                        return -1;
                    }
                    w += r;
                }
                i += chunk;
            }
        }
        add_tx_frame(header_len + data.length);
        return 0;
    }

private:
    ObjectRef!Stream _stream;
    String _host;
    InetAddress _remote;
    const(char)[] _resource; // slice into _host[]; url path, or empty
    WSExtensions _extensions;
    String _protocol;
    bool _is_server;
    bool _subscribed;
    bool _close_sent;

    HTTPParser* _handshake_parser; // non-null while client handshake is in flight
    String _handshake_key;

    Array!ubyte _message;
    size_t _decoded_bytes; // _message begins with decoded bytes, and the tail is pending bytes from incomplete transmission
    size_t _rx_overhead; // framing bytes for fragments buffered but not yet dispatched
    WSMessageType _pending_message_type;

    void stream_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
        {
            if (_subscribed)
            {
                _stream.unsubscribe(&stream_state_change);
                _subscribed = false;
            }
            restart();
        }
    }

    void send_control_frame(ubyte opcode, const(ubyte)[] payload)
    {
        if (!_stream || !_stream.running)
            return;
        assert(payload.length <= 125, "control frame payload must be <= 125 bytes");

        ubyte[2 + 4 + 125] frame = void;
        size_t len = 2;
        frame[0] = cast(ubyte)(0x80 | opcode); // FIN + opcode
        frame[1] = cast(ubyte)((_is_server ? 0 : 0x80) | payload.length);

        if (!_is_server)
        {
            ubyte[4] mask = void;
            *cast(uint*)mask.ptr = rand();
            frame[len .. len + 4][0..4] = mask[];
            len += 4;
            foreach (i; 0 .. payload.length)
                frame[len + i] = cast(ubyte)(payload[i] ^ mask[i & 3]);
        }
        else
            frame[len .. len + payload.length] = payload[];
        len += payload.length;

        _stream.write(frame[0 .. len]);
    }

    void send_close(ushort code)
    {
        if (_close_sent)
            return;
        _close_sent = true;
        ubyte[2] payload = [cast(ubyte)(code >> 8), cast(ubyte)(code & 0xFF)];
        send_control_frame(8, payload[]);
    }

    int handshake_response(ref const HTTPMessage response)
    {
        if (response.status_code != 101)
            return -1;

        auto expected = ws_accept_key(_handshake_key[]);
        if (response.header("Sec-WebSocket-Accept")[] != expected[])
            return -1;

        if (String proto = response.header("Sec-WebSocket-Protocol"))
            _protocol = proto.move;

        // bytes already read past the 101 response are the start of the first frame.
        if (_handshake_parser.current_leftover.length)
            _message = _handshake_parser.current_leftover[];

        return 1; // connection upgraded
    }
}

class WebSocketServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri));
nothrow @nogc:

    enum type_name = "ws-server";
    enum path = "/protocol/websocket/server";
    enum collection_id = CollectionType.ws_server;

    alias NewConnection = void delegate(WebSocket client, void* user_data) nothrow @nogc;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocketServer, id, flags);
    }

    // Properties...

    inout(HTTPServer) http_server() inout pure
        => _server;
    const(char)[] http_server(HTTPServer value)
    {
        _server = value;
        return null;
    }

    const(char)[] uri() const pure
        => _uri[];
    const(char)[] uri(const(char)[] value)
    {
        // TODO: property should just accept a String!
        _uri = value.makeString(defaultAllocator);
        return null;
    }

    // API...

    void set_connection_callback(NewConnection callback, void* user_data = null) pure
    {
        _connection_callback = callback;
        _user_data = user_data;
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _server !is null;

    override CompletionStatus startup()
    {
        if (_uri)
            _server.add_uri_handler(HTTPMethod.GET, uri, &handle_request);
        else
            _default_handler = _server.hook_global_handler(&handle_request);

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        // TODO: need to unlink these things...

        return CompletionStatus.complete;
    }

    override void update()
    {
    }

private:
    ObjectRef!HTTPServer _server;
    String _uri;

    NewConnection _connection_callback;
    void* _user_data;

    HTTPServer.RequestHandler _default_handler;
    int _num_connections;

    int handle_request(ref const HTTPMessage request, ref Stream stream, const(ubyte)[] leftover)
    {
        if (request.header("Upgrade") == "websocket")
        {
            version (DebugWebSocket)
                log.trace("upgrade request from ", stream.remote_name,
                          " uri=", request.url[], " version=", request.header("Sec-WebSocket-Version")[],
                          " protocol=", request.header("Sec-WebSocket-Protocol")[],
                          " extensions=", request.header("Sec-WebSocket-Extensions")[]);

            // validate version (just 13?)
            // else, reply "426 Upgrade Required" with header `Sec-WebSocket-Version` set to an accepted version

            // validate the resource name (path) or report "404 Not Found"

            // validate the connection is accepted, reply "403 Forbodden" if not
            //... `Origin` filtering?

            // check subprotocol from `Sec-WebSocket-Protocol`...?
            // if server accepts, must reply with acceptable `Sec-WebSocket-Protocol` header

            import urt.mem.allocator;
            import urt.mem.temp;
            const(char)[] n = tconcat(name, ++_num_connections);

            WebSocket ws = Collection!WebSocket().create(n, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
            ws._stream = stream;
            ws._is_server = true;
            // any bytes the HTTP parser read past the upgrade request are the start of
            // the first websocket frame; seed them into the rx buffer before the first read.
            if (leftover.length)
                ws._message = leftover[];
            stream = null;

            if (String proto = request.header("Sec-WebSocket-Protocol"))
                ws._protocol = proto.move;

            ubyte request_extensions;
            if (const(char)[] ext = request.header("Sec-WebSocket-Extensions")[])
            {
                each_ext: while (const(char)[] e = ext.split!';'.trim)
                {
                    foreach (i, extName; g_webSocketExtensions[1 .. $])
                    {
                        if (e[] == extName[])
                        {
                            request_extensions |=  cast(ubyte)(1 << i);
                            continue each_ext;
                        }
                    }
                    // unknown extension
                    assert(false, "What to do?!");
                }
            }
            // TODO: I think we're meant to reply with the extensions that we accepted?
//            ws._extensions = cast(WebSocketExtensions)request_extensions;

            auto accept = ws_accept_key(request.header("Sec-WebSocket-Key")[].trim);

            Array!char response;
            http_status_line(request.http_version, 101, "Switching Protocols", response);
            response ~= "Upgrade: websocket\r\n" ~
                        "Connection: Upgrade\r\n" ~
                        "Sec-WebSocket-Accept: ";
            response ~= accept[];
            response ~= "\r\n" ~
//                        "Sec-WebSocket-Protocol: chat, superchat\r\n" ~
                        "\r\n";
            ws._stream.write(response[]);

            version (DebugWebSocket)
                log.trace("handshake complete, created '", ws.name, "'", ws._protocol.length ? " protocol=" : "", ws._protocol[]);

            if (_connection_callback)
                _connection_callback(ws, _user_data);
            return 0;
        }

        if (_default_handler)
            return _default_handler(request, stream, leftover);
        return -1;
    }
}


private:

enum WSMessageType
{
    unknown,
    text,
    binary
}

enum WSAcceptKeyLen = base64_encode_length(20);
char[WSAcceptKeyLen] ws_accept_key(const(char)[] key)
{
    SHA1Context sha_state;
    sha_init(sha_state);
    sha_update(sha_state, key);
    sha_update(sha_state, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    auto digest = sha_finalise(sha_state);
    char[WSAcceptKeyLen] result = void;
    base64_encode(digest, result[]);
    return result;
}

__gshared immutable string[__traits(allMembers, WSExtensions).length] g_webSocketExtensions = [
    null,
    "permessage-deflate",
    "client_max_window_bits"
//    "server-push",
//    "client-push",
//    "channel-id",
//    "channel-id-client",
//    "channel-id-server",
//    "channel-id-client-server"
];
