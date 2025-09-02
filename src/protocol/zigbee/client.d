module protocol.zigbee.client;

import urt.lifetime;
import urt.string;

import manager.base;

import router.iface;
import router.iface.packet;

nothrow @nogc:


class ZigbeeClient : BaseObject
{
    __gshared Property[1] Properties = [ Property.create!("interface", iface)() ];
nothrow @nogc:

    alias TypeName = StringLit!"zigbee-client";

    this(String name, ObjectFlags flags = ObjectFlags.None) nothrow @nogc
    {
        super(collectionTypeInfo!ZigbeeClient, name.move, flags);
    }

    // Properties...

    inout(BaseInterface) iface() inout
        => _interface;
    void iface(BaseInterface value)
    {
        if (_interface)
            _interface.unsubscribe(&incomingPacket);
        _interface = value;
        if (_interface)
            _interface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.OW, owSubType: OW_SubType.ZigbeeAPS));
    }


    // API...

    final override bool validate() const pure
    {
        return _interface !is null;
    }

private:
    BaseInterface _interface;

    void incomingPacket(ref const Packet p, BaseInterface iface, PacketDirection dir, void* userData) nothrow @nogc
    {
    }
}
