module protocol.zigbee.coordinator;

import urt.lifetime;
import urt.string;

import router.iface;
import router.iface.packet;

nothrow @nogc:


class ZigbeeCoordinator
{
nothrow @nogc:

    String name;
    BaseInterface iface;

    this(String name, BaseInterface _interface) nothrow @nogc
    {
        this.name = name.move;
        this.iface = _interface;

        _interface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.Modbus));
    }

    void update()
    {
    }

private:
    void incomingPacket(ref const Packet p, BaseInterface iface, PacketDirection dir, void* userData) nothrow @nogc
    {
    }
}
