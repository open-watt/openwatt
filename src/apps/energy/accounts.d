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


// Per-tick: publish island-level accounts from reconciled circuit overlays:
// production groups, battery terminals, grid/root flow, and derived load.
//
// Current set of accounts published per island:
//   account.solar.power           (W, sum of Solar EnergyMeter active power)
//   account.battery.power         (W, signed: positive = discharging)
//   account.grid.power            (W, signed: positive = importing)
//   account.generation.power      (W, derived: solar + max(battery,0) + max(grid,0))
//   account.load.total.power      (W, derived from balance)
//   account.solar.today.energy    (kWh since local midnight; HACK -- see below)
//   account.battery.today.charge  (kWh since local midnight; HACK)
//   account.battery.today.discharge (kWh since local midnight; HACK)
//   account.grid.today.import     (kWh since local midnight; HACK)
//   account.grid.today.export     (kWh since local midnight; HACK)
//
// HACK: per-element snapshot of cumulative kWh at the start of "today" (local
// midnight, or first observation in the current day). today_delta(e) returns
// current - snapshot[e], lazily populating snapshot on first read of each
// element. Cleared on local-midnight rollover.
//
// TODO(0.6, db.Stream): replace with `value_at(source, midnight)` queries when
// db.Stream lands; drop this struct and today_delta. Tracked in DIP Phase 0.6.
struct DailySnapshot
{
nothrow @nogc:
    Map!(Element*, double) values;
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

// Lazy snapshot + delta. Returns 0 if the element is missing or not numeric;
// 0 on first call for an element (snapshot taken). Subsequent calls return
// current - snapshot.
double today_delta(ref DailySnapshot daily, Element* e)
{
    double current = today_value_kwh(e);
    if (current != current) // NaN
        return 0;

    double* snap = e in daily.values;
    if (!snap)
    {
        daily.values.insert(e, current);
        return 0;
    }
    return current - *snap;
}

double today_value_kwh(Element* e)
{
    if (!e)
        return double.nan;
    if (e.value.isQuantity)
        return e.scaled_value!KilowattHour();
    if (e.value.isNumber)
        return e.value.asFloat;
    return double.nan;
}

struct IslandTotals
{
    float solar_power = 0;
    float battery_power = 0;          // signed: positive = discharging
    float grid_power = 0;             // signed: positive = importing
    float generation_power = 0;
    float load_power = 0;

    // today.* values (kWh since local midnight); HACK -- see file header.
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
        mode.bind(account_element(energy_device, island_id, "mode"));
        members.bind(account_element(energy_device, island_id, "members"));
        solar_power.bind(account_element(energy_device, island_id, "account.solar.power"));
        battery_power.bind(account_element(energy_device, island_id, "account.battery.power"));
        grid_power.bind(account_element(energy_device, island_id, "account.grid.power"));
        generation_power.bind(account_element(energy_device, island_id, "account.generation.power"));
        load_power.bind(account_element(energy_device, island_id, "account.load.total.power"));
        solar_today_energy.bind(account_element(energy_device, island_id, "account.solar.today.energy"));
        battery_today_charge.bind(account_element(energy_device, island_id, "account.battery.today.charge"));
        battery_today_discharge.bind(account_element(energy_device, island_id, "account.battery.today.discharge"));
        grid_today_import.bind(account_element(energy_device, island_id, "account.grid.today.import"));
        grid_today_export.bind(account_element(energy_device, island_id, "account.grid.today.export"));
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

Element* account_element(Device energy_device, const(char)[] island_id, const(char)[] path)
{
    return energy_device.find_or_create_element(tconcat("islands.", island_id, ".", path));
}

bool same_float(float a, float b) pure
{
    return a == b || (a != a && b != b);
}

void update_island_accounts(ref IslandAccountPublisher publisher, Island* island, ref TopologyGraph graph,
                            ref DailySnapshot daily, SysTime ts)
{
    IslandTotals t = compute_island_totals(island, graph, daily);

    // Island metadata: mode + member bus list
    publisher.mode.publish(island_mode_name(island.mode), ts);

    // Comma-separated list of member bus IDs (printable; could become an array later)
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
    publisher.generation_power.publish(t.generation_power, ts);
    publisher.load_power.publish(t.load_power, ts);

    publisher.solar_today_energy.publish(cast(float)t.solar_today_kwh, ts);
    publisher.battery_today_charge.publish(cast(float)t.battery_charge_today_kwh, ts);
    publisher.battery_today_discharge.publish(cast(float)t.battery_discharge_today_kwh, ts);
    publisher.grid_today_import.publish(cast(float)t.grid_import_today_kwh, ts);
    publisher.grid_today_export.publish(cast(float)t.grid_export_today_kwh, ts);
}

IslandTotals compute_island_totals(Island* island, ref TopologyGraph graph, ref DailySnapshot daily)
{
    IslandTotals t;

    // Grid: currently the aggregate flow on the island root bus.
    if (island.root && island.root.balance.has(MeterField.power))
    {
        t.grid_power = island.root.balance.active[0].value;
        foreach (p; island.root.ports[])
        {
            if (p.meter)
            {
                t.grid_import_today_kwh += today_delta(daily, p.meter.find_element("import"));
                t.grid_export_today_kwh += today_delta(daily, p.meter.find_element("export"));
            }
        }
    }

    foreach (ref production; graph.productions[])
        if (production_belongs_to_island(production, graph, island) &&
            production.data.has(MeterField.power))
            t.solar_power += production.data.active[0].value;
    add_production_today(t, graph, island, daily);

    bool have_battery_member;
    foreach (p; graph.ports[])
    {
        if (p.role != PortRole.battery || !bus_in_island(island, p.bus))
            continue;
        if (p.owner && p.owner.kind == "battery")
        {
            have_battery_member = true;
            break;
        }
    }

    foreach (p; graph.ports[])
    {
        if (p.role != PortRole.battery || !bus_in_island(island, p.bus))
            continue;
        bool member = p.owner && p.owner.kind == "battery";
        if (have_battery_member && !member)
            continue;
        if (p.meter_data.has(MeterField.power))
            t.battery_power += member ? -p.meter_data.active[0].value
                                      : p.meter_data.active[0].value;
        if (p.meter)
        {
            Element* import_energy = p.meter.find_element("import");
            Element* export_energy = p.meter.find_element("export");
            if (member)
            {
                t.battery_charge_today_kwh += today_delta(daily, import_energy);
                t.battery_discharge_today_kwh += today_delta(daily, export_energy);
            }
            else
            {
                t.battery_charge_today_kwh += today_delta(daily, export_energy);
                t.battery_discharge_today_kwh += today_delta(daily, import_energy);
            }
        }
    }

    // Generation: positive sources side of the energy bus.
    float bat_src = t.battery_power > 0 ? t.battery_power : 0;
    float grid_src = t.grid_power > 0 ? t.grid_power : 0;
    t.generation_power = t.solar_power + bat_src + grid_src;

    // Load: derived from balance. Sources flow into the bus; battery-charging
    // and grid-export drain off it; the rest is house load.
    float bat_sink = t.battery_power < 0 ? -t.battery_power : 0;
    float grid_sink = t.grid_power < 0 ? -t.grid_power : 0;
    t.load_power = t.generation_power - bat_sink - grid_sink;
    if (t.load_power < 0)
        t.load_power = 0;

    return t;
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
            if (contribution.component)
                if (Component meter = contribution.component.get_first_component_by_template("EnergyMeter"))
                    t.solar_today_kwh += today_delta(daily, meter.find_element("import"));
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
                    t.solar_today_kwh += today_delta(daily, meter.find_element("import"));
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

bool bus_in_island(Island* island, Bus* bus)
{
    return bus !is null && circuit_in_island(island, bus.id[]);
}
