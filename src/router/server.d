module router.server;

import std.datetime : Duration, MonoTime, msecs;
import std.stdio;

import db.value;

import util.log;


enum ServerType : uint
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

	ValueDesc*[] readValues() const { return null; }
	Value[] writeValues() const { return null; }

	override string toString() const
	{
		import std.format;
		return format("%s", cast(void*)this);
	}
}

class Response
{
	RequestStatus status;
	Server server;
	Request request;

	Value[] values() const { return null; }

	override string toString() const
	{
		import std.format;

		assert(request);

		if (status == RequestStatus.Timeout)
			return format("%s: TIMEOUT (%s)", cast(void*)this, server.name);
		else if (status == RequestStatus.Error)
			return format("%s: ERROR (%s)", cast(void*)this, server.name);
		return format("%s: RESPONSE (%s) - ", request, server.name, values);
	}
}


class Server
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

		for (size_t i = 0; i < pendingRequests.length; )
		{
			if (pendingRequests[i].request.requestTime + requestTimeout < now)
			{
				debug writeDebug("requestTimeout: ", cast(void*)pendingRequests[i].request, " - elapsed: ", now - pendingRequests[i].request.requestTime);

				Request request = pendingRequests[i].request;
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;

				Response response = new Response();
				response.status = RequestStatus.Timeout;
				response.server = this;
				response.request = request;

				request.responseHandler(response);
			}
			else
				++i;
		}
	}

	string name;
	ServerType devType;
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

class ModbusServer : Server
{
	this(string name, Connection connection, ubyte address, const ModbusProfile* profile = null)
	{
		super(name);
		devType = ServerType.Modbus;
		requestTimeout = connection.connParams.timeoutThreshold.msecs;
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
			debug writeDebug("forwardModbusMessage: ", name, " --> ", request);

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

	const(ModbusProfile)* profile;

private:
	Connection connection;
	ubyte address;

//	RegValue[int] regValues;

	void receiveResponsePacket(Packet packet, ushort requestId, MonoTime time)
	{
		Request request = popPendingRequest(requestId);
		if (!request)
		{
			debug writeDebug("discardResponse (no pending request): ", requestId, packet);
			return;
		}

		debug writeDebug("receiveResponse: ", requestId, ", ", packet);

		ModbusResponse response = new ModbusResponse();
		response.status = RequestStatus.Success;
		response.server = this;
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
		return format("%s: %s::%s", super.toString(), frame.toString, pdu.toString);
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
			return format("<-- %s :: REQUEST TIMEOUT", server.name);
		return format("<-- %s :: %s", server.name, pdu.toString);
	}
}
