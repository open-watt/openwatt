module apps.energy.state;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time : Duration, getTime, getSysTime, SysTime;

import apps.energy.appliance;
import apps.energy.attribution;
import apps.energy.battery_store : read_battery_soc;
import apps.energy.meter;
import apps.energy.production;
import apps.energy.topology;

import manager;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:

Device create_energy_device()
{
    if ("energy" in g_app.devices)
        return null;

    Device d = alloc!Device(StringLit!"energy");
    d.hidden = true;

    d.add_component(alloc!Component(StringLit!"topology"));
    d.add_component(alloc!Component(StringLit!"circuit"));
    d.add_component(alloc!Component(StringLit!"islands"));
    d.add_component(alloc!Component(StringLit!"policy"));
    d.add_component(alloc!Component(StringLit!"allocation"));
    d.add_component(alloc!Component(StringLit!"control_path"));
    d.add_component(alloc!Component(StringLit!"config"));

    g_app.devices.insert(d);
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
    Element* circuit_islands_count;
    Element* circuit_grid_island;
    Element* topology_generation;

    Array!CircuitBusPublishCache circuit_buses;
    Array!TopologyBusPublishCache topology_buses;
    Array!TopologyPortPublishCache topology_ports;
    Array!TopologyLinkPublishCache topology_links;
    Array!GroupLossPublishCache group_losses;
    Array!BoundaryPublishEntry boundaries;

    void publish(Device energy, ref TopologyGraph graph, ref Islands islands, bool rebuild_layout)
    {
        auto t = getTime();
        if (rebuild_layout || !bound || !shape_matches(graph))
        {
            bind(energy, graph);
            log_slow_topology_publish("bind", getTime() - t);
            t = getTime();
        }
        publish_values(graph);
        SysTime now = getSysTime();
        foreach (i, p; graph.boundaries[])
            boundaries[i].publish(p, graph, islands, now);
        log_slow_topology_publish("values", getTime() - t);
    }

    bool shape_matches(ref TopologyGraph graph) const pure
    {
        return circuit_buses.length == graph.bus_list.length
            && topology_buses.length == graph.bus_list.length
            && topology_ports.length == graph.ports.length
            && topology_links.length == graph.links.length
            && group_losses.length == graph.groups.length
            && boundaries.length == graph.boundaries.length;
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
        circuit_islands_count = energy.find_or_create_element("circuit.islands", int_format);
        circuit_grid_island = energy.find_or_create_element("circuit.grid_island", int_format);
        topology_generation = energy.find_or_create_element("topology.generation", int_format);

        circuit_buses.clear();
        foreach (bus; graph.bus_list[])
        {
            CircuitBusPublishCache c;
            c.bind(energy, bus);
            circuit_buses ~= c;
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

        topology_links.clear();
        foreach (link; graph.links[])
        {
            TopologyLinkPublishCache c;
            c.bind(energy, link);
            topology_links ~= c;
        }

        group_losses.resize(graph.groups.length);
        foreach (i, g; graph.groups[])
            group_losses[i].bind(energy, g);

        boundaries.resize(graph.boundaries.length);
        foreach (i, p; graph.boundaries[])
        {
            foreach (q; graph.boundaries[0 .. i])
                if (boundary_key(q)[] == boundary_key(p)[])
                    writeWarning("energy: boundary key '", boundary_key(p), "' is not unique; an appliance and a link share the name and their publishes will collide");
            boundaries[i].bind(energy, p);
        }
        publish_appliance_index_list(energy, graph);
        log_slow_topology_publish("cache_bind", getTime() - t);

        bound = true;
    }

    void publish_appliance_index_list(Device energy, ref TopologyGraph graph)
    {
        foreach (a; Collection!Appliance().values)
        {
            const(char)[] base = tconcat("appliance.", a.name[], ".");
            energy.set_element(tconcat(base, "kind"), (a.kind.length ? a.kind : "").make_string());
            Port* anchor = graph.anchor_port_for_appliance(a);
            energy.set_element(tconcat(base, "circuit"),
                               (anchor && anchor.bus ? anchor.bus.id[] : "").make_string());
            const(char)[] key;
            foreach (p; graph.boundaries[])
                if (p.owner is a)
                {
                    key = boundary_key(p);
                    break;
                }
            energy.set_element(tconcat(base, "boundary"), key.make_string());
            energy.set_element(tconcat(base, "device"), a.device.make_string());
            energy.set_element(tconcat(base, "vin"), a.vin.make_string());
            energy.set_element(tconcat(base, "connected"), anchor !is null);
        }
    }

    void publish_values(ref TopologyGraph graph)
    {
        circuit_generation.value = cast(int)graph.attribution.generation;
        circuit_buses_count.value = cast(int)graph.bus_list.length;
        circuit_islands_count.value = graph.attribution.island_count;
        circuit_grid_island.value = graph.attribution.grid_island;
        topology_generation.value = cast(int)graph.generation;

        foreach (i, bus; graph.bus_list[])
            circuit_buses[i].publish(bus, graph.attribution.buses[i], graph.attribution.generation);
        foreach (i, bus; graph.bus_list[])
            topology_buses[i].publish(bus, graph.generation);
        foreach (i, port; graph.ports[])
            topology_ports[i].publish(port, graph.generation);
        foreach (i, link; graph.links[])
            topology_links[i].publish(link, graph.generation);
        foreach (i, g; graph.groups[])
            group_losses[i].publish(g);
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

    energy.set_element("topology.schema_version", 2);
    energy.set_element("topology.generation", cast(int)graph.generation);

    foreach (bus; graph.bus_list[])
    {
        const(char)[] base = tconcat("topology.bus.", bus.id[], ".");
        energy.set_element(tconcat(base, "name"), bus.id);
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
        publish_control_path(energy, graph, port.owner);
    }

    foreach (link; graph.links[])
    {
        const(char)[] id = link.id[];
        if (id.length == 0)
            continue;
        const(char)[] base = tconcat("topology.link.", id, ".");
        energy.set_element(tconcat(base, "id"), id.make_string());
        energy.set_element(tconcat(base, "label"), link.label.make_string());
        energy.set_element(tconcat(base, "owner"), (link.owner ? link.owner.name[] : "").make_string());
        energy.set_element(tconcat(base, "parent"), link.a.id);
        energy.set_element(tconcat(base, "child"), (link.b ? link.b.id[] : "").make_string());
        energy.set_element(tconcat(base, "parent_port"), (link.port_a ? link.port_a.id[] : "").make_string());
        energy.set_element(tconcat(base, "child_port"), (link.port_b ? link.port_b.id[] : "").make_string());
        const(char)[] kind = link.kind.length ? link.kind : link.owner ? "appliance" : "link";
        energy.set_element(tconcat(base, "kind"), kind.make_string());
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
                source[i].value = provenance_name(prov).make_string();
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
            String s = value.make_string();
            element.value = s;
            last = s;
            seen = true;
        }
    }
}

// Appliance loss is self-consumption/conversion loss; on switchgear the same
// sum is a two-sides-disagree wiring/calibration alarm.
private struct GroupLossPublishCache
{
nothrow @nogc:
    FloatPublishCell loss;
    BoolPublishCell mismatch;

    void bind(Device energy, PortGroup* g)
    {
        loss = FloatPublishCell();
        mismatch = BoolPublishCell();
        if (g.kind == PortGroupKind.appliance)
        {
            if (g.owner !is null && g.ports.length >= 2)
                loss.bind(energy, tconcat("appliance.", g.owner.name[], "."), "loss_power");
        }
        else if (g.link !is null && g.link.id.length != 0)
        {
            const(char)[] base = tconcat("topology.link.", g.link.id[], ".");
            loss.bind(energy, base, "loss_power");
            mismatch.bind(energy, base, "mismatch");
        }
    }

    void publish(PortGroup* g)
    {
        if (loss.element)
            loss.publish(g.loss_power);
        if (mismatch.element)
            mismatch.publish(g.mismatch);
    }
}

private struct BoundaryPublishEntry
{
nothrow @nogc:
    Element* circuit_e;
    Element* island_e;
    Element* provenance_e;
    FloatPublishCell power_in;
    FloatPublishCell power_out;
    FloatPublishCell energy_in;
    FloatPublishCell energy_out;
    FloatPublishCell soc;
    BoolPublishCell mismatch;
    String last_circuit;
    String last_island;
    Provenance last_prov;
    bool prov_seen;

    void bind(Device energy, Port* p)
    {
        const(char)[] base = tconcat("boundary.", boundary_key(p), ".");
        energy.set_element(tconcat(base, "kind"),
                           boundary_kind_name(boundary_kind(p)).make_string());
        energy.set_element(tconcat(base, "owner"),
                           (p.owner ? p.owner.name[] : "").make_string());
        energy.set_element(tconcat(base, "origin"),
                           (p.group ? port_group_kind_name(p.group.kind) : "").make_string());
        energy.set_element(tconcat(base, "port"), p.id);
        FormatId string_format = register_value_format!String();
        circuit_e = energy.find_or_create_element(tconcat(base, "circuit"), string_format);
        island_e = energy.find_or_create_element(tconcat(base, "island"), string_format);
        provenance_e = energy.find_or_create_element(tconcat(base, "provenance"), string_format);
        power_in.bind(energy, base, "power_in");
        power_out.bind(energy, base, "power_out");
        energy_in.bind(energy, base, "energy_in");
        energy_out.bind(energy, base, "energy_out");
        soc = FloatPublishCell();
        if (boundary_kind(p) == BoundaryKind.battery)
            soc.bind(energy, base, "soc");
        mismatch = BoolPublishCell();
        if (boundary_kind(p) == BoundaryKind.solar && p.owner !is null)
            mismatch.bind(energy, base, "mismatch");
        last_circuit = String();
        last_island = String();
        prov_seen = false;
    }

    void publish(Port* p, ref TopologyGraph graph, ref Islands islands, SysTime ts)
    {
        float pw_in = float.nan, pw_out = float.nan;
        bool have = p.meter_data.has(MeterField.power);
        if (have)
        {
            float power = p.meter_data.active[0].value;
            if (external_boundary(p))
            {
                pw_in = power > 0 ? power : 0;
                pw_out = power < 0 ? -power : 0;
            }
            else
            {
                pw_in = power < 0 ? -power : 0;
                pw_out = power > 0 ? power : 0;
            }
        }
        power_in.publish(pw_in);
        power_out.publish(pw_out);

        BoundaryEnergy e = boundary_energy(p);
        if (e.into_total == e.into_total)
            energy_in.publish(cast(float)e.into_total);
        if (e.out_total == e.out_total)
            energy_out.publish(cast(float)e.out_total);

        Bus* b = boundary_bus(p);
        publish_string(circuit_e, last_circuit, b ? b.id[] : "", ts);
        publish_string(island_e, last_island, island_id_of(b, islands), ts);

        // The reconciled store value, not this port's own view of it.
        if (soc.element)
        {
            float value = float.nan;
            if (b)
                foreach (ref store; graph.battery_stores[])
                    if (store.circuit == b.id[])
                    {
                        value = store.reading.soc;
                        break;
                    }
            soc.publish(value);
        }

        Provenance prov = have ? p.meter_data.source(MeterField.power) : Provenance.missing;
        if (!prov_seen || prov != last_prov)
        {
            provenance_e.value(provenance_name(prov).make_string(), ts);
            last_prov = prov;
            prov_seen = true;
        }

        // Aggregate-vs-member disagreement from the production reconciliation.
        if (mismatch.element)
        {
            bool flag = false;
            foreach (ref prod; graph.productions[])
                if (prod.owner == p.owner.name[] && prod.group == production_group_of(p))
                {
                    flag = prod.mismatch;
                    break;
                }
            mismatch.publish(flag);
        }
    }

    const(char)[] island_id_of(Bus* b, ref Islands islands)
    {
        if (b is null)
            return "";
        foreach (island; islands[])
            foreach (m; island.members[])
                if (m is b)
                    return island.id[];
        return "";
    }

    void publish_string(Element* e, ref String last, const(char)[] value, SysTime ts)
    {
        if (last[] == value)
            return;
        last = value.make_string();
        e.value(last, ts);
    }

    const(char)[] production_group_of(Port* p)
    {
        if (p.path.length == 0)
            return "pv";
        size_t dot = p.path[].findLast('.');
        return dot < p.path.length ? p.path[0 .. dot] : p.path[];
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
    FloatPublishCell soc;
    Component soc_source;

    MeterPublishCache meter;

    void bind(Device energy, Port* port)
    {
        const(char)[] base = tconcat("topology.port.", port.id[], ".");
        generation = elem!int(energy, base, "generation");

        // The device's own gauge at this port; the reconciled store value
        // lives on the battery boundary entry.
        soc = FloatPublishCell();
        soc_source = port_soc_source(port);
        if (soc_source !is null)
            soc.bind(energy, base, "soc");

        meter.bind(energy, base);
    }

    void publish(Port* port, uint gen)
    {
        generation.value = cast(int)gen;
        if (soc.element)
            soc.publish(read_battery_soc(soc_source));
        meter.publish(port.meter_data);
    }
}

// A port carries soc only when the component behind it can answer: mirrors
// read_battery_soc's resolution, gating on element presence rather than the
// current value so an offline device keeps its field.
private Component port_soc_source(Port* port)
{
    Component c = battery_store_source(port);
    if (c is null)
        return null;
    if (c.find_element("soc"))
        return c;
    if (c.template_[] == "Battery")
        return null;
    return c.find_first_component_by_template_recursive("Battery") ? c : null;
}

private struct TopologyLinkPublishCache
{
nothrow @nogc:
    Element* generation;
    Element* closed;
    FloatPublishCell current;
    FloatPublishCell utilisation;
    MeterPublishCache meter;

    void bind(Device energy, Link* link)
    {
        if (link.id.length == 0)
            return;
        const(char)[] base = tconcat("topology.link.", link.id[], ".");
        generation = elem!int(energy, base, "generation");
        closed = elem!bool(energy, base, "closed");
        current.bind(energy, base, "current");
        utilisation.bind(energy, base, "utilisation");
        meter.bind(energy, base);
    }

    void publish(Link* link, uint gen)
    {
        if (generation is null)
            return;
        generation.value = cast(int)gen;
        closed.value = link.closed;
        float amps = link_current_amps(link);
        current.publish(amps);
        utilisation.publish(link.capacity_amps > 0 ? amps / link.capacity_amps : float.nan);
        if (Port* measuring = link_measuring_port(link))
            meter.publish(measuring.meter_data);
    }
}

private Element* elem(T)(Device energy, const(char)[] base, const(char)[] name)
{
    return energy.find_or_create_element(tconcat(base, name), register_value_format!T());
}


void publish_circuit(Device energy, ref TopologyGraph graph)
{
    energy.set_element("circuit.schema_version", 2);
    energy.set_element("circuit.generation", cast(int)graph.attribution.generation);
    energy.set_element("circuit.buses", cast(int)graph.bus_list.length);
    energy.set_element("circuit.islands", graph.attribution.island_count);
    energy.set_element("circuit.grid_island", graph.attribution.grid_island);

    foreach (i, bus; graph.bus_list[])
        publish_circuit_bus(energy, graph.attribution.generation, bus, graph.attribution.buses[i]);
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

private void publish_circuit_bus(Device energy, uint generation, apps.energy.topology.Bus* bus,
                                 ref const BusAttribution attr)
{
    const(char)[] base = tconcat("circuit.bus.", bus.id[], ".");
    energy.set_element(tconcat(base, "generation"), cast(int)generation);
    energy.set_element(tconcat(base, "id"), bus.id);
    energy.set_element(tconcat(base, "coverage"), coverage_name(bus.coverage).make_string());
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

private void publish_control_path(Device energy, ref TopologyGraph graph, Appliance owner)
{
    ControlPath path;
    graph.build_control_path(owner, path);

    const(char)[] base = tconcat("control_path.", owner.name[], ".");
    energy.set_element(tconcat(base, "generation"), cast(int)graph.generation);
    energy.set_element(tconcat(base, "target"), owner.name);
    energy.set_element(tconcat(base, "target_bus"),
        (path.target_bus ? path.target_bus.id[] : "").make_string());
    energy.set_element(tconcat(base, "source_bus"),
        (path.source_bus ? path.source_bus.id[] : "").make_string());
    energy.set_element(tconcat(base, "complete"), path.complete);
    energy.set_element(tconcat(base, "links"), cast(int)path.links.length);
    Array!char route;
    append_control_path_route(route, path);
    energy.set_element(tconcat(base, "route"), route[].make_string());
    energy.set_element(tconcat(base, "headroom_amps"), path.headroom_amps);
    energy.set_element(tconcat(base, "headroom_watts"), path.headroom_watts);
    energy.set_element(tconcat(base, "voltage"), path.voltage);
    energy.set_element(tconcat(base, "limiting_link"),
        (path.limiting_link ? path.limiting_link.id[] : "").make_string());
    energy.set_element(tconcat(base, "limiting_kind"),
        (path.limiting_link ? path.limiting_link.kind : "").make_string());
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

private void publish_port(Device energy, Port* port)
{
    const(char)[] base = tconcat("topology.port.", port.id[], ".");
    const(char)[] port_name = port.path.length ? port.path[] : port_role_name(port.role);
    energy.set_element(tconcat(base, "id"), port.id);
    energy.set_element(tconcat(base, "owner"), (port.owner ? port.owner.name[] : "").make_string());
    energy.set_element(tconcat(base, "label"), port.label.make_string());
    energy.set_element(tconcat(base, "bus"), (port.bus ? port.bus.id[] : "").make_string());
    energy.set_element(tconcat(base, "port"), port_name.make_string());
    energy.set_element(tconcat(base, "port_role"), port_role_name(port.role).make_string());
    energy.set_element(tconcat(base, "flow"), flow_domain_name(port.flow).make_string());
    energy.set_element(tconcat(base, "meter_sign"), meter_sign_name(port.meter_sign).make_string());
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
    energy.set_element(tconcat(base, name, "_source"), provenance_name(data.source(field)).make_string());
}
