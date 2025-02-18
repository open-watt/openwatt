module protocol.http;

import urt.array;
import urt.conv;
import urt.inet;
import urt.lifetime;
import urt.map;
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
}
