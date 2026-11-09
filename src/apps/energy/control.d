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
    CID command_policy;
    bool setpoint_written;

    ControlKind kind() const
    {
        if (kind_e)
            if (const(ControlKind)* p = enum_from_key!ControlKind(kind_e.text_value()))
                return *p;
        if (source && is_switch(source))
            return ControlKind.discrete;
        return ControlKind.unknown;
    }

    ControlDirection direction() const
    {
        if (direction_e)
            if (const(ControlDirection)* p = enum_from_key!ControlDirection(direction_e.text_value()))
                return *p;
        if (source && is_switch(source))
            return ControlDirection.consume;
        return ControlDirection.unknown;
    }

    ControlUnit unit() const
    {
        if (unit_e)
            if (const(ControlUnit)* p = enum_from_key!ControlUnit(unit_e.text_value()))
                return *p;
        if (source && is_switch(source))
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
            const(char)[] s = can_disable_e.text_value();
            if (s.ieq("false") || s[] == "0")
                return enable_e !is null;
        }
        return true;
    }
}


// Maps policy targets to direct or graph-projected control surfaces.
final class ControlRegistry
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

    void settle_dispatch(Control* control)
    {
        if (!control.setpoint_written)
            return;
        clear_alias_commands(by_owner, control);
        clear_alias_commands(by_target, control);
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
                inherit_command(synth, *existing);
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
            if (Control* departing = key in by_target)
                handoff_departing_control(*departing);
            by_target.remove(key);
        }
    }

private:
    static void clear_alias_commands(ref Map!(CID, Control) controls, Control* control)
    {
        foreach (ref alias_control; controls.values)
        {
            if (&alias_control is control || alias_control.setpoint_e !is control.setpoint_e)
                continue;
            alias_control.current_setpoint = float.nan;
            alias_control.command_policy = CID.init;
        }
    }

    // Leave the old actuator visible to the allocator's release pass.
    void handoff_departing_control(ref const Control departing)
    {
        const(Appliance) partner = departing.partner.get;
        if (!partner || departing.current_setpoint != departing.current_setpoint)
            return;
        if (Control* actuator = partner.id in by_owner)
        {
            if (actuator.source is departing.source && actuator.setpoint_e is departing.setpoint_e &&
                actuator.current_setpoint != actuator.current_setpoint)
                inherit_command(*actuator, departing);
        }
    }

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
                synth.current_setpoint = float.nan;
                synth.command_policy = CID.init;
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
                    if (existing.partner.get is link.owner && existing.source is synth.source &&
                        existing.setpoint_e is synth.setpoint_e && existing.enable_e is synth.enable_e)
                        inherit_command(synth, *existing);
                    else
                        handoff_departing_control(*existing);
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
        if (root.template_[] == "PowerControl" || is_switch(root))
            return root;
        if (Component pc = root.find_first_component_by_template_recursive("PowerControl"))
            return pc;
        if (Component sw = root.find_first_component_by_template_recursive("Switch"))
            return sw;
        return root.find_first_component_by_template_recursive("Light");
    }

    void synthesize(Appliance owner, Component source, ref Control ctl)
    {
        ctl.owner = owner;
        ctl.source = source;

        Component c = source;
        while (c !is null && !c.is_device)
            c = c.parent;
        ctl.device = cast(Device)c;

        if (is_switch(source))
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

void inherit_command(ref Control control, ref const Control previous) pure
{
    control.last_transition = previous.last_transition;
    control.last_on = previous.last_on;
    control.current_setpoint = previous.current_setpoint;
    control.command_policy = previous.command_policy;
}

bool is_switch(const Component c)
    => c.template_[] == "Switch" || c.template_[] == "Light";

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


unittest
{
    import urt.mem : alloc, free;
    import urt.si.quantity : Quantity, Watts;
    import urt.si.unit : Percent;

    import apps.energy.allocator : DecisionField, run_allocator;
    import apps.energy.planner : Planner;
    import apps.energy.policy : Policy, PolicyTier;

    auto appliances = Collection!Appliance();
    Appliance a = appliances.alloc("handoff-a");
    Appliance b = appliances.alloc("handoff-b");
    Appliance car = appliances.alloc("handoff-car");
    appliances.add(a);
    appliances.add(b);
    appliances.add(car);
    scope(exit)
        foreach (appliance; [a, b, car])
        {
            appliances.remove(appliance);
            free(appliance);
        }

    DeviceTable devices;
    alias Soc = Quantity!(float, Percent);
    Element* create_evse(Appliance owner)
    {
        auto builder = devices.create(owner.name[]);
        Component pc = builder.component("control", "PowerControl");
        builder.element(pc, "unit", register_value_format!string()).value("W");
        builder.element(pc, "max", register_value_format!Watts()).value(Watts(1000));
        Element* soc = builder.element("soc", register_value_format!Soc());
        soc.sampling_mode = SamplingMode.poll;
        soc.value(Soc(20));
        Element* setpoint = builder.element(pc, "setpoint", register_value_format!Watts());
        builder.commit();
        owner.vin = owner.name[];
        assert(owner.resolve_refs(devices));
        return setpoint;
    }

    Element* setpoint_a = create_evse(a);
    Element* setpoint_b = create_evse(b);
    car.kind = "car";
    auto builder = devices.create(car.name[]);
    Device car_device = builder.device;
    Element* soc = builder.element("soc", register_value_format!Soc());
    soc.sampling_mode = SamplingMode.poll;
    soc.value(Soc(90));
    builder.commit();
    car.vin = car.name[];
    assert(car.resolve_refs(devices));

    auto policies = Collection!Policy();
    Policy add_policy(const(char)[] name, Appliance target, PolicyTier tier, const(char)[] goal)
    {
        Policy policy = policies.alloc(name);
        policies.add(policy);
        assert(policy.target(target.name[]) is null);
        policy.tier = tier;
        assert(policy.goal(goal) is null);
        policies.update_all();
        assert(policy.running);
        return policy;
    }
    Policy floor = add_policy("handoff-floor", car, PolicyTier.floor, "soc(80)");
    Policy direct = add_policy("handoff-direct", a, PolicyTier.floor, "soc(80)");
    scope(exit)
    {
        direct.destroy();
        floor.destroy();
        policies.update_all();
    }

    auto registry = alloc!ControlRegistry();
    scope(exit) free(registry);
    TopologyGraph graph;
    scope(exit) graph.clear();

    void connect(Appliance evse)
    {
        graph.clear();
        Bus* supply = graph.ensure_bus("supply");
        Bus* outlet = graph.ensure_bus("outlet");
        Port* delivery = graph.add_port(evse, outlet, PortRole.car, FlowDomain.supply, null, 0);
        graph.add_port(car, outlet, PortRole.connection, FlowDomain.consume, null, 0);
        graph.add_link(evse, supply, outlet, null, delivery, 0);
        registry.resync_all(graph);
    }

    registry.resync_all(graph);
    Islands islands;
    Planner planner;
    run_allocator(car_device, registry, planner, islands, graph);
    assert(setpoint_a.normalised_value() == 1000);
    Control* direct_control = registry.lookup(a);
    assert(direct_control.command_policy == direct.id && direct_control.current_setpoint == 1000);

    connect(a);
    Control* control = registry.lookup(car);
    direct_control = registry.lookup(a);
    assert(control && control.setpoint_e is setpoint_a);
    assert(control.command_policy == CID.init && control.current_setpoint != control.current_setpoint);
    assert(control.last_transition == direct_control.last_transition && control.last_on == direct_control.last_on);
    assert(direct_control.command_policy == direct.id && direct_control.current_setpoint == 1000);

    Element* direct_soc = a.device_ref.find_element("soc");
    direct_soc.value(Soc(90));
    soc.value(Soc(20));
    Element* max_a = a.device_ref.find_element("control.max");
    max_a.value(Watts(2000));
    SysTime authority_time = getSysTime() + dur!"minutes"(1);
    setpoint_a.value(Watts(1000), authority_time);
    run_allocator(car_device, registry, planner, islands, graph);
    assert(setpoint_a.normalised_value() == 2000 && setpoint_a.last_update == authority_time);
    assert(control.command_policy == floor.id && control.current_setpoint == 2000);
    assert(direct_control.command_policy == CID.init && direct_control.current_setpoint != direct_control.current_setpoint);

    direct_soc.value(Soc(20));
    soc.value(Soc(90));
    max_a.value(Watts(1500));
    run_allocator(car_device, registry, planner, islands, graph);
    assert(setpoint_a.normalised_value() == 1500);
    assert(direct_control.command_policy == direct.id && direct_control.current_setpoint == 1500);
    assert(control.command_policy == CID.init && control.current_setpoint != control.current_setpoint);

    direct_soc.value(Soc(90));
    soc.value(Soc(20));
    max_a.value(Watts(2000));
    run_allocator(car_device, registry, planner, islands, graph);
    assert(control.command_policy == floor.id && control.current_setpoint == 2000);
    assert(direct_control.command_policy == CID.init && direct_control.current_setpoint != direct_control.current_setpoint);

    direct_soc.last_update = getSysTime() - dur!"seconds"(181);
    soc.last_update = direct_soc.last_update;
    connect(a);
    control = registry.lookup(car);
    SysTime command_time = setpoint_a.record_update;
    run_allocator(car_device, registry, planner, islands, graph);
    assert(direct.decision[DecisionField.reason].element.text_value() == "state unknown");
    assert(floor.decision[DecisionField.reason].element.text_value() == "hold: state unknown");
    assert(control.command_policy == floor.id && control.current_setpoint == 2000);
    assert(setpoint_a.record_update == command_time);

    connect(b);
    control = registry.lookup(car);
    assert(control.setpoint_e is setpoint_b && control.command_policy == CID.init);
    assert(control.current_setpoint != control.current_setpoint && !setpoint_b.has_value);
    Control* old_actuator = registry.lookup(a);
    assert(old_actuator.command_policy == floor.id && old_actuator.current_setpoint == 2000);

    setpoint_b.value(Watts(2000));
    Policy off = add_policy("handoff-off", car, PolicyTier.important, "off");
    scope(exit)
    {
        off.destroy();
        policies.update_all();
    }
    run_allocator(car_device, registry, planner, islands, graph);
    assert(floor.decision[DecisionField.reason].element.text_value() == "state unknown");
    assert(off.decision[DecisionField.reason].element.text_value() == "off");
    assert(setpoint_a.normalised_value() == 0 && setpoint_b.normalised_value() == 0);
    assert(old_actuator.command_policy == CID.init && old_actuator.current_setpoint != old_actuator.current_setpoint);

    auto evse_builder = (cast(Device)b.device_ref).edit();
    Element* evse_enable = evse_builder.element("control.enable", register_value_format!bool());
    evse_enable.value(false);
    evse_builder.commit();
    auto vehicle_builder = car_device.edit();
    Element* vehicle_enable = vehicle_builder.element("charging", register_value_format!bool());
    vehicle_enable.value(false);
    vehicle_builder.commit();

    connect(b);
    assert(direct.target(b.name[]) is null);
    assert(direct.goal("on") is null);
    policies.update_all();
    run_allocator(car_device, registry, planner, islands, graph);
    direct_control = registry.lookup(b);
    assert(direct_control.command_policy == direct.id && direct_control.current_setpoint == 1000);
    assert(evse_enable.value.asBool && !vehicle_enable.value.asBool);

    vehicle_enable.value(true);
    command_time = setpoint_b.last_update;
    run_allocator(car_device, registry, planner, islands, graph);
    assert(off.decision[DecisionField.reason].element.text_value() == "off");
    assert(evse_enable.value.asBool && !vehicle_enable.value.asBool);
    assert(setpoint_b.normalised_value() == 1000 && setpoint_b.last_update == command_time);
    assert(direct_control.command_policy == direct.id && direct_control.current_setpoint == 1000);
}
