module driver.power.regulator;

import urt.mem : alloc;
import urt.meta : AliasSeq;
import urt.si.quantity : Quantity;
import urt.si.unit : Hertz;
import urt.string;
import urt.time : Duration, MonoTime, dur, getSysTime, getTime;

import manager : g_app;
import manager.base : ActiveObject, CompletionStatus, ObjectFlags, Prop;
import manager.binding : ProtocolBinding;
import manager.collection : CID, Collection, CollectionTypeInfo, collection_type_info;
import manager.component : Component, ComponentEvent;
import manager.console;
import manager.device : Device;
import manager.element : Access, Element, SampleUpdate, SamplingMode;
import manager.plugin : Module, DeclareModule;
import manager.series : register_value_format;

import urt.driver.gpio : GpioInterruptTrigger, Pull;

import driver.power.hardware;

nothrow @nogc:


alias Frequency = Quantity!(float, Hertz);

enum ZcEdge : ubyte
{
    rising,
    falling,
    change,
}


class PowerRegulator : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("psm-pin", psm_pin),
                                 Prop!("zc-pin", zc_pin),
                                 Prop!("psm-invert", psm_invert),
                                 Prop!("zc-edge", zc_edge),
                                 Prop!("zc-pull", zc_pull),
                                 Prop!("mode", mode),
                                 Prop!("level", level),
                                 Prop!("enable", enable),
                                 Prop!("window", window),
                                 Prop!("droop-start", droop_start),
                                 Prop!("droop-full", droop_full),
                                 Prop!("frequency", frequency, "status", "d"),
                                 Prop!("applied-level", applied_level, "status", "d"),
                                 Prop!("zc-ok", zc_ok, "status", "d"));
nothrow @nogc:

    enum type_name = "power-regulator";
    enum path = "/driver/power/regulator";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!PowerRegulator, id, flags);
    }

    final uint psm_pin() const pure
        => _psm_pin;
    final void psm_pin(uint value)
    {
        if (_psm_pin == value)
            return;
        _psm_pin = value;
        mark_set!(typeof(this), "psm-pin")();
        restart();
    }

    final uint zc_pin() const pure
        => _zc_pin;
    final void zc_pin(uint value)
    {
        if (_zc_pin == value)
            return;
        _zc_pin = value;
        mark_set!(typeof(this), "zc-pin")();
        restart();
    }

    final bool psm_invert() const pure
        => _psm_invert;
    final void psm_invert(bool value)
    {
        if (_psm_invert == value)
            return;
        _psm_invert = value;
        mark_set!(typeof(this), "psm-invert")();
        restart();
    }

    final ZcEdge zc_edge() const pure
        => _zc_edge;
    final void zc_edge(ZcEdge value)
    {
        if (_zc_edge == value)
            return;
        _zc_edge = value;
        mark_set!(typeof(this), "zc-edge")();
        restart();
    }

    final Pull zc_pull() const pure
        => _zc_pull;
    final void zc_pull(Pull value)
    {
        if (_zc_pull == value)
            return;
        _zc_pull = value;
        mark_set!(typeof(this), "zc-pull")();
        restart();
    }

    final FireMode mode() const pure
        => _mode;
    final void mode(FireMode value)
    {
        if (_mode == value)
            return;
        _mode = value;
        mark_set!(typeof(this), "mode")();
        push_params();
        publish_controls();
    }

    // target power fraction in percent; the ceiling when a droop curve is configured
    final float level() const pure
        => _level;
    final void level(float value)
    {
        if (value < 0)
            value = 0;
        else if (value > 100)
            value = 100;
        if (_level == value)
            return;
        _level = value;
        mark_set!(typeof(this), "level")();
        push_params();
        publish_controls();
    }

    final bool enable() const pure
        => _enable;
    final void enable(bool value)
    {
        if (_enable == value)
            return;
        _enable = value;
        mark_set!(typeof(this), "enable")();
        push_params();
        publish_controls();
    }

    // burst repeat window in full mains cycles; bounds the longest off-run at low levels
    final uint window() const pure
        => _window;
    final void window(uint value)
    {
        if (_window == value)
            return;
        _window = value;
        mark_set!(typeof(this), "window")();
        push_params();
    }

    // hertz
    final float droop_start() const pure
        => _droop_start;
    final void droop_start(float value)
    {
        if (_droop_start == value)
            return;
        _droop_start = value;
        mark_set!(typeof(this), "droop-start")();
        push_params();
    }

    // hertz
    final float droop_full() const pure
        => _droop_full;
    final void droop_full(float value)
    {
        if (_droop_full == value)
            return;
        _droop_full = value;
        mark_set!(typeof(this), "droop-full")();
        push_params();
    }

    final float frequency() const
    {
        FireStatus status = fire_status(*cast(FireEngine*)&_engine);
        return status.period_q4 ? 8_000_000.0f / status.period_q4 : 0;
    }

    final float applied_level() const
    {
        FireStatus status = fire_status(*cast(FireEngine*)&_engine);
        return status.level_q16 * (100.0f / 65536);
    }

    final bool zc_ok() const
    {
        FireStatus status = fire_status(*cast(FireEngine*)&_engine);
        return !status.fault && status.period_q4 != 0;
    }

    final override bool validate() const pure
    {
        if (_device.empty || _psm_pin == uint.max || _zc_pin == uint.max || _psm_pin == _zc_pin)
            return false;
        if (_window == 0 || _window > 1000)
            return false;
        if ((_droop_start != 0 || _droop_full != 0) && _droop_full <= _droop_start)
            return false;
        return true;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        if (!_opened)
        {
            FireConfig config;
            config.psm_gpio = _psm_pin;
            config.zc_gpio = _zc_pin;
            config.zc_trigger = cast(GpioInterruptTrigger)_zc_edge;
            config.zc_pull = _zc_pull;
            config.psm_invert = _psm_invert;
            if (!fire_open(_engine, config))
            {
                static if (fire_supported)
                    log.error("failed to claim regulator hardware; pins, counters, or link slots busy?");
                else
                    log.error("power regulator is not supported on this platform");
                return CompletionStatus.error;
            }
            _opened = true;
        }

        push_params();
        subscribe_elements();
        _subscribed = true;

        publish_controls();
        publish_status();
        _device_instance.notify(ComponentEvent.online);

        g_app.schedule(getTime() + telemetry_period, &telemetry);
        _scheduled = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_scheduled)
        {
            g_app.cancel(&telemetry);
            _scheduled = false;
        }
        unsubscribe();
        if (_opened)
        {
            fire_close(_engine);
            _opened = false;
        }
        return super.shutdown();
    }

protected:

    override bool materialise()
    {
        if (_built)
            return true;

        Device* found = _device[] in g_app.devices;
        if (!found)
            return false;
        _device_instance = *found;

        Component info = find_or_create_component(_device_instance, "info", "DeviceInfo");
        set_constant(info, "type", "power-regulator");

        Component status = find_or_create_component(_device_instance, "status", "DeviceStatus");
        _online = add_element!bool(status, "online");
        _frequency = add_element!Frequency(status, "frequency");
        _fault = add_element!bool(status, "fault");

        Component control = find_or_create_component(_device_instance, "control", "PowerControl");
        set_constant(control, "kind", "continuous");
        set_constant(control, "direction", "consume");
        set_constant(control, "unit", "%");
        set_constant(control, "min", 0.0f);
        set_constant(control, "max", 100.0f);
        set_constant(control, "can_disable", true);
        _level_e = add_element!float(control, "level", Access.read_write);
        _mode_e = add_element!FireMode(control, "mode", Access.read_write);
        _enable_e = add_element!bool(control, "enable", Access.read_write);
        _applied = add_element!float(control, "applied");

        g_app.request_rebind();
        _device_instance.notify(ComponentEvent.tree_changed);
        _built = true;
        return true;
    }

private:

    enum telemetry_period = dur!"seconds"(1);

    FireEngine _engine;
    Device _device_instance;
    uint _psm_pin = uint.max;
    uint _zc_pin = uint.max;
    uint _window = 50;
    float _level = 0;
    float _droop_start = 0;
    float _droop_full = 0;
    FireMode _mode;
    ZcEdge _zc_edge;
    Pull _zc_pull;
    bool _psm_invert;
    bool _enable = true;
    bool _opened;
    bool _built;
    bool _subscribed;
    bool _scheduled;

    Element* _online;
    Element* _frequency;
    Element* _fault;
    Element* _level_e;
    Element* _mode_e;
    Element* _enable_e;
    Element* _applied;

    void push_params()
    {
        if (!_opened)
            return;
        FireParams params;
        params.level = cast(uint)(_level * (65536.0f / 100) + 0.5f);
        if (params.level > 0x10000)
            params.level = 0x10000;
        params.window = _window;
        params.mode = _mode;
        params.enable = _enable;
        if (_droop_full > _droop_start && _droop_start > 0)
        {
            params.droop_start_mhz = cast(uint)(_droop_start * 1000 + 0.5f);
            params.droop_span_mhz = cast(uint)((_droop_full - _droop_start) * 1000 + 0.5f);
            if (params.droop_span_mhz)
                params.droop_slope_q16 = cast(uint)((ulong(params.level) << 16) / params.droop_span_mhz);
        }
        fire_set_params(_engine, params);
    }

    void telemetry(MonoTime now)
    {
        _scheduled = false;
        if (!running)
            return;

        publish_status();
        g_app.schedule(now + telemetry_period, &telemetry);
        _scheduled = true;
    }

    void publish_status()
    {
        FireStatus status = fire_status(_engine);
        auto timestamp = getSysTime();
        bool ok = !status.fault && status.period_q4 != 0;
        _online.value(ok, timestamp, &element_changed);
        _fault.value(status.fault, timestamp, &element_changed);
        _frequency.value(Frequency(status.period_q4 ? 8_000_000.0f / status.period_q4 : 0), timestamp, &element_changed);
        _applied.value(status.level_q16 * (100.0f / 65536), timestamp, &element_changed);
    }

    void publish_controls()
    {
        if (!_built)
            return;
        auto timestamp = getSysTime();
        _level_e.value(_level, timestamp, &element_changed);
        _mode_e.value(_mode, timestamp, &element_changed);
        _enable_e.value(_enable, timestamp, &element_changed);
    }

    void subscribe_elements()
    {
        _level_e.subscribe(&element_changed);
        _mode_e.subscribe(&element_changed);
        _enable_e.subscribe(&element_changed);
    }

    void unsubscribe()
    {
        if (!_subscribed)
            return;
        _level_e.unsubscribe(&element_changed);
        _mode_e.unsubscribe(&element_changed);
        _enable_e.unsubscribe(&element_changed);
        _subscribed = false;
    }

    void element_changed(ref const SampleUpdate update)
    {
        if (!update.value_ready)
            return;
        if (update.element is _level_e)
            level(update.value.asFloat);
        else if (update.element is _mode_e)
            mode(cast(FireMode)update.value.asLong);
        else if (update.element is _enable_e)
            enable(update.value.asBool);
    }

    Component find_or_create_component(Component parent, const(char)[] id, const(char)[] template_)
    {
        foreach (component; parent.components)
        {
            if (component.id[] == id)
                return component;
        }
        Component component = alloc!Component(id.make_string());
        component.template_ = template_.make_string();
        component.parent = parent;
        parent.components ~= component;
        return component;
    }

    Element* add_element(T)(Component parent, const(char)[] id, Access access = Access.read,
                            SamplingMode sampling = SamplingMode.report)
    {
        Element* element = parent.find_or_create_element(id, register_value_format!T());
        element.access = access;
        element.sampling_mode = sampling;
        return element;
    }

    void set_constant(T)(Component parent, const(char)[] id, auto ref T value)
    {
        Element* element = parent.find_or_create_element(id, register_value_format(value));
        if (element.sampling_mode != SamplingMode.constant)
        {
            element.value(value);
            element.sampling_mode = SamplingMode.constant;
        }
    }
}


class PowerRegulatorModule : Module
{
    mixin DeclareModule!"driver.power.regulator";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!FireMode();
        g_app.register_enum!ZcEdge();
        g_app.console.register_collection!PowerRegulator();
    }

    override void update()
    {
        Collection!PowerRegulator().update_all();
    }
}
