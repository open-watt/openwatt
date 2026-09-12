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
import manager.series : Scalar;

import protocol.tesla;
import protocol.tesla.master;
import protocol.tesla.twc;

//version = DebugTWCBinding;

nothrow @nogc:


class TeslaTWCBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("master", master),
                                 Prop!("slave_id", slave_id));
nothrow @nogc:

    enum type_name = "twc-binding";
    enum path = "/binding/tesla/twc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaTWCBinding, id, flags);
        _quiet_limit = 30.seconds;
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

        if (!m.adopt(_slave_id, this))
        {
            _fail_reason = "charger already has a binding";
            return CompletionStatus.error;
        }
        if (_target_current.record_update() != SysTime())
            m.set_target_current(_slave_id, (cast(CentiAmps)_target_current.record_value().asQuantity()).value);
        if (_current_cap.record_update() != SysTime())
            m.set_cap(_slave_id, (cast(CentiAmps)_current_cap.record_value().asQuantity()).value);
        _master.subscribe(&master_state_change);
        _subscribed = true;

        if (_target_current)
            _target_current.subscribe(&on_target_current_change);
        if (_current_cap)
            _current_cap.subscribe(&on_cap_change);
        _elem_subscribed = true;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_elem_subscribed)
        {
            if (_target_current)
                _target_current.unsubscribe(&on_target_current_change);
            if (_current_cap)
                _current_cap.unsubscribe(&on_cap_change);
            _elem_subscribed = false;
        }
        detach();
        _target_current = null;
        _current_cap = null;
        _elements.clear();
        _built = false;
        return super.shutdown();
    }

package:
    void refresh_access(bool writable)
    {
        if (!_built)
            return;
        Access access = writable ? Access.read_write : Access.read;
        _bound_device.set_binding_access(this, _target_current, access);
        _bound_device.set_binding_access(this, _current_cap, access);
    }

    // the elements a wire event can move; a push covers only the groups the master says changed
    enum Push : ubyte
    {
        heartbeat = 1,      // slave heartbeat, or our own offer to it
        charge_info = 2,
        link_ready = 4,
        serial = 8,
        vehicle = 16,       // the VIN once fully collected, or dropped when the car leaves
        all = 31,
    }

    void heard()
        => note_activity();

    void push_samples(ref TeslaTWCMaster.Charger charger, Push groups = Push.all)
    {
        SysTime timestamp = getSysTime();
        CommitScope commit = open_commit();

        foreach (ref e; _elements)
        {
            if (!(push_groups[e.kind] & groups))
                continue;
            final switch (e.kind)
            {
                case SampleKind.setpoint:
                    if (e.element.record_update() == SysTime() && charger.device_max_current)
                        write_sample(e, charger.target_current, timestamp, &on_target_current_change);
                    break;
                case SampleKind.cap:
                    if (e.element.record_update() == SysTime())
                        write_sample(e, charger.specified_max_current, timestamp, &on_cap_change);
                    break;
                case SampleKind.allocated:       write_sample(e, charger.offered_current, timestamp);                               break;
                case SampleKind.accepted:        write_sample(e, charger.charge_current_target, timestamp);                         break;
                case SampleKind.state:           write_sample(e, cast(ubyte)charger.charger_state, timestamp);                      break;
                case SampleKind.twc_state:       write_sample(e, cast(ubyte)charger.state, timestamp);                              break;
                case SampleKind.max:             write_sample(e, charger.device_max_current, timestamp);                            break;
                case SampleKind.current:         write_sample(e, (charger.flags & 2) ? charger.current : ushort(0), timestamp);     break;
                case SampleKind.voltage1:        write_sample(e, (charger.flags & 2) ? charger.voltage1 : ushort(0), timestamp);    break;
                case SampleKind.voltage2:        write_sample(e, (charger.flags & 2) ? charger.voltage2 : ushort(0), timestamp);    break;
                case SampleKind.voltage3:        write_sample(e, (charger.flags & 2) ? charger.voltage3 : ushort(0), timestamp);    break;
                case SampleKind.power:           write_sample(e, (charger.flags & 2) ? charger.total_power : ushort(0), timestamp); break;
                case SampleKind.power1:          write_sample(e, (charger.flags & 2) ? charger.power1 : ushort(0), timestamp);      break;
                case SampleKind.power2:          write_sample(e, (charger.flags & 2) ? charger.power2 : ushort(0), timestamp);      break;
                case SampleKind.power3:          write_sample(e, (charger.flags & 2) ? charger.power3 : ushort(0), timestamp);      break;
                case SampleKind.import_:
                case SampleKind.lifetime_energy:
                    write_sample(e, (charger.flags & 2) ? ulong(charger.lifetime_energy) * 1000 : ulong(0), timestamp);
                    break;
                case SampleKind.serial_number:   write_sample(e, (charger.flags & 4) ? charger.serial_number[] : "", timestamp);    break;
                case SampleKind.vin:             write_sample(e, (charger.flags & 0xF0) == 0xF0 ? charger.vin[] : "", timestamp);   break;
                case SampleKind.circuit:         write_sample(e, (charger.flags & 0xF0) == 0xF0 ? charger.vin[] : "", timestamp);   break;
            }
        }
    }

protected:
    override bool materialise()
    {
        if (_built)
            return true;

        DeviceBuilder builder = g_app.devices.open(_device[]);
        Device device = builder.device;
        _bound_device = device;

        Component info = builder.component("info", "DeviceInfo");
        builder.constant(info, "type", "evse");
        builder.constant(info, "name", "Tesla Wall Charger Gen2");
        add_sample(builder, info, "serial_number", SampleKind.serial_number, text_format());

        Component status = builder.component("status", "DeviceStatus");
        builder.constant(status, "address", slave_id);
        add_sample(builder, status, "lifetime_energy", SampleKind.lifetime_energy, quantity_format(ValueType.u64, WattHour));
        add_sample(builder, status, "vin", SampleKind.vin, text_format());

        Component evse = builder.component("evse", "EVSE");
        add_sample(builder, evse, "state", SampleKind.state, enum_format!(TeslaTWCMaster.ChargerState));
        add_sample(builder, evse, "twc_state", SampleKind.twc_state, enum_format!TWCState());

        Component grid = builder.component("grid", "Port");
        builder.constant(grid, "role", "grid");
        builder.constant(grid, "flow", "consume");

        Component car = builder.component("car", "Port");
        builder.constant(car, "role", "car");
        builder.constant(car, "flow", "supply");
        add_sample(builder, car, "circuit", SampleKind.circuit, text_format());

        Component control = builder.component(grid, "control", "PowerControl");
        builder.constant(control, "kind", "continuous");
        builder.constant(control, "direction", "consume");
        builder.constant(control, "unit", "A");
        builder.constant(control, "step", CentiAmps(100));
        builder.constant(control, "min", CentiAmps(500));
        builder.constant(control, "can_disable", false);
        _target_current = add_sample(builder, control, "setpoint", SampleKind.setpoint, centiamps_format());
        _current_cap = add_sample(builder, control, "cap", SampleKind.cap, current_limit_format());
        add_sample(builder, control, "max", SampleKind.max, centiamps_format());
        add_sample(builder, control, "allocated", SampleKind.allocated, centiamps_format());
        add_sample(builder, control, "accepted", SampleKind.accepted, centiamps_format());

        Component meter = builder.component(grid, "meter", "EnergyMeter");
        builder.constant(meter, "type", "three-phase");
        add_sample(builder, meter, "voltage1", SampleKind.voltage1, quantity_format(ValueType.u16, ScaledUnit(Volt)));
        add_sample(builder, meter, "voltage2", SampleKind.voltage2, quantity_format(ValueType.u16, ScaledUnit(Volt)));
        add_sample(builder, meter, "voltage3", SampleKind.voltage3, quantity_format(ValueType.u16, ScaledUnit(Volt)));
        add_sample(builder, meter, "current", SampleKind.current, centiamps_format());
        add_sample(builder, meter, "power1", SampleKind.power1, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(builder, meter, "power2", SampleKind.power2, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(builder, meter, "power3", SampleKind.power3, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(builder, meter, "power", SampleKind.power, quantity_format(ValueType.u16, ScaledUnit(Watt)));
        add_sample(builder, meter, "import", SampleKind.import_, quantity_format(ValueType.u64, WattHour));

        _built = true;
        refresh_access(_master && _master.has_agency);
        builder.commit();
        device.notify(ComponentEvent.online);
        return true;
    }

private:

    enum SampleKind : ubyte
    {
        setpoint,
        cap,
        allocated,
        accepted,
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

    ObjectRef!TeslaTWCMaster _master;

    bool _subscribed;
    bool _elem_subscribed;
    bool _built;

    Element* _target_current;
    Element* _current_cap;
    Array!SampleElement _elements;

    // indexed by SampleKind
    __gshared immutable Push[SampleKind.circuit + 1] push_groups = [
        Push.heartbeat, Push.heartbeat, Push.heartbeat, Push.heartbeat, Push.heartbeat, Push.heartbeat, Push.link_ready,
        Push.heartbeat, Push.charge_info, Push.charge_info, Push.charge_info, Push.charge_info, Push.charge_info,
        Push.charge_info, Push.charge_info, Push.charge_info, Push.charge_info, Push.serial, Push.vehicle, Push.vehicle,
    ];

    Element* add_sample(ref DeviceBuilder b, Component parent, const(char)[] id, SampleKind kind, FormatId format, Access access = Access.read)
    {
        Element* e = bind_element(b, parent, id, format, access);
        _elements ~= SampleElement(e, format, kind);
        return e;
    }

    FormatId quantity_format(ValueType type, ScaledUnit unit)
        => register_format(DataFormat(type, SeriesKind.held, unit));

    FormatId centiamps_format()
        => quantity_format(ValueType.u16, ScaledUnit(Ampere, -2));

    FormatId current_limit_format()
    {
        DataFormat format = DataFormat(ValueType.u16, SeriesKind.held, ScaledUnit(Ampere, -2));
        Constraint constraint;
        constraint.check_fn = &check_current_limit;
        format.constraint = register_constraint(constraint);
        return register_format(format);
    }

    static const(char)[] check_current_limit(ref const Scalar value, ref const DataFormat format)
        => value.u != 0 && value.u < TeslaTWCMaster.Charger.min_current ? "TWC current limit must be zero (no cap) or at least 5A" : null;

    FormatId enum_format(E)()
        => register_format(DataFormat(ValueType.u8, SeriesKind.held, enum_info!E.make_void()));

    FormatId text_format()
    {
        DataFormat format = DataFormat(ValueType.char_, SeriesKind.held);
        format.count = 0;
        return register_format(format);
    }

    void write_sample(T)(ref SampleElement sample, T value, SysTime timestamp, Subscriber who = null)
    {
        static if (is(T : const(char)[]))
        {
            if (sample.element.format == sample.format)
                sample.element.write_sample(value, timestamp, who);
            else
                sample.element.value(value, timestamp, who);
        }
        else
        {
            const(void)[] record = (cast(const(void)*)&value)[0 .. T.sizeof];
            if (sample.element.format == sample.format)
                sample.element.write_record(record, timestamp, who);
            else
                sample.element.value(box_record(record.ptr, *format_info(sample.format)), timestamp, who);
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
        {
            set_device_online(false);
            restart();
        }
    }

    void on_target_current_change(ref const SampleUpdate update)
    {
        TeslaTWCMaster m = _master.get;
        if (!m || !m.has_agency || update.element !is _target_current || !update.value_ready)
            return;
        ushort target = (cast(CentiAmps)update.value.asQuantity()).value;
        m.set_target_current(_slave_id, target);
        version (DebugTWCBinding)
            log.trace("set target current: ", target);
    }

    void on_cap_change(ref const SampleUpdate update)
    {
        TeslaTWCMaster m = _master.get;
        if (!m || !m.has_agency || update.element !is _current_cap || !update.value_ready)
            return;
        ushort limit = (cast(CentiAmps)update.value.asQuantity()).value;
        m.set_cap(_slave_id, limit);
        version (DebugTWCBinding)
            log.trace("set max current: ", limit);
    }
}

unittest
{
    import urt.mem : free;

    static final class TestBinding : TeslaTWCBinding
    {
    nothrow @nogc:
        this(CID id) { super(id); }
        void attach_device(Device device) { _bound_device = device; }
    }
    TestBinding binding = alloc!TestBinding(CID(1));
    scope(exit) free(binding);
    const(DataFormat)* format = format_info(binding.current_limit_format());
    foreach (ushort current; [ushort(0), ushort(500), ushort(2500)])
    {
        Scalar value = Scalar.of(current);
        assert(format.constraint.check(value, *format) is null);
    }
    Scalar below_floor = Scalar.of(ushort(300));
    assert(format.constraint.check(below_floor, *format).length);

    Element[5] elements;
    foreach (i, kind; [TeslaTWCBinding.SampleKind.setpoint, TeslaTWCBinding.SampleKind.cap,
                      TeslaTWCBinding.SampleKind.max, TeslaTWCBinding.SampleKind.allocated, TeslaTWCBinding.SampleKind.accepted])
    {
        elements[i].format = kind == TeslaTWCBinding.SampleKind.cap ? binding.current_limit_format() : binding.centiamps_format();
        binding._elements ~= TeslaTWCBinding.SampleElement(&elements[i], elements[i].format, kind);
    }
    TeslaTWCMaster.Charger charger;
    charger.device_max_current = 3200;
    charger.target_current = 2800;
    charger.specified_max_current = 2000;
    charger.offered_current = 1000;
    charger.charge_current_target = 1600;
    binding.push_samples(charger);
    foreach (i, expected; [2800, 2000, 3200, 1000, 1600])
        assert((cast(CentiAmps)elements[i].record_value().asQuantity()).value == expected);
    charger.offered_current = 500;
    charger.charge_current_target = 1000;
    binding.push_samples(charger);
    foreach (i, expected; [2800, 2000, 3200, 500, 1000])
        assert((cast(CentiAmps)elements[i].record_value().asQuantity()).value == expected);

    DeviceTable table;
    DeviceBuilder access_builder = table.create("twc-access-device");
    Device device = access_builder.device;
    scope(exit) free(device);
    binding.attach_device(device);
    binding._built = true;
    binding._target_current = access_builder.element("setpoint", register_value_format!int());
    binding._current_cap = access_builder.element("cap", register_value_format!int());
    access_builder.commit();
    foreach (element; [binding._target_current, binding._current_cap])
        device.attach_binding(binding, element, Access.read);
    foreach (active; [false, true, false, true])
    {
        binding.refresh_access(active);
        assert(binding._target_current.access == (active ? Access.read_write : Access.read));
        assert(binding._current_cap.access == binding._target_current.access);
    }
}
