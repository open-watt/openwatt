module protocol.ntp.client;

import urt.inet;
import urt.meta : AliasSeq;
import urt.socket;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

nothrow @nogc:


// SNTP (RFC 4330) unicast client
class NTPClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("server",   server),
                                 Prop!("port",     port),
                                 Prop!("interval", interval),
                                 Prop!("offset",   offset));
nothrow @nogc:

    enum type_name = "ntp-client";
    enum path = "/protocol/ntp/client";
    enum collection_id = CollectionType.ntp_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!NTPClient, id, flags);
        _port = 123;
        _interval = seconds(17 * 60);
    }

    // Properties

    final const(char)[] server() const pure
        => _server[];
    final void server(const(char)[] value)
    {
        if (_server[] == value)
            return;
        _server = value.makeString(g_app.allocator);
        mark_set!(typeof(this), "server")();
        restart();
    }

    final ushort port() const pure
        => _port;
    final void port(ushort value)
    {
        if (_port == value)
            return;
        _port = value;
        mark_set!(typeof(this), "port")();
        restart();
    }

    final Duration interval() const pure
        => _interval;
    final void interval(Duration value)
    {
        _interval = value;
        mark_set!(typeof(this), "interval")();
    }

    final Duration offset() const pure
        => _last_offset;

protected:

    override bool validate() const pure
        => _server.length > 0;

    override CompletionStatus startup()
    {
        IPAddr ip;
        size_t n = ip.fromString(_server[]);
        if (n == 0 || n != _server.length)
        {
            log.warning("invalid server address '", _server[], "'");
            return CompletionStatus.error;
        }
        _addr = InetAddress(ip, _port);

        Result r = create_socket(AddressFamily.ipv4, SocketType.datagram, Protocol.udp, _socket);
        if (r)
            r = _socket.set_socket_option(SocketOption.non_blocking, true);
        if (r)
            r = _socket.connect(_addr);
        if (!r)
        {
            if (_socket)
            {
                _socket.close();
                _socket = Socket.invalid;
            }
            return CompletionStatus.continue_;
        }

        _pending = false;
        _next_poll = getTime();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_socket)
        {
            _socket.close();
            _socket = Socket.invalid;
        }
        _pending = false;
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_socket)
            return;

        MonoTime now = getTime();

        if (_pending)
        {
            ubyte[48] buf = void;
            size_t bytes;
            if (_socket.recv(buf[], MsgFlags.none, &bytes))
            {
                if (apply_response(buf[0 .. bytes]))
                {
                    _pending = false;
                    _next_poll = now + _interval;
                }
            }
            else if (now - _request_time > response_timeout)
            {
                log.warning("no response from ", _server[], ':', _port);
                _pending = false;
                _next_poll = now + retry_interval;
            }
        }
        else if (now >= _next_poll)
            send_request(now);
    }

private:
    String   _server;
    ushort   _port;
    Duration _interval;
    Duration _last_offset;

    Socket      _socket = Socket.invalid;
    InetAddress _addr;
    MonoTime    _next_poll;
    MonoTime    _request_time;
    MonoTime    _t1;
    ulong       _nonce;
    bool        _pending;

    enum Duration response_timeout = seconds(4);
    enum Duration retry_interval   = seconds(30);

    void send_request(MonoTime now)
    {
        ubyte[48] pkt = 0;
        pkt[0] = 0x23; // LI=0, VN=4, Mode=3 (client)
        _nonce = now.ticks;
        store64_be(pkt[40 .. 48], _nonce); // transmit timestamp; echoed back as originate

        size_t sent;
        if (!_socket.send(pkt[], MsgFlags.none, &sent))
        {
            log.warning("send to ", _server[], ':', _port, " failed");
            _next_poll = now + retry_interval;
            return;
        }
        _pending = true;
        _request_time = now;
        _t1 = now;
    }

    bool apply_response(const(ubyte)[] buf)
    {
        if (buf.length < 48)
            return false;
        if ((buf[0] & 0x07) != 4) // mode must be 'server'
            return false;
        if (buf[1] == 0) // stratum 0 is kiss-o'-death / unsynchronised
            return false;
        if (load64_be(buf[24 .. 32]) != _nonce) // originate must echo our transmit timestamp
            return false;

        MonoTime t4 = getTime();
        long t2 = ntp_to_unix_ns(buf[32 .. 40]);
        long t3 = ntp_to_unix_ns(buf[40 .. 48]);

        // Subtract the server's processing (t3 - t2) from the round trip, halve
        // for one-way, anchor to its transmit timestamp (t3).
        long rtt = (t4 - _t1).as!"nsecs";
        ulong corrected = cast(ulong)(t3 + (rtt - (t3 - t2)) / 2);

        _last_offset = from_unix_time_ns(corrected) - getSysTime();
        mark_set!(typeof(this), "offset")();
        set_utc_time(corrected);

        log.info("synced from ", _server[], " offset ", _last_offset.as!"msecs", "ms");
        return true;
    }
}


private:

enum ulong ntp_unix_epoch_delta = 2_208_988_800UL; // seconds from 1900-01-01 to 1970-01-01

// NTP 64-bit timestamp (32.32 fixed-point seconds since 1900) -> unix nanoseconds.
// Era 0 only (valid 1968..2036); fine until the 2036 rollover is worth handling.
long ntp_to_unix_ns(const(ubyte)[] b)
{
    ulong ts = load64_be(b);
    ulong secs = ts >> 32;
    ulong frac = ts & 0xFFFF_FFFF;
    long unix_secs = cast(long)secs - cast(long)ntp_unix_epoch_delta;
    long frac_ns = cast(long)((frac * 1_000_000_000UL) >> 32);
    return unix_secs * 1_000_000_000L + frac_ns;
}

ulong load64_be(const(ubyte)[] b)
{
    ulong v = 0;
    foreach (i; 0 .. 8)
        v = (v << 8) | b[i];
    return v;
}

void store64_be(ubyte[] b, ulong v)
{
    foreach (i; 0 .. 8)
        b[i] = cast(ubyte)(v >> (56 - i * 8));
}
