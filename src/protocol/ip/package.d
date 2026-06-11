module protocol.ip;

import urt.array;
import urt.inet;
import urt.mem.temp;
import urt.socket;
import urt.string;
import urt.time;
import urt.log;

import manager.collection;
import manager.console;
import manager.console.session : Session;
import manager.plugin;

import protocol.ip.address;
import protocol.ip.pool;
import protocol.ip.route;
import protocol.ip.stack;
import protocol.ip.tcp_stream;
import protocol.ip.udp_stream;

version (UseInternalIPStack)
{
    import protocol.ip.udp;
    import protocol.ip.tcp : TcpPcb, TcpState, tcp_assign_id, tcp_send_data, tcp_close, free_pcb,
        native_tcp_connect = tcp_connect, native_tcp_listen = tcp_listen;

    public import protocol.ip.stack : IPStack;
}

import router.iface;
import router.iface.ethernet;

version(Windows)
{
    import urt.internal.sys.windows.winsock2 : AF_INET, sockaddr_in;
    import driver.windows.iphlpapi;
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

enum IPProtocol : ubyte
{
    icmp = 1,
    tcp  = 6,
    udp  = 17,
}

struct IPv4Header
{
nothrow @nogc:

    ubyte ver_ihl;  // upper nibble = version, lower = IHL (32-bit words)
    ubyte tos;
    ubyte[2] total_length;
    ubyte[2] ident;
    ubyte[2] flags_frag;
    ubyte ttl;
    IPProtocol protocol;
    ubyte[2] checksum;
    ubyte[4] src;
    ubyte[4] dst;

    ubyte version_() const pure
        => ver_ihl >> 4;
    ubyte ihl() const pure
        => ver_ihl & 0x0F;
}


enum IPEvent : ubyte
{
    connected,      // active connect completed (TCP only)
    closed,         // peer closed the connection (graceful EOF)
    error,          // connection reset / fatal error
}

alias TCPRecvHandler   = void delegate(TCPConnection* conn, const(void)[] data, MonoTime rx_time) nothrow @nogc;
alias TCPEventHandler  = void delegate(TCPConnection* conn, IPEvent event) nothrow @nogc;
alias TCPAcceptHandler = void delegate(TCPListener* listener, TCPConnection* conn, MonoTime rx_time) nothrow @nogc;
alias UDPRecvHandler   = void delegate(UDPEndpoint* ep, const(void)[] data, ref const InetAddress from, MonoTime rx_time) nothrow @nogc;

TCPConnection* tcp_connect(InetAddress remote, TCPRecvHandler on_recv, TCPEventHandler on_event = null, const(InetAddress)* local = null)
{
    version (UseInternalIPStack)
    {
        if (remote.family != AddressFamily.ipv4)
            return null;     // in-tree stack TCP is v4-only for now...

        TcpPcb* pcb = defaultAllocator().allocT!TcpPcb();
        tcp_assign_id(pcb);
        pcb.handle = TcpEndpointOwned;     // keep tcp_tick from auto-freeing it
        if (local && local.family == AddressFamily.ipv4)
        {
            pcb.local_addr = local._a.ipv4.addr;
            pcb.local_port = local._a.ipv4.port;
        }
        if (pcb.local_port == 0)
            pcb.local_port = allocate_tcp_port();
        pcb.remote_addr = remote._a.ipv4.addr;
        pcb.remote_port = remote._a.ipv4.port;

        TCPConnection* c = defaultAllocator().allocT!TCPConnection();
        c._pcb = pcb;
        c._remote = remote;
        c._on_recv = on_recv;
        c._on_event = on_event;
        c._phase = TCPConnection.Phase.connecting;
        pcb.conn_owner = c;

        if (!native_tcp_connect(*_stack_ptr, pcb))
        {
            pcb.conn_owner = null;
            free_pcb(pcb);
            defaultAllocator().freeT(c);
            return null;
        }
        _tcp_conns ~= c;
        return c;
    }
    else
    {
        AddressFamily af = remote.family;
        if (af != AddressFamily.ipv4 && af != AddressFamily.ipv6)
            return null;

        Socket s;
        if (create_socket(af, SocketType.stream, Protocol.tcp, s).failed)
            return null;
        s.set_socket_option(SocketOption.non_blocking, true);

        if (local && (local.family == AddressFamily.ipv4 || local.family == AddressFamily.ipv6))
        {
            if (s.bind(*local).failed)
            {
                s.close();
                return null;
            }
        }

        Result r = s.connect(remote);
        if (r.failed && r.socket_result != SocketResult.would_block)
        {
            s.close();
            return null;
        }

        TCPConnection* c = register_tcp_conn(s, remote);
        c._on_recv = on_recv;
        c._on_event = on_event;
        _worker.register(EntryKind.tcp_conn, cast(size_t)c, s, true);
        return c;
    }
}

TCPListener* tcp_listen(InetAddress local, TCPAcceptHandler on_accept)
{
    version (UseInternalIPStack)
    {
        if (local.family != AddressFamily.ipv4)
            return null;     // in-tree stack TCP is v4-only

        TcpPcb* pcb = defaultAllocator().allocT!TcpPcb();
        tcp_assign_id(pcb);
        pcb.handle = TcpEndpointOwned;
        pcb.local_addr = local._a.ipv4.addr;
        pcb.local_port = local._a.ipv4.port;
        if (pcb.local_port == 0)
            pcb.local_port = allocate_tcp_port();

        TCPListener* l = defaultAllocator().allocT!TCPListener();
        l._lpcb = pcb;
        l._local = InetAddress(pcb.local_addr, pcb.local_port);
        l._on_accept = on_accept;
        pcb.listen_owner = l;
        native_tcp_listen(pcb);     // sets state=listen, registers
        _tcp_listeners ~= l;
        return l;
    }
    else
    {
        AddressFamily af = local.family;
        if (af != AddressFamily.ipv4 && af != AddressFamily.ipv6)
            return null;

        Socket s;
        if (create_socket(af, SocketType.stream, Protocol.tcp, s).failed)
            return null;
        s.set_socket_option(SocketOption.non_blocking, true);
        s.set_socket_option(SocketOption.reuse_address, true);

        if (s.bind(local).failed || s.listen().failed)
        {
            s.close();
            return null;
        }

        TCPListener* l = defaultAllocator().allocT!TCPListener();
        l._socket = s;
        l._local = local;
        l._on_accept = on_accept;
        _tcp_listeners ~= l;
        _worker.register(EntryKind.tcp_listen, cast(size_t)l, s, false);
        return l;
    }
}

TCPListener* tcp_listen(ushort port, TCPAcceptHandler on_accept)
    => tcp_listen(InetAddress(IPAddr.any, port), on_accept);

// `local` binds a receive address/port (null binds any:ephemeral);
// when `remote` is set, send() targets it and the endpoint only delivers datagrams from that peer
UDPEndpoint* udp_open(const(InetAddress)* local, const(InetAddress)* remote, UDPRecvHandler on_recv)
{
    version (UseInternalIPStack)
    {
        // The in-tree stack does UDP over v4 only; deliver datagrams inline.
        UDPEndpoint* ep = defaultAllocator().allocT!UDPEndpoint();
        ep._on_recv = on_recv;

        UdpPcb* pcb = defaultAllocator().allocT!UdpPcb();
        if (local && local.family == AddressFamily.ipv4)
        {
            pcb.local_addr = local._a.ipv4.addr;
            pcb.local_port = local._a.ipv4.port;
        }
        if (pcb.local_port == 0)
            pcb.local_port = allocate_udp_port();
        if (remote && remote.family == AddressFamily.ipv4)
        {
            pcb.remote_addr = remote._a.ipv4.addr;
            pcb.remote_port = remote._a.ipv4.port;
            pcb.connected = true;
            ep._remote = *remote;
            ep._connected = true;
        }
        pcb.owner = ep;
        ep._pcb = pcb;
        udp_register(pcb);
        _udp_eps ~= ep;
        return ep;
    }
    else
    {
        AddressFamily af = AddressFamily.ipv4;
        if (local && (local.family == AddressFamily.ipv4 || local.family == AddressFamily.ipv6))
            af = local.family;
        else if (remote && (remote.family == AddressFamily.ipv4 || remote.family == AddressFamily.ipv6))
            af = remote.family;

        Socket s;
        if (create_socket(af, SocketType.datagram, Protocol.udp, s).failed)
            return null;
        s.set_socket_option(SocketOption.non_blocking, true);

        InetAddress bind_addr = local ? *local : (af == AddressFamily.ipv6 ? InetAddress(IPv6Addr.any, 0) : InetAddress(IPAddr.any, 0));
        if (s.bind(bind_addr).failed)
        {
            s.close();
            return null;
        }

        UDPEndpoint* ep = defaultAllocator().allocT!UDPEndpoint();
        ep._socket = s;
        ep._on_recv = on_recv;
        if (remote && (remote.family == AddressFamily.ipv4 || remote.family == AddressFamily.ipv6))
        {
            ep._remote = *remote;
            ep._connected = true;
        }
        _udp_eps ~= ep;
        _worker.register(EntryKind.udp, cast(size_t)ep, s, false);
        return ep;
    }
}


struct TCPConnection
{
nothrow @nogc:

    InetAddress remote() const pure
        => _remote;

    bool connected() const pure
        => _phase == Phase.open;

    void recv_handler(TCPRecvHandler handler)
    {
        _on_recv = handler;
    }

    void event_handler(TCPEventHandler handler)
    {
        _on_event = handler;
    }

    version (UseInternalIPStack)
    {
        InetAddress local()
            => _pcb ? InetAddress(_pcb.local_addr, _pcb.local_port) : InetAddress();

        ptrdiff_t send(const(void[])[] data...)
        {
            if (_phase != Phase.open || _pcb is null)
                return 0;
            size_t total = 0;
            foreach (b; data)
                total += b.length;
            if (total == 0)
                return 0;
            if (_tx.length + total > max_tx)
                return 0;
            foreach (b; data)
                _tx ~= cast(const(ubyte)[])b;
            flush_tx();
            return _phase == Phase.open ? total : 0;
        }

        // The native stack has no keepalive / Nagle yet; record intent only.
        void enable_keepalive(bool enable, Duration idle = seconds(10), Duration interval = seconds(1), int count = 10)
        {
            _keepalive = enable;
            _keep_idle = idle;
            _keep_interval = interval;
            _keep_count = count;
            _keepalive_set = true;
        }

        void set_no_delay(bool enable)
        {
            _no_delay = enable;
            _no_delay_set = true;
        }

        void close()
        {
            if (_closing)
                return;
            if (_pcb)
            {
                _pcb.conn_owner = null;
                _pcb.handle = 0;     // detach: tcp_tick frees the pcb once it's fully closed
                tcp_close(*_stack_ptr, _pcb);
                if (_pcb.state == TcpState.closed)
                    free_pcb(_pcb);
                _pcb = null;
            }
            _phase = Phase.dead;
            _closing = true;
        }
    }
    else
    {
        InetAddress local()
        {
            InetAddress a;
            if (_socket)
                _socket.get_socket_name(a);
            return a;
        }

        ptrdiff_t send(const(void[])[] data...)
        {
            if (_phase != Phase.open)
                return 0;

            size_t total = 0;
            foreach (b; data)
                total += b.length;
            if (total == 0)
                return 0;

            if (_tx.length > 0)
            {
                flush_tx();
                if (_phase != Phase.open)
                    return 0;
                if (_tx.length > 0)
                {
                    foreach (b; data)
                    {
                        if (!queue_tx(b))
                            return 0;
                    }
                    return total;
                }
            }

            size_t sent;
            Result r = _socket.send(MsgFlags.none, &sent, data);
            if (r.failed && r.socket_result != SocketResult.would_block)
            {
                fail(IPEvent.error);
                return 0;
            }

            size_t skipped = 0;
            foreach (b; data)
            {
                if (skipped + b.length <= sent)
                {
                    skipped += b.length;
                    continue;
                }
                size_t off = sent > skipped ? sent - skipped : 0;
                if (!queue_tx(b[off .. $]))
                    break;
                skipped += b.length;
            }
            return total;
        }

        void enable_keepalive(bool enable, Duration idle = seconds(10), Duration interval = seconds(1), int count = 10)
        {
            _keepalive = enable;
            _keep_idle = idle;
            _keep_interval = interval;
            _keep_count = count;
            _keepalive_set = true;
            if (_phase == Phase.open)
                set_keepalive(_socket, enable, idle, interval, count);
        }

        void set_no_delay(bool enable)
        {
            _no_delay = enable;
            _no_delay_set = true;
            if (_phase == Phase.open)
                _socket.set_socket_option(SocketOption.tcp_no_delay, enable);
        }

        void close()
        {
            if (_closing)
                return;
            _closing = true;
            _worker.destroy_ep(EntryKind.tcp_conn, cast(size_t)&this);
        }
    }

private:
    enum Phase : ubyte { connecting, open, dead }

    Phase _phase;
    bool _closing;
    bool _keepalive;
    bool _keepalive_set;
    bool _no_delay;
    bool _no_delay_set;
    int _keep_count;
    Duration _keep_idle;
    Duration _keep_interval;
    InetAddress _remote;
    TCPRecvHandler _on_recv;
    TCPEventHandler _on_event;
    Array!ubyte _tx;

    enum size_t max_tx = 256 * 1024;

    void fail(IPEvent ev)
    {
        if (_phase == Phase.dead)
            return;
        _phase = Phase.dead;
        if (_on_event)
            _on_event(&this, ev);
    }

    version (UseInternalIPStack)
    {
        TcpPcb* _pcb;

        // RX is pushed inline via deliver(); the pump only observes control-state
        // transitions (connect completion, peer close, reset) and drains TX.
        void pump()
        {
            if (_closing || _pcb is null)
                return;
            final switch (_phase)
            {
                case Phase.connecting:
                    if (_pcb.state == TcpState.established)
                    {
                        _phase = Phase.open;
                        _remote = InetAddress(_pcb.remote_addr, _pcb.remote_port);
                        if (_on_event)
                            _on_event(&this, IPEvent.connected);
                    }
                    else if (_pcb.error_event || _pcb.state == TcpState.closed)
                        fail(IPEvent.error);
                    break;
                case Phase.open:
                    if (_pcb.error_event || _pcb.state == TcpState.closed)
                        fail(IPEvent.error);
                    else if (_pcb.fin_seen)
                        fail(IPEvent.closed);
                    else
                        flush_tx();
                    break;
                case Phase.dead:
                    break;
            }
        }

        package(protocol.ip) void deliver(const(ubyte)[] data, MonoTime rx_time)
        {
            if (_on_recv)
                _on_recv(&this, data, rx_time);
        }

        void flush_tx()
        {
            if (_pcb is null)
                return;
            while (_tx.length > 0)
            {
                size_t n = tcp_send_data(*_stack_ptr, _pcb, _tx[]);
                if (n == 0)
                    break;     // send buffer full; drained on a later pump
                _tx.remove(0, n);
            }
        }
    }
    else
    {
        Socket _socket;

        void pump()
        {
            if (_closing || _phase != Phase.open)
                return;
            flush_tx();
        }

        void flush_tx()
        {
            while (_tx.length > 0)
            {
                size_t sent;
                Result r = _socket.send(MsgFlags.none, &sent, cast(const(void)[])_tx[]);
                if (r.failed && r.socket_result != SocketResult.would_block)
                {
                    fail(IPEvent.error);
                    return;
                }
                if (sent == 0)
                    return;
                _tx.remove(0, sent);
            }
        }

        bool queue_tx(scope const(void)[] b)
        {
            if (b.length == 0)
                return true;
            if (_tx.length + b.length > max_tx)
                return false;
            _tx ~= cast(const(ubyte)[])b;
            return true;
        }
    }
}


struct TCPListener
{
nothrow @nogc:
    ushort port() const pure
        => port_of(_local);

    version (UseInternalIPStack)
    {
        void close()
        {
            if (_closing)
                return;
            if (_lpcb)
            {
                _lpcb.listen_owner = null;
                _lpcb.handle = 0;
                tcp_close(*_stack_ptr, _lpcb);     // RSTs unaccepted children, frees the listen pcb
                if (_lpcb.state == TcpState.closed)
                    free_pcb(_lpcb);
                _lpcb = null;
            }
            _closing = true;
        }
    }
    else
    {
        void close()
        {
            if (_closing)
                return;
            _closing = true;
            _worker.destroy_ep(EntryKind.tcp_listen, cast(size_t)&this);
        }
    }

private:
    bool _closing;
    InetAddress _local;
    TCPAcceptHandler _on_accept;

    version (UseInternalIPStack)
    {
        TcpPcb* _lpcb;

        package(protocol.ip) void on_child(TcpPcb* child, MonoTime rx_time)
        {
            child.handle = TcpEndpointOwned;
            TCPConnection* c = register_tcp_conn_pcb(child);
            if (_on_accept)
                _on_accept(&this, c, rx_time);
            else
                c.close();
        }
    }
    else
    {
        Socket _socket;
    }
}


struct UDPEndpoint
{
nothrow @nogc:
    InetAddress remote() const pure
        => _remote;

    // Send to the connected remote (set at open). Returns bytes sent, or 0.
    version (UseInternalIPStack)
    {
        InetAddress local()
            => _pcb ? InetAddress(_pcb.local_addr, _pcb.local_port) : InetAddress();

        ptrdiff_t send(scope const(void)[] data)
        {
            if (_closing || !_connected)
                return 0;
            if (!udp_output(*_stack_ptr, _pcb.local_addr, _pcb.local_port,
                            v4_addr(_remote), port_of(_remote), cast(const(ubyte)[])data))
                return 0;
            return data.length;
        }

        ptrdiff_t sendto(scope const(void)[] data, InetAddress to)
        {
            if (_closing)
                return 0;
            if (!udp_output(*_stack_ptr, _pcb.local_addr, _pcb.local_port,
                            v4_addr(to), port_of(to), cast(const(ubyte)[])data))
                return 0;
            return data.length;
        }

        void close()
        {
            if (_closing)
                return;
            if (_pcb)
                _pcb.owner = null;     // stop delivery; pcb torn down by release() on sweep
            _closing = true;
        }
    }
    else
    {
        InetAddress local()
        {
            InetAddress a;
            if (_socket)
                _socket.get_socket_name(a);
            return a;
        }

        ptrdiff_t send(scope const(void)[] data)
        {
            if (_closing || !_connected)
                return 0;
            size_t sent;
            if (_socket.sendto(&_remote, &sent, data).failed)
                return 0;
            return sent;
        }

        ptrdiff_t sendto(scope const(void)[] data, InetAddress to)
        {
            if (_closing)
                return 0;
            size_t sent;
            if (_socket.sendto(&to, &sent, data).failed)
                return 0;
            return sent;
        }

        void close()
        {
            if (_closing)
                return;
            _closing = true;
            _worker.destroy_ep(EntryKind.udp, cast(size_t)&this);
        }
    }

private:
    bool _closing;
    bool _connected;
    InetAddress _remote;
    UDPRecvHandler _on_recv;

    version (UseInternalIPStack)
    {
        UdpPcb* _pcb;

        void release()
        {
            if (_pcb)
            {
                udp_unregister(_pcb);
                foreach (ref dgm; _pcb.recv_queue[])
                    udp_free_datagram_data(dgm);
                defaultAllocator().freeT(_pcb);
                _pcb = null;
            }
        }

        package(protocol.ip) void deliver(IPAddr src, ushort sport, const(ubyte)[] data, MonoTime rx_time)
        {
            if (_on_recv)
            {
                InetAddress from = InetAddress(src, sport);
                _on_recv(&this, data, from, rx_time);
            }
        }
    }
    else
    {
        Socket _socket;

        void release() {}
    }
}


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
            _stack_ptr = &_stack;
        }
    }

    override void init()
    {
        g_app.console.register_collection!IPAddress();
        g_app.console.register_collection!IPPool();
        g_app.console.register_collection!IPv6Pool();
        g_app.console.register_collection!IPRoute();
        g_app.console.register_collection!TCPStream();
        g_app.console.register_collection!TCPServer();
        g_app.console.register_collection!UDPStream();

        version (KernelMirror)
        {
            import protocol.ip.linux_mirror : mirror_init;
            mirror_init();
        }

        version (UseInternalIPStack)
        {
            _stack.init_resolvers();

            register_frame_handler(PacketType.ethernet, &_stack.on_packet);
            // TODO: register additional frame handlers when other L3 carriers land
            //       (PacketType._6lowpan, ppp/IPCP frame type, raw_ip tunnels).

            import protocol.ip.tcp : tcp_print;
            g_app.console.register_command!tcp_print("/protocol/ip/tcp", this, "print");
            g_app.console.register_command!neighbour_v4_print("/protocol/ip/neighbour", this, "print");
        }
        else
            _worker.start();
    }

    override void deinit()
    {
        version (UseInternalIPStack) {} else
            _worker.stop();
    }

    version (UseInternalIPStack)
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
        pump_ip_endpoints();

        Collection!IPAddress().update_all();
        Collection!IPPool().update_all();
        Collection!IPv6Pool().update_all();
        Collection!IPRoute().update_all();
        Collection!TCPServer().update_all();

        version (UseInternalIPStack)
            _stack.update();

        version (KernelMirror)
        {
            import protocol.ip.linux_mirror : mirror_drain;
            mirror_drain();
        }
    }

private:
    version (UseInternalIPStack)
        IPStack _stack;
}


private:

__gshared Array!(TCPConnection*) _tcp_conns;
__gshared Array!(TCPListener*)   _tcp_listeners;
__gshared Array!(UDPEndpoint*)   _udp_eps;


IPAddr v4_addr(ref const InetAddress a) pure
    => a.family == AddressFamily.ipv4 ? a._a.ipv4.addr : IPAddr.any;

ushort port_of(ref const InetAddress a) pure
{
    if (a.family == AddressFamily.ipv4)
        return a._a.ipv4.port;
    if (a.family == AddressFamily.ipv6)
        return a._a.ipv6.port;
    return 0;
}

void pump_ip_endpoints()
{
    foreach (i; 0 .. _tcp_conns.length)
        _tcp_conns[i].pump();

    // the socket arm frees endpoints on the worker's destroy handshake instead.
    version (UseInternalIPStack)
    {
        for (size_t i = _tcp_conns.length; i-- > 0; )
        {
            if (_tcp_conns[i]._closing)
            {
                defaultAllocator().freeT(_tcp_conns[i]);
                _tcp_conns.removeSwapLast(i);
            }
        }
        for (size_t i = _tcp_listeners.length; i-- > 0; )
        {
            if (_tcp_listeners[i]._closing)
            {
                defaultAllocator().freeT(_tcp_listeners[i]);
                _tcp_listeners.removeSwapLast(i);
            }
        }
        for (size_t i = _udp_eps.length; i-- > 0; )
        {
            if (_udp_eps[i]._closing)
            {
                _udp_eps[i].release();
                defaultAllocator().freeT(_udp_eps[i]);
                _udp_eps.removeSwapLast(i);
            }
        }
    }
}

version (UseInternalIPStack)
{
    enum int TcpEndpointOwned = -1;

    __gshared IPStack* _stack_ptr;
    __gshared ushort _next_udp_port = 49_152;
    __gshared ushort _next_tcp_port = 49_152;

    ushort allocate_udp_port()
    {
        foreach (_; 0 .. 16_384)
        {
            ushort p = _next_udp_port;
            _next_udp_port = _next_udp_port == 65_535 ? 49_152 : cast(ushort)(_next_udp_port + 1);
            bool used = false;
            foreach (pcb; _pcbs[])
            {
                if (pcb.local_port == p)
                {
                    used = true;
                    break;
                }
            }
            if (!used)
                return p;
        }
        return _next_udp_port;
    }

    ushort allocate_tcp_port()
    {
        ushort p = _next_tcp_port;
        _next_tcp_port = _next_tcp_port == 65_535 ? 49_152 : cast(ushort)(_next_tcp_port + 1);
        return p;
    }

    TCPConnection* register_tcp_conn_pcb(TcpPcb* pcb)
    {
        TCPConnection* c = defaultAllocator().allocT!TCPConnection();
        c._pcb = pcb;
        c._phase = TCPConnection.Phase.open;
        c._remote = InetAddress(pcb.remote_addr, pcb.remote_port);
        pcb.conn_owner = c;
        _tcp_conns ~= c;
        return c;
    }
}
else
{
    import urt.array;
    import urt.thread;
    import urt.sync.semaphore;
    import urt.sync.spsc;
    import urt.atomic;

    TCPConnection* register_tcp_conn(Socket s, InetAddress remote)
    {
        TCPConnection* c = defaultAllocator().allocT!TCPConnection();
        c._socket = s;
        c._remote = remote;
        _tcp_conns ~= c;
        return c;
    }

    enum EntryKind : ubyte
    {
        tcp_conn,
        tcp_listen,
        udp
    }

    enum ReqKind : ubyte
    {
        register,
        destroy
    }

    struct Req
    {
        ReqKind   kind;
        EntryKind ek;
        size_t    ep;           // endpoint pointer, type-erased to a key
        Socket    socket;
        bool      connecting;
    }

    enum EvKind : ubyte {
        data,
        connected,
        peer_closed,
        error,
        accepted,
        destroyed
    }

    struct Ev
    {
        EvKind    kind;
        EntryKind ek;
        size_t    ep;           // endpoint pointer key; for accepted, the listener
        const(ubyte)[] buffer;  // data payload; owned, freed by the main dispatch
        InetAddress from;       // udp source / accepted remote
        Socket    socket;       // accepted child fd
        MonoTime  rx_time;
    }

    struct SocketWorker
    {
    nothrow @nogc:
        void start()
        {
            _space.init();

            // loopback wake socket: a sendto from the main thread breaks the
            // worker out of poll() the instant a request is queued.
            if (create_socket(AddressFamily.ipv4, SocketType.datagram, Protocol.udp, _wake).failed)
            {
                writeError("SocketWorker: no wake socket; socket backend disabled");
                _wake = Socket.invalid;
                return;
            }
            _wake.set_socket_option(SocketOption.non_blocking, true);
            if (_wake.bind(InetAddress(IPAddr.loopback, 0)).failed ||
                _wake.get_socket_name(_wake_addr).failed)
            {
                writeError("SocketWorker: failed to bind wake socket; socket backend disabled");
                _wake.close();
                _wake = Socket.invalid;
                return;
            }

            _thread = thread_spawn(&run);
        }

        void stop()
        {
            if (_thread)
            {
                atomicStore!(MemoryOrder.release)(_stop, true);
                wake();
                _space.signal();
                thread_join(_thread);
                _thread = null;
            }
            if (_wake)
            {
                _wake.close();
                _wake = Socket.invalid;
            }

            Ev ev;
            while (_ring.pop((&ev)[0 .. 1]) == 1)
            {
                if (ev.buffer.length)
                    defaultAllocator().free(cast(void[])ev.buffer);
                if (ev.kind == EvKind.accepted && ev.socket)
                    ev.socket.close();
            }
            foreach (c; _tcp_conns[])
            {
                if (c._socket)
                    c._socket.close();
                defaultAllocator().freeT(c);
            }
            _tcp_conns.clear();
            foreach (l; _tcp_listeners[])
            {
                if (l._socket)
                    l._socket.close();
                defaultAllocator().freeT(l);
            }
            _tcp_listeners.clear();
            foreach (e; _udp_eps[])
            {
                if (e._socket)
                    e._socket.close();
                defaultAllocator().freeT(e);
            }
            _udp_eps.clear();
            _space.destroy();
        }

        void register(EntryKind ek, size_t ep, Socket s, bool connecting)
        {
            post_req(Req(ReqKind.register, ek, ep, s, connecting));
        }

        void destroy_ep(EntryKind ek, size_t ep)
        {
            post_req(Req(ReqKind.destroy, ek, ep));
        }

    private:
        struct Entry
        {
            EntryKind kind;
            size_t    ep;
            Socket    socket;
            bool      connecting;
            bool      dead;     // error/eof posted; quiet until destroyed
        }

        Thread      _thread;
        Semaphore   _space;     // backpressure: dispatch signals as event slots free
        shared bool _stop;
        Socket      _wake = Socket.invalid;
        InetAddress _wake_addr;

        SPSCRing!(Req, 1024) _reqs;     // main -> worker
        SPSCRing!(Ev, 512)   _ring;     // worker -> main

        void post_req(Req r)
        {
            if (_thread is null)
                return;
            Req* slot = _reqs.reserve();
            while (slot is null)
            {
                wake();
                slot = _reqs.reserve();
            }
            *slot = r;
            _reqs.commit();
            wake();
        }

        void wake()
        {
            if (!_wake)
                return;
            size_t sent;
            ubyte one = 0;
            _wake.sendto(&_wake_addr, &sent, (&one)[0 .. 1]);
        }

        // worker thread ----------------------------------------------------

        void run()
        {
            Array!Entry entries;
            Array!PollFd fds;

            while (!atomicLoad!(MemoryOrder.acquire)(_stop))
            {
                apply_requests(entries);

                fds.clear();
                fds ~= PollFd(_wake, PollEvents.read);
                foreach (ref e; entries[])
                {
                    if (e.dead)
                        continue;
                    fds ~= PollFd(e.socket, e.connecting ? PollEvents.write : PollEvents.read);
                }

                uint num;
                if (poll(fds[], msecs(1000), num).failed || num == 0)
                    continue;

                if (fds[0].return_events & PollEvents.read)
                    drain_wake();

                bool posted = false;
                size_t ei = 0;
                for (size_t f = 1; f < fds.length; ++f)
                {
                    while (ei < entries.length && entries[ei].dead)
                        ++ei;
                    if (ei >= entries.length)
                        break;
                    Entry* e = &entries[ei++];
                    PollEvents re = fds[f].return_events;
                    if (re == PollEvents.none)
                        continue;
                    if (!service(e, re, posted))
                        return;     // stopping
                }

                if (posted)
                    g_app.post_event(&dispatch, getTime());
            }
        }

        void apply_requests(ref Array!Entry entries)
        {
            Req r;
            while (_reqs.pop((&r)[0 .. 1]) == 1)
            {
                final switch (r.kind)
                {
                    case ReqKind.register:
                        entries ~= Entry(r.ek, r.ep, r.socket, r.connecting);
                        break;
                    case ReqKind.destroy:
                        foreach (i; 0 .. entries.length)
                        {
                            if (entries[i].ep == r.ep)
                            {
                                entries.removeSwapLast(i);
                                break;
                            }
                        }
                        push(Ev(EvKind.destroyed, r.ek, r.ep));
                        break;
                }
            }
        }

        void drain_wake()
        {
            ubyte[64] tmp = void;
            for (;;)
            {
                size_t got;
                InetAddress from;
                if (recvfrom(_wake, tmp[], MsgFlags.none, &from, &got).failed || got == 0)
                    return;
            }
        }

        // service one ready entry. returns false only when shutting down.
        bool service(Entry* e, PollEvents re, ref bool posted)
        {
            if (e.connecting)
            {
                if (re & (PollEvents.error | PollEvents.hangup | PollEvents.invalid))
                {
                    e.dead = true;
                    posted = true;
                    return push(Ev(EvKind.error, e.kind, e.ep));
                }
                if (re & PollEvents.write)
                {
                    e.connecting = false;
                    posted = true;
                    return push(Ev(EvKind.connected, e.kind, e.ep));
                }
                return true;
            }

            if (e.kind == EntryKind.tcp_listen)
                return accept_children(e, posted);

            return read_ready(e, posted);
        }

        bool accept_children(Entry* e, ref bool posted)
        {
            foreach (_; 0 .. 16)
            {
                Socket child;
                InetAddress remote;
                Result r = e.socket.accept(child, &remote);
                if (r.failed)
                {
                    if (r.socket_result == SocketResult.would_block)
                        return true;
                    e.dead = true;
                    posted = true;
                    return push(Ev(EvKind.error, e.kind, e.ep));
                }
                child.set_socket_option(SocketOption.non_blocking, true);

                Ev ev;
                ev.kind = EvKind.accepted;
                ev.ek = EntryKind.tcp_listen;
                ev.ep = e.ep;
                ev.from = remote;
                ev.socket = child;
                ev.rx_time = getTime();
                posted = true;
                if (!push(ev))
                {
                    child.close();
                    return false;
                }
            }
            return true;
        }

        bool read_ready(Entry* e, ref bool posted)
        {
            immutable bool is_udp = e.kind == EntryKind.udp;

            size_t avail;
            if (pending(e.socket, avail).failed || avail == 0)
                avail = 2048;
            else if (avail > 256 * 1024)
                avail = 256 * 1024;

            void[] buf = defaultAllocator().alloc(avail);
            size_t got;
            InetAddress from;
            Result r = is_udp ? recvfrom(e.socket, buf, MsgFlags.none, &from, &got)
                              : recv(e.socket, buf, MsgFlags.none, &got);

            if (r.failed)
            {
                defaultAllocator().free(buf);
                if (r.socket_result == SocketResult.would_block || is_udp)
                    return true;     // udp: ignore transient errors, keep the socket
                // a genuine peer close (FIN) arrives as a failed ConnectionClosedResult.
                e.dead = true;
                posted = true;
                return push(Ev(EvKind.peer_closed, e.kind, e.ep));
            }
            if (got == 0)
            {
                defaultAllocator().free(buf);
                return true;     // nothing ready (would-block reported as success+0)
            }

            Ev ev;
            ev.kind = EvKind.data;
            ev.ek = e.kind;
            ev.ep = e.ep;
            ev.buffer = cast(const(ubyte)[])buf[0 .. got];
            ev.from = from;
            ev.rx_time = getTime();
            posted = true;
            return push(ev);
        }

        bool push(Ev ev)
        {
            Ev* slot = _ring.reserve();
            while (slot is null)
            {
                g_app.post_event(&dispatch, getTime());
                _space.wait(msecs(50));
                if (atomicLoad!(MemoryOrder.acquire)(_stop))
                    return false;
                slot = _ring.reserve();
            }
            *slot = ev;
            _ring.commit();
            return true;
        }

        // main thread ------------------------------------------------------

        void dispatch(MonoTime)
        {
            Ev ev;
            while (_ring.pop((&ev)[0 .. 1]) == 1)
            {
                handle(ev);
                _space.signal();
            }
        }

        void handle(ref Ev ev)
        {
            final switch (ev.kind)
            {
                case EvKind.data:
                {
                    if (ev.ek == EntryKind.udp)
                    {
                        UDPEndpoint* ep = cast(UDPEndpoint*)ev.ep;
                        if (!ep._closing && ep._on_recv)
                        {
                            InetAddress from = ev.from;
                            ep._on_recv(ep, ev.buffer, from, ev.rx_time);
                        }
                    }
                    else
                    {
                        TCPConnection* c = cast(TCPConnection*)ev.ep;
                        if (!c._closing && c._on_recv)
                            c._on_recv(c, ev.buffer, ev.rx_time);
                    }
                    break;
                }
                case EvKind.connected:
                {
                    TCPConnection* c = cast(TCPConnection*)ev.ep;
                    if (!c._closing && c._phase == TCPConnection.Phase.connecting)
                    {
                        c._phase = TCPConnection.Phase.open;
                        c._socket.get_peer_name(c._remote);
                        if (c._keepalive_set)
                            set_keepalive(c._socket, c._keepalive, c._keep_idle, c._keep_interval, c._keep_count);
                        if (c._no_delay_set)
                            c._socket.set_socket_option(SocketOption.tcp_no_delay, c._no_delay);
                        if (c._on_event)
                            c._on_event(c, IPEvent.connected);
                    }
                    break;
                }
                case EvKind.peer_closed:
                {
                    TCPConnection* c = cast(TCPConnection*)ev.ep;
                    if (!c._closing)
                        c.fail(IPEvent.closed);
                    break;
                }
                case EvKind.error:
                {
                    TCPConnection* c = cast(TCPConnection*)ev.ep;
                    if (!c._closing)
                        c.fail(IPEvent.error);
                    break;
                }
                case EvKind.accepted:
                    accept_on_main(ev);
                    break;
                case EvKind.destroyed:
                    free_endpoint(ev.ek, ev.ep);
                    break;
            }

            if (ev.buffer.length)
                defaultAllocator().free(cast(void[])ev.buffer);
        }

        void accept_on_main(ref Ev ev)
        {
            TCPListener* l = cast(TCPListener*)ev.ep;
            Socket child = ev.socket;
            if (l._closing)
            {
                child.close();
                return;
            }
            TCPConnection* c = register_tcp_conn(child, ev.from);
            c._phase = TCPConnection.Phase.open;
            // register before on_accept so a close() from the handler is ordered after.
            register(EntryKind.tcp_conn, cast(size_t)c, child, false);
            if (l._on_accept)
                l._on_accept(l, c, ev.rx_time);
            else
                c.close();
        }

        void free_endpoint(EntryKind ek, size_t ep)
        {
            final switch (ek)
            {
                case EntryKind.tcp_conn:
                {
                    TCPConnection* c = cast(TCPConnection*)ep;
                    for (size_t i = _tcp_conns.length; i-- > 0; )
                    {
                        if (_tcp_conns[i] is c)
                        {
                            _tcp_conns.removeSwapLast(i);
                            break;
                        }
                    }
                    if (c._socket)
                        c._socket.close();
                    defaultAllocator().freeT(c);
                    break;
                }
                case EntryKind.tcp_listen:
                {
                    TCPListener* l = cast(TCPListener*)ep;
                    for (size_t i = _tcp_listeners.length; i-- > 0; )
                    {
                        if (_tcp_listeners[i] is l)
                        {
                            _tcp_listeners.removeSwapLast(i);
                            break;
                        }
                    }
                    if (l._socket)
                        l._socket.close();
                    defaultAllocator().freeT(l);
                    break;
                }
                case EntryKind.udp:
                {
                    UDPEndpoint* u = cast(UDPEndpoint*)ep;
                    for (size_t i = _udp_eps.length; i-- > 0; )
                    {
                        if (_udp_eps[i] is u)
                        {
                            _udp_eps.removeSwapLast(i);
                            break;
                        }
                    }
                    if (u._socket)
                        u._socket.close();
                    defaultAllocator().freeT(u);
                    break;
                }
            }
        }
    }

    __gshared SocketWorker _worker;
}
