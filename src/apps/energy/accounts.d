module apps.energy.accounts;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem.temp : tconcat;
import urt.si.quantity;
import urt.si.unit;
import urt.string;
import urt.time;
import urt.variant;

import apps.energy.appliance;
import apps.energy.circuit;
import apps.energy.island;
import apps.energy.meter;

import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


// Per-tick: walk each island's member circuits, harvest Solar / Battery
// components from the devices attached via appliances, aggregate by role,
// and publish to elements on the synthetic energy device.
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
    SysTime day_start;
}

void update_accounts(Device energy_device, ref Archipelago archipelago, ref DailySnapshot daily)
{
    if (!energy_device)
        return;

    SysTime now = getSysTime();
    check_day_rollover(daily, now);

    foreach (island; archipelago[])
        update_island_accounts(energy_device, island, daily, now);
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
    if (!e || !e.value.isNumber)
        return 0;
    double current = e.value.asFloat;
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

void update_island_accounts(Device energy_device, Island* island, ref DailySnapshot daily, SysTime ts)
{
    IslandTotals t = compute_island_totals(island, daily);

    // Island metadata: mode + member circuit list
    publish_string(energy_device, island.id[], "mode", island_mode_name(island.mode), ts);

    // Comma-separated list of member circuit IDs (printable; could become an array later)
    Array!char members_buf;
    foreach (i, c; island.members[])
    {
        if (i > 0)
            members_buf ~= ',';
        members_buf ~= c.id[];
    }
    publish_string(energy_device, island.id[], "members", members_buf[], ts);

    set_account(energy_device, island.id[], "account.solar.power", t.solar_power, ts);
    set_account(energy_device, island.id[], "account.battery.power", t.battery_power, ts);
    set_account(energy_device, island.id[], "account.grid.power", t.grid_power, ts);
    set_account(energy_device, island.id[], "account.generation.power", t.generation_power, ts);
    set_account(energy_device, island.id[], "account.load.total.power", t.load_power, ts);

    set_account(energy_device, island.id[], "account.solar.today.energy", cast(float)t.solar_today_kwh, ts);
    set_account(energy_device, island.id[], "account.battery.today.charge", cast(float)t.battery_charge_today_kwh, ts);
    set_account(energy_device, island.id[], "account.battery.today.discharge", cast(float)t.battery_discharge_today_kwh, ts);
    set_account(energy_device, island.id[], "account.grid.today.import", cast(float)t.grid_import_today_kwh, ts);
    set_account(energy_device, island.id[], "account.grid.today.export", cast(float)t.grid_export_today_kwh, ts);
}

IslandTotals compute_island_totals(Island* island, ref DailySnapshot daily)
{
    IslandTotals t;

    // Grid: net flow at the island's root meter (positive = into the island).
    // For an on-grid island, this is grid import/export. For an off-grid
    // island the root meter (if present) describes whatever feeds it.
    if (island.root.meter)
    {
        if (island.root.meter_data.has(MeterField.power))
            t.grid_power = island.root.meter_data.active[0].value;
        // HACK: today.import / today.export from cumulative element deltas
        t.grid_import_today_kwh = today_delta(daily, island.root.meter.find_element("import"));
        t.grid_export_today_kwh = today_delta(daily, island.root.meter.find_element("export"));
    }

    // Harvest Solar / Battery contributions from all devices reachable via
    // appliances on member circuits.
    foreach (c; island.members[])
    {
        foreach (a; c.appliances[])
        {
            Component root = a.device_ref;
            if (root is null)
                continue;
            harvest_device(root, daily, t);
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

void harvest_device(Component device, ref DailySnapshot daily, ref IslandTotals t)
{
    foreach (sub; device.components[])
        harvest_component(sub, daily, t);
}

void harvest_component(Component c, ref DailySnapshot daily, ref IslandTotals t)
{
    if (c.template_[] == "Solar")
    {
        if (Component em = c.get_first_component_by_template("EnergyMeter"))
        {
            MeterData md = get_meter_data(em);
            if (md.has(MeterField.power))
                t.solar_power += md.active[0].value;
            // HACK: per-source today delta; sums into the aggregate.
            t.solar_today_kwh += today_delta(daily, em.find_element("import"));
        }
    }
    else if (c.template_[] == "Battery")
    {
        if (Component em = c.get_first_component_by_template("EnergyMeter"))
        {
            MeterData md = get_meter_data(em);
            if (md.has(MeterField.power))
                t.battery_power += md.active[0].value;
            // Battery DC meter import = charge, export = discharge.
            t.battery_charge_today_kwh += today_delta(daily, em.find_element("import"));
            t.battery_discharge_today_kwh += today_delta(daily, em.find_element("export"));
        }
    }

    // Recurse: Inverter components contain nested Solar/Battery sub-components.
    foreach (sub; c.components[])
        harvest_component(sub, daily, t);
}

void set_account(Device energy_device, const(char)[] island_id, const(char)[] path, float value, SysTime ts)
{
    Element* e = energy_device.find_or_create_element(tconcat("archipelago.island.", island_id, ".", path));
    if (e)
        e.value(value, ts);
}

void publish_string(Device energy_device, const(char)[] island_id, const(char)[] path, const(char)[] value, SysTime ts)
{
    Element* e = energy_device.find_or_create_element(tconcat("archipelago.island.", island_id, ".", path));
    if (e)
        e.value(value, ts);
}
