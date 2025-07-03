module router.iface.zigbee;

import urt.lifetime;
import urt.meta.nullable;
import urt.string;

import manager;
import manager.plugin;
import manager.console.session;

import protocol.ezsp;
import protocol.ezsp.client;

import router.iface;
import router.iface.mac;
import router.iface.packet;


class ZigbeeInterface : BaseInterface
{
nothrow @nogc:

    alias TypeName = StringLit!"zigbee";

    ubyte[8] eui;

    this(String name) nothrow @nogc
    {
        super(name.move, TypeName);
    }

    override void update()
    {
    }

    protected override bool transmit(ref const Packet packet) nothrow @nogc
    {
        // can only handle zigbee packets
        if (packet.etherType != EtherType.ENMS || packet.etherSubType != ENMS_SubType.Zigbee || packet.data.length < 3)
        {
            ++_status.sendDropped;
            return false;
        }

        return false;
    }

private:

}


class ZigbeeInterfaceModule : Module
{
    mixin DeclareModule!"interface.zigbee";
nothrow @nogc:

    override void init()
    {
        g_app.console.registerCommand!add("/interface/zigbee", this);
    }

    // /interface/zigbee/add command
    // TODO: protocol enum!
    void add(Session session, const(char)[] name, const(char)[] ezsp_client, Nullable!(const(char)[]) pcap)
    {
        // TODO: EZSP might not be the only hardware interface...
        assert(ezsp_client, "'ezsp_client' must be specified");

        EZSPClient c = getModule!EZSPProtocolModule.clients.get(ezsp_client);
        if (!c)
        {
            session.writeLine("EZSP client does not exist: ", ezsp_client);
            return;
        }

        auto mod_if = getModule!InterfaceModule;
        String n = mod_if.addInterfaceName(session, name, ZigbeeInterface.TypeName);
        if (!n)
            return;

        ZigbeeInterface iface = g_app.allocator.allocT!ZigbeeInterface(n.move);

        mod_if.addInterface(session, iface, pcap ? pcap.value : null);
    }
}


private:
