module router.stream.tcp;

import urt.array;
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

//version = DebugTCPStream;       // TCPStream write/queue/drain activity

nothrow @nogc:


class TCPStream : Stream
{
    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("remote_address", remote_address),
                                 Prop!("port", port),
                                 Prop!("keepalive", keepalive));
nothrow @nogc:

    enum type_name = "tcp";
    enum path = "/stream/tcp-client";

    this(CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!TCPStream, id, flags, options);
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
            get_address_info(_host[], _port ? _port.tstring : null, &addr_info, results);
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
                debug log.error("create_socket() failed with error: ", r.socket_result);
                return CompletionStatus.error;
            }

            set_socket_option(_socket, SocketOption.non_blocking, true);
            r = _socket.connect(_remote);
            if (!r.succeeded && r.socket_result != SocketResult.would_block)
            {
                if (r.socket_result == SocketResult.network_unreachable || r.socket_result == SocketResult.host_unreachable)
                {
                    close_socket();
                    return CompletionStatus.continue_;
                }
                debug log.warning("connect() failed with error: ", r.socket_result);
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
            debug log.error("poll() failed with error: ", r.socket_result);
            return CompletionStatus.error;
        }

        // no events returned, still waiting...
        if (num_events == 0)
            return CompletionStatus.continue_;

        // check error conditions
        if (fd.return_events & (PollEvents.error | PollEvents.hangup | PollEvents.invalid))
        {
            debug log.error("connection failed to ", _remote);
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
            return;
        }

        if (_pending.length > 0)
            drain_pending();

        super.update();
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
        if (!_host.empty)
            return tstring(remote);
        return tstring(_remote);
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
        add_rx_bytes(bytes);
        return bytes;
    }

    override ptrdiff_t write(const(void[])[] data...)
    {
        if (!running)
            return 0;

        if (_pending.length > 0 && !drain_pending())
            return 0;

        size_t total = 0;
        foreach (b; data)
            total += b.length;
        if (total == 0)
            return 0;

        if (_pending.length > 0)
        {
            if (_pending.length + total > MaxPendingBytes)
            {
                version (DebugTCPStream)
                    log.warning("write ", total, "B refused: pending=", _pending.length, " cap=", MaxPendingBytes);
                return 0;
            }
            foreach (b; data)
                _pending ~= cast(const(ubyte)[])b;
            version (DebugTCPStream)
                log.trace("write ", total, "B fully queued (socket still full); pending=", _pending.length);
            return total;
        }

        size_t bytes;
        Result r = _socket.send(MsgFlags.none, &bytes, data);
        if (r.failed && r.socket_result != SocketResult.would_block)
        {
            version (DebugTCPStream)
                log.warning("send failed: ", r.socket_result, "; restarting");
            restart();
            return 0;
        }

        if (bytes > 0)
        {
            add_tx_bytes(bytes);
            if (_logging)
            {
                import urt.util : min;
                ptrdiff_t remain = bytes;
                for (size_t i = 0; remain > 0; ++i)
                {
                    size_t len = min(data[i].length, remain);
                    write_to_log(false, data[i][0 .. len]);
                    remain -= len;
                }
            }
        }

        size_t unaccepted = total - bytes;
        if (unaccepted > 0)
        {
            if (unaccepted > MaxPendingBytes)
            {
                version (DebugTCPStream)
                    log.warning("write ", total, "B partial: accepted=", bytes, " unaccepted=", unaccepted, " exceeds cap=", MaxPendingBytes);
                return bytes;
            }
            size_t skipped = 0;
            foreach (b; data)
            {
                if (skipped + b.length <= bytes)
                {
                    skipped += b.length;
                    continue;
                }
                size_t off = bytes > skipped ? bytes - skipped : 0;
                _pending ~= (cast(const(ubyte)[])b)[off .. $];
                skipped += b.length;
            }
            version (DebugTCPStream)
                log.trace("write ", total, "B: socket took ", bytes, ", queued tail ", unaccepted, "; pending=", _pending.length);
        }
        else
        {
            version (DebugTCPStream)
            {
                if (total > 0)
                    log.trace("write ", total, "B accepted by socket");
            }
        }

        return total;
    }

    override ptrdiff_t pending()
    {
        if (!running)
            return 0;

        size_t bytes;
        Result r = .pending(_socket, bytes);
        if (r != Result.success)
        {
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
    enum size_t MaxPendingBytes = 256 * 1024;

    Socket _socket;
    InetAddress _remote;
    ushort _port;
    SysTime _last_retry;
    String _host;
    Array!ubyte _pending;
//    TCPServer _reverse_connect_server;

    bool _keep_enable = false;
    int _keep_count = 10;
    Duration _keep_idle;
    Duration _keep_interval;

    bool drain_pending()
    {
        version (DebugTCPStream)
            size_t initial = _pending.length;

        while (_pending.length > 0)
        {
            size_t sent;
            Result r = _socket.send(MsgFlags.none, &sent, cast(const(void)[])_pending[]);
            if (r.failed && r.socket_result != SocketResult.would_block)
            {
                version (DebugTCPStream)
                    log.warning("drain failed: ", r.socket_result, "; restarting (pending=", _pending.length, ')');
                restart();
                return false;
            }
            if (sent == 0)
            {
                version (DebugTCPStream)
                    log.trace("drain stalled: socket full, pending=", _pending.length);
                return true;
            }
            add_tx_bytes(sent);
            if (_logging)
                write_to_log(false, _pending[0 .. sent]);
            _pending.remove(0, sent);
        }

        version (DebugTCPStream)
        {
            if (initial > 0)
                log.trace("drained ", initial, "B fully");
        }
        return true;
    }

    void close_socket()
    {
        _pending.clear();
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

class TCPServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("port", port));

nothrow @nogc:

    enum type_name = "tcp-server";
    enum path = "/stream/tcp-server";
    enum collection_id = CollectionType.tcp_server;

    alias NewConnection = void delegate(Stream client, void* user_data) nothrow @nogc;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TCPServer, id, flags);
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

    void set_connection_callback(NewConnection callback, void* user_data)
    {
        _connection_callback = callback;
        _user_data = user_data;
    }

    override bool validate() const pure
        => _port != 0;

    override CompletionStatus startup()
    {
        assert(!_ip4_listener);
        assert(!_ip6_listener);

        Result create(AddressFamily af, ref Socket sock)
        {
            Socket s;
            Result r = create_socket(af, SocketType.stream, Protocol.tcp, s);

            if (!r.failed)
                r = s.set_socket_option(SocketOption.non_blocking, true);
            if (!r.failed)
                r = s.set_socket_option(SocketOption.reuse_address, true);

            if (!r.failed)
            {
                if (af == AddressFamily.ipv4)
                    r = s.bind(InetAddress(IPAddr.any, _port));
                else if (af == AddressFamily.ipv6)
                    r = s.bind(InetAddress(IPv6Addr.any, _port));
                else
                    assert(false);
            }

            if (!r.failed)
                r = s.listen();

            if (r.failed)
                s.close();
            else
                sock = s;
            return r;
        }

        Result r = create(AddressFamily.ipv4, _ip4_listener);
        if (!r)
        {
            debug log.error("failed to create listening socket. Error ", r.system_code);
            return CompletionStatus.error;
        }

        // TODO: option to disable this???
        r = create(AddressFamily.ipv6, _ip6_listener);
        if (!r)
        {
            // tolerate ipv6 failure... (do we want this?)
            log.info("failed to create IPv6 listener: ", r.system_code);
//            if (_ip4_listener)
//            {
//                _ip4_listener.close();
//                _ip4_listener = null;
//            }
//            return CompletionStatus.error;
        }

        debug log.info("listening on port ", _port);
        return CompletionStatus.complete;
    }

    final override CompletionStatus shutdown()
    {
        if (_ip4_listener)
        {
            _ip4_listener.close();
            _ip4_listener = null;
        }
        if (_ip6_listener)
        {
            _ip6_listener.close();
            _ip6_listener = null;
        }
        return CompletionStatus.complete;
    }

    final override void update()
    {
        while (true)
        {
            Socket conn;
            InetAddress remote_addr;
            Result r = _ip4_listener.accept(conn, &remote_addr);
            if (r.failed && r.socket_result == SocketResult.would_block && _ip6_listener)
                r = _ip6_listener.accept(conn, &remote_addr);

            if (r.failed)
            {
                if (r.socket_result != SocketResult.would_block)
                    restart();
                return;
            }
            assert(conn);

            // if this was a temporary server. maybe we destroy it now?
//            if (options & ServerOptions.JustOne)
//                stop();

            conn.set_socket_option(SocketOption.non_blocking, true);

//            if (_raw_connection_callback)
//                _raw_connection_callback(conn, user_data);
//            else if (_connection_callback)
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

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags)
    {
        super(type_info, id, flags);
    }

    Stream create_stream(Socket conn)
    {
        // prevent duplicate stream names...
        const(char)[] newName = Collection!Stream().generate_name(name[]);

        TCPStream stream = cast(TCPStream)Collection!TCPStream().alloc(newName, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));

        // assign the socket to the stream and bypass the startup process
        stream._socket = conn;
        conn.get_peer_name(stream._remote);
        stream.set_state(State.running);
        Collection!TCPStream().add(stream);
        return stream;
    }
}


class TCPStreamModule : Module
{
    mixin DeclareModule!"stream.tcp";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!TCPStream();
        g_app.console.register_collection!TCPServer();
    }

    override void update()
    {
        Collection!TCPServer().update_all();
    }
}
