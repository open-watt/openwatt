module apps.energy.control;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.meta.enuminfo;
import urt.si.quantity : VarQuantity;
import urt.si.unit : ScaledUnit, Second;
import urt.string;
import urt.time;

import apps.energy.appliance;
import apps.energy.model : read_in_unit;
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


struct Control
{
nothrow @nogc:

    ObjectRef!Appliance owner;

    // Composite controls target owner through an actuator-bearing partner.
    ObjectRef!Appliance partner;

    Device device;
    Component source;

    Element* kind_e;
    Element* direction_e;
    Element* unit_e;

    Element* setpoint_e;

    Element* min_e;
    Element* max_e;
    Element* step_e;
    Element* nameplate_power_e;

    Element* min_on_time_e;
    Element* min_off_time_e;
    Element* min_dwell_e;

    Element* max_cycles_per_hour_e;
    Element* can_disable_e;

    // A composite may expose on/off independently from its scalar setpoint.
    Element* enable_e;

    // Policy witness selected from explicit state or the owner's device.
    Element* state_e;

    MonoTime last_transition;
    MonoTime last_on;
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

    float min()             const => read_float(min_e);
    float max()             const => read_float(max_e);
    float step()            const => read_float(step_e);
    float nameplate_power() const => read_float(nameplate_power_e);

    VarQuantity min_q()       const => read_quantity(min_e);
    VarQuantity max_q()       const => read_quantity(max_e);
    VarQuantity nameplate_q() const => read_quantity(nameplate_power_e);

    Duration min_on_time()      const => read_duration(min_on_time_e);
    Duration min_off_time()     const => read_duration(min_off_time_e);
    Duration min_dwell()        const => read_duration(min_dwell_e);

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
        if (can_disable_e)
        {
            if (can_disable_e.value.isBool)
                return can_disable_e.value.asBool || enable_e !is null;
            if (can_disable_e.value.isString)
            {
                const(char)[] s = can_disable_e.value.asString;
                if (s.ieq("false") || s[] == "0")
                    return enable_e !is null;
            }
        }
        return true;
    }
}


// Maps policy targets to direct or graph-projected control surfaces.
class ControlRegistry
{
nothrow @nogc:

    Map!(CID, Control) by_owner;
    Map!(CID, Control) by_target;

    Control* lookup(Appliance a)
    {
        if (a is null)
            return null;
        if (Control* c = a.id in by_owner)
            return c;
        if (Control* c = a.id in by_target)
            return c;
        return null;
    }

    // TODO: replace the per-tick scan with appliance and component-tree dirtiness.
    void resync_all(ref TopologyGraph graph)
    {
        auto col = Collection!Appliance();

        Array!CID survivors;
        Array!CID composite_survivors;

        foreach (Appliance a; col.values)
        {
            Component source = find_actuator_in(a.device_ref);
            if (source is null)
                continue;

            Control synth;
            synthesize(a, source, synth);

            if (Control* existing = a.id in by_owner)
            {
                synth.last_transition = existing.last_transition;
                synth.last_on = existing.last_on;
                synth.current_setpoint = existing.current_setpoint;
            }

            by_owner.replace(a.id, synth.move);
            survivors ~= a.id;
        }

        synthesize_graph_controls(graph, composite_survivors);

        // TODO: O(N*M). Fine at our scale; revisit if appliance count explodes.
        Array!CID to_remove;
        foreach (key; by_owner.keys)
        {
            bool kept = false;
            foreach (s; survivors)
                if (s == key) { kept = true; break; }
            if (!kept)
                to_remove ~= key;
        }
        foreach (key; to_remove)
            by_owner.remove(key);

        to_remove.clear();
        foreach (key; by_target.keys)
        {
            bool kept = false;
            foreach (s; composite_survivors)
                if (s == key) { kept = true; break; }
            if (!kept)
                to_remove ~= key;
        }
        foreach (key; to_remove)
        {
            // Preserve allocator ownership so a departed car's actuator is released.
            if (Control* dying = key in by_target)
            {
                if (dying.current_setpoint == dying.current_setpoint && dying.partner !is null)
                {
                    if (Control* actuator = dying.partner.get.id in by_owner)
                    {
                        if (actuator.current_setpoint != actuator.current_setpoint)
                        {
                            actuator.current_setpoint = dying.current_setpoint;
                            actuator.last_transition = dying.last_transition;
                            actuator.last_on = dying.last_on;
                        }
                    }
                }
            }
            by_target.remove(key);
        }
    }

private:
    void synthesize_graph_controls(ref TopologyGraph graph, ref Array!CID survivors)
    {
        foreach (link; graph.links[])
        {
            if (link.owner is null)
                continue;
            Control* actuator = link.owner ? link.owner.id in by_owner : null;
            if (actuator is null)
                continue;

            // Only the delivery side identifies the vehicle controlled by this actuator.
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
                if (target.id in by_owner)
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

                if (Control* existing = target.id in by_target)
                {
                    synth.last_transition = existing.last_transition;
                    synth.current_setpoint = existing.current_setpoint;
                }

                by_target.replace(target.id, synth.move);
                survivors ~= target.id;
            }
        }
    }

    bool is_vehicle_target(Appliance a)
    {
        return a.kind == "car" || a.kind == "vehicle" || a.vin.length != 0;
    }

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

    void synthesize(Appliance owner, Component source, ref Control ctl)
    {
        ctl.owner = owner;
        ctl.source = source;

        Component c = source;
        while (c !is null && !c.is_device)
            c = c.parent;
        ctl.device = cast(Device)c;

        if (source.template_[] == "Switch")
            populate_from_switch(ctl, source);
        else
            populate_from_power_control(ctl, source);

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

        ctl.setpoint_e              = pc.find_element("setpoint");
        ctl.enable_e              = pc.find_element("enable");

        ctl.min_e               = pc.find_element("min");
        ctl.max_e               = pc.find_element("max");
        ctl.step_e              = pc.find_element("step");
        ctl.nameplate_power_e   = pc.find_element("nameplate_power");

        ctl.min_on_time_e       = pc.find_element("min_on_time");
        ctl.min_off_time_e      = pc.find_element("min_off_time");
        ctl.min_dwell_e         = pc.find_element("min_dwell");

        ctl.max_cycles_per_hour_e = pc.find_element("max_cycles_per_hour");
        ctl.can_disable_e         = pc.find_element("can_disable");
    }

    void populate_from_switch(ref Control ctl, Component sw)
    {
        ctl.direction_e         = sw.find_element("direction");
        ctl.nameplate_power_e   = sw.find_element("nameplate_power");

        ctl.min_on_time_e       = sw.find_element("min_on_time");
        ctl.min_off_time_e      = sw.find_element("min_off_time");
        ctl.min_dwell_e         = sw.find_element("min_dwell");

        ctl.max_cycles_per_hour_e = sw.find_element("max_cycles_per_hour");
        ctl.can_disable_e         = sw.find_element("can_disable");

        // A switch is both actuator and state witness.
        ctl.enable_e = sw.find_element("switch");
        ctl.state_e  = ctl.enable_e;
    }

    Element* pick_state_element(Component c)
    {
        if (c is null)
            return null;
        foreach (name; ["soc", "state", "temperature", "temp", "switch"])
            if (Element* e = c.find_element(name))
                return e;
        if (Component bat = c.get_first_component_by_template("Battery"))
        {
            if (Element* e = bat.find_element("soc"))
                return e;
            // Prefer real SOC; soc_floor is only a pessimistic fallback.
            if (Element* e = bat.find_element("soc_floor"))
                return e;
            if (Element* e = bat.find_element("state"))
                return e;
        }
        if (Component ts = c.get_first_component_by_template("ThermalStore"))
            if (Element* e = ts.find_element("temperature"))
                return e;
        return null;
    }

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

// Scalar comparisons use SI base units regardless of device storage scale.
float read_float(const(Element)* e)
{
    if (e is null || !e.value.isNumber)
        return float.nan;
    return cast(float)e.normalised_value();
}

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
    // Bare duration constants are already seconds; typed values normalise to them.
    return seconds(cast(long)e.normalised_value());
}
