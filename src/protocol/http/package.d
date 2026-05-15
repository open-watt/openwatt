module protocol.http;

import urt.array;
import urt.conv;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;
import urt.string.format : tconcat, tstring;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.expression : NamedArgument;
import manager.plugin;

import protocol.http.client;
import protocol.http.message;
import protocol.http.sampler;
import protocol.http.server;
import protocol.http.websocket;

import router.stream;
import router.stream.tcp;
import router.stream.tls;

nothrow @nogc:


struct HttpUrl
{
    const(char)[] scheme;
    const(char)[] host;
    const(char)[] path;
}

HttpUrl decompose_http_url(const(char)[] url) pure
{
    HttpUrl r;
    auto sep = url.findFirst("://");
    if (sep < url.length)
    {
        r.scheme = url[0 .. sep];
        url = url[sep + 3 .. $];
    }
    auto slash = url.findFirst('/');
    if (slash < url.length)
    {
        r.path = url[slash .. $];
        url = url[0 .. slash];
    }
    r.host = url;
    return r;
}


class HTTPModule : Module
{
    mixin DeclareModule!"http";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!HTTPClient();
        g_app.console.register_collection!HTTPServer();
        g_app.console.register_collection!WebSocketServer();
        g_app.console.register_collection!WebSocket();
        g_app.console.register_collection!HTTPClientBinding();

        g_app.console.register_command!request("/protocol/http", this);
    }

    override void update()
    {
        Collection!HTTPServer().update_all();
        Collection!HTTPClient().update_all();
        Collection!WebSocketServer().update_all();
    }

    static class HTTPRequestState : CommandState
    {
    nothrow @nogc:

        CommandCompletionState state = CommandCompletionState.in_progress;

        HTTPClient client;

        this(Session session)
        {
            super(session, null);
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

        override void request_cancel()
        {
            // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...
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
        HTTPClient c = Collection!HTTPClient().get(client);
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
