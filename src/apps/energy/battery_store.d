module apps.energy.battery_store;

import urt.array;

import manager.component;
import manager.element;

nothrow @nogc:


enum BatteryStoreContributionKind : ubyte
{
    view,
    member,
}

const(char)[] battery_store_contribution_kind_name(BatteryStoreContributionKind k) pure
{
    final switch (k)
    {
        case BatteryStoreContributionKind.view:   return "view";
        case BatteryStoreContributionKind.member: return "member";
    }
}

struct BatteryStoreContribution
{
    const(char)[] circuit;
    const(char)[] owner;
    const(char)[] port;
    BatteryStoreContributionKind kind;
    Component component;
}

struct BatteryStoreReading
{
    float soc = float.nan;
    float soh = float.nan;
    float remain_capacity = float.nan;
    float full_capacity = float.nan;
    float max_charge_current = float.nan;
    float max_discharge_current = float.nan;
    float max_charge_power = float.nan;
    float max_discharge_power = float.nan;
}

struct BatteryStore
{
    const(char)[] circuit;
    BatteryStoreReading reading;
    uint member_count;
    uint view_count;
    bool soc_anomaly;

private:
    ContributionTotals members;
    ContributionTotals views;
}

void collect_battery_store_contributions(Component port, const(char)[] circuit,
                                         const(char)[] owner, const(char)[] port_path,
                                         BatteryStoreContributionKind kind,
                                         ref Array!BatteryStoreContribution into)
{
    if (port is null || circuit.length == 0)
        return;
    collect_battery_store_contributions_impl(port, circuit, owner, port_path, kind, into);
}

float read_battery_soc(Component c)
{
    if (c is null)
        return float.nan;

    float soc = read_num(c, "soc");
    if (soc == soc || c.template_[] == "Battery")
        return soc;

    Component battery = c.find_first_component_by_template_recursive("Battery");
    return read_num(battery, "soc");
}

void reconcile_battery_stores(ref Array!BatteryStoreContribution contributions, ref Array!BatteryStore stores)
{
    stores.clear();
    foreach (ref c; contributions[])
    {
        BatteryStore* s = find_or_add_store(stores, c.circuit);
        BatteryStoreReading r = read_store(c.component);
        if (c.kind == BatteryStoreContributionKind.member)
        {
            ++s.member_count;
            add_reading(s.members, r, true);
        }
        else
        {
            ++s.view_count;
            add_reading(s.views, r, false);
        }
    }

    foreach (ref s; stores[])
        finalise_store(s);
}

unittest
{
    import urt.mem.allocator : defaultAllocator;
    import urt.string : StringLit, makeString;
    import urt.variant : Variant;

    static Component component(const(char)[] id, const(char)[] template_)
    {
        Component c = defaultAllocator.allocT!Component(id.makeString(defaultAllocator));
        c.template_ = template_.makeString(defaultAllocator);
        return c;
    }

    static void add_num(Component c, const(char)[] id, float value)
    {
        Element* e = defaultAllocator.allocT!Element();
        e.id = id.makeString(defaultAllocator);
        e.value = Variant(value);
        c.elements ~= e;
    }

    static Component battery(const(char)[] id, float soc, float cap)
    {
        Component b = component(id, "Battery");
        if (soc == soc)
            add_num(b, "soc", soc);
        if (cap == cap)
            add_num(b, "full_capacity", cap);
        return b;
    }

    static BatteryStoreContribution contribution(Component battery, const(char)[] circuit,
                                                 BatteryStoreContributionKind kind)
    {
        BatteryStoreContribution c;
        c.circuit = circuit;
        c.owner = "test";
        c.port = "battery";
        c.kind = kind;
        c.component = battery;
        return c;
    }

    // Inverter view + BMS member on one bus: member defines, view corroborates.
    {
        Array!BatteryStoreContribution contributions;
        contributions ~= contribution(battery("inverter_view", 50, float.nan),
                                      "dc_bus", BatteryStoreContributionKind.view);
        contributions ~= contribution(battery("bms_member", 52, 100),
                                      "dc_bus", BatteryStoreContributionKind.member);

        Array!BatteryStore stores;
        reconcile_battery_stores(contributions, stores);
        assert(stores.length == 1);
        assert(stores[0].circuit == "dc_bus");
        assert(stores[0].member_count == 1 && stores[0].view_count == 1);
        assert(absf(stores[0].reading.full_capacity - 100) <= 0.01f);
        assert(absf(stores[0].reading.soc - 52) <= 0.01f);
        assert(!stores[0].soc_anomaly);
    }

    // Lone inverter view: promoted to define the store.
    {
        Array!BatteryStoreContribution contributions;
        contributions ~= contribution(battery("integrated_view", 73, 200),
                                      "dc_bus", BatteryStoreContributionKind.view);

        Array!BatteryStore stores;
        reconcile_battery_stores(contributions, stores);
        assert(stores.length == 1);
        assert(stores[0].member_count == 0 && stores[0].view_count == 1);
        assert(absf(stores[0].reading.soc - 73) <= 0.01f);
        assert(absf(stores[0].reading.full_capacity - 200) <= 0.01f);
    }

    // Parallel packs: members sum capacity and SOC is capacity-weighted.
    {
        Array!BatteryStoreContribution contributions;
        contributions ~= contribution(battery("pack_a", 50, 100),
                                      "dc_bus", BatteryStoreContributionKind.member);
        contributions ~= contribution(battery("pack_b", 60, 100),
                                      "dc_bus", BatteryStoreContributionKind.member);

        Array!BatteryStore stores;
        reconcile_battery_stores(contributions, stores);
        assert(stores.length == 1);
        assert(stores[0].member_count == 2);
        assert(absf(stores[0].reading.full_capacity - 200) <= 0.01f);
        assert(absf(stores[0].reading.soc - 55) <= 0.01f);
    }

    // A view that disagrees with members is flagged but does not define the store.
    {
        Array!BatteryStoreContribution contributions;
        contributions ~= contribution(battery("inverter_view", 20, float.nan),
                                      "dc_bus", BatteryStoreContributionKind.view);
        contributions ~= contribution(battery("bms_member", 80, 100),
                                      "dc_bus", BatteryStoreContributionKind.member);

        Array!BatteryStore stores;
        reconcile_battery_stores(contributions, stores);
        assert(stores.length == 1);
        assert(absf(stores[0].reading.soc - 80) <= 0.01f);
        assert(stores[0].soc_anomaly);
    }
}

private:

enum soc_tolerance = 5.0f;

struct ContributionTotals
{
    float soc_weighted;
    float soc_weight;
    float soc_plain;
    uint soc_count;
    float soh_sum;
    uint soh_count;
    float remain_sum;
    uint remain_count;
    float full_sum;
    uint full_count;
    float max_charge_current_sum;
    uint max_charge_current_count;
    float max_discharge_current_sum;
    uint max_discharge_current_count;
    float max_charge_power_sum;
    uint max_charge_power_count;
    float max_discharge_power_sum;
    uint max_discharge_power_count;
}

void collect_battery_store_contributions_impl(Component c, const(char)[] circuit,
                                              const(char)[] owner, const(char)[] port_path,
                                              BatteryStoreContributionKind kind,
                                              ref Array!BatteryStoreContribution into)
{
    if (c.template_[] == "Battery")
    {
        BatteryStoreContribution contribution;
        contribution.circuit = circuit;
        contribution.owner = owner;
        contribution.port = port_path;
        contribution.kind = kind;
        contribution.component = c;
        into ~= contribution;
        return;
    }

    foreach (child; c.components[])
        collect_battery_store_contributions_impl(child, circuit, owner, port_path, kind, into);
}

BatteryStore* find_or_add_store(ref Array!BatteryStore stores, const(char)[] circuit)
{
    foreach (ref s; stores[])
        if (s.circuit == circuit)
            return &s;

    BatteryStore s;
    s.circuit = circuit;
    stores ~= s;
    return &stores[stores.length - 1];
}

void add_reading(ref ContributionTotals totals, ref const BatteryStoreReading r, bool capacity_weighted)
{
    if (r.soc == r.soc)
    {
        if (capacity_weighted && r.full_capacity == r.full_capacity)
        {
            totals.soc_weighted += r.soc * r.full_capacity;
            totals.soc_weight += r.full_capacity;
        }
        totals.soc_plain += r.soc;
        ++totals.soc_count;
    }
    if (r.soh == r.soh)
    {
        totals.soh_sum += r.soh;
        ++totals.soh_count;
    }
    if (r.remain_capacity == r.remain_capacity)
    {
        totals.remain_sum += r.remain_capacity;
        ++totals.remain_count;
    }
    if (r.full_capacity == r.full_capacity)
    {
        totals.full_sum += r.full_capacity;
        ++totals.full_count;
    }
    if (r.max_charge_current == r.max_charge_current)
    {
        totals.max_charge_current_sum += r.max_charge_current;
        ++totals.max_charge_current_count;
    }
    if (r.max_discharge_current == r.max_discharge_current)
    {
        totals.max_discharge_current_sum += r.max_discharge_current;
        ++totals.max_discharge_current_count;
    }
    if (r.max_charge_power == r.max_charge_power)
    {
        totals.max_charge_power_sum += r.max_charge_power;
        ++totals.max_charge_power_count;
    }
    if (r.max_discharge_power == r.max_discharge_power)
    {
        totals.max_discharge_power_sum += r.max_discharge_power;
        ++totals.max_discharge_power_count;
    }
}

void finalise_store(ref BatteryStore s)
{
    if (s.member_count != 0)
    {
        finalise_member_totals(s.reading, s.members);
        if (s.views.soc_count != 0 && s.reading.soc == s.reading.soc)
            s.soc_anomaly = absf(avg_soc(s.views) - s.reading.soc) > soc_tolerance;
    }
    else
        finalise_view_totals(s.reading, s.views);
}

void finalise_member_totals(ref BatteryStoreReading reading, ref const ContributionTotals totals)
{
    reading.soc = totals.soc_weight > 0 ? totals.soc_weighted / totals.soc_weight :
        totals.soc_count ? totals.soc_plain / totals.soc_count : float.nan;
    reading.soh = avg(totals.soh_sum, totals.soh_count);
    reading.remain_capacity = sum_or_nan(totals.remain_sum, totals.remain_count);
    reading.full_capacity = sum_or_nan(totals.full_sum, totals.full_count);
    reading.max_charge_current = sum_or_nan(totals.max_charge_current_sum, totals.max_charge_current_count);
    reading.max_discharge_current = sum_or_nan(totals.max_discharge_current_sum, totals.max_discharge_current_count);
    reading.max_charge_power = sum_or_nan(totals.max_charge_power_sum, totals.max_charge_power_count);
    reading.max_discharge_power = sum_or_nan(totals.max_discharge_power_sum, totals.max_discharge_power_count);
}

void finalise_view_totals(ref BatteryStoreReading reading, ref const ContributionTotals totals)
{
    reading.soc = avg_soc(totals);
    reading.soh = avg(totals.soh_sum, totals.soh_count);
    reading.remain_capacity = avg(totals.remain_sum, totals.remain_count);
    reading.full_capacity = avg(totals.full_sum, totals.full_count);
    reading.max_charge_current = avg(totals.max_charge_current_sum, totals.max_charge_current_count);
    reading.max_discharge_current = avg(totals.max_discharge_current_sum, totals.max_discharge_current_count);
    reading.max_charge_power = avg(totals.max_charge_power_sum, totals.max_charge_power_count);
    reading.max_discharge_power = avg(totals.max_discharge_power_sum, totals.max_discharge_power_count);
}

BatteryStoreReading read_store(Component c)
{
    BatteryStoreReading r;
    r.soc = read_num(c, "soc");
    r.soh = read_num(c, "soh");
    r.remain_capacity = read_num(c, "remain_capacity");
    r.full_capacity = read_num(c, "full_capacity");
    r.max_charge_current = read_num(c, "max_charge_current");
    r.max_discharge_current = read_num(c, "max_discharge_current");
    r.max_charge_power = read_num(c, "max_charge_power");
    r.max_discharge_power = read_num(c, "max_discharge_power");
    return r;
}

float read_num(Component c, const(char)[] id)
{
    if (c is null)
        return float.nan;
    Element* e = c.find_element(id);
    if (e is null || !e.value.isNumber)
        return float.nan;
    return e.value.asFloat;
}

float avg_soc(ref const ContributionTotals totals) pure
{
    return totals.soc_count ? totals.soc_plain / totals.soc_count : float.nan;
}

float avg(float sum, uint count) pure
{
    return count ? sum / count : float.nan;
}

float sum_or_nan(float sum, uint count) pure
{
    return count ? sum : float.nan;
}

float absf(float value) pure
{
    return value < 0 ? -value : value;
}
