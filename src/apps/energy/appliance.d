module apps.energy.appliance;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.string;

import apps.energy : EnergyAppModule;
import apps.energy.circuit;
import apps.energy.meter;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager : get_module;

nothrow @nogc:


// Flat user-facing entity. Same struct shape for every appliance — different
// "types" use different subsets of the bindings.
//
// type is a freeform tag (UX only — never branched on by the system).
// Capabilities are inferred at use-time by inspecting which bindings resolve
// to components/elements with the relevant shape.
class Appliance : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("kind", kind),
                                 Prop!("vin", vin),
                                 Prop!("circuit", circuit),
                                 Prop!("meter_phase", meter_phase),
                                 Prop!("device", device),
                                 Prop!("meter", meter),
                                 Prop!("state", state));
nothrow @nogc:

    enum type_name = "appliance";
    enum path = "/apps/energy/appliance";
    enum collection_id = CollectionType.appliance;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Appliance, id, flags);
    }

    // freeform tag — for /print grouping and user's mental anchor.
    // System NEVER dispatches on this. Capability is inferred from bindings.
    // Named `kind` (not `type`) to avoid shadowing BaseObject.type (which holds
    // the class type name like "appliance"). User-facing label is the same idea.
    const(char)[] kind() const pure { return _kind[]; }
    void kind(const(char)[] value)
    {
        if (_kind[] == value)
            return;
        _kind = value.makeString(g_app.allocator);
    }

    // optional. Presence enables VIN-based pairing (e.g. car appliance to charger).
    const(char)[] vin() const pure { return _vin[]; }
    void vin(const(char)[] value)
    {
        if (_vin[] == value)
            return;
        _vin = value.makeString(g_app.allocator);
    }

    // circuit assignment — references a circuit by name in the energy module.
    const(char)[] circuit() const pure { return _circuit_id[]; }
    const(char)[] circuit(const(char)[] value)
    {
        if (value.length == 0)
        {
            detach_from_circuit();
            _circuit = null;
            _circuit_id = String();
            return null;
        }
        auto mod = get_module!EnergyAppModule;
        if (mod is null || mod.manager is null)
            return "energy module not initialised";
        Circuit* c = mod.manager.find_circuit(value);
        if (c is null)
            return tconcat("circuit not found: ", value);
        if (_circuit is c)
            return null;
        detach_from_circuit();
        _circuit_id = value.makeString(g_app.allocator);
        _circuit = c;
        restart();
        return null;
    }

    ubyte meter_phase() const pure { return _meter_phase; }
    void meter_phase(ubyte value)
    {
        if (_meter_phase == value)
            return;
        _meter_phase = value;
    }

    // primary device or sub-component. Usually carries the control surface.
    const(char)[] device() const pure { return _device_path[]; }
    const(char)[] device(const(char)[] value)
    {
        if (value.length == 0)
        {
            _device_path = String();
            _device = null;
            restart();
            return null;
        }
        Component c = resolve_component_path(value);
        if (c is null)
            return tconcat("device not found: ", value);
        _device_path = value.makeString(g_app.allocator);
        _device = c;
        restart();
        return null;
    }

    // explicit consumption meter (when not on device itself, or when measuring
    // a circuit-level loop rather than the device's internal meter).
    const(char)[] meter() const pure { return _meter_path[]; }
    const(char)[] meter(const(char)[] value)
    {
        if (value.length == 0)
        {
            _meter_path = String();
            _meter = null;
            restart();
            return null;
        }
        Component c = resolve_component_path(value);
        if (c is null)
            return tconcat("meter not found: ", value);
        _meter_path = value.makeString(g_app.allocator);
        _meter = c;
        restart();
        return null;
    }

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
            restart();
            return null;
        }
        Component c = resolve_component_path(value);
        if (c is null)
            return tconcat("state not found: ", value);
        _state_path = value.makeString(g_app.allocator);
        _state = c;
        restart();
        return null;
    }

    // resolved-reference accessors (for use by allocator/planner)
    Component device_ref() pure { return _device; }
    Component meter_ref() pure { return _meter; }
    Component state_ref() pure { return _state; }
    Circuit* circuit_ref() pure { return _circuit; }

    // runtime state, populated per-tick by circuit.update()
    MeterData meter_data;

    // runtime pairing. Set by update_vin_pairings() when this appliance's VIN
    // matches a VIN reported by another appliance's primary device.
    // Read by ControlRegistry to source partner elements during synthesis.
    Appliance paired_with;

protected:
    override bool validate() const
    {
        // Degenerate appliances (just-a-name placeholders, e.g. cabin_hot_water
        // with no device and no meter) are allowed: the user uses them as
        // anchors for intent before infrastructure exists.
        return true;
    }

    override CompletionStatus startup()
    {
        attach_to_circuit();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        detach_from_circuit();
        break_pairing();
        return CompletionStatus.complete;
    }

    override void update() {}

private:
    String _kind;
    String _vin;
    String _circuit_id;
    Circuit* _circuit;
    ubyte _meter_phase;

    String _device_path;
    Component _device;
    String _meter_path;
    Component _meter;
    String _state_path;
    Component _state;

    void attach_to_circuit()
    {
        if (_circuit is null)
            return;
        foreach (a; _circuit.appliances)
            if (a is this)
                return;
        _circuit.appliances ~= this;
    }

    void detach_from_circuit()
    {
        if (_circuit is null)
            return;
        _circuit.appliances.removeFirstSwapLast(this);
    }

    void break_pairing()
    {
        if (paired_with is null)
            return;
        if (paired_with.paired_with is this)
            paired_with.paired_with = null;
        paired_with = null;
    }
}


// VIN-pairing pass. Call once per tick from EnergyAppModule.update().
// For each appliance with a vin set, find an appliance whose primary device
// reports a matching VIN element and pair them bidirectionally.
void update_vin_pairings()
{
    auto col = Collection!Appliance();
    foreach (Appliance a; col.values)
    {
        if (a.vin.length == 0)
            continue;
        Appliance partner = find_appliance_reporting_vin(col, a.vin);
        if (a.paired_with is partner)
            continue;
        // tear down stale links on both sides
        if (a.paired_with !is null && a.paired_with.paired_with is a)
            a.paired_with.paired_with = null;
        if (partner !is null && partner.paired_with !is null && partner.paired_with.paired_with is partner)
            partner.paired_with.paired_with = null;
        a.paired_with = partner;
        if (partner !is null)
            partner.paired_with = a;
    }
}


private:

Appliance find_appliance_reporting_vin(Collection!Appliance col, const(char)[] vin)
{
    foreach (Appliance a; col.values)
    {
        if (a.device_ref is null)
            continue;
        Element* e = a.device_ref.find_element("vin");
        if (e is null)
        {
            if (Component info = a.device_ref.get_first_component_by_template("DeviceInfo"))
                e = info.find_element("vin");
        }
        if (e !is null && e.value.isString && e.value.asString == vin)
            return a;
    }
    return null;
}

Component resolve_component_path(const(char)[] path)
{
    size_t dot = path.findFirst('.');
    const(char)[] device_id = path[0 .. dot];
    Device* d = device_id in g_app.devices;
    if (!d)
        return null;
    if (dot == path.length)
        return *d;
    return (*d).find_component(path[dot + 1 .. $]);
}
