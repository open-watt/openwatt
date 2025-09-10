module protocol.telnet;

import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.console.session;
import manager.plugin;

import protocol.telnet.server;

import router.iface;
import router.stream.tcp;

nothrow @nogc:


class TelnetModule : Module
{
    mixin DeclareModule!"protocol.telnet";
nothrow @nogc:

    Map!(const(char)[], TelnetServer) servers;

    override void init()
    {
        g_app.console.registerCommand!add_server("/protocol/telnet/server", this, "add");

        // create telnet server
    }

    override void update()
    {
        foreach (server; servers.values)
            server.update();

//        for (auto i = servers.begin; i != servers.end; ++i)
//            (*i).update();
    }

    void add_server(Session session, const(char)[] name, ushort port)
    {
        auto mod_if = get_module!InterfaceModule;

//        BaseInterface i = mod_if.findInterface(_interface);
//        if(i is null)
//        {
//            session.writeLine("Interface '", _interface, "' not found");
//            return;
//        }

        String n = name.makeString(defaultAllocator());

        TelnetServer server = defaultAllocator().allocT!TelnetServer(defaultAllocator(), n.move, &g_app.console, null, port);
        servers[server.name[]] = server;
    }
}
