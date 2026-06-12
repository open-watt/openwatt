module apps.energy.manager;

import urt.map;
import urt.mem;
import urt.si.quantity;
import urt.string;

import apps.energy.circuit;
import apps.energy.island;
import apps.energy.meter;

import manager.component;


struct EnergyManager
{
nothrow @nogc:

    Circuit* main;

    Map!(const(char)[], Circuit*) circuits;

    // Threshold (V AC) above which a meter's voltage reading counts as "circuit live".
    // Tunable per region; the configured value lives on the energy device's config
    // component and is read from there as Phase 0.6 wires that up.
    float voltage_threshold = 100.0f;

    // The set of currently-existing islands. Normally length 1 (one site-wide island);
    // grows transiently when the grid drops and the tree fragments into backup-rooted
    // subtrees, contracts back when the grid returns.
    Archipelago archipelago;

    inout(Circuit)* find_circuit(const(char)[] name) pure inout
    {
        inout(Circuit*)* c = name in circuits;
        if (c)
            return *c;
        return null;
    }

    Circuit* add_circuit(String name, Circuit* parent, uint max_current, Component meter, CircuitType type = CircuitType.unknown, ubyte parent_phase = 0, ubyte meter_phase = 0)
    {
        Circuit* circuit = defaultAllocator.allocT!Circuit(name.move);

        if (!parent)
        {
            assert(!main, "Main circuit already configured");
            main = circuit;
        }
        else
        {
            circuit.parent = parent;
            circuit.parent.sub_circuits ~= circuit;
        }

        circuit.max_current = max_current;
        circuit.meter = meter;
        circuit.type = type;
        circuit.parent_phase = parent_phase;
        circuit.meter_phase = meter_phase;

        if (circuit.type == CircuitType.unknown && meter)
            circuit.type = get_meter_type(meter);

        circuits.insert(circuit.id[], circuit);

        return circuit;
    }

    Volts get_mains_voltage(int phase = 0) pure
    {
        return cast(Volts)main.meter_data.voltage[phase];
    }

    void update()
    {
        if (!main)
            return;

        main.update();
        main.update_liveness(voltage_threshold);
        update_archipelago(archipelago, main);
    }
}
