module router.iface.wpan;

import urt.lifetime;
import urt.meta.nullable;
import urt.string;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;

import router.iface;
import router.iface.mac;
import router.iface.packet;
import router.stream;


class WPANInterface : BaseInterface
{
    __gshared Property[1] Properties = [ Property.create!("eui", _eui)() ];
nothrow @nogc:

    alias TypeName = StringLit!"wpan";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!WPANInterface, name.move, flags);

        // generate the eui
        _eui = mac.makeEui64();

        // add the missing bytes...
        import urt.crc;
        alias ccitt = calculate_crc!(Algorithm.crc16_ccitt);
        uint crc = ccitt(name);
        _eui.b[3] = cast(ubyte)(crc >> 8);
        _eui.b[4] = crc & 0xFF;

        // TODO: proper values?
//        _mtu = 128;
//        _max_l2mtu = _mtu;
//        _l2mtu = 128;
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

    protected override bool transmit(ref const Packet packet) nothrow @nogc
    {
        // can only handle zigbee packets
        if (packet.etherType != EtherType.OW || packet.etherSubType != OW_SubType.WPAN || packet.data.length < 3)
        {
            ++_status.sendDropped;
            return false;
        }

        return false;
    }

private:
    EUI64 _eui;

    union {
        // raw radio device...?
        Stream _serialBridge;
    }

    ubyte maxMacFrameRetries = 3;

    void delegate(uint messageId, bool success) nothrow @nogc transmitCompletionCallback;
}


class WPANInterfaceModule : Module
{
    mixin DeclareModule!"interface.wpan";
nothrow @nogc:

    Collection!WPANInterface wpanInterfaces;

    override void init()
    {
        g_app.console.registerCollection("/interface/wpan", wpanInterfaces);
    }
}


private:
