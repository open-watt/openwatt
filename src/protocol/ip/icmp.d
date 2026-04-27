module protocol.ip.icmp;

import urt.hash;
import urt.inet;

import router.iface.packet;

import protocol.ip.stack;

nothrow @nogc:


enum IcmpType : ubyte
{
    echo_reply        = 0,
    dest_unreachable  = 3,
    echo_request      = 8,
    time_exceeded     = 11,
    parameter_problem = 12,
}

enum IcmpDestUnreachableCode : ubyte
{
    net          = 0,
    host         = 1,
    protocol     = 2,
    port         = 3,
    frag_needed  = 4,       // next-hop MTU in low 16 bits of code_data
    admin_prohib = 13,
}


struct IcmpHeader
{
align(1):
    ubyte    type;
    ubyte    code;
    ubyte[2] checksum;
    // Type-specific 4 bytes follow:
    //   echo: ushort identifier; ushort sequence
    //   dest_unreachable / time_exceeded: ubyte[4] unused (then original IP header + 8 bytes)
}
static assert(IcmpHeader.sizeof == 4);


// Send an ICMP error in response to `original`. Body carries the original IP
// header + first 8 bytes of payload, per RFC 792. `code_data` populates the
// 4-byte rest-of-header (used for frag_needed PMTU; zero for the others).
//
// Suppresses errors for: multicast/broadcast original dst, ICMP-error replies
// (loop avoidance), non-zero fragment offsets.
void icmp_send_error(ref IPStack stack, ubyte type, ubyte code,
                     ref const Packet original, uint code_data = 0)
{
    if (original.data.length < IPv4Header.sizeof)
        return;
    const oip = cast(const IPv4Header*)original.data.ptr;

    // Don't reply to multicast/broadcast.
    if (is_multicast_v4(oip.dst) || oip.dst == IPAddr.broadcast)
        return;

    // Don't reply to non-first fragments (errors are only sensible for full datagrams).
    ushort frag = (ushort(oip.flags_frag[0]) << 8) | oip.flags_frag[1];
    if ((frag & 0x1FFF) != 0)
        return;

    size_t oip_hdr_len = oip.ihl * 4;

    // Don't reply to ICMP error messages (loop avoidance). Echo and other
    // queries are fine to error on.
    if (oip.protocol == IpProtocol.icmp)
    {
        if (original.data.length < oip_hdr_len + 1)
            return;
        ubyte oicmp_type = (cast(const(ubyte)*)original.data.ptr)[oip_hdr_len];
        if (is_icmp_error_type(oicmp_type))
            return;
    }

    IPAddr src = stack.select_source_v4(oip.src);
    if (src == IPAddr.any)
        return;     // we have no IP that can reach the original sender; can't reply

    enum size_t max_size = 1500;
    size_t orig_quote = oip_hdr_len + 8;
    if (original.data.length < orig_quote)
        orig_quote = original.data.length;
    size_t total = IPv4Header.sizeof + 8 + orig_quote;
    if (total > max_size)
        return;

    ubyte[max_size] buf = void;

    auto rip = cast(IPv4Header*)buf.ptr;
    rip.ver_ihl  = 0x45;
    rip.tos      = 0;
    rip.total_length[0] = cast(ubyte)(total >> 8);
    rip.total_length[1] = cast(ubyte)total;
    rip.ident[0] = 0;
    rip.ident[1] = 0;
    rip.flags_frag[0] = 0;
    rip.flags_frag[1] = 0;
    rip.ttl      = 64;
    rip.protocol = IpProtocol.icmp;
    rip.checksum[] = 0;
    rip.src = src;
    rip.dst = oip.src;
    ushort ihc = internet_checksum(buf[0 .. IPv4Header.sizeof]);
    rip.checksum[0] = cast(ubyte)(ihc >> 8);
    rip.checksum[1] = cast(ubyte)ihc;

    ubyte* icmp = buf.ptr + IPv4Header.sizeof;
    icmp[0] = type;
    icmp[1] = code;
    icmp[2] = 0;
    icmp[3] = 0;
    icmp[4] = cast(ubyte)(code_data >> 24);
    icmp[5] = cast(ubyte)(code_data >> 16);
    icmp[6] = cast(ubyte)(code_data >> 8);
    icmp[7] = cast(ubyte)code_data;
    icmp[8 .. 8 + orig_quote] = (cast(const(ubyte)*)original.data.ptr)[0 .. orig_quote];

    ushort cc = internet_checksum(buf[IPv4Header.sizeof .. total]);
    icmp[2] = cast(ubyte)(cc >> 8);
    icmp[3] = cast(ubyte)cc;

    Packet pkt;
    pkt.init!RawFrame(buf[0 .. total]);
    stack.output_v4(pkt);
}


// Process a locally-delivered ICMP datagram.
// pkt.data is the entire IP datagram (IPv4 header + ICMP message).
void icmp_input(ref IPStack stack, ref Packet pkt)
{
    if (pkt.data.length < IPv4Header.sizeof + IcmpHeader.sizeof)
        return;

    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t ip_hdr_len = ip.ihl * 4;
    if (pkt.data.length < ip_hdr_len + IcmpHeader.sizeof)
        return;

    const(ubyte)[] icmp = (cast(const(ubyte)*)pkt.data.ptr)[ip_hdr_len .. pkt.data.length];

    if (internet_checksum(icmp) != 0)
        return;     // bad ICMP checksum

    switch (icmp[0])
    {
        case IcmpType.echo_request:
            handle_echo_request(stack, pkt, ip_hdr_len);
            break;
        case IcmpType.echo_reply:
            // TODO: notify ping client (we don't have one yet)
            break;
        default:
            // TODO: dest_unreachable / time_exceeded -> notify upper layers
            break;
    }
}


private:

void handle_echo_request(ref IPStack stack, ref const Packet pkt, size_t ip_hdr_len)
{
    enum max_size = 1500;
    const(ubyte)[] datagram = (cast(const(ubyte)*)pkt.data.ptr)[0 .. pkt.data.length];
    if (datagram.length > max_size)
        return;

    ubyte[max_size] buf = void;
    buf[0 .. datagram.length] = datagram[];

    auto rip = cast(IPv4Header*)buf.ptr;
    IPAddr orig_dst = rip.dst;
    rip.dst = rip.src;
    rip.src = orig_dst;
    rip.ttl = 64;
    rip.checksum[] = 0;
    ushort ihc = internet_checksum(buf[0 .. ip_hdr_len]);
    rip.checksum[0] = cast(ubyte)(ihc >> 8);
    rip.checksum[1] = cast(ubyte)ihc;

    ubyte* icmp = buf.ptr + ip_hdr_len;
    icmp[0] = IcmpType.echo_reply;
    icmp[2] = 0;
    icmp[3] = 0;
    ushort cc = internet_checksum(buf[ip_hdr_len .. datagram.length]);
    icmp[2] = cast(ubyte)(cc >> 8);
    icmp[3] = cast(ubyte)cc;

    Packet reply;
    reply.init!RawFrame(buf[0 .. datagram.length]);
    stack.output_v4(reply);
}

bool is_multicast_v4(IPAddr ip) pure
    => (ip.b[0] & 0xF0) == 0xE0;     // 224.0.0.0/4

// RFC 1122 §3.2.2: types 3, 4, 5, 11, 12 are errors. 0/8 (echo), 13/14 (timestamp), etc., are queries.
bool is_icmp_error_type(ubyte type) pure
{
    switch (type)
    {
        case IcmpType.dest_unreachable:
        case 4:     // source quench (deprecated)
        case 5:     // redirect
        case IcmpType.time_exceeded:
        case IcmpType.parameter_problem:
            return true;
        default:
            return false;
    }
}
