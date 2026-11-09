module apps.energy.allocator;

import urt.array;
import urt.lifetime;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.si.quantity : Amps, VarQuantity, Watts;
import urt.string;
import urt.time;

import apps.energy.appliance;
import apps.energy.control;
import apps.energy.meter : MeterData, MeterField;
import apps.energy.planner;
import apps.energy.policy;
import apps.energy.topology;

import manager;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:

enum DecisionField : ubyte
{
    reason, target, via, device, commanded, target_bus, source_bus, path_complete,
    path_headroom_amps, path_headroom_watts, available_headroom_amps, available_headroom_watts,
    committed_amps, committed_watts, path_voltage, limiting_link,
}


void run_allocator(Device energy_device, ControlRegistry registry, ref Planner planner, ref Islands islands, ref TopologyGraph graph)
{
    SysTime now = getSysTime();

    static struct Ranked { Policy p; float mv; }
    Array!Ranked queue;
    Array!(Control*) driven;
    foreach (Policy p; Collection!Policy().values)
    {
        if (!p.running)
            continue;
        Control* ctl = registry.lookup(p.target_appliance);
        if (witness_unknown(p, ctl, now))
        {
            if (p.tier == PolicyTier.floor && ctl.command_policy == p.id && ctl.current_setpoint == ctl.current_setpoint)
            {
                driven ~= ctl;
                record_decision(energy_device, p, "hold: state unknown", ctl.current_setpoint, now, null, ctl);
                if (!p.witness_hold_warned)
                {
                    p.log.warning("holding command while state is unknown");
                    p.witness_hold_warned = true;
                }
            }
            else
                record_decision(energy_device, p, "state unknown", float.nan, now, null, ctl);
            continue;
        }
        p.witness_hold_warned = false;
        IslandBudget* b = planner.budget_for_policy(p, islands);
        PolicyAnalysis a = analyse_policy(p, registry, now, planner.slack_threshold, b, &graph);
        if (a.marginal_value > 0)
            queue ~= Ranked(p, a.marginal_value);
    }
    queue.sort!((Ranked a, Ranked b) => a.mv > b.mv);

    Array!PathCommitment commitments;
    Array!SurplusPool surplus_pools;
    foreach (ref r; queue)
    {
        Policy p = r.p;
        Control* ctl = registry.lookup(p.target_appliance);
        if (ctl is null)
        {
            record_decision(energy_device, p, no_control_reason(p.target_appliance), float.nan, now);
            continue;
        }
        if (ctl.setpoint_e is null && ctl.enable_e is null)
        {
            record_decision(energy_device, p, "no actuator element", float.nan, now, null, ctl);
            continue;
        }
        if (control_already_driven(driven, ctl))
        {
            record_decision(energy_device, p, "shadowed by higher-tier policy", float.nan, now, null, ctl);
            continue;
        }

        MonoTime mt = getTime();
        AllocationContext ctx;
        graph.build_control_path(p.target_appliance, ctx.path);
        refresh_available_headroom(ctx, commitments);
        GoalKind goal = p.parsed_goal.kind;
        bool owned = ctl.current_setpoint == ctl.current_setpoint;
        float draw_watts = float.nan;
        float surplus = float.nan;
        if (p.tier == PolicyTier.opportunistic && goal != GoalKind.off)
        {
            surplus = surplus_remaining(surplus_pools, ctx.path.source_bus);
            if (surplus != surplus)
            {
                bool hold = owned && appliance_draw_watts(graph, p.target_appliance, true) > 0;
                if (hold)
                    driven ~= ctl;
                record_decision(energy_device, p, hold ? "hold: no export witness" : "no export witness",
                                hold ? ctl.current_setpoint : float.nan, now, &ctx, ctl);
                continue;
            }
            draw_watts = appliance_draw_watts(graph, p.target_appliance);
        }
        if (ctx.current_lost && goal != GoalKind.off)
        {
            if (owned)
                driven ~= ctl;
            record_decision(energy_device, p, owned ? "hold: link current unknown" : "link current unknown",
                            ctl.current_setpoint, now, &ctx, ctl);
            continue;
        }

        final switch (p.parsed_goal.kind) with (GoalKind)
        {
            case none:
                continue;
            case on:
                const(char)[] block_on = setpoint_change_block_reason(*ctl, 1, mt);
                if (block_on.length != 0)
                {
                    record_decision(energy_device, p, block_on, float.nan, now, &ctx, ctl);
                    continue;
                }
                if (would_exceed_path_headroom(*ctl, ctx))
                {
                    record_decision(energy_device, p, "no path headroom", float.nan, now, &ctx, ctl);
                    continue;
                }
                float on_cmd = drive_control(*ctl, ctl.max_q, now, mt);
                reserve_path_commitment(commitments, ctx, estimated_control_amps(*ctl, ctx, on_cmd));
                record_decision(energy_device, p, "on", on_cmd, now, &ctx, ctl);
                driven ~= ctl;
                break;
            case off:
                const(char)[] block_off = setpoint_change_block_reason(*ctl, 0, mt);
                if (block_off.length != 0)
                {
                    record_decision(energy_device, p, block_off, float.nan, now, &ctx, ctl);
                    continue;
                }
                float off_cmd = release_control(*ctl, now, mt);
                record_decision(energy_device, p, off_cmd == off_cmd && off_cmd > 0 ? "off (parked at min)"
                                                                  : "off",
                                off_cmd, now, &ctx, ctl);
                driven ~= ctl;
                break;
            case soc:
            case temp:
            case duty:
                if (ctl.setpoint_e is null)
                {
                    const(char)[] block_disc = setpoint_change_block_reason(*ctl, 1, mt);
                    if (block_disc.length != 0)
                    {
                        record_decision(energy_device, p, block_disc, float.nan, now, &ctx, ctl);
                        continue;
                    }
                    if (would_exceed_path_headroom(*ctl, ctx))
                    {
                        record_decision(energy_device, p, "no path headroom", float.nan, now, &ctx, ctl);
                        continue;
                    }
                    float disc_cmd = drive_control(*ctl, VarQuantity.init, now, mt);
                    reserve_path_commitment(commitments, ctx, estimated_control_amps(*ctl, ctx, disc_cmd));
                    record_decision(energy_device, p, "drive", disc_cmd, now, &ctx, ctl);
                    driven ~= ctl;
                    break;
                }
                // TODO: floor/essential/important still drive full-rate. Should consult
                //       planner's required_kwh + time_to_deadline to modulate down when
                //       slack is large / conserve battery for higher tiers.
                VarQuantity setpoint = ctl.max_q;
                if (setpoint.value != setpoint.value)
                    setpoint = ctl.nameplate_q;
                if (setpoint.value != setpoint.value)
                {
                    record_decision(energy_device, p, "no max/nameplate", float.nan, now, &ctx, ctl);
                    continue;
                }
                const(char)[] reason = "drive";

                // Present draw is already consuming surplus, so add it back before
                // capping an opportunistic control to the remaining export.
                if (p.tier == PolicyTier.opportunistic &&
                    (ctl.unit == ControlUnit.A || ctl.unit == ControlUnit.W || ctl.unit == ControlUnit.boolean))
                {
                    float budget_watts = (draw_watts == draw_watts ? draw_watts : 0) + surplus;
                    if (budget_watts <= 0)
                    {
                        record_decision(energy_device, p, "no surplus", float.nan, now, &ctx, ctl);
                        continue;
                    }
                    if (ctl.unit == ControlUnit.A)
                    {
                        if (!(ctx.path.voltage > 0))
                        {
                            record_decision(energy_device, p, "no voltage", float.nan, now, &ctx, ctl);
                            continue;
                        }
                        float cap_amps = budget_watts / ctx.path.voltage;
                        float min_amps = ctl.min;
                        if (cap_amps < (min_amps == min_amps ? min_amps : 0))
                        {
                            record_decision(energy_device, p, "no surplus", float.nan, now, &ctx, ctl);
                            continue;
                        }
                        if (setpoint.normalise().value > cap_amps)
                        {
                            setpoint = Amps(cap_amps);
                            reason = "drive (surplus-limited)";
                        }
                    }
                    else if (ctl.unit == ControlUnit.W)
                    {
                        float min_watts = ctl.min;
                        if (budget_watts < (min_watts == min_watts ? min_watts : 0))
                        {
                            record_decision(energy_device, p, "no surplus", float.nan, now, &ctx, ctl);
                            continue;
                        }
                        if (setpoint.normalise().value > budget_watts)
                        {
                            setpoint = Watts(budget_watts);
                            reason = "drive (surplus-limited)";
                        }
                    }
                    else if (ctl.unit == ControlUnit.boolean)
                    {
                        float nameplate = ctl.nameplate_power;
                        if (nameplate == nameplate && nameplate > budget_watts)
                        {
                            record_decision(energy_device, p, "no surplus", float.nan, now, &ctx, ctl);
                            continue;
                        }
                    }
                }

                if (ctl.unit == ControlUnit.A)
                {
                    float headroom = ctx.available_headroom_amps;
                    if (headroom == headroom && setpoint.normalise().value > headroom)
                    {
                        float min_amps = ctl.min;
                        if (headroom < (min_amps == min_amps ? min_amps : 0))
                        {
                            record_decision(energy_device, p, "no path headroom", float.nan, now, &ctx, ctl);
                            continue;
                        }
                        setpoint = Amps(headroom);
                        reason = "drive (headroom-clamped)";
                    }
                }
                else if (ctl.unit == ControlUnit.W)
                {
                    float headroom = ctx.available_headroom_watts;
                    if (headroom == headroom && setpoint.normalise().value > headroom)
                    {
                        float min_watts = ctl.min;
                        if (headroom < (min_watts == min_watts ? min_watts : 0))
                        {
                            record_decision(energy_device, p, "no path headroom", float.nan, now, &ctx, ctl);
                            continue;
                        }
                        setpoint = Watts(headroom);
                        reason = "drive (headroom-clamped)";
                    }
                }
                else if (ctl.unit == ControlUnit.boolean && would_exceed_path_headroom(*ctl, ctx))
                {
                    record_decision(energy_device, p, "no path headroom", float.nan, now, &ctx, ctl);
                    continue;
                }
                // Quantisation prevents meter jitter from churning the actuator.
                if (ctl.unit == ControlUnit.A || ctl.unit == ControlUnit.W)
                {
                    float step = ctl.step;
                    if (step == step && step > 0)
                    {
                        float v = cast(float)setpoint.normalise().value;
                        float q = cast(float)(cast(long)(v / step) * step);
                        if (q != v)
                            setpoint = ctl.unit == ControlUnit.A ? VarQuantity(Amps(q)) : VarQuantity(Watts(q));
                    }
                }
                float commanded = cast(float)setpoint.normalise().value;
                const(char)[] block_drive = setpoint_change_block_reason(*ctl, commanded, mt);
                if (block_drive.length != 0)
                {
                    record_decision(energy_device, p, block_drive, float.nan, now, &ctx, ctl);
                    continue;
                }
                drive_control(*ctl, setpoint, now, mt);
                reserve_path_commitment(commitments, ctx, estimated_control_amps(*ctl, ctx, commanded));
                if (p.tier == PolicyTier.opportunistic)
                {
                    float commanded_watts = commanded_watts_for(*ctl, ctx, commanded);
                    float increase = commanded_watts - (draw_watts == draw_watts ? draw_watts : 0);
                    if (increase == increase && increase > 0)
                        consume_surplus(surplus_pools, ctx.path.source_bus, increase);
                }
                record_decision(energy_device, p, reason, commanded, now, &ctx, ctl);
                driven ~= ctl;
                break;
            case expression:
                // A queued expression is false, so drive until it becomes true.
                // TODO: boolean expressions cannot describe a proportional setpoint.
                const(char)[] block_expr = setpoint_change_block_reason(*ctl, 1, mt);
                if (block_expr.length != 0)
                {
                    record_decision(energy_device, p, block_expr, float.nan, now, &ctx, ctl);
                    continue;
                }
                if (would_exceed_path_headroom(*ctl, ctx))
                {
                    record_decision(energy_device, p, "no path headroom", float.nan, now, &ctx, ctl);
                    continue;
                }
                float expr_cmd = drive_control(*ctl, ctl.max_q, now, mt);
                reserve_path_commitment(commitments, ctx, estimated_control_amps(*ctl, ctx, expr_cmd));
                record_decision(energy_device, p, "expression", expr_cmd, now, &ctx, ctl);
                driven ~= ctl;
                break;
        }
        registry.settle_dispatch(ctl);
        if (goal != GoalKind.off)
            ctl.command_policy = p.id;
    }

    MonoTime mt_release = getTime();
    foreach (ref ctl; registry.by_owner.values)
    {
        if (ctl.current_setpoint != ctl.current_setpoint)
            continue;
        if (control_already_driven(driven, &ctl))
            continue;
        release_control(ctl, now, mt_release);
    }
    foreach (ref ctl; registry.by_target.values)
    {
        if (ctl.current_setpoint != ctl.current_setpoint)
            continue;
        if (control_already_driven(driven, &ctl))
            continue;
        release_control(ctl, now, mt_release);
    }
}


private:

struct PathCommitment
{
    Link* link;
    float amps;
}

// Opportunistic policies consume each source bus's export in rank order.
struct SurplusPool
{
    Bus* bus;
    float remaining;
}

float surplus_remaining(ref Array!SurplusPool pools, Bus* source)
{
    if (source is null)
        return float.nan;
    foreach (ref sp; pools[])
        if (sp.bus is source)
            return sp.remaining;
    float export_watts = bus_export_watts(source);
    pools ~= SurplusPool(source, export_watts);
    return export_watts;
}

void consume_surplus(ref Array!SurplusPool pools, Bus* source, float watts)
{
    if (source is null || watts != watts || watts <= 0)
        return;
    foreach (ref sp; pools[])
    {
        if (sp.bus is source)
        {
            sp.remaining = sp.remaining > watts ? sp.remaining - watts : 0;
            return;
        }
    }
}

// Keep import negative so it actively reduces an opportunistic load's entitlement.
float bus_export_watts(Bus* bus)
{
    if (bus is null)
        return float.nan;
    foreach (p; bus.ports[])
    {
        if (p.role != PortRole.grid)
            continue;
        if (!p.meter_data.has(MeterField.power) || p.meter_data.is_inferred(MeterField.power))
            return float.nan;
        return -p.meter_data.active[0].value;
    }
    return float.nan;
}

float appliance_draw_watts(ref TopologyGraph graph, Appliance target, bool witness_only = false)
{
    if (target is null)
        return float.nan;
    foreach (p; graph.ports[])
    {
        if (p.owner !is target || p.bus is null || !p.meter_data.has(MeterField.power))
            continue;
        float power = p.meter_data.active[0].value;
        if (!witness_only)
            return absf(power);
        if (!p.meter_data.is_inferred(MeterField.power) && power > 0)
            return power;
    }
    return float.nan;
}

float commanded_watts_for(ref const Control ctl, ref AllocationContext ctx, float commanded)
{
    final switch (ctl.unit) with (ControlUnit)
    {
        case A:
            if (ctx.path.voltage == ctx.path.voltage && ctx.path.voltage > 0)
                return commanded * ctx.path.voltage;
            return float.nan;
        case W:
            return commanded;
        case boolean:
            return commanded > 0 ? ctl.nameplate_power : 0;
        case percent:
        case nameplate_fraction:
            return ctl.nameplate_power * commanded;
        case unknown:
            return float.nan;
    }
}

struct AllocationContext
{
    ControlPath path;
    float available_headroom_amps = float.nan;
    float available_headroom_watts = float.nan;
    float committed_amps = float.nan;
    float committed_watts = float.nan;
    bool current_lost;
}

const(char)[] no_control_reason(Appliance target)
{
    if (target !is null && (target.kind == "car" || target.kind == "vehicle" || target.vin.length != 0))
        return "not connected";
    return "no control";
}

bool control_already_driven(ref Array!(Control*) driven, Control* ctl)
{
    if (ctl is null)
        return false;
    foreach (d; driven[])
    {
        if (d is ctl)
            return true;
        if (d !is null && d.setpoint_e !is null && d.setpoint_e is ctl.setpoint_e)
            return true;
    }
    return false;
}

bool would_exceed_path_headroom(ref const Control ctl, ref AllocationContext ctx)
{
    float nameplate = ctl.nameplate_power;
    if (nameplate != nameplate || nameplate <= 0)
        return false;
    float headroom = ctx.available_headroom_watts;
    return headroom == headroom && nameplate > headroom;
}

const(char)[] setpoint_change_block_reason(ref const Control ctl, float desired, MonoTime now)
{
    if (!ctl.last_transition)
        return null;
    bool current_nan = ctl.current_setpoint != ctl.current_setpoint;
    if (!current_nan && desired == desired && ctl.current_setpoint == desired)
        return null;

    bool current_on = !current_nan && ctl.current_setpoint > 0;
    bool desired_on = desired == desired && desired > 0;
    Duration elapsed = now - ctl.last_transition;

    if (ctl.min_dwell != Duration.zero && elapsed < ctl.min_dwell)
        return "min dwell";
    if (current_on && !desired_on && ctl.min_on_time != Duration.zero && elapsed < ctl.min_on_time)
        return "min on time";
    if (!current_on && desired_on && ctl.min_off_time != Duration.zero && elapsed < ctl.min_off_time)
        return "min off time";
    if (!current_on && desired_on && ctl.max_cycles_per_hour > 0 && ctl.last_on != MonoTime.init
        && now - ctl.last_on < dur!"seconds"(3600 / ctl.max_cycles_per_hour))
        return "max cycles";
    return null;
}

void refresh_available_headroom(ref AllocationContext ctx, ref Array!PathCommitment commitments)
{
    ctx.available_headroom_amps = float.nan;
    ctx.available_headroom_watts = float.nan;
    ctx.committed_amps = float.nan;
    ctx.committed_watts = float.nan;
    ctx.current_lost = false;

    float min_headroom = float.infinity;
    bool any;
    foreach (link; ctx.path.links[])
    {
        float current;
        float headroom = link_headroom_amps(link, current);
        if (headroom != headroom)
        {
            if (!ctx.current_lost && current != current && link && link.capacity_amps != 0 &&
                link_has_current_meter(link))
                ctx.current_lost = true;
            continue;
        }
        headroom -= committed_amps_for(link, commitments);
        if (headroom != headroom)
            continue;
        if (headroom < min_headroom)
            min_headroom = headroom;
        any = true;
    }

    if (!any)
        return;

    ctx.available_headroom_amps = min_headroom;
    if (ctx.path.voltage == ctx.path.voltage && ctx.path.voltage > 0)
        ctx.available_headroom_watts = min_headroom * ctx.path.voltage;
}

float committed_amps_for(Link* link, ref Array!PathCommitment commitments)
{
    float total = 0;
    foreach (ref c; commitments[])
        if (c.link is link)
            total += c.amps;
    return total;
}

float estimated_control_amps(ref const Control ctl, ref AllocationContext ctx, float commanded)
{
    final switch (ctl.unit) with (ControlUnit)
    {
        case A:
            return commanded;
        case W:
            return watts_to_path_amps(commanded, ctx);
        case boolean:
            if (commanded <= 0)
                return 0;
            return watts_to_path_amps(ctl.nameplate_power, ctx);
        case percent:
        case nameplate_fraction:
            if (ctl.nameplate_power != ctl.nameplate_power)
                return float.nan;
            return watts_to_path_amps(ctl.nameplate_power * commanded, ctx);
        case unknown:
            return float.nan;
    }
}

float watts_to_path_amps(float watts, ref AllocationContext ctx)
{
    if (watts != watts || ctx.path.voltage != ctx.path.voltage || ctx.path.voltage <= 0)
        return float.nan;
    return watts / ctx.path.voltage;
}

void reserve_path_commitment(ref Array!PathCommitment commitments, ref AllocationContext ctx, float amps)
{
    if (amps != amps || amps <= 0)
        return;
    foreach (link; ctx.path.links[])
        add_commitment(commitments, link, amps);
    ctx.committed_amps = amps;
    if (ctx.path.voltage == ctx.path.voltage && ctx.path.voltage > 0)
        ctx.committed_watts = amps * ctx.path.voltage;
}

void add_commitment(ref Array!PathCommitment commitments, Link* link, float amps)
{
    if (link is null)
        return;
    foreach (ref c; commitments[])
    {
        if (c.link !is link)
            continue;
        c.amps += amps;
        return;
    }

    PathCommitment c;
    c.link = link;
    c.amps = amps;
    commitments ~= c;
}

// Preserve the actuator's unit so its handler can convert to the native scale.
VarQuantity unit_quantity(ref Control ctl, double value)
{
    const(Element)*[3] refs = [ctl.setpoint_e, ctl.max_e, ctl.min_e];
    foreach (e; refs)
    {
        if (e !is null && e.value.isNumber)
        {
            VarQuantity q = e.value.asQuantity();
            q.value = value;
            return q;
        }
    }
    return VarQuantity(value);
}

float drive_control(ref Control ctl, VarQuantity value, SysTime now, MonoTime mt)
{
    bool was_on = ctl.current_setpoint > 0;
    if (ctl.enable_e !is null)
        ctl.enable_e.value(true, now);
    float commanded = 1;
    ctl.setpoint_written = ctl.setpoint_e !is null && value.value == value.value;
    if (ctl.setpoint_written)
    {
        ctl.setpoint_e.value(value, now);
        commanded = cast(float)value.normalise().value;
    }
    if (!was_on)
        ctl.last_on = mt;
    ctl.current_setpoint = commanded;
    ctl.last_transition = mt;
    return commanded;
}

// Compare normalised quantities so scaled storage does not cause a redundant write.
bool setpoint_already(ref const Control ctl, VarQuantity target)
{
    const(Element)* e = ctl.setpoint_e;
    if (e is null || !e.value.isNumber)
        return false;
    double have = e.normalised_value();
    double want = target.normalise().value;
    if (have != have || want != want)
        return false;
    double d = have - want;
    return (d < 0 ? -d : d) <= 1e-6;
}

float release_control(ref Control ctl, SysTime now, MonoTime mt)
{
    ctl.setpoint_written = false;
    if (ctl.setpoint_e is null && ctl.enable_e is null)
    {
        ctl.current_setpoint = float.nan;
        ctl.command_policy = CID.init;
        return float.nan;
    }
    if (setpoint_change_block_reason(ctl, 0, mt).length != 0)
        return float.nan;

    float left_at = 0;
    bool wrote;
    if (ctl.enable_e !is null)
    {
        const(Element)* e = ctl.enable_e;
        if (!e.value.isBool || e.value.asBool)
        {
            ctl.enable_e.value(false, now);
            wrote = true;
        }
    }
    if (ctl.setpoint_e !is null)
    {
        VarQuantity mn = ctl.min_q;
        bool has_min = mn.value == mn.value;
        VarQuantity target;
        bool have_target;
        if (ctl.enable_e is null && ctl.can_disable)
        {
            target = unit_quantity(ctl, 0);
            have_target = true;
        }
        else if (has_min)
        {
            target = mn;
            have_target = true;
            // Without an enable, the minimum is still real consumption.
            if (ctl.enable_e is null)
                left_at = cast(float)mn.normalise().value;
        }
        else if (ctl.enable_e is null)
        {
            // TODO: a per-control off_action could disable an otherwise
            // uncontrollable binding, such as dropping a TWC heartbeat.
            left_at = float.nan;
        }
        if (have_target && !setpoint_already(ctl, target))
        {
            ctl.setpoint_e.value(target, now);
            ctl.setpoint_written = true;
            wrote = true;
        }
    }
    // This tracks allocator ownership, not the actuator's observed value.
    ctl.current_setpoint = float.nan;
    ctl.command_policy = CID.init;
    // An unsatisfiable off policy re-enters the allocator; only a real change
    // may restart dwell.
    if (wrote)
        ctl.last_transition = mt;
    return left_at;
}

void record_decision(Device energy_device, Policy p, const(char)[] reason, float commanded, SysTime now, const(AllocationContext)* ctx = null, const(Control)* ctl = null)
{
    import urt.meta.enuminfo : enum_key_from_value;

    if (energy_device is null || p is null)
        return;
    p.publish_as(p.name[]);
    const(char)[] base = tconcat("allocation.", p.name[], ".");

    void put(T)(DecisionField f, auto ref T value)
        => p.decision[f].write(energy_device, tconcat(base, enum_key_from_value!DecisionField(f)), value, now);

    put(DecisionField.reason, reason);
    put(DecisionField.target, p.target);
    put(DecisionField.via, (ctl !is null && ctl.partner !is null ? ctl.partner.name[] : "").make_string());
    put(DecisionField.device, (ctl !is null && ctl.device !is null ? ctl.device.id[] : "").make_string());
    if (commanded == commanded)
        put(DecisionField.commanded, commanded);
    if (ctx !is null && ctx.path.target_bus !is null)
    {
        put(DecisionField.target_bus, ctx.path.target_bus.id);
        put(DecisionField.source_bus, (ctx.path.source_bus ? ctx.path.source_bus.id[] : "").make_string());
        put(DecisionField.path_complete, ctx.path.complete);
        put(DecisionField.path_headroom_amps, ctx.path.headroom_amps);
        put(DecisionField.path_headroom_watts, ctx.path.headroom_watts);
        put(DecisionField.available_headroom_amps, ctx.available_headroom_amps);
        put(DecisionField.available_headroom_watts, ctx.available_headroom_watts);
        put(DecisionField.committed_amps, ctx.committed_amps);
        put(DecisionField.committed_watts, ctx.committed_watts);
        put(DecisionField.path_voltage, ctx.path.voltage);
        put(DecisionField.limiting_link, (ctx.path.limiting_link ? ctx.path.limiting_link.id[] : "").make_string());
    }
}


unittest
{
    import urt.log : LogMessage, register_log_sink, unregister_log_sink;
    import urt.si.quantity : Quantity;
    import urt.si.unit : Percent;
    import apps.energy.meter : Provenance;

    auto appliances = Collection!Appliance();
    Appliance target = appliances.alloc("allocator-test-load");
    appliances.add(target);
    scope(exit)
    {
        appliances.remove(target);
        free(target);
    }

    auto policies = Collection!Policy();
    Policy policy = policies.alloc("allocator-test-policy");
    policies.add(policy);
    scope(exit)
    {
        policy.destroy();
        policies.update_all();
    }
    assert(policy.target(target.name[]) is null);

    DeviceTable devices;
    auto builder = devices.create("allocator-test");
    Device device = builder.device;
    Element* enable = builder.element("enable", register_value_format!bool());
    Element* setpoint = builder.element("setpoint", register_value_format!Watts());
    Element* max_e = builder.element("max", register_value_format!Watts());
    Element* unit = builder.element("unit", register_value_format!string());
    alias Soc = Quantity!(float, Percent);
    Element* soc = builder.element("soc", register_value_format!Soc());
    Component meter = builder.component("breaker-meter", "EnergyMeter");
    builder.element(meter, "current1", register_value_format!Amps());
    enable.value(false);
    max_e.value(Watts(1000));
    unit.value("W");
    soc.sampling_mode = SamplingMode.poll;
    builder.commit();

    ControlRegistry registry = alloc!ControlRegistry();
    scope(exit) free(registry);
    Control setup;
    setup.enable_e = enable;
    setup.setpoint_e = setpoint;
    setup.max_e = max_e;
    setup.unit_e = unit;
    setup.state_e = soc;
    registry.by_owner.replace(target.id, setup.move);
    Control* ctl = registry.lookup(target);

    TopologyGraph graph;
    scope(exit) graph.clear();
    Bus* source = graph.ensure_bus("source");
    source.contains_grid = true;
    Bus* load = graph.ensure_bus("load");
    Port* grid = graph.add_port(null, source, PortRole.grid, FlowDomain.bidirectional, null, 0);
    Port* load_port = graph.add_port(target, load, PortRole.outlet, FlowDomain.consume, null, 0);
    Port* breaker_port = graph.add_port(null, load, PortRole.connection, FlowDomain.bidirectional, null, 0);
    Link* breaker = graph.add_link(null, source, load, null, breaker_port, 20);
    Islands islands;
    Planner planner;

    static void count_warning(void* context, scope ref const LogMessage message)
    {
        if (message.message == "holding command while state is unknown")
            ++*cast(uint*)context;
    }

    uint warnings;
    auto sink = register_log_sink(&count_warning, &warnings);
    scope(exit) unregister_log_sink(sink);

    void tick(const(char)[] expected)
    {
        policies.update_all();
        assert(policy.running);
        run_allocator(device, registry, planner, islands, graph);
        assert(policy.decision[DecisionField.reason].element.text_value() == expected);
    }

    assert(policy.goal("soc(80)") is null);
    policy.tier = PolicyTier.floor;
    tick("state unknown");
    assert(!enable.value.asBool && warnings == 0);
    assert(analyse_policy(policy, registry, getSysTime(), Duration.zero).marginal_value == 0);

    ctl.enable_e = null;
    assert(!setpoint.has_value);
    assert(policy.goal("on") is null);
    tick("on");
    assert(setpoint.has_value && ctl.current_setpoint == 1000);
    ctl.enable_e = enable;

    assert(policy.goal("soc(80)") is null);
    soc.value(Soc(20));
    publish_policy(device, policy, registry);
    assert(policy.published[PolicyField.current_value].element.has_value);
    tick("drive");
    assert(enable.value.asBool && ctl.current_setpoint == 1000);

    SysTime command_time = setpoint.record_update;
    soc.last_update = getSysTime() - dur!"seconds"(181);
    publish_policy(device, policy, registry);
    assert(!policy.published[PolicyField.current_value].element.has_value);
    tick("hold: state unknown");
    tick("hold: state unknown");
    assert(warnings == 1 && setpoint.record_update == command_time && ctl.current_setpoint == 1000);

    soc.value(Soc(21));
    tick("drive");
    soc.last_update = getSysTime() - dur!"seconds"(181);
    tick("hold: state unknown");
    assert(warnings == 2);
    policy.tier = PolicyTier.important;
    tick("state unknown");
    assert(!enable.value.asBool && ctl.current_setpoint != ctl.current_setpoint);
    assert(ctl.command_policy == CID.init);

    policy.tier = PolicyTier.floor;
    Policy other = policies.alloc("allocator-test-other");
    policies.add(other);
    assert(other.target(target.name[]) is null);
    other.tier = PolicyTier.important;
    assert(other.goal("on") is null);
    tick("state unknown");
    assert(ctl.current_setpoint == 1000 && ctl.command_policy == other.id);
    assert(other.goal("off") is null);
    tick("state unknown");
    assert(!enable.value.asBool && ctl.command_policy == CID.init);
    other.destroy();
    policies.update_all();
    policy.tier = PolicyTier.important;

    ctl.state_e = null;
    tick("drive");
    assert(ctl.current_setpoint == 1000);
    ctl.state_e = soc;
    soc.value(Soc(20));
    policy.tier = PolicyTier.opportunistic;
    grid.meter_data.write_value(MeterField.power, 0, -1000);
    grid.meter_data.mark(MeterField.power, 0, Provenance.inferred_subtraction);
    breaker_port.meter = meter;
    load_port.meter_data.write_value(MeterField.power, 0, 400);
    load_port.meter_data.mark(MeterField.power, 0, Provenance.measured);
    command_time = setpoint.record_update;
    tick("hold: no export witness");
    assert(setpoint.record_update == command_time && ctl.current_setpoint == 1000);

    load_port.meter_data.write_value(MeterField.power, 0, 0);
    tick("no export witness");
    assert(!enable.value.asBool && ctl.current_setpoint != ctl.current_setpoint);
    load_port.meter_data.reset_to_missing();
    enable.value(true);
    ctl.current_setpoint = 1000;
    tick("no export witness");
    assert(!enable.value.asBool && ctl.current_setpoint != ctl.current_setpoint);
    enable.value(true);
    ctl.current_setpoint = 1000;
    load_port.meter_data.write_value(MeterField.power, 0, 400);
    load_port.meter_data.mark(MeterField.power, 0, Provenance.inferred_sum);
    tick("no export witness");
    assert(!enable.value.asBool && ctl.current_setpoint != ctl.current_setpoint);
    enable.value(true);
    ctl.current_setpoint = 1000;
    load_port.meter_data.write_value(MeterField.power, 0, -400);
    load_port.meter_data.mark(MeterField.power, 0, Provenance.measured);
    tick("no export witness");
    assert(!enable.value.asBool && ctl.current_setpoint != ctl.current_setpoint);
    load_port.meter_data.reset_to_missing();
    breaker_port.meter = null;

    assert(policy.goal("on") is null);
    tick("no export witness");
    assert(!enable.value.asBool);
    assert(policy.goal("(false)") is null);
    tick("no export witness");
    assert(!enable.value.asBool);
    assert(policy.goal("soc(80)") is null);
    ctl.setpoint_e = null;
    tick("no export witness");
    assert(!enable.value.asBool);
    ctl.setpoint_e = setpoint;

    grid.meter_data.write_value(MeterField.power, 0, 0);
    grid.meter_data.mark(MeterField.power, 0, Provenance.measured);
    SysTime enable_time = enable.record_update;
    tick("no surplus");
    assert(!enable.value.asBool && enable.record_update == enable_time);

    unit.value("A");
    max_e.value(Amps(16));
    grid.meter_data.write_value(MeterField.power, 0, -1000);
    tick("no voltage");
    assert(!enable.value.asBool);

    unit.value("W");
    max_e.value(Watts(1000));
    policy.tier = PolicyTier.important;
    tick("drive");
    assert(ctl.current_setpoint == 1000 && breaker.capacity_amps == 20);
    breaker_port.meter = meter;
    max_e.value(Watts(2000));
    command_time = setpoint.record_update;
    tick("hold: link current unknown");
    assert(ctl.current_setpoint == 1000 && setpoint.record_update == command_time);

    enable.sampling_mode = SamplingMode.poll;
    enable.last_update = getSysTime() - dur!"seconds"(181);
    assert(policy.goal("off") is null);
    tick("off");
    assert(!enable.value.asBool);
    assert(policy.goal("soc(80)") is null);
    tick("link current unknown");
    assert(!enable.value.asBool && ctl.current_setpoint != ctl.current_setpoint);

    enable.value(true);
    ctl.current_setpoint = 1000;
    soc.value(Soc(90));
    policies.update_all();
    run_allocator(device, registry, planner, islands, graph);
    assert(!enable.value.asBool && ctl.current_setpoint != ctl.current_setpoint);
    publish_policy(device, policy, registry);
    assert(policy.published[PolicyField.satisfied].element.value.asBool);
    soc.last_update = getSysTime() - dur!"seconds"(181);
    publish_policy(device, policy, registry);
    assert(!policy.published[PolicyField.satisfied].element.value.asBool);
    assert(!policy.published[PolicyField.current_value].element.has_value);
}
