module driver.boards.smartevse.binding;

version (SmartEVSE):

import urt.meta : AliasSeq;
import urt.si.quantity : Quantity;
import urt.si.unit : Celsius, ScaledUnit, Volt;
import urt.string;
import urt.time : getSysTime;

import manager : g_app;
import manager.base : ActiveObject, CompletionStatus, ObjectFlags, ObjectRef, Prop, StateSignal;
import manager.binding : ProtocolBinding;
import manager.collection : CID, collection_type_info;
import manager.component : Component, ComponentEvent;
import manager.device : Device;
import manager.element : Access, Element, SampleUpdate, SamplingMode;
import manager.series : DataFormat, SeriesKind, ValueType, register_format, register_value_format;

import driver.boards.smartevse : DeciAmps, SmartEVSE, SmartEVSEADCCalibration,
                                SmartEVSEButton, SmartEVSEChange, SmartEVSEContactor2Mode,
                                SmartEVSEPilot, SmartEVSEState;
import driver.boards.smartevse.display : display_height, display_width;

nothrow @nogc:


alias DegreesC = Quantity!(short, Celsius);
alias MilliVolts = Quantity!(uint, ScaledUnit(Volt, -3));

class SmartEVSEBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("evse", evse));
nothrow @nogc:

    enum type_name = "smartevse-binding";
    enum path = "/binding/smartevse";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SmartEVSEBinding, id, flags);
    }

    final inout(SmartEVSE) evse() inout pure
        => _evse.get;

    final void evse(SmartEVSE value)
    {
        if (_evse.get is value)
            return;
        unsubscribe();
        _evse = value;
        mark_set!(typeof(this), "evse")();
        restart();
    }

    final override bool validate() const pure
        => _evse.get !is null && !_device.empty;

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        SmartEVSE hardware = _evse.get;
        if (!hardware)
            return CompletionStatus.continue_;

        hardware.subscribe_changes(&hardware_changed);
        hardware.subscribe(&hardware_state_changed);
        subscribe_elements();
        _subscribed = true;

        publish(SmartEVSEChange.all);
        publish_online();
        _device_instance.notify(ComponentEvent.online);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe();
        if (_device_instance)
            _device_instance.notify(ComponentEvent.offline);
        return CompletionStatus.complete;
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
        set_constant(info, "type", "evse");
        set_constant(info, "name", "SmartEVSE v3.0");

        Component status = find_or_create_component(_device_instance, "status", "DeviceStatus");
        _online = add_element!bool(status, "online");

        Component grid = find_or_create_component(_device_instance, "grid", "Port");
        set_constant(grid, "role", "parent");
        set_constant(grid, "flow", "consume");

        Component control = find_or_create_component(grid, "control", "PowerControl");
        set_constant(control, "kind", "continuous");
        set_constant(control, "direction", "consume");
        set_constant(control, "unit", "A");
        set_constant(control, "min", DeciAmps(60));
        set_constant(control, "step", DeciAmps(10));
        set_constant(control, "can_disable", true);
        _setpoint = add_element!DeciAmps(control, "setpoint", Access.read_write);
        _control_max = add_element!DeciAmps(control, "max");
        _enable = add_element!bool(control, "enable", Access.read_write);

        Component car = find_or_create_component(_device_instance, "car", "Port");
        set_constant(car, "role", "car");
        set_constant(car, "flow", "supply");

        Component evse_status = find_or_create_component(_device_instance, "evse", "EVSE");
        _state = add_element!SmartEVSEState(evse_status, "state", Access.read_write);
        _connected = add_element!bool(evse_status, "connected");
        _temperature = add_element!DegreesC(evse_status, "temp");
        _temperature_fault = add_element!bool(evse_status, "temperature_fault");
        _rcm_fault = add_element!bool(evse_status, "rcm_fault");

        Component config = find_or_create_component(_device_instance, "config", "Configuration");
        _max_current = add_element!DeciAmps(config, "max_current", Access.read_write, SamplingMode.config);
        _max_temperature = add_element!DegreesC(config, "max_temperature", Access.read_write, SamplingMode.config);
        _contactor2_mode = add_element!SmartEVSEContactor2Mode(
            config, "contactor2_mode", Access.read_write, SamplingMode.config);

        Component diagnostic = find_or_create_component(
            _device_instance, "diagnostic", "SmartEVSEDiagnostics");
        _pilot = add_element!SmartEVSEPilot(diagnostic, "pilot");
        _pwm = add_element!uint(diagnostic, "pwm");
        _effective_current = add_element!DeciAmps(diagnostic, "effective_current");
        _pp_max_current = add_element!DeciAmps(diagnostic, "pp_max_current");
        _pilot_min = add_element!MilliVolts(diagnostic, "pilot_min");
        _pilot_max = add_element!MilliVolts(diagnostic, "pilot_max");
        _pp_voltage = add_element!MilliVolts(diagnostic, "pp_voltage");
        _temperature_voltage = add_element!MilliVolts(diagnostic, "temperature_voltage");
        _adc_calibration = add_element!SmartEVSEADCCalibration(diagnostic, "adc_calibration");
        _rcm_input = add_element!bool(diagnostic, "rcm_input");
        _activation_wait = add_element!ubyte(diagnostic, "activation_wait");
        _activation_pulse = add_element!ubyte(diagnostic, "activation_pulse");
        _contactor1 = add_element!bool(diagnostic, "contactor1");
        _contactor2 = add_element!bool(diagnostic, "contactor2");

        Component buttons = find_or_create_component(_device_instance, "buttons", "Buttons");
        _button_left = add_element!bool(buttons, "left");
        _button_middle = add_element!bool(buttons, "middle");
        _button_right = add_element!bool(buttons, "right");

        Component display = find_or_create_component(_device_instance, "display", "Display");
        set_constant(display, "width", display_width);
        set_constant(display, "height", display_height);
        _backlight = add_element!bool(display, "backlight", Access.read_write);
        _frame = add_blob(display, "frame", Access.read_write);

        g_app.request_rebind();
        _device_instance.notify(ComponentEvent.tree_changed);
        _built = true;
        return true;
    }

private:

    ObjectRef!SmartEVSE _evse;
    Device _device_instance;
    bool _built;
    bool _subscribed;

    Element* _online;
    Element* _setpoint;
    Element* _control_max;
    Element* _enable;
    Element* _state;
    Element* _connected;
    Element* _temperature;
    Element* _temperature_fault;
    Element* _rcm_fault;
    Element* _max_current;
    Element* _max_temperature;
    Element* _contactor2_mode;
    Element* _pilot;
    Element* _pwm;
    Element* _effective_current;
    Element* _pp_max_current;
    Element* _pilot_min;
    Element* _pilot_max;
    Element* _pp_voltage;
    Element* _temperature_voltage;
    Element* _adc_calibration;
    Element* _rcm_input;
    Element* _activation_wait;
    Element* _activation_pulse;
    Element* _contactor1;
    Element* _contactor2;
    Element* _button_left;
    Element* _button_middle;
    Element* _button_right;
    Element* _backlight;
    Element* _frame;

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
                            SamplingMode mode = SamplingMode.report)
    {
        Element* element = parent.find_or_create_element(id, register_value_format!T());
        element.access = access;
        element.sampling_mode = mode;
        return element;
    }

    Element* add_blob(Component parent, const(char)[] id, Access access)
    {
        DataFormat format = DataFormat(ValueType.u8, SeriesKind.held);
        format.count = 0;
        Element* element = parent.find_or_create_element(id, register_format(format));
        element.access = access;
        element.sampling_mode = SamplingMode.report;
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

    void subscribe_elements()
    {
        _setpoint.subscribe(&element_changed);
        _enable.subscribe(&element_changed);
        _state.subscribe(&element_changed);
        _max_current.subscribe(&element_changed);
        _max_temperature.subscribe(&element_changed);
        _contactor2_mode.subscribe(&element_changed);
        _backlight.subscribe(&element_changed);
        _frame.subscribe(&element_changed);
    }

    void unsubscribe()
    {
        if (!_subscribed)
            return;

        SmartEVSE hardware = _evse.get;
        if (hardware)
        {
            hardware.unsubscribe_changes(&hardware_changed);
            hardware.unsubscribe(&hardware_state_changed);
        }
        _setpoint.unsubscribe(&element_changed);
        _enable.unsubscribe(&element_changed);
        _state.unsubscribe(&element_changed);
        _max_current.unsubscribe(&element_changed);
        _max_temperature.unsubscribe(&element_changed);
        _contactor2_mode.unsubscribe(&element_changed);
        _backlight.unsubscribe(&element_changed);
        _frame.unsubscribe(&element_changed);
        _subscribed = false;
    }

    void hardware_changed(SmartEVSE, uint changes)
    {
        publish(changes);
    }

    void hardware_state_changed(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.destroyed)
        {
            restart();
            return;
        }
        publish_online();
    }

    void publish(uint changes)
    {
        SmartEVSE hardware = _evse.get;
        if (!hardware)
            return;

        auto timestamp = getSysTime();
        if (changes & SmartEVSEChange.current)
            _setpoint.value(hardware.current, timestamp, &element_changed);
        if (changes & (SmartEVSEChange.max_current | SmartEVSEChange.pp_max_current))
        {
            DeciAmps maximum = hardware.max_current.value < hardware.pp_max_current.value
                            ? hardware.max_current : hardware.pp_max_current;
            _control_max.value(maximum, timestamp, &element_changed);
        }
        if (changes & SmartEVSEChange.max_current)
            _max_current.value(hardware.max_current, timestamp, &element_changed);
        if (changes & SmartEVSEChange.pp_max_current)
            _pp_max_current.value(hardware.pp_max_current, timestamp, &element_changed);
        if (changes & SmartEVSEChange.stopped)
            _enable.value(!hardware.stopped, timestamp, &element_changed);
        if (changes & SmartEVSEChange.state)
        {
            _state.value(hardware.state, timestamp, &element_changed);
            _connected.value(connected(hardware), timestamp, &element_changed);
        }
        if (changes & SmartEVSEChange.pilot)
        {
            _pilot.value(hardware.pilot, timestamp, &element_changed);
            _connected.value(connected(hardware), timestamp, &element_changed);
        }
        if (changes & SmartEVSEChange.pwm)
            _pwm.value(hardware.pwm, timestamp, &element_changed);
        if (changes & SmartEVSEChange.effective_current)
            _effective_current.value(hardware.effective_current, timestamp, &element_changed);
        if (changes & SmartEVSEChange.pilot_min_mv)
            _pilot_min.value(MilliVolts(hardware.pilot_min_mv), timestamp, &element_changed);
        if (changes & SmartEVSEChange.pilot_max_mv)
            _pilot_max.value(MilliVolts(hardware.pilot_max_mv), timestamp, &element_changed);
        if (changes & SmartEVSEChange.pp_mv)
            _pp_voltage.value(MilliVolts(hardware.pp_mv), timestamp, &element_changed);
        if (changes & SmartEVSEChange.temperature_mv)
            _temperature_voltage.value(MilliVolts(hardware.temperature_mv), timestamp, &element_changed);
        if (changes & SmartEVSEChange.temperature)
            _temperature.value(DegreesC(hardware.temperature), timestamp, &element_changed);
        if (changes & SmartEVSEChange.max_temperature)
            _max_temperature.value(DegreesC(hardware.max_temperature), timestamp, &element_changed);
        if (changes & SmartEVSEChange.temperature_fault)
            _temperature_fault.value(hardware.temperature_fault, timestamp, &element_changed);
        if (changes & SmartEVSEChange.rcm_input)
            _rcm_input.value(hardware.rcm_input, timestamp, &element_changed);
        if (changes & SmartEVSEChange.rcm_fault)
            _rcm_fault.value(hardware.rcm_fault, timestamp, &element_changed);
        if (changes & SmartEVSEChange.activation_wait)
            _activation_wait.value(hardware.activation_wait, timestamp, &element_changed);
        if (changes & SmartEVSEChange.activation_pulse)
            _activation_pulse.value(hardware.activation_pulse, timestamp, &element_changed);
        if (changes & SmartEVSEChange.contactor2_mode)
            _contactor2_mode.value(hardware.contactor2_mode, timestamp, &element_changed);
        if (changes & SmartEVSEChange.contactor1)
            _contactor1.value(hardware.contactor1, timestamp, &element_changed);
        if (changes & SmartEVSEChange.contactor2)
            _contactor2.value(hardware.contactor2, timestamp, &element_changed);
        if (changes & SmartEVSEChange.buttons)
        {
            ubyte pressed = hardware.buttons;
            _button_left.value((pressed & SmartEVSEButton.left) != 0, timestamp, &element_changed);
            _button_middle.value((pressed & SmartEVSEButton.middle) != 0, timestamp, &element_changed);
            _button_right.value((pressed & SmartEVSEButton.right) != 0, timestamp, &element_changed);
        }
        if (changes & SmartEVSEChange.backlight)
            _backlight.value(hardware.backlight, timestamp, &element_changed);
        if (changes & SmartEVSEChange.frame)
            _frame.value(hardware.frame, timestamp, &element_changed);
        if (changes == SmartEVSEChange.all)
            _adc_calibration.value(hardware.adc_calibration, timestamp, &element_changed);
    }

    void publish_online()
    {
        SmartEVSE hardware = _evse.get;
        bool online = hardware && hardware.running;
        auto timestamp = getSysTime();
        _online.value(online, timestamp, &element_changed);
        _enable.value(online && !hardware.stopped, timestamp, &element_changed);
    }

    bool connected(SmartEVSE hardware) const pure
    {
        final switch (hardware.pilot)
        {
            case SmartEVSEPilot.v3:
            case SmartEVSEPilot.v6:
            case SmartEVSEPilot.v9:
                return true;
            case SmartEVSEPilot.invalid:
            case SmartEVSEPilot.diode:
            case SmartEVSEPilot.v12:
            case SmartEVSEPilot.short_:
                return false;
        }
    }

    void element_changed(ref const SampleUpdate update)
    {
        if (!update.value_ready)
            return;
        SmartEVSE hardware = _evse.get;
        if (!hardware)
            return;

        const(char)[] error;
        uint restore;
        if (update.element is _setpoint)
        {
            hardware.current(cast(DeciAmps)update.value.asQuantity());
            restore = SmartEVSEChange.current;
        }
        else if (update.element is _enable)
        {
            error = update.value.asBool ? hardware.start_charging()
                                        : hardware.stop_charging();
            restore = SmartEVSEChange.stopped;
        }
        else if (update.element is _state)
        {
            error = hardware.state(cast(SmartEVSEState)update.value.asLong);
            restore = SmartEVSEChange.state | SmartEVSEChange.rcm_fault;
        }
        else if (update.element is _max_current)
        {
            hardware.max_current(cast(DeciAmps)update.value.asQuantity());
            restore = SmartEVSEChange.max_current | SmartEVSEChange.pp_max_current;
        }
        else if (update.element is _max_temperature)
        {
            hardware.max_temperature((cast(DegreesC)update.value.asQuantity()).value);
            restore = SmartEVSEChange.max_temperature;
        }
        else if (update.element is _backlight)
        {
            hardware.backlight(update.value.asBool);
            restore = SmartEVSEChange.backlight;
        }
        else if (update.element is _frame)
        {
            if (!hardware.frame(update.value.asBuffer))
                error = "frame must be the full panel image";
            restore = SmartEVSEChange.frame;
        }
        else if (update.element is _contactor2_mode)
        {
            error = hardware.contactor2_mode(
                cast(SmartEVSEContactor2Mode)update.value.asLong);
            restore = SmartEVSEChange.contactor2_mode;
        }

        if (error)
        {
            log.warning("SmartEVSE command rejected: ", error);
            publish(restore);
            if (update.element is _enable)
                publish_online();
        }
    }
}
