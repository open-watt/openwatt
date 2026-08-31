module protocol.dhcp;

import manager;
import manager.collection;
import manager.console;
import manager.features : has_gateway;
import manager.plugin;

import protocol.dhcp.client;
import protocol.dhcp.lease;
import protocol.dhcp.option;
import protocol.dhcp.server;

nothrow @nogc:


class DHCPModule : Module
{
    mixin DeclareModule!"protocol.dhcp";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!DHCPOptionType();

        g_app.console.register_collection!DHCPClient();
        g_app.console.register_collection!DHCPOption();
        static if (has_gateway)
        {
            g_app.console.register_collection!DHCPLease();
            g_app.console.register_collection!DHCPServer();
        }
    }

    override void update()
    {
        Collection!DHCPClient().update_all();
        static if (has_gateway)
            Collection!DHCPServer().update_all();
    }
}
