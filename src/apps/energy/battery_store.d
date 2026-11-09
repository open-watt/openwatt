module apps.energy.battery_store;

import urt.array;
import urt.si.unit : ScaledUnit, AmpereHour, Percent;
import urt.time : getSysTime, SysTime;

import apps.energy.model : absf, read_in_unit, reading_present;

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

void collect_battery_store_contributions(Component port, const(char)[] circuit, const(char)[] owner, const(char)[] port_path, BatteryStoreContributionKind kind, ref Array!BatteryStoreContribution into)
{
    if (port is null || circuit.length == 0)
        return;
    collect_battery_store_contributions_impl(port, circuit, owner, port_path, kind, into);
}

float read_battery_soc(Component c)
{
    if (c is null)
        return float.nan;

    SysTime now = getSysTime();
    float soc = read_store_telemetry(c, "soc", Percent, now);
    if (soc == soc || c.template_[] == "Battery")
        return soc;

    Component battery = c.find_first_component_by_template_recursive("Battery");
    return read_store_telemetry(battery, "soc", Percent, now);
}

void reconcile_battery_stores(ref Array!BatteryStoreContribution contributions, ref Array!BatteryStore stores)
{
    stores.clear();
    SysTime now = getSysTime();
    foreach (ref c; contributions[])
    {
        BatteryStore* s = find_or_add_store(stores, c.circuit);
        BatteryStoreReading r = read_store(c.component, now);
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

    import manager.device : DeviceBuilder, DeviceTable;

    static void add_num(ref DeviceBuilder d, Component c, const(char)[] id, float value, ScaledUnit unit)
    {
        Element* e = d.element(c, id, register_format(DataFormat(ValueType.f64, SeriesKind.held, unit)));
        e.value = Variant(Quantity!double(value, unit));
    }

    static Component battery(ref DeviceBuilder d, const(char)[] id, float soc, float cap)
    {
        Component b = d.component(id, "Battery");
        if (soc == soc)
            add_num(d, b, "soc", soc, Percent);
        if (cap == cap)
            add_num(d, b, "full_capacity", cap, AmpereHour);
        return b;
    }

    DeviceTable devices;
    DeviceBuilder d = devices.create("store-test");

    static BatteryStoreContribution contribution(Component battery, const(char)[] circuit, BatteryStoreContributionKind kind)
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
        contributions ~= contribution(battery(d, "inverter_view", 50, float.nan), "dc_bus", BatteryStoreContributionKind.view);
        contributions ~= contribution(battery(d, "bms_member", 52, 100), "dc_bus", BatteryStoreContributionKind.member);

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
        contributions ~= contribution(battery(d, "integrated_view", 73, 200), "dc_bus", BatteryStoreContributionKind.view);

        Array!BatteryStore stores;
        reconcile_battery_stores(contributions, stores);
        assert(stores.length == 1);
        assert(stores[0].member_count == 0 && stores[0].view_count == 1);
        assert(absf(stores[0].reading.soc - 73) <= 0.01f);
        assert(absf(stores[0].reading.full_capacity - 200) <= 0.01f);
    }

    {
        Array!BatteryStoreContribution contributions;
        contributions ~= contribution(battery(d, "pack_a", 50, 100), "dc_bus", BatteryStoreContributionKind.member);
        contributions ~= contribution(battery(d, "pack_b", 60, 100), "dc_bus", BatteryStoreContributionKind.member);

        Array!BatteryStore stores;
        reconcile_battery_stores(contributions, stores);
        assert(stores.length == 1);
        assert(stores[0].member_count == 2);
        assert(absf(stores[0].reading.full_capacity - 200) <= 0.01f);
        assert(absf(stores[0].reading.soc - 55) <= 0.01f);
    }

    {
        Array!BatteryStoreContribution contributions;
        contributions ~= contribution(battery(d, "inverter_view", 20, float.nan), "dc_bus", BatteryStoreContributionKind.view);
        contributions ~= contribution(battery(d, "bms_member", 80, 100), "dc_bus", BatteryStoreContributionKind.member);

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

void collect_battery_store_contributions_impl(Component c, const(char)[] circuit, const(char)[] owner, const(char)[] port_path, BatteryStoreContributionKind kind, ref Array!BatteryStoreContribution into)
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
        finalise_member_totals(s.reading, s.members, s.member_count);
        if (s.views.soc_count != 0 && s.reading.soc == s.reading.soc)
            s.soc_anomaly = absf(avg_soc(s.views) - s.reading.soc) > soc_tolerance;
    }
    else
        finalise_view_totals(s.reading, s.views);
}

void finalise_member_totals(ref BatteryStoreReading reading, ref const ContributionTotals totals, uint member_count)
{
    if (totals.soc_count == member_count)
        reading.soc = (totals.soc_weight > 0 && totals.soc_weight_count == member_count)
            ? totals.soc_weighted / totals.soc_weight
            : totals.soc_plain / member_count;
    if (totals.remain_count == member_count)
        reading.remain_capacity = totals.remain_sum;
    reading.full_capacity = sum_or_nan(totals.full_sum, totals.full_count);
}

void finalise_view_totals(ref BatteryStoreReading reading, ref const ContributionTotals totals)
{
    reading.soc = avg_soc(totals);
    reading.remain_capacity = avg(totals.remain_sum, totals.remain_count);
    reading.full_capacity = avg(totals.full_sum, totals.full_count);
}

BatteryStoreReading read_store(Component c, SysTime now)
{
    BatteryStoreReading r;
    if (c)
    {
        r.soc = read_store_telemetry(c, "soc", Percent, now);
        r.remain_capacity = read_store_telemetry(c, "remain_capacity", AmpereHour, now);
        r.full_capacity = read_in_unit(c.find_element("full_capacity"), AmpereHour);
    }
    return r;
}

float read_store_telemetry(Component c, const(char)[] id, ScaledUnit unit, SysTime now)
{
    Element* e = c ? c.find_element(id) : null;
    return reading_present(e, now) ? read_in_unit(e, unit) : float.nan;
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


unittest
{
    import urt.si.quantity : Quantity;
    import urt.time : dur;
    import manager.device : DeviceTable;

    DeviceTable devices;
    auto builder = devices.create("battery-freshness");
    Component battery = builder.component("battery", "Battery");
    alias Soc = Quantity!(float, Percent);
    alias Capacity = Quantity!(float, AmpereHour);
    Element* soc = builder.element(battery, "soc", register_value_format!Soc());
    Element* remain = builder.element(battery, "remain_capacity", register_value_format!Capacity());
    Element* full = builder.element(battery, "full_capacity", register_value_format!Capacity());
    SysTime now = getSysTime();
    soc.sampling_mode = SamplingMode.poll;
    remain.sampling_mode = SamplingMode.poll;
    full.sampling_mode = SamplingMode.poll;
    soc.value(Soc(50), now);
    remain.value(Capacity(50), now);
    full.value(Capacity(100), now);
    BatteryStoreReading reading = read_store(battery, now);
    assert(reading.soc == 50 && reading.remain_capacity == 50 && reading.full_capacity == 100);

    reading = read_store(battery, now + dur!"seconds"(181));
    assert(reading.soc != reading.soc && reading.remain_capacity != reading.remain_capacity);
    assert(reading.full_capacity == 100);

    Component other = builder.component("other", "Battery");
    builder.element(other, "soc", register_value_format!Soc()).value(Soc(25), now);
    builder.element(other, "remain_capacity", register_value_format!Capacity()).value(Capacity(25), now);
    builder.element(other, "full_capacity", register_value_format!Capacity()).value(Capacity(100), now);
    Array!BatteryStoreContribution contributions;
    foreach (pack; [battery, other])
    {
        BatteryStoreContribution contribution;
        contribution.circuit = "dc";
        contribution.kind = BatteryStoreContributionKind.member;
        contribution.component = pack;
        contributions ~= contribution;
    }
    Array!BatteryStore stores;
    reconcile_battery_stores(contributions, stores);
    assert(stores.length == 1 && stores[0].member_count == 2);
    assert(stores[0].reading.soc == 37.5f && stores[0].reading.remain_capacity == 75);
    assert(stores[0].reading.full_capacity == 200);

    soc.last_update = remain.last_update = now - dur!"seconds"(181);
    reconcile_battery_stores(contributions, stores);
    reading = stores[0].reading;
    assert(reading.soc != reading.soc && reading.remain_capacity != reading.remain_capacity);
    assert(reading.full_capacity == 200);
}
