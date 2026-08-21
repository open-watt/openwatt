module protocol.ip.stack;

version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.time;

import manager.collection;
import manager.features : has_tcp;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

import protocol.ip : IPv4Header, IPv6Header, IPProtocol;
import protocol.ip.address;
import protocol.ip.arp;
import protocol.ip.firewall;
import protocol.ip.icmp;
import protocol.ip.icmp6;
import protocol.ip.nd;
import protocol.ip.neighbour;
import protocol.ip.route;
import protocol.ip.udp;

static if (has_tcp)
    import router.transport.tcp.engine : TcpHeader, tcp_segment_input;

//version = DebugIP;            // bind / unbind, no-route, etc.
//version = DebugRawIngress;    // every packet entering on_packet
//version = DebugIPIngress;     // incoming ethernet packets
//version = DebugIPRoute;       // every route lookup result
//version = DebugIPEgress;      // every packet leaving via egress()
//version = DebugIPNeighbour;   // ARP / ND cache activity

nothrow @nogc:


// the ip module installs its stack here before anything can run; transports lowering ip peers
// read it. It lives beside IPStack so the router layer needs no ip import to declare it.
__gshared IPStack* g_ip_stack;

__gshared uint _route_gen = 1;
__gshared ushort _ip_id;

void bump_route_generation()
{
    ++_route_gen;
}
uint route_generation()
    => _route_gen;

ushort next_ip_id()
    => ++_ip_id;


struct RouteResultT(Addr)
{
    enum Kind : ubyte
    {
        none,           // no matching route -> ICMP unreachable
        local,          // destination is one of our IPAddresses -> deliver up
        forward,        // forward via out_iface, optionally through gateway
        blackhole,      // silently drop
    }

    Kind kind;
    BaseInterface out_iface;
    Addr next_hop;          // == destination if directly attached
    ubyte ttl_decrement;
}
alias RouteResult  = RouteResultT!IPAddr;
alias RouteResult6 = RouteResultT!IPv6Addr;


struct IPStack
{
nothrow @nogc:

    alias log = Log!"ip";

    void init_resolvers()
    {
        neighbour_v4.send_request = &v4_send_request;
        neighbour_v4.drain        = &v4_drain;
        neighbour_v6.send_request = &v6_send_request;
        neighbour_v6.drain        = &v6_drain;
    }

    void output_v4(ref Packet pkt)
    {
        if (firewall_v4.run(HookPoint.output, pkt) == Verdict.drop)
            return;
        RouteResult r = route_lookup_v4(pkt);
        dispatch(pkt, r, firewall_v4);
    }

    void output_v4_routed(ref Packet pkt, BaseInterface egress, IPAddr next_hop)
    {
        if (firewall_v4.run(HookPoint.output, pkt) == Verdict.drop)
            return;
        RouteResult r = RouteResult(RouteResult.Kind.forward, egress, next_hop, 1);
        dispatch(pkt, r, firewall_v4);
    }

    void output_v6(ref Packet pkt)
    {
        if (firewall_v6.run(HookPoint.output, pkt) == Verdict.drop)
            return;
        RouteResult6 r = route_lookup_v6(pkt);
        dispatch_v6(pkt, r, null);
    }

    void output_v6_routed(ref Packet pkt, BaseInterface egress, IPv6Addr next_hop)
    {
        if (firewall_v6.run(HookPoint.output, pkt) == Verdict.drop)
            return;
        RouteResult6 r = RouteResult6(RouteResult6.Kind.forward, egress, next_hop, 1);
        dispatch_v6(pkt, r, null);
    }

    void update()
    {
        MonoTime now = getTime();
        neighbour_v4.tick(now);
        neighbour_v6.tick(now);
        slaac_update(this, now);
    }

    IPAddr select_source_v4(IPAddr dst)
    {
        RouteResult r = route_lookup_v4_dst(dst);
        if (r.kind == RouteResult.Kind.local)
            return dst;
        if (r.kind != RouteResult.Kind.forward || !r.out_iface)
            return IPAddr.any;
        foreach (a; Collection!IPAddress().values)
            if (a.iface is r.out_iface)
                return a.address.addr;
        return IPAddr.any;
    }

    RouteResult route_lookup_v4_dst(IPAddr dst)
    {
        if (dst.is_loopback())
        {
            version (DebugIPRoute)
                log.trace("route dst=", dst, " -> local (loopback)");
            return RouteResult(RouteResult.Kind.local, null, dst, 0);
        }

        foreach (a; Collection!IPAddress().values)
        {
            if (a.address.addr == dst)
            {
                version (DebugIPRoute)
                    log.trace("route dst=", dst, " -> local on ", a.iface.name[]);
                return RouteResult(RouteResult.Kind.local, a.iface, dst, 0);
            }
        }

        IPRoute best_rt = null;
        ubyte best_prefix = 0;
        foreach (rt; Collection!IPRoute().values)
        {
            if (!rt.destination.contains(dst))
                continue;
            ubyte plen = rt.destination.prefix_len;
            if (best_rt && plen <= best_prefix)
                continue;
            best_rt = rt;
            best_prefix = plen;
        }

        RouteResult best = RouteResult(RouteResult.Kind.none);
        if (best_rt)
        {
            if (best_rt.blackhole)
                best = RouteResult(RouteResult.Kind.blackhole);
            else
            {
                IPAddr next = best_rt.gateway != IPAddr.any ? best_rt.gateway : dst;
                BaseInterface egress = best_rt.out_interface;
                if (!egress && best_rt.gateway != IPAddr.any)
                    egress = resolve_connected_iface(best_rt.gateway);
                if (egress)
                    best = RouteResult(RouteResult.Kind.forward, egress, next, 1);
            }
        }

        // TODO: HACK - DO WE WANT THIS??? shoudl we expect the route table to be correct?
        // Fallback: any IPAddress whose subnet contains dst is an implicit
        // connected route. Lets configurations declare addresses without
        // needing a corresponding /protocol/ip/route entry.
        if (best.kind == RouteResult.Kind.none)
        {
            if (BaseInterface egress = resolve_connected_iface(dst))
                best = RouteResult(RouteResult.Kind.forward, egress, dst, 1);
        }

        version (DebugIPRoute)
        {
            if (best.kind == RouteResult.Kind.none)
                log.trace("route dst=", dst, " -> none");
            else if (best.next_hop != IPAddr.any)
                log.trace("route dst=", dst, " -> kind=", best.kind, " via=", best.next_hop, " (", best.out_iface ? best.out_iface.name[] : "<none>", ')');
            else
                log.trace("route dst=", dst, " -> kind=", best.kind, " via=", best.out_iface ? best.out_iface.name[] : "<none>");
        }

        return best;
    }

    IPv6Addr select_source_v6(IPv6Addr dst, BaseInterface iface_hint)
    {
        if (dst.is_link_local || dst.is_multicast)
        {
            if (iface_hint)
                return link_local_of(iface_hint);
            return IPv6Addr.any;
        }

        RouteResult6 r = route_lookup_v6_dst(dst, iface_hint);
        if (r.kind == RouteResult6.Kind.local)
            return dst;
        if (r.kind != RouteResult6.Kind.forward || !r.out_iface)
            return IPv6Addr.any;
        // TODO: RFC 6724 source selection; for now first non-link-local address on the egress iface
        foreach (a; Collection!IPv6Address().values)
            if (a.iface is r.out_iface && !a.address.addr.is_link_local)
                return a.address.addr;
        return link_local_of(r.out_iface);
    }

    RouteResult6 route_lookup_v6_dst(IPv6Addr dst, BaseInterface iface_hint = null)
    {
        if (dst == IPv6Addr.loopback)
        {
            version (DebugIPRoute)
                log.trace("route6 dst=", dst, " -> local (loopback)");
            return RouteResult6(RouteResult6.Kind.local, null, dst, 0);
        }

        // Link-local and multicast destinations never leave the link; they need
        // an interface scope rather than a route.
        if (dst.is_link_local || dst.is_multicast)
        {
            if (iface_hint)
                return RouteResult6(RouteResult6.Kind.forward, iface_hint, dst, 0);
            return RouteResult6(RouteResult6.Kind.none);
        }

        foreach (a; Collection!IPv6Address().values)
        {
            if (a.address.addr == dst)
            {
                version (DebugIPRoute)
                    log.trace("route6 dst=", dst, " -> local on ", a.iface.name[]);
                return RouteResult6(RouteResult6.Kind.local, a.iface, dst, 0);
            }
        }

        IPv6Route best_rt = null;
        ubyte best_prefix = 0;
        foreach (rt; Collection!IPv6Route().values)
        {
            if (!rt.destination.contains(dst))
                continue;
            ubyte plen = rt.destination.prefix_len;
            if (best_rt && plen <= best_prefix)
                continue;
            best_rt = rt;
            best_prefix = plen;
        }

        RouteResult6 best = RouteResult6(RouteResult6.Kind.none);
        if (best_rt)
        {
            if (best_rt.blackhole)
                best = RouteResult6(RouteResult6.Kind.blackhole);
            else
            {
                IPv6Addr next = best_rt.gateway != IPv6Addr.any ? best_rt.gateway : dst;
                BaseInterface egress = best_rt.out_interface;
                if (!egress && best_rt.gateway != IPv6Addr.any && !best_rt.gateway.is_link_local)
                    egress = resolve_connected_iface_v6(best_rt.gateway);
                if (egress)
                    best = RouteResult6(RouteResult6.Kind.forward, egress, next, 1);
            }
        }

        // Same implicit-connected fallback HACK as v4; resolve both together.
        if (best.kind == RouteResult6.Kind.none)
        {
            if (BaseInterface egress = resolve_connected_iface_v6(dst))
                best = RouteResult6(RouteResult6.Kind.forward, egress, dst, 1);
        }

        version (DebugIPRoute)
        {
            if (best.kind == RouteResult6.Kind.none)
                log.trace("route6 dst=", dst, " -> none");
            else
                log.trace("route6 dst=", dst, " -> kind=", best.kind, " via=", best.next_hop, " (", best.out_iface ? best.out_iface.name[] : "<none>", ')');
        }

        return best;
    }

    // Frame handler registered for PacketType.ethernet by the IP module at init.
    // Ethernet-shaped frames (real Ethernet, VLAN sub-interfaces, Ethernet-bridge,
    // and protocols normalised to Ethernet framing) all funnel here.
    void on_packet(ref Packet pkt, BaseInterface iface)
    {
        version (DebugRawIngress)
            log.trace("ingress if=", iface.name, " type=", pkt.type, " (", pkt.length, ") [ ", pkt.data[0 .. 24 < pkt.length ? 24 : pkt.length], 24 < pkt.length ? " ... ]" : " ]");

        if (pkt.type == PacketType.ethernet)
        {
            EthernetStation station = cast(EthernetStation)iface;
            debug assert(station !is null);
            if (station)
                ethernet_ingress(pkt, station);
        }
        // TODO: sixlowpan handler -> register for PacketType._6lowpan
        // TODO: ppp handler -> register for an appropriate PacketType
        // TODO: raw_ip tunnel handler -> register for PacketType.raw (peek IP version byte)
    }

    // Diagnostics access to the neighbour caches (for /protocol/ip/neighbour print).
    ref inout(NeighbourCache!IPAddr) neighbour_v4_cache() inout pure return
        => neighbour_v4;
    ref inout(NeighbourCache!IPv6Addr) neighbour_v6_cache() inout pure return
        => neighbour_v6;

private:

    void ethernet_ingress(ref Packet pkt, EthernetStation iface)
    {
        const Ethernet eth = pkt.hdr!Ethernet();
        if (eth.dst != iface.mac && !eth.dst.is_multicast())
            return; // promiscuous capture; not addressed to us
        version (DebugIPIngress)
            log.trace("ingress if=", iface.name, ' ', pkt.hdr!Ethernet().src, " --> ", pkt.hdr!Ethernet().dst, " (", pkt.length, ") [ ", pkt.data[0 .. 24 < pkt.length ? 24 : pkt.length], 24 < pkt.length ? " ... ]" : " ]");
        switch (eth.ether_type)
        {
            case EtherType.arp:
                on_arp(pkt, iface, neighbour_v4);
                break;
            case EtherType.ip4:
                ingress_v4(pkt, iface);
                break;
            case EtherType.ip6:
                ingress_v6(pkt, iface);
                break;
            default:
                break;  // not an L3 frame we care about; another subscriber may handle it
        }
    }

    void ingress_v4(ref Packet pkt, BaseInterface iface)
    {
        if (pkt.data.length < IPv4Header.sizeof)
            return;

        const ip = cast(const IPv4Header*)pkt.data.ptr;
        if (ip.version_ != 4)
            return;
        if (ip.ihl < 5)
            return;
        size_t hdr_len = ip.ihl * 4;
        if (pkt.data.length < hdr_len)
            return;
        ushort total = ip.total_length.bigEndianToNative!ushort;
        if (total < hdr_len || total > pkt.data.length)
            return;
        if (internet_checksum(pkt.data.ptr[0 .. hdr_len]) != 0)
            return;

        // Learn (src_ip, l2_src_mac) from any unicast IPv4 frame.
        if (pkt.type == PacketType.ethernet)
        {
            const Ethernet eth = pkt.hdr!Ethernet();
            bool src_mcast = eth.src.is_multicast();
            bool onlink = is_connected_on_iface(IPAddr(ip.src), iface);
            if (!src_mcast && onlink)
                neighbour_v4.learn(IPAddr(ip.src), iface, eth.src.b[]);
        }

        // TODO: reassembly via ident/flags/frag_offset
        // TODO: conntrack lookup for stateful firewall

        if (firewall_v4.run(HookPoint.prerouting, pkt) == Verdict.drop)
            return;

        bool non_forwardable = is_non_forwardable_v4_dst(IPAddr(ip.dst), iface);
        if (non_forwardable)
            return;

        RouteResult r = route_lookup_v4(pkt);
        dispatch(pkt, r, firewall_v4);
    }

    void ingress_v6(ref Packet pkt, BaseInterface iface)
    {
        if (pkt.data.length < IPv6Header.sizeof)
            return;

        const ip = cast(const IPv6Header*)pkt.data.ptr;
        if (ip.version_ != 6)
            return;
        size_t total = IPv6Header.sizeof + ip.payload_length.bigEndianToNative!ushort;
        if (total > pkt.data.length)
            return;

        // TODO: reassembly via fragment extension header
        // TODO: conntrack lookup for stateful firewall

        if (firewall_v6.run(HookPoint.prerouting, pkt) == Verdict.drop)
            return;

        IPv6Addr dst = ip.dst_addr;
        IPv6Addr src = ip.src_addr;

        if (src.is_multicast)
            return;

        if (dst.is_multicast)
        {
            if (!is_our_multicast_v6(dst, iface))
                return;
            if (firewall_v6.run(HookPoint.input, pkt) == Verdict.drop)
                return;
            deliver_local_v6(pkt, iface);
            return;
        }

        if (is_our_ip_v6(dst, iface))
        {
            if (firewall_v6.run(HookPoint.input, pkt) == Verdict.drop)
                return;
            deliver_local_v6(pkt, iface);
            return;
        }

        // Link-local scope never crosses the link, in either address.
        if (dst.is_link_local || src.is_link_local)
            return;

        RouteResult6 r = route_lookup_v6_dst(dst);
        dispatch_v6(pkt, r, iface);
    }

    void dispatch(ref Packet pkt, ref RouteResult r, ref FirewallChains fw)
    {
        final switch (r.kind)
        {
            case RouteResult.Kind.none:
                version (DebugIP)
                    log.trace("no route for packet");
                icmp_send_error(this, IcmpType.dest_unreachable, IcmpDestUnreachableCode.net, pkt);
                return;
            case RouteResult.Kind.blackhole:
                return;
            case RouteResult.Kind.local:
                if (fw.run(HookPoint.input, pkt) == Verdict.drop)
                    return;
                deliver_local(pkt);
                return;
            case RouteResult.Kind.forward:
            {
                if (pkt.data.length < IPv4Header.sizeof)
                    return;
                auto ip = cast(IPv4Header*)pkt.data.ptr;
                if (ip.ttl <= r.ttl_decrement)
                {
                    icmp_send_error(this, IcmpType.time_exceeded, 0, pkt);
                    return;
                }
                ip.ttl -= r.ttl_decrement;
                // Incremental checksum update (RFC 1624): TTL sits in the high
                // byte of a 16-bit word, so reducing TTL by N reduces the data
                // sum by N*256 and the 1's-complement checksum rises by N*256.
                uint c = ip.checksum.bigEndianToNative!ushort;
                c += uint(r.ttl_decrement) << 8;
                c = (c & 0xFFFF) + (c >> 16);
                ip.checksum = nativeToBigEndian(cast(ushort)c);
                // TODO: if pkt.length > out_iface.actual_mtu, fragment (v4) or send PTB (v6)
                if (fw.run(HookPoint.forward, pkt) == Verdict.drop)
                    return;
                egress(pkt, r.out_iface, r.next_hop, fw);
                return;
            }
        }
    }

    void dispatch_v6(ref Packet pkt, ref RouteResult6 r, BaseInterface in_iface)
    {
        final switch (r.kind)
        {
            case RouteResult6.Kind.none:
                version (DebugIP)
                    log.trace("no route for v6 packet");
                icmp6_send_error(this, Icmp6Type.dest_unreachable, Icmp6DestUnreachableCode.no_route, pkt);
                return;
            case RouteResult6.Kind.blackhole:
                return;
            case RouteResult6.Kind.local:
                if (firewall_v6.run(HookPoint.input, pkt) == Verdict.drop)
                    return;
                deliver_local_v6(pkt, in_iface);
                return;
            case RouteResult6.Kind.forward:
            {
                if (pkt.data.length < IPv6Header.sizeof)
                    return;
                auto ip = cast(IPv6Header*)pkt.data.ptr;
                if (r.ttl_decrement)
                {
                    if (ip.hop_limit <= r.ttl_decrement)
                    {
                        icmp6_send_error(this, Icmp6Type.time_exceeded, 0, pkt);
                        return;
                    }
                    ip.hop_limit -= r.ttl_decrement;
                }
                // TODO: if pkt.length > out_iface.actual_mtu, send packet-too-big
                if (firewall_v6.run(HookPoint.forward, pkt) == Verdict.drop)
                    return;
                egress_v6(pkt, r.out_iface, r.next_hop);
                return;
            }
        }
    }

    void egress_v6(ref Packet pkt, BaseInterface out_iface, IPv6Addr next_hop)
    {
        if (firewall_v6.run(HookPoint.postrouting, pkt) == Verdict.drop)
            return;

        if (!out_iface)
            return;

        version (DebugIPEgress)
            log.trace("egress6 if=", out_iface.name, " next_hop=", next_hop, " (", pkt.length, ")");

        if (next_hop.is_multicast)
        {
            MACAddress mac = ether_multicast(next_hop);
            frame_and_send(pkt, out_iface, mac.b[]);
            return;
        }

        const(ubyte)[] link_addr = neighbour_v6.resolve(next_hop, out_iface, pkt);
        if (link_addr is null)
        {
            version (DebugIPEgress)
                log.trace("egress6 defer: no neighbour for ", next_hop, " (queued, awaiting resolution)");
            return;
        }

        frame_and_send(pkt, out_iface, link_addr);
    }

    void deliver_local_v6(ref Packet pkt, BaseInterface iface)
    {
        size_t l4_offset, nh_offset;
        IPProtocol proto;
        if (!walk_ext_headers_v6(pkt.data, l4_offset, nh_offset, proto))
            return;

        switch (proto)
        {
            case IPProtocol.icmp6:
                .icmp6_input(this, pkt, l4_offset, iface);
                break;
            case IPProtocol.tcp:
                // TODO: v6 TCP delivery into the transport engine
                break;
            case IPProtocol.udp:
                // TODO: v6 UDP delivery
                break;
            case IPProtocol.no_next:
                break;
            default:
                icmp6_send_error(this, Icmp6Type.parameter_problem, 1, pkt, cast(uint)nh_offset);
                break;
        }
    }

    // Walk v6 extension headers to the upper-layer protocol. Returns false for
    // malformed chains and fragments (no reassembly yet). nh_offset is the
    // offset of the field that named the resulting protocol.
    bool walk_ext_headers_v6(const(void)[] data, out size_t l4_offset, out size_t nh_offset, out IPProtocol proto)
    {
        if (data.length < IPv6Header.sizeof)
            return false;
        const ip = cast(const IPv6Header*)data.ptr;
        const bytes = cast(const(ubyte)*)data.ptr;

        IPProtocol next = ip.next_header;
        nh_offset = IPv6Header.next_header.offsetof;
        size_t offset = IPv6Header.sizeof;
        for (int depth = 0; depth < 8; ++depth)
        {
            switch (next)
            {
                case IPProtocol.hopopt:
                case IPProtocol.ipv6_route:
                case IPProtocol.ipv6_opts:
                    if (data.length < offset + 8)
                        return false;
                    next = cast(IPProtocol)bytes[offset];
                    nh_offset = offset;
                    offset += (bytes[offset + 1] + 1) * 8;
                    if (offset > data.length)
                        return false;
                    break;
                case IPProtocol.ipv6_frag:
                    return false;   // TODO: reassembly
                default:
                    l4_offset = offset;
                    proto = next;
                    return true;
            }
        }
        return false;
    }

    BaseInterface resolve_connected_iface(IPAddr ip)
    {
        foreach (a; Collection!IPAddress().values)
            if (a.address.contains(ip))
                return a.iface;
        return null;
    }

    BaseInterface resolve_connected_iface_v6(IPv6Addr ip)
    {
        foreach (a; Collection!IPv6Address().values)
            if (a.address.contains(ip))
                return a.iface;
        return null;
    }

    bool is_connected_on_iface(IPAddr ip, BaseInterface iface)
    {
        foreach (a; Collection!IPAddress().values)
            if (a.iface is iface && a.address.contains(ip))
                return true;
        return false;
    }

    bool is_non_forwardable_v4_dst(IPAddr dst, BaseInterface iface)
    {
        if (dst == IPAddr.broadcast || dst.is_multicast())
            return true;

        foreach (a; Collection!IPAddress().values)
        {
            if (a.iface !is iface)
                continue;
            ubyte plen = a.address.prefix_len;
            if (plen >= 31)
                continue;
            IPAddr bcast = a.address.get_network() | ~a.address.net_mask();
            if (dst == bcast)
                return true;
        }

        return false;
    }

    RouteResult route_lookup_v4(ref const Packet pkt)
    {
        if (pkt.length < IPv4Header.sizeof)
            return RouteResult(RouteResult.Kind.none);
        const IPv4Header* h = cast(const(IPv4Header)*)pkt.data.ptr;
        return route_lookup_v4_dst(IPAddr(h.dst));
    }

    RouteResult6 route_lookup_v6(ref const Packet pkt)
    {
        if (pkt.length < IPv6Header.sizeof)
            return RouteResult6(RouteResult6.Kind.none);
        const IPv6Header* h = cast(const(IPv6Header)*)pkt.data.ptr;
        return route_lookup_v6_dst(h.dst_addr);
    }

    void egress(ref Packet pkt, BaseInterface out_iface, IPAddr next_hop, ref FirewallChains fw)
    {
        if (fw.run(HookPoint.postrouting, pkt) == Verdict.drop)
            return;

        if (!out_iface)
            return;

        version (DebugIPEgress)
            log.trace("egress if=", out_iface.name, " next_hop=", next_hop, " (", pkt.length, ") [ ", pkt.data[0 .. 24 < pkt.length ? 24 : pkt.length], 24 < pkt.length ? " ... ]" : " ]");

        const(ubyte)[] link_addr = neighbour_v4.resolve(next_hop, out_iface, pkt);
        if (link_addr is null)
        {
            version (DebugIPEgress)
                log.trace("egress defer: no neighbour for ", next_hop, " (queued, awaiting resolution)");
            return;
        }

        frame_and_send(pkt, out_iface, link_addr);
    }

    // TODO: when sixlowpan / ppp / raw_ip are added, dispatch by iface type
    //       (or by a virtual on BaseInterface) to choose the framing.
    void frame_and_send(ref Packet pkt, BaseInterface out_iface, const(ubyte)[] link_addr)
    {
        EthernetStation station = cast(EthernetStation)out_iface;
        if (!station || link_addr.length != 6 || pkt.data.length < 1)
            return;
        MACAddress dst;
        dst.b[] = link_addr[0 .. 6];
        ubyte ver = (cast(const(ubyte)*)pkt.data.ptr)[0] >> 4;
        EtherType etype = ver == 6 ? EtherType.ip6 : EtherType.ip4;
        station.send(dst, pkt.data, etype);
    }

    void deliver_local(ref Packet pkt)
    {
        if (pkt.data.length < IPv4Header.sizeof)
            return;
        const ip = cast(const IPv4Header*)pkt.data.ptr;
        if (ip.version_ != 4)
            return;     // v6 path not yet wired

        switch (ip.protocol)
        {
            case IPProtocol.icmp:
                .icmp_input(this, pkt);
                break;
            case IPProtocol.tcp:
                static if (has_tcp)
                    .tcp_input(pkt);
                break;
            case IPProtocol.udp:
                .udp_input(this, pkt);
                break;
            default:
                icmp_send_error(this, IcmpType.dest_unreachable, IcmpDestUnreachableCode.protocol, pkt);
                break;
        }
    }


    void v4_send_request(IPAddr target, BaseInterface iface)
    {
        if (EthernetStation station = cast(EthernetStation)iface)
            send_arp_request(target, station);
    }

    void v4_drain(ref Packet pkt, BaseInterface iface, const(ubyte)[] link_addr)
    {
        frame_and_send(pkt, iface, link_addr);
    }

    void v6_send_request(IPv6Addr target, BaseInterface iface)
    {
        if (EthernetStation station = cast(EthernetStation)iface)
            send_neighbour_solicit(this, target, station);
    }

    void v6_drain(ref Packet pkt, BaseInterface iface, const(ubyte)[] link_addr)
    {
        frame_and_send(pkt, iface, link_addr);
    }

    NeighbourCache!IPAddr   neighbour_v4;
    NeighbourCache!IPv6Addr neighbour_v6;
    FirewallChains firewall_v4;
    FirewallChains firewall_v6;
    // TODO: ReassemblyTable reasm;
    // TODO: ConntrackTable conntrack;
}


static if (has_tcp)
void tcp_input(ref Packet pkt)
{
    if (pkt.data.length < IPv4Header.sizeof + TcpHeader.sizeof)
        return;
    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t ip_hdr_len = ip.ihl * 4;
    if (pkt.data.length < ip_hdr_len + TcpHeader.sizeof)
        return;

    // Trim to IP total_length: Ethernet pads small frames to 46-byte minimum
    // payload, and pkt.data may include those padding bytes.
    size_t ip_total = ip.total_length.bigEndianToNative!ushort;
    if (ip_total < ip_hdr_len + TcpHeader.sizeof || ip_total > pkt.data.length)
        return;

    const(ubyte)[] tcp_seg = (cast(const(ubyte)*)pkt.data.ptr)[ip_hdr_len .. ip_total];
    tcp_segment_input(InetAddress(IPAddr(ip.src), 0), InetAddress(IPAddr(ip.dst), 0), tcp_seg, pkt.creation_time);
}
