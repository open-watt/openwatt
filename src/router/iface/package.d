module router.iface;

import urt.conv;
import urt.mem.ring;
import urt.string;
import urt.string.format;
import urt.time;

import manager.console;
import manager.plugin;

public import router.iface.packet;


enum BufferOverflowBehaviour : byte
{
	DropOldest,	// drop oldest data in buffer
	DropNewest,	// drop newest data in buffer (or don't add new data to full buffer)
	Fail		// cause the call to fail
}

struct PacketFilter
{
	MACAddress src;
	MACAddress dst;
	ushort etherType;
	ushort enmsSubType;
	ushort vlan;
	bool function(ref const Packet p) filter;
}

struct InterfaceSubscriber
{
	PacketFilter filter;
	void function(ref const Packet p) recvPacket;
}

struct InterfaceStatus
{
	MonoTime linkStatusChangeTime;
	bool linkStatus;
	int linkDowns;

	uint sendPackets;
	uint recvPackets;
	ulong sendBytes;
	ulong revcBytes;
}

// MAC: 02:xx:xx:ra:nd:yy
//      02:13:37:xx:xx:yy
//      02:AC:1D:xx:xx:yy
//      02:C0:DE:xx:xx:yy
//      02:BA:BE:xx:xx:yy
//      02:DE:AD:xx:xx:yy
//      02:FE:ED:xx:xx:yy
//      02:B0:0B:xx:xx:yy

class BaseInterface
{
	String name;
	String type;

	MACAddress mac;

	InterfaceSubscriber[] subscribers;

	BufferOverflowBehaviour sendBehaviour;
	BufferOverflowBehaviour recvBehaviour;

	this(String name, String type)
	{
		this.name = name;
		this.type = type;

		mac = MACAddress([0, 0, 0, 0, 0, 0]);
	}

	void update()
	{
	}

	final size_t packetsPending() => sendQueue.length;
	final size_t packetsAvailable() => recvQueue.length;

	final size_t bytesPending() => sendUse();
	final size_t bytesAvailable() => recvUse();

	ptrdiff_t send(const(void)[] packet)
	{
		// TODO: derived interfaces should probably just transmit the data immediately, or do their own send buffering
		//       ...so, maybe delete all this send buffering code!

		if (packet.length == 0)
			return 0;
		if (packet.length > sendBufferLen)
			return -1;
		while (packet.length > sendAvail())
		{
			final switch (sendBehaviour)
			{
				case BufferOverflowBehaviour.Fail:
					return -1;
				case BufferOverflowBehaviour.DropOldest:
					sendBufferReadCursor += sendQueue[0].length;
					if (sendBufferReadCursor >= sendBufferLen)
						sendBufferReadCursor -= sendBufferLen;
					sendQueue = sendQueue[1 .. $];
					break;
				case BufferOverflowBehaviour.DropNewest:
					return 0; // TODO: should this return 0, or should return packet.length? (ie, indicate it was sent, but drop it)
			}
		}

		if (sendBufferWriteCursor + packet.length > sendBufferLen)
		{
			size_t split = sendBufferLen - sendBufferWriteCursor;
			sendBuffer[sendBufferWriteCursor .. sendBufferLen] = packet[0 .. split];
			sendBuffer[0 .. packet.length - split] = packet[split .. $];
		}
		else
			sendBuffer[sendBufferWriteCursor .. sendBufferWriteCursor + packet.length] = packet[];

		assert(false, "TODO: we can't split the packet, we need to wrap and palce the whole thing at the start, and synth a packet struct...");

		return packet.length;
	}

	ptrdiff_t recv(void[] buffer, MonoTime* timestamp)
	{
		if (recvQueue.empty)
			return 0;

		size_t packetLen = recvQueue[0].length;
		if (!buffer.ptr)
			return packetLen;
		if (buffer.length < packetLen)
			return -1;

		if (timestamp)
			*timestamp = recvQueue[0].creationTime;

		buffer[0 .. packetLen] = recvQueue[0].data;
		recvBufferReadCursor = (recvBufferReadCursor + packetLen) % recvBufferLen;

		recvQueue = recvQueue[1 .. $];

		return packetLen;
	}

package:
	Packet[] recvQueue;
	Packet[] sendQueue;

	void* buffer;

	uint sendBufferLen = 32 * 1024;
	uint recvBufferLen = 64 * 1024;
	uint sendBufferReadCursor;
	uint sendBufferWriteCursor;
	uint recvBufferReadCursor;
	uint recvBufferWriteCursor;

	final void[] sendBuffer() => buffer[0 .. sendBufferLen];
	final void[] recvBuffer() => buffer[sendBufferLen .. sendBufferLen + recvBufferLen];

	final size_t sendAvail() => sendBufferWriteCursor > sendBufferReadCursor ? sendBufferLen - sendBufferWriteCursor + sendBufferReadCursor : sendBufferReadCursor - sendBufferWriteCursor;
	final size_t sendUse() => sendBufferWriteCursor > sendBufferReadCursor ? sendBufferWriteCursor - sendBufferReadCursor : sendBufferLen - sendBufferReadCursor + sendBufferWriteCursor;
	final size_t recvAvail() => recvBufferWriteCursor > recvBufferReadCursor ? recvBufferLen - recvBufferWriteCursor + recvBufferReadCursor : recvBufferReadCursor - recvBufferWriteCursor;
	final size_t recvUse() => recvBufferWriteCursor > recvBufferReadCursor ? recvBufferWriteCursor - recvBufferWriteCursor : recvBufferLen - recvBufferReadCursor + recvBufferWriteCursor;

	Packet* createPacket(MonoTime creationTime, ushort etherType, const(void)[] packet)
	{
		if (packet.length > recvBufferLen - recvBufferWriteCursor)
		{
			// we won't split the message, we'll just discard data until there's enough room at the start of the buffer again
			while (recvBufferReadCursor < packet.length)
			{
				final switch (recvBehaviour)
				{
					case BufferOverflowBehaviour.DropOldest:
						recvBufferReadCursor += recvQueue[0].length;
						if (recvBufferReadCursor >= recvBufferLen)
							recvBufferReadCursor -= recvBufferLen;
						recvQueue = recvQueue[1 .. $];
						break;
					case BufferOverflowBehaviour.DropNewest:
						assert(false);
						break;
					case BufferOverflowBehaviour.Fail:
						assert(false);
						break;
				}
			}
			recvBufferWriteCursor = 0;
		}

		void[] bufferedMessage = recvBuffer[recvBufferWriteCursor .. recvBufferWriteCursor + packet.length];
		recvBufferWriteCursor += packet.length;

		bufferedMessage[] = packet[];

		recvQueue ~= Packet();
		Packet* p = &recvQueue[$-1];
		p.creationTime = creationTime;
		p.etherType = etherType;
		p.length = cast(ushort)bufferedMessage.length;
		p.ptr = bufferedMessage.ptr;
		return p;
	}
}


class InterfaceModule : Plugin
{
	mixin RegisterModule!"interface";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		override void init()
		{
			app.console.registerCommand("/", new InterfaceCommand(app.console, this));
		}
	}
}


private:

class InterfaceCommand : Collection
{
	import manager.console.expression;

	InterfaceModule.Instance instance;

	this(ref Console console, InterfaceModule.Instance instance)
	{
		import urt.mem.string;

		super(console, StringLit!"interface", cast(Collection.Features)(Collection.Features.AddRemove | Collection.Features.SetUnset | Collection.Features.EnableDisable | Collection.Features.Print | Collection.Features.Comment));
		this.instance = instance;
	}

	override const(char)[][] getItems()
	{
		return null;
	}

	override void add(KVP[] params)
	{
		int x = 0;
	}

	override void remove(const(char)[] item)
	{
		int x = 0;
	}

	override void set(const(char)[] item, KVP[] params)
	{
		int x = 0;
	}

	override void print(KVP[] params)
	{
		int x = 0;
	}
}

