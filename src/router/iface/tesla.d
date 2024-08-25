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
}

class TeslaInterface : BaseInterface
{
	Stream stream;

	DeviceMap[] devices;

	this(InterfaceModule.Instance m, String name, Stream stream)
	{
		super(m, name, StringLit!"tesla-twc");
		this.stream = stream;

		// how much buffer do we need? messages are 17-19 bytes...
		sendBufferLen = 512;
		buffer = defaultAllocator.alloc(sendBufferLen).ptr;
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

			// we need to extract the sender/receiver addresses...
			TWCMessage message;
			bool r = msg.parseTWCMessage(message);
			if (!r)
				return;

			Packet p = Packet(msg);
			p.creationTime = now;
			p.etherType = EtherType.ENMS;
			p.etherSubType = ENMS_SubType.TeslaTWC;

			DeviceMap* map = findServerByAddress(message.sender);
			if (!map)
			{
				devices ~= DeviceMap();
				map = &devices[$-1];

				map.name = tformat("{0}.{1,04X}", name[], message.sender).makeString(defaultAllocator());
				map.address = message.sender;
				map.mac = generateMac(name, message.sender);
			}
			p.src = map.mac;

			if (!message.receiver)
			{
				p.dst = MACAddress.broadcast;
			}
			else
			{
				map = findServerByAddress(message.receiver);
				if (!map)
				{
					devices ~= DeviceMap();
					map = &devices[$-1];

					map.name = tformat("{0}.{1,04X}", name[], message.sender).makeString(defaultAllocator());
					map.address = message.sender;
					map.mac = generateMac(name, message.sender);
				}
				p.dst = map.mac;
			}

			dispatch(p);
		}
	}

private:
	MACAddress generateMac(const(char)[] name, ushort address)
	{
		uint crc = name.ethernetCRC();
		return MACAddress(0x02, 0x13, 0x37, crc & 0xFF, address >> 8, address & 0xFF);
	}

	DeviceMap* findServerByMac(MACAddress mac)
	{
		foreach (ref s; devices)
		{
			if (s.mac == mac)
				return &s;
		}
		return null;
	}

	DeviceMap* findServerByAddress(ushort address)
	{
		foreach (ref s; devices)
		{
			if (s.address == address)
				return &s;
		}
		return null;
	}
}


class TeslaInterfaceModule : Plugin
{
	mixin RegisterModule!"interface.tesla-twc";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		BaseInterface[String] interfaces;

		override void init()
		{
			app.console.registerCommand!add("/interface/tesla-twc", this);
		}

		override void update()
		{
			foreach (ref i; interfaces)
				i.update();
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
			{
				foreach (i; 0 .. ushort.max)
				{
					const(char)[] tname = i == 0 ? "tesla-twc" : tconcat("tesla-twc", i);
					if (tname.makeString(tempAllocator()) !in interfaces)
					{
						name = tname.makeString(defaultAllocator());
						break;
					}
				}
			}
			String n = name.makeString(defaultAllocator());

			interfaces[n] = new TeslaInterface(app.moduleInstance!InterfaceModule, n, s);

			// HACK: we'll print packets that we receive...
			interfaces[n].subscribe((ref const Packet p, BaseInterface i) {
				import urt.io;
				writef("{0}: TWC packet received {1}-->{2} [{3}]\n", i.name, p.src, p.dst, p.data);
			}, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.TeslaTWC));
		}
	}
}


private:
