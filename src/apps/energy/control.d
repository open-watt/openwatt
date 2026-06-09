module apps.energy.control;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.meta.enuminfo;
import urt.string;
import urt.time;

import apps.energy.appliance;

import manager.collection;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


enum ControlKind : ubyte
{
    unknown,
    autonomous,
    discrete,
    continuous,
    staged,
}

enum ControlDirection : ubyte
{
    unknown,
    consume,
    produce,
    bidirectional,
}

enum ControlUnit : ubyte
{
    unknown,
    boolean,
    A,
    W,
    percent,
    nameplate_fraction,
}

enum AutonomousMode : ubyte
{
    unknown,
    track_meter,
    schedule,
    weather,
}


// Backend's view of an actuator. Synthesized by ControlRegistry from one or
// more Appliances. Lifecycle is managed entirely by the registry; nothing
// outside the registry should construct or destroy a Control directly.
struct Control
{
nothrow @nogc:

    // The actuator-bearing appliance (where setpoint lives).
    Appliance owner;

    // Optional contributing partner — e.g. a paired car appliance whose BLE
    // surface provides the enable flag and SOC element for an EVSE-owned
    // setpoint. Null for non-composite controls.
    Appliance partner;

    // Convenience refs to the actuator component (within owner.device_ref or
    // partner.device_ref). Used by allocator for path-headroom etc.
    Device device;
    Component source;

    Element* kind_e;
    Element* direction_e;
    Element* unit_e;
    Element* autonomous_mode_e;

    Element* setpoint;
    Element* measured;
    Element* autonomous_reference;

    Element* min_e;
    Element* max_e;
    Element* step_e;
    Element* nameplate_power_e;
    Element* ramp_rate_e;

    Element* min_on_time_e;
    Element* min_off_time_e;
    Element* min_dwell_e;
    Element* command_latency_e;

    Element* max_cycles_per_hour_e;
    Element* can_disable_e;

    // Explicit on/off, separate from setpoint. Populated for composites where
    // the actuator (e.g. TWC) can't disable but a partner element can (e.g.
    // car BLE charging flag). Null when setpoint itself can disable.
    Element* enable_e;

    // Generic state observable: SOC, temperature, position. Whatever Policy
    // needs to evaluate goals like soc(N), temp(N), on/off. Sourced from
    // owner.state_ref, partner.state_ref, or discovered on owner.device_ref.
    Element* state_e;

    // Allocator-owned runtime state; no upstream source.
    MonoTime last_transition;
    float current_setpoint = float.nan;

    ControlKind kind() const
    {
        if (kind_e && kind_e.value.isString)
        {
            if (const(ControlKind)* p = enum_from_key!ControlKind(kind_e.value.asString))
                return *p;
        }
        if (source && source.template_[] == "Switch")
            return ControlKind.discrete;
        return ControlKind.unknown;
    }

    ControlDirection direction() const
    {
        if (direction_e && direction_e.value.isString)
        {
            if (const(ControlDirection)* p = enum_from_key!ControlDirection(direction_e.value.asString))
                return *p;
        }
        if (source && source.template_[] == "Switch")
            return ControlDirection.consume;
        return ControlDirection.unknown;
    }

    ControlUnit unit() const
    {
        if (unit_e && unit_e.value.isString)
        {
            if (const(ControlUnit)* p = enum_from_key!ControlUnit(unit_e.value.asString))
                return *p;
        }
        if (source && source.template_[] == "Switch")
            return ControlUnit.boolean;
        return ControlUnit.unknown;
    }

    AutonomousMode autonomous_mode() const
    {
        if (autonomous_mode_e && autonomous_mode_e.value.isString)
        {
            if (const(AutonomousMode)* p = enum_from_key!AutonomousMode(autonomous_mode_e.value.asString))
                return *p;
        }
        return AutonomousMode.unknown;
    }

    float min()             const => read_float(min_e);
    float max()             const => read_float(max_e);
    float step()            const => read_float(step_e);
    float nameplate_power() const => read_float(nameplate_power_e);
    float ramp_rate()       const => read_float(ramp_rate_e);

    Duration min_on_time()      const => read_duration(min_on_time_e);
    Duration min_off_time()     const => read_duration(min_off_time_e);
    Duration min_dwell()        const => read_duration(min_dwell_e);
    Duration command_latency()  const => read_duration(command_latency_e);

    int max_cycles_per_hour() const
    {
        if (max_cycles_per_hour_e && max_cycles_per_hour_e.value.isNumber)
            return cast(int)max_cycles_per_hour_e.value.asFloat();
        return 0;
    }

    // can_disable defaults to true when there's no explicit element AND no
    // explicit enable_e binding. For composites (TWC+Car), the enable_e bridges
    // the gap: TWC can't disable, but the paired car can — so effectively yes.
    bool can_disable() const
    {
        if (can_disable_e && can_disable_e.value.isBool)
            return can_disable_e.value.asBool || enable_e !is null;
        return true;
    }
}


// Backend-owned registry of synthesized Controls. One entry per actuator-bearing
// appliance (the owner). Composite controls have a non-null partner.
//
// Lifecycle: resync_all() is called once per tick from EnergyAppModule.update()
// after VIN pairing. The map is rebuilt by walking Collection!Appliance().
class ControlRegistry
{
nothrow @nogc:

    Map!(Appliance, Control) by_owner;

    // Look up the Control relevant to an appliance — directly via ownership,
    // or via the pair link (policy.target=evie -> evie.paired_with=charger ->
    // charger's control).
    Control* lookup(Appliance a)
    {
        if (a is null)
            return null;
        if (Control* c = a in by_owner)
            return c;
        if (a.paired_with !is null)
            return a.paired_with in by_owner;
        return null;
    }

    // Rebuild the registry from the current appliance Collection. Cheap at
    // expected scale (tens of appliances). Preserves allocator-owned runtime
    // state (last_transition, current_setpoint) across rebuilds.
    //
    // TODO: dirty-tracking. Currently re-scans every appliance every tick.
    //       Sources of dirtiness to wire up later:
    //         - Appliance property change (device/meter/status binding edited via console)
    //         - Appliance.paired_with changed (VIN pairing formed/broken)
    //         - Underlying device's component tree changed (sub-component added/removed)
    //         - Underlying device went online/offline
    //       A `dirty` flag set on Appliance + a ComponentEvent.tree_changed
    //       subscription on each owner's device covers all four. resync_all
    //       then walks only dirty entries.
    void resync_all()
    {
        auto col = Collection!Appliance();

        // Mark survivors so we can prune the rest.
        Array!Appliance survivors;

        foreach (Appliance a; col.values)
        {
            Component source = find_actuator_in(a.device_ref);
            if (source is null)
                continue;

            // a is the owner; pair contribution (if any) comes from a.paired_with.
            Control synth;
            synthesize(a, source, synth);
            apply_partner(synth, a.paired_with);

            // Preserve allocator-owned runtime state across rebuilds.
            if (Control* existing = a in by_owner)
            {
                synth.last_transition = existing.last_transition;
                synth.current_setpoint = existing.current_setpoint;
            }

            by_owner.insert(a, synth.move);
            survivors ~= a;
        }

        // Prune entries whose owner no longer has an actuator (or no longer exists).
        // TODO: O(N*M). Fine at our scale; revisit if appliance count explodes.
        Array!Appliance to_remove;
        foreach (key; by_owner.keys)
        {
            Appliance k = cast(Appliance)key;
            bool kept = false;
            foreach (s; survivors)
                if (s is k) { kept = true; break; }
            if (!kept)
                to_remove ~= k;
        }
        foreach (key; to_remove)
            by_owner.remove(key);
    }

private:

    // Find a PowerControl or Switch component anywhere within the given
    // component subtree. Returns the first match (PowerControl preferred).
    Component find_actuator_in(Component root)
    {
        if (root is null)
            return null;
        if (root.template_[] == "PowerControl" || root.template_[] == "Switch")
            return root;
        if (Component pc = root.get_first_component_by_template("PowerControl"))
            return pc;
        if (Component sw = root.get_first_component_by_template("Switch"))
            return sw;
        return null;
    }

    // Populate a Control struct from an owner appliance + the actuator
    // component discovered within its device.
    void synthesize(Appliance owner, Component source, ref Control ctl)
    {
        ctl.owner = owner;
        ctl.source = source;

        // Walk up to find the owning Device.
        Component c = source;
        while (c !is null && cast(Device)c is null)
            c = c.parent;
        ctl.device = cast(Device)c;

        if (source.template_[] == "Switch")
            populate_from_switch(ctl, source);
        else
            populate_from_power_control(ctl, source);

        // State observable: prefer explicit state binding, else look on the
        // owner's device for common shapes (SOC on a Battery, temperature on
        // a ThermalStore, switch state on the actuator itself).
        if (owner.state_ref !is null)
            ctl.state_e = pick_state_element(owner.state_ref);
        if (ctl.state_e is null && owner.device_ref !is null)
            ctl.state_e = pick_state_element(owner.device_ref);
    }

    // Apply contributions from a paired partner — currently used for the
    // EVSE+Car case where the car provides enable + state elements that the
    // EVSE actuator alone can't supply.
    void apply_partner(ref Control ctl, Appliance partner)
    {
        if (partner is null)
            return;
        ctl.partner = partner;

        // enable element: look for a charging-style on/off on the partner.
        Element* e;
        if (partner.state_ref !is null)
            e = pick_enable_element(partner.state_ref);
        if (e is null && partner.device_ref !is null)
            e = pick_enable_element(partner.device_ref);
        if (e !is null)
            ctl.enable_e = e;

        // state element: partner trumps owner if partner has one (the car's
        // BLE SOC is more authoritative than whatever the EVSE might guess).
        Element* s;
        if (partner.state_ref !is null)
            s = pick_state_element(partner.state_ref);
        if (s is null && partner.device_ref !is null)
            s = pick_state_element(partner.device_ref);
        if (s !is null)
            ctl.state_e = s;
    }

    void populate_from_power_control(ref Control ctl, Component pc)
    {
        ctl.kind_e              = pc.find_element("kind");
        ctl.direction_e         = pc.find_element("direction");
        ctl.unit_e              = pc.find_element("unit");
        ctl.autonomous_mode_e   = pc.find_element("autonomous_mode");

        ctl.setpoint              = pc.find_element("setpoint");
        ctl.measured              = pc.find_element("measured");
        ctl.autonomous_reference  = pc.find_element("autonomous_reference");

        ctl.min_e               = pc.find_element("min");
        ctl.max_e               = pc.find_element("max");
        ctl.step_e              = pc.find_element("step");
        ctl.nameplate_power_e   = pc.find_element("nameplate_power");
        ctl.ramp_rate_e         = pc.find_element("ramp_rate");

        ctl.min_on_time_e       = pc.find_element("min_on_time");
        ctl.min_off_time_e      = pc.find_element("min_off_time");
        ctl.min_dwell_e         = pc.find_element("min_dwell");
        ctl.command_latency_e   = pc.find_element("command_latency");

        ctl.max_cycles_per_hour_e = pc.find_element("max_cycles_per_hour");
        ctl.can_disable_e         = pc.find_element("can_disable");
    }

    void populate_from_switch(ref Control ctl, Component sw)
    {
        // Switch implicit: kind=discrete, unit=boolean, direction=consume.
        // Accessors fall back to these when *_e is null.
        ctl.setpoint = sw.find_element("switch");

        ctl.direction_e         = sw.find_element("direction");
        ctl.nameplate_power_e   = sw.find_element("nameplate_power");

        ctl.min_on_time_e       = sw.find_element("min_on_time");
        ctl.min_off_time_e      = sw.find_element("min_off_time");
        ctl.min_dwell_e         = sw.find_element("min_dwell");
        ctl.command_latency_e   = sw.find_element("command_latency");

        ctl.max_cycles_per_hour_e = sw.find_element("max_cycles_per_hour");
        ctl.can_disable_e         = sw.find_element("can_disable");

        // Switch is also its own enable + state for trivial cases.
        ctl.enable_e = ctl.setpoint;
        ctl.state_e  = ctl.setpoint;
    }

    // Heuristic: which element on this component looks like a "state"
    // observable usable by Policy goals (soc/temp/on-off)?
    Element* pick_state_element(Component c)
    {
        if (c is null)
            return null;
        // Direct hits first
        foreach (name; ["soc", "state", "temperature", "temp", "switch"])
            if (Element* e = c.find_element(name))
                return e;
        // Look in common sub-component templates
        if (Component bat = c.get_first_component_by_template("Battery"))
        {
            if (Element* e = bat.find_element("soc"))
                return e;
            if (Element* e = bat.find_element("state"))
                return e;
        }
        if (Component ts = c.get_first_component_by_template("ThermalStore"))
            if (Element* e = ts.find_element("temperature"))
                return e;
        return null;
    }

    // Heuristic: which element on this component looks like an on/off enable?
    Element* pick_enable_element(Component c)
    {
        if (c is null)
            return null;
        foreach (name; ["charging", "enable", "enabled", "switch", "on"])
            if (Element* e = c.find_element(name))
                return e;
        return null;
    }
}


private:

float read_float(const(Element)* e)
{
    if (e is null || !e.value.isNumber)
        return float.nan;
    return e.value.asFloat();
}

Duration read_duration(const(Element)* e)
{
    if (e is null || !e.value.isNumber)
        return Duration.zero;
    return seconds(cast(long)e.value.asFloat());
}
