module protocol.goodwe.control;

import urt.meta : AliasSeq;
import urt.mem.temp : tconcat;
import urt.si;
import urt.string;
import urt.time;
import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.series;
import protocol.goodwe.aa55;
import protocol.goodwe.client;
import protocol.modbus;
import protocol.modbus.message;
import protocol.modbus.node;

nothrow @nogc:

enum GoodWeDispatch : ubyte { legacy, battery_power }
enum GoodWeControlKind : ubyte { autonomous, continuous }

// Positive setpoints consume AC power to charge; negative setpoints discharge.
final class GoodWeControlBinding : ProtocolBinding
{
nothrow @nogc:
    ~this() {}

    alias Properties = AliasSeq!(Prop!("client", client), Prop!("node", node),
        Prop!("slave", slave), Prop!("register", register_), Prop!("scheme", scheme),
        Prop!("charge-limit", charge_limit), Prop!("discharge-limit", discharge_limit),
        Prop!("component", control_component));
    enum type_name = "goodwe-control";
    enum path = "/binding/goodwe-control";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!GoodWeControlBinding, id, flags);
    }

    GoodWeClient client() { return _client.get; }
    const(char)[] client(GoodWeClient value) { if (_subscribed) return "disable binding before changing transport"; _client = value; _node = null; mark_set!(typeof(this), "client")(); restart(); return null; }
    ModbusNode node() { return _node.get; }
    const(char)[] node(ModbusNode value) { if (_subscribed) return "disable binding before changing transport"; _node = value; _client = null; mark_set!(typeof(this), "node")(); restart(); return null; }
    ref const(String) slave() const { return _slave; }
    const(char)[] slave(String value) { if (_subscribed) return "disable binding before changing slave"; _slave = value.move; mark_set!(typeof(this), "slave")(); restart(); return null; }
    ushort register_() const { return _register; }
    const(char)[] register_(ushort value) { if (_subscribed) return "disable binding before changing register"; _register = value; mark_set!(typeof(this), "register")(); restart(); return null; }
    GoodWeDispatch scheme() const { return _scheme; }
    const(char)[] scheme(GoodWeDispatch value) { if (_subscribed) return "disable binding before changing scheme"; _scheme = value; mark_set!(typeof(this), "scheme")(); restart(); return null; }
    ushort charge_limit() const { return _charge_limit; }
    void charge_limit(ushort value) { _charge_limit = value; mark_set!(typeof(this), "charge-limit")(); restart(); }
    ushort discharge_limit() const { return _discharge_limit; }
    void discharge_limit(ushort value) { _discharge_limit = value; mark_set!(typeof(this), "discharge-limit")(); restart(); }
    const(char)[] control_component() const { return _control_component.length ? _control_component[] : "inverter.control"; }
    const(char)[] control_component(const(char)[] value)
    {
        if (_subscribed) return "disable binding before changing component";
        if (!value.length) return "control component path is required";
        _control_component = value.make_string();
        mark_set!(typeof(this), "component")();
        restart();
        return null;
    }

protected:
    override bool validate() const
    {
        return _device.length && (_client.get !is null || (_node.get !is null && _slave.length)) && _register && _charge_limit && _discharge_limit;
    }

    override CompletionStatus startup()
    {
        ActiveObject transport = _client.get ? cast(ActiveObject)_client.get : cast(ActiveObject)_node.get;
        if (!transport || !transport.running)
            return CompletionStatus.continue_;
        if (_node.get)
        {
            auto server = get_module!ModbusProtocolModule.find_server_by_name(_slave[]);
            if (!server)
                return CompletionStatus.continue_;
            _address = server.universal_address;
        }
        DeviceBuilder builder = g_app.devices.open(_device[]);
        _bound_device = builder.device;
        Component control = builder.component(control_component(), "PowerControl");
        _kind = bind_element(builder, control, "kind", register_value_format!GoodWeControlKind(), Access.read_write);
        builder.constant(control, "direction", "bidirectional");
        builder.constant(control, "unit", "W");
        builder.constant(control, "min", Watts(-cast(float)_discharge_limit));
        builder.constant(control, "max", Watts(_charge_limit));
        builder.constant(control, "step", Watts(1));
        builder.constant(control, "can_disable", true);
        builder.constant(control, "semantics", _scheme == GoodWeDispatch.legacy ? "battery charge/discharge; AC boundary unverified" : "battery power");
        _setpoint = bind_element(builder, control, "setpoint", register_value_format!Watts(), Access.read_write);
        _enable = bind_element(builder, control, "enable", register_value_format!bool(), Access.read_write);
        _applied = bind_element(builder, control, "applied", register_value_format!Watts());
        _measured = bind_element(builder, control, "measured_power", register_value_format!Watts());
        _available = bind_element(builder, control, "available", register_value_format!bool());
        _mode = bind_element(builder, control, "mode", register_value_format!ushort());
        _error = bind_element(builder, control, "result", register_value_format!(const(char)[])());
        Component watchdog = builder.component(tconcat(control_component(), ".watchdog"), "Watchdog");
        builder.constant(watchdog, "scope", "controller");
        builder.constant(watchdog, "timeout", Seconds(30));
        builder.constant(watchdog, "expiry_action", "request_autonomous");
        builder.constant(watchdog, "device_expiry_action", "unknown");
        _watchdog_feed = bind_element(builder, watchdog, "feed", register_value_format!uint(), Access.read_write);
        _watchdog_remaining = bind_element(builder, watchdog, "remaining", register_value_format!Seconds());
        _watchdog_armed = bind_element(builder, watchdog, "armed", register_value_format!bool());
        _watchdog_feed.value(0u);
        _watchdog_remaining.value(Seconds(0));
        _watchdog_armed.value(false);
        _setpoint.value(Watts(0));
        _kind.value(GoodWeControlKind.autonomous);
        _enable.value(true);
        _available.value(false);
        _error.value("awaiting confirmation");
        _phase = Phase.initial_wait;
        transport.subscribe(&transport_state);
        _subscribed = true;
        g_app.schedule(getTime(), &refresh);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        g_app.cancel(&refresh);
        ActiveObject transport = _client.get ? cast(ActiveObject)_client.get : cast(ActiveObject)_node.get;
        if (_setpoint && transport && transport.running && _phase != Phase.restored &&
            _phase != Phase.initial_wait && _phase != Phase.initial_read)
        {
            if (_phase == Phase.restoring)
                return CompletionStatus.continue_;
            if (_client.get) _client.cancel_requests(&aa55_response);
            if (_node.get) _node.cancel_requests(&modbus_response);
            _sent_mode = _enable.value.asBool ? 1 : 255;
            _sent_power = 0;
            _phase = Phase.restoring;
            if (send_write())
                return CompletionStatus.continue_;
        }
        detach_transport();
        if (_available)
            _available.value(false);
        if (_kind)
            _kind.value(GoodWeControlKind.autonomous);
        _setpoint = _enable = _kind = _applied = _measured = _available = _mode = _error = null;
        if (_watchdog_armed)
            _watchdog_armed.value(false);
        _watchdog_feed = _watchdog_remaining = _watchdog_armed = null;
        _phase = Phase.idle;
        return super.shutdown();
    }

private:
    enum Phase : ubyte { idle, initial_wait, initial_read, writing, verifying, reading, restoring, restored }
    ObjectRef!GoodWeClient _client;
    ObjectRef!ModbusNode _node;
    String _slave;
    String _control_component;
    Element* _setpoint;
    Element* _enable;
    Element* _kind;
    Element* _applied;
    Element* _measured;
    Element* _available;
    Element* _mode;
    Element* _error;
    Element* _watchdog_feed;
    Element* _watchdog_remaining;
    Element* _watchdog_armed;
    ushort _register;
    ushort _charge_limit = 1000;
    ushort _discharge_limit = 1000;
    ushort _sent_mode;
    ushort _sent_power;
    ubyte _address;
    GoodWeDispatch _scheme;
    Phase _phase;
    bool _subscribed;

    void detach_transport()
    {
        if (_client.get)
        {
            _client.cancel_requests(&aa55_response);
            if (_subscribed) _client.unsubscribe(&transport_state);
        }
        if (_node.get)
        {
            _node.cancel_requests(&modbus_response);
            if (_subscribed) _node.unsubscribe(&transport_state);
        }
        _subscribed = false;
    }

    void transport_state(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void refresh(MonoTime now)
    {
        g_app.schedule(now + 1.seconds, &refresh);
        Element* work_mode = _bound_device.find_element(_scheme == GoodWeDispatch.legacy ? "status.operating_mode" : "inverter.mode");
        Element* battery_voltage = _bound_device.find_element("battery.meter.voltage");
        Element* battery_current = _bound_device.find_element("battery.meter.current");
        _available.value(_enable.value.asBool && work_mode && work_mode.record_update() != SysTime() &&
            getSysTime() - work_mode.record_update() <= 30.seconds &&
            work_mode.value.asDouble == (_scheme == GoodWeDispatch.legacy ? 2 : 1) && battery_voltage &&
            battery_voltage.record_update() != SysTime() && getSysTime() - battery_voltage.record_update() <= 5.seconds &&
            battery_voltage.normalised_value() > 10);
        float measured = float.nan;
        // These profiles sample voltage and current together. Derived power/current
        // records may retain their timestamp while their inputs remain unchanged.
        if (battery_voltage && battery_current && battery_voltage.record_update() != SysTime() && getSysTime() - battery_voltage.record_update() <= 5.seconds)
            measured = -cast(float)(battery_voltage.normalised_value() * battery_current.normalised_value());
        _measured.value(Watts(measured));
        bool enabled = _enable.value.isBool && _enable.value.asBool;
        bool controlled = _kind.value.asLong == GoodWeControlKind.continuous;
        SysTime renewed = _kind.record_update() > _setpoint.record_update() ? _kind.record_update() : _setpoint.record_update();
        if (_watchdog_feed.record_update() > renewed)
            renewed = _watchdog_feed.record_update();
        double remaining = controlled ? 30 - (getSysTime() - renewed).as!"seconds" : 0;
        _watchdog_remaining.value(Seconds(remaining > 0 ? remaining : 0));
        _watchdog_armed.value(controlled && remaining > 0);
        if (controlled && getSysTime() - renewed > 30.seconds)
        {
            _kind.value(GoodWeControlKind.autonomous);
            controlled = false;
            log.info("manual override expired; restoring automatic mode");
        }
        if (_phase == Phase.restored)
        {
            if (!controlled && enabled == (_sent_mode != 255))
                return;
            _phase = Phase.idle;
        }
        if (_phase != Phase.idle && _phase != Phase.verifying && _phase != Phase.initial_wait)
            return;
        if (_phase == Phase.initial_wait)
        {
            if (send_read())
                _phase = Phase.initial_read;
            return;
        }
        if (_phase == Phase.verifying)
        {
            send_read();
            return;
        }
        if (!enabled)
        {
            _sent_mode = 255;
            _sent_power = 0;
        }
        else if (controlled)
        {
            float watts = cast(float)_setpoint.value.asQuantity.normalise().value;
            const(char)[] error = setpoint_error(watts);
            if (error.length)
            {
                _error.value(error);
                watts = 0;
            }
            encode_dispatch(_scheme, watts, _sent_mode, _sent_power);
        }
        else
        {
            _sent_mode = 1;
            _sent_power = 0;
        }
        _phase = Phase.writing;
        if (!send_write())
        {
            _phase = Phase.idle;
            _error.value("transport busy or unavailable");
        }
    }

    const(char)[] setpoint_error(float watts)
    {
        // Native targets have 1 W resolution. Validate the rounded command, so
        // unit conversion noise at an exact configured limit cannot reject it.
        if (!(watts > -cast(float)_discharge_limit - 0.5f && watts < cast(float)_charge_limit + 0.5f))
            return "invalid or out-of-range setpoint";
        if (watts <= -0.5f)
        {
            Element* soc = _bound_device.find_element("battery.store.soc");
            if (!soc || soc.record_update() == SysTime() || getSysTime() - soc.record_update() > 30.seconds || !(soc.value.asFloat > 20))
                return "discharge blocked: SOC reserve or stale SOC";
        }
        return null;
    }

    bool send_write()
    {
        if (_client.get)
        {
            ubyte[4] payload = [cast(ubyte)(_sent_mode >> 8), cast(ubyte)_sent_mode, cast(ubyte)(_sent_power >> 8), cast(ubyte)_sent_power];
            return _client.send_modbus(16, _register, 2, payload, &aa55_response);
        }
        if (!_node.get)
            return false;
        ushort[2] words = [_sent_mode, _sent_power];
        ModbusPDU request = createMessage_Write(RegisterType.holding_register, _register, words);
        return _node.sendRequest(_address, request, &modbus_response, &modbus_error);
    }

    bool send_read()
    {
        bool sent;
        if (_client.get)
            sent = _client.send_modbus(3, _register, 2, null, &aa55_response);
        else if (_node.get)
        {
            ModbusPDU request = createMessage_Read(RegisterType.holding_register, _register, 2);
            sent = _node.sendRequest(_address, request, &modbus_response, &modbus_error);
        }
        if (sent)
            _phase = Phase.reading;
        return sent;
    }

    void aa55_response(bool success, ref const GoodWeRequest request, MonoTime, const(ubyte)[] data, void*)
    {
        complete(success, cast(ubyte)request.function_code == 3, data);
    }

    void modbus_response(ref const ModbusPDU request, ref ModbusPDU response, MonoTime, MonoTime)
    {
        bool read = request.function_code == FunctionCode.read_holding_registers;
        bool valid = response.function_code == request.function_code;
        const(ubyte)[] data = response.data;
        if (read)
        {
            enum size_t bytes = 4;
            valid = valid && data.length == bytes + 1 && data[0] == bytes;
            if (valid) data = data[1 .. $];
        }
        else
            valid = valid && data.length == 4 && data == request.data[0 .. 4];
        complete(valid, read, data);
    }

    void modbus_error(ModbusErrorType error, ref const ModbusPDU, MonoTime)
    {
        if (error != ModbusErrorType.Retrying)
            complete(false, false, null);
    }

    void complete(bool success, bool read, const(ubyte)[] data)
    {
        if (_phase == Phase.initial_read)
        {
            _phase = Phase.idle;
            if (!success || !read || data.length != 4)
            {
                _phase = Phase.initial_wait;
                _error.value("initial mode read failed");
                return;
            }
            ushort mode = cast(ushort)((uint(data[0]) << 8) | data[1]);
            _mode.value(mode);
            _sent_mode = mode;
            _sent_power = cast(ushort)((uint(data[2]) << 8) | data[3]);
            _phase = Phase.restored;
            _enable.value(mode != 255);
            _error.value(mode == 255 ? "stopped" : "initial mode read");
            return;
        }
        if (_phase == Phase.restoring)
        {
            _phase = Phase.restored;
            _error.value(success ? _sent_mode == 255 ? "stopped state retained" : "automatic mode request acknowledged" : "control release failed");
            return;
        }
        if (!success)
        {
            _phase = Phase.idle;
            _error.value("command failed");
            return;
        }
        if (!read)
        {
            _phase = Phase.verifying;
            send_read();
            return;
        }
        _phase = Phase.idle;
        if (data.length != 4 || ((uint(data[0]) << 8) | data[1]) != _sent_mode || ((uint(data[2]) << 8) | data[3]) != _sent_power)
        {
            _error.value("readback mismatch");
            return;
        }
        _mode.value(_sent_mode);
        if (_sent_mode == 1 || _sent_mode == 255)
            _phase = Phase.restored;
        _applied.value(Watts(_sent_mode == 1 || _sent_mode == 255 ? float.nan : _sent_mode == 3 || _sent_mode == 12 ? -cast(float)_sent_power : cast(float)_sent_power));
        const(char)[] error = _sent_mode == 1 || _sent_mode == 255 ? null : setpoint_error(cast(float)_setpoint.value.asQuantity.normalise().value);
        _error.value(error.length ? error : _sent_mode == 1 ? "automatic mode read back" : _sent_mode == 255 ? "stopped" : "confirmed");
        note_activity();
    }
}

void encode_dispatch(GoodWeDispatch scheme, float watts, out ushort mode, out ushort power) pure
{
    power = cast(ushort)((watts < 0 ? -watts : watts) + 0.5f);
    mode = scheme == GoodWeDispatch.legacy ? (power && watts > 0 ? 2 : 3) : (!power ? 8 : watts > 0 ? 11 : 12);
}

unittest
{
    ushort mode, power;
    encode_dispatch(GoodWeDispatch.battery_power, 123, mode, power);
    assert(mode == 11 && power == 123);
    encode_dispatch(GoodWeDispatch.battery_power, -137, mode, power);
    assert(mode == 12 && power == 137);
    encode_dispatch(GoodWeDispatch.battery_power, 0, mode, power);
    assert(mode == 8 && power == 0);
    encode_dispatch(GoodWeDispatch.battery_power, 222.00003f, mode, power);
    assert(mode == 11 && power == 222);
    encode_dispatch(GoodWeDispatch.battery_power, -137.00002f, mode, power);
    assert(mode == 12 && power == 137);
    encode_dispatch(GoodWeDispatch.battery_power, -0.49f, mode, power);
    assert(mode == 8 && power == 0);
    encode_dispatch(GoodWeDispatch.legacy, 0, mode, power);
    assert(mode == 3 && power == 0);
}
