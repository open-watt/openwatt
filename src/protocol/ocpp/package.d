module protocol.ocpp;

import urt.array;
import urt.log;
import urt.map;
import urt.string;

import manager.console;
import manager.plugin;

import protocol.http.server;
import protocol.http.websocket;

import router.stream;

version = DebugOCPPMessageFlow;

nothrow @nogc:


class OCPPModule : Module
{
    mixin DeclareModule!"ocpp";
nothrow @nogc:

    Map!(const(char)[], WebSocketServer) servers;
    Array!OCPPClient clients;

    override void init()
    {
        g_app.console.registerCommand!add_server("/protocol/ocpp/server", this, "add");
    }

    override void update()
    {
        foreach (ref c; clients)
            c.update();
    }

    void add_server(Session session, const(char)[] name, const(char)[] http_server, const(char)[] path)
    {
        import protocol.http;

        auto mod_http = getModule!HTTPModule();

        HTTPServer* s = http_server in mod_http.servers;
        if (!s)
        {
            session.write("No HTTP server '", http_server, "'!");
            return;
        }

        WebSocketServer wsServer = mod_http.createWebSocketServer(name.makeString(g_app.allocator), *s, path, &clientConnect, null);
        if (!wsServer)
        {
            session.write("Create OCPP server failed: can't create WebSocket server at ", path);
            return;
        }
        servers.insert(wsServer.name[], wsServer);

        writeInfof("Create OCPP server '{0}' on '{1}' at ''", name, http_server, path);
    }

    void clientConnect(WebSocket stream, void* userData)
    {
        // maybe we begin a welcome sequence?

        clients.emplaceBack(stream);
    }
}


struct OCPPClient
{
nothrow @nogc:
    Stream stream;

    this(WebSocket stream)
    {
        this.stream = stream;
    }

    void update()
    {
        if (!stream.connected)
        {
            // TODO: can we reconnect? or do we just clean up?
            assert(false);
        }

        ubyte[1024] buffer = void;

        while (true)
        {
            ptrdiff_t r = stream.read(buffer[]);
            if (r <= 0)
                break;

            // parse OCPP messages?
            //...
        }
    }
}
