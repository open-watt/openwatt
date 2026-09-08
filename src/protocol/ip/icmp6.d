module protocol.ip.icmp6;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.time;

import manager.collection : CID;

import router.iface;
import router.iface.packet;

import protocol.ip : IPProtocol, IPv6Header, pseudo_header_checksum_v6;
import protocol.ip.icmp : RateLimiter;
import protocol.ip.mld;
import protocol.ip.nd;
import protocol.ip.stack;

//version = DebugICMP6;

nothrow @nogc:


enum Icmp6Type : ubyte
{
    dest_unreachable  = 1,
    packet_too_big    = 2,
    time_exceeded     = 3,
    parameter_problem = 4,
    echo_request      = 128,
    echo_reply        = 129,
    listener_query    = 130,
    listener_report   = 131,
    listener_done     = 132,
    router_solicit    = 133,
    router_advert     = 134,
    neighbour_solicit = 135,
    neighbour_advert  = 136,
    redirect          = 137,
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
    ubyte type;
    ubyte code;
    ubyte[2] checksum;
}
static assert(Icmp6Header.sizeof == 4);

alias Echo6Handler = void delegate(IPv6Addr from, Duration rtt) nothrow @nogc;
alias Echo6ErrorHandler = void delegate(IPv6Addr from, ubyte type, ubyte code, uint data) nothrow @nogc;

void icmp6_send_error(ref IPStack stack, ubyte type, ubyte code, ref const Packet original, BaseInterface ingress, uint code_data = 0)
{
    if (!icmp6_error_allowed(stack, type, code, original))
        return;

    const original_ip = cast(const IPv6Header*)original.data.ptr;
    IPv6Addr original_source = original_ip.src_addr;
    IPv6Addr original_destination = original_ip.dst_addr;
    IPv6Addr source;
    if (!original_destination.is_multicast && stack.owns_address_v6(original_destination))
        source = original_destination;
    else
        source = stack.select_source_v6_on_iface(original_source, ingress);
    if (source == IPv6Addr.any)
        return;

    if (RateLimiter* limiter = rate_limiter_for(type))
        if (!limiter.consume(getTime()))
            return;

    version (DebugICMP6)
        write_log(Severity.debug_, "icmp6", null, "tx error type=", type, " code=", code, " dst=", original_source);

    enum size_t max_size = 1280;
    size_t quote_length = original.data.length;
    if (IPv6Header.sizeof + 8 + quote_length > max_size)
        quote_length = max_size - IPv6Header.sizeof - 8;
    size_t message_length = 8 + quote_length;
    size_t total = IPv6Header.sizeof + message_length;

    Packet* response = alloc_packet!RawFrame(total);
    if (!response)
        return;
    scope(exit)
        response.free_clone();
    ubyte[] buffer = cast(ubyte[])response.payload;

    auto ip = cast(IPv6Header*)buffer.ptr;
    ip.ver_tc_flow[] = 0;
    ip.ver_tc_flow[0] = 0x60;
    storeBigEndian(cast(ushort*)ip.payload_length.ptr, cast(ushort)message_length);
    ip.next_header = IPProtocol.icmp6;
    ip.hop_limit = 64;
    ip.src_addr = source;
    ip.dst_addr = original_source;

    ubyte* message = buffer.ptr + IPv6Header.sizeof;
    message[0] = type;
    message[1] = code;
    storeBigEndian(cast(ushort*)(message + 2), ushort(0));
    storeBigEndian(cast(uint*)(message + 4), code_data);
    message[8 .. 8 + quote_length] = (cast(const(ubyte)*)original.data.ptr)[0 .. quote_length];

    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)message_length, IPProtocol.icmp6);
    ushort checksum = internet_checksum(message[0 .. message_length], pseudo);
    storeBigEndian(cast(ushort*)(message + 2), checksum);

    if (original_source.is_link_local && ingress)
        stack.output_v6_routed(*response, ingress, original_source);
    else
        stack.output_v6(*response);
}

ushort icmp6_echo_send(ref IPStack stack, IPv6Addr destination, BaseInterface iface_hint, Echo6Handler handler, Echo6ErrorHandler error_handler = null)
{
    IPv6Addr source = stack.select_source_v6(destination, iface_hint);
    if (source == IPv6Addr.any || _pending_echoes.length >= ushort.max)
        return 0;
    RouteResult6 route = stack.route_lookup_v6_dst(destination, iface_hint);
    if (iface_hint && route.out_iface !is iface_hint)
        return 0;

    ushort sequence;
    do
        sequence = _next_echo_sequence++;
    while (sequence == 0 || echo_sequence_pending(sequence));

    enum size_t payload_length = 32;
    enum size_t message_length = 8 + payload_length;
    align(size_t.sizeof) ubyte[IPv6Header.sizeof + message_length] buffer = void;

    auto ip = cast(IPv6Header*)buffer.ptr;
    ip.ver_tc_flow[] = 0;
    ip.ver_tc_flow[0] = 0x60;
    storeBigEndian(cast(ushort*)ip.payload_length.ptr, cast(ushort)message_length);
    ip.next_header = IPProtocol.icmp6;
    ip.hop_limit = 64;
    ip.src_addr = source;
    ip.dst_addr = destination;

    ubyte* message = buffer.ptr + IPv6Header.sizeof;
    message[0] = Icmp6Type.echo_request;
    message[1] = 0;
    storeBigEndian(cast(ushort*)(message + 2), ushort(0));
    storeBigEndian(cast(ushort*)(message + 4), echo_identifier);
    storeBigEndian(cast(ushort*)(message + 6), sequence);
    foreach (i; 0 .. payload_length)
        message[8 + i] = cast(ubyte)i;

    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)message_length, IPProtocol.icmp6);
    ushort checksum = internet_checksum(message[0 .. message_length], pseudo);
    storeBigEndian(cast(ushort*)(message + 2), checksum);

    CID scope_iface = iface_hint ? iface_hint.id : CID();
    _pending_echoes ~= PendingEcho(destination, getTime(), handler, sequence, scope_iface, Array!IPv6Addr.init, source, error_handler);

    Packet packet;
    packet.init!RawFrame(buffer[]);
    if (iface_hint && route.kind != RouteResult6.Kind.local)
        stack.output_v6_routed(packet, iface_hint, route.next_hop);
    else
        stack.output_v6(packet, iface_hint);
    return sequence;
}

void icmp6_echo_cancel(ushort sequence)
{
    foreach (i, ref pending; _pending_echoes[])
    {
        if (pending.sequence == sequence)
        {
            _pending_echoes.removeSwapLast(i);
            return;
        }
    }
}

void icmp6_input(ref IPStack stack, ref Packet packet, size_t offset, BaseInterface iface)
{
    if (offset < IPv6Header.sizeof || offset > packet.data.length || packet.data.length - offset < Icmp6Header.sizeof)
        return;

    const ip = cast(const IPv6Header*)packet.data.ptr;
    size_t datagram_end = IPv6Header.sizeof + loadBigEndian(cast(const(ushort)*)ip.payload_length.ptr);
    if (datagram_end > packet.data.length || datagram_end < offset + Icmp6Header.sizeof)
        return;

    const(ubyte)[] message = (cast(const(ubyte)*)packet.data.ptr)[offset .. datagram_end];
    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)message.length, IPProtocol.icmp6);
    if (internet_checksum(message, pseudo) != 0)
    {
        version (DebugICMP6)
            write_log(Severity.trace, "icmp6", null, "rx bad checksum from ", ip.src_addr);
        return;
    }

    version (DebugICMP6)
        write_log(Severity.trace, "icmp6", null, "rx type=", message[0], " code=", message[1], " from ", ip.src_addr, " to ", ip.dst_addr);

    switch (message[0])
    {
        case Icmp6Type.echo_request:
            if (message[1] == 0 && message.length >= 8)
                handle_echo_request(stack, packet, offset, datagram_end, iface);
            break;
        case Icmp6Type.echo_reply:
            if (message[1] == 0)
                handle_echo_reply(*ip, message, iface);
            break;
        case Icmp6Type.listener_query:
        case Icmp6Type.listener_report:
        case Icmp6Type.listener_done:
            mld_input(packet, offset, iface);
            break;
        case Icmp6Type.neighbour_solicit:
            on_neighbour_solicit(stack, *ip, message, iface, packet);
            break;
        case Icmp6Type.neighbour_advert:
            on_neighbour_advert(stack, *ip, message, iface);
            break;
        case Icmp6Type.router_solicit:
            break;
        case Icmp6Type.router_advert:
            on_router_advert(stack, *ip, message, iface);
            break;
        default:
            if (message[0] < 128)
                handle_echo_error(stack, *ip, message, iface);
            break;
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

bool icmp6_error_allowed(ref IPStack stack, ubyte type, ubyte code, ref const Packet original)
{
    if (original.data.length < IPv6Header.sizeof)
        return false;
    const ip = cast(const IPv6Header*)original.data.ptr;
    IPv6Addr source = ip.src_addr;
    IPv6Addr destination = ip.dst_addr;
    if (source == IPv6Addr.any || source.is_multicast)
        return false;
    if (destination.is_multicast && !multicast_error_allowed(type, code))
        return false;
    if (original.type == Ethernet.Type && original.hdr!Ethernet.dst.is_multicast && !multicast_error_allowed(type, code))
        return false;

    size_t offset, next_header_offset;
    IPProtocol protocol;
    if (!stack.upper_protocol_v6(original.data, offset, next_header_offset, protocol))
        return false;
    if (protocol == IPProtocol.icmp6)
    {
        if (original.data.length <= offset)
            return false;
        ubyte original_type = (cast(const(ubyte)*)original.data.ptr)[offset];
        return original_type >= 128 && original_type != Icmp6Type.redirect;
    }
    return true;
}

bool multicast_error_allowed(ubyte type, ubyte code) pure
    => type == Icmp6Type.packet_too_big || (type == Icmp6Type.parameter_problem && code == 2);

void handle_echo_request(ref IPStack stack, ref const Packet packet, size_t offset, size_t datagram_end, BaseInterface iface)
{
    const ip = cast(const IPv6Header*)packet.data.ptr;
    IPv6Addr source = ip.dst_addr;
    if (source.is_multicast)
        source = stack.select_source_v6_on_iface(ip.src_addr, iface);
    if (source == IPv6Addr.any)
        return;

    size_t message_length = datagram_end - offset;
    size_t total = IPv6Header.sizeof + message_length;
    Packet* reply = alloc_packet!RawFrame(total);
    if (!reply)
        return;
    scope(exit)
        reply.free_clone();
    ubyte[] buffer = cast(ubyte[])reply.payload;

    auto reply_ip = cast(IPv6Header*)buffer.ptr;
    reply_ip.ver_tc_flow[] = 0;
    reply_ip.ver_tc_flow[0] = 0x60;
    storeBigEndian(cast(ushort*)reply_ip.payload_length.ptr, cast(ushort)message_length);
    reply_ip.next_header = IPProtocol.icmp6;
    reply_ip.hop_limit = 64;
    reply_ip.src_addr = source;
    reply_ip.dst_addr = ip.src_addr;

    ubyte* message = buffer.ptr + IPv6Header.sizeof;
    message[0 .. message_length] = (cast(const(ubyte)*)packet.data.ptr)[offset .. datagram_end];
    message[0] = Icmp6Type.echo_reply;
    storeBigEndian(cast(ushort*)(message + 2), ushort(0));
    ushort pseudo = pseudo_header_checksum_v6(reply_ip.src, reply_ip.dst, cast(uint)message_length, IPProtocol.icmp6);
    ushort checksum = internet_checksum(message[0 .. message_length], pseudo);
    storeBigEndian(cast(ushort*)(message + 2), checksum);

    version (DebugICMP6)
        write_log(Severity.debug_, "icmp6", null, "tx echo reply dst=", reply_ip.dst_addr, " (", total, " bytes)");

    if (reply_ip.dst_addr.is_link_local && iface)
        stack.output_v6(*reply, iface);
    else
        stack.output_v6(*reply);
}

void handle_echo_reply(ref const IPv6Header ip, const(ubyte)[] message, BaseInterface iface)
{
    if (message.length < 8 || loadBigEndian(cast(const(ushort)*)(message.ptr + 4)) != echo_identifier)
        return;
    ushort sequence = loadBigEndian(cast(const(ushort)*)(message.ptr + 6));

    foreach (i, ref pending; _pending_echoes[])
    {
        if (pending.sequence != sequence || pending.source != ip.dst_addr || (pending.scope_iface && (!iface || pending.scope_iface != iface.id)))
            continue;
        bool multicast = pending.destination.is_multicast;
        if (!multicast && pending.destination != ip.src_addr)
            continue;
        if (multicast)
        {
            if (ip.src_addr == IPv6Addr.any || ip.src_addr.is_multicast)
                return;
            foreach (responder; pending.responders[])
                if (responder == ip.src_addr)
                    return;
            if (pending.responders.length == max_echo_responders)
                return;
            pending.responders ~= ip.src_addr;
        }
        Echo6Handler handler = pending.handler;
        MonoTime sent = pending.sent;
        if (!multicast)
            _pending_echoes.removeSwapLast(i);
        if (handler)
            handler(ip.src_addr, getTime() - sent);
        return;
    }
}

void handle_echo_error(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] message, BaseInterface iface)
{
    if (message.length < 8 + IPv6Header.sizeof + 8 || ip.src_addr == IPv6Addr.any || ip.src_addr.is_multicast)
        return;
    const quoted = cast(const IPv6Header*)(message.ptr + 8);
    if (quoted.ver_tc_flow[0] >> 4 != 6 || quoted.src_addr != ip.dst_addr)
        return;
    size_t quote_length = IPv6Header.sizeof + loadBigEndian(cast(const(ushort)*)quoted.payload_length.ptr);
    if (quote_length > message.length - 8)
        quote_length = message.length - 8;
    const(ubyte)[] quote = message[8 .. 8 + quote_length];
    size_t offset, next_header_offset;
    IPProtocol protocol;
    if (!stack.upper_protocol_v6(quote, offset, next_header_offset, protocol) || protocol != IPProtocol.icmp6 || quote.length - offset < 8)
        return;
    const(ubyte)[] echo = quote[offset .. $];
    if (echo[0] != Icmp6Type.echo_request || echo[1] != 0 || loadBigEndian(cast(const(ushort)*)(echo.ptr + 4)) != echo_identifier)
        return;
    ushort sequence = loadBigEndian(cast(const(ushort)*)(echo.ptr + 6));
    foreach (i, ref pending; _pending_echoes[])
    {
        if (pending.sequence != sequence || pending.source != quoted.src_addr || pending.destination != quoted.dst_addr || (pending.scope_iface && (!iface || pending.scope_iface != iface.id)))
            continue;
        bool multicast = pending.destination.is_multicast;
        if (multicast)
        {
            foreach (source; pending.error_sources[])
                if (source == ip.src_addr)
                    return;
            if (pending.error_sources.length == max_echo_responders)
                return;
            pending.error_sources ~= ip.src_addr;
        }
        Echo6ErrorHandler handler = pending.error_handler;
        if (!multicast)
            _pending_echoes.removeSwapLast(i);
        if (handler)
            handler(ip.src_addr, message[0], message[1], loadBigEndian(cast(const(uint)*)(message.ptr + 4)));
        return;
    }
}

struct PendingEcho
{
    IPv6Addr destination;
    MonoTime sent;
    Echo6Handler handler;
    ushort sequence;
    CID scope_iface;
    Array!IPv6Addr responders;
    IPv6Addr source;
    Echo6ErrorHandler error_handler;
    Array!IPv6Addr error_sources;
}

RateLimiter* rate_limiter_for(ubyte type)
{
    switch (type)
    {
        case Icmp6Type.dest_unreachable:  return &_dest_unreachable_limiter;
        case Icmp6Type.packet_too_big:    return &_packet_too_big_limiter;
        case Icmp6Type.time_exceeded:     return &_time_exceeded_limiter;
        case Icmp6Type.parameter_problem: return &_parameter_problem_limiter;
        default:                          return null;
    }
}

enum ushort echo_identifier = 0x4F57;
enum size_t max_echo_responders = 64;

__gshared Array!PendingEcho _pending_echoes;
__gshared ushort _next_echo_sequence = 1;
__gshared RateLimiter _dest_unreachable_limiter;
__gshared RateLimiter _packet_too_big_limiter;
__gshared RateLimiter _time_exceeded_limiter;
__gshared RateLimiter _parameter_problem_limiter;


unittest
{
    assert(multicast_error_allowed(Icmp6Type.packet_too_big, 0));
    assert(multicast_error_allowed(Icmp6Type.parameter_problem, 2));
    assert(!multicast_error_allowed(Icmp6Type.parameter_problem, 1));
    assert(!multicast_error_allowed(Icmp6Type.dest_unreachable, 0));

    IPStack stack;
    align(uint.sizeof) ubyte[48] data;
    auto ip = cast(IPv6Header*)data.ptr;
    ip.ver_tc_flow[0] = 0x60;
    ip.src_addr = IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
    ip.dst_addr = IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2);
    ip.next_header = IPProtocol.icmp6;
    data[40] = Icmp6Type.echo_request;
    Packet packet;
    packet.init!Ethernet(data[]);
    assert(icmp6_error_allowed(stack, Icmp6Type.dest_unreachable, 0, packet));
    packet.hdr!Ethernet.dst.b[0] = 0x33;
    assert(!icmp6_error_allowed(stack, Icmp6Type.dest_unreachable, 0, packet));
    assert(icmp6_error_allowed(stack, Icmp6Type.packet_too_big, 0, packet));
    assert(icmp6_error_allowed(stack, Icmp6Type.parameter_problem, 2, packet));
    packet.hdr!Ethernet.dst.b[] = 0xff;
    assert(!icmp6_error_allowed(stack, Icmp6Type.time_exceeded, 0, packet));
    packet.hdr!Ethernet.dst.b[] = 0;
    foreach (ubyte type; [Icmp6Type.dest_unreachable, Icmp6Type.redirect])
    {
        data[40] = type;
        assert(!icmp6_error_allowed(stack, Icmp6Type.packet_too_big, 0, packet));
    }
    data[40] = Icmp6Type.echo_request;
    ip.dst_addr = IPv6Addr(0xff02, 0, 0, 0, 0, 0, 0, 1);
    assert(!icmp6_error_allowed(stack, Icmp6Type.time_exceeded, 0, packet));
    assert(icmp6_error_allowed(stack, Icmp6Type.packet_too_big, 0, packet));
    ip.src_addr = IPv6Addr.any;
    assert(!icmp6_error_allowed(stack, Icmp6Type.packet_too_big, 0, packet));
    ip.src_addr = ip.dst_addr;
    assert(!icmp6_error_allowed(stack, Icmp6Type.packet_too_big, 0, packet));
}

unittest
{
    import urt.mem : alloc, free;
    import manager.base : ObjectFlags;
    import manager.collection : collection_type_info;

    static class Link : BaseInterface
    {
    nothrow @nogc:
        this(CID id, ObjectFlags flags = ObjectFlags.none) { super(collection_type_info!Link, id, flags); }
        override int transmit(ref Packet packet, MessageCallback callback, const(QueuePolicy)* policy) { return 0; }
    }

    Link first = alloc!Link(CID(1));
    scope(exit) free(first);
    Link second = alloc!Link(CID(2));
    scope(exit) free(second);
    IPv6Header ip;
    ip.src_addr = IPv6Addr(0xfe80, 0, 0, 0, 0, 0, 0, 1);
    IPv6Addr local = IPv6Addr(0xfe80, 0, 0, 0, 0, 0, 0, 2);
    ip.dst_addr = local;
    align(ushort.sizeof) ubyte[8] message = [Icmp6Type.echo_reply, 0, 0, 0, 0x4f, 0x57, 0, 42];
    struct Replies
    {
        uint count;
        void receive(IPv6Addr, Duration) nothrow @nogc { ++count; }
    }
    Replies replies;
    _pending_echoes ~= PendingEcho(ip.src_addr, getTime(), &replies.receive, 42, first.id, Array!IPv6Addr.init, local);
    scope(exit) icmp6_echo_cancel(42);
    handle_echo_reply(ip, message[], second);
    handle_echo_reply(ip, message[], null);
    ip.dst_addr = IPv6Addr.any;
    handle_echo_reply(ip, message[], first);
    ip.dst_addr = local;
    assert(replies.count == 0);
    handle_echo_reply(ip, message[], first);
    assert(replies.count == 1);
    handle_echo_reply(ip, message[], first);
    assert(replies.count == 1);

    IPv6Addr multicast = IPv6Addr(0xff02, 0, 0, 0, 0, 0, 0, 1);
    _pending_echoes ~= PendingEcho(multicast, getTime(), &replies.receive, 42, first.id, Array!IPv6Addr.init, local);
    handle_echo_reply(ip, message[], second);
    assert(replies.count == 1);
    foreach (ushort host; 1 .. max_echo_responders + 2)
    {
        ip.src_addr = IPv6Addr(0xfe80, 0, 0, 0, 0, 0, 0, host);
        handle_echo_reply(ip, message[], first);
        handle_echo_reply(ip, message[], first);
    }
    assert(replies.count == 1 + max_echo_responders);
    icmp6_echo_cancel(42);
    handle_echo_reply(ip, message[], first);
    assert(replies.count == 1 + max_echo_responders);
}

unittest
{
    IPStack stack;
    IPv6Addr source = IPv6Addr(0x2001, 0xdb8, 1, 0, 0, 0, 0, 1);
    IPv6Addr destination = IPv6Addr(0x2001, 0xdb8, 2, 0, 0, 0, 0, 1);
    align(uint.sizeof) ubyte[104] data;
    auto ip = cast(IPv6Header*)data.ptr;
    ip.ver_tc_flow[0] = 0x60;
    ip.next_header = IPProtocol.icmp6;
    ip.src_addr = IPv6Addr(0x2001, 0xdb8, 3, 0, 0, 0, 0, 1);
    ip.dst_addr = source;
    auto quoted = cast(IPv6Header*)(data.ptr + 48);
    quoted.ver_tc_flow[0] = 0x60;
    quoted.src_addr = source;
    quoted.dst_addr = destination;
    quoted.next_header = IPProtocol.ipv6_opts;
    storeBigEndian(cast(ushort*)quoted.payload_length.ptr, ushort(40));
    data[88] = IPProtocol.icmp6;
    ubyte[8] echo = [Icmp6Type.echo_request, 0, 0, 0, 0x4f, 0x57, 0, 42];
    data[96 .. 104] = echo[];

    struct Errors
    {
        uint count;
        ubyte type;
        uint data;
        void receive(IPv6Addr, ubyte type, ubyte code, uint data) nothrow @nogc
        {
            ++count;
            this.type = type;
            this.data = data;
        }
    }
    Errors errors;
    void pending(IPv6Addr destination) nothrow @nogc
    {
        _pending_echoes ~= PendingEcho(destination, getTime(), null, 42, CID(), Array!IPv6Addr.init, source, &errors.receive);
    }
    void input(size_t length = data.length, bool corrupt = false) nothrow @nogc
    {
        storeBigEndian(cast(ushort*)ip.payload_length.ptr, cast(ushort)(length - 40));
        data[42 .. 44] = 0;
        ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)(length - 40), IPProtocol.icmp6);
        storeBigEndian(cast(ushort*)(data.ptr + 42), internet_checksum(data[40 .. length], pseudo));
        if (corrupt)
            data[42] ^= 1;
        Packet packet;
        packet.init!RawFrame(data[0 .. length]);
        icmp6_input(stack, packet, 40, null);
    }
    scope(exit) icmp6_echo_cancel(42);
    pending(destination);
    data[40] = Icmp6Type.packet_too_big;
    storeBigEndian(cast(uint*)(data.ptr + 44), uint(1280));
    input(data.length, true);
    foreach (length; 44 .. data.length)
        input(length);
    assert(errors.count == 0);
    quoted.dst_addr = source;
    input();
    quoted.dst_addr = destination;
    quoted.src_addr = destination;
    input();
    quoted.src_addr = source;
    ip.dst_addr = destination;
    input();
    ip.dst_addr = source;
    data[103] = 43;
    input();
    data[103] = 42;
    quoted.ver_tc_flow[0] = 0x40;
    input();
    quoted.ver_tc_flow[0] = 0x60;
    _pending_echoes[$ - 1].scope_iface = CID(1);
    input();
    _pending_echoes[$ - 1].scope_iface = CID();
    assert(errors.count == 0);
    input();
    input();
    assert(errors.count == 1 && errors.type == Icmp6Type.packet_too_big && errors.data == 1280);
    foreach (ubyte type; [1, 3, 4, 100])
    {
        pending(destination);
        data[40] = type;
        input();
        assert(errors.type == type);
    }
    assert(errors.count == 5);
    quoted.dst_addr = IPv6Addr(0xff02, 0, 0, 0, 0, 0, 0, 1);
    pending(quoted.dst_addr);
    input();
    input();
    assert(errors.count == 6);
    assert(_pending_echoes[$ - 1].sequence == 42);
    icmp6_echo_cancel(42);
    input();
    assert(errors.count == 6);
}
