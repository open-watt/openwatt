module router.transport.udp;

// UDP endpoint layer: family-agnostic datagram endpoints. Ether peers ([mac]:port over the OW
// ethertype) ride the router fabric with no IP configured; ip peers lower onto the internal
// stack when the ip module is present, else onto the OS kernel's sockets.

import urt.array;
import urt.inet;
import urt.mem.allocator : defaultAllocator;
import urt.mem.temp : tconcat;
import urt.socket;
import urt.time;

import manager : g_app;
import manager.console.session : Session;
import manager.console.table : Table;
import manager.reactor;

import router.iface : BaseInterface;
import router.iface.endpoint;
import router.iface.ethernet;
import router.iface.mac;
import router.transport : ip_lowering, os_bsd, os_iocp;

static if (ip_lowering)
{
    import protocol.ip.stack : RouteResult, g_ip_stack;
    import protocol.ip.udp;
}

static if (os_iocp)
    import driver.windows.winsock;

nothrow @nogc:


alias UDPRecvHandler = void delegate(UDPEndpoint* ep, const(void)[] data, ref const InetAddress from, MonoTime rx_time) nothrow @nogc;

// `local` binds a receive address/port (null binds any:ephemeral);
// when `remote` is set, send() targets it and the endpoint only delivers datagrams from that peer
UDPEndpoint* udp_open(const(InetAddress)* local, const(InetAddress)* remote, UDPRecvHandler on_recv, EthernetStation ether_station = null)
{
    if ((local && local.family == AddressFamily.ether) || (remote && remote.family == AddressFamily.ether))
        return udp_open_ether(local, remote, on_recv, ether_station);

    static if (ip_lowering)
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
    else static if (os_iocp)
    {
        if (local && local.family != AddressFamily.ipv4)
            return null;
        if (remote && remote.family != AddressFamily.ipv4)
            return null;
        IOCP_SOCKET s = ws_socket(WSA_AF_INET, WSA_SOCK_DGRAM, WSA_IPPROTO_UDP, null, 0, WSA_FLAG_OVERLAPPED);
        if (s == INVALID_IOCP_SOCKET)
            return null;
        sockaddr_in la;
        la.sin_family = cast(short)WSA_AF_INET;
        if (local)
            la = to_sockaddr_in(*local);
        if (ws_bind(s, &la, cast(int)sockaddr_in.sizeof) != 0)
        {
            ws_closesocket(s);
            return null;
        }
        if (remote)
        {
            sockaddr_in ra = to_sockaddr_in(*remote);
            if (ws_connect(s, &ra, cast(int)sockaddr_in.sizeof) != 0)
            {
                ws_closesocket(s);
                return null;
            }
        }
        UDPEndpoint* ep = defaultAllocator().allocT!UDPEndpoint();
        ep._handle = s;
        ep._on_recv = on_recv;
        if (remote)
        {
            ep._remote = *remote;
            ep._connected = true;
        }
        if (!g_app.reactor.associate(cast(HANDLE)s) || !ep.post_recv())
        {
            ws_closesocket(s);
            defaultAllocator().freeT(ep);
            return null;
        }
        _udp_eps ~= ep;
        return ep;
    }
    else static if (os_bsd)
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

        bool connect_peer = remote && (remote.family == AddressFamily.ipv4 || remote.family == AddressFamily.ipv6);
        if (connect_peer && s.connect(*remote).failed)
        {
            s.close();
            return null;
        }

        UDPEndpoint* ep = defaultAllocator().allocT!UDPEndpoint();
        ep._socket = s;
        ep._on_recv = on_recv;
        if (connect_peer)
        {
            ep._remote = *remote;
            ep._connected = true;
        }
        if (!g_app.reactor.watch_fd(s.handle, false, &ep.on_ready))
        {
            s.close();
            defaultAllocator().freeT(ep);
            return null;
        }
        ep._watched = true;
        _udp_eps ~= ep;
        return ep;
    }
    else
        return null;     // no ip carrier in this build; ether peers only
}

// a null local or the zero mac is a wildcard bind: every segment, egress by learned neighbour;
// an explicit station binds one segment (a mac cannot: a vlan shares its parent's address)
UDPEndpoint* udp_open_ether(const(InetAddress)* local, const(InetAddress)* remote, UDPRecvHandler on_recv, EthernetStation station)
{
    if (local && local.family != AddressFamily.ether)
        return null;
    if (remote && remote.family != AddressFamily.ether)
        return null;

    ushort local_port = local ? local.port : 0;
    if (!station && local && !local.addr_any)
    {
        station = find_ether_station(MACAddress(local._a.ether.addr));
        if (!station)
            return null;
    }

    UDPEndpoint* ep = defaultAllocator().allocT!UDPEndpoint();
    ep._on_recv = on_recv;
    if (remote)
    {
        ep._remote = *remote;
        ep._connected = true;
    }
    ep._ether = ether_open(station, local_port, &ep.on_ether_recv,
                           remote ? MACAddress(remote._a.ether.addr) : MACAddress(),
                           remote ? remote._a.ether.port : 0);
    if (!ep._ether)
    {
        defaultAllocator().freeT(ep);
        return null;
    }
    _udp_eps ~= ep;
    return ep;
}


struct UDPEndpoint
{
nothrow @nogc:
    InetAddress remote() const pure
        => _remote;

    // interface datagrams egress through; null when the endpoint is multi-drop or the OS owns the route
    BaseInterface egress_iface()
    {
        if (_ether)
            return _ether.iface;
        static if (ip_lowering)
        {
            if (g_ip_stack && _remote.family == AddressFamily.ipv4)
            {
                RouteResult r = g_ip_stack.route_lookup_v4_dst(v4_addr(_remote));
                if (r.kind == RouteResult.Kind.forward)
                    return r.out_iface;
            }
        }
        return null;
    }

    InetAddress local()
    {
        if (_ether)
            return InetAddress(_ether.local.b, _ether.local_port);
        static if (ip_lowering)
            return _pcb ? InetAddress(_pcb.local_addr, _pcb.local_port) : InetAddress();
        else static if (os_iocp)
            return InetAddress();   // TODO: getsockname
        else static if (os_bsd)
        {
            InetAddress a;
            if (_socket)
                _socket.get_socket_name(a);
            return a;
        }
        else
            return InetAddress();
    }

    // Send to the connected remote (set at open). Returns bytes sent, or 0.
    ptrdiff_t send(scope const(void)[] data)
    {
        if (_closing || !_connected)
            return 0;
        if (_ether)
            return _ether.send(data);
        static if (ip_lowering)
        {
            if (!udp_output(*g_ip_stack, _pcb.local_addr, _pcb.local_port,
                            v4_addr(_remote), port_of(_remote), cast(const(ubyte)[])data))
                return 0;
            return data.length;
        }
        else static if (os_iocp)
        {
            if (_handle == INVALID_IOCP_SOCKET || data.length == 0)
                return 0;
            sockaddr_in to = to_sockaddr_in(_remote);
            int n = ws_sendto(_handle, data.ptr, cast(int)data.length, 0, &to, cast(int)sockaddr_in.sizeof);
            return n > 0 ? n : 0;
        }
        else static if (os_bsd)
        {
            size_t sent;
            if (_socket.sendto(&_remote, &sent, data).failed)
                return 0;
            return sent;
        }
        else
            return 0;
    }

    ptrdiff_t sendto(scope const(void)[] data, InetAddress to)
    {
        if (_closing)
            return 0;
        if (_connected)
            return to == _remote ? send(data) : 0;   // connected: the peer is the only destination
        if (_ether)
        {
            const(InetAddress.Ether)* e = to.as_ether;
            return e ? _ether.sendto(MACAddress(e.addr), e.port, data) : 0;
        }
        static if (ip_lowering)
        {
            if (!udp_output(*g_ip_stack, _pcb.local_addr, _pcb.local_port,
                            v4_addr(to), port_of(to), cast(const(ubyte)[])data))
                return 0;
            return data.length;
        }
        else static if (os_iocp)
        {
            if (_handle == INVALID_IOCP_SOCKET || data.length == 0)
                return 0;
            sockaddr_in dst = to_sockaddr_in(to);
            int n = ws_sendto(_handle, data.ptr, cast(int)data.length, 0, &dst, cast(int)sockaddr_in.sizeof);
            return n > 0 ? n : 0;
        }
        else static if (os_bsd)
        {
            size_t sent;
            if (_socket.sendto(&to, &sent, data).failed)
                return 0;
            return sent;
        }
        else
            return 0;
    }

    void close()
    {
        if (_closing)
            return;
        _closing = true;
        if (_ether)
        {
            _ether.close();
            _ether = null;
        }
        static if (ip_lowering)
        {
            if (_pcb)
                _pcb.owner = null;     // stop delivery; pcb torn down by release() on sweep
        }
        else static if (os_iocp)
        {
            if (_handle != INVALID_IOCP_SOCKET)
            {
                CancelIoEx(cast(HANDLE)_handle, null);
                ws_closesocket(_handle);
                _handle = INVALID_IOCP_SOCKET;
            }
        }
        else static if (os_bsd)
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

private:
    bool _closing;
    bool _connected;
    InetAddress _remote;
    UDPRecvHandler _on_recv;
    EtherEndpoint* _ether;

    void on_ether_recv(EtherEndpoint*, const(void)[] data, MACAddress src, ushort src_port, MonoTime rx_time)
    {
        if (_on_recv)
        {
            InetAddress from = InetAddress(src.b, src_port);
            _on_recv(&this, data, from, rx_time);
        }
    }

    // an endpoint is reclaimable once nothing references it; on windows that means its
    // cancelled overlapped ops have all delivered
    bool reclaimable() const
    {
        static if (!ip_lowering && os_iocp)
            return _outstanding == 0;
        else
            return true;
    }

    void release()
    {
        static if (ip_lowering)
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
    }

    static if (ip_lowering)
    {
        UdpPcb* _pcb;

        // the ip stack's udp demux hands datagrams up here
        public void deliver(IPAddr src, ushort sport, const(ubyte)[] data, MonoTime rx_time)
        {
            if (_on_recv)
            {
                InetAddress from = InetAddress(src, sport);
                _on_recv(&this, data, from, rx_time);
            }
        }
    }
    else static if (os_iocp)
    {
        struct RecvFromOp
        {
            IoOp io;
            sockaddr_in from;
            int from_len = cast(int)sockaddr_in.sizeof;
            ubyte[64 * 1024] buf;
        }

        IOCP_SOCKET _handle = INVALID_IOCP_SOCKET;
        int  _outstanding;
        RecvFromOp _recv;

        bool post_recv()
        {
            _recv.io.ov = OVERLAPPED.init;
            _recv.io.on_complete = &recv_complete;
            _recv.from_len = cast(int)sockaddr_in.sizeof;
            WSABUF wb = WSABUF(cast(uint)_recv.buf.length, _recv.buf.ptr);
            uint flags, recvd;
            ++_outstanding;
            if (WSARecvFrom(_handle, &wb, 1, &recvd, &flags, cast(void*)&_recv.from, &_recv.from_len, &_recv.io.ov, null) != 0 &&
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
            if (ok && bytes > 0 && _on_recv)
            {
                InetAddress from = from_sockaddr_in(_recv.from);
                _on_recv(&this, _recv.buf[0 .. bytes], from, getTime());
            }
            if (!_closing)
                post_recv();    // transient errors / empty datagrams: keep the socket armed
        }
    }
    else static if (os_bsd)
    {
        Socket _socket;
        bool _watched;

        void on_ready(IoReady ready)
        {
            if (_closing)
                return;
            while (!_closing)
            {
                size_t got;
                InetAddress from;
                Result r = _socket.recvfrom(_udp_scratch[], MsgFlags.none, &from, &got);
                if (r.failed || got == 0)
                    return;     // would-block, or a transient error udp just shrugs off
                if (_on_recv)
                    _on_recv(&this, _udp_scratch[0 .. got], from, getTime());
            }
        }
    }
}

void udp_print(Session session)
{
    if (_udp_eps.length == 0)
    {
        session.write_line("No UDP endpoints");
        return;
    }

    Table t;
    t.add_column("local");
    t.add_column("remote");
    t.add_column("mode");
    t.add_column("egress");

    foreach (ep; _udp_eps[])
    {
        BaseInterface egress = ep.egress_iface;
        InetAddress local = ep.local;
        bool have_local = local.family == AddressFamily.ipv4 || local.family == AddressFamily.ipv6 ||
                          local.family == AddressFamily.ether;

        t.add_row();
        t.cell(have_local ? tconcat(local) : "-");
        t.cell(ep._connected ? tconcat(ep._remote) : "*");
        t.cell(ep._connected ? "connected" : "multi-drop");
        t.cell(egress ? egress.name[] : "-");
    }

    t.render(session);
}


package(router.transport) void udp_update()
{
    // closed endpoints are freed here once nothing references them (on windows that means their
    // cancelled overlapped ops have all delivered; elsewhere close is immediately reclaimable)
    for (size_t i = _udp_eps.length; i-- > 0; )
    {
        if (_udp_eps[i]._closing && _udp_eps[i].reclaimable)
        {
            _udp_eps[i].release();
            defaultAllocator().freeT(_udp_eps[i]);
            _udp_eps.removeSwapLast(i);
        }
    }
}

package(router.transport) void udp_deinit()
{
    foreach (u; _udp_eps[])
        u.close();
    udp_update();
}


private:

__gshared Array!(UDPEndpoint*) _udp_eps;

static if (os_bsd)
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

static if (ip_lowering)
{
    __gshared ushort _next_udp_port = 49_152;

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
}
