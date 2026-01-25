module apps.energy.meter;

import urt.si;
import urt.util : log2;

import apps.energy.circuit : CircuitType;

import manager.component;

nothrow @nogc:


enum MeterField : ubyte
{
    Voltage,
    InterPhaseVoltage,
    Current,
    Power,
    Reactive,
    Apparent,
    PowerFactor,
    Frequency,
    PhaseAngle,
    TotalActive,
    TotalImportActive,
    TotalExportActive,
    TotalReactive,
    TotalImportReactive,
    TotalExportReactive,
    TotalApparent,
}

enum FieldFlags : uint
{
    None = 0,
    Basic = Voltage | InterPhaseVoltage| Current | Power,
    Realtime = Basic | Reactive | Apparent | PowerFactor | Frequency | PhaseAngle,
    BasicCumulative = TotalActive | TotalImportActive | TotalExportActive,
    Cumulative = BasicCumulative | TotalReactive | TotalImportReactive | TotalExportReactive | TotalApparent,
//    Demand = ,
    All = Realtime | Cumulative, //| Demand,

    Voltage = 1 << MeterField.Voltage,
    InterPhaseVoltage = 1 << MeterField.InterPhaseVoltage,
    Current = 1 << MeterField.Current,
    Power = 1 << MeterField.Power,
    Reactive = 1 << MeterField.Reactive,
    Apparent = 1 << MeterField.Apparent,
    PowerFactor = 1 << MeterField.PowerFactor,
    Frequency = 1 << MeterField.Frequency,
    PhaseAngle = 1 << MeterField.PhaseAngle,
    TotalActive = 1 << MeterField.TotalActive,
    TotalImportActive = 1 << MeterField.TotalImportActive,
    TotalExportActive = 1 << MeterField.TotalExportActive,
    TotalReactive = 1 << MeterField.TotalReactive,
    TotalImportReactive = 1 << MeterField.TotalImportReactive,
    TotalExportReactive = 1 << MeterField.TotalExportReactive,
    TotalApparent = 1 << MeterField.TotalApparent,

    // TODO: demand meter?

    // advanced stuff:
    // phase?
    // thd?
    // ...
}

enum NumFields = MeterField.max + 1;
enum CumulativeFields = MeterField.TotalActive;


alias MeterVolts = Quantity!(float, ScaledUnit(Volt));
alias MeterAmps = Quantity!(float, ScaledUnit(Ampere));
alias MeterWatts = Quantity!(float, ScaledUnit(Watt));

struct MeterData
{
    CircuitType type;
    FieldFlags fields;

    MeterVolts[4] voltage;              // Avg, L1-N, L2-N, L3-N
    MeterVolts[4] crossPhaseVoltage;    // Avg, L1-L2, L2-L3, L3-L1
    MeterAmps[4] current;               // Sum, L1, L2, L3
    MeterWatts[4] active;               // Sum, L1, L2, L3

    float[4] reactive = 0;              // Sum, L1, L2, L3
    float[4] apparent = 0;              // Sum, L1, L2, L3
    float[4] pf = 0;                    // Avg, L1, L2, L3
    float freq = 0;
    float[4] phase = 0;                 // INV, L1, L2, L3

    float[4] totalActive = 0;           // Sum, L1, L2, L3
    float[4] totalImportActive = 0;     // Sum, L1, L2, L3
    float[4] totalExportActive = 0;     // Sum, L1, L2, L3
    float[4] totalReactive = 0;         // Sum, L1, L2, L3
    float[4] totalImportReactive = 0;   // Sum, L1, L2, L3
    float[4] totalExportReactive = 0;   // Sum, L1, L2, L3
    float[4] totalApparent = 0;         // Sum, L1, L2, L3
}

static CircuitType getMeterType(Component meter)
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
            CircuitType t = getMeterType(c);
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

static MeterData getMeterData(Component meter, FieldFlags fields = FieldFlags.All)
{
    import manager.element;
    import urt.string.format;
    import urt.math : sqrt, fabs, acos, PI;

    __gshared immutable string[NumFields] fieldNames = [
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

    __gshared immutable FieldFlags[NumFields] fieldTypes = [
        FieldFlags.Voltage,
        FieldFlags.InterPhaseVoltage,
        FieldFlags.Current,
        FieldFlags.Power,
        FieldFlags.Reactive,
        FieldFlags.Apparent,
        FieldFlags.PowerFactor,
        FieldFlags.Frequency,
        FieldFlags.PhaseAngle,
        FieldFlags.TotalActive,
        FieldFlags.TotalImportActive,
        FieldFlags.TotalExportActive,
        FieldFlags.TotalReactive,
        FieldFlags.TotalImportReactive,
        FieldFlags.TotalExportReactive,
        FieldFlags.TotalApparent,
    ];

    Component realtime;
    Component cumulative;

    MeterData r;
    r.type = getMeterType(meter);

    if (!meter)
        return r;

//    alias Setter = float function(float, bool) nothrow @nogc pure;
//
//    Setter x = (float v, bool set) { if (set) { r.voltage = MeterVolts(v); } return (cast(Quantity!(float, ScaledUnit(Volt)))r.voltage).value; };

    float*[NumFields] f = [
        cast(float*)r.voltage.ptr,
        cast(float*)r.crossPhaseVoltage.ptr,
        cast(float*)r.current.ptr,
        cast(float*)r.active.ptr,
        r.reactive.ptr,
        r.apparent.ptr,
        r.pf.ptr,
        &r.freq,
        r.phase.ptr,
        r.totalActive.ptr,
        r.totalImportActive.ptr,
        r.totalExportActive.ptr,
        r.totalReactive.ptr,
        r.totalImportReactive.ptr,
        r.totalExportReactive.ptr,
        r.totalApparent.ptr,
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

    bool needCalculateSystemPF;
    for (size_t i = 0, bit = 1; i < NumFields; ++i, bit <<= 1)
    {
        if ((fields & bit) == 0)
            continue;
        Component c = i >= CumulativeFields ? cumulative : realtime;
        if (!c)
            continue;

        // frequency is a global value
        if (i == MeterField.Frequency)
        {
            if (Element* e = c.find_element(fieldNames[i]))
                r.freq = e.scaled_value!Hertz();
            r.fields |= FieldFlags.Frequency;
            continue;
        }

        ubyte valuesPresent = 0;
        for (size_t j = 0; j < 4; ++j)
        {
            if (Element* e = c.find_element(j == 0 ? fieldNames[i] : tconcat(fieldNames[i], j)))
            {
                f[i][j] = e.normalised_value();
                valuesPresent |= 1 << j;
            }
        }
        if (valuesPresent == 0)
            continue;

        r.fields |= bit;

        // calculate the sums...
        if (r.type == CircuitType.split_phase)
        {
            // a little more complicated to integrate L-L loads...
            // TODO:
        }

        if ((valuesPresent & 1) == 0)
        {
            if (i == MeterField.PowerFactor)
                needCalculateSystemPF = true;
            else if (i == MeterField.Current)
                f[i][0] = sqrt(f[i][1]*f[i][1] + f[i][2]*f[i][2] + f[i][3]*f[i][3]);
            else
            {
                int nearZeroCount = 0;
                for (size_t j = 1; j < 4; ++j)
                {
                    if (valuesPresent & (1 << j))
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
        if ((valuesPresent & 3) == 1 && r.type == CircuitType.single_phase)
            f[i][1] = f[i][0];
    }

    // if we have an incomplete primary set (V,I,P), then we can calculate the missing values
    enum primary_fields = FieldFlags.Voltage | FieldFlags.Current | FieldFlags.Power;
    if (r.type == CircuitType.dc)
    {
        if ((r.fields & primary_fields) == (FieldFlags.Voltage | FieldFlags.Current))
        {
            foreach (i; 0..4)
                r.active[i] = r.voltage[i] * r.current[i]; // P = VI
            r.fields |= FieldFlags.Power;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.Voltage | FieldFlags.Power))
        {
            foreach (i; 0..4)
                r.current[i] = r.active[i] / r.voltage[i]; // I = P/V
            r.fields |= FieldFlags.Current;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.Current | FieldFlags.Power))
        {
            foreach (i; 0..4)
                r.voltage[i] = MeterVolts(r.active[i] / r.current[i]); // V = P/I
            r.fields |= FieldFlags.Voltage;
        }
    }
    else
    {
        // TODO: AC circuits are much more of a pain in the arse; and we need to assess what details we do know...
        if ((r.fields & primary_fields) == (FieldFlags.Voltage | FieldFlags.Current))
        {
            assert(false, "TODO");
            r.fields |= FieldFlags.Power;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.Voltage | FieldFlags.Power))
        {
            assert(false, "TODO");
            r.fields |= FieldFlags.Current;
        }
        else if ((r.fields & primary_fields) == (FieldFlags.Current | FieldFlags.Power))
        {
            assert(false, "TODO");
            r.fields |= FieldFlags.Voltage;
        }
    }

    // normalise power factor and calcualte phase angle
    foreach (i; 0..4)
    {
        // should we settle on 0 or -1 for invalid pf?
        if (r.pf[i] == -1)
            r.pf[i] = 0;

        if ((r.fields & FieldFlags.PhaseAngle) == 0 && r.pf[i] != 0)
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
    if ((r.fields & (FieldFlags.Apparent | FieldFlags.Reactive)) == 0)
    {
        if ((r.fields & FieldFlags.PowerFactor) == 0)
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

    if (needCalculateSystemPF)
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
    if (field == MeterField.Voltage || field == MeterField.InterPhaseVoltage || field == MeterField.PowerFactor)
        return true;
    return false;
}
