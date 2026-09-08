module protocol.ip.icmp;

version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.mem.temp : talloc;
import urt.time;

import router.iface.packet;
import router.iface : BaseInterface;
import manager.collection : CID, Collection;
import protocol.ip.address : IPAddress;

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

alias EchoHandler = void delegate(IPAddr from, Duration rtt) nothrow @nogc;
alias EchoErrorHandler = void delegate(IPAddr from, ubyte type, ubyte code, uint data) nothrow @nogc;

ushort icmp_echo_send(ref IPStack stack, IPAddr destination, BaseInterface iface, EchoHandler handler, EchoErrorHandler error_handler = null)
{
    RouteResult route = stack.route_lookup_v4_dst(destination);
    IPAddr source = stack.select_source_v4(destination);
    if (iface)
    {
        if (destination.is_multicast || destination == IPAddr.broadcast)
            route = RouteResult(RouteResult.Kind.forward, iface, destination);
        if (route.out_iface !is iface)
            return 0;
        source = IPAddr.any;
        foreach (a; Collection!IPAddress().values)
            if (a.iface is iface)
            {
                source = a.address.addr;
                break;
            }
    }
    if (source == IPAddr.any || _pending_echoes.length >= ushort.max)
        return 0;

    ushort sequence;
    do
        sequence = _next_echo_sequence++;
    while (sequence == 0 || echo_sequence_pending(sequence));

    align(uint.sizeof) ubyte[60] buffer;
    auto ip = cast(IPv4Header*)buffer.ptr;
    ip.ver_ihl = 0x45;
    ip.total_length = nativeToBigEndian(ushort(buffer.length));
    ip.ident = nativeToBigEndian(next_ip_id());
    ip.ttl = 64;
    ip.protocol = IPProtocol.icmp;
    ip.src = source.b;
    ip.dst = destination.b;
    ip.checksum = nativeToBigEndian(internet_checksum(buffer[0 .. IPv4Header.sizeof]));
    ubyte[] message = buffer[IPv4Header.sizeof .. $];
    message[0] = IcmpType.echo_request;
    message[4 .. 6] = nativeToBigEndian(echo_identifier);
    message[6 .. 8] = nativeToBigEndian(sequence);
    foreach (i; 8 .. message.length)
        message[i] = cast(ubyte)(i - 8);
    message[2 .. 4] = nativeToBigEndian(internet_checksum(message));
    _pending_echoes ~= PendingEcho(source, destination, getTime(), handler, error_handler, sequence, iface ? iface.id : CID());
    Packet packet;
    packet.init!RawFrame(buffer[]);
    if (iface && route.kind != RouteResult.Kind.local)
        stack.output_v4_routed(packet, iface, route.next_hop);
    else
        stack.output_v4(packet);
    return sequence;
}

void icmp_echo_cancel(ushort sequence)
{
    foreach (i, ref pending; _pending_echoes[])
        if (pending.sequence == sequence)
        {
            _pending_echoes.removeSwapLast(i);
            return;
        }
}


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
void icmp_input(ref IPStack stack, ref Packet pkt, BaseInterface iface = null)
{
    if (pkt.data.length < IPv4Header.sizeof + IcmpHeader.sizeof)
        return;

    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t ip_hdr_len = ip.ihl * 4;
    size_t ip_total = ip.total_length.bigEndianToNative!ushort;
    if (ip.version_ != 4 || ip_hdr_len < IPv4Header.sizeof || ip_total < ip_hdr_len + IcmpHeader.sizeof || ip_total > pkt.data.length)
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
            if (icmp.length >= 8 && icmp[1] == 0)
                handle_echo_request(stack, pkt, ip_hdr_len);
            break;
        case IcmpType.echo_reply:
            handle_echo_response(*ip, icmp, iface);
            break;
        case IcmpType.dest_unreachable:
            handle_echo_response(*ip, icmp, iface, true);
            handle_dest_unreachable(stack, icmp);
            break;
        case IcmpType.time_exceeded:
        case IcmpType.parameter_problem:
            handle_echo_response(*ip, icmp, iface, true);
            break;
        default:
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
        tcp_handle_unreachable(stack, code, code_data, IPAddr(inner_ip.src), src_port, IPAddr(inner_ip.dst), dst_port);
    }
    // TODO: UDP unreachables -> notify socket layer
}


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


private:

bool echo_sequence_pending(ushort sequence)
{
    foreach (ref pending; _pending_echoes[])
        if (pending.sequence == sequence)
            return true;
    return false;
}

void handle_echo_response(ref const IPv4Header ip, const(ubyte)[] message, BaseInterface iface, bool error = false)
{
    if (message.length < 8)
        return;
    IPAddr source = IPAddr(ip.dst), destination = IPAddr(ip.src);
    const(ubyte)[] echo = message;
    if (error)
    {
        if (message.length < 8 + IPv4Header.sizeof)
            return;
        const quoted = cast(const IPv4Header*)(message.ptr + 8);
        size_t header_length = quoted.ihl * 4;
        if (quoted.version_ != 4 || header_length < IPv4Header.sizeof || message.length < 8 + header_length + 8 || quoted.total_length.bigEndianToNative!ushort < header_length + 8 || quoted.protocol != IPProtocol.icmp || (quoted.flags_frag.bigEndianToNative!ushort & 0x1fff))
            return;
        if (IPAddr(quoted.src) != source)
            return;
        destination = IPAddr(quoted.dst);
        echo = message[8 + header_length .. $];
        if (echo[0] != IcmpType.echo_request)
            return;
    }
    if (echo[1] != 0 || echo[4 .. 6].bigEndianToNative!ushort != echo_identifier)
        return;
    ushort sequence = echo[6 .. 8].bigEndianToNative!ushort;
    foreach (i, ref pending; _pending_echoes[])
    {
        bool group = pending.destination.is_multicast || pending.destination == IPAddr.broadcast;
        if (pending.sequence != sequence || pending.source != source || ((!group || error) && pending.destination != destination) || (pending.scope_iface && (!iface || pending.scope_iface != iface.id)))
            continue;
        IPAddr from = IPAddr(ip.src);
        if (from == IPAddr.any || from.is_multicast || from == IPAddr.broadcast)
            return;
        if (group)
        {
            Array!IPAddr* responders = error ? &pending.error_sources : &pending.responders;
            foreach (responder; (*responders)[])
                if (responder == from)
                    return;
            if (responders.length == 64)
                return;
            *responders ~= from;
        }
        EchoHandler handler = pending.handler;
        EchoErrorHandler error_handler = pending.error_handler;
        MonoTime sent = pending.sent;
        if (!group)
            _pending_echoes.removeSwapLast(i);
        if (error)
        {
            if (error_handler)
                error_handler(from, message[0], message[1], message[4 .. 8].bigEndianToNative!uint);
        }
        else if (handler)
            handler(from, getTime() - sent);
        return;
    }
}

struct PendingEcho
{
    IPAddr source;
    IPAddr destination;
    MonoTime sent;
    EchoHandler handler;
    EchoErrorHandler error_handler;
    ushort sequence;
    CID scope_iface;
    Array!IPAddr responders;
    Array!IPAddr error_sources;
}

enum ushort echo_identifier = 0x4f57;
__gshared ushort _next_echo_sequence = 1;
__gshared Array!PendingEcho _pending_echoes;

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

unittest
{
    import urt.mem : free;
    import manager.base : ObjectFlags;
    import manager.collection : collection_type_info;
    import router.iface.ethernet : EthernetStation;

    static class Link : EthernetStation
    {
        enum type_name = "icmp-echo-test-link";
    nothrow @nogc:
        Array!ubyte captured;
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Link, id, flags);
            _state = State.running;
        }
        override void medium_tx(ref Packet packet) { captured = cast(const(ubyte)[])packet.data; }
    }
    Link link = Collection!Link().create("icmp-echo-test-link");
    IPAddress address = Collection!IPAddress().create("icmp-echo-test-address");
    scope(exit)
    {
        Collection!IPAddress().remove(address);
        free(address);
        Collection!Link().remove(link);
        free(link);
    }
    IPAddr local = IPAddr(192, 0, 2, 1), remote = IPAddr(192, 0, 2, 2);
    address.address = IPNetworkAddress(local, 24);
    address.iface = link;
    IPStack stack;
    ubyte[6] mac = [2, 0, 0, 0, 0, 1];
    stack.neighbour_v4_cache.learn(remote, link, mac[]);
    struct Results
    {
        uint replies, errors;
        void reply(IPAddr, Duration) nothrow @nogc { ++replies; }
        void error(IPAddr, ubyte type, ubyte code, uint data) nothrow @nogc
        {
            assert(type == IcmpType.time_exceeded && code == 0);
            ++errors;
        }
    }
    Results results;
    ushort sequence = icmp_echo_send(stack, remote, link, &results.reply, &results.error);
    assert(sequence && link.captured.length == 60);
    scope(exit) icmp_echo_cancel(sequence);
    assert(internet_checksum(link.captured[0 .. 20]) == 0);
    assert(internet_checksum(link.captured[20 .. $]) == 0);
    align(uint.sizeof) ubyte[60] reply;
    reply[] = link.captured[];
    auto ip = cast(IPv4Header*)reply.ptr;
    ip.src = remote.b;
    ip.dst = local.b;
    reply[20] = IcmpType.echo_reply;
    void input() nothrow @nogc
    {
        reply[22 .. 24] = 0;
        reply[22 .. 24] = nativeToBigEndian(internet_checksum(reply[20 .. $]));
        Packet packet;
        packet.init!RawFrame(reply[]);
        icmp_input(stack, packet, link);
    }
    ip.src = IPAddr(192, 0, 2, 3).b;
    input();
    ip.src = remote.b;
    ip.dst = remote.b;
    input();
    ip.dst = local.b;
    reply[27] ^= 1;
    input();
    reply[27] ^= 1;
    reply[21] = 1;
    input();
    reply[21] = 0;
    assert(results.replies == 0);
    input();
    input();
    assert(results.replies == 1);

    sequence = icmp_echo_send(stack, remote, link, &results.reply, &results.error);
    align(uint.sizeof) ubyte[56] error;
    auto error_ip = cast(IPv4Header*)error.ptr;
    error_ip.ver_ihl = 0x45;
    error_ip.protocol = IPProtocol.icmp;
    error_ip.total_length = nativeToBigEndian(ushort(error.length));
    error_ip.src = IPAddr(192, 0, 2, 3).b;
    error_ip.dst = local.b;
    error[20] = IcmpType.time_exceeded;
    error[28 .. $] = link.captured[0 .. 28];
    error[22 .. 24] = nativeToBigEndian(internet_checksum(error[20 .. $]));
    Packet packet;
    packet.init!RawFrame(error[]);
    icmp_input(stack, packet, null);
    assert(results.errors == 0);
    error[22] ^= 1;
    icmp_input(stack, packet, link);
    assert(results.errors == 0);
    error[22] ^= 1;
    icmp_input(stack, packet, link);
    icmp_input(stack, packet, link);
    assert(results.errors == 1);

    sequence = icmp_echo_send(stack, remote, link, &results.reply);
    reply[26 .. 28] = nativeToBigEndian(sequence);
    icmp_echo_cancel(sequence);
    input();
    assert(results.replies == 1);
    sequence = icmp_echo_send(stack, IPAddr.loopback, null, &results.reply);
    assert(sequence && results.replies == 2);
    assert(!echo_sequence_pending(sequence));
    sequence = icmp_echo_send(stack, local, link, &results.reply);
    assert(sequence && results.replies == 3);
    assert(!echo_sequence_pending(sequence));
}
