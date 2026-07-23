module apps.energy.production;

import urt.array;

import apps.energy.meter;

import manager.component;

nothrow @nogc:


enum ProductionContributionKind : ubyte
{
    aggregate,
    member,
}

const(char)[] production_contribution_kind_name(ProductionContributionKind k) pure
{
    final switch (k)
    {
        case ProductionContributionKind.aggregate: return "aggregate";
        case ProductionContributionKind.member:    return "member";
    }
}

struct ProductionContribution
{
    const(char)[] owner;
    const(char)[] group;
    const(char)[] port;
    const(char)[] circuit;
    ProductionContributionKind kind;
    Component component;
    MeterData meter;
}

struct Production
{
    const(char)[] owner;
    const(char)[] group;
    MeterData data;
    float aggregate_power = float.nan;
    float member_power = float.nan;
    uint aggregate_count;
    uint member_count;
    bool calculated;
    bool mismatch;
}

void reconcile_productions(ref Array!ProductionContribution contributions, ref Array!Production productions)
{
    productions.clear();
    foreach (ref c; contributions[])
    {
        Production* p = find_or_add_production(productions, c.owner, c.group);
        if (c.kind == ProductionContributionKind.aggregate)
        {
            ++p.aggregate_count;
            add_power(p.aggregate_power, c.meter);
        }
        else
        {
            ++p.member_count;
            add_power(p.member_power, c.meter);
        }
    }

    foreach (ref p; productions[])
        finalise_production(p);
}

unittest
{
    static MeterData meter(float power, Provenance provenance = Provenance.measured)
    {
        MeterData m;
        m.reset_to_missing();
        m.write_value(MeterField.power, 0, power);
        m.mark(MeterField.power, 0, provenance);
        return m;
    }

    static ProductionContribution contribution(ProductionContributionKind kind, float power)
    {
        ProductionContribution c;
        c.owner = "inverter";
        c.group = "solar";
        c.port = kind == ProductionContributionKind.aggregate ? "solar" : "solar.mppt1";
        c.circuit = kind == ProductionContributionKind.aggregate ? "" : "pv.east";
        c.kind = kind;
        c.meter = meter(power);
        return c;
    }

    // Without an aggregate Solar meter, production is calculated from PV ports.
    {
        Array!ProductionContribution contributions;
        contributions ~= contribution(ProductionContributionKind.member, 100);
        contributions ~= contribution(ProductionContributionKind.member, 250);

        Array!Production productions;
        reconcile_productions(contributions, productions);

        assert(productions.length == 1);
        assert(productions[0].owner == "inverter");
        assert(productions[0].group == "solar");
        assert(productions[0].member_count == 2);
        assert(productions[0].aggregate_count == 0);
        assert(productions[0].calculated);
        assert(absf(productions[0].data.active[0].value - 350) <= 0.01f);
        assert(productions[0].data.source(MeterField.power) == Provenance.inferred_sum);
    }

    // An aggregate Solar meter is authoritative, with members retained as a
    // cross-check.
    {
        Array!ProductionContribution contributions;
        contributions ~= contribution(ProductionContributionKind.aggregate, 360);
        contributions ~= contribution(ProductionContributionKind.member, 100);
        contributions ~= contribution(ProductionContributionKind.member, 250);

        Array!Production productions;
        reconcile_productions(contributions, productions);

        assert(productions.length == 1);
        assert(!productions[0].calculated);
        assert(!productions[0].mismatch);
        assert(absf(productions[0].data.active[0].value - 360) <= 0.01f);
        assert(productions[0].data.source(MeterField.power) == Provenance.measured);
    }

    // A materially different aggregate/member total is flagged.
    {
        Array!ProductionContribution contributions;
        contributions ~= contribution(ProductionContributionKind.aggregate, 500);
        contributions ~= contribution(ProductionContributionKind.member, 100);
        contributions ~= contribution(ProductionContributionKind.member, 250);

        Array!Production productions;
        reconcile_productions(contributions, productions);

        assert(productions.length == 1);
        assert(productions[0].mismatch);
        assert(absf(productions[0].data.active[0].value - 500) <= 0.01f);
    }
}

private:

enum mismatch_noise_floor_w = 50.0f;

Production* find_or_add_production(ref Array!Production productions,
                                   const(char)[] owner, const(char)[] group)
{
    foreach (ref p; productions[])
        if (p.owner == owner && p.group == group)
            return &p;

    Production p;
    p.owner = owner;
    p.group = group;
    productions ~= p;
    return &productions[productions.length - 1];
}

void add_power(ref float total, ref const MeterData meter) pure
{
    if (!meter.has(MeterField.power))
        return;
    if (total != total)
        total = 0;
    total += meter.active[0].value;
}

// Terminal-vs-boundary selection (which ports contribute at all) happens upstream
// at topology.rebuild_productions per the metering convention in accounts.d. This
// site only reconciles WITHIN one source: the aggregate Solar meter is
// authoritative when present, else the per-input members (MPPT strings, optimiser
// or micro reports sharing the owner's group) are summed, with a mismatch flag as
// the cross-check.
void finalise_production(ref Production p)
{
    p.data.reset_to_missing();
    float selected = p.aggregate_power == p.aggregate_power ? p.aggregate_power : p.member_power;
    if (selected != selected)
        return;
    p.calculated = p.aggregate_power != p.aggregate_power && p.member_power == p.member_power;
    p.data.write_value(MeterField.power, 0, selected);
    p.data.mark(MeterField.power, 0, p.calculated ? Provenance.inferred_sum : Provenance.measured);
    if (p.aggregate_power == p.aggregate_power && p.member_power == p.member_power)
        p.mismatch = absf(p.aggregate_power - p.member_power) > mismatch_noise_floor_w;
}

float absf(float value) pure
{
    return value < 0 ? -value : value;
}
