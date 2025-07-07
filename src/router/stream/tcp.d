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
        writeDebug("TCP stream, name: ", name[]);
        super(collectionTypeInfo!TCPStream, name.move, cast(StreamOptions)(StreamOptions.NonBlocking | StreamOptions.KeepAlive));
    }

    this(String name, const(char)[] host, ushort port, StreamOptions options = StreamOptions.None)
    {
        super(name.move, TypeName, options);

        AddressInfo addrInfo;
        addrInfo.family = AddressFamily.IPv4;
        addrInfo.sock_type = SocketType.stream;
        addrInfo.protocol = Protocol.tcp;
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

    ~this()
    {
        close_socket();
    }


    // Properties...
    ref const(String) remote() const pure
        => _host;
    void remote(InetAddress value)
    {
        // apply explicit port if assigned
        if (_port != 0)
        {
            if (value.family == AddressFamily.IPv4)
                value._a.ipv4.port = _port;
            else if (value.family == AddressFamily.IPv6)
                value._a.ipv6.port = _port;
        }

        _host = null;
        if (value == _remote)
            return;
        _remote = value;

        restart();
    }
    const(char)[] remote(String value)
    {
        if (value.empty)
            return "remote cannot be empty";
        if (value == _host)
            return null;

        _host = value.move;
        _remote = InetAddress();

        restart();
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

        restart();
    }


    // API...

    final override bool validate() const pure
        => ((_remote != InetAddress()) ^^ !_host.empty) &&
            ((_remote.family == AddressFamily.IPv4 && _remote._a.ipv4.port != 0) ||
             (_remote.family == AddressFamily.IPv6 && _remote._a.ipv6.port != 0));

    final override CompletionStatus startup()
    {
        // a reverse-connect socket will be handled by a companion TCPServer
        // TODO...
        if (options & StreamOptions.ReverseConnect)
        {
            assert(false);
            return CompletionStatus.Continue;
        }

        if (_remote == InetAddress())
        {
            assert(_host, "No remote set for TCP stream!");

            AddressInfo addrInfo;
            addrInfo.family = AddressFamily.IPv4;
            addrInfo.sock_type = SocketType.stream;
            addrInfo.protocol = Protocol.tcp;
            AddressInfoResolver results;
            get_address_info(_host, _port ? _port.tstring : null, &addrInfo, results);
            if (!results.next_address(addrInfo))
                return CompletionStatus.Continue;

            // apply explicit port if assigned
            if (_port != 0)
            {
                if (addrInfo.address.family == AddressFamily.IPv4)
                    addrInfo.address._a.ipv4.port = _port;
                else if (addrInfo.address.family == AddressFamily.IPv6)
                    addrInfo.address._a.ipv6.port = _port;
            }

            _remote = addrInfo.address;
        }

        // if the socket is invalid, we'll attempt to initiate a connection...
        if (_socket == Socket.invalid)
        {
            // we don't want to spam connection attempts...
            SysTime now = getSysTime();
            if (now < lastRetry + seconds(5))
                return CompletionStatus.Continue;
            lastRetry = now;

            Result r = create_socket(AddressFamily.IPv4, SocketType.stream, Protocol.tcp, _socket);
            if (!r)
            {
                debug writeWarning("create_socket() failed with error: ", r.socket_result());
                restart();
                return CompletionStatus.Error;
            }

            set_socket_option(_socket, SocketOption.non_blocking, true);
            r = _socket.connect(_remote);
            if (!r.succeeded && r.socket_result != SocketResult.would_block)
            {
                debug writeWarning("_socket.connect() failed with error: ", r.socket_result());
                restart();
                return CompletionStatus.Error;
            }
        }

        // the socket is valid, but not live (waiting for connect() to complete)
        // we'll poll it to see if it connected...
        PollFd fd;
        fd.socket = _socket;
        fd.request_events = PollEvents.write;
        uint numEvents;
        Result r = poll(fd, Duration.zero, numEvents);
        if (r.failed)
        {
            debug writeWarning("poll() failed with error: ", r.socket_result);
            restart();
            return CompletionStatus.Error;
        }

        // no events returned, still waiting...
        if (numEvents == 0)
            return CompletionStatus.Continue;

        // check error conditions
        if (fd.return_events & (PollEvents.error | PollEvents.hangup | PollEvents.invalid))
        {
            debug writeDebug("TCP stream connection failed: '", name, "' to ", remote);
            restart();
            return CompletionStatus.Error;
        }

        // this should be the only case left, we've successfully connected!
        // let's just assert that the socket is writable to be sure...
        assert(fd.return_events & PollEvents.write);

        if (keepEnable)
            set_keepalive(_socket, keepEnable, keepIdle, keepInterval, keepCount);

        writeInfo("TCP stream '", name, "' link established.");
        return CompletionStatus.Complete;
    }

    final override CompletionStatus shutdown()
    {
        if (_host)
            _remote = InetAddress();

        close_socket();

        if (_flags & ObjectFlags.Temporary)
            destroy();

        return CompletionStatus.Complete;
    }

    final override void update()
    {
        // poll to see if the socket is actually alive...

        // TODO: does this actually work?! and do we really even want this?
        ubyte[1] buffer;
        size_t bytesReceived;
        Result r = recv(_socket, null, MsgFlags.peek, &bytesReceived);
        if (r != Result.success && r.socket_result != SocketResult.would_block)
        {
            // something happened... we should try and reconnect I guess?
            restart();
        }
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

        close_socket();
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
        if (_socket)
            set_keepalive(_socket, enable, keepIdle, keepInterval, keepCount);
    }

    override ptrdiff_t read(void[] buffer)
    {
        if (!running)
            return 0;

        size_t bytes = 0;
        Result r = _socket.recv(buffer, MsgFlags.none, &bytes);
        if (r != Result.success)
        {
            SocketResult sr = r.socket_result;
            if (sr != SocketResult.would_block)
                restart();
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
            Result r = _socket.send(data, MsgFlags.none, &bytes);
            if (r != Result.success)
            {
                SocketResult sr = r.socket_result;
                if (sr == SocketResult.would_block)
                    return 0;
                restart();
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
        Result r = _socket.recv(null, MsgFlags.peek, &bytes);
        assert(false, "TODO: not implemented...");
        if (r != Result.success)
        {
//            SocketResult sr = r.socket_result;
            _socket.close();
            _socket = null;
        }
        return bytes;
    }

    override ptrdiff_t flush()
    {
        // TODO: read until can't read no more?
        assert(0);
    }

private:
    InetAddress _remote;
    String _host;
    ushort _port;
    Socket _socket;
    SysTime lastRetry;
//    TCPServer reverseConnectServer;

    bool keepEnable = false;
    int keepCount = 10;
    Duration keepIdle;
    Duration keepInterval;

    void close_socket()
    {
        if (_socket == Socket.invalid)
            return;
        if (_state == State.Stopping)
            _socket.shutdown(SocketShutdownMode.read_write);
        _socket.close();
        _socket = Socket.invalid;
    }

    // TODO: this is a bug! remove the public!!
public:
    this(String name, Socket socket, ushort port)
    {
        this(name.move);

        _state = State.Running;
        _flags |= ObjectFlags.Dynamic | ObjectFlags.Temporary;

        this._socket = socket;
        socket.get_peer_name(_remote);
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

        Result r = create_socket(AddressFamily.IPv4, SocketType.stream, Protocol.tcp, serverSocket);
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "': failed to create _socket. Error ", r.systemCode);
            return;
        }

        r = serverSocket.set_socket_option(SocketOption.non_blocking, true);
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "': set_socket_option failed.  Error ", r.systemCode);
            return;
        }

        r = serverSocket.bind(InetAddress(IPAddr.any, port));
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "': failed to bind port ", port, ". Error ", r.systemCode);
            return;
        }

        r = serverSocket.listen();
        if (r.failed)
        {
            writeError("Error staring TCP server '", name , "': listen failed. Error ", r.systemCode);
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
        if (!isRunning)
            return;

        Socket conn;
        InetAddress remoteAddr;
        Result r = serverSocket.accept(conn, &remoteAddr);
        if (r.failed)
        {
            if (r.socket_result == SocketResult.would_block)
                return;
            // TODO: handle error more good?
            assert(false, tconcat(r.socket_result));
        }

        assert(conn);

        if (options & ServerOptions.JustOne)
            stop();

        // prevent duplicate stream names...
        String newName = getModule!StreamModule.streams.generateName(name).makeString(defaultAllocator());

//        if (rawConnectionCallback)
//            rawConnectionCallback(conn, userData);
//        else if (connectionCallback)
        if (connectionCallback)
            connectionCallback(defaultAllocator().allocT!TCPStream(newName.move, conn, port), userData);
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
