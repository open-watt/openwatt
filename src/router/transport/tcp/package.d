module router.transport.tcp;

// TCP endpoint layer: connections, listeners, and the family dispatch that binds them to a
// backend. Ether peers always ride the in-tree engine (router.transport.tcp.engine) over raw ethernet;
// ip peers ride the internal stack when the ip module is present, else the OS kernel sockets.

import urt.array;
import urt.inet;
import urt.log;
import urt.mem.allocator : defaultAllocator;
import urt.socket;
import urt.time;

import manager : EventPriority, g_app;
import manager.base;
import manager.features : has_tcp;
import manager.reactor;

import router.iface;
import router.iface.endpoint;
import router.iface.ethernet;
import router.iface.mac;
import router.transport : internal_stack, ip_lowering, os_iocp;

static if (has_tcp)
    import router.transport.tcp.engine : TcpPcb, TcpState, tcp_assign_id, tcp_send_data, tcp_consume_data,
        tcp_close, free_pcb, tcp_tick, tcp_segment_input,
        native_tcp_connect = tcp_connect, native_tcp_listen = tcp_listen;

static if (os_iocp)
    import driver.windows.winsock;

private alias log = Log!"tcp";

nothrow @nogc:


enum stack_lowering = has_tcp && ip_lowering;   // the engine lowers ip peers onto the internal stack
enum has_os_tcp     = !internal_stack;          // kernel sockets carry the ip families
enum has_ip_tcp     = stack_lowering || has_os_tcp;   // something carries the ip families


enum TCPEvent : ubyte
{
    connected,      // active connect completed
    closed,         // peer closed the connection (graceful EOF)
    error,          // connection reset / fatal error
}

alias TCPRecvHandler   = void delegate(TCPConnection* conn, const(void)[] data, MonoTime rx_time) nothrow @nogc;
alias TCPEventHandler  = void delegate(TCPConnection* conn, TCPEvent event) nothrow @nogc;
alias TCPAcceptHandler = void delegate(TCPListener* listener, TCPConnection* conn, MonoTime rx_time) nothrow @nogc;

private static immutable ubyte[6] zero_mac;


TCPConnection* tcp_connect(InetAddress remote, TCPRecvHandler on_recv, TCPEventHandler on_event = null, const(InetAddress)* local = null)
{
    if (remote.family == AddressFamily.ether)
    {
        static if (has_tcp)
        {
            // unbound floods the SYN, so the reply must be heard on every segment
            if (local && local.family == AddressFamily.ether && !local.addr_any)
            {
                EthernetStation station = find_ether_station(MACAddress(local._a.ether.addr));
                if (!station)
                    return null;
                ensure_ether_tap(station);
            }
            else
                ether_request_tap_all();
            return connect_pcb(remote, local, on_recv, on_event);
        }
        else
            return null;
    }

    static if (stack_lowering)
    {
        if (remote.family != AddressFamily.ipv4)
            return null;     // TODO: ipv6
        return connect_pcb(remote, local, on_recv, on_event);
    }
    else static if (has_os_tcp)
    {
        version (Windows)
        {
            if (remote.family != AddressFamily.ipv4)
                return null;     // IOCP path is v4-only for now
            IOCP_SOCKET s = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
            if (s == INVALID_IOCP_SOCKET)
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
                defaultAllocator().freeT(c);
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
                defaultAllocator().freeT(c);
                return null;
            }
            c._watched = true;
            return c;
        }
    }
    else
        return null;
}

TCPListener* tcp_listen(InetAddress local, TCPAcceptHandler on_accept)
{
    // One rule for every backend: windows binds listeners with SO_REUSEADDR, so the OS would
    // hand a second server the same port and neither would reliably accept.
    if (listener_bound(local))
    {
        log.warning("listen ", local, " refused; already listening there");
        return null;
    }

    if (local.family == AddressFamily.ether)
    {
        static if (has_tcp)
        {
            if (local.addr_any)
                ether_request_tap_all();    // any-listener: accept on every segment
            else
            {
                EthernetStation station = find_ether_station(MACAddress(local._a.ether.addr));
                if (!station)
                    return null;
                ensure_ether_tap(station);
            }
            return listen_pcb(local, on_accept);
        }
        else
            return null;
    }

    static if (stack_lowering)
    {
        if (local.family != AddressFamily.ipv4)
            return null;     // TODO: ipv6
        return listen_pcb(local, on_accept);
    }
    else static if (has_os_tcp)
    {
        version (Windows)
        {
            if (local.family != AddressFamily.ipv4)
                return null;     // IOCP path is v4-only for now
            IOCP_SOCKET s = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
            if (s == INVALID_IOCP_SOCKET)
                return null;
            int yes = 1;
            ws_setsockopt(s, SOL_SOCKET_, SO_REUSEADDR_, &yes, cast(int)yes.sizeof);
            sockaddr_in la = to_sockaddr_in(local);
            if (ws_bind(s, &la, cast(int)sockaddr_in.sizeof) != 0 || ws_listen(s, 128) != 0)
            {
                ws_closesocket(s);
                return null;
            }
            TCPListener* l = defaultAllocator().allocT!TCPListener();
            l._handle = s;
            l._local = local;
            l._on_accept = on_accept;
            if (!g_app.reactor.associate(cast(HANDLE)s) || !l.post_accept())
            {
                ws_closesocket(s);
                defaultAllocator().freeT(l);
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

            TCPListener* l = defaultAllocator().allocT!TCPListener();
            l._socket = s;
            l._local = local;
            l._on_accept = on_accept;
            if (!g_app.reactor.watch_fd(s.handle, false, &l.on_ready))
            {
                s.close();
                defaultAllocator().freeT(l);
                return null;
            }
            l._watched = true;
            _tcp_listeners ~= l;
            return l;
        }
    }
    else
        return null;
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
        static if (has_tcp)
            if (_engine)
                return _pcb ? _pcb.route_egress : null;
        return null;
    }

    // bytes accepted by send() but not yet handed to the network
    size_t tx_backlog() const pure
    {
        static if (has_tcp)
            if (_engine)
                return _tx.length;
        static if (has_os_tcp)
        {
            version (Windows)
                return _tx_pending;
            else
                return _tx.length;
        }
        else
            return 0;
    }

    void recv_handler(TCPRecvHandler handler)
    {
        _on_recv = handler;
        static if (has_tcp)
            if (_engine && handler && _pcb && _pcb.recv_buf.length != 0)
                queue_service();
    }

    void event_handler(TCPEventHandler handler)
    {
        _on_event = handler;
    }

    InetAddress local()
    {
        static if (has_tcp)
            if (_engine)
                return _pcb ? _pcb.local : InetAddress();
        static if (has_os_tcp)
        {
            version (Windows)
                return InetAddress();   // TODO: getsockname
            else
            {
                InetAddress a;
                if (_socket)
                    _socket.get_socket_name(a);
                return a;
            }
        }
        else
            return InetAddress();
    }

    ptrdiff_t send(const(void[])[] data...)
    {
        static if (has_tcp)
        {
            if (_engine)
            {
                if (_phase != Phase.open || _pcb is null)
                    return 0;
                size_t total = 0;
                foreach (b; data)
                    total += b.length;
                if (total == 0)
                    return 0;
                foreach (b; data)
                    _tx ~= cast(const(ubyte)[])b;
                flush_pcb_tx();
                return _phase == Phase.open ? total : 0;
            }
        }
        static if (has_os_tcp)
        {
            version (Windows)
            {
                if (_phase != Phase.open || _handle == INVALID_IOCP_SOCKET)
                    return 0;
                size_t total = 0;
                foreach (b; data)
                    total += b.length;
                if (total == 0)
                    return 0;
                // the overlapped send owns its buffer until the completion delivers
                SendOp* op = defaultAllocator().allocT!SendOp();
                op.io.on_complete = &send_complete;
                op.buf = cast(ubyte[])defaultAllocator().alloc(total);
                size_t off = 0;
                foreach (b; data)
                {
                    op.buf[off .. off + b.length] = cast(const(ubyte)[])b[];
                    off += b.length;
                }
                WSABUF wb = WSABUF(cast(uint)op.buf.length, op.buf.ptr);
                uint sent;
                ++_outstanding;
                _tx_pending += op.buf.length;
                if (WSASend(_handle, &wb, 1, &sent, 0, &op.io.ov, null) != 0 &&
                    ws_lasterror() != WSA_IO_PENDING)
                {
                    --_outstanding;
                    _tx_pending -= op.buf.length;
                    defaultAllocator().free(op.buf);
                    defaultAllocator().freeT(op);
                    fail(TCPEvent.error);
                    return 0;
                }
                return total;
            }
            else
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
                    fail(TCPEvent.error);
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
        }
        else
            return 0;
    }

    // The pcb engine has no keepalive / Nagle yet; there we record intent only.
    void enable_keepalive(bool enable, Duration idle = seconds(10), Duration interval = seconds(1), int count = 10)
    {
        _keepalive = enable;
        _keep_idle = idle;
        _keep_interval = interval;
        _keep_count = count;
        _keepalive_set = true;
        static if (has_os_tcp)
        {
            version (Windows) {} else
            {
                if (!_engine && _phase == Phase.open)
                    set_keepalive(_socket, enable, idle, interval, count);
            }
        }
    }

    void set_no_delay(bool enable)
    {
        _no_delay = enable;
        _no_delay_set = true;
        static if (has_os_tcp)
        {
            version (Windows) {} else
            {
                if (!_engine && _phase == Phase.open)
                    _socket.set_socket_option(SocketOption.tcp_no_delay, enable);
            }
        }
    }

    void close()
    {
        if (_closing)
            return;
        static if (has_tcp)
        {
            if (_engine)
            {
                if (_pcb)
                {
                    _pcb.conn_owner = null;
                    _pcb.handle = 0;     // detach: tcp_tick frees the pcb once it's fully closed
                    tcp_close(_pcb);
                    if (_pcb.state == TcpState.closed)
                        free_pcb(_pcb);
                    _pcb = null;
                }
                _phase = Phase.dead;
                _closing = true;
                return;
            }
        }
        static if (has_os_tcp)
        {
            _closing = true;
            version (Windows)
            {
                _on_recv = null;
                _on_event = null;
                _phase = Phase.dead;
                if (_handle != INVALID_IOCP_SOCKET)
                {
                    CancelIoEx(cast(HANDLE)_handle, null);
                    ws_closesocket(_handle);
                    _handle = INVALID_IOCP_SOCKET;
                }
                // freed by the pump sweep once the cancelled ops' completions drain
            }
            else
            {
                _phase = Phase.dead;
                detach_watch();
                if (_socket)
                {
                    _socket.close();
                    _socket = null;
                }
                // freed by the pump sweep
            }
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

    static if (has_tcp && has_os_tcp)
        bool _engine;               // runtime backend tag: pcb engine (ether) vs kernel socket
    else
        enum bool _engine = has_tcp;

    enum size_t max_tx = 256 * 1024;

    void fail(TCPEvent ev)
    {
        if (_phase == Phase.dead)
            return;
        _phase = Phase.dead;
        TCPEventHandler handler = _on_event;
        _on_recv = null;
        _on_event = null;
        if (handler)
            handler(&this, ev);
    }

    void pump()
    {
        static if (has_tcp)
        {
            if (_engine)
            {
                pump_pcb();
                return;
            }
        }
        static if (has_os_tcp)
        {
            version (Windows) {}       // completion-driven; nothing to flush here
            else
            {
                if (_closing || _phase != Phase.open)
                    return;
                flush_tx();
            }
        }
    }

    bool reclaimable() const
    {
        static if (has_tcp)
            if (_engine)
                return !_service_pending;
        static if (has_os_tcp)
        {
            version (Windows)
                return _outstanding == 0;
            else
                return true;
        }
        else
            return true;
    }

    static if (has_tcp)
    {
        TcpPcb* _pcb;
        bool _service_pending;

        void pump_pcb()
        {
            if (_closing || _pcb is null)
                return;
            final switch (_phase)
            {
                case Phase.connecting:
                    if (_pcb.state == TcpState.established)
                        mark_connected();
                    else if (_pcb.error_event || _pcb.state == TcpState.closed)
                        fail(TCPEvent.error);
                    break;
                case Phase.open:
                    if (_pcb.error_event || _pcb.state == TcpState.closed)
                        fail(TCPEvent.error);
                    else
                    {
                        drain_pcb_rx();
                        if (_closing || _pcb is null)
                            break;
                        if (_pcb.fin_seen && _pcb.recv_buf.length == 0)
                            fail(TCPEvent.closed);
                        else
                            flush_pcb_tx();
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
                _on_event(&this, TCPEvent.connected);
        }

        package(router.transport.tcp) void queue_service()
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
            pump_pcb();
        }

        void drain_pcb_rx()
        {
            if (_pcb is null || _pcb.recv_buf.length == 0 || _on_recv is null)
                return;

            TcpPcb* pcb = _pcb;
            size_t bytes = pcb.recv_buf.length;
            MonoTime rx_time = pcb.recv_time;
            _on_recv(&this, pcb.recv_buf[0 .. bytes], rx_time);
            if (_pcb is pcb)
                tcp_consume_data(pcb, bytes);
        }

        void flush_pcb_tx()
        {
            if (_pcb is null)
                return;
            while (_tx.length > 0)
            {
                size_t n = tcp_send_data(_pcb, _tx[]);
                if (n == 0)
                    break;     // send buffer full; drained on a later pump
                _tx.remove(0, n);
            }
        }
    }

    static if (has_os_tcp)
    {
        version (Windows)
        {
            struct SendOp { IoOp io; ubyte[] buf; }
            struct RecvOp { IoOp io; ubyte[16 * 1024] buf; }

            IOCP_SOCKET _handle = INVALID_IOCP_SOCKET;
            int  _outstanding;   // overlapped ops in flight; freed by the pump sweep once they drain
            size_t _tx_pending;  // bytes owned by in-flight send ops
            IoOp _connect_op;
            RecvOp _recv;

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
                    fail(TCPEvent.error);
                    return;
                }
                ws_setsockopt(_handle, SOL_SOCKET_, SO_UPDATE_CONNECT_CONTEXT, null, 0);
                _phase = Phase.open;
                if (_on_event)
                    _on_event(&this, TCPEvent.connected);
                if (!_closing)
                    post_recv();
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
                    fail(TCPEvent.error);
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
                    fail(TCPEvent.error);
                    return;
                }
                if (bytes == 0)
                {
                    fail(TCPEvent.closed);
                    return;
                }
                if (_on_recv)
                    _on_recv(&this, _recv.buf[0 .. bytes], getTime());
                if (!_closing && !post_recv())
                    fail(TCPEvent.error);
            }

            void send_complete(IoOp* op, bool ok, uint, uint)
            {
                SendOp* sop = cast(SendOp*)op;
                _tx_pending -= sop.buf.length;
                defaultAllocator().free(sop.buf);
                defaultAllocator().freeT(sop);
                --_outstanding;
                if (!_closing && !ok)
                    fail(TCPEvent.error);
            }
        }
        else
        {
            Socket _socket;
            bool _watched;

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
                        fail(TCPEvent.error);
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
                            _on_event(&this, TCPEvent.connected);
                    }
                    return;
                }
                if (ready & IoReady.error)
                {
                    detach_watch();
                    fail(TCPEvent.error);
                    return;
                }
                if (ready & IoReady.readable)
                    drain_rx();
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
                        fail(TCPEvent.closed);
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
                while (_tx.length > 0)
                {
                    size_t sent;
                    Result r = _socket.send(MsgFlags.none, &sent, cast(const(void)[])_tx[]);
                    if (r.failed && r.socket_result != SocketResult.would_block)
                    {
                        fail(TCPEvent.error);
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
}


struct TCPListener
{
nothrow @nogc:
    ushort port() const pure
        => _local.port;

    void close()
    {
        if (_closing)
            return;
        static if (has_tcp)
        {
            if (_engine)
            {
                if (_lpcb)
                {
                    _lpcb.listen_owner = null;
                    _lpcb.handle = 0;
                    tcp_close(_lpcb);     // RSTs unaccepted children, frees the listen pcb
                    if (_lpcb.state == TcpState.closed)
                        free_pcb(_lpcb);
                    _lpcb = null;
                }
                _closing = true;
                return;
            }
        }
        static if (has_os_tcp)
        {
            _closing = true;
            version (Windows)
            {
                if (_handle != INVALID_IOCP_SOCKET)
                {
                    CancelIoEx(cast(HANDLE)_handle, null);
                    ws_closesocket(_handle);
                    _handle = INVALID_IOCP_SOCKET;
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
    }

private:
    bool _closing;
    InetAddress _local;
    TCPAcceptHandler _on_accept;

    static if (has_tcp && has_os_tcp)
        bool _engine;               // runtime backend tag: pcb engine (ether) vs kernel socket
    else
        enum bool _engine = has_tcp;

    bool reclaimable() const
    {
        static if (has_tcp)
            if (_engine)
                return true;
        static if (has_os_tcp)
        {
            version (Windows)
                return _outstanding == 0;
            else
                return true;
        }
        else
            return true;
    }

    static if (has_tcp)
    {
        TcpPcb* _lpcb;

        package(router.transport.tcp) void on_child(TcpPcb* child, MonoTime rx_time)
        {
            child.handle = TcpEndpointOwned;
            TCPConnection* c = register_tcp_conn_pcb(child);
            if (_on_accept)
                _on_accept(&this, c, rx_time);
            else
                c.close();
        }
    }

    static if (has_os_tcp)
    {
        version (Windows)
        {
            struct AcceptOp
            {
                IoOp io;
                IOCP_SOCKET child = INVALID_IOCP_SOCKET;
                ubyte[(sockaddr_in.sizeof + 16) * 2] addrs;
            }

            IOCP_SOCKET _handle = INVALID_IOCP_SOCKET;
            int  _outstanding;
            AcceptOp _accept;

            bool post_accept()
            {
                if (_closing || g_accept_ex is null)
                    return false;
                IOCP_SOCKET child = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
                if (child == INVALID_IOCP_SOCKET)
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
                    _accept.child = INVALID_IOCP_SOCKET;
                    return false;
                }
                return true;
            }

            void accept_complete(IoOp*, bool ok, uint, uint)
            {
                --_outstanding;
                IOCP_SOCKET child = _accept.child;
                _accept.child = INVALID_IOCP_SOCKET;
                if (_closing)
                {
                    if (child != INVALID_IOCP_SOCKET)
                        ws_closesocket(child);
                    return;
                }
                if (!ok)
                {
                    if (child != INVALID_IOCP_SOCKET)
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
}


package(router.transport) void tcp_update()
{
    static if (has_tcp)
        tcp_tick(getTime());
    update_tcp_endpoints();
}

package(router.transport) void tcp_deinit()
{
    // close whatever the owners left behind; the sweep won't run again, so free what's
    // immediately reclaimable and let cancelled in-flight ops leak at exit. Engine-backed
    // endpoints are left alone: their teardown emits segments, and the fabric they ride
    // may already be gone.
    foreach (c; _tcp_conns[])
    {
        if (!c._engine)
            c.close();
    }
    foreach (l; _tcp_listeners[])
    {
        if (!l._engine)
            l.close();
    }
    update_tcp_endpoints();
}


private:

__gshared Array!(TCPConnection*) _tcp_conns;
__gshared Array!(TCPListener*)   _tcp_listeners;


// A wildcard on either side collides: it accepts everything the specific one would have taken.
// A zero port is an ephemeral request, and each of those lands somewhere different.
bool listener_bound(ref const InetAddress local)
{
    if (local.port == 0)
        return false;
    foreach (l; _tcp_listeners[])
    {
        if (l._closing)
            continue;
        if (l._local.family != local.family || l._local.port != local.port)
            continue;
        if (l._local.addr_any || local.addr_any || l._local.same_addr(local))
            return true;
    }
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

void update_tcp_endpoints()
{
    foreach (i; 0 .. _tcp_conns.length)
        _tcp_conns[i].pump();

    // closed endpoints are freed here once nothing references them (on windows that means their
    // cancelled overlapped ops have all delivered; elsewhere close is immediately reclaimable)
    for (size_t i = _tcp_conns.length; i-- > 0; )
    {
        if (_tcp_conns[i]._closing && _tcp_conns[i].reclaimable)
        {
            defaultAllocator().freeT(_tcp_conns[i]);
            _tcp_conns.removeSwapLast(i);
        }
    }
    for (size_t i = _tcp_listeners.length; i-- > 0; )
    {
        if (_tcp_listeners[i]._closing && _tcp_listeners[i].reclaimable)
        {
            defaultAllocator().freeT(_tcp_listeners[i]);
            _tcp_listeners.removeSwapLast(i);
        }
    }
}

static if (has_tcp)
{
    enum int TcpEndpointOwned = -1;

    __gshared ushort _next_tcp_port = 49_152;

    ushort allocate_tcp_port()
    {
        ushort p = _next_tcp_port;
        _next_tcp_port = _next_tcp_port == 65_535 ? 49_152 : cast(ushort)(_next_tcp_port + 1);
        return p;
    }

    TCPConnection* connect_pcb(InetAddress remote, const(InetAddress)* local, TCPRecvHandler on_recv, TCPEventHandler on_event)
    {
        TcpPcb* pcb = defaultAllocator().allocT!TcpPcb();
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

        TCPConnection* c = defaultAllocator().allocT!TCPConnection();
        c._pcb = pcb;
        c._remote = remote;
        c._on_recv = on_recv;
        c._on_event = on_event;
        c._phase = TCPConnection.Phase.connecting;
        static if (has_os_tcp)
            c._engine = true;
        pcb.conn_owner = c;

        if (!native_tcp_connect(pcb))
        {
            pcb.conn_owner = null;
            free_pcb(pcb);
            defaultAllocator().freeT(c);
            return null;
        }
        _tcp_conns ~= c;
        return c;
    }

    TCPListener* listen_pcb(InetAddress local, TCPAcceptHandler on_accept)
    {
        TcpPcb* pcb = defaultAllocator().allocT!TcpPcb();
        tcp_assign_id(pcb);
        pcb.handle = TcpEndpointOwned;
        pcb.local = local;
        if (pcb.local.port == 0)
            pcb.local.port = allocate_tcp_port();

        TCPListener* l = defaultAllocator().allocT!TCPListener();
        l._lpcb = pcb;
        l._local = pcb.local;
        l._on_accept = on_accept;
        static if (has_os_tcp)
            l._engine = true;
        pcb.listen_owner = l;
        if (!native_tcp_listen(pcb))    // sets state=listen, registers
        {
            pcb.listen_owner = null;
            free_pcb(pcb);
            defaultAllocator().freeT(l);
            return null;
        }
        _tcp_listeners ~= l;
        return l;
    }

    TCPConnection* register_tcp_conn_pcb(TcpPcb* pcb)
    {
        TCPConnection* c = defaultAllocator().allocT!TCPConnection();
        c._pcb = pcb;
        c._phase = TCPConnection.Phase.open;
        c._remote = pcb.remote;
        static if (has_os_tcp)
            c._engine = true;
        pcb.conn_owner = c;
        _tcp_conns ~= c;
        return c;
    }

    package(router.transport) void ether_tcp_input(MACAddress src, MACAddress dst, const(void)[] segment, MonoTime rx_time)
    {
        tcp_segment_input(InetAddress(src.b, 0), InetAddress(dst.b, 0), cast(const(ubyte)[])segment, rx_time);
    }
}

static if (has_os_tcp)
{
    version (Windows)
    {
        TCPConnection* register_tcp_conn(IOCP_SOCKET s, InetAddress remote)
        {
            TCPConnection* c = defaultAllocator().allocT!TCPConnection();
            c._handle = s;
            c._remote = remote;
            _tcp_conns ~= c;
            return c;
        }
    }
    else
    {
        TCPConnection* register_tcp_conn(Socket s, InetAddress remote)
        {
            TCPConnection* c = defaultAllocator().allocT!TCPConnection();
            c._socket = s;
            c._remote = remote;
            _tcp_conns ~= c;
            return c;
        }
    }
}
