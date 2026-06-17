module apps.energy.meter;

import urt.si;
import urt.util : log2;

import apps.energy.circuit : CircuitType, is_multi_phase;

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
    total_active,                   // signed net = import - export
    total_import_active,
    total_export_active,
    total_absolute_active,          // gross = import + export
    total_reactive,                 // signed net = inductive - capacitive
    total_inductive,                // q1 + q2
    total_capacitive,               // q3 + q4
    total_absolute_reactive,        // q1 + q2 + q3 + q4
    total_reactive_import,          // q1 + q4 (reactive while active import)
    total_reactive_export,          // q2 + q3 (reactive while active export)
    total_apparent,
    total_apparent_import,
    total_apparent_export,
}

enum FieldFlags : uint
{
    none = 0,
    basic = voltage | inter_phase_voltage | current | power,
    realtime = basic | reactive | apparent | power_factor | frequency | phase_angle,
    basic_cumulative = total_active | total_import_active | total_export_active,
    cumulative = basic_cumulative | total_absolute_active
               | total_reactive | total_inductive | total_capacitive | total_absolute_reactive
               | total_reactive_import | total_reactive_export
               | total_apparent | total_apparent_import | total_apparent_export,
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
    total_absolute_active = 1 << MeterField.total_absolute_active,
    total_reactive = 1 << MeterField.total_reactive,
    total_inductive = 1 << MeterField.total_inductive,
    total_capacitive = 1 << MeterField.total_capacitive,
    total_absolute_reactive = 1 << MeterField.total_absolute_reactive,
    total_reactive_import = 1 << MeterField.total_reactive_import,
    total_reactive_export = 1 << MeterField.total_reactive_export,
    total_apparent = 1 << MeterField.total_apparent,
    total_apparent_import = 1 << MeterField.total_apparent_import,
    total_apparent_export = 1 << MeterField.total_apparent_export,

    // TODO: demand meter?

    // advanced stuff:
    // phase?
    // thd?
    // ...
}

enum num_fields = MeterField.max + 1;
enum cumulative_fields = MeterField.total_active;


// Where a (field, phase) cell's value came from.
// missing carries NaN; everything else carries a real value.
enum Provenance : ubyte
{
    missing = 0,            // no data; value is NaN
    measured,               // direct read from a meter element
    synthesized,            // computed from primary measurements on the same meter (P=VI, P/Q/S triangle, etc.)
    quadrant_derived,       // cumulative reactive derived from q1..q4 elements
    inferred_sum,           // sum of children's values (unmetered circuit)
    inferred_subtraction,   // parent minus other known children
    rogue,                  // unaccounted remainder at a metered circuit
}


alias MeterVolts = Quantity!(float, ScaledUnit(Volt));
alias MeterAmps = Quantity!(float, ScaledUnit(Ampere));
alias MeterWatts = Quantity!(float, ScaledUnit(Watt));

struct MeterData
{
nothrow @nogc:

    CircuitType type;
    FieldFlags fields;

    // Per-(field, phase) provenance. provenance[field][phase] == Provenance.missing means value is NaN.
    // Provenance is the per-cell source-of-truth; the `fields` bitmask is kept as a derived summary
    // for cheap "anything for this field?" queries.
    Provenance[4][num_fields] provenance;

    MeterVolts[4] voltage;              // Avg, L1-N, L2-N, L3-N
    MeterVolts[4] cross_phase_voltage;  // Avg, L1-L2, L2-L3, L3-L1
    MeterAmps[4] current;               // Sum, L1, L2, L3
    MeterWatts[4] active;               // Sum, L1, L2, L3

    float[4] reactive = 0;              // Sum, L1, L2, L3
    float[4] apparent = 0;              // Sum, L1, L2, L3
    float[4] pf = 0;                    // Avg, L1, L2, L3 (magnitude, always >= 0)
    float freq = 0;
    float[4] phase = 0;                 // Avg, L1, L2, L3 (degrees; signed by reactive)

    float[4] total_active = 0;              // signed net (= import - export)
    float[4] total_import_active = 0;
    float[4] total_export_active = 0;
    float[4] total_absolute_active = 0;     // gross (= import + export)

    float[4] total_reactive = 0;            // signed net (= inductive - capacitive)
    float[4] total_inductive = 0;           // q1 + q2
    float[4] total_capacitive = 0;          // q3 + q4
    float[4] total_absolute_reactive = 0;   // |q1|+|q2|+|q3|+|q4| (= inductive + capacitive)
    float[4] total_reactive_import = 0;     // q1 + q4
    float[4] total_reactive_export = 0;     // q2 + q3

    float[4] total_apparent = 0;
    float[4] total_apparent_import = 0;
    float[4] total_apparent_export = 0;

    bool has(MeterField field, ubyte phase = 0) const pure
        => provenance[field][phase] != Provenance.missing;

    Provenance source(MeterField field, ubyte phase = 0) const pure
        => provenance[field][phase];

    bool is_measured(MeterField field, ubyte phase = 0) const pure
        => provenance[field][phase] == Provenance.measured;

    bool is_inferred(MeterField field, ubyte phase = 0) const pure
    {
        Provenance p = provenance[field][phase];
        return p == Provenance.inferred_sum || p == Provenance.inferred_subtraction || p == Provenance.rogue;
    }

    ubyte phases_present(MeterField field) const pure
    {
        ubyte mask = 0;
        foreach (j; 0..4)
            if (provenance[field][j] != Provenance.missing)
                mask |= cast(ubyte)(1 << j);
        return mask;
    }

    // Reset value cells to NaN and provenance to missing.
    // Called when populating fresh state (start of get_meter_data, before inference rounds, etc.)
    void reset_to_missing() pure
    {
        fields = FieldFlags.none;
        foreach (i; 0..num_fields)
            provenance[i][] = Provenance.missing;
        foreach (j; 0..4)
        {
            voltage[j] = MeterVolts.nan;
            cross_phase_voltage[j] = MeterVolts.nan;
            current[j] = MeterAmps.nan;
            active[j] = MeterWatts.nan;
            reactive[j] = float.nan;
            apparent[j] = float.nan;
            pf[j] = float.nan;
            phase[j] = float.nan;
            total_active[j] = float.nan;
            total_import_active[j] = float.nan;
            total_export_active[j] = float.nan;
            total_absolute_active[j] = float.nan;
            total_reactive[j] = float.nan;
            total_inductive[j] = float.nan;
            total_capacitive[j] = float.nan;
            total_absolute_reactive[j] = float.nan;
            total_reactive_import[j] = float.nan;
            total_reactive_export[j] = float.nan;
            total_apparent[j] = float.nan;
            total_apparent_import[j] = float.nan;
            total_apparent_export[j] = float.nan;
        }
        freq = float.nan;
    }

    // Set a (field, phase) cell's provenance and update the fields bitmask summary.
    // Callers set the value directly via the value arrays; this just records where it came from.
    void mark(MeterField field, ubyte phase, Provenance prov) pure
    {
        provenance[field][phase] = prov;
        if (prov != Provenance.missing)
            fields |= cast(FieldFlags)(1 << field);
    }

    // Generic read/write of a (field, phase) cell as a plain float.
    // Used by circuit-level inference that iterates over fields by enum.
    float read_value(MeterField field, ubyte phase = 0) const pure
    {
        final switch (field)
        {
            case MeterField.voltage:                 return voltage[phase].value;
            case MeterField.inter_phase_voltage:     return cross_phase_voltage[phase].value;
            case MeterField.current:                 return current[phase].value;
            case MeterField.power:                   return active[phase].value;
            case MeterField.reactive:                return reactive[phase];
            case MeterField.apparent:                return apparent[phase];
            case MeterField.power_factor:            return pf[phase];
            case MeterField.frequency:               return freq;
            case MeterField.phase_angle:             return this.phase[phase];
            case MeterField.total_active:            return total_active[phase];
            case MeterField.total_import_active:     return total_import_active[phase];
            case MeterField.total_export_active:     return total_export_active[phase];
            case MeterField.total_absolute_active:   return total_absolute_active[phase];
            case MeterField.total_reactive:          return total_reactive[phase];
            case MeterField.total_inductive:         return total_inductive[phase];
            case MeterField.total_capacitive:        return total_capacitive[phase];
            case MeterField.total_absolute_reactive: return total_absolute_reactive[phase];
            case MeterField.total_reactive_import:   return total_reactive_import[phase];
            case MeterField.total_reactive_export:   return total_reactive_export[phase];
            case MeterField.total_apparent:          return total_apparent[phase];
            case MeterField.total_apparent_import:   return total_apparent_import[phase];
            case MeterField.total_apparent_export:   return total_apparent_export[phase];
        }
    }

    void write_value(MeterField field, ubyte phase, float value) pure
    {
        final switch (field)
        {
            case MeterField.voltage:                 voltage[phase] = MeterVolts(value); break;
            case MeterField.inter_phase_voltage:     cross_phase_voltage[phase] = MeterVolts(value); break;
            case MeterField.current:                 current[phase] = MeterAmps(value); break;
            case MeterField.power:                   active[phase] = MeterWatts(value); break;
            case MeterField.reactive:                reactive[phase] = value; break;
            case MeterField.apparent:                apparent[phase] = value; break;
            case MeterField.power_factor:            pf[phase] = value; break;
            case MeterField.frequency:               freq = value; break;
            case MeterField.phase_angle:             this.phase[phase] = value; break;
            case MeterField.total_active:            total_active[phase] = value; break;
            case MeterField.total_import_active:     total_import_active[phase] = value; break;
            case MeterField.total_export_active:     total_export_active[phase] = value; break;
            case MeterField.total_absolute_active:   total_absolute_active[phase] = value; break;
            case MeterField.total_reactive:          total_reactive[phase] = value; break;
            case MeterField.total_inductive:         total_inductive[phase] = value; break;
            case MeterField.total_capacitive:        total_capacitive[phase] = value; break;
            case MeterField.total_absolute_reactive: total_absolute_reactive[phase] = value; break;
            case MeterField.total_reactive_import:   total_reactive_import[phase] = value; break;
            case MeterField.total_reactive_export:   total_reactive_export[phase] = value; break;
            case MeterField.total_apparent:          total_apparent[phase] = value; break;
            case MeterField.total_apparent_import:   total_apparent_import[phase] = value; break;
            case MeterField.total_apparent_export:   total_apparent_export[phase] = value; break;
        }
    }
}

static CircuitType get_meter_type(Component meter)
{
    import manager.element;

    if (!meter)
        return CircuitType.unknown;

    Element* e = meter.find_element("type");
    // TODO: this should compare to-lower!! (case-insensitive)
    switch(e && e.value.isString ? e.value.asString : "")
    {
        case "dc":              return CircuitType.dc;
        case "single-phase":    return CircuitType.single_phase;
        case "split-phase":     return CircuitType.split_phase;
        case "three-phase":     return CircuitType.three_phase;
        case "delta":           return CircuitType.delta;
        default:                break;
    }
    return CircuitType.unknown;
}

MeterData extract_phase(ref const MeterData raw, CircuitType type, ubyte meter_phase) pure
{
    MeterData r;
    r.reset_to_missing();
    r.type = type;

    // Slot 0 of the result is the phase being extracted (or the same slot if meter_phase==0)
    r.voltage[0] = raw.voltage[meter_phase];
    r.cross_phase_voltage[0] = raw.cross_phase_voltage[meter_phase];
    r.current[0] = raw.current[meter_phase];
    r.active[0] = raw.active[meter_phase];
    r.reactive[0] = raw.reactive[meter_phase];
    r.apparent[0] = raw.apparent[meter_phase];
    r.pf[0] = raw.pf[meter_phase];
    r.freq = raw.freq;
    r.phase[0] = raw.phase[meter_phase];
    r.total_active[0] = raw.total_active[meter_phase];
    r.total_import_active[0] = raw.total_import_active[meter_phase];
    r.total_export_active[0] = raw.total_export_active[meter_phase];
    r.total_absolute_active[0] = raw.total_absolute_active[meter_phase];
    r.total_reactive[0] = raw.total_reactive[meter_phase];
    r.total_inductive[0] = raw.total_inductive[meter_phase];
    r.total_capacitive[0] = raw.total_capacitive[meter_phase];
    r.total_absolute_reactive[0] = raw.total_absolute_reactive[meter_phase];
    r.total_reactive_import[0] = raw.total_reactive_import[meter_phase];
    r.total_reactive_export[0] = raw.total_reactive_export[meter_phase];
    r.total_apparent[0] = raw.total_apparent[meter_phase];
    r.total_apparent_import[0] = raw.total_apparent_import[meter_phase];
    r.total_apparent_export[0] = raw.total_apparent_export[meter_phase];

    foreach (i; 0..num_fields)
    {
        // Frequency is global (no per-phase variant).
        Provenance p = (i == MeterField.frequency)
            ? raw.provenance[i][0]
            : raw.provenance[i][meter_phase];
        r.provenance[i][0] = p;
        if (p != Provenance.missing)
            r.fields |= cast(FieldFlags)(1 << i);
    }

    if (is_multi_phase(r.type))
    {
        r.voltage[1..4] = raw.voltage[1..4];
        r.cross_phase_voltage[1..4] = raw.cross_phase_voltage[1..4];
        r.current[1..4] = raw.current[1..4];
        r.active[1..4] = raw.active[1..4];
        r.reactive[1..4] = raw.reactive[1..4];
        r.apparent[1..4] = raw.apparent[1..4];
        r.pf[1..4] = raw.pf[1..4];
        r.phase[1..4] = raw.phase[1..4];
        r.total_active[1..4] = raw.total_active[1..4];
        r.total_import_active[1..4] = raw.total_import_active[1..4];
        r.total_export_active[1..4] = raw.total_export_active[1..4];
        r.total_absolute_active[1..4] = raw.total_absolute_active[1..4];
        r.total_reactive[1..4] = raw.total_reactive[1..4];
        r.total_inductive[1..4] = raw.total_inductive[1..4];
        r.total_capacitive[1..4] = raw.total_capacitive[1..4];
        r.total_absolute_reactive[1..4] = raw.total_absolute_reactive[1..4];
        r.total_reactive_import[1..4] = raw.total_reactive_import[1..4];
        r.total_reactive_export[1..4] = raw.total_reactive_export[1..4];
        r.total_apparent[1..4] = raw.total_apparent[1..4];
        r.total_apparent_import[1..4] = raw.total_apparent_import[1..4];
        r.total_apparent_export[1..4] = raw.total_apparent_export[1..4];

        foreach (i; 0..num_fields)
        {
            foreach (j; 1..4)
            {
                r.provenance[i][j] = raw.provenance[i][j];
                if (raw.provenance[i][j] != Provenance.missing)
                    r.fields |= cast(FieldFlags)(1 << i);
            }
        }
    }

    return r;
}

static MeterData get_meter_data(Component meter, FieldFlags fields = FieldFlags.all)
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
        "absolute",
        "net_reactive",
        "inductive",
        "capacitive",
        "absolute_reactive",
        "reactive_import",
        "reactive_export",
        "total_apparent",
        "apparent_import",
        "apparent_export",
    ];

    MeterData r;
    r.reset_to_missing();
    r.type = get_meter_type(meter);

    if (!meter)
        return r;

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
        r.total_absolute_active.ptr,
        r.total_reactive.ptr,
        r.total_inductive.ptr,
        r.total_capacitive.ptr,
        r.total_absolute_reactive.ptr,
        r.total_reactive_import.ptr,
        r.total_reactive_export.ptr,
        r.total_apparent.ptr,
        r.total_apparent_import.ptr,
        r.total_apparent_export.ptr,
    ];

    // Local parallel to r.provenance for cells discovered during element-read synthesis.
    // Kept because the synthesis paths below test it cheaply; r.provenance is updated alongside.
    ubyte[num_fields] present;

    bool need_calculate_system_pf;
    for (size_t i = 0, bit = 1; i < num_fields; ++i, bit <<= 1)
    {
        if ((fields & bit) == 0)
            continue;

        // frequency is a global value
        if (i == MeterField.frequency)
        {
            if (Element* e = meter.find_element(field_names[i]))
            {
                double v = e.scaled_value!Hertz();
                if (v == v)
                {
                    r.freq = v;
                    r.mark(MeterField.frequency, 0, Provenance.measured);
                    present[i] = 1;
                }
            }
            continue;
        }

        ubyte values_present = 0;
        for (size_t j = 0; j < 4; ++j)
        {
            if (Element* e = meter.find_element(j == 0 ? field_names[i] : tconcat(field_names[i], j)))
            {
                double v = e.normalised_value();
                if (v == v)
                {
                    f[i][j] = v;
                    values_present |= 1 << j;
                    r.mark(cast(MeterField)i, cast(ubyte)j, Provenance.measured);
                }
            }
        }
        if (values_present == 0)
            continue;

        present[i] = values_present;

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
            {
                float ssum = 0;
                bool any = false;
                for (size_t j = 1; j < 4; ++j)
                {
                    if (values_present & (1 << j))
                    {
                        ssum += f[i][j] * f[i][j];
                        any = true;
                    }
                }
                if (any)
                {
                    f[i][0] = sqrt(ssum);
                    present[i] |= 1;
                    r.mark(MeterField.current, 0, Provenance.synthesized);
                }
            }
            else
            {
                int contrib = 0;
                float sum = 0;
                for (size_t j = 1; j < 4; ++j)
                {
                    if (values_present & (1 << j))
                    {
                        sum += f[i][j];
                        if (f[i][j] >= 1)
                            ++contrib;
                    }
                }
                // voltages/pf get averaged across contributing phases; everything else sums
                if (hasAvg(i) && contrib > 0)
                    f[i][0] = sum / contrib;
                else
                    f[i][0] = sum;
                present[i] |= 1;
                r.mark(cast(MeterField)i, 0, Provenance.synthesized);
            }
        }

        // single-phase meter that only reported a system total: project to L1
        if ((values_present & 3) == 1 && r.type == CircuitType.single_phase)
        {
            f[i][1] = f[i][0];
            present[i] |= 2;
            r.mark(cast(MeterField)i, 1, Provenance.synthesized);
        }
    }

    // Reactive quadrants (q1..q4): scalar inputs to inductive/capacitive/reactive_*/net_reactive synthesis
    float[4] q = 0;
    ubyte q_present;
    if (fields & (FieldFlags.total_inductive | FieldFlags.total_capacitive | FieldFlags.total_absolute_reactive
                  | FieldFlags.total_reactive | FieldFlags.total_reactive_import | FieldFlags.total_reactive_export))
    {
        static immutable string[4] q_names = ["q1", "q2", "q3", "q4"];
        foreach (n; 0..4)
        {
            if (Element* e = meter.find_element(q_names[n]))
            {
                double v = e.normalised_value();
                if (v == v)
                {
                    q[n] = v;
                    q_present |= 1 << n;
                }
            }
        }
    }

    // if we have an incomplete primary set (V,I,P), then we can calculate the missing values
    // (per-phase: NaN propagates where inputs are absent; provenance is set only where both inputs existed)
    enum primary_fields = FieldFlags.voltage | FieldFlags.current | FieldFlags.power;
    if (r.type == CircuitType.dc)
    {
        if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.current))
        {
            foreach (i; 0..4)
            {
                r.active[i] = r.voltage[i] * r.current[i]; // P = VI
                if (r.has(MeterField.voltage, cast(ubyte)i) && r.has(MeterField.current, cast(ubyte)i))
                    r.mark(MeterField.power, cast(ubyte)i, Provenance.synthesized);
            }
        }
        else if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.power))
        {
            foreach (i; 0..4)
            {
                r.current[i] = r.active[i] / r.voltage[i]; // I = P/V
                if (r.has(MeterField.voltage, cast(ubyte)i) && r.has(MeterField.power, cast(ubyte)i))
                    r.mark(MeterField.current, cast(ubyte)i, Provenance.synthesized);
            }
        }
        else if ((r.fields & primary_fields) == (FieldFlags.current | FieldFlags.power))
        {
            foreach (i; 0..4)
            {
                r.voltage[i] = MeterVolts(r.active[i] / r.current[i]); // V = P/I
                if (r.has(MeterField.current, cast(ubyte)i) && r.has(MeterField.power, cast(ubyte)i))
                    r.mark(MeterField.voltage, cast(ubyte)i, Provenance.synthesized);
            }
        }
    }
    else
    {
        if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.current))
        {
            // S = V*I; P only recoverable with PF; Q only with PF too (sign assumed)
            const bool has_pf = (r.fields & FieldFlags.power_factor) != 0;
            foreach (i; 0..4)
            {
                float s = r.voltage[i].value * r.current[i].value;
                r.apparent[i] = s;
                const bool vi_present = r.has(MeterField.voltage, cast(ubyte)i) && r.has(MeterField.current, cast(ubyte)i);
                if (vi_present)
                    r.mark(MeterField.apparent, cast(ubyte)i, Provenance.synthesized);
                if (has_pf)
                {
                    r.active[i].value = s * r.pf[i];
                    if (vi_present && r.has(MeterField.power_factor, cast(ubyte)i))
                        r.mark(MeterField.power, cast(ubyte)i, Provenance.synthesized);
                }
            }
        }
        else if ((r.fields & primary_fields) == (FieldFlags.voltage | FieldFlags.power))
        {
            const bool has_pf = (r.fields & FieldFlags.power_factor) != 0;
            foreach (i; 0..4)
            {
                if (r.voltage[i] == MeterVolts(0))
                    r.current[i] = MeterAmps(0);
                else if (has_pf && r.pf[i] > 0)
                    r.current[i].value = r.active[i].value / (r.voltage[i].value * r.pf[i]);
                else
                    r.current[i].value = r.active[i].value / r.voltage[i].value; // assume PF=1
                if (r.has(MeterField.voltage, cast(ubyte)i) && r.has(MeterField.power, cast(ubyte)i))
                    r.mark(MeterField.current, cast(ubyte)i, Provenance.synthesized);
            }
        }
        else if ((r.fields & primary_fields) == (FieldFlags.current | FieldFlags.power))
        {
            const bool has_s = (r.fields & FieldFlags.apparent) != 0;
            foreach (i; 0..4)
            {
                if (r.current[i] == MeterAmps(0))
                    r.voltage[i] = MeterVolts(0);
                else if (has_s)
                    r.voltage[i] = MeterWatts(r.apparent[i]) / r.current[i]; // V = VA/I
                else
                    r.voltage[i] = r.active[i] / r.current[i]; // V = P/I (assuming PF=1)
                if (r.has(MeterField.current, cast(ubyte)i) && r.has(MeterField.power, cast(ubyte)i))
                    r.mark(MeterField.voltage, cast(ubyte)i, Provenance.synthesized);
            }
        }
    }

    // Normalise PF: -1 is the "invalid" sentinel; otherwise treat the value as magnitude
    // (direction is conveyed by the sign of active power, not by PF).
    foreach (i; 0..4)
    {
        if (r.pf[i] == -1)
        {
            r.pf[i] = float.nan;
            present[MeterField.power_factor] &= ~cast(ubyte)(1 << i);
            r.provenance[MeterField.power_factor][i] = Provenance.missing;
        }
        else if (r.pf[i] < 0)
            r.pf[i] = -r.pf[i];
    }
    // Rebuild fields bit for PF since some phases may have been invalidated above.
    if (r.phases_present(MeterField.power_factor) == 0)
        r.fields &= ~FieldFlags.power_factor;

    // P/Q/S triangle: fill in missing legs from the others
    {
        const bool have_p = (r.fields & FieldFlags.power) != 0;
        const bool have_q = (r.fields & FieldFlags.reactive) != 0;
        const bool have_s = (r.fields & FieldFlags.apparent) != 0;
        const bool have_pf = (r.fields & FieldFlags.power_factor) != 0;

        if (have_p && have_q && !have_s)
        {
            foreach (i; 0..4)
            {
                float p = r.active[i].value;
                r.apparent[i] = sqrt(p*p + r.reactive[i]*r.reactive[i]);
                if (r.has(MeterField.power, cast(ubyte)i) && r.has(MeterField.reactive, cast(ubyte)i))
                    r.mark(MeterField.apparent, cast(ubyte)i, Provenance.synthesized);
            }
        }
        else if (have_p && have_pf && !have_s)
        {
            foreach (i; 0..4)
            {
                float p = r.active[i].value;
                r.apparent[i] = r.pf[i] > 0 ? fabs(p) / r.pf[i] : 0;
                if (r.has(MeterField.power, cast(ubyte)i) && r.has(MeterField.power_factor, cast(ubyte)i))
                    r.mark(MeterField.apparent, cast(ubyte)i, Provenance.synthesized);
            }
        }

        const bool s_now = (r.fields & FieldFlags.apparent) != 0;
        if (have_p && s_now && !have_q)
        {
            // Sign of Q is unknowable without phase info; assume capacitive (negative var),
            // matching long-standing meter convention here.
            foreach (i; 0..4)
            {
                float p = r.active[i].value;
                float s = r.apparent[i];
                float q_mag = s*s - p*p;
                r.reactive[i] = q_mag > 0 ? -cast(float)sqrt(q_mag) : 0;
                if (r.has(MeterField.power, cast(ubyte)i) && r.has(MeterField.apparent, cast(ubyte)i))
                    r.mark(MeterField.reactive, cast(ubyte)i, Provenance.synthesized);
            }
        }

        if (have_p && s_now && !have_pf)
        {
            foreach (i; 0..4)
            {
                float p = r.active[i].value;
                float s = r.apparent[i];
                r.pf[i] = s > 0 ? fabs(p) / s : (p != 0 ? 1 : 0);
                if (r.has(MeterField.power, cast(ubyte)i) && r.has(MeterField.apparent, cast(ubyte)i))
                    r.mark(MeterField.power_factor, cast(ubyte)i, Provenance.synthesized);
            }
        }
    }

    if (need_calculate_system_pf && (r.fields & FieldFlags.apparent))
    {
        r.pf[0] = r.apparent[0] > 0 ? fabs(r.active[0].value) / r.apparent[0] : 0;
        if (r.has(MeterField.power, 0) && r.has(MeterField.apparent, 0))
            r.mark(MeterField.power_factor, 0, Provenance.synthesized);
    }

    // Phase angle in degrees; signed by reactive sign (inductive -> +, capacitive -> -).
    // Only fill phases where it wasn't reported and PF is known and finite.
    if (r.fields & FieldFlags.power_factor)
    {
        foreach (i; 0..4)
        {
            if (present[MeterField.phase_angle] & (1 << i))
                continue;
            if (!(present[MeterField.power_factor] & (1 << i)))
                continue;
            if (r.pf[i] <= 0 || r.pf[i] > 1)
                continue;
            float phi = cast(float)(acos(r.pf[i]) * (180.0/PI));
            if (r.reactive[i] < 0)
                phi = -phi;
            r.phase[i] = phi;
            present[MeterField.phase_angle] |= 1 << i;
            r.mark(MeterField.phase_angle, cast(ubyte)i, Provenance.synthesized);
        }
    }

    // ===== Cumulative synthesis: active energy =====
    // import + export <-> net + absolute (lossless pair conversion)
    {
        const bool have_imp = (r.fields & FieldFlags.total_import_active) != 0;
        const bool have_exp = (r.fields & FieldFlags.total_export_active) != 0;
        const bool have_net = (r.fields & FieldFlags.total_active) != 0;
        const bool have_abs = (r.fields & FieldFlags.total_absolute_active) != 0;

        if (have_imp && have_exp)
        {
            const ubyte pm = present[MeterField.total_import_active] & present[MeterField.total_export_active];
            if (pm)
            {
                if (!have_net)
                {
                    foreach (i; 0..4) if (pm & (1 << i))
                    {
                        r.total_active[i] = r.total_import_active[i] - r.total_export_active[i];
                        r.mark(MeterField.total_active, cast(ubyte)i, Provenance.synthesized);
                        present[MeterField.total_active] |= cast(ubyte)(1 << i);
                    }
                }
                if (!have_abs)
                {
                    foreach (i; 0..4) if (pm & (1 << i))
                    {
                        r.total_absolute_active[i] = r.total_import_active[i] + r.total_export_active[i];
                        r.mark(MeterField.total_absolute_active, cast(ubyte)i, Provenance.synthesized);
                        present[MeterField.total_absolute_active] |= cast(ubyte)(1 << i);
                    }
                }
            }
        }
        else if (have_net && have_abs)
        {
            const ubyte pm = present[MeterField.total_active] & present[MeterField.total_absolute_active];
            if (pm)
            {
                if (!have_imp)
                {
                    foreach (i; 0..4) if (pm & (1 << i))
                    {
                        r.total_import_active[i] = (r.total_active[i] + r.total_absolute_active[i]) * 0.5f;
                        r.mark(MeterField.total_import_active, cast(ubyte)i, Provenance.synthesized);
                        present[MeterField.total_import_active] |= cast(ubyte)(1 << i);
                    }
                }
                if (!have_exp)
                {
                    foreach (i; 0..4) if (pm & (1 << i))
                    {
                        r.total_export_active[i] = (r.total_absolute_active[i] - r.total_active[i]) * 0.5f;
                        r.mark(MeterField.total_export_active, cast(ubyte)i, Provenance.synthesized);
                        present[MeterField.total_export_active] |= cast(ubyte)(1 << i);
                    }
                }
            }
        }
    }

    // ===== Cumulative synthesis: reactive energy =====
    // From q1..q4 (system-level only - quadrant elements have no per-phase variant)
    if (q_present == 0x0F)
    {
        const float ind = q[0] + q[1];
        const float cap = q[2] + q[3];
        const float imp = q[0] + q[3];
        const float exp = q[1] + q[2];
        if (!(r.fields & FieldFlags.total_inductive))
        {
            r.total_inductive[0] = ind;
            r.mark(MeterField.total_inductive, 0, Provenance.quadrant_derived);
            present[MeterField.total_inductive] |= 1;
        }
        if (!(r.fields & FieldFlags.total_capacitive))
        {
            r.total_capacitive[0] = cap;
            r.mark(MeterField.total_capacitive, 0, Provenance.quadrant_derived);
            present[MeterField.total_capacitive] |= 1;
        }
        if (!(r.fields & FieldFlags.total_reactive_import))
        {
            r.total_reactive_import[0] = imp;
            r.mark(MeterField.total_reactive_import, 0, Provenance.quadrant_derived);
            present[MeterField.total_reactive_import] |= 1;
        }
        if (!(r.fields & FieldFlags.total_reactive_export))
        {
            r.total_reactive_export[0] = exp;
            r.mark(MeterField.total_reactive_export, 0, Provenance.quadrant_derived);
            present[MeterField.total_reactive_export] |= 1;
        }
        if (!(r.fields & FieldFlags.total_reactive))
        {
            r.total_reactive[0] = ind - cap;
            r.mark(MeterField.total_reactive, 0, Provenance.quadrant_derived);
            present[MeterField.total_reactive] |= 1;
        }
        if (!(r.fields & FieldFlags.total_absolute_reactive))
        {
            r.total_absolute_reactive[0] = ind + cap;
            r.mark(MeterField.total_absolute_reactive, 0, Provenance.quadrant_derived);
            present[MeterField.total_absolute_reactive] |= 1;
        }
    }

    // inductive + capacitive <-> net + absolute (per-phase)
    if ((r.fields & FieldFlags.total_inductive) && (r.fields & FieldFlags.total_capacitive))
    {
        const ubyte pm = present[MeterField.total_inductive] & present[MeterField.total_capacitive];
        if (pm)
        {
            if (!(r.fields & FieldFlags.total_reactive))
            {
                foreach (i; 0..4) if (pm & (1 << i))
                {
                    r.total_reactive[i] = r.total_inductive[i] - r.total_capacitive[i];
                    r.mark(MeterField.total_reactive, cast(ubyte)i, Provenance.synthesized);
                    present[MeterField.total_reactive] |= cast(ubyte)(1 << i);
                }
            }
            if (!(r.fields & FieldFlags.total_absolute_reactive))
            {
                foreach (i; 0..4) if (pm & (1 << i))
                {
                    r.total_absolute_reactive[i] = r.total_inductive[i] + r.total_capacitive[i];
                    r.mark(MeterField.total_absolute_reactive, cast(ubyte)i, Provenance.synthesized);
                    present[MeterField.total_absolute_reactive] |= cast(ubyte)(1 << i);
                }
            }
        }
    }
    else if ((r.fields & FieldFlags.total_reactive) && (r.fields & FieldFlags.total_absolute_reactive))
    {
        const ubyte pm = present[MeterField.total_reactive] & present[MeterField.total_absolute_reactive];
        if (pm)
        {
            if (!(r.fields & FieldFlags.total_inductive))
            {
                foreach (i; 0..4) if (pm & (1 << i))
                {
                    r.total_inductive[i] = (r.total_reactive[i] + r.total_absolute_reactive[i]) * 0.5f;
                    r.mark(MeterField.total_inductive, cast(ubyte)i, Provenance.synthesized);
                    present[MeterField.total_inductive] |= cast(ubyte)(1 << i);
                }
            }
            if (!(r.fields & FieldFlags.total_capacitive))
            {
                foreach (i; 0..4) if (pm & (1 << i))
                {
                    r.total_capacitive[i] = (r.total_absolute_reactive[i] - r.total_reactive[i]) * 0.5f;
                    r.mark(MeterField.total_capacitive, cast(ubyte)i, Provenance.synthesized);
                    present[MeterField.total_capacitive] |= cast(ubyte)(1 << i);
                }
            }
        }
    }

    // reactive_import + reactive_export -> absolute_reactive (extra coverage if q1..q4 weren't all present)
    if ((r.fields & FieldFlags.total_reactive_import) && (r.fields & FieldFlags.total_reactive_export)
        && !(r.fields & FieldFlags.total_absolute_reactive))
    {
        const ubyte pm = present[MeterField.total_reactive_import] & present[MeterField.total_reactive_export];
        if (pm)
        {
            foreach (i; 0..4) if (pm & (1 << i))
            {
                r.total_absolute_reactive[i] = r.total_reactive_import[i] + r.total_reactive_export[i];
                r.mark(MeterField.total_absolute_reactive, cast(ubyte)i, Provenance.synthesized);
                present[MeterField.total_absolute_reactive] |= cast(ubyte)(1 << i);
            }
        }
    }

    // ===== Cumulative synthesis: apparent energy =====
    if ((r.fields & FieldFlags.total_apparent_import) && (r.fields & FieldFlags.total_apparent_export)
        && !(r.fields & FieldFlags.total_apparent))
    {
        const ubyte pm = present[MeterField.total_apparent_import] & present[MeterField.total_apparent_export];
        if (pm)
        {
            foreach (i; 0..4) if (pm & (1 << i))
            {
                r.total_apparent[i] = r.total_apparent_import[i] + r.total_apparent_export[i];
                r.mark(MeterField.total_apparent, cast(ubyte)i, Provenance.synthesized);
                present[MeterField.total_apparent] |= cast(ubyte)(1 << i);
            }
        }
    }

    if (r.type != CircuitType.dc)
    {
        import urt.log;
        const float v = r.voltage[0].value;
        if (v > 260)
            writeWarning("High voltage detected on meter ", meter.id, ": ", r.voltage[0]);
        else if (v > 40 && v < 80)  // >40 floor: 0V means the meter is offline, not a brownout
            writeWarning("Low voltage detected on meter ", meter.id, ": ", r.voltage[0]);
    }

    return r;
}


private:

bool hasAvg(size_t field)
{
    if (field == MeterField.voltage || field == MeterField.inter_phase_voltage || field == MeterField.power_factor)
        return true;
    return false;
}
