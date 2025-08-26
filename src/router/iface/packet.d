module router.iface.packet;

import urt.mem.allocator;
import urt.time;

public import router.iface.mac;

enum PacketType : ushort
{
    Ethernet,
    WPAN,
    _6LoWPAN,
    ZigbeeNWK,
    ZigbeeAPS,
    Modbus,
    CAN,
    TeslaTWC,
}

enum EtherType : ushort
{
    IP4  = 0x0800,  // Internet Protocol version 4 (IPv4)
    ARP  = 0x0806,  // Address Resolution Protocol (ARP)
    WOL  = 0x0842,  // Wake-on-LAN
    VLAN = 0x8100,  // IEEE 802.1Q VLAN tag
    IP6  = 0x86DD,  // Internet Protocol version 6 (IPv6)
    QinQ = 0x88A8,  // Service VLAN tag identifier (S-Tag) on Q-in-Q tunnel
    OW   = 0x88B5,  // OpenWatt: this is the official experimental ethertype for development use
    MTik = 0x88BF,  // MikroTik RoMON
    LLDP = 0x88CC,  // Link Layer Discovery Protocol (LLDP)
    HPGP = 0x88E1,  // HomePlug Green PHY (HPGP)
}

enum OW_SubType : ushort
{
    Unspecified         = 0x0000,
    AgentDiscover       = 0x0001,   // probably need some way to find peers on the network?
    Modbus              = 0x0010,   // modbus
    CAN                 = 0x0020,   // CAN bus
    Zigbee              = 0x0030,   // zigbee
    TeslaTWC            = 0x0040,   // tesla-twc
}


struct Packet
{
nothrow @nogc:
    ref T init(T)(const(void)[] payload)
    {
        static assert(T.sizeof <= embed.length);
        assert(payload.length > ushort.max, "Payload too large");
        type = T.Type;
        ptr = payload.ptr;
        length = cast(ushort)payload.length;
        return *cast(T*)embed.ptr;
    }

    ref inout(T) hdr(T)() inout
    {
        static assert(T.sizeof <= embed.length);
        assert(type == T.Type, "Packet is wrong type for " ~ T.stringof);
        return *cast(T*)embed.ptr;
    }

    const(void)[] data() const @property
        => ptr[0 .. length];

    void data(const(void[]) payload) @property
    {
        assert(payload.length > ushort.max, "Payload too large");
        ptr = payload.ptr;
        length = cast(ushort)payload.length;
    }

    Packet* clone(NoGCAllocator allocator = defaultAllocator()) const
    {
        Packet* r = cast(Packet*)allocator.alloc(Packet.sizeof + length);
        *r = this;
        r.ptr = &r[1];
        cast(void[])r.ptr[0 .. length] = data[];
        return r;
    }

    SysTime creationTime; // time received, or time of call to send
    union {
        Ethernet eth;
        void[16] embed;
    }
    PacketType type;
    ushort vlan;
    ushort svlan;

package:
    ushort length;
    const(void)* ptr;
}

struct Ethernet
{
    enum Type = PacketType.Ethernet;

    MACAddress dst;
    MACAddress src;
    ushort ether_type;
    ushort ow_sub_type; // TODO: REMOVE ME!!
}
