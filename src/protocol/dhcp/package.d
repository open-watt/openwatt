module protocol.dhcp;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.dhcp.client;
import protocol.dhcp.client6;
import protocol.dhcp.lease;
import protocol.dhcp.lease6;
import protocol.dhcp.option;
import protocol.dhcp.server;
import protocol.dhcp.server6;

nothrow @nogc:


class DHCPModule : Module
{
    mixin DeclareModule!"protocol.dhcp";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!DHCPOptionType();

        g_app.console.register_collection!DHCPClient();
        g_app.console.register_collection!DHCP6Client();
        g_app.console.register_collection!DHCPLease();
        g_app.console.register_collection!DHCP6Lease();
        g_app.console.register_collection!DHCPOption();
        g_app.console.register_collection!DHCPServer();
        g_app.console.register_collection!DHCP6Server();
    }

    override void update()
    {
        Collection!DHCPClient().update_all();
        Collection!DHCP6Client().update_all();
        Collection!DHCPServer().update_all();
        Collection!DHCP6Server().update_all();
    }
}
