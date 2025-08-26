module router.iface.ethernet;

import urt.array;
import urt.log;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;


class EthernetInterface : BaseInterface
{
    __gshared Property[1] Properties = [ Property.create!("adapter", adapter)() ];
nothrow @nogc:

    alias TypeName = StringLit!"ether";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        this(collectionTypeInfo!EthernetInterface, name.move, flags);
    }

    // Properties...

    const(char)[] adapter() pure
        => null;
    void adapter(const(char)[] value)
    {
        assert(false);
    }

    // API...

    override bool validate() const
        => false;

    override CompletionStatus startup()
    {
        return CompletionStatus.Complete;
    }

    override void update()
    {
    }

    protected override bool transmit(ref const Packet packet)
    {
        send(packet);

        ++_status.sendPackets;
        _status.sendBytes += packet.data.length; // TODO: plus ethernet header...

        return true;
    }

protected:
    void incomingPacket(ref const Packet packet, BaseInterface srcInterface, PacketDirection dir, void* userData)
    {
//        // TODO: should we check and strip a vlan tag?
//        ushort srcVlan = 0;
//
//        if (!packet.src.isMulticast)
//            macTable.insert(packet.src, srcPort, srcVlan);
//
//        // we're the destination!
//        // we don't need to forward it, just deliver it to the upper layer...
//        dispatch(packet);
    }

    void send(ref const Packet packet) nothrow @nogc
    {
        assert(false, "TODO");
    }

private:
    this(const CollectionTypeInfo* typeInfo, String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(typeInfo, name.move, flags);

        // TODO: proper values?
//        _mtu = 1500;
//        _max_l2mtu = _mtu;
//        _l2mtu = 1500;
    }
}

class WiFiInterface : EthernetInterface
{
    __gshared Property[1] Properties = [ Property.create!("ssid", ssid)() ];
nothrow @nogc:

    alias TypeName = StringLit!"wifi";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!WiFiInterface, name.move, flags);
    }

    // Properties...

    const(char)[] ssid() pure
        => null;
    void ssid(const(char)[] value)
    {
        assert(false);
    }

protected:
    // TODO: wifi details...
    // ssid, signal details, security.
}


class EthernetInterfaceModule : Module
{
    mixin DeclareModule!"interface.ethernet";
nothrow @nogc:

    Collection!EthernetInterface ethernetInterfaces;
    Collection!WiFiInterface wifiInterfaces;

    override void init()
    {
        g_app.console.registerCollection("/interface/ethernet", ethernetInterfaces);
        g_app.console.registerCollection("/interface/wifi", wifiInterfaces);
    }
}
