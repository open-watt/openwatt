module apps.energy.circuit;

import urt.array;
import urt.lifetime;
import urt.math : sqrt, acos, fabs, PI;
import urt.si.quantity;
import urt.string;

import apps.energy.appliance;
import apps.energy.meter;

import manager.component;
import manager.element;

nothrow @nogc:


enum CircuitType : ubyte { unknown, dc, single_phase, split_phase, three_phase, delta }

bool is_multi_phase(CircuitType type) pure nothrow @nogc
    => type == CircuitType.three_phase || type == CircuitType.delta;


// Fields that sum across siblings/children on the same circuit boundary.
// Primary AC fields (V, I, S, PF, phase) don't sum meaningfully and are derived
// after the sum from active + reactive + voltage.
private static immutable MeterField[] sumFields = [
    MeterField.power,
    MeterField.reactive,
    MeterField.total_active,
    MeterField.total_import_active,
    MeterField.total_export_active,
    MeterField.total_absolute_active,
    MeterField.total_reactive,
    MeterField.total_inductive,
    MeterField.total_capacitive,
    MeterField.total_absolute_reactive,
    MeterField.total_reactive_import,
    MeterField.total_reactive_export,
    MeterField.total_apparent,
    MeterField.total_apparent_import,
    MeterField.total_apparent_export,
];


struct Circuit
{
nothrow @nogc:

    this(String id)
    {
        this.id = id.move;
    }
    this(this) @disable;

    String id;
    String name;
    Circuit* parent;
    Component meter;
    uint max_current;
    Array!(Circuit*) sub_circuits;
    Array!Appliance appliances;

    CircuitType type;
    ubyte parent_phase;
    ubyte meter_phase;

    // Runtime state at this circuit boundary. Provenance is per-(field, phase):
    // measured/synthesized from a real meter, or inferred_sum/inferred_subtraction
    // when computed from children. `rogue` is populated only at metered circuits
    // and carries the residual after known children/loads are subtracted out.
    MeterData meter_data;
    MeterData rogue;

    // Manual override: declares this circuit cut off from its parent. Used for
    // transfer switches and other disconnects that aren't observable from voltage.
    bool isolated;

    // Computed per tick by update_liveness(): whether the circuit currently has
    // voltage on it. A metered circuit derives this from its own measured voltage;
    // an unmetered circuit inherits from its parent (unless isolated).
    bool is_live;

    void update()
    {
        // Update children first (depth-first traversal of the circuit tree)
        foreach (c; sub_circuits)
            c.update();

        foreach (a; appliances)
        {
            Component am = a.meter_ref;
            if (am is null && a.device_ref !is null)
                am = a.device_ref.get_first_component_by_template("EnergyMeter");
            if (am)
            {
                MeterData raw = get_meter_data(am);
                CircuitType atype = a.meter_phase != 0 ? CircuitType.single_phase : raw.type;
                a.meter_data = extract_phase(raw, atype, a.meter_phase);
            }
            else
                a.meter_data.reset_to_missing();
        }

        meter_data.reset_to_missing();
        rogue.reset_to_missing();

        if (meter)
        {
            MeterData raw = get_meter_data(meter);
            if (type == CircuitType.unknown)
                type = raw.type;
            meter_data = extract_phase(raw, type, meter_phase);
        }

        fill_from_children();
        derive_secondary_fields(meter_data, Provenance.synthesized);

        if (meter)
            compute_rogue();
    }

    // Determine liveness for this circuit and propagate to children.
    // Caller invokes on the root after Circuit.update(); the walk is top-down
    // because unmetered children inherit from their parent.
    void update_liveness(float voltage_threshold)
    {
        if (meter && meter_data.has(MeterField.voltage))
        {
            // Direct evidence: live if any phase shows voltage above the threshold
            float v = 0;
            foreach (j; 0..4)
            {
                if (meter_data.has(MeterField.voltage, cast(ubyte)j))
                {
                    float pv = meter_data.voltage[j].value;
                    if (pv > v)
                        v = pv;
                }
            }
            is_live = v > voltage_threshold;
        }
        else
        {
            // No voltage evidence: inherit from parent, suppressed by isolation
            is_live = (parent ? parent.is_live : true) && !isolated;
        }

        foreach (c; sub_circuits)
            c.update_liveness(voltage_threshold);
    }

private:

    void fill_from_children()
    {
        foreach (field; sumFields)
        {
            foreach (j; 0..4)
            {
                if (meter_data.has(field, cast(ubyte)j))
                    continue;
                float sum = 0;
                bool any = false;
                foreach (c; sub_circuits)
                {
                    if (c.meter_data.has(field, cast(ubyte)j))
                    {
                        sum += c.meter_data.read_value(field, cast(ubyte)j);
                        any = true;
                    }
                }
                foreach (a; appliances)
                {
                    if (a.meter_data.has(field, cast(ubyte)j))
                    {
                        sum += a.meter_data.read_value(field, cast(ubyte)j);
                        any = true;
                    }
                }
                if (any)
                {
                    meter_data.write_value(field, cast(ubyte)j, sum);
                    meter_data.mark(field, cast(ubyte)j, Provenance.inferred_sum);
                }
            }
        }

        foreach (j; 0..4)
        {
            if (meter_data.has(MeterField.voltage, cast(ubyte)j))
                continue;
            foreach (c; sub_circuits)
            {
                if (c.meter_data.has(MeterField.voltage, cast(ubyte)j))
                {
                    meter_data.voltage[j] = c.meter_data.voltage[j];
                    meter_data.mark(MeterField.voltage, cast(ubyte)j, Provenance.inferred_sum);
                    break;
                }
            }
            if (meter_data.has(MeterField.voltage, cast(ubyte)j))
                continue;
            foreach (a; appliances)
            {
                if (a.meter_data.has(MeterField.voltage, cast(ubyte)j))
                {
                    meter_data.voltage[j] = a.meter_data.voltage[j];
                    meter_data.mark(MeterField.voltage, cast(ubyte)j, Provenance.inferred_sum);
                    break;
                }
            }
        }

        if (meter_data.has(MeterField.frequency))
            return;
        foreach (c; sub_circuits)
        {
            if (c.meter_data.has(MeterField.frequency))
            {
                meter_data.freq = c.meter_data.freq;
                meter_data.mark(MeterField.frequency, 0, Provenance.inferred_sum);
                return;
            }
        }
        foreach (a; appliances)
        {
            if (a.meter_data.has(MeterField.frequency))
            {
                meter_data.freq = a.meter_data.freq;
                meter_data.mark(MeterField.frequency, 0, Provenance.inferred_sum);
                return;
            }
        }
    }

    // Metered circuit: rogue = meter total minus the sum of known children/loads.
    // Per (field, phase). Marks rogue when at least one contributor was subtracted;
    // leaves missing (NaN) where there are no children/loads to attribute to.
    void compute_rogue()
    {
        foreach (field; sumFields)
        {
            foreach (j; 0..4)
            {
                if (!meter_data.has(field, cast(ubyte)j))
                    continue;
                float total = meter_data.read_value(field, cast(ubyte)j);
                bool any_subtracted = false;
                foreach (c; sub_circuits)
                {
                    if (c.meter_data.has(field, cast(ubyte)j))
                    {
                        total -= c.meter_data.read_value(field, cast(ubyte)j);
                        any_subtracted = true;
                    }
                }
                foreach (a; appliances)
                {
                    if (a.meter_data.has(field, cast(ubyte)j))
                    {
                        total -= a.meter_data.read_value(field, cast(ubyte)j);
                        any_subtracted = true;
                    }
                }
                if (any_subtracted)
                {
                    rogue.write_value(field, cast(ubyte)j, total);
                    rogue.mark(field, cast(ubyte)j, Provenance.rogue);
                }
            }
        }

        // Voltage/frequency on rogue inherit from the parent meter: it's the same wire.
        foreach (j; 0..4)
        {
            if (meter_data.has(MeterField.voltage, cast(ubyte)j))
            {
                rogue.voltage[j] = meter_data.voltage[j];
                rogue.mark(MeterField.voltage, cast(ubyte)j, Provenance.rogue);
            }
        }
        if (meter_data.has(MeterField.frequency))
        {
            rogue.freq = meter_data.freq;
            rogue.mark(MeterField.frequency, 0, Provenance.rogue);
        }

        rogue.type = meter_data.type;
        derive_secondary_fields(rogue, Provenance.rogue);
    }
}


// Derive current, apparent, PF, phase angle from active + reactive (+ voltage), per phase.
// Used by both unmetered inference and rogue computation; only fills cells that
// don't already have a value.
private void derive_secondary_fields(ref MeterData r, Provenance prov) pure
{
    foreach (j; 0..4)
    {
        if (!r.has(MeterField.power, cast(ubyte)j))
            continue;
        float p = r.active[j].value;
        float q = r.has(MeterField.reactive, cast(ubyte)j) ? r.reactive[j] : 0;

        if (!r.has(MeterField.apparent, cast(ubyte)j))
        {
            r.apparent[j] = sqrt(p*p + q*q);
            r.mark(MeterField.apparent, cast(ubyte)j, prov);
        }

        if (!r.has(MeterField.power_factor, cast(ubyte)j))
        {
            r.pf[j] = r.apparent[j] > 0 ? fabs(p) / r.apparent[j] : (p != 0 ? 1 : 0);
            r.mark(MeterField.power_factor, cast(ubyte)j, prov);
        }

        if (!r.has(MeterField.phase_angle, cast(ubyte)j))
        {
            if (r.pf[j] > 0 && r.pf[j] <= 1)
            {
                float phi = cast(float)(acos(r.pf[j]) * (180.0/PI));
                if (q < 0)
                    phi = -phi;
                r.phase[j] = phi;
                r.mark(MeterField.phase_angle, cast(ubyte)j, prov);
            }
        }

        if (!r.has(MeterField.current, cast(ubyte)j) && r.has(MeterField.voltage, cast(ubyte)j) && r.voltage[j].value > 0)
        {
            r.current[j] = MeterAmps(r.apparent[j] / r.voltage[j].value);
            r.mark(MeterField.current, cast(ubyte)j, prov);
        }
    }
}
