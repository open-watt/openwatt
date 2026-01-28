module apps.energy.circuit;

import urt.array;
import urt.lifetime;
import urt.math : sqrt, acos, fabs, PI;
import urt.si.quantity;
import urt.string;

import apps.energy.appliance;
import apps.energy.manager;
import apps.energy.meter;

import manager.component;
import manager.element;

nothrow @nogc:


enum CircuitType : ubyte { unknown, dc, single_phase, split_phase, three_phase, delta }

bool is_multi_phase(CircuitType type) pure nothrow @nogc
    => type == CircuitType.three_phase || type == CircuitType.delta;


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

    MeterData meter_data;
    MeterData rogue;

    void update()
    {
        // update the circuit graph
        foreach (c; sub_circuits)
            c.update();
        foreach (a; appliances)
        {
            if (a.meter)
                a.meter_data = getMeterData(a.meter);
        }

        if (meter)
        {
            // if the circuit has a meter, just read the meter!
            MeterData raw_meter_data = getMeterData(meter);

            // if circuit type is unknown, inherit from meter
            if (type == CircuitType.unknown)
                type = raw_meter_data.type;

            meter_data.type = type;
            meter_data.fields = raw_meter_data.fields;
            meter_data.voltage[0] = raw_meter_data.voltage[meter_phase];
            meter_data.cross_phase_voltage[0] = raw_meter_data.cross_phase_voltage[meter_phase];
            meter_data.current[0] = raw_meter_data.current[meter_phase];
            meter_data.active[0] = raw_meter_data.active[meter_phase];
            meter_data.reactive[0] = raw_meter_data.reactive[meter_phase];
            meter_data.apparent[0] = raw_meter_data.apparent[meter_phase];
            meter_data.pf[0] = raw_meter_data.pf[meter_phase];
            meter_data.freq = raw_meter_data.freq;
            meter_data.phase[0] = raw_meter_data.phase[meter_phase];
            meter_data.total_import_active[0] = raw_meter_data.total_import_active[meter_phase];
            meter_data.total_export_active[0] = raw_meter_data.total_export_active[meter_phase];

            // for multi-phase circuits, copy all phase data
            if (is_multi_phase(meter_data.type))
            {
                meter_data.voltage[1..4] = raw_meter_data.voltage[1..4];
                meter_data.cross_phase_voltage[1..4] = raw_meter_data.cross_phase_voltage[1..4];
                meter_data.current[1..4] = raw_meter_data.current[1..4];
                meter_data.active[1..4] = raw_meter_data.active[1..4];
                meter_data.reactive[1..4] = raw_meter_data.reactive[1..4];
                meter_data.apparent[1..4] = raw_meter_data.apparent[1..4];
                meter_data.pf[1..4] = raw_meter_data.pf[1..4];
                meter_data.phase[1..4] = raw_meter_data.phase[1..4];
                meter_data.total_import_active[1..4] = raw_meter_data.total_import_active[1..4];
                meter_data.total_export_active[1..4] = raw_meter_data.total_export_active[1..4];
            }
        }
        else
        {
            // no meter; we'll infer usage from sub-circuits and appliances...
            // of course, this data is incomplete, and not all energy on this circuit will be accounted for

            meter_data.voltage[] = MeterVolts(0);
            meter_data.cross_phase_voltage[] = MeterVolts(0);
            meter_data.freq = 0;

            meter_data.active[] = MeterWatts(0);
            meter_data.reactive[] = 0;

            // sum the known loads...
            int num_loads = 0;
            foreach (c; sub_circuits)
            {
                if (c.meter_data.fields == 0)
                    continue;
                ++num_loads;

                meter_data.active[] += c.meter_data.active[];
                // TODO: I think summing reactive power this way is imprecise? (phase cancellation effects?)
                meter_data.reactive[] += c.meter_data.reactive[];

                meter_data.freq += c.meter_data.freq;
            }
            foreach (a; appliances)
            {
                if (a.meter_data.fields == 0)
                    continue;
                ++num_loads;

                meter_data.active[] += a.meter_data.active[];
                // TODO: I think summing reactive power this way is imprecise? (phase cancellation effects?)
                meter_data.reactive[] += a.meter_data.reactive[];

                meter_data.freq += a.meter_data.freq;
            }
            // average the frequency (there really shouldn't be any meaningful deviation!)
            if (num_loads)
                meter_data.freq /= num_loads;

            // calculate the apparent power, power factor, phase angle, voltage, and current...
            foreach (i; 0..4)
            {
                // apparent power can be calculated from active and reactive power
                meter_data.apparent[i] = sqrt(meter_data.active[i].value^^2 + meter_data.reactive[i]^^2);

                // with the apparent power, we can calculate the power factor and phase angle
                if (meter_data.apparent[i] > 0)
                    meter_data.pf[i] = fabs(meter_data.active[i].value) / meter_data.apparent[i];
                else
                    meter_data.pf[i] = meter_data.active[i] ? 1 : 0;
                if (meter_data.pf[i] != 0)
                {
                    // in degrees
                    meter_data.phase[i] = acos(meter_data.pf[i])*(1.0/(2*PI));
                    if (meter_data.reactive[i] < 0)
                        meter_data.phase[i] = -meter_data.phase[i];
                }

                // this might be wrong to calculate the voltage... (weighted average of sub-circuits and appliances)
                // but I think it's better than averaging the violtages of the sub-circuits
                if (meter_data.apparent[i] > 0)
                {
                    foreach (c; sub_circuits)
                        meter_data.voltage[i].value += c.meter_data.apparent[i] * c.meter_data.voltage[i].value;
                    foreach (a; appliances)
                        meter_data.voltage[i].value += a.meter_data.apparent[i] * a.meter_data.voltage[i].value;
                    meter_data.voltage[i].value /= meter_data.apparent[i];
                }

                // and given the voltage, we can calculate the current
                // TODO: confirm; I found this from some reference. I'm not sure why `/V` is inside the sqrt?
                //       I would have guessed A = VA/V, rather than A = sqrt(V²A²/V²)...
                if (meter_data.voltage[i])
                    meter_data.current[i].value = sqrt((meter_data.active[i].value^^2 + meter_data.reactive[i]^^2) / meter_data.voltage[i].value^^2);
                else
                    meter_data.current[i] = Amps(0);
            }
            // the same reference seemed to think this was also better to sum the currents
            // TODO: confirm; I would have guessed SUM = L1+L2+L3, rather than SUM = sqrt(L1²+L2²+L3²)...
            meter_data.current[0].value = sqrt(meter_data.current[1].value^^2 + meter_data.current[2].value^^2 + meter_data.current[3].value^^2);
        }

        // calculate rogue load...
        if (meter)
        {
            // if the circuit has a meter, then we want to know what portion of the load is not being sub-metered...
            rogue.voltage[] = meter_data.voltage[];
            rogue.cross_phase_voltage[] = meter_data.cross_phase_voltage[];
            rogue.freq = meter_data.freq;

            rogue.active[] = meter_data.active[];
            rogue.reactive[] = meter_data.reactive[];

            // subtract the known loads from the meter total...
            foreach (c; sub_circuits)
            {
                rogue.active[] -= c.meter_data.active[];
                // TODO: I think subtracting reactive power this way is imprecise? (phase cancellation effects?)
                rogue.reactive[] -= c.meter_data.reactive[];
            }
            foreach (a; appliances)
            {
                rogue.active[] -= a.meter_data.active[];
                // TODO: I think subtracting reactive power this way is imprecise? (phase cancellation effects?)
                rogue.reactive[] -= a.meter_data.reactive[];
            }
            foreach (i; 0..4)
            {
                // calculate the rogue apparent power
                rogue.apparent[i] = sqrt(rogue.active[i].value^^2 + rogue.reactive[i]^^2);

                // calculate rogue power factor and phase angle
                if (rogue.apparent[i] > 0)
                    rogue.pf[i] = rogue.active[i].value / rogue.apparent[i];
                else
                    rogue.pf[i] = rogue.active[i] ? 1 : 0;
                if (rogue.pf[i] != 0)
                {
                    // in degrees
                    rogue.phase[i] = acos(rogue.pf[i])*(1.0/(2*PI));
                    if (rogue.reactive[i] < 0)
                        rogue.phase[i] = -rogue.phase[i];
                }

                // calculate rogue currents assuming the voltages specified by the meter
                if (rogue.voltage[i])
                    rogue.current[i].value = sqrt((rogue.active[i].value^^2 + rogue.reactive[i]^^2) / rogue.voltage[i].value^^2);
                else
                    rogue.current[i] = Amps(0);
            }
            // calculate the sum of the rogue currents
            rogue.current[0].value = sqrt(rogue.current[1].value^^2 + rogue.current[2].value^^2 + rogue.current[3].value^^2);
        }
    }
}
