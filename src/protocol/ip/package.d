module protocol.ip;

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.log;
import urt.mem.pagepool;
import urt.mem.temp;
import urt.meta.nullable;
import urt.socket;
import urt.string;
import urt.time;
import urt.util : is_aligned;

import manager.collection;
import manager.console;
import manager.console.session : Session;
import manager.features : has_ipv6;
import manager.plugin;
import manager.reactor;
import manager : EventPriority, g_app;

import protocol.ip.address;
import protocol.ip.pool;
import protocol.ip.route;
import protocol.ip.stack;
import protocol.ip.tcp_stream;

version (UseInternalIPStack)
{
    import protocol.ip.igmp;
    import protocol.ip.udp;
    static if (has_ipv6)
        import protocol.ip.mld : mld_join, mld_leave;
    import protocol.ip.tcp : TcpPcb, TcpState, TcpSendBufSize, tcp_assign_id, tcp_send_data, tcp_consume_data, tcp_close, free_pcb,
        native_tcp_connect = tcp_connect, native_tcp_listen = tcp_listen;

    public import protocol.ip.stack : IPStack;
}

import router.iface;
import router.iface.endpoint;
import router.iface.ethernet;

version(Windows)
{
    import urt.internal.sys.windows.winsock2 : AF_INET, sockaddr_in;
    import driver.windows.iphlpapi;
    import driver.windows.ethernet : WindowsPcapEthernet;
    import driver.windows.wifi : WindowsWifiRadio, WindowsWlan;
}
else version (Posix)
    import urt.internal.os : IPPROTO_IP, IP_MULTICAST_IF, SOL_SOCKET, SO_BROADCAST, os_setsockopt = setsockopt;

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
//   - IGMPv2 only. IGMPv3 source filters are not represented by the socket API.
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
    hopopt     = 0,     // v6 hop-by-hop options extension header
    icmp       = 1,
    igmp       = 2,
    tcp        = 6,
    udp        = 17,
    ipv6_route = 43,    // v6 routing extension header
    ipv6_frag  = 44,    // v6 fragment extension header
    icmp6      = 58,
    no_next    = 59,
    ipv6_opts  = 60,    // v6 destination options extension header
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

struct IPv6Header
{
nothrow @nogc:

    ubyte[4] ver_tc_flow;   // 4b version, 8b traffic class, 20b flow label
    ubyte[2] payload_length;
    IPProtocol next_header;
    ubyte hop_limit;
    ubyte[16] src;
    ubyte[16] dst;

    ubyte version_() const pure
        => ver_tc_flow[0] >> 4;

    IPv6Addr src_addr() const pure
        => load_ipv6_address(src.ptr);
    IPv6Addr dst_addr() const pure
        => load_ipv6_address(dst.ptr);

    void src_addr(IPv6Addr a) pure
        => store_ipv6_address(src.ptr, a);
    void dst_addr(IPv6Addr a) pure
        => store_ipv6_address(dst.ptr, a);
}
static assert(IPv6Header.sizeof == 40);

IPv6Addr load_ipv6_address(const(ubyte)* source) pure
{
    IPv6Addr address;
    foreach (i; 0 .. 8)
        address.s[i] = loadBigEndian(cast(const(ushort)*)source + i);
    return address;
}

void store_ipv6_address(ubyte* destination, IPv6Addr address) pure
{
    foreach (i; 0 .. 8)
        storeBigEndian(cast(ushort*)destination + i, address.s[i]);
}

ushort pseudo_header_checksum_v6(ref const(ubyte)[16] source, ref const(ubyte)[16] destination, uint length, IPProtocol protocol) pure
{
    align(uint.sizeof) ubyte[40] pseudo_header = void;
    debug assert(is_aligned!(uint.sizeof)(pseudo_header.ptr));
    pseudo_header[0 .. 16] = source[];
    pseudo_header[16 .. 32] = destination[];
    storeBigEndian(cast(uint*)(pseudo_header.ptr + 32), length);
    storeBigEndian(cast(uint*)(pseudo_header.ptr + 36), ubyte(protocol));
    return internet_checksum(pseudo_header[]);
}

MACAddress ipv6_multicast_mac(IPv6Addr address) pure
{
    MACAddress mac;
    mac.b[0] = 0x33;
    mac.b[1] = 0x33;
    mac.b[2] = cast(ubyte)(address.s[6] >> 8);
    mac.b[3] = cast(ubyte)address.s[6];
    mac.b[4] = cast(ubyte)(address.s[7] >> 8);
    mac.b[5] = cast(ubyte)address.s[7];
    return mac;
}

enum IPEvent : ubyte
{
    connected,      // active connect completed (TCP only)
    closed,         // peer closed the connection (graceful EOF)
    error,          // connection reset / fatal error
}

private static immutable ubyte[6] zero_mac;

alias TCPRecvHandler = void delegate(TCPConnection* conn, const(void)[] data, MonoTime rx_time) nothrow @nogc;
alias TCPSendHandler = Page* delegate(TCPConnection* conn, size_t requested) nothrow @nogc;
alias TCPEventHandler = void delegate(TCPConnection* conn, IPEvent event) nothrow @nogc;
alias TCPAcceptHandler = void delegate(TCPListener* listener, TCPConnection* conn, MonoTime rx_time) nothrow @nogc;

TCPConnection* tcp_connect(InetAddress remote, TCPRecvHandler on_recv, TCPEventHandler on_event = null, const(InetAddress)* local = null)
{
    version (UseInternalIPStack)
    {
        if (remote.family != AddressFamily.ipv4 && remote.family != AddressFamily.ether)
            return null;     // TODO: ipv6
        if (remote.family == AddressFamily.ether)
        {
            if (local && local.family == AddressFamily.ether && !local.addr_any)
            {
                EthernetStation station = find_ether_station(MACAddress(local._a.ether.addr));
                if (!station)
                    return null;
            }
        }

        TcpPcb* pcb = alloc!TcpPcb();
        tcp_assign_id(pcb);
        pcb.handle = TcpEndpointOwned;     // keep tcp_tick from auto-freeing it
        if (local && local.family == remote.family)
            pcb.local = *local;
        else if (remote.family == AddressFamily.ether)
            pcb.local = InetAddress(zero_mac, 0);
        else
            pcb.local = InetAddress(IPAddr.any, 0);
        if (pcb.local.port == 0)
            pcb.local.port = allocate_tcp_port();
        pcb.remote = remote;

        TCPConnection* c = alloc!TCPConnection();
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
            free(c);
            return null;
        }
        _tcp_conns ~= c;
        return c;
    }
    else version (Windows)
    {
        if (remote.family != AddressFamily.ipv4)
            return null;     // IOCP path is v4-only for now
        IOCP_SOCKET s = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
        if (s == INVALID_SOCKET)
            return null;
        if (!g_app.reactor.associate(cast(HANDLE)s))
        {
            ws_closesocket(s);
            return null;
        }
        TCPConnection* c = register_tcp_conn(s, remote);
        c._on_recv = on_recv;
        c._on_event = on_event;
        if (!c.start_connect())
        {
            unregister_tcp_conn(c);
            ws_closesocket(s);
            free(c);
            return null;
        }
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
        if (!g_app.reactor.watch_fd(s.handle, true, &c.on_ready))   // write-ready = connect completion
        {
            unregister_tcp_conn(c);
            s.close();
            free(c);
            return null;
        }
        c._watched = true;
        return c;
    }
}

TCPListener* tcp_listen(InetAddress local, TCPAcceptHandler on_accept)
{
    version (UseInternalIPStack)
    {
        if (local.family != AddressFamily.ipv4 && local.family != AddressFamily.ether)
            return null;     // TODO: ipv6
        if (local.family == AddressFamily.ether)
        {
            if (!local.addr_any)
            {
                EthernetStation station = find_ether_station(MACAddress(local._a.ether.addr));
                if (!station)
                    return null;
            }
        }

        TcpPcb* pcb = alloc!TcpPcb();
        tcp_assign_id(pcb);
        pcb.handle = TcpEndpointOwned;
        pcb.local = local;
        if (pcb.local.port == 0)
            pcb.local.port = allocate_tcp_port();

        TCPListener* l = alloc!TCPListener();
        l._lpcb = pcb;
        l._local = pcb.local;
        l._on_accept = on_accept;
        pcb.listen_owner = l;
        native_tcp_listen(pcb);     // sets state=listen, registers
        _tcp_listeners ~= l;
        return l;
    }
    else version (Windows)
    {
        if (local.family != AddressFamily.ipv4)
            return null;     // IOCP path is v4-only for now
        IOCP_SOCKET s = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
        if (s == INVALID_SOCKET)
            return null;
        int yes = 1;
        ws_setsockopt(s, SOL_SOCKET_, SO_REUSEADDR_, &yes, cast(int)yes.sizeof);
        sockaddr_in la = to_sockaddr_in(local);
        if (ws_bind(s, &la, cast(int)sockaddr_in.sizeof) != 0 || ws_listen(s, 128) != 0)
        {
            ws_closesocket(s);
            return null;
        }
        TCPListener* l = alloc!TCPListener();
        l._handle = s;
        l._local = local;
        l._on_accept = on_accept;
        if (!g_app.reactor.associate(cast(HANDLE)s) || !l.post_accept())
        {
            ws_closesocket(s);
            free(l);
            return null;
        }
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

        TCPListener* l = alloc!TCPListener();
        l._socket = s;
        l._local = local;
        l._on_accept = on_accept;
        if (!g_app.reactor.watch_fd(s.handle, false, &l.on_ready))
        {
            s.close();
            free(l);
            return null;
        }
        l._watched = true;
        _tcp_listeners ~= l;
        return l;
    }
}

TCPListener* tcp_listen(ushort port, TCPAcceptHandler on_accept)
    => tcp_listen(InetAddress(IPAddr.any, port), on_accept);

struct TCPConnection
{
nothrow @nogc:

    InetAddress remote() const pure
        => _remote;

    bool connected() const pure
        => _phase == Phase.open;

    // interface this connection's route egresses through; null when the OS owns the socket and the
    // route is opaque to us
    inout(BaseInterface) egress_iface() inout pure
    {
        version (UseInternalIPStack)
            return _pcb ? _pcb.route_egress : null;
        else
            return null;
    }

    size_t tx_request() const pure
    {
        if (_phase != Phase.open)
            return 0;
        version (UseInternalIPStack)
            enum size_t ceiling = TcpSendBufSize;
        else
            enum size_t ceiling = max_tx_refill;
        size_t queued = tx_backlog;
        return queued < ceiling / 2 ? ceiling - queued : 0;
    }

    size_t tx_backlog() const pure
    {
        version (UseInternalIPStack)
            return _tx_bytes + (_pcb ? _pcb.send_buf.length : 0);
        else
            return _tx_bytes;
    }

    void recv_handler(TCPRecvHandler handler)
    {
        _on_recv = handler;
        version (UseInternalIPStack)
            if (handler && _pcb && _pcb.recv_buf.length != 0)
                queue_service();
    }

    void event_handler(TCPEventHandler handler)
    {
        _on_event = handler;
    }

    void tx_handler(TCPSendHandler handler)
    {
        _outgoing = handler;
        service_tx();
    }

    void release_tx_handler(TCPSendHandler handler)
    {
        if (_outgoing is handler)
            _outgoing = null;
    }

    ptrdiff_t send(const(void[])[] data...)
    {
        size_t total;
        foreach (buffer; data)
        {
            if (buffer.length > cast(size_t)ptrdiff_t.max - total)
                return 0;
            total += buffer.length;
        }
        if (_phase != Phase.open || total == 0)
            return 0;

        size_t accepted;
        size_t input_index;
        size_t input_offset;
        while (accepted < total)
        {
            size_t remaining = total - accepted;
            size_t bytes = remaining < max_page_data ? remaining : max_page_data;
            Page* page = page_alloc(bytes);
            if (!page)
                break;

            size_t output_offset;
            while (output_offset < bytes)
            {
                const(void)[] input = data[input_index];
                size_t available = input.length - input_offset;
                size_t copied = bytes - output_offset;
                if (copied > available)
                    copied = available;
                page.data[output_offset .. output_offset + copied] = input[input_offset .. input_offset + copied];
                output_offset += copied;
                input_offset += copied;
                if (input_offset == input.length)
                {
                    ++input_index;
                    input_offset = 0;
                }
            }

            if (!send_page(page))
            {
                page_free(page);
                break;
            }
            accepted += bytes;
        }
        return cast(ptrdiff_t)accepted;
    }

    bool send_page(Page* page)
    {
        if (_phase != Phase.open || !page || page.length == 0)
            return false;

        version (Windows)
        {
            if (_send)
            {
                page.next = null;
                if (_tx_tail)
                    _tx_tail.next = page;
                else
                    _tx_head = page;
                _tx_tail = page;
                _tx_bytes += page.length;
                return true;
            }

            SendOp* op = alloc!SendOp();
            if (!op)
                return false;
            op.io.on_complete = &send_complete;
            op.page = page;
            if (!post_send(op))
            {
                free(op);
                fail(IPEvent.error);
                return false;
            }
            _send = op;
            _tx_bytes += page.length;
        }
        else
        {
            bool empty = _tx_head is null;
            page.next = null;
            if (_tx_tail)
                _tx_tail.next = page;
            else
                _tx_head = page;
            _tx_tail = page;
            _tx_bytes += page.length;
            version (UseInternalIPStack)
            {
                if (empty)
                    queue_service();
            }
            else
            {
                if (empty)
                    g_app.reactor.modify_fd(_socket.handle, true);
            }
        }
        return true;
    }

    version (UseInternalIPStack)
    {
        InetAddress local()
            => _pcb ? _pcb.local : InetAddress();

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
            _outgoing = null;
            clear_tx();
        }
    }
    else version (Windows)
    {
        InetAddress local()
            => InetAddress();   // TODO: getsockname

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
            _closing = true;
            _on_recv = null;
            _on_event = null;
            _phase = Phase.dead;
            _outgoing = null;
            if (_handle != INVALID_SOCKET)
            {
                CancelIoEx(cast(HANDLE)_handle, null);
                ws_closesocket(_handle);
                _handle = INVALID_SOCKET;
            }
            clear_tx();
            // freed by the pump sweep once the cancelled ops' completions drain
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
            _phase = Phase.dead;
            _outgoing = null;
            detach_watch();
            if (_socket)
            {
                _socket.close();
                _socket = null;
            }
            clear_tx();
            // freed by the pump sweep
        }
    }

private:
    enum Phase : ubyte { connecting, open, dead }
    enum size_t max_tx_refill = 16 * 1024;
    enum size_t max_page_data = ushort.max - Page.sizeof - (size_t.sizeof - 1);

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
    Page* _tx_head;
    Page* _tx_tail;
    size_t _tx_bytes;
    TCPSendHandler _outgoing;
    bool _servicing_tx;

    void fail(IPEvent ev)
    {
        if (_phase == Phase.dead)
            return;
        _phase = Phase.dead;
        _outgoing = null;
        clear_tx();
        TCPEventHandler handler = _on_event;
        _on_recv = null;
        _on_event = null;
        if (handler)
            handler(&this, ev);
    }

    void consume_tx(size_t bytes)
    {
        while (bytes != 0)
        {
            Page* page = _tx_head;
            size_t remaining = page.length;
            size_t consumed = bytes < remaining ? bytes : remaining;
            page.offset += cast(ushort)consumed;
            page.length -= cast(ushort)consumed;
            _tx_bytes -= consumed;
            bytes -= consumed;
            if (page.length == 0)
            {
                _tx_head = page.next;
                if (!_tx_head)
                    _tx_tail = null;
                page_free(page);
            }
        }
    }

    void clear_tx()
    {
        while (_tx_head)
        {
            Page* page = _tx_head;
            _tx_head = page.next;
            _tx_bytes -= page.length;
            page_free(page);
        }
        _tx_tail = null;
    }

    void service_tx()
    {
        if (_servicing_tx || _phase != Phase.open)
            return;
        _servicing_tx = true;
        scope (exit) _servicing_tx = false;

        size_t requested = tx_request();
        while (_outgoing && requested != 0)
        {
            TCPSendHandler handler = _outgoing;
            Page* page = handler(&this, requested);
            if (!page)
            {
                if (_outgoing is handler)
                    _outgoing = null;
                continue;
            }
            if (page.length == 0 || !send_page(page))
            {
                page_free(page);
                if (_outgoing is handler)
                    _outgoing = null;
                break;
            }
            requested = tx_request();
        }
    }

    version (UseInternalIPStack)
    {
        TcpPcb* _pcb;
        bool _service_pending;

        bool reclaimable() const
            => !_service_pending;

        void pump()
        {
            if (_closing || _pcb is null)
                return;
            final switch (_phase)
            {
                case Phase.connecting:
                    if (_pcb.state == TcpState.established)
                        mark_connected();
                    else if (_pcb.error_event || _pcb.state == TcpState.closed)
                        fail(IPEvent.error);
                    break;
                case Phase.open:
                    if (_pcb.error_event || _pcb.state == TcpState.closed)
                        fail(IPEvent.error);
                    else
                    {
                        drain_rx();
                        if (_closing || _pcb is null)
                            break;
                        if (_pcb.fin_seen && _pcb.recv_buf.length == 0)
                            fail(IPEvent.closed);
                        else
                        {
                            flush_tx();
                            service_tx();
                        }
                    }
                    break;
                case Phase.dead:
                    break;
            }
        }

        void mark_connected()
        {
            _phase = Phase.open;
            _remote = _pcb.remote;
            if (_on_event)
                _on_event(&this, IPEvent.connected);
            service_tx();
        }

        package(protocol.ip) void queue_service()
        {
            if (_service_pending || _closing || g_app is null)
                return;
            _service_pending = true;
            if (!g_app.post_event(&service_event, getTime(), EventPriority.control))
                _service_pending = false;
        }

        void service_event(MonoTime)
        {
            _service_pending = false;
            pump();
        }

        void drain_rx()
        {
            if (_pcb is null || _pcb.recv_buf.length == 0 || _on_recv is null)
                return;

            TcpPcb* pcb = _pcb;
            size_t bytes = pcb.recv_buf.length;
            MonoTime rx_time = pcb.recv_time;
            _on_recv(&this, pcb.recv_buf[0 .. bytes], rx_time);
            if (_pcb is pcb)
                tcp_consume_data(*_stack_ptr, pcb, bytes);
        }

        void flush_tx()
        {
            if (_pcb is null)
                return;
            while (_tx_head)
            {
                const(ubyte)[] data = cast(const(ubyte)[])_tx_head.data;
                size_t n = tcp_send_data(*_stack_ptr, _pcb, data);
                if (n == 0)
                    break;     // send buffer full; drained on a later pump
                consume_tx(n);
            }
        }
    }
    else version (Windows)
    {
        struct SendOp
        {
            IoOp io;
            Page* page;
        }
        struct RecvOp { IoOp io; ubyte[16 * 1024] buf; }

        IOCP_SOCKET _handle = INVALID_SOCKET;
        int  _outstanding;   // overlapped ops in flight; freed by the pump sweep once they drain
        SendOp* _send;
        IoOp _connect_op;
        RecvOp _recv;

        void pump() {}       // completion-driven; nothing to flush here

        bool reclaimable() const
            => _outstanding == 0;

        bool start_connect()
        {
            if (g_connect_ex is null)
                return false;
            sockaddr_in local_;     // ConnectEx requires an already-bound socket
            local_.sin_family = cast(short)WSA_AF_INET;
            ws_bind(_handle, &local_, cast(int)sockaddr_in.sizeof);

            sockaddr_in ra = to_sockaddr_in(_remote);
            _connect_op.ov = OVERLAPPED.init;
            _connect_op.on_complete = &connect_complete;
            uint sent;
            ++_outstanding;
            if (!g_connect_ex(_handle, &ra, cast(int)sockaddr_in.sizeof, null, 0, &sent, &_connect_op.ov) &&
                ws_lasterror() != WSA_IO_PENDING)
            {
                --_outstanding;
                return false;
            }
            return true;
        }

        void connect_complete(IoOp*, bool ok, uint, uint)
        {
            --_outstanding;
            if (_closing)
                return;
            if (!ok)
            {
                fail(IPEvent.error);
                return;
            }
            ws_setsockopt(_handle, SOL_SOCKET_, SO_UPDATE_CONNECT_CONTEXT, null, 0);
            _phase = Phase.open;
            if (_on_event)
                _on_event(&this, IPEvent.connected);
            if (!_closing)
            {
                service_tx();
                post_recv();
            }
        }

        bool post_recv()
        {
            _recv.io.ov = OVERLAPPED.init;
            _recv.io.on_complete = &recv_complete;
            WSABUF wb = WSABUF(cast(uint)_recv.buf.length, _recv.buf.ptr);
            uint flags, recvd;
            ++_outstanding;
            if (WSARecv(_handle, &wb, 1, &recvd, &flags, &_recv.io.ov, null) != 0 &&
                ws_lasterror() != WSA_IO_PENDING)
            {
                --_outstanding;
                fail(IPEvent.error);
                return false;
            }
            return true;
        }

        bool post_send(SendOp* op)
        {
            op.io.ov = OVERLAPPED.init;
            size_t remaining = op.page.length;
            uint length = remaining < uint.max ? cast(uint)remaining : uint.max;
            WSABUF wb = WSABUF(length, cast(ubyte*)op.page.data.ptr);
            uint sent;
            ++_outstanding;
            if (WSASend(_handle, &wb, 1, &sent, 0, &op.io.ov, null) != 0 &&
                ws_lasterror() != WSA_IO_PENDING)
            {
                --_outstanding;
                return false;
            }
            return true;
        }

        void recv_complete(IoOp*, bool ok, uint bytes, uint)
        {
            --_outstanding;
            if (_closing)
                return;
            if (!ok)
            {
                fail(IPEvent.error);
                return;
            }
            if (bytes == 0)
            {
                fail(IPEvent.closed);
                return;
            }
            if (_on_recv)
                _on_recv(&this, _recv.buf[0 .. bytes], getTime());
            if (!_closing && !post_recv())
                fail(IPEvent.error);
        }

        void send_complete(IoOp* op, bool ok, uint bytes, uint)
        {
            SendOp* sop = cast(SendOp*)op;
            debug assert(sop is _send);
            --_outstanding;
            size_t remaining = sop.page.length;
            debug assert(bytes <= remaining);
            if (!ok || bytes == 0 || bytes > remaining)
            {
                _tx_bytes -= remaining;
                page_free(sop.page);
                free(sop);
                _send = null;
                if (!_closing)
                    fail(IPEvent.error);
                return;
            }

            sop.page.offset += cast(ushort)bytes;
            sop.page.length -= cast(ushort)bytes;
            _tx_bytes -= bytes;
            bool active = !_closing && _phase == Phase.open;
            if (sop.page.length != 0 && active && post_send(sop))
            {
                service_tx();
                return;
            }

            remaining = sop.page.length;
            _tx_bytes -= remaining;
            page_free(sop.page);
            if (remaining != 0)
            {
                free(sop);
                _send = null;
                if (active)
                    fail(IPEvent.error);
                return;
            }

            if (active && _tx_head)
            {
                sop.page = _tx_head;
                _tx_head = sop.page.next;
                if (!_tx_head)
                    _tx_tail = null;
                sop.page.next = null;
                if (post_send(sop))
                {
                    service_tx();
                    return;
                }

                _tx_bytes -= sop.page.length;
                page_free(sop.page);
                free(sop);
                _send = null;
                fail(IPEvent.error);
                return;
            }

            free(sop);
            _send = null;
            if (active)
                service_tx();
        }
    }
    else
    {
        Socket _socket;
        bool _watched;

        void pump() {}

        bool reclaimable() const
            => true;

        void detach_watch()
        {
            if (_watched)
            {
                g_app.unwatch_io(_socket.handle);
                _watched = false;
            }
        }

        void on_ready(IoReady ready)
        {
            if (_closing)
                return;
            if (_phase == Phase.connecting)
            {
                if (ready & IoReady.error)
                {
                    detach_watch();
                    fail(IPEvent.error);
                    return;
                }
                if (ready & IoReady.writable)
                {
                    _phase = Phase.open;
                    g_app.reactor.modify_fd(_socket.handle, false);
                    _socket.get_peer_name(_remote);
                    if (_keepalive_set)
                        set_keepalive(_socket, _keepalive, _keep_idle, _keep_interval, _keep_count);
                    if (_no_delay_set)
                        _socket.set_socket_option(SocketOption.tcp_no_delay, _no_delay);
                    if (_on_event)
                        _on_event(&this, IPEvent.connected);
                    service_tx();
                }
                return;
            }
            if (ready & IoReady.error)
            {
                detach_watch();
                fail(IPEvent.error);
                return;
            }
            if (ready & IoReady.readable)
                drain_rx();
            if (_closing || _phase != Phase.open)
                return;
            if (ready & IoReady.writable)
            {
                flush_tx();
                if (_closing || _phase != Phase.open)
                    return;
                g_app.reactor.modify_fd(_socket.handle, _tx_head !is null);
                service_tx();
            }
        }

        void drain_rx()
        {
            ubyte[4096] buf = void;
            while (!_closing && _phase == Phase.open)
            {
                size_t got;
                Result r = _socket.recv(buf[], MsgFlags.none, &got);
                if (r.failed)
                {
                    if (r.socket_result == SocketResult.would_block)
                        return;
                    // a genuine peer close (FIN) arrives as a failed ConnectionClosedResult
                    detach_watch();
                    fail(IPEvent.closed);
                    return;
                }
                if (got == 0)
                    return;     // would-block reported as success+0
                if (_on_recv)
                    _on_recv(&this, buf[0 .. got], getTime());
            }
        }

        void flush_tx()
        {
            while (_tx_head)
            {
                const(void)[] data = _tx_head.data;
                size_t sent;
                Result r = _socket.send(MsgFlags.none, &sent, data);
                if (r.failed && r.socket_result != SocketResult.would_block)
                {
                    detach_watch();
                    fail(IPEvent.error);
                    return;
                }
                if (sent == 0)
                    return;
                consume_tx(sent);
            }
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
    else version (Windows)
    {
        void close()
        {
            if (_closing)
                return;
            _closing = true;
            if (_handle != INVALID_SOCKET)
            {
                CancelIoEx(cast(HANDLE)_handle, null);
                ws_closesocket(_handle);
                _handle = INVALID_SOCKET;
            }
        }
    }
    else
    {
        void close()
        {
            if (_closing)
                return;
            _closing = true;
            if (_watched)
            {
                g_app.unwatch_io(_socket.handle);
                _watched = false;
            }
            if (_socket)
            {
                _socket.close();
                _socket = null;
            }
        }
    }

private:
    bool _closing;
    InetAddress _local;
    TCPAcceptHandler _on_accept;

    version (UseInternalIPStack)
    {
        TcpPcb* _lpcb;

        bool reclaimable() const
            => true;

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
    else version (Windows)
    {
        struct AcceptOp
        {
            IoOp io;
            IOCP_SOCKET child = INVALID_SOCKET;
            ubyte[(sockaddr_in.sizeof + 16) * 2] addrs;
        }

        IOCP_SOCKET _handle = INVALID_SOCKET;
        int  _outstanding;
        AcceptOp _accept;

        bool reclaimable() const
            => _outstanding == 0;

        bool post_accept()
        {
            if (_closing || g_accept_ex is null)
                return false;
            IOCP_SOCKET child = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
            if (child == INVALID_SOCKET)
                return false;
            enum uint addr_len = cast(uint)sockaddr_in.sizeof + 16;
            _accept.io.ov = OVERLAPPED.init;
            _accept.io.on_complete = &accept_complete;
            _accept.child = child;
            uint received;
            ++_outstanding;
            if (!g_accept_ex(_handle, child, _accept.addrs.ptr, 0, addr_len, addr_len, &received, &_accept.io.ov) &&
                ws_lasterror() != WSA_IO_PENDING)
            {
                --_outstanding;
                ws_closesocket(child);
                _accept.child = INVALID_SOCKET;
                return false;
            }
            return true;
        }

        void accept_complete(IoOp*, bool ok, uint, uint)
        {
            --_outstanding;
            IOCP_SOCKET child = _accept.child;
            _accept.child = INVALID_SOCKET;
            if (_closing)
            {
                if (child != INVALID_SOCKET)
                    ws_closesocket(child);
                return;
            }
            if (!ok)
            {
                if (child != INVALID_SOCKET)
                    ws_closesocket(child);
                post_accept();
                return;
            }
            ws_setsockopt(child, SOL_SOCKET_, SO_UPDATE_ACCEPT_CONTEXT, cast(void*)&_handle, cast(int)IOCP_SOCKET.sizeof);
            sockaddr_in ra;
            int ralen = cast(int)sockaddr_in.sizeof;
            ws_getpeername(child, &ra, &ralen);
            if (!g_app.reactor.associate(cast(HANDLE)child))
            {
                ws_closesocket(child);
                post_accept();
                return;
            }
            TCPConnection* c = register_tcp_conn(child, from_sockaddr_in(ra));
            c._phase = TCPConnection.Phase.open;
            if (!c.post_recv())
            {
                c.close();
                post_accept();
                return;
            }
            if (_on_accept)
                _on_accept(&this, c, getTime());
            else
                c.close();
            if (!post_accept() && _on_accept)
                _on_accept(&this, null, getTime());
        }
    }
    else
    {
        Socket _socket;
        bool _watched;

        bool reclaimable() const
            => true;

        void on_ready(IoReady ready)
        {
            if (_closing)
                return;
            if (ready & IoReady.error)
            {
                if (_watched)
                {
                    g_app.unwatch_io(_socket.handle);
                    _watched = false;
                }
                if (_on_accept)
                    _on_accept(&this, null, getTime());
                return;
            }
            if ((ready & IoReady.readable) == 0)
                return;
            foreach (_; 0 .. 16)
            {
                Socket child;
                InetAddress remote;
                Result r = _socket.accept(child, &remote);
                if (r.failed)
                    return;     // would-block or transient
                child.set_socket_option(SocketOption.non_blocking, true);

                TCPConnection* c = register_tcp_conn(child, remote);
                c._phase = TCPConnection.Phase.open;
                // watch before on_accept so a close() from the handler is ordered after
                if (!g_app.reactor.watch_fd(child.handle, false, &c.on_ready))
                {
                    c.close();
                    continue;
                }
                c._watched = true;
                if (_on_accept)
                    _on_accept(&this, c, getTime());
                else
                    c.close();
            }
        }
    }
}


struct IPUDPState
{
nothrow @nogc:
    bool open(UDPEndpoint* owner, const(InetAddress)* local, const(InetAddress)* remote)
    {
        version (UseInternalIPStack)
        {
            AddressFamily family = AddressFamily.ipv4;
            if (local)
                family = local.family;
            else if (remote)
                family = remote.family;
            if (family != AddressFamily.ipv4 && (!has_ipv6 || family != AddressFamily.ipv6))
                return false;
            if ((local && local.family != family) || (remote && remote.family != family))
                return false;

            UdpPcb* pcb = alloc!UdpPcb();
            pcb.family = family;
            pcb.local_port = local ? local.port : 0;
            if (pcb.local_port == 0)
                pcb.local_port = allocate_udp_port();
            bool available;
            if (family == AddressFamily.ipv4)
            {
                if (local)
                    pcb.local_addr = local._a.ipv4.addr;
                available = udp_bind_available(pcb, pcb.local_addr, pcb.local_port);
            }
            else static if (has_ipv6)
            {
                if (local)
                    pcb.local_addr6 = local._a.ipv6.addr;
                available = udp_bind_available(pcb, pcb.local_addr6, pcb.local_port);
            }
            if (!available)
            {
                free(pcb);
                return false;
            }
            if (remote)
            {
                if (family == AddressFamily.ipv4)
                    pcb.remote_addr = remote._a.ipv4.addr;
                else static if (has_ipv6)
                    pcb.remote_addr6 = remote._a.ipv6.addr;
                pcb.remote_port = remote.port;
                pcb.connected = true;
            }
            _owner = owner;
            pcb.owner = &this;
            _pcb = pcb;
            udp_register(pcb);
            return true;
        }
        else version (Windows)
        {
            if (local && local.family != AddressFamily.ipv4)
                return false;
            if (remote && remote.family != AddressFamily.ipv4)
                return false;
            IOCP_SOCKET socket = ws_socket(WSA_AF_INET, WSA_SOCK_DGRAM, WSA_IPPROTO_UDP, null, 0, WSA_FLAG_OVERLAPPED);
            if (socket == INVALID_SOCKET)
                return false;
            int receive_info = 1;
            if (g_recv_msg is null || ws_setsockopt(socket, WSA_IPPROTO_IP, WSA_IP_PKTINFO, &receive_info, int.sizeof) != 0)
            {
                ws_closesocket(socket);
                return false;
            }
            sockaddr_in address;
            address.sin_family = cast(short)WSA_AF_INET;
            if (local)
                address = to_sockaddr_in(*local);
            if (ws_bind(socket, &address, cast(int)sockaddr_in.sizeof) != 0)
            {
                ws_closesocket(socket);
                return false;
            }
            if (remote)
            {
                sockaddr_in peer = to_sockaddr_in(*remote);
                if (ws_connect(socket, &peer, cast(int)sockaddr_in.sizeof) != 0)
                {
                    ws_closesocket(socket);
                    return false;
                }
            }
            sockaddr_in bound;
            int bound_length = sockaddr_in.sizeof;
            if (ws_getsockname(socket, &bound, &bound_length) != 0)
            {
                ws_closesocket(socket);
                return false;
            }
            _owner = owner;
            _handle = socket;
            _local = from_sockaddr_in(bound);
            if (!g_app.reactor.associate(cast(HANDLE)socket) || !post_recv())
            {
                ws_closesocket(socket);
                _handle = INVALID_SOCKET;
                return false;
            }
            return true;
        }
        else
        {
            if ((local && local.family != AddressFamily.ipv4 && local.family != AddressFamily.ipv6) || (remote && remote.family != AddressFamily.ipv4 && remote.family != AddressFamily.ipv6))
                return false;
            AddressFamily family = AddressFamily.ipv4;
            if (local && (local.family == AddressFamily.ipv4 || local.family == AddressFamily.ipv6))
                family = local.family;
            else if (remote && (remote.family == AddressFamily.ipv4 || remote.family == AddressFamily.ipv6))
                family = remote.family;

            Socket socket;
            if (create_socket(family, SocketType.datagram, Protocol.udp, socket).failed)
                return false;
            socket.set_socket_option(SocketOption.non_blocking, true);
            version (linux)
            {
                SocketOption receive_info = family == AddressFamily.ipv6 ? SocketOption.ipv6_pktinfo : SocketOption.ip_pktinfo;
                if (socket.set_socket_option(receive_info, true).failed)
                {
                    socket.close();
                    return false;
                }
            }
            if (family == AddressFamily.ipv6)
            {
                enum int IPPROTO_IPV6_ = 41;
                version (linux)
                    enum int IPV6_V6ONLY_ = 26;
                else
                    enum int IPV6_V6ONLY_ = 27;
                int yes = 1;
                if (os_setsockopt(socket.handle, IPPROTO_IPV6_, IPV6_V6ONLY_, &yes, cast(uint)yes.sizeof) != 0)
                {
                    socket.close();
                    return false;
                }
            }
            InetAddress bind_address = local ? *local : (family == AddressFamily.ipv6 ? InetAddress(IPv6Addr.any, 0) : InetAddress(IPAddr.any, 0));
            if (socket.bind(bind_address).failed)
            {
                socket.close();
                return false;
            }
            if (remote && socket.connect(*remote).failed)
            {
                socket.close();
                return false;
            }
            if (socket.get_socket_name(_local).failed)
            {
                socket.close();
                return false;
            }

            _owner = owner;
            _socket = socket;
            if (!g_app.reactor.watch_fd(socket.handle, false, &on_ready))
            {
                socket.close();
                _socket = null;
                return false;
            }
            _watched = true;
            return true;
        }
    }

    InetAddress local_address()
    {
        version (UseInternalIPStack)
        {
            if (!_pcb)
                return InetAddress();
            static if (has_ipv6)
            {
                if (_pcb.family == AddressFamily.ipv6)
                    return InetAddress(_pcb.local_addr6, _pcb.local_port);
            }
            return InetAddress(_pcb.local_addr, _pcb.local_port);
        }
        else version (Windows)
            return _local;
        else
            return _local;
    }

    BaseInterface egress_iface(InetAddress remote)
    {
        version (UseInternalIPStack)
        {
            if (_stack_ptr && remote.family == AddressFamily.ipv4)
            {
                RouteResult route = _stack_ptr.route_lookup_v4_dst(v4_addr(remote));
                if (route.kind == RouteResult.Kind.forward)
                    return route.out_iface;
            }
            static if (has_ipv6)
            {
                if (_stack_ptr && remote.family == AddressFamily.ipv6)
                {
                    RouteResult6 route = _stack_ptr.route_lookup_v6_dst(remote._a.ipv6.addr, _pcb.outbound_iface6.get);
                    if (route.kind == RouteResult6.Kind.forward)
                        return route.out_iface;
                }
            }
        }
        return null;
    }

    bool join(IPAddr group, IPAddr interface_ = IPAddr.any)
    {
        if (!group.is_multicast)
            return false;
        version (UseInternalIPStack)
        {
            IPAddr selected = interface_;
            if (selected == IPAddr.any)
                selected = _pcb.local_addr != IPAddr.any ? _pcb.local_addr : _stack_ptr.select_source_v4(group);
            if (!selected)
                return false;
            if (_pcb.multicast_group && _pcb.multicast_group != group)
                return false;
            foreach (joined; _pcb.multicast_interfaces[])
            {
                if (joined == selected)
                    return outbound_interface(selected);
            }
            if (!outbound_interface(selected))
                return false;
            if (!igmp_join(*_stack_ptr, group, selected))
                return false;
            _pcb.multicast_group = group;
            _pcb.multicast_interfaces ~= selected;
            return true;
        }
        else version (Windows)
        {
            IPv4Membership membership = IPv4Membership(group.address, interface_.address);
            if (ws_setsockopt(_handle, WSA_IPPROTO_IP, WSA_IP_MULTICAST_IF, &interface_.address, cast(int)interface_.address.sizeof) != 0)
                return false;
            if (ws_setsockopt(_handle, WSA_IPPROTO_IP, WSA_IP_ADD_MEMBERSHIP, &membership, cast(int)membership.sizeof) != 0)
                return false;
            return true;
        }
        else
        {
            MulticastGroup membership = MulticastGroup(group, interface_);
            if (os_setsockopt(_socket.handle, IPPROTO_IP, IP_MULTICAST_IF, &interface_.address, cast(uint)interface_.address.sizeof) != 0)
                return false;
            if (_socket.set_socket_option(SocketOption.multicast, membership).failed)
                return false;
            return true;
        }
    }

    static if (has_ipv6)
    {
        bool join(IPv6Addr group, BaseInterface iface)
        {
            if (!group.is_multicast || !iface)
                return false;
            version (UseInternalIPStack)
            {
                if (udp_joined(_pcb, group, iface))
                    return true;
                if (!mld_join(*_stack_ptr, group, iface))
                    return false;
                _pcb.groups6 ~= UdpGroup6(group, ObjectRef!BaseInterface(iface));
                if (!_pcb.outbound_iface6)
                    _pcb.outbound_iface6 = iface;
                return true;
            }
            else version (linux)
            {
                if (!_socket || iface.kernel_ifindex == 0)
                    return false;
                struct ipv6_mreq
                {
                    ubyte[16] address;
                    uint ifindex;
                }
                ipv6_mreq membership;
                foreach (i, word; group.s)
                {
                    membership.address[i * 2] = cast(ubyte)(word >> 8);
                    membership.address[i * 2 + 1] = cast(ubyte)word;
                }
                membership.ifindex = cast(uint)iface.kernel_ifindex;
                enum int IPPROTO_IPV6_ = 41, IPV6_ADD_MEMBERSHIP_ = 20;
                return os_setsockopt(_socket.handle, IPPROTO_IPV6_, IPV6_ADD_MEMBERSHIP_, &membership, cast(uint)membership.sizeof) == 0;
            }
            else
                return false;
        }

        bool outbound_interface(BaseInterface iface)
        {
            if (!iface)
                return false;
            version (UseInternalIPStack)
            {
                _pcb.outbound_iface6 = iface;
                return true;
            }
            else version (linux)
            {
                if (!_socket || iface.kernel_ifindex == 0)
                    return false;
                uint index = cast(uint)iface.kernel_ifindex;
                enum int IPPROTO_IPV6_ = 41, IPV6_MULTICAST_IF_ = 17;
                return os_setsockopt(_socket.handle, IPPROTO_IPV6_, IPV6_MULTICAST_IF_, &index, cast(uint)index.sizeof) == 0;
            }
            else
                return false;
        }
    }

    bool outbound_interface(IPAddr interface_)
    {
        if (interface_ == IPAddr.any)
            return false;
        version (UseInternalIPStack)
        {
            if (!interface_for_address(interface_))
                return false;
            _pcb.outbound_interface = interface_;
            return true;
        }
        else
        {
            uint address = interface_.address;
            version (Windows)
                return ws_setsockopt(_handle, WSA_IPPROTO_IP, WSA_IP_MULTICAST_IF, &address, cast(int)address.sizeof) == 0;
            else
                return os_setsockopt(_socket.handle, IPPROTO_IP, IP_MULTICAST_IF, &address, cast(uint)address.sizeof) == 0;
        }
    }

    bool enable_broadcast()
    {
        version (UseInternalIPStack)
            return true;
        else version (Windows)
        {
            int yes = 1;
            return ws_setsockopt(_handle, SOL_SOCKET_, SO_BROADCAST_, &yes, cast(int)yes.sizeof) == 0;
        }
        else
        {
            int yes = 1;
            return os_setsockopt(_socket.handle, SOL_SOCKET, SO_BROADCAST, &yes, cast(uint)yes.sizeof) == 0;
        }
    }

    ptrdiff_t sendto(scope const(void)[] data, InetAddress dst)
    {
        version (UseInternalIPStack)
        {
            static if (has_ipv6)
            {
                if (dst.family == AddressFamily.ipv6)
                {
                    BaseInterface iface = _pcb.outbound_iface6.get;
                    if (!iface && dst._a.ipv6.scopeId)
                        iface = interface_for_kernel_index(cast(int)dst._a.ipv6.scopeId);
                    if (!udp_output6(*_stack_ptr, _pcb.local_addr6, _pcb.local_port, dst._a.ipv6.addr, dst.port, iface, cast(const(ubyte)[])data))
                        return 0;
                    return data.length;
                }
            }
            IPAddr remote = v4_addr(dst);
            IPAddr local = remote.is_multicast && _pcb.outbound_interface ? _pcb.outbound_interface : _pcb.local_addr;
            if (!udp_output(*_stack_ptr, local, _pcb.local_port, remote, port_of(dst), cast(const(ubyte)[])data))
                return 0;
            return data.length;
        }
        else version (Windows)
        {
            if (_handle == INVALID_SOCKET || data.length == 0)
                return 0;
            sockaddr_in to = to_sockaddr_in(dst);
            int sent = ws_sendto(_handle, data.ptr, cast(int)data.length, 0, &to, cast(int)sockaddr_in.sizeof);
            return sent > 0 ? sent : 0;
        }
        else
        {
            size_t sent;
            if (_socket.sendto(&dst, &sent, data).failed)
                return 0;
            return sent;
        }
    }

    void close()
    {
        _closing = true;
        version (UseInternalIPStack)
        {
            if (_pcb)
                _pcb.owner = null;
        }
        else version (Windows)
        {
            if (_handle != INVALID_SOCKET)
            {
                CancelIoEx(cast(HANDLE)_handle, null);
                ws_closesocket(_handle);
                _handle = INVALID_SOCKET;
            }
        }
        else
        {
            if (_watched)
            {
                g_app.unwatch_io(_socket.handle);
                _watched = false;
            }
            if (_socket)
            {
                _socket.close();
                _socket = null;
            }
        }
    }

    bool reclaimable() const
        => backend_reclaimable();

    void release()
        => backend_release();

private:
    bool _closing;
    UDPEndpoint* _owner;

    version (UseInternalIPStack)
    {
        UdpPcb* _pcb;

        bool backend_reclaimable() const
            => true;

        void backend_release()
        {
            if (_pcb)
            {
                foreach (local; _pcb.multicast_interfaces[])
                    igmp_leave(*_stack_ptr, _pcb.multicast_group, local);
                static if (has_ipv6)
                {
                    foreach (ref membership; _pcb.groups6[])
                        if (BaseInterface iface = membership.iface.get)
                            mld_leave(*_stack_ptr, membership.group, iface);
                }
                udp_unregister(_pcb);
                foreach (ref dgm; _pcb.recv_queue[])
                    udp_free_datagram_data(dgm);
                free(_pcb);
                _pcb = null;
            }
        }

        package(protocol.ip) void deliver(ref InetAddress src, ref InetAddress dst, BaseInterface ingress, const(ubyte)[] data, MonoTime rx_time)
        {
            UDPReceiveInfo info;
            info.source = src;
            info.destination = dst;
            info.rx_time = rx_time;
            info.ingress = ingress;
            udp_deliver(_owner, data, info);
        }
    }
    else version (Windows)
    {
        struct RecvFromOp
        {
            IoOp io;
            sockaddr_in from;
            WSABUF buffer;
            WSAMSG message;
            ubyte[64] control;
            ubyte[64 * 1024] buf;
        }

        IOCP_SOCKET _handle = INVALID_SOCKET;
        InetAddress _local;
        int  _outstanding;
        RecvFromOp _recv;

        void backend_release() {}

        bool backend_reclaimable() const
            => _outstanding == 0;

        bool post_recv()
        {
            _recv.io.ov = OVERLAPPED.init;
            _recv.io.on_complete = &recv_complete;
            _recv.buffer = WSABUF(uint(_recv.buf.length), _recv.buf.ptr);
            _recv.message.name = &_recv.from;
            _recv.message.namelen = sockaddr_in.sizeof;
            _recv.message.lpBuffers = &_recv.buffer;
            _recv.message.dwBufferCount = 1;
            _recv.message.Control = WSABUF(uint(_recv.control.length), _recv.control.ptr);
            _recv.message.dwFlags = 0;
            uint recvd;
            ++_outstanding;
            if (g_recv_msg(_handle, &_recv.message, &recvd, &_recv.io.ov, null) != 0 && ws_lasterror() != WSA_IO_PENDING)
            {
                --_outstanding;
                return false;
            }
            return true;
        }

        void recv_complete(IoOp*, bool ok, uint bytes, uint)
        {
            --_outstanding;
            if (_closing)
                return;
            if (ok && bytes > 0)
            {
                uint interface_index;
                InetAddress destination = _local;
                if (_recv.message.Control.len >= control_data_offset + IN_PKTINFO.sizeof)
                {
                    WSACMSGHDR* header = cast(WSACMSGHDR*)_recv.message.Control.buf;
                    if (header.length >= control_data_offset + IN_PKTINFO.sizeof && header.level == WSA_IPPROTO_IP && header.type == WSA_IP_PKTINFO)
                    {
                        IN_PKTINFO* packet_info = cast(IN_PKTINFO*)(_recv.message.Control.buf + control_data_offset);
                        destination._a.ipv4.addr.address = packet_info.address;
                        interface_index = packet_info.interface_index;
                    }
                }
                UDPReceiveInfo info;
                info.source = from_sockaddr_in(_recv.from);
                info.destination = destination;
                info.rx_time = getTime();
                info.ingress = interface_for_kernel_index(int(interface_index));
                udp_deliver(_owner, _recv.buf[0 .. bytes], info);
            }
            if (!_closing)
                post_recv();    // transient errors / empty datagrams: keep the socket armed
        }
    }
    else
    {
        Socket _socket;
        InetAddress _local;
        bool _watched;

        void backend_release() {}

        bool backend_reclaimable() const
            => true;

        void on_ready(IoReady ready)
        {
            if (_closing)
                return;
            while (!_closing)
            {
                size_t got;
                InetAddress from;
                InetAddress destination = _local;
                uint interface_index;
                version (linux)
                    Result r = _socket.recvfrom(_udp_scratch[], MsgFlags.none, &from, &got, &destination, &interface_index);
                else
                    Result r = _socket.recvfrom(_udp_scratch[], MsgFlags.none, &from, &got);
                if (r.failed || got == 0)
                    return;     // would-block, or a transient error udp just shrugs off
                if (destination.family == AddressFamily.unspecified)
                    destination = _local;
                else
                    destination.port = _local.port;
                UDPReceiveInfo info;
                info.source = from;
                info.destination = destination;
                info.rx_time = getTime();
                version (linux)
                    info.ingress = interface_for_kernel_index(int(interface_index));
                else if (destination.family == AddressFamily.ipv4)
                    info.ingress = interface_for_address(v4_addr(destination));
                udp_deliver(_owner, _udp_scratch[0 .. got], info);
            }
        }
    }
}


class IPModule : Module
{
    mixin DeclareModule!"protocol.ip";
nothrow @nogc:

    version (UseInternalIPStack)
    static if (has_ipv6)
    ref IPStack stack() return
        => _stack;

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
        g_app.console.register_collection!IPRoute();
        static if (has_ipv6)
        {
            g_app.console.register_collection!IPv6Address();
            g_app.console.register_collection!IPv6Pool();
            g_app.console.register_collection!IPv6Route();
        }
        g_app.console.register_collection!TCPStream();
        g_app.console.register_collection!TCPServer();

        version (KernelMirror)
        {
            import protocol.ip.linux_mirror : mirror_init;
            mirror_init();
        }

        version (UseInternalIPStack)
        {
            static if (has_ipv6)
            {
                import protocol.ip.ra : RAService;
                g_app.console.register_collection!RAService();
            }

            _stack.init_resolvers();

            register_frame_handler(PacketType.ethernet, &_stack.on_packet);
            // TODO: register additional frame handlers when other L3 carriers land
            //       (PacketType._6lowpan, ppp/IPCP frame type, raw_ip tunnels).

            set_ether_tcp_input(&ether_tcp_input);

            import protocol.ip.tcp : tcp_print;
            g_app.console.register_command!(tcp_print, "print")("/protocol/ip/tcp", this);
            g_app.console.register_command!(neighbour_v4_print, "print")("/protocol/ip/neighbour", this);
            static if (has_ipv6)
            {
                g_app.console.register_command!(neighbour_v6_print, "print")("/protocol/ip/neighbour6", this);
                g_app.console.register_command!(ping6, "ping6")("/protocol/ip", this);
            }
        }
        else version (Windows)
            load_socket_extensions();
    }

    override void deinit()
    {
        version (UseInternalIPStack) {} else
        {
            // close whatever the owners left behind; the pump sweep won't run again, so free
            // what's immediately reclaimable and let cancelled in-flight ops leak at exit
            foreach (c; _tcp_conns[])
                c.close();
            foreach (l; _tcp_listeners[])
                l.close();
            pump_ip_endpoints();
        }
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

    version (UseInternalIPStack)
    static if (has_ipv6)
    void neighbour_v6_print(Session session)
    {
        import urt.mem.temp : tconcat;
        import manager.console.table : Table;
        import router.iface.mac : MACAddress;

        auto entries = _stack.neighbour_v6_cache.entries;
        if (entries.length == 0)
        {
            session.write_line("No IPv6 neighbour entries");
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

    version (UseInternalIPStack)
    static if (has_ipv6)
    {
        Ping6State ping6(Session session, IPv6Addr address, Nullable!uint count, Nullable!BaseInterface iface)
        {
            BaseInterface scope_iface = iface ? iface.value : null;
            if (address == IPv6Addr.any)
            {
                session.write_line("ping6 requires a destination address");
                return null;
            }
            if ((address.is_link_local || address.is_multicast) && !scope_iface)
            {
                session.write_line("scoped destinations need iface=<interface>");
                return null;
            }
            return g_app.allocator.allocT!Ping6State(&_stack, session, address, count ? count.value : 4, scope_iface);
        }

        static class Ping6State : CommandState
        {
        nothrow @nogc:

            CommandCompletionState state = CommandCompletionState.in_progress;

            this(IPStack* stack, Session session, IPv6Addr dst, uint count, BaseInterface iface)
            {
                super(session, null);
                this.stack = stack;
                this.dst = dst;
                this.iface = iface;
                this.count = count ? count : 1;
                send_round();
            }

            override CommandCompletionState update()
            {
                import protocol.ip.icmp6 : icmp6_echo_cancel;

                if (state == CommandCompletionState.cancel_requested)
                {
                    icmp6_echo_cancel(seq);
                    state = CommandCompletionState.cancelled;
                    return state;
                }
                if (getTime() - last_send >= 1.seconds)
                {
                    icmp6_echo_cancel(seq);
                    if (sent >= count)
                    {
                        session.write_line(replies, " replies for ", sent, " requests");
                        state = CommandCompletionState.finished;
                    }
                    else
                        send_round();
                }
                return state;
            }

            override void request_cancel()
            {
                if (state == CommandCompletionState.in_progress)
                    state = CommandCompletionState.cancel_requested;
            }

        private:
            IPStack* stack;
            IPv6Addr dst;
            BaseInterface iface;
            MonoTime last_send;
            uint count;
            uint sent;
            uint replies;
            ushort seq;

            void send_round()
            {
                import protocol.ip.icmp6 : icmp6_echo_send;

                ++sent;
                last_send = getTime();
                seq = icmp6_echo_send(*stack, dst, iface, &on_reply);
                if (seq == 0)
                    session.write_line("no source address or route for ", dst);
            }

            void on_reply(IPv6Addr from, Duration rtt)
            {
                ++replies;
                session.write_line("reply from ", from, ": time=", rtt);
            }
        }
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
                    iface = e;
                    break;
                }
            }
            if (!iface)
            {
                foreach (w; Collection!WindowsWlan().values)
                {
                    auto r = dyn_cast!WindowsWifiRadio(w.radio);
                    if (r && parse_npf_guid(r.adapter) == guid)
                    {
                        iface = w;
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
        Collection!IPRoute().update_all();
        static if (has_ipv6)
        {
            Collection!IPv6Address().update_all();
            Collection!IPv6Pool().update_all();
            Collection!IPv6Route().update_all();
        }
        Collection!TCPServer().update_all();

        version (UseInternalIPStack)
        {
            static if (has_ipv6)
            {
                import protocol.ip.ra : RAService;
                Collection!RAService().update_all();
            }
            _stack.update();
        }

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


bool tcp_conn_registered(TCPConnection* c)
{
    foreach (conn; _tcp_conns[])
        if (conn is c)
            return true;
    return false;
}

void unregister_tcp_conn(TCPConnection* c)
{
    for (size_t i = _tcp_conns.length; i-- > 0; )
    {
        if (_tcp_conns[i] is c)
        {
            _tcp_conns.removeSwapLast(i);
            return;
        }
    }
}

version (UseInternalIPStack) {} else version (Windows) {} else
    __gshared ubyte[64 * 1024] _udp_scratch;    // datagram drain buffer; main thread only

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

    // closed endpoints are freed here once nothing references them (on windows that means their
    // cancelled overlapped ops have all delivered; elsewhere close is immediately reclaimable)
    for (size_t i = _tcp_conns.length; i-- > 0; )
    {
        if (_tcp_conns[i]._closing && _tcp_conns[i].reclaimable)
        {
            free(_tcp_conns[i]);
            _tcp_conns.removeSwapLast(i);
        }
    }
    for (size_t i = _tcp_listeners.length; i-- > 0; )
    {
        if (_tcp_listeners[i]._closing && _tcp_listeners[i].reclaimable)
        {
            free(_tcp_listeners[i]);
            _tcp_listeners.removeSwapLast(i);
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
        TCPConnection* c = alloc!TCPConnection();
        c._pcb = pcb;
        c._phase = TCPConnection.Phase.open;
        c._remote = pcb.remote;
        pcb.conn_owner = c;
        _tcp_conns ~= c;
        return c;
    }

    void ether_tcp_input(MACAddress src, MACAddress dst, const(void)[] segment, MonoTime rx_time)
    {
        import protocol.ip.tcp : tcp_segment_input;
        if (_stack_ptr)
            tcp_segment_input(*_stack_ptr, InetAddress(src.b, 0), InetAddress(dst.b, 0), cast(const(ubyte)[])segment, rx_time);
    }
}
else version (Windows)
{
    // direct Winsock bindings; endpoints drive their own overlapped I/O and hand completions to
    // the reactor's IO completion port (see manager.reactor), rather than going via urt.socket
    import urt.internal.sys.windows.basetsd : HANDLE;
    import urt.internal.sys.windows.winbase : OVERLAPPED, CancelIoEx;

    alias IOCP_SOCKET = size_t;
    struct WSABUF { uint len; ubyte* buf; }     // ULONG len; CHAR* buf
    struct WSAMSG
    {
        void* name;
        int namelen;
        WSABUF* lpBuffers;
        uint dwBufferCount;
        WSABUF Control;
        uint dwFlags;
    }
    struct WSACMSGHDR
    {
        size_t length;
        int level;
        int type;
    }
    struct IN_PKTINFO
    {
        uint address;
        uint interface_index;
    }
    struct IOCP_GUID { uint Data1; ushort Data2, Data3; ubyte[8] Data4; }
    struct IPv4Membership { uint group; uint interface_; }

    extern (Windows) int WSARecv (IOCP_SOCKET, WSABUF*, uint, uint*, uint*, OVERLAPPED*, void*) nothrow @nogc;
    extern (Windows) int WSASend (IOCP_SOCKET, WSABUF*, uint, uint*, uint,  OVERLAPPED*, void*) nothrow @nogc;
    extern (Windows) int WSAIoctl(IOCP_SOCKET, uint, void*, uint, void*, uint, uint*, OVERLAPPED*, void*) nothrow @nogc;

    alias LPFN_CONNECTEX = extern(Windows) int function(IOCP_SOCKET, const(void)*, int, const(void)*, uint, uint*, OVERLAPPED*) nothrow @nogc;
    alias LPFN_ACCEPTEX  = extern(Windows) int function(IOCP_SOCKET, IOCP_SOCKET, void*, uint, uint, uint, uint*, OVERLAPPED*) nothrow @nogc;
    alias LPFN_RECVMSG   = extern(Windows) int function(IOCP_SOCKET, WSAMSG*, uint*, OVERLAPPED*, void*) nothrow @nogc;

    enum uint SIO_GET_EXTENSION_FUNCTION_POINTER = 0xC8000006;
    enum int  SO_UPDATE_CONNECT_CONTEXT = 0x7010;
    enum int  SO_UPDATE_ACCEPT_CONTEXT  = 0x700B;

    __gshared immutable IOCP_GUID WSAID_CONNECTEX = IOCP_GUID(0x25a207b9, 0xddf3, 0x4660, [0x8e,0xe9,0x76,0xe5,0x8c,0x74,0x06,0x3e]);
    __gshared immutable IOCP_GUID WSAID_ACCEPTEX  = IOCP_GUID(0xb5367df1, 0xcbac, 0x11cf, [0x95,0xca,0x00,0x80,0x5f,0x48,0xa1,0x92]);
    __gshared immutable IOCP_GUID WSAID_RECVMSG  = IOCP_GUID(0xf689d7c8, 0x6f1f, 0x436b, [0x8a,0x53,0xe5,0x4f,0xe3,0x51,0xc3,0x22]);

    enum IOCP_SOCKET INVALID_SOCKET = ~IOCP_SOCKET(0);
    enum int WSA_AF_INET = 2, WSA_SOCK_STREAM = 1, WSA_SOCK_DGRAM = 2;
    enum int WSA_IPPROTO_IP = 0, WSA_IPPROTO_TCP = 6, WSA_IPPROTO_UDP = 17;
    enum int WSA_IP_MULTICAST_IF = 9, WSA_IP_ADD_MEMBERSHIP = 12, WSA_IP_PKTINFO = 19;
    enum int SOL_SOCKET_ = 0xffff, SO_REUSEADDR_ = 0x0004, SO_BROADCAST_ = 0x0020, SO_ERROR_ = 0x1007;
    enum size_t control_data_offset = (WSACMSGHDR.sizeof + size_t.alignof - 1) & ~(size_t.alignof - 1);

    // raw winsock; pragma(mangle) keeps the common names from clashing with urt.socket's exports
    enum uint WSA_FLAG_OVERLAPPED = 0x01;
    pragma(mangle, "WSASocketW")  extern(Windows) IOCP_SOCKET ws_socket(int af, int type, int protocol, void* protoInfo, uint group, uint flags) nothrow @nogc;
    pragma(mangle, "bind")        extern(Windows) int ws_bind(IOCP_SOCKET, const(void)*, int) nothrow @nogc;
    pragma(mangle, "connect")     extern(Windows) int ws_connect(IOCP_SOCKET, const(void)*, int) nothrow @nogc;
    pragma(mangle, "listen")      extern(Windows) int ws_listen(IOCP_SOCKET, int) nothrow @nogc;
    pragma(mangle, "closesocket") extern(Windows) int ws_closesocket(IOCP_SOCKET) nothrow @nogc;
    pragma(mangle, "shutdown")    extern(Windows) int ws_shutdown(IOCP_SOCKET, int) nothrow @nogc;
    pragma(mangle, "WSAGetLastError") extern(Windows) int ws_lasterror() nothrow @nogc;
    pragma(mangle, "setsockopt")  extern(Windows) int ws_setsockopt(IOCP_SOCKET, int, int, const(void)*, int) nothrow @nogc;
    pragma(mangle, "getsockopt")  extern(Windows) int ws_getsockopt(IOCP_SOCKET, int, int, void*, int*) nothrow @nogc;
    enum int WSA_IO_PENDING = 997;

    pragma(mangle, "getpeername") extern(Windows) int ws_getpeername(IOCP_SOCKET, void*, int*) nothrow @nogc;
    pragma(mangle, "getsockname") extern(Windows) int ws_getsockname(IOCP_SOCKET, void*, int*) nothrow @nogc;
    pragma(mangle, "sendto")      extern(Windows) int ws_sendto(IOCP_SOCKET, const(void)*, int, int, const(void)*, int) nothrow @nogc;
    __gshared LPFN_CONNECTEX g_connect_ex;
    __gshared LPFN_ACCEPTEX  g_accept_ex;
    __gshared LPFN_RECVMSG   g_recv_msg;

    // build a v4 sockaddr_in from an InetAddress (IOCP TCP/UDP is v4-only for now)
    sockaddr_in to_sockaddr_in(ref const InetAddress a) nothrow @nogc
    {
        sockaddr_in sa;
        sa.sin_family = cast(short)WSA_AF_INET;
        storeBigEndian(&sa.sin_port, a._a.ipv4.port);
        sa.sin_addr.s_addr = a._a.ipv4.addr.address;   // octets in memory order == network order
        return sa;
    }

    InetAddress from_sockaddr_in(ref const sockaddr_in sa) nothrow @nogc
    {
        IPAddr ip;
        ip.address = sa.sin_addr.s_addr;
        return InetAddress(ip, loadBigEndian(&sa.sin_port));
    }


    TCPConnection* register_tcp_conn(IOCP_SOCKET s, InetAddress remote)
    {
        TCPConnection* c = alloc!TCPConnection();
        c._handle = s;
        c._remote = remote;
        _tcp_conns ~= c;
        return c;
    }

    void load_socket_extensions()
    {
        IOCP_SOCKET s = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
        if (s == INVALID_SOCKET)
        {
            writeError("IOCPWorker: probe socket for extension fns failed");
            return;
        }
        uint bytes;
        IOCP_GUID cx = WSAID_CONNECTEX;
        WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, cast(void*)&cx, cast(uint)IOCP_GUID.sizeof, cast(void*)&g_connect_ex, cast(uint)g_connect_ex.sizeof, &bytes, null, null);
        IOCP_GUID ax = WSAID_ACCEPTEX;
        WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, cast(void*)&ax, cast(uint)IOCP_GUID.sizeof, cast(void*)&g_accept_ex, cast(uint)g_accept_ex.sizeof, &bytes, null, null);
        ws_closesocket(s);

        s = ws_socket(WSA_AF_INET, WSA_SOCK_DGRAM, WSA_IPPROTO_UDP, null, 0, WSA_FLAG_OVERLAPPED);
        if (s != INVALID_SOCKET)
        {
            IOCP_GUID rx = WSAID_RECVMSG;
            WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, cast(void*)&rx, uint(IOCP_GUID.sizeof), cast(void*)&g_recv_msg, uint(g_recv_msg.sizeof), &bytes, null, null);
            ws_closesocket(s);
        }
        if (g_connect_ex is null || g_accept_ex is null || g_recv_msg is null)
            writeError("IOCPWorker: failed to resolve socket extension functions");
    }

}
else
{
    TCPConnection* register_tcp_conn(Socket s, InetAddress remote)
    {
        TCPConnection* c = alloc!TCPConnection();
        c._socket = s;
        c._remote = remote;
        _tcp_conns ~= c;
        return c;
    }
}
