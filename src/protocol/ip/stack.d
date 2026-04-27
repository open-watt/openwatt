module protocol.ip.stack;

import urt.array;
import urt.endian;
import urt.inet;
import urt.log;
import urt.time;

import manager.collection;

import router.iface;
import router.iface.packet;

import protocol.ip.address;
import protocol.ip.firewall;
import protocol.ip.neighbour;
import protocol.ip.route;

version = DebugIP;            // bind / unbind, no-route, etc.
//version = DebugIPIngress;     // every packet entering on_packet
version = DebugIPRoute;       // every route lookup result
version = DebugIPEgress;      // every packet leaving via egress()
version = DebugIPNeighbour;   // ARP / ND cache activity

nothrow @nogc:


enum L3Capability : ubyte
{
    none      = 0,
    ethernet  = 1 << 0,   // raw ip4/ip6/arp framed in Ethernet
    sixlowpan = 1 << 1,   // RFC 6282 compressed IPv6 over 802.15.4 / BLE / etc.
    ppp       = 1 << 2,   // PPP IPCP / IPV6CP framed link
    raw_ip    = 1 << 3,   // tunnels: payload is already an IP datagram
}


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


struct BoundInterface
{
    BaseInterface iface;
    L3Capability cap;
    // TODO: per-interface MTU, link-local addr, accept_ra flag, etc.
}


struct IPv4Header
{
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

    ubyte version_() const pure => ver_ihl >> 4;
    ubyte ihl() const pure => ver_ihl & 0x0F;
}


struct IPStack
{
nothrow @nogc:

    alias log = Log!"ip";

    void add_interface(BaseInterface iface, L3Capability cap)
    {
        foreach (ref b; _bound[])
            if (b.iface is iface)
                return;

        if (!iface.set_primary_dispatch(&on_packet))
        {
            log.warning("can't bind ", iface.name, " - already owned (bridged?)");
            return;
        }

        version (DebugIP)
            log.info("bind iface=", iface.name, " cap=", cast(uint)cap);

        _bound ~= BoundInterface(iface, cap);
    }

    void remove_interface(BaseInterface iface)
    {
        foreach (i, ref b; _bound[])
        {
            if (b.iface is iface)
            {
                // TODO: clear_primary_dispatch() on iface once available
                _bound.remove(i);
                // TODO: drop neighbour entries / pending TX bound to this iface
                return;
            }
        }
    }

    // Locally-originated v4 traffic enters here (TCP/UDP send, ping, etc.)
    void output_v4(ref Packet pkt)
    {
        if (firewall_v4.run(HookPoint.output, pkt) == Verdict.drop)
            return;
        RouteResult r = route_lookup_v4(pkt);
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
        neighbour.tick(getSysTime());
    }

private:

    L3Capability cap_for(BaseInterface iface)
    {
        foreach (ref b; _bound[])
            if (b.iface is iface)
                return b.cap;
        return L3Capability.none;
    }

    const(BoundInterface)* find_bound(BaseInterface iface)
    {
        foreach (ref b; _bound[])
            if (b.iface is iface)
                return &b;
        return null;
    }

    void on_packet(ref Packet pkt, BaseInterface iface)
    {
        version (DebugIPIngress)
            log.trace("ingress iface=", iface.name, " ptype=", cast(uint)pkt.type, " len=", pkt.length);

        L3Capability cap = cap_for(iface);
        if (cap & L3Capability.ethernet)
            ethernet_ingress(pkt, iface);
        // TODO: sixlowpan_decompress(pkt, iface) -> ingress_v6(pkt, iface)
        // TODO: ppp_ingress(pkt, iface)
        // TODO: raw_ip ingress -> peek IP version byte, call ingress() directly
    }

    void ethernet_ingress(ref Packet pkt, BaseInterface iface)
    {
        if (pkt.type != PacketType.ethernet)
            return;
        const Ethernet eth = pkt.hdr!Ethernet();
        if (eth.dst != iface.mac && !eth.dst.is_multicast())
            return;     // promiscuous capture; not addressed to us
        switch (eth.ether_type)
        {
            case EtherType.arp:
                neighbour.on_arp(pkt, iface);
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
        // TODO: validate v4 header: version==4, IHL>=5, total_length, header checksum
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
                // TODO: send ICMP destination unreachable back via reverse route
                return;
            case RouteResult.Kind.blackhole:
                return;
            case RouteResult.Kind.local:
                if (fw.run(HookPoint.input, pkt) == Verdict.drop)
                    return;
                deliver_local(pkt);
                return;
            case RouteResult.Kind.forward:
                // TODO: decrement TTL; if it hits 0, send ICMP time-exceeded
                // TODO: if pkt.length > out_iface.actual_mtu, fragment (v4) or send PTB (v6)
                if (fw.run(HookPoint.forward, pkt) == Verdict.drop)
                    return;
                egress(pkt, r.out_iface, r.next_hop, fw);
                return;
        }
    }

    BaseInterface resolve_connected_iface(IPAddr ip)
    {
        foreach (a; Collection!IPAddress().values)
            if (a.address.contains(ip))
                return cast(BaseInterface)a.iface;
        return null;
    }

    RouteResult route_lookup_v4(ref const Packet pkt)
    {
        if (pkt.length < IPv4Header.sizeof)
            return RouteResult(RouteResult.Kind.none);

        const IPv4Header* h = cast(const(IPv4Header)*)pkt.data.ptr;
        IPAddr dst = h.dst;

        foreach (a; Collection!IPAddress().values)
        {
            if (a.address.addr == dst)
            {
                version (DebugIPRoute)
                    log.trace("route dst=", dst, " -> local on ", a.iface.name[]);
                return RouteResult(RouteResult.Kind.local, cast(BaseInterface)a.iface, dst, 0);
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
                BaseInterface egress = cast(BaseInterface)best_rt.out_interface;
                if (!egress && best_rt.gateway != IPAddr.any)
                    egress = resolve_connected_iface(best_rt.gateway);
                if (egress)
                    best = RouteResult(RouteResult.Kind.forward, egress, next, 1);
            }
        }

        version (DebugIPRoute)
        {
            if (!best_rt)
                log.trace("route dst=", dst, " -> none");
            else
                log.trace("route dst=", dst, " -> kind=", cast(uint)best.kind, " via=", best.out_iface ? best.out_iface.name[] : "<none>");
        }

        return best;
    }

    void egress(ref Packet pkt, BaseInterface out_iface, IPAddr next_hop, ref FirewallChains fw)
    {
        if (fw.run(HookPoint.postrouting, pkt) == Verdict.drop)
            return;

        if (!out_iface)
            return;

        version (DebugIPEgress)
            log.trace("egress iface=", out_iface.name, " next_hop=", next_hop, " len=", pkt.length);

        const(BoundInterface)* bound = find_bound(out_iface);
        if (!bound)
            return;  // egress to an unbound interface -> drop (shouldn't happen if route table is sane)

        // TODO: const(ubyte)[] link_addr = neighbour.resolve(next_hop, out_iface, pkt);
        // TODO: if (link_addr is null) return;  // queued, will fire when ARP/ND completes
        // TODO: frame_and_send(pkt, *bound, link_addr);
    }

    void frame_and_send(ref Packet pkt, ref const BoundInterface bound, const(ubyte)[] link_addr)
    {
        // TODO: per-cap framing:
        //   ethernet  -> prepend EthHdr{dst=link_addr, src=our_mac, type=ip4|ip6}; bound.iface.forward(pkt)
        //   sixlowpan -> compress + 802.15.4 frame; bound.iface.forward(pkt)
        //   ppp       -> PPP NCP frame; bound.iface.forward(pkt)
        //   raw_ip    -> bound.iface.forward(pkt) as-is
    }

    void deliver_local(ref Packet pkt)
    {
        // TODO: switch on next-header / protocol:
        //   1  (icmp)  -> icmp_input(pkt)
        //   6  (tcp)   -> tcp_input(pkt)
        //   17 (udp)   -> udp_input(pkt)
        //   58 (icmp6) -> icmp6_input(pkt)
        //   else       -> raw socket demux, or ICMP protocol-unreachable
    }

    void icmp_input(ref Packet pkt) { /* TODO: ping reply, error generation */ }
    void tcp_input(ref Packet pkt)  { /* TODO: stub - hand to tcp module when it exists */ }
    void udp_input(ref Packet pkt)  { /* TODO: stub - hand to udp module when it exists */ }

    Array!BoundInterface _bound;
    NeighbourCache neighbour;
    FirewallChains firewall_v4;
    FirewallChains firewall_v6;
    // TODO: ReassemblyTable reasm;
    // TODO: ConntrackTable conntrack;
}
