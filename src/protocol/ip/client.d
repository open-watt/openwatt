module protocol.ip.client;

import urt.conv : parse_int;
import urt.string : findFirst;
import urt.inet;
import urt.lifetime;
import urt.mem.temp : tconcat;
import urt.result;
import urt.string;
import urt.string.format;

import manager.base;
import manager.collection;
import manager.expression : NamedArgument;
import manager.features;

import protocol.ip.tcp_stream : TCPStream;

import router.stream : Stream;

nothrow @nogc:


// Outbound IP connection helper. Owns a Stream-typed reference to a TCP or
// TLS connection, host/port/addr config, and the subscribe-and-restart
// lifecycle. Used by clients that connect out to a remote IP endpoint
// (HTTP, MQTT, Modbus-TCP, ESPHome, Tesla, etc.).
struct IPClient
{
nothrow @nogc:
    @disable this(this);

    inout(Stream) get() inout pure
        => _stream;
    alias get this;

    bool has_remote() const pure
        => !_host.empty || _addr != InetAddress();

    ref const(String) host() const pure
        => _host;
    InetAddress addr() const pure
        => _addr;
    ushort port() const pure
        => _port;
    bool keepalive() const pure
        => _keepalive;

    const(char)[] remote_name() const
    {
        if (!_host.empty)
            return _host[];
        if (_addr != InetAddress())
        {
            const(char)[] s = tstring(_addr);
            // InetAddress.toString always emits :port; trim it for an unset port
            if (s.length >= 2 && s[$ - 2 .. $] == ":0")
                s = s[0 .. $ - 2];
            return s;
        }
        return null;
    }

    StringResult remote(String value)
    {
        if (value.empty)
            return StringResult("remote cannot be empty");
        InetAddress addr;
        if (addr.fromString(value[]) == value.length)
        {
            _addr = addr;
            _host = null;
            return StringResult.success;
        }
        _host = value.move;
        _addr = InetAddress();
        return StringResult.success;
    }
    void remote(InetAddress value)
    {
        _addr = value;
        _host = null;
    }
    void port(ushort value)
    {
        _port = value;
    }
    void keepalive(bool value)
    {
        _keepalive = value;
        if (auto tcp = cast(TCPStream)_stream)
            tcp.keepalive = value;
        static if (has_tls)
        {
            import protocol.tls : TLSStream;
            if (auto t = cast(TLSStream)_stream)
                t.keepalive = value;
        }
    }

    bool start(ActiveObject owner, ushort default_port = 0, bool tls = false)
    {
        if (_stream)
            return true;
        if (!has_remote())
            return false;

        _owner = owner;

        // split ":port" out of the host so the inner stream gets host + port separately
        ushort embedded_port = 0;
        const(char)[] clean_host = _host.empty ? null : parse_host_port(_host[], embedded_port);

        ushort addr_port = 0;
        if (_addr != InetAddress())
        {
            if (_addr.family == AddressFamily.ipv4)
                addr_port = _addr._a.ipv4.port;
            else if (_addr.family == AddressFamily.ipv6)
                addr_port = _addr._a.ipv6.port;
        }

        ushort use_port = _port != 0 ? _port : embedded_port != 0 ? embedded_port : addr_port != 0 ? addr_port : default_port;
        const(char)[] new_name = Collection!Stream().generate_name(owner.name[]);

        if (tls)
        {
            static if (!has_tls)
                return false;
            else
            {
                import protocol.tls : TLSStream;
                const(char)[] host_with_port;
                if (!clean_host.empty)
                {
                    host_with_port = use_port != 0 ? tconcat(clean_host, ":", use_port) : clean_host;
                }
                else if (_addr != InetAddress())
                {
                    InetAddress a = _addr;
                    if (use_port != 0)
                    {
                        if (a.family == AddressFamily.ipv4)
                            a._a.ipv4.port = use_port;
                        else if (a.family == AddressFamily.ipv6)
                            a._a.ipv6.port = use_port;
                    }
                    host_with_port = tstring(a);
                }
                else
                    return false;

                _stream = cast(Stream)Collection!TLSStream().create(new_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
                    NamedArgument("remote", host_with_port), NamedArgument("keepalive", _keepalive));
            }
        }
        else if (!clean_host.empty)
        {
            if (use_port != 0)
                _stream = cast(Stream)Collection!TCPStream().create(new_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
                    NamedArgument("remote", clean_host), NamedArgument("port", use_port), NamedArgument("keepalive", _keepalive));
            else
                _stream = cast(Stream)Collection!TCPStream().create(new_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
                    NamedArgument("remote", clean_host), NamedArgument("keepalive", _keepalive));
        }
        else
        {
            if (use_port != 0)
                _stream = cast(Stream)Collection!TCPStream().create(new_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
                    NamedArgument("remote", _addr), NamedArgument("port", use_port), NamedArgument("keepalive", _keepalive));
            else
                _stream = cast(Stream)Collection!TCPStream().create(new_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
                    NamedArgument("remote", _addr), NamedArgument("keepalive", _keepalive));
        }

        if (!_stream)
            return false;

        _stream.subscribe(&on_state_change);
        _subscribed = true;
        return true;
    }

    void stop()
    {
        if (_stream is null)
            return;
        if (_subscribed)
        {
            _stream.unsubscribe(&on_state_change);
            _subscribed = false;
        }
        _stream.destroy();
        _stream = null;
    }

    void clear_remote()
    {
        stop();
        _host = null;
        _addr = InetAddress();
        _port = 0;
    }

private:
    ActiveObject _owner;
    Stream _stream;
    String _host;
    InetAddress _addr;
    ushort _port;
    bool _keepalive;
    bool _subscribed;

    void on_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
        {
            _subscribed = false;
            _stream = null;
            if (_owner)
                _owner.restart();
        }
    }
}


const(char)[] parse_host_port(const(char)[] s, out ushort port) pure nothrow @nogc
{
    auto colon = s.findFirst(':');
    if (colon < s.length)
    {
        size_t taken;
        long p = s[colon + 1 .. $].parse_int(&taken);
        if (p > 0 && p <= ushort.max && taken == s.length - colon - 1)
        {
            port = cast(ushort)p;
            return s[0 .. colon];
        }
    }
    return s;
}
