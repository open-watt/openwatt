module router.iface.packet;

import urt.string.format : FormatArg;
import urt.time;


enum EtherType : ushort
{
	IP4  = 0x0800,	// Internet Protocol version 4 (IPv4)
	ARP  = 0x0806,	// Address Resolution Protocol (ARP)
	WOL  = 0x0842,	// Wake-on-LAN
	VLAN = 0x8100,	// IEEE 802.1Q VLAN tag
	IP6  = 0x86DD,	// Internet Protocol version 6 (IPv6)
	QinQ = 0x88A8,	// Service VLAN tag identifier (S-Tag) on Q-in-Q tunnel
	ENMS = 0x88B5,	// OUR PROGRAM: this is the official experimental ethertype for development use
	MTik = 0x88BF,	// MikroTik RoMON
	LLDP = 0x88CC,	// Link Layer Discovery Protocol (LLDP)
	HPGP = 0x88E1,	// HomePlug Green PHY (HPGP)
}

enum ENMS_SubType : ushort
{
	Unspecified			= 0x0000,
	AgentDiscover		= 0x0001, // probably need some way to find peers on the network?
	Modbus				= 0x0010, // modbus
	Zigbee				= 0x0020, // zigbee
	TeslaTWC			= 0x0030, // tesla-twc
}


enum MACAddress MAC(string addr) = (){ MACAddress a; assert(a.fromString(addr), "Not a mac address"); return a; }();


struct MACAddress
{
nothrow @nogc:

	// well-known mac addresses
	enum broadcast		= MACAddress(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
	enum lldp_multicast	= MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E);

	align(2) ubyte[6] b;

	this(ubyte[6] b...) pure
	{
		this.b = b;
	}

	bool opCast(T : bool)() const pure
		=> (b[0] | b[1] | b[2] | b[3] | b[4] | b[5]) != 0;

	bool opEquals(ref const MACAddress rhs) const pure
		=> b == rhs.b;

	bool opEquals(const(ubyte)[6] bytes) const pure
		=> b == bytes;

	int opCmp(ref const MACAddress rhs) const pure
	{
		for (size_t i = 0; i < 6; ++i)
		{
			int c = rhs.b[i] - b[i];
			if (c != 0)
				return c;
		}
		return 0;
	}

	bool isBroadcast() const pure
		=> b == broadcast.b;

	size_t toHash() const pure
	{
		ushort* s = cast(ushort*)b.ptr;

		// TODO: this is just a big hack!
		//       let's investigate a reasonable implementation!

		size_t hash;
		static if (is(size_t == ulong))
		{
			// incorporate all bits
			hash = 0xBAADF00DDEADB33F ^ (cast(ulong)s[0] << 0) ^ (cast(ulong)s[0] << 37);
			hash ^= (cast(ulong)s[1] << 14) ^ (cast(ulong)s[1] << 51);
			hash ^= (cast(ulong)s[2] << 28) ^ (cast(ulong)s[2] << 7);

			// additional mixing
			hash ^= (hash >> 13);
			hash ^= (hash >> 29);
			hash ^= 0xA5A5A5A5A5A5A5A5;
		}
		else
		{
			hash = 0xDEADB33F ^ s[0];
			hash ^= (cast(uint)s[1] << 16);
			hash = (hash << 5) | (hash >> 27);  // 5-bit rotate left
			hash ^= s[2];
			hash ^= 0xA5A5A5A5;
		}
		return hash;
	}

	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
	{
		if (!buffer.ptr)
			return 17;
		if (buffer.length < 17)
			return 0;
		buffer[0]  = hexDigits[b[0] >> 4];
		buffer[1]  = hexDigits[b[0] & 0xF];
		buffer[2]  = ':';
		buffer[3]  = hexDigits[b[1] >> 4];
		buffer[4]  = hexDigits[b[1] & 0xF];
		buffer[5]  = ':';
		buffer[6]  = hexDigits[b[2] >> 4];
		buffer[7]  = hexDigits[b[2] & 0xF];
		buffer[8]  = ':';
		buffer[9]  = hexDigits[b[3] >> 4];
		buffer[10] = hexDigits[b[3] & 0xF];
		buffer[11] = ':';
		buffer[12] = hexDigits[b[4] >> 4];
		buffer[13] = hexDigits[b[4] & 0xF];
		buffer[14] = ':';
		buffer[15] = hexDigits[b[5] >> 4];
		buffer[16] = hexDigits[b[5] & 0xF];
		return 17;
	}

	bool fromString(const(char)[] s, size_t* taken = null)
	{
		import urt.conv;
		import urt.string.ascii;

		if (s.length != 17)
			return false;
		for (size_t n = 0; n < 17; ++n)
		{
			if (n % 3 == 2)
			{
				if (s[n] != ':')
					return false;
			}
			else if (!isHex(s[n]))
				return false;
		}

		for (size_t i = 0; i < 6; ++i)
			b[i] = cast(ubyte)parseInt(s[i*3 .. i*3 + 2], null, null, 16);

		if (taken)
			*taken = 17;
		return true;
	}

	auto __debugOverview()
	{
		import urt.mem;
		char[] buffer = cast(char[])tempAllocator.alloc(17);
		ptrdiff_t len = toString(buffer, null, null);
		return buffer[0 .. len];
	}
	auto __debugExpanded() => b[];
}


struct Packet
{
nothrow @nogc:
	this(const(void)[] data)
	{
		assert(data.length <= ushort.max);
		ptr = data.ptr;
		length = cast(ushort)data.length;
	}

	const(void)[] data() const
		=> ptr[0 .. length];

	MonoTime creationTime; // time received, or time of call to send
	MACAddress src;
	MACAddress dst;
	uint vlan;
	ushort etherType;
	ushort etherSubType;

package:
	ushort length;
	const(void)* ptr;
}


uint ethernetCRC(const(void)[] data) pure nothrow @nogc
{
	uint crc = 0;
	for (size_t n = 0; n < data.length; ++n)
	{
		crc = (crc >> 4) ^ crc_table[(crc ^ ((cast(ubyte*)data.ptr)[n] >> 0)) & 0x0F];  // lower nibble
		crc = (crc >> 4) ^ crc_table[(crc ^ ((cast(ubyte*)data.ptr)[n] >> 4)) & 0x0F];  // upper nibble
	}
	return crc;
}


private:

__gshared immutable char[16] hexDigits = "0123456789ABCDEF";

__gshared immutable uint[16] crc_table = [
	0x4DBDF21C, 0x500AE278, 0x76D3D2D4, 0x6B64C2B0,
	0x3B61B38C, 0x26D6A3E8, 0x000F9344, 0x1DB88320,
	0xA005713C, 0xBDB26158, 0x9B6B51F4, 0x86DC4190,
	0xD6D930AC, 0xCB6E20C8, 0xEDB71064, 0xF0000000
];
