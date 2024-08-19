module router.goodwe.aa55;

import std.socket;
import std.stdio;

import manager.value;

public import router.server;

import router.modbus.server;
import router.stream.udp;

import urt.log;
import urt.string;
import urt.time;


enum GoodWeControlCode : ubyte
{
	Register = 0x00,
	Read = 0x01,
	Execute = 0x03
}

enum GoodWeFunctionCode : ubyte
{
	// Register
	OfflineQuery = 0x00,
	AllocateRegisterAddress = 0x01,
	RemoveRegister = 0x02,

	// Read
	QueryRunningInfo = 0x01,
	QueryIdInfo = 0x02,
	QuerySettingInfo = 0x03,

	// Execute
	StartInverter = 0x1B,
	StopInverter = 0x1C,
	DisconnectGridAndReconnect = 0x1D,
	AdjustRealPower = 0x1E
}


struct GoodWeRequestData
{
	ubyte sourceAddr = 0xC0;
	ubyte destAddr = 0x7F;
	GoodWeControlCode controlCode;
	GoodWeFunctionCode functionCode;
	ubyte[] data;
}

class GoodWeServer : Server
{
	this(string name, string inverterAddr)
	{
		super(name);
		stream = new UDPStream(8899, inverterAddr, options: StreamOptions.NonBlocking | StreamOptions.AllowBroadcast);
		stream.connect();

		sendRequest(new GoodWeRequest(&probeFunc, GoodWeRequestData(controlCode: GoodWeControlCode.Read, GoodWeFunctionCode.QueryIdInfo)));
	}

	~this()
	{
		stream.disconnect();
	}

	override bool linkEstablished()
	{
		return commEstablished;
	}

	override bool sendRequest(Request request)
	{
		request.requestTime = getTime();

		if (inFlight)
		{
			queue ~= request;
			return true;
		}

		ubyte[1024] buffer = void;

		GoodWeRequest goodweRequest = cast(GoodWeRequest)request;
		if (goodweRequest)
		{
			writeInfof("{0} - GOODWE - Send request {1} to '{2}'", request.requestTime, cast(void*)request, name);

			assert(goodweRequest.requestData.data.length < 256);

			buffer[0] = 0xAA;
			buffer[1] = 0x55;
			buffer[2] = goodweRequest.requestData.sourceAddr;
			buffer[3] = goodweRequest.requestData.destAddr;
			buffer[4] = goodweRequest.requestData.controlCode;
			buffer[5] = goodweRequest.requestData.functionCode;
			buffer[6] = cast(ubyte)goodweRequest.requestData.data.length;
			buffer[7 .. 7 + goodweRequest.requestData.data.length] = goodweRequest.requestData.data[];
			ushort *checksum = cast(ushort*)(buffer.ptr + 7 + goodweRequest.requestData.data.length);
			foreach (b; buffer[0 .. 7 + goodweRequest.requestData.data.length])
				*checksum += b;
			version (LittleEndian)
				*checksum = cast(ushort)((*checksum >> 8) | (*checksum << 8));

			stream.write(buffer[0 .. 7 + goodweRequest.requestData.data.length + 2]);
			inFlight = request;
			return true;
		}

		ModbusRequest modbusRequest = cast(ModbusRequest)request;
		if (modbusRequest)
		{
			import router.modbus.message;

			writeInfof("{0} - GOODWE - Send modbus request {1} to '{2}'", request.requestTime, cast(void*)request, name);

			ubyte[] packet;
			packet = frameRTUMessage(modbusRequest.frame.address,
									 modbusRequest.pdu.functionCode,
									 modbusRequest.pdu.data,
									 buffer);

			stream.write(packet);
			inFlight = request;
			return true;
		}

		// TODO: should other requests attempt to be translated based on the profile?
		assert(0);
	}

	override void poll()
	{
		MonoTime now = getTime();

		ubyte[1024] buffer = void;
		ptrdiff_t r = stream.read(buffer);
		if (r == Socket.ERROR)
		{
			if (wouldHaveBlocked())
				r = 0;
			else
				assert(0);
		}
		if (r)
		{
			// I expect this protocol always fits within 1 MTU?

			if (inFlight)
			{
				GoodWeRequest goodweRequest = cast(GoodWeRequest)inFlight;
				Response response;
				if (goodweRequest)
				{
					assert(r >= 9 && buffer[0] == 0xAA && buffer[1] == 0x55, "Protocol error");
					ushort sum = 0;
					foreach (i; 0 .. r - 2)
						sum += buffer[i];
					assert(buffer[r - 2] == (sum >> 8) && buffer[r - 1] == (sum & 0xFF), "Bad checksum");

					GoodWeResponse resp = new GoodWeResponse();

					resp.status = RequestStatus.Success;
					resp.server = this;
					resp.request = goodweRequest;
					resp.responseTime = now;

					resp.responseData.sourceAddr = buffer[2];
					resp.responseData.destAddr = buffer[3];
					resp.responseData.controlCode = cast(GoodWeControlCode)buffer[4];
					resp.responseData.functionCode = cast(GoodWeFunctionCode)buffer[5];
					assert(r == 7 + buffer[6] + 2, "Bad data length");
					resp.responseData.data = buffer[7 .. 7 + buffer[6]].dup;

					assert(resp.responseData.sourceAddr == goodweRequest.requestData.destAddr);
					assert(resp.responseData.destAddr == goodweRequest.requestData.sourceAddr);
					assert(resp.responseData.controlCode == goodweRequest.requestData.controlCode);
					assert(resp.responseData.functionCode == (0x80 | goodweRequest.requestData.functionCode));

					writeInfo(now, " - GOODWE - Received response ", cast(void*)goodweRequest, " from '", name, "' after ", (now - goodweRequest.requestTime).as!"msecs", "ms");

					response = resp;
				}

				ModbusRequest modbusRequest = cast(ModbusRequest)inFlight;
				if (modbusRequest)
				{
					import router.modbus.message;

					assert(buffer[0] == 0xAA && buffer[1] == 0x55);

					ModbusResponse resp = new ModbusResponse();
					resp.status = RequestStatus.Success;
					resp.server = this;
					resp.request = modbusRequest;
					resp.responseTime = now;

					ptrdiff_t len = buffer[2 .. r].getMessage(resp.pdu, &resp.frame, ModbusProtocol.RTU);
					assert(len == r - 2);

					writeInfo(now, " - GOODWE - Received modbus response ", cast(void*)modbusRequest, " from '", name, "' after ", (now - modbusRequest.requestTime).as!"msecs", "ms");

					response = resp;
				}

				inFlight.responseHandler(response, inFlight.userData);
				inFlight = null;
			}
			else
			{
				// unsolocited message!
				//...
			}
		}

		if (inFlight)
		{
			// timeout in-flight requests...
			if (now - inFlight.requestTime > 500.msecs)
			{
				writeWarning(now, " - GOODWE - Request timeout ", cast(void*)inFlight, " after ", (now - inFlight.requestTime).as!"msecs", "ms");

				// send timeout response and discard the request...
				Response response = new Response();
				response.status = RequestStatus.Timeout;
				response.server = this;
				response.request = inFlight;
				response.responseTime = now;
				inFlight.responseHandler(response, inFlight.userData);
				inFlight = null;
			}
		}

		if (!inFlight && queue.length > 0)
		{
			// send next message...
			Request next = queue[0];
			queue = queue[1 .. $];
			sendRequest(next);
		}
	}

private:
	UDPStream stream;

	Request inFlight;
	Request[] queue;

	bool commEstablished;

	void probeFunc(Response response, void[] userData)
	{
		if (response.status == RequestStatus.Timeout)
		{
			GoodWeRequest req = cast(GoodWeRequest)response.request;
			sendRequest(req);
			return;
		}
		GoodWeResponse r = cast(GoodWeResponse)response;
		if (r)
		{
			commEstablished = true;
		}
	}
}

class GoodWeRequest : Request
{
	this(ResponseHandler responseHandler, GoodWeRequestData requestData, void[] userData = null)
	{
		super(responseHandler, userData);
		this.requestData = requestData;
	}

//	override string toString() const
//	{
////		return format("%s: %s::%s", super.toString(), frame.toString, pdu.toString);
//	}

	GoodWeRequestData requestData;
}

class GoodWeResponse : Response
{
	override KVP[string] values()
	{
		import std.string : stripRight;
		import manager.units;
		import router.modbus.coding;

		if (cachedValues)
			return cachedValues;

		switch (responseData.controlCode)
		{
			case GoodWeControlCode.Register:
				switch (responseData.functionCode)
				{
					case GoodWeFunctionCode.OfflineQuery:
						assert(0);

					case GoodWeFunctionCode.AllocateRegisterAddress:
						assert(0);

					case GoodWeFunctionCode.RemoveRegister:
						assert(0);

					default:
						assert(0);
				}
				break;

			case GoodWeControlCode.Read:
				switch (cast(GoodWeFunctionCode)(responseData.functionCode ^ 0x80))
				{
					case GoodWeFunctionCode.QueryRunningInfo:
						assert(0);

					case GoodWeFunctionCode.QueryIdInfo:
						char[] data = cast(char[])responseData.data;
						cachedValues["FirmwareVer"] = Response.KVP("FirmwareVer", Value(data[0 .. 5]));
						cachedValues["ModelName"] = Response.KVP("ModelName", Value(data[5 .. 15]));
						cachedValues["SerialNumber"] = Response.KVP("SerialNumber", Value(data[31 .. 47]));
						cachedValues["Nom_Vpv"] = Response.KVP("Nom_Vpv", Value(data[47 .. 51]));
						cachedValues["InternalVersion"] = Response.KVP("InternalVersion", Value(data[51 .. 63]));
						cachedValues["SafetyCountryCode"] = Response.KVP("SafetyCountryCode", Value(cast(ubyte)data[63]));
						break;

					case GoodWeFunctionCode.QuerySettingInfo:
						assert(0);

					default:
						assert(0);
				}
				break;

			case GoodWeControlCode.Execute:
				assert(0);
				break;

			default:
				assert(0);
		}

		return cachedValues;
	}

//	override string toString() const
//	{
//		import urt.string.format;
//
//		assert(request);
//
//		if (status == RequestStatus.Timeout)
//			return format("<-- %s :: REQUEST TIMEOUT", server.name);
//		return format("<-- %s :: %s", server.name, pdu.toString);
//	}

private:
	GoodWeRequestData responseData;
	KVP[string] cachedValues;
}
