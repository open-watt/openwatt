module router.device;

import std.datetime : Duration, MonoTime, msecs;
import std.stdio;

import db.value;


enum DeviceType : uint
{
	Modbus = 0x00F0D805,
}

enum RequestStatus
{
	Success,
	Pending,
	Timeout,
	Error
};

class Request
{
	alias ResponseHandler = void delegate(Response response);

	MonoTime requestTime;
	ResponseHandler responseHandler;

	this(ResponseHandler responseHandler)
	{
		this.responseHandler = responseHandler;
	}

	ValueDesc*[] readValues() { return null; }
	Value[] writeValues() { return null; }

	override string toString() const
	{
		import std.format;
		assert(0, "TODO");
		//		return format("%s --> :: %s", packet[]);
	}
}

class Response
{
	RequestStatus status;
	Device device;
	Request request;

	Value[] values() { return null; }

	override string toString() const
	{
		import std.format;

		assert(request);

		if (status == RequestStatus.Timeout)
			return format("<-- %s :: REQUEST TIMEOUT", device.name);
		assert(0, "TODO");
//		return format("%s <-- %s :: %s", request ? request.client.name : "", device.name, packet[]);
	}
}


class Device
{
	this(string name)
	{
		this.name = name;
	}

	bool linkEstablished()
	{
		return false;
	}

	bool sendRequest(Request request)
	{
		request.requestTime = MonoTime.currTime;

		// request data by high-level id
		return false;
	}

	void poll()
	{
		// check if any requests have timed out...
		MonoTime now = MonoTime.currTime;

		for (size_t i = 0; i < pendingRequests.length; ++i)
		{
			if (pendingRequests[i].request.requestTime + requestTimeout < now)
			{
				Request request = pendingRequests[i].request;
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;

				Response response = new Response();
				response.status = RequestStatus.Timeout;
				response.device = this;
				response.request = request;

				request.responseHandler(response);
			}
		}
	}

	string name;
	DeviceType devType;
	Duration requestTimeout;

private:
	PendingRequest[] pendingRequests;

	struct PendingRequest
	{
		ushort requestId;
		Request request;
	}

	Request popPendingRequest(ushort requestId)
	{
		if (pendingRequests.length == 0)
			return null;

		Request request = null;
		size_t i = 0;
		for (; i < pendingRequests.length; ++i)
		{
			if (pendingRequests[i].requestId == requestId)
			{
				request = pendingRequests[i].request;
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;
				return request;
			}
		}
		return null;
	}
}


// MODBUS
import router.modbus.connection;
import router.modbus.message;
import router.modbus.profile;

class ModbusDevice : Device
{
	this(string name, Connection connection, ubyte address, const ModbusProfile* profile = null)
	{
		super(name);
		devType = DeviceType.Modbus;
		requestTimeout = msecs(1000);
		this.connection = connection;
		this.address = address;
		this.profile = profile;

		assert(connection.connParams.mode == Mode.Slave);
	}

	override bool linkEstablished()
	{
		return connection.linkEstablished;
	}

	override bool sendRequest(Request request)
	{
		request.requestTime = MonoTime.currTime;

		ModbusRequest modbusRequest = cast(ModbusRequest)request;
		if (modbusRequest)
		{
			int x = 0;

			// forward the modbus frame if the profile matches...

			ushort requestId = connection.sendRequest(address, &modbusRequest.pdu, &receiveResponsePacket);
			if (requestId != cast(ushort)-1)
			{
				pendingRequests ~= PendingRequest(requestId, request);
				return true;
			}
		}

		// encode and send response
		//...
		assert(0);

		return false;
	}
/+
	bool forwardModbusRequest(Request* request)
	{
		assert(request.client.protocol == Protocol.Modbus);

		if (request.client.modbus.profile != modbus.profile &&
			request.client.modbus.profile && modbus.profile)
		{
			// TODO: if the profiles are mismatching, then we need to translate...
			assert(0);
		}

		return sendModbusRequest(&request.modbus.pdu, request);
	}

	bool sendModbusRequest(ModbusPDU* message, Request* request)
	{
		assert(protocol == Protocol.Modbus);

		return modbus.connection.sendRequest(modbus.address, message, request);
	}
+/
private:
	Connection connection;
	ubyte address;
	const(ModbusProfile)* profile;

//	RegValue[int] regValues;

	void receiveResponsePacket(Packet packet, ushort requestId, MonoTime time)
	{
		Request request = popPendingRequest(requestId);
		if (!request)
			return;

		ModbusResponse response = new ModbusResponse();
		response.status = RequestStatus.Success;
		response.device = this;
		response.request = request;
		response.frame = packet.frame;
		response.pdu = packet.pdu;

		request.responseHandler(response);
	}
}

class ModbusRequest : Request
{
	ModbusFrame frame;
	ModbusPDU pdu;

	this(ResponseHandler responseHandler, ModbusPDU* message, ubyte address = 0)
	{
		super(responseHandler);
		frame.address = address;
		pdu = *message;
	}

	override string toString() const
	{
		import std.format;
		return format("--> %s :: %s", frame.toString, pdu.toString);
	}
}

class ModbusResponse : Response
{
	ModbusFrame frame;
	ModbusPDU pdu;

	override string toString() const
	{
		import std.format;

		assert(request);

		if (status == RequestStatus.Timeout)
			return format("<-- %s :: REQUEST TIMEOUT", device.name);
		return format("<-- %s :: %s", device.name, pdu.toString);
	}
}
