module protocol.ip;

import urt.inet;
import urt.mem.temp;
import urt.string;
import urt.log;

import manager.collection;
import manager.console;
import manager.console.session : Session;
import manager.plugin;

import protocol.ip.address;
import protocol.ip.pool;
import protocol.ip.route;
import protocol.ip.stack;

import router.iface;
import router.iface.ethernet;

public import protocol.ip.stack : IPStack;

version(Windows)
{
    import urt.array;
    import urt.internal.sys.windows.winsock2 : AF_INET, sockaddr_in;
    import manager.os.iphlpapi;
    import driver.windows.ethernet : WindowsPcapEthernet;
    import driver.windows.wifi : WindowsWifiRadio, WindowsWlan;
}

nothrow @nogc:


// =============================================================================
// Known limitations / TODOs across the IP stack
//
// Each entry notes what's missing and where it bites. Tags:
//   [small/medium/large]   = implementation effort
//   (high/med/low value)   = perceived value to our actual deployments
// Without explicit qualification, high-value items belong to common WAN /
// real-world paths; low-value items mostly matter for niche scenarios or
// edge security postures we don't currently expose.
// =============================================================================
//
// TCP (protocol/ip/tcp.d)
//   - No congestion control. cwnd is effectively the peer's rwnd; on a lossy
//     or congested path we'll bury it and back off only via RTO. Reno is the
//     obvious next step. [medium] (high value on WAN, low on LAN-only)
//   - No fast retransmit / SACK / DSACK. One drop stalls for ~RTO until the
//     retransmit fires. SACK is the highest-leverage addition; without it
//     bulk transfers over lossy paths are very slow. [medium] (high)
//   - No window scaling / timestamps. Throughput on high-BDP paths is capped
//     at 64KB in flight regardless of bandwidth. PAWS protection absent, but
//     at our speeds wraparound isn't a real risk. [small each] (med)
//   - No Nagle. Bursty small-write apps emit many tiny segments. Delayed
//     ACK *is* implemented. [small] (low/med — depends on app patterns)
//   - No TCP keepalive. SO_KEEPALIVE is a no-op; long-idle dead peers aren't
//     detected. FIN_WAIT_2 timeout bounds half-closes but ESTABLISHED can
//     leak indefinitely. [small] (med — long-lived MQTT/Modbus links care)
//   - PMTUD is reactive only. We set DF and react to ICMP frag-needed, but
//     never re-probe upward (RFC 1191 §6.5) and have no blackhole detection
//     (RFC 4821 / PLPMTUD). Firewalls that swallow ICMP stall us with no
//     recovery -- common in real WAN paths. [medium] (high)
//   - ISS generation isn't cryptographic (RFC 6528). Spoofing risk on
//     untrusted networks. [small] (low for LAN, med for internet-facing)
//   - No challenge-ACK on suspect RST/SYN (RFC 5961). Off-path RST injection
//     can tear down connections. [small] (low — niche)
//   - No SYN cookies. Vulnerable to SYN flood DoS on internet-exposed ports.
//     [medium] (med if we expose listeners on the public internet)
//   - No TCP Fast Open (RFC 7413). Saves an RTT on reconnect; little use for
//     our typical long-lived flows. [medium] (low)
//   - No ECN (RFC 3168). Modern routers can mark instead of drop. Pairs with
//     congestion control. [small] (low without CC)
//   - No urgent pointer / URG flag handling. Practically dead protocol
//     feature. [small] (low)
//   - PCB lookup is O(N) linear over _pcbs. Fine at our scale; replace with
//     a 4-tuple hash if connection counts grow. [small] (low at IoT scale)
//
// UDP (protocol/ip/udp.d)
//   - Recv queue cap of 16 datagrams per socket; newest dropped on overflow.
//     Bursty receivers (DHCP server, mDNS responder) can lose packets. (med)
//   - No fragmentation; datagrams larger than path MTU are refused at
//     output. Needed for oversized DNS, DHCP option storms. (med)
//   - ICMP unreachables not propagated to the socket layer. Apps see no
//     fast-fail and wait for app-level timeout. (med)
//   - No "connected UDP" semantics: after connect() we still accept packets
//     from any peer rather than filtering. [small] (low)
//   - No IGMP. Multicast joins aren't signalled to the upstream switch /
//     router; we just listen on the wire. Works on dumb L2; fails on
//     IGMP-snooping switches. (med — mDNS, SSDP, multicast Modbus)
//
// ICMP (protocol/ip/icmp.d)
//   - frag_needed not generated when forwarding oversized DF=1 packets.
//     Router-role only; we're primarily end-host. [small] (low)
//   - ICMP redirect (type 5) ignored on receive. We don't act on routing
//     hints from upstream gateways. [small] (low)
//   - No ICMP echo client (we reply, can't ping out). Diagnostics gap;
//     `/tools/ping` would be a natural place. [small] (med)
//   - No ICMP rate counter exposed. We rate-limit silently; no way to see
//     drops in diagnostics. [small] (low)
//   - No router solicitation / advertisement processing. Static config only.
//     [small] (low — we use DHCP)
//
// Routing / forwarding
//   - No source-address selection per RFC 6724. We pick the first IPAddress
//     on the egress iface; bites on multi-addressed interfaces (e.g. a
//     primary plus secondary IP). (med)
//   - Per-egress metric / multipath: model allows it, lookup doesn't.
//     [medium] (low — single-uplink deployments)
//   - Implicit-connected fallback in route_lookup_v4_dst is a HACK. Either
//     document and keep, or require explicit /protocol/ip/route entries --
//     decide before this pattern entrenches.
//   - No policy routing (mark-based / src-based). [medium] (low)
//   - No per-interface forwarding toggle. We forward whenever a route says
//     so; can't disable forwarding on, say, a guest WiFi interface. [small]
//     (med if we deploy as a real router with isolation requirements)
//   - No NAT (SNAT/DNAT). Site-to-site / multi-tenant deployments require
//     it. Also relevant if the device is the home gateway. [large] (high if
//     we ever position as a gateway, otherwise low)
//
// Neighbour cache (protocol/ip/neighbour.d)
//   - Single-slot pending-packet queue per entry. On a cold ARP burst all
//     but the last queued packet is dropped. Aging + NUD probes ARE
//     implemented; resolution kicks off on first miss. [small] (low)
//   - No gratuitous ARP on address bind. Peers won't refresh stale caches
//     when we change or move our IP. [small] (med — IP roams between iface
//     are silent failures)
//   - No ARP probe / DAD (RFC 5227) before claiming an address. Silent
//     collisions possible. [small] (low)
//   - No proxy ARP. Can't transparently bridge L2 to a routed segment.
//     [small] (low — niche)
//   - No console "add static neighbour" command for diagnostics / pinning.
//     [small] (low)
//
// IPv6
//   - ingress_v6 is a stub: no header validation, no extension-header walk,
//     no reassembly, no route lookup, no output, no ND. [large] (high if
//     we ever ship to a v6-only network; low for current deployments)
//   - No DHCPv6 / SLAAC. [medium] (paired with above)
//   - No ICMPv6 (echo, ND, MLD). [medium]
//   - 6LoWPAN frame handler not registered (PacketType._6lowpan). [medium]
//     (only valuable if we get a 6LoWPAN driver on board)
//   - No privacy extensions (RFC 4941). [small] (low)
//
// Fragmentation
//   - v4 fragments dropped at ingress (no reassembly). Affects large
//     incoming UDP / fragmented ICMP. [medium] (med — DNS-over-UDP edge
//     cases bite here)
//   - Egress doesn't fragment; oversized datagrams dropped. TCP segments by
//     MSS so this only bites UDP/raw senders. [small] (low — apps can
//     work around with smaller writes)
//
// Sockets (protocol/ip/socket.d)
//   - DNS / get_address_info stubbed. Apps must use literal IPs.
//     (low — explicit choice; we resolve via /protocol/dns module instead)
//   - No SO_ERROR readback for non-blocking connect completion. Apps poll
//     PollEvents.write to detect connect. [small] (low — current apps cope)
//   - Most SocketOption values accepted but no-op (SO_KEEPALIVE, SO_LINGER,
//     TCP_NODELAY, IP_TTL, SO_REUSEADDR, etc). [small each] (low individually,
//     med cumulatively for portability of 3rd-party libs)
//   - No raw sockets. [small] (low — only matters for tools like our own
//     ping / traceroute, which don't exist yet)
//   - No async ICMP error delivery. TCP RST / UDP port-unreachable should
//     surface as ECONNREFUSED / EHOSTUNREACH on next read/write. [small]
//     (med)
//   - No IP_PKTINFO / IP_RECVDSTADDR. Apps that bind 0.0.0.0 can't tell
//     which local addr a packet arrived on. [small] (med — DHCP server,
//     multi-homed responders)
//   - No SO_BINDTODEVICE. Can't constrain a socket to a specific egress
//     interface. [small] (med — multi-uplink scenarios)
//   - No dual-stack v4-mapped-in-v6 sockets. (paired with v6 work)
//
// Bridging / VLAN
//   - IP stack and bridges share primary dispatch on a port; bind-time check
//     warns. No automatic rebind to bridge-as-iface flow. (med)
//   - No VLAN-aware IP binding (one IP per VLAN sub-iface). May already
//     work via /interface/vlan; verify before claiming a TODO.
//
// Stack-wide
//   - No loopback interface. Apps can't connect to themselves over IP
//     (127.0.0.1). [small] (med — many libs assume loopback exists)
//   - No IP options handling on receive (record-route, source routing).
//     We silently strip / ignore. [small] (low — modern internet drops
//     these anyway)
//   - No DSCP / TOS preservation across forward. Fields are zeroed on
//     egress. [small] (low — only matters with traffic shaping)
//   - No tunneling (IP-in-IP, GRE, VXLAN). [large] (low/med — site-to-site
//     would benefit but isn't on the deployment roadmap)
//
// Diagnostics / console
//   - tcp_print and neighbour_v4_print expose live state; routes/addresses
//     print via their Collections. Missing: socket-layer print, UDP PCB
//     print, per-PCB PMTU history, ICMP error counters, packet drop
//     counters by reason. [small each] (med — debugging without these is
//     guesswork)
//   - No /tools/ping or /tools/traceroute. [small] (med — every other
//     router has these)
//   - No flow logging hook. Firewall logs only by Verdict, not full path.
//     [small] (low)
//
// Performance / scale
//   - No zero-copy receive path; every ingress copies into a Packet. Fine
//     at IoT scale; revisit if we ever push gigabits. [large] (low)
//   - Linear route lookup. Fine for tens of routes; trie if hundreds.
//     [medium] (low at our scale)
//
// =============================================================================


class IPModule : Module
{
    mixin DeclareModule!"protocol.ip";
nothrow @nogc:

    override void pre_init()
    {
        version (UseInternalIPStack)
        {
            import protocol.ip.socket : install_socket_backend;
            install_socket_backend(&_stack);
        }
    }

    override void init()
    {
        g_app.console.register_collection!IPAddress();
        g_app.console.register_collection!IPPool();
        g_app.console.register_collection!IPv6Pool();
        g_app.console.register_collection!IPRoute();

        _stack.init_resolvers();

        register_frame_handler(PacketType.ethernet, &_stack.on_packet);
        // TODO: register additional frame handlers when other L3 carriers land
        //       (PacketType._6lowpan, ppp/IPCP frame type, raw_ip tunnels).

        import protocol.ip.tcp : tcp_print;
        g_app.console.register_command!tcp_print("/protocol/ip/tcp", this, "print");
        g_app.console.register_command!neighbour_v4_print("/protocol/ip/neighbour", this, "print");
    }

    void neighbour_v4_print(Session session)
    {
        import router.iface.mac : MACAddress;
        import manager.console.table : Table;
        import urt.mem.temp : tconcat;

        auto entries = _stack.neighbour_v4_cache.entries;
        if (entries.length == 0)
        {
            session.write_line("No IPv4 neighbour entries");
            return;
        }

        Table t;
        t.add_column("ip");
        t.add_column("mac");
        t.add_column("state");
        t.add_column("rtry", Table.TextAlign.right);
        t.add_column("iface");

        foreach (ref e; entries)
        {
            MACAddress mac;
            if (e.link_addr_len >= 6)
                mac.b[] = e.link_addr[0 .. 6];

            t.add_row();
            t.cell(tconcat(e.ip));
            t.cell(tconcat(mac));
            t.cell(tconcat(e.state));
            t.cell(tconcat(e.retry_count));
            t.cell(e.iface ? e.iface.name[] : "");
        }

        t.render(session);
    }

    version(Windows)
    void seed_from_windows()
    {
        if (!iphlpapi_loaded() || GetIpForwardTable2 is null)
            return;

        struct IfMapEntry { uint if_index; BaseInterface iface; }
        Array!IfMapEntry if_map;

        enumerate_os_adapters((IP_ADAPTER_ADDRESSES_LH* p) nothrow @nogc {
            const(char)[] guid = adapter_guid(p);
            if (guid.length == 0)
                return;

            BaseInterface iface;
            foreach (e; Collection!WindowsPcapEthernet().values)
            {
                if (parse_npf_guid(e.adapter) == guid)
                {
                    iface = cast(BaseInterface)e;
                    break;
                }
            }
            if (!iface)
            {
                foreach (w; Collection!WindowsWlan().values)
                {
                    auto r = cast(WindowsWifiRadio)w.radio;
                    if (r && parse_npf_guid(r.adapter) == guid)
                    {
                        iface = cast(BaseInterface)w;
                        break;
                    }
                }
            }
            if (!iface)
                return;

            if_map ~= IfMapEntry(p.IfIndex, iface);

            for (auto u = p.FirstUnicastAddress; u !is null; u = u.Next)
            {
                if (u.Address.lpSockaddr is null)
                    continue;
                ushort family = *cast(ushort*)u.Address.lpSockaddr;
                if (family != AF_INET)
                    continue;
                const sockaddr_in* sin = cast(const sockaddr_in*)u.Address.lpSockaddr;

                IPNetworkAddress net_addr;
                net_addr.addr.address = sin.sin_addr.s_addr;
                net_addr.prefix_len   = u.OnLinkPrefixLength;

                IPAddress ip = Collection!IPAddress().create(tconcat(iface.name, ".addr"));
                if (!ip)
                    continue;
                ip.address = net_addr;
                ip.iface   = iface;
            }
        });

        if (if_map.length == 0)
            return;

        enumerate_ipv4_routes((ref const IpForwardRowV4 r) nothrow @nogc {
            if (r.is_loopback)
                return;
            if (IPNetworkAddress.loopback.contains(r.destination.addr))
                return;
            if (IPNetworkAddress.linklocal.contains(r.destination.addr))
                return;
            if (IPNetworkAddress.multicast.contains(r.destination.addr))
                return;
            if (r.destination.prefix_len == 32)
                return;     // host routes (incl. 255.255.255.255) are stack-internal

            BaseInterface iface = null;
            foreach (ref m; if_map[])
            {
                if (m.if_index == r.if_index)
                {
                    iface = m.iface;
                    break;
                }
            }
            if (!iface)
                return;

            IPRoute rt = Collection!IPRoute().create(null);
            if (!rt)
                return;
            rt.destination = r.destination;
            if (r.gateway != IPAddr.any)
                rt.gateway = r.gateway;
            else
                rt.out_interface = iface;
            rt.distance = r.metric > 255 ? cast(ubyte)255 : cast(ubyte)r.metric;
        });
    }

    override void update()
    {
        Collection!IPAddress().update_all();
        Collection!IPPool().update_all();
        Collection!IPv6Pool().update_all();
        Collection!IPRoute().update_all();
        _stack.update();
    }

private:
    IPStack _stack;
}
