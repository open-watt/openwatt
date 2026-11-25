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


struct TelnetModule
{
    mixin DeclareStaticModule!"protocol.telnet";
    static __gshared TelnetModule module_state;
nothrow @nogc:

    void init()
    {
        g_app.register_enum!TelnetRole();

        g_app.console.register_collection!TelnetStream();
        g_app.console.register_collection!TelnetServer();
        g_app.console.register_command!telnet("/tools", &this);
    }
}
