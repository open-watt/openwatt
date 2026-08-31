module protocol.ip.mld;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.time;
import urt.util : max;

import manager.base;
import manager.collection;

import router.iface;
import router.iface.packet;

import protocol.ip : IPv6Header, IPProtocol, load_ipv6_address, pseudo_header_checksum_v6, store_ipv6_address;
import protocol.ip.address;
import protocol.ip.icmp6 : Icmp6Type;
import protocol.ip.stack;

nothrow @nogc:


bool mld_join(ref IPStack stack, IPv6Addr group, BaseInterface iface)
{
    if (!group.is_multicast || !iface || (iface.flags & ObjectFlags.slave))
        return false;
    if (group == all_nodes)
        return true;
    ubyte scope_ = ubyte(group.s[0] & 0xF);
    if (scope_ == 0)
        return false;

    foreach (ref membership; _memberships[])
    {
        if (membership.group == group && membership.iface.get is iface)
        {
            ++membership.references;
            return true;
        }
    }

    Membership membership;
    membership.group = group;
    membership.iface = iface;
    membership.references = 1;
    membership.online = iface.running;
    if (requires_report(group))
    {
        bool sent = send_report(stack, membership);
        membership.report_due = getTime() + (sent ? random_delay(10.seconds) : 1.seconds);
    }
    _memberships ~= membership;
    return true;
}

void mld_leave(ref IPStack stack, IPv6Addr group, BaseInterface iface)
{
    foreach (i, ref membership; _memberships[])
    {
        if (membership.group != group || membership.iface.get !is iface)
            continue;
        if (--membership.references != 0)
            return;
        if (membership.last_reporter && requires_report(group))
            send_message(stack, Icmp6Type.listener_done, membership, all_routers);
        _memberships.removeSwapLast(i);
        return;
    }
}

bool mld_accepts(IPv6Addr group, BaseInterface iface)
{
    if (!iface || (iface.flags & ObjectFlags.slave))
        return false;
    if (group == all_nodes)
        return true;
    foreach (ref membership; _memberships[])
        if (membership.group == group && membership.iface.get is iface)
            return true;
    return false;
}

void mld_update(ref IPStack stack, MonoTime now)
{
    for (size_t i = _memberships.length; i > 0; --i)
    {
        ref membership = _memberships[i - 1];
        BaseInterface iface = membership.iface.get;
        if (!iface)
        {
            _memberships.removeSwapLast(i - 1);
            continue;
        }

        bool online = iface.running && !(iface.flags & ObjectFlags.slave);
        if (online != membership.online)
        {
            membership.online = online;
            if (online && requires_report(membership.group))
                membership.report_due = now;
        }
        if (!online || !requires_report(membership.group))
            continue;

        IPv6Addr source = link_local_source(iface);
        if (source != membership.report_source)
            membership.report_due = now;
        if (!membership.report_due || now < membership.report_due)
            continue;
        if (send_report(stack, membership))
            membership.report_due = MonoTime();
        else
            membership.report_due = now + 1.seconds;
    }
}

void mld_input(ref Packet packet, size_t offset, BaseInterface iface)
{
    if (!iface || packet.data.length < offset + MldHeader.sizeof)
        return;
    const ip = cast(const IPv6Header*)packet.data.ptr;
    if (ip.hop_limit != 1)
        return;

    const message = cast(const MldHeader*)((cast(const(ubyte)*)packet.data.ptr) + offset);
    if (message.code != 0)
        return;
    IPv6Addr group = load_ipv6_address(message.multicast_address.ptr);
    if (message.type == Icmp6Type.listener_query)
    {
        if (!ip.src_addr.is_link_local || (group != IPv6Addr.any && !group.is_multicast))
            return;
        if ((group == IPv6Addr.any && ip.dst_addr != all_nodes) || (group != IPv6Addr.any && ip.dst_addr != group))
            return;
        Duration window = response_window(loadBigEndian(cast(const(ushort)*)message.maximum_response_delay.ptr), packet.data.length - offset);
        MonoTime now = getTime();
        foreach (ref membership; _memberships[])
        {
            if (membership.iface.get !is iface || !requires_report(membership.group) || (group != IPv6Addr.any && membership.group != group))
                continue;
            MonoTime due = window > Duration.zero ? now + random_delay(window) : now;
            if (!membership.report_due || due < membership.report_due)
                membership.report_due = due;
        }
    }
    else if (message.type == Icmp6Type.listener_report)
    {
        if (!ip.src_addr.is_link_local || ip.dst_addr != group)
            return;
        foreach (ref membership; _memberships[])
        {
            if (membership.group == group && membership.iface.get is iface && requires_report(group))
            {
                membership.report_due = MonoTime();
                membership.last_reporter = false;
            }
        }
    }
}


private:

enum IPv6Addr all_nodes = IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 1);
enum IPv6Addr all_routers = IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 2);

struct MldHeader
{
    ubyte type;
    ubyte code;
    ubyte[2] checksum;
    ubyte[2] maximum_response_delay;
    ubyte[2] reserved;
    ubyte[16] multicast_address;
}
static assert(MldHeader.sizeof == 24);

struct Membership
{
    IPv6Addr group;
    ObjectRef!BaseInterface iface;
    IPv6Addr report_source;
    MonoTime report_due;
    uint references;
    bool last_reporter;
    bool online;
}

enum message_align = max(IPv6Header.alignof, ushort.alignof);

align(message_align) struct MessageBuffer
{
    ubyte[72] bytes;
}
static assert(MessageBuffer.sizeof == 72);

__gshared Array!Membership _memberships;

bool requires_report(IPv6Addr group) pure
    => group != all_nodes && (group.s[0] & 0xF) > 1;

IPv6Addr link_local_source(BaseInterface iface)
{
    foreach (address; Collection!IPv6Address().values)
        if (address.iface is iface && address.address.addr.is_link_local)
            return address.address.addr;
    return IPv6Addr.any;
}

Duration response_window(ushort code, size_t message_length) pure
{
    if (message_length < 28 || (code & 0x8000) == 0)
        return code.msecs;
    uint mantissa = (code & 0x0FFF) | 0x1000;
    uint exponent = (code >> 12) & 7;
    return (mantissa << (exponent + 3)).msecs;
}

bool has_router_alert(const(void)[] data, size_t icmp_offset) pure
{
    if (data.length < IPv6Header.sizeof + 8 || icmp_offset < IPv6Header.sizeof + 8)
        return false;
    const bytes = cast(const(ubyte)[])data;
    const ip = cast(const IPv6Header*)data.ptr;
    if (ip.next_header != IPProtocol.hopopt)
        return false;

    size_t end = IPv6Header.sizeof + (bytes[IPv6Header.sizeof + 1] + 1) * 8;
    if (end > data.length || end > icmp_offset)
        return false;
    size_t cursor = IPv6Header.sizeof + 2;
    while (cursor < end)
    {
        ubyte type = bytes[cursor];
        if (type == 0)
        {
            ++cursor;
            continue;
        }
        if (cursor + 2 > end)
            return false;
        size_t option_end = cursor + 2 + bytes[cursor + 1];
        if (option_end > end)
            return false;
        if (type == 5 && bytes[cursor + 1] == 2 && bytes[cursor + 2] == 0 && bytes[cursor + 3] == 0)
            return true;
        cursor = option_end;
    }
    return false;
}

bool send_report(ref IPStack stack, ref Membership membership)
{
    if (!send_message(stack, Icmp6Type.listener_report, membership, membership.group))
        return false;
    membership.last_reporter = true;
    return true;
}

bool send_message(ref IPStack stack, Icmp6Type type, ref Membership membership, IPv6Addr destination)
{
    BaseInterface iface = membership.iface.get;
    if (!iface || !iface.running || (iface.flags & ObjectFlags.slave))
        return false;

    IPv6Addr source = link_local_source(iface);
    MessageBuffer buffer = void;
    write_message(buffer, type, source, membership.group, destination);
    membership.report_source = source;

    Packet packet;
    packet.init!RawFrame(buffer.bytes[]);
    stack.output_v6_routed(packet, iface, destination);
    return true;
}

void write_message(ref MessageBuffer buffer, Icmp6Type type, IPv6Addr source, IPv6Addr group, IPv6Addr destination)
{
    ubyte[] bytes = buffer.bytes[];
    auto ip = cast(IPv6Header*)bytes.ptr;
    ip.ver_tc_flow[] = 0;
    ip.ver_tc_flow[0] = 0x60;
    storeBigEndian(cast(ushort*)ip.payload_length.ptr, cast(ushort)(8 + MldHeader.sizeof));
    ip.next_header = IPProtocol.hopopt;
    ip.hop_limit = 1;
    ip.src_addr = source;
    ip.dst_addr = destination;

    ubyte[] hop = bytes[IPv6Header.sizeof .. IPv6Header.sizeof + 8];
    hop[0] = IPProtocol.icmp6;
    hop[1] = 0;
    hop[2] = 5;
    hop[3] = 2;
    storeBigEndian(cast(ushort*)(hop.ptr + 4), ushort(0));
    hop[6] = 1;
    hop[7] = 0;

    ubyte[] message = bytes[IPv6Header.sizeof + 8 .. $];
    message[] = 0;
    message[0] = type;
    store_ipv6_address(message.ptr + 8, group);
    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)message.length, IPProtocol.icmp6);
    storeBigEndian(cast(ushort*)(message.ptr + 2), internet_checksum(message, pseudo));
}


unittest
{
    assert(!requires_report(IPv6Addr(0xFF01, 0, 0, 0, 0, 0, 0, 1)));
    assert(!requires_report(all_nodes));
    assert(requires_report(IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 3)));

    assert(response_window(0, 24) == Duration.zero);
    assert(response_window(1_000, 24) == 1.seconds);
    assert(response_window(0x9C40, 24) == 40.seconds);
    assert(response_window(0x9C40, 28) == 115_712.msecs);

    IPv6Addr source = IPv6Addr(0xFE80, 0, 0, 0, 0, 0, 0, 1);
    IPv6Addr group = IPv6Addr(0xFF02, 0, 0, 0, 0, 1, 0xFF00, 1);
    MessageBuffer buffer = void;
    write_message(buffer, Icmp6Type.listener_report, source, group, group);
    const(ubyte)[] bytes = buffer.bytes[];
    const ip = cast(const IPv6Header*)bytes.ptr;
    assert(ip.hop_limit == 1 && ip.next_header == IPProtocol.hopopt);
    assert(ip.src_addr == source && ip.dst_addr == group);
    assert(has_router_alert(bytes, IPv6Header.sizeof + 8));
    const(ubyte)[] message = bytes[IPv6Header.sizeof + 8 .. $];
    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)message.length, IPProtocol.icmp6);
    assert(internet_checksum(message, pseudo) == 0);
}
