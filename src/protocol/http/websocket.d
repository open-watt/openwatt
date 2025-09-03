module protocol.http.websocket;

import urt.array;
import urt.digest.sha;
import urt.encoding;
import urt.endian;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.base;

import protocol.http;
import protocol.http.message;
import protocol.http.server;

import router.stream;

nothrow @nogc:


enum WebSocketExtensions : ubyte
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


class WebSocket : Stream
{
nothrow @nogc:

    enum TypeName = StringLit!"websocket";

    this(String name, ObjectFlags flags = ObjectFlags.None, StreamOptions options = StreamOptions.None)
    {
        super(collectionTypeInfo!WebSocket, name.move, flags, options);
    }

    // Properties...

    // API...

    override bool connect()
    {
        // TODO: websockets which are explicitly connected may support this, but websockets created by WebsocketServer can't connect()...
        return _stream.connect();
    }

    override void disconnect()
    {
        _stream.disconnect();
    }

    override const(char)[] remoteName()
        => _stream.remoteName(); // TODO: maybe we should report the value from the `Origin` header?

    final override void update()
    {
    }

    override ptrdiff_t read(void[] buffer)
    {
        ubyte[1024] tmp;
        size_t offset = 0;
        size_t read = 0;

        ptrdiff_t bytes = _stream.read(tmp[_tail.length .. $]);
        if (bytes <= 0)
            return bytes; // TODO: handle errors

        // prepend _tail...
        tmp[0 .. _tail.length] = _tail[];
        bytes += _tail.length;
        _tail.clear();

        ubyte[] msg = tmp[0 .. bytes];
        if (bytes < 2)
            goto stash_for_later;
        offset += 2;

        {
            bool fin = msg[0] >> 7; // FIN
            ubyte rsv = msg[0] >> 4; // RSV
            ubyte opcode = msg[0] & 0xF; // OPCODE
            bool mask = msg[1] >> 7; // MASK
            ulong payload_len = msg[1] & 0x7F;

            if (payload_len == 0xFE)
            {
                if (bytes < offset + 2)
                    goto stash_for_later;
                payload_len = msg[2 .. 4].bigEndianToNative!ushort;
                offset += 2;
            }
            else if (payload_len == 0xFF)
            {
                if (bytes < offset + 8)
                    goto stash_for_later;
                payload_len = msg[2 .. 10].bigEndianToNative!ulong;
                offset += 8;
            }

            if (mask)
            {
                if (bytes < offset + 4)
                    goto stash_for_later;
                ubyte[] maskKey = msg[offset .. offset + 4];
                offset += 4;
                for (size_t i = 0; i < payload_len; ++i)
                    msg[offset + i] ^= maskKey[i & 3];
            }

            switch (opcode)
            {
                case 0: // continuation frame
                    break;
                case 1: // text frame
                    break;
                case 2: // binary frame
                    break;
                case 8: // connection close
                    break;
                case 9: // ping
                    break;
                case 10: // pong
                    break;
                default:
                    assert(false, "TODO: handle unknown opcode");
                    // TODO: should we terminate the stream, or try and re-sync?
            }

//            buffer
        }
        return read;

    stash_for_later:
        _tail = msg[offset .. $];
        return read;
    }

    override ptrdiff_t write(const void[] data)
    {
        assert(false, "TODO");

        return _stream.write(data);
    }

    override ptrdiff_t pending()
        => _stream.pending();

    override ptrdiff_t flush()
        => _stream.flush();

private:
    Stream _stream;
    WebSocketExtensions _extensions;
    String _protocol;
    Array!ubyte _tail;
}

class WebSocketServer : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("http-server", http_server)(),
                                         Property.create!("uri", uri)() ];
nothrow @nogc:

    alias TypeName = StringLit!"websocket-server";

    alias NewConnection = void delegate(WebSocket client, void* user_data) nothrow @nogc;

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!WebSocketServer, name.move, flags);
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
        => _uri;
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
            if (HTTPServer s = getModule!HTTPModule.servers.get(_server.name))
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

        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        // TODO: need to unlink these things...

        return CompletionStatus.Complete;
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

            WebSocket ws = getModule!HTTPModule.websockets.create(n.move, cast(ObjectFlags)(ObjectFlags.Dynamic | ObjectFlags.Temporary));
            ws._stream = stream;
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
            stream.write(response);

            _connection_callback(ws, _user_data);
            return 0;
        }

        if (_default_handler)
            return _default_handler(request, stream);
        return -1;
    }
}


private:

__gshared immutable string[__traits(allMembers, WebSocketExtensions).length] g_webSocketExtensions = [
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
