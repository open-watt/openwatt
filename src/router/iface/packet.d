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
    ENMS = 0x88B5,  // OUR PROGRAM: this is the official experimental ethertype for development use
    MTik = 0x88BF,  // MikroTik RoMON
    LLDP = 0x88CC,  // Link Layer Discovery Protocol (LLDP)
    HPGP = 0x88E1,  // HomePlug Green PHY (HPGP)
}

enum ENMS_SubType : ushort
{
    Unspecified         = 0x0000,
    AgentDiscover       = 0x0001,   // probably need some way to find peers on the network?
    Modbus              = 0x0010,   // modbus
    Zigbee              = 0x0020,   // zigbee
    TeslaTWC            = 0x0030,   // tesla-twc
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

    const(void)[] data() const
        => ptr[0 .. length];

    Packet* clone(NoGCAllocator allocator = defaultAllocator()) const
    {
        Packet* r = cast(Packet*)allocator.alloc(Packet.sizeof + length);
        *r = this;
        r.ptr = &r[1];
        cast(void[])r.ptr[0 .. length] = data[];
        return r;
    }

    MonoTime creationTime; // time received, or time of call to send
    MACAddress src;
    MACAddress dst;
    uint vlan;
    ushort etherType;
    ushort etherSubType;

package:
    ushort length;
    const(void)* ptr;
}


uint ethernetCRC(const(void)[] data) pure nothrow @nogc
{
    uint crc = 0;
    for (size_t n = 0; n < data.length; ++n)
    {
        crc = (crc >> 4) ^ crc_table[(crc ^ ((cast(ubyte*)data.ptr)[n] >> 0)) & 0x0F];  // lower nibble
        crc = (crc >> 4) ^ crc_table[(crc ^ ((cast(ubyte*)data.ptr)[n] >> 4)) & 0x0F];  // upper nibble
    }
    return crc;
}


private:

__gshared immutable uint[16] crc_table = [
    0x4DBDF21C, 0x500AE278, 0x76D3D2D4, 0x6B64C2B0,
    0x3B61B38C, 0x26D6A3E8, 0x000F9344, 0x1DB88320,
    0xA005713C, 0xBDB26158, 0x9B6B51F4, 0x86DC4190,
    0xD6D930AC, 0xCB6E20C8, 0xEDB71064, 0xF0000000
];
