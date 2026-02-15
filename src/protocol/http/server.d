module protocol.http.server;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.log;
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

//version = DebugHTTPMessageFlow;

nothrow @nogc:


class HTTPServer : BaseObject
{
    __gshared Property[1] Properties = [ Property.create!("port", port)() ];
nothrow @nogc:

    enum type_name = "http-server";

    alias RequestHandler = int delegate(ref const HTTPMessage, ref Stream stream) nothrow @nogc;

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!HTTPServer, name.move, flags);
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
            if ((h.methods & (1 << method)) && uri_prefix[].startsWith(h.uri_prefix[]))
                return false;
        }

        _handlers ~= Handler(1 << method, uri_prefix.makeString(defaultAllocator), request_handler);
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
        const(char)[] server_name = get_module!TCPStreamModule.tcp_servers.generate_name(name[]);
        _server = get_module!TCPStreamModule.tcp_servers.create(server_name, ObjectFlags.dynamic, NamedArgument("port", _port));
        if (!_server)
            return CompletionStatus.error;

        _server.set_connection_callback(&accept_connection, null);

        writeInfo(type, ": '", name, "' listening on port ", _port, "...");

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        while (!_sessions.empty)
        {
            Session* s = _sessions.popBack();
            s.close();
            defaultAllocator().freeT(s);
        }

        if (_server)
        {
            _server.destroy();
            _server = null;
        }

        return CompletionStatus.complete;
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
        uint methods;
        String uri_prefix;
        RequestHandler request_handler;
    }

    ushort _port = 80;
    RequestHandler _default_request_handler;

    TCPServer _server;
    Array!Handler _handlers;
    Array!(Session*) _sessions;

    void accept_connection(Stream stream, void*)
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
            stream.subscribe(&signal_handler);
            parser = HTTPParser(&request_callback);
        }

        void close()
        {
            if (!stream)
                return;
            stream.destroy();
            stream = null;
        }

        int update()
        {
            if (!stream)
                return -1;
            if (int result = parser.update(stream))
            {
                close();
                return result;
            }
            return 0;
        }

        int request_callback(ref const HTTPMessage request)
        {
            foreach (ref h; server._handlers)
            {
                if (((1 << request.method) & h.methods) && request.request_target[].startsWith(h.uri_prefix[]))
                    return h.request_handler(request, stream);
            }

            if (server._default_request_handler)
                return server._default_request_handler(request, stream);

            // implement default response...
            enum message_body = "OpenWatt Webserver";
            HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"text/plain", message_body);
            stream.write(response.format_message()[]);

            return 0;
        }

        HTTPServer server;
        Stream stream;

    private:
        HTTPParser parser;

        void signal_handler(BaseObject object, StateSignal signal)
        {
            if (signal != StateSignal.online)
            {
                stream.unsubscribe(&signal_handler);
                stream = null;
            }
        }
    }
}
