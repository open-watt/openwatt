module protocol.tesla;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.tesla.master;
import protocol.tesla.sampler;

import router.iface;
import router.iface.mac;
import router.iface.tesla;


class TeslaProtocolModule : Module
{
    mixin DeclareModule!"protocol.tesla";
nothrow @nogc:

    Map!(const(char)[], TeslaTWCMaster) twcMasters;

    override void init()
    {
        g_app.console.registerCommand!twc_add("/protocol/tesla/twc", this, "add");
        g_app.console.registerCommand!twc_set("/protocol/tesla/twc", this, "set");
        g_app.console.registerCommand!device_add("/protocol/tesla/twc/device", this, "add");
    }

    override void update()
    {
        foreach(m; twcMasters.values)
            m.update();
    }

    void twc_add(Session session, const(char)[] name, const(char)[] _interface, ushort id, float max_current)
    {
        auto mod_if = getModule!InterfaceModule;

        BaseInterface i = mod_if.interfaces.get(_interface);
        if(i is null)
        {
            session.writeLine("Interface '", _interface, "' not found");
            return;
        }

        TeslaTWCMaster master;
        foreach (m; twcMasters.values)
        {
            if (m.iface is i)
            {
                master = m;
                break;
            }
        }
        if (!master)
        {
            String n = tconcat(_interface, "_twc").makeString(defaultAllocator());

            master = defaultAllocator().allocT!TeslaTWCMaster(this, n.move, i);
            twcMasters[master.name[]] = master;
        }

        String n = name.makeString(defaultAllocator());

        master.addCharger(n.move, id, cast(ushort)(max_current * 100));
    }

    void twc_set(Session session, const(char)[] name, float target_current)
    {
        auto mod_if = getModule!TeslaInterfaceModule;

        foreach (m; twcMasters.values)
        {
            if (m.setTargetCurrent(name, cast(ushort)(target_current * 100)) >= 0)
                return;
        }
    }

    void device_add(Session session, const(char)[] id, Nullable!MACAddress mac, Nullable!ushort slave_id, Nullable!(const(char)[]) name)
    {
        import manager.component;
        import manager.device;
        import manager.element;

        if (id in g_app.devices)
        {
            session.writeLine("Device '", id, "' already exists");
            return;
        }

        if ((mac && slave_id) || (!mac && !slave_id))
        {
            session.writeLine("Must specify either mac or slave-id");
            return;
        }

        // create the device
        Device device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
        if (name)
            device.name = name.value.makeString(g_app.allocator);

        // create a sampler for this modbus server...
        TeslaTWCSampler sampler = g_app.allocator.allocT!TeslaTWCSampler(this, cast(ushort)(slave_id ? slave_id.value : 0), mac ? mac.value : MACAddress());
        device.samplers ~= sampler;

        Component c;
        Element* e;

        import urt.mem.string;

        // device info
        c = g_app.allocator.allocT!Component(String("info".addString));
        c.template_ = "DeviceInfo".addString;

        e = g_app.allocator.allocT!Element();
        e.id = "deviceType".addString;
        e.latest = "evse";
        c.elements ~= e;

        e = g_app.allocator.allocT!Element();
        e.id = "deviceName".addString;
        e.latest = "Tesla Wall Charger Gen2";
        c.elements ~= e;

        e = g_app.allocator.allocT!Element();
        e.id = "serialNumber".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "lifetimeEnergy".addString;
        c.elements ~= e;
        sampler.addElement(e);

        // HACK: remove this, move to car component...
        e = g_app.allocator.allocT!Element();
        e.id = "vin".addString;
        c.elements ~= e;
        sampler.addElement(e);

        device.components ~= c;

        // charge control
        c = g_app.allocator.allocT!Component(String("control".addString));
        c.template_ = "ChargeControl".addString;

        e = g_app.allocator.allocT!Element();
        e.id = "state".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "targetCurrent".addString;
        e.access = Access.ReadWrite;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "maxCurrent".addString;
        c.elements ~= e;
        sampler.addElement(e);

        device.components ~= c;

//        // car
//        c = g_app.allocator.allocT!Component(String("car".addString));
//        c.template_ = "Car".addString;
//
//        e = g_app.allocator.allocT!Element();
//        e.id = "vin".addString;
//        c.elements ~= e;
//        sampler.addElement(e);
//
//        device.components ~= c;

        // energy meter
        c = g_app.allocator.allocT!Component(String("realtime".addString));
        c.template_ = "RealtimeEnergyMeter".addString;

        e = g_app.allocator.allocT!Element();
        e.id = "type".addString;
        e.value = "three-phase".addString;
        c.elements ~= e;

        e = g_app.allocator.allocT!Element();
        e.id = "voltage1".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "voltage2".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "voltage3".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "current".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power1".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power2".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power3".addString;
        c.elements ~= e;
        sampler.addElement(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power".addString;
        c.elements ~= e;
        sampler.addElement(e);

        device.components ~= c;

        // cumulative energy meter
        c = g_app.allocator.allocT!Component(String("cumulative".addString));
        c.template_ = "CumulativeEnergyMeter".addString;

        e = g_app.allocator.allocT!Element();
        e.id = "type".addString;
        e.value = "three-phase".addString;
        c.elements ~= e;

        e = g_app.allocator.allocT!Element();
        e.id = "totalImportActiveEnergy".addString;
        c.elements ~= e;
        sampler.addElement(e);

        device.components ~= c;

        g_app.devices.insert(device.id, device);
    }
}
