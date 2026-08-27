module apps.energy.battery_store;

import urt.array;
import urt.si.unit : ScaledUnit, AmpereHour, Percent;

import apps.energy.model : absf, read_in_unit;

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
    float remain_capacity = float.nan;
    float full_capacity = float.nan;
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
    import urt.mem;
    import urt.si.quantity : Quantity;
    import urt.string : StringLit, make_string;
    import manager.series : DataFormat, SeriesKind, ValueType, register_format;
    import urt.variant : Variant;

    static Component component(const(char)[] id, const(char)[] template_)
    {
        Component c = alloc!Component(id.make_string());
        c.template_ = template_.make_string();
        return c;
    }

    static void add_num(Component c, const(char)[] id, float value, ScaledUnit unit)
    {
        Element* e = alloc_element();
        e.id = id.make_string();
        e.format = register_format(DataFormat(ValueType.f64, SeriesKind.held, unit));
        e.value = Variant(Quantity!double(value, unit));
        c.elements ~= e;
    }

    static Component battery(const(char)[] id, float soc, float cap)
    {
        Component b = component(id, "Battery");
        if (soc == soc)
            add_num(b, "soc", soc, Percent);
        if (cap == cap)
            add_num(b, "full_capacity", cap, AmpereHour);
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
    // accumulators must zero-init; float.init NaN poisons +=
    float soc_weighted = 0;
    float soc_weight = 0;
    float soc_plain = 0;
    uint soc_count;
    uint soc_weight_count;
    float remain_sum = 0;
    uint remain_count;
    float full_sum = 0;
    uint full_count;
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
            ++totals.soc_weight_count;
        }
        totals.soc_plain += r.soc;
        ++totals.soc_count;
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
    reading.soc = (totals.soc_weight > 0 && totals.soc_weight_count == totals.soc_count)
        ? totals.soc_weighted / totals.soc_weight
        : totals.soc_count ? totals.soc_plain / totals.soc_count : float.nan;
    reading.remain_capacity = sum_or_nan(totals.remain_sum, totals.remain_count);
    reading.full_capacity = sum_or_nan(totals.full_sum, totals.full_count);
}

void finalise_view_totals(ref BatteryStoreReading reading, ref const ContributionTotals totals)
{
    reading.soc = avg_soc(totals);
    reading.remain_capacity = avg(totals.remain_sum, totals.remain_count);
    reading.full_capacity = avg(totals.full_sum, totals.full_count);
}

BatteryStoreReading read_store(Component c)
{
    BatteryStoreReading r;
    r.soc = read_num(c, "soc");
    r.remain_capacity = read_scaled(c, "remain_capacity", AmpereHour);
    r.full_capacity = read_scaled(c, "full_capacity", AmpereHour);
    return r;
}

// Percent is scaled despite being dimensionless.
float read_num(Component c, const(char)[] id)
{
    if (c is null)
        return float.nan;
    return read_in_unit(c.find_element(id), Percent);
}

float read_scaled(Component c, const(char)[] id, ScaledUnit unit)
{
    if (c is null)
        return float.nan;
    return read_in_unit(c.find_element(id), unit);
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
