module urt.socket;

public import urt.endian;
public import urt.inet;
public import urt.mem;
public import urt.result;
public import urt.time;

version (Windows)
{
    // TODO: this is in core.sys.windows.winsock2; why do I need it here?
    pragma(lib, "ws2_32");

    import core.sys.windows.windows;
    import core.sys.windows.winsock2 :
        _bind = bind, _listen = listen, _connect = connect, _accept = accept,
        _send = send, _sendto = sendto, _recv = recv, _recvfrom = recvfrom,
        _shutdown = shutdown;

    version = HasIPv6;

    alias SocketHandle = SOCKET;
}
else version (Posix)
{
    import core.stdc.errno;
    import core.sys.posix.fcntl;
    import core.sys.posix.poll;
    import core.sys.posix.unistd : close, gethostname;
    import urt.internal.os; // use ImportC to import system C headers...
    import core.sys.posix.netinet.in_ : sockaddr_in6;

    alias _bind = urt.internal.os.bind, _listen = urt.internal.os.listen, _connect = urt.internal.os.connect,
        _accept = urt.internal.os.accept, _send = urt.internal.os.send, _sendto = urt.internal.os.sendto,
        _recv = urt.internal.os.recv, _recvfrom = urt.internal.os.recvfrom, _shutdown = urt.internal.os.shutdown;
    alias _poll = core.sys.posix.poll.poll;

    version = HasUnixSocket;
    version = HasIPv6;

    alias SocketHandle = int;
    enum INVALID_SOCKET = -1;

    // for some reason these don't get scraped from the C headers...
    enum AF_UNSPEC = 0;
    enum AF_UNIX = 1;   // Unix domain sockets
    enum AF_INET = 2;   // Internet IP Protocol
    enum AF_IPX = 4;    // Novell IPX
    enum AF_BRIDGE = 7;     // Multiprotocol bridge
    enum AF_INET6 = 10;     // IP version 6
}
else
    static assert(false, "Platform not supported");

nothrow @nogc:


enum SocketResult
{
    Success,
    Failure,
    WouldBlock,
    NoBuffer,
    NetworkDown,
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    ConnectionClosed,
    Interrupted,
    InvalidSocket,
    InvalidArgument,
}

enum SocketType : byte
{
    Unknown = -1,
    Stream = 0,
    Datagram,
    Raw,
}

enum Protocol : byte
{
    Unknown = -1,
    TCP = 0,
    UDP,
    IP,
    ICMP,
    Raw,
}

enum SocketShutdownMode : ubyte
{
    Read,
    Write,
    ReadWrite
}

enum SocketOption : ubyte
{
    // not traditionally a 'socket option', but this is way more convenient
    NonBlocking,

    // Socket options
    KeepAlive,
    Linger,
    RandomizePort,
    SendBufferLength,
    RecvBufferLength,
    ReuseAddress,
    NoSigPipe,
    Error,

    // IP options
    FirstIpOption,
    Multicast = FirstIpOption,
    MulticastLoopback,
    MulticastTTL,

    // IPv6 options
    FirstIpv6Option,

    // ICMP options
    FirstIcmpOption = FirstIpv6Option,

    // ICMPv6 options
    FirstIcmpv6Option = FirstIcmpOption,

    // TCP options
    FirstTcpOption = FirstIcmpv6Option,
    TCP_KeepIdle = FirstTcpOption,
    TCP_KeepIntvl,
    TCP_KeepCnt,
    TCP_KeepAlive, // Apple: similar to KeepIdle
    TCP_NoDelay,


    // UDP options
    FirstUdpOption,
}

enum MsgFlags : ubyte
{
    None    = 0,
    OOB     = 1 << 0,
    Peek    = 1 << 1,
    Confirm = 1 << 2,
    NoSig   = 1 << 3,
    //...
}

enum AddressInfoFlags : ubyte
{
    None        = 0,
    Passive     = 1 << 0,
    CanonName   = 1 << 1,
    NumericHost = 1 << 2,
    NumericServ = 1 << 3,
    All         = 1 << 4,
    AddrConfig  = 1 << 5,
    V4Mapped    = 1 << 6,
    FQDN        = 1 << 7,
}

enum PollEvents : ubyte
{
    None    = 0,
    Read    = 1 << 0,
    Write   = 1 << 1,
    Error   = 1 << 2,
    HangUp  = 1 << 3,
    Invalid = 1 << 4,
}


struct Socket
{
nothrow @nogc:
    enum Socket invalid = Socket();

    bool opCast(T : bool)() const => handle != invalid.handle;

    void opAssign(typeof(null)) { handle = invalid.handle; }

private:
    SocketHandle handle = INVALID_SOCKET;
}


Result create_socket(AddressFamily af, SocketType type, Protocol proto, out Socket socket)
{
    version (HasUnixSocket) {} else
        assert(af != AddressFamily.Unix, "Unix sockets not supported on this platform!");

    socket.handle = .socket(s_addressFamily[af], s_socketType[type], s_protocol[proto]);
    if (socket == Socket.invalid)
        return socket_getlasterror();
    return Result.Success;
}

Result close(Socket socket)
{
    version (Windows)
        int result = closesocket(socket.handle);
    else version (Posix)
        int result = close(socket.handle);
    else
        assert(false, "Not implemented!");
    if (result < 0)
        return socket_getlasterror();

//    {
//        LockGuard<SharedMutex> lock(s_noSignalMut);
//        s_noSignal.Erase(socket);
//    }

    return Result.Success;
}

Result shutdown(Socket socket, SocketShutdownMode how)
{
    int t = int(how);
    switch (how)
    {
        version (Windows)
        {
            case SocketShutdownMode.Read:       t = SD_RECEIVE; break;
            case SocketShutdownMode.Write:      t = SD_SEND;    break;
            case SocketShutdownMode.ReadWrite:  t = SD_BOTH;    break;
        }
        else version (Posix)
        {
            case SocketShutdownMode.Read:       t = SHUT_RD;    break;
            case SocketShutdownMode.Write:      t = SHUT_WR;    break;
            case SocketShutdownMode.ReadWrite:  t = SHUT_RDWR;  break;
        }
        default:
            assert(false, "Invalid `how`");
    }

    if (_shutdown(socket.handle, t) < 0)
        return socket_getlasterror();
    return Result.Success;
}

Result bind(Socket socket, ref const InetAddress address)
{
    ubyte[512] buffer = void;
    size_t addrLen;
    sockaddr* sockAddr = make_sockaddr(address, buffer, addrLen);
    assert(sockAddr, "Invalid socket address");

    if (_bind(socket.handle, sockAddr, cast(int)addrLen) < 0)
        return socket_getlasterror();
    return Result.Success;
}

Result listen(Socket socket, uint backlog = -1)
{
    if (_listen(socket.handle, int(backlog & 0x7FFFFFFF)) < 0)
        return socket_getlasterror();
    return Result.Success;
}

Result connect(Socket socket, ref const InetAddress address)
{
    ubyte[512] buffer = void;
    size_t addrLen;
    sockaddr* sockAddr = make_sockaddr(address, buffer, addrLen);
    assert(sockAddr, "Invalid socket address");

    if (_connect(socket.handle, sockAddr, cast(int)addrLen) < 0)
        return socket_getlasterror();
    return Result.Success;
}

Result accept(Socket socket, out Socket connection, InetAddress* connectingSocketAddress = null)
{
    char[sockaddr_storage.sizeof] buffer = void;
    sockaddr* addr = cast(sockaddr*)buffer.ptr;
    socklen_t size = buffer.sizeof;

    connection.handle = _accept(socket.handle, addr, &size);
    if (connection == Socket.invalid)
        return socket_getlasterror();
    else if (connectingSocketAddress)
        *connectingSocketAddress = make_InetAddress(addr);
    return Result.Success;
}

Result send(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.None, size_t* bytesSent = null)
{
    Result r = Result.Success;

    ptrdiff_t sent = _send(socket.handle, message.ptr, cast(int)message.length, map_message_flags(flags));
    if (sent < 0)
    {
        r = socket_getlasterror();
        sent = 0;
    }
    if (bytesSent)
        *bytesSent = sent;
    return r;
}

Result sendto(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.None, const InetAddress* address = null, size_t* bytesSent = null)
{
    ubyte[sockaddr_storage.sizeof] tmp = void;
    size_t addrLen;
    sockaddr* sockAddr = null;
    if (address)
    {
        sockAddr = make_sockaddr(*address, tmp, addrLen);
        assert(sockAddr, "Invalid socket address");
    }

    Result r = Result.Success;
    ptrdiff_t sent = _sendto(socket.handle, message.ptr, cast(int)message.length, map_message_flags(flags), sockAddr, cast(int)addrLen);
    if (sent < 0)
    {
        r = socket_getlasterror();
        sent = 0;
    }
    if (bytesSent)
        *bytesSent = sent;
    return r;
}

Result recv(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.None, size_t* bytesReceived)
{
    Result r = Result.Success;
    ptrdiff_t bytes = _recv(socket.handle, buffer.ptr, cast(int)buffer.length, map_message_flags(flags));
    if (bytes > 0)
        *bytesReceived = bytes;
    else
    {
        *bytesReceived = 0;
        if (bytes == 0)
        {
            // if we request 0 bytes, we receive 0 bytes, and it doesn't imply end-of-stream
            if (buffer.length > 0)
            {
                // a graceful disconnection occurred
                // TODO: !!!
                r = ConnectionClosedResult;
//                r = InternalResult(InternalCode.RemoteDisconnected);
            }
        }
        else
        {
            Result error = socket_getlasterror();
            // TODO: Do we want a better way to distinguish between receiving a 0-length packet vs no-data (which looks like an error)?
            //       Is a zero-length packet possible to detect in TCP streams? Makes more sense for recvfrom...
            SocketResult sr = get_SocketResult(error);
            if (sr != SocketResult.WouldBlock)
                r = error;
        }
    }
    return r;
}

Result recvfrom(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.None, InetAddress* senderAddress = null, size_t* bytesReceived)
{
    char[sockaddr_storage.sizeof] addrBuffer = void;
    sockaddr* addr = cast(sockaddr*)addrBuffer.ptr;
    socklen_t size = addrBuffer.sizeof;

    Result r = Result.Success;
    ptrdiff_t bytes = _recvfrom(socket.handle, buffer.ptr, cast(int)buffer.length, map_message_flags(flags), addr, &size);
    if (bytes >= 0)
        *bytesReceived = bytes;
    else
    {
        *bytesReceived = 0;

        Result error = socket_getlasterror();
        SocketResult sockRes = get_SocketResult(error);
        if (sockRes != SocketResult.NoBuffer && // buffers full
            sockRes != SocketResult.ConnectionRefused && // posix error
            sockRes != SocketResult.ConnectionReset) // !!! windows may report this error, but it appears to mean something different on posix
            r = error;
    }
    if (r && senderAddress)
        *senderAddress = make_InetAddress(addr);
    return r;
}

Result set_socket_option(Socket socket, SocketOption option, const(void)* optval, size_t optlen)
{
    Result r = Result.Success;

    // check the option appears to be the proper datatype
    const OptInfo* optInfo = &s_socketOptions[option];
    assert(optInfo.rtType != OptType.Unsupported, "Socket option is unsupported on this platform!");
    assert(optlen == s_optTypeRtSize[optInfo.rtType], "Socket option has incorrect payload size!");

    // special case for non-blocking
    // this is not strictly a 'socket option', but this rather simplifies our API
    if (option == SocketOption.NonBlocking)
    {
        bool value = *cast(const(bool)*)optval;
        version (Windows)
        {
            uint opt = value ? 1 : 0;
            r.systemCode = ioctlsocket(socket.handle, FIONBIO, &opt);
        }
        else version (Posix)
        {
            int flags = fcntl(socket.handle, F_GETFL, 0);
            r.systemCode = fcntl(socket.handle, F_SETFL, value ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK));
        }
        else
            assert(false, "Not implemented!");
        return r;
    }

//    // Convenience for socket-level no signal since some platforms only support message flag
//    if (option == SocketOption.NoSigPipe)
//    {
//        LockGuard!SharedMutex lock(s_noSignalMut);
//        s_noSignal.InsertOrAssign(socket.handle, *cast(const(bool)*)optval);
//
//        if (optInfo.platformType == OptType.Unsupported)
//            return r;
//    }

    // determine the option 'level'
    OptLevel level = get_optlevel(option);
    version (HasIPv6) {} else
        assert(level != OptLevel.IPv6 && level != OptLevel.ICMPv6, "Platform does not support IPv6!");

    // platforms don't all agree on option data formats!
    const(void)* arg = optval;
    int itmp = void;
    linger ling = void;
    if (optInfo.rtType != optInfo.platformType)
    {
        switch (optInfo.rtType)
        {
            // TODO: there are more converstions necessary as options/platforms are added
            case OptType.Bool:
            {
                const bool value = *cast(const(bool)*)optval;
                switch (optInfo.platformType)
                {
                    case OptType.Int:
                        itmp = value ? 1 : 0;
                        arg = &itmp;
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            case OptType.Duration:
            {
                const Duration value = *cast(const(Duration)*)optval;
                switch (optInfo.platformType)
                {
                    case OptType.Seconds:
                        itmp = cast(int)value.as!"seconds";
                        arg = &itmp;
                        break;
                    case OptType.Milliseconds:
                        itmp = cast(int)value.as!"msecs";
                        arg = &itmp;
                        break;
                    case OptType.Linger:
                        itmp = cast(int)value.as!"seconds";
                        ling = linger(!!itmp, cast(ushort)itmp);
                        arg = &ling;
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            default:
                assert(false, "Unexpected!");
        }
    }

    // set the option
    r.systemCode = setsockopt(socket.handle, s_sockOptLevel[level], optInfo.option, cast(const(char)*)arg, s_optTypePlatformSize[optInfo.platformType]);

    return r;
}

Result set_socket_option(Socket socket, SocketOption option, bool value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Bool, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, bool.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, int value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Int, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, int.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, Duration value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Duration, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, Duration.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, IPAddr value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.INAddress, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, IPAddr.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, ref MulticastGroup value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.MulticastGroup, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, MulticastGroup.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, void* output, size_t outputlen)
{
    Result r = Result.Success;

    // check the option appears to be the proper datatype
    const OptInfo* optInfo = &s_socketOptions[option];
    assert(optInfo.rtType != OptType.Unsupported, "Socket option is unsupported on this platform!");
    assert(outputlen == s_optTypeRtSize[optInfo.rtType], "Socket option has incorrect payload size!");

    assert(option != SocketOption.NonBlocking, "Socket option NonBlocking cannot be get");

    // determine the option 'level'
    OptLevel level = get_optlevel(option);
    version (HasIPv6)
        assert(level != OptLevel.IPv6 && level != OptLevel.ICMPv6, "Platform does not support IPv6!");

    // platforms don't all agree on option data formats!
    void* arg = output;
    int itmp = 0;
    linger ling = { 0, 0 };
    if (optInfo.rtType != optInfo.platformType)
    {
        switch (optInfo.platformType)
        {
            case OptType.Int:
            case OptType.Seconds:
            case OptType.Milliseconds:
            {
                arg = &itmp;
                break;
            }
            case OptType.Linger:
            {
                arg = &ling;
                break;
            }
            default:
                assert(false, "Unexpected!");
        }
    }

    socklen_t writtenLen = s_optTypePlatformSize[optInfo.platformType];
    // get the option
    r.systemCode = getsockopt(socket.handle, s_sockOptLevel[level], optInfo.option, cast(char*)arg, &writtenLen);

    if (optInfo.rtType != optInfo.platformType)
    {
        switch (optInfo.rtType)
        {
            // TODO: there are more converstions necessary as options/platforms are added
            case OptType.Bool:
            {
                bool* value = cast(bool*)output;
                switch (optInfo.platformType)
                {
                    case OptType.Int:
                        *value = !!itmp;
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            case OptType.Duration:
            {
                Duration* value = cast(Duration*)output;
                switch (optInfo.platformType)
                {
                    case OptType.Seconds:
                        *value = seconds(itmp);
                        break;
                    case OptType.Milliseconds:
                        *value = msecs(itmp);
                        break;
                    case OptType.Linger:
                        *value = seconds(ling.l_linger);
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            default:
                assert(false, "Unexpected!");
        }
    }

    assert(optInfo.rtType != OptType.INAddress, "TODO: uncomment this block... for some reason, this block causes DMD to do a bad codegen!");
/+
    // Options expected in network-byte order
    switch (optInfo.rtType)
    {
        case OptType.INAddress:
        {
            IPAddr* addr = cast(IPAddr*)output;
            addr.address = loadBigEndian(&addr.address());
            break;
        }
        default:
            break;
    }
+/
    return r;
}

Result get_socket_option(Socket socket, SocketOption option, out bool output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Bool, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, bool.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, out int output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Int, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, int.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, out Duration output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Duration, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, Duration.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, out IPAddr output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.INAddress, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, IPAddr.sizeof);
}

Result set_keepalive(Socket socket, bool enable, Duration keepIdle, Duration keepInterval, int keepCount)
{
    version (Windows)
    {
        tcp_keepalive alive;
        alive.onoff = enable ? 1 : 0;
        alive.keepalivetime = cast(uint)keepIdle.as!"msecs";
        alive.keepaliveinterval = cast(uint)keepInterval.as!"msecs";

        uint bytesReturned = 0;
        if (WSAIoctl(socket.handle, SIO_KEEPALIVE_VALS, &alive, alive.sizeof, null, 0, &bytesReturned, null, null) < 0)
            return socket_getlasterror();
        return Result.Success;
    }
    else
    {
        Result res = set_socket_option(socket, SocketOption.KeepAlive, enable);
        if (!enable || res != Result.Success)
            return res;
        version (Darwin)
        {
            // OSX doesn't support setting keep-alive interval and probe count.
            return set_socket_option(socket, SocketOption.TCP_KeepAlive, keepIdle);
        }
        else
        {
            res = set_socket_option(socket, SocketOption.TCP_KeepIdle, keepIdle);
            if (res != Result.Success)
                return res;
            res = set_socket_option(socket, SocketOption.TCP_KeepIntvl, keepInterval);
            if (res != Result.Success)
                return res;
            return set_socket_option(socket, SocketOption.TCP_KeepCnt, keepCount);
        }
    }
}

Result get_peer_name(Socket socket, out InetAddress name)
{
    char[sockaddr_storage.sizeof] buffer;
    sockaddr* addr = cast(sockaddr*)buffer;
    socklen_t bufferLen = buffer.sizeof;

    int fail = getpeername(socket.handle, addr, &bufferLen);
    if (fail == 0)
        name = make_InetAddress(addr);
    else
        return socket_getlasterror();
    return Result.Success;
}

Result get_socket_name(Socket socket, out InetAddress name)
{
    char[sockaddr_storage.sizeof] buffer;
    sockaddr* addr = cast(sockaddr*)buffer;
    socklen_t bufferLen = buffer.sizeof;

    int fail = getsockname(socket.handle, addr, &bufferLen);
    if (fail == 0)
        name = make_InetAddress(addr);
    else
        return socket_getlasterror();
    return Result.Success;
}

Result get_hostname(char* name, size_t len)
{
    int fail = gethostname(name, cast(int)len);
    if (fail)
        return socket_getlasterror();
    return Result.Success;
}

Result get_address_info(const(char)[] nodeName, const(char)[] service, AddressInfo* hints, out AddressInfoResolver result)
{
    import urt.array : findFirst;
    import urt.mem.temp : tstringz;

    size_t colon = nodeName.findFirst(':');
    if (colon < nodeName.length)
    {
        if (!service)
            service = nodeName[colon + 1..$];
        nodeName = nodeName[0 .. colon];
    }

    addrinfo tmpHints;
    if (hints)
    {
        // translate hints...
        tmpHints.ai_flags = map_addrinfo_flags(hints.flags);
        tmpHints.ai_family = s_addressFamily[hints.family];
        tmpHints.ai_socktype = s_socketType[hints.sockType];
        tmpHints.ai_protocol = s_protocol[hints.protocol];
        tmpHints.ai_canonname = cast(char*)hints.canonName; // HAX!
        tmpHints.ai_addrlen = 0;
        tmpHints.ai_addr = null;
        tmpHints.ai_next = null;
    }

    addrinfo* res;
    int err = getaddrinfo(nodeName.tstringz, service ? service.tstringz : null, hints ? &tmpHints : null, &res);
    if (err != 0)
        return Result(err);

    // if it was used previously
    if (result.m_internal[0])
        freeaddrinfo(cast(addrinfo*)result.m_internal[0]);

    result.m_internal[0] = res;
    result.m_internal[1] = res;

    return Result.Success;
}

Result poll(PollFd[] pollFds, Duration timeout, out uint numEvents)
{
    enum MaxFds = 512;
    assert(pollFds.length <= MaxFds, "Too many fds!");
    version (Windows)
        WSAPOLLFD[MaxFds] fds;
    else version (Posix)
        pollfd[MaxFds] fds;
    for (size_t i = 0; i < pollFds.length; ++i)
    {
        fds[i].fd = pollFds[i].socket.handle;
        fds[i].revents = 0;
        fds[i].events = ((pollFds[i].requestEvents & PollEvents.Read)  ? POLLRDNORM : 0) |
                        ((pollFds[i].requestEvents & PollEvents.Write) ? POLLWRNORM : 0);
    }
    version (Windows)
        int r = WSAPoll(fds.ptr, cast(uint)pollFds.length, timeout.ticks < 0 ? -1 : cast(int)timeout.as!"msecs");
    else version (Posix)
        int r = _poll(fds.ptr, pollFds.length, timeout.ticks < 0 ? -1 : cast(int)timeout.as!"msecs");
    else
        assert(false, "Not implemented!");
    if (r < 0)
    {
        numEvents = 0;
        return socket_getlasterror();
    }
    numEvents = r;
    for (size_t i = 0; i < pollFds.length; ++i)
    {
        pollFds[i].returnEvents = cast(PollEvents)(
                                    ((fds[i].revents & POLLRDNORM) ? PollEvents.Read    : 0) |
                                    ((fds[i].revents & POLLWRNORM) ? PollEvents.Write   : 0) |
                                    ((fds[i].revents & POLLERR)    ? PollEvents.Error   : 0) |
                                    ((fds[i].revents & POLLHUP)    ? PollEvents.HangUp  : 0) |
                                    ((fds[i].revents & POLLNVAL)   ? PollEvents.Invalid : 0));
    }
    return Result.Success;
}

Result poll(ref PollFd pollFd, Duration timeout, out uint numEvents)
{
    return poll((&pollFd)[0..1], timeout, numEvents);
}

struct AddressInfo
{
    AddressInfoFlags flags;
    AddressFamily family;
    SocketType sockType;
    Protocol protocol;
    const(char)* canonName; // Note: this memory is valid until the next call to `next_address`, or until `AddressInfoResolver` is destroyed
    InetAddress address;
}

struct AddressInfoResolver
{
nothrow @nogc:

    // TODO: this should be a MOVE ONLY construction
    // @disable the COPY constructor!
    this(AddressInfoResolver rh)
    {
        m_internal[] = rh.m_internal[];
        rh.m_internal[0] = null;
        rh.m_internal[1] = null;
    }

    ~this()
    {
        if (m_internal[0])
            freeaddrinfo(cast(addrinfo*)m_internal[0]);
    }

    // TODO: this should be a MOVE ONLY assignment!
    // @disable the COPY assignment!
    ref AddressInfoResolver opAssign(AddressInfoResolver rh)
    {
//        if (&rh == &this)
//            return this;
        this.destroy();
        m_internal[0] = rh.m_internal[0];
        m_internal[1] = rh.m_internal[1];
        rh.m_internal[0] = null;
        rh.m_internal[1] = null;
        return this;
    }

    bool next_address(out AddressInfo addressInfo)
    {
        if (!m_internal[1])
            return false;

        addrinfo* info = cast(addrinfo*)(m_internal[1]);
        m_internal[1] = info.ai_next;

        addressInfo.flags = AddressInfoFlags.None; // info.ai_flags is only used for 'hints'
        addressInfo.family = map_address_family(info.ai_family);
        addressInfo.sockType = cast(int)info.ai_socktype ? map_socket_type(info.ai_socktype) : SocketType.Unknown;
        addressInfo.protocol = map_protocol(info.ai_protocol);
        addressInfo.canonName = info.ai_canonname;
        addressInfo.address = make_InetAddress(info.ai_addr);
        return true;
    }

    void*[2] m_internal = [ null, null ];
}

struct PollFd
{
    Socket socket;
    PollEvents requestEvents;
    PollEvents returnEvents;
    void* userData;
}



Result socket_getlasterror()
{
    version (Windows)
        return Result(WSAGetLastError());
    else
        return Result(errno);
}

Result get_socket_error(Socket socket)
{
    Result r;
    socklen_t optlen = r.systemCode.sizeof;
    int callResult = getsockopt(socket.handle, SOL_SOCKET, SO_ERROR, cast(char*)&r.systemCode, &optlen);
    if (callResult)
        r.systemCode = callResult;
    return r;
}

// TODO: !!!
enum Result ConnectionClosedResult = Result(-12345); 
SocketResult get_SocketResult(Result result)
{
    if (result)
        return SocketResult.Success;
    if (result.systemCode == ConnectionClosedResult.systemCode)
        return SocketResult.ConnectionClosed;
    version (Windows)
    {
        if (result.systemCode == WSAEWOULDBLOCK)
            return SocketResult.WouldBlock;
        if (result.systemCode == WSAEINPROGRESS)
            return SocketResult.WouldBlock;
        if (result.systemCode == WSAENOBUFS)
            return SocketResult.NoBuffer;
        if (result.systemCode == WSAENETDOWN)
            return SocketResult.NetworkDown;
        if (result.systemCode == WSAECONNREFUSED)
            return SocketResult.ConnectionRefused;
        if (result.systemCode == WSAECONNRESET)
            return SocketResult.ConnectionReset;
        if (result.systemCode == WSAEINTR)
            return SocketResult.Interrupted;
        if (result.systemCode == WSAENOTSOCK)
            return SocketResult.InvalidSocket;
        if (result.systemCode == WSAEINVAL)
            return SocketResult.InvalidArgument;
    }
    else version (Posix)
    {
        static if (EAGAIN != EWOULDBLOCK)
            if (result.systemCode == EAGAIN)
                return SocketResult.WouldBlock;
        if (result.systemCode == EWOULDBLOCK)
            return SocketResult.WouldBlock;
        if (result.systemCode == EINPROGRESS)
            return SocketResult.WouldBlock;
        if (result.systemCode == ENOMEM)
            return SocketResult.NoBuffer;
        if (result.systemCode == ENETDOWN)
            return SocketResult.NetworkDown;
        if (result.systemCode == ECONNREFUSED)
            return SocketResult.ConnectionRefused;
        if (result.systemCode == ECONNRESET)
            return SocketResult.ConnectionReset;
        if (result.systemCode == EINTR)
            return SocketResult.Interrupted;
        if (result.systemCode == EINVAL)
            return SocketResult.InvalidArgument;
    }
    return SocketResult.Failure;
}


sockaddr* make_sockaddr(ref const InetAddress address, ubyte[] buffer, out size_t addrLen)
{
    sockaddr* sockAddr = cast(sockaddr*)buffer.ptr;

    switch (address.family)
    {
        case AddressFamily.IPv4:
        {
            addrLen = sockaddr_in.sizeof;
            if (buffer.length < sockaddr_in.sizeof)
                return null;

            sockaddr_in* ain = cast(sockaddr_in*)sockAddr;
            memzero(ain, sockaddr_in.sizeof);
            ain.sin_family = s_addressFamily[AddressFamily.IPv4];
            version (Windows)
            {
                ain.sin_addr.S_un.S_un_b.s_b1 = address._a.ipv4.addr.b[0];
                ain.sin_addr.S_un.S_un_b.s_b2 = address._a.ipv4.addr.b[1];
                ain.sin_addr.S_un.S_un_b.s_b3 = address._a.ipv4.addr.b[2];
                ain.sin_addr.S_un.S_un_b.s_b4 = address._a.ipv4.addr.b[3];
            }
            else version (Posix)
                ain.sin_addr.s_addr = address._a.ipv4.addr.address;
            else
                assert(false, "Not implemented!");
            storeBigEndian(&ain.sin_port, ushort(address._a.ipv4.port));
            break;
        }
        case AddressFamily.IPv6:
        {
            version (HasIPv6)
            {
                addrLen = sockaddr_in6.sizeof;
                if (buffer.length < sockaddr_in6.sizeof)
                    return null;

                sockaddr_in6* ain6 = cast(sockaddr_in6*)sockAddr;
                memzero(ain6, sockaddr_in6.sizeof);
                ain6.sin6_family = s_addressFamily[AddressFamily.IPv6];
                storeBigEndian(&ain6.sin6_port, cast(ushort)address._a.ipv6.port);
                storeBigEndian(cast(uint*)&ain6.sin6_flowinfo, address._a.ipv6.flowInfo);
                storeBigEndian(cast(uint*)&ain6.sin6_scope_id, address._a.ipv6.scopeId);
                for (int a = 0; a < 8; ++a)
                {
                    version (Windows)
                        storeBigEndian(&ain6.sin6_addr.in6_u.u6_addr16[a], address._a.ipv6.addr.s[a]);
                    else version (Posix)
                        storeBigEndian(cast(ushort*)ain6.sin6_addr.s6_addr + a, address._a.ipv6.addr.s[a]);
                    else
                        assert(false, "Not implemented!");
                }
            }
            else
                assert(false, "Platform does not support IPv6!");
            break;
        }
        case AddressFamily.Unix:
        {
//            version (HasUnixSocket)
//            {
//                addrLen = sockaddr_un.sizeof;
//                if (buffer.length < sockaddr_un.sizeof)
//                    return null;
//
//                sockaddr_un* aun = cast(sockaddr_un*)sockAddr;
//                memzero(aun, sockaddr_un.sizeof);
//                aun.sun_family = s_addressFamily[AddressFamily.Unix];
//
//                memcpy(aun.sun_path, address.un.path, UNIX_PATH_LEN);
//                break;
//            }
//            else
                assert(false, "Platform does not support unix sockets!");
        }
        default:
        {
            sockAddr = null;
            addrLen = 0;

            assert(false, "Unsupported address family");
            break;
        }
    }

    return sockAddr;
}

InetAddress make_InetAddress(const(sockaddr)* sockAddress)
{
    InetAddress addr;
    addr.family = map_address_family(sockAddress.sa_family);
    switch (addr.family)
    {
        case AddressFamily.IPv4:
        {
            const sockaddr_in* ain = cast(const(sockaddr_in)*)sockAddress;

            addr._a.ipv4.port = loadBigEndian(&ain.sin_port);
            version (Windows)
            {
                addr._a.ipv4.addr.b[0] = ain.sin_addr.S_un.S_un_b.s_b1;
                addr._a.ipv4.addr.b[1] = ain.sin_addr.S_un.S_un_b.s_b2;
                addr._a.ipv4.addr.b[2] = ain.sin_addr.S_un.S_un_b.s_b3;
                addr._a.ipv4.addr.b[3] = ain.sin_addr.S_un.S_un_b.s_b4;
            }
            else version (Posix)
                addr._a.ipv4.addr.address = ain.sin_addr.s_addr;
            else
                assert(false, "Not implemented!");
            break;
        }
        case AddressFamily.IPv6:
        {
            version (HasIPv6)
            {
                const sockaddr_in6* ain6 = cast(const(sockaddr_in6)*)sockAddress;

                addr._a.ipv6.port = loadBigEndian(&ain6.sin6_port);
                addr._a.ipv6.flowInfo = loadBigEndian(cast(const(uint)*)&ain6.sin6_flowinfo);
                addr._a.ipv6.scopeId = loadBigEndian(cast(const(uint)*)&ain6.sin6_scope_id);

                for (int a = 0; a < 8; ++a)
                {
                    version (Windows)
                        addr._a.ipv6.addr.s[a] = loadBigEndian(&ain6.sin6_addr.in6_u.u6_addr16[a]);
                    else version (Posix)
                        addr._a.ipv6.addr.s[a] = loadBigEndian(cast(const(ushort)*)ain6.sin6_addr.s6_addr + a);
                    else
                        assert(false, "Not implemented!");
                }
            }
            else
                assert(false, "Platform does not support IPv6!");
            break;
        }
        case AddressFamily.Unix:
        {
//            version (HasUnixSocket)
//            {
//                const sockaddr_un* aun = cast(const(sockaddr_un)*)sockAddress;
//
//                memcpy(addr.un.path, aun.sun_path, UNIX_PATH_LEN);
//                if (UNIX_PATH_LEN < UnixPathLen)
//                    memzero(addr.un.path + UNIX_PATH_LEN, addr.un.path.sizeof - UNIX_PATH_LEN);
//            }
//            else
                assert(false, "Platform does not support unix sockets!");
            break;
        }
        default:
            assert(false, "Unsupported address family.");
            break;
    }

    return addr;
}


private:

enum OptLevel : ubyte
{
    Socket,
    IP,
    IPv6,
    ICMP,
    ICMPv6,
    TCP,
    UDP,
}

enum OptType : ubyte
{
    Unsupported,
    Bool,
    Int,
    Seconds,
    Milliseconds,
    Duration,
    INAddress, // IPAddr + in_addr
    //IN6Address, // IPv6Addr + in6_addr
    MulticastGroup, // MulticastGroup + ip_mreq
    //MulticastGroupIPv6, // MulticastGroupIPv6? + ipv6_mreq
    Linger,
    // etc...
}


__gshared immutable ubyte[] s_optTypeRtSize = [ 0, bool.sizeof, int.sizeof, int.sizeof, int.sizeof, Duration.sizeof, IPAddr.sizeof, MulticastGroup.sizeof, 0 ];
__gshared immutable ubyte[] s_optTypePlatformSize = [ 0, 0, int.sizeof, int.sizeof, int.sizeof, 0, in_addr.sizeof, ip_mreq.sizeof, linger.sizeof ];


struct OptInfo
{
    short option;
    OptType rtType;
    OptType platformType;
}

__gshared immutable ushort[AddressFamily.max+1] s_addressFamily = [
    AF_UNSPEC,
    AF_UNIX,
    AF_INET,
    AF_INET6
];
AddressFamily map_address_family(int addressFamily)
{
    if (addressFamily == AF_INET)
        return AddressFamily.IPv4;
    else if (addressFamily == AF_INET6)
        return AddressFamily.IPv6;
    else if (addressFamily == AF_UNIX)
        return AddressFamily.Unix;
    else if (addressFamily == AF_UNSPEC)
        return AddressFamily.Unspecified;
    assert(false, "Unsupported address family");
    return AddressFamily.Unknown;
}

__gshared immutable int[SocketType.max+1] s_socketType = [
    SOCK_STREAM,
    SOCK_DGRAM,
    SOCK_RAW
];
SocketType map_socket_type(int sockType)
{
    if (sockType == SOCK_STREAM)
        return SocketType.Stream;
    else if (sockType == SOCK_DGRAM)
        return SocketType.Datagram;
    else if (sockType == SOCK_RAW)
        return SocketType.Raw;
    assert(false, "Unsupported socket type");
    return SocketType.Unknown;
}

__gshared immutable int[Protocol.max+1] s_protocol = [
    IPPROTO_TCP,
    IPPROTO_UDP,
    IPPROTO_IP,
    IPPROTO_ICMP,
    IPPROTO_RAW
];
Protocol map_protocol(int protocol)
{
    if (protocol == IPPROTO_TCP)
        return Protocol.TCP;
    else if (protocol == IPPROTO_UDP)
        return Protocol.UDP;
    else if (protocol == IPPROTO_IP)
        return Protocol.IP;
    else if (protocol == IPPROTO_ICMP)
        return Protocol.ICMP;
    else if (protocol == IPPROTO_RAW)
        return Protocol.Raw;
    assert(false, "Unsupported protocol");
    return Protocol.Unknown;
}

version (linux)
{
    __gshared immutable int[OptLevel.max+1] s_sockOptLevel = [
        SOL_SOCKET,
        SOL_IP,
        SOL_IPV6,
        IPPROTO_ICMP,
        SOL_ICMPV6,
        SOL_TCP,
        IPPROTO_UDP,
    ];
}
else
{
    __gshared immutable int[OptLevel.max+1] s_sockOptLevel = [
        SOL_SOCKET,
        IPPROTO_IP,
        IPPROTO_IPV6,
        IPPROTO_ICMP,
        58, // IPPROTO_ICMPV6,
        IPPROTO_TCP,
        IPPROTO_UDP,
    ];
}

version (Windows) // BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
{
    __gshared immutable OptInfo[SocketOption.max] s_socketOptions = [
        OptInfo( -1, OptType.Bool, OptType.Bool ), // NonBlocking
        OptInfo( SO_KEEPALIVE, OptType.Bool, OptType.Int ),
        OptInfo( SO_LINGER, OptType.Duration, OptType.Linger ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
//        OptInfo( SO_RANDOMIZE_PORT, OptType.Bool, OptType.Int ),  // TODO:  BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
        OptInfo( SO_SNDBUF, OptType.Int, OptType.Int ),
        OptInfo( SO_RCVBUF, OptType.Int, OptType.Int ),
        OptInfo( SO_REUSEADDR, OptType.Bool, OptType.Int ),
        OptInfo( -1, OptType.Bool, OptType.Unsupported ), // NoSignalPipe
        OptInfo( SO_ERROR, OptType.Int, OptType.Int ),
        OptInfo( IP_ADD_MEMBERSHIP, OptType.MulticastGroup, OptType.MulticastGroup ),
        OptInfo( IP_MULTICAST_LOOP, OptType.Bool, OptType.Int ),
        OptInfo( IP_MULTICAST_TTL, OptType.Int, OptType.Int ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( TCP_NODELAY, OptType.Bool, OptType.Int ),
    ];
}
else version (linux) // BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
{
    __gshared immutable OptInfo[SocketOption.max] s_socketOptions = [
        OptInfo( -1, OptType.Bool, OptType.Bool ), // NonBlocking
        OptInfo( SO_KEEPALIVE, OptType.Bool, OptType.Int ),
        OptInfo( SO_LINGER, OptType.Duration, OptType.Linger ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( SO_SNDBUF, OptType.Int, OptType.Int ),
        OptInfo( SO_RCVBUF, OptType.Int, OptType.Int ),
        OptInfo( SO_REUSEADDR, OptType.Bool, OptType.Int ),
        OptInfo( -1, OptType.Bool, OptType.Unsupported ), // NoSignalPipe
        OptInfo( SO_ERROR, OptType.Int, OptType.Int ),
        OptInfo( IP_ADD_MEMBERSHIP, OptType.MulticastGroup, OptType.MulticastGroup ),
        OptInfo( IP_MULTICAST_LOOP, OptType.Bool, OptType.Int ),
        OptInfo( IP_MULTICAST_TTL, OptType.Int, OptType.Int ),
        OptInfo( TCP_KEEPIDLE, OptType.Duration, OptType.Seconds ),
        OptInfo( TCP_KEEPINTVL, OptType.Duration, OptType.Seconds ),
        OptInfo( TCP_KEEPCNT, OptType.Int, OptType.Int ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( TCP_NODELAY, OptType.Bool, OptType.Int ),
    ];
}
else version (Darwin)
{
    __gshared immutable OptInfo[SocketOption.max] s_socketOptions = [
        OptInfo( -1, OptType.Bool, OptType.Bool ), // NonBlocking
        OptInfo( SO_KEEPALIVE, OptType.Bool, OptType.Int ),
        OptInfo( SO_LINGER, OptType.Duration, OptType.Linger ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( SO_SNDBUF, OptType.Int, OptType.Int ),
        OptInfo( SO_RCVBUF, OptType.Int, OptType.Int ),
        OptInfo( SO_REUSEADDR, OptType.Bool, OptType.Int ),
        OptInfo( SO_NOSIGPIPE, OptType.Bool, OptType.Int ),
        OptInfo( SO_ERROR, OptType.Int, OptType.Int ),
        OptInfo( IP_ADD_MEMBERSHIP, OptType.MulticastGroup, OptType.MulticastGroup ),
        OptInfo( IP_MULTICAST_LOOP, OptType.Bool, OptType.Int ),
        OptInfo( IP_MULTICAST_TTL, OptType.Int, OptType.Int ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( -1, OptType.Unsupported, OptType.Unsupported ),
        OptInfo( TCP_KEEPALIVE, OptType.Duration, OptType.Seconds ),
        OptInfo( TCP_NODELAY, OptType.Bool, OptType.Int ),
    ];
}
else
    static assert(false, "TODO");

int map_message_flags(MsgFlags flags)
{
    int r = 0;
    if (flags & MsgFlags.OOB) r |= MSG_OOB;
    if (flags & MsgFlags.Peek) r |= MSG_PEEK;
    version (linux)
    {
        if (flags & MsgFlags.Confirm) r |= MSG_CONFIRM;
        if (flags & MsgFlags.NoSig) r |= MSG_NOSIGNAL;
    }
    return r;
}

int map_addrinfo_flags(AddressInfoFlags flags)
{
    int r = 0;
    if (flags & AddressInfoFlags.Passive) r |= AI_PASSIVE;
    if (flags & AddressInfoFlags.CanonName) r |= AI_CANONNAME;
    if (flags & AddressInfoFlags.NumericHost) r |= AI_NUMERICHOST;
    if (flags & AddressInfoFlags.NumericServ) r |= AI_NUMERICSERV;
    if (flags & AddressInfoFlags.All) r |= AI_ALL;
    if (flags & AddressInfoFlags.AddrConfig) r |= AI_ADDRCONFIG;
    if (flags & AddressInfoFlags.V4Mapped) r |= AI_V4MAPPED;
    version (Windows)
        if (flags & AddressInfoFlags.FQDN) r |= AI_FQDN;
    return r;
}

OptLevel get_optlevel(SocketOption opt)
{
    if (opt < SocketOption.FirstIpOption) return OptLevel.Socket;
    else if (opt < SocketOption.FirstIpv6Option) return OptLevel.IP;
    else if (opt < SocketOption.FirstIcmpOption) return OptLevel.IPv6;
    else if (opt < SocketOption.FirstIcmpv6Option) return OptLevel.ICMP;
    else if (opt < SocketOption.FirstTcpOption) return OptLevel.ICMPv6;
    else if (opt < SocketOption.FirstUdpOption) return OptLevel.TCP;
    else return OptLevel.UDP;
}


version (Windows)
{
    pragma(crt_constructor)
    void crt_bootup()
    {
        WSADATA wsaData;
        int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
        // what if this fails???
    }

    pragma(crt_destructor)
    void crt_shutdown()
    {
        WSACleanup();
    }
}





// TODO: REMOVE ME - pushed to druntime...
version (Windows)
{
    // stuff that's missing from the windows headers...

    enum: int {
        AI_NUMERICSERV = 0x0008,
        AI_ALL = 0x0100,
        AI_V4MAPPED = 0x0800,
        AI_FQDN = 0x4000,
    }

    struct pollfd
    {
        SOCKET  fd;         // Socket handle
        SHORT   events;     // Requested events to monitor
        SHORT   revents;    // Returned events indicating status
    }
    alias WSAPOLLFD = pollfd;
    alias PWSAPOLLFD = pollfd*;
    alias LPWSAPOLLFD = pollfd*;

    enum: short {
        POLLRDNORM = 0x0100,
        POLLRDBAND = 0x0200,
        POLLIN = (POLLRDNORM | POLLRDBAND),
        POLLPRI = 0x0400,

        POLLWRNORM = 0x0010,
        POLLOUT = (POLLWRNORM),
        POLLWRBAND = 0x0020,

        POLLERR = 0x0001,
        POLLHUP = 0x0002,
        POLLNVAL = 0x0004
    }

    extern(Windows) int WSAPoll(LPWSAPOLLFD fdArray, uint fds, int timeout);

    struct ip_mreq
    {
        in_addr imr_multiaddr;
        in_addr imr_interface;
    }
}
