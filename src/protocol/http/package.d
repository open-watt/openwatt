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
import protocol.http.tls;
import protocol.http.websocket;

import router.stream;
import router.stream.tcp;

nothrow @nogc:


Stream create_http_stream(const(char)[] stream_name, const(char)[] host_str, InetAddress remote, out const(char)[] resource)
{
    if (host_str.length)
    {
        const(char)[] host = host_str;
        const(char)[] protocol = "http";

        size_t prefix = host.findFirst(":");
        if (prefix != host.length)
        {
            protocol = host[0 .. prefix];
            host = host[prefix + 1 .. $];
        }
        if (host.startsWith("//"))
            host = host[2 .. $];

        size_t res_offset = host.findFirst("/");
        if (res_offset != host.length)
        {
            resource = host[res_offset .. $];
            host = host[0 .. res_offset];
        }

        ushort port;
        size_t colon = host.findFirst(":");
        if (colon != host.length)
        {
            size_t taken;
            long i = host[colon + 1 .. $].parse_int(&taken);
            if (i > ushort.max || taken != host.length - colon - 1)
                return null;
            port = cast(ushort)i;
        }

        bool plain = protocol.icmp("http") == 0 || protocol.icmp("ws") == 0;
        bool secure = protocol.icmp("https") == 0 || protocol.icmp("wss") == 0;

        if (plain)
        {
            if (port == 0)
                port = 80;
            return cast(Stream)Collection!TCPStream().create(stream_name, ObjectFlags.dynamic, NamedArgument("port", port), NamedArgument("remote", host));
        }
        if (secure)
        {
            import protocol.http.tls : TLSStream;
            if (port == 0)
                host = tconcat(host, ":443");
            return cast(Stream)Collection!TLSStream().create(stream_name, ObjectFlags.dynamic, NamedArgument("remote", host));
        }
        return null;
    }

    if (remote != InetAddress())
    {
        InetAddress addr = remote;
        if (addr.family == AddressFamily.ipv6 && addr._a.ipv6.port == 0)
            addr._a.ipv6.port = 80;
        else if (addr.family == AddressFamily.ipv4 && addr._a.ipv4.port == 0)
            addr._a.ipv4.port = 80;
        return cast(Stream)Collection!TCPStream().create(stream_name, ObjectFlags.dynamic, NamedArgument("remote", addr));
    }

    return null;
}

const(char)[] http_host_header(const(char)[] url) pure
{
    const(char)[] h = url;
    size_t colon = h.findFirst(":");
    if (colon != h.length)
        h = h[colon + 1 .. $];
    if (h.startsWith("//"))
        h = h[2 .. $];
    size_t slash = h.findFirst("/");
    if (slash != h.length)
        h = h[0 .. slash];
    return h;
}


class HTTPModule : Module
{
    mixin DeclareModule!"http";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!TLSStream();
        g_app.console.register_collection!TLSServer();
        g_app.console.register_collection!HTTPClient();
        g_app.console.register_collection!HTTPServer();
        g_app.console.register_collection!WebSocketServer();
        g_app.console.register_collection!WebSocket();

        g_app.console.register_command!request("/protocol/http", this);
        g_app.console.register_command!device_add("/protocol/http/device", this, "add");
    }

    override void update()
    {
        Collection!TLSServer().update_all();
        Collection!HTTPServer().update_all();
        Collection!HTTPClient().update_all();
        Collection!WebSocketServer().update_all();
    }

    void device_add(Session session, const(char)[] id, HTTPClient client, const(char)[] profile, Nullable!(const(char)[]) name, Nullable!(const(char)[]) model, const(NamedArgument)[] named_args)
    {
        import manager;
        import manager.device;
        import manager.element;
        import manager.profile;
        import urt.file;
        import urt.mem.temp;

        void[] file = load_file(tconcat("conf/rest_profiles/", profile, ".conf"), g_app.allocator);
        if (!file)
        {
            session.write_line("Failed to load profile '", profile, "'");
            return;
        }
        scope(exit) g_app.allocator.free(file);

        Profile* p = parse_profile(cast(char[])file, g_app.allocator);
        if (!p)
        {
            session.write_line("Failed to parse profile '", profile, "'");
            return;
        }

        // Resolve profile parameters from named args
        const(char)[][32] names = void, values = void;
        auto profile_params = p.get_parameters;
        if (profile_params.length > names.length)
        {
            session.write_line("Too many parameters for profile '", profile, "'");
            g_app.allocator.freeT(p);
            return;
        }

        size_t n;
        outer: foreach (ref param; profile_params)
        {
            names[n] = param;
            foreach (ref arg; named_args)
            {
                if (arg.name == param)
                {
                    values[n++] = arg.value.asString();
                    continue outer;
                }
            }
            session.write_line("Missing required parameter '", param, "' for profile '", profile, "'");
            g_app.allocator.freeT(p);
            return;
        }

        HTTPSampler sampler = g_app.allocator.allocT!HTTPSampler(client, p);

        Device device = create_device_from_profile(*p, model ? model.value : null, id, name ? name.value : null, (Device device, Element* e, ref const ElementDesc desc, ubyte) {
            if (desc.type != ElementType.http)
                return;
            ref const ElementDesc_HTTP http = p.get_http(desc.element);
            sampler.add_element(e, desc, http, names[0 .. n], values[0 .. n]);
        });

        if (!device)
        {
            session.write_line("Failed to create device '", id, "'");
            g_app.allocator.freeT(sampler);
            g_app.allocator.freeT(p);
            return;
        }

        device.samplers ~= sampler;
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
