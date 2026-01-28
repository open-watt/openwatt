module apps.energy.manager;

import urt.algorithm;
import urt.array;
import urt.map;
import urt.mem;
import urt.si.quantity;
import urt.string;
import urt.util;

import apps.energy;
import apps.energy.appliance;
import apps.energy.circuit;
import apps.energy.meter;

import manager.component;


struct EnergyManager
{
nothrow @nogc:

    Circuit* main;

    Map!(const(char)[], Circuit*) circuits;
    Map!(const(char)[], Appliance) appliances;

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

        circuits.insert(circuit.id, circuit);

        return circuit;
    }

    Appliance add_appliance(Appliance appliance, Circuit* circuit)
    {
        if (circuit)
        {
            appliance.circuit = circuit;
            circuit.appliances ~= appliance;
        }

        appliances.insert(appliance.id, appliance);

        return appliance;
    }

    Volts getMainsVoltage(int phase = 0) pure
    {
        return cast(Volts)main.meter_data.voltage[phase];
    }

    void update()
    {
        if (!main)
            return;

        main.update();

        Array!Appliance wantPower;
        Watts excessSolar = main.meter_data.active[0] < Watts(0) ? cast(Watts)-main.meter_data.active[0] : Watts(0);
        foreach (a; appliances.values)
        {
            if (a.canControl)
            {
                Watts power = a.currentConsumption;
                if (power > Watts(0))
                    excessSolar += power;
                if (a.wantsPower || power > Watts(0))
                    wantPower ~= a;
            }
        }

        wantPower.sort!((Appliance x, Appliance y) => compare(x.priority, y.priority));

        // HACK: TO CHARGE MY CAR FOR THE AIRPORT!
//        excessSolar += Watts(4000);

        // excessSolar is the total excess solar we are able to distribute
        // some may already be consumed by implicit loads; like a solar battery
        foreach (a; wantPower)
        {
            if (excessSolar <= Watts(0))
                break;

            Watts wants = a.wantsPower();
            Watts consumption = a.currentConsumption;

            ControlCapability controlCap = a.hasControl();
            if (controlCap & ControlCapability.Linear)
            {
                // there is a problem where the implicit inverter loses to a downward spiral where chargers creep upwards
                // HACK: fix it with a scaling factor...
                Watts minimum;
                if (!a.minPowerLimit(minimum) || excessSolar >= minimum)
                    a.offerPower(min(wants, excessSolar * 0.9));

                // TODO: if we fall below the minimum for some period, we should probably turn the device off...
                //...

            }
            else if (controlCap & ControlCapability.OnOff)
            {
                // TODO: if there is more excess than the device generally consumes, we can turn it on
                //...

                // TODO: implement a toggle frequency so we don't damage relays!
            }

            excessSolar -= consumption;
        }

        // update the appliances, this might commit the state changes from above
        foreach (a; appliances.values)
            a.update();
    }
}

