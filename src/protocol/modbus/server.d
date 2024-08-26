module protocol.modbus.server;

import protocol.modbus;

import router.iface;


class ModbusServer
{
	ModbusProtocolModule.Instance m;

	BaseInterface iface;

	this(ModbusProtocolModule.Instance m, const(char)[] iface)
	{
		this.m = m;
		this.iface = m.app.moduleInstance!InterfaceModule().findInterface(iface);
	}
}
