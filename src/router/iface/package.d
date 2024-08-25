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
	alias FilterCallback = bool delegate(ref const Packet p) nothrow @nogc;

	MACAddress src;
	MACAddress dst;
	ushort etherType;
	ushort enmsSubType;
	ushort vlan;
	FilterCallback customFilter;

	bool match(ref Packet p)
	{
		if (etherType && p.etherType != etherType)
			return false;
		if (enmsSubType && p.etherSubType != enmsSubType)
			return false;
		if (vlan && p.vlan != vlan)
			return false;
		if (src && p.src != src)
			return false;
		if (dst && p.dst != dst)
			return false;
		if (customFilter)
			return customFilter(p);
		return true;
	}
}

struct InterfaceSubscriber
{
	alias IncomingPacketHandler = void delegate(ref const Packet p, BaseInterface i) nothrow @nogc;

	PacketFilter filter;
	IncomingPacketHandler recvPacket;
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
	InterfaceModule.Instance mod_iface;

	String name;
	String type;

	MACAddress mac;
	MACAddress[] discovered;

	InterfaceSubscriber[] subscribers;

	BufferOverflowBehaviour sendBehaviour;
	BufferOverflowBehaviour recvBehaviour;

	this(InterfaceModule.Instance m, String name, String type)
	{
		this.mod_iface = m;
		this.name = name;
		this.type = type;

		mac = MACAddress();
		mod_iface.addAddress(mac, this);
	}

	~this()
	{
		foreach(ref a; discovered)
			mod_iface.removeAddress(a);
		mod_iface.removeAddress(mac);
	}

	void update()
	{
	}

	final size_t packetsPending() => sendQueue.length;
	final size_t bytesPending() => sendUse();

	void subscribe(InterfaceSubscriber.IncomingPacketHandler packetHandler, PacketFilter filter)
	{
		subscribers ~= InterfaceSubscriber(filter, packetHandler);
	}

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

package:
	Packet[] sendQueue;

	void* buffer;

	uint sendBufferLen = 32 * 1024;
	uint sendBufferReadCursor;
	uint sendBufferWriteCursor;

	final void[] sendBuffer() => buffer[0 .. sendBufferLen];

	final size_t sendAvail() => sendBufferWriteCursor > sendBufferReadCursor ? sendBufferLen - sendBufferWriteCursor + sendBufferReadCursor : sendBufferReadCursor - sendBufferWriteCursor;
	final size_t sendUse() => sendBufferWriteCursor > sendBufferReadCursor ? sendBufferWriteCursor - sendBufferReadCursor : sendBufferLen - sendBufferReadCursor + sendBufferWriteCursor;

	size_t findMacAddress(MACAddress mac)
	{
		foreach (i, ref a; discovered)
		{
			if (a == mac)
				return i;
		}
		return -1;
	}

	void addMacAddress(MACAddress mac)
	{
		if (findMacAddress(mac) == -1)
		{
			discovered ~= mac;

			// add to global mac table!
		}
	}

	void dispatch(ref Packet packet)
	{
		// check if we ever saw the sender before...
		bool found = false;
		foreach (i, ref a; discovered)
		{
			if (packet.src == a)
			{
				found = true;
				break;
			}
		}
		if (!found)
		{
			discovered ~= packet.src;
			mod_iface.addAddress(packet.src, this);
		}

		foreach (ref subscriber; subscribers)
		{
			if (subscriber.filter.match(packet))
				subscriber.recvPacket(packet, this);
		}
	}
}


class InterfaceModule : Plugin
{
	mixin RegisterModule!"interface";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		BaseInterface[MACAddress] macTable;

		override void init()
		{
		}

		final void addAddress(MACAddress mac, BaseInterface iface)
		{
			macTable[mac] = iface;
		}

		final void removeAddress(MACAddress mac)
		{
			macTable.remove(mac);
		}

		final BaseInterface whoHas(MACAddress mac)
		{
			BaseInterface* i = mac in macTable;
			if (i)
				return *i;
			return null;
		}
	}
}


private:
