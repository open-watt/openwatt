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
        server = defaultAllocator().allocT!TCPServer(name.toString().makeString(defaultAllocator), port, &acceptConnection, null);
        this.name = name.move;
        this.requestHandler = requestHandler;
    }

    ~this()
    {
        defaultAllocator().freeT(server);
    }

    void update()
    {
        server.update();

        for (size_t i = 0; i < sessions.length; )
        {
            int result = sessions[i].update();
            if (result != 0)
            {
                defaultAllocator().freeT(sessions[i]);
                sessions.remove(i);
            }
            ++i;
        }
    }

package:
    TCPServer server;
    Array!(Session*) sessions;
    RequestHandler requestHandler;

    void acceptConnection(TCPStream stream, void* )
    {
        sessions.emplaceBack(defaultAllocator().allocT!Session(stream, requestHandler));
    }

private:
	struct Session
	{
    nothrow @nogc:

        this(Stream stream, RequestHandler requestHandler)
        {
            this.stream = stream;
            stream.setOpts(StreamOptions.NonBlocking);
            parser = HTTPParser(&requestCallback);
            this.requestHandler = requestHandler;
        }

        int update()
        {
            stream.update();

            int result = parser.update(stream);
            if (result != 0)
            {
                stream.disconnect();
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

        Stream stream;
        HTTPParser parser;
        RequestHandler requestHandler;
	}
}
