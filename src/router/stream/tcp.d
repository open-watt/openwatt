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

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

public import router.stream;


class TCPStream : Stream
{
    __gshared Property[3] Properties = [ Property.create!("remote", remote)(),
                                         Property.create!("port", port)(),
                                         Property.create!("keepalive", keepalive)() ];
nothrow @nogc:

    alias TypeName = StringLit!"tcp-client";

    this(String name, ObjectFlags flags = ObjectFlags.None, StreamOptions options = StreamOptions.None)
    {
        super(collectionTypeInfo!TCPStream, name.move, flags, options);
    }

    // Properties...
    ref const(String) remote() const pure
        => _host;
    void remote(InetAddress value)
    {
        // apply explicit port if assigned
        if (_port != 0)
            update_port(value, _port);

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
        update_port(_remote, _port);

        restart();
    }

    bool keepalive() const pure
        => _keep_enable;
    void keepalive(bool value)
    {
        if (_keep_enable == value)
            return;
        enableKeepAlive(value);
    }


    // API...

    final override bool validate() const pure
    {
        if (_remote != InetAddress())
        {
            if (!_host.empty)
                return false;
            if ((_remote.family == AddressFamily.IPv4 && _remote._a.ipv4.port != 0) ||
                (_remote.family == AddressFamily.IPv6 && _remote._a.ipv6.port != 0))
                return true;
        }
        else if (_host.empty)
            return false;
        return true;
    }

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
            _remote = addrInfo.address;

            // apply explicit port if assigned
            if (_port != 0)
                update_port(_remote, _port);
        }

        // if the socket is invalid, we'll attempt to initiate a connection...
        if (_socket == Socket.invalid)
        {
            // we don't want to spam connection attempts...
            SysTime now = getSysTime();
            if (now < _last_retry + seconds(5))
                return CompletionStatus.Continue;
            _last_retry = now;

            Result r = create_socket(AddressFamily.IPv4, SocketType.stream, Protocol.tcp, _socket);
            if (!r)
            {
                debug writeError(type, " '", name, "' - create_socket() failed with error: ", r.socket_result);
                return CompletionStatus.Error;
            }

            set_socket_option(_socket, SocketOption.non_blocking, true);
            r = _socket.connect(_remote);
            if (!r.succeeded && r.socket_result != SocketResult.would_block)
            {
                debug writeWarning(type, " '", name, "' - connect() failed with error: ", r.socket_result);
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
            debug writeError(type, " '", name, "' - poll() failed with error: ", r.socket_result);
            return CompletionStatus.Error;
        }

        // no events returned, still waiting...
        if (numEvents == 0)
            return CompletionStatus.Continue;

        // check error conditions
        if (fd.return_events & (PollEvents.error | PollEvents.hangup | PollEvents.invalid))
        {
            debug writeError(type, " '", name, "' - connection failed to ", _remote);
            return CompletionStatus.Error;
        }

        // this should be the only case left, we've successfully connected!
        // let's just assert that the socket is writable to be sure...
        assert(fd.return_events & PollEvents.write);

        if (_keep_enable)
            set_keepalive(_socket, _keep_enable, _keep_idle, _keep_interval, _keep_count);

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
        _last_retry = SysTime();
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

    void enableKeepAlive(bool enable, Duration keep_idle = seconds(10), Duration keep_interval = seconds(1), int keep_count = 10)
    {
        _keep_enable = enable;
        _keep_idle = keep_idle;
        _keep_interval = keep_interval;
        _keep_count = keep_count;
        if (_socket)
            set_keepalive(_socket, enable, keep_idle, keep_interval, keep_count);
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
        if (!running)
            return 0;

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
    Socket _socket;
    InetAddress _remote;
    ushort _port;
    SysTime _last_retry;
    String _host;
//    TCPServer reverseConnectServer;

    bool _keep_enable = false;
    int _keep_count = 10;
    Duration _keep_idle;
    Duration _keep_interval;

    void close_socket()
    {
        if (_socket == Socket.invalid)
            return;
        if (_state == State.Stopping)
            _socket.shutdown(SocketShutdownMode.read_write);
        _socket.close();
        _socket = Socket.invalid;
    }

    bool update_port(ref InetAddress addr, ushort port)
    {
        if (addr.family == AddressFamily.IPv4)
        {
            addr._a.ipv4.port = port;
            return true;
        }
        else if (addr.family == AddressFamily.IPv6)
        {
            addr._a.ipv6.port = port;
            return true;
        }
        return false;
    }
}

enum ServerOptions
{
    None = 0,
    JustOne = 1 << 0, // Only accept one connection then terminate the server
}

class TCPServer : BaseObject
{
    __gshared Property[1] Properties = [ Property.create!("port", port)() ];

nothrow @nogc:

    alias TypeName = StringLit!"tcp-server";

    alias NewConnection = void delegate(TCPStream client, void* userData) nothrow @nogc;

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!TCPServer, name.move, flags);
    }

    // Properties
    ushort port() const pure
        => _port;
    void port(ushort value)
    {
        if (_port == value)
            return;
        _port = value;
        restart();
    }

    // API...

    void setConnectionCallback(NewConnection callback, void* userData)
    {
        _connectionCallback = callback;
        _userData = userData;
    }

    final override bool validate() const pure
        => _port != 0;

    final override CompletionStatus startup()
    {
        assert(!_serverSocket);

        Result r = create_socket(AddressFamily.IPv4, SocketType.stream, Protocol.tcp, _serverSocket);
        if (r.failed)
        {
            debug writeError(type, " '", name, "' - failed to create socket. Error ", r.systemCode);
            return CompletionStatus.Error;
        }

        r = _serverSocket.set_socket_option(SocketOption.non_blocking, true);
        if (r.failed)
        {
            debug writeError(type, " '", name, "' - set_socket_option failed.  Error ", r.systemCode);
            return CompletionStatus.Error;
        }

        r = _serverSocket.bind(InetAddress(IPAddr.any, _port));
        if (r.failed)
        {
            debug writeWarning(type, " '", name, "' - failed to bind port ", _port, ". Error ", r.systemCode);
            return CompletionStatus.Error;
        }

        r = _serverSocket.listen();
        if (r.failed)
        {
            debug writeError(type, " '", name, "' - listen failed. Error ", r.systemCode);
            return CompletionStatus.Error;
        }

        debug writeInfo(type, " '", name, "' - listening on port ", _port);
        return CompletionStatus.Complete;
    }

    final override CompletionStatus shutdown()
    {
        if (_serverSocket)
        {
            _serverSocket.close();
            _serverSocket = null;
        }
        return CompletionStatus.Complete;
    }

    final override void update()
    {
        Socket conn;
        InetAddress remoteAddr;
        Result r = _serverSocket.accept(conn, &remoteAddr);
        if (r.failed)
        {
            if (r.socket_result != SocketResult.would_block)
            {
                // do we want to know what went wrong??
                restart();
            }
            return;
        }
        assert(conn);

        // if this was a temporary server. maybe we destroy it now?
//        if (options & ServerOptions.JustOne)
//            stop();

        // prevent duplicate stream names...
        String newName = getModule!StreamModule.streams.generateName(name).makeString(defaultAllocator());

//        if (_rawConnectionCallback)
//            _rawConnectionCallback(conn, userData);
//        else if (_connectionCallback)
        if (_connectionCallback)
        {
            TCPStream stream = getModule!TCPStreamModule.tcp_streams.alloc(newName.move, cast(ObjectFlags)(ObjectFlags.Dynamic | ObjectFlags.Temporary));

            // assign the socket to the stream and bypass the startup process
            stream._socket = conn;
            conn.get_peer_name(stream._remote);
            stream._state = State.Running;
            getModule!TCPStreamModule.tcp_streams.add(stream);

            _connectionCallback(stream, _userData);
        }

        // TODO: should the stream we just created to into the stream pool...?
    }

private:
    alias NewRawConnection = void function(Socket client, void* userData) nothrow @nogc;

//    ServerOptions _options;
    ushort _port;
    NewConnection _connectionCallback;
//    NewRawConnection _rawConnectionCallback;
    void* _userData;
    Socket _serverSocket;

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

    Collection!TCPStream tcp_streams;
    Collection!TCPServer tcp_servers;

    override void init()
    {
        g_app.console.registerCollection("/stream/tcp-client", tcp_streams);
        g_app.console.registerCollection("/stream/tcp-server", tcp_servers);
    }

    override void preUpdate()
    {
        tcp_streams.updateAll();
    }

    override void update()
    {
        tcp_servers.updateAll();
    }
}
