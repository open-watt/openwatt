module apps.energy.allocator;

import urt.array;
import urt.lifetime;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time;

import apps.energy.appliance;
import apps.energy.circuit;
import apps.energy.control;
import apps.energy.island;
import apps.energy.meter : MeterField;
import apps.energy.planner;
import apps.energy.policy;

import manager;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


void run_allocator(Device energy_device, ControlRegistry registry, ref Planner planner, ref Archipelago archipelago)
{
    SysTime now = getSysTime();

    static struct Ranked { Policy p; float mv; }
    Array!Ranked queue;
    foreach (Policy p; Collection!Policy().values)
    {
        IslandBudget* b = planner.budget_for_policy(p, archipelago);
        PolicyAnalysis a = analyse_policy(p, registry, now, planner.slack_threshold, b);
        if (a.marginal_value > 0)
            queue ~= Ranked(p, a.marginal_value);
    }
    queue.sort!((Ranked a, Ranked b) => a.mv > b.mv);

    Array!(Control*) driven;
    foreach (ref r; queue)
    {
        Policy p = r.p;
        Control* ctl = registry.lookup(p.target_appliance);
        if (ctl is null)
        {
            record_decision(energy_device, p, "no control", float.nan, now);
            continue;
        }
        if (ctl.setpoint is null)
        {
            record_decision(energy_device, p, "no setpoint element", float.nan, now);
            continue;
        }
        if (driven[].findFirst(ctl) < driven.length)
        {
            record_decision(energy_device, p, "shadowed by higher-tier policy", float.nan, now);
            continue;
        }
        driven ~= ctl;

        MonoTime mt = getTime();
        final switch (p.parsed_goal.kind) with (GoalKind)
        {
            case none:
                continue;
            case on:
                ctl.setpoint.value(true, now);
                ctl.current_setpoint = 1;
                ctl.last_transition = mt;
                record_decision(energy_device, p, "on", 1, now);
                break;
            case off:
                ctl.setpoint.value(false, now);
                ctl.current_setpoint = 0;
                ctl.last_transition = mt;
                record_decision(energy_device, p, "off", 0, now);
                break;
            case soc:
            case temp:
            case duty:
                // TODO: drive full-rate is a strawman. Should consult planner's
                //       required_kwh + time_to_deadline to pick a smarter setpoint
                //       (modulate down when slack is large; conserve battery for higher tiers).
                float setpoint = ctl.max;
                if (setpoint != setpoint)
                    setpoint = ctl.nameplate_power;
                if (setpoint != setpoint)
                {
                    record_decision(energy_device, p, "no max/nameplate", float.nan, now);
                    continue;
                }
                const(char)[] reason = "drive";
                if (ctl.unit == ControlUnit.A)
                {
                    Circuit* circuit = find_circuit_for_appliance(p.target_appliance);
                    float headroom = path_headroom_amps(circuit);
                    if (headroom == headroom && setpoint > headroom)
                    {
                        float min_amps = ctl.min;
                        if (headroom < (min_amps == min_amps ? min_amps : 0))
                        {
                            record_decision(energy_device, p, "no path headroom", float.nan, now);
                            continue;
                        }
                        setpoint = headroom;
                        reason = "drive (headroom-clamped)";
                    }
                }
                // TODO: path-headroom for W and boolean units. W needs nominal voltage to
                //       convert headroom_amps -> headroom_W. Boolean needs nameplate_power
                //       to decide if turning on would breach the circuit budget.
                ctl.setpoint.value(setpoint, now);
                ctl.current_setpoint = setpoint;
                ctl.last_transition = mt;
                record_decision(energy_device, p, reason, setpoint, now);
                break;
            case expression:
                // TODO: expression goals shouldn't always drive `true`. The right shape is
                //       probably: the expression evaluates to the *desired setpoint value*,
                //       and the allocator writes that. Currently we treat satisfaction as
                //       "expression truthy" and react with a hardcoded on; needs a redesign
                //       of the expression-goal contract.
                ctl.setpoint.value(true, now);
                ctl.current_setpoint = 1;
                ctl.last_transition = mt;
                record_decision(energy_device, p, "expression", 1, now);
                break;
        }
    }

    // Release controls we previously commanded but no policy wants now.
    MonoTime mt_release = getTime();
    foreach (ref ctl; registry.by_owner.values)
    {
        if (ctl.current_setpoint != ctl.current_setpoint)
            continue;
        if (driven[].findFirst(&ctl) < driven.length)
            continue;
        release_control(ctl, now, mt_release);
    }
    // TODO: book-keep per-circuit commitments across the queue. Right now headroom
    //       checks read the meter-measured load only; multiple controls on the same
    //       circuit in the same tick don't see each other's pending writes.
    // TODO: respect Control's min_on_time / min_off_time / min_dwell / max_cycles_per_hour
    //       constraints — currently we toggle setpoints freely and could thrash relays.
}


private:

// Resolve the circuit an appliance lives on. The appliance carries its own
// circuit pointer (set when its `circuit=` property resolves), so this is
// trivial — unlike the old version which had to walk archipelago->island->
// circuit->appliances to find the link.
Circuit* find_circuit_for_appliance(Appliance a)
{
    if (a is null)
        return null;
    return a.circuit_ref;
}

// Minimum spare current (amps) along the path from `circuit` up to the island
// root. NaN means no info on the path (no metered circuit or no max_current set).
float path_headroom_amps(Circuit* circuit)
{
    if (circuit is null)
        return float.nan;
    float min_headroom = float.infinity;
    bool any = false;
    Circuit* c = circuit;
    while (c !is null)
    {
        if (c.max_current > 0 && c.meter_data.has(MeterField.current))
        {
            float load = c.meter_data.current[0].value;
            float headroom = cast(float)c.max_current - load;
            if (headroom < min_headroom)
                min_headroom = headroom;
            any = true;
        }
        c = c.parent;
    }
    return any ? min_headroom : float.nan;
}

void release_control(ref Control ctl, SysTime now, MonoTime mt)
{
    if (ctl.setpoint is null)
    {
        ctl.current_setpoint = float.nan;
        return;
    }
    if (ctl.unit == ControlUnit.boolean)
    {
        ctl.setpoint.value(false, now);
    }
    else if (ctl.can_disable)
    {
        ctl.setpoint.value(0.0f, now);
    }
    else
    {
        float mn = ctl.min;
        if (mn == mn)
            ctl.setpoint.value(mn, now);
        // TODO: !can_disable && no min — silently leave the previous setpoint. Could write
        //       0 anyway and let the device clamp, or surface a warning. Decide once we hit
        //       a real case (none in the smartevse/TWC retrofits so far).
    }
    ctl.current_setpoint = float.nan;
    ctl.last_transition = mt;
}

void record_decision(Device energy_device, Policy p, const(char)[] reason, float commanded, SysTime now)
{
    if (energy_device is null || p is null)
        return;
    const(char)[] base = tconcat("allocation.", p.name[]);

    if (Element* e = energy_device.find_or_create_element(tconcat(base, ".reason")))
        e.value(reason, now);
    if (Element* e = energy_device.find_or_create_element(tconcat(base, ".target")))
        e.value(p.target, now);
    if (commanded == commanded)
    {
        if (Element* e = energy_device.find_or_create_element(tconcat(base, ".commanded")))
            e.value(commanded, now);
    }
}
