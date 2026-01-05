module protocol.http.websocket;

import urt.array;
import urt.digest.sha;
import urt.encoding;
import urt.endian;
import urt.lifetime;
import urt.mem : memmove;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.base;

import protocol.http;
import protocol.http.message;
import protocol.http.server;

import router.stream;

nothrow @nogc:


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

enum WSMessageType
{
    unknown,
    text,
    binary
}

alias WSMessageHandler = void delegate(const(ubyte)[] message, WSMessageType message_type) nothrow @nogc;

class WebSocket : BaseObject
{
nothrow @nogc:

    alias TypeName = StringLit!"websocket";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocket, name.move, flags);
    }

    // Properties...

    // API...

    ptrdiff_t send_text(const(char)[] text)
    {
        // TODO: confirm valid utf8, fail if not
        return send(text, WSMessageType.text);
    }

    ptrdiff_t send_binary(const(void)[] data)
    {
        return send(data, WSMessageType.binary);
    }

    final override void update()
    {
        // how much stack space can we spare for buffering?
        // this should always be high on the callstack...
        ubyte[16] tmp = void; // TODO: increase this buffer len; it's really short to test the various overflow paths...
        ubyte[] buf = _message.empty ? tmp[] : _message[];
        size_t read = _message.empty ? 0 : _message.length;
        size_t frame_start = _decoded_bytes;

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

            // fail-over to an allocated buffer if necessary
            size_t available = _stream.pending();
            if (available == 0)
                break; // nothing more to read
            if (available > buf.length - read)
            {
                _message.resize(read + available);
                if (buf.ptr is tmp.ptr)
                    _message[0 .. read] = tmp[0 .. read]; // HACK: why the extra brackets?
                buf = _message[];
            }

            ptrdiff_t r = _stream.read(buf[read .. read + available]);
            if (r < 0)
            {
                assert(false, "TODO: handle errors?");
                return;
            }
            assert(r == available);
            read += r;

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
                        // TODO: better error handling maybe?
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

                // check if we have a full-frame
                size_t msg_len = offset + payload_len;
                if (read > frame_start + msg_len)
                    break;

                switch (opcode)
                {
                    case 0: // continuation frame
                        if (_pending_message_type == WSMessageType.unknown)
                            restart(); // we can't have a continuation frame without a prior frame
                        break;

                    case 1: // text frame
                    case 2: // binary frame
                        if (_pending_message_type != WSMessageType.unknown)
                            restart(); // must be the first frame in a series
                        _pending_message_type = opcode == 1 ? WSMessageType.text : WSMessageType.binary;
                        break;

                    case 9: // ping
                        ubyte[2] pong = [0x80 | 10, 0]; // FIN + pong opcode, no payload
                        if (_stream.write(pong) != pong.sizeof)
                        {
                            // TODO: some kind of error?
                            debug assert(false, "TODO: test this case?");
                        }
                        break;

                    case 10: // pong
                        // TODO: record ping time...
                        break;

                    case 8: // connection close
                    default:
                        // "If an unknown opcode is received, the receiving endpoint MUST _Fail the WebSocket Connection_"
                        restart();
                        return;
                }

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
                        _msg_handler(msg[offset .. msg_len], _pending_message_type);
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
                    _msg_handler(buf[0 .. _decoded_bytes], _pending_message_type);
                    _pending_message_type = WSMessageType.unknown;
                    _decoded_bytes = 0;
                }
            }
        }

        // stash any remaining bytes...
        _message.resize(read);
        if (read > 0 && buf.ptr is tmp.ptr)
        {
            assert(frame_start == _decoded_bytes); // the code above should have shuffled tail bytes back to start
            _message[] = tmp[0 .. read];
        }
    }

private:
    Stream _stream;
    WSExtensions _extensions;
    String _protocol;
    bool _is_server;

    WSMessageHandler _msg_handler;

    Array!ubyte _message;
    size_t _decoded_bytes; // _message begins with decoded bytes, and the tail is pending bytes from incomplete transmission
    WSMessageType _pending_message_type;

    ptrdiff_t send(const(void)[] data, WSMessageType type)
    {
        ubyte[16] header; // max header size
        size_t header_len = 2;
        header[0] = 0x80 | (type == WSMessageType.text ? 1 : 2); // FIN + opcode
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

        if (!_is_server)
        {
            ubyte[4] mask_key = 0;

            // TODO: generate a mask (0 mask will work without xor below for now)
//            import urt.rand;
//            *cast(uint*)mask_key.ptr = rand();

            header[header_len .. header_len + 4][0..4] = mask_key[];
            header_len += 4;
        }

        // write the header
        if (_stream.write(header[0 .. header_len]) != header_len)
        {
            // TODO: some kind of error?
            restart();
            return -1;
        }

        size_t written = 0;
        while (written < data.length)
        {
            // TODO: we need to xor with the mask key...
            //       which is 0, so we're good for now!

            ptrdiff_t r = _stream.write(data[written .. $]);
            if (r < 0)
            {
                // TODO: some kind of error?
                restart();
                return -1;
            }
            written += r;
        }
        return written;
    }
}

class WebSocketServer : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("http-server", http_server)(),
                                         Property.create!("uri", uri)() ];
nothrow @nogc:

    alias TypeName = StringLit!"websocket-server";

    alias NewConnection = void delegate(WebSocket client, void* user_data) nothrow @nogc;

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!WebSocketServer, name.move, flags);
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

    override bool validate() const pure
        => _server !is null;

    override CompletionStatus validating()
    {
        // TODO: change to try_reattach()
        if (_server.detached)
        {
            if (HTTPServer s = get_module!HTTPModule.servers.get(_server.name))
                _server = s;
        }
        return super.validating();
    }

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

    int handle_request(ref const HTTPMessage request, ref Stream stream)
    {
        if (request.header("Upgrade") == "websocket")
        {
            // validate version (just 13?)
            // else, reply "426 Upgrade Required" with header `Sec-WebSocket-Version` set to an accepted version

            // validate the resource name (path) or report "404 Not Found"

            // validate the connection is accepted, reply "403 Forbodden" if not
            //... `Origin` filtering?

            // check subprotocol from `Sec-WebSocket-Protocol`...?
            // if server accepts, must reply with acceptable `Sec-WebSocket-Protocol` header

            import urt.mem.allocator;
            import urt.mem.temp;
            String n = tconcat(name, ++_num_connections).makeString(defaultAllocator);

            WebSocket ws = get_module!HTTPModule.websockets.create(n.move, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
            ws._stream = stream;
            ws._is_server = true;
            stream = null; // TODO: better strategy to notify the caller that we claimed the stream!?

            if (const(char)[] proto = request.header("Sec-WebSocket-Protocol"))
                ws._protocol = proto.makeString(defaultAllocator);

            ubyte request_extensions;
            if (const(char)[] ext = request.header("Sec-WebSocket-Extensions"))
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

            // we must generate the accept key...
            // this is literally the STUPIDEST spec i've ever read in all my years!!
            SHA1Context sha_state;
            sha_init(sha_state);
            sha_update(sha_state, request.header("Sec-WebSocket-Key").trim); // hash the challenge
            sha_update(sha_state, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");   // and this ridiculous magic string!
            auto digest = sha_finalise(sha_state);
            enum EncodeLen = base64_encode_length(digest.length);

            // complete the handshake...
            MutableString!0 response;
            http_status_line(request.http_version, 101, "Switching Protocols", response);
            response ~= "Upgrade: websocket\r\n" ~
                        "Connection: Upgrade\r\n" ~
                        "Sec-WebSocket-Accept: ";
            base64_encode(digest, response.extend(EncodeLen));
            response ~= "\r\n" ~
//                        "Sec-WebSocket-Protocol: chat, superchat\r\n" ~
                        "\r\n";
            ws._stream.write(response);

            if (_connection_callback)
                _connection_callback(ws, _user_data);
            return 0;
        }

        if (_default_handler)
            return _default_handler(request, stream);
        return -1;
    }
}


private:

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
