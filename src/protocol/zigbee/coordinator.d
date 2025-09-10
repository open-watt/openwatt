module protocol.zigbee.coordinator;

import urt.lifetime;
import urt.string;

import manager.base;

import router.iface;
import router.iface.packet;

nothrow @nogc:


class ZigbeeCoordinator : BaseObject
{
    __gshared Property[1] Properties = [ Property.create!("interface", iface)() ];
nothrow @nogc:

    alias TypeName = StringLit!"zigbee-coordinator";

    this(String name, ObjectFlags flags = ObjectFlags.None) nothrow @nogc
    {
        super(collection_type_info!ZigbeeCoordinator, name.move, flags);
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
