module protocol.ip.stack;

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.time;

import manager.collection;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import protocol.ip.address;
import protocol.ip.arp;
import protocol.ip.firewall;
import protocol.ip.icmp;
import protocol.ip.neighbour;
import protocol.ip.route;
import protocol.ip.tcp;
import protocol.ip.udp;

//version = DebugIP;            // bind / unbind, no-route, etc.
//version = DebugRawIngress;    // every packet entering on_packet
//version = DebugIPIngress;     // incoming ethernet packets
//version = DebugIPRoute;       // every route lookup result
//version = DebugIPEgress;      // every packet leaving via egress()
//version = DebugIPNeighbour;   // ARP / ND cache activity

nothrow @nogc:


__gshared uint _route_gen = 1;

void bump_route_generation()
{
    ++_route_gen;
}
uint route_generation()
    => _route_gen;


struct RouteResult
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
    IPAddr next_hop;        // == destination if directly attached
    ubyte ttl_decrement;
}


struct IPv4Header
{
nothrow @nogc:
align(1):
    ubyte ver_ihl;          // upper nibble = version, lower = IHL (32-bit words)
    ubyte tos;
    ubyte[2] total_length;
    ubyte[2] ident;
    ubyte[2] flags_frag;
    ubyte ttl;
    ubyte protocol;
    ubyte[2] checksum;
    IPAddr src;
    IPAddr dst;

    ubyte version_() const pure
        => ver_ihl >> 4;
    ubyte ihl() const pure
        => ver_ihl & 0x0F;
}

enum IpProtocol : ubyte
{
    icmp = 1,
    tcp  = 6,
    udp  = 17,
}


struct IPStack
{
nothrow @nogc:

    alias log = Log!"ip";

    void init_resolvers()
    {
        neighbour_v4.send_request = &v4_send_request;
        neighbour_v4.drain        = &v4_drain;
        // TODO: ND wiring once v6 lands
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
        // TODO: RouteResult r = route_lookup_v6(pkt); dispatch(pkt, r, firewall_v6);
    }

    void update()
    {
        MonoTime now = getTime();
        neighbour_v4.tick(now);
        neighbour_v6.tick(now);
        tcp_tick(this, now);
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

    // Frame handler registered for PacketType.ethernet by the IP module at init.
    // Ethernet-shaped frames (real Ethernet, VLAN sub-interfaces, Ethernet-bridge,
    // and protocols normalised to Ethernet framing) all funnel here.
    void on_packet(ref Packet pkt, BaseInterface iface)
    {
        version (DebugRawIngress)
            log.trace("ingress if=", iface.name, " type=", pkt.type, " (", pkt.length, ") [ ", pkt.data[0 .. 24 < pkt.length ? 24 : pkt.length], 24 < pkt.length ? " ... ]" : " ]");

        ethernet_ingress(pkt, iface);
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

    void ethernet_ingress(ref Packet pkt, BaseInterface iface)
    {
        if (pkt.type != PacketType.ethernet)
            return;
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
        ushort total = (ushort(ip.total_length[0]) << 8) | ip.total_length[1];
        if (total < hdr_len || total > pkt.data.length)
            return;
        if (internet_checksum(pkt.data.ptr[0 .. hdr_len]) != 0)
            return;

        // Learn (src_ip, l2_src_mac) from any unicast IPv4 frame.
        if (pkt.type == PacketType.ethernet)
        {
            const Ethernet eth = pkt.hdr!Ethernet();
            if (!eth.src.is_multicast())
                neighbour_v4.learn(ip.src, iface, eth.src.b[]);
        }

        // TODO: reassembly via ident/flags/frag_offset
        // TODO: conntrack lookup for stateful firewall

        if (firewall_v4.run(HookPoint.prerouting, pkt) == Verdict.drop)
            return;

        RouteResult r = route_lookup_v4(pkt);
        dispatch(pkt, r, firewall_v4);
    }

    void ingress_v6(ref Packet pkt, BaseInterface iface)
    {
        // TODO: validate v6 header: version==6, payload_length, walk extension headers
        // TODO: reassembly via fragment extension header
        // TODO: conntrack lookup for stateful firewall

        if (firewall_v6.run(HookPoint.prerouting, pkt) == Verdict.drop)
            return;

        // TODO: RouteResult r = route_lookup_v6(pkt); dispatch(pkt, r, firewall_v6);
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
                uint c = (uint(ip.checksum[0]) << 8) | ip.checksum[1];
                c += uint(r.ttl_decrement) << 8;
                c = (c & 0xFFFF) + (c >> 16);
                ip.checksum[0] = cast(ubyte)(c >> 8);
                ip.checksum[1] = cast(ubyte)(c & 0xFF);
                // TODO: if pkt.length > out_iface.actual_mtu, fragment (v4) or send PTB (v6)
                if (fw.run(HookPoint.forward, pkt) == Verdict.drop)
                    return;
                egress(pkt, r.out_iface, r.next_hop, fw);
                return;
            }
        }
    }

    BaseInterface resolve_connected_iface(IPAddr ip)
    {
        foreach (a; Collection!IPAddress().values)
            if (a.address.contains(ip))
                return a.iface;
        return null;
    }

    RouteResult route_lookup_v4(ref const Packet pkt)
    {
        if (pkt.length < IPv4Header.sizeof)
            return RouteResult(RouteResult.Kind.none);
        const IPv4Header* h = cast(const(IPv4Header)*)pkt.data.ptr;
        return route_lookup_v4_dst(h.dst);
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
                log.trace("egress drop: no neighbour for ", next_hop);
            // TODO: queue pending packet, kick off ARP request
            return;
        }

        frame_and_send(pkt, out_iface, link_addr);
    }

    // TODO: when sixlowpan / ppp / raw_ip are added, dispatch by iface type
    //       (or by a virtual on BaseInterface) to choose the framing.
    void frame_and_send(ref Packet pkt, BaseInterface out_iface, const(ubyte)[] link_addr)
    {
        if (link_addr.length != 6 || pkt.data.length < 1)
            return;
        MACAddress dst;
        dst.b[] = link_addr[0 .. 6];
        ubyte ver = (cast(const(ubyte)*)pkt.data.ptr)[0] >> 4;
        EtherType etype = ver == 6 ? EtherType.ip6 : EtherType.ip4;
        out_iface.send(dst, pkt.data, etype);
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
            case IpProtocol.icmp:
                .icmp_input(this, pkt);
                break;
            case IpProtocol.tcp:
                .tcp_input(this, pkt);
                break;
            case IpProtocol.udp:
                .udp_input(this, pkt);
                break;
            default:
                icmp_send_error(this, IcmpType.dest_unreachable, IcmpDestUnreachableCode.protocol, pkt);
                break;
        }
    }


    void v4_send_request(IPAddr target, BaseInterface iface)
    {
        send_arp_request(target, iface);
    }

    void v4_drain(ref Packet pkt, BaseInterface iface, const(ubyte)[] link_addr)
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
