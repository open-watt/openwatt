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
import protocol.http.binding;
import protocol.http.server;
import protocol.http.websocket;

import router.stream;
import protocol.ip.tcp_stream;
import protocol.tls;

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

bool http_request(const(char)[] url,
                  HTTPMessageHandler on_response,
                  HTTPMethod method = HTTPMethod.GET,
                  const(void)[] content = null,
                  HTTPParam[] headers = null,
                  String username = null,
                  String password = null,
                  HTTPFlags flags = HTTPFlags.None)
{
    if (on_response is null)
        return false;

    HttpUrl parsed = decompose_http_url(url);
    if (parsed.host.empty)
        return false;

    const(char)[] scheme = parsed.scheme.empty ? "http" : parsed.scheme;
    if (scheme.icmp("http") != 0 && scheme.icmp("https") != 0)
        return false;

    HTTPOneShot one = defaultAllocator.allocT!HTTPOneShot();
    one.user_handler = on_response;
    one.method = method;
    one.path = (parsed.path.empty ? "/" : parsed.path).makeString(defaultAllocator);
    if (content.length > 0)
        one.content ~= cast(const(ubyte)[])content;
    one.username = username.move;
    one.password = password.move;
    one.flags = flags;

    // copy caller's headers and force Connection: close so the client's temporary
    // flag tears the connection down after exactly one response.
    foreach (ref h; headers)
    {
        if (h.key[].icmp("Connection") == 0)
            continue;
        one.headers ~= HTTPParam(h.key, h.value);
    }
    one.headers ~= HTTPParam(StringLit!"Connection", StringLit!"close");

    String remote_str = tconcat(scheme, "://", parsed.host).makeString(defaultAllocator);
    const(char)[] client_name = Collection!HTTPClient().generate_name("http-req");
    HTTPClient c = Collection!HTTPClient().create(client_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("remote", remote_str));
    if (!c)
    {
        defaultAllocator.freeT(one);
        return false;
    }

    one.client = c;
    c.subscribe(&one.on_state);

    // HACK: create() advances the state machine one tick. The client is usually still
    // `starting` (waiting on TCP connect) at this point, but cover the case where
    // it became running synchronously.
    // TODO: clean this up when we stop this terrible eager update policy!
    if (c.running)
        one.on_state(c, StateSignal.online);

    return true;
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

        this(Session session)
        {
            super(session, null);
        }

        override CommandCompletionState update()
            => state;

        override void request_cancel()
        {
            // TODO: thread cancellation through to http_request's HTTPOneShot
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

    HTTPRequestState request(Session session, const(char)[] url, HTTPMethod method = HTTPMethod.GET)
    {
        HTTPRequestState state = g_app.allocator.allocT!HTTPRequestState(session);
        if (!http_request(url, &state.response_handler, method))
        {
            session.writef("HTTP request setup failed for '{0}'", url);
            g_app.allocator.freeT(state);
            return null;
        }
        return state;
    }
}


private:

class HTTPOneShot
{
nothrow @nogc:

    HTTPClient client;
    HTTPMessageHandler user_handler;

    HTTPMethod method;
    String path;
    Array!ubyte content;
    Array!HTTPParam headers;
    String username;
    String password;
    HTTPFlags flags;

    bool submitted;
    bool fired;

    void on_state(ActiveObject, StateSignal sig)
    {
        final switch (sig)
        {
            case StateSignal.online:
                if (submitted)
                    return;
                submitted = true;
                HTTPMessage* req = client.request(method, path[], &on_response, content[], null, headers[], username.move, password.move);
                if (req !is null)
                    req.flags = flags;
                else
                {
                    fire_failure();
                    HTTPClient c = client;
                    c.destroy();
                }
                break;

            case StateSignal.offline:
                break;

            case StateSignal.destroyed:
                client.unsubscribe(&on_state);
                fire_failure();
                defaultAllocator.freeT(this);
                break;
        }
    }

    int on_response(ref const HTTPMessage response)
    {
        fire(response);
        if (response.status_code == 0)
        {
            // failure path (timeout); the success path triggers teardown via
            // the Connection: close header + temporary flag
            HTTPClient c = client;
            c.destroy();
        }
        return 0;
    }

    void fire(ref const HTTPMessage response)
    {
        if (fired || user_handler is null)
            return;
        fired = true;
        user_handler(response);
    }

    void fire_failure()
    {
        if (fired)
            return;
        HTTPMessage empty;
        fire(empty);
    }
}
