module protocol.goodwe.server;

import urt.array;
import urt.conv;
import urt.inet;
import urt.lifetime;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.profile;
import manager.sample;

import protocol.goodwe : aa55_section_kind, goodwe_section;
import protocol.goodwe.aa55 : IDInfo, RunningInfo, RunningData, SettingInfo, GoodWeControlCode, GoodWeFunctionCode;
import protocol.goodwe.client : GoodWeWire, GoodWeClient, GoodWeRequest, GoodWePriority;
import protocol.goodwe.binding : ElementDesc_AA55, goodwe_profile_field;
import protocol.goodwe.message;
import manager.console.session : Session;
import router.iface.endpoint;

nothrow @nogc:


final class GoodWeServer : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("profile", profile),
                                 Prop!("upstream", upstream),
                                 Prop!("model", model),
                                 Prop!("serial-number", serial_number),
                                 Prop!("bind-address", bind_address),
                                 Prop!("advertise-address", advertise_address),
                                 Prop!("port", port),
                                 Prop!("discovery-port", discovery_port),
                                 Prop!("discovery-id", discovery_id),
                                 Prop!("module-network-config", module_network_config),
                                 Prop!("trace", trace));
nothrow @nogc:
    ~this() {}

    enum type_name = "goodwe-server";
    enum path = "/protocol/goodwe/server";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!GoodWeServer, id, flags);
        _discovery_id = StringLit!"020000000001,Solar-WiFiOpenWatt";
    }

    ref const(String) profile() const pure => _profile;
    void profile(String value)
    {
        _profile = value.move;
        mark_set!(typeof(this), "profile")();
        restart();
    }

    ref const(String) model() const pure => _model;

    inout(GoodWeClient) upstream() inout pure => _upstream.get;
    void upstream(GoodWeClient value)
    {
        if (_upstream.get is value)
            return;
        detach_upstream();
        _upstream = value;
        mark_set!(typeof(this), "upstream")();
        restart();
    }

    void model(String value)
    {
        _model = value.move;
        mark_set!(typeof(this), "model")();
        restart();
    }

    ref const(String) serial_number() const pure => _serial_number;
    const(char)[] serial_number(String value)
    {
        if (value.length && value.length != 16)
            return "serial-number must be empty or exactly 16 ASCII characters";
        foreach (c; value[])
            if (c < 0x20 || c > 0x7E)
                return "serial-number must be printable ASCII";
        _serial_number = value.move;
        mark_set!(typeof(this), "serial-number")();
        restart();
        return null;
    }

    IPAddr bind_address() const pure => _bind_address;
    void bind_address(IPAddr value)
    {
        _bind_address = value;
        mark_set!(typeof(this), "bind-address")();
        restart();
    }

    IPAddr advertise_address() const pure => _advertise_address;
    void advertise_address(IPAddr value)
    {
        _advertise_address = value;
        mark_set!(typeof(this), "advertise-address")();
    }

    ushort port() const pure => _port;
    void port(ushort value)
    {
        _port = value;
        mark_set!(typeof(this), "port")();
        restart();
    }

    ushort discovery_port() const pure => _discovery_port;
    void discovery_port(ushort value)
    {
        _discovery_port = value;
        mark_set!(typeof(this), "discovery-port")();
        restart();
    }

    ref const(String) discovery_id() const pure => _discovery_id;
    const(char)[] discovery_id(String value)
    {
        foreach (c; value[])
            if (c < 0x20 || c > 0x7E)
                return "discovery-id must be printable ASCII";
        if (value.length == 0 || value.length > 128)
            return "discovery-id must contain 1..128 characters";
        _discovery_id = value.move;
        mark_set!(typeof(this), "discovery-id")();
        return null;
    }

    bool trace() const pure => _trace;
    ref const(String) module_network_config() const pure => _module_network_config;
    const(char)[] module_network_config(String value)
    {
        if (value.length)
        {
            if (value.length > 68)
                return "module-network-config must contain at most 68 characters";
            const(char)[] remaining = value[];
            if (remaining.length < 5 || remaining[0 .. 5] != "DHCP,")
                return "module-network-config requires DHCP,ip,mask,gateway,dns or an empty string";
            remaining = remaining[5 .. $];
            foreach (i; 0 .. 4)
            {
                IPAddr address;
                ptrdiff_t n = address.fromString(remaining);
                if (n <= 0)
                    return "module-network-config requires four IPv4 addresses";
                remaining = remaining[n .. $];
                if (i < 3)
                {
                    if (!remaining.length || remaining[0] != ',')
                        return "module-network-config requires four comma-separated IPv4 addresses";
                    remaining = remaining[1 .. $];
                }
            }
            if (remaining.length)
                return "unexpected data after module-network-config DNS address";
        }
        _module_network_config = value.move;
        mark_set!(typeof(this), "module-network-config")();
        return null;
    }

    void trace(bool value)
    {
        _trace = value;
        mark_set!(typeof(this), "trace")();
    }

    const(char)[] set_reply(ubyte control, ubyte fn, const(ubyte)[] data)
    {
        if (fn & 0x80 || data.length > 255)
            return "request function must be below 128 and reply payload at most 255 bytes";
        foreach (ref reply; _replies)
            if (reply.control == control && reply.fn == fn)
            {
                reply.data = data;
                return null;
            }
        Reply* reply = &_replies.pushBack();
        reply.control = control;
        reply.fn = fn;
        reply.data = data;
        return null;
    }

    void clear_replies()
    {
        _replies.clear();
        _raw_replies.clear();
    }

    void print_requests(Session session)
    {
        foreach (ref request; _captures)
            session.write_line("id=", request.id, " peer=", request.peer, " data=", cast(const(void)[])request.data[]);
    }

    const(ubyte)[] captured(uint id) const
    {
        foreach (ref request; _captures)
            if (request.id == id)
                return request.data[];
        return null;
    }

    const(char)[] respond(uint id, const(ubyte)[] data)
    {
        if (!running || !_endpoint)
            return "server is not running";
        if (!data.length || data.length > 4096)
            return "response must contain 1..4096 bytes";
        foreach (ref request; _captures)
            if (request.id == id)
            {
                return send(_endpoint, data, request.peer) ? null : "send failed";
            }
        return "request ID expired or not found";
    }

    const(char)[] raw_reply(const(ubyte)[] request, const(ubyte)[] response)
    {
        if (!request.length || request.length > 4096 || !response.length || response.length > 4096)
            return "request and response must contain 1..4096 bytes";
        foreach (ref rule; _raw_replies)
            if (rule.request[] == request)
            {
                rule.response = response;
                return null;
            }
        if (_raw_replies.length >= 32)
            return "32 raw rules already installed; clear-replies first";
        RawReply* rule = &_raw_replies.pushBack();
        rule.request = request;
        rule.response = response;
        return null;
    }

    const(char)[] answer(uint id, const(ubyte)[] data, bool repeat)
    {
        AA55Message request;
        const(ubyte)[] bytes = captured(id);
        if (!AA55Message.decode(bytes, request) || request.function_code >= 128)
            return "captured request is missing or is not an AA55 request";
        if (data.length > 255)
            return "AA55 payload must be <=255 bytes";
        ubyte[264] buffer = void;
        AA55Message reply = AA55Message(data, _address, request.source, request.control, cast(ubyte)(request.function_code | 128));
        size_t length = reply.encode(buffer);
        return repeat ? raw_reply(bytes, buffer[0 .. length]) : respond(id, buffer[0 .. length]);
    }

protected:
    override const(char)[] profile_name() const pure => _profile[];
    override const(char)[] model_name() const pure => _model[];

    override bool validate() const pure
        => !_device.empty && !_profile.empty && _port != 0 && _port != _discovery_port;

    override CompletionStatus startup()
    {
        GoodWeClient client = _upstream.get;
        if (_upstream.name.length && (!client || !client.running))
            return CompletionStatus.continue_;
        if (!materialise())
            return CompletionStatus.error;
        InetAddress local = InetAddress(_bind_address, _port);
        _endpoint = udp_open(&local, null, &receive);
        if (!_endpoint)
            return CompletionStatus.error;
        if (_discovery_port)
        {
            local = InetAddress(_bind_address, _discovery_port);
            _discovery = udp_open(&local, null, &receive_discovery);
            if (!_discovery)
            {
                _endpoint.close();
                _endpoint = null;
                return CompletionStatus.error;
            }
        }
        if (client)
        {
            client.subscribe(&upstream_state);
            _upstream_subscribed = true;
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        detach_upstream();
        g_app.cancel(&flush_forward);
        _forwarded.clear();
        _forward_active = false;
        if (_endpoint)
            _endpoint.close();
        if (_discovery)
            _discovery.close();
        _endpoint = _discovery = null;
        _address = 0x7F;
        _fields.clear();
        _captures.clear();
        return super.shutdown();
    }

    override FormatId add_handler(Device device, Element* element, ref const ElementDesc desc, ubyte)
    {
        ElementDesc_AA55 field;
        if (!(desc.access & manager.profile.Access.read) || !goodwe_profile_field(*_profile_data, desc, field) || field.action || field.commit_format)
            return FormatId.invalid;
        if (field.desc == ushort.max || uint(field.offset) + field.length > 255 ||
            (!field.length && (field.wire != GoodWeWire.module_ || !desc_by_index(field.desc).fmt.is_text)))
            return FormatId.invalid;
        _fields ~= Field(element, field);
        return desc_by_index(field.desc).format;
    }

private:
    struct Forwarded
    {
        Array!ubyte data;
        InetAddress peer;
        MonoTime deadline;
    }
    ObjectRef!GoodWeClient _upstream;
    Array!Forwarded _forwarded;

    void detach_upstream()
    {
        if (_upstream_subscribed)
        {
            if (GoodWeClient client = _upstream.get)
            {
                client.cancel_requests(&forward_response);
                client.unsubscribe(&upstream_state);
            }
            _upstream_subscribed = false;
        }
    }

    void upstream_state(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    bool forward(const(ubyte)[] data, ref const InetAddress peer)
    {
        if (!_upstream.name.length)
            return false;
        GoodWeModuleMessage module_request;
        GoodWeModbusMessage registers;
        AA55Message vendor;
        if (GoodWeModuleMessage.decode(data, module_request))
        {
            if (module_request.function_code >= 128 || module_request.payload.length > 1024)
                return false;
            if (module_request.family == 1 && module_request.function_code == 3 && !module_request.payload.length && _module_network_config.length)
                return false;
        }
        else if (AA55Message.decode(data, vendor))
        {
            if (!vendor.control || vendor.function_code >= 128 ||
                (vendor.destination != 0x7F && vendor.destination != _address))
                return false;
            foreach (ref reply; _replies)
                if (reply.control == vendor.control && reply.fn == vendor.function_code)
                    return false;
        }
        else if (GoodWeModbusMessage.decode(data, registers))
        {
            ubyte fn = registers.function_code;
            if ((fn != 3 && fn != 4 && fn != 6 && fn != 16) || registers.payload.length < 4)
                return false;
            uint count = uint(registers.payload[2]) << 8 | registers.payload[3];
            if (fn == 16 ? !count || count > 123 || registers.payload.length != 5 + count * 2 || registers.payload[4] != count * 2 :
                registers.payload.length != 4 || ((fn == 3 || fn == 4) && (!count || count > 125)))
                return false;
        }
        else
            return false;
        foreach (ref pending; _forwarded)
            if (pending.peer == peer && pending.data[] == data)
                return true;
        if (_forwarded.length >= 16)
        {
            log.warning("upstream queue full for ", peer);
            if (registers.function_code)
            {
                ubyte[1] error = [10];
                ubyte[257] buffer = void;
                GoodWeModbusMessage response = GoodWeModbusMessage(error, registers.unit, registers.function_code | 128);
                send(_endpoint, buffer[0 .. response.encode(buffer, true)], peer);
            }
            return true;
        }
        Forwarded* request = &_forwarded.pushBack();
        request.data = data;
        request.peer = peer;
        request.deadline = getTime() + 10.seconds;
        flush_forward(getTime());
        return true;
    }

    void flush_forward(MonoTime now)
    {
        if (!running || !_forwarded.length || _forward_active)
            return;
        if (now >= _forwarded[0].deadline)
        {
            forward_response(false, GoodWeRequest.init, now, null, null);
            return;
        }
        GoodWeClient client = _upstream.get;
        bool sent;
        if (client && client.running)
        {
            const(ubyte)[] data = _forwarded[0].data[];
            GoodWeModuleMessage module_request;
            GoodWeModbusMessage registers;
            AA55Message vendor;
            if (GoodWeModuleMessage.decode(data, module_request))
                sent = client.send_module(module_request.function_code, module_request.payload, &forward_response, null, GoodWePriority.realtime, module_request.family);
            else if (AA55Message.decode(data, vendor))
                sent = client.send_request(cast(GoodWeControlCode)vendor.control,
                    cast(GoodWeFunctionCode)vendor.function_code, vendor.payload, &forward_response);
            else if (GoodWeModbusMessage.decode(data, registers))
            {
                ushort address = cast(ushort)(uint(registers.payload[0]) << 8 | registers.payload[1]);
                ushort count = cast(ushort)(uint(registers.payload[2]) << 8 | registers.payload[3]);
                sent = client.send_modbus(registers.function_code, address, count,
                    registers.function_code == 16 ? registers.payload[5 .. $] : null, &forward_response, null, registers.unit);
            }
        }
        if (sent)
            _forward_active = true;
        else
            g_app.schedule(now + 50.msecs, &flush_forward);
    }

    void forward_response(bool success, ref const GoodWeRequest, MonoTime now, const(ubyte)[] payload, void*)
    {
        if (!_forwarded.length)
            return;
        Forwarded request = _forwarded[0];
        _forwarded.remove(0);
        _forward_active = false;
        ubyte[1032] buffer = void;
        ubyte[1024] values = void;
        size_t length;
        GoodWeModuleMessage module_request;
        GoodWeModbusMessage registers;
        AA55Message vendor;
        if (GoodWeModuleMessage.decode(request.data[], module_request))
        {
            if (success)
                length = GoodWeModuleMessage(payload, module_request.function_code | 128, module_request.family).encode(buffer);
        }
        else if (AA55Message.decode(request.data[], vendor))
        {
            if (success)
            {
                values[0 .. payload.length] = payload;
                if (vendor.control == 1 && vendor.function_code == 2 && _serial_number.length && payload.length >= 47)
                    values[31 .. 47] = cast(const(ubyte)[])_serial_number[];
                length = AA55Message(values[0 .. payload.length], _address, vendor.source,
                    vendor.control, vendor.function_code | 128).encode(buffer);
            }
        }
        else if (GoodWeModbusMessage.decode(request.data[], registers))
        {
            ubyte fn = registers.function_code;
            if (!success)
            {
                values[0] = payload.length == 1 ? payload[0] : 11;
                fn |= 128;
                length = 1;
            }
            else if (fn == 3 || fn == 4)
            {
                values[0] = cast(ubyte)payload.length;
                values[1 .. 1 + payload.length] = payload;
                length = 1 + payload.length;
                if (fn == 3)
                    override_serial(cast(ushort)(uint(registers.payload[0]) << 8 | registers.payload[1]), values[1 .. length]);
            }
            else
            {
                values[0 .. payload.length] = payload;
                length = payload.length;
            }
            GoodWeModbusMessage response = GoodWeModbusMessage(values[0 .. length], registers.unit, fn);
            length = response.encode(buffer, true);
        }
        if (length && _endpoint)
            send(_endpoint, buffer[0 .. length], request.peer);
        else
            log.warning("upstream request failed for ", request.peer, " ", cast(const(void)[])request.data[]);
        if (_forwarded.length)
            g_app.schedule(now, &flush_forward);
    }

    struct Capture
    {
        Array!ubyte data;
        InetAddress peer;
        uint id;
    }
    struct RawReply
    {
        Array!ubyte request;
        Array!ubyte response;
    }
    Array!Capture _captures;
    Array!RawReply _raw_replies;
    uint _next_capture;
    struct Field
    {
        Element* element;
        ElementDesc_AA55 wire;
    }

    struct Reply
    {
        Array!ubyte data;
        ubyte control;
        ubyte fn;
    }

    String _profile;
    String _model;
    String _serial_number;
    String _discovery_id;
    String _module_network_config;
    Array!Field _fields;
    Array!Reply _replies;
    UDPEndpoint* _endpoint;
    UDPEndpoint* _discovery;
    IPAddr _bind_address;
    IPAddr _advertise_address;
    ushort _port = 8899;
    ushort _discovery_port = 48899;
    ubyte _address = 0x7F;
    bool _trace = true;
    bool _upstream_subscribed;
    bool _forward_active;

    size_t read_payload(ubyte fn, ubyte[] payload, size_t length = 0, GoodWeWire wire = GoodWeWire.aa55, ushort address = 0)
    {
        size_t base_length = length;
        foreach (ref field; _fields)
            if (field.wire.wire == wire && field.wire.function_code == fn && field.wire.address == address)
            {
                size_t end = uint(field.wire.offset) + field.wire.length;
                if (end > length)
                    length = end;
            }
        if (!length)
            return 0;
        if (wire == GoodWeWire.aa55) switch (fn)
        {
            case 1: if (length < RunningInfo.sizeof) length = RunningInfo.sizeof; break;
            case 2: if (length < IDInfo.sizeof) length = IDInfo.sizeof; break;
            case 3: if (length < SettingInfo.sizeof) length = SettingInfo.sizeof; break;
            case 6: if (length < RunningData.sizeof) length = RunningData.sizeof; break;
            default: break;
        }
        if (length > payload.length)
            return 0;
        payload[base_length .. length] = 0;
        foreach (ref field; _fields)
        {
            if (field.wire.wire != wire || field.wire.function_code != fn || field.wire.address != address)
                continue;
            if (!emit_field(field.element, field.wire, payload[0 .. length]))
                return 0;
        }
        if (wire == GoodWeWire.aa55 && fn == 2 && _serial_number.length)
            payload[31 .. 47] = cast(const(ubyte)[])_serial_number[];
        return length;
    }

    size_t read_module_payload(ubyte fn, ubyte[] payload, ushort address = 0)
    {
        Field* first;
        ubyte last_index;
        foreach (ref field; _fields)
            if (field.wire.wire == GoodWeWire.module_ && field.wire.function_code == fn && field.wire.address == address && !field.wire.length)
            {
                if (!first)
                    first = &field;
                if (field.wire.field_index > last_index)
                    last_index = field.wire.field_index;
            }
        if (!first)
            return read_payload(fn, payload, 0, GoodWeWire.module_, address);
        size_t length;
        foreach (uint index; 0 .. uint(last_index) + 1)
        {
            Field* selected;
            foreach (ref field; _fields)
                if (field.wire.wire == GoodWeWire.module_ && field.wire.function_code == fn && field.wire.address == address && !field.wire.length &&
                    field.wire.field_encoding == first.wire.field_encoding && field.wire.field_index == index)
                {
                    selected = &field;
                    break;
                }
            if (!selected || !selected.element.has_value || !selected.element.data_format.is_text)
                return 0;
            const(char)[] text = selected.element.text_value();
            auto encoding = selected.wire.field_encoding;
            if (encoding == GoodWeFieldEncoding.status)
            {
                size_t taken;
                ulong value = text.parse_uint_with_base(&taken);
                if (taken == text.length && taken && value <= 255)
                {
                    payload[0] = cast(ubyte)value;
                    return 1;
                }
            }
            if (encoding == GoodWeFieldEncoding.csv)
            {
                foreach (c; text)
                    if (c == ',' || c == 0)
                        return 0;
            }
            size_t prefix = encoding == GoodWeFieldEncoding.length_prefixed || (encoding == GoodWeFieldEncoding.csv && index) ? 1 : 0;
            if (length + prefix + text.length > payload.length ||
                (encoding == GoodWeFieldEncoding.length_prefixed && text.length > 255))
                return 0;
            if (prefix)
                payload[length++] = encoding == GoodWeFieldEncoding.csv ? ',' : cast(ubyte)text.length;
            payload[length .. length + text.length] = cast(const(ubyte)[])text;
            length += text.length;
        }
        return length;
    }

    bool read_registers(ushort address, ushort count, ubyte[] payload, ubyte function_code = 3)
    {
        if (!count || count > 125 || payload.length != count * 2)
            return false;
        SysTime[250] sampled;
        uint start = uint(address) * 2;
        foreach (ref field; _fields)
        {
            if (field.wire.wire != GoodWeWire.modbus &&
                !(field.wire.wire == GoodWeWire.aa55 && field.wire.function_code == 0x1A))
                continue;
            if (field.wire.wire == GoodWeWire.modbus ? field.wire.function_code != function_code : function_code != 3)
                continue;
            uint position = uint(field.wire.address) * 2 + field.wire.offset;
            if (position >= start + payload.length || position + field.wire.length <= start)
                continue;
            ubyte[255] value = void;
            ElementDesc_AA55 descriptor = field.wire;
            descriptor.offset = 0;
            if (!emit_field(field.element, descriptor, value[0 .. descriptor.length]))
                continue;
            SysTime updated = field.element.record_update();
            foreach (i; 0 .. descriptor.length)
                if (position + i >= start && position + i < start + payload.length)
                {
                    size_t offset = position + i - start;
                    if (updated >= sampled[offset])
                    {
                        payload[offset] = value[i];
                        sampled[offset] = updated;
                    }
                }
        }
        foreach (updated; sampled[0 .. payload.length])
            if (updated == SysTime())
                return false;
        if (function_code == 3)
            override_serial(address, payload);
        return true;
    }

    void override_serial(ushort address, ubyte[] payload)
    {
        uint start = uint(address) * 2;
        if (_serial_number.length)
            foreach (i, value; cast(const(ubyte)[])_serial_number[])
            {
                uint position = 35003u * 2 + cast(uint)i;
                if (position >= start && position < start + payload.length)
                    payload[position - start] = value;
            }
    }

    static bool emit_field(Element* element, ref const ElementDesc_AA55 field, ubyte[] payload)
    {
        if (!element.format.valid || !element.has_value || element.record_update() == SysTime())
            return false;
        SampleDesc desc = desc_by_index(field.desc);
        const(DataFormat)* fmt = desc.fmt;
        ubyte[] wire = payload[field.offset .. uint(field.offset) + field.length];
        if (fmt.is_text)
            return element.data_format.is_text && emit_text(element.text_value(), desc, wire);
        if (fmt.is_scalar)
        {
            if (element.format == desc.format)
                return emit_record(element.latest_record.raw[0 .. fmt.stride], desc, wire);
            Variant value = element.value;
            Scalar scalar;
            return unbox_scalar(value, *fmt, scalar) && emit_record(scalar.raw[0 .. fmt.stride], desc, wire);
        }
        return element.format == desc.format && emit_record(element.tail_record(), desc, wire);
    }

    void receive_discovery(UDPEndpoint* endpoint, const(void)[] data, ref UDPReceiveInfo info)
    {
        if (_trace)
            log.info("discovery rx ", info.source, " ", data);
        if (cast(const(char)[])data != "WIFIKIT-214028-READ")
            return;
        IPAddr address = _advertise_address != IPAddr.any ? _advertise_address : _bind_address;
        if (address == IPAddr.any || address.is_multicast || address == IPAddr.broadcast)
        {
            log.warning("set advertise-address to the server's LAN IPv4 address");
            return;
        }
        const(char)[] reply = tconcat(address, ',', _discovery_id[]);
        send(endpoint, cast(const(ubyte)[])reply, info.source);
    }

    void receive(UDPEndpoint* endpoint, const(void)[] bytes, ref UDPReceiveInfo info)
    {
        if (bytes.length <= 4096)
        {
            if (_captures.length == 32)
                _captures.remove(0);
            Capture* capture = &_captures.pushBack();
            capture.id = ++_next_capture;
            capture.peer = info.source;
            capture.data = cast(const(ubyte)[])bytes;
            if (_trace)
                log.info("capture id=", capture.id);
        }
        if (_trace)
            log.info("rx ", info.source, " ", bytes);
        foreach (ref rule; _raw_replies)
            if (rule.request[] == cast(const(ubyte)[])bytes)
            {
                send(endpoint, rule.response[], info.source);
                return;
            }
        if (forward(cast(const(ubyte)[])bytes, info.source))
            return;
        const(ubyte)[] data = cast(const(ubyte)[])bytes;
        if (data.length >= 2 && data[0] == 0x5A && data[1] == 0x5A)
        {
            GoodWeModuleMessage module_request;
            if (!GoodWeModuleMessage.decode(data, module_request))
            {
                log.warning("invalid WLAN module datagram from ", info.source);
                return;
            }
            if (module_request.family == 1 && module_request.function_code == 3 && module_request.payload.length == 0 && _module_network_config.length)
            {
                ubyte[76] buffer = void;
                GoodWeModuleMessage response = GoodWeModuleMessage(cast(const(ubyte)[])_module_network_config[], 0x83);
                size_t length = response.encode(buffer);
                if (length)
                    send(endpoint, buffer[0 .. length], info.source);
                return;
            }
            if (module_request.family == 1 && module_request.payload.length <= 1 && module_request.function_code < 0x80)
            {
                ubyte[255] payload = void;
                size_t length = read_module_payload(module_request.function_code, payload, module_request.payload.length ? cast(ushort)(module_request.payload[0] + 1) : 0);
                if (length)
                {
                    ubyte[263] buffer = void;
                    GoodWeModuleMessage response = GoodWeModuleMessage(payload[0 .. length], module_request.function_code | 0x80);
                    send(endpoint, buffer[0 .. response.encode(buffer)], info.source);
                    return;
                }
            }
            log.warning("unhandled WLAN module request from ", info.source, " fn=", module_request.function_code, " payload=", cast(const(void)[])module_request.payload);
            return;
        }
        GoodWeModbusMessage register_request;
        if (!(data.length >= 2 && data[0] == 0xAA && data[1] == 0x55) && GoodWeModbusMessage.decode(data, register_request))
        {
            ubyte[251] payload = void;
            size_t length = 1;
            ubyte fn = register_request.function_code | 0x80;
            payload[0] = 1; // illegal function; unknown writes never get a success echo
            if ((register_request.function_code == 3 || register_request.function_code == 4) && register_request.payload.length == 4)
            {
                ushort address = cast(ushort)((uint(register_request.payload[0]) << 8) | register_request.payload[1]);
                ushort count = cast(ushort)((uint(register_request.payload[2]) << 8) | register_request.payload[3]);
                payload[0] = 2;
                if (count && count <= 125 && read_registers(address, count, payload[1 .. 1 + count * 2], register_request.function_code))
                {
                    fn = register_request.function_code;
                    payload[0] = cast(ubyte)(count * 2);
                    length = 1 + count * 2;
                }
            }
            GoodWeModbusMessage response = GoodWeModbusMessage(payload[0 .. length], register_request.unit, fn);
            ubyte[257] buffer = void;
            send(endpoint, buffer[0 .. response.encode(buffer, true)], info.source);
            return;
        }
        AA55Message request;
        if (!AA55Message.decode(cast(const(ubyte)[])bytes, request))
        {
            log.warning("invalid AA55 datagram from ", info.source);
            return;
        }
        ubyte[264] buffer = void;
        size_t length = make_response(request, buffer);
        if (!length)
        {
            log.warning("unhandled request from ", info.source, " control=", request.control, " fn=", request.function_code, " payload=", cast(const(void)[])request.payload);
            return;
        }
        send(endpoint, buffer[0 .. length], info.source);
    }

    size_t make_response(ref const AA55Message request, ubyte[] buffer)
    {
        if ((request.function_code & 0x80) || (request.destination != 0x7F && request.destination != _address))
            return 0;
        ubyte[255] payload = void;
        size_t length;
        bool supplied;
        foreach (ref reply; _replies)
            if (reply.control == request.control && reply.fn == request.function_code)
            {
                length = reply.data.length;
                payload[0 .. length] = reply.data[];
                supplied = true;
                break;
            }
        if (request.control == 1 && request.function_code == 0x1A && request.payload.length == 3)
        {
            ushort address = cast(ushort)((uint(request.payload[0]) << 8) | request.payload[1]);
            length = uint(request.payload[2]) * 2;
            if (length > payload.length || !read_registers(address, request.payload[2], payload[0 .. length]))
                return 0;
        }
        else if (request.control == 1 && request.payload.length == 0)
        {
            length = read_payload(request.function_code, payload, length);
            if (!length)
                return 0;
        }
        else if (request.control == 0 && !supplied)
        {
            ubyte[255] id_payload = void;
            if (read_payload(2, id_payload) < IDInfo.sizeof)
                return 0;
            switch (request.function_code)
            {
                case 0:
                    if (request.payload.length)
                        return 0;
                    payload[0 .. 16] = id_payload[31 .. 47];
                    length = 16;
                    break;
                case 1:
                    if (request.payload.length != 17 || request.payload[0 .. 16] != id_payload[31 .. 47])
                        return 0;
                    _address = request.payload[16];
                    break;
                case 2:
                    if (request.payload.length)
                        return 0;
                    AA55Message reply = AA55Message(null, _address, request.source, 0, 0x82);
                    _address = 0x7F;
                    return reply.encode(buffer);
                default: return 0;
            }
        }
        else if (!supplied)
            return 0;
        AA55Message reply = AA55Message(payload[0 .. length], _address, request.source, request.control, cast(ubyte)(request.function_code | 0x80));
        return reply.encode(buffer);
    }

    bool send(UDPEndpoint* endpoint, const(ubyte)[] bytes, InetAddress destination)
    {
        if (endpoint.sendto(bytes, destination) != bytes.length)
        {
            log.warning("send failed to ", destination);
            return false;
        }
        if (_trace)
            log.info("tx ", destination, " ", cast(const(void)[])bytes);
        return true;
    }
}

unittest
{
    import urt.mem : alloc, free;
    import urt.si.quantity : Quantity;
    import urt.si.unit : ScaledUnit, Volt;
    import manager.sample.spec : compile_spec, stream_be_context;

    GoodWeServer server = alloc!GoodWeServer(CID(1));
    scope(exit) free(server);
    SampleDesc volts;
    assert(compile_spec("u16:0.1V", stream_be_context, ScaledUnit(), 1, null, null, volts));
    Element voltage;
    voltage.format = volts.format;
    voltage.value = Variant(Quantity!double(230.5, ScaledUnit(Volt)));
    ElementDesc_AA55 field;
    field.function_code = 6;
    field.offset = 34;
    field.length = 2;
    field.desc = register_desc(volts);
    server._fields ~= GoodWeServer.Field(&voltage, field);
    AA55Message request = AA55Message(null, 0xC0, 0x7F, 1, 6);
    ubyte[264] buffer;
    size_t n = server.make_response(request, buffer);
    AA55Message response;
    assert(n == RunningData.sizeof + 9 && AA55Message.decode(buffer[0 .. n], response));
    assert(response.source == 0x7F && response.destination == 0xC0 && response.function_code == 0x86);
    assert(response.payload[34] == 0x09 && response.payload[35] == 0x01);
    voltage.value = Variant(Quantity!double(241.2, ScaledUnit(Volt)));
    n = server.make_response(request, buffer);
    assert(AA55Message.decode(buffer[0 .. n], response));
    assert(response.payload[34] == 0x09 && response.payload[35] == 0x6C);

    ubyte[140] base;
    base[100] = 0xAB;
    assert(server.set_reply(1, 6, base) is null);
    n = server.make_response(request, buffer);
    assert(AA55Message.decode(buffer[0 .. n], response));
    assert(response.payload[100] == 0xAB && response.payload[35] == 0x6C);
    request.control = 2;
    request.function_code = 0x39;
    assert(server.make_response(request, buffer) == 0);
    ubyte[1] ack = [1];
    Scalar previous = voltage.latest_record;
    assert(server.set_reply(2, 0x39, ack) is null);
    n = server.make_response(request, buffer);
    assert(AA55Message.decode(buffer[0 .. n], response));
    assert(response.control == 2 && response.function_code == 0xB9 && response.payload == ack[]);
    assert(voltage.latest_record.raw == previous.raw);
    server.clear_replies();
    assert(server.make_response(request, buffer) == 0);
    assert(server.set_reply(1, 0x80, null) !is null);

    SampleDesc text;
    assert(compile_spec("str16", stream_be_context, ScaledUnit(), 1, null, null, text));
    Element serial;
    serial.format = text.format;
    serial.value = Variant("00000ESU00000001");
    field.function_code = 2;
    field.offset = 31;
    field.length = 16;
    field.desc = register_desc(text);
    server._fields ~= GoodWeServer.Field(&serial, field);
    request = AA55Message(null, 0xC0, 0x7F, 0, 0);
    n = server.make_response(request, buffer);
    assert(AA55Message.decode(buffer[0 .. n], response));
    assert(cast(const(char)[])response.payload == "00000ESU00000001");
    ubyte[17] assignment;
    assignment[0 .. 16] = response.payload;
    assignment[16] = 0x0D;
    request.function_code = 1;
    request.payload = assignment;
    n = server.make_response(request, buffer);
    assert(AA55Message.decode(buffer[0 .. n], response));
    assert(response.source == 0x0D && response.function_code == 0x81 && response.payload.length == 0);
    assignment[0] ^= 1;
    assert(server.make_response(request, buffer) == 0);
    request.payload = null;
    request.function_code = 2;
    n = server.make_response(request, buffer);
    assert(AA55Message.decode(buffer[0 .. n], response));
    assert(response.source == 0x0D && response.function_code == 0x82 && server._address == 0x7F);
}
