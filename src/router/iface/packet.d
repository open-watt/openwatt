module router.iface.packet;

import urt.mem.allocator;
import urt.time;

public import router.iface.mac;

enum PacketType : ushort
{
    Unknown,
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
    IP4     = 0x0800,   // Internet Protocol version 4 (IPv4)
    ARP     = 0x0806,   // Address Resolution Protocol (ARP)
    WOL     = 0x0842,   // Wake-on-LAN
    VLAN    = 0x8100,   // IEEE 802.1Q VLAN tag
    IP6     = 0x86DD,   // Internet Protocol version 6 (IPv6)
    PPPoED  = 0x8863,   // PPPoE Discovery (PADI/PADO/PADR/PADS/PADT)
    PPPoES  = 0x8864,   // PPPoE Session (carries PPP: LCP, IPCP/IPv6CP, etc.)
    QinQ    = 0x88A8,   // Service VLAN tag identifier (S-Tag) on Q-in-Q tunnel
    OW      = 0x88B5,   // OpenWatt: this is the official experimental ethertype for development use
    MTik    = 0x88BF,   // MikroTik RoMON
    LLDP    = 0x88CC,   // Link Layer Discovery Protocol (LLDP)
    HPGP    = 0x88E1,   // HomePlug Green PHY (HPGP)
}

enum OW_SubType : ushort
{
    Unspecified         = 0x0000,
    AgentDiscover       = 0x0001,   // probably need some way to find peers on the network?
    Modbus              = 0x0010,   // modbus
    CAN                 = 0x0020,   // CAN bus
    MAC_802_15_4        = 0x0030,   // 802.15.4 MAC encapsulation
    ZigbeeNWK           = 0x0031,   // zigbee NWK frame
    ZigbeeAPS           = 0x0032,   // zigbee APS frame
    TeslaTWC            = 0x0040,   // tesla-twc
}


struct Packet
{
nothrow @nogc:
    ref T init(T)(const(void)[] payload, SysTime create_time = getSysTime())
    {
        static assert(T.sizeof <= embed.length);
        assert(payload.length <= ushort.max, "Payload too large");
        creationTime = create_time;
        type = T.Type;
        vlan = 0;
        _flags = 0;
        _offset = 0;
        _length = cast(ushort)payload.length;
        _ptr = payload.ptr;
        return *cast(T*)embed.ptr;
    }
    ref T init(T)(void[] payload, SysTime create_time = getSysTime())
    {
        ref T r = init!T(cast(const)payload, create_time);
        _flags |= 0x01; // mutable
        return r;
    }

    ref inout(T) hdr(T)() inout
    {
        static assert(T.sizeof <= embed.length);
        assert(type == T.Type, "Packet is wrong type for " ~ T.stringof);
        return *cast(inout(T)*)embed.ptr;
    }

    const(void)[] data() const @property
        => _ptr[_offset .. _length];

    void* alloc_prefix(size_t bytes)
    {
        // check we have mutable header bytes
        if (!(_flags & 0x01) || _offset < bytes)
            return null;
        _offset -= cast(ubyte)bytes;
        return cast(void*)_ptr + _offset;
    }

    void data(const(void[]) payload) @property
    {
        assert(payload.length <= ushort.max, "Payload too large");
        _ptr = payload.ptr;
        _offset = 0;
        _length = cast(ushort)payload.length;
    }

    uint length() const
        => _length - _offset;

    Packet* clone(NoGCAllocator allocator = defaultAllocator()) const
    {
        Packet* r = cast(Packet*)allocator.alloc(Packet.sizeof + length);
        *r = this;
        r._flags |= 0x01; // mutable
        r._ptr = &r[1];
        cast(void[])r._ptr[0 .. _length] = _ptr[0 .. _length];
        return r;
    }

    SysTime creationTime; // time received, or time of call to send
    union {
        Ethernet eth;
        void[24] embed;
    }
    PacketType type;
    ushort vlan;

package:
    ubyte _flags; // tag type, mutable alloc, etc...
    ubyte _offset;
    ushort _length;
    const(void)* _ptr;
}

struct Ethernet
{
    enum Type = PacketType.Ethernet;

    MACAddress dst;
    MACAddress src;
    ushort ether_type;
    ushort ow_sub_type; // TODO: REMOVE ME!!
}
