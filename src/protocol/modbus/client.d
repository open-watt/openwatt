module protocol.modbus.client;

import urt.lifetime;
import urt.string;
import urt.time;

import protocol.modbus;

import router.iface;
import router.modbus.message;


alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, MonoTime responseTime);

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

	void sendRequest(ref const MACAddress server, ref const ModbusPDU request, ModbusResponseHandler responseHandler)
	{
		pending ~= PendingRequest(getTime(), request, server);
		PendingRequest* r = &pending[$-1];

		// format packet and transmit...

		void[] msg = (cast(void*)&request)[0 .. 1 + request.length];
		iface.send(server, msg, EtherType.ENMS, ENMS_SubType.Modbus);
	}

private:
	struct PendingRequest
	{
		MonoTime requestTime;
		ModbusPDU request;
		MACAddress server;
	}

	PendingRequest[] pending;

	void incomingPacket(ref const Packet p, BaseInterface i) nothrow @nogc
	{
		assert(false);
	}
}
