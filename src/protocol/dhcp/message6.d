module protocol.dhcp.message6;

version (NoIPv6) {} else:

import urt.endian;
import urt.hash;
import urt.inet;
import urt.time;

import protocol.ip : IPv6Header, IPProtocol, load_ipv6_address, pseudo_header_checksum_v6, store_ipv6_address;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

nothrow @nogc:


enum ushort dhcp6_client_port = 546;
enum ushort dhcp6_server_port = 547;

// ff02::1:2, all DHCP relay agents and servers
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
    no_addrs_avail  = 2,
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
    const(ubyte)[] options;     // IAADDR / IAPREFIX / status sub-options
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

struct Dhcp6Build
{
nothrow @nogc:
    ubyte[dhcp6_build_buf_size] buf = void;
    size_t offset;

    enum size_t payload_start = IPv6Header.sizeof + UdpHeader.sizeof;

    void start(Dhcp6MsgType type, uint txid)
    {
        offset = payload_start;
        buf[offset++] = type;
        buf[offset++] = cast(ubyte)(txid >> 16);
        buf[offset++] = cast(ubyte)(txid >> 8);
        buf[offset++] = cast(ubyte)txid;
    }

    void add_option(Dhcp6Option code, const(ubyte)[] data)
    {
        buf[offset .. offset + 2] = nativeToBigEndian(ushort(code));
        buf[offset + 2 .. offset + 4] = nativeToBigEndian(cast(ushort)data.length);
        offset += 4;
        buf[offset .. offset + data.length] = data[];
        offset += data.length;
    }

    size_t begin_option(Dhcp6Option code)
    {
        buf[offset .. offset + 2] = nativeToBigEndian(ushort(code));
        buf[offset + 2 .. offset + 4] = 0;
        offset += 4;
        return offset;
    }

    void end_option(size_t body_start)
    {
        buf[body_start - 2 .. body_start] = nativeToBigEndian(cast(ushort)(offset - body_start));
    }

    void put_u32(uint v)
    {
        buf[offset .. offset + 4] = nativeToBigEndian(v);
        offset += 4;
    }

    void put_addr(IPv6Addr a)
    {
        store_ipv6_address(buf.ptr + offset, a);
        offset += 16;
    }

    size_t begin_ia(Dhcp6Option code, uint iaid, uint t1, uint t2)
    {
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
        buf[offset++] = prefix_len;
        put_addr(prefix);
        end_option(body_);
    }

    void add_status(Dhcp6Status status, const(char)[] message = null)
    {
        size_t body_ = begin_option(Dhcp6Option.status_code);
        buf[offset .. offset + 2] = nativeToBigEndian(ushort(status));
        offset += 2;
        buf[offset .. offset + message.length] = cast(const(ubyte)[])message[];
        offset += message.length;
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
            buf[offset .. offset + 2] = nativeToBigEndian(c);
            offset += 2;
        }
        end_option(body_);
    }

    void transmit(EthernetStation iface, IPv6Addr src, IPv6Addr dst, MACAddress eth_dst,
                  ushort src_port, ushort dst_port)
    {
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

        iface.send(eth_dst, frame, EtherType.ip6);
    }

private:
    struct UdpHeader
    {
    align(1):
        ubyte[2] src_port;
        ubyte[2] dst_port;
        ubyte[2] length;
        ubyte[2] checksum;
    }
}


struct Dhcp6Parse
{
nothrow @nogc:
    Dhcp6MsgType type;
    uint txid;
    const(ubyte)[] options;

    bool init(const(ubyte)[] payload)
    {
        if (payload.length < 4)
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
        while (opts.length >= 4)
        {
            ushort c = opts[0 .. 2].bigEndianToNative!ushort;
            ushort len = opts[2 .. 4].bigEndianToNative!ushort;
            if (4 + len > opts.length)
                return false;
            if (c == code)
            {
                value = opts[4 .. 4 + len];
                return true;
            }
            opts = opts[4 + len .. $];
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
        if (!find(code, v) || v.length < 12)
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
        if (!find_in(ia.options, Dhcp6Option.ia_addr, v) || v.length < 24)
            return false;
        r.addr = load_ipv6_address(v.ptr);
        r.preferred = v[16 .. 20].bigEndianToNative!uint;
        r.valid = v[20 .. 24].bigEndianToNative!uint;
        return true;
    }

    static bool ia_prefix(ref const Ia ia, out IaPrefix r)
    {
        const(ubyte)[] v;
        if (!find_in(ia.options, Dhcp6Option.ia_prefix, v) || v.length < 25)
            return false;
        r.preferred = v[0 .. 4].bigEndianToNative!uint;
        r.valid = v[4 .. 8].bigEndianToNative!uint;
        r.prefix_len = v[8];
        r.prefix = load_ipv6_address(v.ptr + 9);
        return true;
    }

    // a missing status option means success
    static Dhcp6Status status_of(const(ubyte)[] opts)
    {
        const(ubyte)[] v;
        if (!find_in(opts, Dhcp6Option.status_code, v) || v.length < 2)
            return Dhcp6Status.success;
        return cast(Dhcp6Status)v[0 .. 2].bigEndianToNative!ushort;
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
    assert(p.init(b.buf[Dhcp6Build.payload_start .. b.offset]));
    assert(p.type == Dhcp6MsgType.solicit && p.txid == 0x123456);
    assert(p.client_id() == duid[]);

    Ia pd;
    assert(p.ia(Dhcp6Option.ia_pd, pd) && pd.iaid == 1);
    IaPrefix ip;
    assert(Dhcp6Parse.ia_prefix(pd, ip));
    assert(ip.prefix == IPv6Addr(0xfd00, 6, 0, 0, 0, 0, 0, 0));
    assert(ip.prefix_len == 48 && ip.preferred == 300 && ip.valid == 600);
    assert(Dhcp6Parse.status_of(p.options) == Dhcp6Status.success);
}
