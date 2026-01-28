module apps.energy.meter;

import urt.si;
import urt.util : log2;

import apps.energy.circuit : CircuitType;

import manager.component;

nothrow @nogc:


enum MeterField : ubyte
{
    voltage,
    inter_phase_voltage,
    current,
    power,
    reactive,
    apparent,
    power_factor,
    frequency,
    phase_angle,
    total_active,
    total_import_active,
    total_export_active,
    total_reactive,
    total_import_reactive,
    total_export_reactive,
    total_apparent,
}

enum FieldFlags : uint
{
    none = 0,
    basic = voltage | inter_phase_voltage| current | power,
    realtime = basic | reactive | apparent | power_factor | frequency | phase_angle,
    basic_cumulative = total_active | total_import_active | total_export_active,
    cumulative = basic_cumulative | total_reactive | total_import_reactive | total_export_reactive | total_apparent,
//    demand = ,
    all = realtime | cumulative, //| demand,

    voltage = 1 << MeterField.voltage,
    inter_phase_voltage = 1 << MeterField.inter_phase_voltage,
    current = 1 << MeterField.current,
    power = 1 << MeterField.power,
    reactive = 1 << MeterField.reactive,
    apparent = 1 << MeterField.apparent,
    power_factor = 1 << MeterField.power_factor,
    frequency = 1 << MeterField.frequency,
    phase_angle = 1 << MeterField.phase_angle,
    total_active = 1 << MeterField.total_active,
    total_import_active = 1 << MeterField.total_import_active,
    total_export_active = 1 << MeterField.total_export_active,
    total_reactive = 1 << MeterField.total_reactive,
    total_import_reactive = 1 << MeterField.total_import_reactive,
    total_export_reactive = 1 << MeterField.total_export_reactive,
    total_apparent = 1 << MeterField.total_apparent,

    // TODO: demand meter?

    // advanced stuff:
    // phase?
    // thd?
    // ...
}

enum num_fields = MeterField.max + 1;
enum cumulative_fields = MeterField.total_active;


alias MeterVolts = Quantity!(float, ScaledUnit(Volt));
alias MeterAmps = Quantity!(float, ScaledUnit(Ampere));
alias MeterWatts = Quantity!(float, ScaledUnit(Watt));

struct MeterData
{
    CircuitType type;
    FieldFlags fields;

    MeterVolts[4] voltage;              // Avg, L1-N, L2-N, L3-N
    MeterVolts[4] cross_phase_voltage;  // Avg, L1-L2, L2-L3, L3-L1
    MeterAmps[4] current;               // Sum, L1, L2, L3
    MeterWatts[4] active;               // Sum, L1, L2, L3

    float[4] reactive = 0;              // Sum, L1, L2, L3
    float[4] apparent = 0;              // Sum, L1, L2, L3
    float[4] pf = 0;                    // Avg, L1, L2, L3
    float freq = 0;
    float[4] phase = 0;                 // INV, L1, L2, L3

    float[4] total_active = 0;          // Sum, L1, L2, L3
    float[4] total_import_active = 0;   // Sum, L1, L2, L3
    float[4] total_export_active = 0;   // Sum, L1, L2, L3
    float[4] total_reactive = 0;        // Sum, L1, L2, L3
    float[4] total_import_reactive = 0; // Sum, L1, L2, L3
    float[4] total_export_reactive = 0; // Sum, L1, L2, L3
    float[4] total_apparent = 0;        // Sum, L1, L2, L3
}

static CircuitType get_meter_type(Component meter)
{
    import manager.element;

    if (!meter)
        return CircuitType.unknown;

    if (meter.template_[] == "RealtimeEnergyMeter" || meter.template_[] == "CumulativeEnergyMeter")
    {
        Element* e = meter.find_element("type");
        // TODO: this should compare to-lower!! (case-insensitive)
        switch(e && e.value.isString ? e.value.asString : "")
        {
            case "dc":              return CircuitType.dc;
            case "single-phase":    return CircuitType.single_phase;
            case "split-phase":     return CircuitType.split_phase;
            case "three-phase":     return CircuitType.three_phase;
            case "delta":           return CircuitType.delta;
            default:                return CircuitType.unknown;
        }
    }

    CircuitType type;
    foreach (c; meter.components)
    {
        if (c.template_[] == "RealtimeEnergyMeter" || c.template_[] == "CumulativeEnergyMeter")
        {
            CircuitType t = get_meter_type(c);
            if (t != CircuitType.unknown)
            {
                if (type != CircuitType.unknown && type != t)
                {
                    assert(type == t, "Inconsistent meter types!");
                    return CircuitType.unknown;
                }
                type = t;
            }
        }
    }
    return type;
}

static MeterData getMeterData(Component meter, FieldFlags fields = FieldFlags.all)
{
    import manager.element;
    import urt.string.format;
    import urt.math : sqrt, fabs, acos, PI;

    __gshared immutable string[num_fields] field_names = [
        "voltage",
        "ipv",      // inter-phase voltage
        "current",
        "power",
        "reactive",
        "apparent",
        "pf",
        "frequency",
        "phase",
        "net",
        "import",
        "export",
        "net_reactive",
        "import_reactive",
        "export_reactive",
        "total_apparent",
    ];

    __gshared immutable FieldFlags[num_fields] field_types = [
        FieldFlags.voltage,
        FieldFlags.inter_phase_voltage,
        FieldFlags.current,
        FieldFlags.power,
        FieldFlags.reactive,
        FieldFlags.apparent,
        FieldFlags.power_factor,
        FieldFlags.frequency,
        FieldFlags.phase_angle,
        FieldFlags.total_active,
        FieldFlags.total_import_active,
        FieldFlags.total_export_active,
        FieldFlags.total_reactive,
        FieldFlags.total_import_reactive,
        FieldFlags.total_export_reactive,
        FieldFlags.total_apparent,
    ];

    Component realtime;
    Component cumulative;

    MeterData r;
    r.type = get_meter_type(meter);

    if (!meter)
        return r;

//    alias Setter = float function(float, bool) nothrow @nogc pure;
//
//    Setter x = (float v, bool set) { if (set) { r.voltage = MeterVolts(v); } return (cast(Quantity!(float, ScaledUnit(Volt)))r.voltage).value; };

    float*[num_fields] f = [
        cast(float*)r.voltage.ptr,
        cast(float*)r.cross_phase_voltage.ptr,
        cast(float*)r.current.ptr,
        cast(float*)r.active.ptr,
        r.reactive.ptr,
        r.apparent.ptr,
        r.pf.ptr,
        &r.freq,
        r.phase.ptr,
        r.total_active.ptr,
        r.total_import_active.ptr,
        r.total_export_active.ptr,
        r.total_reactive.ptr,
        r.total_import_reactive.ptr,
        r.total_export_reactive.ptr,
        r.total_apparent.ptr,
    ];

    if (meter.template_[] == "RealtimeEnergyMeter")
        realtime = meter;
    else if (meter.template_[] == "CumulativeEnergyMeter")
        cumulative = meter;
    else
    {
        foreach (c; meter.components)
        {
            if (c.template_[] == "RealtimeEnergyMeter")
                realtime = c;
            else if (c.template_[] == "CumulativeEnergyMeter")
                cumulative = c;
        }
    }

    bool need_calculate_system_pf;
    for (size_t i = 0, bit = 1; i < num_fields; ++i, bit <<= 1)
    {
        if ((fields & bit) == 0)
            continue;
        Component c = i >= cumulative_fields ? cumulative : realtime;
        if (!c)
            continue;

        // frequency is a global value
        if (i == MeterField.frequency)
        {
            if (Element* e = c.find_element(field_names[i]))
                r.freq = e.scaled_value!Hertz();
            r.fields |= FieldFlags.frequency;
            continue;
        }

        ubyte values_present = 0;
        for (size_t j = 0; j < 4; ++j)
        {
            if (Element* e = c.find_element(j == 0 ? field_names[i] : tconcat(field_names[i], j)))
            {
                f[i][j] = e.normalised_value();
                values_present |= 1 << j;
            }
        }
        if (values_present == 0)
            continue;

        r.fields |= bit;

        // calculate the sums...
        if (r.type == CircuitType.split_phase)
        {
            // a little more complicated to integrate L-L loads...
            // TODO:
        }

        if ((values_present & 1) == 0)
        {
            if (i == MeterField.power_factor)
                need_calculate_system_pf = true;
            else if (i == MeterField.current)
                f[i][0] = sqrt(f[i][1]*f[i][1] + f[i][2]*f[i][2] + f[i][3]*f[i][3]);
            else
            {
                int nearZeroCount = 0;
                for (size_t j = 1; j < 4; ++j)
                {
                    if (values_present & (1 << j))
                    {
                        f[i][0] += f[i][j];
                        if (f[i][j] >= 1)
                            ++nearZeroCount;
                    }
                }

                // voltages are averaged... (or are they?)
                if (hasAvg(i))
                    f[i][0] /= nearZeroCount;
            }
        }

        // if a single-phase meter only read a sum, then assign L1 to match
        if ((values_present & 3) == 1 && r.type == CircuitType.single_phase)
            f[i][1] = f[i][0];
    }

    // if we have an incomplete primary set (V,I,P), then we can calculate the missing values
    enum primary_fields = FieldFlags.voltage | FieldFlags.current | FieldFlags.power;
    if (r.type == CircuitType.dc)
    {
        if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.current))
        {
            foreach (i; 0..4)
                r.active[i] = r.voltage[i] * r.current[i]; // P = VI
            r.fields |= FieldFlags.power;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.power))
        {
            foreach (i; 0..4)
                r.current[i] = r.active[i] / r.voltage[i]; // I = P/V
            r.fields |= FieldFlags.current;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.current | FieldFlags.power))
        {
            foreach (i; 0..4)
                r.voltage[i] = MeterVolts(r.active[i] / r.current[i]); // V = P/I
            r.fields |= FieldFlags.voltage;
        }
    }
    else
    {
        // TODO: AC circuits are much more of a pain in the arse; and we need to assess what details we do know...
        if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.current))
        {
            assert(false, "TODO");
            r.fields |= FieldFlags.power;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.power))
        {
            assert(false, "TODO");
            r.fields |= FieldFlags.current;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.current | FieldFlags.power))
        {
            assert(false, "TODO");
            r.fields |= FieldFlags.voltage;
        }
    }

    // normalise power factor and calcualte phase angle
    foreach (i; 0..4)
    {
        // should we settle on 0 or -1 for invalid pf?
        if (r.pf[i] == -1)
            r.pf[i] = 0;

        if ((r.fields & FieldFlags.phase_angle) == 0 && r.pf[i] != 0)
        {
            // TODO: is reactive signed? what if we don't know reactive? are we guessing at the sign?
            r.phase[i] = -acos(r.pf[i])*(1.0/(2*PI));
            if (r.reactive[i] > 0)
                r.phase[i] = -r.phase[i];
        }
    }

    // should we try and infer missing values?
    // - what kind of meter that can read PF doesn't also read apparent and reactive?
    // - for primitive meters; should we assume PF=1 and assign apparent=active and reactive=0?
    if ((r.fields & (FieldFlags.apparent | FieldFlags.reactive)) == 0)
    {
        if ((r.fields & FieldFlags.power_factor) == 0)
        {
            r.pf = 1;
            foreach (i; 0..4)
                r.apparent[i] = fabs(r.active[i].value);
        }
        else
        {
            import urt.math : sqrt;
            foreach (i; 0..4)
            {
                r.apparent[i] = fabs(r.active[i].value) / r.pf[i];
                r.reactive[i] = -cast(float)sqrt(r.apparent[i]^^2 - r.active[i].value^^2); // assume negative var?
            }
        }
    }

    if (need_calculate_system_pf)
        r.pf[0] = r.active[0].value / r.apparent[0];

//    if ((fields & Cumulative) && !
    // accumulate total since last update?

    import urt.dbg;
    if (r.voltage[0] > Volts(400))
        breakpoint();

    return r;
}


private:

bool hasAvg(size_t field)
{
    if (field == MeterField.voltage || field == MeterField.inter_phase_voltage || field == MeterField.power_factor)
        return true;
    return false;
}
