module apps.energy.attribution;

import urt.array;
import urt.map;

import apps.energy.meter;
import apps.energy.model;
import apps.energy.topology;

nothrow @nogc:


// Presentation-only attribution derived from the measured topology, which
// remains authoritative for coverage, balance, and accounts.
struct BusAttribution
{
    float source_power = float.nan;
    float local_source_power = float.nan;
    float grid_source_power = float.nan;
    float load_power = float.nan;
    float local_fraction = float.nan;
    int island = -1;
    int depth = -1;
    int parent = -1;
}

struct TerminalAttribution
{
    float consumed_power = float.nan;
    float supplied_power = float.nan;
    float local_power = float.nan;
    float grid_power = float.nan;
    float local_fraction = float.nan;
}

struct CircuitAttribution
{
nothrow @nogc:
    uint generation;
    int island_count;
    int grid_island = -1;
    Array!BusAttribution buses;           // parallel to graph.bus_list
    Array!TerminalAttribution terminals;  // parallel to graph.ports

    void clear()
    {
        buses.clear();
        terminals.clear();
        island_count = 0;
        grid_island = -1;
    }

    void compute(ref TopologyGraph graph)
    {
        generation = graph.generation;
        buses.resize(graph.bus_list.length);
        terminals.resize(graph.ports.length);
        foreach (ref a; buses[])
            a = BusAttribution.init;
        foreach (ref a; terminals[])
            a = TerminalAttribution.init;

        Map!(Bus*, int) bus_index;
        foreach (i, b; graph.bus_list[])
            bus_index.insert(b, cast(int)i);

        partition_islands(graph, bus_index);
        build_grid_spanning_tree(graph, bus_index);
        attribute_source_mix(graph, bus_index);
    }

    int terminal_index(ref TopologyGraph graph, Port* p)
    {
        if (p is null)
            return -1;
        foreach (i, q; graph.ports[])
            if (q is p)
                return cast(int)i;
        return -1;
    }

private:
    void partition_islands(ref TopologyGraph graph, ref Map!(Bus*, int) bus_index)
    {
        island_count = 0;
        grid_island = -1;
        foreach (i, b; graph.bus_list[])
        {
            if (buses[i].island >= 0)
                continue;
            int island = island_count++;
            flood_island(graph, bus_index, cast(int)i, island);
        }
        foreach (i, b; graph.bus_list[])
            if (b.contains_grid)
                grid_island = buses[i].island;
    }

    void flood_island(ref TopologyGraph graph, ref Map!(Bus*, int) bus_index, int start, int island)
    {
        Array!int queue;
        queue ~= start;
        buses[cast(size_t)start].island = island;
        for (size_t qi = 0; qi < queue.length; ++qi)
        {
            Bus* b = graph.bus_list[cast(size_t)queue[qi]];
            foreach (link; b.links[])
            {
                if (!link.closed)
                    continue;
                Bus* other = adjacent(b, link);
                if (other is null)
                    continue;
                int* oi = other in bus_index;
                if (oi is null || buses[cast(size_t)*oi].island >= 0)
                    continue;
                buses[cast(size_t)*oi].island = island;
                queue ~= *oi;
            }
        }
    }

    void build_grid_spanning_tree(ref TopologyGraph graph, ref Map!(Bus*, int) bus_index)
    {
        int root = -1;
        foreach (i, b; graph.bus_list[])
            if (b.contains_grid)
            {
                root = cast(int)i;
                break;
            }
        if (root < 0)
            foreach (i, b; graph.bus_list[])
                if (b.explicit_root)
                {
                    root = cast(int)i;
                    break;
                }
        if (root < 0)
            return;

        Array!int queue;
        queue ~= root;
        buses[cast(size_t)root].parent = root;
        buses[cast(size_t)root].depth = 0;
        for (size_t qi = 0; qi < queue.length; ++qi)
        {
            int bi = queue[qi];
            Bus* b = graph.bus_list[cast(size_t)bi];
            foreach (link; b.links[])
            {
                if (!link.closed)
                    continue;
                Bus* other = adjacent(b, link);
                if (other is null)
                    continue;
                int* oi = other in bus_index;
                if (oi is null || buses[cast(size_t)*oi].parent >= 0)
                    continue;
                buses[cast(size_t)*oi].parent = bi;
                buses[cast(size_t)*oi].depth = buses[cast(size_t)bi].depth + 1;
                queue ~= *oi;
            }
        }
    }

    void attribute_source_mix(ref TopologyGraph graph, ref Map!(Bus*, int) bus_index)
    {
        size_t nb = graph.bus_list.length;
        Array!float local;
        Array!float grid;
        Array!float next_local;
        Array!float next_grid;
        local.resize(nb);
        grid.resize(nb);
        next_local.resize(nb);
        next_grid.resize(nb);

        seed_source_mix(graph, bus_index, local, grid);
        foreach (_; 0 .. nb + graph.links.length + 1)
        {
            seed_source_mix(graph, bus_index, next_local, next_grid);

            foreach (link; graph.links[])
            {
                if (!link.closed)
                    continue;
                int* pi = link.a in bus_index;
                int* ci = link.b in bus_index;
                if (pi is null || ci is null)
                    continue;

                float flow = branch_flow_down(link);
                if (flow != flow || flow == 0)
                    continue;

                int source = flow > 0 ? *pi : *ci;
                int sink = flow > 0 ? *ci : *pi;
                float amount = absf(flow);
                float fraction = source_fraction(local[cast(size_t)source], grid[cast(size_t)source],
                                                 graph.bus_list[cast(size_t)source].contains_grid);
                next_local[cast(size_t)sink] += amount * fraction;
                next_grid[cast(size_t)sink] += amount * (1 - fraction);
            }

            bool changed = false;
            foreach (i; 0 .. nb)
                if (next_local[][i] != local[][i] || next_grid[][i] != grid[][i])
                {
                    changed = true;
                    break;
                }
            local = next_local;
            grid = next_grid;
            if (!changed)
                break;
        }

        foreach (i, b; graph.bus_list[])
        {
            buses[i].local_source_power = local[i];
            buses[i].grid_source_power = grid[i];
            buses[i].source_power = local[i] + grid[i];
            buses[i].load_power = terminal_load(b);
            buses[i].local_fraction = bus_local_fraction(local[i], grid[i], b.contains_grid);
        }

        Map!(Port*, float) feed_fraction;
        foreach (link; graph.links[])
        {
            if (!link.closed)
                continue;
            int* pi = link.a in bus_index;
            int* ci = link.b in bus_index;
            if (pi is null || ci is null)
                continue;
            float flow = branch_flow_down(link);
            if (flow != flow || flow == 0)
                continue;
            int src = flow > 0 ? *pi : *ci;
            Port* sink_port = flow > 0 ? link.port_b : link.port_a;
            if (sink_port !is null)
                feed_fraction.insert(sink_port,
                    bus_local_fraction(local[][src], grid[][src], graph.bus_list[cast(size_t)src].contains_grid));
        }

        foreach (i, p; graph.ports[])
        {
            if (!p.meter_data.has(MeterField.power))
                continue;
            int* bi = p.bus in bus_index;
            if (bi is null)
                continue;
            float power = p.meter_data.active[0].value;
            if (power != power)
                continue;

            if (power >= 0)
            {
                float fraction = buses[cast(size_t)*bi].local_fraction;
                terminals[i].consumed_power = power;
                terminals[i].supplied_power = 0;
                terminals[i].local_power = power * fraction;
                terminals[i].grid_power = power * (1 - fraction);
                terminals[i].local_fraction = fraction;
            }
            else
            {
                float fraction = 1;
                if (float* ff = p in feed_fraction)
                    fraction = *ff;
                terminals[i].consumed_power = 0;
                terminals[i].supplied_power = -power;
                terminals[i].local_power = -power * fraction;
                terminals[i].grid_power = -power * (1 - fraction);
                terminals[i].local_fraction = fraction;
            }
        }
    }

    // Seeds are the solved boundary in-flows: grid-kind seeds grid, everything
    // else seeds local (diffuse/unclassified supply is local by nature; battery
    // discharge is local regardless of what charged it). Residuals never seed:
    // error is not energy. A grid bus no grid boundary reported on falls back
    // to the load-shortfall heuristic.
    void seed_source_mix(ref TopologyGraph graph, ref Map!(Bus*, int) bus_index,
                         ref Array!float local, ref Array!float grid)
    {
        foreach (i; 0 .. local.length)
        {
            local[][i] = 0;
            grid[][i] = float.nan;
        }
        foreach (ref f; graph.boundary_flows[])
        {
            int* bi = boundary_bus(f.port) in bus_index;
            if (bi is null)
                continue;
            if (f.kind == BoundaryKind.grid)
            {
                if (grid[][cast(size_t)*bi] != grid[][cast(size_t)*bi])
                    grid[][cast(size_t)*bi] = 0;
                grid[][cast(size_t)*bi] += f.power_into_graph;
            }
            else
                local[][cast(size_t)*bi] += f.power_into_graph;
        }
        foreach (i, b; graph.bus_list[])
            if (grid[][i] != grid[][i])
                grid[][i] = b.contains_grid ? grid_terminal_source(b, local[][i]) : 0;
    }

    float terminal_load(Bus* bus)
    {
        float load = 0;
        foreach (p; bus.ports[])
        {
            if (!p.meter_data.has(MeterField.power))
                continue;
            float power = p.meter_data.active[0].value;
            if (power == power && power > 0)
                load += power;
        }
        return load;
    }

    float grid_terminal_source(Bus* bus, float local_source)
    {
        float needed = terminal_load(bus) - local_source;
        return needed > 0 ? needed : 0;
    }

    float branch_flow_down(Link* link)
    {
        if (link.port_a && !link.port_a_is_hub && link.port_a.meter_data.has(MeterField.power))
        {
            float power = link.port_a.meter_data.active[0].value;
            if (power == power)
                return power;
        }
        if (link.port_b && link.port_b.meter_data.has(MeterField.power))
        {
            float power = link.port_b.meter_data.active[0].value;
            if (power == power)
                return -power;
        }
        return float.nan;
    }
}


private Bus* adjacent(Bus* bus, Link* link)
{
    if (link.a is bus)
        return link.b;
    if (link.b is bus)
        return link.a;
    return null;
}


float source_fraction(float local, float grid, bool contains_grid)
{
    float total = local + grid;
    if (total > 0)
        return local / total;
    return contains_grid ? 0 : 1;
}

float bus_local_fraction(float local, float grid, bool contains_grid)
{
    float total = local + grid;
    if (total > 0)
        return local / total;
    return contains_grid ? 0 : float.nan;
}

unittest
{
    // grid import and a local pv boundary blend by classification, not sign:
    // 1000 W import + 500 W pv serving 1500 W load = one-third local
    TopologyGraph g;
    Bus* gridb = g.ensure_bus("grid");
    Bus* house = g.ensure_bus("house");

    Port* gp = g.add_port(null, gridb, PortRole.parent, FlowDomain.bidirectional, null, 0, MeterSign.normal, "parent", "main");
    gp.meter_data.write_value(MeterField.power, 0, 1000);
    gp.meter_data.mark(MeterField.power, 0, Provenance.measured);
    Port* hp = g.add_port(null, house, PortRole.child, FlowDomain.bidirectional, null, 0, MeterSign.normal, "child", "main");
    hp.meter_data.write_value(MeterField.power, 0, -1000);
    hp.meter_data.mark(MeterField.power, 0, Provenance.measured);
    Link* ml = g.add_link(null, gridb, house, gp, hp, 63, true, "main");
    PortGroup* main_g = g.add_group("main", PortGroupKind.switchgear, null, ml);
    g.add_to_group(main_g, gp);
    g.add_to_group(main_g, hp);

    Port* pv = g.add_port(null, house, PortRole.pv, FlowDomain.supply, null, 0, MeterSign.normal, "pv");
    pv.meter_data.write_value(MeterField.power, 0, -500);
    pv.meter_data.mark(MeterField.power, 0, Provenance.measured);
    g.add_to_group(g.add_group("pv", PortGroupKind.appliance), pv);

    Port* load = g.add_port(null, house, PortRole.connection, FlowDomain.consume, null, 0, MeterSign.normal, "heater");
    load.meter_data.write_value(MeterField.power, 0, 1500);
    load.meter_data.mark(MeterField.power, 0, Provenance.measured);
    g.add_to_group(g.add_group("heater", PortGroupKind.appliance), load);

    g.rebuild_boundaries();
    g.reduce_boundary_flows();
    g.attribution.compute(g);

    size_t gi = g.bus_list[].findFirst(gridb);
    size_t hi = g.bus_list[].findFirst(house);
    assert(g.attribution.buses[gi].local_fraction == 0);
    assert(absf(g.attribution.buses[hi].local_source_power - 500) <= 0.01f);
    assert(absf(g.attribution.buses[hi].grid_source_power - 1000) <= 0.01f);
    assert(absf(g.attribution.buses[hi].local_fraction - 1.0f / 3) <= 0.001f);

    size_t li = g.ports[].findFirst(load);
    assert(absf(g.attribution.terminals[li].consumed_power - 1500) <= 0.01f);
    assert(absf(g.attribution.terminals[li].local_power - 500) <= 0.01f);
    assert(absf(g.attribution.terminals[li].grid_power - 1000) <= 0.01f);

    g.clear();
}
