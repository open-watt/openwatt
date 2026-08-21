module router.iface.snoop;

import urt.array;
import urt.endian;
import urt.inet : IPv6Addr;
import urt.log;
import urt.time;

import manager.features : has_igmp;

import router.iface.mac;
import router.iface.packet;

nothrow @nogc:


// L2 snooping support for the bridge: multicast group learning from IGMP/MLD
// control traffic, and DHCP server-role detection for port trust filtering.
// Self-contained frame peeks only; the router layer stays free of protocol/ip.

static if (has_igmp)
{

enum Duration membership_timeout  = 260.seconds;    // RFC 3376 group membership interval
enum Duration router_port_timeout = 255.seconds;    // RFC 3376 other-querier-present interval


struct MulticastSnoop
{
nothrow @nogc:

    struct PortEntry
    {
        ubyte port;
        MonoTime expiry;
    }

    struct Group
    {
        ulong address;      // universal dst address of the group (mac | vlan | type)
        Array!PortEntry members;
    }

    // Inspects a frame entering the switch; learns group membership from
    // reports and router ports from queries. Returns true for IGMP/MLD control
    // frames, which must flood rather than be masked by the tables they build.
    bool snoop(ref Packet packet, ubyte src_port, ubyte num_ports)
    {
        MonoTime now = packet.creation_time;
        if (now >= _next_sweep)
            sweep(now);

        ushort ether_type;
        const(ubyte)[] l3 = l3_of(packet, ether_type);
        if (!l3.length)
            return false;

        bool learn = src_port < num_ports;

        if (ether_type == EtherType.ip4)
        {
            if (l3.length < 20 || (l3[0] >> 4) != 4)
                return false;
            size_t hdr_len = (l3[0] & 0x0F) * 4;
            if (l3[9] != 2 || l3.length < hdr_len + 8)
                return false;
            const(ubyte)[] igmp = l3[hdr_len .. $];
            switch (igmp[0])
            {
                case 0x11:      // query
                    if (learn)
                        mark_router_port(src_port, now);
                    break;
                case 0x12:      // v1 report
                case 0x16:      // v2 report
                    if (learn)
                        join(group_key_v4(igmp[4 .. 8], packet.vlan), src_port, now);
                    break;
                case 0x22:      // v3 report
                    if (learn)
                        snoop_v3_records(igmp, packet.vlan, src_port, now);
                    break;
                default:        // 0x17 leave: expiry handles departure
                    break;
            }
            return true;
        }

        if (ether_type == EtherType.ip6)
        {
            if (l3.length < 40 || (l3[0] >> 4) != 6)
                return false;
            ubyte next = l3[6];
            size_t offset = 40;
            for (int depth = 0; depth < 4; ++depth)
            {
                if (next == 58)
                    break;
                if (next != 0 && next != 43 && next != 60)
                    return false;
                if (l3.length < offset + 8)
                    return false;
                next = l3[offset];
                offset += (l3[offset + 1] + 1) * 8;
            }
            if (next != 58 || l3.length < offset + 4)
                return false;
            const(ubyte)[] icmp = l3[offset .. $];
            switch (icmp[0])
            {
                case 130:       // query
                    if (learn)
                        mark_router_port(src_port, now);
                    return true;
                case 131:       // MLDv1 report
                    if (learn && icmp.length >= 24)
                        join(group_key_v6(icmp[8 .. 24], packet.vlan), src_port, now);
                    return true;
                case 132:       // done: expiry handles departure
                    return true;
                case 143:       // MLDv2 report
                    if (learn)
                        snoop_mld2_records(icmp, packet.vlan, src_port, now);
                    return true;
                default:
                    return false;
            }
        }

        return false;
    }

    // Returns the member-port set for a registered group, or null to flood.
    const(Group)* lookup(ulong dst_address)
    {
        foreach (ref g; _groups[])
        {
            if (g.address == dst_address)
                return g.members.length ? &g : null;
        }
        return null;
    }

    bool group_member(ref const Group g, ubyte port) const
    {
        foreach (ref m; g.members[])
            if (m.port == port)
                return true;
        return false;
    }

    bool router_port(ubyte port) const
    {
        foreach (ref r; _router_ports[])
            if (r.port == port)
                return true;
        return false;
    }

    int opApply(scope int delegate(ref const Group g) nothrow @nogc dg) const
    {
        foreach (ref g; _groups[])
        {
            if (int r = dg(g))
                return r;
        }
        return 0;
    }

    void clear()
    {
        _groups.clear();
        _router_ports.clear();
    }

private:

    Array!Group _groups;
    Array!PortEntry _router_ports;
    MonoTime _next_sweep;

    void join(ulong key, ubyte port, MonoTime now)
    {
        if (!key)
            return;
        foreach (ref g; _groups[])
        {
            if (g.address != key)
                continue;
            foreach (ref m; g.members[])
            {
                if (m.port == port)
                {
                    m.expiry = now + membership_timeout;
                    return;
                }
            }
            g.members ~= PortEntry(port, now + membership_timeout);
            return;
        }
        Group g;
        g.address = key;
        g.members ~= PortEntry(port, now + membership_timeout);
        _groups ~= g;
    }

    void mark_router_port(ubyte port, MonoTime now)
    {
        foreach (ref r; _router_ports[])
        {
            if (r.port == port)
            {
                r.expiry = now + router_port_timeout;
                return;
            }
        }
        _router_ports ~= PortEntry(port, now + router_port_timeout);
    }

    void snoop_v3_records(const(ubyte)[] igmp, ushort vlan, ubyte port, MonoTime now)
    {
        size_t n = be16(igmp, 6);
        size_t offset = 8;
        foreach (_; 0 .. n)
        {
            if (igmp.length < offset + 8)
                return;
            ubyte rec_type = igmp[offset];
            size_t nsrc = be16(igmp, offset + 2);
            // exclude-mode and allow records are joins; include with sources too;
            // include with no sources is a leave, which expiry handles
            bool is_join = rec_type == 2 || rec_type == 4 || rec_type == 5 ||
                           ((rec_type == 1 || rec_type == 3) && nsrc > 0);
            if (is_join)
                join(group_key_v4(igmp[offset + 4 .. offset + 8], vlan), port, now);
            offset += 8 + nsrc * 4 + igmp[offset + 1] * 4;
        }
    }

    void snoop_mld2_records(const(ubyte)[] icmp, ushort vlan, ubyte port, MonoTime now)
    {
        if (icmp.length < 8)
            return;
        size_t n = be16(icmp, 6);
        size_t offset = 8;
        foreach (_; 0 .. n)
        {
            if (icmp.length < offset + 20)
                return;
            ubyte rec_type = icmp[offset];
            size_t nsrc = be16(icmp, offset + 2);
            bool is_join = rec_type == 2 || rec_type == 4 || rec_type == 5 ||
                           ((rec_type == 1 || rec_type == 3) && nsrc > 0);
            if (is_join)
                join(group_key_v6(icmp[offset + 4 .. offset + 20], vlan), port, now);
            offset += 20 + nsrc * 16 + icmp[offset + 1] * 4;
        }
    }

    void sweep(MonoTime now)
    {
        _next_sweep = now + 30.seconds;
        for (size_t i = _groups.length; i > 0; --i)
        {
            ref Group g = _groups[i - 1];
            for (size_t m = g.members.length; m > 0; --m)
            {
                if (now >= g.members[m - 1].expiry)
                    g.members.removeSwapLast(m - 1);
            }
            if (g.members.length == 0)
                _groups.removeSwapLast(i - 1);
        }
        for (size_t i = _router_ports.length; i > 0; --i)
        {
            if (now >= _router_ports[i - 1].expiry)
                _router_ports.removeSwapLast(i - 1);
        }
    }
}

}


// True for DHCP frames only a server (or relay) may originate: v4 UDP source
// port 67, v6 UDP source port 547. Untrusted bridge ports drop these.
bool is_dhcp_server_frame(ref const Packet packet)
{
    ushort ether_type;
    const(ubyte)[] l3 = l3_of(packet, ether_type);

    if (ether_type == EtherType.ip4)
    {
        if (l3.length < 20 || (l3[0] >> 4) != 4)
            return false;
        size_t hdr_len = (l3[0] & 0x0F) * 4;
        if (l3[9] != 17 || l3.length < hdr_len + 4)
            return false;
        // ignore non-first fragments (no udp header to check)
        if ((l3[6] & 0x1F) != 0 || l3[7] != 0)
            return false;
        return be16(l3, hdr_len) == 67;
    }

    if (ether_type == EtherType.ip6)
    {
        if (l3.length < 40 || (l3[0] >> 4) != 6)
            return false;
        ubyte next = l3[6];
        size_t offset = 40;
        for (int depth = 0; depth < 4; ++depth)
        {
            if (next == 17)
                break;
            if (next != 0 && next != 43 && next != 60)
                return false;
            if (l3.length < offset + 8)
                return false;
            next = l3[offset];
            offset += (l3[offset + 1] + 1) * 8;
        }
        if (next != 17 || l3.length < offset + 2)
            return false;
        return be16(l3, offset) == 547;
    }

    return false;
}


private:

ushort be16(const(ubyte)[] b, size_t offset) pure
    => cast(ushort)(b[offset] << 8 | b[offset + 1]);

// Ethernet payload and effective ether_type, looking through an in-band
// 802.1Q tag (present when the bridge is not vlan-filtering).
const(ubyte)[] l3_of(ref const Packet packet, out ushort ether_type)
{
    if (packet.type != PacketType.ethernet)
        return null;
    const(ubyte)[] data = cast(const(ubyte)[])packet.data;
    ether_type = packet.hdr!Ethernet().ether_type;
    if (ether_type == EtherType.vlan)
    {
        if (data.length < 4)
            return null;
        ether_type = data[2 .. 4].bigEndianToNative!ushort;
        data = data[4 .. $];
    }
    return data;
}

static if (has_igmp)
{

ulong group_key_v4(const(ubyte)[] group, ushort vlan)
{
    // 224.0.0.0/24 is never snooped: local-segment control groups always flood
    if (group[0] == 224 && group[1] == 0 && group[2] == 0)
        return 0;
    MACAddress m = MACAddress(0x01, 0x00, 0x5E, group[1] & 0x7F, group[2], group[3]);
    return m.ul | (ulong(vlan & 0xFFF) << 48) | (ulong(PacketType.ethernet) << 60);
}

ulong group_key_v6(const(ubyte)[] group, ushort vlan)
{
    MACAddress m = MACAddress(0x33, 0x33, group[12], group[13], group[14], group[15]);
    return m.ul | (ulong(vlan & 0xFFF) << 48) | (ulong(PacketType.ethernet) << 60);
}

}


static if (has_igmp)
unittest
{
    // IGMPv2 report for 239.1.2.3 on port 2 constrains lookup; query marks router port
    MulticastSnoop snoop;

    static immutable ubyte[4] group_a = [239, 1, 2, 3];
    static immutable ubyte[4] group_b = [224, 0, 0, 251];

    ubyte[28] igmp_report;
    igmp_report[0] = 0x45;
    igmp_report[9] = 2;
    igmp_report[20] = 0x16;
    igmp_report[24 .. 28] = group_a[];

    Packet p;
    ref eth = p.init!Ethernet(igmp_report[]);
    eth.ether_type = EtherType.ip4;

    assert(snoop.snoop(p, 2, 4));
    ulong key = MACAddress(0x01, 0x00, 0x5E, 1, 2, 3).ul | (ulong(PacketType.ethernet) << 60);
    auto g = snoop.lookup(key);
    assert(g && snoop.group_member(*g, 2) && !snoop.group_member(*g, 1));

    // 224.0.0.x reports never register
    igmp_report[24 .. 28] = group_b[];
    assert(snoop.snoop(p, 2, 4));
    assert(snoop.lookup(MACAddress(0x01, 0x00, 0x5E, 0, 0, 251).ul | (ulong(PacketType.ethernet) << 60)) is null);

    ubyte[28] igmp_query;
    igmp_query[0] = 0x45;
    igmp_query[9] = 2;
    igmp_query[20] = 0x11;
    ref eth2 = p.init!Ethernet(igmp_query[]);
    eth2.ether_type = EtherType.ip4;
    assert(snoop.snoop(p, 1, 4));
    assert(snoop.router_port(1) && !snoop.router_port(2));
}

unittest
{
    // DHCP: server frame (sport 67) detected, client frame (sport 68) passed
    ubyte[28] dhcp;
    dhcp[0] = 0x45;
    dhcp[9] = 17;
    dhcp[21] = 67;
    Packet p;
    ref eth = p.init!Ethernet(dhcp[]);
    eth.ether_type = EtherType.ip4;
    assert(is_dhcp_server_frame(p));
    dhcp[21] = 68;
    assert(!is_dhcp_server_frame(p));
}
