module protocol.http.server;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;
import urt.string.format : tconcat, tstring;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.http;
import protocol.http.message;

import router.stream.tcp;
import router.iface;

nothrow @nogc:


class HTTPServer : BaseObject
{
    __gshared Property[1] Properties = [ Property.create!("port", port)() ];
nothrow @nogc:

    alias TypeName = StringLit!"http-server";

    alias RequestHandler = int delegate(ref const HTTPMessage, ref Stream stream) nothrow @nogc;

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!HTTPServer, name.move, flags);
    }

    // Properties...

    ushort port() const pure
        => _port;
    const(char)[] port(ushort value)
    {
        if (_port == value)
            return null;
        if (value == 0)
            return "port must be non-zero";
        _port = value;

        if (_server)
            _server.port = _port;
        return null;
    }

    // API...

    void set_default_request_handler(RequestHandler default_request_handler)
    {
        _default_request_handler = default_request_handler;
    }

    bool add_uri_handler(HTTPMethod method, const(char)[] uri_prefix, RequestHandler request_handler)
    {
        foreach (ref h; _handlers)
        {
            // if a higher level handler already exists, we can't add this handler
            if (h.method == method && uri_prefix.startsWith(h.uri_prefix))
                return false;
        }

        _handlers ~= Handler(method, uri_prefix.makeString(defaultAllocator), request_handler);
        return true;
    }

    RequestHandler hook_global_handler(RequestHandler request_handler)
    {
        RequestHandler old = _default_request_handler;
        _default_request_handler = request_handler;
        return old;
    }

    override CompletionStatus startup()
    {
        const(char)[] server_name = getModule!TCPStreamModule.tcp_servers.generateName(name);
        _server = getModule!TCPStreamModule.tcp_servers.create(server_name.makeString(defaultAllocator), ObjectFlags.Dynamic, NamedArgument("port", _port));
        if (!_server)
            return CompletionStatus.Error;

        _server.setConnectionCallback(&accept_connection, null);

        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        if (_server)
            _server.destroy();

        return CompletionStatus.Complete;
    }

    override void update()
    {
        for (size_t i = 0; i < _sessions.length; )
        {
            int result = _sessions[i].update();
            if (result != 0)
            {
                defaultAllocator().freeT(_sessions[i]);
                _sessions.remove(i);
            }
            else
                ++i;
        }
    }

private:
    struct Handler
    {
        HTTPMethod method;
        String uri_prefix;
        RequestHandler request_handler;
    }

    ushort _port = 80;
    RequestHandler _default_request_handler;

    TCPServer _server;
    Array!Handler _handlers;
    Array!(Session*) _sessions;

    void accept_connection(TCPStream stream, void*)
    {
        _sessions.emplaceBack(defaultAllocator().allocT!Session(this, stream));
    }

    struct Session
    {
    nothrow @nogc:

        this(HTTPServer server, Stream stream)
        {
            this.server = server;
            this.stream = stream;
            parser = HTTPParser(&request_callback);
        }

        int update()
        {
            if (!stream)
                return -1;
            int result = parser.update(stream);
            if (result != 0)
            {
                stream.destroy();
                return result;
            }

            return 0;
        }

        int request_callback(ref const HTTPMessage request)
        {
            foreach (ref h; server._handlers)
            {
                if (request.method == h.method && request.request_target.startsWith(h.uri_prefix))
                    return h.request_handler(request, stream);
            }

            if (server._default_request_handler)
                return server._default_request_handler(request, stream);

            // implement default response...
            enum message_body = "OpenWatt Webserver";

            MutableString!0 response;
            http_status_line(request.http_version, request.status_code == 0 ? 200 : request.status_code, "", response);
            http_date(getDateTime(), response);

            http_field_lines([ HTTPParam(StringLit!"Content-Type", StringLit!"text/plain"),
                             HTTPParam(StringLit!"Content-Length", makeString(tstring(message_body.length), defaultAllocator())) ], response);

            response ~= "\r\n";
            response ~= message_body;

            stream.write(response);
            return 0;
        }

        HTTPServer server;
        ObjectRef!Stream stream;

    private:
        HTTPParser parser;
    }
}
