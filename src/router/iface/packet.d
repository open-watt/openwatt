module router.iface.packet;

import urt.endian;
import urt.log;
import urt.mem;
import urt.mem.pagepool;
import urt.meta : AliasSeq;
import urt.time;
import urt.util : align_down;

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


alias AddressExtract = ulong function(const(Packet)*) pure nothrow @nogc;
alias IsMulticastAddress = bool function(ulong address) pure nothrow @nogc;

// OW ethertype encapsulation: exotic packet types are carried over ethernet as
// [0x88B5][type:u16][data_len:u16][hdr_len:u8][encoded header][payload]. Each
// protocol's codec translates its embed header to/from a stable wire format.
// encode returns bytes written; decode sets packet type + embed header and returns
// header bytes consumed; <= 0 = failure for both. decode may consume less than the
// wire hdr_len (older node, newer peer); the payload is located by hdr_len regardless.
alias OWHeaderEncode = ptrdiff_t function(const(Packet)*, ubyte[] buffer) nothrow @nogc;
alias OWHeaderDecode = ptrdiff_t function(Packet*, const(ubyte)[] header) nothrow @nogc;

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

enum ulong network_address_vid_mask = ulong(0xFFF) << 48;

ulong get_network_src_address(const(Packet)* p) pure
    => packet_codec(p.type).extract_src(p);

ulong get_network_dst_address(const(Packet)* p) pure
    => packet_codec(p.type).extract_dst(p);

bool is_network_multicast_address(ulong address) pure
    => packet_codec(cast(PacketType)(address >> 60)).is_multicast(address);


struct Packet
{
nothrow @nogc:
    @disable this(this);

    // a new frame of type T over the same bytes, for a packet its caller owns; priority and checksum state carry over
    ref T reframe(T)()
    {
        static assert(T.sizeof <= embed.length);
        type = T.Type;
        vlan &= 0xF000;
        _flags &= checksum_pending_flag | checksum_verified_flag;
        return *cast(T*)embed.ptr;
    }

    ref inout(T) hdr(T)() inout
    {
        static assert(T.sizeof <= embed.length);
        assert(type == T.Type, "Packet is wrong type for " ~ T.stringof);
        return *cast(inout(T)*)embed.ptr;
    }

    const(void)[] data() const @property
        => _ptr[0 .. _length];

    // null unless the packet alone holds the page its bytes live in
    void[] payload() @property
        => page_unique(page) ? (cast(void*)_ptr)[0 .. _length] : null;

    void truncate(size_t length)
    {
        assert(length <= _length, "Cannot grow a packet by truncating it");
        _length = cast(ushort)length;
    }

    // the bytes the packet may prepend in place: none unless it alone holds the page its bytes live in
    size_t headroom() const
    {
        if (!page_unique(page))
            return 0;
        size_t start = cast(size_t)(_ptr - cast(const(void)*)page);
        return start - (packet_page_offset < start ? packet_page_offset + Packet.sizeof : Page.sizeof);
    }

    void[] alloc_prefix(size_t bytes)
    {
        if (bytes > headroom)
            return null;
        _ptr -= bytes;
        _length += cast(ushort)bytes;
        return (cast(void*)_ptr)[0 .. bytes];
    }

    bool consume_prefix(size_t bytes)
    {
        if (bytes > _length)
            return false;
        _ptr += bytes;
        _length -= cast(ushort)bytes;
        return true;
    }

    uint length() const
        => _length;

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
        consume_prefix(4);
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

    bool has_hw_timestamp() const pure
        => (_flags & hw_timestamp_flag) != 0;

    void set_hw_timestamp(HwTimestamp time) pure
    {
        hdr!Ethernet().hw_time = time;
        _flags |= hw_timestamp_flag;
    }

    bool checksum_pending() const pure
        => (_flags & checksum_pending_flag) != 0;

    void checksum_pending(bool value) pure
    {
        _flags = cast(ubyte)(value ? _flags | checksum_pending_flag : _flags & ~checksum_pending_flag);
    }

    bool checksum_verified() const pure
        => (_flags & checksum_verified_flag) != 0;

    void set_checksum_verified() pure
    {
        _flags |= checksum_verified_flag;
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
    ushort _length;
    const(void)* _ptr;

private:
    enum ubyte vlan_tag_mask = 7;
    enum ubyte hw_timestamp_flag = 1 << 5;
    enum ubyte checksum_pending_flag = 1 << 6;
    enum ubyte checksum_verified_flag = 1 << 7;

    Page* page() const
    {
        ushort offset = packet_page_offset;
        debug assert(offset >= Page.sizeof, "a StackPacket is initialised before use");
        return cast(Page*)(cast(void*)&this - offset);
    }

    ushort packet_page_offset() const
        => (cast(const(ushort)*)&this)[-1];

    ref T init(T)(const(void)[] payload, MonoTime create_time = getTime())
    {
        static assert(T.sizeof <= embed.length);
        assert(payload.length <= ushort.max, "Payload too large");
        creation_time = create_time;
        type = T.Type;
        vlan = 0;
        _flags = 0;
        _length = cast(ushort)payload.length;
        _ptr = payload.ptr;
        return *cast(T*)embed.ptr;
    }

    void take_metadata(const(Packet)* from)
    {
        creation_time = from.creation_time;
        embed = from.embed;
        type = from.type;
        vlan = from.vlan;
        _flags = from._flags;
    }
}

// a packet over bytes that live elsewhere, lent for the call
struct StackPacket
{
nothrow @nogc:
    @disable this(this);

    ref T init(T)(const(void)[] bytes, MonoTime create_time = getTime())
    {
        lend();
        return packet.init!T(bytes, create_time);
    }

    // the source's bytes under metadata of its own
    void init_view(const(Packet)* source)
    {
        lend();
        packet = Packet();
        packet.take_metadata(source);
        data = source.data;
    }

    const(void)[] data() const @property
        => packet.data;

    // a lent packet may view any bytes; a pool packet's view stays within its page
    void data(const(void)[] bytes) @property
    {
        assert(bytes.length <= ushort.max, "Payload too large");
        packet._ptr = bytes.ptr;
        packet._length = cast(ushort)bytes.length;
    }

    alias packet this;

private:
    StackPage!0 _page;
public:
    Packet packet;

private:
    void lend()
    {
        _page.page();
        (cast(ushort*)&packet)[-1] = Page.sizeof;
    }
}
static assert(StackPacket.packet.offsetof == Page.sizeof);

enum ubyte packet_headroom = 80;

version (FramingDiagnostics) enum bool has_framing_diagnostics = true;
else debug enum bool has_framing_diagnostics = true;
else enum bool has_framing_diagnostics = false;

// without diagnostics there is no site argument: FramingSiteArg and framing_site!name expand to nothing
static if (has_framing_diagnostics)
{
    // a site that frames packets in place, and the frames it copied because their page lacked the room
    struct FramingSite
    {
        string name;
        uint copies;
    }

    alias FramingSiteArg = FramingSite*;

    FramingSite* framing_site(string name)()
    {
        __gshared FramingSite site = FramingSite(name);
        return &site;
    }

    uint packet_room_copies()
        => _room_copies;
}
else
{
    alias FramingSiteArg = AliasSeq!();
    alias framing_site(string name) = AliasSeq!();
}

// a reference of the caller's own to a packet it borrowed: a pool page is shared, a lent packet is copied
Packet* packet_retain(const(Packet)* packet)
{
    if (page_foreign(packet.page))
        return packet_copy(packet);
    page_share(cast(Page*)packet.page);
    return cast(Packet*)packet;
}

// a packet the caller may edit: itself unless its page is shared, else a copy reserving `reserve` in front; null, having freed it, if the copy fails
Packet* packet_mutable(Packet* packet, size_t headroom = 0, size_t reserve = packet_headroom, FramingSiteArg site = null)
{
    debug assert(headroom <= reserve && reserve <= packet_headroom);
    bool unique = page_unique(packet.page);
    size_t had;
    if (unique)
    {
        had = packet.headroom;
        if (had >= headroom)
            return packet;
    }
    else if (page_foreign(packet.page) && !headroom)
        return packet;
    Packet* copy = packet_copy(packet, reserve);
    packet_free(packet);
    static if (has_framing_diagnostics)
    {
        if (copy && unique && site)
            room_copied(site, headroom, had, 0, 0);
    }
    return copy;
}

// the packet's bytes as a page with head and tail bytes of room around them for a frame; consumes the packet, null if a copy fails
Page* packet_page(Packet* packet, size_t head, size_t tail, FramingSiteArg site = null)
{
    Page* page = packet.page;
    size_t start = packet._ptr - cast(void*)page;
    size_t length = head + packet._length + tail;
    bool unique = page_unique(page);
    size_t had_head, had_tail;
    if (unique)
    {
        had_head = packet.headroom;
        had_tail = page.capacity - start - packet._length;
        if (had_head >= head && had_tail >= tail)
        {
            page.offset = cast(ushort)(start - head);
            page.length = cast(ushort)length;
            return page;
        }
    }
    Page* copy = page_alloc(length);
    if (copy)
        copy.data[head .. head + packet._length] = packet.data[];
    packet_free(packet);
    static if (has_framing_diagnostics)
    {
        if (copy && unique && site)
            room_copied(site, head, had_head, tail, had_tail);
    }
    return copy;
}

// makes a reference the caller owns storable: a pool packet as it is, a lent one copied
Packet* packet_keep(Packet* packet, size_t headroom = packet_headroom)
    => page_foreign(packet.page) ? packet_copy(packet, headroom) : packet;

Packet* packet_copy(const(Packet)* packet, size_t headroom = packet_headroom)
{
    const(void)[] source = packet.data;
    Page* p = page_alloc(source.length, size_t.sizeof, packet_prefix_size + headroom);
    if (!p)
        return null;
    Packet* r = attach_packet(p);
    if (!r)
    {
        page_free(p);
        return null;
    }
    r.take_metadata(packet);
    r.payload[] = source;
    return r;
}

void packet_free(Packet* packet)
{
    if (packet)
        page_free(packet.page);
}

Packet* alloc_packet(T)(size_t payload, ubyte headroom = packet_headroom)
{
    Page* page = page_alloc(payload, size_t.sizeof, packet_prefix_size + headroom);
    if (!page)
        return null;

    Packet* p = attach_packet(page);
    if (!p)
    {
        page_free(page);
        return null;
    }
    p.creation_time = getTime();
    p.type = T.Type;
    return p;
}

Packet* alloc_packet(T)(const(void)[] payload, ubyte headroom = packet_headroom)
{
    Packet* p = alloc_packet!T(payload.length, headroom);
    if (p)
        p.payload[] = cast(void[])payload[];
    return p;
}

Packet* attach_packet(Page* page)
{
    if (!page)
        return null;

    size_t offset = packet_page_start;
    if (page.offset < packet_page_start + Packet.sizeof)
    {
        size_t base = cast(size_t)page;
        size_t end = base + page.capacity;
        size_t address = (end - Packet.sizeof).align_down(Packet.alignof);
        offset = address - base;
        if (offset < ushort.sizeof || page.offset + page.length > offset - ushort.sizeof)
            return null;
        page.capacity = cast(ushort)(offset - ushort.sizeof);
    }

    Packet* packet = cast(Packet*)(cast(void*)page + offset);
    (cast(ushort*)packet)[-1] = cast(ushort)offset;
    *packet = Packet();
    packet._ptr = page.data.ptr;
    packet._length = page.length;
    return packet;
}

struct RawFrame
{
    enum Type = PacketType.raw;

    bool is_text; // payload is text, which can be verified for validity, or drive WebSocket text flag for instance
}

// When the start-of-frame delimiter crossed the receiving MAC, on the clock of that MAC:
// the IEEE 1588 domain, which a PTP servo steers and MonoTime does not follow.
struct HwTimestamp
{
    uint seconds;
    uint nanoseconds;
}

struct Ethernet
{
    enum Type = PacketType.ethernet;

    MACAddress dst;
    MACAddress src;
    ushort ether_type;
    HwTimestamp hw_time;    // valid only where Packet.has_hw_timestamp

    static ulong extract_src(const(Packet)* p) pure nothrow @nogc
    {
        ulong addr = p.hdr!Ethernet().src.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.ethernet) << 60;
        return addr;
    }

    static ulong extract_dst(const(Packet)* p) pure nothrow @nogc
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
    static ulong extract_src(const(Packet)* p) pure nothrow @nogc
    {
        ulong addr = p.hdr!Wifi80211().addr2.ul;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.wifi_80211) << 60;
        return addr;
    }

    static ulong extract_dst(const(Packet)* p) pure nothrow @nogc
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
    static ptrdiff_t encode_ow_header(const(Packet)* p, ubyte[] buffer) nothrow @nogc
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

    static ptrdiff_t decode_ow_header(Packet* p, const(ubyte)[] header) nothrow @nogc
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

enum ushort packet_page_start = Page.sizeof;
enum ushort packet_prefix_size = Packet.sizeof;
static assert(packet_page_start % Packet.alignof == 0);

immutable ushort[6] vlan_tpids = [0, EtherType.vlan, EtherType.qinq, EtherType._9100, EtherType._9200, EtherType._9300];
__gshared PacketCodec[PacketType.count] g_packet_codecs = [ PacketCodec(), PacketCodec(&Ethernet.extract_src, &Ethernet.extract_dst, &Ethernet.is_multicast) ];

ref const(PacketCodec) packet_codec(PacketType type) pure
{
    static ref const(PacketCodec) impl(PacketType ty) nothrow @nogc
        => g_packet_codecs[ty];
    alias FP = ref const(PacketCodec) function(PacketType) pure nothrow @nogc;
    return (cast(FP)&impl)(type);
}

static if (has_framing_diagnostics)
{
    __gshared uint _room_copies;

    // warns on a site's 1st, 2nd, 4th, 8th... copy
    void room_copied(FramingSite* site, size_t head, size_t had_head, size_t tail, size_t had_tail)
    {
        ++_room_copies;
        uint n = ++site.copies;
        if ((n & (n - 1)) == 0)
            log_warning("packet", site.name, " copied a frame for want of room: head ", had_head, " of ", head, ", tail ", had_tail, " of ", tail, " (", n, n == 1 ? " copy)" : " copies)");
    }
}


unittest
{
    bool owns_pool = page_pool_init();
    scope(exit) if (owns_pool) page_pool_deinit();

    Packet* owned = alloc_packet!RawFrame(4);
    assert(owned && owned.packet_page_offset == packet_page_start);
    assert(owned.page.offset == packet_page_start + Packet.sizeof + packet_headroom);
    assert(owned.data.ptr is owned.page.data.ptr && owned.data.length == 4);
    const(void)* start = owned.data.ptr;
    assert(owned.alloc_prefix(4).length == 4);
    assert(owned.data.ptr is start - 4 && owned.data.length == 8);
    assert(owned.consume_prefix(4));
    assert(owned.data.ptr is start && owned.data.length == 4);
    assert(packet_retain(owned) is owned && owned.alloc_prefix(4) is null && owned.payload is null, "a shared packet is not written in place");
    packet_free(owned);
    packet_free(owned);

    Page* raw = page_alloc(16);
    assert(raw);
    ushort old_capacity = raw.capacity;
    Packet* attached = attach_packet(raw);
    assert(attached && attached.packet_page_offset > raw.offset + raw.length);
    assert(raw.capacity == attached.packet_page_offset - ushort.sizeof);
    assert(raw.capacity < old_capacity && attached.data.length == 16);
    size_t slack = raw.tailroom;
    assert(packet_page(attached, 0, slack) is raw && raw.length == 16 + slack, "a tail packet's trimmed capacity is room to the byte");
    page_free(raw);
    raw = page_alloc(16);
    attached = attach_packet(raw);
    size_t over = raw.tailroom + 1;
    Page* spilled = packet_page(attached, 0, over);
    assert(spilled && spilled !is raw && spilled.length == 16 + over, "one byte past the trimmed capacity is copied");
    page_free(spilled);

    ubyte[4] lent_bytes = [1, 2, 3, 4];
    StackPacket lent;
    lent.init!Ethernet(lent_bytes[]).ether_type = EtherType.ow;
    lent.vlan = 5;
    assert(page_foreign(lent.page) && lent.data.ptr is lent_bytes.ptr);
    StackPacket view;
    view.init_view(&lent.packet);
    view.vlan = 7;
    assert(view.data.ptr is lent_bytes.ptr && view.hdr!Ethernet.ether_type == EtherType.ow && lent.vlan == 5);
    Packet* kept = packet_retain(&view.packet);
    assert(kept && kept.data.ptr !is lent_bytes.ptr && cast(const(ubyte)[])kept.data == lent_bytes[] && kept.vlan == 7);
    assert(packet_retain(kept) is kept && !page_unique(kept.page), "a pool packet is shared, not copied");
    packet_free(kept);
    assert(page_unique(kept.page));
    packet_free(kept);
    packet_free(&lent.packet);
    assert(cast(const(ubyte)[])lent.data == lent_bytes[], "freeing a lent packet leaves its bytes alone");

    ubyte[1500] mtu_bytes;
    StackPacket mtu;
    mtu.init!Ethernet(mtu_bytes[]);
    static immutable ushort[2] class_payloads = [253, 1500];
    foreach (ubyte category, payload; class_payloads)
    {
        Packet* p = alloc_packet!RawFrame(payload);
        assert(p && page_category(p.page) == category, "a default packet of 253 or 1500 bytes fits its page class");
        packet_free(p);
    }
    Packet* framable = packet_mutable(&mtu.packet, 18, 18);
    assert(framable && framable.headroom >= 18 && page_category(framable.page) < page_pool_num_categories(), "a full-size lent frame is copied with the room it asks for into a pool page");
    packet_free(framable);

    Packet* framed = alloc_packet!RawFrame(lent_bytes[]);
    Page* own_page = framed.page;
    const(void)* own_bytes = framed.data.ptr;
    Page* in_place = packet_page(framed, 1, 2, framing_site!"packet-test");
    assert(in_place is own_page && in_place.data.ptr is own_bytes - 1 && in_place.length == 7, "a unique page frames in place");
    framed = alloc_packet!RawFrame(lent_bytes[]);
    Page* copied = packet_page(packet_retain(framed), 1, 2, framing_site!"packet-test");
    assert(copied !is framed.page && page_unique(framed.page) && (cast(ubyte[])copied.data)[1 .. 5] == lent_bytes[], "a shared page is copied");
    static if (has_framing_diagnostics)
    {
        assert(framing_site!"packet-test".copies == 0, "copying a shared page is not a want of room");
        uint total = packet_room_copies();
    }
    Packet* bare = alloc_packet!RawFrame(lent_bytes[], 0);
    Page* reframed = packet_page(bare, 7, 0, framing_site!"packet-test");
    assert(reframed && reframed.length == 11, "a head miss copies despite spare tail");
    static if (has_framing_diagnostics)
        assert(framing_site!"packet-test".copies == 1 && packet_room_copies() == total + 1);
    page_free(reframed);
    page_free(in_place);
    page_free(copied);
    packet_free(framed);

    ubyte[8] payload = [0x00, 0x03, 0x08, 0x00, 1, 2, 3, 4];
    StackPacket packet;
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
