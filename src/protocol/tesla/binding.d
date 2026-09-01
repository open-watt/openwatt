module protocol.tesla.binding;

import urt.array;
import urt.log;
import urt.mem;
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

//version = DebugTWCBinding;

nothrow @nogc:


class TeslaTWCBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("master", master),
                                 Prop!("slave_id", slave_id),
                                 Prop!("max-current", max_current));
nothrow @nogc:

    enum type_name = "twc-binding";
    enum path = "/binding/tesla/twc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaTWCBinding, id, flags);
    }

    final inout(TeslaTWCMaster) master() inout pure
        => _master;
    final void master(TeslaTWCMaster value)
    {
        if (_master.get is value)
            return;
        detach();
        _master = value;
        mark_set!(typeof(this), "master")();
        restart();
    }

    final ushort slave_id() const pure
        => _slave_id;
    final void slave_id(ushort value)
    {
        if (_slave_id == value)
            return;
        detach();
        _slave_id = value;
        mark_set!(typeof(this), "slave_id")();
        restart();
    }

    final float max_current() const pure
        => _max_current / 100.0f;
    final void max_current(float value)
    {
        ushort ca = value > 0 ? cast(ushort)(value * 100) : 0;
        if (_max_current == ca)
            return;
        _max_current = ca;
        mark_set!(typeof(this), "max-current")();
        restart();
    }

    final override bool validate() const pure
    {
        return !_device.empty && _slave_id != 0 && _master !is null;
    }

    override CompletionStatus startup()
    {
        TeslaTWCMaster m = _master.get;
        if (!m || !m.running)
            return CompletionStatus.continue_;

        if (!materialise())
            return CompletionStatus.error;

        m.adopt(_slave_id, this, _max_current);
        _master.subscribe(&master_state_change);
        _subscribed = true;

        if (_target_current)
        {
            _target_current.subscribe(&on_target_current_change);
            _elem_subscribed = true;
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_elem_subscribed)
        {
            _target_current.unsubscribe(&on_target_current_change);
            _elem_subscribed = false;
        }
        detach();
        _target_current = null;
        _elements.clear();
        detach_device();
        _built = false;
        return CompletionStatus.complete;
    }

package:
    void push_samples(ref TeslaTWCMaster.Charger charger)
    {
        SysTime timestamp = getSysTime();

        foreach (ref e; _elements)
        {
            final switch (e.kind)
            {
                case SampleKind.setpoint:        write_sample(e, charger.charge_current, timestamp);                                      break;
                case SampleKind.state:           write_sample(e, cast(ubyte)charger.charger_state, timestamp);                            break;
                case SampleKind.twc_state:       write_sample(e, cast(ubyte)charger.state, timestamp);                                    break;
                case SampleKind.max:             write_sample(e, charger.max_current, timestamp);                                         break;
                case SampleKind.current:         write_sample(e, (charger.flags & 2) ? charger.current : ushort(0), timestamp);            break;
                case SampleKind.voltage1:        write_sample(e, (charger.flags & 2) ? charger.voltage1 : ushort(0), timestamp);           break;
                case SampleKind.voltage2:        write_sample(e, (charger.flags & 2) ? charger.voltage2 : ushort(0), timestamp);           break;
                case SampleKind.voltage3:        write_sample(e, (charger.flags & 2) ? charger.voltage3 : ushort(0), timestamp);           break;
                case SampleKind.power:           write_sample(e, (charger.flags & 2) ? charger.total_power : ushort(0), timestamp);       break;
                case SampleKind.power1:          write_sample(e, (charger.flags & 2) ? charger.power1 : ushort(0), timestamp);             break;
                case SampleKind.power2:          write_sample(e, (charger.flags & 2) ? charger.power2 : ushort(0), timestamp);             break;
                case SampleKind.power3:          write_sample(e, (charger.flags & 2) ? charger.power3 : ushort(0), timestamp);             break;
                case SampleKind.import_:
                case SampleKind.lifetime_energy:
                    write_sample(e, (charger.flags & 2) ? ulong(charger.lifetime_energy) * 1000 : ulong(0), timestamp);
                    break;
                case SampleKind.serial_number:   write_sample(e, (charger.flags & 4) ? charger.serial_number[] : "", timestamp);       break;
                case SampleKind.vin:             write_sample(e, (charger.flags & 0xF0) == 0xF0 ? charger.vin[] : "", timestamp);      break;
                case SampleKind.circuit:         write_sample(e, (charger.flags & 0xF0) == 0xF0 ? charger.vin[] : "", timestamp);      break;
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
            device = alloc!Device(_device);
            g_app.devices.insert(device);
        }
        _bound_device = device;

        Component info = find_or_create_component(device, "info", "DeviceInfo");
        set_constant(info, "type", "evse");
        set_constant(info, "name", "Tesla Wall Charger Gen2");
        add_sample(info, "serial_number", SampleKind.serial_number, text_format());

        Component status = find_or_create_component(device, "status", "DeviceStatus");
        set_constant(status, "address", slave_id);
        add_sample(status, "lifetime_energy", SampleKind.lifetime_energy, quantity_format(ValueType.u64, WattHour));
        add_sample(status, "vin", SampleKind.vin, text_format());

        Component evse = find_or_create_component(device, "evse", "EVSE");
        add_sample(evse, "state", SampleKind.state, enum_format!(TeslaTWCMaster.ChargerState));
        add_sample(evse, "twc_state", SampleKind.twc_state, enum_format!TWCState());

        Component grid = find_or_create_component(device, "grid", "Port");
        set_constant(grid, "role", "grid");
        set_constant(grid, "flow", "consume");

        Component car = find_or_create_component(device, "car", "Port");
        set_constant(car, "role", "car");
        set_constant(car, "flow", "supply");
        add_sample(car, "circuit", SampleKind.circuit, text_format());

        Component control = find_or_create_component(grid, "control", "PowerControl");
        set_constant(control, "kind", "continuous");
        set_constant(control, "direction", "consume");
        set_constant(control, "unit", "A");
        set_constant(control, "step", 1);
        set_constant(control, "min", CentiAmps(500));
        set_constant(control, "can_disable", false);
        _target_current = add_sample(control, "setpoint", SampleKind.setpoint, centiamps_format(), Access.read_write);
        add_sample(control, "max", SampleKind.max, centiamps_format());

        Component meter = find_or_create_component(grid, "meter", "EnergyMeter");
        set_constant(meter, "type", "three-phase");
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
        FormatId format;
        SampleKind kind;
    }

    ushort _slave_id;
    ushort _max_current;

    ObjectRef!TeslaTWCMaster _master;

    bool _subscribed;
    bool _elem_subscribed;
    bool _built;

    Element* _target_current;
    Array!SampleElement _elements;

    Component find_or_create_component(Component parent, const(char)[] id, const(char)[] template_)
    {
        foreach (c; parent.components)
            if (c.id[] == id)
            {
                if (!c.template_)
                    c.template_ = template_.make_string();
                return c;
            }
        Component c = alloc!Component(id.make_string());
        c.template_ = template_.make_string();
        c.parent = parent;
        parent.components ~= c;
        return c;
    }

    Element* find_or_create_element(Component parent, const(char)[] id, FormatId format, Access access = Access.none)
    {
        foreach (e; parent.elements)
        {
            if (e.id[] == id)
            {
                if (!e.format.valid)
                    e.format = format;
                else
                    assert(e.format == format || value_compatible(*format_info(format), *e.data_format),
                           "Tesla element format mismatch");
                if (access != Access.none)
                    e.access = cast(Access)(e.access | access);
                return e;
            }
        }
        Element* e = alloc_element();
        e.parent = parent;
        e.id = id.make_string();
        e.format = format;
        e.access = access;
        parent.elements ~= e;
        g_app.notify_element_created(e);
        return e;
    }

    Element* add_sample(Component parent, const(char)[] id, SampleKind kind, FormatId format, Access access = Access.read)
    {
        Element* e = find_or_create_element(parent, id, format);
        _elements ~= SampleElement(e, format, kind);
        _bound_device.attach_binding(this, e, access);
        return e;
    }

    FormatId quantity_format(ValueType type, ScaledUnit unit)
        => register_format(DataFormat(type, SeriesKind.held, unit));

    FormatId centiamps_format()
        => quantity_format(ValueType.u16, ScaledUnit(Ampere, -2));

    FormatId enum_format(E)()
        => register_format(DataFormat(ValueType.u8, SeriesKind.held, enum_info!E.make_void()));

    FormatId text_format()
    {
        DataFormat format = DataFormat(ValueType.char_, SeriesKind.held);
        format.count = 0;
        return register_format(format);
    }

    void write_sample(T)(ref SampleElement sample, T value, SysTime timestamp)
    {
        static if (is(T : const(char)[]))
        {
            if (sample.element.format == sample.format)
                sample.element.write_sample(value, timestamp);
            else
                sample.element.value(value, timestamp);
        }
        else
        {
            const(void)[] record = (cast(const(void)*)&value)[0 .. T.sizeof];
            if (sample.element.format == sample.format)
                sample.element.write_record(record, timestamp);
            else
                sample.element.value(box_record(record.ptr, *format_info(sample.format)), timestamp);
        }
    }

    void set_constant(T)(Component parent, const(char)[] id, T value)
    {
        Element* e = find_or_create_element(parent, id, register_value_format(value), Access.read);
        if (e.record_update() == SysTime())
        {
            e.value(value);
            e.sampling_mode = SamplingMode.constant;
        }
    }

    void detach()
    {
        if (_subscribed)
        {
            _master.unsubscribe(&master_state_change);
            _subscribed = false;
        }
        if (TeslaTWCMaster m = _master.get)
            m.detach(_slave_id, this);
    }

    void master_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void on_target_current_change(ref const SampleUpdate update)
    {
        TeslaTWCMaster m = _master.get;
        if (!m || update.element !is _target_current || !update.value_ready)
            return;
        ushort target = (cast(CentiAmps)update.value.asQuantity()).value;
        m.set_target_current(_slave_id, target);
        version (DebugTWCBinding)
            log.trace("set target current: ", target);
    }
}
