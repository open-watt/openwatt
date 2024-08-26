module protocol.modbus.client;

import protocol.modbus;

import router.iface;


class ModbusClient
{
	ModbusProtocolModule.Instance m;

	BaseInterface iface;

	this(ModbusProtocolModule.Instance m, const(char)[] iface)
	{
		this.m = m;
		this.iface = m.app.moduleInstance!InterfaceModule().findInterface(iface);
	}

	// TODO: place modbus request...

}
