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
import protocol.ip.udp;

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
        SysTime now = getSysTime();
        neighbour_v4.tick(now);
        neighbour_v6.tick(now);
    }

    // Pick a local IPv4 source address to use when sending to `dst`.
    // Walks IPAddress collection for a connected network containing dst,
    // and returns one of our IPs on that interface. Returns IPAddr.any if none.
    IPAddr select_source_v4(IPAddr dst)
    {
        BaseInterface egress = resolve_connected_iface(dst);
        if (!egress)
            return IPAddr.any;
        foreach (a; Collection!IPAddress().values)
            if (cast(BaseInterface)a.iface is egress)
                return a.address.addr;
        return IPAddr.any;
    }

private:

    L3Capability cap_for(BaseInterface iface)
    {
        foreach (ref b; _bound[])
            if (b.iface is iface)
                return b.cap;
        return L3Capability.none;
    }

    BoundInterface* find_bound(BaseInterface iface)
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
                icmp_send_error(this, IcmpType.dest_unreachable,
                                IcmpDestUnreachableCode.net, pkt);
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

        BoundInterface* bound = find_bound(out_iface);
        if (!bound)
            return;  // egress to an unbound interface -> drop (shouldn't happen if route table is sane)

        const(ubyte)[] link_addr = neighbour_v4.resolve(next_hop, out_iface, pkt);
        if (link_addr is null)
        {
            version (DebugIPEgress)
                log.trace("egress drop: no neighbour for ", next_hop);
            // TODO: queue pending packet, kick off ARP request
            return;
        }

        frame_and_send(pkt, *bound, link_addr);
    }

    void frame_and_send(ref Packet pkt, ref BoundInterface bound, const(ubyte)[] link_addr)
    {
        if (bound.cap & L3Capability.ethernet)
        {
            if (link_addr.length != 6 || pkt.data.length < 1)
                return;
            MACAddress dst;
            dst.b[] = link_addr[0 .. 6];
            ubyte ver = (cast(const(ubyte)*)pkt.data.ptr)[0] >> 4;
            EtherType etype = ver == 6 ? EtherType.ip6 : EtherType.ip4;
            bound.iface.send(dst, pkt.data, etype);
            return;
        }
        // TODO: sixlowpan / ppp / raw_ip
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
                tcp_input(pkt);
                break;
            case IpProtocol.udp:
                .udp_input(this, pkt);
                break;
            default:
                icmp_send_error(this, IcmpType.dest_unreachable,
                                IcmpDestUnreachableCode.protocol, pkt);
                break;
        }
    }

    void tcp_input(ref Packet pkt)  { /* TODO: stub - hand to tcp module when it exists */ }

    void v4_send_request(IPAddr target, BaseInterface iface)
    {
        send_arp_request(target, iface);
    }

    void v4_drain(ref Packet pkt, BaseInterface iface, const(ubyte)[] link_addr)
    {
        if (auto bound = find_bound(iface))
            frame_and_send(pkt, *bound, link_addr);
    }

    Array!BoundInterface _bound;
    NeighbourCache!IPAddr   neighbour_v4;
    NeighbourCache!IPv6Addr neighbour_v6;
    FirewallChains firewall_v4;
    FirewallChains firewall_v6;
    // TODO: ReassemblyTable reasm;
    // TODO: ConntrackTable conntrack;
}
