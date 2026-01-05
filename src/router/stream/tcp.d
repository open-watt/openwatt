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
    __gshared Property[4] Properties = [ Property.create!("remote", remote)(),
                                         Property.create!("remote_address", remote_address)(),
                                         Property.create!("port", port)(),
                                         Property.create!("keepalive", keepalive)() ];
nothrow @nogc:

    alias TypeName = StringLit!"tcp";

    this(String name, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!TCPStream, name.move, flags, options);
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
    StringResult remote(String value)
    {
        if (value.empty)
            return StringResult("remote cannot be empty");
        if (value == _host)
            return StringResult();

        _host = value.move;
        _remote = InetAddress();

        restart();
        return StringResult();
    }

    InetAddress remote_address() const pure
        => _remote;

    ushort port() const pure
        => _port;
    void port(WellKnownPort value)
        => port(cast(ushort)value);
    void port(ushort value)
    {
        if (_port == value)
            return;

        _port = value;
        if ((_remote.family == AddressFamily.ipv4 && _remote._a.ipv4.port == value) ||
            (_remote.family == AddressFamily.ipv6 && _remote._a.ipv6.port == value))
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
        enable_keep_alive(value);
    }


    // API...

    final override bool validate() const pure
    {
        if (_remote != InetAddress())
        {
            if (!_host.empty)
                return false;
            if ((_remote.family == AddressFamily.ipv4 && _remote._a.ipv4.port != 0) ||
                (_remote.family == AddressFamily.ipv6 && _remote._a.ipv6.port != 0))
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
        if (_options & StreamOptions.reverse_connect)
        {
            assert(false);
            return CompletionStatus.continue_;
        }

        if (_remote == InetAddress())
        {
            assert(_host, "No remote set for TCP stream!");

            AddressInfo addr_info;
            addr_info.family = AddressFamily.ipv4;
            addr_info.sock_type = SocketType.stream;
            addr_info.protocol = Protocol.tcp;
            AddressInfoResolver results;
            get_address_info(_host, _port ? _port.tstring : null, &addr_info, results);
            if (!results.next_address(addr_info))
                return CompletionStatus.continue_;
            _remote = addr_info.address;

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
                return CompletionStatus.continue_;
            _last_retry = now;

            Result r = create_socket(AddressFamily.ipv4, SocketType.stream, Protocol.tcp, _socket);
            if (!r)
            {
                debug writeError(type, " '", name, "' - create_socket() failed with error: ", r.socket_result);
                return CompletionStatus.error;
            }

            set_socket_option(_socket, SocketOption.non_blocking, true);
            r = _socket.connect(_remote);
            if (!r.succeeded && r.socket_result != SocketResult.would_block)
            {
                debug writeWarning(type, " '", name, "' - connect() failed with error: ", r.socket_result);
                return CompletionStatus.error;
            }
        }

        // the socket is valid, but not live (waiting for connect() to complete)
        // we'll poll it to see if it connected...
        PollFd fd;
        fd.socket = _socket;
        fd.request_events = PollEvents.write;
        uint num_events;
        Result r = poll(fd, Duration.zero, num_events);
        if (r.failed)
        {
            debug writeError(type, " '", name, "' - poll() failed with error: ", r.socket_result);
            return CompletionStatus.error;
        }

        // no events returned, still waiting...
        if (num_events == 0)
            return CompletionStatus.continue_;

        // check error conditions
        if (fd.return_events & (PollEvents.error | PollEvents.hangup | PollEvents.invalid))
        {
            debug writeError(type, " '", name, "' - connection failed to ", _remote);
            return CompletionStatus.error;
        }

        // this should be the only case left, we've successfully connected!
        // let's just assert that the socket is writable to be sure...
        assert(fd.return_events & PollEvents.write);

        if (_keep_enable)
            set_keepalive(_socket, _keep_enable, _keep_idle, _keep_interval, _keep_count);

        return CompletionStatus.complete;
    }

    final override CompletionStatus shutdown()
    {
        if (_host)
            _remote = InetAddress();

        close_socket();

        if (_flags & ObjectFlags.temporary)
            destroy();

        return CompletionStatus.complete;
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
//        if (_reverse_connect_server !is null)
//        {
//            _reverse_connect_server.stop();
//            _reverse_connect_server = null;
//        }

        close_socket();
    }

    override const(char)[] remote_name()
    {
        return tstring(remote);
    }

    final void enable_keep_alive(bool enable, Duration keep_idle = seconds(10), Duration keep_interval = seconds(1), int keep_count = 10)
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
        if (_logging)
            write_to_log(true, buffer[0 .. bytes]);
        _status.recv_bytes += bytes;
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
            if (_logging)
                write_to_log(false, data[0 .. bytes]);
            return bytes;
        }

        if (_options & StreamOptions.buffer_data)
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
        if (r != Result.success)
        {
            SocketResult sr = r.socket_result;
            if (sr != SocketResult.would_block)
                restart();
            return 0;
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
//    TCPServer _reverse_connect_server;

    bool _keep_enable = false;
    int _keep_count = 10;
    Duration _keep_idle;
    Duration _keep_interval;

    void close_socket()
    {
        if (_socket == Socket.invalid)
            return;
        if (_state == State.stopping)
            _socket.shutdown(SocketShutdownMode.read_write);
        _socket.close();
        _socket = Socket.invalid;
    }

    bool update_port(ref InetAddress addr, ushort port)
    {
        if (addr.family == AddressFamily.ipv4)
        {
            addr._a.ipv4.port = port;
            return true;
        }
        else if (addr.family == AddressFamily.ipv6)
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

    alias NewConnection = void delegate(Stream client, void* user_data) nothrow @nogc;

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TCPServer, name.move, flags);
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

    void setConnectionCallback(NewConnection callback, void* user_data)
    {
        _connection_callback = callback;
        _user_data = user_data;
    }

    final override bool validate() const pure
        => _port != 0;

    final override CompletionStatus startup()
    {
        assert(!_ip4_listener);
        assert(!_ip6_listener);

        Result create(ref Socket sock)
        {
            Result r = create_socket(AddressFamily.ipv4, SocketType.stream, Protocol.tcp, sock);
            if (r.failed)
                return r;

            r = sock.set_socket_option(SocketOption.non_blocking, true);
            if (r.failed)
                return r;

            r = sock.set_socket_option(SocketOption.reuse_address, true);
            if (r.failed)
                return r;

            r = sock.bind(InetAddress(IPAddr.any, _port));
            if (r.failed)
                return r;

            r = sock.listen();
            if (r.failed)
                return r;
            return Result.success;
        }

        Result r = create(_ip4_listener);
        if (!r)
        {
            debug writeError(type, " '", name, "' - failed to create listening socket. Error ", r.systemCode);
            return CompletionStatus.error;
        }

        // TODO: option to disable this???
        r = create(_ip6_listener);
        if (!r)
        {
            // tolerate ipv6 failure... (do we want this?)
            if (_ip6_listener)
            {
                _ip6_listener.close();
                _ip6_listener = null;
            }
        }

        debug writeInfo(type, " '", name, "' - listening on port ", _port);
        return CompletionStatus.complete;
    }

    final override CompletionStatus shutdown()
    {
        if (_ip4_listener)
        {
            _ip4_listener.close();
            _ip4_listener = null;
        }
        if (_ip4_listener)
        {
            _ip4_listener.close();
            _ip4_listener = null;
        }
        return CompletionStatus.complete;
    }

    final override void update()
    {
        Socket conn;
        InetAddress remote_addr;
        Result r = _ip4_listener.accept(conn, &remote_addr);
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

        conn.set_socket_option(SocketOption.non_blocking, true);

//        if (_raw_connection_callback)
//            _raw_connection_callback(conn, user_data);
//        else if (_connection_callback)
        if (_connection_callback)
        {
            Stream stream = create_stream(conn);
            if (stream)
                _connection_callback(stream, _user_data);
        }

        // TODO: should the stream we just created to into the stream pool...?
        else
        {
            // TODO: if nobody is accepting connections; I guess we should just terminate them as they come?
            conn.shutdown(SocketShutdownMode.read_write);
            conn.close();
        }
    }

protected:
    alias NewRawConnection = void function(Socket client, void* user_data) nothrow @nogc;

//    ServerOptions _options;
    ushort _port;
    NewConnection _connection_callback;
//    NewRawConnection _raw_connection_callback;
    void* _user_data;
    Socket _ip4_listener;
    Socket _ip6_listener;

    this(const CollectionTypeInfo* type_info, String name, ObjectFlags flags)
    {
        super(type_info, name.move, flags);
    }

    Stream create_stream(Socket conn)
    {
        // prevent duplicate stream names...
        String newName = get_module!StreamModule.streams.generate_name(name).makeString(defaultAllocator());

        TCPStream stream = get_module!TCPStreamModule.tcp_streams.alloc(newName.move, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));

        // assign the socket to the stream and bypass the startup process
        stream._socket = conn;
        conn.get_peer_name(stream._remote);
        stream._state = State.running;
        get_module!TCPStreamModule.tcp_streams.add(stream);
        return stream;
    }
}


class TCPStreamModule : Module
{
    mixin DeclareModule!"stream.tcp";
nothrow @nogc:

    Collection!TCPStream tcp_streams;
    Collection!TCPServer tcp_servers;

    override void init()
    {
        g_app.console.register_collection("/stream/tcp-client", tcp_streams);
        g_app.console.register_collection("/stream/tcp-server", tcp_servers);
    }

    override void pre_update()
    {
        tcp_streams.update_all();
    }

    override void update()
    {
        tcp_servers.update_all();
    }
}
