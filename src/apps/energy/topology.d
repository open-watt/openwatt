module apps.energy.topology;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.si.unit : ScaledUnit, Ampere;
import urt.string;
import urt.time : SysTime;
import urt.variant : Variant;

import apps.energy.appliance;
import apps.energy.attribution;
import apps.energy.battery_store;
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
    PortGroup* group;
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

enum PortGroupKind : ubyte
{
    appliance,
    switchgear,
    transfer,
    handover,
    sink,
}

// The thing whose declared terminals these are; transient per topology build.
struct PortGroup
{
nothrow @nogc:
    this(this) @disable;

    String id;
    PortGroupKind kind;
    Appliance owner;
    Link* link;
    Array!(Port*) ports;
    bool closed = true;
}

// The connected port of a one-port group, or any dangling port, is a boundary
// edge of the modeled graph; interior ports support balance and cross-checks.
bool is_boundary(Port* p) pure
{
    if (p is null || p.group is null)
        return false;
    return p.group.ports.length == 1 || p.bus is null;
}

// Appliances are unconditional energy junctions; switchgear connectivity
// follows live contact state.
bool ports_connected(PortGroup* g, Port* a, Port* b)
{
    if (g is null || a is b || a.group !is g || b.group !is g)
        return false;
    final switch (g.kind)
    {
        case PortGroupKind.appliance:
        case PortGroupKind.handover:
            return true;
        case PortGroupKind.switchgear:
        case PortGroupKind.sink:
            return g.link ? g.link.closed : g.closed;
        case PortGroupKind.transfer:
            assert(false, "TODO: transfer switch connectivity needs a declaration surface");
    }
}

// The island a dangling boundary belongs to: the bus reached through its
// group's active internal connections, or null when isolated.
Bus* boundary_bus(Port* p)
{
    if (p is null)
        return null;
    if (p.bus !is null)
        return p.bus;
    if (p.group is null)
        return null;
    foreach (q; p.group.ports[])
        if (q.bus !is null && ports_connected(p.group, p, q))
            return q.bus;
    return null;
}

// Terminals represent equipment and source accounts; boundary ports represent
// places and support only balance and cross-checks.
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

// Utility ingress is an unowned link into the grid bus, distinct from local
// consumers and generators on that bus.
bool is_grid_inlet_port(Port* p) pure
{
    if (p is null || p.bus is null || !p.bus.contains_grid)
        return false;
    foreach (l; p.bus.links[])
        if (l.owner is null && l.a is p.bus && l.b !is null && l.port_a is p)
            return true;
    return false;
}

bool bus_has_grid_inlet(Bus* b) pure
{
    if (b is null)
        return false;
    foreach (p; b.ports[])
        if (is_grid_inlet_port(p))
            return true;
    return false;
}

// A shared hub meter is an appliance aggregate, not a reading for one link.
Port* link_measuring_port(Link* link) pure
{
    if (link is null)
        return null;
    if (link.port_a && !link.port_a_is_hub)
        return link.port_a;
    return link.port_b;
}

// Share hub-meter selection with the allocator so the two cannot diverge.
float link_current_amps(Link* link) pure
{
    if (link is null)
        return float.nan;
    if (link.port_a && !link.port_a_is_hub)
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

Component battery_store_source(Port* p) pure
{
    if (p is null)
        return null;
    if (p.owner !is null && p.owner.device_ref !is null && p.path.length != 0)
        if (Component c = p.owner.device_ref.find_component(p.path[]))
            return c;
    return p.component;
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
    // port_a is an appliance's shared hub port, carrying the aggregate of every
    // leg rather than this link's flow; only port_b measures this link.
    bool port_a_is_hub;
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
        {
            island.id = StringLit!"grid";
            // Traversal order is arbitrary, so explicitly anchor on-grid islands.
            foreach (b; island.members[])
                if (b.contains_grid)
                {
                    island.root = b;
                    break;
                }
        }
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
    Array!(PortGroup*) groups;
    Array!(Element*) shape_elements;
    bool shape_dirty;
    CircuitAttribution attribution;
    Array!BatteryStoreContribution battery_store_contributions;
    Array!BatteryStore battery_stores;
    Array!ProductionContribution production_contributions;
    Array!Production productions;
    Array!String production_strings;
    uint generation;
    uint sample_generation;

    void clear()
    {
        attribution.clear();
        battery_store_contributions.clear();
        battery_stores.clear();
        production_contributions.clear();
        productions.clear();
        production_strings.clear();
        foreach (g; groups[])
            defaultAllocator.freeT(g);
        foreach (p; ports[])
            defaultAllocator.freeT(p);
        foreach (l; links[])
            defaultAllocator.freeT(l);
        foreach (b; bus_list[])
            defaultAllocator.freeT(b);
        groups.clear();
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
        if (bus)
            bus.ports ~= p;
        ports ~= p;
        return p;
    }

    PortGroup* add_group(const(char)[] id, PortGroupKind kind, Appliance owner = null, Link* link = null)
    {
        PortGroup* g = defaultAllocator.allocT!PortGroup();
        g.id = id.makeString(defaultAllocator());
        g.kind = kind;
        g.owner = owner;
        g.link = link;
        groups ~= g;
        return g;
    }

    void add_to_group(PortGroup* g, Port* p)
    {
        p.group = g;
        g.ports ~= p;
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
            if (p.owner !is a || p.bus is null)
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

    // Include the EVSE's upstream breaker chain in car control paths.
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
            if (any_connected(device_ports))
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

    // A boundary role declares equipment on the facing bus. Represent missing
    // equipment with an implicit terminal so balance inference can account for
    // it; a real terminal displaces the stand-in.
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
        add_to_group(add_group(p.id[], PortGroupKind.handover), p);
    }

    void refresh()
    {
        ++sample_generation;
        refresh_meters();
        infer_graph();
        attribution.compute(this);
        rebuild_stores();
        rebuild_productions();
    }

private:
    void on_shape_change(ref const SampleUpdate)
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
            Link* l = add_link(null, ba, bb, pa, pb, link.capacity, link.closed, link.name[], link.kind);
            PortGroup* g = add_group(link.name[], PortGroupKind.switchgear, null, l);
            add_to_group(g, pa);
            add_to_group(g, pb);
        }
        else
        {
            // A parent-only link dangles toward unenumerated attachments; its
            // far endpoint is the boundary (the sink).
            Bus* b = ensure_bus(left.length ? left : "unassigned");
            Port* pa = add_port(null, b, PortRole.connection, flow_for(link.kind), meter, link.meter_phase, link.meter_sign, "connection", link.name[]);
            PortRole dangling_role = link.role.length ? port_role_from_name(link.role) : PortRole.child;
            Port* pb = add_port(null, null, dangling_role, flow_for_role(dangling_role), null, 0, MeterSign.normal, "child", link.name[]);
            PortGroup* g = add_group(link.name[], PortGroupKind.sink);
            g.closed = link.closed;
            add_to_group(g, pa);
            add_to_group(g, pb);
        }
    }

    FlowDomain flow_for_role(PortRole role) pure
    {
        if (role == PortRole.pv)
            return FlowDomain.supply;
        if (role == PortRole.battery || role == PortRole.grid || role == PortRole.backup)
            return FlowDomain.bidirectional;
        return FlowDomain.consume;
    }

    void add_device_ports(Appliance a, ref Array!DevicePort specs)
    {
        size_t connected;
        foreach (ref spec; specs[])
            if (spec.circuit.length != 0)
                ++connected;

        PortGroup* group = add_group(a.name[], PortGroupKind.appliance, a);
        Array!(Port*) added;
        Array!(DevicePort*) added_specs;
        foreach (ref spec; specs[])
        {
            Bus* b = spec.circuit.length ? ensure_bus(spec.circuit) : null;
            Port* p = add_port(a, b, spec.role, spec.flow, spec.meter, spec.phase, spec.sign, spec.path[], null, spec.component);
            add_to_group(group, p);
            if (b is null)
                continue;
            p.root = a.root && (spec.flow != FlowDomain.consume || connected == 1);
            if (p.root)
                b.explicit_root = true;
            added ~= p;
            added_specs ~= &spec;
        }

        if (added.length >= 2)
        {
            Port* first = added[0];
            foreach (i; 1 .. added.length)
            {
                DevicePort* spec = added_specs[i];
                Link* l = add_link(a, first.bus, added[i].bus, first, added[i], spec.capacity_amps, spec.closed, null, "appliance");
                // With 3+ ports the star shares `first` across every leg, so its
                // meter is the appliance aggregate, not this leg's flow.
                if (l && added.length > 2)
                    l.port_a_is_hub = true;
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
            into ~= spec;
        }
        foreach (child; c.components[])
        {
            const(char)[] child_path = path.length ? tconcat(path, ".", child.id[]) : child.id[];
            collect_device_ports(a, child, child_path, into);
        }
    }

    bool any_connected(ref Array!DevicePort specs) pure
    {
        foreach (ref spec; specs[])
            if (spec.circuit.length != 0)
                return true;
        return false;
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

    // A shared VIN circuit joins an unprofiled car to its EVSE.
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

        DevicePort* target;
        DevicePort* first_connected;
        foreach (ref spec; specs[])
        {
            if (spec.circuit.length == 0)
                continue;
            if (first_connected is null)
                first_connected = &spec;
            if (spec.role == PortRole.grid || spec.role == PortRole.connection || spec.role == PortRole.parent)
            {
                target = &spec;
                break;
            }
            if (target is null && spec.flow == FlowDomain.consume)
                target = &spec;
        }
        if (target is null)
            target = first_connected;
        if (target !is null)
        {
            target.meter = a.meter_ref;
            target.sign = a.meter_sign_set ? a.meter_sign : MeterSign.normal;
            target.phase = 0;
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
            if (ports[i].owner is a && ports[i].bus !is null)
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
        // Infer only a single dark port, alternating with link mirroring.
        foreach (_; 0 .. bus_list.length + links.length + groups.length + 1)
        {
            bool changed = infer_link_endpoints();
            foreach (b; bus_list[])
                aggregate_bus(b);
            // One assignment per pass lets its mirrored value reach the far bus
            // before that bus independently infers the other end.
            foreach (b; bus_list[])
                if (infer_single_dark_port(b))
                {
                    changed = true;
                    break;
                }
            foreach (g; groups[])
                if (infer_group_single_unknown(g))
                {
                    changed = true;
                    break;
                }
            if (!changed)
                break;
        }

        foreach (b; bus_list[])
            aggregate_bus(b);
    }

    // Zero-loss group conservation: sum of all declared port powers is zero,
    // solvable when exactly one port (connected or dangling) is unknown.
    bool infer_group_single_unknown(PortGroup* g)
    {
        if (g.ports.length < 2)
            return false;
        if ((g.kind == PortGroupKind.switchgear || g.kind == PortGroupKind.sink) &&
            !(g.link ? g.link.closed : g.closed))
            return false;

        Port* dark;
        float sum = 0;
        foreach (p; g.ports[])
        {
            if (p.meter_data.has(MeterField.power))
                sum += p.meter_data.active[0].value;
            else
            {
                if (dark !is null)
                    return false;
                dark = p;
            }
        }
        if (dark is null)
            return false;

        dark.meter_data.reset_to_missing();
        dark.meter_data.write_value(MeterField.power, 0, -sum);
        dark.meter_data.mark(MeterField.power, 0, Provenance.inferred_subtraction);
        return true;
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

            // A real PV terminal displaces a boundary declaration.
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
                // A net-metered child cannot prove generation while net-consuming.
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

    // Only a two-port appliance conserves power across one unambiguous link.
    // Dangling ports do not carry inferred flow yet, so they do not disqualify.
    bool is_passthrough(Appliance a)
    {
        size_t n;
        foreach (p; ports[])
            if (p.owner is a && p.bus !is null)
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

        // Assign only residuals compatible with the dark port's flow direction.
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

    // In the port-draw frame, positive residual is missing generation and
    // negative residual is missing load.
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

        // Bracketing meters naturally differ by calibration and wiring loss.
        float noise_floor_w = flow_scale * 0.02f > 50 ? flow_scale * 0.02f : 50;
        bool balanced = absf(signed_power) <= noise_floor_w;

        if (b.dark_ports == 0)
        {
            if (balanced)
                b.coverage = Coverage.measured;
            else
            {
                b.coverage = Coverage.rogue_value;
                // Missing load is plausible; unexplained generation is anomalous.
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


}

unittest
{
    TopologyGraph graph;

    // one-port appliance on a bus: the connected port is the boundary
    Bus* house = graph.ensure_bus("house");
    PortGroup* dish = graph.add_group("dishwasher", PortGroupKind.appliance);
    Port* dish_p = graph.add_port(null, house, PortRole.connection, FlowDomain.consume, null, 0);
    graph.add_to_group(dish, dish_p);
    assert(is_boundary(dish_p));

    // two-port sink group: connected upstream interior, dangling downstream boundary
    Port* up = graph.add_port(null, house, PortRole.connection, FlowDomain.consume, null, 0, MeterSign.normal, "connection", "gpo");
    Port* down = graph.add_port(null, null, PortRole.child, FlowDomain.consume, null, 0, MeterSign.normal, "child", "gpo");
    PortGroup* gpo = graph.add_group("gpo", PortGroupKind.sink);
    graph.add_to_group(gpo, up);
    graph.add_to_group(gpo, down);
    assert(up.bus is house && house.ports[].findFirst(up) < house.ports.length);
    assert(down.bus is null && house.ports[].findFirst(down) == house.ports.length);
    assert(!is_boundary(up));
    assert(is_boundary(down));
    assert(ports_connected(gpo, up, down));
    assert(boundary_bus(down) is house);
    gpo.closed = false;
    assert(!ports_connected(gpo, up, down));
    assert(boundary_bus(down) is null);
    gpo.closed = true;

    // multi-port appliance: connected ports interior, dangling MPPT boundary
    Bus* battery = graph.ensure_bus("battery");
    PortGroup* inverter = graph.add_group("inverter", PortGroupKind.appliance);
    Port* grid_p = graph.add_port(null, house, PortRole.grid, FlowDomain.bidirectional, null, 0, MeterSign.normal, "grid");
    Port* batt_p = graph.add_port(null, battery, PortRole.battery, FlowDomain.bidirectional, null, 0, MeterSign.normal, "battery");
    Port* mppt = graph.add_port(null, null, PortRole.pv, FlowDomain.supply, null, 0, MeterSign.normal, "pv.mppt1");
    graph.add_to_group(inverter, grid_p);
    graph.add_to_group(inverter, batt_p);
    graph.add_to_group(inverter, mppt);
    assert(!is_boundary(grid_p));
    assert(!is_boundary(batt_p));
    assert(is_boundary(mppt));
    assert(ports_connected(inverter, grid_p, batt_p));
    assert(boundary_bus(mppt) is house || boundary_bus(mppt) is battery);

    // switchgear with both ends connected: neither endpoint is a boundary
    Bus* outlet = graph.ensure_bus("outlet");
    Port* bra = graph.add_port(null, house, PortRole.parent, FlowDomain.bidirectional, null, 0, MeterSign.normal, "parent", "breaker");
    Port* brb = graph.add_port(null, outlet, PortRole.child, FlowDomain.bidirectional, null, 0, MeterSign.normal, "child", "breaker");
    Link* brl = graph.add_link(null, house, outlet, bra, brb, 20, true, "breaker");
    PortGroup* breaker = graph.add_group("breaker", PortGroupKind.switchgear, null, brl);
    graph.add_to_group(breaker, bra);
    graph.add_to_group(breaker, brb);
    assert(!is_boundary(bra));
    assert(!is_boundary(brb));
    assert(ports_connected(breaker, bra, brb));
    brl.closed = false;
    assert(!ports_connected(breaker, bra, brb));
    brl.closed = true;

    graph.clear();
    assert(graph.ports.length == 0 && graph.groups.length == 0 && graph.bus_list.length == 0);

    // sink absorption: the bus residual solves the connected port, group
    // conservation pushes it out the dangling boundary
    {
        TopologyGraph g2;
        Bus* site = g2.ensure_bus("site");

        Port* main_p = g2.add_port(null, site, PortRole.connection, FlowDomain.bidirectional, null, 0, MeterSign.normal, "main");
        main_p.meter_data.write_value(MeterField.power, 0, -1000);
        main_p.meter_data.mark(MeterField.power, 0, Provenance.measured);
        g2.add_to_group(g2.add_group("main", PortGroupKind.handover), main_p);

        Port* dish_p2 = g2.add_port(null, site, PortRole.connection, FlowDomain.consume, null, 0, MeterSign.normal, "dish");
        dish_p2.meter_data.write_value(MeterField.power, 0, 400);
        dish_p2.meter_data.mark(MeterField.power, 0, Provenance.measured);
        g2.add_to_group(g2.add_group("dish", PortGroupKind.appliance), dish_p2);

        Port* sink_up = g2.add_port(null, site, PortRole.connection, FlowDomain.consume, null, 0, MeterSign.normal, "connection", "outlets");
        Port* sink_down = g2.add_port(null, null, PortRole.child, FlowDomain.consume, null, 0, MeterSign.normal, "child", "outlets");
        PortGroup* outlets = g2.add_group("outlets", PortGroupKind.sink);
        g2.add_to_group(outlets, sink_up);
        g2.add_to_group(outlets, sink_down);

        g2.infer_graph();
        assert(absf(sink_up.meter_data.active[0].value - 600) <= 0.01f);
        assert(absf(sink_down.meter_data.active[0].value + 600) <= 0.01f);
        assert(sink_down.meter_data.source(MeterField.power) == Provenance.inferred_subtraction);
        assert(is_boundary(sink_down) && boundary_bus(sink_down) is site);
        g2.clear();
    }
}
