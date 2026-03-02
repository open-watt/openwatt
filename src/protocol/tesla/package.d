module protocol.tesla;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.collection;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.tesla.iface;
import protocol.tesla.master;
import protocol.tesla.sampler;

import router.iface;
import router.iface.mac;

nothrow @nogc:


struct DeviceMap
{
    String name;
    MACAddress mac;
    ushort address;
    TeslaInterface iface;
}

class TeslaProtocolModule : Module
{
    mixin DeclareModule!"protocol.tesla";
nothrow @nogc:

    Collection!TeslaInterface twc_interfaces;
    Map!(const(char)[], TeslaTWCMaster) twc_masters;
    Map!(ushort, DeviceMap) devices;

    override void init()
    {
        g_app.console.register_collection("/interface/tesla-twc", twc_interfaces);
        g_app.console.register_command!twc_add("/protocol/tesla/twc", this, "add");
        g_app.console.register_command!twc_set("/protocol/tesla/twc", this, "set");
        g_app.console.register_command!device_add("/protocol/tesla/twc/device", this, "add");
    }

    override void update()
    {
        twc_interfaces.update_all();
        foreach(m; twc_masters.values)
            m.update();
    }

        DeviceMap* find_server_by_name(const(char)[] name)
    {
        foreach (ref map; devices.values)
        {
            if (map.name[] == name[])
                return &map;
        }
        return null;
    }

    DeviceMap* find_server_by_mac(MACAddress mac)
    {
        foreach (ref map; devices.values)
        {
            if (map.mac == mac)
                return &map;
        }
        return null;
    }

    DeviceMap* find_server_by_address(ushort address)
    {
        return address in devices;
    }

    DeviceMap* add_device(const(char)[] name, TeslaInterface iface, ushort address)
    {
        if (!name)
            name = tformat("{0}.{1,04X}", iface.name[], address);

        DeviceMap map;
        map.name = name.makeString(defaultAllocator());
        map.address = address;
        map.mac = iface.generate_mac_address();
        map.mac.b[4] = address >> 8;
        map.mac.b[5] = address & 0xFF;
//        while (find_mac_address(map.mac) !is null)
//            ++map.mac.b[5];
        map.iface = iface;

        iface.add_address(map.mac, iface);
        return devices.insert(address, map);
    }

    DeviceMap* add_server(const(char)[] name, BaseInterface iface, ushort address)
    {
        DeviceMap map;
        map.name = name.makeString(defaultAllocator());
        map.address = address;
        map.mac = iface.mac;
//        map.iface = iface;
        return devices.insert(address, map);
    }

    void twc_add(Session session, const(char)[] name, const(char)[] _interface, ushort id, float max_current)
    {
        auto mod_if = get_module!InterfaceModule;

        BaseInterface i = mod_if.interfaces.get(_interface);
        if(i is null)
        {
            session.write_line("Interface '", _interface, "' not found");
            return;
        }

        TeslaTWCMaster master;
        foreach (m; twc_masters.values)
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
            twc_masters[master.name[]] = master;
        }

        String n = name.makeString(defaultAllocator());

        master.add_charger(n.move, id, cast(ushort)(max_current * 100));
    }

    void twc_set(Session session, const(char)[] name, float target_current)
    {
        foreach (m; twc_masters.values)
        {
            if (m.set_target_current(name, cast(ushort)(target_current * 100)) >= 0)
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
            session.write_line("Device '", id, "' already exists");
            return;
        }

        if ((mac && slave_id) || (!mac && !slave_id))
        {
            session.write_line("Must specify either mac or slave-id");
            return;
        }

        // create the device
        Device device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
        if (name)
            device.name = name.value.makeString(g_app.allocator);

        // create a sampler for this modbus server...
        TeslaTWCSampler sampler = g_app.allocator.allocT!TeslaTWCSampler(cast(ushort)(slave_id ? slave_id.value : 0), mac ? mac.value : MACAddress());
        device.samplers ~= sampler;

        Component c;
        Element* e;

        import urt.mem.string;

        // device info
        c = g_app.allocator.allocT!Component(String("info".addString));
        c.template_ = "DeviceInfo".addString;

        e = g_app.allocator.allocT!Element();
        e.id = "type".addString;
        e.value = "evse";
        e.sampling_mode = SamplingMode.constant;
        c.elements ~= e;

        e = g_app.allocator.allocT!Element();
        e.id = "name".addString;
        e.value = "Tesla Wall Charger Gen2";
        e.sampling_mode = SamplingMode.constant;
        c.elements ~= e;

        e = g_app.allocator.allocT!Element();
        e.id = "serial_number".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "lifetime_energy".addString;
        c.elements ~= e;
        sampler.add_element(e);

        // HACK: remove this, move to car component...
        e = g_app.allocator.allocT!Element();
        e.id = "vin".addString;
        c.elements ~= e;
        sampler.add_element(e);

        device.components ~= c;

        // charge control
        c = g_app.allocator.allocT!Component(String("charge_control".addString));
        c.template_ = "ChargeControl".addString;

        e = g_app.allocator.allocT!Element();
        e.id = "state".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "twc_state".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "target_current".addString;
        e.access = Access.read_write;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "max_current".addString;
        c.elements ~= e;
        sampler.add_element(e);

        device.components ~= c;

//        // car
//        c = g_app.allocator.allocT!Component(String("car".addString));
//        c.template_ = "Car".addString;
//
//        e = g_app.allocator.allocT!Element();
//        e.id = "vin".addString;
//        c.elements ~= e;
//        sampler.add_element(e);
//
//        device.components ~= c;

        // energy meter
        c = g_app.allocator.allocT!Component(String("meter".addString));
        c.template_ = "EnergyMeter".addString;

        e = g_app.allocator.allocT!Element();
        e.id = "type".addString;
        e.value = "three-phase".addString;
        e.sampling_mode = SamplingMode.constant;
        c.elements ~= e;

        e = g_app.allocator.allocT!Element();
        e.id = "voltage1".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "voltage2".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "voltage3".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "current".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power1".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power2".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power3".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "power".addString;
        c.elements ~= e;
        sampler.add_element(e);

        e = g_app.allocator.allocT!Element();
        e.id = "import".addString;
        c.elements ~= e;
        sampler.add_element(e);

        device.components ~= c;

        g_app.devices.insert(device.id[], device);
    }
}
