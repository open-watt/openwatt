module protocol.esphome.client;

import urt.array;
import urt.conv;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.result;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.system : hostname;

import protocol.esphome;
import protocol.esphome.protobuf;

import router.stream;
import router.stream.tcp;

//version = DebugESPHomeClient;

nothrow @nogc:


alias ESPHomeMessageHandler = void delegate(uint msg_type, const(ubyte)[] payload);


class ESPHomeClient : BaseObject
{
    __gshared Property[4] Properties = [ Property.create!("remote", remote)(),
                                         Property.create!("port", port)(),
                                         Property.create!("server_name", server_name)(),
                                         Property.create!("server_info", server_info)() ];
nothrow @nogc:

    enum type_name = "esphome";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ESPHomeClient, name.move, flags);
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

    const(char)[] server_name() const pure
        => _server_name[];

    const(char)[] server_info() const pure
        => _server_info[];

    // API...

    // alias the base functions into this scope to merge the overload sets
    alias subscribe = typeof(super).subscribe;
    alias unsubscribe = typeof(super).unsubscribe;

    void subscribe(ESPHomeMessageHandler handler)
    {
        assert(!_subscribers[].contains(handler), "Already registered");
        _subscribers ~= handler;
    }

    void unsubscribe(ESPHomeMessageHandler handler)
    {
        _subscribers.removeFirstSwapLast(handler);
    }

    ptrdiff_t send_message(Msg)(auto ref const Msg msg)
    {
        assert(is(typeof(Msg.id)), "Msg must have an `id` option member");

        ubyte[] encode;
        Array!ubyte overflow;
        ubyte[256] buffer = void;

        size_t len = buffer_len(msg);
        if (len > buffer.sizeof)
            encode = overflow.extend(len);
        else
            encode = buffer[0 .. len];

        size_t enc_len = proto_serialise(encode, msg);
        if (enc_len != len)
            return -1;
        return send_frame(Msg.id, encode[0 .. len]);
    }

    void terminate()
    {
        if (_state < 2)
            send_message(DisconnectRequest());
        if (_state == 3)
            restart();
    }

protected:

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

    override CompletionStatus startup()
    {
        if (!_stream)
        {
            // TODO: if _host and _port, then we need to stick the port on the end of the host string... (truncate if there's one already there!)

            const(char)[] new_name = get_module!StreamModule.streams.generate_name(name[]);
            _stream = get_module!TCPStreamModule.tcp_streams.create(new_name, ObjectFlags.dynamic, NamedArgument("remote", _host ? Variant(_host) : Variant(_remote)), NamedArgument("port", Variant(_port)));
            _stream.subscribe(&stream_state_handler);
            version (DebugESPHomeClient)
                writeDebug("esphome - created tcp stream with name: ", new_name);
            if (!_stream)
                return CompletionStatus.error;
        }
        if (_stream.running)
        {
            if (_state == 0)
            {
                if (!send_hello())
                    return CompletionStatus.error;
            }
            else
                service_stream();

            if (_state == 2)
                return CompletionStatus.complete;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        version (DebugESPHomeClient)
            writeDebug("esphome - client shutdown: ", name[]);

        _major = _minor = 0;
        _server_info = null;
        _server_name = null;
        _state = 0;

        if (_stream)
        {
            _stream.unsubscribe(&stream_state_handler);
            _stream.destroy();
            _stream = null;
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_stream || !_stream.running)
        {
            restart();
            return;
        }

        MonoTime now = getTime();

        service_stream();

        if (now - last_contact_time > 1.seconds)
            send_message(PingRequest());
    }

private:
    Array!ubyte _tail;
    Stream _stream;

    Array!ESPHomeMessageHandler _subscribers;

    String _host;
    InetAddress _remote;
    ushort _port = 6053;

    ubyte _state = 0;

    uint _major, _minor;
    String _server_info;
    String _server_name;

    MonoTime last_contact_time;

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

    ptrdiff_t send_frame(uint msg_type, const(ubyte)[] payload)
    {
        ubyte[11] header = void;
        header[0] = 0;
        ptrdiff_t written = write_var_int(cast(uint)payload.length, header[1 .. $]);
        assert(written > 0);
        ptrdiff_t written2 = write_var_int(msg_type, header[1 + written .. $]);
        assert(written2 > 0);
        ptrdiff_t sent = _stream.write(header[0 .. 1 + written + written2], payload[]);
        if (sent != 1 + written + written2 + payload.length)
            return -1;
        return sent;
    }

    void service_stream()
    {
        // check for data
        ubyte[1024] buffer = void;
        assert(_tail.length <= buffer.length);
        buffer[0 .. _tail.length] = _tail[]; // TODO: what if message is longer than the stack buffer?
        ptrdiff_t length = _tail.length;
        _tail.clear();
        read_loop: while (true)
        {
            ptrdiff_t r = _stream.read(buffer[length .. $]);
            if (r < 0)
            {
                assert(false, "TODO: what causes read to fail?");
                break read_loop;
            }
            if (r == 0)
            {
                // if there were no extra bytes available, stash the _tail until later
                _tail = buffer[0 .. length];
                break read_loop;
            }
            length += r;
            assert(length <= buffer.sizeof);

//            if (connParams.logDataStream)
//                logStream.rawWrite(buffer[0 .. length]);

            ubyte[] frame = buffer[0 .. length];
            while (!frame.empty)
            {
                size_t offset = 1;

                if (frame[0] == 0)
                {
                    uint payload_len, msg_type;
                    ptrdiff_t taken = frame[offset..$].take_var_int(payload_len);
                    if (taken <= 0)
                        break;
                    offset += taken;
                    taken = frame[offset..$].take_var_int(msg_type);
                    if (taken <= 0)
                        break;
                    offset += taken;

                    if (payload_len > frame.length - offset)
                        break;
                    incoming_frame(msg_type, frame[offset .. offset + payload_len]);
                    offset += payload_len;
                }
                else
                {
                    // noise frame
                    assert(false, "TODO");
                }

                frame = frame[offset .. $];
            }

            length = frame.length;
            if (length > 0)
                memmove(buffer.ptr, frame.ptr, length);
        }
    }

    void incoming_frame(uint msg_type, const(ubyte)[] frame)
    {
        last_contact_time = getTime();

        switch (msg_type)
        {
            case HelloRequest.id:
                // why did we receive a hello from the server? just ignore it, I guess?
                break;

            case HelloResponse.id:
                HelloResponse res;
                if (proto_deserialise(frame, res) != frame.length)
                    assert(false, "what here?");

                _major = res.api_version_major;
                _minor = res.api_version_minor;
                _server_info = res.server_info.move;
                _server_name = res.name.move;

                version (DebugESPHomeClient)
                    writeDebug("esphome ", name[], " - received hello response from server: ", _server_name[], " (", _server_info[], ") with API version ", _major, ".", _minor);

                _state = 2;
                break;

            case DisconnectRequest.id:
                version (DebugESPHomeClient)
                    writeDebug("esphome ", name[], " - received disconnect request from server, shutting down client");
                send_message(DisconnectResponse());
                _state = 3;
                terminate();
                break;

            case DisconnectResponse.id:
                _state = 3;
                terminate();
                break;

            case PingRequest.id:
                version (DebugESPHomeClient)
                    writeDebug("esphome ", name[], " - received ping request from server");
                send_message(PingResponse());
                break;

            case PingResponse.id:
                // nothing; we just updated `last_contact_time`
                break;

            case GetTimeRequest.id:
                version (DebugESPHomeClient)
                    writeDebug("esphome ", name[], " - received get time request from server");
                GetTimeResponse res;
                res.epoch_seconds = cast(uint)(getSysTime().unixTimeNs() / 1_000_000_000);
                res.timezone = StringLit!"AEST-10"; // TODO: we need to get the proper timezone...
                send_message(res);
                break;

            default:
                foreach (ref sub; _subscribers)
                    sub(msg_type, frame);
                break;
        }
    }

    void stream_state_handler(BaseObject object, StateSignal signal)
    {
        if (signal == StateSignal.offline)
        {
            _state = 0;
            set_state(State.starting);
        }
        else if (signal == StateSignal.destroyed)
        {
            _stream.unsubscribe(&stream_state_handler);
            _stream = null;
            restart();
        }
    }

    bool send_hello()
    {
        HelloRequest req;
        req.client_info = hostname;
        req.api_version_major = 1;
        req.api_version_minor = 14;

        if (send_message(req) < 0)
            return false;

        _state = 1;
        return true;
    }
}


private:

ptrdiff_t take_var_int(const(ubyte)[] data, out uint value)
{
    value = 0;
    uint shift = 0;
    uint i = 0;
    while (i < data.length)
    {
        ubyte b = data[i++];
        value |= (uint(b & 0x7F) << shift);
        if ((b & 0x80) == 0)
            return i;
        shift += 7;
        if (shift >= 32)
            break; // varint too long
    }
    return -1;
}

ptrdiff_t write_var_int(uint value, ubyte[] data)
{
    size_t i = 0;
    while (true)
    {
        if (i >= data.length)
            return -1; // not enough space
        ubyte b = value & 0x7F;
        value >>= 7;
        if (value != 0)
            b |= 0x80;
        data[i++] = b;
        if (value == 0)
            break;
    }
    return i;
}
