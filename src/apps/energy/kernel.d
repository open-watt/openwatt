module apps.energy.kernel;

import urt.array;

import apps.energy.meter;
import apps.energy.model;

nothrow @nogc:


enum SignDomain : ubyte
{
    unknown,
    sink,
    source,
    bidirectional,
}

const(char)[] sign_domain_name(SignDomain d) pure
{
    final switch (d)
    {
        case SignDomain.unknown:       return "unknown";
        case SignDomain.sink:          return "sink";
        case SignDomain.source:        return "source";
        case SignDomain.bidirectional: return "bidirectional";
    }
}

// One explicit Port projected into the role-blind circuit kernel.
// Terminal meters use the energy app port convention: positive means power
// flows from the connected circuit into the appliance terminal.
struct CircuitTerminal
{
    const(char)[] id;
    const(char)[] owner;
    const(char)[] owner_kind;
    const(char)[] owner_device;
    const(char)[] port;
    const(char)[] label;
    const(char)[] circuit;
    const(char)[] role;
    SignDomain domain;
    MeterData meter;
    float consumed_power = float.nan;
    float supplied_power = float.nan;
    float local_power = float.nan;
    float grid_power = float.nan;
    float local_fraction = float.nan;
    float soc = float.nan;
    bool root;

    bool metered() const pure nothrow @nogc
    {
        return meter.has(MeterField.power);
    }

    float contribution() const pure nothrow @nogc
    {
        return metered ? meter.active[0].value : float.nan;
    }
}

// Conducting element between circuits: breaker, inline meter, transfer leg,
// appliance bridge, etc. Branches are metadata and connectivity; terminals
// carry the electrical measurements.
struct CircuitBranch
{
    const(char)[] id;
    const(char)[] owner;
    const(char)[] label;
    const(char)[] kind;
    const(char)[] parent;
    const(char)[] child;
    uint capacity_amps;
    bool conducting = true;
    int parent_terminal = -1;
    int child_terminal = -1;
}

struct Bus
{
    const(char)[] circuit;
    MeterData balance;
    Coverage coverage;
    float accounted_power = float.nan;
    float residual_power = float.nan;
    float unaccounted_load_power = float.nan;
    float unaccounted_source_power = float.nan;
    float dark_power_bound = float.nan;
    float source_power = float.nan;
    float local_source_power = float.nan;
    float grid_source_power = float.nan;
    float load_power = float.nan;
    float local_fraction = float.nan;
    uint terminal_count;
    uint metered_count;
    uint dark_count;
    bool anomaly;
    bool contains_grid;
    bool explicit_root;
    int island = -1;
    int depth = -1;
    int parent = -1;
}

struct CircuitKernel
{
nothrow @nogc:
    uint generation;
    Array!CircuitTerminal terminals;
    Array!CircuitBranch branches;
    Array!Bus buses;
    int island_count;
    int grid_island = -1;

    void clear()
    {
        terminals.clear();
        branches.clear();
        buses.clear();
        island_count = 0;
        grid_island = -1;
    }

    int find_bus(const(char)[] circuit) pure
    {
        foreach (i, ref b; buses[])
            if (b.circuit == circuit)
                return cast(int)i;
        return -1;
    }

    Bus* ensure_bus(const(char)[] circuit)
    {
        int idx = find_bus(circuit);
        if (idx >= 0)
            return &buses[cast(size_t)idx];

        Bus b;
        b.circuit = circuit;
        b.contains_grid = circuit == "grid";
        buses ~= b;
        return &buses[buses.length - 1];
    }

    int add_terminal(CircuitTerminal t)
    {
        ensure_bus(t.circuit);
        terminals ~= t;
        return cast(int)(terminals.length - 1);
    }

    void add_branch(CircuitBranch b)
    {
        ensure_bus(b.parent);
        ensure_bus(b.child);
        branches ~= b;
    }

    void infer()
    {
        foreach (ref b; buses[])
            aggregate_bus(b);
        partition_islands();
        build_grid_spanning_tree();
        attribute_source_mix();
    }

private:
    void aggregate_bus(ref Bus bus)
    {
        bus.balance.reset_to_missing();
        bus.coverage = Coverage.unknown;
        bus.accounted_power = float.nan;
        bus.residual_power = float.nan;
        bus.unaccounted_load_power = float.nan;
        bus.unaccounted_source_power = float.nan;
        bus.dark_power_bound = float.nan;
        bus.source_power = float.nan;
        bus.local_source_power = float.nan;
        bus.grid_source_power = float.nan;
        bus.load_power = float.nan;
        bus.local_fraction = float.nan;
        bus.terminal_count = 0;
        bus.metered_count = 0;
        bus.dark_count = 0;
        bus.anomaly = false;

        float signed_power = 0;
        float flow_scale = 0;
        bool any_metered;
        bool dark_nonsink;
        foreach (ref t; terminals[])
        {
            if (t.circuit != bus.circuit)
                continue;
            ++bus.terminal_count;
            if (!t.metered)
            {
                ++bus.dark_count;
                if (t.domain != SignDomain.sink)
                    dark_nonsink = true;
                continue;
            }

            any_metered = true;
            ++bus.metered_count;
            signed_power += t.contribution;
            if (absf(t.contribution) > flow_scale)
                flow_scale = absf(t.contribution);
            bus.balance.write_value(MeterField.power, 0, signed_power);
            bus.balance.mark(MeterField.power, 0, Provenance.inferred_sum);
            if (t.meter.has(MeterField.voltage) && !bus.balance.has(MeterField.voltage))
            {
                bus.balance.voltage[0] = t.meter.voltage[0];
                bus.balance.mark(MeterField.voltage, 0, Provenance.inferred_sum);
            }
            if (t.meter.has(MeterField.current))
            {
                float c = bus.balance.has(MeterField.current) ? bus.balance.current[0].value : 0;
                bus.balance.current[0] = MeterAmps(t.meter.current[0].value + c);
                bus.balance.mark(MeterField.current, 0, Provenance.inferred_sum);
            }
        }

        if (!any_metered)
            return;

        bus.accounted_power = signed_power;
        classify_bus(bus, signed_power, flow_scale, dark_nonsink);
    }

    void classify_bus(ref Bus bus, float signed_power, float flow_scale, bool dark_nonsink)
    {
        bus.residual_power = signed_power;
        bus.unaccounted_load_power = signed_power > 0 ? signed_power : 0;
        bus.unaccounted_source_power = signed_power < 0 ? -signed_power : 0;

        // health classification needs a tolerance: bracketing meters always disagree slightly by
        // stacked calibration + wiring loss, and that is not power appearing from nowhere
        float noise_floor_w = flow_scale * 0.02f > 50 ? flow_scale * 0.02f : 50;
        bool balanced = absf(signed_power) <= noise_floor_w;

        if (bus.dark_count == 0)
        {
            if (balanced)
                bus.coverage = Coverage.measured;
            else
            {
                bus.coverage = Coverage.rogue_value;
                if (signed_power < 0 && !dark_nonsink)
                    bus.anomaly = true;
                bus.balance.mark(MeterField.power, 0, Provenance.rogue);
            }
            return;
        }

        bus.coverage = Coverage.bounded;
        if (signed_power < 0)
            bus.dark_power_bound = dark_nonsink ? -signed_power : 0;
        else
        {
            bus.dark_power_bound = 0;
            if (!balanced)
                bus.anomaly = true;
        }
    }

    void partition_islands()
    {
        foreach (ref bus; buses[])
            bus.island = -1;
        island_count = 0;
        grid_island = -1;

        foreach (i, ref root; buses[])
        {
            if (root.island >= 0)
                continue;
            int island = island_count++;
            flood_island(cast(int)i, island);
        }

        foreach (ref bus; buses[])
            if (bus.contains_grid)
                grid_island = bus.island;
    }

    void flood_island(int start, int island)
    {
        Array!int queue;
        queue ~= start;
        buses[cast(size_t)start].island = island;
        for (size_t qi = 0; qi < queue.length; ++qi)
        {
            int bi = queue[qi];
            foreach (ref b; branches[])
            {
                if (!b.conducting)
                    continue;
                int other = adjacent_bus(bi, b);
                if (other < 0)
                    continue;
                Bus* other_bus = &buses[cast(size_t)other];
                if (other_bus.island >= 0)
                    continue;
                other_bus.island = island;
                queue ~= other;
            }
        }
    }

    int adjacent_bus(int bus, ref const CircuitBranch b) pure
    {
        int parent = find_bus(b.parent);
        int child = find_bus(b.child);
        if (bus == parent)
            return child;
        if (bus == child)
            return parent;
        return -1;
    }

    void build_grid_spanning_tree()
    {
        foreach (ref bus; buses[])
        {
            bus.parent = -1;
            bus.depth = -1;
        }

        int root = find_bus("grid");
        if (root < 0)
            root = first_explicit_root();
        if (root < 0)
            return;

        Array!int queue;
        queue ~= root;
        buses[cast(size_t)root].parent = root;
        buses[cast(size_t)root].depth = 0;
        for (size_t qi = 0; qi < queue.length; ++qi)
        {
            int bi = queue[qi];
            foreach (ref b; branches[])
            {
                if (!b.conducting)
                    continue;
                int other = adjacent_bus(bi, b);
                if (other < 0)
                    continue;
                Bus* other_bus = &buses[cast(size_t)other];
                if (other_bus.parent >= 0)
                    continue;
                other_bus.parent = bi;
                other_bus.depth = buses[cast(size_t)bi].depth + 1;
                queue ~= other;
            }
        }
    }

    int first_explicit_root() pure
    {
        foreach (i, ref bus; buses[])
            if (bus.explicit_root)
                return cast(int)i;
        return -1;
    }

    void attribute_source_mix()
    {
        Array!float local;
        Array!float grid;
        Array!float next_local;
        Array!float next_grid;

        local.resize(buses.length);
        grid.resize(buses.length);
        next_local.resize(buses.length);
        next_grid.resize(buses.length);

        seed_source_mix(local, grid);
        foreach (_; 0 .. buses.length + branches.length + 1)
        {
            seed_source_mix(next_local, next_grid);

            foreach (ref branch; branches[])
            {
                if (!branch.conducting)
                    continue;
                int parent = find_bus(branch.parent);
                int child = find_bus(branch.child);
                if (parent < 0 || child < 0)
                    continue;

                float flow = branch_flow_down(branch);
                if (flow != flow || flow == 0)
                    continue;

                int source = flow > 0 ? parent : child;
                int sink = flow > 0 ? child : parent;
                float amount = absf(flow);
                float fraction = source_fraction(local[][cast(size_t)source], grid[][cast(size_t)source],
                                                 buses[cast(size_t)source].contains_grid);
                next_local[][cast(size_t)sink] += amount * fraction;
                next_grid[][cast(size_t)sink] += amount * (1 - fraction);
            }

            local = next_local;
            grid = next_grid;
        }

        foreach (i, ref bus; buses[])
        {
            bus.local_source_power = local[][i];
            bus.grid_source_power = grid[][i];
            bus.source_power = local[][i] + grid[][i];
            bus.local_fraction = source_fraction(local[][i], grid[][i], bus.contains_grid);
        }

        foreach (ref terminal; terminals[])
        {
            terminal.consumed_power = float.nan;
            terminal.supplied_power = float.nan;
            terminal.local_power = float.nan;
            terminal.grid_power = float.nan;
            terminal.local_fraction = float.nan;

            if (!terminal.metered)
                continue;

            int bus = find_bus(terminal.circuit);
            float power = terminal.contribution;
            if (bus < 0 || power != power)
                continue;

            if (power >= 0)
            {
                float fraction = buses[cast(size_t)bus].local_fraction;
                terminal.consumed_power = power;
                terminal.supplied_power = 0;
                terminal.local_power = power * fraction;
                terminal.grid_power = power * (1 - fraction);
                terminal.local_fraction = fraction;
            }
            else
            {
                terminal.consumed_power = 0;
                terminal.supplied_power = -power;
                terminal.local_power = -power;
                terminal.grid_power = 0;
                terminal.local_fraction = 1;
            }
        }
    }

    void seed_source_mix(ref Array!float local, ref Array!float grid)
    {
        foreach (i, ref bus; buses[])
        {
            local[][i] = local_terminal_source(cast(int)i);
            grid[][i] = bus.contains_grid ? grid_terminal_source(cast(int)i, local[][i]) : 0;
            bus.load_power = terminal_load(cast(int)i);
        }
    }

    float local_terminal_source(int bus_index) pure
    {
        float source = 0;
        foreach (i, ref terminal; terminals[])
        {
            if (terminal.circuit != buses[cast(size_t)bus_index].circuit || is_branch_terminal(cast(int)i))
                continue;
            float power = terminal.contribution;
            if (power == power && power < 0)
                source += -power;
        }
        return source;
    }

    float terminal_load(int bus_index) pure
    {
        float load = 0;
        foreach (ref terminal; terminals[])
        {
            if (terminal.circuit != buses[cast(size_t)bus_index].circuit)
                continue;
            float power = terminal.contribution;
            if (power == power && power > 0)
                load += power;
        }
        return load;
    }

    float grid_terminal_source(int bus_index, float local_source) pure
    {
        float demand = terminal_load(bus_index);
        float needed = demand - local_source;
        return needed > 0 ? needed : 0;
    }

    bool is_branch_terminal(int terminal) pure
    {
        foreach (ref branch; branches[])
            if (branch.parent_terminal == terminal || branch.child_terminal == terminal)
                return true;
        return false;
    }

    float branch_flow_down(ref const CircuitBranch branch) pure
    {
        if (branch.parent_terminal >= 0)
        {
            float power = terminal_power(branch.parent_terminal);
            if (power == power)
                return power;
        }
        if (branch.child_terminal >= 0)
        {
            float power = terminal_power(branch.child_terminal);
            if (power == power)
                return -power;
        }
        return float.nan;
    }

    float terminal_power(int terminal) pure
    {
        if (terminal < 0 || terminal >= terminals.length)
            return float.nan;
        return terminals[cast(size_t)terminal].contribution;
    }
}

SignDomain domain_for_flow(FlowDomain flow) pure
{
    final switch (flow)
    {
        case FlowDomain.unknown:       return SignDomain.unknown;
        case FlowDomain.consume:       return SignDomain.sink;
        case FlowDomain.supply:        return SignDomain.source;
        case FlowDomain.bidirectional: return SignDomain.bidirectional;
    }
}


float absf(float v) pure
{
    return v < 0 ? -v : v;
}

float source_fraction(float local, float grid, bool contains_grid) pure
{
    float total = local + grid;
    if (total > 0)
        return local / total;
    return contains_grid ? 0 : 1;
}