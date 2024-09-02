module router.modbus.connection;

import std.file;
import std.stdio;

import urt.log;
import urt.string;
import urt.time;

import core.lifetime;

import router.modbus.coding;
import router.modbus.message;
import router.modbus.util;
import router.stream;
import router.stream.serial;


/+
enum ConnectionOptions : uint
{
	None = 0,
	KeepAlive = 1 << 0,
	SupportSimultaneousRequests = 1 << 1,
}

struct ConnectionParams
{
	Mode mode = Mode.Slave;
	int pollingInterval = 0;		// issue requests no more frequently than this
	int pollingDelay = 40;			// wait this long after a response before issuing another request
	int timeoutThreshold = 1000;	// timeout for pending requests
	ConnectionOptions options = ConnectionOptions.None;
	PacketHandler unsolicitedPacketHandler = null;
	string logDataStream;			// log filename
}

alias PacketHandler = void delegate(Packet packet, ushort requestId, MonoTime time);
alias TimeoutHandler = void delegate(ushort requestId, MonoTime time);

class Connection
{
	this(string name, Stream stream, ModbusProtocol modbusProtocol, ConnectionParams connectionParams)
	{
		this.name = name;
		this.stream = stream;
		if (cast(SerialStream)stream)
		{
			this.transport = Transport.Serial;
			assert(modbusProtocol == ModbusProtocol.RTU, "Serial modbus only supports RTU transport.");
			assert(!(connectionParams.options & ConnectionOptions.SupportSimultaneousRequests), "RTU transport does not support simultaneous requests.");
		}
		else
			this.transport = Transport.Ethernet;

		this.protocol = modbusProtocol;
		this.connParams = connectionParams;

		if (connectionParams.logDataStream)
			this.logStream = openLogFile(connectionParams.logDataStream);

		if (!stream.connected())
			stream.connect();
	}

	bool linkEstablished()
	{
		return false;
	}

	void poll()
	{
		MonoTime now = getTime();

		ubyte[1024] buffer = void;
		ptrdiff_t length;
		do
		{
			length = stream.read(buffer);
			if (length <= 0)
				break;
			if (connParams.logDataStream)
				logStream.rawWrite(buffer[0 .. length]);
			appendInput(buffer[0 .. length]);

			debug writeDebug(now, " - Modbus - Recv '", name, "': ", cast(void[])buffer[0..length]);
		}
		while (length == buffer.sizeof);

		if (inputLen != 0)
		{
			// Check for complete packet based on the protocol
			Packet packet;
			ptrdiff_t len = inputBuffer[0 .. inputLen].getMessage(packet.pdu, &packet.frame, protocol);
			if (len <= 0)
			{
				if (len < 0)
				{
					// there was an error in the data stream; i guess we just discard the buffer...?
					writeWarning(now, " - Modbus - Error in stream. Discarding input buffer: ", cast(void[])inputBuffer[0..inputLen]);
					inputLen = 0;
				}
				else if (inputLen >= 256)
				{
					// there should be at least one complete message... we must have lost synchronisation with the stream?
					writeWarning(now, " - Modbus - >256 bytes in queue but no valid message. Discarding input buffer: ", cast(void[])inputBuffer[0..inputLen]);
					// TODO: it's likely only the first few bytes are corrupt followed by a series of good packets
					//       we may want to scan for the start of the start of the next good packet rather than clearing the whole buffer?
					inputLen = 0;
				}
				// in this case, the packet doesn't look corrupt, so maybe we just have an incomplete (split) packet...
				// thing is; I don't know what cases where a <256 byte ethernet packet would be split, and RS485 serial reads should also not report incomplete packets (?)
				// ... is this a problem case? we'll just wait, when we exceed 256 bytes, then we can determine we have a corrupt packet.
			}
			else
			{
				debug // TODO: REMOVE ME!
				{
					if (inputLen > 0)
					{
						import router.modbus.util;
						// confirm that the following bytes appear to start a new packet...
						if (inputBuffer[0] > 247)
						{
							int x = 0;
						}
						if (inputLen > 1 && !(cast(FunctionCode)inputBuffer[1]).validFunctionCode)
						{
							int x = 0;
						}
					}
				}

				assert(protocol != ModbusProtocol.RTU || pendingRequests.length <= 1);

				lastRespTime = now;
				packet.data = takeInput(len);

				PendingRequest req;
				bool r = popPendingRequest(protocol == ModbusProtocol.TCP ? packet.frame.tcp.transactionId : 0, req);
				if (!r)
				{
					// we got an unsolicited message
					if (connParams.unsolicitedPacketHandler != null)
						connParams.unsolicitedPacketHandler(packet.move, 0, now);
				}
				else
					req.request.responseHandler(packet.move, req.request.requestId, req.requestTime);
			}
		}

		// check for timeouts
		for (size_t i = 0; i < pendingRequests.length; )
		{
			if (now - pendingRequests[i].requestTime > connParams.timeoutThreshold.msecs)
			{
				PendingRequest* req = &pendingRequests[i];

				debug writeDebug(now - pendingRequests[i].requestTime, " - Modbus - Timeout req: ", req.request.requestId, ", elapsed: ", (now - req.requestTime).as!"msecs", "ms");

				req.request.timeoutHandler(req.request.requestId, now);

				// drop pending message
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;
			}
			else
				++i;
		}

		// lodge queued request
		now = getTime();
		Duration sinceLastReq = now - lastReqTime;
		Duration sinceLastResp = now - lastRespTime;
		if (pendingRequests.length == 0 && requestQueue.length > 0 &&
			((connParams.pollingInterval && sinceLastReq > connParams.pollingInterval.msecs) ||
			 (connParams.pollingDelay && sinceLastResp > connParams.pollingDelay.msecs)))
		{
			QueuedRequest next;
			if (popQueuedRequest(next))
			{
//				debug writeDebug(now.printTime, " - Modbus - Send queued: ", next.requestId, ", elapsed: ", sinceLastReq.as!"msecs", "ms, delay: ", sinceLastResp.as!"msecs", "ms");
				sendRequest(next.move);
			}
		}
	}

	ptrdiff_t sendMessage(ubyte address, ModbusPDU* message, ushort transactionId)
	{
		ubyte[1024] buffer = void;
		ubyte[] packet;
		switch (protocol)
		{
			case ModbusProtocol.RTU:
				packet = frameRTUMessage(address,
										 message.functionCode,
										 message.data,
										 buffer);
				break;
			case ModbusProtocol.TCP:
				packet = frameTCPMessage(transactionId,
										 address,
										 message.functionCode,
										 message.data,
										 buffer);
				break;
			default:
				assert(0);
		}
		return write(packet);
	}

	ushort sendRequest(ubyte address, ModbusPDU* message, PacketHandler responseHandler, TimeoutHandler timeoutHandler)
	{
		const canSimRequest = protocol == ModbusProtocol.TCP && (connParams.options & ConnectionOptions.SupportSimultaneousRequests);
		if (!canSimRequest && pendingRequests.length > 0)
		{
			requestQueue ~= QueuedRequest(address, nextTransactionId, message, responseHandler, timeoutHandler);
			return nextTransactionId++;
		}

		if (sendRequest(QueuedRequest(address, nextTransactionId, message, responseHandler, timeoutHandler)))
			return nextTransactionId++;
		return cast(ushort)-1;
	}

	Transport transport;
	ModbusProtocol protocol;
	ConnectionParams connParams;

	union
	{
		Serial serial;
		Ethernet ethernet;
	}

private:
	string name;
	Stream stream;
	ubyte[] inputBuffer;
	size_t inputLen;

	PendingRequest[] pendingRequests;
	QueuedRequest[] requestQueue;
	short nextTransactionId = 1;
	MonoTime lastReqTime;
	MonoTime lastRespTime;

	File logStream;

	struct Serial
	{
		string device;
		SerialParams params;
	}

	struct Ethernet
	{
		string host;
		ushort port;
		EthernetMethod method;
	}

	struct QueuedRequest
	{
		ubyte address;
		ushort requestId;
		ModbusPDU* message;
		PacketHandler responseHandler;
		TimeoutHandler timeoutHandler;
	}

	struct PendingRequest
	{
		QueuedRequest request;
		ushort transactionId;
		MonoTime requestTime;
	}

	bool popQueuedRequest(out QueuedRequest next)
	{
		if (requestQueue.length == 0)
			return false;
		next = requestQueue[0].move;
		requestQueue = requestQueue[1 .. $];
		return true;
	}

	bool popPendingRequest(ushort transactionId, out PendingRequest request)
	{
		if (pendingRequests.length == 0)
			return false;

		for (size_t i = 0; i < pendingRequests.length; ++i)
		{
			if (pendingRequests[i].transactionId == transactionId)
			{
				request = pendingRequests[i].move;
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;
				return true;
			}
		}
		return false;
	}

	ptrdiff_t write(const(ubyte[]) data)
	{
		size_t r = stream.write(data);
		if (connParams.logDataStream)
			logStream.rawWrite(data);
		return r;
	}

	bool sendRequest(QueuedRequest request)
	{
		MonoTime now = getTime();
		Duration sinceLastReq = now - lastReqTime;
		Duration sinceLastResp = now - lastRespTime;
		if ((connParams.pollingInterval && sinceLastReq < connParams.pollingInterval.msecs) ||
			(connParams.pollingDelay && sinceLastResp < connParams.pollingDelay.msecs))
		{
//			debug writeDebug(now.printTime, " - Modbus - Queue req: ", request.requestId, ", elapsed: ", sinceLastReq.total!"msecs", "ms, delay: ", sinceLastResp.total!"msecs", "ms");
 			requestQueue ~= request;
			return true;
		}

		ushort transactionId = protocol == ModbusProtocol.TCP ? request.requestId : 0;
		ptrdiff_t bytes = sendMessage(request.address, request.message, transactionId);
		pendingRequests ~= PendingRequest(request, transactionId, now);
		lastReqTime = now;

		debug writeDebugf("{0} - Modbus - Send req {1}: {2}", now, request.requestId, cast(void[])frameRTUMessage(request.address, request.message.functionCode, request.message.data));

		return bytes > 0;
	}

	void appendInput(const(ubyte)[] data)	{
		while (data.length > inputBuffer.length - inputLen)
		{
			if (inputBuffer.length == 0)
				inputBuffer = new ubyte[1024];
			else
			{
				ubyte[] newBuffer = new ubyte[inputBuffer.length * 2];
				newBuffer[0 .. inputLen] = inputBuffer[0 .. inputLen];
				inputBuffer = newBuffer;
			}
		}
		inputBuffer[inputLen .. inputLen + data.length] = data[];
		inputLen += data.length;
	}

	ubyte[] takeInput(size_t bytes)
	{
		assert(bytes <= inputLen);

		ubyte[] r = inputBuffer[0 .. bytes].dup;
		inputLen -= bytes;

		for (size_t i = 0; i < inputLen; i += bytes)
		{
			import urt.util : min;
			size_t copy = min(inputLen - i, bytes);
			inputBuffer[i .. i + copy] = inputBuffer[i + bytes .. i + bytes + copy];
		}
		inputBuffer[inputLen .. inputLen + bytes] = 0;

		return r;
	}

	static File openLogFile(string name)
	{
		import std.conv : to;

		int i = 0;
		do
		{
			string t = name;
			if (i > 0)
				t ~= '.' ~ i.to!string;
			t ~= ".log";
			if (!exists(t))
			{
				File f;
				f.open(t, "ab");
				return f;
			}
		}
		while (++i < 100000);
		return File();
	}
}
+/
