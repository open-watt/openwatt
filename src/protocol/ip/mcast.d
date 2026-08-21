module protocol.ip.mcast;

version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.time;

import manager.base;
import manager.collection;
import manager.features : has_igmp;

import router.iface;
import router.iface.endpoint : foreach_ether_station;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

import protocol.ip : IPv4Header, IPv6Header, IPProtocol;
import protocol.ip.address;
import protocol.ip.icmp6;
import protocol.ip.nd : ether_multicast, link_local_for, solicited_node, read_addr, write_addr;
import protocol.ip.stack;

//version = DebugMcast;

private alias log = Log!"mcast";

nothrow @nogc:


enum IgmpType : ubyte
{
    query     = 0x11,
    report_v1 = 0x12,
    report_v2 = 0x16,
    leave     = 0x17,
    report_v3 = 0x22,
}

// 01:00:5e + low 23 bits of the group (RFC 1112)
MACAddress ether_multicast_v4(IPAddr a) pure
    => MACAddress(0x01, 0x00, 0x5E, a.b[1] & 0x7F, a.b[2], a.b[3]);


// Group membership: the stack's record of which multicast groups we listen on,
// per interface. Explicit joins (sockets, protocol modules) are refcounted;
// v6 solicited-node groups are derived from owned addresses by reconciliation.
// Membership drives both local delivery and IGMPv2/MLDv1 host signalling so
// snooping switches keep forwarding us the groups.
// NoIGMP strips the engine: joins are inert, only implicit groups deliver.

static if (has_igmp)
{

// iface null = all interfaces carrying an IPv4 address
void mcast_join_v4(IPAddr group, BaseInterface iface)
{
    if (!group.is_multicast || group == all_hosts_v4)
        return;
    foreach (ref e; _groups_v4[])
    {
        if (e.group == group && matches_iface(e, iface))
        {
            ++e.refs;
            return;
        }
    }
    GroupV4 e;
    e.group = group;
    e.iface = iface;
    e.all_ifaces = iface is null;
    e.refs = 1;
    e.pending = unsolicited_reports;
    e.due = getTime();
    _groups_v4 ~= e;
    _next_due = e.due;
    version (DebugMcast)
        log.debug_("join ", group, iface ? " on " : "", iface ? iface.name[] : "");
}

void mcast_leave_v4(IPAddr group, BaseInterface iface)
{
    foreach (i, ref e; _groups_v4[])
    {
        if (e.group != group || !matches_iface(e, iface))
            continue;
        if (--e.refs == 0)
        {
            if (e.last_reporter)
                send_igmp(e, IgmpType.leave);
            _groups_v4.removeSwapLast(i);
        }
        return;
    }
}

void mcast_join_v6(IPv6Addr group, BaseInterface iface)
{
    if (!group.is_multicast || group == IPv6Addr.linkLocal_allNodes || !iface)
        return;
    GroupV6* e = find_or_add_v6(group, iface);
    ++e.refs;
}

void mcast_leave_v6(IPv6Addr group, BaseInterface iface)
{
    foreach (i, ref e; _groups_v6[])
    {
        if (e.group != group || e.iface.get !is iface)
            continue;
        if (--e.refs == 0 && !e.derived)
        {
            if (e.last_reporter)
                send_mld(e, Icmp6Type.mld_done);
            _groups_v6.removeSwapLast(i);
        }
        return;
    }
}

bool is_member_v4(IPAddr group, BaseInterface iface)
{
    foreach (ref e; _groups_v4[])
        if (e.group == group && (e.all_ifaces || e.iface.get is iface))
            return true;
    return false;
}

bool is_member_v6(IPv6Addr group, BaseInterface iface)
{
    foreach (ref e; _groups_v6[])
        if (e.group == group && e.iface.get is iface)
            return true;
    return false;
}


// Reconciles derived v6 groups and emits due reports. Called from the stack's
// frame update beside the neighbour tick; early-outs keep the idle cost to two
// compares.
void mcast_update(MonoTime now)
{
    uint gen = route_generation();
    if (gen != _seen_gen || now >= _next_rescan)
    {
        _seen_gen = gen;
        _next_rescan = now + rescan_interval;
        reconcile_v6();
    }

    if (now < _next_due)
        return;
    _next_due = now + idle_wake;

    foreach (ref e; _groups_v4[])
    {
        if (e.pending && now >= e.due)
        {
            send_igmp(e, IgmpType.report_v2);
            if (--e.pending)
                e.due = now + unsolicited_interval;
        }
        if (e.pending && e.due < _next_due)
            _next_due = e.due;
    }
    foreach (ref e; _groups_v6[])
    {
        if (e.pending && now >= e.due)
        {
            send_mld(e, Icmp6Type.mld_report);
            if (--e.pending)
                e.due = now + unsolicited_interval;
        }
        if (e.pending && e.due < _next_due)
            _next_due = e.due;
    }
}


// Locally-delivered IGMP (proto 2); pkt.data is the whole IPv4 datagram.
void igmp_input(ref Packet pkt, BaseInterface iface)
{
    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t hdr_len = ip.ihl * 4;
    size_t total = ip.total_length.bigEndianToNative!ushort;
    if (total < hdr_len + 8 || total > pkt.data.length)
        return;
    const(ubyte)[] igmp = (cast(const(ubyte)*)pkt.data.ptr)[hdr_len .. total];
    if (internet_checksum(igmp) != 0)
        return;

    IPAddr group = IPAddr(igmp[4], igmp[5], igmp[6], igmp[7]);
    switch (igmp[0])
    {
        case IgmpType.query:
            // max-resp is 1/10s units; 0 is a v1 querier (fixed 10s window)
            uint window_ms = igmp[1] * 100;
            if (window_ms == 0 || window_ms > max_response_window_ms)
                window_ms = max_response_window_ms;
            schedule_responses_v4(iface, group, window_ms);
            break;
        case IgmpType.report_v1:
        case IgmpType.report_v2:
            // another member answered; suppress our response (RFC 2236 3)
            foreach (ref e; _groups_v4[])
            {
                if (e.group == group && (e.all_ifaces || e.iface.get is iface))
                {
                    e.pending = 0;
                    e.last_reporter = false;
                }
            }
            break;
        default:
            break;
    }
}

// MLD query/report, dispatched from icmp6_input.
void on_mld_query(ref const IPv6Header ip, const(ubyte)[] icmp, BaseInterface iface)
{
    if (icmp.length < 24)
        return;
    uint window_ms = icmp[4 .. 6].bigEndianToNative!ushort;
    if (icmp.length >= 28 && window_ms >= 0x8000)
    {
        // MLDv2 exponential max-resp code (RFC 3810 5.1.3)
        window_ms = ((window_ms & 0x0FFF) | 0x1000) << (((window_ms >> 12) & 7) + 3);
    }
    if (window_ms == 0 || window_ms > max_response_window_ms)
        window_ms = max_response_window_ms;
    IPv6Addr group = read_addr(icmp[8 .. 24]);

    MonoTime now = getTime();
    uint i = 0;
    foreach (ref e; _groups_v6[])
    {
        if (e.iface.get !is iface)
            continue;
        if (group != IPv6Addr.any && e.group != group)
            continue;
        MonoTime due = now + ((++i * 173) % window_ms).msecs;
        if (!e.pending || due < e.due)
        {
            e.pending = 1;
            e.due = due;
            if (due < _next_due)
                _next_due = due;
        }
    }
}

void on_mld_report(ref const IPv6Header ip, const(ubyte)[] icmp, BaseInterface iface)
{
    if (icmp.length < 24)
        return;
    IPv6Addr group = read_addr(icmp[8 .. 24]);
    foreach (ref e; _groups_v6[])
    {
        if (e.group == group && e.iface.get is iface)
        {
            e.pending = 0;
            e.last_reporter = false;
        }
    }
}


private:

enum IPAddr all_hosts_v4          = IPAddr(224, 0, 0, 1);
enum IPAddr all_routers_v4        = IPAddr(224, 0, 0, 2);
enum ubyte unsolicited_reports    = 2;
enum Duration unsolicited_interval = 1.seconds;
enum Duration rescan_interval     = 2.seconds;
enum Duration idle_wake           = 60.seconds;
enum uint max_response_window_ms  = 10_000;

struct GroupV4
{
    IPAddr group;
    ObjectRef!BaseInterface iface;
    bool all_ifaces;
    bool last_reporter;
    ubyte pending;
    ushort refs;
    MonoTime due;
}

struct GroupV6
{
    IPv6Addr group;
    ObjectRef!BaseInterface iface;
    bool derived;
    bool mark;
    bool last_reporter;
    ubyte pending;
    ushort refs;
    MonoTime due;
}

__gshared Array!GroupV4 _groups_v4;
__gshared Array!GroupV6 _groups_v6;
__gshared uint _seen_gen;
__gshared MonoTime _next_rescan;
__gshared MonoTime _next_due;

bool matches_iface(ref const GroupV4 e, BaseInterface iface)
    => e.all_ifaces ? iface is null : e.iface.get is iface;

GroupV6* find_or_add_v6(IPv6Addr group, BaseInterface iface)
{
    foreach (ref e; _groups_v6[])
        if (e.group == group && e.iface.get is iface)
            return &e;
    GroupV6 e;
    e.group = group;
    e.iface = iface;
    e.pending = unsolicited_reports;
    e.due = getTime();
    _groups_v6 ~= e;
    _next_due = e.due;
    version (DebugMcast)
        log.debug_("join ", group, " on ", iface.name[]);
    return &_groups_v6[$ - 1];
}

void want_derived_v6(IPv6Addr group, BaseInterface iface)
{
    if (group == IPv6Addr.linkLocal_allNodes || !iface)
        return;
    GroupV6* e = find_or_add_v6(group, iface);
    e.derived = true;
    e.mark = true;
}

void reconcile_v6()
{
    foreach (ref e; _groups_v6[])
        e.mark = false;

    foreach_ether_station((EthernetStation s) {
        if (s.running)
            want_derived_v6(solicited_node(link_local_for(s.mac)), s);
    });
    foreach (a; Collection!IPv6Address().values)
    {
        if (BaseInterface i = cast(BaseInterface)a.iface)
            want_derived_v6(solicited_node(a.address.addr), i);
    }

    for (size_t i = _groups_v6.length; i > 0; --i)
    {
        GroupV6* e = &_groups_v6[i - 1];
        if (e.derived && !e.mark)
        {
            e.derived = false;
            if (e.refs == 0)
            {
                if (e.last_reporter)
                    send_mld(*e, Icmp6Type.mld_done);
                _groups_v6.removeSwapLast(i - 1);
                continue;
            }
        }
        if (e.refs == 0 && !e.derived)
            _groups_v6.removeSwapLast(i - 1);
    }
}

void schedule_responses_v4(BaseInterface iface, IPAddr group, uint window_ms)
{
    MonoTime now = getTime();
    uint i = 0;
    foreach (ref e; _groups_v4[])
    {
        if (!e.all_ifaces && e.iface.get !is iface)
            continue;
        if (group != IPAddr.any && e.group != group)
            continue;
        MonoTime due = now + ((++i * 173) % window_ms).msecs;
        if (!e.pending || due < e.due)
        {
            e.pending = 1;
            e.due = due;
            if (due < _next_due)
                _next_due = due;
        }
    }
}

void send_igmp(ref GroupV4 e, IgmpType type)
{
    void send_on(EthernetStation s)
    {
        if (!s.running)
            return;

        IPAddr src = IPAddr.any;
        foreach (a; Collection!IPAddress().values)
        {
            if (cast(BaseInterface)a.iface is s)
            {
                src = a.address.addr;
                break;
            }
        }

        IPAddr dst = type == IgmpType.leave ? all_routers_v4 : e.group;

        // ihl=6: the 4-byte router-alert option IGMP requires (RFC 2236 2)
        ubyte[24 + 8] buf = void;
        auto ip = cast(IPv4Header*)buf.ptr;
        ip.ver_ihl = 0x46;
        ip.tos = 0;
        ip.total_length = nativeToBigEndian(cast(ushort)buf.length);
        ip.ident = nativeToBigEndian(next_ip_id());
        ip.flags_frag[] = 0;
        ip.ttl = 1;
        ip.protocol = IPProtocol.igmp;
        ip.checksum[] = 0;
        ip.src = src.b;
        ip.dst = dst.b;
        buf[20] = 0x94;
        buf[21] = 0x04;
        buf[22] = 0;
        buf[23] = 0;
        ip.checksum = internet_checksum(buf[0 .. 24]).nativeToBigEndian;

        buf[24] = type;
        buf[25] = 0;
        buf[26 .. 28] = 0;
        buf[28 .. 32] = e.group.b[];
        buf[26 .. 28] = internet_checksum(buf[24 .. 32]).nativeToBigEndian;

        version (DebugMcast)
            log.debug_("tx igmp type=", type, " group=", e.group, " on ", s.name[]);

        s.send(ether_multicast_v4(dst), buf[], EtherType.ip4);
    }

    if (type != IgmpType.leave)
        e.last_reporter = true;

    if (e.all_ifaces)
    {
        foreach_ether_station((EthernetStation s) {
            foreach (a; Collection!IPAddress().values)
            {
                if (cast(BaseInterface)a.iface is s)
                {
                    send_on(s);
                    break;
                }
            }
        });
    }
    else if (EthernetStation s = cast(EthernetStation)e.iface.get)
        send_on(s);
}

void send_mld(ref GroupV6 e, Icmp6Type type)
{
    EthernetStation s = cast(EthernetStation)e.iface.get;
    if (!s || !s.running)
        return;

    if (type == Icmp6Type.mld_report)
        e.last_reporter = true;

    IPv6Addr dst = type == Icmp6Type.mld_done ? IPv6Addr.linkLocal_routers : e.group;

    enum size_t icmp_len = 24;
    ubyte[IPv6Header.sizeof + 8 + icmp_len] buf = void;
    auto ip = cast(IPv6Header*)buf.ptr;
    ip.ver_tc_flow[] = 0;
    ip.ver_tc_flow[0] = 0x60;
    ip.payload_length = nativeToBigEndian(cast(ushort)(8 + icmp_len));
    ip.next_header = IPProtocol.hopopt;
    ip.hop_limit = 1;
    ip.src_addr = link_local_for(s.mac);
    ip.dst_addr = dst;

    // hop-by-hop router alert (RFC 2711), padded to 8 bytes
    ubyte* hbh = buf.ptr + IPv6Header.sizeof;
    hbh[0] = IPProtocol.icmp6;
    hbh[1] = 0;
    hbh[2] = 5;
    hbh[3] = 2;
    hbh[4] = 0;
    hbh[5] = 0;
    hbh[6] = 1;
    hbh[7] = 0;

    ubyte* icmp = hbh + 8;
    icmp[0] = type;
    icmp[1] = 0;
    icmp[2 .. 8] = 0;
    write_addr(icmp[8 .. 24], e.group);

    ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, icmp_len, IPProtocol.icmp6);
    icmp[2 .. 4] = internet_checksum(icmp[0 .. icmp_len], pseudo).nativeToBigEndian;

    version (DebugMcast)
        log.debug_("tx mld type=", type, " group=", e.group, " on ", s.name[]);

    s.send(ether_multicast(dst), buf[], EtherType.ip6);
}

}
else
{

void mcast_join_v4(IPAddr, BaseInterface) {}
void mcast_leave_v4(IPAddr, BaseInterface) {}
void mcast_join_v6(IPv6Addr, BaseInterface) {}
void mcast_leave_v6(IPv6Addr, BaseInterface) {}
bool is_member_v4(IPAddr, BaseInterface) => false;
bool is_member_v6(IPv6Addr, BaseInterface) => false;
void mcast_update(MonoTime) {}
void igmp_input(ref Packet, BaseInterface) {}
void on_mld_query(ref const IPv6Header, const(ubyte)[], BaseInterface) {}
void on_mld_report(ref const IPv6Header, const(ubyte)[], BaseInterface) {}

}
