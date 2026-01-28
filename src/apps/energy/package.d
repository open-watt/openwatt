module apps.energy;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;

import apps.energy.appliance;
import apps.energy.circuit;
import apps.energy.manager;
import apps.energy.meter;

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

        registerApplianceType!Inverter();
        registerApplianceType!EVSE();
        registerApplianceType!Car();
        registerApplianceType!AirCon();
        registerApplianceType!WaterHeater();

        manager = defaultAllocator.allocT!EnergyManager();

        g_app.console.register_command!circuit_add("/apps/energy/circuit", this, "add");
        g_app.console.register_command!circuit_print("/apps/energy/circuit", this, "print");

        g_app.console.register_command!appliance_add("/apps/energy/appliance", this, "add");
    }

    void registerApplianceType(ApplianceType)()
    {
        appliance_factory.insert(ApplianceType.Type, (String id, EnergyManager* manager) => cast(Appliance)defaultAllocator().allocT!ApplianceType(id.move, manager));
    }
    Appliance create_appliance(const char[] type, String id, EnergyManager* manager)
    {
        if (auto fn = type in appliance_factory)
            return (*fn)(id.move, manager);
        return null;
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

        if (device)
        {
            if (!info)
                info = device.value.get_first_component_by_template("DeviceInfo");
        }
        if (!type && info)
        {
            if (Element* infoEl = info.find_element("type"))
                type = infoEl.value.asString();
            if (!type)
            {
                session.write_line("No appliance type for '", id, "'");
                return;
            }
        }

        Appliance appliance = create_appliance(type, id.makeString(g_app.allocator), manager);
        if (!appliance)
        {
            session.write_line("Couldn't create appliance of type '", type, "'");
            return;
        }

        appliance.name = name ? name.value.makeString(g_app.allocator) : String();
        appliance.info = info;
        appliance.init(device ? device.value : null);

        appliance.meter = meter ? meter.value : null;
        appliance.priority = priority ? priority.value : int.max;

        // TODO: delete this, move it all into init functions...
        switch (type)
        {
            case "inverter":
                Inverter a = cast(Inverter)appliance;

                if (control)
                    a.control = control.value;
                if (backup)
                    a.backup = backup.value;
                if (battery)
                    a.mppt ~= battery.value;
                if (mppt) foreach (pv; mppt.value)
                    a.mppt ~= pv;

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

            case "ac":
                AirCon a = cast(AirCon)appliance;

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
}


