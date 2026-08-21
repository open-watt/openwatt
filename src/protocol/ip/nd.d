module protocol.ip.nd;

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.mem.temp : tconcat;
import urt.time;

import manager.base;
import manager.collection;
import manager.expression : NamedArgument;

import router.iface;
import router.iface.endpoint : foreach_ether_station;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

import protocol.ip : IPv6Header, IPProtocol;
import protocol.ip.address;
import protocol.ip.icmp6;
import protocol.ip.neighbour;
import protocol.ip.route;
import protocol.ip.stack;

//version = DebugND;

private alias log = Log!"nd";

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


version (UseInternalIPStack):


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
    import protocol.ip.mcast : is_member_v6;

    if (ip == IPv6Addr.linkLocal_allNodes)
        return true;
    if (is_member_v6(ip, iface))
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
        // Another node is running DAD on `target`: if it collides with our own
        // in-flight DAD both must back off, but an address we hold is defended
        // with an unsolicited advert to all-nodes.
        if (slaac_dad_defeat(target, iface))
            return;
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

    slaac_dad_defeat(target, iface);

    const(ubyte)[] tlla = find_option(icmp[24 .. $], NDOption.target_link_addr);
    version (DebugND)
        write_log(Severity.debug_, "nd", null, "rx advert ", target, tlla.length == 6 ? " is-at tlla" : " (no tlla)", " on ", iface.name);
    if (tlla.length == 6)
        stack.neighbour_v6_cache.learn(target, iface, tlla);
}


void on_router_advert(ref IPStack stack, ref const IPv6Header ip, const(ubyte)[] icmp, BaseInterface iface)
{
    EthernetStation station = cast(EthernetStation)iface;
    if (!station)
        return;
    if (ip.hop_limit != 255 || icmp[1] != 0)
        return;
    if (icmp.length < 16)
        return;
    IPv6Addr router = ip.src_addr;
    if (!router.is_link_local)
        return;     // RFC 4861 6.1.2

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "rx router-advert from ", router, " on ", iface.name);

    MonoTime now = getTime();
    SlaacIface* st = iface_state(iface);
    st.ra_seen = true;

    ra_router(station, router, icmp[6..8].bigEndianToNative!ushort, now);

    const(ubyte)[] opts = icmp[16 .. $];
    while (opts.length >= 8)
    {
        size_t len = opts[1] * 8;
        if (len == 0 || len > opts.length)
            break;
        switch (opts[0])
        {
            case NDOption.source_link_addr:
                if (len == 8)
                    stack.neighbour_v6_cache.learn(router, iface, opts[2 .. 8]);
                break;
            case NDOption.mtu:
                // TODO: apply to egress once fragmentation / packet-too-big lands
                if (len == 8)
                    st.mtu = opts[4 .. 8].bigEndianToNative!uint;
                break;
            case NDOption.prefix_info:
                if (len == 32)
                    ra_prefix(station, router, opts[0 .. 32], now);
                break;
            default:
                break;
        }
        opts = opts[len .. $];
    }
}


// Drives router solicitation, DAD completion, and lifetime expiry of
// RA-learned addresses and routes. Called from the stack's frame update, the
// same cadence as the neighbour cache tick.
void slaac_update(ref IPStack stack, MonoTime now)
{
    foreach_ether_station((EthernetStation s) {
        SlaacIface* st = iface_state(s);
        if (!s.running)
        {
            st.rs_sent = 0;
            st.ra_seen = false;
            return;
        }
        if (st.ra_seen || st.rs_sent >= max_rtr_solicitations)
            return;
        if (now - st.last_rs < rtr_solicitation_interval)
            return;
        ++st.rs_sent;
        st.last_rs = now;
        send_router_solicit(s);
    });

    for (size_t i = _slaac_prefixes.length; i > 0; --i)
    {
        auto e = &_slaac_prefixes[i - 1];
        if (!e.iface || now >= e.valid_until)
        {
            if (auto a = e.addr.get)
            {
                log.info("SLAAC address ", a.address, " expired");
                a.destroy();
            }
            _slaac_prefixes.removeSwapLast(i - 1);
            continue;
        }
        if (e.dad_in_flight && now - e.dad_sent >= dad_window)
        {
            e.dad_in_flight = false;
            create_slaac_address(*e);
        }
    }

    for (size_t i = _slaac_routers.length; i > 0; --i)
    {
        auto r = &_slaac_routers[i - 1];
        if (!r.iface || now >= r.expires)
        {
            if (auto rt = r.route.get)
            {
                log.info("default route via ", r.router, " expired");
                rt.destroy();
            }
            _slaac_routers.removeSwapLast(i - 1);
        }
    }

    for (size_t i = _slaac_ifaces.length; i > 0; --i)
    {
        if (!_slaac_ifaces[i - 1].iface)
            _slaac_ifaces.removeSwapLast(i - 1);
    }
}


private:

enum ubyte max_rtr_solicitations     = 3;
enum Duration rtr_solicitation_interval = 4.seconds;
enum Duration dad_window             = 1.seconds;
enum uint max_lifetime_s             = 0x00FF_FFFF;     // clamp; routers re-advertise long before this

struct SlaacIface
{
    ObjectRef!BaseInterface iface;
    ubyte rs_sent;
    bool ra_seen;
    MonoTime last_rs;
    uint mtu;
}

struct SlaacPrefix
{
    IPv6Addr prefix;
    ubyte prefix_len;
    ObjectRef!BaseInterface iface;
    IPv6Addr router;
    IPv6Addr formed;            // prefix + our interface identifier
    MonoTime valid_until;
    MonoTime preferred_until;   // TODO: deprecate for source selection past this
    bool dad_in_flight;
    bool duplicate;
    MonoTime dad_sent;
    ObjectRef!IPv6Address addr;
}

struct SlaacRouter
{
    IPv6Addr router;
    ObjectRef!BaseInterface iface;
    MonoTime expires;
    ObjectRef!IPv6Route route;
}

__gshared Array!SlaacIface  _slaac_ifaces;
__gshared Array!SlaacPrefix _slaac_prefixes;
__gshared Array!SlaacRouter _slaac_routers;

SlaacIface* iface_state(BaseInterface iface)
{
    foreach (ref s; _slaac_ifaces[])
        if (s.iface.get is iface)
            return &s;
    SlaacIface s;
    s.iface = iface;
    _slaac_ifaces ~= s;
    return &_slaac_ifaces[$ - 1];
}

void send_router_solicit(EthernetStation iface)
{
    enum size_t icmp_len = 8 + 8;
    ubyte[IPv6Header.sizeof + icmp_len] buf = void;

    auto hdr = cast(IPv6Header*)buf.ptr;
    hdr.ver_tc_flow[] = 0;
    hdr.ver_tc_flow[0] = 0x60;
    hdr.payload_length = nativeToBigEndian(cast(ushort)icmp_len);
    hdr.next_header = IPProtocol.icmp6;
    hdr.hop_limit = 255;
    hdr.src_addr = link_local_for(iface.mac);
    hdr.dst_addr = IPv6Addr.linkLocal_routers;

    ubyte* icmp = buf.ptr + IPv6Header.sizeof;
    icmp[0] = Icmp6Type.router_solicit;
    icmp[1 .. 8] = 0;
    icmp[8] = NDOption.source_link_addr;
    icmp[9] = 1;
    icmp[10 .. 16] = iface.mac.b[];

    ushort pseudo = pseudo_header_checksum_v6(hdr.src, hdr.dst, icmp_len, IPProtocol.icmp6);
    ushort cc = internet_checksum(icmp[0 .. icmp_len], pseudo);
    icmp[2..4] = cc.nativeToBigEndian;

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "solicit routers on ", iface.name);

    iface.send(ether_multicast(IPv6Addr.linkLocal_routers), buf[], EtherType.ip6);
}

void ra_router(EthernetStation iface, IPv6Addr router, ushort lifetime, MonoTime now)
{
    foreach (i, ref r; _slaac_routers[])
    {
        if (r.router == router && r.iface.get is iface)
        {
            if (lifetime == 0)
            {
                if (auto rt = r.route.get)
                    rt.destroy();
                _slaac_routers.removeSwapLast(i);
            }
            else
                r.expires = now + lifetime.seconds;
            return;
        }
    }
    if (lifetime == 0)
        return;

    SlaacRouter r;
    r.router = router;
    r.iface = iface;
    r.expires = now + lifetime.seconds;
    const(char)[] name = Collection!IPv6Route().generate_name(tconcat(iface.name[], ".ra"));
    r.route = Collection!IPv6Route().create(
        name,
        ObjectFlags.dynamic,
        NamedArgument("destination", IPv6NetworkAddress(IPv6Addr.any, 0)),
        NamedArgument("gateway", router),
        NamedArgument("out-interface", cast(BaseInterface)iface));
    if (!r.route)
    {
        log.error("failed to create dynamic default route");
        return;
    }
    _slaac_routers ~= r;
    log.info("default route via ", router, " on ", iface.name, " (lifetime ", lifetime, "s)");
}

void ra_prefix(EthernetStation iface, IPv6Addr router, const(ubyte)[] opt, MonoTime now)
{
    ubyte plen = opt[2];
    if (!(opt[3] & 0x40))
        return;     // autonomous flag absent; on-link-only prefixes need no address
    uint valid = opt[4..8].bigEndianToNative!uint;
    uint preferred = opt[8..12].bigEndianToNative!uint;
    IPv6Addr prefix = read_addr(opt[16 .. 32]);

    if (prefix.is_link_local || prefix.is_multicast)
        return;
    if (plen != 64)
    {
        log.warning("ignoring RA prefix ", prefix, "/", plen, ": SLAAC needs a /64 for the interface identifier");
        return;
    }
    if (valid > max_lifetime_s)
        valid = max_lifetime_s;
    if (preferred > valid)
        preferred = valid;

    foreach (i, ref e; _slaac_prefixes[])
    {
        if (e.prefix == prefix && e.iface.get is iface)
        {
            if (valid == 0)
            {
                if (auto a = e.addr.get)
                    a.destroy();
                _slaac_prefixes.removeSwapLast(i);
                return;
            }
            // TODO: RFC 4862 5.5.3(e) two-hour rule against lifetime-shortening attacks
            e.valid_until = now + valid.seconds;
            e.preferred_until = now + preferred.seconds;
            return;
        }
    }
    if (valid == 0)
        return;

    SlaacPrefix e;
    e.prefix = prefix;
    e.prefix_len = plen;
    e.iface = iface;
    e.router = router;
    e.formed = prefix;
    e.formed.s[4 .. 8] = link_local_for(iface.mac).s[4 .. 8];
    e.valid_until = now + valid.seconds;
    e.preferred_until = now + preferred.seconds;
    e.dad_in_flight = true;
    e.dad_sent = now;
    _slaac_prefixes ~= e;

    version (DebugND)
        write_log(Severity.debug_, "nd", null, "DAD probe for ", e.formed, " on ", iface.name);

    ubyte[IPv6Header.sizeof + 24] buf = void;
    size_t icmp_len = build_ns_na(buf[], Icmp6Type.neighbour_solicit, 0, IPv6Addr.any,
                                  solicited_node(e.formed), e.formed, MACAddress(), 0);
    iface.send(ether_multicast(solicited_node(e.formed)), buf[0 .. IPv6Header.sizeof + icmp_len], EtherType.ip6);
}

void create_slaac_address(ref SlaacPrefix e)
{
    if (e.duplicate)
        return;
    BaseInterface iface = e.iface.get;
    if (!iface)
        return;
    const(char)[] name = Collection!IPv6Address().generate_name(tconcat(iface.name[], ".slaac"));
    e.addr = Collection!IPv6Address().create(
        name,
        ObjectFlags.dynamic,
        NamedArgument("address", IPv6NetworkAddress(e.formed, e.prefix_len)),
        NamedArgument("interface", iface));
    if (!e.addr)
    {
        log.error("failed to create dynamic IPv6Address");
        return;
    }
    log.info("SLAAC address ", e.formed, "/", e.prefix_len, " on ", iface.name);
}

bool slaac_dad_defeat(IPv6Addr target, BaseInterface iface)
{
    foreach (ref e; _slaac_prefixes[])
    {
        if (e.dad_in_flight && e.formed == target && e.iface.get is iface)
        {
            e.dad_in_flight = false;
            e.duplicate = true;
            log.warning("DAD: ", target, " already in use on ", iface.name, "; address suppressed");
            return true;
        }
    }
    return false;
}

// NS and NA share a layout: 4B rest-of-header, 16B target, then options.
// option_type 0 omits the link-address option (DAD probes MUST NOT carry SLLA).
// Returns the ICMPv6 message length; buf receives the complete IPv6 datagram.
size_t build_ns_na(ubyte[] buf, ubyte type, uint flags, IPv6Addr src, IPv6Addr dst, IPv6Addr target,
                   MACAddress link_addr, ubyte option_type)
{
    size_t icmp_len = option_type ? 24 + 8 : 24;

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
    if (option_type)
    {
        icmp[24] = option_type;
        icmp[25] = 1;
        icmp[26 .. 32] = link_addr.b[];
    }

    ushort pseudo = pseudo_header_checksum_v6(hdr.src, hdr.dst, cast(uint)icmp_len, IPProtocol.icmp6);
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
