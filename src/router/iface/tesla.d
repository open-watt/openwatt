module router.iface.tesla;

import urt.mem;
import urt.string;
import urt.string.format;
import urt.time;

import manager.console;
import manager.instance;
import manager.plugin;

import protocol.tesla.twc;

import router.iface;
import router.iface.packet;
import router.stream;

// TODO: delete this nonsense!
import router.tesla.twc;


struct DeviceMap
{
	String name;
	MACAddress mac;
	ushort address;
	TeslaInterface iface;
}

class TeslaInterface : BaseInterface
{
	Stream stream;

	this(InterfaceModule.Instance m, String name, Stream stream) nothrow @nogc
	{
		super(m, name, StringLit!"tesla-twc");
		this.stream = stream;
	}

	override void update()
	{
		if (!stream.connected)
			return;

		MonoTime now = getTime();

		ubyte[1024] buffer = void;
		ptrdiff_t bytes = stream.read(buffer);
		if (bytes < 0)
		{
			assert(false, "what causes read to fail?");
			// TODO...
		}
		if (bytes == 0)
			return;

		size_t offset = 0;
		while (offset < bytes)
		{
			// scan for start of message
			while (offset < bytes && buffer[offset] != 0xC0)
				++offset;
			size_t end = offset + 1;
			for (; end < bytes; ++end)
			{
				if (buffer[end] == 0xC0)
					break;
			}

			if (offset == bytes || end == bytes)
			{
				if (bytes != buffer.length || offset == 0)
					break;
				for (size_t i = offset; i < bytes; ++i)
					buffer[i - offset] = buffer[i];
				bytes = bytes - offset;
				offset = 0;
				bytes += stream.read(buffer[bytes .. $]);
				continue;
			}

			ubyte[] msg = buffer[offset + 1 .. end];
			offset = end;

			// let's check if the message looks valid...
			if (msg.length < 13)
				continue;
			msg = unescapeMsg(msg);
			if (!msg)
				continue;
			ubyte checksum = 0;
			for (size_t i = 1; i < msg.length - 1; i++)
				checksum += msg[i];
			if (checksum != msg[$ - 1])
				continue;
			msg = msg[0 .. $-1];

			// we seem to have a valid packet...
			incomingPacket(msg, now);
		}
	}

	override bool forward(ref const Packet packet) nothrow @nogc
	{
		if (packet.etherType != EtherType.ENMS || packet.etherSubType != ENMS_SubType.TeslaTWC)
			return false;

		const(ubyte)[] msg = cast(ubyte[])packet.data;

		ubyte[64] t = void;
		size_t offset = 1;
		ubyte checksum = 0;

		t[0] = 0xC0;
		for (size_t i = 0; i < msg.length; i++)
		{
			if (i > 0)
				checksum += msg.ptr[i];
			if (msg.ptr[i] == 0xC0)
			{
				t[offset++] = 0xDB;
				t[offset++] = 0xDC;
			}
			else if (msg.ptr[i] == 0xDB)
			{
				t[offset++] = 0xDB;
				t[offset++] = 0xDD;
			}
			else
				t[offset++] = msg.ptr[i];
		}
		t[offset++] = checksum;
		t[offset++] = 0xC0;

		// It works without this byte, but I always receive it from a real device!
		t[offset++] = 0xFD;

		size_t written = stream.write(t[0..offset]);
		if (written != offset)
		{
			assert(written == offset, "Write failed?");
			return false;
		}

		++status.sendPackets;
		status.sendBytes += packet.data.length;
		// TODO: but should we record the ACTUAL protocol packet?
		return true;
	}

private:

	final void incomingPacket(const(ubyte)[] msg, MonoTime recvTime)
	{
		// we need to extract the sender/receiver addresses...
		TWCMessage message;
		bool r = msg.parseTWCMessage(message);
		if (!r)
			return;

		Packet p = Packet(msg);
		p.creationTime = recvTime;
		p.etherType = EtherType.ENMS;
		p.etherSubType = ENMS_SubType.TeslaTWC;

		auto tesla = mod_iface.app.moduleInstance!TeslaInterfaceModule();

		DeviceMap* map = tesla.findServerByAddress(message.sender);
		if (!map)
			map = tesla.addDevice(null, this, message.sender);
		p.src = map.mac;

		if (!message.receiver)
			p.dst = MACAddress.broadcast;
		else
		{
			// find receiver... do we have a global device registry?
			map = tesla.findServerByAddress(message.receiver);
			if (!map)
			{
				// we haven't seen the other guy, so we can't assign a dst address
				return;
			}
			p.dst = map.mac;
		}

		if (p.dst)
			dispatch(p);
	}
}


class TeslaInterfaceModule : Plugin
{
	mixin RegisterModule!"interface.tesla-twc";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		DeviceMap[ushort] devices;

		override void init()
		{
			app.console.registerCommand!add("/interface/tesla-twc", this);
		}

		void add(Session session, const(char)[] name, const(char)[] stream)
		{
			Stream s = app.moduleInstance!StreamModule.getStream(stream);
			if (!s)
			{
				session.writeLine("Stream does not exist: ", stream);
				return;
			}

			if (name.empty)
				name = app.moduleInstance!InterfaceModule.generateInterfaceName("tesla-twc");
			String n = name.makeString(defaultAllocator());

			TeslaInterface iface = defaultAllocator.allocT!TeslaInterface(app.moduleInstance!InterfaceModule, n.move, s);
			app.moduleInstance!InterfaceModule().addInterface(iface);

			import urt.log;
			debug writeDebugf("Create tesla-twc interface {0} - '{1}'", iface.mac, name);

			// HACK: we'll print packets that we receive...
			iface.subscribe((ref const Packet p, BaseInterface i) {
				import urt.io;
				writef("{0}: TWC packet received {1}-->{2} [{3}]\n", i.name, p.src, p.dst, p.data);
			}, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.TeslaTWC));
		}


		DeviceMap* findServerByName(const(char)[] name) nothrow @nogc
		{
			try foreach (ref map; devices)
			{
				if (map.name[] == name)
					return &map;
			}
			catch(Exception) {}
			return null;
		}

		DeviceMap* findServerByMac(MACAddress mac) nothrow @nogc
		{
			try foreach (ref map; devices)
			{
				if (map.mac == mac)
					return &map;
			}
			catch(Exception) {}
			return null;
		}

		DeviceMap* findServerByAddress(ushort address) nothrow @nogc
		{
			return address in devices;
		}

		DeviceMap* addDevice(const(char)[] name, TeslaInterface iface, ushort address)
		{
			if (!name)
				name = tformat("{0}.{1,04X}", iface.name[], address);

			DeviceMap map;
			map.name = name.makeString(defaultAllocator());
			map.address = address;
			map.mac = iface.generateMacAddress();
			map.mac.b[4] = address >> 8;
			map.mac.b[5] = address & 0xFF;
//			while (findMacAddress(map.mac) !is null)
//				++map.mac.b[5];
			map.iface = iface;

			devices[address] = map;
			iface.addAddress(map.mac, iface);

			return address in devices;
		}
	}
}


private:
