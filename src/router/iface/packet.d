module router.iface.packet;

import urt.time;


struct MACAddress
{
	nothrow @nogc:

	// well-known mac addresses
	enum broadcast = MACAddress(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
	enum lldp      = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E);

	ubyte[6] b;

	this(ubyte[6] b...) pure
	{
		this.b = b;
	}

	bool opCast(T : bool)() const pure
		=> b[0] | b[1] | b[2] | b[3] | b[4] | b[5];

	bool opEquals(ref MACAddress rhs) const pure
		=> b == rhs.b;

	bool opEquals(const(ubyte)[6] bytes) const pure
		=> b == bytes;

	bool isBroadcast() const pure
		=> b == broadcast.b;

	import urt.string.format : FormatArg;
	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
	{
		if (!buffer.ptr)
			return 17;
		if (buffer.length != 17)
			return 0;
		static immutable char[16] hex = "0123456789ABCDEF";
		buffer[0]  = hex[b[0] >> 4];
		buffer[1]  = hex[b[0] & 0xF];
		buffer[2]  = ':';
		buffer[3]  = hex[b[1] >> 4];
		buffer[4]  = hex[b[1] & 0xF];
		buffer[5]  = ':';
		buffer[6]  = hex[b[2] >> 4];
		buffer[7]  = hex[b[2] & 0xF];
		buffer[8]  = ':';
		buffer[9]  = hex[b[3] >> 4];
		buffer[10] = hex[b[3] & 0xF];
		buffer[11] = ':';
		buffer[12] = hex[b[4] >> 4];
		buffer[13] = hex[b[4] & 0xF];
		buffer[14] = ':';
		buffer[15] = hex[b[5] >> 4];
		buffer[16] = hex[b[5] & 0xF];
		return 17;
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
	AgentDiscover		= 0x0001, // probably need some way to find peers on the network?
	Modbus				= 0x0010, // modbus
	Zigbee				= 0x0020, // zigbee
	TeslaTWC			= 0x0030, // tesla-twc
}

struct Packet
{
nothrow @nogc:
	this(MonoTime time, void[] data)
	{
		assert(data.length <= ushort.max);
		creationTime = time;
		ptr = data.ptr;
		length = cast(ushort)data.length;
	}

	inout(void)[] data() inout => ptr[0 .. length];

	MonoTime creationTime; // time received, or time of call to send
	MACAddress src;
	MACAddress dst;
	uint vlan;
	ushort etherType;
	ushort etherSubType;
	ushort length;
	void* ptr;
}


__gshared immutable uint[16] crc_table = [
	0x4DBDF21C, 0x500AE278, 0x76D3D2D4, 0x6B64C2B0,
	0x3B61B38C, 0x26D6A3E8, 0x000F9344, 0x1DB88320,
	0xA005713C, 0xBDB26158, 0x9B6B51F4, 0x86DC4190,
	0xD6D930AC, 0xCB6E20C8, 0xEDB71064, 0xF0000000
];

uint ethernetCRC(const(void)[] data)
{
	uint crc = 0;
	for (size_t n = 0; n < data.length; ++n)
	{
		crc = (crc >> 4) ^ crc_table[(crc ^ ((cast(ubyte*)data.ptr)[n] >> 0)) & 0x0F];  // lower nibble
		crc = (crc >> 4) ^ crc_table[(crc ^ ((cast(ubyte*)data.ptr)[n] >> 4)) & 0x0F];  // upper nibble
	}
	return crc;
}

