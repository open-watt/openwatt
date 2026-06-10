module router.iface.packet;

import urt.mem.allocator;
import urt.time;

public import router.iface.mac;

nothrow @nogc:


// PacketType is wire-visible (the OW encapsulation type field) and packed into the
// top nibble of universal addresses: values are append-only, never renumber.
enum PacketType : ushort
{
    unknown     = ushort.max,
    raw         = 0,
    ethernet    = 1,
    wifi_80211  = 2,
    wpan        = 3,
    _6lowpan    = 4,
    zigbee_nwk  = 5,
    zigbee_aps  = 6,
    modbus      = 7,
    can         = 8,
    tesla_twc   = 9,
    ble_ll      = 10,
    ble_att     = 11,
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

// Bit 15 of the OW encapsulation type field marks control-plane messages;
// otherwise the field is the PacketType of the encapsulated frame.
enum ushort ow_control_flag = 0x8000;

enum OWControl : ushort
{
    agent_discover = ow_control_flag | 0x0001,  // probably need some way to find peers on the network?
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

// OW ethertype encapsulation: exotic packet types are carried over ethernet as
// [0x88B5][type:u16][data_len:u16][hdr_len:u8][encoded header][payload]. Each
// protocol's codec translates its embed header to/from a stable wire format.
// encode returns bytes written; decode sets packet type + embed header and returns
// header bytes consumed; <= 0 = failure for both. decode may consume less than the
// wire hdr_len (older node, newer peer); the payload is located by hdr_len regardless.
alias OWHeaderEncode = ptrdiff_t function(ref const Packet, ubyte[] buffer) nothrow @nogc;
alias OWHeaderDecode = ptrdiff_t function(ref Packet, const(ubyte)[] header) nothrow @nogc;

struct PacketCodec
{
    AddressExtract extract_src;
    AddressExtract extract_dst;
    IsMulticastAddress is_multicast;
    OWHeaderEncode encode;
    OWHeaderDecode decode;
}

void register_packet_codec(Hdr)()
{
    static assert(Hdr.Type < PacketType.count);
    PacketCodec c;
    c.extract_src = &Hdr.extract_src;
    c.extract_dst = &Hdr.extract_dst;
    c.is_multicast = &Hdr.is_multicast;
    static if (__traits(hasMember, Hdr, "encode_ow_header"))
    {
        c.encode = &Hdr.encode_ow_header;
        c.decode = &Hdr.decode_ow_header;
    }
    g_packet_codecs[Hdr.Type] = c;
}

const(PacketCodec)* get_ow_codec(PacketType type)
    => g_packet_codecs[type].encode ? &g_packet_codecs[type] : null;

ulong get_network_src_address(ref const Packet p) pure
    => packet_codec(p.type).extract_src(p);

ulong get_network_dst_address(ref const Packet p) pure
    => packet_codec(p.type).extract_dst(p);

bool is_network_multicast_address(ulong address) pure
    => packet_codec(cast(PacketType)(address >> 60)).is_multicast(address);


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

    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!Ethernet().src.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.ethernet) << 60;
        return addr;
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!Ethernet().dst.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.ethernet) << 60;
        return addr;
    }

    static bool is_multicast(ulong address) pure nothrow @nogc
    {
        version (LittleEndian)
            return (address & 1) != 0;
        else
            return ((address >> 40) & 1) != 0;
    }
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

    // 802.11 monitor frames address by RA/TA; multicast follows the ethernet bit semantics
    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!Wifi80211().addr2.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.wifi_80211) << 60;
        return addr;
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!Wifi80211().addr1.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.wifi_80211) << 60;
        return addr;
    }

    static bool is_multicast(ulong address) pure nothrow @nogc
        => Ethernet.is_multicast(address);

    // OW encapsulation wire codec: [fc:2 LE][seq_ctrl:2 LE][addr1:6][addr2:6][addr3:6][rssi:1][channel:1]
    // FC and seq_ctrl keep 802.11's little-endian convention
    static ptrdiff_t encode_ow_header(ref const Packet p, ubyte[] buffer) nothrow @nogc
    {
        import urt.endian : nativeToLittleEndian;
        if (buffer.length < 24)
            return -1;
        ref const f = p.hdr!Wifi80211;
        buffer[0 .. 2] = f.frame_control.nativeToLittleEndian;
        buffer[2 .. 4] = f.seq_ctrl.nativeToLittleEndian;
        buffer[4 .. 10] = f.addr1.b[];
        buffer[10 .. 16] = f.addr2.b[];
        buffer[16 .. 22] = f.addr3.b[];
        buffer[22] = cast(ubyte)f.rssi;
        buffer[23] = f.channel;
        return 24;
    }

    static ptrdiff_t decode_ow_header(ref Packet p, const(ubyte)[] header) nothrow @nogc
    {
        import urt.endian : littleEndianToNative;
        if (header.length < 24)
            return -1;
        p.type = PacketType.wifi_80211;
        ref f = p.hdr!Wifi80211;
        f.frame_control = header[0 .. 2].littleEndianToNative!ushort;
        f.seq_ctrl = header[2 .. 4].littleEndianToNative!ushort;
        f.addr1 = MACAddress(header[4 .. 10]);
        f.addr2 = MACAddress(header[10 .. 16]);
        f.addr3 = MACAddress(header[16 .. 22]);
        f.rssi = cast(byte)header[22];
        f.channel = header[23];
        return 24;
    }
}
static assert(Wifi80211.sizeof == 24);


private:

__gshared PacketCodec[PacketType.count] g_packet_codecs = [ PacketCodec(), PacketCodec(&Ethernet.extract_src, &Ethernet.extract_dst, &Ethernet.is_multicast) ];

ref const(PacketCodec) packet_codec(PacketType type) pure
{
    static ref const(PacketCodec) impl(PacketType ty) nothrow @nogc
        => g_packet_codecs[ty];
    alias FP = ref const(PacketCodec) function(PacketType) pure nothrow @nogc;
    return (cast(FP)&impl)(type);
}
