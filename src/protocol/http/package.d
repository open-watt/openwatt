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
import protocol.http.message;

import router.stream.tcp;

nothrow @nogc:


class HTTPModule : Module
{
    mixin DeclareModule!"http";
nothrow @nogc:

    Collection!HTTPServer servers;
    Collection!HTTPClient clients;

    override void init()
    {
        g_app.console.registerCollection("/protocol/http/client", clients);
        g_app.console.registerCollection("/protocol/http/server", servers);
        g_app.console.registerCommand!request("/protocol/http", this);
    }

    override void update()
    {
        servers.updateAll();
        clients.updateAll();
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

        int response_handler(ref const HTTPMessage response)
        {
            if (response.status_code == 0)
            {
                session.writef("HTTP request failed!");
                state = CommandCompletionState.Error;
                return -1;
            }

            session.writef("HTTP response: {0}\n{1}", response.status_code, cast(const char[])response.content[]);
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
        c.request(method, uri, &state.response_handler);
        return state;
    }
}
