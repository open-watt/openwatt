module router.modbus.server;

import std.datetime : Duration, MonoTime, msecs;
import std.stdio;

public import router.server;

import manager.element;
import manager.value;

import router.modbus.connection;
import router.modbus.message;
import router.modbus.profile;
import router.modbus.util;

import urt.endian;
import urt.log;
import urt.string;

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
			writeInfof("{0} - Modbus - Send request {1} to '{2}'", request.requestTime.printTime, cast(void*)request, name);

			// forward the modbus frame if the profile matches...
			ushort requestId = connection.sendRequest(address, &modbusRequest.pdu, &receiveResponsePacket, &timeoutHandler);
			if (requestId != cast(ushort)-1)
			{
				pendingRequests ~= PendingRequest(requestId, request);
				return true;
			}
		}

		// TODO: should non-modbus requests attempt to be translated based on the profile?
		assert(0);
	}

	override void requestElements(Element*[] elements)
	{
		import std.algorithm : map;
		import std.array;

		auto modbusRequestElements = elements.map!(e => ModbusReqElement(e, e.sampler, cast(const(ModbusRegInfo)*)e.sampler.samplerData));

		size_t startEl = 0;
		ushort firstReg = modbusRequestElements[0].regInfo.reg;
		ushort prevReg = firstReg;
		for (size_t i = 0; i < modbusRequestElements.length; ++i)
		{
			ushort seqStart = modbusRequestElements[i].regInfo.reg;
			ushort seqEnd = cast(ushort)(seqStart + modbusRequestElements[i].regInfo.seqLen);

			ModbusReqElement[] thisReq = null;

			enum BigGap = 20; // how big is a big gap?
			if (i == modbusRequestElements.length - 1)
				thisReq = modbusRequestElements[startEl .. $].array;
			else if (seqEnd - firstReg > 120 || seqStart - prevReg > BigGap)
			{
				thisReq = modbusRequestElements[startEl .. i].array;
				startEl = i;
				firstReg = seqStart;
			}
			prevReg = seqEnd;

			if (thisReq)
			{
				foreach (ref ModbusReqElement e; thisReq)
					e.sampler.inFlight = true;

				ushort from = thisReq[0].regInfo.reg;
				ushort count = cast(ushort)(thisReq[$-1].regInfo.reg + thisReq[$-1].regInfo.seqLen - thisReq[0].regInfo.reg);

				ModbusPDU pdu = createMessage_Read(thisReq[0].regInfo.regType, from, count);
				ModbusRequest request = new ModbusRequest(&modbusResponseHandler, &pdu, 0, thisReq);
				sendRequest(request);
			}
		}
	}

	const(ModbusProfile)* profile;

	Request.ResponseHandler snoopBusMessageHandler;
	void[] snoopBusMessageUserData;

private:
	struct ModbusReqElement
	{
		Element* element;
		Sampler* sampler;
		const(ModbusRegInfo)* regInfo;
	}

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
			writeWarning(time.printTime, " - Modbus - Discard response from '", name, "'; no pending request");
			return;
		}

		writeInfo(time.printTime, " - Modbus - Received response ", cast(void*)request, " from '", name, "' after ", (time - request.requestTime).total!"msecs", "ms");

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

	void timeoutHandler(ushort requestId, MonoTime time)
	{
		Request request = popPendingRequest(requestId);
		if (request)
		{
			writeWarning(time.printTime, " - Modbus - Request timeout ", cast(void*)request, " after ", (time - request.requestTime).total!"msecs", "ms");

			ModbusResponse response = new ModbusResponse();
			response.status = RequestStatus.Timeout;
			response.server = this;
			response.request = request;
			response.responseTime = time;
			response.profile = profile;

			request.responseHandler(response, request.userData);
		}
	}

	void snoopHandler(Packet packet, ushort requestId, MonoTime time)
	{
//		assert(snoopBusMessageHandler, "Snooped bus requires `snoopBusMessageHandler`");

		// check the packet regards the device we're interested in, and that we have 2 packets in sequence
		if (packet.frame.address == address)
		{
			// check if packet is a response to the last request we captured
			if (confirmReqRespSeq(prevSnoopPacket.pdu, packet.pdu))
			{
				writeInfo(time.printTime, " - Modbus - Snooped transaction on '", name, "'");

				if (snoopBusMessageHandler)
				{
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
				}

				prevSnoopPacket = Packet();
			}
			else
			{
				prevSnoopPacket = packet;
				prevPacketTime = time;
			}
			return;
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

	void modbusResponseHandler(Response response, void[] userData)
	{
		ModbusResponse modbusResponse = cast(ModbusResponse)response;
		ModbusReqElement[] thisReq = cast(ModbusReqElement[])userData;
		string name = response.server.name;

		Response.KVP[string] values = response.status == RequestStatus.Success ? response.values : null;

		foreach (ref ModbusReqElement e; thisReq)
		{
			e.sampler.inFlight = false;

			if (response.status != RequestStatus.Success)
				continue;

			if (e.sampler.updateIntervalMs == 0)
				e.sampler.constantSampled = true;
			else
			{
				do
					e.sampler.nextSample += e.sampler.updateIntervalMs.msecs;
				while (e.sampler.nextSample <= Duration.zero);
			}

			Response.KVP* kvp = e.regInfo.desc.name in values;
			if (kvp)
			{
				e.element.latest = kvp.value;

				switch (e.element.latest.type)
				{
					case Value.Type.Integer:
						if (e.element.type == Value.Type.Integer)
							break;
						assert(0);
					case Value.Type.Float:
						if (e.element.type == Value.Type.Integer)
							e.element.latest = Value(cast(long)e.element.latest.asFloat);
						else if (e.element.type == Value.Type.Float)
							break;
						else if (e.element.type == Value.Type.Bool)
							e.element.latest = Value(e.element.latest.asFloat != 0);
						assert(0);
					case Value.Type.String:
						if (e.element.type == Value.Type.String)
							break;
						assert(0);
					default:
						assert(0);
				}

				writeDebug("Modbus - ", name, '.', e.element.id, ": ", e.element.latest, e.element.unit);
			}
		}
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

	this(ResponseHandler responseHandler, FunctionCode functionCode, const(ubyte)[] payload, ubyte address = 0, void[] userData = null)
	{
		this(responseHandler, new ModbusPDU(functionCode, payload), address, userData);
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

				UnitDef unitConv = getUnitConv(regInfo.units, regInfo.desc.displayUnits);
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
					case RecordType.uint64:
						value = Value((cast(ulong)data.rw.values[i] << 48 | cast(ulong)data.rw.values[i + 1] << 32 | data.rw.values[i + 2] << 16 | data.rw.values[i + 3]) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.uint64le:
						value = Value((cast(ulong)data.rw.values[i + 3] << 48 | cast(ulong)data.rw.values[i + 2] << 32 | data.rw.values[i + 1] << 16 | data.rw.values[i]) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.int64:
						value = Value(cast(long)(cast(ulong)data.rw.values[i] << 48 | cast(ulong)data.rw.values[i + 1] << 32 | data.rw.values[i + 2] << 16 | data.rw.values[i + 3]) * unitConv.scale + unitConv.offset);
						break;
					case RecordType.int64le:
						value = Value(cast(long)(cast(ulong)data.rw.values[i + 3] << 48 | cast(ulong)data.rw.values[i + 2] << 32 | data.rw.values[i + 1] << 16 | data.rw.values[i]) * unitConv.scale + unitConv.offset);
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
					case RecordType.float64:
						ulong d = cast(ulong)data.rw.values[i] << 48 | cast(ulong)data.rw.values[i + 1] << 32 | data.rw.values[i + 2] << 16 | data.rw.values[i + 3];
						value = Value(*cast(double*)&d * unitConv.scale + unitConv.offset);
						break;
					case RecordType.float64le:
						ulong d = cast(ulong)data.rw.values[i + 3] << 48 | cast(ulong)data.rw.values[i + 2] << 32 | data.rw.values[i + 1] << 16 | data.rw.values[i];
						value = Value(*cast(double*)&d * unitConv.scale + unitConv.offset);
						break;
					case RecordType.bf16:
					case RecordType.enum16:
						value = Value(data.rw.values[i]);
						break;
					case RecordType.bf32:
					case RecordType.enum32:
						value = Value(data.rw.values[i] << 16 | data.rw.values[i + 1]);
						break;
					case RecordType.enum32_float:
						uint f = data.rw.values[i] << 16 | data.rw.values[i + 1];
						value = Value(cast(int)*cast(float*)&f);
						break;
					case RecordType.bf64:
						value = Value(cast(ulong)data.rw.values[i] << 48 | cast(ulong)data.rw.values[i + 1] << 32 | data.rw.values[i + 2] << 16 | data.rw.values[i + 3]);
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
				cachedValues[regInfo.desc.name] = KVP(regInfo.desc.name, value);
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
