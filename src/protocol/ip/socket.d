module protocol.ip.socket;

version (SocketCallbacks):

import urt.array;
import urt.inet;
import urt.map;
import urt.mem.alloc : defaultAllocator;
import urt.socket;
import urt.time;

import protocol.ip.stack;
import protocol.ip.udp;

nothrow @nogc:


// Install our SocketBackend so urt.socket calls route through this stack.
// `stack` is held by reference for the lifetime of the program.
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
    // TcpPcb*    tcp;     // future
    // RawPcb*    raw;     // future
}

__gshared SocketBackend _backend;
__gshared Map!(int, Slot*) _slots;
__gshared int _next_handle = 1;
__gshared ushort _next_ephemeral = 49152;
__gshared IPStack* _stack;


Slot* lookup(Socket s)
{
    int h = s.raw_handle;
    if (auto p = h in _slots)
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
    if (af != AddressFamily.ipv4)
        return SocketResult.invalid_argument;     // v6 later
    if (type != SocketType.datagram)
        return SocketResult.invalid_argument;     // TCP / raw later

    Slot* s = defaultAllocator().allocT!Slot();
    s.sock_type = type;
    s.family    = af;
    s.udp       = defaultAllocator().allocT!UdpPcb();
    udp_register(s.udp);

    int h = _next_handle++;
    s.udp.handle = h;
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
    int h = socket.raw_handle;
    _slots.remove(h);
    defaultAllocator().freeT(s);
    return SocketResult.success;
}

SocketResult c_bind(Socket socket, ref const InetAddress address)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (!s.udp)
        return SocketResult.invalid_argument;
    if (address.family != AddressFamily.ipv4)
        return SocketResult.invalid_argument;

    s.udp.local_addr = address._a.ipv4.addr;
    ushort port = address._a.ipv4.port;
    if (port == 0)
        port = allocate_ephemeral();
    s.udp.local_port = port;
    return SocketResult.success;
}

SocketResult c_listen(Socket socket, uint backlog)
    => SocketResult.invalid_argument;     // TCP-only

SocketResult c_connect(Socket socket, ref const InetAddress address)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
    if (!s.udp)
        return SocketResult.invalid_argument;
    if (address.family != AddressFamily.ipv4)
        return SocketResult.invalid_argument;

    if (s.udp.local_port == 0)
        s.udp.local_port = allocate_ephemeral();

    s.udp.remote_addr = address._a.ipv4.addr;
    s.udp.remote_port = address._a.ipv4.port;
    s.udp.connected   = true;
    return SocketResult.success;
}

SocketResult c_accept(Socket socket, out Socket connection, InetAddress* remote)
    => SocketResult.invalid_argument;     // TCP-only

SocketResult c_shutdown(Socket socket, SocketShutdownMode how)
    => SocketResult.success;              // no-op for UDP

SocketResult c_sendmsg(Socket socket, const(InetAddress)* addr, MsgFlags flags,
                       const(void[])[] buffers, size_t* bytes_sent)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
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

    if (!udp_output(*_stack, s.udp.local_addr, s.udp.local_port,
                    dst_addr, dst_port, gather[0 .. total]))
        return SocketResult.failure;

    if (bytes_sent)
        *bytes_sent = total;
    return SocketResult.success;
}

SocketResult c_recv(Socket socket, void[] buffer, MsgFlags flags, size_t* bytes_received)
    => c_recvfrom(socket, buffer, flags, null, bytes_received);

SocketResult c_recvfrom(Socket socket, void[] buffer, MsgFlags flags,
                        InetAddress* from, size_t* bytes_received)
{
    auto s = lookup(socket);
    if (!s)
        return SocketResult.invalid_socket;
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
    bytes = (s.udp && s.udp.recv_queue.length > 0) ? s.udp.recv_queue[0].data.length : 0;
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
    if (opt == SocketOption.non_blocking)
    {
        if (size < 1)
            return SocketResult.invalid_argument;
        s.non_blocking = *cast(const ubyte*)value != 0;
    }
    // Most options not yet meaningful; treat as no-op rather than failing.
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

SocketResult c_get_address_info(const(char)[] node, const(char)[] service,
                                AddressInfo* info, AddressInfoResolver* resolver)
    => SocketResult.failure;     // TODO: hook into DNS module

bool c_next_address(AddressInfoResolver* resolver, out AddressInfo info)
    => false;

void c_free_address_info(AddressInfoResolver* resolver) {}
