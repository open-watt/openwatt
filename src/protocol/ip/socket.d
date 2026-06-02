module protocol.ip.socket;

version (UseInternalIPStack):

import urt.array;
import urt.inet;
import urt.map;
import urt.mem : defaultAllocator, memcpy, memmove;
import urt.socket;
import urt.time;

import protocol.ip.stack;
import protocol.ip.tcp;
import protocol.ip.tcp.pbuf;
import protocol.ip.udp;

nothrow @nogc:


void install_socket_backend(IPStack* stack)
{
    _stack = stack;

    _backend.create            = &c_create;
    _backend.close             = &c_close;
    _backend.bind              = &c_bind;
    _backend.listen            = &c_listen;
    _backend.connect           = &c_connect;
    _backend.accept            = &c_accept;
    _backend.shutdown          = &c_shutdown;
    _backend.sendmsg           = &c_sendmsg;
    _backend.recv              = &c_recv;
    _backend.recvfrom          = &c_recvfrom;
    _backend.pending           = &c_pending;
    _backend.poll              = &c_poll;
    _backend.set_option        = &c_set_option;
    _backend.get_option        = &c_get_option;
    _backend.get_peer_name     = &c_get_peer_name;
    _backend.get_socket_name   = &c_get_socket_name;
    _backend.get_hostname      = &c_get_hostname;
    _backend.get_address_info  = &c_get_address_info;
    _backend.next_address      = &c_next_address;
    _backend.free_address_info = &c_free_address_info;

    register_socket_backend(&_backend);
}


private:

struct TcpSlot
{
    tcp_pcb*          pcb;              // nulled in on_err after lwIP frees the pcb
    int               handle;
    Array!ubyte       recv_buf;
    Array!(TcpSlot*)  accept_queue;
    bool fin_seen;
    bool error_event;
    bool connect_done;
    bool connect_failed;
    bool is_listener;
}

struct Slot
{
    SocketType    sock_type;
    AddressFamily family;
    bool          non_blocking;
    UdpPcb*       udp;
    TcpSlot*      tcp;
    // RawPcb*    raw;     // future
}


__gshared SocketBackend _backend;
__gshared Map!(int, Slot*) _slots;
__gshared int _next_handle = 1;
__gshared ushort _next_ephemeral = 49152;
__gshared IPStack* _stack;


Slot* lookup(Socket s)
{
    if (auto p = s.handle in _slots)
        return *p;
    return null;
}

ushort allocate_ephemeral()
{
    ushort port = _next_ephemeral;
    _next_ephemeral = port == 0xFFFF ? 49152 : cast(ushort)(port + 1);
    return port;
}

ip_addr_t ip_addr_v4(IPAddr a)
{
    ip_addr_t r;
    r.u_addr.ip4 = a;
    r.type = IPADDR_TYPE_V4;
    return r;
}


err_t on_recv(void* arg, tcp_pcb* tpcb, pbuf* p, err_t err) nothrow @nogc
{
    TcpSlot* slot = cast(TcpSlot*)arg;
    if (slot is null)
    {
        // arg cleared by c_close; pcb is on its way out
        if (p !is null)
            pbuf_free(p);
        return ERR_OK;
    }
    if (p is null)
    {
        slot.fin_seen = true;
        return ERR_OK;
    }
    ushort total = p.tot_len;
    if (total > 0)
    {
        size_t old = slot.recv_buf.length;
        slot.recv_buf.resize(old + total);
        pbuf_copy_partial(p, slot.recv_buf.ptr + old, total, 0);
        tcp_recved(tpcb, total);
    }
    pbuf_free(p);
    return ERR_OK;
}

err_t on_sent(void* arg, tcp_pcb* tpcb, ushort len) nothrow @nogc
{
    return ERR_OK;
}

void on_err(void* arg, err_t err) nothrow @nogc
{
    TcpSlot* slot = cast(TcpSlot*)arg;
    if (slot is null)
        return;
    // lwIP frees the pcb before firing this callback (tcp_abandon order); slot.pcb is dangling.
    slot.error_event = true;
    slot.pcb = null;
    if (!slot.connect_done)
        slot.connect_failed = true;
}

err_t on_accept(void* arg, tcp_pcb* newpcb, err_t err) nothrow @nogc
{
    TcpSlot* listener = cast(TcpSlot*)arg;
    if (listener is null || err != ERR_OK || newpcb is null)
        return ERR_VAL;
    // Wire callbacks eagerly: data may arrive on the child pcb between here and
    // c_accept; without our on_recv installed, lwIP's tcp_recv_null silently drops it.
    TcpSlot* child = defaultAllocator().allocT!TcpSlot();
    child.pcb = newpcb;
    install_callbacks(child);
    listener.accept_queue ~= child;
    return ERR_OK;
}

err_t on_connected(void* arg, tcp_pcb* tpcb, err_t err) nothrow @nogc
{
    TcpSlot* slot = cast(TcpSlot*)arg;
    if (slot is null)
        return ERR_OK;
    if (err == ERR_OK)
        slot.connect_done = true;
    else
        slot.connect_failed = true;
    return ERR_OK;
}

void install_callbacks(TcpSlot* slot)
{
    tcp_arg (slot.pcb, slot);
    tcp_recv(slot.pcb, &on_recv);
    tcp_sent(slot.pcb, &on_sent);
    tcp_err (slot.pcb, &on_err);
}


SocketResult c_create(AddressFamily af, SocketType type, Protocol proto, out Socket socket)
{
    if (af != AddressFamily.ipv4)
        return SocketResult.invalid_argument;     // v6 later

    Slot* s = defaultAllocator().allocT!Slot();
    s.sock_type = type;
    s.family    = af;

    int h = _next_handle++;
    if (type == SocketType.datagram)
    {
        s.udp = defaultAllocator().allocT!UdpPcb();
        s.udp.handle = h;
        udp_register(s.udp);
    }
    else if (type == SocketType.stream)
    {
        TcpSlot* tslot = defaultAllocator().allocT!TcpSlot();
        tslot.pcb = tcp_new();
        if (tslot.pcb is null)
        {
            defaultAllocator().freeT(tslot);
            defaultAllocator().freeT(s);
            return SocketResult.failure;
        }
        tslot.handle = h;
        install_callbacks(tslot);
        s.tcp = tslot;
    }
    else
    {
        defaultAllocator().freeT(s);
        return SocketResult.invalid_argument;     // raw later
    }

    _slots[h] = s;
    socket = Socket(h);
    return SocketResult.success;
}

SocketResult c_close(Socket socket)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;

    if (s.udp)
    {
        udp_unregister(s.udp);
        foreach (ref dgm; s.udp.recv_queue[])
            udp_free_datagram_data(dgm);
        defaultAllocator().freeT(s.udp);
    }
    else if (s.tcp)
    {
        TcpSlot* ts = s.tcp;
        if (ts.pcb !is null)
        {
            // detach arg so any late callbacks don't deref the about-to-be-freed slot
            tcp_arg(ts.pcb, null);
            err_t err = tcp_close(ts.pcb);
            if (err != ERR_OK)
                tcp_abort(ts.pcb);
        }
        // children wired in on_accept but never claimed via c_accept
        foreach (child; ts.accept_queue[])
        {
            if (child.pcb !is null)
            {
                tcp_arg(child.pcb, null);
                tcp_abort(child.pcb);
            }
            child.recv_buf.clear();
            defaultAllocator().freeT(child);
        }
        ts.accept_queue.clear();
        ts.recv_buf.clear();
        defaultAllocator().freeT(ts);
    }
    _slots.remove(socket.handle);
    defaultAllocator().freeT(s);
    return SocketResult.success;
}

SocketResult c_bind(Socket socket, ref const InetAddress address)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (address.family != AddressFamily.ipv4)
        return SocketResult.invalid_argument;

    ushort port = address._a.ipv4.port;
    if (port == 0)
        port = allocate_ephemeral();

    if (s.tcp)
    {
        ip_addr_t local = ip_addr_v4(address._a.ipv4.addr);
        err_t err = tcp_bind(s.tcp.pcb, &local, port);
        if (err == ERR_USE)  return SocketResult.address_in_use;
        if (err != ERR_OK)   return SocketResult.failure;
        return SocketResult.success;
    }
    if (!s.udp)
        return SocketResult.invalid_argument;

    s.udp.local_addr = address._a.ipv4.addr;
    s.udp.local_port = port;
    return SocketResult.success;
}

SocketResult c_listen(Socket socket, uint backlog)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (!s.tcp || s.tcp.pcb is null)
        return SocketResult.invalid_argument;

    // tcp_listen swaps the pcb for a smaller tcp_pcb_listen and frees the original; rewire on the listener

    ubyte b = backlog > 255 ? 255 : cast(ubyte)backlog;
    tcp_pcb* lpcb = tcp_listen_with_backlog(s.tcp.pcb, b);
    if (lpcb is null)
        return SocketResult.failure;
    s.tcp.pcb = lpcb;
    s.tcp.is_listener = true;
    tcp_arg(lpcb, s.tcp);
    tcp_accept(lpcb, &on_accept);
    return SocketResult.success;
}

SocketResult c_connect(Socket socket, ref const InetAddress address)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (address.family != AddressFamily.ipv4)
        return SocketResult.invalid_argument;

    if (s.tcp)
    {
        if (s.tcp.pcb is null)
            return SocketResult.failure;
        if (s.tcp.pcb.state != CLOSED)
            return SocketResult.already_connected;
        ip_addr_t remote = ip_addr_v4(address._a.ipv4.addr);
        err_t err = tcp_connect(s.tcp.pcb, &remote, address._a.ipv4.port, &on_connected);
        if (err == ERR_RTE)  return SocketResult.network_unreachable;
        if (err != ERR_OK)   return SocketResult.failure;
        return SocketResult.would_block;
    }
    if (s.udp)
    {
        if (s.udp.local_port == 0)
            s.udp.local_port = allocate_ephemeral();
        s.udp.remote_addr = address._a.ipv4.addr;
        s.udp.remote_port = address._a.ipv4.port;
        s.udp.connected   = true;
        return SocketResult.success;
    }
    return SocketResult.invalid_argument;
}

SocketResult c_accept(Socket socket, out Socket connection, InetAddress* remote)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (!s.tcp || !s.tcp.is_listener)
        return SocketResult.invalid_argument;

    if (s.tcp.accept_queue.length == 0)
        return SocketResult.would_block;

    TcpSlot* cts = s.tcp.accept_queue[0];
    s.tcp.accept_queue.remove(0);

    int h = _next_handle++;
    cts.handle = h;
    Slot* cs = defaultAllocator().allocT!Slot();
    cs.sock_type = SocketType.stream;
    cs.family    = AddressFamily.ipv4;
    cs.tcp       = cts;
    _slots[h] = cs;

    connection = Socket(h);
    if (remote && cts.pcb !is null)
        *remote = InetAddress(cts.pcb.remote_ip.u_addr.ip4, cts.pcb.remote_port);

    if (cts.pcb !is null)
        tcp_backlog_accepted(cts.pcb);
    return SocketResult.success;
}

SocketResult c_shutdown(Socket socket, SocketShutdownMode how)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (s.tcp && s.tcp.pcb !is null)
    {
        int rx = (how == SocketShutdownMode.read  || how == SocketShutdownMode.read_write) ? 1 : 0;
        int tx = (how == SocketShutdownMode.write || how == SocketShutdownMode.read_write) ? 1 : 0;
        tcp_shutdown(s.tcp.pcb, rx, tx);
    }
    return SocketResult.success;
}

SocketResult c_sendmsg(Socket socket, const(InetAddress)* addr, MsgFlags flags, const(void[])[] buffers, size_t* bytes_sent)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;

    if (s.tcp)
    {
        if (s.tcp.pcb is null)
            return SocketResult.connection_closed;

        size_t total_avail = 0;
        foreach (b; buffers)
            total_avail += b.length;

        size_t total_sent = 0;
        foreach (b; buffers)
        {
            if (b.length == 0) continue;
            size_t remaining = b.length;
            const(ubyte)* src = cast(const(ubyte)*)b.ptr;
            while (remaining > 0)
            {
                ushort cap = tcp_sndbuf(s.tcp.pcb);
                if (cap == 0)
                    goto done;
                ushort chunk = remaining < cap ? cast(ushort)remaining : cap;
                err_t err = tcp_write(s.tcp.pcb, src, chunk, TCP_WRITE_FLAG_COPY);
                if (err == ERR_MEM)
                    goto done;
                if (err != ERR_OK)
                {
                    if (bytes_sent) *bytes_sent = total_sent;
                    return SocketResult.failure;
                }
                src        += chunk;
                remaining  -= chunk;
                total_sent += chunk;
            }
        }
    done:
        if (total_sent > 0)
            tcp_output(s.tcp.pcb);
        if (bytes_sent) *bytes_sent = total_sent;
        if (total_sent == 0 && total_avail > 0)
            return SocketResult.would_block;
        return SocketResult.success;
    }

    if (!s.udp)
        return SocketResult.invalid_argument;

    IPAddr dst_addr;
    ushort dst_port;
    if (addr)
    {
        if (addr.family != AddressFamily.ipv4)
            return SocketResult.invalid_argument;
        dst_addr = addr._a.ipv4.addr;
        dst_port = addr._a.ipv4.port;
    }
    else if (s.udp.connected)
    {
        dst_addr = s.udp.remote_addr;
        dst_port = s.udp.remote_port;
    }
    else
        return SocketResult.invalid_argument;

    enum size_t max = 1500 - 28;     // - IP - UDP
    ubyte[max] gather = void;
    size_t total = 0;
    foreach (b; buffers)
    {
        if (total + b.length > max)
            return SocketResult.invalid_argument;
        gather[total .. total + b.length] = (cast(const(ubyte)[])b)[];
        total += b.length;
    }

    if (s.udp.local_port == 0)
        s.udp.local_port = allocate_ephemeral();

    if (!udp_output(*_stack, s.udp.local_addr, s.udp.local_port, dst_addr, dst_port, gather[0 .. total]))
        return SocketResult.failure;

    if (bytes_sent)
        *bytes_sent = total;
    return SocketResult.success;
}

SocketResult c_recv(Socket socket, void[] buffer, MsgFlags flags, size_t* bytes_received)
    => c_recvfrom(socket, buffer, flags, null, bytes_received);

SocketResult c_recvfrom(Socket socket, void[] buffer, MsgFlags flags, InetAddress* from, size_t* bytes_received)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;

    if (s.tcp)
    {
        TcpSlot* ts = s.tcp;
        size_t avail = ts.recv_buf.length;
        size_t n = avail < buffer.length ? avail : buffer.length;
        if (n > 0)
        {
            memcpy(buffer.ptr, ts.recv_buf.ptr, n);
            ts.recv_buf.remove(0, n);
        }
        if (bytes_received)
            *bytes_received = n;
        if (from && ts.pcb !is null)
            *from = InetAddress(ts.pcb.remote_ip.u_addr.ip4, ts.pcb.remote_port);
        if (n == 0)
        {
            if (ts.fin_seen || ts.pcb is null ||
                ts.pcb.state == CLOSE_WAIT ||
                ts.pcb.state == LAST_ACK ||
                ts.pcb.state == CLOSED)
                return SocketResult.connection_closed;
            return SocketResult.would_block;
        }
        return SocketResult.success;
    }

    if (!s.udp)
        return SocketResult.invalid_argument;

    UdpDatagram d;
    if (!udp_recv(s.udp, d))
    {
        if (bytes_received)
            *bytes_received = 0;
        return SocketResult.would_block;
    }

    size_t n = d.data.length < buffer.length ? d.data.length : buffer.length;
    if (n > 0)
        (cast(ubyte[])buffer)[0 .. n] = d.data[0 .. n];
    if (bytes_received)
        *bytes_received = n;
    if (from)
        *from = InetAddress(d.src_addr, d.src_port);

    udp_free_datagram_data(d);
    return SocketResult.success;
}

SocketResult c_pending(Socket socket, out size_t bytes)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (s.tcp)
        bytes = s.tcp.recv_buf.length;
    else if (s.udp && s.udp.recv_queue.length > 0)
        bytes = s.udp.recv_queue[0].data.length;
    else
        bytes = 0;
    return SocketResult.success;
}

SocketResult c_poll(PollFd[] fds, Duration timeout, out uint num_ready)
{
    num_ready = 0;
    foreach (ref fd; fds)
    {
        fd.return_events = PollEvents.none;
        auto s = lookup(fd.socket);
        if (!s)
        {
            fd.return_events = PollEvents.invalid;
            ++num_ready;
            continue;
        }
        if (s.udp)
        {
            if ((fd.request_events & PollEvents.read) && s.udp.recv_queue.length > 0)
                fd.return_events |= PollEvents.read;
            if (fd.request_events & PollEvents.write)
                fd.return_events |= PollEvents.write;     // UDP is always writable
        }
        else if (s.tcp)
        {
            TcpSlot* ts = s.tcp;
            bool pcb_closed = (ts.pcb is null || ts.pcb.state == CLOSED);
            if (fd.request_events & PollEvents.read)
            {
                bool readable = ts.recv_buf.length > 0
                              || (ts.is_listener && ts.accept_queue.length > 0)
                              || ts.fin_seen
                              || pcb_closed
                              || (ts.pcb !is null && ts.pcb.state == CLOSE_WAIT);
                if (readable)
                    fd.return_events |= PollEvents.read;
            }
            if (fd.request_events & PollEvents.write)
            {
                if (ts.pcb !is null &&
                    ts.pcb.state == ESTABLISHED &&
                    tcp_sndbuf(ts.pcb) > 0)
                    fd.return_events |= PollEvents.write;
            }
            if (ts.error_event || pcb_closed)
                fd.return_events |= PollEvents.hangup;
        }
        if (fd.return_events != PollEvents.none)
            ++num_ready;
    }
    // never block; IP stack runs on the same main loop, callers iterate

    return SocketResult.success;
}

SocketResult c_set_option(Socket socket, SocketOption opt, const(void)* value, size_t size)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (opt == SocketOption.non_blocking)
    {
        if (size != 1)
            return SocketResult.invalid_argument;
        s.non_blocking = *cast(ubyte*)value != 0;
        return SocketResult.success;
    }
    return SocketResult.success;
}

SocketResult c_get_option(Socket socket, SocketOption opt, void* value, size_t size)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (opt == SocketOption.non_blocking)
    {
        if (size < 1)
            return SocketResult.invalid_argument;
        *cast(ubyte*)value = s.non_blocking ? 1 : 0;
    }
    return SocketResult.success;
}

SocketResult c_get_peer_name(Socket socket, out InetAddress addr)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (s.tcp && s.tcp.pcb !is null && s.tcp.pcb.remote_port != 0)
    {
        addr = InetAddress(s.tcp.pcb.remote_ip.u_addr.ip4, s.tcp.pcb.remote_port);
        return SocketResult.success;
    }
    if (s.udp && s.udp.connected)
    {
        addr = InetAddress(s.udp.remote_addr, s.udp.remote_port);
        return SocketResult.success;
    }
    return SocketResult.invalid_argument;
}

SocketResult c_get_socket_name(Socket socket, out InetAddress addr)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (s.tcp && s.tcp.pcb !is null)
    {
        addr = InetAddress(s.tcp.pcb.local_ip.u_addr.ip4, s.tcp.pcb.local_port);
        return SocketResult.success;
    }
    if (s.udp)
    {
        addr = InetAddress(s.udp.local_addr, s.udp.local_port);
        return SocketResult.success;
    }
    return SocketResult.invalid_argument;
}

SocketResult c_get_hostname(char* buffer, size_t size)
{
    static immutable string name = "openwatt";
    if (size < name.length + 1)
        return SocketResult.invalid_argument;
    foreach (i, c; name)
        buffer[i] = c;
    buffer[name.length] = 0;
    return SocketResult.success;
}

SocketResult c_get_address_info(const(char)[] node, const(char)[] service, AddressInfo* info, AddressInfoResolver* resolver)
    => SocketResult.failure;     // TODO: hook into DNS module

bool c_next_address(AddressInfoResolver* resolver, out AddressInfo info)
    => false;

void c_free_address_info(AddressInfoResolver* resolver)
{
}
