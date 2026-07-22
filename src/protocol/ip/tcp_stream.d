module protocol.ip.tcp_stream;

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

import protocol.ip;

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
        mark_set!(typeof(this), [ "remote", "remote_address" ])();

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
        mark_set!(typeof(this), [ "remote", "remote_address" ])();

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
        mark_set!(typeof(this), "port")();
        if ((_remote.family == AddressFamily.ipv4 && _remote._a.ipv4.port == value) ||
            (_remote.family == AddressFamily.ipv6 && _remote._a.ipv6.port == value))
            return;
        update_port(_remote, _port);
        mark_set!(typeof(this), "remote_address")();

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
            mark_set!(typeof(this), "remote_address")();
        }

        // initiate the connection; completion arrives asynchronously via on_event
        if (_conn is null)
        {
            // we don't want to spam connection attempts...
            SysTime now = getSysTime();
            if (now < _last_retry + seconds(5))
                return CompletionStatus.continue_;
            _last_retry = now;

            _link = 0;
            _conn = tcp_connect(_remote, &on_data, &on_event);
            if (_conn is null)
                return CompletionStatus.continue_;     // no route / refused outright; retry later
            if (_keep_enable)
                _conn.enable_keepalive(_keep_enable, _keep_idle, _keep_interval, _keep_count);
        }

        if (_link < 0)
        {
            // the connect attempt failed; tear down and retry after the backoff
            close_conn();
            return CompletionStatus.continue_;
        }
        if (_link > 0)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    final override CompletionStatus shutdown()
    {
        if (_host)
        {
            _remote = InetAddress();
            mark_set!(typeof(this), "remote_address")();
        }
        close_conn();
        return CompletionStatus.complete;
    }

    final override void update()
    {
        if (_link < 0)
        {
            restart();
            return;
        }
        super.update();
    }

    final void enable_keep_alive(bool enable, Duration keep_idle = seconds(10), Duration keep_interval = seconds(1), int keep_count = 10)
    {
        _keep_enable = enable;
        _keep_idle = keep_idle;
        _keep_interval = keep_interval;
        _keep_count = keep_count;
        mark_set!(typeof(this), "keepalive")();
        if (_conn)
            _conn.enable_keepalive(enable, keep_idle, keep_interval, keep_count);
    }

    override ptrdiff_t write(const(void[])[] data...)
    {
        if (!running || _conn is null)
            return 0;

        size_t total = 0;
        foreach (b; data)
            total += b.length;

        ptrdiff_t n = _conn.send(data);
        if (n > 0)
        {
            add_tx_bytes(n);
            if (_logging)
            {
                import urt.util : min;
                ptrdiff_t remain = n;
                for (size_t i = 0; remain > 0; ++i)
                {
                    size_t len = min(data[i].length, remain);
                    write_to_log(false, data[i][0 .. len]);
                    remain -= len;
                }
            }
        }
        if (n < cast(ptrdiff_t)total)
            log.warning("stream '", name[], "': short write -- ", n, " of ", total, " bytes sent, ", total - n, " dropped");
        return n;
    }

private:
    TCPConnection* _conn;
    InetAddress _remote;
    ushort _port;
    SysTime _last_retry;
    String _host;
    byte _link;

    bool _keep_enable = false;
    int _keep_count = 10;
    Duration _keep_idle;
    Duration _keep_interval;

    void on_data(TCPConnection* conn, const(void)[] data, MonoTime rx_time)
    {
        incoming(data, rx_time);
    }

    void on_event(TCPConnection* conn, IPEvent event)
    {
        if (event == IPEvent.connected)
        {
            _link = 1;
            if (_state == State.starting)
                set_state(State.running);
        }
        else
            _link = -1;
    }

    void close_conn()
    {
        if (_conn)
        {
            _conn.close();
            _conn = null;
        }
        _link = 0;
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

    alias NewConnection = void delegate(Stream client, ref const InetAddress remote, void* user_data) nothrow @nogc;

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
        mark_set!(typeof(this), "port")();
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
        assert(_listener is null);
        _listener = tcp_listen(_port, &on_accept);
        if (_listener is null)
        {
            debug log.error("failed to listen on port ", _port);
            return CompletionStatus.error;
        }
        debug log.info("listening on port ", _port);
        return CompletionStatus.complete;
    }

    final override CompletionStatus shutdown()
    {
        if (_listener)
        {
            _listener.close();
            _listener = null;
        }
        return CompletionStatus.complete;
    }

protected:
//    ServerOptions _options;
    ushort _port;
    NewConnection _connection_callback;
    void* _user_data;
    TCPListener* _listener;

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags)
    {
        super(type_info, id, flags);
    }

    void on_accept(TCPListener* listener, TCPConnection* conn, MonoTime)
    {
        if (conn is null)
        {
            restart();
            return;
        }
        if (_connection_callback)
        {
            const InetAddress remote = conn.remote();
            Stream stream = create_stream(conn);
            if (stream)
                _connection_callback(stream, remote, _user_data);
        }
        else
            conn.close();
    }

    Stream create_stream(TCPConnection* conn)
    {
        // prevent duplicate stream names...
        const(char)[] newName = Collection!Stream().generate_name(name[]);

        TCPStream stream = cast(TCPStream)Collection!TCPStream().alloc(newName, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));

        // adopt the accepted connection and bypass the startup/connect process
        stream._conn = conn;
        stream._remote = conn.remote();
        stream._link = 1;
        conn.recv_handler(&stream.on_data);
        conn.event_handler(&stream.on_event);
        stream.set_state(State.running);
        Collection!TCPStream().add(stream);
        return stream;
    }
}
