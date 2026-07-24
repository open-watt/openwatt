module apps.energy.allocator;

import urt.array;
import urt.lifetime;
import urt.mem : defaultAllocator;
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


void run_allocator(Device energy_device, ControlRegistry registry, ref Planner planner,
                   ref Islands islands, ref TopologyGraph graph)
{
    SysTime now = getSysTime();

    static struct Ranked { Policy p; float mv; }
    Array!Ranked queue;
    foreach (Policy p; Collection!Policy().values)
    {
        if (!p.running)
            continue;
        IslandBudget* b = planner.budget_for_policy(p, islands);
        PolicyAnalysis a = analyse_policy(p, registry, now, planner.slack_threshold, b, &graph);
        if (a.marginal_value > 0)
            queue ~= Ranked(p, a.marginal_value);
    }
    queue.sort!((Ranked a, Ranked b) => a.mv > b.mv);

    Array!(Control*) driven;
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
                record_decision(energy_device, p,
                                off_cmd == off_cmd && off_cmd > 0 ? "off (parked at min)"
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
                float draw_watts = float.nan;
                if (p.tier == PolicyTier.opportunistic)
                {
                    draw_watts = appliance_draw_watts(graph, p.target_appliance);
                    float surplus = surplus_remaining(surplus_pools, ctx.path.source_bus);
                    if (surplus == surplus)
                    {
                        float budget_watts = (draw_watts == draw_watts ? draw_watts : 0) + surplus;
                        if (ctl.unit == ControlUnit.A && ctx.path.voltage == ctx.path.voltage && ctx.path.voltage > 0)
                        {
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
        if (!p.meter_data.has(MeterField.power))
            return float.nan;
        return -p.meter_data.active[0].value;
    }
    return float.nan;
}

float appliance_draw_watts(ref TopologyGraph graph, Appliance target)
{
    if (target is null)
        return float.nan;
    foreach (p; graph.ports[])
        if (p.owner is target && p.meter_data.has(MeterField.power))
            return absf(p.meter_data.active[0].value);
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

    float min_headroom = float.infinity;
    bool any;
    foreach (link; ctx.path.links[])
    {
        float headroom = link_headroom_after_commitments(link, commitments);
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

float link_headroom_after_commitments(Link* link, ref Array!PathCommitment commitments)
{
    float headroom = link_headroom_amps(link);
    if (headroom != headroom)
        return float.nan;
    return headroom - committed_amps_for(link, commitments);
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
    if (ctl.setpoint_e !is null && value.value == value.value)
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
    if (ctl.setpoint_e is null && ctl.enable_e is null)
    {
        ctl.current_setpoint = float.nan;
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
            wrote = true;
        }
    }
    // This tracks allocator ownership, not the actuator's observed value.
    ctl.current_setpoint = float.nan;
    // An unsatisfiable off policy re-enters the allocator; only a real change
    // may restart dwell.
    if (wrote)
        ctl.last_transition = mt;
    return left_at;
}

void record_decision(Device energy_device, Policy p, const(char)[] reason, float commanded,
                     SysTime now, const(AllocationContext)* ctx = null, const(Control)* ctl = null)
{
    if (energy_device is null || p is null)
        return;
    const(char)[] base = tconcat("allocation.", p.name[]);

    energy_device.set_element(tconcat(base, ".reason"), reason, now);
    energy_device.set_element(tconcat(base, ".target"), p.target, now);
    energy_device.set_element(tconcat(base, ".via"),
        (ctl !is null && ctl.partner !is null ? ctl.partner.name[] : "").makeString(defaultAllocator()), now);
    energy_device.set_element(tconcat(base, ".device"),
        (ctl !is null && ctl.device !is null ? ctl.device.id[] : "").makeString(defaultAllocator()), now);
    if (commanded == commanded)
        energy_device.set_element(tconcat(base, ".commanded"), commanded, now);
    if (ctx !is null && ctx.path.target_bus !is null)
    {
        energy_device.set_element(tconcat(base, ".target_bus"),
            ctx.path.target_bus.id[].makeString(defaultAllocator()), now);
        energy_device.set_element(tconcat(base, ".source_bus"),
            (ctx.path.source_bus ? ctx.path.source_bus.id[] : "").makeString(defaultAllocator()), now);
        energy_device.set_element(tconcat(base, ".path_complete"), ctx.path.complete, now);
        energy_device.set_element(tconcat(base, ".path_headroom_amps"), ctx.path.headroom_amps, now);
        energy_device.set_element(tconcat(base, ".path_headroom_watts"), ctx.path.headroom_watts, now);
        energy_device.set_element(tconcat(base, ".available_headroom_amps"), ctx.available_headroom_amps, now);
        energy_device.set_element(tconcat(base, ".available_headroom_watts"), ctx.available_headroom_watts, now);
        energy_device.set_element(tconcat(base, ".committed_amps"), ctx.committed_amps, now);
        energy_device.set_element(tconcat(base, ".committed_watts"), ctx.committed_watts, now);
        energy_device.set_element(tconcat(base, ".path_voltage"), ctx.path.voltage, now);
        energy_device.set_element(tconcat(base, ".limiting_link"),
            (ctx.path.limiting_link ? ctx.path.limiting_link.id[] : "").makeString(defaultAllocator()), now);
    }
}
