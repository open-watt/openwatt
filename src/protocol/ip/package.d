module protocol.ip;

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
}

import router.iface;
import router.iface.ethernet;

public import protocol.ip.stack : IPStack;

version(Windows)
{
    import urt.array;
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


// =============================================================================
// Event-driven TCP/UDP endpoint API
//
// The consumer hands in local/remote config plus an RX callback and gets back a
// handle it uses to send, tweak options, and tear down. The listen counterpart
// spawns a handle per inbound connection. This is the migration target away from
// polling raw sockets / Stream objects directly.
//
// Two backends, selected at compile time:
//   - UseInternalIPStack: handles bind directly into the in-tree stack and RX is
//     pushed inline from ingress (zero-copy; the payload points into the ingress
//     packet, valid for the callback only).
//   - otherwise: handles wrap a non-blocking urt.socket, pumped each frame from
//     IPModule.update() (an event-driven reactor will replace the polling).
//
// Currently only UDP takes the direct path; TCP is socket-backed on both.
// =============================================================================

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


// Initiate an outbound TCP connection. Returns immediately; the handshake
// completes asynchronously and reports IPEvent.connected (or .error) via
// on_event. `local` optionally binds a source address/port.
TCPConnection* tcp_connect(InetAddress remote, TCPRecvHandler on_recv, TCPEventHandler on_event = null, const(InetAddress)* local = null)
{
    version (UseInternalIPStack)
    {
        if (remote.family != AddressFamily.ipv4)
            return null;     // in-tree stack TCP is v4-only

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

        // tcp_connect only fails before it registers the pcb, so free_pcb is safe.
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
        return c;
    }
}

// Listen for inbound TCP connections. on_accept fires with a fresh, already-open
// TCPConnection* for each peer; the consumer installs that handle's RX/event
// handlers from inside the callback.
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
        return l;
    }
}

TCPListener* tcp_listen(ushort port, TCPAcceptHandler on_accept)
    => tcp_listen(InetAddress(IPAddr.any, port), on_accept);

// Open a UDP endpoint. `local` binds a receive address/port (null binds any:0,
// an ephemeral port); when `remote` is set, send() targets it and the endpoint
// only delivers datagrams from that peer.
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
            if (_socket)
                _socket.close();
            _socket = Socket.invalid;
            _closing = true;
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
            if (_closing)
                return;
            final switch (_phase)
            {
                case Phase.connecting:
                    pump_connect();
                    break;
                case Phase.open:
                    flush_tx();
                    if (_phase == Phase.open)
                        pump_recv();
                    break;
                case Phase.dead:
                    break;
            }
        }

        void pump_connect()
        {
            PollFd fd;
            fd.socket = _socket;
            fd.request_events = PollEvents.write;
            uint num;
            if (poll(fd, Duration.zero, num).failed)
            {
                fail(IPEvent.error);
                return;
            }
            if (num == 0)
                return;
            if (fd.return_events & (PollEvents.error | PollEvents.hangup | PollEvents.invalid))
            {
                fail(IPEvent.error);
                return;
            }

            _phase = Phase.open;
            _socket.get_peer_name(_remote);
            if (_keepalive_set)
                set_keepalive(_socket, _keepalive, _keep_idle, _keep_interval, _keep_count);
            if (_no_delay_set)
                _socket.set_socket_option(SocketOption.tcp_no_delay, _no_delay);
            if (_on_event)
                _on_event(&this, IPEvent.connected);
        }

        void pump_recv()
        {
            ubyte[4096] buf = void;
            foreach (_; 0 .. 8)
            {
                size_t n;
                Result r = _socket.recv(buf[], MsgFlags.none, &n);
                if (r.succeeded)
                {
                    if (n == 0)
                        break;
                    if (_on_recv)
                        _on_recv(&this, buf[0 .. n], getTime());
                    if (_phase != Phase.open || _closing)
                        return;
                    if (n < buf.length)
                        break;
                    continue;
                }
                SocketResult sr = r.socket_result;
                if (sr == SocketResult.would_block)
                    break;
                fail(sr == SocketResult.connection_closed ? IPEvent.closed : IPEvent.error);
                return;
            }
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
            if (_socket)
                _socket.close();
            _socket = Socket.invalid;
            _closing = true;
        }
    }

private:
    bool _closing;
    InetAddress _local;
    TCPAcceptHandler _on_accept;

    version (UseInternalIPStack)
    {
        TcpPcb* _lpcb;

        void pump() {}     // inbound connections arrive via the on_accept hook

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

        void pump()
        {
            if (_closing)
                return;
            foreach (_; 0 .. 8)
            {
                Socket conn;
                InetAddress remote;
                Result r = _socket.accept(conn, &remote);
                if (r.failed)
                {
                    if (r.socket_result != SocketResult.would_block)
                        _closing = true;
                    return;
                }

                conn.set_socket_option(SocketOption.non_blocking, true);
                TCPConnection* c = register_tcp_conn(conn, remote);
                c._phase = TCPConnection.Phase.open;
                if (_on_accept)
                    _on_accept(&this, c, getTime());
                else
                    c.close();
                if (_closing)
                    return;
            }
        }
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
            if (_socket)
                _socket.close();
            _socket = Socket.invalid;
            _closing = true;
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

        // Backend teardown, run from the sweep before the endpoint is freed.
        // (An explicit ~this() can't be emplaced by allocT in this runtime.)
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

        void pump() {}     // RX is push-delivered via deliver()
    }
    else
    {
        Socket _socket;

        void release() {}

        void pump()
        {
            if (_closing)
                return;
            ubyte[2048] buf = void;
            foreach (_; 0 .. 8)
            {
                size_t n;
                InetAddress from;
                Result r = _socket.recvfrom(buf[], MsgFlags.none, &from, &n);
                if (r.failed)
                    break;
                if (_on_recv)
                    _on_recv(&this, buf[0 .. n], from, getTime());
                if (_closing)
                    return;
            }
        }
    }
}


private __gshared Array!(TCPConnection*) _tcp_conns;
private __gshared Array!(TCPListener*)   _tcp_listeners;
private __gshared Array!(UDPEndpoint*)   _udp_eps;

version (UseInternalIPStack)
{
    private __gshared IPStack* _stack_ptr;
    private __gshared ushort _next_udp_port = 49_152;

    private ushort allocate_udp_port()
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
}

private IPAddr v4_addr(ref const InetAddress a) pure
    => a.family == AddressFamily.ipv4 ? a._a.ipv4.addr : IPAddr.any;

version (UseInternalIPStack)
{
    // pcb.handle marker: the endpoint owns this pcb, so tcp_tick must not
    // auto-free it (that path is gated on handle == 0). The endpoint frees it
    // itself in close(), or hands it to tcp_tick by clearing handle there.
    private enum int TcpEndpointOwned = -1;

    private __gshared ushort _next_tcp_port = 49_152;

    private ushort allocate_tcp_port()
    {
        ushort p = _next_tcp_port;
        _next_tcp_port = _next_tcp_port == 65_535 ? 49_152 : cast(ushort)(_next_tcp_port + 1);
        return p;
    }

    private TCPConnection* register_tcp_conn_pcb(TcpPcb* pcb)
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
    private TCPConnection* register_tcp_conn(Socket s, InetAddress remote)
    {
        TCPConnection* c = defaultAllocator().allocT!TCPConnection();
        c._socket = s;
        c._remote = remote;
        _tcp_conns ~= c;
        return c;
    }
}

private ushort port_of(ref const InetAddress a) pure
{
    if (a.family == AddressFamily.ipv4)
        return a._a.ipv4.port;
    if (a.family == AddressFamily.ipv6)
        return a._a.ipv6.port;
    return 0;
}

private void pump_ip_endpoints()
{
    foreach (i; 0 .. _tcp_listeners.length)
        _tcp_listeners[i].pump();
    foreach (i; 0 .. _tcp_conns.length)
        _tcp_conns[i].pump();
    foreach (i; 0 .. _udp_eps.length)
        _udp_eps[i].pump();

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
        pump_ip_endpoints();

        Collection!IPAddress().update_all();
        Collection!IPPool().update_all();
        Collection!IPv6Pool().update_all();
        Collection!IPRoute().update_all();
        Collection!TCPServer().update_all();
        _stack.update();
    }

private:
    IPStack _stack;
}
