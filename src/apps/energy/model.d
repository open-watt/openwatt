module apps.energy.model;

nothrow @nogc:


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
