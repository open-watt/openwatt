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
import urt.string.format : tstring;
import urt.time;

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
        g_app.console.register_command!device_add("/protocol/http/device", this, "add");
    }

    override void pre_update()
    {
        websockets.update_all();
    }

    override void update()
    {
        tls_streams.update_all();
        tls_servers.update_all();
        servers.update_all();
        clients.update_all();
        ws_servers.update_all();
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
