module protocol.inet;

import urt.conv;
import urt.meta.nullable;
import urt.string.format;


enum AddressFamily : ubyte
{
	Unknown,
	IPv4,
	IPv6
}


struct IPAddr
{
nothrow @nogc:

	enum broadcast = IPAddr(255, 255, 255, 255);

	align(4) ubyte[4] b;

	this(ubyte[4] b...) pure
	{
		this.b = b;
	}

	bool opCast(T : bool)() const pure
		=> (b[0] | b[1] | b[2] | b[3]) != 0;

	bool opEquals(ref const IPAddr rhs) const pure
		=> b == rhs.b;

	bool opEquals(const(ubyte)[4] bytes) const pure
		=> b == bytes;

	size_t toHash() const pure
	{
		import urt.string : fnv1aHash, fnv1aHash64;
		static if (size_t.sizeof > 4)
			return fnv1aHash64(b[]);
		else
			return fnv1aHash(b[]);
	}

	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
	{
		char[15] stackBuffer;
		char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;
		size_t offset = 0;
		for (int i = 0; i < 4; i++)
		{
			if (i > 0)
				tmp[offset++] = '.';
			offset += b[i].formatInt(tmp[offset..$]);
		}

		if (buffer.ptr == null)
			return offset;
		if (buffer.length < offset)
			return 0;

		if (tmp.ptr == stackBuffer.ptr)
			buffer[0 .. offset] = tmp[0 .. offset];
		return offset;
	}

	ptrdiff_t fromString(const(char)[] s)
	{
		ubyte[4] t;
		size_t offset = 0, len;
		ulong i = s[offset..$].parseInt(&len);
		offset += len;
		if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
			return 0;
		t[0] = cast(ubyte)i;
		i = s[offset..$].parseInt(&len);
		offset += len;
		if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
			return 0;
		t[1] = cast(ubyte)i;
		i = s[offset..$].parseInt(&len);
		offset += len;
		if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
			return 0;
		t[2] = cast(ubyte)i;
		i = s[offset..$].parseInt(&len);
		offset += len;
		if (len == 0 || i > 255)
			return 0;
		t[3] = cast(ubyte)i;
		b = t;
		return offset;
	}

	auto __debugOverview()
	{
		import urt.mem;
		char[] buffer = cast(char[])tempAllocator.alloc(15);
		ptrdiff_t len = toString(buffer, null, null);
		return buffer[0 .. len];
	}
	auto __debugExpanded() => b[];
}


struct IPv6Addr
{
	nothrow @nogc:

	// well-known mac addresses
	enum linkLocal_allNodes		= IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 1);

	align(2) ushort[8] s;

	this(ushort[8] s...) pure
	{
		this.s = s;
	}

	bool opCast(T : bool)() const pure
		=> (s[0] | s[1] | s[2] | s[3] | s[4] | s[5] | s[6] | s[7]) != 0;

	bool opEquals(ref const IPv6Addr rhs) const pure
		=> s == rhs.s;

	bool opEquals(const(ushort)[8] words) const pure
		=> s == words;

	size_t toHash() const pure
	{
		import urt.string : fnv1aHash, fnv1aHash64;
		static if (size_t.sizeof > 4)
			return fnv1aHash64(cast(ubyte[])s[]);
		else
			return fnv1aHash(cast(ubyte[])s[]);
	}

	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
	{
		import urt.string.ascii;

		// find consecutive zeroes...
		int skipFrom = 0;
		int[8] z;
		for (int i = 0; i < 8; i++)
		{
			if (s[i] == 0)
			{
				for (int j = i - 1; j >= 0; --j)
				{
					if (z[j] != 0)
					{
						++z[j];
						if (z[j] > z[skipFrom])
							skipFrom = j;
					}
					else
						break;
				}
				z[i] = 1;
				if (z[i] > z[skipFrom])
					skipFrom = i;
			}
		}

		// write the string to a temp buffer
		char[39] tmp;
		size_t offset = 0;
		for (int i = 0; i < 8;)
		{
			if (i > 0)
				tmp[offset++] = ':';
			if (z[skipFrom] > 1 && i == skipFrom)
			{
				if (i == 0)
					tmp[offset++] = ':';
				i += z[skipFrom];
				if (i == 8)
					tmp[offset++] = ':';
				continue;
			}
			offset += s[i].formatInt(tmp[offset..$], 16);
			++i;
		}

		if (buffer.ptr == null)
			return offset;
		if (buffer.length < offset)
			return 0;

		foreach (i, c; tmp[0 .. offset])
			buffer[i] = c.toLower;
		return offset;
	}

	ptrdiff_t fromString(const(char)[] str)
	{
		ushort[8] t;
		size_t offset = 0;
		assert(false);
		return offset;
	}

	auto __debugOverview()
	{
		import urt.mem;
		char[] buffer = cast(char[])tempAllocator.alloc(39);
		ptrdiff_t len = toString(buffer, null, null);
		return buffer[0 .. len];
	}
	auto __debugExpanded() => s[];
}

struct IPSubnet
{
	IPAddr addr;
	ubyte prefixLen;

	this(IPAddr addr, ubyte prefixLen)
	{
		this.addr = addr;
		this.prefixLen = prefixLen;
	}

	size_t toHash() const pure
		=> addr.toHash() ^ prefixLen;

	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
	{
		char[18] stackBuffer;
		char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;

		size_t offset = addr.toString(tmp, null, null);
		tmp[offset++] = '/';
		offset += prefixLen.formatInt(tmp[offset..$]);

		if (tmp.ptr == stackBuffer.ptr)
			buffer[0 .. offset] = tmp[0 .. offset];
		return offset;
	}

	ptrdiff_t fromString(const(char)[] s)
	{
		IPAddr a;
		size_t taken = a.fromString(s);
		if (taken == 0 || s.length <= taken + 1 || s[taken++] != '/')
			return 0;
		size_t t;
		ulong plen = s[taken..$].parseInt(&t);
		if (t == 0 || plen > 32)
			return 0;
		addr = a;
		prefixLen = cast(ubyte)plen;
		return taken + t;
	}

	auto __debugOverview()
	{
		import urt.mem;
		char[] buffer = cast(char[])tempAllocator.alloc(18);
		ptrdiff_t len = toString(buffer, null, null);
		return buffer[0 .. len];
	}
}

struct IPv6Subnet
{
	IPv6Addr addr;
	ubyte prefixLen;

	this(IPv6Addr addr, ubyte prefixLen)
	{
		this.addr = addr;
		this.prefixLen = prefixLen;
	}

	size_t toHash() const pure
		=> addr.toHash() ^ prefixLen;

	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
	{
		char[42] stackBuffer;
		char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;

		size_t offset = addr.toString(tmp, null, null);
		tmp[offset++] = '/';
		offset += prefixLen.formatInt(tmp[offset..$]);

		if (tmp.ptr == stackBuffer.ptr)
			buffer[0 .. offset] = tmp[0 .. offset];
		return offset;
	}

	ptrdiff_t fromString(const(char)[] s)
	{
		IPv6Addr a;
		size_t taken = a.fromString(s);
		if (taken == 0 || s.length <= taken + 1 || s[taken++] != '/')
			return 0;
		size_t t;
		ulong plen = s[taken..$].parseInt(&t);
		if (t == 0 || plen > 32)
			return 0;
		addr = a;
		prefixLen = cast(ubyte)plen;
		return taken + t;
	}

	auto __debugOverview()
	{
		import urt.mem;
		char[] buffer = cast(char[])tempAllocator.alloc(42);
		ptrdiff_t len = toString(buffer, null, null);
		return buffer[0 .. len];
	}
}

struct InetAddress
{
	union Addr
	{
		IPAddr ipv4;
		IPv6Addr ipv6;
	}

	AddressFamily addressFamily;
	ushort port;
	Addr addr;

	this(IPAddr addr, ushort port)
	{
		addressFamily = AddressFamily.IPv4;
		this.addr.ipv4 = addr;
		this.port = port;
	}

	this(IPv6Addr addr, ushort port)
	{
		addressFamily = AddressFamily.IPv6;
		this.addr.ipv6 = addr;
		this.port = port;
	}

	size_t toHash() const pure
	{
		if (addressFamily == AddressFamily.IPv4)
			return addr.ipv4.toHash() ^ port;
		else
			return addr.ipv6.toHash() ^ port;
	}

	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
	{
		char[47] stackBuffer;
		char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;

		size_t offset = void;
		if (addressFamily == AddressFamily.IPv4)
		{
			offset = addr.ipv4.toString(tmp, null, null);
			tmp[offset++] = ':';
			offset += port.formatInt(tmp[offset..$]);
		}
		else
		{
			tmp[0] = '[';
			offset = 1 + addr.ipv6.toString(tmp[1 .. $], null, null);
			tmp[offset++] = ']';
			tmp[offset++] = ':';
			offset += port.formatInt(tmp[offset..$]);
		}

		if (tmp.ptr == stackBuffer.ptr)
			buffer[0 .. offset] = tmp[0 .. offset];
		return offset;
	}

	ptrdiff_t fromString(const(char)[] s)
	{
		AddressFamily af;
		IPAddr a4 = void;
		IPv6Addr a6 = void;
		ushort port = 0;
		size_t taken = 0;

		// take address
		if (s.length >= 4 && (s[1] == '.' || s[2] == '.' || s[3] == '.'))
			af = AddressFamily.IPv4;
		else
			af = AddressFamily.IPv6;
		if (af == AddressFamily.IPv4)
		{
			taken = a4.fromString(s);
			if (taken == 0)
				return 0;
		}
		else
		{
			if (s.length > 0 && s[0] == '[')
				++taken;
			size_t t = a6.fromString(s[taken..$]);
			if (t == 0)
				return 0;
			if (s[0] == '[' && (s.length < t + 2 || s[t + taken++] != ']'))
				return 0;
			taken += t;
		}

		// take port
		if (s.length > taken && s[taken] == ':')
		{
			size_t t;
			ulong p = s[++taken..$].parseInt(&t);
			if (t == 0 || p > 0xFFFF)
				return 0;
			taken += t;
			port = cast(ushort)p;
		}

		// success! store results..
		addressFamily = af;
		this.port = port;
		if (af == AddressFamily.IPv4)
			addr.ipv4 = a4;
		else
			addr.ipv6 = a6;
		return taken;
	}

	auto __debugOverview()
	{
		import urt.mem;
		char[] buffer = cast(char[])tempAllocator.alloc(47);
		ptrdiff_t len = toString(buffer, null, null);
		return buffer[0 .. len];
	}
}


unittest
{
	char[64] tmp;

	assert(tmp[0 .. IPAddr(192, 168, 0, 1).toString(tmp, null, null)] == "192.168.0.1");
	assert(tmp[0 .. IPAddr(0, 0, 0, 0).toString(tmp, null, null)] == "0.0.0.0");

	IPAddr addr;
	assert(addr.fromString("192.168.0.1/24") == 11 && addr == IPAddr(192, 168, 0, 1));
	assert(addr.fromString("0.0.0.0:21") == 7 && addr == IPAddr(0, 0, 0, 0));

	assert(tmp[0 .. IPSubnet(IPAddr(192, 168, 0, 0), 24).toString(tmp, null, null)] == "192.168.0.0/24");
	assert(tmp[0 .. IPSubnet(IPAddr(0, 0, 0, 0), 0).toString(tmp, null, null)] == "0.0.0.0/0");

	IPSubnet subnet;
	assert(subnet.fromString("192.168.0.0/24") == 14 && subnet == IPSubnet(IPAddr(192, 168, 0, 0), 24));
	assert(subnet.fromString("0.0.0.0/0") == 9 && subnet == IPSubnet(IPAddr(0, 0, 0, 0), 0));

	assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1).toString(tmp, null, null)] == "2001:db8:0:1::1");
	assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 0, 1, 0, 0, 1).toString(tmp, null, null)] == "2001:db8::1:0:0:1");
	assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0).toString(tmp, null, null)] == "2001:db8::");
	assert(tmp[0 .. IPv6Addr(0, 0, 0, 0, 0, 0, 0, 1).toString(tmp, null, null)] == "::1");
	assert(tmp[0 .. IPv6Addr(0, 0, 0, 0, 0, 0, 0, 0).toString(tmp, null, null)] == "::");

//	IPv6Addr addr6;
//	assert(addr6.fromString("::2") == 3 && addr6 == IPv6Addr(0, 0, 0, 0, 0, 0, 0, 2));
//	assert(addr6.fromString("1::2") == 3 && addr6 == IPv6Addr(1, 0, 0, 0, 0, 0, 0, 2));
//	assert(addr6.fromString("2001:db8::1/24") == 14 && addr6 == IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1));

	assert(tmp[0 .. IPv6Subnet(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 24).toString(tmp, null, null)] == "2001:db8::1/24");
	assert(tmp[0 .. IPv6Subnet(IPv6Addr(), 0).toString(tmp, null, null)] == "::/0");

//	IPv6Subnet subnet6;
//	assert(subnet6.fromString("2001:db8::1/24") == 14 && subnet6 == IPv6Subnet(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 24));
//	assert(subnet6.fromString("::/0") == 4 && subnet6 == IPv6Subnet(IPv6Addr(), 0));

	assert(tmp[0 .. InetAddress(IPAddr(192, 168, 0, 1), 12345).toString(tmp, null, null)] == "192.168.0.1:12345");
	assert(tmp[0 .. InetAddress(IPAddr(10, 0, 0, 0), 21).toString(tmp, null, null)] == "10.0.0.0:21");

	assert(tmp[0 .. InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 12345).toString(tmp, null, null)] == "[2001:db8:0:1::1]:12345");
	assert(tmp[0 .. InetAddress(IPv6Addr(), 21).toString(tmp, null, null)] == "[::]:21");

	InetAddress address;
	assert(address.fromString("192.168.0.1:21") == 14 && address == InetAddress(IPAddr(192, 168, 0, 1), 21));
	assert(address.fromString("10.0.0.1:12345") == 14 && address == InetAddress(IPAddr(10, 0, 0, 1), 12345));

//	assert(address.fromString("[2001:db8:0:1::1]:12345") == 14 && address == InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 12345));
//	assert(address.fromString("[::]:21") == 14 && address == InetAddress(IPv6Addr(), 21));
}
