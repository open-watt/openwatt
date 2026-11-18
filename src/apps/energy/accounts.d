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
double counter_delta(ref DailySnapshot daily, Element* key, SysTime now)
{
    double current = read_energy_counter(key, now);
    if (current != current)
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
    IslandTotals t = compute_island_totals(island, graph, daily, ts);

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
IslandTotals compute_island_totals(Island* island, ref TopologyGraph graph, ref DailySnapshot daily,
                                   SysTime now = getSysTime())
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
    complete_boundary_totals(t, island, graph, daily, missing_power, now);
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

    // Interior PV can have daily counters without a solar boundary of its own.
    add_production_today(t, graph, island, daily, now);

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

double boundary_counter_delta(ref DailySnapshot daily, Port* p, bool into_graph, SysTime now)
{
    return counter_delta(daily, port_counter_element(p, into_graph == external_boundary(p)), now);
}

void complete_boundary_totals(ref IslandTotals t, Island* island, ref TopologyGraph graph,
                              ref DailySnapshot daily, ref bool[BoundaryKind.max + 1] missing_power, SysTime now)
{
    foreach (p; graph.boundaries[])
    {
        Bus* b = boundary_bus(p);
        if (b is null || !island_contains(island, b))
            continue;
        BoundaryKind kind = boundary_kind(p);
        if (!p.meter_data.has(MeterField.power))
            missing_power[kind] = true;
        final switch (kind)
        {
            case BoundaryKind.grid:
                t.grid_import_today_kwh += boundary_counter_delta(daily, p, true, now);
                t.grid_export_today_kwh += boundary_counter_delta(daily, p, false, now);
                break;
            case BoundaryKind.battery:
                t.battery_discharge_today_kwh += boundary_counter_delta(daily, p, true, now);
                t.battery_charge_today_kwh += boundary_counter_delta(daily, p, false, now);
                break;
            case BoundaryKind.solar:
                if (!solar_boundary_represented(p, b, graph))
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

bool belongs_to_production(ref const ProductionContribution contribution, ref const Production production)
    => contribution.owner == production.owner && contribution.group == production.group;

bool solar_boundary_represented(Port* p, Bus* bus, ref TopologyGraph graph)
{
    foreach (ref contribution; graph.production_contributions[])
        if (contribution.kind == ProductionContributionKind.member &&
            (p.implicit ? boundary_bus(contribution.port) is bus : contribution.port is p))
            return true;
    if (p.implicit)
        foreach (port; bus.ports[])
            if (unmetered_interior_pv(port))
                return true;
    return false;
}

bool unmetered_interior_pv(Port* p) pure
    => p.role == PortRole.pv && !p.implicit && unmetered_interior(p);

void add_production_today(ref IslandTotals t, ref TopologyGraph graph, Island* island, ref DailySnapshot daily,
                          SysTime now)
{
    // Interior PV ports without meters have no production observation row.
    bool has_unmetered_members;
    foreach (p; graph.ports[])
    {
        if (!unmetered_interior_pv(p))
            continue;
        has_unmetered_members = true;
        if (!island_contains(island, p.bus))
            continue;
        const(char)[] owner = production_owner(p);
        const(char)[] group = production_group(p);
        bool represented;
        foreach (ref production; graph.productions[])
            if (production.owner == owner && production.group == group)
            {
                represented = true;
                break;
            }
        if (!represented)
            t.solar_today_kwh = double.nan;
    }

    foreach (ref production; graph.productions[])
    {
        // A gap in a declared counter must not switch the daily total to a different source.
        bool has_members;
        bool use_members = true;
        bool has_outside_members;
        Element* aggregate;
        foreach (ref contribution; graph.production_contributions[])
        {
            if (!belongs_to_production(contribution, production))
                continue;
            if (contribution.kind == ProductionContributionKind.aggregate)
            {
                aggregate = contribution.import_counter;
                continue;
            }
            if (island_contains(island, boundary_bus(contribution.port)))
            {
                has_members = true;
                use_members &= contribution.import_counter !is null;
            }
            else
                has_outside_members = true;
        }
        if (has_unmetered_members)
            foreach (p; graph.ports[])
            {
                if (!unmetered_interior_pv(p) || production_owner(p) != production.owner ||
                    production_group(p) != production.group)
                    continue;
                if (island_contains(island, p.bus))
                {
                    has_members = true;
                    use_members = false;
                }
                else
                    has_outside_members = true;
            }
        if (!has_members)
            continue;

        if (use_members)
        {
            foreach (ref contribution; graph.production_contributions[])
                if (contribution.kind == ProductionContributionKind.member &&
                    belongs_to_production(contribution, production) &&
                    island_contains(island, boundary_bus(contribution.port)))
                    t.solar_today_kwh += counter_delta(daily, contribution.import_counter, now);
            continue;
        }

        t.solar_today_kwh += counter_delta(daily, has_outside_members ? null : aggregate, now);
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

    ProductionContribution aggregate;
    aggregate.owner = "inverter";
    aggregate.group = "solar";
    aggregate.kind = ProductionContributionKind.aggregate;
    Component aggregate_meter = builder.component("solar.meter", "EnergyMeter");
    alias Energy = Quantity!(float, KilowattHour);
    Element* aggregate_counter = builder.element(aggregate_meter, "import", register_value_format!Energy());
    aggregate.import_counter = aggregate_counter;

    ProductionContribution member = aggregate;
    member.port = solar;
    member.kind = ProductionContributionKind.member;
    Component member_meter = builder.component("mppt.meter", "EnergyMeter");
    Element* counter = builder.element(member_meter, "import", register_value_format!Energy());
    Element* phase_counter = builder.element(member_meter, "import1", register_value_format!Energy());
    phase_counter.value(Energy(7));
    member.import_counter = counter;
    member.meter = get_meter_data(member_meter);
    assert(member.meter.source(MeterField.total_import_active) == Provenance.synthesized);

    ProductionContribution second = member;
    Component second_meter = builder.component("mppt2.meter", "EnergyMeter");
    Element* second_counter = builder.element(second_meter, "import", register_value_format!Energy());
    second.port = graph.add_port(null, site, PortRole.pv, FlowDomain.supply, second_meter, 0);
    second.import_counter = second_counter;
    graph.production_contributions ~= aggregate;
    graph.production_contributions ~= second;
    graph.production_contributions ~= member;
    reconcile_productions(graph.production_contributions, graph.productions);

    IslandTotals totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh != totals.solar_today_kwh);
    assert((counter in daily.values) is null);
    counter.value(Energy(10));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh != totals.solar_today_kwh);
    assert((counter in daily.values).anchor == 10);
    counter.value(Energy(11));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh != totals.solar_today_kwh);

    second_counter.value(Energy(50));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 1);

    aggregate_counter.value(Energy(100));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 1);
    aggregate_counter.value(Energy(101));
    counter.value(Energy(12));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 2);

    counter.sampling_mode = SamplingMode.poll;
    totals = compute_island_totals(&island, graph, daily, getSysTime() + dur!"seconds"(181));
    assert(counter.has_value && totals.solar_today_kwh != totals.solar_today_kwh);
    assert((counter in daily.values).last == 12 && (aggregate_counter in daily.values) is null);
    counter.value(Energy(13));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 3);

    second_counter.value(Energy(54));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 7);
    member = graph.production_contributions[2];
    second = graph.production_contributions[1];
    graph.production_contributions[][1] = member;
    graph.production_contributions.resize(2);
    reconcile_productions(graph.production_contributions, graph.productions);
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 3);
    graph.production_contributions ~= second;
    reconcile_productions(graph.production_contributions, graph.productions);
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 7);

    check_day_rollover(daily, now + dur!"hours"(26));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 0);
    counter.value(Energy(15));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 2);

    graph.production_contributions[2].import_counter = null;
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 0);
    aggregate_counter.value(Energy(105));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 4);
    aggregate_counter.invalidate();
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh != totals.solar_today_kwh);
    aggregate_counter.value(Energy(107));
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 6);

    Port* unrepresented = graph.add_port(null, site, PortRole.pv, FlowDomain.supply, null, 0, MeterSign.normal, "other", "inverter");
    graph.add_to_group(graph.add_group("other", PortGroupKind.appliance), unrepresented);
    graph.boundaries ~= unrepresented;
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh != totals.solar_today_kwh);

    graph.boundaries.resize(2);
    graph.production_contributions.resize(1);
    reconcile_productions(graph.production_contributions, graph.productions);
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh != totals.solar_today_kwh);

    graph.boundaries.clear();
    graph.reduce_boundary_flows();
    totals = compute_island_totals(&island, graph, daily);
    assert(totals.solar_today_kwh == 0);
}

unittest
{
    TopologyGraph graph;
    Islands islands;
    scope(exit)
    {
        graph.clear();
        update_islands(islands, graph);
    }

    DeviceTable devices;
    auto builder = devices.create("solar-switch");
    Component east_meter = builder.component("east", "EnergyMeter");
    Component west_meter = builder.component("west", "EnergyMeter");
    alias Energy = Quantity!(float, KilowattHour);
    auto counter_format = register_value_format!Energy();
    Element* east_counter = builder.element(east_meter, "import", counter_format);
    Element* west_counter = builder.element(west_meter, "import", counter_format);
    east_counter.value(Energy(100));
    west_counter.value(Energy(200));

    Bus* east = graph.ensure_bus("east");
    Bus* west = graph.ensure_bus("west");
    Port* east_solar = graph.add_port(null, east, PortRole.pv, FlowDomain.supply, east_meter, 0,
                                     MeterSign.normal, "solar.mppt1", "inverter");
    Port* west_solar = graph.add_port(null, west, PortRole.pv, FlowDomain.supply, west_meter, 0,
                                     MeterSign.normal, "solar.mppt2", "inverter");
    graph.add_to_group(graph.add_group("east-pv", PortGroupKind.appliance), east_solar);
    graph.add_to_group(graph.add_group("west-pv", PortGroupKind.appliance), west_solar);

    Port* from = graph.add_port(null, east, PortRole.parent, FlowDomain.bidirectional, null, 0);
    Port* to = graph.add_port(null, west, PortRole.child, FlowDomain.bidirectional, null, 0);
    Link* contact = graph.add_link(null, east, west, from, to, 30, true, "contact");
    PortGroup* switchgear = graph.add_group("contact", PortGroupKind.switchgear, null, contact);
    graph.add_to_group(switchgear, from);
    graph.add_to_group(switchgear, to);
    graph.rebuild_boundaries();
    graph.refresh();
    update_islands(islands, graph);

    DailySnapshot daily;
    assert(graph.productions.length == 1);
    assert(islands.length == 1);
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 0);
    east_counter.value(Energy(104));
    west_counter.value(Energy(209));
    graph.refresh();
    double joined_today = compute_island_totals(islands[0], graph, daily).solar_today_kwh;
    assert(joined_today == 13);

    contact.closed = false;
    graph.refresh();
    update_islands(islands, graph);
    assert(islands.length == 2);
    double split_today = 0;
    foreach (island; islands[])
    {
        double today = compute_island_totals(island, graph, daily).solar_today_kwh;
        assert(today == (island.root is east ? 4 : 9));
        split_today += today;
    }
    assert(split_today == joined_today);

    contact.closed = true;
    graph.refresh();
    update_islands(islands, graph);
    assert(islands.length == 1);
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == joined_today);

    ProductionContribution aggregate = graph.production_contributions[0];
    aggregate.kind = ProductionContributionKind.aggregate;
    aggregate.port = null;
    Element* aggregate_counter = builder.element("aggregate", counter_format);
    aggregate.import_counter = aggregate_counter;
    foreach (ref member; graph.production_contributions[])
        member.import_counter = null;
    graph.production_contributions ~= aggregate;
    reconcile_productions(graph.production_contributions, graph.productions);

    aggregate_counter.value(Energy(500));
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 0);
    aggregate_counter.value(Energy(513));
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 13);

    contact.closed = false;
    update_islands(islands, graph);
    assert(islands.length == 2);
    foreach (island; islands[])
    {
        double today = compute_island_totals(island, graph, daily).solar_today_kwh;
        assert(today != today);
    }

    foreach (ref member; graph.production_contributions[])
        if (member.kind == ProductionContributionKind.member && boundary_bus(member.port) is east)
            member.import_counter = east_counter;
    foreach (island; islands[])
    {
        double today = compute_island_totals(island, graph, daily).solar_today_kwh;
        if (island.root is east)
            assert(today == 4);
        else
            assert(today != today);
    }

    contact.closed = true;
    update_islands(islands, graph);
    assert(islands.length == 1);
    aggregate_counter.value(Energy(515));
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 15);

    Port unassigned_port;
    ProductionContribution unassigned = graph.production_contributions[0];
    unassigned.port = &unassigned_port;
    graph.production_contributions ~= unassigned;
    reconcile_productions(graph.production_contributions, graph.productions);
    double today = compute_island_totals(islands[0], graph, daily).solar_today_kwh;
    assert(today != today);

    west_solar.label = "other";
    Bus* roof = graph.ensure_bus("roof");
    Port* hidden = graph.add_port(null, roof, PortRole.pv, FlowDomain.supply, null, 0,
                                 MeterSign.normal, "solar.mppt3", "inverter");
    Port* peer = graph.add_port(null, west, PortRole.connection, FlowDomain.bidirectional, null, 0);
    Link* interior = graph.add_link(null, west, roof, peer, hidden, 30, true, "inverter-interior");
    PortGroup* plant = graph.add_group("inverter-interior", PortGroupKind.appliance, null, interior);
    graph.add_to_group(plant, peer);
    graph.add_to_group(plant, hidden);
    assert(!is_boundary(hidden));
    graph.rebuild_boundaries();
    graph.refresh();
    update_islands(islands, graph);
    assert(islands.length == 1);
    assert(graph.production_contributions.length == 2);

    ProductionContribution group_aggregate;
    group_aggregate.owner = "inverter";
    group_aggregate.group = "solar";
    group_aggregate.kind = ProductionContributionKind.aggregate;
    group_aggregate.import_counter = aggregate_counter;
    graph.production_contributions ~= group_aggregate;
    reconcile_productions(graph.production_contributions, graph.productions);
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 24);

    east_solar.meter = builder.component("uncounted", "EnergyMeter");
    contact.closed = false;
    graph.refresh();
    update_islands(islands, graph);
    assert(islands.length == 2);
    assert(graph.production_contributions.length == 2);
    graph.production_contributions ~= group_aggregate;
    reconcile_productions(graph.production_contributions, graph.productions);
    foreach (island; islands[])
    {
        double split = compute_island_totals(island, graph, daily).solar_today_kwh;
        assert(split != split);
    }

    east_solar.label = "independent";
    graph.refresh();
    foreach (island; islands[])
        if (!island_contains(island, east))
        {
            double omitted = compute_island_totals(island, graph, daily).solar_today_kwh;
            assert(omitted != omitted);
        }
}


unittest
{
    import manager.collection : Collection;

    Appliance pv = Collection!Appliance().alloc("interior-pv-test");
    assert(pv);
    scope(exit) free(pv);
    pv.kind("pv");

    TopologyGraph graph;
    Islands islands;
    scope(exit)
    {
        graph.clear();
        update_islands(islands, graph);
    }

    DeviceTable devices;
    auto builder = devices.create("interior-pv");
    pv.vin("interior-pv");
    assert(pv.resolve_refs(devices));
    Component east_meter = builder.component("east", "EnergyMeter");
    Component west_meter = builder.component("west", "EnergyMeter");
    alias Energy = Quantity!(float, KilowattHour);
    auto format = register_value_format!Energy();
    Element* east_counter = builder.element(east_meter, "import", format);
    Element* west_counter = builder.element(west_meter, "import", format);
    east_counter.value(Energy(10));
    west_counter.value(Energy(20));

    Bus* east = graph.ensure_bus("east");
    Bus* west = graph.ensure_bus("west");
    Port* east_pv = graph.add_port(pv, east, PortRole.pv, FlowDomain.supply, east_meter, 0,
                                   MeterSign.normal, "solar.mppt1");
    Port* west_pv = graph.add_port(pv, west, PortRole.pv, FlowDomain.supply, west_meter, 0,
                                   MeterSign.normal, "solar.mppt2");
    Link* link = graph.add_link(pv, east, west, east_pv, west_pv, 30);
    PortGroup* group = graph.add_group("inverter", PortGroupKind.appliance, pv, link);
    graph.add_to_group(group, east_pv);
    graph.add_to_group(group, west_pv);
    graph.synthesise_implicit_terminals();
    graph.rebuild_boundaries();
    assert(graph.boundaries.length == 0);
    graph.refresh();
    update_islands(islands, graph);
    assert(islands.length == 1);
    assert(graph.production_contributions.length == 2);

    DailySnapshot daily;
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 0);
    east_counter.value(Energy(14));
    west_counter.value(Energy(23));
    graph.refresh();
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 7);

    east_counter.invalidate();
    graph.refresh();
    double missing = compute_island_totals(islands[0], graph, daily).solar_today_kwh;
    assert(missing != missing);
    east_counter.value(Energy(16));
    graph.refresh();
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 9);

    east_pv.meter = null;
    graph.refresh();
    missing = compute_island_totals(islands[0], graph, daily).solar_today_kwh;
    assert(missing != missing);

    Component solar = builder.component("solar", "Solar");
    Component aggregate_meter = builder.component(solar, "meter", "EnergyMeter");
    Element* aggregate = builder.element(aggregate_meter, "import", format);
    aggregate.value(Energy(100));
    west_pv.meter = null;
    pv.kind("inverter");
    graph.synthesise_implicit_terminals();
    graph.rebuild_boundaries();
    assert(graph.boundaries.length == 2);
    graph.refresh();
    assert(graph.production_contributions.length == 1);
    assert(graph.production_contributions[0].import_counter is aggregate);
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 0);
    aggregate.value(Energy(107));
    graph.refresh();
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 7);

    link.closed = false;
    graph.refresh();
    update_islands(islands, graph);
    assert(islands.length == 2);
    foreach (island; islands[])
    {
        double split = compute_island_totals(island, graph, daily).solar_today_kwh;
        assert(split != split);
    }

    aggregate.value(Energy(109));
    link.closed = true;
    graph.refresh();
    update_islands(islands, graph);
    assert(islands.length == 1);
    assert(compute_island_totals(islands[0], graph, daily).solar_today_kwh == 9);
}

unittest
{
    import urt.si.quantity : Quantity, Watts;
    import urt.si.unit : KilowattHour;
    import manager.component : Component;

    TopologyGraph graph;
    scope(exit) graph.clear();
    Bus* site = graph.ensure_bus("site");
    Island island;
    island.root = site;
    island.members ~= site;

    DeviceTable devices;
    auto builder = devices.create("grid-freshness");
    Component meter = builder.component("meter", "EnergyMeter");
    builder.element(meter, "type", register_value_format!string()).value("three-phase");
    alias Energy = Quantity!(float, KilowattHour);
    Element* power = builder.element(meter, "power", register_value_format!Watts());
    builder.element(meter, "power1", register_value_format!Watts()).value(Watts(-40));
    builder.element(meter, "power2", register_value_format!Watts());
    Element* counter = builder.element(meter, "export", register_value_format!Energy());
    Element* phase1 = builder.element(meter, "export1", register_value_format!Energy());
    Element* phase2 = builder.element(meter, "export2", register_value_format!Energy());
    Element* phase3 = builder.element(meter, "export3", register_value_format!Energy());
    Element* reverse2 = builder.element(meter, "import2", register_value_format!Energy());
    Device device = builder.device;
    int source;
    device.set_online(&source, true);
    SysTime now = getSysTime();
    power.sampling_mode = SamplingMode.poll;
    counter.sampling_mode = SamplingMode.poll;
    power.value(Watts(-100), now - dur!"seconds"(181));
    counter.value(Energy(100), now);

    Port* grid = graph.add_port(null, site, PortRole.grid, FlowDomain.bidirectional, meter, 0);
    Port* load = graph.add_port(null, site, PortRole.outlet, FlowDomain.consume, null, 0);
    graph.add_to_group(graph.add_group("grid", PortGroupKind.handover), grid);
    graph.add_to_group(graph.add_group("load", PortGroupKind.appliance), load);
    graph.rebuild_boundaries();

    DailySnapshot daily;
    IslandAccountPublisher publisher;
    publisher.bind(builder, "site");
    graph.refresh();
    assert(power.has_value && !grid.meter_data.has(MeterField.power));
    assert(!load.meter_data.has(MeterField.power));
    assert(site.coverage == Coverage.unknown && graph.boundary_flows.length == 0);
    update_island_accounts(publisher, &island, graph, daily, now);
    assert(!publisher.grid_power.element.has_value && !publisher.load_power.element.has_value);
    assert(publisher.grid_today_import.element.has_value && publisher.grid_today_import.element.value.asFloat == 0);

    power.value(Watts(-100), now);
    graph.refresh();
    assert(grid.meter_data.source(MeterField.power) == Provenance.measured);
    assert(load.meter_data.source(MeterField.power) == Provenance.inferred_subtraction);
    assert(load.meter_data.active[0].value == 100);
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(1));
    assert(publisher.grid_today_import.element.value.asFloat == 0);

    const stale = now - dur!"seconds"(181);
    counter.last_update = stale;
    phase1.value(Energy(10));
    phase2.value(Energy(20));
    phase3.value(Energy(10));
    graph.refresh();
    assert(grid.meter_data.source(MeterField.total_export_active) == Provenance.synthesized);
    assert(grid.meter_data.total_export_active[0] == 40);
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(2));
    assert(!publisher.grid_today_import.element.has_value);

    device.set_online(&source, false);
    graph.refresh();
    assert(!grid.meter_data.has(MeterField.total_export_active));
    assert(!load.meter_data.has(MeterField.power));
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(2));
    assert(!publisher.grid_today_import.element.has_value);

    device.set_online(&source, true);
    counter.value(Energy(108));
    graph.refresh();
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(3));
    assert(publisher.grid_today_import.element.has_value && publisher.grid_today_import.element.value.asFloat == 8);

    grid.meter_phase = 2;
    grid.meter_sign = MeterSign.inverted;
    Port* other_grid = graph.add_port(null, site, PortRole.grid, FlowDomain.bidirectional, meter, 1);
    graph.add_to_group(graph.add_group("grid-phase1", PortGroupKind.handover), other_grid);
    graph.rebuild_boundaries();
    reverse2.sampling_mode = SamplingMode.poll;
    reverse2.value(Energy(200));
    graph.refresh();
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(4));
    assert(publisher.grid_today_import.element.has_value && publisher.grid_today_import.element.value.asFloat == 0);

    assert((phase1 in daily.values).anchor == 10 && (reverse2 in daily.values).anchor == 200);
    reverse2.last_update = stale;
    phase1.value(Energy(13));
    graph.refresh();
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(5));
    assert(!publisher.grid_today_import.element.has_value);

    reverse2.value(Energy(208));
    graph.refresh();
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(6));
    assert(publisher.grid_today_import.element.has_value && publisher.grid_today_import.element.value.asFloat == 11);

    grid.meter = builder.component("single", "EnergyMeter");
    grid.meter_phase = 1;
    grid.meter_sign = MeterSign.normal;
    builder.element(grid.meter, "type", register_value_format!string()).value("single-phase");
    Element* single_export = builder.element(grid.meter, "export", register_value_format!Energy());
    daily.values.clear();
    single_export.value(Energy(100));
    graph.refresh();
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(7));
    assert(publisher.grid_today_import.element.value.asFloat == 0);

    single_export.value(Energy(107));
    graph.refresh();
    update_island_accounts(publisher, &island, graph, daily, now + dur!"seconds"(8));
    assert(publisher.grid_today_import.element.value.asFloat == 7);
}
