module protocol.dns;

import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.dns;
import protocol.dns.mdns;

nothrow @nogc:


class DNSModule : Module
{
    mixin DeclareModule!"protocol.dns";
nothrow @nogc:

    Map!(const(char)[], mDNSServer) servers;

    override void init()
    {
        g_app.console.registerCommand!server_add("/protocol/mdns/server", this, "add");
    }

    override void update()
    {
        foreach(name, server; servers)
            server.update();
    }

    void server_add(Session session, const(char)[] name)//, const(char)[][] _interface)
    {
        // TODO: we probably want servers to only apply to select interfaces rather than all interfaces...
//            Array!BaseInterface interfaces;
//            foreach(i; 0 .. _interface.length)
//            {
//                BaseInterface iface = getModule!InterfaceModule.findInterface(_interface[i]);
//                if (!iface)
//                {
//                    session.writeLine("Interface does not exist: ", _interface[i]);
//                    return;
//                }
//                interfaces ~= iface;
//            }

        NoGCAllocator a = g_app.allocator;

        String n = name.makeString(a);
        mDNSServer server = a.allocT!mDNSServer(n.move);//, interfaces.move);
        servers.insert(server.name[], server);

        writeInfof("Create mDNS server '{0}'", name);
    }
}
