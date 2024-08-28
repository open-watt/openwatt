module urt.socket;

public import urt.endian;
public import urt.inet;
public import urt.mem;
public import urt.time;

version (Windows)
{
	import core.sys.windows.windows;
	import core.sys.windows.winsock2;

	version = HasIPv6;

    alias SocketHandle = SOCKET;
}
else version (Posix)
{
	version = HasUnixSocket;
	version = HasIPv6;

    alias SocketHandle = int;
}
else
	static assert(false, "Platform not supported");

nothrow @nogc:


enum SocketResult
{
    Success,
    Failure,
    InProgress,
    Again,
    WouldBlock,
    NoBuffer,
    NetworkDown,
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    ConnectionClosed,
    Interrupted,
	InvalidSocket,
    NoMemory,
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

enum SocketOption
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

    // IP options
    FirstIpOption,
    Multicast = FirstIpOption,
    MulticastUseLoopback,
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
    None        = 0x00000000,
    OOB         = 1 << 0,
    Peek        = 1 << 1,
    Confirm     = 1 << 2,
    NoSig       = 1 << 3,
    //...
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


struct Result
{
	enum Success = Result();

	uint systemCode = 0;

	bool opCast(T : bool)() const
		=> systemCode == 0;

	bool succeeded() const
		=> systemCode == 0;
	bool failed() const
		=> systemCode != 0;
}

// Internal error codes
enum InternalCode
{
    Success = 0,
    BufferTooSmall,
    InvalidParameter,
    Unsupported
}


Result CreateSocket(AddressFamily af, SocketType type, Protocol proto, out Socket socket)
{
	version (HasUnixSocket) {} else
	    assert(af != AddressFamily.Unix, "Unix sockets not supported on this platform!");

    socket.handle = .socket(s_addressFamily[af], s_socketType[type], s_protocol[proto]);
    if (socket == Socket.invalid)
        return SocketGetLastError();
    return Result.Success;
}

Result CloseSocket(Socket socket)
{
	version (Windows)
		int result = closesocket(socket.handle);
	else version (Posix)
		int result = close(socket.handle);
	else
	    assert(false, "Not implemented!");
    if (result < 0)
        return SocketGetLastError();

//    {
//        LockGuard<SharedMutex> lock(s_noSignalMut);
//        s_noSignal.Erase(socket);
//    }

    return Result.Success;
}

Result ShutdownSocket(Socket socket, SocketShutdownMode how)
{
    int t = int(how);
    switch (how)
    {
		version (Windows)
		{
			case SocketShutdownMode.Read:      t = SD_RECEIVE; break;
			case SocketShutdownMode.Write:     t = SD_SEND;    break;
			case SocketShutdownMode.ReadWrite: t = SD_BOTH;    break;
		}
		else version (Posix)
		{
			case SocketShutdownMode.Read:      t = SHUT_RD;   break;
			case SocketShutdownMode.Write:     t = SHUT_WR;   break;
			case SocketShutdownMode.ReadWrite: t = SHUT_RDWR; break;
		}
        default:
			assert(false, "Invalid `how`");
    }

    if (shutdown(socket.handle, t) < 0)
        return SocketGetLastError();
    return Result.Success;
}

Result Bind(Socket socket, ref const InetAddress address)
{
    ubyte[512] buffer = void;
    size_t addrLen;
    sockaddr* sockAddr = MakeSockaddr(address, buffer, addrLen);
    assert(sockAddr, "Invalid socket address");

    if (bind(socket.handle, sockAddr, cast(int)addrLen) < 0)
        return SocketGetLastError();
    return Result.Success;
}

Result Listen(Socket socket, uint backlog = -1)
{
    if (listen(socket.handle, int(backlog & 0x7FFFFFFF)) < 0)
        return SocketGetLastError();
    return Result.Success;
}

Result Connect(Socket socket, ref const InetAddress address)
{
    ubyte[512] buffer = void;
    size_t addrLen;
    sockaddr* sockAddr = MakeSockaddr(address, buffer, addrLen);
    assert(sockAddr, "Invalid socket address");

    if (connect(socket.handle, sockAddr, cast(int)addrLen) < 0)
        return SocketGetLastError();
    return Result.Success;
}

Result Accept(Socket socket, out Socket connection, InetAddress* connectingSocketAddress = null)
{
    char[sockaddr_storage.sizeof] buffer = void;
    sockaddr* addr = cast(sockaddr*)buffer.ptr;
    socklen_t size = buffer.sizeof;

    connection.handle = accept(socket.handle, addr, &size);
    if (connection == Socket.invalid)
        return SocketGetLastError();
    else if (connectingSocketAddress)
        *connectingSocketAddress = MakeSocketAddress(addr);
    return Result.Success;
}

Result Send(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.None, size_t* bytesSent = null)
{
    Result r = Result.Success;

//    {
//        SharedLockGuard<SharedMutex> lock(s_noSignalMut);
//        if ((*s_noSignal)[socket])
//        {
//            flags |= MsgFlags.NoSig;
//        }
//    }

    ptrdiff_t sent = send(socket.handle, message.ptr, cast(int)message.length, MapMessageFlags(flags));
    if (sent < 0)
    {
        r = SocketGetLastError();
        sent = 0;
    }
    if (bytesSent)
        *bytesSent = sent;
    return r;
}

Result SendTo(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.None, const InetAddress* address = null, size_t* bytesSent = null)
{
    ubyte[sockaddr_storage.sizeof] tmp = void;
    size_t addrLen;
    sockaddr* sockAddr = null;
    if (address)
    {
        sockAddr = MakeSockaddr(*address, tmp, addrLen);
        assert(sockAddr, "Invalid socket address");
    }

//    {
//        bcSharedLockGuard<bcSharedMutex> lock(s_noSignalMut);
//        if ((*s_noSignal)[socket])
//        {
//            flags |= MsgFlags.NoSig;
//        }
//    }

    Result r = Result.Success;
    ptrdiff_t sent = sendto(socket.handle, message.ptr, cast(int)message.length, MapMessageFlags(flags), sockAddr, cast(int)addrLen);
    if (sent < 0)
    {
        r = SocketGetLastError();
        sent = 0;
    }
    if (bytesSent)
        *bytesSent = sent;
    return r;
}

Result Recv(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.None, size_t* bytesReceived)
{
    Result r = Result.Success;
    ptrdiff_t bytes = recv(socket.handle, buffer.ptr, cast(int)buffer.length, MapMessageFlags(flags));
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
            Result error = SocketGetLastError();
            // TODO: Do we want a better way to distinguish between receiving a 0-length packet vs no-data (which looks like an error)?
            //       Is a zero-length packet possible to detect in TCP streams? Makes more sense for recvfrom...
            SocketResult sr = GetSocketResult(error);
            if (sr != SocketResult.Again && sr != SocketResult.WouldBlock)
                r = error;
        }
    }
    return r;
}

Result RecvFrom(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.None, InetAddress* senderAddress = null, size_t* bytesReceived)
{
    char[sockaddr_storage.sizeof] addrBuffer = void;
    sockaddr* addr = cast(sockaddr*)addrBuffer.ptr;
    socklen_t size = addrBuffer.sizeof;

    Result r = Result.Success;
    ptrdiff_t bytes = recvfrom(socket.handle, buffer.ptr, cast(int)buffer.length, MapMessageFlags(flags), addr, &size);
    if (bytes >= 0)
        *bytesReceived = bytes;
    else
    {
        *bytesReceived = 0;

        Result error = SocketGetLastError();
        SocketResult sockRes = GetSocketResult(error);
        if (sockRes != SocketResult.NoBuffer && // buffers full
            sockRes != SocketResult.ConnectionRefused && // posix error
            sockRes != SocketResult.ConnectionReset) // !!! windows may report this error, but it appears to mean something different on posix
            r = error;
    }
    if (r && senderAddress)
        *senderAddress = MakeSocketAddress(addr);
    return r;
}

Result SetSocketOption(Socket socket, SocketOption option, const(void)* optval, size_t optlen)
{
    Result r = Result.Success;

    // check the option appears to be the proper datatype
    const OptInfo* optInfo = &s_socketOptions[option];
    assert(optInfo.rtType != OptType.Unsupported, "Socket option is unsupported on this platform!");
    assert(optlen == s_optTypeSize[optInfo.rtType], "Socket option has incorrect payload size!");

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
    OptLevel level = GetOptLevel(option);
	version (HasIPv6) {} else
	    assert(level != OptLevel.IPv6 && level != OptLevel.ICMPv6, "Platform does not support IPv6!");

    // platforms don't all agree on option data formats!
    const(void)* arg = optval;
    int itmp = 0;
    linger ling;
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
    
    // Options expected in network-byte order
    IPAddr inaddtmp;
    MulticastGroup mgtmp;
    switch (optInfo.rtType)
    {
        case OptType.INAddress:
        {
            const(IPAddr)* addr = cast(const(IPAddr)*)optval;
            storeBigEndian(&inaddtmp.address(), addr.address);
            arg = &inaddtmp;
            break;
        }
        case OptType.MulticastGroup:
        {
            const(MulticastGroup)* group = cast(const(MulticastGroup)*)optval;
            storeBigEndian(&mgtmp.address.address(), group.address.address);
            storeBigEndian(&mgtmp.iface.address(), group.iface.address);
            arg = &mgtmp;
            break;
        }
        default:
            break;
    }

    // set the option
    r.systemCode = setsockopt(socket.handle, s_sockOptLevel[level], optInfo.option, cast(const(char)*)arg, s_optTypeSize[optInfo.platformType]);

    return r;
}

Result SetSocketOption(Socket socket, SocketOption option, bool value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Bool, "Incorrect option value type for call");
    return SetSocketOption(socket, option, &value, bool.sizeof);
}

Result SetSocketOption(Socket socket, SocketOption option, int value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Int, "Incorrect option value type for call");
    return SetSocketOption(socket, option, &value, int.sizeof);
}

Result SetSocketOption(Socket socket, SocketOption option, Duration value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Duration, "Incorrect option value type for call");
    return SetSocketOption(socket, option, &value, Duration.sizeof);
}

Result SetSocketOption(Socket socket, SocketOption option, IPAddr value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.INAddress, "Incorrect option value type for call");
    return SetSocketOption(socket, option, &value, IPAddr.sizeof);
}

Result GetSocketOption(Socket socket, SocketOption option, void* output, size_t outputlen)
{
    Result r = Result.Success;

    // check the option appears to be the proper datatype
    const OptInfo* optInfo = &s_socketOptions[option];
    assert(optInfo.rtType != OptType.Unsupported, "Socket option is unsupported on this platform!");
    assert(outputlen == s_optTypeSize[optInfo.rtType], "Socket option has incorrect payload size!");

    assert(option != SocketOption.NonBlocking, "Socket option NonBlocking cannot be get");

    // determine the option 'level'
    OptLevel level = GetOptLevel(option);
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

    socklen_t writtenLen = s_optTypeSize[optInfo.platformType];
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

    return r;
}

Result GetSocketOption(Socket socket, SocketOption option, out bool output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Bool, "Incorrect option value type for call");
    return GetSocketOption(socket, option, &output, bool.sizeof);
}

Result GetSocketOption(Socket socket, SocketOption option, out int output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Int, "Incorrect option value type for call");
    return GetSocketOption(socket, option, &output, int.sizeof);
}

Result GetSocketOption(Socket socket, SocketOption option, out Duration output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.Duration, "Incorrect option value type for call");
    return GetSocketOption(socket, option, &output, Duration.sizeof);
}

Result GetSocketOption(Socket socket, SocketOption option, out IPAddr output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rtType == OptType.Unsupported)
        return InternalResult(InternalCode.Unsupported);
    assert(optInfo.rtType == OptType.INAddress, "Incorrect option value type for call");
    return GetSocketOption(socket, option, &output, IPAddr.sizeof);
}

Result SetKeepAlive(Socket socket, bool enable, Duration keepIdle, Duration keepInterval, int keepCount)
{
	version (Windows)
	{
		tcp_keepalive alive;
		alive.onoff = enable ? 1 : 0;
		alive.keepalivetime = cast(uint)keepIdle.as!"msecs";
		alive.keepaliveinterval = cast(uint)keepInterval.as!"msecs";

		uint bytesReturned = 0;
		if (WSAIoctl(socket.handle, SIO_KEEPALIVE_VALS, &alive, alive.sizeof, null, 0, &bytesReturned, null, null) < 0)
			return SocketGetLastError();
		return Result.Success;
	}
	else
	{
		Result res = SetSocketOption(socket, SocketOption.KeepAlive, enable);
		if (!enable || res != Result.Success)
			return res;
		version (Darwin)
		{
			// Mac doesn't provide API for setting keep-alive interval and probe count.
			// To set those values,
			//
			// run `sysctl - w net.inet.tcp.keepcnt = 3 net.inet.tcp.keepintvl = 10000`
			//
			// or edit /etc/sysctl.conf as follows,
			// $ vi /etc/sysctl.conf
			// net.inet.tcp.keepintvl = 10000
			// net.inet.tcp.keepcnt = 3
			//
			// Note that the following code uses seconds value but above configuration uses
			// milliseconds value.

			return SetSocketOption(socket, SocketOption.TCP_KeepAlive, keepIdle);
		}
		else
		{
			res = SetSocketOption(socket, SocketOption.TCP_KeepIdle, keepIdle);
			if (res != Result.Success)
				return res;
			res = SetSocketOption(socket, SocketOption.TCP_KeepIntvl, keepInterval);
			if (res != Result.Success)
				return res;
			return SetSocketOption(socket, SocketOption.TCP_KeepCnt, keepCount);
		}
	}
}

Result GetPeerName(Socket socket, out InetAddress name)
{
    char[sockaddr_storage.sizeof] buffer;
    sockaddr* addr = cast(sockaddr*)buffer;
    socklen_t bufferLen = buffer.sizeof;

    int fail = getpeername(socket.handle, addr, &bufferLen);
    if (fail == 0)
        name = MakeSocketAddress(addr);
    else
        return SocketGetLastError();
    return Result.Success;
}

Result GetSockName(Socket socket, out InetAddress name)
{
    char[sockaddr_storage.sizeof] buffer;
    sockaddr* addr = cast(sockaddr*)buffer;
    socklen_t bufferLen = buffer.sizeof;

    int fail = getsockname(socket.handle, addr, &bufferLen);
    if (fail == 0)
        name = MakeSocketAddress(addr);
    else
        return SocketGetLastError();
    return Result.Success;
}

Result GetHostName(char* name, size_t len)
{
    int fail = gethostname(name, cast(int)len);
    if (fail)
        return SocketGetLastError();
    return Result.Success;
}



Result SocketGetLastError()
{
	version (Windows)
	    return Result(WSAGetLastError());
	else
	    return Result(errno);
}

Result GetSocketError(Socket socket)
{
    Result r;
    socklen_t optlen = r.systemCode.sizeof;
    int callResult = getsockopt(socket.handle, SOL_SOCKET, SO_ERROR, cast(char*)&r.systemCode, &optlen);
    if (callResult)
        r.systemCode = callResult;
    return r;
}

version (Windows)
{
	Result InternalResult(InternalCode code)
	{
		switch (code)
		{
			case InternalCode.Success: return Result(0);
			case InternalCode.BufferTooSmall: return Result(ERROR_INSUFFICIENT_BUFFER);
			case InternalCode.InvalidParameter: return Result(ERROR_INVALID_PARAMETER);
			default: return Result(ERROR_INVALID_FUNCTION); // InternalCode.Unsupported
		}
	}
}
else version (Posix)
{
	Result PosixResult(int err)
		=> Result(err + kPOSIXErrorBase);
	Result ErrnoResult()
		=> Result(errno + kPOSIXErrorBase);

	Result InternalResult(InternalCode code)
	{
		switch (code)
		{
			case InternalCode.Success: return Result(0);
			case InternalCode.BufferTooSmall: return Result(ERANGE + kPOSIXErrorBase);
			case InternalCode.InvalidParameter: return Result(EINVAL + kPOSIXErrorBase);
			default: return Result(ENOTSUP + kPOSIXErrorBase); // InternalCode.Unsupported
		}
	}
}

// TODO: !!!
enum Result ConnectionClosedResult = Result(-12345); 
SocketResult GetSocketResult(Result result)
{
    if (result)
        return SocketResult.Success;
    if (result.systemCode == ConnectionClosedResult.systemCode)
        return SocketResult.ConnectionClosed;
	version (Windows)
	{
		if (result.systemCode == WSAEINPROGRESS)
			return SocketResult.InProgress;
		if (result.systemCode == WSAEWOULDBLOCK)
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
	}
	else version (Posix)
	{
		auto checkResult = (Result result, int err) => result == PosixResult(err) || cast(int)result.systemCode == err;
		if (checkResult(result, EINPROGRESS))
			return SocketResult.InProgress;
		if (checkResult(result, EAGAIN))
			return SocketResult.Again;
		if (checkResult(result, EWOULDBLOCK))
			return SocketResult.WouldBlock;
		if (checkResult(result, ENOMEM))
			return SocketResult.NoBuffer;
		if (checkResult(result, ENETDOWN))
			return SocketResult.NetworkDown;
		if (checkResult(result, ECONNREFUSED))
			return SocketResult.ConnectionRefused;
		if (checkResult(result, ECONNRESET))
			return SocketResult.ConnectionReset;
		if (checkResult(result, EINTR))
			return SocketResult.Interrupted;
		if (checkResult(result, ENOMEM))
			return SocketResult.NoMemory;
	}
    return SocketResult.Failure;
}



// TODO: implement something like getaddrinfo...

// but for now we wrap the D lib...

size_t getAddress(const(char)[] host, ushort port, InetAddress[] outAddresses) nothrow @nogc
{
	import std.socket;

	// HACK CALL @nogc FUNCTION
	auto t = &__traits(getOverloads, std.socket, "getAddress")[1];

	Address[] addrs;
	try
		addrs = (cast(Address[] function(scope const(char)[], ushort) @nogc)t)(host, port);
	catch (Exception)
		return 0;

	size_t numResults = 0;
	for (size_t i = 0; i < addrs.length; i++)
	{
		if (i == outAddresses.length)
			return i;
		InetAddress* a = &outAddresses[numResults++];
		switch (addrs[i].addressFamily)
		{
			case std.socket.AddressFamily.INET:
				a.family = urt.inet.AddressFamily.IPv4;
				assert(addrs[i].nameLen == sockaddr_in.sizeof);
				sockaddr_in* ain = cast(sockaddr_in*)addrs[i].name;
				a._a.ipv4.addr.b[0] = ain.sin_addr.S_un.S_un_b.s_b1;
				a._a.ipv4.addr.b[1] = ain.sin_addr.S_un.S_un_b.s_b2;
				a._a.ipv4.addr.b[2] = ain.sin_addr.S_un.S_un_b.s_b3;
				a._a.ipv4.addr.b[3] = ain.sin_addr.S_un.S_un_b.s_b4;
				a._a.ipv4.port = loadBigEndian(&ain.sin_port);
				break;
			case std.socket.AddressFamily.INET6:
				a.family = urt.inet.AddressFamily.IPv6;
				assert(addrs[i].nameLen == sockaddr_in6.sizeof);
				sockaddr_in6* ain6 = cast(sockaddr_in6*)addrs[i].name;
				for (size_t j = 0; j < 8; j++)
					a._a.ipv6.addr.s[j] = loadBigEndian(&ain6.sin6_addr.in6_u.u6_addr16[j]);
				a._a.ipv6.port = loadBigEndian(&ain6.sin6_port);
				a._a.ipv6.flowInfo = loadBigEndian(&ain6.sin6_flowinfo);
				a._a.ipv6.scopeId = loadBigEndian(&ain6.sin6_scope_id);
				break;
			default:
				break;
		}
	}
	return numResults;
}





sockaddr* MakeSockaddr(ref const InetAddress address, ubyte[] buffer, out size_t addrLen)
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
	            ain.sin_addr.s_addr = address.ipv4.addr.address;
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
						storeBigEndian(cast(ushort*)ain6.sin6_addr.s6_addr + a, address.ipv6.addr.s[a]);
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
			version (HasUnixSocket)
			{
				addrLen = sockaddr_un.sizeof;
				if (buffer.length < sockaddr_un.sizeof)
					return null;

				sockaddr_un* aun = cast(sockaddr_un*)sockAddr;
				memzero(aun, sockaddr_un.sizeof);
				aun.sun_family = s_addressFamily[AddressFamily.Unix];

				bcMemCopy(aun.sun_path, address.un.path, UNIX_PATH_LEN);
				break;
			}
			else
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

InetAddress MakeSocketAddress(const(sockaddr)* sockAddress)
{
    InetAddress addr;
    addr.family = GetAddressFamily(sockAddress.sa_family);
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
	            addr.ipv4.addr.address = ain.sin_addr.s_addr;
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
		                addr.ipv6.addr.s[a] = loadBigEndian(cast(const(ushort)*)ain6.sin6_addr.s6_addr + a);
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
			version (HasUnixSocket)
			{
				const sockaddr_un* aun = cast(const(sockaddr_un)*)sockAddress;

				memcpy(addr.un.path, aun.sun_path, UNIX_PATH_LEN);
				if (UNIX_PATH_LEN < UnixPathLen)
					memzero(addr.un.path + UNIX_PATH_LEN, addr.un.path.sizeof - UNIX_PATH_LEN);
			}
			else
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

enum OptLevel
{
    Socket,
    IP,
    IPv6,
    ICMP,
    ICMPv6,
    TCP,
    UDP,
}

enum OptType
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


__gshared immutable ubyte[] s_optTypeSize = [ 0, bool.sizeof, int.sizeof, int.sizeof, int.sizeof, Duration.sizeof, IPAddr.sizeof, MulticastGroup.sizeof, linger.sizeof ];

struct OptInfo
{
    int option;
    OptType rtType;
    OptType platformType;
}

__gshared immutable ushort[AddressFamily.max+1] s_addressFamily = [
    AF_UNSPEC,
    AF_UNIX,
    AF_INET,
    AF_INET6
];
AddressFamily GetAddressFamily(int addressFamily)
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
SocketType GetSocketType(int sockType)
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
Protocol GetProtocol(int protocol)
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
//		OptInfo( SO_RANDOMIZE_PORT, OptType.Bool, OptType.Int ),  // TODO:  BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
		OptInfo( SO_SNDBUF, OptType.Int, OptType.Int ),
		OptInfo( SO_RCVBUF, OptType.Int, OptType.Int ),
		OptInfo( SO_REUSEADDR, OptType.Bool, OptType.Int ),
		OptInfo( -1, OptType.Bool, OptType.Unsupported ), // NoSignalPipe
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

int MapMessageFlags(MsgFlags flags)
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

OptLevel GetOptLevel(SocketOption opt)
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
