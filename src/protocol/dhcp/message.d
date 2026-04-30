module protocol.dhcp.message;

import urt.hash;
import urt.inet;
import urt.time;

import protocol.ip.stack : IPv4Header, IpProtocol;

import router.iface;
import router.iface.mac;
import router.iface.packet;

nothrow @nogc:


enum size_t DhcpMagicCookie = 0x63825363;
enum ushort DhcpClientPort = 68;
enum ushort DhcpServerPort = 67;

enum ubyte BootpRequest = 1;
enum ubyte BootpReply   = 2;

enum ubyte HType_Ethernet = 1;

enum DhcpMessageType : ubyte
{
    discover = 1,
    offer    = 2,
    request  = 3,
    decline  = 4,
    ack      = 5,
    nak      = 6,
    release  = 7,
    inform   = 8,
}

enum DhcpOption : ubyte
{
    pad                = 0,
    subnet_mask        = 1,
    router             = 3,
    dns                = 6,
    hostname           = 12,
    broadcast_address  = 28,
    requested_address  = 50,
    lease_time         = 51,
    message_type       = 53,
    server_id          = 54,
    parameter_list     = 55,
    message            = 56,
    renewal_time       = 58,
    rebinding_time     = 59,
    vendor_class_id    = 60,
    client_identifier  = 61,
    end                = 255,
}


struct UdpHeader
{
align(1):
    ubyte[2] src_port;
    ubyte[2] dst_port;
    ubyte[2] length;
    ubyte[2] checksum;
}
static assert(UdpHeader.sizeof == 8);

struct DhcpHeader
{
align(1):
    ubyte op;
    ubyte htype;
    ubyte hlen;
    ubyte hops;
    ubyte[4] xid;
    ubyte[2] secs;
    ubyte[2] flags;     // 0x8000 = broadcast
    ubyte[4] ciaddr;
    ubyte[4] yiaddr;
    ubyte[4] siaddr;
    ubyte[4] giaddr;
    ubyte[16] chaddr;
    ubyte[64] sname;
    ubyte[128] file;
    ubyte[4] magic;
}
static assert(DhcpHeader.sizeof == 240);


// Build buffer big enough for the BOOTP minimum (300 byte payload) plus IP+UDP.
enum size_t DhcpBuildBufSize = 590;

struct DhcpBuild
{
nothrow @nogc:
    ubyte[DhcpBuildBufSize] buf = void;
    size_t opt_offset;
    size_t total_len;     // populated by finish()

    // Initialise a BOOTP frame (op = BootpRequest or BootpReply).
    void start(ubyte op, MACAddress chaddr, uint xid, ushort secs, bool broadcast_flag)
    {
        buf[] = 0;
        auto h = cast(DhcpHeader*)(buf.ptr + IPv4Header.sizeof + UdpHeader.sizeof);
        h.op = op;
        h.htype = HType_Ethernet;
        h.hlen = 6;
        h.xid[0] = cast(ubyte)(xid >> 24);
        h.xid[1] = cast(ubyte)(xid >> 16);
        h.xid[2] = cast(ubyte)(xid >> 8);
        h.xid[3] = cast(ubyte)xid;
        h.secs[0] = cast(ubyte)(secs >> 8);
        h.secs[1] = cast(ubyte)secs;
        if (broadcast_flag)
            h.flags[0] = 0x80;
        h.chaddr[0 .. 6] = chaddr.b[];
        h.magic = [0x63, 0x82, 0x53, 0x63];
        opt_offset = IPv4Header.sizeof + UdpHeader.sizeof + DhcpHeader.sizeof;
    }

    // Mirror BOOTP fields server-side from the request: copies xid, secs, flags, giaddr, chaddr.
    void start_reply_from(ref const DhcpHeader req)
    {
        buf[] = 0;
        auto h = cast(DhcpHeader*)(buf.ptr + IPv4Header.sizeof + UdpHeader.sizeof);
        h.op = BootpReply;
        h.htype = HType_Ethernet;
        h.hlen = 6;
        h.xid = req.xid;
        h.flags = req.flags;
        h.giaddr = req.giaddr;
        h.chaddr = req.chaddr;
        h.magic = [0x63, 0x82, 0x53, 0x63];
        opt_offset = IPv4Header.sizeof + UdpHeader.sizeof + DhcpHeader.sizeof;
    }

    void set_ciaddr(IPAddr addr) { hdr().ciaddr = addr.b; }
    void set_yiaddr(IPAddr addr) { hdr().yiaddr = addr.b; }
    void set_siaddr(IPAddr addr) { hdr().siaddr = addr.b; }

    DhcpHeader* hdr()
        => cast(DhcpHeader*)(buf.ptr + IPv4Header.sizeof + UdpHeader.sizeof);

    void add_message_type(DhcpMessageType t)
    {
        buf[opt_offset++] = DhcpOption.message_type;
        buf[opt_offset++] = 1;
        buf[opt_offset++] = t;
    }

    void add_addr_option(DhcpOption opt, IPAddr addr)
    {
        buf[opt_offset++] = opt;
        buf[opt_offset++] = 4;
        buf[opt_offset .. opt_offset + 4] = addr.b[];
        opt_offset += 4;
    }

    // Generic option append: caller-supplied code and raw value bytes.
    // Returns false if the option wouldn't fit before the END marker is written.
    bool add_raw_option(ubyte code, const(ubyte)[] data)
    {
        if (data.length > 255)
            return false;
        // reserve 2 bytes (END + at least one pad slot is implicit) at the tail
        if (opt_offset + 2 + data.length > DhcpBuildBufSize - 1)
            return false;
        buf[opt_offset++] = code;
        buf[opt_offset++] = cast(ubyte)data.length;
        if (data.length > 0)
        {
            buf[opt_offset .. opt_offset + data.length] = data[];
            opt_offset += data.length;
        }
        return true;
    }

    void add_uint_option(DhcpOption opt, uint value)
    {
        buf[opt_offset++] = opt;
        buf[opt_offset++] = 4;
        buf[opt_offset++] = cast(ubyte)(value >> 24);
        buf[opt_offset++] = cast(ubyte)(value >> 16);
        buf[opt_offset++] = cast(ubyte)(value >> 8);
        buf[opt_offset++] = cast(ubyte)value;
    }

    void add_client_identifier(MACAddress mac)
    {
        buf[opt_offset++] = DhcpOption.client_identifier;
        buf[opt_offset++] = 7;
        buf[opt_offset++] = HType_Ethernet;
        buf[opt_offset .. opt_offset + 6] = mac.b[];
        opt_offset += 6;
    }

    void add_parameter_request_list()
    {
        static immutable ubyte[4] params = [
            DhcpOption.subnet_mask,
            DhcpOption.router,
            DhcpOption.dns,
            DhcpOption.lease_time,
        ];
        buf[opt_offset++] = DhcpOption.parameter_list;
        buf[opt_offset++] = params.length;
        buf[opt_offset .. opt_offset + params.length] = params[];
        opt_offset += params.length;
    }

    void add_string_option(DhcpOption opt, const(char)[] s)
    {
        size_t n = s.length > 255 ? 255 : s.length;
        buf[opt_offset++] = opt;
        buf[opt_offset++] = cast(ubyte)n;
        if (n > 0)
        {
            buf[opt_offset .. opt_offset + n] = cast(const(ubyte)[])s[0 .. n];
            opt_offset += n;
        }
    }

    void add_message(const(char)[] s)
    {
        size_t n = s.length > 255 ? 255 : s.length;
        buf[opt_offset++] = DhcpOption.message;
        buf[opt_offset++] = cast(ubyte)n;
        buf[opt_offset .. opt_offset + n] = cast(const(ubyte)[])s[0 .. n];
        opt_offset += n;
    }

    void finish()
    {
        buf[opt_offset++] = DhcpOption.end;

        // pad BOOTP payload to legacy minimum (300 bytes) so picky clients/servers don't ignore us
        size_t dhcp_payload = opt_offset - (IPv4Header.sizeof + UdpHeader.sizeof);
        enum size_t min_dhcp_payload = 300;
        if (dhcp_payload < min_dhcp_payload)
        {
            size_t pad = min_dhcp_payload - dhcp_payload;
            buf[opt_offset .. opt_offset + pad] = 0;
            opt_offset += pad;
        }
        total_len = opt_offset;
    }

    // Frame the IP+UDP+DHCP payload and hand it to the interface for transmission.
    // src_port/dst_port choose the BOOTP direction (server -> client uses 67->68).
    void transmit(BaseInterface iface, IPAddr src, IPAddr dst, MACAddress eth_dst, ushort src_port, ushort dst_port)
    {
        ubyte[] frame = buf[0 .. total_len];
        size_t udp_len = total_len - IPv4Header.sizeof;
        size_t ip_total = total_len;

        auto ip = cast(IPv4Header*)frame.ptr;
        ip.ver_ihl = 0x45;
        ip.tos = 0;
        ip.total_length[0] = cast(ubyte)(ip_total >> 8);
        ip.total_length[1] = cast(ubyte)ip_total;
        ip.ident[0] = 0;
        ip.ident[1] = 0;
        ip.flags_frag[0] = 0;
        ip.flags_frag[1] = 0;
        ip.ttl = 64;
        ip.protocol = IpProtocol.udp;
        ip.checksum[] = 0;
        ip.src = src;
        ip.dst = dst;
        ushort ihc = internet_checksum(frame[0 .. IPv4Header.sizeof]);
        ip.checksum[0] = cast(ubyte)(ihc >> 8);
        ip.checksum[1] = cast(ubyte)ihc;

        auto u = cast(UdpHeader*)(frame.ptr + IPv4Header.sizeof);
        u.src_port[0] = cast(ubyte)(src_port >> 8);
        u.src_port[1] = cast(ubyte)src_port;
        u.dst_port[0] = cast(ubyte)(dst_port >> 8);
        u.dst_port[1] = cast(ubyte)dst_port;
        u.length[0] = cast(ubyte)(udp_len >> 8);
        u.length[1] = cast(ubyte)udp_len;
        u.checksum[] = 0;
        ushort pseudo = pseudo_header_checksum(src, dst, IpProtocol.udp, cast(ushort)udp_len);
        ushort cc = internet_checksum(frame[IPv4Header.sizeof .. total_len], pseudo);
        if (cc == 0)
            cc = 0xFFFF;
        u.checksum[0] = cast(ubyte)(cc >> 8);
        u.checksum[1] = cast(ubyte)cc;

        iface.send(eth_dst, frame, EtherType.ip4);
    }
}


struct DhcpParse
{
nothrow @nogc:
    const(ubyte)[] options;

    bool find(ubyte code, out const(ubyte)[] value)
    {
        size_t i = 0;
        while (i < options.length)
        {
            ubyte c = options[i++];
            if (c == DhcpOption.end)
                return false;
            if (c == DhcpOption.pad)
                continue;
            if (i >= options.length)
                return false;
            ubyte len = options[i++];
            if (i + len > options.length)
                return false;
            if (c == code)
            {
                value = options[i .. i + len];
                return true;
            }
            i += len;
        }
        return false;
    }

    bool message_type(out DhcpMessageType t)
    {
        const(ubyte)[] v;
        if (!find(DhcpOption.message_type, v) || v.length != 1)
            return false;
        t = cast(DhcpMessageType)v[0];
        return true;
    }

    bool addr_option(DhcpOption opt, out IPAddr addr)
    {
        const(ubyte)[] v;
        if (!find(opt, v) || v.length < 4)
            return false;
        addr.b = v[0 .. 4];
        return true;
    }

    bool server_id(out IPAddr a) { return addr_option(DhcpOption.server_id, a); }
    bool subnet_mask(out IPAddr a) { return addr_option(DhcpOption.subnet_mask, a); }
    bool router(out IPAddr a) { return addr_option(DhcpOption.router, a); }
    bool requested_address(out IPAddr a) { return addr_option(DhcpOption.requested_address, a); }

    bool uint_option(DhcpOption opt, out uint value)
    {
        const(ubyte)[] v;
        if (!find(opt, v) || v.length != 4)
            return false;
        value = (uint(v[0]) << 24) | (uint(v[1]) << 16) | (uint(v[2]) << 8) | v[3];
        return true;
    }

    bool lease_time(out Duration d)
    {
        uint s;
        if (!uint_option(DhcpOption.lease_time, s)) return false;
        d = s.seconds;
        return true;
    }

    bool renewal_time(out Duration d)
    {
        uint s;
        if (!uint_option(DhcpOption.renewal_time, s)) return false;
        d = s.seconds;
        return true;
    }

    bool rebinding_time(out Duration d)
    {
        uint s;
        if (!uint_option(DhcpOption.rebinding_time, s)) return false;
        d = s.seconds;
        return true;
    }

    const(char)[] hostname()
    {
        const(ubyte)[] v;
        if (!find(DhcpOption.hostname, v))
            return null;
        return cast(const(char)[])v;
    }

    const(ubyte)[] client_identifier()
    {
        const(ubyte)[] v;
        find(DhcpOption.client_identifier, v);
        return v;
    }
}


ushort pseudo_header_checksum(IPAddr src, IPAddr dst, ubyte protocol, ushort transport_length) pure
{
    ubyte[12] ph = void;
    ph[0..4]  = src.b[];
    ph[4..8]  = dst.b[];
    ph[8]     = 0;
    ph[9]     = protocol;
    ph[10]    = cast(ubyte)(transport_length >> 8);
    ph[11]    = cast(ubyte)transport_length;
    return internet_checksum(ph[]);
}

ubyte subnet_prefix_len(IPAddr mask) pure
{
    uint m = (uint(mask.b[0]) << 24) | (uint(mask.b[1]) << 16) | (uint(mask.b[2]) << 8) | mask.b[3];
    ubyte n = 0;
    while ((m & 0x80000000) && n < 32)
    {
        ++n;
        m <<= 1;
    }
    return n;
}

IPAddr prefix_to_mask(ubyte prefix_len) pure
{
    IPAddr r;
    if (prefix_len == 0)
        return r;
    if (prefix_len > 32)
        prefix_len = 32;
    uint m = 0xFFFFFFFFU << (32 - prefix_len);
    r.b[0] = cast(ubyte)(m >> 24);
    r.b[1] = cast(ubyte)(m >> 16);
    r.b[2] = cast(ubyte)(m >> 8);
    r.b[3] = cast(ubyte)m;
    return r;
}
