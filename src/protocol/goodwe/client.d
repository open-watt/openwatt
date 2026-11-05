module protocol.goodwe.client;

import urt.array;
import urt.conv;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.meta;
import urt.result;
import urt.si;
import urt.socket;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;

import protocol.goodwe : GoodWeModule;
import protocol.goodwe.message;
import protocol.goodwe.aa55;

import router.stream;

//version = DebugAA55;

nothrow @nogc:


alias GoodWeResponse = void delegate(bool success, ref const GoodWeRequest request, MonoTime response_time, const(ubyte)[] response_data, void* user_data) nothrow @nogc;

enum GoodWeIdentity : ubyte { aa55, modbus }

enum GoodWeWire : ubyte { aa55, module_, modbus }
enum GoodWePriority : ubyte { background, realtime }

struct GoodWeRequest
{
    MonoTime request_time;
    ubyte source_addr = 0xC0;
    ubyte dest_addr = 0x7F;
    GoodWeControlCode control_code;
    GoodWeFunctionCode function_code;
    GoodWeWire wire;
    ubyte response_function;
    GoodWePriority priority = GoodWePriority.realtime;
    ushort address;
    ushort count_or_value;

private:
    Array!ubyte frame;
    // TODO: multiple `read` requests can stack on to in-flight requests
    //       we should keep a list of callback/userdata and append for each request; and callback all waiting on response
    GoodWeResponse callback;
    void* user_data;
}


final class GoodWeClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("remote", remote), Prop!("manual", manual), Prop!("trace", trace), Prop!("identity", identity));
nothrow @nogc:
    ~this() {}

    enum type_name = "goodwe-client";
    enum path = "/protocol/goodwe/client";
    enum collection_id = CollectionType.aa55;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!GoodWeClient, id, flags);
    }

    // Properties

    ref const(String) remote() const pure
        => _host; // TODO: RETURNS NOTHING IF _remote IS SET!
    void remote(InetAddress value)
    {
        _host = null;
        if (value == _remote)
            return;
        _remote = value;
        mark_set!(typeof(this), "remote")();

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
        mark_set!(typeof(this), "remote")();

        restart();
        return null;
    }

    GoodWeIdentity identity() const pure { return _identity; }
    void identity(GoodWeIdentity value)
    {
        if (_identity == value)
            return;
        _identity = value;
        mark_set!(typeof(this), "identity")();
        restart();
    }

    // API

    bool manual() const pure => _manual;
    void manual(bool value)
    {
        _manual = value;
        _last_activity = getTime();
        _experiment_response.clear();
    }

    bool trace() const pure => _trace;
    void trace(bool value) { _trace = value; }

    const(ubyte)[] experiment_response() const => _experiment_response[];

    const(char)[] transmit_raw(const(ubyte)[] data)
    {
        if (!_manual || !running)
            return "client must be running with manual=true";
        if (_pending_requests.length)
            return "normal requests are draining; retry shortly";
        if (!data.length || data.length > 4096)
            return "datagram must contain 1..4096 bytes";
        _experiment_response.clear();
        size_t sent;
        Result r = get_module!GoodWeModule.aa55_socket.sendto(data, MsgFlags.none, &_remote, &sent);
        if (!r || sent != data.length)
            return "send failed";
        log.info("experiment tx ", _remote, " ", cast(const(void)[])data);
        return null;
    }

    void cancel_requests(GoodWeResponse callback)
    {
        for (size_t i; i < _pending_requests.length; )
            if (_pending_requests[i].callback == callback)
                _pending_requests.remove(i);
            else
                ++i;
        g_app.schedule(getTime(), &send_next);
    }

    bool read_in_flight(GoodWeFunctionCode function_code)
    {
        foreach (ref req; _pending_requests)
        {
            if (req.wire == GoodWeWire.aa55 && req.control_code == GoodWeControlCode.read && req.function_code == function_code)
                return true;
        }
        return false;
    }

    bool match_server(ref const InetAddress sender) const pure
        => _remote == sender;

    bool send_request(GoodWeControlCode control_code, GoodWeFunctionCode function_code, const(ubyte)[] data, GoodWeResponse callback, void* user_data = null, int response_function = -1, GoodWePriority priority = GoodWePriority.realtime)
    {
        if (!_active || _manual)
            return false;
        if (!callback || data.length > 255)
            return false;
        foreach (ref pending; _pending_requests)
            if (pending.wire == GoodWeWire.aa55 && pending.control_code == control_code && pending.function_code == function_code)
                return false;

        GoodWeRequest req;
        req.source_addr = _source_addr;
        req.dest_addr = 0x7F;
        req.control_code = control_code;
        req.function_code = function_code;
        if (control_code == GoodWeControlCode.read && function_code == GoodWeFunctionCode.read_registers && data.length == 3)
        {
            req.address = cast(ushort)((uint(data[0]) << 8) | data[1]);
            req.count_or_value = data[2];
        }
        req.callback = callback;
        req.priority = priority;
        req.user_data = user_data;
        req.response_function = cast(ubyte)(response_function < 0 ? (cast(ubyte)function_code | 0x80) : response_function);

        return send_request_internal(req, data);
    }

    bool send_module(ubyte fn, const(ubyte)[] payload, GoodWeResponse callback, void* user_data = null, GoodWePriority priority = GoodWePriority.realtime, ubyte family = 1)
    {
        if (!_active || _manual || !callback || payload.length > 1024 || fn >= 0x80 || (family != 1 && family != 2))
            return false;
        foreach (ref pending; _pending_requests)
            if (pending.wire == GoodWeWire.module_ && cast(ubyte)pending.control_code == family && cast(ubyte)pending.function_code == fn)
                return false;
        GoodWeRequest request;
        request.wire = GoodWeWire.module_;
        request.control_code = cast(GoodWeControlCode)family;
        request.address = payload.length == 1 ? cast(ushort)(payload[0] + 1) : 0;
        request.function_code = cast(GoodWeFunctionCode)fn;
        request.response_function = fn | 0x80;
        request.callback = callback;
        request.priority = priority;
        request.user_data = user_data;
        ubyte[1032] buffer = void;
        GoodWeModuleMessage message = GoodWeModuleMessage(payload, fn, family);
        return transmit(request, buffer[0 .. message.encode(buffer)]);
    }

    bool send_modbus(ubyte fn, ushort address, ushort count_or_value, const(ubyte)[] values, GoodWeResponse callback, void* user_data = null, ubyte unit = 0xF7, GoodWePriority priority = GoodWePriority.realtime)
    {
        if (!_active || _manual || !callback || (fn != 3 && fn != 4 && fn != 6 && fn != 16))
            return false;
        if (((fn == 3 || fn == 4) && (!count_or_value || count_or_value > 125 || values.length)) ||
            (fn == 6 && values.length) ||
            (fn == 16 && (!count_or_value || count_or_value > 123 || values.length != count_or_value * 2)))
            return false;
        GoodWeRequest request;
        request.wire = GoodWeWire.modbus;
        request.dest_addr = unit;
        request.function_code = cast(GoodWeFunctionCode)fn;
        request.address = address;
        request.count_or_value = count_or_value;
        request.callback = callback;
        request.priority = priority;
        request.user_data = user_data;
        ubyte[251] payload = void;
        payload[0] = cast(ubyte)(address >> 8);
        payload[1] = cast(ubyte)address;
        payload[2] = cast(ubyte)(count_or_value >> 8);
        payload[3] = cast(ubyte)count_or_value;
        size_t length = 4;
        if (fn == 16)
        {
            payload[4] = cast(ubyte)values.length;
            payload[5 .. 5 + values.length] = values;
            length += 1 + values.length;
        }
        ubyte[256] buffer = void;
        GoodWeModbusMessage message = GoodWeModbusMessage(payload[0 .. length], unit, fn);
        return transmit(request, buffer[0 .. message.encode(buffer)]);
    }

protected:

    override bool validate() const pure
        => !_host.empty || (_remote != InetAddress() && _remote.family == AddressFamily.ipv4);

    override CompletionStatus startup()
    {
        if (_remote._a.ipv4.port == 0)
        {
            // TODO: 48899 is also in use in some models; we should probably try both?

            if (_remote == InetAddress())
            {
                assert(_host, "valide shouldn't have succeeded if host is null");

                const(char)[] host = _host[];
                ushort port = 0;

                size_t colon = host.findFirst(":");
                if (colon != host.length)
                {
                    size_t taken;
                    long i = host[colon + 1 .. $].parse_int(&taken);
                    if (i > ushort.max || taken != host.length - colon - 1)
                        return CompletionStatus.error;
                    port = cast(ushort)i;
                    host = host[0 .. colon];
                }

                if (port == 0)
                    port = 8899;

                AddressInfo addrInfo;
                addrInfo.family = AddressFamily.ipv4;
                AddressInfoResolver results;
                get_address_info(host, null, &addrInfo, results);
                if (!results.next_address(addrInfo))
                    return CompletionStatus.continue_;

                _remote = InetAddress(addrInfo.address._a.ipv4.addr, port);
            }
            else
                _remote._a.ipv4.port = 8899;
        }

        // Check if we're active (received a response)
        if (_active)
            return CompletionStatus.complete;

        MonoTime now = getTime();

        if (!_identity_requested)
        {
            _identity_requested = true;
            _last_activity = now;

            GoodWeRequest req;
            req.source_addr = _source_addr;
            req.dest_addr = 0x7F;
            req.control_code = GoodWeControlCode.read;
            req.function_code = GoodWeFunctionCode.id_info;
            req.callback = &id_response;
            if (_identity == GoodWeIdentity.modbus)
            {
                req.wire = GoodWeWire.modbus;
                req.dest_addr = 0xF7;
                req.function_code = cast(GoodWeFunctionCode)3;
                req.address = 35000;
                req.count_or_value = 33;
                ubyte[8] buffer;
                immutable ubyte[4] payload = [0x88, 0xB8, 0, 33];
                GoodWeModbusMessage message = GoodWeModbusMessage(payload[], 0xF7, 3);
                transmit(req, buffer[0 .. message.encode(buffer)]);
            }
            else
                send_request_internal(req, null);

            version (DebugAA55)
            {
                if (_host)
                    writeInfo("aa55: '", name, "' begin handshake with ", _host[]);
                else
                    writeInfo("aa55: '", name, "' begin handshake with ", _remote);
            }
        }

        if (now - _last_activity >= 10.seconds)
        {
            version (DebugAA55)
                writeWarning("aa55: '", name, "' handshake timeout");
            return CompletionStatus.error;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        g_app.cancel(&send_next);
        MonoTime now = getTime();
        while (_pending_requests.length)
        {
            GoodWeRequest req = _pending_requests[0];
            _pending_requests.remove(0);
            req.callback(false, req, now, null, req.user_data);
        }

        _last_activity = MonoTime();
        _identity_requested = false;
        _active = false;
        g_app.cancel(&send_next);

        return CompletionStatus.complete;
    }

    override void update()
    {
        // Check watchdog
        if (!_manual && getTime() - _last_activity >= 10.seconds)
        {
            version (DebugAA55)
                writeWarning("aa55: '", name, "' timeout, restarting...");
            restart();
            return;
        }

        // Timeout requests...
        MonoTime now = getTime();
        for (size_t i = 0; i < _pending_requests.length; )
        {
            ref req = _pending_requests[i];

            if (req.request_time != MonoTime() && now - req.request_time >= 1500.msecs)
            {
                version (DebugAA55)
                    writeWarning("aa55: '", name, "' request timeout after ", (now - req.request_time).as!"msecs", "ms");

                GoodWeRequest expired = req;
                _pending_requests.remove(i);
                expired.callback(false, expired, now, null, expired.user_data);
                g_app.schedule(now, &send_next);
            }
            else
                ++i;
        }
    }

package:
    void incoming_message(const(ubyte)[] data, MonoTime now)
    {
        _last_activity = getTime();
        if (_trace || _manual)
            log.info("rx ", _remote, " ", cast(const(void)[])data);
        if (_manual && !_pending_requests.length)
        {
            _experiment_response = data;
            return;
        }

        while (data.length)
        {
            size_t length = goodwe_response_length(data);
            if (!length)
            {
                if (_trace) log.info("malformed datagram remainder ", cast(const(void)[])data);
                break;
            }
            incoming_frame(data[0 .. length], now);
            data = data[length .. $];
        }
    }

    void incoming_frame(const(ubyte)[] data, MonoTime now)
    {
        foreach (i; 0 .. _pending_requests.length)
        {
            ref request = _pending_requests[i];
            if (request.request_time == MonoTime())
                continue;
            const(ubyte)[] payload;
            bool success = true;
            final switch (request.wire)
            {
                case GoodWeWire.aa55:
                    AA55Message message;
                    if (!AA55Message.decode(data, message) || message.destination != request.source_addr ||
                        message.control != request.control_code || message.function_code != request.response_function)
                        continue;
                    payload = message.payload;
                    break;
                case GoodWeWire.module_:
                    GoodWeModuleMessage message;
                    if (!GoodWeModuleMessage.decode(data, message) || message.family != cast(ubyte)request.control_code || message.function_code != request.response_function)
                        continue;
                    payload = message.payload;
                    break;
                case GoodWeWire.modbus:
                    GoodWeModbusMessage message;
                    bool prefixed = data.length >= 2 && data[0] == 0xAA && data[1] == 0x55;
                    if (!GoodWeModbusMessage.decode(data, message, prefixed) || message.unit != request.dest_addr)
                        continue;
                    if (message.function_code == (cast(ubyte)request.function_code | 0x80) && message.payload.length == 1)
                    {
                        success = false;
                        payload = message.payload;
                    }
                    else if (message.function_code != cast(ubyte)request.function_code)
                        continue;
                    else if (message.function_code == 3 || message.function_code == 4)
                    {
                        if (!message.read_data(request.count_or_value, payload))
                            continue;
                    }
                    else
                    {
                        payload = message.payload;
                        if (payload.length != 4 || ((uint(payload[0]) << 8) | payload[1]) != request.address ||
                            ((uint(payload[2]) << 8) | payload[3]) != request.count_or_value)
                            continue;
                    }
                    break;
            }
            GoodWeRequest completed = request;
            _pending_requests.remove(i);
            completed.callback(success, completed, now, payload, completed.user_data);
            g_app.schedule(now, &send_next);
            return;
        }
        if (_trace)
            log.info("unmatched datagram ", cast(const(void)[])data);
    }

    const(char)[] get_address() const
    {
        import urt.mem.temp : tstring;
        if (_host)
            return _host[];
        else if (_remote.family == AddressFamily.ipv4)
            return _remote._a.ipv4.addr.tstring;
        else if (_remote.family == AddressFamily.ipv6)
            return _remote._a.ipv6.addr.tstring;
        return null;
    }


private:
    String _host;
    InetAddress _remote;

    bool _identity_requested;
    bool _active;
    ubyte _source_addr = 0xC0;
    ubyte _realtime_burst;

    MonoTime _last_activity;

    Array!GoodWeRequest _pending_requests;
    Array!ubyte _experiment_response;
    bool _manual;
    bool _trace;

    // device details
    GoodWeIdentity _identity;
    String firmware_version;
    String model_name;
    String serial_number;
    String software_version;
    ushort dsp1_version;
    ushort dsp2_version;
    ushort arm_version;
    uint nom_vpv; // 0.1V Nominal PV voltage
//    ubyte safety_country_code; // not interesting?

    bool send_request_internal(ref GoodWeRequest req, const(ubyte)[] data)
    {
        if (data.length > 255)
            return false;
        if (!req.response_function)
            req.response_function = cast(ubyte)req.function_code | 0x80;
        ubyte[264] buffer = void;
        AA55Message message = AA55Message(data, req.source_addr, req.dest_addr, req.control_code, req.function_code);
        return transmit(req, buffer[0 .. message.encode(buffer)]);
    }

    bool transmit(ref GoodWeRequest request, const(ubyte)[] data)
    {
        if (!get_module!GoodWeModule.aa55_socket || !data.length || _pending_requests.length >= 32)
            return false;
        request.frame = data;
        size_t position;
        if (_pending_requests.length && _pending_requests[0].request_time != MonoTime())
            position = 1;
        while (position < _pending_requests.length && _pending_requests[position].priority >= request.priority)
            ++position;
        _pending_requests.insert(position, request);
        g_app.schedule(getTime(), &send_next);
        return true;
    }

    void send_next(MonoTime now)
    {
        if (!_pending_requests.length || _pending_requests[0].request_time != MonoTime())
            return;
        Socket socket = get_module!GoodWeModule.aa55_socket;
        if (!socket)
            return;
        if (_realtime_burst >= 3)
            foreach (i, ref pending; _pending_requests)
                if (pending.priority == GoodWePriority.background)
                {
                    if (i)
                    {
                        GoodWeRequest next = pending;
                        _pending_requests.remove(i);
                        _pending_requests.insert(0, next);
                    }
                    break;
                }
        ref request = _pending_requests[0];
        const(ubyte)[] data = request.frame[];
        size_t sent;
        Result result = socket.sendto(data, MsgFlags.none, &_remote, &sent);
        if (!result || sent != data.length)
        {
            GoodWeRequest failed = request;
            _pending_requests.remove(0);
            failed.callback(false, failed, now, null, failed.user_data);
            g_app.schedule(now, &send_next);
            return;
        }
        if (_trace)
            log.info("tx ", _remote, " ", cast(const(void)[])data);
        request.request_time = now;
        if (request.priority == GoodWePriority.background)
            _realtime_burst = 0;
        else if (_realtime_burst < 3)
            ++_realtime_burst;
    }

    void id_response(bool success, ref const GoodWeRequest request, MonoTime response_time, const(ubyte)[] response, void* user_data)
    {
        if (!success)
            return;
        if (request.wire == GoodWeWire.modbus)
        {
            if (response.length != 66)
                return;
            serial_number = (cast(const(char)[])response[6 .. 22]).strlen_trim.make_string();
            model_name = (cast(const(char)[])response[22 .. 32]).strlen_trim.make_string();
            firmware_version = (cast(const(char)[])response[42 .. 54]).strlen_trim.make_string();
            software_version = (cast(const(char)[])response[54 .. 66]).strlen_trim.make_string();
            dsp1_version = cast(ushort)((uint(response[32]) << 8) | response[33]);
            dsp2_version = cast(ushort)((uint(response[34]) << 8) | response[35]);
            arm_version = cast(ushort)((uint(response[38]) << 8) | response[39]);
            _active = true;
            return;
        }
        if (response.length < IDInfo.sizeof)
            return;

        ref IDInfo info = *cast(IDInfo*)response.ptr;
        _active = true;

        firmware_version = info.firmware_version.strlen_trim.make_string();
        model_name = info.model_name.strlen_trim.make_string();
        serial_number = info.serial_number.strlen_trim.make_string();
        software_version = info.software_version.strlen_trim.make_string();

        size_t taken;
        nom_vpv = cast(uint)info.nom_vpv[].parse_uint(&taken);
        if (taken != 4)
            nom_vpv = 0;

        if (firmware_version.length >= 2)
            dsp1_version = cast(ubyte)firmware_version[0..2].parse_int();
        if (firmware_version.length >= 4)
            dsp2_version = cast(ubyte)firmware_version[2..4].parse_int();
        if (firmware_version.length >= 5)
            arm_version = cast(ubyte)firmware_version[4..5].parse_int(null, 36);
    }
}


private:

inout(char)[] strlen_trim(inout(char)[] str)
    => str[0..str.strlen_s].trimBack;
