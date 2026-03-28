module apps.energy;

import urt.array;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.variant;

import apps.api : APIModule;
import apps.energy.appliance;
import apps.energy.circuit;
import apps.energy.manager;
import apps.energy.meter;

import protocol.http.message;
import protocol.http.server;

import router.stream;

import manager;
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

    Map!(const(char)[], Appliance function(String id, EnergyManager* manager) nothrow @nogc) appliance_factory;

    EnergyManager* manager;

    override void init()
    {
        g_app.register_enum!CircuitType();

        register_appliance_type!Inverter();
        register_appliance_type!EVSE();
        register_appliance_type!Car();
        register_appliance_type!HVAC();
        register_appliance_type!WaterHeater();

        manager = defaultAllocator.allocT!EnergyManager();

        g_app.console.register_command!circuit_add("/apps/energy/circuit", this, "add");
        g_app.console.register_command!circuit_print("/apps/energy/circuit", this, "print");

        g_app.console.register_command!appliance_add("/apps/energy/appliance", this, "add");

        get_module!APIModule.register_api_handler("/energy", &energy_api);
    }

    void register_appliance_type(ApplianceType)()
    {
        appliance_factory.insert(ApplianceType.Type[], (String id, EnergyManager* manager) => cast(Appliance)defaultAllocator().allocT!ApplianceType(id.move, manager));
    }
    Appliance create_appliance(const(char)[] type, String id, EnergyManager* manager)
    {
        if (auto fn = type in appliance_factory)
            return (*fn)(id.move, manager);
        return defaultAllocator().allocT!Appliance(id.move, type.makeString(defaultAllocator()), manager);
    }

    override void update()
    {
        manager.update();
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

    void appliance_add(Session session, const(char)[] id, Nullable!(Device) device, Nullable!(const(char)[]) _type, Nullable!(const(char)[]) name, Nullable!(const(char)[]) circuit, Nullable!(int) priority, Nullable!Component meter, Nullable!(const(char)[]) vin, Nullable!Component _info, Nullable!Component control, Nullable!(Component[]) mppt, Nullable!Component backup, Nullable!Component battery)
    {
        const(char)[] type = _type ? _type.value : null;
        Component info = _info ? _info.value : null;

        if (device && !info)
            info = device.value.get_first_component_by_template("DeviceInfo");

        if (!type && info)
        {
            if (Element* infoEl = info.find_element("type"))
                type = infoEl.value.asString();
        }
        if (!type)
        {
            session.write_line("No appliance type for '", id, "'");
            return;
        }

        Appliance appliance = create_appliance(type, id.makeString(g_app.allocator), manager);
        if (!appliance)
        {
            session.write_line("Couldn't create appliance of type '", type, "'");
            return;
        }

        appliance.name = name ? name.value.makeString(g_app.allocator) : String();
        appliance.info = info;
        appliance.meter = meter ? meter.value : null;
        appliance.priority = priority ? priority.value : int.max;

        appliance.init(device ? device.value : null);

        // TODO: delete this, move it all into init functions...
        switch (type)
        {
            case "inverter":
                Inverter a = cast(Inverter)appliance;

                if (control)
                    a.control = control.value;
                if (backup)
                    a.backup = backup.value;
                if (mppt) foreach (pv; mppt.value)
                    a.mppt ~= pv;
                if (battery)
                {
                    a.battery ~= battery.value;
                    a.mppt ~= battery.value;
                }

                // TODO: dummy meter stuff...
                break;

            case "evse":
                EVSE a = cast(EVSE)appliance;

                if (control)
                    a.control = control.value;
                else if (device)
                {
                    a.control = device.value.find_component("charge_control");
                    if (!a.control)
                        a.control = device.value.find_component("control"); // TODO: delete this alias? or should we allow it for non-chargers?
                }
                break;

            case "car":
                Car a = cast(Car)appliance;

                if (battery)
                    a.battery = battery.value;
                if (control)
                    a.control = control.value;
                if (vin)
                    a.vin = vin.value.makeString(g_app.allocator);
                break;

            case "hvac":
                HVAC a = cast(HVAC)appliance;

                if (info)
                    a.info = info;
                if (control)
                    a.control = control.value;
                break;

            case "water-heater":
                WaterHeater a = cast(WaterHeater)appliance;

                if (control)
                    a.control = control.value;
                break;

            default:
                break;
        }

        Circuit* c;
        if (circuit)
        {
            Circuit** t = circuit.value in manager.circuits;
            if (!t)
            {
                session.write_line("Circuit '", circuit.value, "' not found");
                return;
            }
            c = *t;
        }

        manager.add_appliance(appliance, c);
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

                add_meter_row(t, tconcat(child_prefix, a_branch), a.id[], a.meter_data);

                if (Inverter inverter = a.as!Inverter)
                {
                    foreach (mi, mppt; inverter.mppt)
                    {
                        Component meter = mppt.get_first_component_by_template("EnergyMeter");
                        if (meter)
                        {
                            MeterData mppt_data = get_meter_data(meter);
                            bool last_mppt = mi == inverter.mppt.length - 1;
                            MutableString!0 detail;
                            if (mppt.template_[] == "Battery")
                            {
                                if (Element* soc_el = mppt.find_element("soc"))
                                {
                                    float soc = soc_el.value.asFloat();
                                    detail ~= format_soc_bar(soc);
                                    detail ~= "  ";
                                }
                            }
                            detail.append(mppt_data.active[0], "  ", mppt_data.voltage[0], "  ", mppt_data.current[0], "  (",
                                mppt_data.total_import_active[0] * 0.001f, "/", mppt_data.total_export_active[0] * 0.001f, "kWh)");

                            add_span_row(t, tconcat(a_prefix, last_mppt ? tLast : tBranch), mppt.id[], detail[]);
                        }
                    }
                }
                else if (EVSE evse = a.as!EVSE)
                {
                    if (evse.connectedCar)
                        add_span_row(t, tconcat(a_prefix, tLast), evse.connectedCar.id[], evse.connectedCar.vin[]);
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

        HTTPMessage response = create_response(request.http_version, 404, StringLit!"Not Found", StringLit!"application/json", "{\"error\":\"Not Found\"}");
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    int handle_circuit_api(ref const HTTPMessage request, ref Stream stream)
    {
        if (!manager.main)
        {
            HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", "{}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        Array!char json;
        json.reserve(4096);
        json ~= '{';

        build_circuit_json(manager.main, json);

        json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", json[]);
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
                json.append('\"', a.id[], '\"');
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

        bool first = true;
        foreach (a; manager.appliances.values)
        {
            if (!first)
                json ~= ',';
            first = false;

            json.append('\"', a.id[], "\":{");

            json.append("\"type\":\"", a.type, '\"');

            if (a.name.length > 0)
                json.append(",\"name\":\"", a.name[], '\"');

            if (a.circuit)
                json.append(",\"circuit\":\"", a.circuit.id[], '\"');

            if (a.meter)
                json.append(",\"meter\":\"", a.meter.id[], '\"');

            json.append(",\"enabled\":", a.enabled ? "true" : "false");
            json.append(",\"priority\":", a.priority);

            json ~= ',';
            append_meter_data(a.meter_data, json);

            if (Inverter inv = a.as!Inverter)
            {
                json ~= ",\"inverter\":{";
                json.append("\"rated_power\":", inv.ratedPower.value);

                if (inv.mppt.length > 0)
                {
                    json ~= ",\"mppt\":[";
                    bool first_mppt = true;
                    foreach (mppt; inv.mppt)
                    {
                        if (!first_mppt)
                            json ~= ',';
                        first_mppt = false;
                        json.append("{\"id\":\"", mppt.id[], "\",\"template\":\"", mppt.template_[], '\"');

                        Component meter = mppt.get_first_component_by_template("EnergyMeter");
                        if (meter)
                        {
                            MeterData mppt_data = get_meter_data(meter);
                            json ~= ',';
                            append_meter_data(mppt_data, json);
                        }

                        if (mppt.template_[] == "Battery")
                        {
                            if (Element* soc_el = mppt.find_element("soc"))
                                json.append(",\"soc\":", soc_el.value.asFloat());
                            if (Element* mode_el = mppt.find_element("mode"))
                                json.append(",\"mode\":", mode_el.value.asFloat());
                            if (Element* remain_el = mppt.find_element("remain_capacity"))
                                json.append(",\"remain_capacity\":", remain_el.value.asFloat());
                            if (Element* full_el = mppt.find_element("full_capacity"))
                                json.append(",\"full_capacity\":", full_el.value.asFloat());
                        }
                        json ~= '}';
                    }
                    json ~= ']';
                }
                json ~= '}';
            }
            else if (EVSE evse = a.as!EVSE)
            {
                json ~= ",\"evse\":{";
                if (evse.connectedCar)
                    json.append("\"connected_car\":\"", evse.connectedCar.id[], '\"');
                else
                    json ~= "\"connected_car\":null";
                json ~= '}';
            }
            else if (Car car = a.as!Car)
            {
                json ~= ",\"car\":{";
                if (car.vin.length > 0)
                    json.append("\"vin\":\"", car.vin[], '\"');
                if (car.evse)
                {
                    if (car.vin.length > 0)
                        json ~= ',';
                    json.append("\"evse\":\"", car.evse.id[], '\"');
                }
                json ~= '}';
            }

            json ~= '}';
        }

        json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", json[]);
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

    override void render_content(uint offset, uint count, uint width)
    {
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }
        auto avail = count > 0 ? count - 1 : 0;
        _mod.build_circuit_table(session).render_viewport(session, offset, avail, _sticky_widths[]);
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
            if (Inverter inv = a.as!Inverter)
            {
                foreach (mppt; inv.mppt)
                {
                    if (mppt.get_first_component_by_template("EnergyMeter"))
                        ++rows;
                }
            }
            else if (EVSE evse = a.as!EVSE)
            {
                if (evse.connectedCar)
                    ++rows;
            }
        }
        foreach (sub; c.sub_circuits)
            rows += count_rows(sub);
        return rows;
    }
}
