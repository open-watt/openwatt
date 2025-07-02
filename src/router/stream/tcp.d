module router.stream.tcp;

import urt.conv;
import urt.io;
import urt.log;
import urt.mem;
import urt.meta.nullable;
import urt.socket;
import urt.string;
import urt.string.format;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

public import router.stream;


class TCPStream : Stream
{
    __gshared Property[2] Properties = [ Property.create!("remote", remote)(),
                                         Property.create!("port", port)() ];
nothrow @nogc:

    alias TypeName = StringLit!"tcp-client";

    this(String name)
    {
        super(collectionTypeInfo!TCPStream, name.move, cast(StreamOptions)(StreamOptions.NonBlocking | StreamOptions.KeepAlive));
    }

    this(String name, const(char)[] host, ushort port, StreamOptions options = StreamOptions.None)
    {
        super(name.move, TypeName, options);

        AddressInfo addrInfo;
        addrInfo.family = AddressFamily.IPv4;
        addrInfo.sockType = SocketType.Stream;
        addrInfo.protocol = Protocol.TCP;
        AddressInfoResolver results;
        get_address_info(host, port ? port.tstring : null, &addrInfo, results);
        if (!results.next_address(addrInfo))
        {
            // TODO: handle error case for no remote host...
            assert(0);
        }
        _remote = addrInfo.address;
        _status.linkStatusChangeTime = getSysTime();
        update();
    }

    this(String name, InetAddress address, StreamOptions options = StreamOptions.None)
    {
        super(name.move, TypeName, options);

        _remote = address;
        _status.linkStatusChangeTime = getSysTime();
        update();
    }


    // Properties...
    ref const(String) remote() const pure
        => _host;
    const(char)[] remote(InetAddress value)
    {
        // apply explicit port if assigned
        if (_port != 0)
        {
            if (value.family == AddressFamily.IPv4)
                value._a.ipv4.port = _port;
            else if (value.family == AddressFamily.IPv6)
                value._a.ipv6.port = _port;
        }

        if (value == _remote)
            return null;

        _remote = value;
        _host = null;

        if (socket)
            closeLink();
        return null;
    }
    const(char)[] remote(String value)
    {
        if (value == _host && (value || _remote == InetAddress()))
            return null;

        if (!value)
        {
            _host = null;
            _remote = InetAddress(); // reset remote address
            if (socket)
                closeLink();
            return null;
        }

        AddressInfo addrInfo;
        addrInfo.family = AddressFamily.IPv4;
        addrInfo.sockType = SocketType.Stream;
        addrInfo.protocol = Protocol.TCP;
        AddressInfoResolver results;
        get_address_info(value, port ? port.tstring : null, &addrInfo, results);
        if (!results.next_address(addrInfo))
        {
            _host = value.move;
            _remote = InetAddress(); // reset remote address
            // TODO: we couldn't resolve the address, but that's not necessarily an invalid input...
            //       or do we return as in error here?
            return null;
        }

        // apply explicit port if assigned
        if (_port != 0)
        {
            if (addrInfo.address.family == AddressFamily.IPv4)
                addrInfo.address._a.ipv4.port = _port;
            else if (addrInfo.address.family == AddressFamily.IPv6)
                addrInfo.address._a.ipv6.port = _port;
        }

        _host = value.move;

        if (addrInfo.address == _remote)
            return null;

        _remote = addrInfo.address;

        if (socket)
            closeLink();
        return null;
    }

    ushort port() const pure
        => _port;
    void port(WellKnownPort value)
        => port(cast(ushort)value);
    void port(ushort value)
    {
        if (_port == value)
            return;

        _port = value;
        if ((_remote.family == AddressFamily.IPv4 && _remote._a.ipv4.port == value) ||
            (_remote.family == AddressFamily.IPv6 && _remote._a.ipv6.port == value))
            return;

        // apply the explicit port
        if (_remote.family == AddressFamily.IPv4)
            _remote._a.ipv4.port = value;
        else if (_remote.family == AddressFamily.IPv6)
            _remote._a.ipv6.port = value;

        // port changed; reset the stream
        if (socket)
            closeLink();
    }


    // API...

    final override bool validate() const pure
        => _remote != InetAddress() &&
            ((_remote.family == AddressFamily.IPv4 && _remote._a.ipv4.port != 0) ||
             (_remote.family == AddressFamily.IPv6 && _remote._a.ipv6.port != 0));

    final override bool enable(bool enable)
    {
        bool old = _enabled;
        if (_enabled != enable)
        {
            _enabled = enable;
            if (!enable)
            {
                if (socket)
                {
                    socket.shutdown(SocketShutdownMode.ReadWrite);
                    closeLink();
                }
            }
        }
        return old;
    }


    override bool connect()
    {
        lastRetry = SysTime();
        update();
        return true;
    }

    override void disconnect()
    {
//        if (reverseConnectServer !is null)
//        {
//            reverseConnectServer.stop();
//            reverseConnectServer = null;
//        }

        if (socket)
        {
//            if (socket.isAlive)
            socket.shutdown(SocketShutdownMode.ReadWrite);
            closeLink();
        }
    }

    override const(char)[] remoteName()
    {
        return tstring(remote);
    }

    override void setOpts(StreamOptions options)
    {
        this.options = options;
    }

    void enableKeepAlive(bool enable, Duration keepIdle = seconds(10), Duration keepInterval = seconds(1), int keepCount = 10)
    {
        this.keepEnable = enable;
        this.keepIdle = keepIdle;
        this.keepInterval = keepInterval;
        this.keepCount = keepCount;
        if (socket)
            set_keepalive(socket, enable, keepIdle, keepInterval, keepCount);
    }

    override ptrdiff_t read(void[] buffer)
    {
        if (!running)
            return 0;

        size_t bytes = 0;
        Result r = socket.recv(buffer, MsgFlags.None, &bytes);
        if (r != Result.Success)
        {
            SocketResult sr = r.get_SocketResult;
            if (sr != SocketResult.WouldBlock)
                closeLink();
            return 0;
        }
        if (logging)
            writeToLog(true, buffer[0 .. bytes]);
        _status.recvBytes += bytes;
        return bytes;
    }

    override ptrdiff_t write(const void[] data)
    {
        if (!running && (options & StreamOptions.OnDemand))
            connect();

        if (running)
        {
            size_t bytes;
            Result r = socket.send(data, MsgFlags.None, &bytes);
            if (r != Result.Success)
            {
                SocketResult sr = r.get_SocketResult;
                if (sr == SocketResult.WouldBlock)
                    return 0;

                closeLink();
            }
            else
            {
                if (logging)
                    writeToLog(false, data[0 .. bytes]);
                return bytes;
            }
        }

        if (options & StreamOptions.BufferData)
        {
            assert(false, "TODO: buffer data for when the stream becomes available again");
            // how long should buffered data linger? how big is the buffer?
        }

        return 0;
    }

    override ptrdiff_t pending()
    {
        if (!running)
            return 0;

        size_t bytes;
        Result r = socket.recv(null, MsgFlags.Peek, &bytes);
        assert(false, "TODO: not implemented...");
        if (r != Result.Success)
        {
//            SocketResult sr = r.get_SocketResult;
            socket.close();
            socket = null;
        }
        return bytes;
    }

    override ptrdiff_t flush()
    {
        // TODO: read until can't read no more?
        assert(0);
    }

    override void update()
    {
        if (!_enabled || !validate())
            return;

        if (status.linkStatus == Status.Link.Up)
        {
            // poll to see if the socket is actually alive...

            // TODO: does this actually work?! and do we really even want this?
            ubyte[1] buffer;
            size_t bytesReceived;
            Result r = recv(socket, null, MsgFlags.Peek, &bytesReceived);
            if (r == Result.Success || r.get_SocketResult == SocketResult.WouldBlock)
                _status.linkStatus = Status.Link.Up;
            else
            {
                // something happened... we should try and reconnect I guess?
                closeLink();
            }
        }
        if (_status.linkStatus == Status.Link.Up)
            return;

        // a reverse-connect socket will be handled by a companion TCPServer
        // TODO...
        if (options & StreamOptions.ReverseConnect)
        {
            assert(false);
            return;
        }

        SysTime now = getSysTime();

        // if the socket is invalid, we'll attempt to initiate a connection...
        if (socket == Socket.invalid)
        {
            // we don't want to spam connection attempts...
            if (now < lastRetry + seconds(5))
                return;
            lastRetry = now;

            Result r = create_socket(AddressFamily.IPv4, SocketType.Stream, Protocol.TCP, socket);
            if (!r)
            {
                socket = Socket.invalid;
                debug writeWarning("create_socket() failed with error: ", r.get_SocketResult());
            }

            set_socket_option(socket, SocketOption.NonBlocking, true);
            r = socket.connect(_remote);
            if (r.succeeded)
            {
                _status.linkStatus = Status.Link.Up;
                return;
            }
            else
            {
                version (Windows)
                {
                    if (r.get_SocketResult == SocketResult.WouldBlock)
                        return;
                }
                else version (Posix)
                {
                    if (r.get_SocketResult == SocketResult.InProgress)
                        return;
                }
                else
                    static assert(0, "Unsupported platform?");

                // something went wrong with the call to connect; we'll destroy the socket and try again later
                socket.close();
                socket = Socket.invalid;

                debug writeWarning("socket.connect() failed with error: ", r.get_SocketResult());
            }
        }
        else
        {
            // the socket is valid, but not live (waiting for connect() to complete)
            // we'll poll it to see if it connected...

            PollFd fd;
            fd.socket = socket;
            fd.requestEvents = PollEvents.Write;
            uint numEvents;
            Result r = poll(fd, Duration.zero, numEvents);
            if (r.failed)
            {
                debug writeWarning("poll() failed with error: ", r.get_SocketResult);
                // TODO: destroy socket and start over?
                return;
            }

            // no events returned, still waiting...
            if (numEvents == 0)
                return;

            // check error conditions
            if (fd.returnEvents & (PollEvents.Error | PollEvents.HangUp | PollEvents.Invalid))
            {
                socket.close();
                socket = Socket.invalid;
                debug writeDebug("TCP stream connection failed: '", name, "' to ", remote);
                return;
            }

            // this should be the only case left, we've successfully connected!
            // let's just assert that the socket is writable to be sure...
            assert(fd.returnEvents & PollEvents.Write);

            if (keepEnable)
                set_keepalive(socket, keepEnable, keepIdle, keepInterval, keepCount);

            _status.linkStatus = Status.Link.Up;
            _status.linkStatusChangeTime = now;

            writeInfo("TCP stream '", name, "' link established.");
        }
    }

    void closeLink()
    {
        socket.close();
        socket = Socket.invalid;
        _status.linkStatus = Status.Link.Down;
        _status.linkStatusChangeTime = getSysTime();
        ++_status.linkDowns;

        writeWarning("TCP stream '", name, "' link down.");
    }


    // TODO: this is a bug! uncomment this bad boy!!
//private:
    InetAddress _remote;
    String _host;
    ushort _port;
    bool _enabled;
    Socket socket;
    SysTime lastRetry;
//    TCPServer reverseConnectServer;

    bool keepEnable = false;
    int keepCount = 10;
    Duration keepIdle;
    Duration keepInterval;

    this(String name, Socket socket, ushort port)
    {
        super(name.move, "tcp-client", StreamOptions.None);
        socket.get_peer_name(_remote);

        this.socket = socket;
        _status.linkStatus = Status.Link.Up;
    }
}

enum ServerOptions
{
    None = 0,
    JustOne = 1 << 0, // Only accept one connection then terminate the server
}

class TCPServer
{
    nothrow @nogc:

    alias NewConnection = void delegate(TCPStream client, void* userData) nothrow @nogc;

    this(String name, ushort port, NewConnection callback, void* userData, ServerOptions options = ServerOptions.None) nothrow @nogc
    {
        this.name = name.move;
        this.port = port;
        this.options = options;
        this.connectionCallback = callback;
        this.userData = userData;

        start();
    }

    ~this()
    {
        stop();
    }

    void start() nothrow @nogc
    {
        // TODO: should we just accept multiple calls to start() and ignore if already running?
        assert(!isRunning, "Already started");

        Result r = create_socket(AddressFamily.IPv4, SocketType.Stream, Protocol.TCP, serverSocket);
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "':port ", port, " failed to create socket. Error ", r.systemCode, ".");
            return;
        }

        r = serverSocket.set_socket_option(SocketOption.NonBlocking, true);
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "':port ", port, " set_socket_option failed.  Error ", r.systemCode, ".");
            return;
        }

        r = serverSocket.bind(InetAddress(IPAddr.any, port));
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "':port ", port, " failed to bind socket.", r.systemCode, ".");
            return;
        }

        r = serverSocket.listen();
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "':port ", port, " call to listen failed.", r.systemCode, ".");
            return;
        }

        isRunning = true;

        writeInfo("TCP server '", name , "' listening on port ", port);
    }

    void stop()
    {
        assert(isRunning, "Not started");

        isRunning = false;

        serverSocket.close();
        serverSocket = null;
    }

    bool running()
    {
        return isRunning;
    }

    // TODO: remove this, we should use threads instead of polling!
    void update()
    {
        Socket conn;
        InetAddress remoteAddr;
        Result r = serverSocket.accept(conn, &remoteAddr);
        if (r.failed)
        {
            if (r.get_SocketResult == SocketResult.WouldBlock)
                return;
            // TODO: handle error more good?
            assert(false, tconcat(r.get_SocketResult));
        }

        assert(conn);

        if (options & ServerOptions.JustOne)
            stop();

//        if (rawConnectionCallback)
//            rawConnectionCallback(conn, userData);
//        else if (connectionCallback)
        if (connectionCallback)
            connectionCallback(defaultAllocator().allocT!TCPStream(name, conn, port), userData);
    }

private:
    alias NewRawConnection = void function(Socket client, void* userData) nothrow @nogc;

    String name;
    ServerOptions options;
    ushort port;
    bool isRunning;
    NewConnection connectionCallback;
//    NewRawConnection rawConnectionCallback;
    void* userData;
    Socket serverSocket;

//    this(ushort port, NewRawConnection callback, void* userData, ServerOptions options = ServerOptions.None)
//    {
//        this.port = port;
//        this.options = options;
//        this.rawConnectionCallback = callback;
//        this.userData = userData;
//        mutex = new Mutex;
//    }
}


class TCPStreamModule : Module
{
    mixin DeclareModule!"stream.tcp";
nothrow @nogc:

    Collection!TCPStream tcpStreams;

    override void init()
    {
        g_app.console.registerCollection("/stream/tcp-client", tcpStreams);
    }
}
