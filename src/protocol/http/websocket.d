module protocol.http.websocket;

import urt.array;
import urt.digest.sha;
import urt.encoding;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem : memmove;
import urt.mem;
import urt.mem.pagepool;
import urt.rand;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.http;
import protocol.http.message;
import protocol.http.server;
import protocol.ip.client : IPClient;

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


final class WebSocket : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("stream", stream));
nothrow @nogc:

    ~this() {}

    enum type_name = "websocket";
    enum path = "/interface/websocket";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocket, id, flags);
        _mtu = ushort.max;  // a message carries whatever a producer hands it
        _caps |= InterfaceCaps.reliable | InterfaceCaps.ordered;   // TCP-backed: consumers needn't supply either
        mark_set!(typeof(this), "caps")();
    }

    // Properties...

    const(char)[] remote() const
    {
        auto r = _conn.remote_name();
        return r.empty ? null : tconcat(_tls ? "wss://" : "ws://", r, _resource[]);
    }
    void remote(InetAddress value)
    {
        detach_stream();
        _conn.remote(value);
        _tls = false;
        _resource = String();
        _stream = null;
        mark_set!(typeof(this), [ "remote", "stream" ])();
        restart();
    }
    const(char)[] remote(String value)
    {
        auto url = decompose_http_url(value[]);
        bool tls;
        if (url.scheme.empty || url.scheme.icmp("ws") == 0 || url.scheme.icmp("http") == 0)
            tls = false;
        else if (url.scheme.icmp("wss") == 0 || url.scheme.icmp("https") == 0)
            tls = true;
        else
            return tconcat("unsupported scheme '", url.scheme, "' (expected ws or wss)");
        if (url.host.empty)
            return "host cannot be empty";

        auto r = _conn.remote(url.host.make_string());
        if (r.failed)
            return r.message;
        detach_stream();
        _tls = tls;
        _resource = url.path.make_string();
        _stream = null;
        mark_set!(typeof(this), [ "remote", "stream" ])();
        restart();
        return null;
    }

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream stream)
    {
        if (_stream is stream)
            return;
        detach_stream();
        _conn.clear_remote();
        _stream = stream;
        mark_set!(typeof(this), [ "stream", "remote" ])();
        restart();
    }

    // API...

protected:

    override bool validate() const pure
    {
        if (_is_server)
            return _stream !is null;
        // client: URL xor stream
        return _conn.has_remote() != !!_stream;
    }

    override CompletionStatus startup()
    {
        if (!_stream && _conn.has_remote())
        {
            ushort default_port = _tls ? 443 : 80;
            if (!_conn.start(this, default_port, _tls))
                return CompletionStatus.error;
            _stream = _conn.get;
        }
        if (!_stream)
            return CompletionStatus.error;

        if (!_stream.running)
            return CompletionStatus.continue_;
        if (_stream.rx_handler !is &stream_rx)
            _stream.rx_handler(&stream_rx);

        if (!_is_server && _handshake_parser is null && !_subscribed)
        {
            // Generate a 16-byte random nonce, base64-encoded, as the Sec-WebSocket-Key.
            align(4) ubyte[16] nonce = void;
            foreach (i; 0 .. 4)
                (cast(uint*)nonce.ptr)[i] = rand();
            char[base64_encode_length(16)] key_b64 = void;
            base64_encode(nonce[], key_b64[]);
            _handshake_key = key_b64[].make_string();

            HTTPMessage req;
            req.http_version = HTTPVersion.V1_1;
            req.method = HTTPMethod.GET;
            req.flags = HTTPFlags.NoDefaults;
            req.request_target = (_resource.empty ? "/" : _resource[]).make_string();
            req.headers ~= HTTPParam(StringLit!"User-Agent", StringLit!"OpenWatt");
            req.headers ~= HTTPParam(StringLit!"Upgrade", StringLit!"websocket");
            req.headers ~= HTTPParam(StringLit!"Connection", StringLit!"Upgrade");
            req.headers ~= HTTPParam(StringLit!"Sec-WebSocket-Key", _handshake_key);
            req.headers ~= HTTPParam(StringLit!"Sec-WebSocket-Version", StringLit!"13");

            Array!char msg = format_message_head(req, _conn.host[], false, 0);
            if (msg.empty || _stream.write(msg[]) != msg.length)
                return CompletionStatus.error;

            _handshake_parser = alloc!HTTPParser(&handshake_response);
        }

        if (_handshake_parser)
        {
            if (!_upgraded)
                return CompletionStatus.continue_;
            free(_handshake_parser);
            _handshake_parser = null;
            _handshake_key = String();
        }

        _stream.subscribe(&stream_state_change);
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override void online()
    {
        super.online();

        if (Stream s = _stream)
            set_link_speed(s.tx_link_speed, s.rx_link_speed);
        // bytes that arrived before the session ran: past the upgrade, or seeded by the server
        if (!_message.empty)
            parse_frames(getTime());
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
            send_close(1001); // going away
        detach_stream();
        if (_is_server && _stream && _stream.running)
            _stream.destroy();   // the per-connection socket serves only this session
        if (_handshake_parser)
        {
            free(_handshake_parser);
            _handshake_parser = null;
            _handshake_key = String();
        }
        _upgraded = false;
        if (!_is_server && _conn.has_remote())
        {
            _conn.stop();
            _stream = null;
        }
        _resource = String();
        _close_sent = false;
        _message.clear();
        _decoded_bytes = 0;
        _rx_overhead = 0;
        _pending_message_type = WSMessageType.unknown;
        free_tx_queue();
        return CompletionStatus.complete;
    }

    override int transmit(ref Packet packet, MessageCallback, const(QueuePolicy)*)
    {
        if (packet.type != PacketType.raw)
        {
            add_tx_drop();
            return -1;
        }

        ref hdr = packet.hdr!RawFrame();
        const(void)[] data = packet.data;

        // TODO: if hdr.is_text, confirm valid utf8 and fail if not

        ubyte[14] header; // max header size: 2 + 8 (ext-len) + 4 (mask)
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

        size_t frame_len = header_len + data.length;
        if (!admit_tx(frame_len))
            return -1;

        version (DebugWebSocket)
        {
            log.trace("send ", hdr.is_text ? "text" : "binary", " (", data.length, ")[ ",
                      cast(void[])data[0 .. data.length <= 200 ? data.length : 200], data.length > 200 ? ", ... ]" : " ]");
        }

        if (!queue_frame(header[0 .. header_len], cast(const(ubyte)[])data, _is_server ? null : mask_key[]))
            return -1;
        add_tx_frame(frame_len);
        arm_tx();
        return 0;
    }

    override void tx_handler_changed()
    {
        pull_tx();
    }

    override bool tx_ready() const
        => !_tx_waiter.queued && tx_queued < tx_low_water;

private:
    ObjectRef!Stream _stream;
    IPClient _conn;
    String _resource; // url path, or empty
    WSExtensions _extensions;
    String _protocol;
    bool _tls;
    bool _is_server;
    bool _subscribed;
    bool _close_sent;
    bool _tx_closing;
    bool _tx_pulling;
    bool _upgraded;

    HTTPParser* _handshake_parser; // non-null while client handshake is in flight
    String _handshake_key;

    Array!ubyte _message;
    size_t _decoded_bytes; // _message begins with decoded bytes, and the tail is pending bytes from incomplete transmission
    size_t _rx_overhead; // framing bytes for fragments buffered but not yet dispatched
    WSMessageType _pending_message_type;

    Page* _tx_queue;
    PageWaiter _tx_waiter;
    enum size_t max_tx_frame = 64 * 1024 + 14;                  // maximum sync payload plus WebSocket header
    enum size_t max_tx_pending = 128 * 1024;
    enum size_t tx_low_water = 16 * 1024;                       // reserve room for one maximum frame
    static assert(tx_low_water + max_tx_frame <= max_tx_pending, "the last frame admitted must fit");

    void stream_rx(Stream stream, const(void)[] data, MonoTime rx_time)
    {
        if (_handshake_parser && !_upgraded)
        {
            int r = _handshake_parser.feed(cast(const(ubyte)[])data, stream);
            if (r < 0)
                restart();
            else if (r > 0)
                _upgraded = true;
            return;
        }
        version (DebugWebSocket)
            log.trace("recv: (", data.length, ")[ ", data[0 .. data.length <= 200 ? data.length : 200], data.length > 200 ? ", ... ]" : " ]");
        _message ~= cast(const(ubyte)[])data;
        if (running)
            parse_frames(rx_time);
    }

    // _message holds the decoded bytes of a fragmented message, then the undecoded tail
    void parse_frames(MonoTime timestamp)
    {
        ubyte[] buf = _message[];
        size_t read = _message.length;
        size_t frame_start = _decoded_bytes;

        while (frame_start + 2 <= read)
        {
            ubyte[] msg = buf[frame_start .. read];

            ubyte opcode = msg[0] & 0xF; // OPCODE
            bool rsv3 = (msg[0] >> 4) & 1; // RSV3
            bool rsv2 = (msg[0] >> 5) & 1; // RSV2
            bool rsv1 = (msg[0] >> 6) & 1; // RSV1
            bool fin = msg[0] >> 7; // FIN
            bool mask = msg[1] >> 7; // MASK
            align(4) ubyte[4] mask_key;

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

                // the top bit must be clear (RFC 6455 5.2), and the length must fit this build's address space
                if ((len >> 63) || len > size_t.max)
                {
                    add_rx_drop();
                    restart();
                    return;
                }
                payload_len = cast(size_t)len;
            }

            // every header is judged before its payload is buffered: control frames are whole and at most 125 bytes
            // (RFC 6455 5.5), and an unknown opcode fails the connection
            if (opcode >= 8 ? opcode > 10 || !fin || payload_len > 125 : opcode > 2)
            {
                add_rx_drop();
                restart();
                return;
            }
            if (opcode <= 2 && payload_len > actual_mtu - _decoded_bytes)
            {
                add_rx_drop();
                send_close(1009);
                restart();
                return;
            }

            // if a mask was included
            if (mask)
            {
                if (msg.length < offset + 4)
                    break;
                mask_key = msg[offset .. offset + 4];
                offset += 4;
            }

            // incomplete frame: the tail waits in _message for the next chunk; compared by subtraction, so no sum can wrap
            if (payload_len > msg.length - offset)
                break;
            size_t msg_len = offset + payload_len;

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
                    assert(false, "unknown opcodes are refused with the header");
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
                    ref hdr = p.init!RawFrame(msg[offset .. msg_len], timestamp);
                    hdr.is_text = _pending_message_type == WSMessageType.text;
                    _status.rx_bytes += _rx_overhead; // incoming_packet() counts the payload; we add framing
                    _rx_overhead = 0;
                    incoming_packet(p);

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
                ref hdr = p.init!RawFrame(buf[0 .. _decoded_bytes], timestamp);
                hdr.is_text = _pending_message_type == WSMessageType.text;
                _status.rx_bytes += _rx_overhead;
                _rx_overhead = 0;
                incoming_packet(p);

                _pending_message_type = WSMessageType.unknown;
                _decoded_bytes = 0;
            }
        }

        if (frame_start > _decoded_bytes)
        {
            size_t tail = read - frame_start;
            memmove(buf.ptr + _decoded_bytes, buf.ptr + frame_start, tail);
            read = _decoded_bytes + tail;
        }
        _message.resize(read);
    }

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
            align(4) ubyte[4] mask = void;
            *cast(uint*)mask.ptr = rand();
            frame[len .. len + 4][0..4] = mask[];
            len += 4;
            foreach (i; 0 .. payload.length)
                frame[len + i] = cast(ubyte)(payload[i] ^ mask[i & 3]);
        }
        else
            frame[len .. len + payload.length] = payload[];
        len += payload.length;

        if (!admit_tx(len) || !queue_frame(frame[0 .. len], null, null))
            return;
        arm_tx();
    }

    // copies a frame into pages behind what is queued, masking the body with a client's key
    // a frame the pages cannot hold is refused whole, and the producer is invited back when pages are freed
    bool queue_frame(const(ubyte)[] header, const(ubyte)[] body, const(ubyte)[] mask)
    {
        uint generation = page_free_generation();
        Page* frame;
        size_t total = header.length + body.length;
        for (size_t at = 0; at < total; )
        {
            size_t n = total - at < max_tx_page ? total - at : max_tx_page;
            Page* page = page_alloc(n);
            if (!page)
            {
                free_chain(frame);
                add_tx_drop();
                _tx_waiter.wake = &pull_tx;
                page_wait(&_tx_waiter, generation);
                return false;
            }
            ubyte[] dst = cast(ubyte[])page.data;
            size_t h;
            if (at < header.length)
            {
                h = header.length - at < n ? header.length - at : n;
                dst[0 .. h] = header[at .. at + h];
            }
            size_t from = at + h - header.length;
            dst[h .. n] = body[from .. from + n - h];
            if (mask.length)
            {
                foreach (i; h .. n)
                    dst[i] ^= mask[(from + i - h) & 3];
            }
            append_tx_chain(frame, page);
            at += n;
        }
        append_tx_chain(_tx_queue, frame);
        return true;
    }

    size_t tx_queued() const
    {
        size_t bytes;
        for (const(Page)* page = _tx_queue; page; page = (cast(Page*)page).next)
            bytes += page.length;
        return bytes;
    }

    void free_tx_queue()
    {
        free_chain(_tx_queue);
        _tx_queue = null;
    }

    static void free_chain(Page* page)
    {
        while (page)
        {
            Page* next = page.next;
            page_free(page);
            page = next;
        }
    }

    // every callback and timer that references this object or the stream is released here
    void detach_stream()
    {
        g_app.cancel(&tx_overflow);
        page_unwait(&_tx_waiter);
        _tx_closing = false;
        if (_stream)
        {
            _stream.release_tx_handler(&produce_tx);
            _stream.release_rx_handler(&stream_rx);
        }
        if (_subscribed)
        {
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
    }

    // one bound for data and control frames alike
    bool admit_tx(size_t bytes)
    {
        if (tx_queued + bytes <= max_tx_pending)
            return true;
        add_tx_drop();
        close_tx();
        return false;
    }

    // a message that cannot be retained closes the link; deferred, the refusal is detected inside the sender's own call
    void close_tx()
    {
        if (_tx_closing)
            return;
        _tx_closing = true;
        g_app.schedule(getTime(), &tx_overflow);
    }

    void tx_overflow(MonoTime)
    {
        log.warning("tx overflow: ", tx_queued, " bytes pending; closing");
        restart();
    }

    void arm_tx()
    {
        if (_stream && _stream.tx_handler is null)
            _stream.tx_handler(&produce_tx);
    }

    void pull_tx()
    {
        if (_tx_pulling || _tx_closing)
            return;
        if (tx_ready)
        {
            _tx_pulling = true;
            invite_tx();
            _tx_pulling = false;
        }
        arm_tx();
    }

    Page* produce_tx(ref const TxRequest req, out TxStatus status)
    {
        pull_tx();
        if (!_tx_queue)
        {
            status = TxStatus.idle;
            return null;
        }
        return take_tx_page(_tx_queue, req, status);
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

final class WebSocketServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri));
nothrow @nogc:

    ~this() {}

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
        mark_set!(typeof(this), "http-server")();
        return null;
    }

    const(char)[] uri() const pure
        => _uri[];
    const(char)[] uri(const(char)[] value)
    {
        // TODO: property should just accept a String!
        _uri = value.make_string();
        mark_set!(typeof(this), "uri")();
        return null;
    }

    // API...

    void set_connection_callback(NewConnection callback, void* user_data = null) pure
    {
        _connection_callback = callback;
        _user_data = user_data;
    }

protected:

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
                log.trace("upgrade request on ", stream.name,
                          " uri=", request.request_target[], " version=", request.header("Sec-WebSocket-Version")[],
                          " protocol=", request.header("Sec-WebSocket-Protocol")[],
                          " extensions=", request.header("Sec-WebSocket-Extensions")[]);

            // validate version (just 13?)
            // else, reply "426 Upgrade Required" with header `Sec-WebSocket-Version` set to an accepted version

            // validate the resource name (path) or report "404 Not Found"

            // validate the connection is accepted, reply "403 Forbodden" if not
            //... `Origin` filtering?

            // check subprotocol from `Sec-WebSocket-Protocol`...?
            // if server accepts, must reply with acceptable `Sec-WebSocket-Protocol` header

            import urt.mem;
            import urt.mem.temp;
            const(char)[] n = tconcat(name, ++_num_connections);

            WebSocket ws = Collection!WebSocket().create(n, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
            ws._stream = stream;
            ws._is_server = true;
            // bytes past the upgrade request start the first frame; what follows buffers until the session runs
            if (leftover.length)
                ws._message = leftover[];
            stream.rx_handler(&ws.stream_rx);
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


unittest
{
    import urt.mem : alloc, free;

    WebSocket ws = alloc!WebSocket(CID(1));
    scope (exit) free(ws);

    // a header alone, declaring a 64-bit length: read as the parser would see it, with nothing behind
    ulong parse(ulong len, ubyte first = 0x82)
    {
        ws._message.clear();
        ws._decoded_bytes = 0;
        ubyte[14] frame = [first, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4];
        foreach (i; 0 .. 8)
            frame[2 + i] = cast(ubyte)(len >> (56 - 8 * i));
        ws._message ~= frame[];
        ulong dropped = ws.rx_dropped;
        ws.parse_frames(MonoTime());
        return ws.rx_dropped - dropped;
    }

    // the top bit set is invalid on every build
    assert(parse(ulong.max) == 1 && parse(1UL << 63) == 1);
    // a message past the advertised size is refused before its payload arrives; one within it waits for it
    assert(parse(0x7FFF_FFFF_FFFF_FFFF) == 1 && parse(uint.max) == 1 && parse(ws.actual_mtu + 1) == 1);
    assert(parse(ws.actual_mtu) == 0 && ws._message.length == 14);
    assert(parse(1) == 0 && ws._message.length == 14);
    // a control frame over 125 bytes, a fragmented one and an unknown opcode are refused with the header, before any payload
    assert(parse(126, 0x89) == 1 && parse(70_000, 0x88) == 1 && parse(70_000, 0x8A) == 1 && parse(5, 0x09) == 1);
    assert(parse(70_000, 0x83) == 1 && parse(70_000, 0x8B) == 1 && parse(1, 0x8F) == 1);
    assert(parse(125, 0x89) == 0 && ws._message.length == 14);
    ws._message.clear();

    // a frame larger than a page is queued across pages, and a client's body is masked in the copy
    {
        ubyte[4000] body = void;
        foreach (i, ref b; body)
            b = cast(ubyte)i;
        ubyte[2] header = [0x82, 0x7E];
        ubyte[4] mask = [0x11, 0x22, 0x33, 0x44];
        assert(ws.queue_frame(header[], body[], mask[]) && ws.tx_queued == header.length + body.length);
        assert(ws._tx_queue.length == max_tx_page && ws._tx_queue.next.next.next is null);
        size_t at;
        for (Page* page = ws._tx_queue; page; page = page.next)
        {
            foreach (b; cast(const(ubyte)[])page.data)
            {
                ubyte expect = at < header.length ? header[at] : cast(ubyte)(body[at - header.length] ^ mask[(at - header.length) & 3]);
                assert(b == expect);
                ++at;
            }
        }
        assert(at == header.length + body.length);
        ws.free_tx_queue();
        assert(ws.tx_queued == 0);
    }
}
