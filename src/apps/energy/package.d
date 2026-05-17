module apps.energy;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time : SysTime, getSysTime;
import urt.variant;

import apps.api : APIModule;
import apps.energy.accounts;
import apps.energy.allocator;
import apps.energy.appliance;
import apps.energy.circuit;
import apps.energy.control;
import apps.energy.forecast;
import apps.energy.island;
import apps.energy.manager;
import apps.energy.meter;
import apps.energy.planner;
import apps.energy.policy;
import apps.energy.state;
import apps.energy.vehicle;

import protocol.http.message;
import protocol.http.server;

import router.stream;

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

    // Synthetic device that publishes the energy app's runtime state (per-island
    // accounts, pressures, policy/allocation records). See state.d.
    Device energy_device;

    DailySnapshot daily;
    Planner planner;
    ControlRegistry registry;

    Array!Device subscribed_devices;

    override void init()
    {
        g_app.register_enum!CircuitType();
        g_app.register_enum!PolicyTier();
        g_app.register_enum!PolicyShape();

        manager = defaultAllocator.allocT!EnergyManager();
        energy_device = create_energy_device();
        create_vehicles_device();
        registry = defaultAllocator.allocT!ControlRegistry();

        planner.supply_forecast = defaultAllocator.allocT!NoSupplyForecast();
        planner.demand_forecast = defaultAllocator.allocT!ConstantLoadDemandForecast();

        g_app.console.register_command!circuit_add("/apps/energy/circuit", this, "add");
        g_app.console.register_command!circuit_print("/apps/energy/circuit", this, "print");
        g_app.console.register_command!circuit_set("/apps/energy/circuit", this, "set");

        g_app.console.register_collection!Appliance();

        g_app.console.register_command!control_print("/apps/energy/control", this, "print");

        g_app.console.register_collection!Policy();

        g_app.console.register_command!why("/apps/energy", this, "why");
        g_app.console.register_command!live("/apps/energy", this, "live");

        get_module!APIModule.register_api_handler("/energy", &energy_api);
    }

    override void update()
    {
        refresh_device_subscriptions();
        manager.update();
        Collection!Appliance().update_all();
        update_vin_pairings();
        registry.resync_all();
        Collection!Policy().update_all();
        foreach (Policy p; Collection!Policy().values)
            publish_policy(energy_device, p, registry);
        planner.tick(energy_device, registry, manager.archipelago, getSysTime());
        run_allocator(energy_device, registry, planner, manager.archipelago);
        update_accounts(energy_device, manager.archipelago, daily);
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
        Device d = cast(Device)c;
        if (d is null)
            return;
        if (event == ComponentEvent.destroyed)
        {
            d.unsubscribe(&on_device_event);
            subscribed_devices.removeFirstSwapLast(d);
            // TODO: matching appliances should clear their device_ref or fail
            //       resolution on next validate. For now registry.resync_all
            //       drops their controls on the next tick (find_actuator_in
            //       returns null when device_ref dangles? No — it could crash).
            return;
        }
        // ComponentEvent.tree_changed: registry.resync_all picks up new/removed
        // PowerControl/Switch components on next tick.
    }

    void circuit_add(Session session, const(char)[] name, Nullable!(const(char)[]) parent, Nullable!Component meter, Nullable!(uint) max_current, Nullable!CircuitType _type, Nullable!(uint) parent_phase, Nullable!(uint) meter_phase)
    {
        Circuit* p;
        if (parent)
        {
            p = manager.find_circuit(parent.value);
            if (!p)
            {
                session.write_line("Circuit '", parent.value, "' not found");
                return;
            }
        }

        CircuitType type = _type ? _type.value : CircuitType.unknown;
        ubyte pphase = 0, mphase = 0;

        if (parent_phase)
        {
            if (parent_phase.value < 1 || parent_phase.value > 3)
            {
                session.write_line("Parent phase must be 1, 2, or 3");
                return;
            }
            pphase = cast(ubyte)parent_phase.value;
        }
        if (meter_phase)
        {
            if (meter_phase.value < 1 || meter_phase.value > 3)
            {
                session.write_line("Meter phase must be 1, 2, or 3");
                return;
            }
            mphase = cast(ubyte)meter_phase.value;
        }

        if (type.is_multi_phase)
        {
            if (mphase != 0)
            {
                session.write_line("3-phase circuit cannot specify meter_phase");
                return;
            }
            if (p)
            {
                CircuitType parent_type = p.type != CircuitType.unknown ? p.type : (p.meter ? get_meter_type(p.meter) : CircuitType.unknown);
                if (!parent_type.is_multi_phase && parent_type != CircuitType.unknown)
                {
                    session.write_line("3-phase circuit must have 3-phase parent");
                    return;
                }
            }
        }

        if (p)
        {
            CircuitType parent_type = p.type != CircuitType.unknown ? p.type : (p.meter ? get_meter_type(p.meter) : CircuitType.unknown);
            if (parent_type.is_multi_phase && !type.is_multi_phase && type != CircuitType.unknown && pphase == 0)
            {
                session.write_line("Non-3-phase circuit on 3-phase parent must specify parent_phase");
                return;
            }
        }

        manager.add_circuit(name.makeString(g_app.allocator), p, max_current ? max_current.value : 0, meter ? meter.value : null, type, pphase, mphase);
    }

    void circuit_set(Session session, const(char)[] name, Nullable!bool isolated)
    {
        Circuit* c = manager.find_circuit(name);
        if (!c)
        {
            session.write_line("Circuit '", name, "' not found");
            return;
        }
        if (isolated)
            c.isolated = isolated.value;
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

        foreach (island; this.manager.archipelago[])
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
        Element* e = energy_device.find_element(tconcat("archipelago.island.", island_id, ".", path));
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
            table.cell(enum_key_from_value!PolicyTier(p.tier));
            table.cell(p.goal);

            Control* ctl = registry.lookup(p.target_appliance);
            float cv = current_value(p, ctl);
            table.cell(cv == cv ? tconcat(cv) : "-");
            table.cell(satisfied(p, ctl) ? "yes" : "no");

            IslandBudget* b = planner.budget_for_policy(p, this.manager.archipelago);
            PolicyAnalysis a = analyse_policy(p, registry, now, planner.slack_threshold, b);
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
        {
            table.add_row();
            table.cell(ctl.owner ? ctl.owner.name[] : "-");
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

        table.render(session);
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

    Table build_circuit_table(Session)
    {
        import urt.conv : format_float;
        import urt.mem.temp : tconcat;
        import manager.console.table;

        Table table;
        table.add_column("name");
        table.add_column("power", Table.TextAlign.right);
        table.add_column("import", Table.TextAlign.right);
        table.add_column("export", Table.TextAlign.right);
        table.add_column("apparent", Table.TextAlign.right);
        table.add_column("reactive", Table.TextAlign.right);
        table.add_column("V", Table.TextAlign.right);
        table.add_column("I", Table.TextAlign.right);
        table.add_column("PF (ϕ)");
        table.add_column("freq", Table.TextAlign.right);

        if (!this.manager.main)
            return table;

        enum tBranch = "├─ ";
        enum tLast   = "└─ ";
        enum tPipe   = "│  ";
        enum tBlank  = "   ";

        void add_meter_row(ref Table t, const(char)[] prefix, const(char)[] name, ref MeterData data)
        {
            t.add_row();
            t.cell(tconcat(prefix, name));
            t.cell(tconcat(data.active[0]));
            t.cell(tconcat(data.total_import_active[0] * 0.001f, "kWh"));
            t.cell(tconcat(data.total_export_active[0] * 0.001f, "kWh"));
            t.cell(tconcat(data.apparent[0], "VA"));
            t.cell(tconcat(data.reactive[0], "var"));
            t.cell(tconcat(data.voltage[0]));
            t.cell(tconcat(data.current[0]));
            t.cell(tconcat(data.pf[0], " (", data.phase[0] * 360, "°)"));
            t.cell(tconcat(data.freq, "Hz"));
        }

        void add_span_row(ref Table t, const(char)[] prefix, const(char)[] name, const(char)[] detail)
        {
            t.add_row();
            t.cell(tconcat(prefix, name));
            t.cell_span(detail);
        }

        void traverse(ref Table t, Circuit* c, const(char)[] prefix, bool is_last, bool is_root = false)
        {
            const(char)[] branch = is_root ? "" : (is_last ? tLast : tBranch);
            const(char)[] child_prefix = is_root ? "" : tconcat(prefix, is_last ? tBlank : tPipe);

            add_meter_row(t, tconcat(prefix, branch), c.id[], c.meter_data);

            bool has_leftover = c.meter && (c.appliances.length != 0 || c.sub_circuits.length != 0);
            size_t total_children = (has_leftover ? 1 : 0) + c.appliances.length + c.sub_circuits.length;
            size_t child_idx = 0;

            if (has_leftover)
            {
                ++child_idx;
                bool last_child = child_idx == total_children;
                add_meter_row(t, tconcat(child_prefix, last_child ? tLast : tBranch), "?", c.rogue);
            }

            foreach (ai, a; c.appliances)
            {
                ++child_idx;
                bool last_child = child_idx == total_children;
                const(char)[] a_branch = last_child ? tLast : tBranch;
                const(char)[] a_prefix = tconcat(child_prefix, last_child ? tBlank : tPipe);

                add_meter_row(t, tconcat(child_prefix, a_branch), a.name[], a.meter_data);

                // Heuristic drilldown: walk the appliance's primary device for
                // Solar/Battery sub-components and show their per-MPPT meter
                // data + SOC bar. Replaces the old type-specific Inverter walker.
                // Also show VIN-paired partner (replaces old EVSE.connectedCar).
                Array!Component drilldown_components;
                if (a.device_ref !is null)
                {
                    collect_drilldown(a.device_ref, drilldown_components);
                }
                size_t drilldown_total = drilldown_components.length + (a.paired_with !is null ? 1 : 0);
                size_t drilldown_idx = 0;
                foreach (sub; drilldown_components)
                {
                    ++drilldown_idx;
                    bool last_drill = drilldown_idx == drilldown_total;
                    Component meter = sub.get_first_component_by_template("EnergyMeter");
                    if (meter is null)
                        continue;
                    MeterData sub_data = get_meter_data(meter);
                    MutableString!0 detail;
                    if (sub.template_[] == "Battery")
                    {
                        if (Element* soc_el = sub.find_element("soc"))
                        {
                            float soc = soc_el.value.asFloat();
                            detail ~= format_soc_bar(soc);
                            detail ~= "  ";
                        }
                    }
                    detail.append(sub_data.active[0], "  ", sub_data.voltage[0], "  ", sub_data.current[0], "  (",
                        sub_data.total_import_active[0] * 0.001f, "/", sub_data.total_export_active[0] * 0.001f, "kWh)");
                    add_span_row(t, tconcat(a_prefix, last_drill ? tLast : tBranch), sub.id[], detail[]);
                }
                if (a.paired_with !is null)
                {
                    Appliance partner = a.paired_with;
                    add_span_row(t, tconcat(a_prefix, tLast), partner.name[], partner.vin);
                }
            }

            foreach (si, sub; c.sub_circuits)
            {
                ++child_idx;
                bool last_child = child_idx == total_children;
                traverse(t, sub, child_prefix, last_child);
            }
        }

        traverse(table, this.manager.main, "", true, true);
        return table;
    }

    int energy_api(const(char)[] uri, ref const HTTPMessage request, ref Stream stream)
    {
        import urt.format.json;

        if (uri == "/circuit")
            return handle_circuit_api(request, stream);
        if (uri == "/appliances")
            return handle_appliances_api(request, stream);

        HTTPMessage response = create_response(request.http_version, 404, StringLit!"application/json", "{\"error\":\"Not Found\"}");
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    int handle_circuit_api(ref const HTTPMessage request, ref Stream stream)
    {
        if (!manager.main)
        {
            HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/json", "{}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        Array!char json;
        json.reserve(4096);
        json ~= '{';

        build_circuit_json(manager.main, json);

        json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/json", json[]);
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    void build_circuit_json(Circuit* circuit, ref Array!char json)
    {
        json.append('\"', circuit.id[], "\":{");

        if (circuit.name.length > 0)
            json.append("\"name\":\"", circuit.name[], "\",");

        json.append("\"type\":\"", circuit.type, "\",");
        json.append("\"max_current\":", circuit.max_current, ',');

        if (circuit.meter)
            json.append("\"meter\":\"", circuit.meter.id[], "\",");

        append_meter_data(circuit.meter_data, json);

        if (circuit.sub_circuits.length > 0)
        {
            json ~= ",\"sub_circuits\":{";
            bool first = true;
            foreach (sub; circuit.sub_circuits)
            {
                if (!first)
                    json ~= ',';
                first = false;
                build_circuit_json(sub, json);
            }
            json ~= "}";
        }

        if (circuit.appliances.length > 0)
        {
            json ~= ",\"appliances\":[";
            bool first = true;
            foreach (a; circuit.appliances)
            {
                if (!first)
                    json ~= ',';
                first = false;
                json.append('\"', a.name[], '\"');
            }
            json ~= "]";
        }

        json ~= '}';
    }

    int handle_appliances_api(ref const HTTPMessage request, ref Stream stream)
    {
        Array!char json;
        json.reserve(4096);
        json ~= '{';

        // TODO: this API surface is heuristic — walks each appliance's primary
        //       device for Solar/Battery sub-components and emits them as
        //       generic blobs. Loses the explicit shape of the old
        //       inverter/evse/car JSON. The full UX-side renovation will
        //       replace this with a properly structured surface.
        bool first = true;
        foreach (Appliance a; Collection!Appliance().values)
        {
            if (!first)
                json ~= ',';
            first = false;

            json.append('\"', a.name[], "\":{");

            json.append("\"kind\":\"", a.kind, '\"');

            if (a.name.length > 0)
                json.append(",\"name\":\"", a.name[], '\"');

            if (a.circuit_ref)
                json.append(",\"circuit\":\"", a.circuit_ref.id[], '\"');

            if (a.meter_ref)
                json.append(",\"meter\":\"", a.meter_ref.id[], '\"');

            if (a.vin.length > 0)
                json.append(",\"vin\":\"", a.vin, '\"');

            if (a.paired_with !is null)
                json.append(",\"paired_with\":\"", a.paired_with.name[], '\"');

            json ~= ',';
            append_meter_data(a.meter_data, json);

            // Generic sub-component drilldown (replaces inverter.mppt blob)
            Array!Component drill;
            if (a.device_ref !is null)
                collect_drilldown(a.device_ref, drill);
            if (drill.length > 0)
            {
                json ~= ",\"subassemblies\":[";
                bool first_sub = true;
                foreach (sub; drill)
                {
                    if (!first_sub)
                        json ~= ',';
                    first_sub = false;
                    json.append("{\"id\":\"", sub.id[], "\",\"template\":\"", sub.template_[], '\"');

                    Component meter = sub.get_first_component_by_template("EnergyMeter");
                    if (meter)
                    {
                        MeterData sub_data = get_meter_data(meter);
                        json ~= ',';
                        append_meter_data(sub_data, json);
                    }

                    if (sub.template_[] == "Battery")
                    {
                        if (Element* soc_el = sub.find_element("soc"))
                            json.append(",\"soc\":", soc_el.value.asFloat());
                        if (Element* mode_el = sub.find_element("mode"))
                            json.append(",\"mode\":", mode_el.value.asFloat());
                        if (Element* remain_el = sub.find_element("remain_capacity"))
                            json.append(",\"remain_capacity\":", remain_el.value.asFloat());
                        if (Element* full_el = sub.find_element("full_capacity"))
                            json.append(",\"full_capacity\":", full_el.value.asFloat());
                    }
                    json ~= '}';
                }
                json ~= ']';
            }

            json ~= '}';
        }

        json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/json", json[]);
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    void append_meter_data(ref const MeterData data, ref Array!char json)
    {
        json ~= "\"meter_data\":{";

        bool first = true;

        void append_element(T)(const(char)[] name, ref const T[4] values, bool multi)
        {
            static if (is(T == float))
                alias f = values;
            else
            {
                float[4] f = void;
                foreach (i; 0 .. multi ? 4 : 1)
                   f[i] = values[i].value;
            }
            if (f[0] != f[0])
                return; // NaN check

            if (multi)
                json.append(first ? "\"" : ",\"", name, "\":[", f[0], ',', f[1], ',', f[2], ',', f[3], ']');
            else
                json.append(first ? "\"" : ",\"", name, "\":", f[0]);
            first = false;
        }

        bool is_multi = data.type.is_multi_phase;
        if (data.fields & FieldFlags.voltage)
            append_element("voltage", data.voltage, is_multi);
        if (data.fields & FieldFlags.current)
            append_element("current", data.current, is_multi);
        if (data.fields & FieldFlags.power)
            append_element("power", data.active, is_multi);
        if (data.fields & FieldFlags.reactive)
            append_element("reactive", data.reactive, is_multi);
        if (data.fields & FieldFlags.apparent)
            append_element("apparent", data.apparent, is_multi);
        if (data.fields & FieldFlags.power_factor)
            append_element("pf", data.pf, is_multi);
        if (data.fields & FieldFlags.phase_angle)
            append_element("phase", data.phase, is_multi);
        if (data.fields & FieldFlags.total_import_active)
            append_element("import", data.total_import_active, is_multi);
        if (data.fields & FieldFlags.total_export_active)
            append_element("export", data.total_export_active, is_multi);
        if (data.fields & FieldFlags.frequency)
            append_element("frequency", (&data.freq)[0..4], false);

        json ~= '}';
    }
}

// Heuristic walker for the circuit-tree drilldown UI: collect direct Solar
// and Battery sub-components from an appliance's primary device. Misses
// non-conforming devices (anything that doesn't expose its arrays as
// Solar/Battery templates), which is fine — the row just doesn't drill in.
// TODO: a more principled mechanism would be an explicit `subassemblies=`
//       slot on Appliance, or a generic "show me your meterable parts"
//       interface on Component. Punted until the device side of the UX gets
//       a proper renovation.
void collect_drilldown(Component device, ref Array!Component into)
{
    if (device is null)
        return;
    Component solar_root = device.get_first_component_by_template("Solar");
    if (solar_root !is null)
    {
        // If there's an outer Solar wrapper with nested Solar children, list
        // the children; otherwise list the wrapper itself.
        Array!Component nested = solar_root.find_components_by_template("Solar");
        if (nested.length > 0)
        {
            foreach (n; nested)
                into ~= n;
        }
        else
        {
            into ~= solar_root;
        }
    }
    if (Component battery = device.get_first_component_by_template("Battery"))
        into ~= battery;
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
        => cast(uint)_mod.manager.archipelago.length;

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
        size_t n = _mod.manager.archipelago.length;
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
        if (!_mod.manager.main)
            return 0;
        return count_rows(_mod.manager.main);
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
        if (!_mod.manager.main)
            return "no circuits";
        return tconcat(count_rows(_mod.manager.main), " rows");
    }

private:
    import manager.console.table : Table;

    EnergyAppModule _mod;
    size_t[Table.max_cols] _sticky_widths;
    uint _prev_width;

    static uint count_rows(Circuit* c)
    {
        uint rows = 1;
        bool has_leftover = c.meter && (c.appliances.length != 0 || c.sub_circuits.length != 0);
        if (has_leftover)
            ++rows;
        foreach (a; c.appliances)
        {
            ++rows;
            // Match the drilldown in build_circuit_table.traverse: count each
            // Solar/Battery sub-component that has its own EnergyMeter, plus
            // the paired-partner row.
            Array!Component drill;
            if (a.device_ref !is null)
                collect_drilldown(a.device_ref, drill);
            foreach (sub; drill)
                if (sub.get_first_component_by_template("EnergyMeter"))
                    ++rows;
            if (a.paired_with !is null)
                ++rows;
        }
        foreach (sub; c.sub_circuits)
            rows += count_rows(sub);
        return rows;
    }
}
