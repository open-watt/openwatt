module protocol.http;

import urt.array;
import urt.conv;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.string;
import urt.string.format : tstring;
import urt.time;

import manager.console;
import manager.plugin;

import protocol.http.client;
import protocol.http.server;
import protocol.http.message;

import router.stream.tcp;

version = DebugHTTPMessageFlow;

nothrow @nogc:


class HTTPModule : Module
{
    mixin DeclareModule!"http";
nothrow @nogc:

    Map!(const(char)[], HTTPClient) clients;
    Map!(const(char)[], HTTPServer) servers;

    override void init()
    {
        g_app.console.registerCommand!add_server("/protocol/http/server", this, "add");
        g_app.console.registerCommand!add_client("/protocol/http/client", this, "add");
        g_app.console.registerCommand!request("/protocol/http", this);
    }

    HTTPClient createClient(String name, const(char)[] server)
    {
        const(char)[] protocol = "http";

        size_t prefix = server.findFirst(":");
        if (prefix != server.length)
        {
            protocol = server[0 .. prefix];
            server = server[prefix + 1 .. $];
        }
        if (server.startsWith("//"))
            server = server[2 .. $];

        const(char)[] resource;
        size_t resOffset = server.findFirst("/");
        if (resOffset != server.length)
        {
            resource = server[resOffset .. $];
            server = server[0 .. resOffset];
        }

        // TODO: I don't think we need a resource when connecting?
        //       maybe we should keep it and make all requests relative to this resource?

        Stream stream = null;
        if (protocol.icmp("http") == 0)
        {
            ushort port = 80;

            // see if server has a port...
            size_t colon = server.findFirst(":");
            if (colon != server.length)
            {
                const(char)[] portStr = server[colon + 1 .. $];
                server = server[0 .. colon];

                size_t taken;
                long i = portStr.parseInt(&taken);
                if (i > ushort.max || taken != portStr.length)
                    return null; // invalid port string!
            }

            stream = g_app.allocator.allocT!TCPStream(name, server, port, StreamOptions.OnDemand);
            getModule!StreamModule.streams.add(stream);
        }
        else if (protocol.icmp("https") == 0)
        {
            assert(false, "TODO: need TLS stream");
//                stream = g_app.allocator.allocT!SSLStream(name, server, ushort(0));
//                getModule!StreamModule.addStream(stream);
        }
        if (!stream)
        {
            assert(false, "error strategy... just write log output?");
            return null;
        }

        HTTPClient http = g_app.allocator.allocT!HTTPClient(name.move, stream, server.makeString(g_app.allocator));
        clients.insert(http.name[], http);
        return http;
    }

    HTTPClient createClient(String name, InetAddress address)
    {
        char[47] tmp = void;
        address.toString(tmp, null, null);
        String host = tmp.makeString(g_app.allocator);

        // TODO: guess http/https from the port maybe?
        Stream stream = g_app.allocator.allocT!TCPStream(name, address, StreamOptions.OnDemand);
        getModule!StreamModule.streams.add(stream);

        HTTPClient http = g_app.allocator.allocT!HTTPClient(name.move, stream, host.move);
        clients.insert(http.name[], http);
        return http;
    }

    HTTPClient createClient(String name, Stream stream)
    {
        String host;

        assert(false, "TODO: get host from stream");

        HTTPClient http = g_app.allocator.allocT!HTTPClient(name.move, stream, host.move);
        clients.insert(http.name[], http);
        return http;
    }

    HTTPServer createServer(const(char)[] name, ushort port, HTTPServer.RequestHandler handler)
    {
        HTTPServer server = defaultAllocator().allocT!HTTPServer(name.makeString(defaultAllocator()), null, port, handler);
        servers[server.name[]] = server;

        return server;
    }

    override void update()
    {
        foreach (server; servers.values)
            server.update();

        foreach (client; clients.values)
            client.update();
    }

    void add_server(Session session, const(char)[] name, ushort port)
    {
        createServer(name, port, (request, stream) {
            MutableString!0 response;

            const string messageBody = "enermon Webserver";

            httpStatusLine(request.httpVersion, request.statusCode == 0 ? 200 : request.statusCode, "", response);
            httpDate(getDateTime(), response);

            httpFieldLines([ HTTPParam(StringLit!"Content-Type", StringLit!"text/plain"),
                             HTTPParam(StringLit!"Content-Length", makeString(tstring(messageBody.length), defaultAllocator())) ], response);

            response ~= "\r\n";
            response ~= messageBody;
            stream.write(response);

            return 0;
        });

        writeInfof("Create HTTP server '{0}' on port {1}", name, port);
    }

    void add_client(Session session, const(char)[] name, const(char)[] host)
    {
        if (!createClient(name.makeString(defaultAllocator), host))
        {
            // TODO: so bad!
        }

        writeInfof("Create HTTP client '{0}' to host {1}", name, host);
    }

    static class HTTPRequestState : FunctionCommandState
    {
    nothrow @nogc:
        HTTPClient client;

        this(Session session)
        {
            super(session);
        }

        ~this()
        {
            if (client)
            {
                // TODO: destroy the client...
                assert(false);
            }
        }

        override CommandCompletionState update()
        {
            // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...

            return state;
        }

        int responseHandler(ref const HTTPMessage response)
        {
            if (response.statusCode == 0)
            {
                session.writef("HTTP request failed!");
                state = CommandCompletionState.Error;
                return -1;
            }

            session.writef("HTTP response: {0}\n{1}", response.statusCode, cast(const char[])response.content[]);
            state = CommandCompletionState.Finished;
            return 0;
        }
    }

    HTTPRequestState request(Session session, const(char)[] client, const(char)[] uri = "/", HTTPMethod method = HTTPMethod.GET)
    {
        HTTPClient* c = client in clients;
        if (!c)
        {
            session.writef("No HTTP client: '{0}'", client);
            return null;
        }

        HTTPRequestState state = g_app.allocator.allocT!HTTPRequestState(session);
        c.request(method, uri, &state.responseHandler);
        return state;
    }
}
