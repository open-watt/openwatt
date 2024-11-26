module apps.energy;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;

import apps.energy.appliance;
import apps.energy.circuit;
import apps.energy.manager;
import apps.energy.meter;

import manager.component;
import manager.device;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.element;
import manager.plugin;

nothrow @nogc:



class EnergyAppModule : Plugin
{
    mixin RegisterModule!"apps.energy";

    class Instance : Plugin.Instance
    {
        mixin DeclareInstance;
    nothrow @nogc:

        Map!(const(char)[], Appliance function(String id, EnergyManager* manager) nothrow @nogc) applianceFactory;

        EnergyManager* manager;

        override void init()
        {
            registerApplianceType!Inverter();
            registerApplianceType!EVSE();
            registerApplianceType!Car();
            registerApplianceType!AirCon();
            registerApplianceType!WaterHeater();

            manager = defaultAllocator.allocT!EnergyManager();

            app.console.registerCommand!circuit_add("/apps/energy/circuit", this, "add");
            app.console.registerCommand!circuit_print("/apps/energy/circuit", this, "print");

            app.console.registerCommand!appliance_add("/apps/energy/appliance", this, "add");
        }

        void registerApplianceType(ApplianceType)()
        {
            applianceFactory.insert(ApplianceType.Type, (String id, EnergyManager* manager) => cast(Appliance)defaultAllocator().allocT!ApplianceType(id.move, manager));
        }
        Appliance createAppliance(const char[] type, String id, EnergyManager* manager)
        {
            if (auto fn = type in applianceFactory)
                return (*fn)(id.move, manager);
            return null;
        }

        override void update()
        {
            manager.update();
        }

        void circuit_add(Session session, const(char)[] name, Nullable!(const(char)[]) parent, Nullable!(const(char)[]) meter, Nullable!(uint) max_current)
        {
            Component m;
            if (meter)
            {
                m = app.findComponent(meter.value);
                if (!m)
                {
                    session.writeLine("Meter '", meter.value, "' not found");
                    return;
                }
            }

            Circuit* p;
            if (parent)
            {
                p = manager.findCircuit(parent.value);
                if (!p)
                {
                    session.writeLine("Circuit '", parent.value, "' not found");
                    return;
                }
            }

            manager.addCircuit(name.makeString(app.allocator), p, max_current ? max_current.value : 0, m);
        }

        void appliance_add(Session session, const(char)[] id, Nullable!(Device) device, Nullable!(const(char)[]) _type, Nullable!(const(char)[]) name, Nullable!(const(char)[]) circuit, Nullable!(int) priority, Nullable!Component meter, Nullable!(const(char)[]) vin, Nullable!Component _info, Nullable!Component control, Nullable!(Component[]) mppt, Nullable!Component backup, Nullable!Component battery)
        {
            const(char)[] type = _type ? _type.value : null;
            Component info = _info ? _info.value : null;

            if (device)
            {
                if (!info)
                    info = device.value.getFirstComponentByTemplate("DeviceInfo");
            }
            if (!type && info)
            {
                if (Element* infoEl = info.findElement("deviceType"))
                    type = infoEl.value.getString();
                if (!type)
                {
                    session.writeLine("No appliance type for '", id, "'");
                    return;
                }
            }

            Appliance appliance = createAppliance(type, id.makeString(app.allocator), manager);
            if (!appliance)
            {
                session.writeLine("Couldn't create appliance of type '", type, "'");
                return;
            }

            appliance.name = name ? name.value.makeString(app.allocator) : String();
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
                    if (mppt)
                        a.mppt ~= mppt.value;

                    // TODO: dummy meter stuff...
                    break;

                case "evse":
                    EVSE a = cast(EVSE)appliance;

                    if (control)
                        a.control = control.value;
                    else if (device)
                        a.control = device.value.findComponent("control");
                    break;

                case "car":
                    Car a = cast(Car)appliance;

                    if (battery)
                        a.battery = battery.value;
                    if (control)
                        a.control = control.value;
                    if (vin)
                        a.vin = vin.value.makeString(app.allocator);
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
                    session.writeLine("Circuit '", circuit.value, "' not found");
                    return;
                }
                c = *t;
            }

            manager.addAppliance(appliance, c);
        }

        // /apps/energy/print command
        void circuit_print(Session session)
        {
            import urt.conv : formatFloat;
            import urt.util;

            import manager.element;
            import manager.units;

            struct Line
            {
                Appliance appliance;
                ubyte indent;
                const(char)[] id;
                MeterData* data;
            }

            Line[20] lineCache = void;
            Line[] lines;
            size_t numLines = this.manager.circuits.length*2 + this.manager.appliances.length;
            if (numLines > 20)
                lines = defaultAllocator().allocArray!Line(numLines);
            else
            {
                lines = lineCache[0 .. numLines];
                lines[] = Line();
            }

            size_t i = 0;
            size_t nameLen = 4;
            size_t powerLen = 5;
            size_t importLen = 6;
            size_t exportLen = 6;
            size_t apparentLen = 8;
            size_t reactiveLen = 8;
            size_t currentLen = 1;

            void traverse(Circuit* c, uint indent)
            {
                Line* circuit = &lines[i++];
                circuit.indent = cast(ubyte)indent;
                circuit.id = c.id[];
                circuit.data = &c.meterData;

                nameLen = max(nameLen, circuit.indent + c.id.length);
                powerLen = max(powerLen, c.meterData.active[0].formatFloat(null) + 1);
                importLen = max(importLen, c.meterData.totalImportActive[0].formatFloat(null) + 3);
                exportLen = max(exportLen, c.meterData.totalExportActive[0].formatFloat(null) + 3);
                apparentLen = max(apparentLen, c.meterData.apparent[0].formatFloat(null) + 2);
                reactiveLen = max(reactiveLen, c.meterData.reactive[0].formatFloat(null) + 3);
                currentLen = max(currentLen, c.meterData.current[0].formatFloat(null) + 1);

                Line* unknown;
                bool hasLeftover = c.meter && (c.appliances.length != 0 || c.subCircuits.length != 0);
                if (hasLeftover)
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
                    line.data = &a.meterData;

                    nameLen = max(nameLen, line.indent + a.id.length);
                    powerLen = max(powerLen, a.meterData.active[0].formatFloat(null) + 1);
                    importLen = max(importLen, a.meterData.totalImportActive[0].formatFloat(null) + 3);
                    exportLen = max(exportLen, a.meterData.totalExportActive[0].formatFloat(null) + 3);
                    apparentLen = max(apparentLen, a.meterData.apparent[0].formatFloat(null) + 2);
                    reactiveLen = max(reactiveLen, a.meterData.reactive[0].formatFloat(null) + 3);
                    currentLen = max(currentLen, a.meterData.current[0].formatFloat(null) + 1);
                }

                foreach (sub; c.subCircuits)
                    traverse(sub, indent + 2);
            }

            traverse(this.manager.main, 0);

            session.writef("{0, -*1}  {2, *3}  {4, *5}  {6, *7}  {8, *9}  {10, *11}  {'V', 6}  {'I', *12}  {'PF (ϕ)', 12}  {'FREQ', 6}\n",
                            "NAME", nameLen,
                            "POWER", powerLen,
                            "IMPORT", importLen, "EXPORT", exportLen,
                            "APPARENT", apparentLen, "REACTIVE", reactiveLen,
                            currentLen);

            foreach (ref l; lines[0..i])
            {
                session.writef("{'', *17}{0, -*1}  {2, *3}W  {4, *5}kWh  {6, *7}kWh  {8, *9}VA  {10, *11}var  {12, 5.4}V  {13, *14}A  {@19, 12}  {16, 5.4}Hz\n",
                               l.id, nameLen - l.indent,
                               l.data.active[0], powerLen-1,
                               l.data.totalImportActive[0] * 0.001f, importLen-3, l.data.totalExportActive[0] * 0.001f, exportLen-3,
                               l.data.apparent[0], apparentLen-2, l.data.reactive[0], reactiveLen-3,
                               l.data.voltage[0], l.data.current[0], currentLen-2,
                               l.data.pf[0], l.data.freq, l.indent, l.data.phase[0]*360, "{15, 4.2} ({18, .3}°)");
                if (l.appliance)
                {
                    if(Inverter inverter = l.appliance.as!Inverter)
                    {
                        // show the MPPT's?
                        foreach (mppt; inverter.mppt)
                        {
                            MeterData mpptData = getMeterData(mppt);
                            float soc;
                            bool hasSoc = false;
                            string name = "mppt";
                            if (mppt.template_[] == "Battery")
                            {
                                name = "battery";
                                if (Element* socEl = mppt.findElement("soc"))
                                {
                                    soc = socEl.value.asFloat();
                                    hasSoc = true;
                                }
                            }
                            session.writef("{'', *10}{0, -*1}  {@3,?2}  {5}W  {6}V  {7}A ({8}kWh/{9}kWh)\n", name, nameLen - l.indent - 7, hasSoc, "{4, 3}%  ", soc, 
                                           mpptData.active[0], mpptData.voltage[0], mpptData.current[0], mpptData.totalImportActive[0] * 0.001f, mpptData.totalExportActive[0] * 0.001f, l.indent + 2);
                        }
                    }
                    else if (EVSE evse = l.appliance.as!EVSE)
                    {
                        if (evse.connectedCar)
                            session.writef("{'', *3}{0, -*1}  {2}\n", evse.connectedCar.id, nameLen - l.indent - 4, evse.connectedCar.vin, l.indent + 2);
                    }
                }
            }

            if (lines !is lineCache[])
                defaultAllocator().freeArray(lines);
        }
    }
}


