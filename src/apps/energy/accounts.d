module apps.energy.accounts;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.si.quantity;
import urt.si.unit;
import urt.string;
import urt.time;
import urt.variant;

import apps.energy.appliance;
import apps.energy.meter;
import apps.energy.production;
import apps.energy.topology;

import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


// TODO(0.6, db.Stream): replace with `value_at(source, midnight)` queries when
// db.Stream lands. The snapshot currently has to follow corrected meter_data so
// daily and live accounts use the same sign and phase conventions.
struct DailyCounter
{
    double anchor = 0;
    double last = 0;
    double carry = 0;
}

struct DailySnapshot
{
nothrow @nogc:
    Map!(Element*, DailyCounter) values;
    Array!IslandAccountPublisher account_publishers;
    SysTime day_start;
}

void update_accounts(Device energy_device, ref Islands islands, ref TopologyGraph graph,
                     ref DailySnapshot daily)
{
    if (!energy_device)
        return;

    SysTime now = getSysTime();
    check_day_rollover(daily, now);

    daily.account_publishers.resize(islands.length);
    foreach (i, island; islands[])
    {
        ref publisher = daily.account_publishers[i];
        if (!publisher.bound || publisher.id != island.id[])
            publisher.bind(energy_device, island.id[]);
        update_island_accounts(publisher, island, graph, daily, now);
    }
}


private:

void check_day_rollover(ref DailySnapshot daily, SysTime now)
{
    TimeOfDay tod = time_of_day(now);
    Duration since_midnight = tod - TimeOfDay(0, 0, 0, 0);
    SysTime today_midnight = now - since_midnight;
    if (daily.day_start < today_midnight)
    {
        daily.values.clear();
        daily.day_start = today_midnight;
    }
}

// Bank completed segments so a meter reset cannot make today's total negative
// or discard energy accumulated before the reset.
double today_delta_value(ref DailySnapshot daily, Element* key, double current)
{
    if (key is null || current != current)
        return 0;

    DailyCounter* c = key in daily.values;
    if (!c)
    {
        daily.values.insert(key, DailyCounter(current, current, 0));
        return 0;
    }
    if (current < c.last)
    {
        c.carry += c.last - c.anchor;
        c.anchor = current;
    }
    c.last = current;
    return c.carry + (current - c.anchor);
}

struct IslandTotals
{
    float solar_power = 0;
    float battery_power = 0;          // positive is discharging
    float grid_power = 0;             // positive is importing
    float rogue_generation_power = 0;
    float rogue_load_power = 0;
    float generation_power = 0;
    float load_power = 0;

    double solar_today_kwh = 0;
    double battery_charge_today_kwh = 0;
    double battery_discharge_today_kwh = 0;
    double grid_import_today_kwh = 0;
    double grid_export_today_kwh = 0;
}

struct IslandAccountPublisher
{
nothrow @nogc:
    bool bound;
    String id;
    AccountStringCell mode;
    AccountStringCell members;
    AccountFloatCell solar_power;
    AccountFloatCell battery_power;
    AccountFloatCell grid_power;
    AccountFloatCell rogue_generation_power;
    AccountFloatCell rogue_load_power;
    AccountFloatCell generation_power;
    AccountFloatCell load_power;
    AccountFloatCell solar_today_energy;
    AccountFloatCell battery_today_charge;
    AccountFloatCell battery_today_discharge;
    AccountFloatCell grid_today_import;
    AccountFloatCell grid_today_export;

    void bind(Device energy_device, const(char)[] island_id)
    {
        id = island_id.makeString(defaultAllocator());
        mode.bind(account_element!String(energy_device, island_id, "mode"));
        members.bind(account_element!String(energy_device, island_id, "members"));
        solar_power.bind(account_element!float(energy_device, island_id, "account.solar.power"));
        battery_power.bind(account_element!float(energy_device, island_id, "account.battery.power"));
        grid_power.bind(account_element!float(energy_device, island_id, "account.grid.power"));
        rogue_generation_power.bind(account_element!float(energy_device, island_id, "account.rogue.generation.power"));
        rogue_load_power.bind(account_element!float(energy_device, island_id, "account.rogue.load.power"));
        generation_power.bind(account_element!float(energy_device, island_id, "account.generation.power"));
        load_power.bind(account_element!float(energy_device, island_id, "account.load.total.power"));
        solar_today_energy.bind(account_element!float(energy_device, island_id, "account.solar.today.energy"));
        battery_today_charge.bind(account_element!float(energy_device, island_id, "account.battery.today.charge"));
        battery_today_discharge.bind(account_element!float(energy_device, island_id, "account.battery.today.discharge"));
        grid_today_import.bind(account_element!float(energy_device, island_id, "account.grid.today.import"));
        grid_today_export.bind(account_element!float(energy_device, island_id, "account.grid.today.export"));
        bound = true;
    }
}

struct AccountFloatCell
{
nothrow @nogc:
    Element* element;
    float last;
    bool seen;

    void bind(Element* e)
    {
        element = e;
        seen = false;
    }

    void publish(float value, SysTime ts)
    {
        if (!seen || !same_float(value, last))
        {
            element.value(value, ts);
            last = value;
            seen = true;
        }
    }
}

struct AccountStringCell
{
nothrow @nogc:
    Element* element;
    String last;
    bool seen;

    void bind(Element* e)
    {
        element = e;
        last = null;
        seen = false;
    }

    void publish(const(char)[] value, SysTime ts)
    {
        if (!seen || last != value)
        {
            String s = value.makeString(defaultAllocator());
            element.value(s, ts);
            last = s;
            seen = true;
        }
    }
}

Element* account_element(T)(Device energy_device, const(char)[] island_id, const(char)[] path)
{
    return energy_device.find_or_create_element(
        tconcat("islands.", island_id, ".", path), register_value_format!T());
}


void update_island_accounts(ref IslandAccountPublisher publisher, Island* island, ref TopologyGraph graph,
                            ref DailySnapshot daily, SysTime ts)
{
    IslandTotals t = compute_island_totals(island, graph, daily);

    publisher.mode.publish(island_mode_name(island.mode), ts);

    Array!char members_buf;
    foreach (i, b; island.members[])
    {
        if (i > 0)
        members_buf ~= ',';
        members_buf ~= b.id[];
    }
    publisher.members.publish(members_buf[], ts);

    publisher.solar_power.publish(t.solar_power, ts);
    publisher.battery_power.publish(t.battery_power, ts);
    publisher.grid_power.publish(t.grid_power, ts);
    publisher.rogue_generation_power.publish(t.rogue_generation_power, ts);
    publisher.rogue_load_power.publish(t.rogue_load_power, ts);
    publisher.generation_power.publish(t.generation_power, ts);
    publisher.load_power.publish(t.load_power, ts);

    publisher.solar_today_energy.publish(cast(float)t.solar_today_kwh, ts);
    publisher.battery_today_charge.publish(cast(float)t.battery_charge_today_kwh, ts);
    publisher.battery_today_discharge.publish(cast(float)t.battery_discharge_today_kwh, ts);
    publisher.grid_today_import.publish(cast(float)t.grid_import_today_kwh, ts);
    publisher.grid_today_export.publish(cast(float)t.grid_export_today_kwh, ts);
}

// Every account is a projection of the one boundary reduction: each solved
// boundary edge contributes once, classified by metadata, oriented by shape.
IslandTotals compute_island_totals(Island* island, ref TopologyGraph graph, ref DailySnapshot daily)
{
    IslandTotals t;
    float generator_power = 0;

    foreach (ref f; graph.boundary_flows[])
    {
        Bus* b = boundary_bus(f.port);
        if (b is null || !circuit_in_island(island, b.id[]))
            continue;
        float net = f.power_into_graph - f.power_out_of_graph;
        final switch (f.kind)
        {
            case BoundaryKind.grid:
                t.grid_power += net;
                break;
            case BoundaryKind.solar:
                t.solar_power += net;
                break;
            case BoundaryKind.generator:
                generator_power += net;
                break;
            case BoundaryKind.battery:
                t.battery_power += net;
                break;
            case BoundaryKind.load:
                break;
            case BoundaryKind.unclassified:
                t.rogue_generation_power += f.power_into_graph;
                t.rogue_load_power += f.power_out_of_graph;
                break;
        }
    }

    add_boundary_energy(t, island, graph, daily);

    // Solar daily counters still reconcile through productions: an inferred
    // boundary (implicit pv terminal) has no counter of its own, but its bus's
    // interior mppt meters count the same energy.
    add_production_today(t, graph, island, daily);

    add_island_rogue(t, island);

    // Keep grid separate so load = generation + grid before the zero clamp.
    t.generation_power = t.solar_power + generator_power + t.battery_power + t.rogue_generation_power;

    t.load_power = t.generation_power + t.grid_power;
    if (t.load_power < 0)
        t.load_power = 0;

    return t;
}

void add_boundary_energy(ref IslandTotals t, Island* island, ref TopologyGraph graph, ref DailySnapshot daily)
{
    foreach (p; graph.boundaries[])
    {
        Bus* b = boundary_bus(p);
        if (b is null || !circuit_in_island(island, b.id[]))
            continue;
        BoundaryEnergy e = boundary_energy(p);
        final switch (boundary_kind(p))
        {
            case BoundaryKind.grid:
                t.grid_import_today_kwh += today_delta_value(daily, e.into_key, e.into_total);
                t.grid_export_today_kwh += today_delta_value(daily, e.out_key, e.out_total);
                break;
            case BoundaryKind.battery:
                t.battery_discharge_today_kwh += today_delta_value(daily, e.into_key, e.into_total);
                t.battery_charge_today_kwh += today_delta_value(daily, e.out_key, e.out_total);
                break;
            case BoundaryKind.solar:
            case BoundaryKind.generator:
            case BoundaryKind.load:
            case BoundaryKind.unclassified:
                break;
        }
    }
}

void add_island_rogue(ref IslandTotals t, Island* island)
{
    foreach (bus; island.members[])
    {
        if (bus is island.root)
            continue;
        if (bus.coverage != Coverage.rogue_value && bus.coverage != Coverage.bounded)
            continue;
        if (bus.unaccounted_source_power == bus.unaccounted_source_power)
            t.rogue_generation_power += bus.unaccounted_source_power;
        if (bus.unaccounted_load_power == bus.unaccounted_load_power)
            t.rogue_load_power += bus.unaccounted_load_power;
    }
}

bool production_belongs_to_island(ref const Production production, ref TopologyGraph graph, Island* island)
{
    foreach (ref contribution; graph.production_contributions[])
        if (contribution.owner == production.owner &&
            contribution.group == production.group &&
            circuit_in_island(island, contribution.circuit))
            return true;
    return false;
}

void add_production_today(ref IslandTotals t, ref TopologyGraph graph, Island* island, ref DailySnapshot daily)
{
    foreach (ref production; graph.productions[])
    {
        if (!production_belongs_to_island(production, graph, island))
            continue;

        bool used_aggregate;
        foreach (ref contribution; graph.production_contributions[])
        {
            if (contribution.owner != production.owner || contribution.group != production.group)
                continue;
            if (contribution.kind != ProductionContributionKind.aggregate)
                continue;
            if (contribution.component is null)
                continue;
            Component meter = contribution.component.get_first_component_by_template("EnergyMeter");
            if (meter is null)
                continue;
            Element* import_e = meter.find_element("import");
            if (import_e is null)
                continue;
            t.solar_today_kwh += today_delta_value(daily, import_e, contribution.meter.total_import_active[0]);
            used_aggregate = true;
        }
        if (used_aggregate)
            continue;

        foreach (ref contribution; graph.production_contributions[])
        {
            if (contribution.owner != production.owner || contribution.group != production.group)
                continue;
            if (!circuit_in_island(island, contribution.circuit))
                continue;
            if (contribution.component)
                if (Component meter = contribution.component.get_first_component_by_template("EnergyMeter"))
                    t.solar_today_kwh += today_delta_value(daily, meter.find_element("import"),
                                                           contribution.meter.total_import_active[0]);
        }
    }
}

bool circuit_in_island(Island* island, const(char)[] circuit)
{
    foreach (b; island.members[])
        if (b.id[] == circuit)
            return true;
    return false;
}
