module router.iface.packet;

import urt.mem.allocator;
import urt.time;

public import router.iface.mac;


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
    WPAN                = 0x0050,   // 802.15.4 MAC layer (WPAN)
}


struct Packet
{
nothrow @nogc:
    this(const(void)[] data)
    {
        assert(data.length <= ushort.max);
        ptr = data.ptr;
        length = cast(ushort)data.length;
    }

    const(void)[] data() const @property
        => ptr[0 .. length];

    void data(const(void[]) payload) @property
    {
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
    MACAddress src;
    MACAddress dst;
    uint vlan;
    ushort etherType;
    ushort etherSubType;

package:
    ushort length;
    const(void)* ptr;
}
