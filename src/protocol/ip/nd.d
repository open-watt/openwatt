module protocol.ip.nd;

version (UseInternalIPStack):

import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;

import manager.collection;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

import protocol.ip : IPv6Header, IPProtocol;
import protocol.ip.address;
import protocol.ip.icmp6;
import protocol.ip.neighbour;
import protocol.ip.stack;

//version = DebugND;

nothrow @nogc:


enum NDOption : ubyte
{
    source_link_addr = 1,
    target_link_addr = 2,
    prefix_info      = 3,
    redirected_hdr   = 4,
    mtu              = 5,
}


// ff02::1:ffXX:XXXX carrying the low 24 bits of the target address
IPv6Addr solicited_node(IPv6Addr a) pure
    => IPv6Addr(0xFF02, 0, 0, 0, 0, 1, 0xFF00 | (a.s[6] & 0xFF), a.s[7]);

// 33:33 + low 32 bits of the destination address (RFC 2464)
MACAddress ether_multicast(IPv6Addr a) pure
{
    MACAddress m;
    m.b[0] = 0x33;
    m.b[1] = 0x33;
    m.b[2] = cast(ubyte)(a.s[6] >> 8);
    m.b[3] = cast(ubyte)a.s[6];
    m.b[4] = cast(ubyte)(a.s[7] >> 8);
    m.b[5] = cast(ubyte)a.s[7];
    return m;
}

// fe80:: + modified EUI-64 from the MAC (U/L bit flipped, FFFE inserted)
IPv6Addr link_local_for(MACAddress mac) pure
{
    IPv6Addr a;
    a.s[0] = 0xFE80;
    a.s[4] = cast(ushort)((mac.b[0] ^ 0x02) << 8 | mac.b[1]);
    a.s[5] = cast(ushort)(mac.b[2] << 8 | 0xFF);
    a.s[6] = cast(ushort)(0xFE00 | mac.b[3]);
    a.s[7] = cast(ushort)(mac.b[4] << 8 | mac.b[5]);
    return a;
}

IPv6Addr link_local_of(BaseInterface iface)
{
    if (EthernetStation station = cast(EthernetStation)iface)
        return link_local_for(station.mac);
    return IPv6Addr.any;
}


bool is_our_ip_v6(IPv6Addr ip, BaseInterface iface)
{
    if (ip == link_local_of(iface))
        return true;
    foreach (a; Collection!IPv6Address().values)
        if (cast(BaseInterface)a.iface is iface && a.address.addr == ip)
            return true;
    return false;
}

// True for multicast groups we implicitly listen on: all-nodes, and the
// solicited-node group of every address we own on `iface`.
bool is_our_multicast_v6(IPv6Addr ip, BaseInterface iface)
{
    if (ip == IPv6Addr.linkLocal_allNodes)
        return true;
    if ((ip.s[0] != 0xFF02) || ip.s[5] != 1 || (ip.s[6] & 0xFF00) != 0xFF00)
        return false;
    if (ip == solicited_node(link_local_of(iface)))
        return true;
    foreach (a; Collection!IPv6Address().values)
        if (cast(BaseInterface)a.iface is iface && solicited_node(a.address.addr) == ip)
            return true;
    return false;
}


// Send a neighbour solicitation for `target` out `iface`, to the target's
// solicited-node multicast group.
void send_neighbour_solicit(ref IPStack stack, IPv6Addr target, EthernetStation iface)
{
    IPv6Addr src = source_for_target(target, iface);
    IPv6Addr dst = solicited_node(target);

    ubyte[IPv6Header.sizeof + 24 + 8] buf = void;
    size_t icmp_len = build_ns_na(buf[], Icmp6Type.neighbour_solicit, 0, src, dst, target, iface.mac,
                                  NDOption.source_link_addr);

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "solicit who-has ", target, " on ", iface.name, " (src=", src, ")");

    iface.send(ether_multicast(dst), buf[0 .. IPv6Header.sizeof + icmp_len], EtherType.ip6);
}


// Parse and react to a neighbour solicitation addressed to (a multicast group
// of) this node. `icmp` is the checksum-verified ICMPv6 message.
void on_neighbour_solicit(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] icmp, BaseInterface iface)
{
    EthernetStation station = cast(EthernetStation)iface;
    if (!station)
        return;
    if (ip.hop_limit != 255 || icmp[1] != 0)
        return;     // RFC 4861 7.1.1
    if (icmp.length < 24)
        return;

    IPv6Addr target = read_addr(icmp[8 .. 24]);
    if (target.is_multicast)
        return;

    IPv6Addr src = ip.src_addr;
    const(ubyte)[] slla = find_option(icmp[24 .. $], NDOption.source_link_addr);

    version (DebugND)
        write_log(Severity.trace, "nd", null, "rx solicit for ", target, " from ", src, " on ", iface.name);

    if (src == IPv6Addr.any)
    {
        // DAD probe: defend addresses we own with an unsolicited advert to all-nodes.
        if (!is_our_ip_v6(target, iface))
            return;
        send_neighbour_advert(stack, target, IPv6Addr.linkLocal_allNodes, station, false);
        return;
    }

    if (slla.length == 6)
        stack.neighbour_v6_cache.learn(src, iface, slla);

    if (!is_our_ip_v6(target, iface))
        return;

    send_neighbour_advert(stack, target, src, station, true);
}


void on_neighbour_advert(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] icmp, BaseInterface iface)
{
    if (ip.hop_limit != 255 || icmp[1] != 0)
        return;
    if (icmp.length < 24)
        return;

    IPv6Addr target = read_addr(icmp[8 .. 24]);
    if (target.is_multicast)
        return;

    const(ubyte)[] tlla = find_option(icmp[24 .. $], NDOption.target_link_addr);
    version (DebugND)
        write_log(Severity.debug_, "nd", null, "rx advert ", target, tlla.length == 6 ? " is-at tlla" : " (no tlla)", " on ", iface.name);
    if (tlla.length == 6)
        stack.neighbour_v6_cache.learn(target, iface, tlla);
}


void on_router_advert(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] icmp, BaseInterface iface)
{
    // TODO: SLAAC - consume prefix-information options into dynamic IPv6Address
    //       entries with lifetimes, install a default route via the advertising
    //       router, honour the MTU option.
    version (DebugND)
        write_log(Severity.debug_, "nd", null, "rx router-advert from ", ip.src_addr, " on ", iface.name, " (SLAAC TODO)");
}


private:

// NS and NA share a layout: 4B rest-of-header, 16B target, then options.
// Returns the ICMPv6 message length; buf receives the complete IPv6 datagram.
size_t build_ns_na(ubyte[] buf, ubyte type, uint flags, IPv6Addr src, IPv6Addr dst, IPv6Addr target,
                   MACAddress link_addr, ubyte option_type)
{
    enum size_t icmp_len = 24 + 8;

    auto hdr = cast(IPv6Header*)buf.ptr;
    hdr.ver_tc_flow[] = 0;
    hdr.ver_tc_flow[0] = 0x60;
    hdr.payload_length = nativeToBigEndian(cast(ushort)icmp_len);
    hdr.next_header = IPProtocol.icmp6;
    hdr.hop_limit = 255;
    hdr.src_addr = src;
    hdr.dst_addr = dst;

    ubyte* icmp = buf.ptr + IPv6Header.sizeof;
    icmp[0] = type;
    icmp[1] = 0;
    icmp[2] = 0;
    icmp[3] = 0;
    icmp[4..8] = flags.nativeToBigEndian;
    write_addr(icmp[8 .. 24], target);
    icmp[24] = option_type;
    icmp[25] = 1;
    icmp[26 .. 32] = link_addr.b[];

    ushort pseudo = pseudo_header_checksum_v6(hdr.src, hdr.dst, icmp_len, IPProtocol.icmp6);
    ushort cc = internet_checksum(icmp[0 .. icmp_len], pseudo);
    icmp[2..4] = cc.nativeToBigEndian;
    return icmp_len;
}

void send_neighbour_advert(ref IPStack stack, IPv6Addr target, IPv6Addr dst, EthernetStation iface, bool solicited)
{
    enum uint flag_solicited = 0x4000_0000;
    enum uint flag_override  = 0x2000_0000;
    uint flags = flag_override | (solicited ? flag_solicited : 0);

    ubyte[IPv6Header.sizeof + 24 + 8] buf = void;
    size_t icmp_len = build_ns_na(buf[], Icmp6Type.neighbour_advert, flags, target, dst, target, iface.mac,
                                  NDOption.target_link_addr);

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "advert ", target, " is-at ", iface.mac, " on ", iface.name);

    if (dst.is_multicast)
        iface.send(ether_multicast(dst), buf[0 .. IPv6Header.sizeof + icmp_len], EtherType.ip6);
    else if (auto e = stack.neighbour_v6_cache.find(dst, iface))
    {
        MACAddress mac;
        mac.b[] = e.link_addr[0 .. 6];
        iface.send(mac, buf[0 .. IPv6Header.sizeof + icmp_len], EtherType.ip6);
    }
}

IPv6Addr source_for_target(IPv6Addr target, BaseInterface iface)
{
    foreach (a; Collection!IPv6Address().values)
        if (cast(BaseInterface)a.iface is iface && a.address.contains(target))
            return a.address.addr;
    return link_local_of(iface);
}

const(ubyte)[] find_option(const(ubyte)[] options, ubyte type)
{
    while (options.length >= 8)
    {
        size_t len = options[1] * 8;
        if (len == 0 || len > options.length)
            return null;
        if (options[0] == type)
            return options[2 .. len];
        options = options[len .. $];
    }
    return null;
}

IPv6Addr read_addr(const(ubyte)[] b) pure
{
    IPv6Addr a;
    foreach (i; 0 .. 8)
        a.s[i] = cast(ushort)(b[i*2] << 8 | b[i*2 + 1]);
    return a;
}

void write_addr(ubyte[] b, IPv6Addr a) pure
{
    foreach (i; 0 .. 8)
    {
        b[i*2]     = cast(ubyte)(a.s[i] >> 8);
        b[i*2 + 1] = cast(ubyte)a.s[i];
    }
}


unittest
{
    IPv6Addr a = IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0x1234, 0x5678);
    assert(solicited_node(a) == IPv6Addr(0xFF02, 0, 0, 0, 0, 1, 0xFF34, 0x5678));

    MACAddress m = ether_multicast(solicited_node(a));
    assert(m.b[] == [ 0x33, 0x33, 0xFF, 0x34, 0x56, 0x78 ]);

    MACAddress mac = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55);
    assert(link_local_for(mac) == IPv6Addr(0xFE80, 0, 0, 0, 0x0211, 0x22FF, 0xFE33, 0x4455));

    ubyte[16] wire;
    write_addr(wire[], a);
    assert(read_addr(wire[]) == a);

    // option walk: skip an 8-byte unknown option, find TLLA, reject zero-length
    ubyte[24] opts = 0;
    opts[0] = 14; opts[1] = 1;
    opts[8] = NDOption.target_link_addr; opts[9] = 1;
    opts[10 .. 16] = mac.b[];
    opts[16] = NDOption.source_link_addr; opts[17] = 0;
    assert(find_option(opts[], NDOption.target_link_addr) == mac.b[]);
    assert(find_option(opts[], NDOption.source_link_addr) == null);
}
