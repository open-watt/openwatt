module protocol.ip.icmp;

version (UseInternalIPStack):

import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.mem.temp : talloc;
import urt.time;

import router.iface.packet;

import protocol.ip : IPv4Header, IPProtocol;
import protocol.ip.stack;

//version = DebugICMP;

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
void icmp_send_error(ref IPStack stack, ubyte type, ubyte code, ref const Packet original, uint code_data = 0)
{
    if (original.data.length < IPv4Header.sizeof)
        return;
    const oip = cast(const IPv4Header*)original.data.ptr;

    // Don't reply to multicast/broadcast.
    IPAddr oip_dst = IPAddr(oip.dst);
    if (is_multicast_v4(oip_dst) || oip_dst == IPAddr.broadcast)
    {
        version (DebugICMP)
            write_log(Severity.debug_, "icmp", null, "suppress error type=", type, " code=", code, " (orig dst=", oip_dst, " is mcast/bcast)");
        return;
    }

    // Don't reply to non-first fragments (errors are only sensible for full datagrams).
    ushort frag = oip.flags_frag.bigEndianToNative!ushort;
    if ((frag & 0x1FFF) != 0)
        return;

    size_t oip_hdr_len = oip.ihl * 4;

    // Don't reply to ICMP error messages (loop avoidance). Echo and other
    // queries are fine to error on.
    if (oip.protocol == IPProtocol.icmp)
    {
        if (original.data.length < oip_hdr_len + 1)
            return;
        ubyte oicmp_type = (cast(const(ubyte)*)original.data.ptr)[oip_hdr_len];
        if (is_icmp_error_type(oicmp_type))
            return;
    }

    // RFC 1812 §4.3.2.8: rate-limit error generation per type.
    if (auto rl = rate_limiter_for(type))
    {
        if (!rl.consume(getTime()))
        {
            version (DebugICMP)
                write_log(Severity.trace, "icmp", null, "rate-limit drop type=", type, " code=", code);
            return;
        }
    }

    IPAddr oip_src = IPAddr(oip.src);
    IPAddr src = stack.select_source_v4(oip_src);
    if (src == IPAddr.any)
    {
        version (DebugICMP)
            write_log(Severity.debug_, "icmp", null, "suppress error type=", type, " code=", code, " (no source addr for ", oip_src, ")");
        return;     // we have no IP that can reach the original sender; can't reply
    }

    version (DebugICMP)
        write_log(Severity.debug_, "icmp", null, "tx error type=", type, " code=", code, " src=", src, " dst=", oip_src, " (orig proto=", oip.protocol, " orig dst=", oip_dst, ")");

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
    rip.total_length = nativeToBigEndian(cast(ushort)total);
    ushort ip_id = next_ip_id();
    rip.ident = nativeToBigEndian(ip_id);
    rip.flags_frag[0] = 0;
    rip.flags_frag[1] = 0;
    rip.ttl      = 64;
    rip.protocol = IPProtocol.icmp;
    rip.checksum[] = 0;
    rip.src = src.b;
    rip.dst = oip_src.b;
    ushort ihc = internet_checksum(buf[0 .. IPv4Header.sizeof]);
    rip.checksum = nativeToBigEndian(ihc);

    ubyte* icmp = buf.ptr + IPv4Header.sizeof;
    icmp[0] = type;
    icmp[1] = code;
    icmp[2] = 0;
    icmp[3] = 0;
    icmp[4..8] = code_data.nativeToBigEndian;
    icmp[8 .. 8 + orig_quote] = (cast(const(ubyte)*)original.data.ptr)[0 .. orig_quote];

    ushort cc = internet_checksum(buf[IPv4Header.sizeof .. total]);
    icmp[2..4] = cc.nativeToBigEndian;

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
    size_t ip_total = ip.total_length.bigEndianToNative!ushort;
    if (ip_total < ip_hdr_len + IcmpHeader.sizeof || ip_total > pkt.data.length)
        return;

    const(ubyte)[] icmp = (cast(const(ubyte)*)pkt.data.ptr)[ip_hdr_len .. ip_total];

    if (internet_checksum(icmp) != 0)
    {
        version (DebugICMP)
            write_log(Severity.trace, "icmp", null, "rx bad checksum from ", ip.src);
        return;
    }

    version (DebugICMP)
        write_log(Severity.trace, "icmp", null, "rx type=", icmp[0], " code=", icmp[1], " from ", ip.src, " to ", ip.dst);

    switch (icmp[0])
    {
        case IcmpType.echo_request:
            handle_echo_request(stack, pkt, ip_hdr_len);
            break;
        case IcmpType.echo_reply:
            // TODO: notify ping client (we don't have one yet)
            break;
        case IcmpType.dest_unreachable:
            handle_dest_unreachable(stack, icmp);
            break;
        default:
            // TODO: time_exceeded -> notify upper layers
            break;
    }
}


void handle_dest_unreachable(ref IPStack stack, const(ubyte)[] icmp)
{
    import protocol.ip.tcp : tcp_handle_unreachable;

    // ICMP body: 1B type, 1B code, 2B checksum, 4B rest-of-header,
    // then quoted original IP header + first 8B of original payload.
    if (icmp.length < IcmpHeader.sizeof + 4 + IPv4Header.sizeof)
        return;

    ubyte code = icmp[1];
    uint code_data = icmp[4..8].bigEndianToNative!uint;

    const(ubyte)[] inner = icmp[IcmpHeader.sizeof + 4 .. $];
    auto inner_ip = cast(const IPv4Header*)inner.ptr;
    if (inner_ip.version_ != 4)
        return;
    size_t inner_hdr_len = inner_ip.ihl * 4;
    if (inner_hdr_len < IPv4Header.sizeof || inner.length < inner_hdr_len + 8)
        return;

    if (inner_ip.protocol == IPProtocol.tcp)
    {
        const(ubyte)[] tcp8 = inner[inner_hdr_len .. inner_hdr_len + 8];
        ushort src_port = tcp8[0..2].bigEndianToNative!ushort;
        ushort dst_port = tcp8[2..4].bigEndianToNative!ushort;
        // inner_ip.src is *us* (the original sender), inner_ip.dst is the peer.
        tcp_handle_unreachable(stack, code, code_data,
                               IPAddr(inner_ip.src), src_port,
                               IPAddr(inner_ip.dst), dst_port);
    }
    // TODO: UDP unreachables -> notify socket layer
}


private:

void handle_echo_request(ref IPStack stack, ref const Packet pkt, size_t ip_hdr_len)
{
    enum max_size = 1500;
    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t ip_total = ip.total_length.bigEndianToNative!ushort;
    if (ip_total < ip_hdr_len + IcmpHeader.sizeof || ip_total > pkt.data.length)
        return;

    const(ubyte)[] datagram = (cast(const(ubyte)*)pkt.data.ptr)[0 .. ip_total];
    if (datagram.length > max_size)
        return;

    ubyte[] buf = cast(ubyte[])talloc(datagram.length);
    buf[] = datagram[];

    auto rip = cast(IPv4Header*)buf.ptr;
    IPAddr orig_dst = IPAddr(rip.dst);
    rip.dst = rip.src;
    rip.src = orig_dst.b;

    version (DebugICMP)
        write_log(Severity.debug_, "icmp", null, "tx echo-reply src=", rip.src, " dst=", rip.dst, " (", datagram.length, " bytes)");
    rip.ttl = 64;
    rip.checksum[] = 0;
    ushort ihc = internet_checksum(buf[0 .. ip_hdr_len]);
    rip.checksum = nativeToBigEndian(ihc);

    ubyte* icmp = buf.ptr + ip_hdr_len;
    icmp[0] = IcmpType.echo_reply;
    icmp[2] = 0;
    icmp[3] = 0;
    ushort cc = internet_checksum(buf[ip_hdr_len .. datagram.length]);
    icmp[2..4] = cc.nativeToBigEndian;

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

// Token bucket: 1 token per second sustained, 6 token burst. Credit is held
// in milliseconds (1 token = 1000 ms credit) to avoid floating-point.
struct RateLimiter
{
nothrow @nogc:
    enum uint burst_ms     = 6_000;
    enum uint per_token_ms = 1_000;

    uint     credit_ms;
    MonoTime last_check;

    bool consume(MonoTime now)
    {
        if (last_check.ticks == 0)
        {
            credit_ms = burst_ms;
        }
        else
        {
            long elapsed = (now - last_check).as!"msecs";
            if (elapsed > 0)
            {
                ulong nc = ulong(credit_ms) + ulong(elapsed);
                credit_ms = nc > burst_ms ? burst_ms : cast(uint)nc;
            }
        }
        last_check = now;

        if (credit_ms < per_token_ms)
            return false;
        credit_ms -= per_token_ms;
        return true;
    }
}

__gshared RateLimiter _rl_dest_unreachable;
__gshared RateLimiter _rl_time_exceeded;
__gshared RateLimiter _rl_parameter_problem;

RateLimiter* rate_limiter_for(ubyte type)
{
    switch (type)
    {
        case IcmpType.dest_unreachable:  return &_rl_dest_unreachable;
        case IcmpType.time_exceeded:     return &_rl_time_exceeded;
        case IcmpType.parameter_problem: return &_rl_parameter_problem;
        default:                         return null;
    }
}
