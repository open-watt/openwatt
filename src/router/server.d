module router.server;

import std.datetime : Duration, MonoTime, msecs;
import std.stdio;

import manager.value;

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
	alias ResponseHandler = void delegate(Response response, void[] userData);

	MonoTime requestTime;
	ResponseHandler responseHandler;
	void[] userData;

	this(ResponseHandler responseHandler, void[] userData = null)
	{
		this.responseHandler = responseHandler;
		this.userData = userData;
	}

//	ValueDesc*[] readValues() const { return null; }
//	Value[] writeValues() const { return null; }

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
	MonoTime responseTime;

	KVP[string] values() { return null; }

	Duration latency() const { return responseTime - request.requestTime; }

	override string toString()
	{
		import std.format;

		assert(request);

		if (status == RequestStatus.Timeout)
			return format("%s: TIMEOUT (%s)", cast(void*)this, server.name);
		else if (status == RequestStatus.Error)
			return format("%s: ERROR (%s)", cast(void*)this, server.name);
		return format("%s: RESPONSE (%s) - ", request, server.name, values);
	}

	struct KVP
	{
		string element;
		Value value;
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
				response.responseTime = now;

				request.responseHandler(response, request.userData);
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
import router.modbus.util;

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

		if (connection.connParams.mode == Mode.SnoopBus)
		{
			userUnsolicitedPacketHandler = connection.connParams.unsolicitedPacketHandler;
			connection.connParams.unsolicitedPacketHandler = &snoopHandler;
		}
	}

	override bool linkEstablished()
	{
		return connection.linkEstablished;
	}

	bool isBusSnooping() const
	{
		return connection.connParams.mode == Mode.SnoopBus;
	}

	override bool sendRequest(Request request)
	{
		// users can't place requests to a snooped bus
		if (connection.connParams.mode == Mode.SnoopBus)
			return false;

		request.requestTime = MonoTime.currTime;

		ModbusRequest modbusRequest = cast(ModbusRequest)request;
		if (modbusRequest)
		{
			writeInfo("Send modbus request to '", name, "'");

			// forward the modbus frame if the profile matches...
			ushort requestId = connection.sendRequest(address, &modbusRequest.pdu, &receiveResponsePacket);
			if (requestId != cast(ushort)-1)
			{
				pendingRequests ~= PendingRequest(requestId, request);
				return true;
			}
		}

		// TODO: should non-modbus requests attempt to be translated based on the profile?
		assert(0);
	}

	const(ModbusProfile)* profile;

	Request.ResponseHandler snoopBusMessageHandler;
	void[] snoopBusMessageUserData;

private:
	Connection connection;
	ubyte address;

	Packet prevSnoopPacket;
	MonoTime prevPacketTime;
	PacketHandler userUnsolicitedPacketHandler = null;

	void receiveResponsePacket(Packet packet, ushort requestId, MonoTime time)
	{
		Request request = popPendingRequest(requestId);
		if (!request)
		{
			writeInfo("Discard modbus response from '", name, "'; no pending request");
			return;
		}

		writeInfo("Received modbus response from '", name, "'");

		ModbusResponse response = new ModbusResponse();
		response.status = RequestStatus.Success;
		response.server = this;
		response.request = request;
		response.responseTime = time;
		response.profile = profile;
		response.frame = packet.frame;
		response.pdu = packet.pdu;

		request.responseHandler(response, request.userData);
	}

	void snoopHandler(Packet packet, ushort requestId, MonoTime time)
	{
		assert(snoopBusMessageHandler, "Snooped bus requires `snoopBusMessageHandler`");

		// check the packet regards the device we're interested in, and that we have 2 packets in sequence
		if (packet.frame.address == address)
		{
			// check if packet is a response to the last request we captured
			if (confirmReqRespSeq(prevSnoopPacket.pdu, packet.pdu))
			{
				writeInfo("Snooped modbus transaction on '", name, "'");

				// fabricate a Request for prevSnoopPacket
				ModbusRequest request = new ModbusRequest(null, &prevSnoopPacket.pdu, 0, null);
				request.frame = prevSnoopPacket.frame;
				request.requestTime = prevPacketTime;

				// fabricate a Response for packet
				ModbusResponse response = new ModbusResponse();
				response.status = RequestStatus.Success;
				response.server = this;
				response.request = request;
				response.responseTime = time;
				response.profile = profile;
				response.frame = packet.frame;
				response.pdu = packet.pdu;

				// what do we do with it now?!
				snoopBusMessageHandler(response, snoopBusMessageUserData);

				prevSnoopPacket = Packet();
				return;
			}
			else
			{
				prevSnoopPacket = packet;
				prevPacketTime = time;
			}
		}
		else
			prevSnoopPacket = Packet();

		// if the user wants the packets, we'll forward them
		if (userUnsolicitedPacketHandler)
			userUnsolicitedPacketHandler(packet, requestId, time);
	}

	static bool confirmReqRespSeq(ref const ModbusPDU req, ref const ModbusPDU resp)
	{
		if (req.functionCode != resp.functionCode)
			return false;
		switch (req.functionCode)
		{
			case FunctionCode.ReadCoils:
			case FunctionCode.ReadDiscreteInputs:
				if (req.length == 4 && req.data[2..4].bigEndianToNative!ushort <= 2000 &&
					resp.data[0] == resp.length - 1 && resp.data[0] == (req.data[2..4].bigEndianToNative!ushort + 7) / 8)
					return true;
				break;
			case FunctionCode.ReadHoldingRegisters:
			case FunctionCode.ReadInputRegisters:
				if (req.length == 4 && req.data[2..4].bigEndianToNative!ushort <= 123 &&
					resp.data[0] == resp.length - 1 && resp.data[0] == req.data[2..4].bigEndianToNative!ushort * 2)
					return true;
				break;
			default:
				break;
		}
		return false;
	}
}

class ModbusRequest : Request
{
	ModbusFrame frame;
	ModbusPDU pdu;

	this(ResponseHandler responseHandler, ModbusPDU* message, ubyte address = 0, void[] userData = null)
	{
		super(responseHandler, userData);
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
	const(ModbusProfile)* profile;
	ModbusFrame frame;
	ModbusPDU pdu;

	override KVP[string] values()
	{
		import std.string : stripRight;
		import manager.units;
		import router.modbus.coding;

		if (cachedValues)
			return cachedValues;

		ModbusRequest modbusRequest = cast(ModbusRequest)request;

		void[512] temp = void;
		ModbusMessageData data = parseModbusMessage(RequestType.Request, modbusRequest.pdu, temp);
		ushort readReg = data.rw.readRegister;
		ushort readCount = data.rw.readCount;
		data = parseModbusMessage(RequestType.Response, pdu, temp);

		if (data.functionCode >= 128)
		{
			// exception!
			writeln("Modbus exception - function: ", cast(FunctionCode)(data.functionCode - 128), " data: ", data.exceptionStatus);
			return null;
		}

		for (ushort i = 0; i < readCount; ++i)
		{
			if (!profile)
			{
				import std.format;
				string reg = format("reg%d", readReg + i);
				cachedValues[reg] = KVP(reg, Value(data.rw.values[i]));
				continue;
			}

			const ModbusRegInfo** pRegInfo = readReg + i in profile.regById;
			if (pRegInfo)
			{
				const ModbusRegInfo* regInfo = *pRegInfo;
				if (i + regInfo.seqLen > readCount)
					continue;

				UnitDef unitConv = getUnitConv(regInfo.units, regInfo.displayUnits);
				// TODO: if unitConv is integer, then don't coerce to floats...

				Value value;
				final switch (regInfo.type)
				{
					case RecordType.uint16:
						value = Value(data.rw.values[i] * unitConv.scale + unitConv.offset);
						break;
					case RecordType.int16:
						value = Value(cast(short)data.rw.values[i] * unitConv.scale + unitConv.offset);
						break;
					case RecordType.uint32:
						value = Value((data.rw.values[i] << 16 | data.rw.values[i + 1]) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.uint32le:
						value = Value((data.rw.values[i + 1] << 16 | data.rw.values[i]) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.int32:
						value = Value(cast(int)(data.rw.values[i] << 16 | data.rw.values[i + 1]) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.int32le:
						value = Value(cast(int)(data.rw.values[i + 1] << 16 | data.rw.values[i]) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.uint8H:
						value = Value((data.rw.values[i] >> 8) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.uint8L:
						value = Value((data.rw.values[i] & 0xFF) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.int8H:
						value = Value(cast(byte)(data.rw.values[i] >> 8) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.int8L:
						value = Value(cast(byte)(data.rw.values[i] & 0xFF) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.exp10:
						assert(false);
					case RecordType.float32:
						uint f = data.rw.values[i] << 16 | data.rw.values[i + 1];
						value = Value(*cast(float*)&f * unitConv.scale + unitConv.offset);
						break;
					case RecordType.float32le:
						uint f = data.rw.values[i + 1] << 16 | data.rw.values[i]; // seems to use little endian?
						value = Value(*cast(float*)&f * unitConv.scale + unitConv.offset);
						break;
					case RecordType.bf16:
					case RecordType.enum16:
						value = Value(data.rw.values[i]);
						break;
					case RecordType.bf32:
					case RecordType.enum32:
						value = Value(data.rw.values[i] << 16 | data.rw.values[i + 1]);
						break;
					case RecordType.str:
						char[256] tmp;
						assert(regInfo.seqLen*2 <= tmp.sizeof);
						for (size_t j = 0; j < regInfo.seqLen; ++j)
						{
							tmp[j*2] = cast(char)(data.rw.values[i + j] >> 8);
							tmp[j*2 + 1] = cast(char)(data.rw.values[i + j] & 0xFF);
						}
						value = Value(tmp[0..regInfo.seqLen*2].stripRight.idup);
						break;
				}
				cachedValues[regInfo.name] = KVP(regInfo.name, value);
			}
		}
		return cachedValues;
	}

	override string toString() const
	{
		import std.format;

		assert(request);

		if (status == RequestStatus.Timeout)
			return format("<-- %s :: REQUEST TIMEOUT", server.name);
		return format("<-- %s :: %s", server.name, pdu.toString);
	}

private:
	KVP[string] cachedValues;
}
