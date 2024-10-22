module protocol.tesla;

import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.tesla.master;
import protocol.tesla.sampler;

import router.iface;
import router.iface.mac;
import router.iface.tesla;


class TeslaProtocolModule : Plugin
{
	mixin RegisterModule!"protocol.tesla";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		Map!(const(char)[], TeslaTWCMaster) twcMasters;

		override void init()
		{
			app.console.registerCommand!twc_add("/protocol/tesla/twc", this, "add");
			app.console.registerCommand!twc_set("/protocol/tesla/twc", this, "set");
			app.console.registerCommand!device_add("/protocol/tesla/twc/device", this, "add");
		}

		override void update()
		{
			foreach(_, m; twcMasters)
				m.update();
		}

		void twc_add(Session session, const(char)[] name, const(char)[] _interface, ushort id, float max_current) nothrow @nogc
		{
			auto mod_if = app.moduleInstance!InterfaceModule;

			BaseInterface i = mod_if.findInterface(_interface);
			if(i is null)
			{
				session.writeLine("Interface '", _interface, "' not found");
				return;
			}

            TeslaTWCMaster master;
            foreach (_, m; twcMasters)
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

        void twc_set(Session session, const(char)[] name, float target_current) nothrow @nogc
        {
            auto mod_if = app.moduleInstance!TeslaInterfaceModule;

            foreach (_, m; twcMasters)
            {
                if (m.setTargetCurrent(name, cast(ushort)(target_current * 100)) >= 0)
                    return;
            }
        }

        void device_add(Session session, const(char)[] id, Nullable!MACAddress mac, Nullable!ushort slave_id, Nullable!(const(char)[]) name) nothrow @nogc
        {
            import manager.component;
            import manager.device;
            import manager.element;
            import manager.value;

            if (id in app.devices)
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
            Device* device = app.allocator.allocT!Device();
            device.id = id.makeString(app.allocator);
            if (name)
                device.name = name.value.makeString(app.allocator);

            // create a sampler for this modbus server...
            TeslaTWCSampler sampler = app.allocator.allocT!TeslaTWCSampler(this, cast(ushort)(slave_id ? slave_id.value : 0), mac ? mac.value : MACAddress());
            device.samplers ~= sampler;

            Component* c;
            Element* e;

            import urt.mem.string;

            // device info
            c = app.allocator.allocT!Component();

            c.id = "info".addString;
            c.template_ = "DeviceInfo".addString;

            e = app.allocator.allocT!Element();
            e.id = "deviceName".addString;
            e.latest = Value("Tesla Wall Charger Gen2");
            c.elements ~= e;

            e = app.allocator.allocT!Element();
            e.id = "serialNumber".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "lifetimeEnergy".addString;
            e.unit = "kWh".addString;
            c.elements ~= e;
            sampler.addElement(e);

            device.components ~= c;

            // charge control
            c = app.allocator.allocT!Component();

            c.id = "control".addString;
            c.template_ = "ChargeControl".addString;

            e = app.allocator.allocT!Element();
            e.id = "state".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "targetCurrent".addString;
            e.unit = "10mA".addString;
            e.access = Access.ReadWrite;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "maxCurrent".addString;
            e.unit = "10mA".addString;
            c.elements ~= e;
            sampler.addElement(e);

            device.components ~= c;

            // car
            c = app.allocator.allocT!Component();

            c.id = "car".addString;
            c.template_ = "Car".addString;

            e = app.allocator.allocT!Element();
            e.id = "vin".addString;
            c.elements ~= e;
            sampler.addElement(e);

            device.components ~= c;

            // energy meter
            c = app.allocator.allocT!Component();

            c.id = "meter".addString;
            c.template_ = "RealtimeEnergyMeter".addString;

            e = app.allocator.allocT!Element();
            e.id = "voltage1".addString;
            e.unit = "V".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "voltage2".addString;
            e.unit = "V".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "voltage3".addString;
            e.unit = "V".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "current".addString;
            e.unit = "10mA".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "activePower1".addString;
            e.unit = "W".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "activePower2".addString;
            e.unit = "W".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "activePower3".addString;
            e.unit = "W".addString;
            c.elements ~= e;
            sampler.addElement(e);

            e = app.allocator.allocT!Element();
            e.id = "totalPower".addString;
            e.unit = "W".addString;
            c.elements ~= e;
            sampler.addElement(e);

            device.components ~= c;

            app.devices.insert(device.id, device);
        }
    }
}
