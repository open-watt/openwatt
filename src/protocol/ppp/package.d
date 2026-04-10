module protocol.ppp;

import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;

import protocol.ppp.server;
import protocol.ppp.client;

import router.iface;
import router.stream;

nothrow @nogc:


enum TunnelProtocol
{
    PPP,
    SLIP,
    PPPoE,
    PPPoA,
}

enum PPPProtocol
{
    LCP = 0xC021, // Link Control Protocol
    BCP = 0xC029, // Bridge Control Protocol
    IPCP = 0x8021, // Internet Protocol Control Protocol
    IPv6CP = 0x8057, // Internet Protocol version 6 Control Protocol
    IPv4 = 0x0021, // Internet Protocol version 4
    IPv6 = 0x0057, // Internet Protocol version 6
    CCP = 0x80FD, // Compression Control Protocol
    PAP = 0xC023, // Password Authentication Protocol
    CHAP = 0xC223, // Challenge Handshake Authentication Protocol
    EAP = 0xC227, // Extensible Authentication Protocol
}


class PPPModule : Module
{
    mixin DeclareModule!"protocol.ppp";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!TunnelProtocol();

        g_app.console.register_collection!PPPClient("/protocol/ppp/client");
        g_app.console.register_collection!PPPoEClient("/protocol/pppoe/client");
        g_app.console.register_collection!PPPServer("/protocol/ppp/server");
        g_app.console.register_collection!PPPoEServer("/protocol/pppoe/server");
    }

    override void update()
    {
        Collection!PPPServer().update_all();
        Collection!PPPoEServer().update_all();
    }
}
