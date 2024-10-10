module protocol.tesla;

import urt.map;
import urt.mem;
import urt.string;
import urt.string.format;
import urt.time;

import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;
import protocol.tesla.master;
import router.iface;
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
	}
}
