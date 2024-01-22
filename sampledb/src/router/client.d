module router.client;

import router.connection;
import router.device : Response;
import router.modbus.message : frameRTUMessage, frameTCPMessage, ModbusPDU, ModbusProtocol = Protocol;
import router.modbus.profile;
import router.serial : SerialParams;

class Client
{
	this(string name)
	{
		this.name = name;
	}

	bool createModbus(Connection connection, const ModbusProfile* profile = null)
	{
		this.connection = connection;

		protocol = Protocol.Modbus;
		modbus.profile = profile;

		return true;
	}

	bool createSerialModbus(string device, ref in SerialParams params, ubyte address, const ModbusProfile* profile = null)
	{
		connection = new Connection;
		connection.openSerialModbus(device, params, address);

		protocol = Protocol.Modbus;
		modbus.profile = profile;

		return true;
	}

	bool createEthernetModbus(string host, ushort port, EthernetMethod method, ubyte unitId, ModbusProtocol modbusProtocol = ModbusProtocol.Unknown, const ModbusProfile* profile = null)
	{
		connection = new Connection;
		connection.createEthernetModbus(host, port, method, unitId, modbusProtocol);

		protocol = Protocol.Modbus;
		modbus.profile = profile;

		return true;
	}

	bool linkEstablished()
	{
		return false;
	}

	bool sendResponse(Response* response)
	{
		// send response
		return false;
	}

	bool sendModbusResponse(Response* response)
	{
		assert(protocol == Protocol.Modbus);
		assert(response.device.protocol == Protocol.Modbus);

		if (response.device.modbus.profile != modbus.profile &&
			response.device.modbus.profile && modbus.profile)
		{
			// TODO: if the profiles are mismatching, then we need to translate...
			assert(0);
		}

		Request* request = response.request;

		ubyte[1024] buffer = void;
		ubyte[] packet;
		switch (connection.modbus.protocol)
		{
			case ModbusProtocol.RTU:
				packet = frameRTUMessage(request.packet.modbus.frame.rtu.address,
										 response.packet.modbus.message.functionCode,
										 response.packet.modbus.message.data,
										 buffer);
				break;
			case ModbusProtocol.TCP:
				packet = frameTCPMessage(request.packet.modbus.frame.tcp.transactionId,
										 request.packet.modbus.frame.tcp.unitId,
										 request.packet.modbus.message.functionCode,
										 request.packet.modbus.message.data,
										 buffer);
				break;
			default:
				assert(0);
		}

		connection.write(packet);

		// send formatted modbus response
		return true;
	}

	Request* poll()
	{
		Request* request = null;

		Packet packet;
		bool success = connection.poll(packet);
		if (success && packet.raw)
		{
			request = new Request;
			request.client = this;
			request.packet = packet;
		}

		return request;
	}

public:
	string name;
	Connection connection;

	Protocol protocol;
	union
	{
		Modbus modbus;
	}

private:
	struct Modbus
	{
		const(ModbusProfile)* profile;
	}
}

struct Request
{
	Client client;
	Packet packet;

	string toString() const
	{
		import router.modbus.message: getFunctionCodeName;
		import std.format;

		if (client.protocol == Protocol.Modbus)
		{
			return format("%s --> %s :: %s", client.name, packet.modbus.frame.toString, packet.modbus.message.toString);
		}

		return format("%s --> :: %s", packet.raw[]);
	}
}
