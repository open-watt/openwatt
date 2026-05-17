module apps.energy.state;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time : Duration, getTime;

import apps.energy.appliance;
import apps.energy.kernel;
import apps.energy.meter;
import apps.energy.production;
import apps.energy.topology;

import manager;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:

alias CircuitBus = apps.energy.kernel.Bus;

// The synthetic `energy` device. Carries all runtime state the energy app
// publishes: islands (with per-island accounts, pressures, mode),
// active policies, current allocations, and tunable config. Dashboard, the
// /apps/energy/why command, and external subscribers (sync, MQTT) read from
// this device like any other.
//
// Top-level structure (populated by subsequent Phase 0 work):
//
//   energy
//     circuit
//       bus.<id>.{coverage,residual_power,terminal_count,...}
//       terminal.<id>.{owner,port,circuit,role,domain,local_fraction,...}
//       branch.<id>.{kind,parent,child,capacity,conducting,...}
//       production.<owner.group>.{power,member_count,aggregate_count,...}
//     topology
//       bus.<id>.{ports,links,coverage,...}
//     islands
//       <id>
//         account.{solar,battery,grid,generation,load.*}
//         pressure.{today,overnight,branch.*}
//         budget.{overnight_reserve_kwh,...}
//         constraints.binding
//         members, mode
//     policy
//       <policy_id>.{tier,goal,deadline,satisfied,marginal_value,...}
//     allocation
//       <target_id>.{setpoint_w,actual_w,reason,active_policy}
//     config
//       overnight_reserve_factor, voltage_threshold, slow_loop_period, daily_reset_time

Device create_energy_device()
{
    Device d = g_app.allocator.allocT!Device("energy".makeString(g_app.allocator));
    d.hidden = true;

    d.add_component(g_app.allocator.allocT!Component("topology".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("circuit".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("islands".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("policy".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("allocation".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("control_path".makeString(g_app.allocator)));
    d.add_component(g_app.allocator.allocT!Component("config".makeString(g_app.allocator)));

    g_app.devices.insert(d.id[], d);
    d.notify(ComponentEvent.tree_changed);
    d.notify(ComponentEvent.online);

    return d;
}

struct TopologyPublisher
{
nothrow @nogc:
    bool bound;

    Element* circuit_generation;
    Element* circuit_buses_count;
    Element* circuit_terminals_count;
    Element* circuit_branches_count;
    Element* circuit_islands_count;
    Element* circuit_grid_island;
    Element* topology_generation;
    Element* productions_count;
    Element* production_contributions_count;

    Array!CircuitBusPublishCache circuit_buses;
    Array!CircuitTerminalPublishCache circuit_terminals;
    Array!TopologyBusPublishCache topology_buses;
    Array!TopologyPortPublishCache topology_ports;
    Array!TopologyAppliancePublishCache topology_appliances;
    Array!TopologyLinkPublishCache topology_links;
    Array!ProductionPublishCache productions;
    Array!ProductionContributionPublishCache production_contributions;

    void publish(Device energy, ref TopologyGraph graph, bool rebuild_layout)
    {
        auto t = getTime();
        if (rebuild_layout || !bound || !shape_matches(graph))
        {
            bind(energy, graph);
            log_slow_topology_publish("bind", getTime() - t);
            t = getTime();
        }
        publish_values(graph);
        log_slow_topology_publish("values", getTime() - t);
    }

    bool shape_matches(ref TopologyGraph graph) const pure
    {
        return circuit_buses.length == graph.kernel.buses.length
            && circuit_terminals.length == graph.kernel.terminals.length
            && topology_buses.length == graph.bus_list.length
            && topology_ports.length == graph.ports.length
            && topology_appliances.length == graph.ports.length
            && topology_links.length == graph.links.length
            && productions.length == graph.productions.length
            && production_contributions.length == graph.production_contributions.length;
    }

    void bind(Device energy, ref TopologyGraph graph)
    {
        auto t = getTime();
        publish_topology_layout(energy, graph);
        log_slow_topology_publish("layout", getTime() - t);

        t = getTime();
        circuit_generation = energy.find_or_create_element("circuit.generation");
        circuit_buses_count = energy.find_or_create_element("circuit.buses");
        circuit_terminals_count = energy.find_or_create_element("circuit.terminals");
        circuit_branches_count = energy.find_or_create_element("circuit.branches");
        circuit_islands_count = energy.find_or_create_element("circuit.islands");
        circuit_grid_island = energy.find_or_create_element("circuit.grid_island");
        topology_generation = energy.find_or_create_element("topology.generation");
        productions_count = energy.find_or_create_element("circuit.productions");
        production_contributions_count = energy.find_or_create_element("circuit.production_contributions");

        circuit_buses.clear();
        foreach (ref bus; graph.kernel.buses[])
        {
            CircuitBusPublishCache c;
            c.bind(energy, bus);
            circuit_buses ~= c;
        }

        circuit_terminals.clear();
        foreach (ref terminal; graph.kernel.terminals[])
        {
            CircuitTerminalPublishCache c;
            c.bind(energy, terminal);
            circuit_terminals ~= c;
        }

        topology_buses.clear();
        foreach (bus; graph.bus_list[])
        {
            TopologyBusPublishCache c;
            c.bind(energy, bus);
            topology_buses ~= c;
        }

        topology_ports.clear();
        foreach (port; graph.ports[])
        {
            TopologyPortPublishCache c;
            c.bind(energy, port);
            topology_ports ~= c;
        }

        topology_appliances.clear();
        foreach (port; graph.ports[])
        {
            TopologyAppliancePublishCache c;
            c.bind(energy, port);
            topology_appliances ~= c;
        }

        topology_links.clear();
        foreach (link; graph.links[])
        {
            TopologyLinkPublishCache c;
            c.bind(energy, link);
            topology_links ~= c;
        }

        productions.clear();
        foreach (ref production; graph.productions[])
        {
            ProductionPublishCache c;
            c.bind(energy, production);
            productions ~= c;
        }

        production_contributions.clear();
        foreach (i, ref contribution; graph.production_contributions[])
        {
            ProductionContributionPublishCache c;
            c.bind(energy, cast(uint)i);
            production_contributions ~= c;
        }
        log_slow_topology_publish("cache_bind", getTime() - t);

        bound = true;
    }

    void publish_values(ref TopologyGraph graph)
    {
        circuit_generation.value = cast(int)graph.kernel.generation;
        circuit_buses_count.value = cast(int)graph.kernel.buses.length;
        circuit_terminals_count.value = cast(int)graph.kernel.terminals.length;
        circuit_branches_count.value = cast(int)graph.kernel.branches.length;
        circuit_islands_count.value = graph.kernel.island_count;
        circuit_grid_island.value = graph.kernel.grid_island;
        topology_generation.value = cast(int)graph.generation;
        productions_count.value = cast(int)graph.productions.length;
        production_contributions_count.value = cast(int)graph.production_contributions.length;

        foreach (i, ref bus; graph.kernel.buses[])
            circuit_buses[i].publish(bus, graph.kernel.generation);
        foreach (i, ref terminal; graph.kernel.terminals[])
            circuit_terminals[i].publish(terminal, graph.kernel.generation);
        foreach (i, bus; graph.bus_list[])
            topology_buses[i].publish(bus, graph.generation);
        foreach (i, port; graph.ports[])
        {
            topology_ports[i].publish(port, graph.generation);
            topology_appliances[i].publish(port, graph.generation);
        }
        foreach (i, link; graph.links[])
            topology_links[i].publish(link, graph.generation);
        foreach (i, ref production; graph.productions[])
            productions[i].publish(production, graph.generation);
        foreach (i, ref contribution; graph.production_contributions[])
            production_contributions[i].publish(contribution, graph.generation);
    }
}

private void log_slow_topology_publish(const(char)[] phase, Duration d)
{
    if (d.as!"msecs" >= 50)
        writeWarning("energy.topology.publish.", phase, ": ", d.as!"msecs", "ms");
}

private void publish_topology_layout(Device energy, ref TopologyGraph graph)
{
    publish_circuit_kernel(energy, graph.kernel);
    publish_productions(energy, graph.generation,
                        graph.productions, graph.production_contributions);

    energy.find_or_create_element("topology.schema_version").value = 1;
    energy.find_or_create_element("topology.generation").value = cast(int)graph.generation;

    foreach (bus; graph.bus_list[])
    {
        const(char)[] base = tconcat("topology.bus.", bus.id[], ".");
        energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)graph.generation;
        energy.find_or_create_element(tconcat(base, "name")).value = bus.id[].makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "coverage")).value = coverage_name(bus.coverage).makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "accounted_power")).value = bus.accounted_power;
        energy.find_or_create_element(tconcat(base, "residual_power")).value = bus.residual_power;
        energy.find_or_create_element(tconcat(base, "unaccounted_load_power")).value = bus.unaccounted_load_power;
        energy.find_or_create_element(tconcat(base, "unaccounted_source_power")).value = bus.unaccounted_source_power;
        energy.find_or_create_element(tconcat(base, "dark_power_bound")).value = bus.dark_power_bound;
        energy.find_or_create_element(tconcat(base, "anomaly")).value = bus.anomaly;
        energy.find_or_create_element(tconcat(base, "ports")).value = cast(int)bus.ports.length;
        energy.find_or_create_element(tconcat(base, "links")).value = cast(int)bus.links.length;
        energy.find_or_create_element(tconcat(base, "metered_ports")).value = cast(int)bus.metered_ports;
        energy.find_or_create_element(tconcat(base, "dark_ports")).value = cast(int)bus.dark_ports;
        energy.find_or_create_element(tconcat(base, "contains_grid")).value = bus.contains_grid;
        energy.find_or_create_element(tconcat(base, "explicit_root")).value = bus.explicit_root;
        publish_meter(energy, base, bus.balance);
    }

    foreach (port; graph.ports[])
    {
        publish_port(energy, graph.generation, port);
    }

    foreach (port; graph.ports[])
    {
        if (port.owner is null || !is_first_owner_port(graph, port))
            continue;
        publish_appliance_index(energy, graph, port.owner);
        publish_control_path(energy, graph, port.owner);
    }

    foreach (port; graph.ports[])
    {
        if (port.owner is null)
            continue;
        const(char)[] port_id = port.path.length ? port.path[] : port_role_name(port.role);
        const(char)[] base = tconcat("topology.appliance.", port.owner.name[], ".", port_id, ".");
        energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)graph.generation;
        energy.find_or_create_element(tconcat(base, "owner")).value = port.owner.name[].makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "bus")).value = port.bus.id[].makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "port_role")).value = port_role_name(port.role).makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "port")).value = port_id.makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "flow")).value = flow_domain_name(port.flow).makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "meter_sign")).value = meter_sign_name(port.meter_sign).makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "root")).value = port.root;
        publish_meter(energy, base, port.meter_data);
    }

    foreach (link; graph.links[])
    {
        const(char)[] id = link.id[];
        if (id.length == 0)
            continue;
        const(char)[] base = tconcat("topology.link.", id, ".");
        energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)graph.generation;
        energy.find_or_create_element(tconcat(base, "id")).value = id.makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "label")).value = link.label.makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "owner")).value = (link.owner ? link.owner.name[] : "").makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "parent")).value = link.a.id[].makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "child")).value = link.b.id[].makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "parent_port")).value = (link.port_a ? link.port_a.id[] : "").makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "child_port")).value = (link.port_b ? link.port_b.id[] : "").makeString(defaultAllocator());
        const(char)[] kind = link.kind.length ? link.kind : link.owner ? "appliance" : "link";
        energy.find_or_create_element(tconcat(base, "kind")).value = kind.makeString(defaultAllocator());
        energy.find_or_create_element(tconcat(base, "closed")).value = link.closed;
        energy.find_or_create_element(tconcat(base, "capacity")).value = cast(int)link.capacity_amps;
        publish_meter(energy, base, link.port_a ? link.port_a.meter_data : MeterData.init);
    }
}

private struct MeterPublishCache
{
nothrow @nogc:
    enum size_t cell_count = 9;
    Element*[cell_count] value;
    Element*[cell_count] source;
    float[cell_count] last_value;
    Provenance[cell_count] last_source;
    bool[cell_count] seen;

    void bind(Device energy, const(char)[] base)
    {
        bind_cell(energy, base, 0, "power");
        bind_cell(energy, base, 1, "current");
        bind_cell(energy, base, 2, "voltage");
        bind_cell(energy, base, 3, "import");
        bind_cell(energy, base, 4, "export");
        bind_cell(energy, base, 5, "apparent");
        bind_cell(energy, base, 6, "reactive");
        bind_cell(energy, base, 7, "pf");
        bind_cell(energy, base, 8, "frequency");
        foreach (i; 0 .. cell_count)
            seen[i] = false;
    }

    void bind_cell(Device energy, const(char)[] base, size_t i, const(char)[] name)
    {
        value[i] = energy.find_or_create_element(tconcat(base, name));
        source[i] = energy.find_or_create_element(tconcat(base, name, "_source"));
    }

    void publish(ref const MeterData data)
    {
        publish_cell(0, data, MeterField.power);
        publish_cell(1, data, MeterField.current);
        publish_cell(2, data, MeterField.voltage);
        publish_cell(3, data, MeterField.total_import_active);
        publish_cell(4, data, MeterField.total_export_active);
        publish_cell(5, data, MeterField.apparent);
        publish_cell(6, data, MeterField.reactive);
        publish_cell(7, data, MeterField.power_factor);
        publish_cell(8, data, MeterField.frequency);
    }

    void publish_cell(size_t i, ref const MeterData data, MeterField field)
    {
        Provenance prov = data.source(field);
        float v = data.has(field) ? data.read_value(field) : float.nan;
        if (!seen[i] || prov != last_source[i] || !same_float(v, last_value[i]))
        {
            value[i].value = v;
            if (!seen[i] || prov != last_source[i])
                source[i].value = provenance_name(prov).makeString(defaultAllocator());
            last_value[i] = v;
            last_source[i] = prov;
            seen[i] = true;
        }
    }
}

private struct IntPublishCell
{
nothrow @nogc:
    Element* element;
    int last;
    bool seen;

    void bind(Element* e)
    {
        element = e;
        seen = false;
    }

    void publish(int value)
    {
        if (!seen || value != last)
        {
            element.value = value;
            last = value;
            seen = true;
        }
    }
}

private struct BoolPublishCell
{
nothrow @nogc:
    Element* element;
    bool last;
    bool seen;

    void bind(Element* e)
    {
        element = e;
        seen = false;
    }

    void publish(bool value)
    {
        if (!seen || value != last)
        {
            element.value = value;
            last = value;
            seen = true;
        }
    }
}

private struct FloatPublishCell
{
nothrow @nogc:
    Element* element;
    float last;
    bool seen;

    void bind(Element* e)
    {
        element = e;
        seen = false;
    }

    void publish(float value)
    {
        if (!seen || !same_float(value, last))
        {
            element.value = value;
            last = value;
            seen = true;
        }
    }
}

private struct StringPublishCell
{
nothrow @nogc:
    Element* element;
    String last;
    bool seen;

    void bind(Element* e)
    {
        element = e;
        seen = false;
        last = null;
    }

    void publish(const(char)[] value)
    {
        if (!seen || last != value)
        {
            String s = value.makeString(defaultAllocator());
            element.value = s;
            last = s;
            seen = true;
        }
    }
}

private struct CircuitBusPublishCache
{
nothrow @nogc:
    IntPublishCell generation;
    StringPublishCell coverage;
    FloatPublishCell accounted_power;
    FloatPublishCell residual_power;
    FloatPublishCell unaccounted_load_power;
    FloatPublishCell unaccounted_source_power;
    FloatPublishCell dark_power_bound;
    FloatPublishCell source_power;
    FloatPublishCell local_source_power;
    FloatPublishCell grid_source_power;
    FloatPublishCell load_power;
    FloatPublishCell local_fraction;
    IntPublishCell terminal_count;
    IntPublishCell metered_count;
    IntPublishCell dark_count;
    BoolPublishCell anomaly;
    IntPublishCell island;
    IntPublishCell depth;
    IntPublishCell parent;
    MeterPublishCache meter;

    void bind(Device energy, ref const CircuitBus bus)
    {
        const(char)[] base = tconcat("circuit.bus.", bus.circuit, ".");
        generation.bind(elem(energy, base, "generation"));
        coverage.bind(elem(energy, base, "coverage"));
        accounted_power.bind(elem(energy, base, "accounted_power"));
        residual_power.bind(elem(energy, base, "residual_power"));
        unaccounted_load_power.bind(elem(energy, base, "unaccounted_load_power"));
        unaccounted_source_power.bind(elem(energy, base, "unaccounted_source_power"));
        dark_power_bound.bind(elem(energy, base, "dark_power_bound"));
        source_power.bind(elem(energy, base, "source_power"));
        local_source_power.bind(elem(energy, base, "local_source_power"));
        grid_source_power.bind(elem(energy, base, "grid_source_power"));
        load_power.bind(elem(energy, base, "load_power"));
        local_fraction.bind(elem(energy, base, "local_fraction"));
        terminal_count.bind(elem(energy, base, "terminal_count"));
        metered_count.bind(elem(energy, base, "metered_count"));
        dark_count.bind(elem(energy, base, "dark_count"));
        anomaly.bind(elem(energy, base, "anomaly"));
        island.bind(elem(energy, base, "island"));
        depth.bind(elem(energy, base, "depth"));
        parent.bind(elem(energy, base, "parent"));
        meter.bind(energy, base);
    }

    void publish(ref const CircuitBus bus, uint gen)
    {
        generation.publish(cast(int)gen);
        coverage.publish(coverage_name(bus.coverage));
        accounted_power.publish(bus.accounted_power);
        residual_power.publish(bus.residual_power);
        unaccounted_load_power.publish(bus.unaccounted_load_power);
        unaccounted_source_power.publish(bus.unaccounted_source_power);
        dark_power_bound.publish(bus.dark_power_bound);
        source_power.publish(bus.source_power);
        local_source_power.publish(bus.local_source_power);
        grid_source_power.publish(bus.grid_source_power);
        load_power.publish(bus.load_power);
        local_fraction.publish(bus.local_fraction);
        terminal_count.publish(cast(int)bus.terminal_count);
        metered_count.publish(cast(int)bus.metered_count);
        dark_count.publish(cast(int)bus.dark_count);
        anomaly.publish(bus.anomaly);
        island.publish(cast(int)bus.island);
        depth.publish(cast(int)bus.depth);
        parent.publish(cast(int)bus.parent);
        meter.publish(bus.balance);
    }
}

private struct CircuitTerminalPublishCache
{
nothrow @nogc:
    Element* generation;
    FloatPublishCell consumed_power;
    FloatPublishCell supplied_power;
    FloatPublishCell local_power;
    FloatPublishCell grid_power;
    FloatPublishCell local_fraction;
    FloatPublishCell soc;
    MeterPublishCache meter;

    void bind(Device energy, ref const CircuitTerminal terminal)
    {
        const(char)[] base = tconcat("circuit.terminal.", terminal.id, ".");
        generation = elem(energy, base, "generation");
        consumed_power.bind(elem(energy, base, "consumed_power"));
        supplied_power.bind(elem(energy, base, "supplied_power"));
        local_power.bind(elem(energy, base, "local_power"));
        grid_power.bind(elem(energy, base, "grid_power"));
        local_fraction.bind(elem(energy, base, "local_fraction"));
        soc.bind(elem(energy, base, "soc"));
        meter.bind(energy, base);
    }

    void publish(ref const CircuitTerminal terminal, uint gen)
    {
        generation.value = cast(int)gen;
        consumed_power.publish(terminal.consumed_power);
        supplied_power.publish(terminal.supplied_power);
        local_power.publish(terminal.local_power);
        grid_power.publish(terminal.grid_power);
        local_fraction.publish(terminal.local_fraction);
        soc.publish(terminal.soc);
        meter.publish(terminal.meter);
    }
}

private struct TopologyBusPublishCache
{
nothrow @nogc:
    IntPublishCell generation;
    StringPublishCell coverage;
    FloatPublishCell accounted_power;
    FloatPublishCell residual_power;
    FloatPublishCell unaccounted_load_power;
    FloatPublishCell unaccounted_source_power;
    FloatPublishCell dark_power_bound;
    BoolPublishCell anomaly;
    IntPublishCell metered_ports;
    IntPublishCell dark_ports;
    MeterPublishCache meter;

    void bind(Device energy, apps.energy.topology.Bus* bus)
    {
        const(char)[] base = tconcat("topology.bus.", bus.id[], ".");
        generation.bind(elem(energy, base, "generation"));
        coverage.bind(elem(energy, base, "coverage"));
        accounted_power.bind(elem(energy, base, "accounted_power"));
        residual_power.bind(elem(energy, base, "residual_power"));
        unaccounted_load_power.bind(elem(energy, base, "unaccounted_load_power"));
        unaccounted_source_power.bind(elem(energy, base, "unaccounted_source_power"));
        dark_power_bound.bind(elem(energy, base, "dark_power_bound"));
        anomaly.bind(elem(energy, base, "anomaly"));
        metered_ports.bind(elem(energy, base, "metered_ports"));
        dark_ports.bind(elem(energy, base, "dark_ports"));
        meter.bind(energy, base);
    }

    void publish(apps.energy.topology.Bus* bus, uint gen)
    {
        generation.publish(cast(int)gen);
        coverage.publish(coverage_name(bus.coverage));
        accounted_power.publish(bus.accounted_power);
        residual_power.publish(bus.residual_power);
        unaccounted_load_power.publish(bus.unaccounted_load_power);
        unaccounted_source_power.publish(bus.unaccounted_source_power);
        dark_power_bound.publish(bus.dark_power_bound);
        anomaly.publish(bus.anomaly);
        metered_ports.publish(cast(int)bus.metered_ports);
        dark_ports.publish(cast(int)bus.dark_ports);
        meter.publish(bus.balance);
    }
}

private struct TopologyPortPublishCache
{
nothrow @nogc:
    Element* generation;

    MeterPublishCache meter;

    void bind(Device energy, Port* port)
    {
        const(char)[] base = tconcat("topology.port.", port.id[], ".");
        generation = elem(energy, base, "generation");

        meter.bind(energy, base);
    }

    void publish(Port* port, uint gen)
    {
        generation.value = cast(int)gen;
        meter.publish(port.meter_data);
    }
}

private struct TopologyAppliancePublishCache
{
nothrow @nogc:
    Element* generation;

    MeterPublishCache meter;

    void bind(Device energy, Port* port)
    {
        if (port.owner is null)
            return;
        const(char)[] port_id = port.path.length ? port.path[] : port_role_name(port.role);
        const(char)[] base = tconcat("topology.appliance.", port.owner.name[], ".", port_id, ".");
        generation = elem(energy, base, "generation");

        meter.bind(energy, base);
    }

    void publish(Port* port, uint gen)
    {
        if (generation is null)
            return;
        generation.value = cast(int)gen;
        meter.publish(port.meter_data);
    }
}

private struct TopologyLinkPublishCache
{
nothrow @nogc:
    Element* generation;
    Element* closed;
    MeterPublishCache meter;

    void bind(Device energy, Link* link)
    {
        if (link.id.length == 0)
            return;
        const(char)[] base = tconcat("topology.link.", link.id[], ".");
        generation = elem(energy, base, "generation");
        closed = elem(energy, base, "closed");
        meter.bind(energy, base);
    }

    void publish(Link* link, uint gen)
    {
        if (generation is null)
            return;
        generation.value = cast(int)gen;
        closed.value = link.closed;
        if (link.port_a)
            meter.publish(link.port_a.meter_data);
    }
}

private struct ProductionPublishCache
{
nothrow @nogc:
    Element* generation;
    Element* aggregate_power;
    Element* member_power;
    Element* aggregate_count;
    Element* member_count;
    Element* calculated;
    Element* mismatch;
    MeterPublishCache meter;

    void bind(Device energy, ref const Production production)
    {
        const(char)[] base = tconcat("circuit.production.", production.owner, ".", production.group, ".");
        generation = elem(energy, base, "generation");
        aggregate_power = elem(energy, base, "aggregate_power");
        member_power = elem(energy, base, "member_power");
        aggregate_count = elem(energy, base, "aggregate_count");
        member_count = elem(energy, base, "member_count");
        calculated = elem(energy, base, "calculated");
        mismatch = elem(energy, base, "mismatch");
        meter.bind(energy, base);
    }

    void publish(ref const Production production, uint gen)
    {
        generation.value = cast(int)gen;
        aggregate_power.value = production.aggregate_power;
        member_power.value = production.member_power;
        aggregate_count.value = cast(int)production.aggregate_count;
        member_count.value = cast(int)production.member_count;
        calculated.value = production.calculated;
        mismatch.value = production.mismatch;
        meter.publish(production.data);
    }
}

private struct ProductionContributionPublishCache
{
nothrow @nogc:
    Element* generation;

    MeterPublishCache meter;

    void bind(Device energy, uint index)
    {
        const(char)[] base = tconcat("circuit.production_contribution.", index, ".");
        generation = elem(energy, base, "generation");

        meter.bind(energy, base);
    }

    void publish(ref const ProductionContribution contribution, uint gen)
    {
        generation.value = cast(int)gen;
        meter.publish(contribution.meter);
    }
}

private Element* elem(Device energy, const(char)[] base, const(char)[] name)
{
    return energy.find_or_create_element(tconcat(base, name));
}

private bool same_float(float a, float b) pure
{
    return a == b || (a != a && b != b);
}

void publish_circuit_kernel(Device energy, ref CircuitKernel kernel)
{
    energy.find_or_create_element("circuit.schema_version").value = 1;
    energy.find_or_create_element("circuit.generation").value = cast(int)kernel.generation;
    energy.find_or_create_element("circuit.buses").value = cast(int)kernel.buses.length;
    energy.find_or_create_element("circuit.terminals").value = cast(int)kernel.terminals.length;
    energy.find_or_create_element("circuit.branches").value = cast(int)kernel.branches.length;
    energy.find_or_create_element("circuit.islands").value = kernel.island_count;
    energy.find_or_create_element("circuit.grid_island").value = kernel.grid_island;

    foreach (ref bus; kernel.buses[])
        publish_circuit_bus(energy, kernel.generation, bus);
    foreach (ref terminal; kernel.terminals[])
        publish_circuit_terminal(energy, kernel.generation, terminal);
    foreach (ref branch; kernel.branches[])
        publish_circuit_branch(energy, kernel.generation, branch);
}

void publish_productions(Device energy, uint generation, ref Array!Production productions,
                         ref Array!ProductionContribution contributions)
{
    energy.find_or_create_element("circuit.productions").value = cast(int)productions.length;
    energy.find_or_create_element("circuit.production_contributions").value = cast(int)contributions.length;

    foreach (ref production; productions[])
        publish_production(energy, generation, production);
    foreach (i, ref contribution; contributions[])
        publish_production_contribution(energy, generation, cast(uint)i, contribution);
}

private void publish_circuit_bus(Device energy, uint generation, ref const CircuitBus bus)
{
    const(char)[] base = tconcat("circuit.bus.", bus.circuit, ".");
    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)generation;
    energy.find_or_create_element(tconcat(base, "id")).value = bus.circuit.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "coverage")).value = coverage_name(bus.coverage).makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "accounted_power")).value = bus.accounted_power;
    energy.find_or_create_element(tconcat(base, "residual_power")).value = bus.residual_power;
    energy.find_or_create_element(tconcat(base, "unaccounted_load_power")).value = bus.unaccounted_load_power;
    energy.find_or_create_element(tconcat(base, "unaccounted_source_power")).value = bus.unaccounted_source_power;
    energy.find_or_create_element(tconcat(base, "dark_power_bound")).value = bus.dark_power_bound;
    energy.find_or_create_element(tconcat(base, "source_power")).value = bus.source_power;
    energy.find_or_create_element(tconcat(base, "local_source_power")).value = bus.local_source_power;
    energy.find_or_create_element(tconcat(base, "grid_source_power")).value = bus.grid_source_power;
    energy.find_or_create_element(tconcat(base, "load_power")).value = bus.load_power;
    energy.find_or_create_element(tconcat(base, "local_fraction")).value = bus.local_fraction;
    energy.find_or_create_element(tconcat(base, "terminal_count")).value = cast(int)bus.terminal_count;
    energy.find_or_create_element(tconcat(base, "metered_count")).value = cast(int)bus.metered_count;
    energy.find_or_create_element(tconcat(base, "dark_count")).value = cast(int)bus.dark_count;
    energy.find_or_create_element(tconcat(base, "anomaly")).value = bus.anomaly;
    energy.find_or_create_element(tconcat(base, "contains_grid")).value = bus.contains_grid;
    energy.find_or_create_element(tconcat(base, "explicit_root")).value = bus.explicit_root;
    energy.find_or_create_element(tconcat(base, "island")).value = cast(int)bus.island;
    energy.find_or_create_element(tconcat(base, "depth")).value = cast(int)bus.depth;
    energy.find_or_create_element(tconcat(base, "parent")).value = cast(int)bus.parent;
    publish_meter(energy, base, bus.balance);
}

private void publish_circuit_terminal(Device energy, uint generation, ref const CircuitTerminal terminal)
{
    const(char)[] base = tconcat("circuit.terminal.", terminal.id, ".");
    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)generation;
    energy.find_or_create_element(tconcat(base, "id")).value = terminal.id.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "owner")).value = terminal.owner.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "owner_kind")).value = terminal.owner_kind.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "owner_device")).value = terminal.owner_device.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "port")).value = terminal.port.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "label")).value = terminal.label.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "circuit")).value = terminal.circuit.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "role")).value = terminal.role.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "domain")).value = sign_domain_name(terminal.domain).makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "consumed_power")).value = terminal.consumed_power;
    energy.find_or_create_element(tconcat(base, "supplied_power")).value = terminal.supplied_power;
    energy.find_or_create_element(tconcat(base, "local_power")).value = terminal.local_power;
    energy.find_or_create_element(tconcat(base, "grid_power")).value = terminal.grid_power;
    energy.find_or_create_element(tconcat(base, "local_fraction")).value = terminal.local_fraction;
    energy.find_or_create_element(tconcat(base, "soc")).value = terminal.soc;
    energy.find_or_create_element(tconcat(base, "root")).value = terminal.root;
    publish_meter(energy, base, terminal.meter);
}

private void publish_circuit_branch(Device energy, uint generation, ref const CircuitBranch branch)
{
    const(char)[] base = tconcat("circuit.branch.", branch.id, ".");
    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)generation;
    energy.find_or_create_element(tconcat(base, "id")).value = branch.id.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "owner")).value = branch.owner.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "label")).value = branch.label.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "kind")).value = branch.kind.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "parent")).value = branch.parent.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "child")).value = branch.child.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "capacity")).value = cast(int)branch.capacity_amps;
    energy.find_or_create_element(tconcat(base, "conducting")).value = branch.conducting;
    energy.find_or_create_element(tconcat(base, "parent_terminal")).value = cast(int)branch.parent_terminal;
    energy.find_or_create_element(tconcat(base, "child_terminal")).value = cast(int)branch.child_terminal;
}

private void publish_production(Device energy, uint generation, ref const Production production)
{
    const(char)[] base = tconcat("circuit.production.", production.owner, ".", production.group, ".");
    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)generation;
    energy.find_or_create_element(tconcat(base, "owner")).value = production.owner.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "group")).value = production.group.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "aggregate_power")).value = production.aggregate_power;
    energy.find_or_create_element(tconcat(base, "member_power")).value = production.member_power;
    energy.find_or_create_element(tconcat(base, "aggregate_count")).value = cast(int)production.aggregate_count;
    energy.find_or_create_element(tconcat(base, "member_count")).value = cast(int)production.member_count;
    energy.find_or_create_element(tconcat(base, "calculated")).value = production.calculated;
    energy.find_or_create_element(tconcat(base, "mismatch")).value = production.mismatch;
    publish_meter(energy, base, production.data);
}

private void publish_production_contribution(Device energy, uint generation, uint index,
                                             ref const ProductionContribution contribution)
{
    const(char)[] base = tconcat("circuit.production_contribution.", index, ".");
    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)generation;
    energy.find_or_create_element(tconcat(base, "owner")).value = contribution.owner.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "group")).value = contribution.group.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "port")).value = contribution.port.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "circuit")).value = contribution.circuit.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "kind")).value =
        production_contribution_kind_name(contribution.kind).makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "component")).value =
        (contribution.component ? contribution.component.id[] : "").makeString(defaultAllocator());
    publish_meter(energy, base, contribution.meter);
}

private void publish_control_path(Device energy, ref TopologyGraph graph, Appliance owner)
{
    ControlPath path;
    graph.build_control_path(owner, path);

    const(char)[] base = tconcat("control_path.", owner.name[], ".");
    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)graph.generation;
    energy.find_or_create_element(tconcat(base, "target")).value = owner.name[].makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "target_bus")).value =
        (path.target_bus ? path.target_bus.id[] : "").makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "source_bus")).value =
        (path.source_bus ? path.source_bus.id[] : "").makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "complete")).value = path.complete;
    energy.find_or_create_element(tconcat(base, "links")).value = cast(int)path.links.length;
    Array!char route;
    append_control_path_route(route, path);
    energy.find_or_create_element(tconcat(base, "route")).value = route[].makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "headroom_amps")).value = path.headroom_amps;
    energy.find_or_create_element(tconcat(base, "headroom_watts")).value = path.headroom_watts;
    energy.find_or_create_element(tconcat(base, "voltage")).value = path.voltage;
    energy.find_or_create_element(tconcat(base, "limiting_link")).value =
        (path.limiting_link ? path.limiting_link.id[] : "").makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "limiting_kind")).value =
        (path.limiting_link ? path.limiting_link.kind : "").makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "limiting_capacity_amps")).value =
        cast(int)path.limiting_capacity_amps;
    energy.find_or_create_element(tconcat(base, "limiting_current_amps")).value =
        path.limiting_current_amps;
}

private void append_control_path_route(ref Array!char route, ref ControlPath path)
{
    bool first = true;
    foreach (link; path.links[])
    {
        if (!first)
            route ~= ',';
        first = false;
        route.append(link.id[]);
    }
}

private bool is_first_owner_port(ref TopologyGraph graph, Port* port)
{
    foreach (candidate; graph.ports[])
    {
        if (candidate is port)
            return true;
        if (candidate.owner is port.owner)
            return false;
    }
    return true;
}

private void publish_appliance_index(Device energy, ref TopologyGraph graph, Appliance owner)
{
    const(char)[] base = tconcat("topology.appliance_index.", owner.name[], ".");
    uint port_count;
    bool explicit_root;
    foreach (port; graph.ports[])
    {
        if (port.owner !is owner)
            continue;
        ++port_count;
        explicit_root = explicit_root || port.root;
    }

    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)graph.generation;
    energy.find_or_create_element(tconcat(base, "id")).value = owner.name[].makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "kind")).value = owner.kind.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "root")).value = explicit_root || owner.root;
    energy.find_or_create_element(tconcat(base, "device")).value = owner.device.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "meter")).value = owner.meter.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "state")).value = owner.state.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "vin")).value = owner.vin.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "ports")).value = cast(int)port_count;
}

private void publish_port(Device energy, uint generation, Port* port)
{
    const(char)[] base = tconcat("topology.port.", port.id[], ".");
    const(char)[] port_name = port.path.length ? port.path[] : port_role_name(port.role);
    energy.find_or_create_element(tconcat(base, "generation")).value = cast(int)generation;
    energy.find_or_create_element(tconcat(base, "id")).value = port.id[].makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "owner")).value = (port.owner ? port.owner.name[] : "").makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "label")).value = port.label.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "bus")).value = port.bus.id[].makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "port")).value = port_name.makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "port_role")).value = port_role_name(port.role).makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "flow")).value = flow_domain_name(port.flow).makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "meter_sign")).value = meter_sign_name(port.meter_sign).makeString(defaultAllocator());
    energy.find_or_create_element(tconcat(base, "root")).value = port.root;
    publish_meter(energy, base, port.meter_data);
}

private void publish_meter(Device energy, const(char)[] base, ref const MeterData data)
{
    publish_meter_value(energy, base, "power", data, MeterField.power);
    publish_meter_value(energy, base, "current", data, MeterField.current);
    publish_meter_value(energy, base, "voltage", data, MeterField.voltage);
    publish_meter_value(energy, base, "import", data, MeterField.total_import_active);
    publish_meter_value(energy, base, "export", data, MeterField.total_export_active);
    publish_meter_value(energy, base, "apparent", data, MeterField.apparent);
    publish_meter_value(energy, base, "reactive", data, MeterField.reactive);
    publish_meter_value(energy, base, "pf", data, MeterField.power_factor);
    publish_meter_value(energy, base, "frequency", data, MeterField.frequency);
}

private void publish_meter_value(Device energy, const(char)[] base, const(char)[] name, ref const MeterData data, MeterField field)
{
    float value = data.has(field) ? data.read_value(field) : float.nan;
    energy.find_or_create_element(tconcat(base, name)).value = value;
    energy.find_or_create_element(tconcat(base, name, "_source")).value = provenance_name(data.source(field)).makeString(defaultAllocator());
}
