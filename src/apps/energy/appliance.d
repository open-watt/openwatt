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

nothrow @nogc:


struct PortCircuitBinding
{
    String port;
    String circuit;
}

// Flat user-facing entity. Capabilities are inferred at use-time by inspecting
// the device tree; electrical topology is supplied by Port component paths.
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

    // Rare explicit override. Normally inferred from device.info.type.
    // Named `kind` (not `type`) to avoid shadowing BaseObject.type (which holds
    // the class type name like "appliance"). User-facing label is the same idea.
    const(char)[] kind() const pure
    {
        if (_kind.length != 0)
            return _kind[];
        if (_device)
            if (auto e = _device.find_element("info.type"))
                if (e.value.isString)
                    return e.value.asString;
        return null;
    }
    void kind(const(char)[] value)
    {
        if (_kind[] == value)
            return;
        _kind = value.makeString(g_app.allocator);
        mark_set!(typeof(this), "kind")();
    }

    // Optional metadata. When a vehicle is modelled without a device profile,
    // bind its electrical circuit explicitly, usually `connection=<vin>`.
    const(char)[] vin() const pure { return _vin[]; }
    void vin(const(char)[] value)
    {
        if (_vin[] == value)
            return;
        _vin = value.makeString(g_app.allocator);
        mark_set!(typeof(this), "vin")();
    }

    // usable battery capacity in kWh; fallback for SOC estimation when the
    // vehicle can't report its own and no empirical estimate exists yet
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

    // primary device or sub-component. Usually carries the control surface.
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
        Component c = resolve_component_path(value);
        if (c is null)
            return tconcat("device not found: ", value);
        _device_path = value.makeString(g_app.allocator);
        _device = c;
        mark_set!(typeof(this), [ "device", "kind" ])();
        restart();
        return null;
    }

    // explicit consumption meter (when not on device itself, or when measuring
    // a bus/link-level loop rather than the device's internal meter).
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
        Component c = resolve_component_path(value);
        if (c is null)
            return tconcat("meter not found: ", value);
        _meter_path = value.makeString(g_app.allocator);
        _meter = c;
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

    // explicit state component (SOC, temperature, on/off, etc).
    // Used when state lives on a different device than the control surface
    // (e.g. car BLE provides SOC, TWC provides linear-A control).
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
        Component c = resolve_component_path(value);
        if (c is null)
            return tconcat("state not found: ", value);
        _state_path = value.makeString(g_app.allocator);
        _state = c;
        mark_set!(typeof(this), "state")();
        restart();
        return null;
    }

    Component device_ref() pure { return _device; }
    Component meter_ref() pure { return _meter; }
    Component state_ref() pure { return _state; }

    // Runtime state, populated per tick by TopologyGraph.build().
    MeterData meter_data;

protected:
    override StringResult set_unknown_property(scope const(char)[] property, ref const Variant value)
    {
        if (!value.isString)
            return StringResult(tconcat("Port binding '", property, "' must be a circuit string"));
        set_port_circuit(property, value.asString);
        return StringResult.success;
    }

    override bool validate() const
    {
        // Degenerate appliances (just-a-name placeholders, e.g. cabin_hot_water
        // with no device and no meter) are allowed: the user uses them as
        // anchors for intent before infrastructure exists.
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
            binding.circuit = circuit.makeString(g_app.allocator);
            restart();
            return;
        }

        PortCircuitBinding binding;
        binding.port = port.makeString(g_app.allocator);
        binding.circuit = circuit.makeString(g_app.allocator);
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
