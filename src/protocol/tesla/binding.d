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

    ~this() {}

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

        TeslaTWCMaster.Charger* charger = m.adopt(_slave_id, this);
        if (!charger)
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

        if (charger.link_ready_at != SysTime())
            push_samples(*charger, Push.link_ready);
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
    final void refresh_access(bool writable)
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
        heartbeat = 1,
        charge_info = 2,
        link_ready = 4,
        serial = 8,
        vehicle = 16,
        offer = 32,
        accepted = 64,
        current = 128,
    }

    void heard()
        => note_activity();

    final void push_samples(ref TeslaTWCMaster.Charger charger, Push groups)
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
                    if (e.element.record_update() == SysTime())
                        write_sample(e, charger.target_current, charger.link_ready_at, &on_target_current_change);
                    break;
                case SampleKind.allocated:       write_sample(e, charger.offered_current, timestamp); break;
                case SampleKind.accepted:        write_sample(e, charger.charge_current_target, timestamp); break;
                case SampleKind.state:           write_sample(e, cast(ubyte)charger.charger_state, timestamp); break;
                case SampleKind.twc_state:       write_sample(e, cast(ubyte)charger.state, timestamp); break;
                case SampleKind.max:             write_sample(e, charger.device_max_current, charger.link_ready_at); break;
                case SampleKind.current:         write_sample(e, charger.current, timestamp); break;
                case SampleKind.voltage1:        write_sample(e, charger.voltage1, timestamp); break;
                case SampleKind.voltage2:        write_sample(e, charger.voltage2, timestamp); break;
                case SampleKind.voltage3:        write_sample(e, charger.voltage3, timestamp); break;
                case SampleKind.power:           write_sample(e, charger.total_power, timestamp); break;
                case SampleKind.power1:          write_sample(e, charger.power1, timestamp); break;
                case SampleKind.power2:          write_sample(e, charger.power2, timestamp); break;
                case SampleKind.power3:          write_sample(e, charger.power3, timestamp); break;
                case SampleKind.import_:
                case SampleKind.lifetime_energy:
                    write_sample(e, ulong(charger.lifetime_energy) * 1000, timestamp);
                    break;
                case SampleKind.serial_number:   write_sample(e, charger.serial_number[], timestamp); break;
                case SampleKind.vin:
                    if ((charger.flags & 0xF0) == 0xF0)
                        write_sample(e, charger.vin[], timestamp);
                    else if (e.element.has_value)
                        write_sample(e, "", timestamp);
                    break;
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
        Element* vin = add_sample(builder, status, "vin", SampleKind.vin, text_format());

        Component evse = builder.component("evse", "EVSE");
        add_sample(builder, evse, "state", SampleKind.state, enum_format!(TeslaTWCMaster.ChargerState));
        add_sample(builder, evse, "twc_state", SampleKind.twc_state, enum_format!TWCState());

        Component grid = builder.component("grid", "Port");
        builder.constant(grid, "role", "grid");
        builder.constant(grid, "flow", "consume");

        Component car = builder.component("car", "Port");
        builder.constant(car, "role", "car");
        builder.constant(car, "flow", "supply");
        add_circuit_alias(builder, vin);

        Component control = builder.component(grid, "control", "PowerControl");
        builder.constant(control, "kind", "continuous");
        builder.constant(control, "direction", "consume");
        builder.constant(control, "unit", "A");
        builder.constant(control, "step", CentiAmps(100));
        builder.constant(control, "min", CentiAmps(500));
        builder.constant(control, "can_disable", false);
        _target_current = add_sample(builder, control, "setpoint", SampleKind.setpoint, centiamps_format());
        _current_cap = bind_element(builder, control, "cap", current_limit_format(), Access.read);
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
        device.notify(ComponentEvent.materialised);
        return true;
    }

private:

    enum SampleKind : ubyte
    {
        setpoint,
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
        vin
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
    __gshared immutable Push[SampleKind.vin + 1] push_groups = [
        Push.link_ready, Push.offer, Push.accepted, Push.heartbeat, Push.heartbeat, Push.link_ready,
        Push.current, Push.charge_info, Push.charge_info, Push.charge_info, Push.charge_info, Push.charge_info,
        Push.charge_info, Push.charge_info, Push.charge_info, Push.charge_info, Push.serial, Push.vehicle,
    ];

    Element* add_sample(ref DeviceBuilder b, Component parent, const(char)[] id, SampleKind kind, FormatId format, Access access = Access.read)
    {
        Element* e = bind_element(b, parent, id, format, access);
        _elements ~= SampleElement(e, format, kind);
        return e;
    }

    static void add_circuit_alias(ref DeviceBuilder builder, Element* vin)
    {
        Element* circuit = builder.element("car.circuit", vin.format);
        circuit.access = Access.read;
        circuit.sampling_mode = SamplingMode.dependent;
        foreach (ref computation; builder.device.computations)
            if (computation.kind == ComputationKind.alias_ && computation.target is circuit)
                return;

        Computation computation;
        computation.kind = ComputationKind.alias_;
        computation.device = builder.device;
        computation.target = circuit;
        computation.link = g_app.create_link(circuit, null, vin, null, true);
        computation.bound = true;
        builder.device.computations ~= computation;
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
    import urt.endian;
    import urt.mem : free;

    import manager.system : node_id;

    import protocol.tesla.iface : TWCFrame;
    import router.iface : BaseInterface, MessageCallback;
    import router.iface.packet : Packet, QueuePolicy, StackPacket, packet_free;

    static class TestBinding : TeslaTWCBinding
    {
    nothrow @nogc:

        ~this() {}
        DeviceTable* fixtures;
        this(CID id, ObjectFlags flags = ObjectFlags.none) { super(id, flags); }
        void attach_device(Device device) { _bound_device = device; }
        void step() { set_state(State.starting); }
        override bool materialise()
        {
            DeviceBuilder builder = fixtures.open(_device[]);
            _bound_device = builder.device;
            _target_current = add_sample(builder, builder.device, "setpoint", SampleKind.setpoint, centiamps_format());
            _current_cap = bind_element(builder, builder.device, "cap", current_limit_format());
            add_sample(builder, builder.device, "max", SampleKind.max, centiamps_format());
            add_sample(builder, builder.device, "accepted", SampleKind.accepted, centiamps_format());
            _built = true;
            return true;
        }
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

    alias Push = TeslaTWCBinding.Push;
    alias SampleKind = TeslaTWCBinding.SampleKind;
    Element[6] elements;
    foreach (i, kind; [SampleKind.setpoint, SampleKind.max, SampleKind.allocated,
                       SampleKind.accepted, SampleKind.current, SampleKind.vin])
    {
        elements[i].format = kind == SampleKind.vin ? binding.text_format() : binding.centiamps_format();
        binding._elements ~= TeslaTWCBinding.SampleElement(&elements[i], elements[i].format, kind);
    }
    TeslaTWCMaster.Charger charger;
    binding.push_samples(charger, cast(Push)(Push.heartbeat | Push.vehicle));
    foreach (ref element; elements)
        assert(!element.has_value && element.record_update() == SysTime());

    charger.link_ready_at = from_unix_time_ns(1_000_000);
    charger.device_max_current = 3200;
    charger.target_current = 2800;
    binding.push_samples(charger, Push.link_ready);
    assert((cast(CentiAmps)elements[0].record_value().asQuantity()).value == 2800);
    assert((cast(CentiAmps)elements[1].record_value().asQuantity()).value == 3200);
    foreach (ref element; elements[2 .. $])
        assert(!element.has_value);

    binding.push_samples(charger, cast(Push)(Push.accepted | Push.current));
    assert(elements[3].has_value && (cast(CentiAmps)elements[3].record_value().asQuantity()).value == 0);
    assert(elements[4].has_value && (cast(CentiAmps)elements[4].record_value().asQuantity()).value == 0);
    charger.offered_current = 500;
    binding.push_samples(charger, Push.offer);
    assert((cast(CentiAmps)elements[2].record_value().asQuantity()).value == 500);

    charger.flags = 0xF0;
    charger.vin[] = "5YJ3E1EA7KF000001"[];
    binding.push_samples(charger, Push.vehicle);
    assert(elements[5].record_value().asString == charger.vin[]);
    charger.flags = 0;
    binding.push_samples(charger, Push.vehicle);
    assert(elements[5].has_value && elements[5].text_value.empty);

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

    static final class TestInterface : BaseInterface
    {
        enum type_name = "twc-replay-test-interface";
    nothrow @nogc:

        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none) { super(collection_type_info!TestInterface, id, flags); }
        void start() { set_state(State.running); }
        void receive(const(Packet)* packet) { fire_subscribers(packet); }
        override CompletionStatus startup() => CompletionStatus.complete;
        override int transmit(Packet* packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null)
        {
            packet_free(packet);
            return 0;
        }
    }

    static final class TestMaster : TeslaTWCMaster
    {
    nothrow @nogc:

        ~this() {}
        this(CID id) { super(id); }
        CompletionStatus listen() => super.startup();
        void start() { set_state(State.running); }
        void stop() { set_state_deferred(State.stopping); }
        override CompletionStatus shutdown() => CompletionStatus.complete;
    }
    TestMaster master = alloc!TestMaster(Collection!TeslaTWCMaster().allocate_id("twc-binding-lifecycle"));
    Collection!TeslaTWCMaster().add(master);
    TestInterface iface = Collection!TestInterface().alloc("twc-binding-interface");
    Collection!TestInterface().add(iface);
    iface.start();
    master.iface = iface;
    assert(master.listen() == CompletionStatus.continue_);
    TestBinding live = alloc!TestBinding(Collection!TeslaTWCBinding().allocate_id("twc-binding-live"), ObjectFlags.dynamic);
    Collection!TeslaTWCBinding().add(live);
    Device lifecycle_device = table.create("twc-binding-device").device;
    scope(exit) free(lifecycle_device);
    live.fixtures = &table;
    live.master = master;
    live.slave_id = 123;
    live.device = "twc-binding-device".make_string();
    master.start();

    ubyte[15] message;
    message[0 .. 2] = ushort(0xFDE2).nativeToBigEndian;
    message[2 .. 4] = ushort(123).nativeToBigEndian;
    StackPacket packet;
    MonoTime announced_at = getTime() - 1.seconds;
    ref TWCFrame announced = packet.init!TWCFrame(message[], announced_at);
    announced.src = 123;
    announced.dst = TWCFrame.broadcast;
    iface.receive(&packet.packet);
    TeslaTWCMaster.Charger* discovered = master.find_charger(123);
    assert(!live.running && discovered && !discovered.binding);

    live.step();
    assert(live.running && live._subscribed && live._elem_subscribed);
    Element* maximum = lifecycle_device.find_element("max");
    Element* accepted = lifecycle_device.find_element("accepted");
    assert(maximum && maximum.has_value && (cast(CentiAmps)maximum.record_value().asQuantity()).value == 0);
    assert(maximum.record_update() == cast(SysTime)announced_at);
    assert(live._target_current.has_value && live._target_current.record_update() == maximum.record_update());
    assert((cast(CentiAmps)live._target_current.record_value().asQuantity()).value == 0);
    assert(accepted && !accepted.has_value);

    ushort master_address = cast(ushort)node_id();
    if (master_address == 0 || master_address == TWCFrame.broadcast)
        master_address = 0x7777;
    message[0 .. 2] = ushort(0xFDE0).nativeToBigEndian;
    message[4 .. 6] = master_address.nativeToBigEndian;
    message[6] = TWCState.Charging;
    message[7 .. 9] = ushort(1200).nativeToBigEndian;
    ref TWCFrame heartbeat = packet.init!TWCFrame(message[]);
    heartbeat.src = 123;
    heartbeat.dst = master_address;
    iface.receive(&packet.packet);
    assert(accepted.has_value && (cast(CentiAmps)accepted.record_value().asQuantity()).value == 1200);
    assert(maximum.record_update() == cast(SysTime)announced_at);

    assert(!live._current_cap.has_value);
    live._current_cap.value(CentiAmps(0));
    assert(live._current_cap.has_value);
    lifecycle_device.set_online(cast(void*)live, true);
    master.stop();
    iface.destroy();
    Collection!BaseInterface().update_all();
    assert(!live.running && !live._subscribed && !live._elem_subscribed);
    assert(lifecycle_device.online_status == OnlineStatus.offline);
    assert(Collection!TeslaTWCBinding().get("twc-binding-live") is live);
    foreach (provider; lifecycle_device.bindings)
        assert(provider !is live);
    master.start();
    live.step();
    assert(live.running && live._subscribed && live._elem_subscribed);
    master.destroy();
    assert(Collection!TeslaTWCBinding().get("twc-binding-live") is null);
    assert(!live._subscribed && !live._elem_subscribed);
    assert(table.find("twc-binding-device", 0) is lifecycle_device);
    foreach (provider; lifecycle_device.bindings)
        assert(provider !is live);
}
