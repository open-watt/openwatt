module protocol.tesla.binding;

import urt.array;
import urt.log;
import urt.mem.string : addString;
import urt.meta : AliasSeq;
import urt.meta.enuminfo : enum_info;
import urt.si;
import urt.si.quantity;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.plugin;
import manager.sample;
import manager.series;

import protocol.tesla;
import protocol.tesla.master;
import protocol.tesla.twc;

version = DebugTWCBinding;

nothrow @nogc:


class TeslaTWCBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("slave_id", slave_id));
nothrow @nogc:

    enum type_name = "twc-binding";
    enum path = "/binding/tesla/twc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaTWCBinding, id, flags);
    }

    final ushort slave_id() const pure
        => _slave_id;
    final void slave_id(ushort value)
    {
        if (_slave_id == value)
            return;
        _slave_id = value;
        mark_set!(typeof(this), "slave_id")();
        restart();
    }

    final override bool validate() const pure
    {
        return !_device.empty && _slave_id != 0;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        if (!_master)
        {
            auto tesla_mod = get_module!TeslaProtocolModule;
            outer: foreach (twc; tesla_mod.twc_masters.values)
            {
                foreach (i, ref c; twc.chargers)
                {
                    if (_slave_id == c.id)
                    {
                        _master = twc;
                        _charger_index = cast(ubyte)i;
                        break outer;
                    }
                }
            }
            if (!_master)
                return CompletionStatus.continue_;
        }

        if (_target_current && _target_current.access != Access.read)
        {
            _target_current.add_subscriber(&on_target_current_change);
            _subscribed = true;
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _target_current.remove_subscriber(&on_target_current_change);
            _subscribed = false;
        }
        _master = null;
        _target_current = null;
        _elements.clear();
        _built = false;    // materialise() must rebuild _elements next startup
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_master)
            return;

        TeslaTWCMaster.Charger* charger = &_master.chargers[_charger_index];
        SysTime timestamp = getSysTime();

        // TODO: user can write to target_current; we just push the master's view here
        foreach (ref e; _elements)
        {
            final switch (e.kind)
            {
                case SampleKind.setpoint:        observe(e, charger.target_current, timestamp);                                      break;
                case SampleKind.state:           observe(e, cast(ubyte)charger.charger_state, timestamp);                            break;
                case SampleKind.twc_state:       observe(e, cast(ubyte)charger.state, timestamp);                                    break;
                case SampleKind.max:             observe(e, charger.max_current, timestamp);                                         break;
                case SampleKind.current:         observe(e, (charger.flags & 2) ? charger.current : ushort(0), timestamp);            break;
                case SampleKind.voltage1:        observe(e, (charger.flags & 2) ? charger.voltage1 : ushort(0), timestamp);           break;
                case SampleKind.voltage2:        observe(e, (charger.flags & 2) ? charger.voltage2 : ushort(0), timestamp);           break;
                case SampleKind.voltage3:        observe(e, (charger.flags & 2) ? charger.voltage3 : ushort(0), timestamp);           break;
                case SampleKind.power:           observe(e, (charger.flags & 2) ? charger.total_power : ushort(0), timestamp);       break;
                case SampleKind.power1:          observe(e, (charger.flags & 2) ? charger.power1 : ushort(0), timestamp);             break;
                case SampleKind.power2:          observe(e, (charger.flags & 2) ? charger.power2 : ushort(0), timestamp);             break;
                case SampleKind.power3:          observe(e, (charger.flags & 2) ? charger.power3 : ushort(0), timestamp);             break;
                case SampleKind.import_:
                case SampleKind.lifetime_energy:
                    observe(e, (charger.flags & 2) ? ulong(charger.lifetime_energy) * 1000 : ulong(0), timestamp);
                    break;
                case SampleKind.serial_number:   observe_text(e, (charger.flags & 4) ? charger.serial_number[] : "", timestamp);       break;
                case SampleKind.vin:             observe_text(e, (charger.flags & 0xF0) == 0xF0 ? charger.vin[] : "", timestamp);      break;
                case SampleKind.circuit:         observe_text(e, (charger.flags & 0xF0) == 0xF0 ? charger.vin[] : "", timestamp);      break;
            }
        }
    }

protected:
    override bool materialise()
    {
        if (_built)
            return true;

        Device device;
        if (Device* existing = _device[] in g_app.devices)
            device = *existing;
        else
        {
            device = g_app.allocator.allocT!Device(_device);
            g_app.devices.insert(device.id[], device);
        }

        Component info = find_or_create_component(device, "info", "DeviceInfo");
        set_constant(find_or_create_element(info, "type"), "evse");
        set_constant(find_or_create_element(info, "name"), "Tesla Wall Charger Gen2");
        add_sample(info, "serial_number", SampleKind.serial_number, text_format());

        Component status = find_or_create_component(device, "status", "DeviceStatus");
        set_constant(find_or_create_element(status, "address"), slave_id); // id? slave-id? what's a good element name?
        add_sample(status, "lifetime_energy", SampleKind.lifetime_energy, quantity_format(ValueType.u64, WattHour));
        add_sample(status, "vin", SampleKind.vin, text_format());

        Component evse = find_or_create_component(device, "evse", "EVSE");
        add_sample(evse, "state", SampleKind.state, enum_format!(TeslaTWCMaster.ChargerState));
        add_sample(evse, "twc_state", SampleKind.twc_state, enum_format!TWCState());

        Component grid = find_or_create_component(device, "grid", "Port");
        set_constant(find_or_create_element(grid, "role"), "grid");
        set_constant(find_or_create_element(grid, "flow"), "consume");

        Component car = find_or_create_component(device, "car", "Port");
        set_constant(find_or_create_element(car, "role"), "car");
        set_constant(find_or_create_element(car, "flow"), "supply");
        add_sample(car, "circuit", SampleKind.circuit, text_format());

        Component control = find_or_create_component(grid, "control", "PowerControl");
        set_constant(find_or_create_element(control, "kind"), "continuous");
        set_constant(find_or_create_element(control, "direction"), "consume");
        set_constant(find_or_create_element(control, "unit"), "A");
        set_constant(find_or_create_element(control, "step"), 1);
        set_constant(find_or_create_element(control, "min"), CentiAmps(500));
        set_constant(find_or_create_element(control, "can_disable"), false);
        _target_current = add_sample(control, "setpoint", SampleKind.setpoint, centiamps_format(), Access.read_write);
        add_sample(control, "max", SampleKind.max, centiamps_format());

        Component meter = find_or_create_component(grid, "meter", "EnergyMeter");
        set_constant(find_or_create_element(meter, "type"), "three-phase");
        add_sample(meter, "voltage1", SampleKind.voltage1, quantity_format(ValueType.u16, ScaledUnit(Volt)));
        add_sample(meter, "voltage2", SampleKind.voltage2, quantity_format(ValueType.u16, ScaledUnit(Volt)));
        add_sample(meter, "voltage3", SampleKind.voltage3, quantity_format(ValueType.u16, ScaledUnit(Volt)));
        add_sample(meter, "current", SampleKind.current, centiamps_format());
        add_sample(meter, "power1", SampleKind.power1, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(meter, "power2", SampleKind.power2, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(meter, "power3", SampleKind.power3, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(meter, "power", SampleKind.power, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(meter, "import", SampleKind.import_, quantity_format(ValueType.u64, WattHour));

        _built = true;
        return true;
    }

private:

    ushort _slave_id;

    TeslaTWCMaster _master;
    ubyte _charger_index;

    bool _subscribed;
    bool _built;

    Element* _target_current;
    Array!SampleElement _elements;

    enum SampleKind : ubyte
    {
        setpoint,
        state,
        twc_state,
        max,
        current,
        voltage1,
        voltage2,
        voltage3,
        power,
        power1,
        power2,
        power3,
        import_,
        lifetime_energy,
        serial_number,
        vin,
        circuit
    }

    struct SampleElement
    {
        Element* element;
        const(DataFormat)* format;
        SampleKind kind;
    }

    Component find_or_create_component(Component parent, const(char)[] id, const(char)[] template_)
    {
        foreach (c; parent.components)
            if (c.id[] == id)
                return c;
        Component c = g_app.allocator.allocT!Component(String(id.addString()));
        c.template_ = template_.addString();
        c.parent = parent;
        parent.components ~= c;
        return c;
    }

    Element* find_or_create_element(Component parent, const(char)[] id, Access access = Access.read)
    {
        foreach (e; parent.elements)
            if (e.id[] == id)
                return e;
        Element* e = g_app.allocator.allocT!Element();
        e.parent = parent;
        e.id = id.addString();
        e.access = access;
        parent.elements ~= e;
        g_app.notify_element_created(e);
        return e;
    }

    Element* add_sample(Component parent, const(char)[] id, SampleKind kind, const(DataFormat)* format, Access access = Access.read)
    {
        Element* e = find_or_create_element(parent, id, access);
        if (!e.series.format)
            e.series.format = format;
        _elements ~= SampleElement(e, format, kind);
        return e;
    }

    const(DataFormat)* quantity_format(ValueType type, ScaledUnit unit)
        => format_by_index(register_format(DataFormat(type, SeriesKind.held, unit)));

    const(DataFormat)* centiamps_format()
        => quantity_format(ValueType.u16, ScaledUnit(Ampere, -2));

    const(DataFormat)* enum_format(E)()
        => format_by_index(register_format(DataFormat(ValueType.u8, SeriesKind.held, enum_info!E.make_void())));

    const(DataFormat)* text_format()
    {
        DataFormat format = DataFormat(ValueType.char_, SeriesKind.held);
        format.count = 0;
        return format_by_index(register_format(format));
    }

    void observe(T)(ref SampleElement sample, T value, SysTime timestamp)
    {
        const(void)[] record = (cast(const(void)*)&value)[0 .. T.sizeof];
        if (sample.element.series.format is sample.format)
            sample.element.observe_record(record, timestamp);
        else
            sample.element.value(box_record(record.ptr, *sample.format), timestamp);
    }

    void observe_text(ref SampleElement sample, const(char)[] value, SysTime timestamp)
    {
        if (sample.element.series.format is sample.format)
            sample.element.observe_text(value, timestamp);
        else
            sample.element.value(value, timestamp);
    }

    void set_constant(T)(Element* e, T value)
    {
        if (e.sampling_mode != SamplingMode.constant)
        {
            e.value(value);
            e.sampling_mode = SamplingMode.constant;
        }
    }

    void on_target_current_change(ref Element e, ref const Variant val, SysTime ts, ref const Variant prev, SysTime prev_ts)
    {
        if (!_master)
            return;
        TeslaTWCMaster.Charger* charger = &_master.chargers[_charger_index];
        charger.target_current = (cast(CentiAmps)val.asQuantity()).value;
        version (DebugTWCBinding)
            log.trace("set target current: ", charger.target_current);
    }
}
