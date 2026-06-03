module router.iface.packet;

import urt.mem.allocator;
import urt.time;

public import router.iface.mac;

nothrow @nogc:


enum PacketType : ushort
{
    unknown = ushort.max,
    raw = 0,
    ethernet,
    wifi_80211,
    wpan,
    _6lowpan,
    zigbee_nwk,
    zigbee_aps,
    modbus,
    can,
    tesla_twc,
    ble_ll,
    ble_att,
    count
}
static assert(PacketType.count <= 16, "PacketType must fit in 4 bits");

enum EtherType : ushort
{
    ip4     = 0x0800,   // Internet Protocol version 4 (IPv4)
    arp     = 0x0806,   // Address Resolution Protocol (ARP)
    wol     = 0x0842,   // Wake-on-LAN
    vlan    = 0x8100,   // IEEE 802.1Q VLAN tag
    ip6     = 0x86DD,   // Internet Protocol version 6 (IPv6)
    pppoed  = 0x8863,   // PPPoE Discovery (PADI/PADO/PADR/PADS/PADT)
    pppoes  = 0x8864,   // PPPoE Session (carries PPP: LCP, IPCP/IPv6CP, etc.)
    qinq    = 0x88A8,   // Service VLAN tag identifier (S-Tag) on Q-in-Q tunnel
    ow      = 0x88B5,   // OpenWatt: this is the official experimental ethertype for development use
    mtik    = 0x88BF,   // MikroTik RoMON
    lldp    = 0x88CC,   // Link Layer Discovery Protocol (LLDP)
    hpgp    = 0x88E1,   // HomePlug Green PHY (HPGP)
}

enum OW_SubType : ushort
{
    unspecified         = 0x0000,
    agent_discover      = 0x0001,   // probably need some way to find peers on the network?
    modbus              = 0x0010,   // modbus
    can                 = 0x0020,   // CAN bus
    mac_802_15_4        = 0x0030,   // 802.15.4 MAC encapsulation
    zigbee_nwk          = 0x0031,   // zigbee NWK frame
    zigbee_aps          = 0x0032,   // zigbee APS frame
    tesla_twc           = 0x0040,   // tesla-twc
    ble_ll              = 0x0050,   // BLE Link Layer PDU
    ble_att             = 0x0051,   // BLE ATT frame
}

// 802.1p PCP traffic classes
// scheduling order: BK < BE < EE < CA < VI < VO < IC < NC
enum PCP : ubyte
{
    be = 0,  // Best Effort (default)
    bk = 1,  // Background  (lowest priority)
    ee = 2,  // Excellent Effort
    ca = 3,  // Critical Applications
    vi = 4,  // Video
    vo = 5,  // Voice
    ic = 6,  // Internetwork Control
    nc = 7,  // Network Control
}

immutable ubyte[8] pcp_priority_map = [1, 0, 2, 3, 4, 5, 6, 7];


alias AddressExtract = ulong function(ref const Packet) pure nothrow @nogc;
alias IsMulticastAddress = bool function(ulong address) pure nothrow @nogc;

void register_address_extractor(PacketType type, AddressExtract src_extract, AddressExtract dst_extract, IsMulticastAddress is_multicast)
{
    assert(type <= PacketType.count);
    g_address_extractors[type].src = src_extract;
    g_address_extractors[type].dst = dst_extract;
    g_address_extractors[type].is_multicast = is_multicast;
}

ulong get_network_src_address(ref const Packet p) pure
    => get_address_extractor(p.type).src(p);

ulong get_network_dst_address(ref const Packet p) pure
    => get_address_extractor(p.type).dst(p);

bool is_network_multicast_address(ulong address) pure
    => get_address_extractor(cast(PacketType)(address >> 60)).is_multicast(address);


struct Packet
{
nothrow @nogc:
    ref T init(T)(const(void)[] payload, SysTime create_time = getSysTime())
    {
        static assert(T.sizeof <= embed.length);
        assert(payload.length <= ushort.max, "Payload too large");
        creation_time = create_time;
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
        Packet* r = cast(Packet*)allocator.alloc(Packet.sizeof + _length);
        *r = this;
        r._flags |= 0x01; // mutable
        r._ptr = &r[1];
        cast(void[])r._ptr[0 .. _length] = _ptr[0 .. _length];
        return r;
    }

    // Free a Packet returned by clone(). Caller must pass the same allocator
    // that was used to clone(); defaults match.
    void free_clone(NoGCAllocator allocator = defaultAllocator())
    {
        allocator.free((cast(void*)&this)[0 .. Packet.sizeof + _length]);
    }

    PCP pcp() const pure
        => cast(PCP)(vlan >> 13);
    void pcp(PCP value) pure
    {
        vlan = (vlan & 0x1FFF) | cast(ushort)(value << 13);
    }

    bool dei() const pure
        => (vlan & 0x1000) != 0;
    void dei(bool value) pure
    {
        vlan = value ? (vlan | 0x1000) : cast(ushort)(vlan & ~0x1000);
    }

    ushort vid() const pure
        => vlan & 0x0FFF;

    // TODO: should be MonoTime - a packet is a physical event, not a wall-clock label; project to SysTime at the pcap/display boundary
    SysTime creation_time; // time received, or time of call to send
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

struct RawFrame
{
    enum Type = PacketType.raw;

    bool is_text; // payload is text, which can be verified for validity, or drive WebSocket text flag for instance
}

struct Ethernet
{
    enum Type = PacketType.ethernet;

    MACAddress dst;
    MACAddress src;
    ushort ether_type;
    ushort ow_sub_type; // TODO: REMOVE ME!!
}

struct Wifi80211
{
    enum Type = PacketType.wifi_80211;

    ushort frame_control;   // FC field: type[3:2], subtype[7:4], to_ds, from_ds, more_frag, retry, pwr_mgmt, more_data, protected, order
    ushort seq_ctrl;        // sequence control field (fragment + sequence number)
    MACAddress addr1;       // receiver (RA) / dst
    MACAddress addr2;       // transmitter (TA) / src
    MACAddress addr3;       // BSSID / dst / src depending on ToDS/FromDS
    byte rssi;              // RX signal strength, dBm
    ubyte channel;          // RX channel (1..14 for 2.4 GHz)

    // Not included to keep this in 24 bytes -- parse from payload when needed:
    // ushort duration;      // Duration/ID, only matters for NAV math
    // MACAddress addr4;     // 4-address WDS / mesh frames only
    // ushort qos_ctrl;      // QoS data frames (HT/VHT/HE)
    // uint ht_ctrl;         // HT Control field for +HTC frames
}
static assert(Wifi80211.sizeof == 24);


private:

struct AddressExtractors
{
    AddressExtract src;
    AddressExtract dst;
    IsMulticastAddress is_multicast;
}
__gshared AddressExtractors[PacketType.count] g_address_extractors = [ AddressExtractors(), AddressExtractors(&extract_ethernet_src_address, &extract_ethernet_dst_address, &is_ethernet_multicast_address) ];

ref const(AddressExtractors) get_address_extractor(PacketType type) pure
{
    static ref const(AddressExtractors) impl(PacketType ty) nothrow @nogc
        => g_address_extractors[ty];
    alias FP = ref const(AddressExtractors) function(PacketType) pure nothrow @nogc;
    return (cast(FP)&impl)(type);
}

ulong extract_ethernet_src_address(ref const Packet p) pure
{
    ulong addr = p.hdr!Ethernet().src.ul;
    addr |= ulong(p.vlan & 0xFFF) << 48;
    addr |= ulong(PacketType.ethernet) << 60;
    return addr;
}

ulong extract_ethernet_dst_address(ref const Packet p) pure
{
    ulong addr = p.hdr!Ethernet().dst.ul;
    addr |= ulong(p.vlan & 0xFFF) << 48;
    addr |= ulong(PacketType.ethernet) << 60;
    return addr;
}

bool is_ethernet_multicast_address(ulong address) pure
{
    version (LittleEndian)
        return (address & 1) != 0;
    else
        return ((address >> 40) & 1) != 0;
}
