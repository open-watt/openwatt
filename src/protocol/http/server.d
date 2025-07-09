module protocol.http.server;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import manager;
import manager.base;

import protocol.http;
import protocol.http.message;

import router.stream.tcp;
import router.iface;

nothrow @nogc:


class HTTPServer
{
nothrow @nogc:

    alias RequestHandler = int delegate(ref const HTTPMessage, Stream stream) nothrow @nogc;

    const String name;

    this(String name, BaseInterface , ushort port, RequestHandler requestHandler)
    {
        const(char)[] server_name = getModule!TCPStreamModule.tcp_servers.generateName(name);

        server = getModule!TCPStreamModule.tcp_servers.create(server_name.makeString(defaultAllocator), ObjectFlags.Dynamic);
        server.port = port;
        server.setConnectionCallback(&acceptConnection, null);

        this.name = name.move;
        this.requestHandler = requestHandler;
    }

    ~this()
    {
        server.destroy();
    }

    void update()
    {
        for (size_t i = 0; i < sessions.length; )
        {
            int result = sessions[i].update();
            if (result != 0)
            {
                defaultAllocator().freeT(sessions[i]);
                sessions.remove(i);
            }
            else
                ++i;
        }
    }

package:
    TCPServer server;
    Array!(Session*) sessions;
    RequestHandler requestHandler;

    void acceptConnection(TCPStream stream, void* )
    {
        sessions ~= defaultAllocator().allocT!Session(stream, requestHandler);
    }

private:
    struct Session
    {
    nothrow @nogc:

        this(Stream stream, RequestHandler requestHandler)
        {
            this.stream = stream;
            parser = HTTPParser(&requestCallback);
            this.requestHandler = requestHandler;
        }

        int update()
        {
            if (!stream)
                return -1;
            int result = parser.update(stream);
            if (result != 0)
            {
                stream.destroy();
                return result;
            }

            return 0;
        }

        int requestCallback(ref const HTTPMessage request)
        {
            HTTPMessage response;
            int result = requestHandler(request, stream);
            if (result != 0)
                return result;

            return 0;
        }

        ObjectRef!Stream stream;
        HTTPParser parser;
        RequestHandler requestHandler;
    }
}
