module apps.energy.topology;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time : SysTime;
import urt.variant : Variant;

import apps.energy.appliance;
import apps.energy.battery_store;
import apps.energy.kernel;
import apps.energy.link;
import apps.energy.meter;
import apps.energy.production;
import apps.energy.vehicle : vehicle_for;
public import apps.energy.model;

import manager;
import manager.collection;
import manager.component;
import manager.element;

nothrow @nogc:

alias log = Log!"energy.topology";


struct Bus
{
nothrow @nogc:
    this(String id)
    {
        this.id = id.move;
    }
    this(this) @disable;

    String id;
    Array!(Port*) ports;
    Array!(Link*) links;
    MeterData balance;
    Coverage coverage;
    float accounted_power = float.nan;
    float residual_power = float.nan;
    float unaccounted_load_power = float.nan;
    float unaccounted_source_power = float.nan;
    float dark_power_bound = float.nan;
    uint metered_ports;
    uint dark_ports;
    bool anomaly;
    bool contains_grid;
    bool explicit_root;
}

struct Port
{
nothrow @nogc:
    Appliance owner;
    String id;
    String path;
    const(char)[] label;
    Bus* bus;
    PortRole role;
    FlowDomain flow;
    Component component;
    Component meter;
    ubyte meter_phase;
    MeterSign meter_sign;
    MeterData meter_data;
    bool root;
    bool implicit;
}

// Terminal vs boundary: a class terminal IS the battery/pv itself (a battery or
// pv appliance's own connection, or a synthesized implicit terminal standing in
// for unmodeled equipment); a boundary port (inverter port, declared breaker
// child) merely faces the bus that equipment lives on. Terminals source the
// island accounts; boundary meters are bus-balance and cross-check only.
// See the metering convention comment in accounts.d.
bool class_terminal(Port* p) pure
{
    if (p.implicit)
        return true;
    if (p.owner is null)
        return false;
    if (p.role == PortRole.battery)
        return p.owner.kind == "battery";
    if (p.role == PortRole.pv)
        return p.owner.kind == "pv" || p.owner.kind == "solar";
    return false;
}

struct Link
{
nothrow @nogc:
    Appliance owner;
    String id;
    const(char)[] label;
    const(char)[] kind;
    Bus* a;
    Bus* b;
    Port* port_a;
    Port* port_b;
    uint capacity_amps;
    bool closed;
}

struct DevicePort
{
nothrow @nogc:
    Component component;
    String path;
    const(char)[] circuit;
    PortRole role;
    FlowDomain flow;
    Component meter;
    ubyte phase;
    MeterSign sign;
    uint capacity_amps;
    bool closed = true;
}

struct ControlPath
{
nothrow @nogc:
    Appliance target;
    Bus* target_bus;
    Bus* source_bus;
    Array!(Link*) links;
    Link* limiting_link;
    float headroom_amps = float.nan;
    float headroom_watts = float.nan;
    float voltage = float.nan;
    float limiting_current_amps = float.nan;
    uint limiting_capacity_amps;
    bool complete;
}

enum IslandMode : ubyte
{
    unknown,
    on_grid,
    off_grid,
}

const(char)[] island_mode_name(IslandMode m) pure
{
    final switch (m)
    {
        case IslandMode.unknown:  return "unknown";
        case IslandMode.on_grid:  return "on_grid";
        case IslandMode.off_grid: return "off_grid";
    }
}

struct Island
{
nothrow @nogc:
    this(this) @disable;

    String id;
    Bus* root;
    Array!(Bus*) members;
    IslandMode mode;
}

alias Islands = Array!(Island*);

void update_islands(ref Islands islands, ref TopologyGraph graph)
{
    Array!(Bus*) visited;
    Array!(Bus*) roots;

    foreach (bus; graph.bus_list[])
    {
        if (visited[].findFirst(bus) < visited.length)
            continue;
        roots ~= bus;
        collect_component(bus, visited);
    }

    foreach (root; roots[])
    {
        Island* island = find_or_create_island(islands, root);
        island.members.clear();
        collect_component(root, island.members);
        island.mode = contains_grid(island) ? IslandMode.on_grid : IslandMode.off_grid;
        if (island.mode == IslandMode.on_grid)
            island.id = StringLit!"grid";
    }

    for (size_t i = islands.length; i-- > 0; )
    {
        Island* island = islands[i];
        bool kept;
        foreach (root; roots[])
        {
            const(char)[] id = component_contains_grid(root) ? "grid" : root.id[];
            if (island.id[] == id)
            {
                kept = true;
                break;
            }
        }
        if (!kept)
        {
            destroy_island(island);
            islands.remove(i);
        }
    }
}

private void collect_component(Bus* root, ref Array!(Bus*) into)
{
    if (root is null)
        return;
    Array!(Bus*) queue;
    queue ~= root;
    into ~= root;
    for (size_t i = 0; i < queue.length; ++i)
    {
        Bus* b = queue[i];
        foreach (l; b.links[])
        {
            if (!l.closed)
                continue;
            Bus* other = l.a is b ? l.b : l.a;
            if (into[].findFirst(other) < into.length)
                continue;
            into ~= other;
            queue ~= other;
        }
    }
}

private bool contains_grid(Island* island) pure
{
    foreach (b; island.members[])
        if (b.contains_grid)
            return true;
    return false;
}

private Island* find_or_create_island(ref Islands islands, Bus* root)
{
    const(char)[] id = component_contains_grid(root) ? "grid" : root.id[];
    foreach (island; islands[])
    {
        if (island.id[] == id)
        {
            island.root = root;
            return island;
        }
    }
    Island* island = defaultAllocator.allocT!Island();
    island.id = id.makeString(defaultAllocator());
    island.root = root;
    islands ~= island;
    return island;
}

private bool component_contains_grid(Bus* root)
{
    Array!(Bus*) members;
    collect_component(root, members);
    foreach (bus; members[])
        if (bus.contains_grid)
            return true;
    return false;
}

private void destroy_island(Island* island)
{
    defaultAllocator.freeT(island);
}

struct TopologyGraph
{
nothrow @nogc:
    Map!(const(char)[], Bus*) buses;
    Array!(Bus*) bus_list;
    Array!(Port*) ports;
    Array!(Link*) links;
    Array!(Element*) shape_elements;
    bool shape_dirty;
    CircuitKernel kernel;
    Array!BatteryStoreContribution battery_store_contributions;
    Array!BatteryStore battery_stores;
    Array!ProductionContribution production_contributions;
    Array!Production productions;
    Array!String production_strings;
    uint generation;
    uint sample_generation;

    void clear()
    {
        kernel.clear();
        battery_store_contributions.clear();
        battery_stores.clear();
        production_contributions.clear();
        productions.clear();
        production_strings.clear();
        foreach (p; ports[])
            defaultAllocator.freeT(p);
        foreach (l; links[])
            defaultAllocator.freeT(l);
        foreach (b; bus_list[])
            defaultAllocator.freeT(b);
        ports.clear();
        links.clear();
        bus_list.clear();
        buses.clear();
        release_shape_watches();
    }

    void release_shape_watches()
    {
        foreach (e; shape_elements[])
            e.unsubscribe(&on_shape_change);
        shape_elements.clear();
    }

    Bus* find_bus(const(char)[] name)
    {
        Bus** b = name in buses;
        return b ? *b : null;
    }

    Bus* ensure_bus(const(char)[] name)
    {
        if (name.length == 0)
            name = "unknown";
        if (Bus* b = find_bus(name))
            return b;
        Bus* b = defaultAllocator.allocT!Bus(name.makeString(defaultAllocator()));
        b.contains_grid = b.id[] == "grid";
        buses.insert(b.id[], b);
        bus_list ~= b;
        return b;
    }

    Port* add_port(Appliance owner, Bus* bus, PortRole role, FlowDomain flow, Component meter,
                   ubyte phase, MeterSign sign = MeterSign.normal, const(char)[] path = null,
                   const(char)[] label = null, Component component = null)
    {
        Port* p = defaultAllocator.allocT!Port();
        p.owner = owner;
        p.id = make_port_id(owner, bus, role, path, label).makeString(defaultAllocator());
        if (path.length != 0)
            p.path = path.makeString(defaultAllocator());
        p.label = label;
        p.bus = bus;
        p.role = role;
        p.flow = flow;
        p.component = component;
        p.meter = meter;
        p.meter_phase = phase;
        p.meter_sign = sign;
        p.meter_data.reset_to_missing();
        if (meter)
            p.meter_data = get_port_meter_data(meter, phase, sign);
        bus.ports ~= p;
        ports ~= p;
        return p;
    }

    const(char)[] make_port_id(Appliance owner, Bus* bus, PortRole role, const(char)[] path, const(char)[] label)
    {
        if (owner !is null)
            return tconcat(owner.name[], ".", path.length ? path : port_role_name(role));
        if (label.length != 0)
            return tconcat(label, ".", path.length ? path : port_role_name(role));
        return tconcat(bus ? bus.id[] : "unknown", ".", path.length ? path : port_role_name(role));
    }

    Link* add_link(Appliance owner, Bus* a, Bus* b, Port* port_a, Port* port_b,
                   uint capacity_amps, bool closed = true, const(char)[] label = null,
                   const(char)[] kind = null, const(char)[] id = null)
    {
        Link* l = defaultAllocator.allocT!Link();
        l.owner = owner;
        l.id = make_link_id(owner, port_a, port_b, label, id).makeString(defaultAllocator());
        l.label = label;
        l.kind = kind;
        l.a = a;
        l.b = b;
        l.port_a = port_a;
        l.port_b = port_b;
        l.capacity_amps = capacity_amps;
        l.closed = closed;
        a.links ~= l;
        if (b !is a)
            b.links ~= l;
        links ~= l;
        return l;
    }

    const(char)[] make_link_id(Appliance owner, Port* a, Port* b, const(char)[] label, const(char)[] id)
    {
        if (id.length != 0)
            return id;
        if (label.length != 0)
            return label;
        if (owner !is null)
        {
            const(char)[] from = a && a.path.length ? a.path[] : a ? port_role_name(a.role) : "a";
            const(char)[] to = b && b.path.length ? b.path[] : b ? port_role_name(b.role) : "b";
            return tconcat(owner.name[], ".", from, ".", to);
        }
        return tconcat(a && a.bus ? a.bus.id[] : "unknown", ".",
                       b && b.bus ? b.bus.id[] : "unknown");
    }

    Bus* bus_for_appliance(Appliance a)
    {
        Port* p = anchor_port_for_appliance(a);
        return p ? p.bus : null;
    }

    Port* anchor_port_for_appliance(Appliance a)
    {
        if (a is null)
            return null;
        Port* fallback;
        foreach (p; ports[])
        {
            if (p.owner !is a)
                continue;
            if (fallback is null)
                fallback = p;
            if (p.role == PortRole.grid || p.role == PortRole.connection || p.role == PortRole.parent)
                return p;
            if (p.flow == FlowDomain.consume)
                return p;
        }
        return fallback;
    }

    void build_control_path(Appliance target, ref ControlPath path)
    {
        path.target = target;
        path.target_bus = null;
        path.source_bus = null;
        path.links.clear();
        path.limiting_link = null;
        path.headroom_amps = float.nan;
        path.headroom_watts = float.nan;
        path.voltage = float.nan;
        path.limiting_current_amps = float.nan;
        path.limiting_capacity_amps = 0;
        path.complete = false;

        Port* anchor = anchor_port_for_appliance(target);
        if (anchor is null)
            return;
        path.target_bus = anchor.bus;
        path.source_bus = anchor.bus;

        Array!(Bus*) seen;
        Bus* bus = anchor.bus;
        while (bus !is null)
        {
            if (bus.contains_grid || bus.explicit_root)
            {
                path.source_bus = bus;
                path.complete = true;
                break;
            }
            if (seen[].findFirst(bus) < seen.length)
                break;
            seen ~= bus;

            Link* link = upstream_physical_link(bus);
            Bus* next = link ? link.a : null;
            if (link is null)
            {
                link = upstream_delivery_link(bus, next);
                if (link is null)
                    break;
            }
            path.links ~= link;
            path.source_bus = next;
            update_path_limit(path, link);
            bus = next;
        }
        finalize_path_power(path);
    }

    Link* upstream_physical_link(Bus* bus)
    {
        if (bus is null)
            return null;
        foreach (link; bus.links[])
            if (link.owner is null && link.closed && link.b is bus)
                return link;
        return null;
    }

    // follow the EVSE's internal delivery link upstream so car policies see the breaker chain
    Link* upstream_delivery_link(Bus* bus, out Bus* upstream)
    {
        if (bus is null)
            return null;
        foreach (link; bus.links[])
        {
            if (link.owner is null || !link.closed)
                continue;
            if (link.b is bus && link.port_b !is null && link.port_b.role == PortRole.car)
            {
                upstream = link.a;
                return link;
            }
            if (link.a is bus && link.port_a !is null && link.port_a.role == PortRole.car)
            {
                upstream = link.b;
                return link;
            }
        }
        return null;
    }

    float link_current_amps(Link* link) pure
    {
        if (link is null)
            return float.nan;
        if (link.port_a)
        {
            float v = meter_current_amps(link.port_a.meter_data);
            if (v == v)
                return v;
        }
        if (link.port_b)
        {
            float v = meter_current_amps(link.port_b.meter_data);
            if (v == v)
                return v;
        }
        return float.nan;
    }

    float link_headroom_amps(Link* link) pure
    {
        if (link is null || link.capacity_amps == 0)
            return float.nan;
        float current = link_current_amps(link);
        if (current != current)
            return float.nan;
        return cast(float)link.capacity_amps - current;
    }

    void build()
    {
        clear();
        ++generation;

        foreach (l; Collection!EnergyLink().values)
            add_config_link(l);

        foreach (a; Collection!Appliance().values)
        {
            Array!DevicePort device_ports;
            collect_device_ports(a, device_ports);
            if (device_ports.length != 0)
            {
                apply_appliance_meter(a, device_ports);
                warn_unmatched_bindings(a, device_ports);
                add_device_ports(a, device_ports);
                continue;
            }

            Array!DevicePort virtual_ports;
            collect_bound_ports(a, virtual_ports);
            if (virtual_ports.length == 0)
                collect_vehicle_port(a, virtual_ports);
            if (virtual_ports.length != 0)
            {
                add_device_ports(a, virtual_ports);
                continue;
            }

            a.meter_data.reset_to_missing();
        }

        synthesise_implicit_terminals();

        refresh();
    }

    // A role-declared boundary port (an inverter's battery/pv port, or a breaker
    // child declared role=pv) states what lives on the bus it faces. When nothing
    // of that class is actually modeled there, stand in an implicit dark terminal:
    // node-balance inference assigns it the bus residual, so the equipment the
    // boundary meter can only see in aggregate becomes an accountable terminal,
    // and the bus reads healthy instead of rogue. Modeling the real thing (a BMS,
    // a DC MPPT appliance) displaces the implicit terminal automatically.
    void synthesise_implicit_terminals()
    {
        foreach (b; bus_list[])
        {
            synthesise_class_terminal(b, PortRole.battery, FlowDomain.bidirectional);
            synthesise_class_terminal(b, PortRole.pv, FlowDomain.supply);
        }
    }

    void synthesise_class_terminal(Bus* b, PortRole role, FlowDomain flow)
    {
        bool declared;
        foreach (p; b.ports[])
        {
            if (p.role != role)
                continue;
            if (class_terminal(p))
                return;
            declared = true;
        }
        if (!declared)
            return;
        Port* p = add_port(null, b, role, flow, null, 0, MeterSign.normal, null, b.id[]);
        p.implicit = true;
    }

    void refresh()
    {
        ++sample_generation;
        refresh_meters();
        infer_graph();
        build_kernel();
        rebuild_stores();
        rebuild_productions();
    }

private:
    void on_shape_change(ref const SampleCommit)
    {
        shape_dirty = true;
    }

    void refresh_meters()
    {
        foreach (p; ports[])
        {
            p.meter_data.reset_to_missing();
            if (p.meter)
                p.meter_data = get_port_meter_data(p.meter, p.meter_phase, p.meter_sign);
        }

        foreach (a; Collection!Appliance().values)
        {
            if (Port* p = last_port_for(a))
                a.meter_data = p.meter_data;
            else
                a.meter_data.reset_to_missing();
        }
    }

    void update_path_limit(ref ControlPath path, Link* link) pure
    {
        float headroom = link_headroom_amps(link);
        if (headroom != headroom)
            return;
        if (path.limiting_link is null || headroom < path.headroom_amps)
        {
            path.limiting_link = link;
            path.headroom_amps = headroom;
            path.limiting_current_amps = link_current_amps(link);
            path.limiting_capacity_amps = link.capacity_amps;
        }
    }

    float meter_current_amps(ref const MeterData data) pure
    {
        if (data.has(MeterField.current))
            return absf(data.current[0].value);
        if (data.has(MeterField.power) && data.has(MeterField.voltage))
        {
            float volts = absf(data.voltage[0].value);
            if (volts > 0)
                return absf(data.active[0].value / volts);
        }
        return float.nan;
    }

    void finalize_path_power(ref ControlPath path) pure
    {
        path.voltage = path_voltage(path);
        if (path.headroom_amps == path.headroom_amps && path.voltage == path.voltage && path.voltage > 0)
            path.headroom_watts = path.headroom_amps * path.voltage;
    }

    float path_voltage(ref const ControlPath path) pure
    {
        if (path.target_bus && path.target_bus.balance.has(MeterField.voltage))
            return absf(path.target_bus.balance.voltage[0].value);
        if (path.source_bus && path.source_bus.balance.has(MeterField.voltage))
            return absf(path.source_bus.balance.voltage[0].value);
        foreach (link; path.links[])
        {
            if (link.port_a)
            {
                float volts = meter_voltage(link.port_a.meter_data);
                if (volts == volts)
                    return volts;
            }
            if (link.port_b)
            {
                float volts = meter_voltage(link.port_b.meter_data);
                if (volts == volts)
                    return volts;
            }
        }
        return float.nan;
    }

    float meter_voltage(ref const MeterData data) pure
    {
        if (!data.has(MeterField.voltage))
            return float.nan;
        return absf(data.voltage[0].value);
    }

    void add_config_link(EnergyLink link)
    {
        Component meter = link.meter_ref;
        const(char)[] left = link.parent_circuit.length ? link.parent_circuit : link.circuit;
        const(char)[] right = link.child_circuit;

        if (right.length != 0)
        {
            Bus* ba = ensure_bus(left.length ? left : "grid");
            Bus* bb = ensure_bus(right);
            // only the contents-declaration roles are meaningful on a breaker child
            PortRole child_role = PortRole.child;
            if (link.role.length != 0)
            {
                PortRole declared = port_role_from_name(link.role);
                if (declared == PortRole.pv || declared == PortRole.battery)
                    child_role = declared;
                else
                    log.warning("link '", link.name[], "': role '", link.role, "' is not a downstream contents declaration; expected pv or battery");
            }
            Port* pa = add_port(null, ba, PortRole.parent, FlowDomain.bidirectional, meter, link.meter_phase, link.meter_sign, "parent", link.name[]);
            Port* pb = add_port(null, bb, child_role, FlowDomain.bidirectional, null, 0, MeterSign.normal, "child", link.name[]);
            add_link(null, ba, bb, pa, pb, link.capacity, link.closed, link.name[], link.kind);
        }
        else
        {
            Bus* b = ensure_bus(left.length ? left : "unassigned");
            add_port(null, b, PortRole.connection, flow_for(link.kind), meter, link.meter_phase, link.meter_sign, "connection", link.name[]);
        }
    }

    void add_device_ports(Appliance a, ref Array!DevicePort specs)
    {
        Array!(Port*) added;
        foreach (ref spec; specs[])
        {
            Bus* b = ensure_bus(spec.circuit);
            Port* p = add_port(a, b, spec.role, spec.flow, spec.meter, spec.phase, spec.sign, spec.path[], null, spec.component);
            p.root = a.root && (spec.flow != FlowDomain.consume || specs.length == 1);
            if (p.root)
                b.explicit_root = true;
            added ~= p;
        }

        if (added.length >= 2)
        {
            Port* first = added[0];
            foreach (i; 1 .. added.length)
            {
                DevicePort* spec = &specs[i];
                add_link(a, first.bus, added[i].bus, first, added[i], spec.capacity_amps, spec.closed, null, "appliance");
            }
        }

        if (Port* p = last_port_for(a))
            a.meter_data = p.meter_data;
        else
            a.meter_data.reset_to_missing();
    }

    void collect_device_ports(Appliance a, ref Array!DevicePort into)
    {
        if (a.device_ref is null)
            return;
        collect_device_ports(a, a.device_ref, null, into);
    }

    void collect_device_ports(Appliance a, Component c, const(char)[] path, ref Array!DevicePort into)
    {
        if (c.template_[] == "Port")
        {
            foreach (e; c.elements[])
            {
                e.subscribe(&on_shape_change);
                shape_elements ~= e;
            }

            DevicePort spec;
            spec.component = c;
            spec.path = path.makeString(defaultAllocator());
            spec.role = read_port_role(c);
            spec.flow = read_flow_domain(c);
            spec.circuit = read_port_circuit(a, c, path);
            spec.meter = c.get_first_component_by_template("EnergyMeter");
            spec.phase = read_port_phase(c);
            spec.sign = read_meter_sign(c);
            spec.capacity_amps = read_port_capacity(c);
            spec.closed = read_port_closed(c);
            if (spec.circuit.length != 0)
                into ~= spec;
        }
        foreach (child; c.components[])
        {
            const(char)[] child_path = path.length ? tconcat(path, ".", child.id[]) : child.id[];
            collect_device_ports(a, child, child_path, into);
        }
    }

    void collect_bound_ports(Appliance a, ref Array!DevicePort into)
    {
        bool attach_meter = a.port_bindings.length == 1;
        foreach (ref binding; a.port_bindings[])
        {
            if (binding.circuit.length == 0)
                continue;
            DevicePort spec;
            spec.path = binding.port[].makeString(defaultAllocator());
            spec.circuit = binding.circuit[];
            spec.role = port_role_from_name(last_path_segment(binding.port[]));
            spec.flow = flow_for_port(binding.port[], a.kind);
            spec.meter = attach_meter ? a.meter_ref : null;
            spec.sign = attach_meter && a.meter_sign_set ? a.meter_sign : MeterSign.normal;
            spec.closed = true;
            into ~= spec;
        }
    }

    // a VIN-only car attaches to the circuit named by its VIN; the EVSE reading the same VIN lands on the same bus
    void collect_vehicle_port(Appliance a, ref Array!DevicePort into)
    {
        if (a.vin.length == 0)
            return;
        if (a.kind != "car" && a.kind != "vehicle")
            return;
        DevicePort spec;
        spec.path = StringLit!"connection";
        spec.circuit = a.vin;
        spec.role = PortRole.connection;
        spec.flow = FlowDomain.consume;
        spec.meter = a.meter_ref;
        spec.sign = a.meter_sign_set ? a.meter_sign : MeterSign.normal;
        spec.component = a.state_ref;
        if (spec.component is null)
            spec.component = a.device_ref;
        if (spec.component is null)
            spec.component = vehicle_for(a.vin);
        into ~= spec;
    }

    void apply_appliance_meter(Appliance a, ref Array!DevicePort specs)
    {
        if (a.meter_ref is null)
            return;
        foreach (ref spec; specs[])
            if (spec.meter !is null)
                return;

        DevicePort* target;
        foreach (ref spec; specs[])
        {
            if (spec.role == PortRole.grid || spec.role == PortRole.connection || spec.role == PortRole.parent)
            {
                target = &spec;
                break;
            }
            if (target is null && spec.flow == FlowDomain.consume)
                target = &spec;
        }
        if (target is null && specs.length != 0)
            target = &specs[0];
        if (target !is null)
        {
            target.meter = a.meter_ref;
            if (a.meter_sign_set)
                target.sign = a.meter_sign;
        }
    }

    void warn_unmatched_bindings(Appliance a, ref Array!DevicePort specs)
    {
        foreach (ref binding; a.port_bindings[])
        {
            bool found;
            foreach (ref spec; specs[])
                if (spec.path[] == binding.port[])
                {
                    found = true;
                    break;
                }
            if (!found)
                log.warning("energy appliance '", a.name[], "' binds unknown port '",
                            binding.port[], "'; ignoring circuit '", binding.circuit[], "'");
        }
    }

    const(char)[] read_port_circuit(Appliance a, Component c, const(char)[] path)
    {
        const(char)[] bound = a.port_circuit(path);
        if (bound.length != 0)
            return bound;
        if (Element* e = c.find_element("circuit"))
            if (e.value.isString && e.value.asString.length != 0)
                return e.value.asString;
        return null;
    }

    PortRole port_role_from_name(const(char)[] role) pure
    {
        if (role == "connection") return PortRole.connection;
        if (role == "parent")     return PortRole.parent;
        if (role == "child")      return PortRole.child;
        if (role == "grid")       return PortRole.grid;
        if (role == "battery")    return PortRole.battery;
        if (role == "backup")     return PortRole.backup;
        if (role == "car")        return PortRole.car;
        if (role == "outlet")     return PortRole.outlet;
        if (role == "pv")         return PortRole.pv;
        if (role == "dc")         return PortRole.dc;
        if (role == "ac")         return PortRole.ac;
        return PortRole.connection;
    }

    PortRole read_port_role(Component c)
    {
        if (Element* e = c.find_element("role"))
            if (e.value.isString)
                return port_role_from_name(e.value.asString);
        return PortRole.connection;
    }

    FlowDomain read_flow_domain(Component c)
    {
        if (Element* e = c.find_element("flow"))
            if (e.value.isString)
            {
                const(char)[] flow = e.value.asString;
                if (flow == "consume")       return FlowDomain.consume;
                if (flow == "supply")        return FlowDomain.supply;
                if (flow == "bidirectional") return FlowDomain.bidirectional;
            }
        return FlowDomain.consume;
    }

    ubyte read_port_phase(Component c)
    {
        if (Element* e = c.find_element("phase"))
            if (e.value.isNumber)
                return cast(ubyte)e.value.asFloat;
        return 0;
    }

    MeterSign read_meter_sign(Component c)
    {
        if (Element* e = c.find_element("meter_sign"))
            if (e.value.isString)
                return meter_sign_from_name(e.value.asString);
        return MeterSign.normal;
    }

    uint read_port_capacity(Component c)
    {
        if (Element* e = c.find_element("capacity"))
            if (e.value.isNumber)
                return cast(uint)e.value.asFloat;
        return 0;
    }

    bool read_port_closed(Component c)
    {
        if (Element* e = c.find_element("closed"))
            if (e.value.isBool)
                return e.value.asBool;
        return true;
    }

    Port* last_port_for(Appliance a)
    {
        for (size_t i = ports.length; i-- > 0; )
            if (ports[i].owner is a)
                return ports[i];
        return null;
    }

    FlowDomain flow_for(Appliance a) pure
        => flow_for(a.kind);

    FlowDomain flow_for(const(char)[] kind) pure
    {
        if (kind == "pv" || kind == "solar" || kind == "generator")
            return FlowDomain.supply;
        if (kind == "battery" || kind == "inverter")
            return FlowDomain.bidirectional;
        return FlowDomain.consume;
    }

    FlowDomain flow_for_port(const(char)[] path, const(char)[] kind) pure
    {
        const(char)[] name = last_path_segment(path);
        if (kind == "evse")
        {
            if (name == "car")
                return FlowDomain.supply;
            if (name == "grid" || name == "supply" || name == "connection")
                return FlowDomain.consume;
        }
        if (name == "battery" || name == "grid" || name == "backup")
            return FlowDomain.bidirectional;
        if (name == "pv" || name == "generator" || name == "car" || name.startsWith("outlet"))
            return FlowDomain.supply;
        if (name == "supply")
            return FlowDomain.consume;
        return flow_for(kind);
    }

    const(char)[] last_path_segment(const(char)[] path) pure
    {
        size_t dot = path.findLast('.');
        return dot < path.length ? path[dot + 1 .. $] : path;
    }

    void infer_graph()
    {
        // Alternate link-endpoint mirroring with node-balance inference until no
        // new port data appears. This is intentionally conservative: a bus only
        // infers a missing port when exactly one port is dark.
        foreach (_; 0 .. bus_list.length + links.length + 1)
        {
            bool changed = infer_link_endpoints();
            foreach (b; bus_list[])
                aggregate_bus(b);
            foreach (b; bus_list[])
                changed = infer_single_dark_port(b) || changed;
            if (!changed)
                break;
        }

        foreach (b; bus_list[])
            aggregate_bus(b);
    }

    void build_kernel()
    {
        kernel.clear();
        kernel.generation = generation;

        foreach (b; bus_list[])
        {
            auto bus = kernel.ensure_bus(b.id[]);
            bus.contains_grid = b.contains_grid;
            bus.explicit_root = b.explicit_root;
        }

        foreach (p; ports[])
        {
            CircuitTerminal t;
            t.id = p.id[];
            t.owner = p.owner ? p.owner.name[] : "";
            t.owner_kind = p.owner ? p.owner.kind[] : "";
            t.owner_device = p.owner ? p.owner.device[] : "";
            t.port = p.path.length ? p.path[] : port_role_name(p.role);
            t.label = p.label;
            t.circuit = p.bus ? p.bus.id[] : "";
            t.role = port_role_name(p.role);
            t.domain = domain_for_flow(p.flow);
            t.meter = p.meter_data;
            t.soc = read_battery_soc(battery_store_source(p));
            t.root = p.root;
            t.implicit = p.implicit;
            kernel.add_terminal(t);
        }

        foreach (link; links[])
        {
            CircuitBranch b;
            b.id = link.id[];
            b.owner = link.owner ? link.owner.name[] : "";
            b.label = link.label;
            b.kind = link.kind.length ? link.kind : link.owner ? "appliance" : "link";
            b.parent = link.a ? link.a.id[] : "";
            b.child = link.b ? link.b.id[] : "";
            b.capacity_amps = link.capacity_amps;
            b.conducting = link.closed;
            b.parent_terminal = kernel_terminal_index(link.port_a);
            b.child_terminal = kernel_terminal_index(link.port_b);
            kernel.add_branch(b);
        }

        kernel.infer();
    }

    int kernel_terminal_index(Port* port) pure
    {
        if (port is null)
            return -1;
        foreach (i, ref t; kernel.terminals[])
            if (t.id == port.id[])
                return cast(int)i;
        return -1;
    }


    void rebuild_stores()
    {
        battery_store_contributions.clear();
        battery_stores.clear();
        foreach (p; ports[])
        {
            if (p.bus is null)
                continue;
            Component source = battery_store_source(p);
            if (source is null)
                continue;
            collect_battery_store_contributions(source, p.bus.id[],
                                                p.owner ? p.owner.name[] : "",
                                                p.path.length ? p.path[] : port_role_name(p.role),
                                                battery_store_contribution_kind(p),
                                                battery_store_contributions);
        }
        reconcile_battery_stores(battery_store_contributions, battery_stores);
    }

    Component battery_store_source(Port* p) pure
    {
        if (p is null)
            return null;
        if (p.owner !is null && p.owner.device_ref !is null && p.path.length != 0)
            if (Component c = p.owner.device_ref.find_component(p.path[]))
                return c;
        return p.component;
    }

    BatteryStoreContributionKind battery_store_contribution_kind(Port* p) pure
    {
        if (p !is null && p.owner !is null && p.owner.kind == "battery")
            return BatteryStoreContributionKind.member;
        return BatteryStoreContributionKind.view;
    }

    void rebuild_productions()
    {
        production_contributions.clear();
        productions.clear();
        production_strings.clear();
        foreach (p; ports[])
        {
            if (p.bus is null || p.role != PortRole.pv || p.implicit)
                continue;

            // terminal-first: a boundary pv port (inverter MPPT, declared breaker child)
            // yields to a real pv appliance modeled on the same bus
            if (!class_terminal(p) && bus_has_real_class_terminal(p.bus, PortRole.pv))
                continue;

            const(char)[] owner_name = p.owner ? p.owner.name[] : p.label;
            if (owner_name.length == 0)
                continue;

            const(char)[] group = production_group(p);
            ProductionContribution member;
            member.owner = retain_production_string(owner_name);
            member.group = retain_production_string(group);
            member.port = retain_production_string(p.path.length ? p.path[] : port_role_name(p.role));
            member.circuit = retain_production_string(p.bus.id[]);
            member.kind = ProductionContributionKind.member;
            member.component = p.component;
            member.meter = p.meter_data;
            if (p.owner is null && member.meter.has(MeterField.power) && member.meter.active[0].value < 0)
            {
                // a declared breaker child is net-metered: negative means downstream load
                // exceeds the micros right now, so the visible generation floor is zero
                member.meter.write_value(MeterField.power, 0, 0);
            }
            production_contributions ~= member;

            if (p.owner !is null)
                add_production_aggregate_once(p.owner, group);
        }

        foreach (a; Collection!Appliance().values)
            add_unbound_device_productions(a);
        reconcile_productions(production_contributions, productions);
    }

    void add_unbound_device_productions(Appliance owner)
    {
        if (owner is null || owner.device_ref is null)
            return;

        Array!DevicePort production_ports;
        collect_device_production_ports(owner, owner.device_ref, null, production_ports);
        foreach (ref spec; production_ports[])
        {
            if (production_contribution_exists(owner, spec.path[]))
                continue;
            if (spec.circuit.length == 0)
                spec.circuit = primary_owner_circuit(owner);
            if (spec.circuit.length == 0)
                continue;

            add_production_member(owner, spec);
            add_production_aggregate_once(owner, production_group(spec.path[]));
        }
    }

    void collect_device_production_ports(Appliance owner, Component c, const(char)[] path,
                                         ref Array!DevicePort into)
    {
        if (c.template_[] == "Port")
        {
            PortRole role = read_port_role(c);
            if (role == PortRole.pv)
            {
                DevicePort spec;
                spec.component = c;
                spec.path = path.makeString(defaultAllocator());
                spec.role = role;
                spec.flow = read_flow_domain(c);
                spec.circuit = read_port_circuit(owner, c, path);
                spec.meter = c.get_first_component_by_template("EnergyMeter");
                spec.phase = read_port_phase(c);
                spec.capacity_amps = read_port_capacity(c);
                spec.closed = read_port_closed(c);
                if (spec.meter !is null)
                    into ~= spec;
            }
        }
        foreach (child; c.components[])
        {
            const(char)[] child_path = path.length ? tconcat(path, ".", child.id[]) : child.id[];
            collect_device_production_ports(owner, child, child_path, into);
        }
    }

    bool bus_has_real_class_terminal(Bus* b, PortRole role) pure
    {
        foreach (p; b.ports[])
            if (p.role == role && !p.implicit && class_terminal(p))
                return true;
        return false;
    }

    bool production_contribution_exists(Appliance owner, const(char)[] port) pure
    {
        if (owner is null)
            return false;
        foreach (ref c; production_contributions[])
            if (c.owner == owner.name[] && c.port == port)
                return true;
        return false;
    }

    const(char)[] primary_owner_circuit(Appliance owner) pure
    {
        foreach (p; ports[])
        {
            if (p.owner !is owner || p.bus is null)
                continue;
            if (p.role == PortRole.grid || p.role == PortRole.connection)
                return p.bus.id[];
        }
        foreach (p; ports[])
            if (p.owner is owner && p.bus !is null)
                return p.bus.id[];
        return null;
    }

    void add_production_member(Appliance owner, ref DevicePort spec)
    {
        const(char)[] group = production_group(spec.path[]);
        ProductionContribution member;
        member.owner = retain_production_string(owner.name[]);
        member.group = retain_production_string(group);
        member.port = retain_production_string(spec.path[]);
        member.circuit = retain_production_string(spec.circuit);
        member.kind = ProductionContributionKind.member;
        member.component = spec.component;
        member.meter = get_port_meter_data(spec.meter, spec.phase, spec.sign);
        production_contributions ~= member;
    }

    void add_production_aggregate_once(Appliance owner, const(char)[] group)
    {
        if (owner is null || owner.device_ref is null || group.length == 0)
            return;
        foreach (ref c; production_contributions[])
            if (c.kind == ProductionContributionKind.aggregate &&
                c.owner == owner.name[] && c.group == group)
                return;

        Component aggregate = owner.device_ref.find_component(group);
        if (aggregate is null || aggregate.template_[] != "Solar")
            return;
        Component meter = aggregate.get_first_component_by_template("EnergyMeter");
        if (meter is null)
            return;

        ProductionContribution contribution;
        contribution.owner = retain_production_string(owner.name[]);
        contribution.group = retain_production_string(group);
        contribution.port = retain_production_string(group);
        contribution.circuit = "";
        contribution.kind = ProductionContributionKind.aggregate;
        contribution.component = aggregate;
        contribution.meter = get_meter_data(meter);
        production_contributions ~= contribution;
    }

    const(char)[] retain_production_string(const(char)[] value)
    {
        if (value.length == 0)
            return "";
        production_strings ~= value.makeString(defaultAllocator());
        return production_strings[production_strings.length - 1][];
    }

    const(char)[] production_group(Port* p) pure
    {
        if (p is null || p.path.length == 0)
            return "pv";
        return production_group(p.path[]);
    }

    const(char)[] production_group(const(char)[] path) pure
    {
        if (path.length == 0)
            return "pv";
        size_t dot = path.findLast('.');
        return dot < path.length ? path[0 .. dot] : path;
    }

    bool infer_link_endpoints()
    {
        bool changed;
        foreach (link; links[])
        {
            if (!link.closed)
                continue;
            if (link.owner !is null && !is_passthrough(link.owner))
                continue;
            if (copy_inferred_meter_data(link.port_b, link.port_a))
                changed = true;
            if (copy_inferred_meter_data(link.port_a, link.port_b))
                changed = true;
        }
        return changed;
    }

    // a 2-port appliance (EVSE, inline charger) conserves power across its single internal link;
    // 3+ ports (inverters, multi-outlet) split flow between links, so no per-link mirror is valid
    bool is_passthrough(Appliance a)
    {
        size_t n;
        foreach (p; ports[])
            if (p.owner is a)
                ++n;
        return n == 2;
    }

    bool copy_inferred_meter_data(Port* dst, Port* src)
    {
        if (dst is null || src is null)
            return false;
        if (dst.meter_data.has(MeterField.power) || !src.meter_data.has(MeterField.power))
            return false;

        dst.meter_data = src.meter_data;
        apply_meter_sign(dst.meter_data, MeterSign.inverted);
        mark_meter_data(dst.meter_data, Provenance.inferred_subtraction);
        return true;
    }

    void mark_meter_data(ref MeterData data, Provenance provenance) pure
    {
        foreach (i; 0 .. num_fields)
            foreach (phase; 0 .. 4)
                if (data.provenance[i][phase] != Provenance.missing)
                    data.provenance[i][phase] = provenance;
    }

    bool infer_single_dark_port(Bus* b)
    {
        if (b is null || b.metered_ports == 0 || b.dark_ports != 1)
            return false;
        if (b.residual_power != b.residual_power)
            return false;

        Port* dark;
        foreach (p; b.ports[])
            if (!p.meter_data.has(MeterField.power))
            {
                dark = p;
                break;
            }
        if (dark is null)
            return false;

        // only assign a residual the dark port could physically carry: a positive
        // residual needs a source, a negative one needs a sink
        if (b.residual_power > 0 && dark.flow == FlowDomain.consume)
            return false;
        if (b.residual_power < 0 && dark.flow == FlowDomain.supply)
            return false;

        dark.meter_data.reset_to_missing();
        dark.meter_data.write_value(MeterField.power, 0, -b.residual_power);
        dark.meter_data.mark(MeterField.power, 0, Provenance.inferred_subtraction);
        if (b.balance.has(MeterField.voltage))
        {
            dark.meter_data.voltage[0] = b.balance.voltage[0];
            dark.meter_data.mark(MeterField.voltage, 0, Provenance.inferred_subtraction);
        }
        return true;
    }

    void aggregate_bus(Bus* b)
    {
        b.balance.reset_to_missing();
        b.coverage = Coverage.unknown;
        b.accounted_power = float.nan;
        b.residual_power = float.nan;
        b.unaccounted_load_power = float.nan;
        b.unaccounted_source_power = float.nan;
        b.dark_power_bound = float.nan;
        b.metered_ports = 0;
        b.dark_ports = 0;
        b.anomaly = false;

        float signed_power = 0;
        float flow_scale = 0;
        bool dark_can_sink, dark_can_source;
        foreach (p; b.ports[])
        {
            if (!p.meter_data.has(MeterField.power))
            {
                ++b.dark_ports;
                if (p.flow != FlowDomain.supply)
                    dark_can_sink = true;
                if (p.flow != FlowDomain.consume)
                    dark_can_source = true;
                continue;
            }
            ++b.metered_ports;
            signed_power += p.meter_data.active[0].value;
            if (absf(p.meter_data.active[0].value) > flow_scale)
                flow_scale = absf(p.meter_data.active[0].value);
            b.balance.write_value(MeterField.power, 0, signed_power);
            b.balance.mark(MeterField.power, 0, Provenance.inferred_sum);
            if (p.meter_data.has(MeterField.voltage) && !b.balance.has(MeterField.voltage))
            {
                b.balance.voltage[0] = p.meter_data.voltage[0];
                b.balance.mark(MeterField.voltage, 0, Provenance.inferred_sum);
            }
            if (p.meter_data.has(MeterField.current))
            {
                float c = b.balance.has(MeterField.current) ? b.balance.current[0].value : 0;
                b.balance.current[0] = MeterAmps(p.meter_data.current[0].value + c);
                b.balance.mark(MeterField.current, 0, Provenance.inferred_sum);
            }
        }

        b.accounted_power = signed_power;
        classify_bus_coverage(b, signed_power, flow_scale, dark_can_sink, dark_can_source);
    }

    // Residual frame: signed_power sums port draw (positive = drawn from the bus).
    // A positive residual means known ports draw more than known ports inject, so an
    // unmetered SOURCE must make up the difference (rogue generation); a negative
    // residual means unmetered LOAD is absorbing the surplus (the common case:
    // GPO circuits, cabling loss between bracketing meters).
    void classify_bus_coverage(Bus* b, float signed_power, float flow_scale, bool dark_can_sink, bool dark_can_source)
    {
        if (b.metered_ports == 0)
        {
            b.coverage = Coverage.unknown;
            return;
        }

        b.residual_power = signed_power;
        b.unaccounted_source_power = signed_power > 0 ? signed_power : 0;
        b.unaccounted_load_power = signed_power < 0 ? -signed_power : 0;

        // health classification needs a tolerance: bracketing meters always disagree slightly by
        // stacked calibration + wiring loss, and that is not power appearing from nowhere
        float noise_floor_w = flow_scale * 0.02f > 50 ? flow_scale * 0.02f : 50;
        bool balanced = absf(signed_power) <= noise_floor_w;

        if (b.dark_ports == 0)
        {
            if (balanced)
                b.coverage = Coverage.measured;
            else
            {
                b.coverage = Coverage.rogue_value;
                // rogue load is everyday reality; power appearing from nowhere is not
                if (signed_power > 0)
                    b.anomaly = true;
                b.balance.mark(MeterField.power, 0, Provenance.rogue);
            }
            return;
        }

        b.coverage = Coverage.bounded;
        if (signed_power < 0)
        {
            b.dark_power_bound = dark_can_sink ? -signed_power : 0;
            if (!balanced && !dark_can_sink)
                b.anomaly = true;
        }
        else
        {
            b.dark_power_bound = dark_can_source ? signed_power : 0;
            if (!balanced && !dark_can_source)
                b.anomaly = true;
        }
    }

    float absf(float v) pure
    {
        return v < 0 ? -v : v;
    }

}
