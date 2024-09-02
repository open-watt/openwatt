module protocol.modbus;

import urt.map;
import urt.mem;
import urt.string;

import manager.console.session;
import manager.plugin;
import protocol.modbus.client;
import router.iface;


struct ModbusEndpoint
{
	String name;
	Interface busInterface;
	MACAddress macAddress;
	ubyte localAddress;
	ubyte universalAddress;
}


class ModbusProtocolModule : Plugin
{
	mixin RegisterModule!"protocol.modbus";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		Map!(const(char)[], ModbusClient) clients;
//		Server[string] servers;

		override void init()
		{
			app.console.registerCommand!add_client("/protocol/modbus/client", this, "add");
		}

		override void update()
		{
//			foreach(client; clients)
//				client.update();
		}

		void add_client(Session session, const(char)[] name, const(char)[] _interface)
		{
			auto mod_if = app.moduleInstance!InterfaceModule;
			BaseInterface i = mod_if.findInterface(_interface);
			if(i is null)
			{
				session.writeLine("Interface '", _interface, "' not found");
				return;
			}

			String n = name.makeString(defaultAllocator());

			ModbusClient client = defaultAllocator().allocT!ModbusClient(this, n.move, i);
			clients[client.name[]] = client;
		}
	}
}
