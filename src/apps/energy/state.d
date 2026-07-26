module apps.energy.state;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time : Duration, getTime;

import apps.energy.appliance;
import apps.energy.attribution;
import apps.energy.battery_store : read_battery_soc;
import apps.energy.meter;
import apps.energy.production;
import apps.energy.topology;

import manager;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:

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
        return circuit_buses.length == graph.bus_list.length
            && circuit_terminals.length == graph.ports.length
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
        FormatId int_format = register_value_format!int();
        circuit_generation = energy.find_or_create_element("circuit.generation", int_format);
        circuit_buses_count = energy.find_or_create_element("circuit.buses", int_format);
        circuit_terminals_count = energy.find_or_create_element("circuit.terminals", int_format);
        circuit_branches_count = energy.find_or_create_element("circuit.branches", int_format);
        circuit_islands_count = energy.find_or_create_element("circuit.islands", int_format);
        circuit_grid_island = energy.find_or_create_element("circuit.grid_island", int_format);
        topology_generation = energy.find_or_create_element("topology.generation", int_format);
        productions_count = energy.find_or_create_element("circuit.productions", int_format);
        production_contributions_count = energy.find_or_create_element(
            "circuit.production_contributions", int_format);

        circuit_buses.clear();
        foreach (bus; graph.bus_list[])
        {
            CircuitBusPublishCache c;
            c.bind(energy, bus);
            circuit_buses ~= c;
        }

        circuit_terminals.clear();
        foreach (port; graph.ports[])
        {
            CircuitTerminalPublishCache c;
            c.bind(energy, port);
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
        circuit_generation.value = cast(int)graph.attribution.generation;
        circuit_buses_count.value = cast(int)graph.bus_list.length;
        circuit_terminals_count.value = cast(int)graph.ports.length;
        circuit_branches_count.value = cast(int)graph.links.length;
        circuit_islands_count.value = graph.attribution.island_count;
        circuit_grid_island.value = graph.attribution.grid_island;
        topology_generation.value = cast(int)graph.generation;
        productions_count.value = cast(int)graph.productions.length;
        production_contributions_count.value = cast(int)graph.production_contributions.length;

        foreach (i, bus; graph.bus_list[])
            circuit_buses[i].publish(bus, graph.attribution.buses[i], graph.attribution.generation);
        foreach (i, port; graph.ports[])
            circuit_terminals[i].publish(port, graph.attribution.terminals[i], graph.attribution.generation);
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

// Dynamic fields belong only in publish caches; publishing them here too creates
// competing writers.
private void publish_topology_layout(Device energy, ref TopologyGraph graph)
{
    publish_circuit(energy, graph);
    publish_productions(energy, graph.generation,
                        graph.productions, graph.production_contributions);

    energy.set_element("topology.schema_version", 1);
    energy.set_element("topology.generation", cast(int)graph.generation);

    foreach (bus; graph.bus_list[])
    {
        const(char)[] base = tconcat("topology.bus.", bus.id[], ".");
        energy.set_element(tconcat(base, "name"), bus.id[].makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "ports"), cast(int)bus.ports.length);
        energy.set_element(tconcat(base, "links"), cast(int)bus.links.length);
        energy.set_element(tconcat(base, "contains_grid"), bus.contains_grid);
        energy.set_element(tconcat(base, "explicit_root"), bus.explicit_root);
    }

    foreach (port; graph.ports[])
    {
        publish_port(energy, port);
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
        energy.set_element(tconcat(base, "owner"), port.owner.name[].makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "bus"), (port.bus ? port.bus.id[] : "").makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "port_role"), port_role_name(port.role).makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "port"), port_id.makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "flow"), flow_domain_name(port.flow).makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "meter_sign"), meter_sign_name(port.meter_sign).makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "root"), port.root);
    }

    foreach (link; graph.links[])
    {
        const(char)[] id = link.id[];
        if (id.length == 0)
            continue;
        const(char)[] base = tconcat("topology.link.", id, ".");
        energy.set_element(tconcat(base, "id"), id.makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "label"), link.label.makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "owner"), (link.owner ? link.owner.name[] : "").makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "parent"), link.a.id[].makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "child"), link.b.id[].makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "parent_port"), (link.port_a ? link.port_a.id[] : "").makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "child_port"), (link.port_b ? link.port_b.id[] : "").makeString(defaultAllocator()));
        const(char)[] kind = link.kind.length ? link.kind : link.owner ? "appliance" : "link";
        energy.set_element(tconcat(base, "kind"), kind.makeString(defaultAllocator()));
        energy.set_element(tconcat(base, "capacity"), link.capacity_amps);
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
        value[i] = energy.find_or_create_element(tconcat(base, name),
                                                  register_value_format!float());
        source[i] = energy.find_or_create_element(tconcat(base, name, "_source"),
                                                   register_value_format!String());
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

    void bind(Device energy, const(char)[] base, const(char)[] name)
    {
        bind(elem!int(energy, base, name));
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

    void bind(Device energy, const(char)[] base, const(char)[] name)
    {
        bind(elem!bool(energy, base, name));
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

    void bind(Device energy, const(char)[] base, const(char)[] name)
    {
        bind(elem!float(energy, base, name));
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

    void bind(Device energy, const(char)[] base, const(char)[] name)
    {
        bind(elem!String(energy, base, name));
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

    void bind(Device energy, apps.energy.topology.Bus* bus)
    {
        const(char)[] base = tconcat("circuit.bus.", bus.id[], ".");
        generation.bind(energy, base, "generation");
        coverage.bind(energy, base, "coverage");
        accounted_power.bind(energy, base, "accounted_power");
        residual_power.bind(energy, base, "residual_power");
        unaccounted_load_power.bind(energy, base, "unaccounted_load_power");
        unaccounted_source_power.bind(energy, base, "unaccounted_source_power");
        dark_power_bound.bind(energy, base, "dark_power_bound");
        source_power.bind(energy, base, "source_power");
        local_source_power.bind(energy, base, "local_source_power");
        grid_source_power.bind(energy, base, "grid_source_power");
        load_power.bind(energy, base, "load_power");
        local_fraction.bind(energy, base, "local_fraction");
        terminal_count.bind(energy, base, "terminal_count");
        metered_count.bind(energy, base, "metered_count");
        dark_count.bind(energy, base, "dark_count");
        anomaly.bind(energy, base, "anomaly");
        island.bind(energy, base, "island");
        depth.bind(energy, base, "depth");
        parent.bind(energy, base, "parent");
        meter.bind(energy, base);
    }

    void publish(apps.energy.topology.Bus* bus, ref const BusAttribution attr, uint gen)
    {
        generation.publish(cast(int)gen);
        coverage.publish(coverage_name(bus.coverage));
        accounted_power.publish(bus.accounted_power);
        residual_power.publish(bus.residual_power);
        unaccounted_load_power.publish(bus.unaccounted_load_power);
        unaccounted_source_power.publish(bus.unaccounted_source_power);
        dark_power_bound.publish(bus.dark_power_bound);
        source_power.publish(attr.source_power);
        local_source_power.publish(attr.local_source_power);
        grid_source_power.publish(attr.grid_source_power);
        load_power.publish(attr.load_power);
        local_fraction.publish(attr.local_fraction);
        terminal_count.publish(cast(int)bus.ports.length);
        metered_count.publish(cast(int)bus.metered_ports);
        dark_count.publish(cast(int)bus.dark_ports);
        anomaly.publish(bus.anomaly);
        island.publish(attr.island);
        depth.publish(attr.depth);
        parent.publish(attr.parent);
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

    void bind(Device energy, Port* port)
    {
        const(char)[] base = tconcat("circuit.terminal.", port.id[], ".");
        generation = elem!int(energy, base, "generation");
        consumed_power.bind(energy, base, "consumed_power");
        supplied_power.bind(energy, base, "supplied_power");
        local_power.bind(energy, base, "local_power");
        grid_power.bind(energy, base, "grid_power");
        local_fraction.bind(energy, base, "local_fraction");
        soc.bind(energy, base, "soc");
        meter.bind(energy, base);
    }

    void publish(Port* port, ref const TerminalAttribution attr, uint gen)
    {
        generation.value = cast(int)gen;
        consumed_power.publish(attr.consumed_power);
        supplied_power.publish(attr.supplied_power);
        local_power.publish(attr.local_power);
        grid_power.publish(attr.grid_power);
        local_fraction.publish(attr.local_fraction);
        soc.publish(read_battery_soc(battery_store_source(port)));
        meter.publish(port.meter_data);
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
        generation.bind(energy, base, "generation");
        coverage.bind(energy, base, "coverage");
        accounted_power.bind(energy, base, "accounted_power");
        residual_power.bind(energy, base, "residual_power");
        unaccounted_load_power.bind(energy, base, "unaccounted_load_power");
        unaccounted_source_power.bind(energy, base, "unaccounted_source_power");
        dark_power_bound.bind(energy, base, "dark_power_bound");
        anomaly.bind(energy, base, "anomaly");
        metered_ports.bind(energy, base, "metered_ports");
        dark_ports.bind(energy, base, "dark_ports");
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
        generation = elem!int(energy, base, "generation");

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
        generation = elem!int(energy, base, "generation");

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
        generation = elem!int(energy, base, "generation");
        closed = elem!bool(energy, base, "closed");
        meter.bind(energy, base);
    }

    void publish(Link* link, uint gen)
    {
        if (generation is null)
            return;
        generation.value = cast(int)gen;
        closed.value = link.closed;
        if (Port* measuring = link_measuring_port(link))
            meter.publish(measuring.meter_data);
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
        generation = elem!int(energy, base, "generation");
        aggregate_power = elem!float(energy, base, "aggregate_power");
        member_power = elem!float(energy, base, "member_power");
        aggregate_count = elem!int(energy, base, "aggregate_count");
        member_count = elem!int(energy, base, "member_count");
        calculated = elem!bool(energy, base, "calculated");
        mismatch = elem!bool(energy, base, "mismatch");
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
        generation = elem!int(energy, base, "generation");

        meter.bind(energy, base);
    }

    void publish(ref const ProductionContribution contribution, uint gen)
    {
        generation.value = cast(int)gen;
        meter.publish(contribution.meter);
    }
}

private Element* elem(T)(Device energy, const(char)[] base, const(char)[] name)
{
    return energy.find_or_create_element(tconcat(base, name), register_value_format!T());
}


void publish_circuit(Device energy, ref TopologyGraph graph)
{
    energy.set_element("circuit.schema_version", 1);
    energy.set_element("circuit.generation", cast(int)graph.attribution.generation);
    energy.set_element("circuit.buses", cast(int)graph.bus_list.length);
    energy.set_element("circuit.terminals", cast(int)graph.ports.length);
    energy.set_element("circuit.branches", cast(int)graph.links.length);
    energy.set_element("circuit.islands", graph.attribution.island_count);
    energy.set_element("circuit.grid_island", graph.attribution.grid_island);

    foreach (i, bus; graph.bus_list[])
        publish_circuit_bus(energy, graph.attribution.generation, bus, graph.attribution.buses[i]);
    foreach (i, port; graph.ports[])
        publish_circuit_terminal(energy, graph.attribution.generation, port, graph.attribution.terminals[i]);
    foreach (link; graph.links[])
        publish_circuit_branch(energy, graph.attribution.generation, graph, link);
}

private const(char)[] circuit_domain_name(FlowDomain f) pure
{
    final switch (f)
    {
        case FlowDomain.unknown:       return "unknown";
        case FlowDomain.consume:       return "sink";
        case FlowDomain.supply:        return "source";
        case FlowDomain.bidirectional: return "bidirectional";
    }
}

void publish_productions(Device energy, uint generation, ref Array!Production productions,
                         ref Array!ProductionContribution contributions)
{
    energy.set_element("circuit.productions", cast(int)productions.length);
    energy.set_element("circuit.production_contributions", cast(int)contributions.length);

    foreach (ref production; productions[])
        publish_production(energy, generation, production);
    foreach (i, ref contribution; contributions[])
        publish_production_contribution(energy, generation, cast(uint)i, contribution);
}

private void publish_circuit_bus(Device energy, uint generation, apps.energy.topology.Bus* bus,
                                 ref const BusAttribution attr)
{
    const(char)[] base = tconcat("circuit.bus.", bus.id[], ".");
    energy.set_element(tconcat(base, "generation"), cast(int)generation);
    energy.set_element(tconcat(base, "id"), bus.id[].makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "coverage"), coverage_name(bus.coverage).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "accounted_power"), bus.accounted_power);
    energy.set_element(tconcat(base, "residual_power"), bus.residual_power);
    energy.set_element(tconcat(base, "unaccounted_load_power"), bus.unaccounted_load_power);
    energy.set_element(tconcat(base, "unaccounted_source_power"), bus.unaccounted_source_power);
    energy.set_element(tconcat(base, "dark_power_bound"), bus.dark_power_bound);
    energy.set_element(tconcat(base, "source_power"), attr.source_power);
    energy.set_element(tconcat(base, "local_source_power"), attr.local_source_power);
    energy.set_element(tconcat(base, "grid_source_power"), attr.grid_source_power);
    energy.set_element(tconcat(base, "load_power"), attr.load_power);
    energy.set_element(tconcat(base, "local_fraction"), attr.local_fraction);
    energy.set_element(tconcat(base, "terminal_count"), cast(int)bus.ports.length);
    energy.set_element(tconcat(base, "metered_count"), cast(int)bus.metered_ports);
    energy.set_element(tconcat(base, "dark_count"), cast(int)bus.dark_ports);
    energy.set_element(tconcat(base, "anomaly"), bus.anomaly);
    energy.set_element(tconcat(base, "contains_grid"), bus.contains_grid);
    energy.set_element(tconcat(base, "explicit_root"), bus.explicit_root);
    energy.set_element(tconcat(base, "island"), attr.island);
    energy.set_element(tconcat(base, "depth"), attr.depth);
    energy.set_element(tconcat(base, "parent"), attr.parent);
    publish_meter(energy, base, bus.balance);
}

private void publish_circuit_terminal(Device energy, uint generation, Port* port,
                                      ref const TerminalAttribution attr)
{
    const(char)[] base = tconcat("circuit.terminal.", port.id[], ".");
    energy.set_element(tconcat(base, "generation"), cast(int)generation);
    energy.set_element(tconcat(base, "id"), port.id[].makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "owner"), (port.owner ? port.owner.name[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "owner_kind"), (port.owner ? port.owner.kind[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "owner_device"), (port.owner ? port.owner.device[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "port"),
        (port.path.length ? port.path[] : port_role_name(port.role)).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "label"), port.label.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "circuit"), (port.bus ? port.bus.id[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "role"), port_role_name(port.role).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "domain"), circuit_domain_name(port.flow).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "consumed_power"), attr.consumed_power);
    energy.set_element(tconcat(base, "supplied_power"), attr.supplied_power);
    energy.set_element(tconcat(base, "local_power"), attr.local_power);
    energy.set_element(tconcat(base, "grid_power"), attr.grid_power);
    energy.set_element(tconcat(base, "local_fraction"), attr.local_fraction);
    energy.set_element(tconcat(base, "soc"), read_battery_soc(battery_store_source(port)));
    energy.set_element(tconcat(base, "root"), port.root);
    energy.set_element(tconcat(base, "implicit"), port.implicit);
    publish_meter(energy, base, port.meter_data);
}

private void publish_circuit_branch(Device energy, uint generation, ref TopologyGraph graph, Link* link)
{
    const(char)[] base = tconcat("circuit.branch.", link.id[], ".");
    energy.set_element(tconcat(base, "generation"), cast(int)generation);
    energy.set_element(tconcat(base, "id"), link.id[].makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "owner"), (link.owner ? link.owner.name[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "label"), link.label.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "kind"),
        (link.kind.length ? link.kind : link.owner ? "appliance" : "link").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "parent"), (link.a ? link.a.id[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "child"), (link.b ? link.b.id[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "capacity"), link.capacity_amps);
    energy.set_element(tconcat(base, "conducting"), link.closed);
    energy.set_element(tconcat(base, "parent_terminal"), graph.attribution.terminal_index(graph, link.port_a));
    energy.set_element(tconcat(base, "child_terminal"), graph.attribution.terminal_index(graph, link.port_b));
}

private void publish_production(Device energy, uint generation, ref const Production production)
{
    const(char)[] base = tconcat("circuit.production.", production.owner, ".", production.group, ".");
    energy.set_element(tconcat(base, "generation"), cast(int)generation);
    energy.set_element(tconcat(base, "owner"), production.owner.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "group"), production.group.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "aggregate_power"), production.aggregate_power);
    energy.set_element(tconcat(base, "member_power"), production.member_power);
    energy.set_element(tconcat(base, "aggregate_count"), cast(int)production.aggregate_count);
    energy.set_element(tconcat(base, "member_count"), cast(int)production.member_count);
    energy.set_element(tconcat(base, "calculated"), production.calculated);
    energy.set_element(tconcat(base, "mismatch"), production.mismatch);
    publish_meter(energy, base, production.data);
}

private void publish_production_contribution(Device energy, uint generation, uint index,
                                             ref const ProductionContribution contribution)
{
    const(char)[] base = tconcat("circuit.production_contribution.", index, ".");
    energy.set_element(tconcat(base, "generation"), cast(int)generation);
    energy.set_element(tconcat(base, "owner"), contribution.owner.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "group"), contribution.group.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "port"), contribution.port.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "circuit"), contribution.circuit.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "kind"),
        production_contribution_kind_name(contribution.kind).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "component"),
        (contribution.component ? contribution.component.id[] : "").makeString(defaultAllocator()));
    publish_meter(energy, base, contribution.meter);
}

private void publish_control_path(Device energy, ref TopologyGraph graph, Appliance owner)
{
    ControlPath path;
    graph.build_control_path(owner, path);

    const(char)[] base = tconcat("control_path.", owner.name[], ".");
    energy.set_element(tconcat(base, "generation"), cast(int)graph.generation);
    energy.set_element(tconcat(base, "target"), owner.name[].makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "target_bus"),
        (path.target_bus ? path.target_bus.id[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "source_bus"),
        (path.source_bus ? path.source_bus.id[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "complete"), path.complete);
    energy.set_element(tconcat(base, "links"), cast(int)path.links.length);
    Array!char route;
    append_control_path_route(route, path);
    energy.set_element(tconcat(base, "route"), route[].makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "headroom_amps"), path.headroom_amps);
    energy.set_element(tconcat(base, "headroom_watts"), path.headroom_watts);
    energy.set_element(tconcat(base, "voltage"), path.voltage);
    energy.set_element(tconcat(base, "limiting_link"),
        (path.limiting_link ? path.limiting_link.id[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "limiting_kind"),
        (path.limiting_link ? path.limiting_link.kind : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "limiting_capacity_amps"), path.limiting_capacity_amps);
    energy.set_element(tconcat(base, "limiting_current_amps"),
        path.limiting_current_amps);
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

    energy.set_element(tconcat(base, "generation"), cast(int)graph.generation);
    energy.set_element(tconcat(base, "id"), owner.name[].makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "kind"), owner.kind.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "root"), explicit_root || owner.root);
    energy.set_element(tconcat(base, "device"), owner.device.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "meter"), owner.meter.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "state"), owner.state.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "vin"), owner.vin.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "ports"), cast(int)port_count);
}

private void publish_port(Device energy, Port* port)
{
    const(char)[] base = tconcat("topology.port.", port.id[], ".");
    const(char)[] port_name = port.path.length ? port.path[] : port_role_name(port.role);
    energy.set_element(tconcat(base, "id"), port.id[].makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "owner"), (port.owner ? port.owner.name[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "label"), port.label.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "bus"), (port.bus ? port.bus.id[] : "").makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "port"), port_name.makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "port_role"), port_role_name(port.role).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "flow"), flow_domain_name(port.flow).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "meter_sign"), meter_sign_name(port.meter_sign).makeString(defaultAllocator()));
    energy.set_element(tconcat(base, "root"), port.root);
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
    energy.set_element(tconcat(base, name), value);
    energy.set_element(tconcat(base, name, "_source"), provenance_name(data.source(field)).makeString(defaultAllocator()));
}
