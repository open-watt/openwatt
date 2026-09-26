module router.iface.sfp;

import urt.array;
import urt.atomic;
import urt.attribute : critical, isr_safe;
import urt.driver.event;
import urt.driver.gpio;
import urt.log;
import urt.meta : AliasSeq;
import urt.si.quantity;
import urt.si.unit;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.binding : ProtocolBinding;
import manager.collection;
import manager.component : Component, ComponentEvent;
import manager.device : Device, DeviceBuilder;
import manager.element : Access, Element;
import manager.series : register_value_format;

import router.iface;
import router.iface.ethernet;
import router.iface.i2c;
import router.iface.packet;
import router.iface.sff8472;

nothrow @nogc:

enum SFPChange : uint
{
    cage        = 1 << 0,
    identity    = 1 << 1,
    diagnostics = 1 << 2,
    all         = cage | identity | diagnostics,
}

alias SFPChangeHandler = void delegate(SFPInterface sfp, uint changes) nothrow @nogc;

// The cage runs on its I2C and GPIO wiring alone; a platform that drives the port's MAC supplies the data path hooks.
class SFPInterface : EthernetInterface
{
    alias Properties = AliasSeq!(Prop!("i2c", i2c),
                                 Prop!("mod-def0-gpio", mod_def0_gpio),
                                 Prop!("los-gpio", los_gpio),
                                 Prop!("tx-disable-gpio", tx_disable_gpio),
                                 Elem!("present", bool, ReadOnly),
                                 Elem!("los", bool, ReadOnly),
                                 Elem!("tx-enabled", bool, ReadOnly));
nothrow @nogc:

    enum type_name = "sfp";
    enum path = "/interface/sfp";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        this(collection_type_info!SFPInterface, id, flags);
    }

    inout(I2CInterface) i2c() inout pure
        => _i2c;

    void i2c(I2CInterface value)
    {
        if (_i2c.get is value)
            return;
        cage_down();
        _i2c = value;
        mark_set!(typeof(this), "i2c")();
        restart();
    }

    byte mod_def0_gpio() const pure
        => _mod_def0_gpio;
    void mod_def0_gpio(byte value) { set_pin!"mod-def0-gpio"(_mod_def0_gpio, value); }

    byte los_gpio() const pure
        => _los_gpio;
    void los_gpio(byte value) { set_pin!"los-gpio"(_los_gpio, value); }

    byte tx_disable_gpio() const pure
        => _tx_disable_gpio;
    void tx_disable_gpio(byte value) { set_pin!"tx-disable-gpio"(_tx_disable_gpio, value); }

    bool present() const
        => prop_read!(SFPInterface, "present");

    bool los() const
        => prop_read!(SFPInterface, "los");

    bool tx_enabled() const
        => prop_read!(SFPInterface, "tx-enabled");

    const(ModuleId)* module_id() const return
        => _id_valid ? &_id : null;

    const(Diagnostics)* diagnostics() const return
        => _diag_valid ? &_diag : null;

    void subscribe_changes(SFPChangeHandler handler)
    {
        _change_handlers ~= handler;
    }

    void unsubscribe_changes(SFPChangeHandler handler) pure
    {
        _change_handlers.removeFirstSwapLast(handler);
    }

    override bool validate() const
    {
        immutable byte[3] pins = [_mod_def0_gpio, _los_gpio, _tx_disable_gpio];
        foreach (pin; pins)
        {
            if (pin >= cast(int)gpio_count())
                return false;
        }
        return data_path_valid();
    }

protected:

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags)
    {
        super(type_info, id, flags);
    }

    override CompletionStatus startup()
    {
        if (!_cage_up)
        {
            I2CInterface bus = _i2c.get;
            if (bus && !bus.running)
                return CompletionStatus.continue_;
            if (!cage_up())
                return CompletionStatus.error;
        }
        return data_path_up();
    }

    override CompletionStatus shutdown()
    {
        cage_down();
        if (!data_path_down())
            return CompletionStatus.continue_;
        return super.shutdown();
    }

    // The data path: none here, so the port carries no traffic and the laser stays off.
    bool data_path_valid() const
        => true;

    CompletionStatus data_path_up()
        => CompletionStatus.complete;

    bool data_path_down()
        => true;

    override int wire_send(const(ubyte)[] frame)
        => -1;

    // The data path's say over the laser; it lights only while a module is also present.
    final void set_laser(bool on)
    {
        _laser_on = on;
        if (_cage_up && _tx_disable_gpio >= 0)
            gpio_output_set(_tx_disable_gpio, !on);
        if (update_tx_enabled())
            notify(SFPChange.cage);
    }

private:

    enum Read : ubyte { none, id, diagnostics }

    enum Duration settle_time = 300.msecs;   // SFF-8472 t_init: ready this long after insertion
    enum Duration diag_interval = 5.seconds;

    ObjectRef!I2CInterface _i2c;
    Array!SFPChangeHandler _change_handlers;
    Link _present_link;
    Link _los_link;
    ModuleId _id;
    Diagnostics _diag;
    ushort _sequence;
    byte _mod_def0_gpio = -1;
    byte _los_gpio = -1;
    byte _tx_disable_gpio = -1;
    Read _pending;
    bool _cage_up;
    bool _laser_on;
    bool _id_valid;
    bool _diag_valid;
    shared uint _signalled;

    void set_pin(string prop)(ref byte field, byte value)
    {
        if (field == value)
            return;
        cage_down();
        field = value;
        mark_set!(typeof(this), prop)();
        restart();
    }

    bool cage_up()
    {
        if (_tx_disable_gpio >= 0)
            gpio_output_init(_tx_disable_gpio, !_laser_on);
        if (!watch(_present_link, _mod_def0_gpio) || !watch(_los_link, _los_gpio))
        {
            link_close(_present_link);
            return false;
        }
        if (I2CInterface bus = _i2c.get)
        {
            bus.subscribe(&packet_handler, PacketFilter(type: PacketType.i2c, direction: PacketDirection.incoming));
            bus.subscribe(&bus_state_change);
        }
        _cage_up = true;
        cage_changed();
        return true;
    }

    bool watch(ref Link link, byte pin)
    {
        if (pin < 0)
            return true;
        gpio_input_init(pin);
        if (link_acquire(link, gpio_event(GpioLine(0, pin), GpioInterruptTrigger.change), isr_task!cage_edge(cast(void*)this)))
            return true;
        log.error("cannot watch GPIO", pin);
        return false;
    }

    void cage_down()
    {
        if (!_cage_up)
            return;
        link_close(_present_link);
        link_close(_los_link);
        _i2c.unsubscribe(&bus_state_change);
        _i2c.unsubscribe(&packet_handler);
        _pending = Read.none;
        _cage_up = false;
        forget_module();
        _laser_on = false;
        prop_write!(SFPInterface, "present")(false);
        prop_write!(SFPInterface, "los")(false);
        prop_write!(SFPInterface, "tx-enabled")(false);
        notify(SFPChange.all);
    }

    void bus_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void cage_changed()
    {
        bool los = _los_gpio >= 0 && gpio_input_read(_los_gpio);
        bool present = _mod_def0_gpio < 0 || !gpio_input_read(_mod_def0_gpio);
        uint changes;
        if (los != this.los)
        {
            prop_write!(SFPInterface, "los")(los);
            changes |= SFPChange.cage;
        }
        if (present != this.present)
        {
            prop_write!(SFPInterface, "present")(present);
            changes |= SFPChange.cage;
            forget_module();
            changes |= SFPChange.identity | SFPChange.diagnostics;
            log.info(present ? "module inserted" : "module removed");
            if (present)
                g_app.schedule(getTime() + settle_time, &read_id_timer);
        }
        if (update_tx_enabled())
            changes |= SFPChange.cage;
        notify(changes);
    }

    // A cage with no TX-disable pin has the laser wired on.
    bool update_tx_enabled()
    {
        bool on = present && (_tx_disable_gpio < 0 || _laser_on);
        if (on == tx_enabled)
            return false;
        prop_write!(SFPInterface, "tx-enabled")(on);
        return true;
    }

    void forget_module()
    {
        g_app.cancel(&read_id_timer);
        g_app.cancel(&diagnostics_timer);
        _id_valid = false;
        _diag_valid = false;
    }

    void read_id_timer(MonoTime)
    {
        ubyte[1] offset = [0];
        send(Read.id, sfp_id_address, offset[], id_length);
    }

    void diagnostics_timer(MonoTime)
    {
        ubyte[1] offset = [diag_offset];
        send(Read.diagnostics, sfp_diag_address, offset[], diag_length);
    }

    void send(Read what, ubyte address, const(ubyte)[] data, size_t read_length)
    {
        I2CInterface bus = _i2c.get;
        if (!bus || !bus.running || _pending != Read.none)
            return;
        Packet request;
        ref frame = request.init!I2CFrame(data);
        frame.sequence_number = ++_sequence;
        frame.address = address;
        frame.read_length = cast(ushort)read_length;
        frame.type = I2CFrameType.request;
        frame.flags = I2CFrameFlags.none;
        _pending = what;
        if (bus.forward(request, &message_complete) <= 0)
            request_failed();
    }

    void message_complete(int, MessageState state)
    {
        if (state != MessageState.complete && _pending != Read.none)
            request_failed();
    }

    void request_failed()
    {
        immutable what = _pending;
        _pending = Read.none;
        if (!_cage_up || !present)
            return;
        log.warning(what == Read.id ? "module ID read failed; retrying" : "module diagnostics read failed");
        if (what == Read.id)
            g_app.schedule(getTime() + 1.seconds, &read_id_timer);
        else
            g_app.schedule(getTime() + diag_interval, &diagnostics_timer);
    }

    void packet_handler(ref const Packet packet, BaseInterface, PacketDirection, void*)
    {
        ref frame = packet.hdr!I2CFrame;
        if (_pending == Read.none || frame.type != I2CFrameType.response || frame.sequence_number != _sequence)
            return;
        immutable what = _pending;
        _pending = Read.none;
        auto data = cast(const(ubyte)[])packet.data;

        if (what == Read.id)
        {
            if (!decode_id(data, _id))
            {
                log.warning("module ID checksum failed; retrying");
                g_app.schedule(getTime() + 1.seconds, &read_id_timer);
                return;
            }
            _id_valid = true;
            log.info("module ", _id.vendor_name, ' ', _id.part_number, ' ', _id.standard, ' ', _id.wavelength_nm, "nm");
            notify(SFPChange.identity);
            if (_id.diagnostics && !_id.external_calibration)
                diagnostics_timer(getTime());
            return;
        }

        decode_diagnostics(data, _diag);
        _diag_valid = true;
        notify(SFPChange.diagnostics);
        g_app.schedule(getTime() + diag_interval, &diagnostics_timer);
    }

    void notify(uint changes)
    {
        if (!changes)
            return;
        foreach (handler; _change_handlers[])
            handler(this, changes);
    }

    // Cage edges arrive in interrupt context; the sweep carries them to the main loop.
    @isr_safe @critical static bool cage_edge(void* context, LinkContext)
    {
        atomicStore!(MemoryOrder.release)((cast(SFPInterface)context)._signalled, 1u);
        if (g_app is null || !cas(&_sweep_pending, 0u, 1u))
            return false;
        bool queued;
        immutable woke = g_app.post_event_from_isr(&_sweep.event, EventPriority.control, queued);
        if (!queued)
            atomicStore!(MemoryOrder.release)(_sweep_pending, 0u);
        return woke;
    }

    // A posted event cannot be recalled, so it finds its cages by walking the collection.
    static struct CageSweep
    {
        void event(MonoTime) nothrow @nogc
        {
            atomicStore!(MemoryOrder.release)(_sweep_pending, 0u);
            foreach (SFPInterface sfp; Collection!SFPInterface().values)
            {
                if (sfp._cage_up && cas(&sfp._signalled, 1u, 0u))
                    sfp.cage_changed();
            }
        }
    }
    __gshared CageSweep _sweep;
    static shared uint _sweep_pending;
}


alias DegreesC = Quantity!(float, Celsius);
alias Volts = Quantity!(float, ScaledUnit(Volt));
alias MilliAmps = Quantity!(float, ScaledUnit(Ampere, -3));
alias MilliWatts = Quantity!(float, ScaledUnit(Watt, -3));
alias Nanometres = Quantity!(uint, ScaledUnit(Metre, -9));

final class SFPBinding : ProtocolBinding
{
    alias Properties = AliasSeq!(Prop!("interface", iface));
nothrow @nogc:

    enum type_name = "sfp-binding";
    enum path = "/binding/sfp";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SFPBinding, id, flags);
    }

    inout(SFPInterface) iface() inout pure
        => _iface;

    void iface(SFPInterface value)
    {
        if (_iface.get is value)
            return;
        unsubscribe();
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    override bool validate() const pure
        => _iface.get !is null && !_device.empty;

protected:

    override CompletionStatus startup()
    {
        SFPInterface sfp = _iface.get;
        if (!sfp || !sfp.running)
            return CompletionStatus.continue_;
        if (!materialise())
            return CompletionStatus.error;
        sfp.subscribe_changes(&changed);
        sfp.subscribe(&interface_state_change);
        _subscribed = true;
        changed(sfp, SFPChange.all);
        _device_instance.notify(ComponentEvent.materialised);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe();
        if (_device_instance)
            set_device_online(false);
        _built = false;
        return super.shutdown();
    }

    override bool materialise()
    {
        if (_built)
            return true;
        DeviceBuilder builder = g_app.devices.open(_device[]);
        _device_instance = builder.device;
        _bound_device = _device_instance;

        Component info = builder.component("info", "DeviceInfo");
        builder.constant(info, "type", "sfp-module");
        builder.constant(info, "name", "SFP module");
        _manufacturer = add_element!String(builder, info, "manufacturer_name");
        _model = add_element!String(builder, info, "model_name");
        _serial = add_element!String(builder, info, "serial_number");
        _revision = add_element!String(builder, info, "hardware_version");

        builder.component("status", "DeviceStatus");

        Component optics = builder.component("transceiver", "OpticalTransceiver");
        _present = add_element!bool(builder, optics, "present");
        _los = add_element!bool(builder, optics, "los");
        _tx_enabled = add_element!bool(builder, optics, "tx_enabled");
        _standard = add_element!String(builder, optics, "standard");
        _wavelength = add_element!Nanometres(builder, optics, "wavelength");
        _temperature = add_element!DegreesC(builder, optics, "temperature");
        _supply = add_element!Volts(builder, optics, "supply_voltage");
        _tx_bias = add_element!MilliAmps(builder, optics, "tx_bias");
        _tx_power = add_element!MilliWatts(builder, optics, "tx_power");
        _rx_power = add_element!MilliWatts(builder, optics, "rx_power");

        g_app.request_rebind();
        builder.commit();
        _built = true;
        return true;
    }

private:

    ObjectRef!SFPInterface _iface;
    Device _device_instance;
    Element* _manufacturer;
    Element* _model;
    Element* _serial;
    Element* _revision;
    Element* _present;
    Element* _los;
    Element* _tx_enabled;
    Element* _standard;
    Element* _wavelength;
    Element* _temperature;
    Element* _supply;
    Element* _tx_bias;
    Element* _tx_power;
    Element* _rx_power;
    bool _built;
    bool _subscribed;

    Element* add_element(T)(ref DeviceBuilder b, Component parent, const(char)[] id)
        => bind_element(b, parent, id, register_value_format!T(), Access.read);

    void unsubscribe()
    {
        if (!_subscribed)
            return;
        _iface.unsubscribe(&interface_state_change);
        if (SFPInterface sfp = _iface.get)
            sfp.unsubscribe_changes(&changed);
        _subscribed = false;
    }

    void interface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void changed(SFPInterface sfp, uint changes)
    {
        immutable timestamp = getSysTime();
        if (changes & SFPChange.cage)
        {
            _present.value(sfp.present, timestamp);
            _los.value(sfp.los, timestamp);
            _tx_enabled.value(sfp.tx_enabled, timestamp);
            set_device_online(sfp.present);
        }
        if (changes & SFPChange.identity)
        {
            const(ModuleId)* id = sfp.module_id;
            _manufacturer.value(id ? id.vendor_name.make_string : String(), timestamp);
            _model.value(id ? id.part_number.make_string : String(), timestamp);
            _serial.value(id ? id.serial_number.make_string : String(), timestamp);
            _revision.value(id ? id.revision_code.make_string : String(), timestamp);
            _standard.value(id ? id.standard.make_string : String(), timestamp);
            _wavelength.value(Nanometres(id ? id.wavelength_nm : 0), timestamp);
        }
        if (changes & SFPChange.diagnostics)
        {
            if (const(Diagnostics)* d = sfp.diagnostics)
            {
                _temperature.value(DegreesC(d.temperature_c), timestamp);
                _supply.value(Volts(d.supply_v), timestamp);
                _tx_bias.value(MilliAmps(d.tx_bias_ma), timestamp);
                _tx_power.value(MilliWatts(d.tx_power_mw), timestamp);
                _rx_power.value(MilliWatts(d.rx_power_mw), timestamp);
            }
        }
    }
}
