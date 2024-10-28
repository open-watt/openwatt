module router.iface.zigbee;

import urt.lifetime;
import urt.string;

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


    this(InterfaceModule.Instance m, String name) nothrow @nogc
    {
        super(m, name.move, StringLit!"zigbee");
    }

    override void update()
    {
    }

    override bool forward(ref const Packet packet) nothrow @nogc
    {
        // can only handle zigbee packets
        if (packet.etherType != EtherType.ENMS || packet.etherSubType != ENMS_SubType.Zigbee || packet.data.length < 3)
        {
            ++status.sendDropped;
            return false;
        }

        return false;
    }

private:

}


class ZigbeeInterfaceModule : Plugin
{
    mixin RegisterModule!"interface.zigbee";

    class Instance : Plugin.Instance
    {
        mixin DeclareInstance;
    nothrow @nogc:

        override void init()
        {
            app.console.registerCommand!add("/interface/zigbee", this);
        }

        import urt.meta.nullable;

        // /interface/zigbee/add command
        // TODO: protocol enum!
        void add(Session session, const(char)[] name, const(char)[] ezsp_client)
        {
            // TODO: EZSP might not be the only hardware interface...
            assert(ezsp_client, "'ezsp_client' must be specified");

            EZSPClient c = app.moduleInstance!EZSPProtocolModule.getClient(ezsp_client);
            if (!c)
            {
                session.writeLine("EZSP client does not exist: ", ezsp_client);
                return;
            }

            auto mod_if = app.moduleInstance!InterfaceModule;

            if (name.empty)
                name = mod_if.generateInterfaceName("zigbee");
            String n = name.makeString(app.allocator);

            ZigbeeInterface iface = app.allocator.allocT!ZigbeeInterface(mod_if, n.move);
            mod_if.addInterface(iface);

            import urt.log;
            writeInfo("Create zigbee interface '", name, "' - ", iface.mac);
        }

    }
}


private:
