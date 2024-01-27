module router.modbus.connection;

import std.container.array;
import std.datetime;
import std.socket;
import std.stdio;

import core.lifetime;

import router.modbus.coding;
import router.modbus.message;
import router.modbus.util;
import router.serial;

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
	int pollingInterval = 200;
	int timeoutThreshold = 1000;
	ConnectionOptions options = ConnectionOptions.None;
	PacketHandler unsolicitedPacketHandler = null;
}

struct Packet
{
	ubyte[] data;
	ModbusPDU pdu;
	ModbusFrame frame;
}

alias PacketHandler = void delegate(Packet packet, ushort requestId, MonoTime time);

class Connection
{
	static Connection createSerialModbus(string device, ref in SerialParams serialParams, ConnectionParams connectionParams)
	{
		Connection c = new Connection;
		c.transport = Transport.Serial;
		c.protocol = ModbusProtocol.RTU;
		c.connParams = connectionParams;

		c.serial.device = device;
		c.serial.params = serialParams;

		assert(!(connectionParams.options & ConnectionOptions.SupportSimultaneousRequests) || c.protocol == ModbusProtocol.TCP, "RTU transport does not support simultaneous requests.");

		// open serial stream...
		c.serial.serialPort.open(device, serialParams);

		// TODO: if open fails, report error

		return c;
	}

	static Connection createEthernetModbus(string host, ushort port, EthernetMethod method, ModbusProtocol modbusProtocol, ConnectionParams params)
	{
		Connection c = new Connection;

		c.transport = Transport.Ethernet;
		c.protocol = modbusProtocol;
		c.connParams = params;

		c.ethernet.host = host;
		c.ethernet.port = port;
		c.ethernet.method = method;

		switch (method)
		{
			case EthernetMethod.TCP:
				// try and connect to server...
				c.ethernet.socket = new TcpSocket();
				c.ethernet.socket.connect(new InternetAddress(host, port));
				break;
			case EthernetMethod.UDP:
				// maybe we need to bind to receive messages?
				assert(0);
				break;
			default:
				assert(0);
		}

		return c;
	}

	bool linkEstablished()
	{
		return false;
	}

	void poll()
	{
		ubyte[1024] buffer = void;

		switch (transport)
		{
			case Transport.Serial:
				ptrdiff_t length;
				do
				{
					length = serial.serialPort.read(buffer);
					if (length <= 0)
						break;
					appendInput(buffer[0 .. length]);
				}
				while (length == buffer.sizeof);
				break;
			case Transport.Ethernet:
				switch (ethernet.method)
				{
					case EthernetMethod.TCP:
						SocketSet readSet = new SocketSet;
						readSet.add(ethernet.socket);
						if (Socket.select(readSet, null, null, dur!"usecs"(0)))
						{
							auto length = ethernet.socket.receive(buffer);
							if (length > 0)
								appendInput(buffer[0 .. length]);
						}
						break;
					case EthernetMethod.UDP:
						assert(0);
					default:
						assert(0);
				}
				break;
			default:
				assert(0);
		}

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

				packet.data = takeInput(len);

				PendingRequest req;
				if (!popPendingRequest(protocol == ModbusProtocol.TCP ? packet.frame.tcp.transactionId : 0, req))
				{
					// we got an unsolicited message
					if (connParams.unsolicitedPacketHandler != null)
						connParams.unsolicitedPacketHandler(packet.move, 0, MonoTime.currTime);
				}
				req.request.responseHandler(packet.move, req.request.requestId, req.requestTime);

				// lodge next packet...
				QueuedRequest next;
				if (popQueuedRequest(next))
					sendRequest(next.move);
			}
		}
	}

	bool sendMessage(ubyte address, ModbusPDU* message, ushort transactionId)
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
	ubyte[] inputBuffer;
	size_t inputLen;

	PendingRequest[] pendingRequests;
	QueuedRequest[] requestQueue;
	short nextTransactionId;

	struct Serial
	{
		string device;
		SerialParams params;
		SerialPort serialPort;
	}

	struct Ethernet
	{
		string host;
		ushort port;
		EthernetMethod method;
		Socket socket;
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

	bool write(const(ubyte[]) data)
	{
		switch (transport)
		{
			case Transport.Serial:
				serial.serialPort.write(data);
				return true;
			case Transport.Ethernet:
				switch (ethernet.method)
				{
					case EthernetMethod.TCP:
						ethernet.socket.send(data);
						return true;
					case EthernetMethod.UDP:
						assert(0);
					default:
						assert(0);
				}
				break;
			default:
				assert(0);
		}
		return false;
	}

	bool sendRequest(QueuedRequest request)
	{
		ushort transactionId = protocol == ModbusProtocol.TCP ? request.requestId : 0;
		bool r = sendMessage(request.address, request.message, transactionId);
		pendingRequests ~= PendingRequest(request, transactionId, MonoTime.currTime);
		return r;
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
}
