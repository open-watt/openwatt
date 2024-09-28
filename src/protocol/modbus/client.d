module protocol.modbus.client;

import urt.lifetime;
import urt.string;
import urt.time;

import protocol.modbus;

import router.iface;
import router.modbus.message;


alias ModbusResponseHandler = void delegate(ref const ModbusPDU request, ref ModbusPDU response, MonoTime responseTime) nothrow @nogc;

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

    ~this()
    {
        // TODO: unsubscribe!
    }

	void sendRequest(ref const MACAddress server, ref const ModbusPDU request, ModbusResponseHandler responseHandler) nothrow
	{
		pending ~= PendingRequest(getTime(), request, server, responseHandler);
		PendingRequest* r = &pending[$-1];

        // send the packet
		void[] msg = (cast(void*)&request)[0 .. 1 + request.data.length];
		iface.send(server, msg, EtherType.ENMS, ENMS_SubType.Modbus);
	}

private:
	struct PendingRequest
	{
		MonoTime requestTime;
		ModbusPDU request;
		MACAddress server;
        ModbusResponseHandler responseHandler;
	}

	PendingRequest[] pending;

	void incomingPacket(ref const Packet p, BaseInterface iface, void* userData) nothrow @nogc
	{
        foreach (i, ref PendingRequest req; pending)
        {
            if (p.src != req.server)
                continue;

            // this appears to be the message we're waiting for!
            auto message = cast(const(ubyte)[])p.data[];
            ModbusPDU response = ModbusPDU(cast(FunctionCode)message[0], message[1 .. $]);
            req.responseHandler(req.request, response, p.creationTime);

            // HACK! remove the pending request...
            debug
                pending = pending[0 .. i] ~ pending[i + 1 .. $];
            return;
        }
	}
}
