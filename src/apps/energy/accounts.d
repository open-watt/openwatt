module apps.energy.accounts;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time;
import urt.variant;

import apps.energy.appliance;
import apps.energy.meter;
import apps.energy.topology;

import manager.device;
import manager.element;

nothrow @nogc:


// TODO(0.6, db.Stream): replace with `value_at(source, midnight)` queries when db.Stream lands.
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

void update_accounts(Device energy_device, ref Islands islands, ref TopologyGraph graph, ref DailySnapshot daily)
{
    if (!energy_device)
        return;

    SysTime now = getSysTime();
    check_day_rollover(daily, now);

    DeviceBuilder builder = energy_device.edit();
    daily.account_publishers.resize(islands.length);
    foreach (i, island; islands[])
    {
        ref publisher = daily.account_publishers[i];
        if (!publisher.bound || publisher.id != island.id[])
            publisher.bind(builder, island.id[]);
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
        return double.nan;

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
    float generation_power = float.nan;
    float load_power = float.nan;

    float local_fraction = float.nan;

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
    AccountFloatCell local_fraction;
    AccountFloatCell solar_today_energy;
    AccountFloatCell battery_today_charge;
    AccountFloatCell battery_today_discharge;
    AccountFloatCell grid_today_import;
    AccountFloatCell grid_today_export;

    void bind(ref DeviceBuilder builder, const(char)[] island_id)
    {
        id = island_id.make_string();
        mode.bind(account_element!String(builder, island_id, "mode"));
        members.bind(account_element!String(builder, island_id, "members"));
        solar_power.bind(account_element!float(builder, island_id, "account.solar.power"));
        battery_power.bind(account_element!float(builder, island_id, "account.battery.power"));
        grid_power.bind(account_element!float(builder, island_id, "account.grid.power"));
        rogue_generation_power.bind(account_element!float(builder, island_id, "account.rogue.generation.power"));
        rogue_load_power.bind(account_element!float(builder, island_id, "account.rogue.load.power"));
        generation_power.bind(account_element!float(builder, island_id, "account.generation.power"));
        load_power.bind(account_element!float(builder, island_id, "account.load.total.power"));
        local_fraction.bind(account_element!float(builder, island_id, "account.local_fraction"));
        solar_today_energy.bind(account_element!float(builder, island_id, "account.solar.today.energy"));
        battery_today_charge.bind(account_element!float(builder, island_id, "account.battery.today.charge"));
        battery_today_discharge.bind(account_element!float(builder, island_id, "account.battery.today.discharge"));
        grid_today_import.bind(account_element!float(builder, island_id, "account.grid.today.import"));
        grid_today_export.bind(account_element!float(builder, island_id, "account.grid.today.export"));
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
            publish_float(element, value, ts);
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
            String s = value.make_string();
            element.value(s, ts);
            last = s;
            seen = true;
        }
    }
}

Element* account_element(T)(ref DeviceBuilder builder, const(char)[] island_id, const(char)[] path)
{
    return builder.element(tconcat("islands.", island_id, ".", path), register_value_format!T());
}


void update_island_accounts(ref IslandAccountPublisher publisher, Island* island, ref TopologyGraph graph, ref DailySnapshot daily, SysTime ts)
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
    publisher.local_fraction.publish(t.local_fraction, ts);

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
        if (b is null || !island_contains(island, b))
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

    add_island_rogue(t, island);
    bool[BoundaryKind.max + 1] missing_power;
    complete_boundary_totals(t, island, graph, daily, missing_power);
    if (missing_power[BoundaryKind.grid])
        t.grid_power = float.nan;
    if (missing_power[BoundaryKind.solar])
        t.solar_power = float.nan;
    if (missing_power[BoundaryKind.battery])
        t.battery_power = float.nan;
    if (missing_power[BoundaryKind.generator])
        generator_power = float.nan;
    if (missing_power[BoundaryKind.unclassified])
        t.rogue_generation_power = t.rogue_load_power = float.nan;

    // Interior PV can require daily reconciliation without a solar boundary.
    foreach (p; graph.ports[])
        if (p.role == PortRole.pv && island_contains(island, boundary_bus(p)))
        {
            t.solar_today_kwh = double.nan;
            break;
        }

    // Keep grid separate so load = generation + grid before the zero clamp.
    t.generation_power = t.solar_power + generator_power + t.battery_power + t.rogue_generation_power;
    t.load_power = t.generation_power + t.grid_power;
    if (t.load_power < 0)
        t.load_power = 0;

    // Battery discharge counts as local regardless of what charged it; when
    // exporting, consumption is fully locally served.
    if (t.load_power > 0)
    {
        float f = t.generation_power / t.load_power;
        t.local_fraction = f < 0 ? 0 : (f > 1 ? 1 : f);
    }

    return t;
}

void complete_boundary_totals(ref IslandTotals t, Island* island, ref TopologyGraph graph,
                              ref DailySnapshot daily, ref bool[BoundaryKind.max + 1] missing_power)
{
    foreach (p; graph.boundaries[])
    {
        Bus* b = boundary_bus(p);
        if (b is null || !island_contains(island, b))
            continue;
        BoundaryKind kind = boundary_kind(p);
        if (!p.meter_data.has(MeterField.power))
            missing_power[kind] = true;
        BoundaryEnergy e = boundary_energy(p);
        final switch (kind)
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
                t.solar_today_kwh = double.nan;
                break;
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

bool island_contains(Island* island, Bus* bus)
{
    foreach (b; island.members[])
        if (b is bus)
            return true;
    return false;
}

unittest
{
    TopologyGraph graph;
    scope(exit) graph.clear();
    Bus* site = graph.ensure_bus("site");
    Island island;
    island.id = StringLit!"site";
    island.root = site;
    island.members ~= site;
    DailySnapshot daily;

    DeviceTable devices;
    auto builder = devices.create("accounts-test");
    auto publisher = IslandAccountPublisher();
    publisher.bind(builder, "site");
    SysTime now = getSysTime();
    check_day_rollover(daily, now);
    update_island_accounts(publisher, &island, graph, daily, now);
    assert(publisher.solar_power.element.has_value && publisher.solar_power.element.value.asFloat == 0);
    assert(publisher.load_power.element.has_value && publisher.load_power.element.value.asFloat == 0);
    assert(publisher.solar_today_energy.element.has_value && publisher.solar_today_energy.element.value.asFloat == 0);

    Port* solar = graph.add_port(null, site, PortRole.pv, FlowDomain.supply, null, 0, MeterSign.normal, "mppt", "inverter");
    Port* grid = graph.add_port(null, site, PortRole.grid, FlowDomain.bidirectional, null, 0);
    graph.add_to_group(graph.add_group("solar", PortGroupKind.appliance), solar);
    graph.boundaries ~= solar;
    graph.boundaries ~= grid;
    grid.meter_data.write_value(MeterField.power, 0, 100);
    grid.meter_data.mark(MeterField.power, 0, Provenance.measured);
    graph.reduce_boundary_flows();
    update_island_accounts(publisher, &island, graph, daily, now);
    assert(publisher.grid_power.element.value.asFloat == -100);
    assert(!publisher.solar_power.element.has_value);
    assert(!publisher.generation_power.element.has_value);
    assert(!publisher.load_power.element.has_value);
    assert(!publisher.solar_today_energy.element.has_value);
    assert(!publisher.grid_today_import.element.has_value && !publisher.grid_today_export.element.has_value);
    assert(publisher.battery_power.element.has_value && publisher.battery_power.element.value.asFloat == 0);

    solar.meter_data.write_value(MeterField.power, 0, -150);
    solar.meter_data.mark(MeterField.power, 0, Provenance.inferred_subtraction);
    graph.reduce_boundary_flows();
    update_island_accounts(publisher, &island, graph, daily, now);
    assert(publisher.solar_power.element.value.asFloat == 150);
    assert(publisher.generation_power.element.value.asFloat == 150);
    assert(publisher.load_power.element.value.asFloat == 50);

    assert(!publisher.solar_today_energy.element.has_value);

    graph.clear();
    island.members.clear();
    Bus* roof = graph.ensure_bus("roof");
    island.root = roof;
    island.members ~= roof;
    Port* input = graph.add_port(null, roof, PortRole.pv, FlowDomain.supply, null, 0);
    Port* output = graph.add_port(null, roof, PortRole.connection, FlowDomain.supply, null, 0);
    PortGroup* inverter = graph.add_group("inverter", PortGroupKind.appliance);
    graph.add_to_group(inverter, input);
    graph.add_to_group(inverter, output);
    graph.rebuild_boundaries();
    assert(graph.boundaries.length == 0);

    IslandAccountPublisher interior;
    interior.bind(builder, "roof");
    update_island_accounts(interior, &island, graph, daily, now);
    assert(!interior.solar_today_energy.element.has_value);
    assert(interior.solar_today_energy.element.record_update == SysTime.init);
}
