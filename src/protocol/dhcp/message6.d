module protocol.dhcp.message6;

version (NoIPv6) {} else:

import urt.endian;
import urt.hash;
import urt.inet;

import protocol.ip : IPv6Header, IPProtocol, pseudo_header_checksum_v6;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

nothrow @nogc:


enum ushort dhcp6_client_port = 546;
enum ushort dhcp6_server_port = 547;

enum IPv6Addr dhcp6_multicast = IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 1, 2);

enum Dhcp6MsgType : ubyte
{
    solicit      = 1,
    advertise    = 2,
    request      = 3,
    confirm      = 4,
    renew        = 5,
    rebind       = 6,
    reply        = 7,
    release_     = 8,
    decline      = 9,
    reconfigure  = 10,
    info_request = 11,
}

enum Dhcp6Option : ushort
{
    client_id    = 1,
    server_id    = 2,
    ia_na        = 3,
    ia_ta        = 4,
    ia_addr      = 5,
    oro          = 6,
    preference   = 7,
    elapsed_time = 8,
    status_code  = 13,
    rapid_commit = 14,
    dns_servers  = 23,
    ia_pd        = 25,
    ia_prefix    = 26,
}

enum Dhcp6Status : ushort
{
    success         = 0,
    unspec_fail     = 1,
    no_addrs_avail   = 2,
    no_binding      = 3,
    not_on_link     = 4,
    use_multicast   = 5,
    no_prefix_avail = 6,
}


// DUID-LL (RFC 8415 11.4): type 3, hardware type 1 (ethernet), MAC.
enum size_t duid_ll_size = 10;
enum size_t max_duid_size = 130;

ubyte[duid_ll_size] duid_ll(MACAddress mac) pure
{
    ubyte[duid_ll_size] d;
    d[0] = 0;
    d[1] = 3;
    d[2] = 0;
    d[3] = 1;
    d[4 .. 10] = mac.b[];
    return d;
}


struct Ia
{
    uint iaid;
    uint t1;
    uint t2;
    const(ubyte)[] options;
}

struct IaAddr
{
    IPv6Addr addr;
    uint preferred;
    uint valid;
}

struct IaPrefix
{
    IPv6Addr prefix;
    ubyte prefix_len;
    uint preferred;
    uint valid;
}


enum size_t dhcp6_build_buf_size = 1280;
static assert(dhcp6_build_buf_size <= ushort.max);

struct Dhcp6Build
{
nothrow @nogc:
    enum size_t payload_start = IPv6Header.sizeof + UdpHeader.sizeof;

    bool complete() const pure => !failed && open_option == 0;
    const(ubyte)[] payload() const pure => complete ? buf[payload_start .. offset] : null;

    void start(Dhcp6MsgType type, uint txid)
    {
        failed = type < Dhcp6MsgType.solicit || type > Dhcp6MsgType.info_request;
        open_option = 0;
        offset = payload_start;
        if (failed)
            return;
        buf[offset++] = type;
        buf[offset++] = cast(ubyte)(txid >> 16);
        buf[offset++] = cast(ubyte)(txid >> 8);
        buf[offset++] = cast(ubyte)txid;
    }

    void add_option(Dhcp6Option code, const(ubyte)[] data)
    {
        size_t body_ = begin_option(code);
        put(data);
        end_option(body_);
    }

    size_t begin_option(Dhcp6Option code)
    {
        if (!reserve(4))
            return 0;
        buf[offset .. offset + 2] = nativeToBigEndian(ushort(code));
        // Until closed, the length field links to the enclosing option.
        buf[offset + 2 .. offset + 4] = nativeToBigEndian(cast(ushort)open_option);
        offset += 4;
        open_option = offset;
        return offset;
    }

    void end_option(size_t body_start)
    {
        if (failed)
            return;
        if (!open_option || body_start != open_option)
        {
            failed = true;
            return;
        }
        open_option = buf[body_start - 2 .. body_start][0 .. 2].bigEndianToNative!ushort;
        buf[body_start - 2 .. body_start] = nativeToBigEndian(cast(ushort)(offset - body_start));
    }

    void put_u32(uint v)
    {
        if (!reserve(4))
            return;
        buf[offset .. offset + 4] = nativeToBigEndian(v);
        offset += 4;
    }

    void put_addr(IPv6Addr a)
    {
        if (!reserve(16))
            return;
        foreach (i; 0 .. 8)
            buf[offset + i * 2 .. offset + i * 2 + 2] = nativeToBigEndian(a.s[i]);
        offset += 16;
    }

    size_t begin_ia(Dhcp6Option code, uint iaid, uint t1, uint t2)
    {
        if (code != Dhcp6Option.ia_na && code != Dhcp6Option.ia_pd)
        {
            failed = true;
            return 0;
        }
        size_t body_ = begin_option(code);
        put_u32(iaid);
        put_u32(t1);
        put_u32(t2);
        return body_;
    }

    void add_ia_addr(IPv6Addr addr, uint preferred, uint valid)
    {
        size_t body_ = begin_option(Dhcp6Option.ia_addr);
        put_addr(addr);
        put_u32(preferred);
        put_u32(valid);
        end_option(body_);
    }

    void add_ia_prefix(IPv6Addr prefix, ubyte prefix_len, uint preferred, uint valid)
    {
        size_t body_ = begin_option(Dhcp6Option.ia_prefix);
        put_u32(preferred);
        put_u32(valid);
        if (reserve(1))
            buf[offset++] = prefix_len;
        put_addr(prefix);
        end_option(body_);
    }

    void add_status(Dhcp6Status status, const(char)[] message = null)
    {
        size_t body_ = begin_option(Dhcp6Option.status_code);
        ubyte[2] value = nativeToBigEndian(ushort(status));
        put(value[]);
        put(cast(const(ubyte)[])message);
        end_option(body_);
    }

    void add_elapsed_time(ushort centiseconds)
    {
        ubyte[2] v = nativeToBigEndian(centiseconds);
        add_option(Dhcp6Option.elapsed_time, v[]);
    }

    void add_oro(const(ushort)[] codes...)
    {
        size_t body_ = begin_option(Dhcp6Option.oro);
        foreach (c; codes)
        {
            ubyte[2] value = nativeToBigEndian(c);
            put(value[]);
        }
        end_option(body_);
    }

    bool transmit(EthernetStation iface, IPv6Addr src, IPv6Addr dst, MACAddress eth_dst, ushort src_port, ushort dst_port)
    {
        if (!complete)
            return false;
        ubyte[] frame = buf[0 .. offset];
        size_t udp_len = offset - IPv6Header.sizeof;

        auto ip = cast(IPv6Header*)frame.ptr;
        ip.ver_tc_flow[] = 0;
        ip.ver_tc_flow[0] = 0x60;
        ip.payload_length = nativeToBigEndian(cast(ushort)udp_len);
        ip.next_header = IPProtocol.udp;
        ip.hop_limit = dst.is_multicast ? 1 : 64;
        ip.src_addr = src;
        ip.dst_addr = dst;

        auto u = cast(UdpHeader*)(frame.ptr + IPv6Header.sizeof);
        u.src_port = nativeToBigEndian(src_port);
        u.dst_port = nativeToBigEndian(dst_port);
        u.length = nativeToBigEndian(cast(ushort)udp_len);
        u.checksum[] = 0;
        ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)udp_len, IPProtocol.udp);
        ushort cc = internet_checksum(frame[IPv6Header.sizeof .. $], pseudo);
        if (cc == 0)
            cc = 0xFFFF;
        u.checksum = nativeToBigEndian(cc);

        return iface.send(eth_dst, frame, EtherType.ip6) >= 0;
    }

private:
    align(uint.sizeof) ubyte[dhcp6_build_buf_size] buf = void;
    ushort offset;
    ushort open_option;
    bool failed = true;

    bool reserve(size_t count)
    {
        if (failed)
            return false;
        if (count > buf.length - offset)
        {
            failed = true;
            return false;
        }
        return true;
    }

    void put(const(ubyte)[] data)
    {
        if (!reserve(data.length))
            return;
        buf[offset .. offset + data.length] = data[];
        offset += data.length;
    }

    struct UdpHeader
    {
    align(1):
        ubyte[2] src_port;
        ubyte[2] dst_port;
        ubyte[2] length;
        ubyte[2] checksum;
    }
}


struct Dhcp6Options
{
nothrow @nogc:
    this(const(ubyte)[] options)
    {
        _valid = well_formed(options);
        if (_valid)
            _remaining = options;
    }

    bool valid() const pure => _valid;

    bool next(out Dhcp6Option code, out const(ubyte)[] value)
    {
        if (!_remaining.length)
            return false;
        code = cast(Dhcp6Option)_remaining[0 .. 2].bigEndianToNative!ushort;
        size_t length = _remaining[2 .. 4].bigEndianToNative!ushort;
        value = _remaining[4 .. 4 + length];
        _remaining = _remaining[4 + length .. $];
        return true;
    }

    static bool well_formed(const(ubyte)[] options) pure
    {
        while (options.length)
        {
            if (options.length < 4)
                return false;
            ushort code = options[0 .. 2].bigEndianToNative!ushort;
            size_t length = options[2 .. 4].bigEndianToNative!ushort;
            if (length > options.length - 4 || (code == Dhcp6Option.status_code && length < 2))
                return false;
            options = options[4 + length .. $];
        }
        return true;
    }

private:
    const(ubyte)[] _remaining;
    bool _valid;
}


struct Dhcp6Parse
{
nothrow @nogc:
    Dhcp6MsgType type;
    uint txid;
    const(ubyte)[] options;

    bool init(const(ubyte)[] payload)
    {
        this = Dhcp6Parse();
        if (payload.length < 4 || payload[0] < Dhcp6MsgType.solicit || payload[0] > Dhcp6MsgType.info_request)
            return false;
        if (!Dhcp6Options.well_formed(payload[4 .. $]))
            return false;
        type = cast(Dhcp6MsgType)payload[0];
        txid = (uint(payload[1]) << 16) | (uint(payload[2]) << 8) | payload[3];
        options = payload[4 .. $];
        return true;
    }

    bool find(Dhcp6Option code, out const(ubyte)[] value) const
        => find_in(options, code, value);

    static bool find_in(const(ubyte)[] opts, Dhcp6Option code, out const(ubyte)[] value)
    {
        auto options = Dhcp6Options(opts);
        Dhcp6Option current;
        const(ubyte)[] body_;
        while (options.next(current, body_))
        {
            if (current == code)
            {
                value = body_;
                return true;
            }
        }
        return false;
    }

    const(ubyte)[] client_id() const
    {
        const(ubyte)[] v;
        find(Dhcp6Option.client_id, v);
        return v;
    }

    const(ubyte)[] server_id() const
    {
        const(ubyte)[] v;
        find(Dhcp6Option.server_id, v);
        return v;
    }

    bool ia(Dhcp6Option code, out Ia r) const
    {
        const(ubyte)[] v;
        return find(code, v) && parse_ia(code, v, r);
    }

    static bool parse_ia(Dhcp6Option code, const(ubyte)[] v, out Ia r)
    {
        if ((code != Dhcp6Option.ia_na && code != Dhcp6Option.ia_pd) || v.length < 12 || !Dhcp6Options.well_formed(v[12 .. $]))
            return false;
        r.iaid = v[0 .. 4].bigEndianToNative!uint;
        r.t1 = v[4 .. 8].bigEndianToNative!uint;
        r.t2 = v[8 .. 12].bigEndianToNative!uint;
        r.options = v[12 .. $];
        return true;
    }

    static bool ia_addr(ref const Ia ia, out IaAddr r)
    {
        const(ubyte)[] v;
        return find_in(ia.options, Dhcp6Option.ia_addr, v) && parse_ia_addr(v, r);
    }

    static bool parse_ia_addr(const(ubyte)[] v, out IaAddr r)
    {
        if (v.length < 24 || !Dhcp6Options.well_formed(v[24 .. $]))
            return false;
        foreach (i; 0 .. 8)
            r.addr.s[i] = v[i * 2 .. i * 2 + 2][0 .. 2].bigEndianToNative!ushort;
        r.preferred = v[16 .. 20].bigEndianToNative!uint;
        r.valid = v[20 .. 24].bigEndianToNative!uint;
        return true;
    }

    static bool ia_prefix(ref const Ia ia, out IaPrefix r)
    {
        const(ubyte)[] v;
        return find_in(ia.options, Dhcp6Option.ia_prefix, v) && parse_ia_prefix(v, r);
    }

    static bool parse_ia_prefix(const(ubyte)[] v, out IaPrefix r)
    {
        if (v.length < 25 || v[8] > 128 || !Dhcp6Options.well_formed(v[25 .. $]))
            return false;
        r.preferred = v[0 .. 4].bigEndianToNative!uint;
        r.valid = v[4 .. 8].bigEndianToNative!uint;
        r.prefix_len = v[8];
        foreach (i; 0 .. 8)
            r.prefix.s[i] = v[9 + i * 2 .. 11 + i * 2][0 .. 2].bigEndianToNative!ushort;
        return true;
    }

    static bool status_of(const(ubyte)[] opts, out Dhcp6Status status)
    {
        status = Dhcp6Status.success;
        if (!Dhcp6Options.well_formed(opts))
            return false;
        const(ubyte)[] v;
        if (find_in(opts, Dhcp6Option.status_code, v))
            status = cast(Dhcp6Status)v[0 .. 2].bigEndianToNative!ushort;
        return true;
    }
}


unittest
{
    Dhcp6Build b;
    b.start(Dhcp6MsgType.solicit, 0x123456);
    ubyte[10] duid = duid_ll(MACAddress(1, 2, 3, 4, 5, 6));
    b.add_option(Dhcp6Option.client_id, duid[]);
    size_t ia = b.begin_ia(Dhcp6Option.ia_pd, 1, 0, 0);
    b.add_ia_prefix(IPv6Addr(0xfd00, 6, 0, 0, 0, 0, 0, 0), 48, 300, 600);
    b.end_option(ia);
    b.add_elapsed_time(0);

    Dhcp6Parse p;
    assert(b.complete && p.init(b.payload));
    assert(p.type == Dhcp6MsgType.solicit && p.txid == 0x123456);
    assert(p.client_id() == duid[]);

    Ia pd;
    assert(p.ia(Dhcp6Option.ia_pd, pd) && pd.iaid == 1);
    IaPrefix ip;
    assert(Dhcp6Parse.ia_prefix(pd, ip));
    assert(ip.prefix == IPv6Addr(0xfd00, 6, 0, 0, 0, 0, 0, 0));
    assert(ip.prefix_len == 48 && ip.preferred == 300 && ip.valid == 600);
    Dhcp6Status status;
    assert(Dhcp6Parse.status_of(p.options, status) && status == Dhcp6Status.success);
}


unittest
{
    Dhcp6Build b;
    assert(!b.complete && b.payload.length == 0);
    b.put_addr(IPv6Addr.loopback);
    assert(b.failed && b.offset == 0);

    ubyte[dhcp6_build_buf_size] data;
    enum capacity = dhcp6_build_buf_size - Dhcp6Build.payload_start - 8;
    b.start(Dhcp6MsgType.reply, 1);
    b.add_option(Dhcp6Option.server_id, data[0 .. capacity]);
    assert(b.complete && b.offset == dhcp6_build_buf_size);
    auto saved = b.buf;
    b.put_addr(IPv6Addr.loopback);
    b.put_u32(1);
    b.add_option(Dhcp6Option.rapid_commit, null);
    assert(!b.complete && b.payload.length == 0 && b.buf == saved);
    assert(!b.transmit(null, IPv6Addr.any, IPv6Addr.any, MACAddress.init, 546, 547));

    b.start(Dhcp6MsgType.reply, 2);
    b.add_option(Dhcp6Option.server_id, data[0 .. capacity + 1]);
    assert(!b.complete && b.offset <= dhcp6_build_buf_size);
    b.start(Dhcp6MsgType.reply, 3);
    b.add_status(Dhcp6Status.unspec_fail, cast(const(char)[])data[]);
    assert(!b.complete && b.offset <= dhcp6_build_buf_size);

    b.start(Dhcp6MsgType.reply, 4);
    size_t outer = b.begin_ia(Dhcp6Option.ia_na, 1, 0, 0);
    size_t inner = b.begin_option(Dhcp6Option.ia_addr);
    assert(!b.complete && b.payload.length == 0);
    assert(!b.transmit(null, IPv6Addr.any, IPv6Addr.any, MACAddress.init, 546, 547));
    b.end_option(outer);
    b.end_option(inner);
    assert(b.failed);

    foreach (size_t invalid; [size_t(0), size_t(1), size_t.max])
    {
        b.start(Dhcp6MsgType.reply, 5);
        b.end_option(invalid);
        assert(b.failed);
    }
    b.start(Dhcp6MsgType.reply, 6);
    outer = b.begin_ia(Dhcp6Option.ia_na, 1, 0, 0);
    b.add_ia_addr(IPv6Addr.loopback, 30, 60);
    b.end_option(outer);
    assert(b.complete);
    b.end_option(outer);
    assert(b.failed);

    b.start(Dhcp6MsgType.reply, 7);
    b.add_option(Dhcp6Option.server_id, data[0 .. 1]);
    outer = b.begin_ia(Dhcp6Option.ia_pd, 1, 0, 0);
    IPv6Addr prefix = IPv6Addr(0x2001, 0xdb8, 0x1234, 0x5600, 0, 0, 0, 0);
    b.add_ia_prefix(prefix, 56, 30, 60);
    b.end_option(outer);
    assert(b.complete);
    Dhcp6Parse parsed;
    Ia ia;
    IaPrefix result;
    assert(parsed.init(b.payload) && parsed.ia(Dhcp6Option.ia_pd, ia));
    assert(Dhcp6Parse.ia_prefix(ia, result) && result.prefix == prefix && result.prefix_len == 56);
}


unittest
{
    import urt.encoding : HexDecode;

    static immutable repeated_ias = HexDecode!"071234560003000c000000010000000a000000140003000c000000020000001e0000003c";
    Dhcp6Parse p;
    assert(p.init(repeated_ias[]) && p.txid == 0x123456);
    auto options = Dhcp6Options(p.options);
    assert(options.valid);
    Dhcp6Option code;
    const(ubyte)[] body_;
    Ia ia;
    assert(options.next(code, body_) && Dhcp6Parse.parse_ia(code, body_, ia) && ia.iaid == 1 && ia.t1 == 10 && ia.t2 == 20);
    assert(options.next(code, body_) && Dhcp6Parse.parse_ia(code, body_, ia) && ia.iaid == 2 && ia.t1 == 30 && ia.t2 == 60);
    assert(!options.next(code, body_));

    static immutable repeated_addresses = HexDecode!(
        "00050018000000000000000000000000000000010000001e0000003c"
        ~ "00050018000000000000000000000000000000020000002800000050");
    options = Dhcp6Options(repeated_addresses[]);
    IaAddr addr;
    assert(options.next(code, body_) && code == Dhcp6Option.ia_addr && Dhcp6Parse.parse_ia_addr(body_, addr));
    assert(addr.addr == IPv6Addr.loopback && addr.preferred == 30 && addr.valid == 60);
    assert(options.next(code, body_) && Dhcp6Parse.parse_ia_addr(body_, addr));
    assert(addr.addr == IPv6Addr(0, 0, 0, 0, 0, 0, 0, 2) && addr.preferred == 40 && addr.valid == 80);
    assert(!options.next(code, body_));

    static immutable truncated = HexDecode!"0712345600010001aa00";
    assert(!p.init(truncated[]) && p.options.length == 0);
    assert(!Dhcp6Parse.find_in(truncated[4 .. $], Dhcp6Option.client_id, body_) && body_.length == 0);
    options = Dhcp6Options(truncated[4 .. $]);
    assert(!options.valid && !options.next(code, body_));
    Dhcp6Status status;
    assert(!Dhcp6Parse.status_of(truncated[4 .. $], status));
    static immutable short_status = HexDecode!"000d0001ff";
    static immutable broken_tail = HexDecode!"000d000200000001ffff";
    static immutable failure_status = HexDecode!"000d00020001";
    static immutable broken_ia = HexDecode!"000000010000000000000000ff";
    static immutable na_header = HexDecode!"000000010000000000000000";
    assert(!Dhcp6Parse.status_of(short_status[], status));
    assert(!Dhcp6Parse.status_of(broken_tail[], status));
    assert(Dhcp6Parse.status_of(null, status) && status == Dhcp6Status.success);
    assert(Dhcp6Parse.status_of(failure_status[], status) && status == Dhcp6Status.unspec_fail);
    assert(!Dhcp6Parse.parse_ia(Dhcp6Option.ia_na, broken_ia[], ia));
    assert(!Dhcp6Parse.parse_ia(Dhcp6Option.ia_ta, na_header[], ia));

    ubyte[4] header = [0, 0, 0, 1];
    foreach (ubyte type; [ubyte(0), ubyte(12), ubyte(13), ubyte(255)])
    {
        header[0] = type;
        assert(!p.init(header[]));
        Dhcp6Build b;
        b.start(cast(Dhcp6MsgType)type, 1);
        assert(!b.complete);
    }
    Dhcp6Build b;
    b.start(Dhcp6MsgType.reply, 1);
    b.begin_ia(Dhcp6Option.ia_ta, 1, 0, 0);
    assert(!b.complete);
}
