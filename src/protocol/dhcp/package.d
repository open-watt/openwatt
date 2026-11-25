module protocol.dhcp;

import manager;
import manager.collection;
import manager.console;
import manager.features : has_gateway, has_ipv6;
import manager.plugin;

import protocol.dhcp.client;
import protocol.dhcp.client6;
import protocol.dhcp.lease;
import protocol.dhcp.option;
import protocol.dhcp.server;

nothrow @nogc:


struct DHCPModule
{
    mixin DeclareStaticModule!"protocol.dhcp";
nothrow @nogc:

    static void init(void*)
    {
        g_app.register_enum!DHCPOptionType();

        g_app.console.register_collection!DHCPClient();
        version (UseInternalIPStack)
        static if (has_ipv6)
            g_app.console.register_collection!DHCP6Client();
        g_app.console.register_collection!DHCPOption();
        static if (has_gateway)
        {
            g_app.console.register_collection!DHCPLease();
            g_app.console.register_collection!DHCPServer();
        }
    }

    static void update(void*)
    {
        Collection!DHCPClient().update_all();
        version (UseInternalIPStack)
        static if (has_ipv6)
            Collection!DHCP6Client().update_all();
        static if (has_gateway)
            Collection!DHCPServer().update_all();
    }
}
