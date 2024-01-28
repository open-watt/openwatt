module router.client;

import std.datetime : Duration, MonoTime, msecs;

import db.value;
import router.server;


class Client
{
	this(string name)
	{
		this.name = name;
	}

	bool linkEstablished()
	{
		return false;
	}

	void sendResponse(Response response)
	{
		// send response
		//...
	}

	Request poll()
	{
		return null;
	}

public:
	string name;

	ServerType devType;
}


// MODBUS
import router.modbus.connection;
import router.modbus.message;
import router.modbus.profile;
class ModbusClient : Client
{

	this(string name, Connection connection)
	{
		super(name);
		devType = ServerType.Modbus;
		connection = connection;

		assert(connection.connParams.mode == Mode.Master);
		connection.connParams.unsolicitedPacketHandler = &receiveRequest;
	}

	override Request poll()
	{
		if (pendingRequests.length == 0)
			return null;
		Request r = pendingRequests[0];
		pendingRequests = pendingRequests[1..$];
		return r;
	}

	override void sendResponse(Response response)
	{
		// TODO: see if this response matches a pending request...

		ModbusResponse modbusResponse = cast(ModbusResponse)response;
		if (modbusResponse)
		{
			ModbusServer modbusServer = cast(ModbusServer)response.server;
			ModbusRequest modbusRequest = cast(ModbusRequest)response.request;
			assert(modbusServer && modbusRequest);

			// forward the modbus frame if the profile matches...
//			if (response.server.modbus.profile != modbus.profile &&
//				response.server.modbus.profile && modbus.profile)
			if (false) // TODO: how to properly match profile?
			{
				// TODO: if the profiles are mismatching, then we need to translate...
				assert(0);
			}

			ptrdiff_t r = connection.sendMessage(modbusRequest.frame.address, &modbusResponse.pdu, modbusRequest.frame.protocol == ModbusProtocol.TCP ? modbusRequest.frame.tcp.transactionId : 0);
		}

		// format and send response
		//...
	}

private:
	Connection connection;

	// TODO: each server address needs a profile...
	// maybe we can create a client with an address->profile map?
	// or is the map external and something to do with the router perhaps?
//	const(ModbusProfile)* profile;

	ModbusRequest[] pendingRequests;

	void receiveRequest(Packet packet, ushort requestId, MonoTime time)
	{
		ModbusRequest req = new ModbusRequest(&sendResponse, &packet.pdu);
		req.requestTime = time;
		req.frame = packet.frame;
		pendingRequests ~= req;
	}
}
