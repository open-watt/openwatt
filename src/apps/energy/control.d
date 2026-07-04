module apps.energy.control;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.meta.enuminfo;
import urt.si.quantity : VarQuantity;
import urt.string;
import urt.time;

import apps.energy.appliance;
import apps.energy.topology;
import apps.energy.vehicle;

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


struct Control
{
nothrow @nogc:

    Appliance owner;

    // Optional contributing partner retained for future graph-local composite
    // controls. Null for direct controls.
    Appliance partner;

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

    VarQuantity min_q()       const => read_quantity(min_e);
    VarQuantity max_q()       const => read_quantity(max_e);
    VarQuantity nameplate_q() const => read_quantity(nameplate_power_e);

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

    // can_disable defaults to true when there's no explicit element. Composite
    // graph controls may later add a separate enable_e to bridge split actuators.
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
// after topology refresh. The map is rebuilt by walking Collection!Appliance().
class ControlRegistry
{
nothrow @nogc:

    Map!(Appliance, Control) by_owner;
    Map!(Appliance, Control) by_target;

    // Look up the Control relevant to an appliance. Direct controls win; graph
    // composites let a policy target a car while the setpoint lives on its EVSE.
    Control* lookup(Appliance a)
    {
        if (a is null)
            return null;
        if (Control* c = a in by_owner)
            return c;
        if (Control* c = a in by_target)
            return c;
        return null;
    }

    // Rebuild the registry from the current appliance Collection. Cheap at
    // expected scale (tens of appliances). Preserves allocator-owned runtime
    // state (last_transition, current_setpoint) across rebuilds.
    //
    // TODO: dirty-tracking. Currently re-scans every appliance every tick.
    //       Sources of dirtiness to wire up later:
    //         - Appliance property change (device/meter/status binding edited via console)
    //         - Appliance bus/port binding changed
    //         - Underlying device's component tree changed (sub-component added/removed)
    //         - Underlying device went online/offline
    //       A `dirty` flag set on Appliance + a ComponentEvent.tree_changed
    //       subscription on each owner's device covers all four. resync_all
    //       then walks only dirty entries.
    void resync_all(ref TopologyGraph graph)
    {
        auto col = Collection!Appliance();

        // Mark survivors so we can prune the rest.
        Array!Appliance survivors;
        Array!Appliance composite_survivors;

        foreach (Appliance a; col.values)
        {
            Component source = find_actuator_in(a.device_ref);
            if (source is null)
                continue;

            // a is the owner. Composite controls will be synthesized from graph
            // adjacency in a later pass.
            Control synth;
            synthesize(a, source, synth);

            // Preserve allocator-owned runtime state across rebuilds.
            if (Control* existing = a in by_owner)
            {
                synth.last_transition = existing.last_transition;
                synth.current_setpoint = existing.current_setpoint;
            }

            by_owner.insert(a, synth.move);
            survivors ~= a;
        }

        synthesize_graph_controls(graph, composite_survivors);

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

        to_remove.clear();
        foreach (key; by_target.keys)
        {
            Appliance k = cast(Appliance)key;
            bool kept = false;
            foreach (s; composite_survivors)
                if (s is k) { kept = true; break; }
            if (!kept)
                to_remove ~= k;
        }
        foreach (key; to_remove)
        {
            // car left mid-drive: hand drive state to the actuator so the release pass winds the setpoint down
            if (Control* dying = key in by_target)
            {
                if (dying.current_setpoint == dying.current_setpoint && dying.partner !is null)
                {
                    if (Control* actuator = dying.partner in by_owner)
                    {
                        if (actuator.current_setpoint != actuator.current_setpoint)
                        {
                            actuator.current_setpoint = dying.current_setpoint;
                            actuator.last_transition = dying.last_transition;
                        }
                    }
                }
            }
            by_target.remove(key);
        }
    }

private:
    void synthesize_graph_controls(ref TopologyGraph graph, ref Array!Appliance survivors)
    {
        foreach (link; graph.links[])
        {
            if (link.owner is null)
                continue;
            Control* actuator = link.owner in by_owner;
            if (actuator is null)
                continue;

            // only project across the delivery side; the grid-side bus carries unrelated peers
            Bus* far;
            if (link.port_b !is null && link.port_b.role == PortRole.car)
                far = link.b;
            else if (link.port_a !is null && link.port_a.role == PortRole.car)
                far = link.a;
            if (far is null)
                continue;

            foreach (p; far.ports[])
            {
                Appliance target = p.owner;
                if (target is null || target is link.owner)
                    continue;
                if (!is_vehicle_target(target))
                    continue;
                if (target in by_owner)
                    continue;

                Control synth = *actuator;
                synth.owner = target;
                synth.partner = link.owner;
                synth.state_e = null;
                synth.enable_e = null;

                Component target_state = target.state_ref;
                if (target_state is null)
                    target_state = target.device_ref;
                if (target_state is null && target.vin.length != 0)
                    target_state = vehicle_for(target.vin);

                if (target_state !is null)
                {
                    synth.state_e = pick_state_element(target_state);
                    synth.enable_e = pick_enable_element(target_state);
                }
                if (synth.state_e is null)
                    synth.state_e = actuator.state_e;
                if (synth.enable_e is null)
                    synth.enable_e = actuator.enable_e;

                if (Control* existing = target in by_target)
                {
                    synth.last_transition = existing.last_transition;
                    synth.current_setpoint = existing.current_setpoint;
                }

                by_target.insert(target, synth.move);
                survivors ~= target;
            }
        }
    }

    bool is_vehicle_target(Appliance a)
    {
        return a.kind == "car" || a.kind == "vehicle" || a.vin.length != 0;
    }

    // Find a PowerControl or Switch component anywhere within the given
    // component subtree. Returns the first match (PowerControl preferred).
    Component find_actuator_in(Component root)
    {
        if (root is null)
            return null;
        if (root.template_[] == "PowerControl" || root.template_[] == "Switch")
            return root;
        if (Component pc = root.find_first_component_by_template_recursive("PowerControl"))
            return pc;
        if (Component sw = root.find_first_component_by_template_recursive("Switch"))
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
        while (c !is null && !c.is_device)
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

// Normalise to SI base units so the scalar accessors (used for display and for
// scalar comparison against meter-derived values) are unit-consistent regardless
// of how the device stores them — e.g. the TWC's CentiAmps and the SmartEVSE's Amps
// both read back as amps.
float read_float(const(Element)* e)
{
    if (e is null || !e.value.isNumber)
        return float.nan;
    return cast(float)e.normalised_value();
}

// Dimensioned read: the value with its unit/scale intact (NaN-valued if absent).
VarQuantity read_quantity(const(Element)* e)
{
    if (e is null || !e.value.isNumber)
        return VarQuantity.nan;
    return e.value.asQuantity();
}

Duration read_duration(const(Element)* e)
{
    if (e is null || !e.value.isNumber)
        return Duration.zero;
    return seconds(cast(long)e.value.asFloat());
}
