module router.device;

import std.stdio;

import router.client : Request;
import router.connection;
import router.modbus.message : frameRTUMessage, frameTCPMessage, ModbusPDU, ModbusProtocol = Protocol;
import router.modbus.profile;
import router.serial : SerialParams;

enum RequestStatus
{
	Success,
	Pending,
	Timeout,
	Error
};

struct Response
{
	Device device;
	Request* request;
	Packet packet;
	RequestStatus status;

	string toString() const
	{
		import router.modbus.message: getFunctionCodeName;
		import std.format;

		if (status == RequestStatus.Timeout)
			return format("%s <-- %s :: REQUEST TIMEOUT", request ? request.client.name : "", device.name);
		if (device.protocol == Protocol.Modbus)
		{
			return format("%s <-- %s :: %s", request ? request.client.name : "", device.name, packet.modbus.message.toString);
		}
		return format("%s <-- %s :: %s", request ? request.client.name : "", device.name, packet.raw[]);
	}
}


class Device
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

	bool createEthernetModbus(string host, ushort port, EthernetMethod method, ubyte unitId, ModbusProtocol modbusProtocol, const ModbusProfile* profile = null)
	{
		assert(modbusProtocol != ModbusProtocol.Unknown, "Can't guess modbus protocol for slave devices");

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

	bool requestData(Request* request)
	{
		// request data by high-level id
		return false;
	}

	bool forwardModbusRequest(Request* request)
	{
		assert(request.client.protocol == Protocol.Modbus);

		ModbusPDU* pdu = &request.packet.modbus.message;

		if (request.client.modbus.profile != modbus.profile &&
			request.client.modbus.profile && modbus.profile)
		{
			// TODO: if the profiles are mismatching, then we need to translate...
			assert(0);
		}

		return sendModbusRequest(&request.packet.modbus.message, request);
	}

	bool sendModbusRequest(ModbusPDU* message, Request* request = null)
	{
		assert(protocol == Protocol.Modbus);

		if (connection.modbus.protocol != ModbusProtocol.TCP)
		{
			// if there's a request in flight, we need to queue...
			if (modbus.pendingRequests.length > 0)
			{
				modbus.requestQueue ~= Modbus.QueuedRequest(message, request);
				return true;
			}
		}

		ubyte[1024] buffer = void;
		ubyte[] packet;
		switch (connection.modbus.protocol)
		{
			case ModbusProtocol.RTU:
				packet = frameRTUMessage(connection.modbus.address,
										 message.functionCode,
										 message.data,
										 buffer);
				modbus.pendingRequests ~= Modbus.PendingRequest(Modbus.QueuedRequest(message, request), 0, MonoTime.currTime);
				break;
			case ModbusProtocol.TCP:
				packet = frameTCPMessage(modbus.nextTransactionId,
										 connection.modbus.address,
										 message.functionCode,
										 message.data,
										 buffer);
				modbus.pendingRequests ~= Modbus.PendingRequest(Modbus.QueuedRequest(message, request), modbus.nextTransactionId++, MonoTime.currTime);
				break;
			default:
				assert(0);
		}

		connection.write(packet);

		return true;
	}

	Response* poll()
	{
		Response* response = null;

		Packet packet;
		bool success = connection.poll(packet);
		if (success && packet.raw)
		{
			response = new Response;
			response.device = this;
			response.packet = packet;
			response.status = RequestStatus.Success;

			if (protocol == Protocol.Modbus)
			{
				Modbus.QueuedRequest req = modbus.popPendingRequest(connection.modbus.protocol == ModbusProtocol.TCP ? packet.modbus.frame.tcp.transactionId : 0);
				response.request = req.request;

				if (connection.modbus.protocol != ModbusProtocol.TCP)
				{
					// there are requests in the queue; we'll dispatch the next one...
					req = modbus.popModbusRequest();
					if (req.message)
						sendModbusRequest(req.message, req.request);
				}
			}
			else
			{
				// TODO: how do we associate the request?
				assert(0);
			}
		}
		else
		{
			if (protocol == Protocol.Modbus)
			{
				// check for request timeouts
				MonoTime earliestTime = MonoTime.max;
				ushort transactionId;
				for (int i = 0; i < modbus.pendingRequests.length; ++i)
				{
					if (i == 0 || modbus.pendingRequests[i].requestTime < earliestTime)
					{
						earliestTime = modbus.pendingRequests[i].requestTime;
						transactionId = modbus.pendingRequests[i].transactionId;
					}
				}
				if (modbus.pendingRequests.length > 0 && earliestTime + requestTimeout < MonoTime.currTime)
				{
					response = new Response;
					response.device = this;
					response.status = RequestStatus.Timeout;

					Modbus.QueuedRequest req = modbus.popPendingRequest(transactionId);
					response.request = req.request;

					if (connection.modbus.protocol != ModbusProtocol.TCP)
					{
						// there are requests in the queue; we'll dispatch the next one...
						req = modbus.popModbusRequest();
						if (req.message)
							sendModbusRequest(req.message, req.request);
					}
				}
			}
		}

		return response;
	}

public:
	import std.datetime : Duration, MonoTime, msecs;

	string name;
	Connection connection;

	Protocol protocol;
	union
	{
		Modbus modbus;
	}

	Duration requestTimeout = msecs(1000);

private:
	struct Modbus
	{
		struct QueuedRequest
		{
			ModbusPDU* message;
			Request* request;
		}
		struct PendingRequest
		{
			QueuedRequest request;
			ushort transactionId;
			MonoTime requestTime;
		}

		const(ModbusProfile)* profile;
		PendingRequest[] pendingRequests;
		QueuedRequest[] requestQueue;
		RegValue[int] regValues;
		short nextTransactionId;

		QueuedRequest popModbusRequest()
		{
			if (requestQueue.length == 0)
				return QueuedRequest();
			QueuedRequest next = requestQueue[0];
			for (size_t i = 1; i < requestQueue.length; ++i)
				requestQueue[i - 1] = requestQueue[i];
			--requestQueue.length;
			return next;
		}

		QueuedRequest popPendingRequest(ushort transactionId)
		{
			if (pendingRequests.length == 0)
				return QueuedRequest();

			QueuedRequest r = QueuedRequest();
			size_t i = 0;
			for (; i < pendingRequests.length; ++i)
			{
				if (pendingRequests[i].transactionId == transactionId)
				{
					r = pendingRequests[i].request;
					break;
				}
			}
			for (; i < pendingRequests.length - 1; ++i)
				pendingRequests[i] = pendingRequests[i + 1];
			--pendingRequests.length;
			return r;
		}
	}
}
