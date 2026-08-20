module protocol.ip.icmp6;

version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.mem.temp : talloc;
import urt.time;

import router.iface;
import router.iface.packet;

import protocol.ip : IPv6Header, IPProtocol;
import protocol.ip.icmp : RateLimiter;
import protocol.ip.nd;
import protocol.ip.stack;

//version = DebugICMP6;

nothrow @nogc:


enum Icmp6Type : ubyte
{
    dest_unreachable   = 1,
    packet_too_big     = 2,
    time_exceeded      = 3,
    parameter_problem  = 4,
    echo_request       = 128,
    echo_reply         = 129,
    router_solicit     = 133,
    router_advert      = 134,
    neighbour_solicit  = 135,
    neighbour_advert   = 136,
    redirect           = 137,
}

enum Icmp6DestUnreachableCode : ubyte
{
    no_route     = 0,
    admin_prohib = 1,
    beyond_scope = 2,
    addr         = 3,
    port         = 4,
}


struct Icmp6Header
{
    ubyte    type;
    ubyte    code;
    ubyte[2] checksum;
    // Type-specific 4 bytes follow, as for ICMPv4.
}
static assert(Icmp6Header.sizeof == 4);


ushort pseudo_header_checksum_v6(ref const(ubyte)[16] src, ref const(ubyte)[16] dst, uint upper_length, ubyte next_header) pure
{
    ubyte[40] ph = void;
    ph[0..16]  = src[];
    ph[16..32] = dst[];
    ph[32..36] = upper_length.nativeToBigEndian;
    ph[36..39] = 0;
    ph[39]     = next_header;
    return internet_checksum(ph[]);
}


// Send an ICMPv6 error in response to `original`. Body carries as much of the
// original datagram as fits within the 1280-byte v6 minimum MTU, per RFC 4443.
void icmp6_send_error(ref IPStack stack, ubyte type, ubyte code, ref const Packet original, uint code_data = 0)
{
    if (original.data.length < IPv6Header.sizeof)
        return;
    const oip = cast(const IPv6Header*)original.data.ptr;

    IPv6Addr oip_dst = oip.dst_addr;
    IPv6Addr oip_src = oip.src_addr;

    // Don't reply to multicast destinations (except PTB / parameter problem, per RFC 4443 2.4(e)),
    // nor to an unspecified source.
    if (oip_dst.is_multicast && type != Icmp6Type.packet_too_big && type != Icmp6Type.parameter_problem)
        return;
    if (oip_src == IPv6Addr.any || oip_src.is_multicast)
        return;

    // Don't reply to ICMPv6 error messages (loop avoidance).
    if (oip.next_header == IPProtocol.icmp6 && original.data.length >= IPv6Header.sizeof + 1)
    {
        ubyte oicmp_type = (cast(const(ubyte)*)original.data.ptr)[IPv6Header.sizeof];
        if (oicmp_type < 128)
            return;     // types 0-127 are errors
    }

    if (auto rl = rate_limiter_for(type))
    {
        if (!rl.consume(getTime()))
            return;
    }

    IPv6Addr src = stack.select_source_v6(oip_src, null);
    if (src == IPv6Addr.any)
        return;

    version (DebugICMP6)
        write_log(Severity.debug_, "icmp6", null, "tx error type=", type, " code=", code, " dst=", oip_src);

    enum size_t max_size = 1280;
    size_t orig_quote = original.data.length;
    if (IPv6Header.sizeof + 8 + orig_quote > max_size)
        orig_quote = max_size - IPv6Header.sizeof - 8;
    size_t total = IPv6Header.sizeof + 8 + orig_quote;

    ubyte[max_size] buf = void;

    auto rip = cast(IPv6Header*)buf.ptr;
    rip.ver_tc_flow[] = 0;
    rip.ver_tc_flow[0] = 0x60;
    rip.payload_length = nativeToBigEndian(cast(ushort)(8 + orig_quote));
    rip.next_header = IPProtocol.icmp6;
    rip.hop_limit = 64;
    rip.src_addr = src;
    rip.dst_addr = oip_src;

    ubyte* icmp = buf.ptr + IPv6Header.sizeof;
    icmp[0] = type;
    icmp[1] = code;
    icmp[2] = 0;
    icmp[3] = 0;
    icmp[4..8] = code_data.nativeToBigEndian;
    icmp[8 .. 8 + orig_quote] = (cast(const(ubyte)*)original.data.ptr)[0 .. orig_quote];

    ushort pseudo = pseudo_header_checksum_v6(rip.src, rip.dst, cast(uint)(8 + orig_quote), IPProtocol.icmp6);
    ushort cc = internet_checksum(buf[IPv6Header.sizeof .. total], pseudo);
    icmp[2..4] = cc.nativeToBigEndian;

    Packet pkt;
    pkt.init!RawFrame(buf[0 .. total]);
    stack.output_v6(pkt);
}


alias Echo6Handler = void delegate(IPv6Addr from, Duration rtt) nothrow @nogc;

// Send one echo request to `dst`; `handler` fires on reply until cancelled.
// `iface_hint` scopes link-local destinations. Returns 0 if no source address
// or route was available, else the sequence number for icmp6_echo_cancel.
ushort icmp6_echo_send(ref IPStack stack, IPv6Addr dst, BaseInterface iface_hint, Echo6Handler handler)
{
    IPv6Addr src = stack.select_source_v6(dst, iface_hint);
    if (src == IPv6Addr.any)
        return 0;

    ushort seq = _next_echo_seq++;
    if (seq == 0)
        seq = _next_echo_seq++;

    enum size_t payload_len = 32;
    enum size_t icmp_len = 8 + payload_len;
    ubyte[IPv6Header.sizeof + icmp_len] buf = void;

    auto ip = cast(IPv6Header*)buf.ptr;
    ip.ver_tc_flow[] = 0;
    ip.ver_tc_flow[0] = 0x60;
    ip.payload_length = nativeToBigEndian(cast(ushort)icmp_len);
    ip.next_header = IPProtocol.icmp6;
    ip.hop_limit = 64;
    ip.src_addr = src;
    ip.dst_addr = dst;

    ubyte* icmp = buf.ptr + IPv6Header.sizeof;
    icmp[0] = Icmp6Type.echo_request;
    icmp[1] = 0;
    icmp[2] = 0;
    icmp[3] = 0;
    icmp[4..6] = echo_ident.nativeToBigEndian;
    icmp[6..8] = seq.nativeToBigEndian;
    foreach (i; 0 .. payload_len)
        icmp[8 + i] = cast(ubyte)i;

    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, icmp_len, IPProtocol.icmp6);
    ushort cc = internet_checksum(icmp[0 .. icmp_len], pseudo);
    icmp[2..4] = cc.nativeToBigEndian;

    _pending_echoes ~= PendingEcho(seq, getTime(), handler);

    Packet pkt;
    pkt.init!RawFrame(buf[]);
    if ((dst.is_link_local || dst.is_multicast) && iface_hint)
        stack.output_v6_routed(pkt, iface_hint, dst);
    else
        stack.output_v6(pkt);
    return seq;
}

void icmp6_echo_cancel(ushort seq)
{
    foreach (i, ref p; _pending_echoes[])
    {
        if (p.seq == seq)
        {
            _pending_echoes.removeSwapLast(i);
            return;
        }
    }
}


// Process a locally-delivered ICMPv6 message.
// pkt.data is the whole IPv6 datagram; l4_offset is where the ICMPv6 message
// starts (past any extension headers); iface is the ingress interface (null
// for locally-originated loopback delivery).
void icmp6_input(ref IPStack stack, ref Packet pkt, size_t l4_offset, BaseInterface iface)
{
    if (pkt.data.length < l4_offset + Icmp6Header.sizeof)
        return;

    const ip = cast(const IPv6Header*)pkt.data.ptr;
    size_t datagram_end = IPv6Header.sizeof + ip.payload_length.bigEndianToNative!ushort;
    if (datagram_end > pkt.data.length || datagram_end < l4_offset + Icmp6Header.sizeof)
        return;

    const(ubyte)[] icmp = (cast(const(ubyte)*)pkt.data.ptr)[l4_offset .. datagram_end];

    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)icmp.length, IPProtocol.icmp6);
    if (internet_checksum(icmp, pseudo) != 0)
    {
        version (DebugICMP6)
            write_log(Severity.trace, "icmp6", null, "rx bad checksum from ", ip.src_addr);
        return;
    }

    version (DebugICMP6)
        write_log(Severity.trace, "icmp6", null, "rx type=", icmp[0], " code=", icmp[1], " from ", ip.src_addr, " to ", ip.dst_addr);

    switch (icmp[0])
    {
        case Icmp6Type.echo_request:
            handle_echo_request(stack, pkt, l4_offset, datagram_end);
            break;
        case Icmp6Type.echo_reply:
            handle_echo_reply(*ip, icmp);
            break;
        case Icmp6Type.neighbour_solicit:
            on_neighbour_solicit(stack, *ip, icmp, iface);
            break;
        case Icmp6Type.neighbour_advert:
            on_neighbour_advert(stack, *ip, icmp, iface);
            break;
        case Icmp6Type.router_solicit:
            // TODO: answer when we grow a router-advertisement role
            break;
        case Icmp6Type.router_advert:
            on_router_advert(stack, *ip, icmp, iface);
            break;
        case Icmp6Type.dest_unreachable:
        case Icmp6Type.packet_too_big:
            // TODO: propagate to TCP (PMTU) / socket layer as for v4
            break;
        default:
            break;
    }
}


private:

void handle_echo_request(ref IPStack stack, ref const Packet pkt, size_t l4_offset, size_t datagram_end)
{
    enum max_size = 1500;
    if (datagram_end > max_size)
        return;

    const ip = cast(const IPv6Header*)pkt.data.ptr;
    IPv6Addr orig_dst = ip.dst_addr;
    if (orig_dst.is_multicast)
        orig_dst = stack.select_source_v6(ip.src_addr, null);
    if (orig_dst == IPv6Addr.any)
        return;

    // Reply echoes the request datagram with ICMPv6 immediately after the v6
    // header; any extension headers on the request are not reproduced.
    size_t icmp_len = datagram_end - l4_offset;
    size_t total = IPv6Header.sizeof + icmp_len;
    ubyte[] buf = cast(ubyte[])talloc(total);

    auto rip = cast(IPv6Header*)buf.ptr;
    rip.ver_tc_flow[] = 0;
    rip.ver_tc_flow[0] = 0x60;
    rip.payload_length = nativeToBigEndian(cast(ushort)icmp_len);
    rip.next_header = IPProtocol.icmp6;
    rip.hop_limit = 64;
    rip.src_addr = orig_dst;
    rip.dst = ip.src;

    ubyte* icmp = buf.ptr + IPv6Header.sizeof;
    icmp[0 .. icmp_len] = (cast(const(ubyte)*)pkt.data.ptr)[l4_offset .. datagram_end];
    icmp[0] = Icmp6Type.echo_reply;
    icmp[2] = 0;
    icmp[3] = 0;
    ushort pseudo = pseudo_header_checksum_v6(rip.src, rip.dst, cast(uint)icmp_len, IPProtocol.icmp6);
    ushort cc = internet_checksum(buf[IPv6Header.sizeof .. total], pseudo);
    icmp[2..4] = cc.nativeToBigEndian;

    version (DebugICMP6)
        write_log(Severity.debug_, "icmp6", null, "tx echo-reply dst=", rip.dst_addr, " (", total, " bytes)");

    Packet reply;
    reply.init!RawFrame(buf[0 .. total]);
    stack.output_v6(reply);
}

void handle_echo_reply(ref const IPv6Header ip, const(ubyte)[] icmp)
{
    if (icmp.length < 8)
        return;
    if (icmp[4..6].bigEndianToNative!ushort != echo_ident)
        return;
    ushort seq = icmp[6..8].bigEndianToNative!ushort;

    foreach (i, ref p; _pending_echoes[])
    {
        if (p.seq == seq)
        {
            Echo6Handler handler = p.handler;
            MonoTime sent = p.sent;
            _pending_echoes.removeSwapLast(i);
            if (handler)
                handler(ip.src_addr, getTime() - sent);
            return;
        }
    }
}

enum ushort echo_ident = 0x4F57;    // 'OW'

struct PendingEcho
{
    ushort seq;
    MonoTime sent;
    Echo6Handler handler;
}
__gshared Array!PendingEcho _pending_echoes;
__gshared ushort _next_echo_seq = 1;

__gshared RateLimiter _rl_dest_unreachable;
__gshared RateLimiter _rl_packet_too_big;
__gshared RateLimiter _rl_time_exceeded;
__gshared RateLimiter _rl_parameter_problem;

RateLimiter* rate_limiter_for(ubyte type)
{
    switch (type)
    {
        case Icmp6Type.dest_unreachable:  return &_rl_dest_unreachable;
        case Icmp6Type.packet_too_big:    return &_rl_packet_too_big;
        case Icmp6Type.time_exceeded:     return &_rl_time_exceeded;
        case Icmp6Type.parameter_problem: return &_rl_parameter_problem;
        default:                          return null;
    }
}
