module router.goodwe;

import manager;
import manager.config;
import manager.component;
import manager.device;
import manager.element;
import manager.plugin;

import router.goodwe.aa55;

import router.modbus.profile;

import urt.log;
import urt.mem.string;
import urt.string;

/+
class GoodWePlugin : Plugin
{
    mixin RegisterModule!"goodwe";

    ModbusPlugin modbus;

    int poo;

    class Instance : Plugin.Instance
    {
        mixin DeclareInstance;

        ModbusPlugin.Instance modbus;

        override void init()
        {
            modbus = get_module!ModbusPlugin;

            // register modbus component
            app.registerComponentType("goodwe-component", &createGoodWeComponent);
        }

        override void parseConfig(ref ConfItem conf)
        {
            import router.stream;

            foreach (ref gw; conf.subItems) switch (gw.name)
            {
                case "device":
                    string name;
                    const(char)[] host;
                    const(char)[] model;
                    ubyte address = 0xF7;

                    foreach (ref param; gw.subItems) switch (param.name)
                    {
                        case "name":
                            name = param.value.unQuote.idup;
                            break;

                        case "host":
                            host = param.value.unQuote;
                            break;

                        case "model":
                            model = param.value.unQuote;
                            break;

                        case "address":
                            address = param.value.to!ubyte;
                            break;

                        default:
                            writeln("Invalid token: ", param.name);
                    }

                    // TODO: load a profile based on the model...
//                    ModbusProfile* profile = plugin.getProfile(profileName);
//                    if (!profile)
//                    {
//                        // try and load profile...
//                        profile = loadModbusProfile("conf/modbus_profiles/" ~ profileName ~ ".conf");
//                    }

                    // TODO: all this should be warning messages, not asserts
                    // TODO: messages should have config file+line
//                    assert(profile);
/+
                    assert(name !in app.servers);
                    app.servers[name] = new GoodWeServer(name, host.idup);//, model, address);
+/
                    break;

                case "scan":
                    // TODO: implement device scanning...
                    break;

                default:
                    writeln("Invalid token: ", gw.name);
            }
        }

        Component* createGoodWeComponent(Device* device, ref ConfItem config)
        {
            const(char)[] id, name, server;
            foreach (ref com; config.subItems) switch (com.name)
            {
                case "id":
                    id = com.value.unQuote;
                    break;
                case "name":
                    name = com.value.unQuote;
                    break;
                case "server":
                    server = com.value.unQuote;
                    break;
                default:
                    writeln("Invalid token: ", com.name);
            }
/+
            Server* pServer = server in app.servers;
            // TODO: proper error message
            assert(pServer, "No server");

            GoodWeServer goodweServer = pServer ? cast(GoodWeServer)*pServer : null;
            // TODO: proper error message
            assert(goodweServer, "Not a GoodWe server");

            Component* component = new Component;
            component.id = addString(id);
            component.name = addString(name);
+/
//            if (goodweServer.profile)
//            {
//                // Create elements for each modbus register
//                Element[] elements = new Element[goodweServer.profile.registers.length];
//                component.elements = elements;
//
//                foreach (size_t i, ref const ModbusRegInfo reg; goodweServer.profile.registers)
//                {
//                    elements[i].id = reg.name;
//                    elements[i].name = reg.desc;
//                    elements[i].unit = reg.displayUnits;
//                    elements[i].method = Element.Method.Sample;
//                    elements[i].type = modbusRegTypeToElementTypeMap[reg.type]; // maybe some numeric values should remain integer?
//                    elements[i].arrayLen = 0;
//                    elements[i].sampler = new Sampler(goodweServer, cast(void*)&reg);
//                    elements[i].sampler.convert = unitConversion(reg.units, reg.displayUnits);
//                    elements[i].sampler.updateIntervalMs = updateIntervalMap[reg.updateFrequency];
//                    elements[i].sampler.lessThan = &elementLessThan;
//                }
//
//                // populate the id lookup table
//                foreach (ref Element element; component.elements)
//                    component.elementsById[element.id] = &element;
//            }

//            return component;
            return null;
        }
    }
}


private:

immutable uint[Frequency.max + 1] updateIntervalMap = [
    50,        // realtime
    1000,    // high
    10000,    // medium
    60000,    // low
    0,        // constant
    0,        // configuration
];

static bool elementLessThan(Sampler* a, Sampler* b)
{
    const ModbusRegInfo* areg = cast(ModbusRegInfo*)a.samplerData;
    const ModbusRegInfo* breg = cast(ModbusRegInfo*)b.samplerData;
    return areg.reg < breg.reg;
}
+/
