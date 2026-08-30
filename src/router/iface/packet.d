module router.iface.packet;

import urt.endian;
import urt.mem;
import urt.mem.pagepool;
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
    ble         = 10,
    cpc         = 11,
    i2c         = 12,
    udp         = 13,
    obd         = 15,
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
    cfm     = 0x8902,   // IEEE 802.1ag / ITU-T Y.1731 Connectivity Fault Management
    _9100   = 0x9100,
    _9200   = 0x9200,
    _9300   = 0x9300,
}

enum VlanTag : ubyte
{
    none,
    _8100,
    _88a8,
    _9100,
    _9200,
    _9300,
}

VlanTag vlan_tag_from_tpid(ushort tpid) pure
{
    foreach (i, candidate; vlan_tpids)
        if (candidate == tpid)
            return cast(VlanTag)i;
    return VlanTag.none;
}

ushort vlan_tpid(VlanTag tag) pure
    => vlan_tpids[tag];

// The top two bits select how to interpret the OW discriminator. Zero carries
// an exotic PacketType, 01 carries an IP protocol number in the low byte, and
// 10 carries an OWControl value. 11 is reserved.
enum ushort ow_class_mask = 0xC000;
enum ushort ow_transport_flag = 0x4000;
enum ushort ow_control_flag = 0x8000;

bool is_ow_transport(ushort discriminator) pure
    => (discriminator & 0xFF00) == ow_transport_flag;

ushort ow_transport_discriminator(ubyte protocol) pure
    => ow_transport_flag | protocol;

enum OWControl : ushort
{
    who_has     = ow_control_flag | 0x0001,  // body: universal address (u64 BE) -- which station carries this?
    addr_query  = ow_control_flag | 0x0002,  // body: [txid:u32 BE][PacketType:u16 BE, unknown = all] -- report your addresses
    addr_report = ow_control_flag | 0x0003,  // body: [txid:u32 BE, 0 = unsolicited][name_len:u8][name][N x universal address (u64 BE)]
    announce    = ow_control_flag | 0x0004,  // body: identity TLVs (see manager.sync.discovery) -- peering beacon
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

struct QueuePolicy
{
nothrow @nogc:
    void set_deadline(Duration timeout, PCP urgent, ubyte escalation_percent = 50)
    {
        assert(timeout > Duration.zero, "Queue deadline must be positive");
        assert(escalation_percent <= 100, "Escalation percentage must be at most 100");

        long timeout_ms = timeout.as!"msecs";
        assert(timeout_ms <= uint.max, "Queue deadline must fit in milliseconds");
        deadline_after = cast(uint)timeout_ms;
        priority_escalation_after = cast(uint)(timeout_ms * escalation_percent / 100);
        urgent_pcp = urgent;
    }

    uint deadline_after;
    uint priority_escalation_after;
    PCP urgent_pcp = PCP.be;
}


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
    ref T init(T)(const(void)[] payload, MonoTime create_time = getTime())
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
    ref T init(T)(void[] payload, MonoTime create_time = getTime())
    {
        ref T r = init!T(cast(const)payload, create_time);
        _flags |= mutable_flag;
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

    // null unless the packet owns its payload
    void[] payload() @property
    {
        if (!(_flags & mutable_flag))
            return null;
        return (cast(void*)_ptr)[_offset .. _length];
    }

    void truncate(size_t length)
    {
        assert(_offset + length <= _length, "Cannot grow a packet by truncating it");
        _length = cast(ushort)(_offset + length);
    }

    void[] alloc_prefix(size_t bytes)
    {
        if (!(_flags & mutable_flag) || _offset < bytes)
            return null;
        _offset -= cast(ubyte)bytes;
        return (cast(void*)_ptr)[_offset .. _offset + bytes];
    }

    bool consume_prefix(size_t bytes)
    {
        if (_offset + bytes > _length)
            return false;
        _offset += cast(ubyte)bytes;
        return true;
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

    Packet* clone() const
    {
        void[] page = page_alloc_for(Packet.sizeof + _length);
        if (!page.ptr)
            return null;
        Packet* r = cast(Packet*)page.ptr;
        *r = this;
        r._flags |= mutable_flag;
        r._ptr = &r[1];
        cast(void[])r._ptr[0 .. _length] = _ptr[0 .. _length];
        return r;
    }

    void free_clone()
    {
        page_free(&this);
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

    VlanTag vlan_tag() const pure
        => cast(VlanTag)(_flags & vlan_tag_mask);

    void vlan_tag(VlanTag value) pure
    {
        assert(value <= VlanTag._9300);
        _flags = cast(ubyte)((_flags & ~vlan_tag_mask) | value);
    }

    bool set_vlan_tag(ushort tpid) pure
    {
        VlanTag tag = vlan_tag_from_tpid(tpid);
        if (tag == VlanTag.none && tpid != 0)
            return false;
        vlan_tag = tag;
        return true;
    }

    bool has_inline_vlan_tag() const pure
        => vlan_tag == VlanTag.none &&
           type == PacketType.ethernet &&
           vlan_tag_from_tpid(eth.ether_type) != VlanTag.none;

    bool promote_vlan_tag()
    {
        if (vlan_tag != VlanTag.none)
            return true;
        VlanTag tag = type == PacketType.ethernet ? vlan_tag_from_tpid(eth.ether_type) : VlanTag.none;
        if (tag == VlanTag.none || data.length < 4)
            return false;
        const(ushort)* tci = cast(const(ushort)*)data.ptr;
        vlan = loadBigEndian(tci);
        eth.ether_type = loadBigEndian(tci + 1);
        _offset += 4;
        vlan_tag = tag;
        return true;
    }

    bool consume_priority_tags()
    {
        if (has_inline_vlan_tag && !promote_vlan_tag())
            return false;
        while (vlan_tag != VlanTag.none && vid == 0)
        {
            consume_vlan_tag();
            if (!has_inline_vlan_tag)
                break;
            if (!promote_vlan_tag())
                return false;
        }
        return true;
    }

    void consume_vlan_tag() pure
    {
        vlan &= 0xF000;
        vlan_tag = VlanTag.none;
    }

    // monotonic; a packet is a physical event, not a wall-clock label. Project to SysTime only at record boundaries (element values, pcap, logs).
    MonoTime creation_time; // time received, or time of call to send
    union {
        Ethernet eth;
        void[24] embed;
    }
    PacketType type;
    ushort vlan;

package:
    ubyte _flags;
    ubyte _offset;
    ushort _length;
    const(void)* _ptr;

private:
    enum ubyte vlan_tag_mask = 7;
    enum ubyte mutable_flag = 1 << 3;
}

// _offset is a ubyte, so 255 is the ceiling.
enum ubyte packet_headroom = 128;

Packet* alloc_packet(T)(size_t payload, ubyte headroom = packet_headroom)
{
    if (payload + headroom > ushort.max)
        return null;

    void[] page = page_alloc_for(Packet.sizeof + headroom + payload);
    if (!page.ptr)
        return null;

    // `Packet.init` names the init!T member template, not the default value
    Packet blank;
    Packet* p = cast(Packet*)page.ptr;
    *p = blank;
    p.creation_time = getTime();
    p.type = T.Type;
    p._flags = 0x01;     // mutable, so alloc_prefix will work
    p._offset = headroom;
    p._length = cast(ushort)(headroom + payload);
    p._ptr = &p[1];
    return p;
}

Packet* alloc_packet(T)(const(void)[] payload, ubyte headroom = packet_headroom)
{
    Packet* p = alloc_packet!T(payload.length, headroom);
    if (p)
        p.payload[] = cast(void[])payload[];
    return p;
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

immutable ushort[6] vlan_tpids = [0, EtherType.vlan, EtherType.qinq, EtherType._9100, EtherType._9200, EtherType._9300];
__gshared PacketCodec[PacketType.count] g_packet_codecs = [ PacketCodec(), PacketCodec(&Ethernet.extract_src, &Ethernet.extract_dst, &Ethernet.is_multicast) ];

ref const(PacketCodec) packet_codec(PacketType type) pure
{
    static ref const(PacketCodec) impl(PacketType ty) nothrow @nogc
        => g_packet_codecs[ty];
    alias FP = ref const(PacketCodec) function(PacketType) pure nothrow @nogc;
    return (cast(FP)&impl)(type);
}


unittest
{
    ubyte[8] payload = [0x00, 0x03, 0x08, 0x00, 1, 2, 3, 4];
    Packet packet;
    ref eth = packet.init!Ethernet(payload[]);
    eth.ether_type = vlan_tpid(VlanTag._8100);
    packet.pcp = PCP.vo;

    assert(packet.vlan_tag == VlanTag.none);
    assert(packet.has_inline_vlan_tag);
    assert(packet.promote_vlan_tag());
    assert(packet.vlan_tag == VlanTag._8100);
    assert(packet.vid == 3);
    assert(packet.pcp == PCP.be);
    assert(packet.eth.ether_type == EtherType.ip4);
    assert(cast(const(ubyte)[])packet.data == payload[4 .. $]);

    packet.consume_vlan_tag();
    assert(packet.vlan_tag == VlanTag.none);
    assert(packet.vlan == 0);

    packet.vlan = 0xA000;
    packet.vlan_tag = VlanTag._88a8;
    assert(packet.promote_vlan_tag());
    assert(packet.vlan == 0xA000);
    assert(packet.vlan_tag == VlanTag._88a8);

    packet.consume_vlan_tag();
    eth.ether_type = vlan_tpid(VlanTag._8100);
    packet.data = payload[];
    assert(packet.pcp == PCP.vo);
    packet.vlan_tag = VlanTag._88a8;
    assert(packet.consume_priority_tags());
    assert(packet.pcp == PCP.be);
    assert(packet.vid == 3);
    assert(packet.vlan_tag == VlanTag._8100);

    packet.vlan = 0xA000;
    packet.vlan_tag = VlanTag._8100;
    eth.ether_type = EtherType.ip4;
    assert(packet.consume_priority_tags());
    assert(packet.pcp == PCP.vo);
    assert(packet.vid == 0);
    assert(packet.vlan_tag == VlanTag.none);
}
