module apps.energy.planner;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time;

import apps.energy.appliance;
import apps.energy.battery_store;
import apps.energy.control;
import apps.energy.forecast;
import apps.energy.meter;
import apps.energy.policy;
import apps.energy.topology;
import apps.energy.vehicle;

import manager;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


// Slow strategic loop (Phase 3). Sits behind the per-tick allocator and computes
// inputs the allocator can use to make better-informed decisions: slack-aware
// marginal values, reserve targets, pressure scopes.
//
// v0.1 scope: slack-aware marginal_value for policies where the math is
// well-defined (duty, soc with known battery capacity). Publishes per-policy
// analysis to energy.policy.<name>.planner.* for inspection; the allocator also
// uses the same analysis to order policies.
struct Planner
{
nothrow @nogc:

    Duration cadence = dur!"minutes"(5);
    Duration slack_threshold = dur!"hours"(4);
    Duration forecast_window = dur!"hours"(12);
    float reserve_safety_factor = 1.25f;

    SupplyForecast supply_forecast;
    DemandForecast demand_forecast;

    SysTime last_tick;

    // Latest per-island budgets, keyed by island.id. Refreshed each slow tick;
    // consumed by analyse_policy() (pressure modifier on opportunistic) and the
    // allocator (via budget_for_policy).
    Map!(const(char)[], IslandBudget) island_budgets;

    void tick(Device energy_device, ControlRegistry registry, ref Islands islands,
              ref TopologyGraph graph, SysTime now)
    {
        if (last_tick != SysTime.init && now - last_tick < cadence)
            return;
        last_tick = now;

        // Refresh per-island budgets (uses analyse_policy without pressure mod,
        // so opportunistic doesn't depend on the very value we're computing).
        island_budgets.clear();
        foreach (island; islands[])
        {
            IslandBudget b = compute_island_budget(island, registry, now, slack_threshold,
                                                   reserve_safety_factor, &graph);
            if (supply_forecast !is null)
                b.forecast_supply_kwh = supply_forecast.expected_kwh(island, now, forecast_window);
            if (demand_forecast !is null)
                b.forecast_demand_kwh = demand_forecast.expected_kwh(island, now, forecast_window);
            if (b.forecast_supply_kwh == b.forecast_supply_kwh && b.forecast_demand_kwh == b.forecast_demand_kwh)
                b.forecast_net_kwh = b.forecast_demand_kwh - b.forecast_supply_kwh;
            island_budgets.insert(island.id[], b);
            publish_island_budget(energy_device, island, b, now);
        }

            foreach (Policy p; Collection!Policy().values)
        {
            IslandBudget* b = budget_for_policy(p, islands);
            PolicyAnalysis a = analyse_policy(p, registry, now, slack_threshold, b, &graph);
            publish_analysis(energy_device, p, a, now);
        }
    }

    IslandBudget* budget_for_policy(Policy p, ref Islands islands)
    {
        Island* island = find_policy_island_in(p, islands);
        if (island is null)
            return null;
        return island.id[] in island_budgets;
    }
}


struct IslandBudget
{
nothrow @nogc:
    float battery_available_kwh = 0;
    float battery_capacity_kwh = 0;
    float demand_floor_kwh = 0;
    float demand_essential_kwh = 0;
    float demand_important_kwh = 0;
    float demand_opportunistic_kwh = 0;
    float reserve_kwh = 0;
    float pressure = float.nan;
    float forecast_supply_kwh = float.nan;
    float forecast_demand_kwh = float.nan;
    float forecast_net_kwh = float.nan;
}


struct PolicyAnalysis
{
nothrow @nogc:
    float marginal_value = float.nan;
    float required_kwh = float.nan;
    float max_rate_kw = float.nan;
    Duration time_to_deadline;
    Duration time_to_satisfy;
    Duration slack;
    bool slack_known;
}


IslandBudget compute_island_budget(Island* island, ControlRegistry registry, SysTime now,
                                   Duration slack_threshold, float safety_factor,
                                   TopologyGraph* graph = null)
{
    IslandBudget b;
    if (island is null)
        return b;

    if (graph is null || !sum_battery_stores(island, *graph, b))
    {
        Array!Appliance seen;
        foreach (bus; island.members[])
        {
            foreach (port; bus.ports[])
            {
                Appliance owner = port.owner;
                if (owner is null || seen[].findFirst(owner) < seen.length)
                    continue;
                seen ~= owner;
                sum_batteries(owner.device_ref, b);
            }
        }
    }

    foreach (Policy p; Collection!Policy().values)
    {
        Island* pi = find_policy_island(p, island.id[].length == 0 ? null : island);
        if (pi !is island)
            continue;
        PolicyAnalysis pa = analyse_policy(p, registry, now, slack_threshold, null, graph);
        float req = pa.required_kwh;
        if (req != req || req <= 0)
            continue;
        final switch (p.tier) with (PolicyTier)
        {
            case floor:         b.demand_floor_kwh += req;         break;
            case essential:     b.demand_essential_kwh += req;     break;
            case important:     b.demand_important_kwh += req;     break;
            case opportunistic: b.demand_opportunistic_kwh += req; break;
        }
    }

    b.reserve_kwh = (b.demand_floor_kwh + b.demand_essential_kwh) * safety_factor;

    if (b.demand_opportunistic_kwh > 0)
        b.pressure = (b.battery_available_kwh - b.reserve_kwh) / b.demand_opportunistic_kwh;
    return b;
}


PolicyAnalysis analyse_policy(Policy p, ControlRegistry registry, SysTime now, Duration slack_threshold,
                              const(IslandBudget)* budget = null, TopologyGraph* graph = null)
{
    PolicyAnalysis a;

    Control* ctl = registry !is null ? registry.lookup(p.target_appliance) : null;

    if (satisfied(p, ctl))
    {
        a.marginal_value = 0;
        return a;
    }

    float base;
    bool slack_applies;
    final switch (p.tier) with (PolicyTier)
    {
        case floor:
            a.marginal_value = float.infinity;
            return a;
        case essential:
            base = 0.8f;
            slack_applies = true;
            break;
        case important:
            base = 0.5f;
            slack_applies = true;
            break;
        case opportunistic:
            a.marginal_value = 0.2f * pressure_modifier(budget);
            return a;
    }

    a.marginal_value = base;

    if (!slack_applies)
        return a;

    a.max_rate_kw = (ctl !is null) ? control_max_rate_kw(*ctl, p.target_appliance, graph) : float.nan;
    a.required_kwh = required_energy_kwh(p, ctl, graph);
    a.time_to_deadline = compute_time_to_deadline(p.deadline, now);

    bool have_rate = a.max_rate_kw == a.max_rate_kw && a.max_rate_kw > 0;
    bool have_required = a.required_kwh == a.required_kwh && a.required_kwh > 0;
    bool have_deadline = a.time_to_deadline != Duration.zero;
    if (!have_rate || !have_required || !have_deadline)
        return a;

    double hours = a.required_kwh / a.max_rate_kw;
    a.time_to_satisfy = dur!"seconds"(cast(long)(hours * 3600));
    a.slack = a.time_to_deadline - a.time_to_satisfy;
    a.slack_known = true;

    float slack_seconds = cast(float)a.slack.as!"seconds";
    float threshold_seconds = cast(float)slack_threshold.as!"seconds";
    float slack_norm = threshold_seconds > 0 ? slack_seconds / threshold_seconds : 1;
    float slack_mod;
    if (slack_norm >= 1)
        slack_mod = 1;
    else if (slack_norm <= 0)
        slack_mod = 2;
    else
        slack_mod = 1 + (1 - slack_norm);
    // TODO: cap is hard 2x for past-deadline (slack <= 0). DIP says "boost" but doesn't pick a cap.
    //       Revisit once we see how real policies behave near/past deadlines.

    a.marginal_value = base * slack_mod;
    return a;
}


private:

void sum_batteries(Component target, ref IslandBudget b)
{
    if (target is null)
        return;
    sum_batteries_walk(target, b);
}

void sum_batteries_walk(Component c, ref IslandBudget b)
{
    if (c.template_[] == "Battery")
    {
        float cap = battery_capacity_kwh(c);
        if (cap == cap && cap > 0)
        {
            b.battery_capacity_kwh += cap;
            float soc = float.nan;
            if (Element* soc_e = c.find_element("soc"))
                if (soc_e.value.isNumber)
                    soc = soc_e.value.asFloat;
            if (soc == soc)
                b.battery_available_kwh += cap * soc * 0.01f;
        }
    }
    foreach (sub; c.components[])
        sum_batteries_walk(sub, b);
}

Island* find_policy_island(Policy p, Island* candidate)
{
    if (candidate is null)
        return null;
    Appliance target = p.target_appliance;
    if (target is null)
        return null;
    foreach (bus; candidate.members[])
        foreach (port; bus.ports[])
            if (port.owner is target)
                return candidate;
    return null;
}

Island* find_policy_island_in(Policy p, ref Islands islands)
{
    foreach (island; islands[])
        if (Island* hit = find_policy_island(p, island))
            return hit;
    return null;
}

float pressure_modifier(const(IslandBudget)* budget)
{
    if (budget is null || budget.pressure != budget.pressure)
        return 1.0f;
    float p = budget.pressure;
    if (p >= 1.5f)
        return 1.0f;
    if (p <= 1.0f)
        return 0.0f;
    return (p - 1.0f) / 0.5f;
}

void publish_island_budget(Device energy_device, Island* island, ref const IslandBudget b, SysTime now)
{
    if (energy_device is null || island is null)
        return;
    const(char)[] base = tconcat("islands.", island.id[], ".budget");

    void set_num(string field, float val)
    {
        if (val != val)
            return;
        if (Element* e = energy_device.find_or_create_element(tconcat(base, ".", field)))
            e.value(val, now);
    }

    set_num("battery_available_kwh", b.battery_available_kwh);
    set_num("battery_capacity_kwh", b.battery_capacity_kwh);
    set_num("demand_floor_kwh", b.demand_floor_kwh);
    set_num("demand_essential_kwh", b.demand_essential_kwh);
    set_num("demand_important_kwh", b.demand_important_kwh);
    set_num("demand_opportunistic_kwh", b.demand_opportunistic_kwh);
    set_num("reserve_kwh", b.reserve_kwh);
    if (b.pressure == b.pressure)
        set_num("pressure", b.pressure);
    set_num("forecast_supply_kwh", b.forecast_supply_kwh);
    set_num("forecast_demand_kwh", b.forecast_demand_kwh);
    set_num("forecast_net_kwh", b.forecast_net_kwh);
}


void publish_analysis(Device energy_device, Policy p, ref const PolicyAnalysis a, SysTime now)
{
    if (energy_device is null)
        return;
    const(char)[] base = tconcat("policy.", p.name[], ".planner");

    void set_num(string field, float val)
    {
        if (val != val)
            return;
        if (Element* e = energy_device.find_or_create_element(tconcat(base, ".", field)))
            e.value(val, now);
    }

    set_num("marginal_value", a.marginal_value);
    set_num("required_kwh", a.required_kwh);
    set_num("max_rate_kw", a.max_rate_kw);
    if (a.slack_known)
    {
        set_num("slack_hours", cast(float)a.slack.as!"seconds" / 3600.0f);
        set_num("time_to_deadline_hours", cast(float)a.time_to_deadline.as!"seconds" / 3600.0f);
        set_num("time_to_satisfy_hours", cast(float)a.time_to_satisfy.as!"seconds" / 3600.0f);
    }
}

float required_energy_kwh(Policy p, const Control* ctl, TopologyGraph* graph = null)
{
    final switch (p.parsed_goal.kind) with (GoalKind)
    {
        case none, on, off, temp, expression:
            return float.nan;
        case soc:
            float current = current_value(p, ctl);
            float goal = p.parsed_goal.arg;
            if (current != current || current >= goal)
                return 0;
            float capacity_kwh = appliance_battery_capacity_kwh(p.target_appliance, graph);
            if (capacity_kwh != capacity_kwh)
                return float.nan;
            return (goal - current) * 0.01f * capacity_kwh;
        case duty:
            float remaining_seconds = cast(float)p.parsed_goal.arg_duration.as!"seconds" - current_value(p, ctl);
            if (remaining_seconds <= 0)
                return 0;
            if (ctl is null)
                return float.nan;
            float rate_kw = control_max_rate_kw(*ctl, p.target_appliance, graph);
            if (rate_kw != rate_kw)
                return float.nan;
            return rate_kw * remaining_seconds / 3600.0f;
    }
}

float control_max_rate_kw(ref const Control ctl, Appliance target = null, TopologyGraph* graph = null)
{
    float np = ctl.nameplate_power;
    if (np == np && np > 0)
        return np * 0.001f;
    final switch (ctl.unit) with (ControlUnit)
    {
        case W:
            float mx = ctl.max;
            return (mx == mx && mx > 0) ? mx * 0.001f : float.nan;
        case A:
            float mx = ctl.max;
            float volts = control_path_voltage(target, graph);
            return (mx == mx && mx > 0 && volts == volts && volts > 0) ? mx * volts * 0.001f : float.nan;
        case percent, nameplate_fraction, boolean, unknown:
            // TODO: percent/nameplate_fraction can resolve to W given nameplate_power
            return float.nan;
    }
}

float appliance_battery_capacity_kwh(Appliance a, TopologyGraph* graph = null)
{
    if (a is null)
        return float.nan;
    if (graph !is null)
    {
        float graph_capacity = graph_battery_capacity_kwh(a, *graph);
        if (graph_capacity == graph_capacity)
            return graph_capacity;
    }
    Component c = a.device_ref;
    if (c is null && a.vin.length != 0)
        c = vehicle_for(a.vin);
    return battery_capacity_kwh(c);
}

bool sum_battery_stores(Island* island, ref TopologyGraph graph, ref IslandBudget b)
{
    if (island is null)
        return false;
    bool found;
    foreach (ref store; graph.battery_stores[])
    {
        Bus* bus = find_island_bus(island, store.circuit);
        if (bus is null)
            continue;
        float voltage = bus_voltage(bus);
        float cap = battery_store_capacity_kwh(store, voltage);
        if (cap == cap && cap > 0)
        {
            b.battery_capacity_kwh += cap;
            float available = battery_store_available_kwh(store, voltage, cap);
            if (available == available)
                b.battery_available_kwh += available;
            found = true;
        }
    }
    return found;
}

Bus* find_island_bus(Island* island, const(char)[] circuit)
{
    if (island is null)
        return null;
    foreach (bus; island.members[])
        if (bus !is null && bus.id[] == circuit)
            return bus;
    return null;
}

float graph_battery_capacity_kwh(Appliance a, ref TopologyGraph graph)
{
    foreach (p; graph.ports[])
    {
        if (p.owner !is a || p.role != PortRole.battery || p.bus is null)
            continue;
        BatteryStore* store = battery_store_for(graph, p.bus.id[]);
        if (store is null)
            continue;
        float cap = battery_store_capacity_kwh(*store, battery_store_voltage(p));
        if (cap == cap)
            return cap;
    }
    return float.nan;
}

BatteryStore* battery_store_for(ref TopologyGraph graph, const(char)[] circuit)
{
    foreach (ref store; graph.battery_stores[])
        if (store.circuit == circuit)
            return &store;
    return null;
}

float battery_store_capacity_kwh(ref const BatteryStore store, float voltage) pure
{
    if (store.reading.full_capacity != store.reading.full_capacity ||
        voltage != voltage || voltage <= 0)
        return float.nan;
    return store.reading.full_capacity * voltage * 0.001f;
}

float battery_store_available_kwh(ref const BatteryStore store, float voltage, float capacity_kwh) pure
{
    if (store.reading.remain_capacity == store.reading.remain_capacity &&
        voltage == voltage && voltage > 0)
        return store.reading.remain_capacity * voltage * 0.001f;
    if (store.reading.soc == store.reading.soc && capacity_kwh == capacity_kwh)
        return capacity_kwh * store.reading.soc * 0.01f;
    return float.nan;
}

float battery_store_voltage(Port* port)
{
    if (port is null)
        return float.nan;
    float voltage = port.bus !is null ? bus_voltage(port.bus) : float.nan;
    if (voltage == voltage)
        return voltage;
    if (port.meter_data.has(MeterField.voltage))
        return port.meter_data.voltage[0].value;
    return float.nan;
}

float bus_voltage(Bus* bus)
{
    if (bus is null || !bus.balance.has(MeterField.voltage))
        return float.nan;
    return bus.balance.voltage[0].value;
}

float control_path_voltage(Appliance target, TopologyGraph* graph)
{
    if (target is null || graph is null)
        return float.nan;
    ControlPath path;
    graph.build_control_path(target, path);
    return path.voltage;
}

float battery_capacity_kwh(Component target)
{
    if (target is null)
        return float.nan;
    Component battery = (target.template_[] == "Battery")
        ? target
        : target.get_first_component_by_template("Battery");
    if (battery is null)
        return float.nan;
    Element* cap_e = battery.find_element("full_capacity");
    if (cap_e is null || !cap_e.value.isNumber)
        return float.nan;
    float ah = cap_e.value.asFloat;
    // TODO: nominal_voltage element on Battery would be more correct than the live meter reading
    //       (which dips under load). Or full_capacity should declare kWh directly when known.
    Component meter = battery.get_first_component_by_template("EnergyMeter");
    if (meter is null)
        return float.nan;
    Element* v_e = meter.find_element("voltage");
    if (v_e is null || !v_e.value.isNumber)
        return float.nan;
    float voltage = v_e.value.asFloat;
    if (voltage <= 0)
        return float.nan;
    return ah * voltage * 0.001f;
}

Duration compute_time_to_deadline(TimeOfDay deadline, SysTime now)
{
    if (deadline == TimeOfDay.init)
        return Duration.zero;
    TimeOfDay now_tod = time_of_day(now);
    Duration delta = deadline - now_tod;
    if (delta.ticks < 0)
        delta = delta + dur!"hours"(24);
    return delta;
}
