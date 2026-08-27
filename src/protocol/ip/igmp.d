module protocol.ip.igmp;

version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.time;

import router.iface;
import router.iface.packet;

import protocol.ip : IPv4Header, IPProtocol;
import protocol.ip.address;
import protocol.ip.stack;

nothrow @nogc:


bool igmp_join(ref IPStack stack, IPAddr group, IPAddr local)
{
    if (!group.is_multicast || !interface_for_address(local))
        return false;
    foreach (ref membership; _memberships[])
    {
        if (membership.group == group && membership.local == local)
        {
            ++membership.references;
            return true;
        }
    }

    Membership membership;
    membership.group = group;
    membership.local = local;
    membership.references = 1;
    if (group != all_systems)
    {
        bool sent = send_report(stack, membership);
        membership.report_due = getTime() + (sent ? random_delay(10.seconds) : 1.seconds);
    }
    _memberships ~= membership;
    return true;
}

void igmp_leave(ref IPStack stack, IPAddr group, IPAddr local)
{
    foreach (i, ref membership; _memberships[])
    {
        if (membership.group != group || membership.local != local)
            continue;
        if (--membership.references != 0)
            return;
        if (membership.last_reporter)
            send_message(stack, IgmpType.leave_group, membership.local, membership.group, all_routers);
        _memberships.removeSwapLast(i);
        return;
    }
}

void igmp_update(ref IPStack stack, MonoTime now)
{
    foreach (ref membership; _memberships[])
    {
        if (!membership.report_due || now < membership.report_due)
            continue;
        if (send_report(stack, membership))
            membership.report_due = MonoTime();
        else
            membership.report_due = now + 1.seconds;
    }
}

void igmp_input(ref Packet packet, BaseInterface iface)
{
    if (packet.data.length < IPv4Header.sizeof + IgmpHeader.sizeof)
        return;
    const ip = cast(const(IPv4Header)*)packet.data.ptr;
    size_t ip_header_length = ip.ihl * 4;
    size_t total = ip.total_length.bigEndianToNative!ushort;
    if (total < ip_header_length + IgmpHeader.sizeof || total > packet.data.length)
        return;
    const(ubyte)[] payload = (cast(const(ubyte)*)packet.data.ptr)[ip_header_length .. total];
    if (internet_checksum(payload) != 0)
        return;
    const header = cast(const(IgmpHeader)*)payload.ptr;
    IPAddr group = IPAddr(header.group);

    if (header.type == IgmpType.membership_query)
    {
        Duration window = response_window(header.max_response_code);
        MonoTime now = getTime();
        foreach (ref membership; _memberships[])
        {
            if (membership.group == all_systems || !interface_has_address(iface, membership.local))
                continue;
            if (group != IPAddr.any && membership.group != group)
                continue;
            MonoTime due = now + random_delay(window);
            if (!membership.report_due || due < membership.report_due)
                membership.report_due = due;
        }
    }
    else if (header.type == IgmpType.membership_report_v1 || header.type == IgmpType.membership_report_v2)
    {
        foreach (ref membership; _memberships[])
        {
            if (membership.group == group && interface_has_address(iface, membership.local))
            {
                membership.report_due = MonoTime();
                membership.last_reporter = false;
            }
        }
    }
}


private:

enum IPAddr all_systems = IPAddr(224, 0, 0, 1);
enum IPAddr all_routers = IPAddr(224, 0, 0, 2);

enum IgmpType : ubyte
{
    membership_query     = 0x11,
    membership_report_v1 = 0x12,
    membership_report_v2 = 0x16,
    leave_group          = 0x17,
}

struct IgmpHeader
{
    ubyte type;
    ubyte max_response_code;
    ubyte[2] checksum;
    ubyte[4] group;
}
static assert(IgmpHeader.sizeof == 8);

struct Membership
{
    IPAddr group;
    IPAddr local;
    uint references;
    MonoTime report_due;
    bool last_reporter;
}

align(size_t.sizeof) struct MessageBuffer
{
nothrow @nogc:

    inout(ubyte)[] bytes() inout
        => (cast(inout(ubyte)*)words.ptr)[0 .. words.sizeof];

    uint[(IPv4Header.sizeof + 4 + IgmpHeader.sizeof) / uint.sizeof] words;
}

__gshared Array!Membership _memberships;

Duration response_window(ubyte code) pure
{
    if (code == 0)
        return 10.seconds;
    return (code * 100).msecs;
}

bool send_report(ref IPStack stack, ref Membership membership)
{
    if (!send_message(stack, IgmpType.membership_report_v2, membership.local, membership.group, membership.group))
        return false;
    membership.last_reporter = true;
    return true;
}

bool send_message(ref IPStack stack, IgmpType type, IPAddr local, IPAddr group, IPAddr destination)
{
    BaseInterface iface = interface_for_address(local);
    if (!iface || !iface.running)
        return false;

    MessageBuffer buffer = void;
    write_message(buffer, type, local, group, destination, next_ip_id());

    Packet packet;
    packet.init!RawFrame(buffer.bytes);
    stack.output_v4_routed(packet, iface, destination);
    return true;
}

void write_message(ref MessageBuffer buffer, IgmpType type, IPAddr local, IPAddr group, IPAddr destination, ushort identifier)
{
    storeBigEndian(&buffer.words[0], 0x4600_0000u | cast(uint)buffer.words.sizeof);
    storeBigEndian(&buffer.words[1], cast(uint)identifier << 16);
    storeBigEndian(&buffer.words[2], 0x0102_0000u);
    buffer.words[3] = local.address;
    buffer.words[4] = destination.address;
    storeBigEndian(&buffer.words[5], 0x9404_0000u);
    storeBigEndian(&buffer.words[6], cast(uint)type << 24);
    buffer.words[7] = group.address;

    ubyte[] bytes = buffer.bytes;
    ubyte[] ip_header = bytes[0 .. IPv4Header.sizeof + 4];
    ubyte[] igmp = bytes[IPv4Header.sizeof + 4 .. $];
    storeBigEndian(cast(ushort*)(ip_header.ptr + 10), internet_checksum(ip_header));
    storeBigEndian(cast(ushort*)(igmp.ptr + 2), internet_checksum(igmp));
}


unittest
{
    assert(response_window(0) == 10.seconds);
    assert(response_window(10) == 1.seconds);
    assert(response_window(128) == 12_800.msecs);
    assert(response_window(255) == 25_500.msecs);

    IPAddr local = IPAddr(192, 168, 1, 2);
    IPAddr group = IPAddr(239, 255, 79, 87);
    MessageBuffer buffer = void;
    write_message(buffer, IgmpType.membership_report_v2, local, group, group, 0x1234);
    const(ubyte)[] bytes = buffer.bytes;
    const ip = cast(const(IPv4Header)*)bytes.ptr;
    assert(ip.ihl == 6 && ip.ttl == 1 && ip.protocol == IPProtocol.igmp);
    assert(IPAddr(ip.src) == local && IPAddr(ip.dst) == group);
    assert(internet_checksum(bytes[0 .. IPv4Header.sizeof + 4]) == 0);
    assert(bytes[IPv4Header.sizeof .. IPv4Header.sizeof + 4] == [0x94, 4, 0, 0]);
    assert(internet_checksum(bytes[IPv4Header.sizeof + 4 .. $]) == 0);

    _memberships.clear();
    scope(exit) _memberships.clear();
    IPStack stack;
    MonoTime now = getTime() + 1.seconds;
    Membership pending;
    pending.group = group;
    pending.references = 1;
    pending.report_due = now;
    _memberships ~= pending;
    igmp_update(stack, now);
    assert(_memberships[0].report_due == now + 1.seconds);
}
