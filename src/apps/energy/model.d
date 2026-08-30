module apps.energy.model;

import urt.si.unit : ScaledUnit;

import manager.element;

nothrow @nogc:


// Convert through quantity metadata because raw magnitudes can differ by scale
// and offset. Bare values remain dimensionless scale-1 quantities, while
// incompatible dimensions must be rejected because adjust_scale does not.
// TODO: this rejects quietly because it runs per tick. Reporting it belongs in
//       one-shot profile validation.
float read_in_unit(const(Element)* e, ScaledUnit unit)
{
    if (e is null || !e.value.isNumber)
        return float.nan;
    if (e.value.asQuantity().unit.unit != unit.unit)
        return float.nan;
    return cast(float)e.scaled_value(unit);
}


// Kept as float rather than routing through urt.math.fabs, which is the C
// double fabs(double): promoting through double costs a soft-float call on the
// targets without hardware doubles.
float absf(float v) pure
    => v < 0 ? -v : v;

// NaN-equal comparison, for change detection on values that are legitimately NaN
bool same_float(float a, float b) pure
    => a == b || (a != a && b != b);


enum BusType : ubyte { unknown, dc, single_phase, split_phase, three_phase, delta }

bool is_multi_phase(BusType type) pure nothrow @nogc
    => type == BusType.three_phase || type == BusType.delta;

enum FlowDomain : ubyte
{
    unknown,
    consume,
    supply,
    bidirectional,
}

const(char)[] flow_domain_name(FlowDomain f) pure
{
    final switch (f)
    {
        case FlowDomain.unknown:       return "unknown";
        case FlowDomain.consume:       return "consume";
        case FlowDomain.supply:        return "supply";
        case FlowDomain.bidirectional: return "bidirectional";
    }
}

enum MeterSign : ubyte
{
    normal,
    inverted,
}

const(char)[] meter_sign_name(MeterSign s) pure
{
    final switch (s)
    {
        case MeterSign.normal:   return "normal";
        case MeterSign.inverted: return "inverted";
    }
}

MeterSign meter_sign_from_name(const(char)[] value) pure
{
    if (value == "inverted" || value == "invert" || value == "reversed" || value == "reverse")
        return MeterSign.inverted;
    return MeterSign.normal;
}

enum Coverage : ubyte
{
    unknown,
    bounded,
    rogue_value,
    measured,
    estimated,
}

const(char)[] coverage_name(Coverage c) pure
{
    final switch (c)
    {
        case Coverage.unknown:     return "unknown";
        case Coverage.bounded:     return "bounded";
        case Coverage.rogue_value: return "rogue-value";
        case Coverage.measured:    return "measured";
        case Coverage.estimated:   return "estimated";
    }
}

enum PortRole : ubyte
{
    unknown,
    connection,
    parent,
    child,
    grid,
    battery,
    backup,
    car,
    outlet,
    pv,
    dc,
    ac,
}

const(char)[] port_role_name(PortRole r) pure
{
    final switch (r)
    {
        case PortRole.unknown:    return "unknown";
        case PortRole.connection: return "connection";
        case PortRole.parent:     return "parent";
        case PortRole.child:      return "child";
        case PortRole.grid:       return "grid";
        case PortRole.battery:    return "battery";
        case PortRole.backup:     return "backup";
        case PortRole.car:        return "car";
        case PortRole.outlet:     return "outlet";
        case PortRole.pv:         return "pv";
        case PortRole.dc:         return "dc";
        case PortRole.ac:         return "ac";
    }
}


unittest
{
    import urt.mem;
    import urt.si.quantity : Quantity;
    import urt.si.unit : Ampere, AmpereHour, Celsius, Percent, ScaledUnit, Volt;
    import urt.string : StringLit;
    import urt.variant : Variant;

    import manager.series : DataFormat, SeriesKind, ValueType, register_format;

    static Element* elem(double value, ScaledUnit unit)
    {
        Element* e = alloc_element();
        e.id = StringLit!"e";
        e.format = register_format(DataFormat(ValueType.f64, SeriesKind.held, unit));
        e.value = Variant(Quantity!double(value, unit));
        return e;
    }

    static Element* bare(double value)
    {
        Element* e = alloc_element();
        e.id = StringLit!"e";
        e.format = register_value_format(value);
        e.value = Variant(value);
        return e;
    }

    static bool near(float a, float b) => absf(a - b) <= 0.001f;

    assert(near(read_in_unit(elem(60, ScaledUnit(Ampere, -1)), ScaledUnit(Ampere)), 6));
    assert(near(read_in_unit(elem(6, ScaledUnit(Ampere)), ScaledUnit(Ampere)), 6));

    Element* pct = elem(80, Percent);
    assert(near(read_in_unit(pct, Percent), 80));
    assert(near(cast(float)pct.normalised_value(), 0.8f));

    assert(near(read_in_unit(elem(25, Celsius), Celsius), 25));

    // Bare ratios convert to the 0.01-scaled Percent view.
    assert(near(read_in_unit(bare(0.1), Percent), 10));
    assert(near(read_in_unit(bare(0.5), Percent), 50));
    assert(near(read_in_unit(bare(80), Percent), 8000));

    assert(read_in_unit(elem(240, ScaledUnit(Volt)), ScaledUnit(Ampere)) !=
           read_in_unit(elem(240, ScaledUnit(Volt)), ScaledUnit(Ampere)));
    assert(read_in_unit(elem(100, AmpereHour), Percent) !=
           read_in_unit(elem(100, AmpereHour), Percent));

    assert(read_in_unit(null, Percent) != read_in_unit(null, Percent));

    // register_value_format reads a static unit from the type, not the value.
    Element* typed = alloc_element();
    typed.id = StringLit!"soc_floor";
    typed.format = register_value_format!(Quantity!(double, Percent))();
    typed.value = Variant(Quantity!(double, Percent)(50));
    assert(near(read_in_unit(typed, Percent), 50));
}
