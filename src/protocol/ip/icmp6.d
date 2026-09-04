module protocol.ip.icmp6;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.log;
import urt.time;

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

ushort icmp6_echo_send(ref IPStack stack, IPv6Addr destination, BaseInterface iface_hint, Echo6Handler handler)
{
    IPv6Addr source = stack.select_source_v6(destination, iface_hint);
    if (source == IPv6Addr.any)
        return 0;

    ushort sequence = _next_echo_sequence++;
    if (sequence == 0)
        sequence = _next_echo_sequence++;

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

    _pending_echoes ~= PendingEcho(destination, getTime(), handler, sequence);

    Packet packet;
    packet.init!RawFrame(buffer[]);
    if ((destination.is_link_local || destination.is_multicast) && iface_hint)
        stack.output_v6_routed(packet, iface_hint, destination);
    else
        stack.output_v6(packet);
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
    if (packet.data.length < offset + Icmp6Header.sizeof)
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
            if (message[1] == 0)
                handle_echo_request(stack, packet, offset, datagram_end, iface);
            break;
        case Icmp6Type.echo_reply:
            if (message[1] == 0)
                handle_echo_reply(*ip, message);
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
            on_router_solicit(stack, *ip, message, iface);
            break;
        case Icmp6Type.router_advert:
            on_router_advert(stack, *ip, message, iface);
            break;
        case Icmp6Type.dest_unreachable:
        case Icmp6Type.packet_too_big:
            break;
        default:
            break;
    }
}


private:

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

    size_t offset, next_header_offset;
    IPProtocol protocol;
    if (!stack.upper_protocol_v6(original.data, offset, next_header_offset, protocol))
        return false;
    if (protocol == IPProtocol.icmp6 && original.data.length > offset)
        return (cast(const(ubyte)*)original.data.ptr)[offset] >= 128;
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
        stack.output_v6_routed(*reply, iface, reply_ip.dst_addr);
    else
        stack.output_v6(*reply);
}

void handle_echo_reply(ref const IPv6Header ip, const(ubyte)[] message)
{
    if (message.length < 8 || loadBigEndian(cast(const(ushort)*)(message.ptr + 4)) != echo_identifier)
        return;
    ushort sequence = loadBigEndian(cast(const(ushort)*)(message.ptr + 6));

    foreach (i, ref pending; _pending_echoes[])
    {
        if (pending.destination == ip.src_addr && pending.sequence == sequence)
        {
            Echo6Handler handler = pending.handler;
            MonoTime sent = pending.sent;
            _pending_echoes.removeSwapLast(i);
            if (handler)
                handler(ip.src_addr, getTime() - sent);
            return;
        }
    }
}

struct PendingEcho
{
    IPv6Addr destination;
    MonoTime sent;
    Echo6Handler handler;
    ushort sequence;
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
}
