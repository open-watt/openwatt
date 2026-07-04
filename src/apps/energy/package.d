module apps.energy;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time : Duration, MonoTime, SysTime, getSysTime, getTime;
import urt.variant;

import apps.energy.accounts;
import apps.energy.allocator;
import apps.energy.appliance;
import apps.energy.control;
import apps.energy.forecast;
import apps.energy.link;
import apps.energy.manager;
import apps.energy.meter;
import apps.energy.model;
import apps.energy.planner;
import apps.energy.policy;
import apps.energy.state;
import apps.energy.topology;
import apps.energy.vehicle;

import manager;
import manager.collection;
import manager.component;
import manager.device;
import manager.console.command;
import manager.console.live_view;
import manager.console.session;
import manager.console.table;
import manager.element;
import manager.plugin;

nothrow @nogc:



class EnergyAppModule : Module
{
    mixin DeclareModule!"apps.energy";
nothrow @nogc:

    EnergyManager* manager;

    // Synthetic device that publishes the energy app's runtime state
    Device energy_device;

    DailySnapshot daily;
    Planner planner;
    ControlRegistry registry;
    TopologyPublisher topology_publisher;

    Array!Device subscribed_devices;
    bool topology_dirty = true;
    MonoTime last_topology_rebuild;

    override void init()
    {
        g_app.register_enum!BusType();
        g_app.register_enum!Coverage();
        g_app.register_enum!PolicyTier();
        g_app.register_enum!PolicyShape();

        manager = defaultAllocator.allocT!EnergyManager();
        energy_device = create_energy_device();
        create_vehicles_device();
        registry = defaultAllocator.allocT!ControlRegistry();

        planner.supply_forecast = defaultAllocator.allocT!NoSupplyForecast();
        planner.demand_forecast = defaultAllocator.allocT!ConstantLoadDemandForecast();

        g_app.console.register_collection!Appliance();
        g_app.console.register_collection!EnergyLink();
        g_app.console.register_collection!Policy();

        g_app.console.register_command!topology_print("/apps/energy", this, "topology");
        g_app.console.register_command!circuit_print("/apps/energy", this, "circuit");
        g_app.console.register_command!control_print("/apps/energy", this, "control");
        g_app.console.register_command!why("/apps/energy", this, "why");
        g_app.console.register_command!live("/apps/energy", this, "live");

    }

    override void update()
    {
        auto t = getTime();
        refresh_device_subscriptions();
        log_slow_phase("refresh_device_subscriptions", getTime() - t);
        t = getTime();
        if (!topology_dirty && manager.graph.circuit_drift())
            topology_dirty = true;
        log_slow_phase("circuit_drift", getTime() - t);
        t = getTime();
        bool rebuild_topology = consume_topology_rebuild_request();
        manager.update(rebuild_topology);
        if (rebuild_topology)
            last_topology_rebuild = getTime();
        log_slow_phase("manager.update", getTime() - t);
        t = getTime();
        topology_publisher.publish(energy_device, manager.graph, rebuild_topology);
        log_slow_phase("publish_topology", getTime() - t);
        t = getTime();
        Collection!Appliance().update_all();
        log_slow_phase("appliance.update_all", getTime() - t);
        t = getTime();
        registry.resync_all(manager.graph);
        log_slow_phase("registry.resync_all", getTime() - t);
        t = getTime();
        Collection!Policy().update_all();
        log_slow_phase("policy.update_all", getTime() - t);
        t = getTime();
        foreach (Policy p; Collection!Policy().values)
            publish_policy(energy_device, p, registry);
        log_slow_phase("publish_policy", getTime() - t);
        t = getTime();
        planner.tick(energy_device, registry, manager.islands, manager.graph, getSysTime());
        log_slow_phase("planner.tick", getTime() - t);
        t = getTime();
        run_allocator(energy_device, registry, planner, manager.islands, manager.graph);
        log_slow_phase("run_allocator", getTime() - t);
        t = getTime();
        update_accounts(energy_device, manager.islands, manager.graph, daily);
        log_slow_phase("update_accounts", getTime() - t);
    }

    void log_slow_phase(const(char)[] phase, Duration d)
    {
        if (d.as!"msecs" >= 50)
            writeWarning("energy.update.", phase, ": ", d.as!"msecs", "ms");
    }

    void refresh_device_subscriptions()
    {
        foreach (Device d; g_app.devices.values)
        {
            if (d is energy_device)
                continue;
            if (subscribed_devices[].findFirst(d) < subscribed_devices.length)
                continue;
            subscribed_devices ~= d;
            d.subscribe(&on_device_event);
            // TODO: device tree change should mark dependent appliances dirty
            //       so registry.resync_all only re-synthesizes affected controls.
        }
    }

    void on_device_event(Component c, ComponentEvent event)
    {
        if (c is null || !c.is_device)
            return;
        Device d = cast(Device)c;
        if (event == ComponentEvent.destroyed)
        {
            d.unsubscribe(&on_device_event);
            subscribed_devices.removeFirstSwapLast(d);
            topology_dirty = true;
            // TODO: matching appliances should clear their device_ref or fail
            //       resolution on next validate. For now registry.resync_all
            //       drops their controls on the next tick (find_actuator_in
            //       returns null when device_ref dangles? No — it could crash).
            return;
        }
        if (event == ComponentEvent.tree_changed || event == ComponentEvent.online)
            topology_dirty = true;
        // ComponentEvent.tree_changed: registry.resync_all picks up new/removed
        // PowerControl/Switch components on next topology rebuild.
    }

    bool consume_topology_rebuild_request()
    {
        if (topology_dirty)
        {
            topology_dirty = false;
            return true;
        }
        return last_topology_rebuild == MonoTime.init;
    }

    // appliance/link property edits reshape the graph without raising a device tree event
    void request_topology_rebuild()
    {
        topology_dirty = true;
    }

    CommandState live(Session session, const(Variant)[] args)
    {
        return defaultAllocator.allocT!EnergyLiveView(session, this);
    }

    Table build_island_table()
    {
        import urt.conv : format_float;
        import urt.mem.temp : tconcat;
        import manager.console.table;

        Table table;
        table.add_column("island");
        table.add_column("mode");
        table.add_column("solar", Table.TextAlign.right);
        table.add_column("battery", Table.TextAlign.right);
        table.add_column("grid", Table.TextAlign.right);
        table.add_column("generation", Table.TextAlign.right);
        table.add_column("load", Table.TextAlign.right);

        foreach (island; this.manager.islands[])
        {
            table.add_row();
            table.cell(island.id[]);
            table.cell(island_mode_name(island.mode));
            table.cell(read_account_cell(island.id[], "account.solar.power"));
            table.cell(read_account_cell(island.id[], "account.battery.power"));
            table.cell(read_account_cell(island.id[], "account.grid.power"));
            table.cell(read_account_cell(island.id[], "account.generation.power"));
            table.cell(read_account_cell(island.id[], "account.load.total.power"));
        }
        return table;
    }

    const(char)[] read_account_cell(const(char)[] island_id, const(char)[] path)
    {
        import urt.mem.temp : tconcat;
        Element* e = energy_device.find_element(tconcat("islands.", island_id, ".", path));
        if (!e || !e.value.isNumber)
            return "-";
        float v = e.value.asFloat;
        if (v != v)
            return "-";
        return tconcat(v, "W");
    }

    void why(Session session)
    {
        import urt.mem.temp : tconcat;
        import urt.meta.enuminfo : enum_key_from_value;
        import manager.console.table;

        Table table;
        table.add_column("policy");
        table.add_column("target");
        table.add_column("via");
        table.add_column("tier");
        table.add_column("goal");
        table.add_column("current", Table.TextAlign.right);
        table.add_column("ok");
        table.add_column("mv", Table.TextAlign.right);
        table.add_column("decision");
        table.add_column("commanded", Table.TextAlign.right);

        SysTime now = getSysTime();

        foreach (Policy p; Collection!Policy().values)
        {
            table.add_row();
            table.cell(p.name[]);
            table.cell(p.target);

            Control* ctl = registry.lookup(p.target_appliance);
            table.cell(ctl !is null && ctl.partner !is null ? ctl.partner.name[] : "-");
            table.cell(enum_key_from_value!PolicyTier(p.tier));
            table.cell(p.goal);

            float cv = current_value(p, ctl);
            table.cell(cv == cv ? tconcat(cv) : "-");
            table.cell(satisfied(p, ctl) ? "yes" : "no");

            IslandBudget* b = planner.budget_for_policy(p, this.manager.islands);
            PolicyAnalysis a = analyse_policy(p, registry, now, planner.slack_threshold, b, &this.manager.graph);
            table.cell(a.marginal_value == a.marginal_value ? tconcat(a.marginal_value) : "-");

            const(char)[] reason_path = tconcat("allocation.", p.name[], ".reason");
            const(char)[] cmd_path = tconcat("allocation.", p.name[], ".commanded");
            Element* reason_e = energy_device.find_element(reason_path);
            Element* cmd_e = energy_device.find_element(cmd_path);
            table.cell((reason_e && reason_e.value.isString) ? reason_e.value.asString : "-");
            table.cell((cmd_e && cmd_e.value.isNumber) ? tconcat(cmd_e.value.asFloat) : "-");
        }

        table.render(session);
    }

    void control_print(Session session)
    {
        import urt.mem.temp : tconcat;
        import urt.meta.enuminfo : enum_key_from_value;
        import urt.si.quantity : Amps, Watts;
        import manager.console.table;

        Table table;
        table.add_column("appliance");
        table.add_column("via");
        table.add_column("device");
        table.add_column("path");
        table.add_column("kind");
        table.add_column("dir");
        table.add_column("unit");
        table.add_column("range", Table.TextAlign.right);
        table.add_column("setpoint", Table.TextAlign.right);
        table.add_column("nameplate", Table.TextAlign.right);

        char[256] path_buf = void;

        foreach (ref ctl; registry.by_owner.values)
            add_control_row(table, ctl, path_buf[]);
        foreach (ref ctl; registry.by_target.values)
            add_control_row(table, ctl, path_buf[]);

        table.render(session);
    }

    void add_control_row(ref Table table, ref Control ctl, char[] path_buf)
    {
        import urt.mem.temp : tconcat;
        import urt.meta.enuminfo : enum_key_from_value;
        import urt.si.quantity : Amps, Watts;

        table.add_row();
        table.cell(ctl.owner ? ctl.owner.name[] : "-");
        table.cell(ctl.partner ? ctl.partner.name[] : "-");
        table.cell(ctl.device ? ctl.device.id[] : "-");

        if (ctl.source is null)
            table.cell("-");
        else
        {
            ptrdiff_t n = ctl.source.full_path(path_buf[]);
            const(char)[] path = n <= path_buf.length ? path_buf[0 .. n] : "...";
            if (ctl.device !is null)
            {
                const(char)[] dev_prefix = tconcat(ctl.device.id[], ".");
                if (path.length > dev_prefix.length && path[0 .. dev_prefix.length] == dev_prefix)
                    path = path[dev_prefix.length .. $];
            }
            table.cell(path);
        }

        table.cell(enum_key_from_value!ControlKind(ctl.kind));
        table.cell(enum_key_from_value!ControlDirection(ctl.direction));
        table.cell(enum_key_from_value!ControlUnit(ctl.unit));

        const(char)[] suffix;
        final switch (ctl.unit) with (ControlUnit)
        {
            case A:                  suffix = "A"; break;
            case W:                  suffix = "W"; break;
            case percent:            suffix = "%"; break;
            case boolean:
            case nameplate_fraction:
            case unknown:            suffix = ""; break;
        }

        bool has_min = ctl.min == ctl.min;
        bool has_max = ctl.max == ctl.max;
        if (has_min && has_max)
            table.cell(tconcat(ctl.min, "-", ctl.max, suffix));
        else if (has_max)
            table.cell(tconcat("<=", ctl.max, suffix));
        else if (has_min)
            table.cell(tconcat(">=", ctl.min, suffix));
        else
            table.cell("-");

        if (ctl.setpoint is null)
            table.cell("-");
        else if (ctl.setpoint.value.isBool)
            table.cell(ctl.setpoint.value.asBool ? "on" : "off");
        else if (!ctl.setpoint.value.isNumber)
            table.cell("-");
        else
        {
            final switch (ctl.unit) with (ControlUnit)
            {
                case A:                  table.cell(tconcat(cast(Amps)ctl.setpoint.value.asQuantity)); break;
                case W:                  table.cell(tconcat(cast(Watts)ctl.setpoint.value.asQuantity)); break;
                case percent:            table.cell(tconcat(ctl.setpoint.value.asFloat, "%")); break;
                case boolean:
                case nameplate_fraction:
                case unknown:            table.cell(tconcat(ctl.setpoint.value.asFloat)); break;
            }
        }

        if (ctl.nameplate_power == ctl.nameplate_power)
            table.cell(tconcat(ctl.nameplate_power, "W"));
        else
            table.cell("-");
    }

    CommandState topology_print(Session session, const(Variant)[] args)
    {
        bool watch;
        foreach (a; args)
        {
            auto s = a.asString();
            if (s == "-w" || s == "--watch")
                watch = true;
        }

        if (watch)
            return defaultAllocator.allocT!TopologyWatchState(session, this);

        build_topology_table(session).render(session);
        return null;
    }

    CommandState circuit_print(Session session, const(Variant)[] args)
    {
        bool watch;
        foreach (a; args)
        {
            auto s = a.asString();
            if (s == "-w" || s == "--watch")
                watch = true;
        }

        if (watch)
            return defaultAllocator.allocT!CircuitWatchState(session, this);

        build_circuit_table(session).render(session);
        return null;
    }

    Table build_topology_table(Session)
    {
        import urt.mem.temp : tconcat;
        import manager.console.table;

        Table table;
        table.add_column("object");
        table.add_column("id");
        table.add_column("kind");
        table.add_column("bus");
        table.add_column("parent");
        table.add_column("child");
        table.add_column("owner");
        table.add_column("path");
        table.add_column("role");
        table.add_column("state/flow");
        table.add_column("meter");
        table.add_column("coverage");
        table.add_column("power", Table.TextAlign.right);
        table.add_column("I", Table.TextAlign.right);
        table.add_column("extra");

        if (this.manager.graph.bus_list.length == 0)
            return table;

        // "--" for absent (NaN) readings; only stringify live values.
        static const(char)[] fmt(T)(T v, const(char)[] suffix = "")
        {
            static if (is(typeof(v.value) : double))
                const double f = v.value;
            else
                const double f = v;
            return f != f ? "--" : tconcat(v, suffix);
        }

        const(char)[] meter_path(Component meter, char[] scratch)
        {
            if (meter is null)
                return "-";
            ptrdiff_t n = meter.full_path(scratch);
            if (n <= 0)
                return meter.id[];
            if (n > scratch.length)
                return "...";
            return scratch[0 .. n];
        }

        const(char)[] port_id(Port* p)
        {
            if (p.owner)
            {
                if (p.path.length != 0)
                    return tconcat(p.owner.name[], ".", p.path[]);
                return p.owner.name[];
            }
            if (p.label.length != 0)
                return tconcat(p.label, ".", port_role_name(p.role));
            return port_role_name(p.role);
        }

        const(char)[] link_id(Link* link)
        {
            if (link.owner)
                return link.owner.name[];
            if (link.label.length != 0)
                return link.label;
            return tconcat(link.a.id[], "_", link.b.id[]);
        }

        void append_extra(ref MutableString!0 extra, const(char)[] value)
        {
            if (value.length == 0)
                return;
            if (extra.length != 0)
                extra ~= " ";
            extra ~= value;
        }

        void add_row(const(char)[] object, const(char)[] id, const(char)[] kind,
                     const(char)[] bus, const(char)[] parent, const(char)[] child,
                     const(char)[] owner, const(char)[] path, const(char)[] role,
                     const(char)[] state,
                     const(char)[] meter, const(char)[] coverage,
                     const(char)[] power, const(char)[] current, const(char)[] extra)
        {
            table.add_row();
            table.cell(object);
            table.cell(id);
            table.cell(kind);
            table.cell(bus);
            table.cell(parent);
            table.cell(child);
            table.cell(owner);
            table.cell(path);
            table.cell(role);
            table.cell(state);
            table.cell(meter);
            table.cell(coverage);
            table.cell(power);
            table.cell(current);
            table.cell(extra);
        }

        MeterData* link_meter(Link* link)
        {
            if (link.port_a)
                return &link.port_a.meter_data;
            if (link.port_b)
                return &link.port_b.meter_data;
            return null;
        }

        const(char)[] link_meter_path(Link* link, char[] scratch)
        {
            if (link.port_a && link.port_a.meter)
                return meter_path(link.port_a.meter, scratch);
            if (link.port_b && link.port_b.meter)
                return meter_path(link.port_b.meter, scratch);
            return "-";
        }

        void add_bus_row(Bus* bus)
        {
            MutableString!0 extra;
            if (bus.contains_grid)
                append_extra(extra, "grid");
            if (bus.explicit_root)
                append_extra(extra, "root");
            if (bus.anomaly)
                append_extra(extra, "anomaly");
            append_extra(extra, tconcat("accounted=", fmt(bus.accounted_power, "W")));
            append_extra(extra, tconcat("residual=", fmt(bus.residual_power, "W")));
            if (bus.unaccounted_load_power > 0)
                append_extra(extra, tconcat("unaccounted_load=", fmt(bus.unaccounted_load_power, "W")));
            if (bus.unaccounted_source_power > 0)
                append_extra(extra, tconcat("unaccounted_source=", fmt(bus.unaccounted_source_power, "W")));
            append_extra(extra, tconcat("metered_ports=", bus.metered_ports));
            append_extra(extra, tconcat("dark_ports=", bus.dark_ports));
            add_row("bus", bus.id[], "-", bus.id[], "-", "-", "-", "-", "-", "-",
                "-", coverage_name(bus.coverage),
                fmt(bus.balance.active[0]), fmt(bus.balance.current[0]),
                extra.length ? extra[] : "-");
        }

        void add_link_row(Link* link)
        {
            MeterData* data = link_meter(link);
            const(char)[] power = data ? fmt(data.active[0]) : "--";
            const(char)[] current = data ? fmt(data.current[0]) : "--";
            char[256] meter_buf = void;
            MutableString!0 extra;
            if (link.capacity_amps)
                append_extra(extra, tconcat("limit=", link.capacity_amps, "A"));
            if (link.port_a)
                append_extra(extra, tconcat("port_a=", port_id(link.port_a)));
            if (link.port_b)
                append_extra(extra, tconcat("port_b=", port_id(link.port_b)));
            add_row("link", link_id(link),
                link.kind.length ? link.kind : link.owner ? "appliance" : "link",
                "-", link.a ? link.a.id[] : "-", link.b ? link.b.id[] : "-",
                link.owner ? link.owner.name[] : "-",
                "-", "-", link.closed ? "closed" : "open",
                link_meter_path(link, meter_buf[]), "-", power, current,
                extra.length ? extra[] : "-");
        }

        void add_port_row(Port* port)
        {
            char[256] meter_buf = void;
            MutableString!0 extra;
            if (port.root)
                append_extra(extra, "root");
            if (port.meter_phase)
                append_extra(extra, tconcat("phase=", port.meter_phase));
            if (port.label.length != 0)
                append_extra(extra, tconcat("label=", port.label));
            add_row("port", port_id(port), "-", port.bus ? port.bus.id[] : "-",
                "-", "-", port.owner ? port.owner.name[] : "-",
                port.path.length ? port.path[] : "-",
                port_role_name(port.role), flow_domain_name(port.flow),
                meter_path(port.meter, meter_buf[]), "-",
                fmt(port.meter_data.active[0]), fmt(port.meter_data.current[0]),
                extra.length ? extra[] : "-");
        }

        foreach (bus; this.manager.graph.bus_list[])
            add_bus_row(bus);
        foreach (link; this.manager.graph.links[])
            add_link_row(link);
        foreach (port; this.manager.graph.ports[])
            add_port_row(port);

        return table;
    }

    Table build_circuit_table(Session)
    {
        import urt.mem.temp : tconcat;
        import manager.console.table;

        Table table;
        table.add_column("circuit");
        table.add_column("kind");
        table.add_column("power", Table.TextAlign.right);
        table.add_column("import", Table.TextAlign.right);
        table.add_column("export", Table.TextAlign.right);
        table.add_column("apparent", Table.TextAlign.right);
        table.add_column("reactive", Table.TextAlign.right);
        table.add_column("V", Table.TextAlign.right);
        table.add_column("I", Table.TextAlign.right);
        table.add_column("PF (ϕ)", Table.TextAlign.right);
        table.add_column("freq", Table.TextAlign.right);

        if (this.manager.graph.bus_list.length == 0)
            return table;

        static const(char)[] fmt(T)(T v, const(char)[] suffix = "")
        {
            static if (is(typeof(v.value) : double))
                const double f = v.value;
            else
                const double f = v;
            return f != f ? "--" : tconcat(v, suffix);
        }

        const(char)[] metric(MeterData* data, MeterField field, const(char)[] suffix = "")
        {
            if (data is null || !data.has(field))
                return "--";
            return fmt(data.read_value(field), suffix);
        }

        const(char)[] pf_phase(MeterData* data)
        {
            if (data is null || !data.has(MeterField.power_factor))
                return "--";
            if (!data.has(MeterField.phase_angle))
                return fmt(data.pf[0]);
            return tconcat(fmt(data.pf[0]), " (", fmt(data.phase[0], "°"), ")");
        }

        Component find_battery_component(Component root)
        {
            if (root is null)
                return null;
            if (root.template_[] == "Battery")
                return root;
            return root.find_first_component_by_template_recursive("Battery");
        }

        const(char)[] component_soc(Component root)
        {
            Component battery = find_battery_component(root);
            if (battery is null)
                return null;
            if (Element* e = battery.find_element("soc"))
                if (e.value.isNumber)
                    return format_soc_bar(cast(float)e.value.asFloat);
            return null;
        }

        const(char)[] battery_soc(Appliance a, Port* p)
        {
            if (a.kind != "battery")
                return null;
            const(char)[] soc = component_soc(a.state_ref);
            if (soc.length == 0 && p !is null)
                soc = component_soc(p.component);
            if (soc.length == 0)
                soc = component_soc(a.device_ref);
            return soc;
        }

        void add_row(const(char)[] label, const(char)[] kind, MeterData* data,
                     const(char)[] apparent_override = null)
        {
            table.add_row();
            table.cell(label);
            table.cell(kind);
            table.cell(metric(data, MeterField.power, "W"));
            table.cell(metric(data, MeterField.total_import_active, "kWh"));
            table.cell(metric(data, MeterField.total_export_active, "kWh"));
            table.cell(apparent_override.length ? apparent_override : metric(data, MeterField.apparent, "VA"));
            table.cell(metric(data, MeterField.reactive, "var"));
            table.cell(metric(data, MeterField.voltage, "V"));
            table.cell(metric(data, MeterField.current, "A"));
            table.cell(pf_phase(data));
            table.cell(metric(data, MeterField.frequency, "Hz"));
        }

        Port* primary_port(Appliance a)
        {
            foreach (p; this.manager.graph.ports[])
                if (p.owner is a)
                    return p;
            return null;
        }

        bool appliance_belongs_on(Appliance a, Bus* bus)
        {
            Port* p = primary_port(a);
            return p !is null && p.bus is bus;
        }

        void add_bus_row(Bus* bus, const(char)[] prefix, const(char)[] connector)
        {
            add_row(tconcat(prefix, connector, "bus ", bus.id[]), "-", &bus.balance);
        }

        void add_link_row(Link* link, const(char)[] prefix, const(char)[] connector)
        {
            MeterData* data;
            if (link.port_a)
                data = &link.port_a.meter_data;
            else if (link.port_b)
                data = &link.port_b.meter_data;
            const(char)[] kind = link.kind.length ? link.kind : "link";
            if (link.capacity_amps)
                kind = tconcat(kind, " ", link.capacity_amps, "A");
            add_row(tconcat(prefix, connector, link.label),
                kind, data);
        }

        void add_appliance_row(Appliance a, const(char)[] prefix, bool last)
        {
            Port* p = primary_port(a);
            add_row(tconcat(prefix, last ? "└─ " : "├─ ", a.name[]),
                a.kind.length ? a.kind : "-", p ? &p.meter_data : null, battery_soc(a, p));
        }

        Component implicit_port_member(Port* p)
        {
            if (p is null || p.component is null)
                return null;
            if (Component c = p.component.find_first_component_by_template_recursive("Battery"))
                return c;
            if (p.component.template_[] == "Port" && port_role_is(p.component, "pv"))
                return p.component;
            if (Component c = p.component.find_first_component_by_template_recursive("Solar"))
                return c;
            if (Component c = p.component.find_first_component_by_template_recursive("Vehicle"))
                return c;
            return null;
        }

        const(char)[] implicit_member_kind(Component c)
        {
            if (c is null)
                return "-";
            if (c.template_[] == "Battery")
                return "battery";
            if (c.template_[] == "Solar" || port_role_is(c, "pv"))
                return "solar";
            if (c.template_[] == "Vehicle")
                return "vehicle";
            return c.template_[];
        }

        const(char)[] implicit_member_label(Port* p, Component c)
        {
            if (p is null || p.owner is null)
                return c ? c.id[] : "?";
            if (p.path.length == 0)
                return c ? tconcat(p.owner.name[], ".", c.id[]) : p.owner.name[];
            if (c is null)
                return tconcat(p.owner.name[], ".", p.path[]);
            return tconcat(p.owner.name[], ".", p.path[], ".", c.id[]);
        }

        void add_implicit_member_row(Link* link, const(char)[] prefix, bool last)
        {
            Port* p = link.port_b;
            Component member = implicit_port_member(p);
            MeterData member_data;
            MeterData* data = p ? &p.meter_data : null;
            if ((data is null || !data.has(MeterField.power)) && member !is null)
            {
                if (Component meter = member.get_first_component_by_template("EnergyMeter"))
                {
                    member_data = get_meter_data(meter);
                    data = &member_data;
                }
            }
            add_row(tconcat(prefix, last ? "└─ " : "├─ ", implicit_member_label(p, member)),
                implicit_member_kind(member), data, component_soc(member));
        }

        bool bus_has_unaccounted(Bus* bus)
        {
            return bus !is null &&
                   ((bus.unaccounted_load_power == bus.unaccounted_load_power && bus.unaccounted_load_power > 0) ||
                    (bus.unaccounted_source_power == bus.unaccounted_source_power && bus.unaccounted_source_power > 0));
        }

        void add_unaccounted_row(Bus* bus, const(char)[] prefix, bool last)
        {
            MeterData data;
            data.reset_to_missing();
            bool load = bus.unaccounted_load_power == bus.unaccounted_load_power && bus.unaccounted_load_power > 0;
            bool source = bus.unaccounted_source_power == bus.unaccounted_source_power && bus.unaccounted_source_power > 0;
            float power = load ? bus.unaccounted_load_power :
                          source ? -bus.unaccounted_source_power : float.nan;
            data.write_value(MeterField.power, 0, power);
            data.mark(MeterField.power, 0, Provenance.rogue);
            add_row(tconcat(prefix, last ? "└─ " : "├─ ", "?"),
                load ? "unaccounted load" : source ? "unaccounted source" : "unaccounted",
                &data);
        }

        size_t appliance_count(Bus* bus)
        {
            size_t n;
            foreach (a; Collection!Appliance().values)
                if (appliance_belongs_on(a, bus))
                    ++n;
            return n;
        }

        size_t child_link_count(Bus* bus, Link* ingress)
        {
            size_t n;
            foreach (link; bus.links[])
            {
                if (link is ingress)
                    continue;
                if (link.owner !is null || link.a !is bus)
                    continue;
                ++n;
            }
            return n;
        }

        bool bus_has_explicit_children(Bus* bus, Link* ingress)
        {
            return appliance_count(bus) != 0 || child_link_count(bus, ingress) != 0;
        }

        bool link_has_implicit_member(Link* link)
        {
            return link !is null && link.owner !is null && link.b !is null &&
                   !bus_has_explicit_children(link.b, link) &&
                   implicit_port_member(link.port_b) !is null;
        }

        bool bus_has_circuit_children(Bus* bus)
        {
            if (bus is null)
                return false;
            if (appliance_count(bus) != 0)
                return true;
            if (bus_has_unaccounted(bus))
                return true;
            foreach (link; bus.links[])
                if (link.owner is null && link.a is bus)
                    return true;
            return false;
        }

        bool appliance_child_visible(Link* link, Appliance a, Bus* anchor)
        {
            return link.owner is a && link.a is anchor && link.b !is anchor &&
                   (bus_has_circuit_children(link.b) || link_has_implicit_member(link));
        }

        size_t appliance_child_count(Appliance a, Bus* anchor)
        {
            size_t n;
            foreach (link; this.manager.graph.links[])
                if (appliance_child_visible(link, a, anchor))
                    ++n;
            return n;
        }

        size_t root_link_count(Bus* bus)
        {
            if (!bus.contains_grid)
                return 0;
            size_t n;
            foreach (link; bus.links[])
                if (link.owner is null && link.a is bus)
                    ++n;
            return n;
        }

        void add_bus_tree(Bus* bus, Link* ingress, const(char)[] prefix, const(char)[] connector,
                          ref Array!(Bus*) visited, bool emit_self = true)
        {
            if (bus is null)
                return;
            visited ~= bus;
            if (emit_self)
            {
                if (ingress)
                    add_link_row(ingress, prefix, connector);
                else
                    add_bus_row(bus, prefix, connector);
            }

            const(char)[] child_prefix = emit_self
                ? tconcat(prefix, connector == "├─ " ? "│  " : connector.length ? "   " : "")
                : prefix;
            bool has_implicit_member = link_has_implicit_member(ingress);
            bool has_unaccounted = !has_implicit_member && bus_has_unaccounted(bus);
            size_t total = appliance_count(bus) + child_link_count(bus, ingress) +
                           (has_implicit_member ? 1 : 0) +
                           (has_unaccounted ? 1 : 0);
            size_t emitted;

            foreach (a; Collection!Appliance().values)
            {
                if (!appliance_belongs_on(a, bus))
                    continue;
                ++emitted;
                bool last = emitted == total;
                add_appliance_row(a, child_prefix, last);

                size_t child_total = appliance_child_count(a, bus);
                if (child_total == 0)
                    continue;

                const(char)[] appliance_prefix = tconcat(child_prefix, last ? "   " : "│  ");
                size_t child_emitted;
                foreach (link; this.manager.graph.links[])
                {
                    if (!appliance_child_visible(link, a, bus))
                        continue;
                    ++child_emitted;
                    bool child_last = child_emitted == child_total;
                    const(char)[] lane_prefix = child_last ? appliance_prefix : tconcat(appliance_prefix, "│  ");
                    if (visited[].findFirst(link.b) < visited.length)
                        continue;
                    else
                        add_bus_tree(link.b, link, lane_prefix, "└─ ", visited, false);
                }
            }

            foreach (link; bus.links[])
            {
                if (link is ingress)
                    continue;
                if (link.owner !is null || link.a !is bus)
                    continue;
                ++emitted;
                bool last = emitted == total;
                if (link.closed && visited[].findFirst(link.b) >= visited.length)
                    add_bus_tree(link.b, link, child_prefix, last ? "└─ " : "├─ ", visited);
                else
                    add_link_row(link, child_prefix, last ? "└─ " : "├─ ");
            }

            if (has_implicit_member)
            {
                ++emitted;
                add_implicit_member_row(ingress, child_prefix, emitted == total);
            }

            if (has_unaccounted)
            {
                ++emitted;
                add_unaccounted_row(bus, child_prefix, emitted == total);
            }
        }

        bool has_incoming_link(Bus* bus)
        {
            foreach (link; bus.links[])
                if (link.b is bus)
                    return true;
            return false;
        }

        Array!(Bus*) roots;
        void add_root(Bus* bus)
        {
            if (bus is null)
                return;
            if (roots[].findFirst(bus) < roots.length)
                return;
            roots ~= bus;
        }

        bool add_grid_root(Bus* bus, ref Array!(Bus*) visited)
        {
            size_t total = root_link_count(bus);
            if (total == 0)
                return false;

            visited ~= bus;
            size_t emitted;
            foreach (link; bus.links[])
            {
                if (link.owner !is null || link.a !is bus)
                    continue;
                ++emitted;
                bool last = emitted == total;
                if (link.closed && visited[].findFirst(link.b) >= visited.length)
                    add_bus_tree(link.b, link, "", last ? "└─ " : "├─ ", visited);
                else
                    add_link_row(link, "", last ? "└─ " : "├─ ");
            }
            return true;
        }

        bool is_grid_ingress(Link* link)
        {
            return link !is null && link.owner is null && link.a !is null &&
                   link.a.contains_grid && link.b !is null;
        }

        size_t grid_ingress_count()
        {
            size_t n;
            foreach (link; this.manager.graph.links[])
                if (is_grid_ingress(link))
                    ++n;
            return n;
        }

        bool add_grid_ingress_roots(ref Array!(Bus*) visited)
        {
            size_t total = grid_ingress_count();
            if (total == 0)
                return false;

            size_t emitted;
            foreach (link; this.manager.graph.links[])
            {
                if (!is_grid_ingress(link))
                    continue;
                if (visited[].findFirst(link.a) >= visited.length)
                    visited ~= link.a;
                ++emitted;
                bool last = emitted == total;
                if (link.closed && visited[].findFirst(link.b) >= visited.length)
                    add_bus_tree(link.b, link, "", last ? "└─ " : "├─ ", visited);
                else
                    add_link_row(link, "", last ? "└─ " : "├─ ");
            }
            return true;
        }

        add_root(this.manager.graph.find_bus("grid"));
        foreach (bus; this.manager.graph.bus_list[])
            if (bus.explicit_root)
                add_root(bus);
        if (roots.length == 0)
            foreach (bus; this.manager.graph.bus_list[])
                if (!has_incoming_link(bus))
                    add_root(bus);
        if (roots.length == 0)
            add_root(this.manager.graph.bus_list[0]);

        Array!(Bus*) visited;
        add_grid_ingress_roots(visited);
        foreach (root; roots[])
        {
            if (visited[].findFirst(root) < visited.length)
                continue;
            if (root.contains_grid && add_grid_root(root, visited))
                continue;
            add_bus_tree(root, null, "", "", visited);
        }

        foreach (bus; this.manager.graph.bus_list[])
        {
            if (visited[].findFirst(bus) < visited.length)
                continue;
            if (!bus_has_circuit_children(bus))
            {
                visited ~= bus;
                continue;
            }
            add_bus_tree(bus, null, "", "", visited);
        }

        return table;
    }

}

bool port_role_is(Component c, const(char)[] role)
{
    if (c is null || c.template_[] != "Port")
        return false;
    Element* e = c.find_element("role");
    return e && e.value.isString && e.value.asString == role;
}


const(char)[] format_soc_bar(float soc)
{
    import urt.mem.temp : tconcat;

    enum bar_width = 10;
    enum green_bg = "\x1b[42;97m";
    enum grey_bg = "\x1b[100;97m";
    enum reset = "\x1b[0m";

    if (soc != soc)
        soc = 0; // NaN guard
    if (soc < 0)
        soc = 0;
    if (soc > 100)
        soc = 100;

    char[bar_width] bar = ' ';
    int pct = cast(int)(soc + 0.5f);
    const(char)[] label = tconcat(pct, '%');

    // center the label
    size_t label_start = (bar_width - label.length) / 2;
    bar[label_start .. label_start + label.length] = label[];

    // split point: how many chars get green bg
    size_t split = cast(size_t)(soc * bar_width / 100.0f + 0.5f);
    if (split > bar_width)
        split = bar_width;

    if (split == 0)
        return tconcat(grey_bg, bar, reset);
    if (split == bar_width)
        return tconcat(green_bg, bar, reset);
    return tconcat(green_bg, bar[0 .. split], grey_bg, bar[split .. $], reset);
}

class EnergyLiveView : LiveViewState
{
nothrow @nogc:

    this(Session session, EnergyAppModule mod)
    {
        super(session, null);
        _mod = mod;
    }

    override uint content_height()
        => cast(uint)_mod.manager.islands.length;

    override uint header_rows()
        => 1;

    override void render_content(uint offset, uint count, uint width)
    {
        import manager.console.table : Table;
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }
        _mod.build_island_table().render_viewport(session, offset, count, _sticky_widths[]);
    }

    override const(char)[] status_text()
    {
        import urt.mem.temp : tconcat;
        size_t n = _mod.manager.islands.length;
        if (n == 0)
            return "no islands";
        return tconcat(n, n == 1 ? " island" : " islands");
    }

private:
    import manager.console.table : Table;

    EnergyAppModule _mod;
    size_t[Table.max_cols] _sticky_widths;
    uint _prev_width;
}


class TopologyWatchState : LiveViewState
{
nothrow @nogc:

    this(Session session, EnergyAppModule mod)
    {
        super(session, null);
        _mod = mod;
    }

    override uint content_height()
    {
        return cast(uint)(_mod.manager.graph.bus_list.length +
                          _mod.manager.graph.links.length +
                          _mod.manager.graph.ports.length);
    }

    override uint header_rows()
        => 1;

    override void render_content(uint offset, uint count, uint width)
    {
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }
        _mod.build_topology_table(session).render_viewport(session, offset, count, _sticky_widths[]);
    }

    override const(char)[] status_text()
    {
        import urt.mem.temp : tconcat;
        return tconcat(_mod.manager.graph.bus_list.length, " buses");
    }

private:
    import manager.console.table : Table;

    EnergyAppModule _mod;
    size_t[Table.max_cols] _sticky_widths;
    uint _prev_width;

}

class CircuitWatchState : LiveViewState
{
nothrow @nogc:

    this(Session session, EnergyAppModule mod)
    {
        super(session, null);
        _mod = mod;
    }

    override uint content_height()
    {
        Table table = _mod.build_circuit_table(session);
        return table.num_rows;
    }

    override uint header_rows()
        => 1;

    override void render_content(uint offset, uint count, uint width)
    {
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }
        _mod.build_circuit_table(session).render_viewport(session, offset, count, _sticky_widths[]);
    }

    override const(char)[] status_text()
    {
        import urt.mem.temp : tconcat;
        Table table = _mod.build_circuit_table(session);
        return tconcat(table.num_rows, " circuit rows");
    }

private:
    import manager.console.table : Table;

    EnergyAppModule _mod;
    size_t[Table.max_cols] _sticky_widths;
    uint _prev_width;
}
