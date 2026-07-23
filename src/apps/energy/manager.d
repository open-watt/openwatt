module apps.energy.manager;

import urt.map;
import urt.mem;
import urt.si.quantity;
import urt.string;

import apps.energy.meter;
import apps.energy.topology;

import manager.component;


struct EnergyManager
{
nothrow @nogc:

    TopologyGraph graph;

    // Threshold (V AC) above which a direct voltage reading counts as live.
    // The graph model treats absent/stale evidence as unknown, not dead; this
    // value is only for health/diagnostic classification.
    float voltage_threshold = 100.0f;

    // Connected bus components. The component containing `grid` is on-grid;
    // all others are off-grid.
    Islands islands;

    inout(Bus)* find_bus(const(char)[] name) inout
    {
        inout(Bus*)* b = name in graph.buses;
        if (b)
            return *b;
        return null;
    }

    Volts get_mains_voltage(int phase = 0)
    {
        Bus* grid = graph.find_bus("grid");
        return grid ? cast(Volts)grid.balance.voltage[phase] : Volts.init;
    }

    void update(bool rebuild_shape)
    {
        if (rebuild_shape || graph.generation == 0)
            graph.build();
        else
            graph.refresh();
        update_islands(islands, graph);
    }
}
