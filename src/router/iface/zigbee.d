module router.iface.zigbee;

import urt.lifetime;
import urt.meta.nullable;
import urt.string;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;

import protocol.ezsp;
import protocol.ezsp.client;

import router.iface;
import router.iface.mac;
import router.iface.packet;


class ZigbeeInterface : BaseInterface
{
nothrow @nogc:

    alias TypeName = StringLit!"zigbee";

    EUI64 eui;

    this(String name, ObjectFlags flags = ObjectFlags.None) nothrow @nogc
    {
        super(collectionTypeInfo!ZigbeeInterface, name.move, flags);
    }

    override void update()
    {
    }

    protected override bool transmit(ref const Packet packet) nothrow @nogc
    {
        // can only handle zigbee packets
        if (packet.etherType != EtherType.OW || packet.etherSubType != OW_SubType.Zigbee || packet.data.length < 3)
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

    Collection!ZigbeeInterface zigbee_interfaces;

    override void init()
    {
        g_app.console.registerCollection("/interface/zigbee", zigbee_interfaces);
    }
}


private:
