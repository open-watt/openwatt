module protocol.telnet;

import urt.lifetime;
import urt.map;
import urt.mem;
import urt.string;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;

import protocol.telnet.client;
import protocol.telnet.server;
import protocol.telnet.stream;

import router.iface;
import protocol.ip.tcp_stream;

nothrow @nogc:


class TelnetModule : Module
{
    mixin DeclareModule!"protocol.telnet";
nothrow @nogc:

    Map!(const(char)[], TelnetServer) servers;

    override void init()
    {
        g_app.register_enum!TelnetRole();

        g_app.console.register_collection!TelnetStream();
        g_app.console.register_command!(add_server, "add")("/protocol/telnet/server", this);
        g_app.console.register_command!telnet("/tools", this);
    }

    void add_server(Session session, const(char)[] name, ushort port)
    {
        auto mod_if = get_module!InterfaceModule;

//        BaseInterface i = mod_if.findInterface(_interface);
//        if(i is null)
//        {
//            session.write_line("Interface '", _interface, "' not found");
//            return;
//        }

        String n = name.make_string();

        TelnetServer server = alloc!TelnetServer(n.move, &g_app.console, null, port);
        servers[server.name[]] = server;
    }
}
