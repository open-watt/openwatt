module protocol.ip.socket;

version (UseInternalIPStack):

import urt.array;
import urt.inet;
import urt.map;
import urt.mem;
import urt.socket;
import urt.time;

import manager.collection : Collection;
import manager.features : has_ipv6;

import router.iface : BaseInterface, interface_for_scope;

import protocol.ip.address;
import protocol.ip.stack;
import protocol.ip.tcp;
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

struct Slot
{
    SocketType    sock_type;
    AddressFamily family;
    bool          non_blocking;
    UdpPcb*       udp;
    TcpPcb*       tcp;
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


SocketResult c_create(AddressFamily af, SocketType type, Protocol proto, out Socket socket)
{
    if (!family_supported(af))
        return SocketResult.invalid_argument;
    if (type == SocketType.stream && af != AddressFamily.ipv4)
        return SocketResult.invalid_argument;    // TODO: TCPv6

    Slot* s = alloc!Slot();
    s.sock_type = type;
    s.family    = af;

    int h = _next_handle++;
    if (type == SocketType.datagram)
    {
        s.udp = alloc!UdpPcb();
        s.udp.family = af;
        s.udp.handle = h;
        udp_register(s.udp);
    }
    else if (type == SocketType.stream)
    {
        s.tcp = alloc!TcpPcb();
        s.tcp.handle = h;
        tcp_assign_id(s.tcp);
    }
    else
    {
        free(s);
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
        udp_close(*_stack, s.udp);
    else if (s.tcp)
    {
        // Detach from socket layer; TCP may continue closing in background
        // (FIN_WAIT/TIME_WAIT). Mark handle=0 so tcp_tick can free once closed.
        s.tcp.handle = 0;
        tcp_close(*_stack, s.tcp);
        // If tcp_close drove us straight to closed (e.g. listen with no children,
        // or syn_sent), the PCB has already been unregistered and we own it.
        if (s.tcp.state == TcpState.closed)
            free_pcb(s.tcp);
    }
    _slots.remove(socket.handle);
    free(s);
    return SocketResult.success;
}

SocketResult c_bind(Socket socket, ref const InetAddress address)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (address.family != s.family)
        return SocketResult.invalid_argument;

    if (s.tcp)
    {
        s.tcp.local = address;
        if (s.tcp.local.port == 0)
            s.tcp.local.port = allocate_ephemeral();
        return SocketResult.success;
    }
    if (!s.udp)
        return SocketResult.invalid_argument;

    if (s.udp.local_port != 0)
        return SocketResult.invalid_argument;
    if (!udp_bind(s.udp, address))
        return SocketResult.address_in_use;
    return SocketResult.success;
}

SocketResult c_listen(Socket socket, uint backlog)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (!s.tcp)
        return SocketResult.invalid_argument;
    if (s.tcp.local.family == AddressFamily.unspecified)
        s.tcp.local = InetAddress(IPAddr.any, 0);
    if (s.tcp.local.port == 0)
        s.tcp.local.port = allocate_ephemeral();
    tcp_listen(s.tcp);
    return SocketResult.success;
}

SocketResult c_connect(Socket socket, ref const InetAddress address)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (address.family != s.family)
        return SocketResult.invalid_argument;

    if (s.tcp)
    {
        if (s.tcp.state != TcpState.closed)
            return SocketResult.already_connected;
        if (s.tcp.local.family == AddressFamily.unspecified)
            s.tcp.local = InetAddress(IPAddr.any, 0);
        if (s.tcp.local.port == 0)
            s.tcp.local.port = allocate_ephemeral();
        s.tcp.remote = address;
        if (s.tcp.local.addr_any)
        {
            IPAddr src = _stack.select_source_v4(s.tcp.remote._a.ipv4.addr);
            if (src == IPAddr.any)
                return SocketResult.network_unreachable;
            s.tcp.local = InetAddress(src, s.tcp.local.port);
        }
        if (!tcp_connect(*_stack, s.tcp))
            return SocketResult.failure;
        return SocketResult.would_block;
    }
    if (s.udp)
    {
        if (s.udp.local_port == 0 && !udp_bind(s.udp, udp_local(s.udp)))
            return SocketResult.address_in_use;
        if (!udp_connect(s.udp, address))
            return SocketResult.invalid_argument;
        return SocketResult.success;
    }
    return SocketResult.invalid_argument;
}

bool family_supported(AddressFamily af) pure
    => af == AddressFamily.ipv4 || (has_ipv6 && af == AddressFamily.ipv6);

SocketResult c_accept(Socket socket, out Socket connection, InetAddress* remote)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (!s.tcp || !s.tcp.is_listener)
        return SocketResult.invalid_argument;

    TcpPcb* child;
    if (!tcp_accept(s.tcp, child))
        return SocketResult.would_block;

    int h = _next_handle++;
    Slot* cs = alloc!Slot();
    cs.sock_type = SocketType.stream;
    cs.family    = AddressFamily.ipv4;
    cs.tcp       = child;
    child.handle = h;
    _slots[h] = cs;

    connection = Socket(h);
    if (remote)
        *remote = child.remote;

    s.tcp.accept_event = (s.tcp.accept_queue.length > 0);
    return SocketResult.success;
}

SocketResult c_shutdown(Socket socket, SocketShutdownMode how)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (s.tcp && (how == SocketShutdownMode.write || how == SocketShutdownMode.read_write))
        tcp_shutdown_write(*_stack, s.tcp);
    return SocketResult.success;
}

SocketResult c_sendmsg(Socket socket, const(InetAddress)* addr, MsgFlags flags, const(void[])[] buffers, size_t* bytes_sent)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;

    if (s.tcp)
    {
        // Stream send. Gather buffers, push as much as the send buffer accepts.
        size_t total_avail = 0;
        foreach (b; buffers)
            total_avail += b.length;

        size_t total_sent = 0;
        foreach (b; buffers)
        {
            if (b.length == 0) continue;
            size_t n = tcp_send_data(*_stack, s.tcp, cast(const(ubyte)[])b);
            total_sent += n;
            if (n < b.length)
                break;     // send buffer full; partial accept
        }
        if (bytes_sent)
            *bytes_sent = total_sent;
        if (total_sent == 0 && total_avail > 0)
            return SocketResult.would_block;
        return SocketResult.success;
    }

    if (!s.udp)
        return SocketResult.invalid_argument;

    InetAddress dst;
    if (addr)
    {
        if (addr.family != s.family)
            return SocketResult.invalid_argument;
        dst = *addr;
    }
    else if (s.udp.connected)
        dst = udp_remote(s.udp);
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

    if (s.udp.local_port == 0 && !udp_bind(s.udp, udp_local(s.udp)))
        return SocketResult.failure;
    if (!udp_send(*_stack, s.udp, dst, gather[0 .. total]))
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
        size_t n = tcp_recv_data(s.tcp, cast(ubyte[])buffer);
        if (bytes_received)
            *bytes_received = n;
        if (from)
            *from = s.tcp.remote;
        if (n == 0)
        {
            // EOF on closed connection vs just-no-data-yet:
            if (s.tcp.fin_seen ||
                s.tcp.state == TcpState.close_wait ||
                s.tcp.state == TcpState.last_ack ||
                s.tcp.state == TcpState.closed)
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
        *from = d.src;

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
            if (fd.request_events & PollEvents.read)
            {
                bool readable = s.tcp.recv_buf.length > 0
                              || (s.tcp.is_listener && s.tcp.accept_queue.length > 0)
                              || s.tcp.fin_seen
                              || s.tcp.state == TcpState.close_wait
                              || s.tcp.state == TcpState.closed;
                if (readable)
                    fd.return_events |= PollEvents.read;
            }
            if (fd.request_events & PollEvents.write)
            {
                if (s.tcp.state == TcpState.established &&
                    s.tcp.send_buf.length < TcpSendBufSize)
                    fd.return_events |= PollEvents.write;
            }
            if (s.tcp.error_event || s.tcp.state == TcpState.closed)
                fd.return_events |= PollEvents.hangup;
        }
        if (fd.return_events != PollEvents.none)
            ++num_ready;
    }
    // The IP stack runs on the same main loop as `poll` callers, so we never
    // block here -- the timeout is a hint we ignore. Callers iterate.
    return SocketResult.success;
}

SocketResult c_set_option(Socket socket, SocketOption opt, const(void)* value, size_t size)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    switch (opt)
    {
        case SocketOption.non_blocking:
            if (size != 1)
                return SocketResult.invalid_argument;
            s.non_blocking = *cast(ubyte*)value != 0;
            return SocketResult.success;
        case SocketOption.multicast:
        {
            if (!s.udp || size != MulticastGroup.sizeof)
                return SocketResult.invalid_argument;
            const MulticastGroup* group = cast(const(MulticastGroup)*)value;
            return udp_join(*_stack, s.udp, group.address, group.iface) ? SocketResult.success : SocketResult.invalid_argument;
        }
        static if (has_ipv6)
        {
            case SocketOption.multicast6:
            {
                if (!s.udp || size != MulticastGroup6.sizeof)
                    return SocketResult.invalid_argument;
                const MulticastGroup6* group = cast(const(MulticastGroup6)*)value;
                if (group.scope_id)
                {
                    BaseInterface iface = interface_for_scope(group.scope_id);
                    return iface && udp_join6(*_stack, s.udp, group.address, iface) ? SocketResult.success : SocketResult.invalid_argument;
                }
                // no zone: every link carrying an IPv6 address, as a native stack's default-interface join does for one
                bool joined;
                foreach (address; Collection!IPv6Address().values)
                    joined |= udp_join6(*_stack, s.udp, group.address, address.iface);
                return joined ? SocketResult.success : SocketResult.invalid_argument;
            }
            case SocketOption.multicast_interface6:
            {
                if (!s.udp || size != uint.sizeof)
                    return SocketResult.invalid_argument;
                BaseInterface iface = interface_for_scope(*cast(const(uint)*)value);
                if (!iface)
                    return SocketResult.invalid_argument;
                s.udp.outbound_iface6 = iface;
                return SocketResult.success;
            }
        }
        default:
            return SocketResult.success;    // not yet meaningful; a no-op rather than a failure
    }
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
    if (s.tcp && s.tcp.remote.port != 0)
    {
        addr = s.tcp.remote;
        return SocketResult.success;
    }
    if (s.udp && s.udp.connected)
    {
        addr = udp_remote(s.udp);
        return SocketResult.success;
    }
    return SocketResult.invalid_argument;
}

SocketResult c_get_socket_name(Socket socket, out InetAddress addr)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (s.tcp)
    {
        addr = s.tcp.local;
        return SocketResult.success;
    }
    if (s.udp)
    {
        addr = udp_local(s.udp);
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
