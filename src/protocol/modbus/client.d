module protocol.modbus.client;

import urt.lifetime;
import urt.string;

import protocol.modbus;

import router.iface;


class ModbusClient
{
	ModbusProtocolModule.Instance m;

	String name;
	BaseInterface iface;

	this(ModbusProtocolModule.Instance m, String name, BaseInterface _interface) nothrow @nogc
	{
		this.m = m;
		this.name = name.move;
		this.iface = _interface;

		_interface.subscribe(&incomingPacket, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.Modbus));
	}

	void incomingPacket(ref const Packet p, BaseInterface i) nothrow @nogc
	{
		assert(false);
	}
}
