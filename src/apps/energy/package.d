module apps.energy;

import urt.array;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;

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
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
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
        appliance_factory.insert(ApplianceType.Type, (String id, EnergyManager* manager) => cast(Appliance)defaultAllocator().allocT!ApplianceType(id.move, manager));
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

    // /apps/energy/print command
    void circuit_print(Session session)
    {
        import urt.conv : format_float;
        import urt.util;

        import manager.element;

        struct Line
        {
            Appliance appliance;
            ubyte indent;
            const(char)[] id;
            MeterData* data;
        }

        Line[20] line_cache = void;
        Line[] lines;
        size_t num_lines = this.manager.circuits.length*2 + this.manager.appliances.length;
        if (num_lines > 20)
            lines = defaultAllocator().allocArray!Line(num_lines);
        else
        {
            lines = line_cache[0 .. num_lines];
            lines[] = Line();
        }

        size_t i = 0;
        size_t name_len = 4;
        size_t power_len = 5;
        size_t import_len = 6;
        size_t export_len = 6;
        size_t apparent_len = 8;
        size_t reactive_len = 8;
        size_t current_len = 1;

        void traverse(Circuit* c, uint indent)
        {
            Line* circuit = &lines[i++];
            circuit.indent = cast(ubyte)indent;
            circuit.id = c.id[];
            circuit.data = &c.meter_data;

            name_len = max(name_len, circuit.indent + c.id.length);
            power_len = max(power_len, c.meter_data.active[0].value.format_float(null) + 1);
            import_len = max(import_len, c.meter_data.total_import_active[0].format_float(null) + 3);
            export_len = max(export_len, c.meter_data.total_export_active[0].format_float(null) + 3);
            apparent_len = max(apparent_len, c.meter_data.apparent[0].format_float(null) + 2);
            reactive_len = max(reactive_len, c.meter_data.reactive[0].format_float(null) + 3);
            current_len = max(current_len, c.meter_data.current[0].value.format_float(null) + 1);

            Line* unknown;
            bool has_leftover = c.meter && (c.appliances.length != 0 || c.sub_circuits.length != 0);
            if (has_leftover)
            {
                unknown = &lines[i++];
                unknown.indent = cast(ubyte)(indent + 2);
                unknown.id = "?";
                unknown.data = &c.rogue;
            }

            foreach (a; c.appliances)
            {
                Line* line = &lines[i++];
                line.appliance = a;
                line.indent = cast(ubyte)(indent + 2);
                line.id = a.id[];
                line.data = &a.meter_data;

                name_len = max(name_len, line.indent + a.id.length);
                power_len = max(power_len, a.meter_data.active[0].value.format_float(null) + 1);
                import_len = max(import_len, a.meter_data.total_import_active[0].format_float(null) + 3);
                export_len = max(export_len, a.meter_data.total_export_active[0].format_float(null) + 3);
                apparent_len = max(apparent_len, a.meter_data.apparent[0].format_float(null) + 2);
                reactive_len = max(reactive_len, a.meter_data.reactive[0].format_float(null) + 3);
                current_len = max(current_len, a.meter_data.current[0].value.format_float(null) + 1);
            }

            foreach (sub; c.sub_circuits)
                traverse(sub, indent + 2);
        }

        traverse(this.manager.main, 0);

        session.writef("{0, -*1}  {2, *3}  {4, *5}  {6, *7}  {8, *9}  {10, *11}  {'V', 6}  {'I', *12}  {'PF (ϕ)', 12}  {'FREQ', 6}\n",
                        "NAME", name_len,
                        "POWER", power_len,
                        "IMPORT", import_len, "EXPORT", export_len,
                        "APPARENT", apparent_len, "REACTIVE", reactive_len,
                        current_len);

        foreach (ref l; lines[0..i])
        {
            session.writef("{'', *17}{0, -*1}  {2, *3}  {4, *5}kWh  {6, *7}kWh  {8, *9}VA  {10, *11}var  {12, 5.4}  {13, *14}  {@19, 12}  {16, 5.4}Hz\n",
                            l.id, name_len - l.indent,
                            l.data.active[0], power_len-1,
                            l.data.total_import_active[0] * 0.001f, import_len-3, l.data.total_export_active[0] * 0.001f, export_len-3,
                            l.data.apparent[0], apparent_len-2, l.data.reactive[0], reactive_len-3,
                            l.data.voltage[0], l.data.current[0], current_len-2,
                            l.data.pf[0], l.data.freq, l.indent, l.data.phase[0]*360, "{15, 4.2} ({18, .3}°)");
            if (l.appliance)
            {
                if(Inverter inverter = l.appliance.as!Inverter)
                {
                    // show the MPPT's?
                    foreach (mppt; inverter.mppt)
                    {
                        MeterData mppt_data = getMeterData(mppt);
                        float soc;
                        bool has_soc = false;
                        const(char)[] name = mppt.id[];
                        if (mppt.template_[] == "Battery")
                        {
                            if (Element* soc_el = mppt.find_element("soc"))
                            {
                                soc = soc_el.value.asFloat();
                                has_soc = true;
                            }
                        }
                        if (mppt.template_[] == "Solar")
                        {
                            // anything special?
                        }
                        session.writef("{'', *10}{0, -*1}  {@3,?2}{'    ',!2}  {5}  {6}  {7} ({8}kWh/{9}kWh)\n", name, name_len - l.indent - 7, has_soc, "{4, 3}%  ", soc, 
                                        mppt_data.active[0], mppt_data.voltage[0], mppt_data.current[0], mppt_data.total_import_active[0] * 0.001f, mppt_data.total_export_active[0] * 0.001f, l.indent + 2);
                    }
                }
                else if (EVSE evse = l.appliance.as!EVSE)
                {
                    if (evse.connectedCar)
                        session.writef("{'', *3}{0, -*1}  {2}\n", evse.connectedCar.id, name_len - l.indent - 4, evse.connectedCar.vin, l.indent + 2);
                }
            }
        }

        if (lines !is line_cache[])
            defaultAllocator().freeArray(lines);
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

                        MeterData mppt_data = getMeterData(mppt);
                        json ~= ',';
                        append_meter_data(mppt_data, json);

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
