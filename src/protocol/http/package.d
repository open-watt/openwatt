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

import manager.collection;
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

    Collection!HTTPClient clients;
    Map!(const(char)[], HTTPServer) servers;

    override void init()
    {
        g_app.console.registerCollection("/protocol/http/client", clients);
        g_app.console.registerCommand!add_server("/protocol/http/server", this, "add");
        g_app.console.registerCommand!request("/protocol/http", this);
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

        clients.updateAll();
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
        HTTPClient c = clients.get(client);
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
