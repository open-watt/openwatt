module apps.energy.appliance;

import urt.array;
import urt.lifetime;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.result;
import urt.string;
import urt.variant;

import apps.energy : EnergyAppModule;
import apps.energy.meter;
import apps.energy.model;
import apps.energy.reference;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.device : DeviceTable;

nothrow @nogc:


struct PortCircuitBinding
{
    String port;
    String circuit;
}

class Appliance : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("kind", kind),
                                 Prop!("vin", vin),
                                 Prop!("capacity", capacity),
                                 Prop!("root", root),
                                 Prop!("device", device),
                                 Prop!("meter", meter),
                                 Prop!("meter-sign", meter_sign),
                                 Prop!("state", state));
nothrow @nogc:

    enum type_name = "appliance";
    enum path = "/apps/energy/appliance";
    enum collection_id = CollectionType.appliance;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Appliance, id, flags);
    }

    const(char)[] kind() const pure
    {
        if (_kind.length != 0)
            return _kind[];
        if (_device)
            if (auto e = _device.find_element("info.type"))
                return e.text_value;
        return null;
    }
    void kind(const(char)[] value)
    {
        if (_kind[] == value)
            return;
        _kind = value.make_string();
        mark_set!(typeof(this), "kind")();
        restart();
    }

    const(char)[] vin() const pure { return _vin[]; }
    void vin(const(char)[] value)
    {
        if (_vin[] == value)
            return;
        _vin = value.make_string();
        mark_set!(typeof(this), "vin")();
        restart();
    }

    float capacity() const pure { return _capacity; }
    void capacity(float value)
    {
        _capacity = value;
        mark_set!(typeof(this), "capacity")();
    }

    bool root() const pure { return _root; }
    void root(bool value)
    {
        if (_root == value)
            return;
        _root = value;
        mark_set!(typeof(this), "root")();
        restart();
    }

    ref const(Array!PortCircuitBinding) port_bindings() const pure
    {
        return _port_bindings;
    }

    const(char)[] port_circuit(const(char)[] port) const pure
    {
        foreach (ref binding; _port_bindings[])
            if (binding.port[] == port)
                return binding.circuit[];
        return null;
    }

    const(char)[] device() const pure { return _device_path[]; }
    const(char)[] device(const(char)[] value)
    {
        if (value.length == 0)
        {
            _device_path = String();
            _device = null;
            mark_set!(typeof(this), [ "device", "kind" ])();
            restart();
            return null;
        }
        _device_path = value.make_string();
        _device = resolve_component_path(value);
        mark_set!(typeof(this), [ "device", "kind" ])();
        restart();
        return null;
    }

    const(char)[] meter() const pure { return _meter_path[]; }
    const(char)[] meter(const(char)[] value)
    {
        if (value.length == 0)
        {
            _meter_path = String();
            _meter = null;
            mark_set!(typeof(this), "meter")();
            restart();
            return null;
        }
        _meter_path = value.make_string();
        _meter = resolve_component_path(value);
        mark_set!(typeof(this), "meter")();
        restart();
        return null;
    }

    MeterSign meter_sign() const pure { return _meter_sign; }
    void meter_sign(MeterSign value)
    {
        if (_meter_sign_set && _meter_sign == value)
            return;
        _meter_sign = value;
        _meter_sign_set = true;
        mark_set!(typeof(this), "meter-sign")();
        restart();
    }

    bool meter_sign_set() const pure { return _meter_sign_set; }

    const(char)[] state() const pure { return _state_path[]; }
    const(char)[] state(const(char)[] value)
    {
        if (value.length == 0)
        {
            _state_path = String();
            _state = null;
            mark_set!(typeof(this), "state")();
            restart();
            return null;
        }
        _state_path = value.make_string();
        _state = resolve_component_path(value);
        mark_set!(typeof(this), "state")();
        restart();
        return null;
    }

    Component device_ref() pure { return _device; }
    Component meter_ref() pure { return _meter; }
    Component state_ref() pure { return _state; }

    bool resolve_refs(ref DeviceTable devices)
    {
        bool bound = false;
        if (_device is null && _device_path.length && (_device = resolve_component_path(_device_path[], devices)) !is null)
        {
            _mark_dirty(prop_mask!(typeof(this), [ "kind" ]));
            bound = true;
        }
        if (_meter is null && _meter_path.length && (_meter = resolve_component_path(_meter_path[], devices)) !is null)
            bound = true;
        if (_state is null && _state_path.length && (_state = resolve_component_path(_state_path[], devices)) !is null)
            bound = true;
        return bound;
    }

    MeterData meter_data;

protected:
    // TODO: validate port names against an authoritative namespace (see TODO.md).
    override StringResult set_unknown_property(scope const(char)[] property, ref const Variant value)
    {
        if (!value.isString)
            return StringResult(tconcat("Port binding '", property, "' must be a circuit string"));
        set_port_circuit(property, value.asString);
        return StringResult.success;
    }

    override bool validate() const
    {
        return true;
    }

    override CompletionStatus startup()
    {
        get_module!EnergyAppModule.request_topology_rebuild();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        get_module!EnergyAppModule.request_topology_rebuild();
        return CompletionStatus.complete;
    }

    override void update() {}

private:
    void set_port_circuit(const(char)[] port, const(char)[] circuit)
    {
        foreach (ref binding; _port_bindings[])
        {
            if (binding.port[] != port)
                continue;
            if (binding.circuit[] == circuit)
                return;
            binding.circuit = circuit.make_string();
            restart();
            return;
        }

        PortCircuitBinding binding;
        binding.port = port.make_string();
        binding.circuit = circuit.make_string();
        _port_bindings ~= binding.move;
        restart();
    }

    String _kind;
    String _vin;
    float _capacity = float.nan;
    bool _root;
    Array!PortCircuitBinding _port_bindings;
    String _device_path;
    Component _device;
    String _meter_path;
    Component _meter;
    MeterSign _meter_sign;
    bool _meter_sign_set;
    String _state_path;
    Component _state;

}

unittest
{
    import urt.mem;
    import manager.device : Device;

    DeviceTable devices;
    Appliance appliance = alloc!Appliance(CID(1));
    scope(exit) free(appliance);
    appliance._device_path = StringLit!"late.battery";
    appliance._meter_path = StringLit!"late.battery.meter";
    appliance._state_path = StringLit!"late.battery.state";
    assert(!appliance.resolve_refs(devices));

    Device device = alloc!Device(StringLit!"late");
    scope(exit) free(device);
    devices.insert(device);
    assert(!appliance.resolve_refs(devices));

    Component battery = alloc!Component(StringLit!"battery");
    scope(exit) free(battery);
    device.add_component(battery);
    assert(appliance.resolve_refs(devices));
    assert(appliance.device_ref is battery);
    assert(appliance.meter_ref is null && appliance.state_ref is null);
    assert(!appliance.resolve_refs(devices));

    Component meter = alloc!Component(StringLit!"meter");
    scope(exit) free(meter);
    Component state = alloc!Component(StringLit!"state");
    scope(exit) free(state);
    battery.add_component(meter);
    battery.add_component(state);
    assert(appliance.resolve_refs(devices));
    assert(appliance.device_ref is battery);
    assert(appliance.meter_ref is meter && appliance.state_ref is state);
    assert(!appliance.resolve_refs(devices));
    assert(appliance.device == "late.battery");
    assert(appliance.meter == "late.battery.meter");
    assert(appliance.state == "late.battery.state");
}
