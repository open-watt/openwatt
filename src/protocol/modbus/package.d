module protocol.modbus;

import urt.string;

import manager.plugin;

import router.iface;


struct ModbusEndpoint
{
	String name;
	Interface busInterface;
	MACAddress macAddress;
	ubyte localAddress;
}




class ModbusProtocolModule : Plugin
{
	mixin RegisterModule!"protocol.modbus";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

//		Server[string] servers;

		override void init()
		{
//			app.console.registerCommand("/interface", new InterfaceCommand(app.console, this));
		}
	}
}
