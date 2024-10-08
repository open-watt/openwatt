module router.iface.modbus;

import urt.array;
import urt.conv;
import urt.endian;
import urt.map;
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

enum ModbusFrameType : ubyte
{
	Unknown,
	Request,
	Response
}

struct ServerMap
{
	String name;
	MACAddress mac;
	ubyte localAddress;
	ubyte universalAddress;
	ModbusInterface iface;
}

struct ModbusRequest
{
	MonoTime requestTime;
	MACAddress requestFrom;
	ubyte localServerAddress;
	ushort sequenceNumber;
	const(Packet)* bufferedPacket;
}

class ModbusInterface : BaseInterface
{
nothrow @nogc:

	Stream stream;

	ModbusProtocol protocol;
	bool isBusMaster;
    ushort requestTimeout = 500; // default 500ms? longer?

	// if we are the bus master
	Array!ModbusRequest pendingRequests;

	// if we are not the bus master
	MACAddress masterMac;
	ModbusFrameType expectMessageType = ModbusFrameType.Unknown;

	this(InterfaceModule.Instance m, String name, Stream stream, ModbusProtocol protocol, bool isMaster) nothrow @nogc
	{
		super(m, name, StringLit!"modbus");
		this.stream = stream;
		this.protocol = protocol;
		this.isBusMaster = isMaster;

		if (!isMaster)
		{
			masterMac = generateMacAddress();
			masterMac.b[5] = 0xFF;
			addAddress(masterMac, this);

            // if we're not the master, we can't write to the bus unless we are responding...
            // and if the stream is TCP, we'll never know if the remote has dropped the connection
            // we'll enable keep-alive in tcp streams to to detect this...
            import router.stream.tcp : TCPStream;
            auto tcpStream = cast(TCPStream)stream;
            if (tcpStream)
                tcpStream.enableKeepAlive(true, seconds(10), seconds(1), 10);
		}

		status.linkStatusChangeTime = getTime();
		status.linkStatus = stream.connected;

		// TODO: warn the user if they configure an interface to use modbus tcp over a serial line
		//       user needs to be warned that data corruption may occur!

		// TODO: assert that recvBufferLen and sendBufferLen are both larger than a single PDU (254 bytes)!
	}

	override void update()
	{
		MonoTime now = getTime();

        // check for timeouts
        for (size_t i = 0; i < pendingRequests.length; )
        {
            auto req = &pendingRequests[i];
            if (now - req.requestTime > 500.msecs)
            {
                pendingRequests.remove(i);

                // TODO: do we need to send any queued messages?
//                assert(false);
            }
            else
                ++i;
        }

        // check the link status
        bool isConnected = stream.connected();
        if (isConnected != status.linkStatus)
        {
            status.linkStatus = isConnected;
            status.linkStatusChangeTime = now;
            if (!isConnected)
                ++status.linkDowns;
        }
        if (!isConnected)
            return;

		// check for data
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
				assert(false, "TODO: what causes read to fail?");
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
					memmove(buffer.ptr, buffer.ptr + offset, readOffset);
					length = readOffset;
					offset = 0;
					assert(length < 260);
					continue read_loop;
				}
				offset += taken;

				incomingPacket(message, now, frameInfo);
			}

			// we've eaten the whole buffer...
			length = 0;
		}
		while (true);
	}

	override bool forward(ref const Packet packet) nothrow @nogc
	{
		// can only handle modbus packets
		if (packet.etherType != EtherType.ENMS || packet.etherSubType != ENMS_SubType.Modbus)
        {
            ++status.sendDropped;
			return false;
        }

		auto modbus = mod_iface.app.moduleInstance!ModbusInterfaceModule();

		ushort length = 0;
		ubyte address = 0;
		ubyte[520] buffer;

		if (isBusMaster)
		{
			if (!packet.dst.isBroadcast)
			{
				ServerMap* map = modbus.findServerByMac(packet.dst);
				if (!map)
                {
                    ++status.sendDropped;
                    return false; // we don't know who this server is!
                }
				if (map.iface !is this)
					assert(false); // what happened here? why did this interface receive the message?
				address = map.localAddress;

				// we need to queue the request so we can return the response to the sender...
				pendingRequests ~= ModbusRequest(getTime(), packet.src, map.localAddress, 0, &packet);
			}
		}
		else
		{
			// if we're not a bus master, we can only send response packets destined for the master
			if (packet.dst != masterMac)
            {
                ++status.sendDropped;
                return false;
            }

			// the packet is a response to the master; just frame it and send it...
			ServerMap* map = modbus.findServerByMac(packet.src);
			if (!map)
            {
                ++status.sendDropped;
				return false; // how did we even get a response if we don't know who the server is?
            }

			if (map.iface is this)
			{
				assert(false, "This should be impossible; it should have served its own response...?");
				address = map.localAddress;
			}
			else
				address = map.universalAddress;
		}

		// frame it up and send...
		final switch (protocol)
		{
			case ModbusProtocol.Unknown:
				assert(false, "Modbus protocol not specified");
			case ModbusProtocol.RTU:
				// frame the packet
				length = cast(ushort)(1 + packet.data.length);
				buffer[0] = address;
				buffer[1 .. length] = cast(ubyte[])packet.data[];
				buffer[length .. length + 2][0 .. 2] = calculateModbusCRC(buffer[0 .. length]).nativeToLittleEndian;
				length += 2;
				break;
			case ModbusProtocol.TCP:
				assert(false);
			case ModbusProtocol.ASCII:
                // calculate the LRC
                ubyte lrc = address;
                foreach (b; cast(ubyte[])packet.data[])
                    lrc += cast(ubyte)b;
                lrc = cast(ubyte)-lrc;

                // format the packet
                buffer[0] = ':';
                formatInt(address, cast(char[])buffer[1..3], 16, 2, '0');
                length = cast(ushort)(3 + toHexString(cast(ubyte[])packet.data[], cast(char[])buffer[3..$]).length);
                formatInt(lrc, cast(char[])buffer[length .. length + 2], 16, 2, '0');
                (cast(char[])buffer)[length + 2 .. length + 4] = "\r\n";
                length += 4;
		}

		ptrdiff_t written = stream.write(buffer[0 .. length]);
		if (written <= 0)
		{
            ++status.sendDropped;

            // what could have gone wrong here?
			// proper error handling?
			assert(false);
		}

		++status.sendPackets;
		status.sendBytes += packet.data.length;
		// TODO: or should we record `length`? payload bytes, or full protocol bytes?
		return true;
	}

private:
	ubyte[260] tail;
	ushort tailBytes;

    final void incomingPacket(const(void)[] message, MonoTime recvTime, ref ModbusFrameInfo frameInfo)
    {
        // TODO: some debug logging of the incoming packet stream?
        debug {
            import urt.log;
            writeDebug("Modbus packet received from interface: '", name, "' (", message.length, ")[ ", message[], " ]");
        }

        // if we are the bus master, then we can only receive responses...
        ModbusFrameType type = isBusMaster ? ModbusFrameType.Response : frameInfo.frameType;

        // TODO: if the time since the last packet is longer than the modbus timeout,
        //       we should ignore expectMessageType and expect a request packet..
        if (type == ModbusFrameType.Unknown)
            type = expectMessageType;

        MACAddress frameMac = void;
        if (frameInfo.address == 0)
            frameMac = MACAddress.broadcast;
        else
        {
            auto modbus = mod_iface.app.moduleInstance!ModbusInterfaceModule();

            // we probably need to find a way to cache these lookups.
            // doing this every packet feels kinda bad...

            // if we are the bus master, then incoming packets are responses from slaves
            //    ...so the address must be their local bus address
            // if we are not the bus master, then it could be a request from a master to a local or remote slave, or a response from a local slave
            //    ...the response is local, so it can only be a universal address if it's a request!
            ServerMap* map = modbus.findServerByLocalAddress(frameInfo.address, this);
            if (!map && type == ModbusFrameType.Request)
                map = modbus.findServerByUniversalAddress(frameInfo.address);
            if (!map)
            {
                // apparently this is the first time we've seen this guy...
                // this should be impossible if we're the bus master, because we must know anyone we sent a request to...
                // so, it must be a communication from a local master with a local slave we don't know...

                // let's confirm and then record their existence...
                assert(!isBusMaster, "This should be impossible...?");

                // we won't bother generating a universal address since 3rd party's can't send requests anyway, because we're not the bus master!
                map = modbus.addRemoteServer(null, this, frameInfo.address, null);
            }
            frameMac = map.mac;
        }

        Packet p = Packet(message);
        p.creationTime = recvTime;
        p.etherType = EtherType.ENMS;
        p.etherSubType = ENMS_SubType.Modbus;

        if (isBusMaster)
        {
            // if we are the bus master, we expect to receive packets in response to queued requests
            foreach (i, ref req; pendingRequests)
            {
                if (req.localServerAddress != frameInfo.address)
                    continue;

                p.src = frameMac;
                p.dst = req.requestFrom;
                dispatch(p);

                // remove the request from the queue
                pendingRequests.remove(i);
                break;
            }
        }
        else
        {
            // we can't dispatch this message if we don't know if its a request or a response...
            // we'll need to discard messages until we get one that we know, and then we can predict future messages from there
            if (type == ModbusFrameType.Unknown)
                return;

            p.src = type == ModbusFrameType.Request ? masterMac : frameMac;
            p.dst = type == ModbusFrameType.Request ? frameMac : masterMac;
            dispatch(p);

            expectMessageType = type == ModbusFrameType.Request ? ModbusFrameType.Response : ModbusFrameType.Request;
        }
    }
}


class ModbusInterfaceModule : Plugin
{
	mixin RegisterModule!"interface.modbus";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;
    nothrow @nogc:

		Map!(ubyte, ServerMap) remoteServers;

		override void init()
		{
			app.console.registerCommand!add("/interface/modbus", this);
			app.console.registerCommand!remote_server_add("/interface/modbus/remote-server", this, "add");
		}

		ServerMap* findServerByName(const(char)[] name) nothrow @nogc
		{
			try foreach (ref map; remoteServers)
			{
				if (map.name[] == name)
					return &map;
			}
			catch(Exception) {}
			return null;
		}

		ServerMap* findServerByMac(MACAddress mac) nothrow @nogc
		{
			try foreach (ref map; remoteServers)
			{
				if (map.mac == mac)
					return &map;
			}
			catch(Exception) {}
			return null;
		}

		ServerMap* findServerByLocalAddress(ubyte localAddress, BaseInterface iface) nothrow @nogc
		{
			try foreach (ref map; remoteServers)
			{
				if (map.localAddress == localAddress && map.iface is iface)
					return &map;
			}
			catch(Exception) {}
			return null;
		}

		ServerMap* findServerByUniversalAddress(ubyte universalAddress) nothrow @nogc
		{
			return universalAddress in remoteServers;
		}

		ServerMap* addRemoteServer(const(char)[] name, ModbusInterface iface, ubyte address, const(char)[] profile, ubyte universalAddress = 0)
		{
			if (!name)
				name = tconcat(iface.name[], '.', address);

			ServerMap map;
			map.name = name.makeString(defaultAllocator());
			map.mac = iface.generateMacAddress();
			map.mac.b[5] = address;

			if (!universalAddress)
			{
				universalAddress = map.mac.b[4] ^ address;
				while (universalAddress in remoteServers)
					++universalAddress;
			}
			else
				assert(universalAddress !in remoteServers, "Universal address already in use.");

			map.localAddress = address;
			map.universalAddress = universalAddress;
			map.iface = iface;

			//profile...

			remoteServers[universalAddress] = map;
			iface.addAddress(map.mac, iface);

			import urt.log;
			debug writeDebugf("Create modbus server {0} - '{1}'  uid: {2}  at: {3}({4})", map.mac, map.name, map.universalAddress, iface.name, map.localAddress);

			return universalAddress in remoteServers;
		}

		import urt.meta.nullable;

		// /interface/modbus/add command
		// TODO: protocol enum!
		void add(Session session, const(char)[] name, const(char)[] stream, const(char)[] protocol, Nullable!bool master)
		{
			// is it an error to not specify a stream?
			assert(stream, "'stream' must be specified");

			Stream s = app.moduleInstance!StreamModule.getStream(stream);
			if (!s)
			{
				session.writeLine("Stream does not exist: ", stream);
				return;
			}

			ModbusProtocol p = ModbusProtocol.Unknown;
			switch (protocol)
			{
				case "rtu":
					p = ModbusProtocol.RTU;
					break;
				case "tcp":
					p = ModbusProtocol.TCP;
					break;
				case "ascii":
					p = ModbusProtocol.ASCII;
					break;
				default:
					session.writeLine("Invalid modbus protocol '", protocol, "', expect 'rtu|tcp|ascii'.");
					return;
			}
			if (p == ModbusProtocol.Unknown)
			{
				if (s && s.type == "tcp-client") // TODO: UDP here too... but what is the type called?
					p = ModbusProtocol.TCP;
				else
					p = ModbusProtocol.RTU;
			}

			auto mod_if = app.moduleInstance!InterfaceModule;

			if (name.empty)
				name = mod_if.generateInterfaceName("modbus");
			String n = name.makeString(defaultAllocator());

			ModbusInterface iface = defaultAllocator.allocT!ModbusInterface(mod_if, n.move, s, p, master ? master.value : false);
			mod_if.addInterface(iface);

			import urt.log;
			debug writeDebugf("Create modbus interface {0} - '{1}'", iface.mac, name);

//			// HACK: we'll print packets that we receive...
//			iface.subscribe((ref const Packet p, BaseInterface i) nothrow @nogc {
//				import urt.io;
//
//				auto modbus = app.moduleInstance!ModbusInterfaceModule;
//				ServerMap* src = modbus.findServerByMac(p.src);
//				ServerMap* dst = modbus.findServerByMac(p.dst);
//				const(char)[] srcName = src ? src.name[] : tconcat(p.src);
//				const(char)[] dstName = dst ? dst.name[] : tconcat(p.dst);
//				writef("{0}: Modbus packet received: ( {1} -> {2} )  [{3}]\n", i.name, srcName, dstName, p.data);
//			}, PacketFilter(etherType: EtherType.ENMS, enmsSubType: ENMS_SubType.Modbus));
		}


		void remote_server_add(Session session, const(char)[] name, const(char)[] _interface, ubyte address, const(char)[] profile, ubyte universal_address = 0)
		{
			if (!_interface)
			{
				session.writeLine("Interface must be specified.");
				return;
			}
			if (!address)
			{
				session.writeLine("Local address must be specified.");
				return;
			}

			BaseInterface iface = app.moduleInstance!InterfaceModule.findInterface(_interface);
			if (!iface)
			{
				session.writeLine("Interface '", _interface, "' not found.");
				return;
			}
			ModbusInterface modbusInterface = cast(ModbusInterface)iface;
			if (!modbusInterface)
			{
				session.writeLine("Interface '", _interface, "' is not a modbus interface.");
				return;
			}

			if (universal_address)
			{
				ServerMap* t = universal_address in remoteServers;
				if (t)
				{
					session.writeLine("Universal address '", universal_address, "' already in use by '", t.name, "'.");
					return;
				}
			}

			addRemoteServer(name, modbusInterface, address, profile, universal_address);
		}
	}
}


private:

nothrow @nogc:

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
	// RTU has no sync markers, so we need to get pretty creative to validate frames!
	// 1: packets are delimited by a 2-byte CRC, so any sequence of bytes where the running CRC is followed by 2 bytes with that value might be a frame...
	// 2: but 2-byte CRC's aren't good enough protection against false positives! (they appear semi-regularly), so...
	// 3:  a. we can exclude packets that start with an invalid function code
	//     b. we can exclude packets to the broadcast address (0), with a function code that can't broadcast
	//     c. we can then try and determine the expected packet length, and check for CRC only at the length offsets
	//     d. failing all that, we can crawl the buffer for a CRC...
	//     e. if we don't find a packet, repeat starting at the next BYTE...

	// ... losing stream sync might have a high computational cost!
	// we might determine that in practise it's superior to just drop the whole buffer and wait for new data which is probably aligned to the bitstream to arrive?

	// NOTE: it's also worth noting, that some of our stream validity checks exclude non-standard protocol...
	//       for instance, we exclude any function code that's not in the spec. What if an implementation invents their own function codes?
	//       maybe it should be an interface flag to control whether it accepts non-standard streams, and relax validation checking?

	if (data.length < 4) // @unlikely
		return 0;

	// check the address is in the valid range
	ubyte address = data[0];
	if (address >= 248 && address <= 255) // @unlikely
		return 0;
	frameInfo.address = address;

	// frames must start with a valid function code...
	ubyte f = data[1];
	FunctionCode fc = cast(FunctionCode)(f & 0x7F);
	ushort fnData = fc < functionLens.length ? functionLens[f] : fc == 0x2B ? 0xFFFF : 0;
	if (fnData == 0) // @unlikely
		return 0;
	frameInfo.functionCode = fc;

	// exceptions are always 3 bytes
	ubyte reqLength = void;
	ubyte resLength = void;
	if (f & 0x80) // @unlikely
	{
		frameInfo.exceptionCode = cast(ExceptionCode)data[2];
		frameInfo.frameType = ModbusFrameType.Response;
		reqLength = 3;
		resLength = 3;
	}

	// zero bytes (broadcast address) are common in data streams, and if the function code can't broadcast, we can exclude this packet
	// NOTE: this can only catch 10 bad bytes in the second byte position... maybe not worth the if()?
//	else if (address == 0 && (fFlags & 2) == 0) // @unlikely
//	{
//		frameId.invalidFrame = true;
//		return false;
//	}

	// if the function code can determine the length...
	else if (fnData != 0xFFFF) // @likely
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
		assert(false, "TODO");
	}

	int failResult = 0;
	if (reqLength != resLength) // @likely
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

		if (data.length >= length + 2) // @likely
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
	if (data.length < reqLength + 2) // @unlikely
		return -1;

	ushort crc = calculateModbusCRC(data[0 .. reqLength]);

	if (crc == (data[reqLength] | cast(ushort)data[reqLength + 1] << 8))
		return reqLength;

	return failResult;
}


size_t parseRTU(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frameInfo)
{
	if (data.length < 4)
		return 0;

	// the stream might have corruption or noise, RTU frames could be anywhere, so we'll scan forward searching for the next frame...
	size_t offset = 0;
	for (; offset < data.length - 4; ++offset)
	{
		int length = parseFrame(data[offset .. data.length], frameInfo);
		if (length < 0)
			return 0;
		if (length == 0)
			continue;

		message = data[offset + 1 .. offset + length];
		return length + 2;
	}

	// no packet was found in the stream... how odd!
	return 0;
}

size_t parseTCP(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frameInfo)
{
    assert(false);
	return 0;
}

size_t parseASCII(const(ubyte)[] data, out const(void)[] message, out ModbusFrameInfo frameInfo)
{
    assert(false);
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
/+
bool validFunctionCode(FunctionCode functionCode)
{
	if (functionCode & 0x80)
		functionCode ^= 0x80;

	version (X86_64) // TODO: use something more general!
	{
		enum ulong validCodes = 0b10000000000000000001111100111001100111111110;
		if (functionCode >= 64) // TODO: REMOVE THIS LINE (DMD BUG!)
			return false;		// TODO: REMOVE THIS LINE (DMD BUG!)
		return ((1uL << functionCode) & validCodes) != 0;
	}
	else
	{
		enum uint validCodes = 0b1111100111001100111111110;
		if (functionCode >= 32) // TODO: REMOVE THIS LINE (DMD BUG!)
			return false;		// TODO: REMOVE THIS LINE (DMD BUG!)
		if ((1 << functionCode) & validCodes)
			return true;
		return functionCode == FunctionCode.MEI;
	}
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

__gshared immutable ushort[256] crc_table = [
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
