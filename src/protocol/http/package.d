module protocol.http;

import urt.array;
import urt.conv;
import urt.inet;
import urt.lifetime;
import urt.map;
import urt.meta.nullable;
import urt.string;

import manager.console;
import manager.plugin;

import protocol.http.client;

import router.stream.tcp;

nothrow @nogc:


class HTTPModule : Module
{
    mixin DeclareModule!"http";
nothrow @nogc:

    Map!(const(char)[], HTTPClient) clients;

    override void init()
    {
        app.console.registerCommand!client_add("/protocol/http/client", this, "add");
        app.console.registerCommand!request_get("/protocol/http/client/request", this, "get");
        app.console.registerCommand!request_post("/protocol/http/client/request", this, "post");

        app.console.registerCommand!device_add("/protocol/http/device", this, "add");

        // TODO: maybe we should make a command which can make a request without a client?
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

            stream = app.allocator.allocT!TCPStream(name, server, port, StreamOptions.OnDemand);
            app.moduleInstance!StreamModule.addStream(stream);
        }
        else if (protocol.icmp("https") == 0)
        {
            assert(false, "TODO: need TLS stream");
//                stream = app.allocator.allocT!SSLStream(name, server, ushort(0));
//                app.moduleInstance!StreamModule.addStream(stream);
        }
        if (!stream)
        {
            assert(false, "error strategy... just write log output?");
            return null;
        }

        HTTPClient http = app.allocator.allocT!HTTPClient(name.move, stream, server.makeString(app.allocator));
        clients.insert(http.name[], http);
        return http;
    }

    HTTPClient createClient(String name, InetAddress address)
    {
        char[47] tmp = void;
        address.toString(tmp, null, null);
        String host = tmp.makeString(app.allocator);

        // TODO: guess http/https from the port maybe?
        Stream stream = app.allocator.allocT!TCPStream(name, address, StreamOptions.OnDemand);
        app.moduleInstance!StreamModule.addStream(stream);

        HTTPClient http = app.allocator.allocT!HTTPClient(name.move, stream, host.move);
        clients.insert(http.name[], http);
        return http;
    }

    HTTPClient createClient(String name, Stream stream)
    {
        String host;

        assert(false, "TODO: get host from stream");

        HTTPClient http = app.allocator.allocT!HTTPClient(name.move, stream, host.move);
        clients.insert(http.name[], http);
        return http;
    }

    override void update()
    {
        foreach (client; clients)
        {
            client.update();
        }
    }

    void client_add(Session session, const(char)[] name, const(char)[] url, Nullable!ushort port, Nullable!ushort username, Nullable!ushort password)
    {

        // TODO: generate name if not supplied
        String n = name.makeString(app.allocator);

        HTTPClient client = createClient(n.move, url);
        clients[client.name[]] = client;
    }

    void device_add(Session session, const(char)[] id, Nullable!(const(char)[]) name, Nullable!(const(char)[]) _profile)
    {
        if (id in app.devices)
        {
            session.writeLine("Device '", id, "' already exists");
            return;
        }

        if (!_profile)
        {
            session.writeLine("No profile specified");
            return;
        }
        const(char)[] profileName = _profile.value;
/+
        import manager.component;
        import manager.device;
        import manager.element;
        import manager.value;
        import router.modbus.profile;
        import urt.file;
        import urt.string.format;

        void[] file = load_file(tconcat("conf/http_profiles/", profileName, ".conf"), app.allocator);
        HTTPProfile* profile = parseHttpProfile(cast(char[])file, app.allocator);

        // create the device
        Device device = app.allocator.allocT!Device(id.makeString(app.allocator));
        if (name)
            device.name = name.value.makeString(app.allocator);

        // create a sampler for each distinct connection...
        // TODO...

        // create a sampler for this modbus server...
        HTTPSampler sampler = app.allocator.allocT!HTTPSampler(client, target);
        device.samplers ~= sampler;

        Component createComponent(ref ComponentTemplate ct)
        {
            Component c = app.allocator.allocT!Component(ct.id.move);
            c.template_ = ct.template_.move;

            foreach (ref child; ct.components)
            {
                Component childComponent = createComponent(child);
                c.components ~= childComponent;
            }

            foreach (ref el; ct.elements)
            {
                Element* e = app.allocator.allocT!Element();
                e.id = el.id.move;

                if (el.value.length > 0)
                {
                    final switch (el.type)
                    {
                        case ElementTemplate.Type.Constant:
                            e.latest.fromString(el.value);
                            break;

                        case ElementTemplate.Type.Map:
                            const(char)[] mapReg = el.value.unQuote;
                            ModbusRegInfo** pReg;
                            if (mapReg.length >= 2 && mapReg[0] == '@')
                                pReg = mapReg[1..$] in profile.regByName;
                            if (!pReg)
                            {
                                session.writeLine("Invalid register specified for element-map '", e.id, "': ", mapReg);
                                app.allocator.freeT(e);
                                continue;
                            }

                            // HACK HACK HACK: this is all one huge gross HACK!
                            __gshared immutable Value.Type[RecordType.str] typeMap = [
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Float,
                                Value.Type.Float,
                                Value.Type.Float,
                                Value.Type.Float,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Integer,
                                Value.Type.Float,
                            ];

                            e.unit = (*pReg).units.makeString(app.allocator);
                            e.type = (*pReg).type < RecordType.str ? typeMap[(*pReg).type] : Value.Type.String;
                            e.arrayLen = 0; // TODO: handle arrays?
                            e.access = cast(manager.element.Access)(*pReg).access; // HACK: delete the rh type!

                            // TODO: if values are bitfields or enums, we should record the keys...

                            // record samper data...
                            sampler.addElement(e, **pReg);
                            device.sampleElements ~= e; // TODO: remove this?
                            break;
                    }
                }

                c.elements ~= e;
            }

            return c;
        }

        // create a bunch of components from the profile template
        foreach (ref ct; profile.componentTemplates)
        {
            Component c = createComponent(ct);
            device.components ~= c;
        }

        app.devices.insert(device.id, device);

        // clean up...
        app.allocator.freeT(profile);
        app.allocator.free(file);
+/
    }

    RequestState request_get(Session session, const(char)[] client, Nullable!(const(char)[]) resource, Nullable!(const(char)[]) content)//, Nullable!(HTTPParam[]) params)
    {
        return request(session, HTTPMethod.GET, client, resource, content);
    }

    RequestState request_post(Session session, const(char)[] client, Nullable!(const(char)[]) resource, Nullable!(const(char)[]) content)//, Nullable!(HTTPParam[]) params)
    {
        return request(session, HTTPMethod.POST, client, resource, content);
    }

    RequestState request(Session session, HTTPMethod method, const(char)[] client, Nullable!(const(char)[]) resource, Nullable!(const(char)[]) content)//, Nullable!(HTTPParam[]) params)
    {
        HTTPClient* c = client in clients;
        if (!c)
        {
            session.writeLine("No HTTP client: '", client, "'");
            return null;
        }

        RequestState state = app.allocator.allocT!RequestState(session);
        c.request(method, resource ? resource.value : null, &state.responseHandler);
        return state;
    }
}

class RequestState : FunctionCommandState
{
    nothrow @nogc:

    this(Session session)
    {
        super(session);
    }

    override CommandCompletionState update()
    {
        // TODO: how to handle request cancellation? if we bail, then the client will try and call a dead delegate...

        return state;
    }

    void responseHandler(ref HTTPResponse response) nothrow @nogc
    {
//        session.writeLine("Response from ", slave[], " in ", (responseTime - requestTime).as!"msecs", "ms: ", toHexString(response.data[1..$], 2, 4, "_ "));
        state = CommandCompletionState.Finished;
    }
}

