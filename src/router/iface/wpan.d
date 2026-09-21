module router.iface.wpan;

import urt.endian;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

import router.iface;
import router.iface.mac;
import router.iface.packet;

nothrow @nogc:


enum WpanFrameType : ubyte
{
    beacon,
    data,
    ack,
    command,
    reserved,
    multipurpose,
    fragment,
    extended,
}

enum WpanAddressMode : ubyte
{
    none = 0,
    short_ = 2,
    extended = 3,
}

enum ushort wpan_broadcast_pan = 0xFFFF;
enum ushort wpan_broadcast_short = 0xFFFF;
enum ushort wpan_no_short_address = 0xFFFE;


// The payload is the whole MAC frame from the frame control field, without FCS; the sequence
// number, security header and IEs are read from there.
struct WpanFrame
{
    enum Type = PacketType.wpan;
nothrow @nogc:

    ushort frame_control;
    byte rssi;              // dBm
    ubyte lqi;
    ushort dst_pan;         // wpan_broadcast_pan where the frame elides it
    ushort src_pan;
    EUI64 dst;              // extended address, or a short address in the low 16 bits of ul
    EUI64 src;

    WpanFrameType frame_type() const pure
        => cast(WpanFrameType)(frame_control & 0x7);
    bool pan_compression() const pure
        => (frame_control & 0x0040) != 0;
    bool seq_suppressed() const pure
        => frame_version == 2 && (frame_control & 0x0100) != 0;
    WpanAddressMode dst_mode() const pure
        => cast(WpanAddressMode)((frame_control >> 10) & 0x3);
    ubyte frame_version() const pure
        => (frame_control >> 12) & 0x3;
    WpanAddressMode src_mode() const pure
        => cast(WpanAddressMode)((frame_control >> 14) & 0x3);

    // 802.15.4-2015 table 7-2; earlier versions carry a PAN with every address unless compressed
    bool dst_pan_present() const pure
    {
        WpanAddressMode dm = dst_mode, sm = src_mode;
        if (frame_version != 2)
            return dm != WpanAddressMode.none;
        if (dm == WpanAddressMode.none)
            return sm == WpanAddressMode.none && pan_compression;
        if (sm == WpanAddressMode.none || (dm == WpanAddressMode.extended && sm == WpanAddressMode.extended))
            return !pan_compression;
        return true;
    }

    bool src_pan_present() const pure
    {
        WpanAddressMode dm = dst_mode, sm = src_mode;
        if (sm == WpanAddressMode.none || pan_compression)
            return false;
        return !(frame_version == 2 && dm == WpanAddressMode.extended && sm == WpanAddressMode.extended);
    }

    // TODO: multipurpose, fragment and extended frames have their own header formats and are refused
    static bool has_general_header(ushort frame_control) pure
    {
        return (frame_control & 0x7) <= WpanFrameType.command && ((frame_control >> 12) & 0x3) != 3 &&
               ((frame_control >> 10) & 0x3) != 1 && ((frame_control >> 14) & 0x3) != 1;
    }

    size_t parse(const(ubyte)[] frame) pure
    {
        if (frame.length < 2)
            return 0;
        frame_control = frame[0 .. 2][0 .. 2].littleEndianToNative!ushort;
        if (!has_general_header(frame_control))
            return 0;
        size_t offset = seq_suppressed ? 2 : 3;
        if (frame.length < offset)
            return 0;

        dst_pan = wpan_broadcast_pan;
        dst = EUI64.init;
        src = EUI64.init;

        if (dst_pan_present && !read_pan(frame, offset, dst_pan))
            return 0;
        if (dst_mode != WpanAddressMode.none && !read_address(frame, offset, dst_mode, dst))
            return 0;
        // an elided source PAN is the destination's
        src_pan = src_mode != WpanAddressMode.none ? dst_pan : wpan_broadcast_pan;
        if (src_pan_present && !read_pan(frame, offset, src_pan))
            return 0;
        if (src_mode != WpanAddressMode.none && !read_address(frame, offset, src_mode, src))
            return 0;
        return offset;
    }

    // a universal address holds 48 bits: a short address under its PAN, or the low 48 of an extended one
    // TODO: EUI-64 does not fit the universal address; an OUI collision aliases two radios in an address table
    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ref const f = p.hdr!WpanFrame();
        ulong addr = universal(f.src, f.src_mode, f.src_pan);
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.wpan) << 60;
        return addr;
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ref const f = p.hdr!WpanFrame();
        ulong addr = universal(f.dst, f.dst_mode, f.dst_pan);
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.wpan) << 60;
        return addr;
    }

    static bool is_multicast(ulong address) pure nothrow @nogc
        => (address & 0xFFFF_FFFF_FFFF) == 0 || (address & 0xFFFF) == wpan_broadcast_short;

    // OW encapsulation wire codec: [fc:2 LE][rssi:1][lqi:1][dst_pan:2 LE][src_pan:2 LE][dst:8][src:8]
    enum ow_header_size = 24;

    static ptrdiff_t encode_ow_header(ref const Packet p, ubyte[] buffer) nothrow @nogc
    {
        if (buffer.length < ow_header_size)
            return -1;
        ref const f = p.hdr!WpanFrame;
        buffer[0 .. 2] = f.frame_control.nativeToLittleEndian;
        buffer[2] = cast(ubyte)f.rssi;
        buffer[3] = f.lqi;
        buffer[4 .. 6] = f.dst_pan.nativeToLittleEndian;
        buffer[6 .. 8] = f.src_pan.nativeToLittleEndian;
        buffer[8 .. 16] = f.dst.b[];
        buffer[16 .. 24] = f.src.b[];
        return ow_header_size;
    }

    static ptrdiff_t decode_ow_header(ref Packet p, const(ubyte)[] header) nothrow @nogc
    {
        if (header.length < ow_header_size)
            return -1;
        ushort frame_control = header[0 .. 2][0 .. 2].littleEndianToNative!ushort;
        if (!has_general_header(frame_control))
            return -1;
        p.type = PacketType.wpan;
        ref f = p.hdr!WpanFrame;
        f.frame_control = frame_control;
        f.rssi = cast(byte)header[2];
        f.lqi = header[3];
        f.dst_pan = header[4 .. 6][0 .. 2].littleEndianToNative!ushort;
        f.src_pan = header[6 .. 8][0 .. 2].littleEndianToNative!ushort;
        f.dst.b[] = header[8 .. 16];
        f.src.b[] = header[16 .. 24];
        return ow_header_size;
    }

private:
    static bool read_pan(const(ubyte)[] frame, ref size_t offset, ref ushort pan) pure
    {
        if (frame.length < offset + 2)
            return false;
        pan = frame[offset .. offset + 2][0 .. 2].littleEndianToNative!ushort;
        offset += 2;
        return true;
    }

    static bool read_address(const(ubyte)[] frame, ref size_t offset, WpanAddressMode mode, ref EUI64 addr) pure
    {
        if (mode == WpanAddressMode.short_)
        {
            if (frame.length < offset + 2)
                return false;
            addr.ul = frame[offset .. offset + 2][0 .. 2].littleEndianToNative!ushort;
            offset += 2;
            return true;
        }
        if (frame.length < offset + 8)
            return false;
        foreach (i; 0 .. 8)
            addr.b[i] = frame[offset + 7 - i];
        offset += 8;
        return true;
    }

    static ulong universal(ref const EUI64 addr, WpanAddressMode mode, ushort pan) pure
    {
        final switch (mode)
        {
            case WpanAddressMode.none:
                return 0;
            case WpanAddressMode.short_:
                return (ulong(pan) << 16) | (addr.ul & 0xFFFF);
            case WpanAddressMode.extended:
                return MACAddress(addr.b[2 .. 8]).ul;
        }
    }
}
static assert(WpanFrame.sizeof == 24);


abstract class WpanInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("channel",          channel,          "radio"),
                                 Prop!("tx-power",         tx_power,         "radio"),
                                 Prop!("pan-id",           pan_id,           "radio"),
                                 Prop!("short-address",    short_address,    "radio"),
                                 Prop!("extended-address", extended_address, "radio"),
                                 Prop!("promiscuous",      promiscuous,      "radio"));
nothrow @nogc:

    protected this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);
        _max_l2mtu = 125; // aMaxPhyPacketSize less the FCS; the MHR is inside it
        _l2mtu = _max_l2mtu;
    }

    final ubyte channel() const pure
        => _channel;
    final void channel(ubyte value)
    {
        if (_channel == value)
            return;
        _channel = value;
        mark_set!(typeof(this), "channel")();
        if (channel_valid)
            on_channel_changed(value);
        else
            restart();
    }

    final byte tx_power() const pure
        => _tx_power;
    final void tx_power(byte value)
    {
        if (_tx_power == value)
            return;
        _tx_power = value;
        mark_set!(typeof(this), "tx-power")();
        on_tx_power_changed(value);
    }

    final ushort pan_id() const pure
        => _pan_id;
    final void pan_id(ushort value)
    {
        if (_pan_id == value)
            return;
        _pan_id = value;
        mark_set!(typeof(this), "pan-id")();
        on_pan_id_changed(value);
    }

    final ushort short_address() const pure
        => _short_address;
    final void short_address(ushort value)
    {
        if (_short_address == value)
            return;
        _short_address = value;
        mark_set!(typeof(this), "short-address")();
        on_short_address_changed(value);
    }

    final EUI64 extended_address() const pure
        => _extended_address;
    final void extended_address(EUI64 value)
    {
        if (_extended_address == value)
            return;
        _extended_address = value;
        mark_set!(typeof(this), "extended-address")();
        restart();
    }

    final bool promiscuous() const pure
        => _promiscuous;
    final void promiscuous(bool value)
    {
        if (_promiscuous == value)
            return;
        _promiscuous = value;
        mark_set!(typeof(this), "promiscuous")();
        on_promiscuous_changed(value);
    }

protected:

    override bool validate() const
        => channel_valid && super.validate();

    override const(char)[] status_message() const
    {
        if (_channel == 0)
            return "channel is not set";
        if (!channel_valid)
            return "channel must be 11 to 26";
        return super.status_message();
    }

    // the driver reports the address it actually runs, which is the factory EUI-64 unless one was assigned
    final void adopt_extended_address(EUI64 value)
    {
        if (_extended_address == value)
            return;
        _extended_address = value;
        mark_set!(typeof(this), "extended-address")();
    }

    void on_channel_changed(ubyte channel) {}

    void on_tx_power_changed(byte power) {}

    void on_pan_id_changed(ushort pan_id) {}

    void on_short_address_changed(ushort address) {}

    void on_promiscuous_changed(bool enabled) {}

    final override ushort pcap_type() const
        => 230; // LINKTYPE_IEEE802_15_4_NOFCS

    final override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(scope const void[] packet_data) nothrow @nogc sink) const
    {
        if (packet.type == PacketType.wpan)
            sink(packet.data);
    }

private:
    EUI64 _extended_address;
    ushort _pan_id = wpan_broadcast_pan;
    ushort _short_address = wpan_no_short_address;
    ubyte _channel;
    byte _tx_power;
    bool _promiscuous;

    bool channel_valid() const pure
        => _channel >= 11 && _channel <= 26;
}


final class WpanInterfaceModule : Module
{
    mixin DeclareModule!"interface.wpan";
nothrow @nogc:

    override void init()
    {
        register_packet_codec!WpanFrame();
    }
}


unittest
{
    // data frame, v2006, pan compression, short dst + short src
    static immutable ubyte[9] short_frame = [0x41, 0x88, 0x2A, 0x34, 0x12, 0xFF, 0xFF, 0x01, 0x00];
    WpanFrame h;
    assert(h.parse(short_frame[]) == 9);
    assert(h.frame_type == WpanFrameType.data);
    assert(h.dst_pan == 0x1234 && h.src_pan == 0x1234);
    assert(h.dst_mode == WpanAddressMode.short_ && h.dst.ul == 0xFFFF);
    assert(h.src_mode == WpanAddressMode.short_ && h.src.ul == 0x0001);
    assert(h.parse(short_frame[0 .. 8]) == 0);

    // beacon request: command frame, short dst, no src
    static immutable ubyte[8] beacon_req = [0x03, 0x08, 0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0x07];
    assert(h.parse(beacon_req[]) == 7);
    assert(h.frame_type == WpanFrameType.command);
    assert(h.src_mode == WpanAddressMode.none && h.src_pan == wpan_broadcast_pan);

    // inter-PAN: the source is learned in its own PAN, not the destination's
    static immutable ubyte[11] inter_pan = [0x01, 0x98, 0x07, 0x34, 0x12, 0x02, 0x00, 0x78, 0x56, 0x01, 0x00];
    assert(h.parse(inter_pan[]) == 11);
    assert(h.dst_pan == 0x1234 && h.src_pan == 0x5678);
    Packet ip;
    ip.init!WpanFrame(inter_pan[]) = h;
    assert((WpanFrame.extract_src(ip) & 0xFFFF_FFFF_FFFF) == 0x5678_0001);
    assert((WpanFrame.extract_dst(ip) & 0xFFFF_FFFF_FFFF) == 0x1234_0002);

    // source only
    static immutable ubyte[7] src_only = [0x01, 0x90, 0x07, 0x78, 0x56, 0x01, 0x00];
    assert(h.parse(src_only[]) == 7);
    assert(h.dst_mode == WpanAddressMode.none && h.src_pan == 0x5678 && h.src.ul == 0x0001);

    // extended dst and src without compression: 2 + 1 + 2 + 8 + 2 + 8
    static immutable ubyte[23] ext_frame = [0x01, 0xCC, 0x07,
                                            0x34, 0x12, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
                                            0x78, 0x56, 0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11];
    assert(h.parse(ext_frame[]) == 23);
    assert(h.dst_pan == 0x1234 && h.src_pan == 0x5678);
    assert(h.dst == EUI64(0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08));
    assert(h.src == EUI64(0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18));

    Packet p;
    p.init!WpanFrame(ext_frame[]) = h;
    ubyte[32] wire = void;
    assert(WpanFrame.encode_ow_header(p, wire[]) == WpanFrame.ow_header_size);
    Packet q;
    assert(WpanFrame.decode_ow_header(q, wire[0 .. WpanFrame.ow_header_size]) == WpanFrame.ow_header_size);
    assert(q.hdr!WpanFrame.dst == h.dst && q.hdr!WpanFrame.frame_control == h.frame_control);
    assert(q.hdr!WpanFrame.src_pan == 0x5678);
    assert(WpanFrame.extract_dst(q) == WpanFrame.extract_dst(p));
    assert(WpanFrame.extract_src(q) == WpanFrame.extract_src(p));

    // 802.15.4-2015, table 7-2
    static immutable ubyte[5] v2_dst_compressed = [0x41, 0x28, 0x01, 0x34, 0x12];
    assert(h.parse(v2_dst_compressed[]) == 5);
    assert(h.dst.ul == 0x1234 && h.dst_pan == wpan_broadcast_pan);

    static immutable ubyte[2] v2_bare = [0x01, 0x21];
    assert(h.parse(v2_bare[]) == 2 && h.seq_suppressed);
    assert(h.parse(v2_bare[0 .. 1]) == 0);

    static immutable ubyte[5] v2_pan_only = [0x41, 0x20, 0x01, 0x34, 0x12];
    assert(h.parse(v2_pan_only[]) == 5);
    assert(h.dst_mode == WpanAddressMode.none && h.dst_pan == 0x1234);

    static immutable ubyte[21] v2_ext_ext = [0x01, 0xEC, 0x07, 0x34, 0x12,
                                             0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
                                             0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11];
    assert(h.parse(v2_ext_ext[]) == 21);
    assert(h.dst_pan == 0x1234 && h.src_pan == 0x1234);
    assert(h.src == EUI64(0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18));

    static immutable ubyte[19] v2_ext_ext_compressed = [0x41, 0xEC, 0x07,
                                                        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
                                                        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11];
    assert(h.parse(v2_ext_ext_compressed[]) == 19);
    assert(h.dst_pan == wpan_broadcast_pan);

    // the legacy seq-suppression bit is reserved: a v2006 frame still carries its sequence number
    static immutable ubyte[9] legacy_bit8 = [0x41, 0x89, 0x2A, 0x34, 0x12, 0xFF, 0xFF, 0x01, 0x00];
    assert(h.parse(legacy_bit8[]) == 9 && !h.seq_suppressed);

    // reserved address mode, reserved version and non-general frame types are refused at both ingress formats
    static immutable ubyte[13] reserved_mode = [0x01, 0x14, 0x07, 0x34, 0x12, 1, 2, 3, 4, 5, 6, 7, 8];
    assert(h.parse(reserved_mode[]) == 0);
    static immutable ubyte[13] reserved_version = [0x01, 0x38, 0x07, 0x34, 0x12, 1, 2, 3, 4, 5, 6, 7, 8];
    assert(h.parse(reserved_version[]) == 0);
    static immutable ubyte[13] multipurpose = [0x05, 0x08, 0x07, 0x34, 0x12, 1, 2, 3, 4, 5, 6, 7, 8];
    assert(h.parse(multipurpose[]) == 0);
    wire[0] = 0x01;
    wire[1] = 0x14;
    assert(WpanFrame.decode_ow_header(q, wire[0 .. WpanFrame.ow_header_size]) == -1);
}
