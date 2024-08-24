module router.iface.modbus;

import urt.mem;
import urt.string;
import urt.string.format;
import urt.time;

import manager.console;
import manager.instance;
import manager.plugin;

import router.iface;
import router.iface.packet;
import router.modbus.message;
import router.stream;


enum ModbusProtocol : byte
{
	Unknown = -1,
	RTU,
	TCP,
	ASCII
}

struct ServerMap
{
	String name;
	MACAddress mac;
	ubyte localAddress;
	ubyte universalAddress;
}

struct ModbusRequest
{
	MonoTime requestTime;
	MACAddress requestFrom;
	ubyte localServerAddress;
	ushort sequenceNumber;
	Packet* bufferedPacket;
}

class ModbusInterface : BaseInterface
{
	Stream stream;

	ModbusProtocol protocol;
	bool isBusMaster;

	ServerMap[] servers;

	// if we are the bus master
	ModbusRequest[] pendingRequests;

	// if we are not the bus master
	MACAddress masterMac;
	ModbusFrameType expectMessageType = ModbusFrameType.Unknown;

	this(String name, Stream stream, ModbusProtocol protocol, bool isMaster)
	{
		super(name, StringLit!"modbus");
		this.stream = stream;
		this.protocol = protocol;
		this.isBusMaster = isMaster;

		sendBufferLen = 4 * 1024;
		recvBufferLen = 4 * 1024;

		buffer = defaultAllocator.alloc(sendBufferLen + recvBufferLen).ptr;

		if (!isMaster)
			masterMac = generateMac(name, 0xFF);

		// TODO: warn the user if they configure an interface to use modbus tcp over a serial line
		//       user needs to be warned that data corruption may occur!

		// TODO: assert that recvBufferLen and sendBufferLen are both larger than a single PDU (254 bytes)!
	}

	override void update()
	{
		if (!stream.connected)
			return;

		MonoTime now = getTime();

		ubyte[1024] buffer = void;
		buffer[0 .. tailBytes] = tail[0 .. tailBytes];
		ptrdiff_t readOffset = tailBytes;
		ptrdiff_t length = tailBytes;
		tailBytes = 0;
		read_loop: do
		{
			assert(length < 260);

			ptrdiff_t r = stream.read(buffer[readOffset .. $]);
			if (r < 0)
			{
				assert(false, "what causes read to fail?");
				break read_loop;
			}
			if (r == 0)
			{
				// if there were no extra bytes available, stash the tail until later
				tail[0 .. length] = buffer[0 .. length];
				tailBytes = cast(ushort)length;
				break read_loop;
			}
			length += r;
			assert(length <= buffer.sizeof);

//			if (connParams.logDataStream)
//				logStream.rawWrite(buffer[0 .. length]);

			size_t offset = 0;
			while (offset < length)
			{
				// parse packets from the stream...
				const(void)[] message = void;
				ModbusFrameInfo frameInfo = void;
				size_t taken = 0;
				final switch (protocol)
				{
					case ModbusProtocol.Unknown:
						assert(false, "Modbus protocol not specified");
						break;
					case ModbusProtocol.RTU:
						taken = parseRTU(buffer[offset .. length], message, frameInfo);
						break;
					case ModbusProtocol.TCP:
						taken = parseTCP(buffer[offset .. length], message, frameInfo);
						break;
					case ModbusProtocol.ASCII:
						taken = parseASCII(buffer[offset .. length], message, frameInfo);
						break;
				}

				if (taken == 0)
				{
					readOffset = length - offset;
					buffer[0 .. readOffset] = buffer[offset .. length];
					length = readOffset;
					offset = 0;
					assert(length < 260);
					continue read_loop;
				}

				// drop the address byte since we have it in frameInfo...
				message = message[1 .. $];

				MACAddress targetMac = void;
				if (frameInfo.address == 0)
					targetMac = MACAddress([0xFF,0xFF,0xFF,0xFF,0xFF,0xFF]);
				else
				{
					ServerMap* map = findServerByLocalAddress(frameInfo.address);
					if (!map)
					{
						// apparently this is the first time we've seen this guy...
						//							map = defaultAllocator.allocT!ServerMap();
						servers ~= ServerMap();
						map = &servers[$-1];

						map.name = tconcat(name[], '.', map.localAddress).makeString(defaultAllocator());
						map.localAddress = frameInfo.address;
						map.mac = generateMac(name, map.localAddress);
						map.universalAddress = map.mac.b[5];
					}
					targetMac = map.mac;
				}

				if (isBusMaster)
				{
					// if we ARE the bus master, then we expect to receive packets in response to queued requests
					// those queued requests will know the dest mac address...


				}
				else
				{

					// TODO: if the time since the last packet is longer than the modbus timeout,
					//       we should ignore expectMessageType and expect a request packet..

					ModbusFrameType type = frameInfo.frameType;
					if (type == ModbusFrameType.Unknown)
						type = expectMessageType;

					// we can't buffer this message if we don't know if its a request or a response...
					// we'll need to discard messages until we get one that we know, and then we can predict future messages from there...
					if (type != ModbusFrameType.Unknown)
					{
						Packet* p = createPacket(now, EtherType.ENMS, message);
						p.src = type == ModbusFrameType.Request ? masterMac : targetMac;
						p.dst = type == ModbusFrameType.Request ? targetMac : masterMac;
						p.etherSubType = ENMS_SubType.Modbus;

						expectMessageType = type == ModbusFrameType.Request ? ModbusFrameType.Response : ModbusFrameType.Request;
					}
					else
					{
						assert(false);
					}
				}

				offset += taken;

				// TODO: some debug logging of the incoming packet stream?
				import urt.log;
//				debug writeDebug("Modbus packet received from interface: '", name, "' (", message.length, ")[ ", message[], " ]");
			}

			// we've eaten the whole buffer...
			length = 0;
		}
		while (true);
	}

private:
	ubyte[260] tail;
	ushort tailBytes;

	MACAddress generateMac(const(char)[] name, ubyte localAddress)
	{
		uint crc = name.ethernetCRC();
		return MACAddress([0x02, 0x13, 0x37, crc & 0xFF, (crc >> 8) & 0xFF, localAddress]);
	}

	ServerMap* findServerByMac(MACAddress mac)
	{
		foreach (ref s; servers)
		{
			if (s.mac == mac)
				return &s;
		}
		return null;
	}

	ServerMap* findServerByLocalAddress(ubyte localAddress)
	{
		foreach (ref s; servers)
		{
			if (s.localAddress == localAddress)
				return &s;
		}
		return null;
	}

	ServerMap* findServerByUniversalAddress(ubyte universalAddress)
	{
		foreach (ref s; servers)
		{
			if (s.universalAddress == universalAddress)
				return &s;
		}
		return null;
	}
}


class ModbusInterfaceModule : Plugin
{
	mixin RegisterModule!"interface.modbus";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		BaseInterface[String] interfaces;

		override void init()
		{
			app.console.registerCommand("/interface", new ModbusInterfaceCommand(app.console, this));
		}

		override void update()
		{
			foreach (ref i; interfaces)
				i.update();
		}
	}
}


private:

class ModbusInterfaceCommand : Collection
{
	import manager.console.expression;

	ModbusInterfaceModule.Instance instance;

	this(ref Console console, ModbusInterfaceModule.Instance instance)
	{
		import urt.mem.string;

		super(console, StringLit!"modbus", cast(Collection.Features)(Collection.Features.AddRemove | Collection.Features.SetUnset | Collection.Features.EnableDisable | Collection.Features.Print | Collection.Features.Comment));
		this.instance = instance;
	}

	override const(char)[][] getItems()
	{
		return null;
	}

	override void add(KVP[] params)
	{
		String name;
		Stream stream;
		ModbusProtocol protocol = ModbusProtocol.Unknown;
		bool master = false;

		foreach (ref p; params)
		{
			if (p.k.type != Token.Type.Identifier)
				goto bad_parameter;
			switch (p.k.token[])
			{
				case "name":
					if (p.v.type == Token.Type.String)
						name = p.v.token[].unQuote.makeString(defaultAllocator());
					else
						name = p.v.token[].makeString(defaultAllocator());
					break;
					// TODO: confirm that the stream does not already exist!
				case "stream":
					const(char)[] streamName;
					if (p.v.type == Token.Type.String)
						streamName = p.v.token[].unQuote;
					else
						streamName = p.v.token[];

					stream = instance.app.moduleInstance!StreamModule.getStream(streamName);

					if (!stream)
					{
						session.writeLine("Stream does not exist: ", streamName);
						return;
					}
					break;
				case "protocol":
					switch (p.v.token[])
					{
						case "rtu":
							protocol = ModbusProtocol.RTU;
							break;
						case "tcp":
							protocol = ModbusProtocol.TCP;
							break;
						case "ascii":
							protocol = ModbusProtocol.ASCII;
							break;
						default:
							session.writeLine("Invalid modbus protocol '", p.v.token, "', expect 'rtu|tcp|ascii'.");
							return;
					}
					break;
				case "master":
					master = p.v.token[] == "true";
					break;
				default:
				bad_parameter:
					session.writeLine("Invalid parameter name: ", p.k.token);
					return;
			}
		}

		if (name.empty)
		{
			foreach (i; 0 .. ushort.max)
			{
				const(char)[] tname = i == 0 ? "modbus" : tconcat("modbus", i);
				if (tname.makeString(tempAllocator()) !in instance.interfaces)
				{
					name = tname.makeString(defaultAllocator());
					break;
				}
			}
		}

		if (protocol == ModbusProtocol.Unknown)
		{
			if (stream.type == "tcp-client") // TODO: UDP here too... but what is the type called?
				protocol = ModbusProtocol.TCP;
			else
				protocol = ModbusProtocol.RTU;
		}

		instance.interfaces[name] = new ModbusInterface(name, stream, protocol, master);
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


enum ModbusFrameType : ubyte
{
	Unknown,
	Request,
	Response
}

struct ModbusFrameInfo
{
	ubyte address;
	FunctionCode functionCode;
	ExceptionCode exceptionCode = ExceptionCode.None;
	ModbusFrameType frameType = ModbusFrameType.Unknown;
}

__gshared immutable ushort[25] functionLens = [
	0x0000, 0x2306, 0x2306, 0x2306, 0x2306, 0x0606, 0x0606, 0x0302,
	0xFFFF, 0xFFFF, 0xFFFF, 0x0602, 0x2302, 0xFFFF, 0xFFFF, 0x0667,
	0x0667, 0x2302, 0xFFFF, 0xFFFF, 0x3232, 0x3232, 0x0808, 0x23AB,
	0x3404
];

int parseFrame(const(ubyte)[] data, out ModbusFrameInfo frameInfo)
{
	if (data.length < 4)
		return 0;

	// check the address is in the valid range
	ubyte address = data[0];
	if (address >= 248 && address <= 255)
		return 0;
	frameInfo.address = address;

	// frames must start with a valid function code...
	ubyte f = data[1];
	FunctionCode fc = cast(FunctionCode)(f & 0x7F);
	ushort fnData = fc < functionLens.length ? functionLens[f] : fc == 0x2B ? 0xFFFF : 0;
	if (fnData == 0)
		return 0;
	frameInfo.functionCode = fc;

	// exceptions are always 3 bytes
	ubyte reqLength = void;
	ubyte resLength = void;
	if (f & 0x80)
	{
		frameInfo.exceptionCode = cast(ExceptionCode)data[2];
		frameInfo.frameType = ModbusFrameType.Response;
		reqLength = 3;
		resLength = 3;
	}

	// zero bytes (broadcast address) are common in data streams, and if the function code can't broadcast, we can exclude this packet
	// NOTE: this can only catch 10 bad bytes in the second byte position... maybe not worth the if()?
//	else if (address == 0 && (fFlags & 2) == 0)
//	{
//		frameId.invalidFrame = true;
//		return false;
//	}

	// if the function code can determine the length...
	else if (fnData != 0xFFFF)
	{
		// TODO: we can instead load these bytes separately if the bit-shifting is worse than loads...
		reqLength = fnData & 0xF;
		ubyte reqExtra = (fnData >> 4) & 0xF;
		resLength = (fnData >> 8) & 0xF;
		ubyte resExtra = fnData >> 12;
		if (reqExtra && reqExtra < data.length)
			reqLength += data[reqExtra];
		if (resExtra)
			resLength += data[resExtra];
	}
	else
	{
		// scan for a CRC...
		assert(false);
	}

	int failResult = 0;
	if (reqLength != resLength)
	{
		ubyte length = void, smallerLength = void;
		ModbusFrameType type = void, smallerType = void;
		if (reqLength > resLength)
		{
			length = reqLength;
			smallerLength = resLength;
			type = ModbusFrameType.Request;
			smallerType = ModbusFrameType.Response;
		}
		else
		{
			length = resLength;
			smallerLength = reqLength;
			type = ModbusFrameType.Response;
			smallerType = ModbusFrameType.Request;
		}

		if (data.length >= length + 2)
		{
			uint crc2 = calculateModbusCRC2(data[0 .. length], smallerLength);

			if ((crc2 >> 16) == (data[smallerLength] | cast(ushort)data[smallerLength + 1] << 8))
			{
				frameInfo.frameType = smallerType;
				return smallerLength;
			}
			if ((crc2 & 0xFFFF) == (data[length] | cast(ushort)data[length + 1] << 8))
			{
				frameInfo.frameType = type;
				return length;
			}
			return 0;
		}
		else
		{
			failResult = -1;
			reqLength = smallerLength;
			frameInfo.frameType = smallerType;
		}
	}

	// check we have enough data...
	if (data.length < reqLength + 2)
		return -1;

	ushort crc = calculateModbusCRC(data[0 .. reqLength]);

	if (crc == (data[reqLength] | cast(ushort)data[reqLength + 1] << 8))
		return reqLength;

	return failResult;
}


size_t parseRTU(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frameInfo)
{
	// the stream might have corruption or noise, RTU frames could be anywhere, so we'll scan forward searching for the next frame...
	// RTU has no sync markers, so we need to get pretty creative!
	// 1: packets are delimited by a 2-byte CRC, so any sequence of bytes where the running CRC is followed by 2 bytes with that value might be a frame...
	// 2: but 2-byte CRC's aren't good enough protection against false positives! (they appear semi-regularly), so...
	// 3:  a. we can exclude packets that start with an invalid function code
	//     b. we can exclude packets to the broadcast address (0), with a function code that can't broadcast
	//     c. we can then try and determine the expected packet length, and check the CRC only at the length offsets
	//     d. failing all that, we can crawl the buffer for a CRC...
	//     e. if we don't find a packet, repeat starting at the next BYTE...

	// ... losing stream sync might have a high computational cost!
	// we might determine that in practise it's superior to just drop the whole buffer and wait for new data which is probably aligned to the bitstream to arrive?


	// NOTE: it's also worth noting, that some of our stream validity checks exclude non-standard protocol...
	//       for instance, we exclude any function code that's not in the spec. What if an implementation invents their own function codes?
	//       maybe it should be an interface flag to control whether it accepts non-standard streams, and relax validation checking?

	if (data.length < 4)
		return 0;

	size_t offset = 0;
	for (; offset < data.length - 4; ++offset)
	{
		int length = parseFrame(data[offset .. data.length], frameInfo);
		if (length < 0)
			return 0;
		if (length == 0)
			continue;

		message = data[offset .. offset + length];
		return length + 2;
	}

	// no packet was found in the stream... how odd!
	return 0;
}

size_t parseTCP(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frameInfo)
{
	return 0;
}

size_t parseASCII(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frameInfo)
{
	return 0;
}

/+

inout(ubyte)[] crawlForRTU(inout(ubyte)[] data, ushort* rcrc = null)
{
	if (data.length < 4)
		return null;

	enum NumCRC = 8;
	ushort[NumCRC] foundCRC = void;
	size_t[NumCRC] foundCRCPos = void;
	int numfoundCRC = 0;

	// crawl through the buffer accumulating a CRC and looking for the following bytes to match
	ushort crc = 0xFFFF;
	ushort next = data[0] | cast(ushort)data[1] << 8;
	size_t len = data.length < 256 ? data.length : 256;
	for (size_t pos = 2; pos < len; )
	{
		ubyte index = (next & 0xFF) ^ cast(ubyte)crc;
		crc = (crc >> 8) ^ crc_table[index];

		// get the next word in sequence
		next = next >> 8 | cast(ushort)data[pos++] << 8;

		// if the running CRC matches the next word, we probably have an RTU packet delimiter
		if (crc == next)
		{
			foundCRC[numfoundCRC] = crc;
			foundCRCPos[numfoundCRC++] = pos;
			if (numfoundCRC == NumCRC)
				break;
		}
	}

	if (numfoundCRC > 0)
	{
		int bestMatch = 0;

		// TODO: this is a lot of code!
		// we should do some statistics to work out which conditions actually lead to better outcomes and compress the logic to only what is iecessary

		if (numfoundCRC > 1)
		{
			// if we matched multiple CRC's in the buffer, then we need to work out which CRC is not a false-positive...
			int[NumCRC] score;
			for (int i = 0; i < numfoundCRC; ++i)
			{
				// if the CRC is at the end of the buffer, we have a single complete message, and that's a really good indicator
				if (foundCRCPos[i] == data.length)
					score[i] += 10;
				else if (foundCRCPos[i] <= data.length - 2)
				{
					// we can check the bytes following the CRC appear to begin a new message...
					// confirm the function code is valid
					if (validFunctionCode(cast(FunctionCode)data[foundCRCPos[i] + 1]))
						score[i] += 5;
					// we can also give a nudge if the address looks plausible
					ubyte addr = data[foundCRCPos[i]];
					if (addr <= 247)
					{
						if (addr == 0)
							score[i] += 1; // broadcast address is unlikely
						else if (addr <= 4 || addr >= 245)
							score[i] += 3; // very small or very big addresses are more likely
						else
							score[i] += 2;
					}
				}
			}
			for (int i = 1; i < numfoundCRC; ++i)
			{
				if (score[i] > score[i - 1])
					bestMatch = i;
			}
		}

		if (rcrc)
			*rcrc = foundCRC[bestMatch];
		return data[0 .. foundCRCPos[bestMatch]];
	}

	// didn't find anything...
	return null;
}
+/

ushort calculateModbusCRC(const ubyte[] buf)
{
	ushort crc = 0xFFFF;
	for (size_t i = 0; i < buf.length; ++i)
	{
		ubyte index = buf.ptr[i] ^ cast(ubyte)crc;
		crc = (crc >> 8) ^ crc_table[index];
	}
	return crc;
}

uint calculateModbusCRC2(const ubyte[] buf, uint earlyOffset)
{
	ushort highCRC = 0x0000;
	ushort crc = 0xFFFF;
	for (size_t i = 0; i < buf.length; ++i)
	{
		if (i == earlyOffset)
			highCRC = crc;

		ubyte index = buf.ptr[i] ^ cast(ubyte)crc;
		crc = (crc >> 8) ^ crc_table[index];
	}
	return crc | highCRC << 16;
}

immutable ushort[256] crc_table = [
	0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241,
	0xC601, 0x06C0, 0x0780, 0xC741, 0x0500, 0xC5C1, 0xC481, 0x0440,
	0xCC01, 0x0CC0, 0x0D80, 0xCD41, 0x0F00, 0xCFC1, 0xCE81, 0x0E40,
	0x0A00, 0xCAC1, 0xCB81, 0x0B40, 0xC901, 0x09C0, 0x0880, 0xC841,
	0xD801, 0x18C0, 0x1980, 0xD941, 0x1B00, 0xDBC1, 0xDA81, 0x1A40,
	0x1E00, 0xDEC1, 0xDF81, 0x1F40, 0xDD01, 0x1DC0, 0x1C80, 0xDC41,
	0x1400, 0xD4C1, 0xD581, 0x1540, 0xD701, 0x17C0, 0x1680, 0xD641,
	0xD201, 0x12C0, 0x1380, 0xD341, 0x1100, 0xD1C1, 0xD081, 0x1040,
	0xF001, 0x30C0, 0x3180, 0xF141, 0x3300, 0xF3C1, 0xF281, 0x3240,
	0x3600, 0xF6C1, 0xF781, 0x3740, 0xF501, 0x35C0, 0x3480, 0xF441,
	0x3C00, 0xFCC1, 0xFD81, 0x3D40, 0xFF01, 0x3FC0, 0x3E80, 0xFE41,
	0xFA01, 0x3AC0, 0x3B80, 0xFB41, 0x3900, 0xF9C1, 0xF881, 0x3840,
	0x2800, 0xE8C1, 0xE981, 0x2940, 0xEB01, 0x2BC0, 0x2A80, 0xEA41,
	0xEE01, 0x2EC0, 0x2F80, 0xEF41, 0x2D00, 0xEDC1, 0xEC81, 0x2C40,
	0xE401, 0x24C0, 0x2580, 0xE541, 0x2700, 0xE7C1, 0xE681, 0x2640,
	0x2200, 0xE2C1, 0xE381, 0x2340, 0xE101, 0x21C0, 0x2080, 0xE041,
	0xA001, 0x60C0, 0x6180, 0xA141, 0x6300, 0xA3C1, 0xA281, 0x6240,
	0x6600, 0xA6C1, 0xA781, 0x6740, 0xA501, 0x65C0, 0x6480, 0xA441,
	0x6C00, 0xACC1, 0xAD81, 0x6D40, 0xAF01, 0x6FC0, 0x6E80, 0xAE41,
	0xAA01, 0x6AC0, 0x6B80, 0xAB41, 0x6900, 0xA9C1, 0xA881, 0x6840,
	0x7800, 0xB8C1, 0xB981, 0x7940, 0xBB01, 0x7BC0, 0x7A80, 0xBA41,
	0xBE01, 0x7EC0, 0x7F80, 0xBF41, 0x7D00, 0xBDC1, 0xBC81, 0x7C40,
	0xB401, 0x74C0, 0x7580, 0xB541, 0x7700, 0xB7C1, 0xB681, 0x7640,
	0x7200, 0xB2C1, 0xB381, 0x7340, 0xB101, 0x71C0, 0x7080, 0xB041,
	0x5000, 0x90C1, 0x9181, 0x5140, 0x9301, 0x53C0, 0x5280, 0x9241,
	0x9601, 0x56C0, 0x5780, 0x9741, 0x5500, 0x95C1, 0x9481, 0x5440,
	0x9C01, 0x5CC0, 0x5D80, 0x9D41, 0x5F00, 0x9FC1, 0x9E81, 0x5E40,
	0x5A00, 0x9AC1, 0x9B81, 0x5B40, 0x9901, 0x59C0, 0x5880, 0x9841,
	0x8801, 0x48C0, 0x4980, 0x8941, 0x4B00, 0x8BC1, 0x8A81, 0x4A40,
	0x4E00, 0x8EC1, 0x8F81, 0x4F40, 0x8D01, 0x4DC0, 0x4C80, 0x8C41,
	0x4400, 0x84C1, 0x8581, 0x4540, 0x8701, 0x47C0, 0x4680, 0x8641,
	0x8201, 0x42C0, 0x4380, 0x8341, 0x4100, 0x81C1, 0x8081, 0x4040
];
