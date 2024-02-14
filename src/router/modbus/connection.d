module router.modbus.connection;

import std.container.array;
import std.datetime;
import std.file;
import std.socket;
import std.stdio;
debug import std.digest;

import core.lifetime;

import router.modbus.coding;
import router.modbus.message;
import router.modbus.util;
import router.serial;
import router.stream;

import util.log;


enum Transport : ubyte
{
	Serial,
	Ethernet
};

enum EthernetMethod : ubyte
{
	TCP,
	UDP
}

enum Mode : ubyte
{
	Slave,
	Master,
	SnoopBus
};

enum ConnectionOptions : uint
{
	None = 0,
	KeepAlive = 1 << 0,
	SupportSimultaneousRequests = 1 << 1,
}

struct ConnectionParams
{
	Mode mode = Mode.Slave;
	int pollingInterval = 0;		// issue requests no more requently than this
	int pollingDelay = 40;			// wait this long after a response before issuing another request
	int timeoutThreshold = 1000;	// timeout for pending requests
	ConnectionOptions options = ConnectionOptions.None;
	PacketHandler unsolicitedPacketHandler = null;
	string logDataStream;			// log filename
}

struct Packet
{
	ubyte[] data;
	ModbusPDU pdu;
	ModbusFrame frame;

	string toString() const
	{
		import std.format;
		return format("%s->%s", frame, pdu);
	}
}

alias PacketHandler = void delegate(Packet packet, ushort requestId, MonoTime time);

class Connection
{
	this(Stream stream, ModbusProtocol modbusProtocol, ConnectionParams connectionParams)
	{
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
		MonoTime now = MonoTime.currTime;

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
		}
		while (length == buffer.sizeof);

		if (inputLen != 0)
		{
			// Check for complete packet based on the protocol
			Packet packet;
			ptrdiff_t len = inputBuffer[0 .. inputLen].getMessage(packet.pdu, &packet.frame, protocol);
			if (len < 0)
			{
				// what to do? purge the buffer and start over maybe?
				assert(0);
			}
			if (len > 0)
			{
				assert(protocol != ModbusProtocol.RTU || pendingRequests.length <= 1);

				lastRespTime = now;
				packet.data = takeInput(len);

				PendingRequest req;
				bool r = popPendingRequest(protocol == ModbusProtocol.TCP ? packet.frame.tcp.transactionId : 0, req);

				debug writeDebug("recvModbusMessage - req: ", r ? req.request.requestId : -1, ", bytes: ", packet.data.length, ", data: ", packet.data.toHexString);

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
				debug writeDebug("modbusMessageTimeout - req: ", pendingRequests[i].request.requestId, ", elapsed: ", (now - pendingRequests[i].requestTime).total!"msecs");

				// drop pending message
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;
			}
			else
				++i;
		}

		// lodge queued requests
		now = MonoTime.currTime;
		if (pendingRequests.length == 0 && requestQueue.length > 0 &&
			((connParams.pollingInterval && now - lastReqTime > connParams.pollingInterval.msecs) ||
			 (connParams.pollingDelay && now - lastRespTime > connParams.pollingDelay.msecs)))
		{
			QueuedRequest next;
			if (popQueuedRequest(next))
			{
				debug writeDebug("lodgeQueued - req: ", next.requestId, ", elapsed: ", now - lastReqTime);
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

	ushort sendRequest(ubyte address, ModbusPDU* message, PacketHandler responseHandler)
	{
		const canSimRequest = protocol == ModbusProtocol.TCP && (connParams.options & ConnectionOptions.SupportSimultaneousRequests);
		if (!canSimRequest && pendingRequests.length > 0)
		{
			requestQueue ~= QueuedRequest(address, nextTransactionId, message, responseHandler);
			return nextTransactionId++;
		}

		if (sendRequest(QueuedRequest(address, nextTransactionId, message, responseHandler)))
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
		MonoTime now = MonoTime.currTime;
		if ((connParams.pollingInterval && now - lastReqTime < connParams.pollingInterval.msecs) ||
			(connParams.pollingDelay && now - lastRespTime < connParams.pollingDelay.msecs))
		{
			debug writeDebug("deferModbusMessage - req: ", request.requestId, ", elapsed: ", now - lastReqTime);
 			requestQueue ~= request;
			return true;
		}

		ushort transactionId = protocol == ModbusProtocol.TCP ? request.requestId : 0;
		ptrdiff_t bytes = sendMessage(request.address, request.message, transactionId);
		pendingRequests ~= PendingRequest(request, transactionId, MonoTime.currTime);
		lastReqTime = now;

		debug writeDebug("sendModbusMessage - req: ", request.requestId, ", bytes: ", bytes);

		return bytes > 0;
	}

	void appendInput(const(ubyte)[] data)
	{
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
		assert(inputLen < 1 || inputLen > 3); // WHY THIS ASSERT?

		for (size_t i = 0; i < inputLen; i += bytes)
		{
			import std.algorithm : min;
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
