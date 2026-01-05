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
import protocol.http.message;
import protocol.http.server;
import protocol.http.tls;
import protocol.http.websocket;

import router.stream.tcp;

nothrow @nogc:


class HTTPModule : Module
{
    mixin DeclareModule!"http";
nothrow @nogc:

    Collection!TLSStream tls_streams;
    Collection!TLSServer tls_servers;
    Collection!HTTPServer servers;
    Collection!HTTPClient clients;
    Collection!WebSocketServer ws_servers;
    Collection!WebSocket websockets;

    override void init()
    {
        g_app.console.register_collection("/stream/tls", tls_streams);
        g_app.console.register_collection("/protocol/tls/server", tls_servers);
        g_app.console.register_collection("/protocol/http/client", clients);
        g_app.console.register_collection("/protocol/http/server", servers);
        g_app.console.register_collection("/protocol/websocket/server", ws_servers);
        g_app.console.register_collection("/protocol/websocket", websockets);

        g_app.console.register_command!request("/protocol/http", this);
    }

    override void pre_update()
    {
        websockets.update_all();
    }

    override void update()
    {
        tls_streams.update_all();
        servers.update_all();
        clients.update_all();
        ws_servers.update_all();
    }

    static class HTTPRequestState : FunctionCommandState
    {
    nothrow @nogc:

        CommandCompletionState state = CommandCompletionState.in_progress;

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

        int response_handler(ref const HTTPMessage response)
        {
            if (response.status_code == 0)
            {
                session.writef("HTTP request failed!");
                state = CommandCompletionState.error;
                return -1;
            }

            session.writef("HTTP response: {0}\n{1}", response.status_code, cast(const char[])response.content[]);
            state = CommandCompletionState.finished;
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
        c.request(method, uri, &state.response_handler);
        return state;
    }
}
