module urt.inet;

import urt.conv;
import urt.endian;
import urt.meta.nullable;
import urt.string.format;
import urt.util : clz;

nothrow @nogc:


enum AddressFamily : byte
{
    Unknown = -1,
    Unspecified = 0,
    Unix,
    IPv4,
    IPv6,
}

enum WellKnownPort : ushort
{
    Auto    = 0,
    FTP     = 21,
    SSH     = 22,
    Telnet  = 23,
    DNS     = 53,
    DHCP    = 67,
    HTTP    = 80,
    NTP     = 123,
    SNMP    = 161,
    HTTPS   = 443,
    MQTT    = 1883,
    MDNS    = 5353,
}

enum IPAddr IPAddrLit(string addr) = () { IPAddr a; size_t taken = a.fromString(addr); assert(taken == addr.length, "Not an IPv4 address"); return a; }();
//enum IPv6Addr IPv6AddrLit(string addr) = () { IPv6Addr a; size_t taken = a.fromString(addr); assert(taken == addr.length, "Not an IPv6 address"); return a; }();

struct IPAddr
{
nothrow @nogc:

    enum any       = IPAddr(0, 0, 0, 0);
    enum loopback  = IPAddr(127, 0, 0, 1);
    enum broadcast = IPAddr(255, 255, 255, 255);
    enum none      = IPAddr(255, 255, 255, 255);

    union {
        uint address;
        ubyte[4] b;
    }

    this(ubyte[4] b...) pure
    {
        this.b = b;
    }

    bool isMulticast() const pure
        => (b[0] & 0xF0) == 224;
    bool isLoopback() const pure
        => b[0] == 127;
    bool isLinkLocal() const pure
        => (b[0] == 169 && b[1] == 254);
    bool isPrivate() const pure
        => (b[0] == 192 && b[1] == 168) || b[0] == 10 || (b[0] == 172 && (b[1] & 0xF) == 16);

    bool opCast(T : bool)() const pure
        => address != 0;

    bool opEquals(ref const IPAddr rhs) const pure
        => address == rhs.address;

    bool opEquals(const(ubyte)[4] bytes) const pure
        => b == bytes;

    IPAddr opUnary(string op : "~")() const pure
    {
        IPAddr r;
        r.address = ~address;
        return r;
    }

    IPAddr opBinary(string op)(const IPAddr rhs) const pure
        if (op == "&" || op == "|" || op == "^")
    {
        IPAddr r;
        r.address = mixin("address" ~ op ~ "rhs.address");
        return r;
    }

    void opOpAssign(string op)(const IPAddr rhs) pure
        if (op == "&" || op == "|" || op == "^")
    {
        address = mixin("address" ~ op ~ "rhs.address");
    }

    size_t toHash() const pure
    {
        import urt.hash : fnv1aHash, fnv1aHash64;
        static if (size_t.sizeof > 4)
            return fnv1aHash64(b[]);
        else
            return fnv1aHash(b[]);
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
    {
        char[15] stackBuffer = void;
        char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;
        size_t offset = 0;
        for (int i = 0; i < 4; i++)
        {
            if (i > 0)
                tmp[offset++] = '.';
            offset += b[i].formatInt(tmp[offset..$]);
        }

        if (buffer.ptr && tmp.ptr == stackBuffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        ubyte[4] t;
        size_t offset = 0, len;
        ulong i = s[offset..$].parseInt(&len);
        offset += len;
        if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
            return -1;
        t[0] = cast(ubyte)i;
        i = s[offset..$].parseInt(&len);
        offset += len;
        if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
            return -1;
        t[1] = cast(ubyte)i;
        i = s[offset..$].parseInt(&len);
        offset += len;
        if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
            return -1;
        t[2] = cast(ubyte)i;
        i = s[offset..$].parseInt(&len);
        offset += len;
        if (len == 0 || i > 255)
            return -1;
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

    enum any                = IPv6Addr(0, 0, 0, 0, 0, 0, 0, 0);
    enum loopback           = IPv6Addr(0, 0, 0, 0, 0, 0, 0, 1);
    enum linkLocal_allNodes = IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 1);
    enum linkLocal_routers  = IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 2);

    ushort[8] s;

    this(ushort[8] s...) pure
    {
        this.s = s;
    }

    bool isGlobal() const pure
        => (s[0] & 0xE000) == 0x2000;
    bool isLinkLocal() const pure
        => (s[0] & 0xFFC0) == 0xFE80;
    bool isMulticast() const pure
        => (s[0] & 0xFF00) == 0xFF00;
    bool isUniqueLocal() const pure
        => (s[0] & 0xFE00) == 0xFC00;

    bool opCast(T : bool)() const pure
        => (s[0] | s[1] | s[2] | s[3] | s[4] | s[5] | s[6] | s[7]) != 0;

    bool opEquals(ref const IPv6Addr rhs) const pure
        => s == rhs.s;

    bool opEquals(const(ushort)[8] words) const pure
        => s == words;

    IPv6Addr opUnary(string op : "~")() const pure
    {
        IPv6Addr r;
        foreach (i; 0..8)
            r.s[i] = cast(ushort)~s[i];
        return r;
    }

    IPv6Addr opBinary(string op)(const IPv6Addr rhs) pure
        if (op == "&" || op == "|" || op == "^")
    {
        IPv6Addr t;
        foreach (i, v; s)
            t.s[i] = mixin("v " ~ op ~ " rhs.s[i]");
        return t;
    }

    void opOpAssign(string op)(const IPv6Addr rhs) pure
        if (op == "&" || op == "|" || op == "^")
    {
        foreach (i, v; s)
            this = mixin("this " ~ op ~ " rhs");
    }

    size_t toHash() const pure
    {
        import urt.hash : fnv1aHash, fnv1aHash64;
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

        if (buffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            foreach (i, c; tmp[0 .. offset])
                buffer[i] = c.toLower;
        }
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
nothrow @nogc:

    enum multicast = IPSubnet(IPAddr(224, 0, 0, 0), 4);
    enum loopback  = IPSubnet(IPAddr(127, 0, 0, 0), 8);
    enum linkLocal = IPSubnet(IPAddr(169, 254, 0, 0), 16);
    enum privateA  = IPSubnet(IPAddr(10, 0, 0, 0), 8);
    enum privateB  = IPSubnet(IPAddr(172, 16, 0, 0), 12);
    enum privateC  = IPSubnet(IPAddr(192, 168, 0, 0), 16);
    // TODO: ya know, this is gonna align to 4-bytes anyway...
    //       we could store the actual mask in the native endian, and then clz to recover the prefix len in one opcode

    IPAddr addr;
    IPAddr mask;

    ubyte prefixLen() @property const pure
        => clz(~loadBigEndian(&mask.address));
    void prefixLen(ubyte len) @property pure
    {
        if (len == 0)
            mask.address = 0;
        else
            storeBigEndian(&mask.address, 0xFFFFFFFF << (32 - len));
    }

    this(IPAddr addr, ubyte prefixLen)
    {
        this.addr = addr;
        this.prefixLen = prefixLen;
    }

    IPAddr netMask() const pure
        => mask;

    bool contains(IPAddr ip) const pure
        => (ip & netMask()) == addr;

    IPAddr getNetwork(IPAddr ip) const pure
        => ip & mask;
    IPAddr getLocal(IPAddr ip) const pure
        => ip & ~mask;

    size_t toHash() const pure
        => addr.toHash() ^ prefixLen;

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
    {
        char[18] stackBuffer = void;
        char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;

        size_t offset = addr.toString(tmp, null, null);
        tmp[offset++] = '/';
        offset += prefixLen.formatInt(tmp[offset..$]);

        if (buffer.ptr && tmp.ptr == stackBuffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        IPAddr a;
        size_t taken = a.fromString(s);
        if (taken < 0 || s.length <= taken + 1 || s[taken++] != '/')
            return -1;
        size_t t;
        ulong plen = s[taken..$].parseInt(&t);
        if (t == 0 || plen > 32)
            return -1;
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
nothrow @nogc:

    enum global      = IPv6Subnet(IPv6Addr(0x2000, 0, 0, 0, 0, 0, 0, 0), 3);
    enum linkLocal   = IPv6Subnet(IPv6Addr(0xFE80, 0, 0, 0, 0, 0, 0, 0), 10);
    enum multicast   = IPv6Subnet(IPv6Addr(0xFF00, 0, 0, 0, 0, 0, 0, 0), 8);
    enum uniqueLocal = IPv6Subnet(IPv6Addr(0xFC00, 0, 0, 0, 0, 0, 0, 0), 7);

    IPv6Addr addr;
    ubyte prefixLen;

    this(IPv6Addr addr, ubyte prefixLen)
    {
        this.addr = addr;
        this.prefixLen = prefixLen;
    }

    IPv6Addr netMask() const pure
    {
        IPv6Addr r;
        int i, j = prefixLen / 16;
        while (i < j) r.s[i++] = 0xFFFF;
        r.s[i++] = cast(ushort)(0xFFFF << (16 - (prefixLen % 16)));
        while (i < 8) r.s[i++] = 0;
        return r;
    }

    bool contains(IPv6Addr ip) const pure
    {
        uint n = prefixLen / 16;
        uint i = 0;
        for (; i < n; ++i)
            if (ip.s[i] != addr.s[i])
                return false;
        if (prefixLen % 16)
        {
            uint s = 16 - (prefixLen % 16);
            if (ip.s[i] >> s != addr.s[i] >> s)
                return false;
        }
        return true;
    }

    size_t toHash() const pure
        => addr.toHash() ^ prefixLen;

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
    {
        char[42] stackBuffer = void;
        char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;

        size_t offset = addr.toString(tmp, null, null);
        tmp[offset++] = '/';
        offset += prefixLen.formatInt(tmp[offset..$]);

        if (buffer.ptr && tmp.ptr == stackBuffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        IPv6Addr a;
        size_t taken = a.fromString(s);
        if (taken < 0 || s.length <= taken + 1 || s[taken++] != '/')
            return -1;
        size_t t;
        ulong plen = s[taken..$].parseInt(&t);
        if (t == 0 || plen > 32)
            return -1;
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

struct MulticastGroup
{
    IPAddr address;
    IPAddr iface;
}

struct InetAddress
{
nothrow @nogc:

    struct IPv4
    {
        IPAddr addr;
        ushort port;
    }
    struct IPv6
    {
        IPv6Addr addr;
        ushort port;
        uint flowInfo;
        uint scopeId;
    }
    struct Addr
    {
        IPv4 ipv4;
        IPv6 ipv6;
    }

    AddressFamily family;
    Addr _a;

    this(IPAddr addr, ushort port)
    {
        family = AddressFamily.IPv4;
        this._a.ipv4.addr = addr;
        this._a.ipv4.port = port;
    }

    this(IPv6Addr addr, ushort port)
    {
        family = AddressFamily.IPv6;
        this._a.ipv6.addr = addr;
        this._a.ipv6.port = port;
    }

    size_t toHash() const pure
    {
        if (family == AddressFamily.IPv4)
            return _a.ipv4.addr.toHash() ^ _a.ipv4.port;
        else
            return _a.ipv6.addr.toHash() ^ _a.ipv6.port;
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const pure
    {
        char[47] stackBuffer = void;
        char[] tmp = buffer.length < stackBuffer.sizeof ? stackBuffer : buffer;

        size_t offset = void;
        if (family == AddressFamily.IPv4)
        {
            offset = _a.ipv4.addr.toString(tmp, null, null);
            tmp[offset++] = ':';
            offset += _a.ipv4.port.formatInt(tmp[offset..$]);
        }
        else
        {
            tmp[0] = '[';
            offset = 1 + _a.ipv6.addr.toString(tmp[1 .. $], null, null);
            tmp[offset++] = ']';
            tmp[offset++] = ':';
            offset += _a.ipv6.port.formatInt(tmp[offset..$]);
        }

        if (buffer.ptr && tmp.ptr == stackBuffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
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
            if (taken < 0)
                return -1;
        }
        else
        {
            if (s.length > 0 && s[0] == '[')
                ++taken;
            size_t t = a6.fromString(s[taken..$]);
            if (t < 0)
                return -1;
            if (s[0] == '[' && (s.length < t + 2 || s[t + taken++] != ']'))
                return -1;
            taken += t;
        }

        // take port
        if (s.length > taken && s[taken] == ':')
        {
            size_t t;
            ulong p = s[++taken..$].parseInt(&t);
            if (t == 0 || p > 0xFFFF)
                return -1;
            taken += t;
            port = cast(ushort)p;
        }

        // success! store results..
        family = af;
        if (af == AddressFamily.IPv4)
        {
            _a.ipv4.addr = a4;
            _a.ipv4.port = port;
        }
        else
        {
            _a.ipv6.addr = a6;
            _a.ipv6.port = port;
            _a.ipv6.flowInfo = 0;
            _a.ipv6.scopeId = 0;
        }
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

    assert(~IPAddr(255, 255, 248, 0) == IPAddr(0, 0, 7, 255));
    assert((IPAddr(255, 255, 248, 0) ^ IPAddr(255, 0, 255, 255)) == IPAddr(0, 255, 7, 255));
    assert(IPSubnet(IPAddr(), 21).netMask() == IPAddr(0xFF, 0xFF, 0xF8, 0));

    assert(tmp[0 .. IPAddr(192, 168, 0, 1).toString(tmp, null, null)] == "192.168.0.1");
    assert(tmp[0 .. IPAddr(0, 0, 0, 0).toString(tmp, null, null)] == "0.0.0.0");

    IPAddr addr;
    assert(addr.fromString("192.168.0.1/24") == 11 && addr == IPAddr(192, 168, 0, 1));
    assert(addr.fromString("0.0.0.0:21") == 7 && addr == IPAddr(0, 0, 0, 0));
    addr |= IPAddr(1, 2, 3, 4);
    assert(addr == IPAddr(1, 2, 3, 4));

    assert(tmp[0 .. IPSubnet(IPAddr(192, 168, 0, 0), 24).toString(tmp, null, null)] == "192.168.0.0/24");
    assert(tmp[0 .. IPSubnet(IPAddr(0, 0, 0, 0), 0).toString(tmp, null, null)] == "0.0.0.0/0");

    IPSubnet subnet;
    assert(subnet.fromString("192.168.0.0/24") == 14 && subnet == IPSubnet(IPAddr(192, 168, 0, 0), 24));
    assert(subnet.fromString("0.0.0.0/0") == 9 && subnet == IPSubnet(IPAddr(0, 0, 0, 0), 0));

    assert(~IPv6Addr(0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFF0, 0, 0, 0) == IPv6Addr(0, 0, 0, 0, 0xF, 0xFFFF, 0xFFFF, 0xFFFF));
    assert((IPv6Addr(0xFFFF, 0, 1, 2, 3, 4, 5, 6) ^ IPv6Addr(0xFF00, 0, 3, 0, 0, 0, 0, 2)) == IPv6Addr(0xFF, 0, 2, 2, 3, 4, 5, 4));
    assert(IPv6Subnet(IPv6Addr(), 21).netMask() == IPv6Addr(0xFFFF, 0xF800, 0, 0, 0, 0, 0, 0));

    assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1).toString(tmp, null, null)] == "2001:db8:0:1::1");
    assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 0, 1, 0, 0, 1).toString(tmp, null, null)] == "2001:db8::1:0:0:1");
    assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0).toString(tmp, null, null)] == "2001:db8::");
    assert(tmp[0 .. IPv6Addr(0, 0, 0, 0, 0, 0, 0, 1).toString(tmp, null, null)] == "::1");
    assert(tmp[0 .. IPv6Addr(0, 0, 0, 0, 0, 0, 0, 0).toString(tmp, null, null)] == "::");

//    IPv6Addr addr6;
//    assert(addr6.fromString("::2") == 3 && addr6 == IPv6Addr(0, 0, 0, 0, 0, 0, 0, 2));
//    assert(addr6.fromString("1::2") == 3 && addr6 == IPv6Addr(1, 0, 0, 0, 0, 0, 0, 2));
//    assert(addr6.fromString("2001:db8::1/24") == 14 && addr6 == IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1));

    assert(tmp[0 .. IPv6Subnet(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 24).toString(tmp, null, null)] == "2001:db8::1/24");
    assert(tmp[0 .. IPv6Subnet(IPv6Addr(), 0).toString(tmp, null, null)] == "::/0");

//    IPv6Subnet subnet6;
//    assert(subnet6.fromString("2001:db8::1/24") == 14 && subnet6 == IPv6Subnet(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 24));
//    assert(subnet6.fromString("::/0") == 4 && subnet6 == IPv6Subnet(IPv6Addr(), 0));

    assert(tmp[0 .. InetAddress(IPAddr(192, 168, 0, 1), 12345).toString(tmp, null, null)] == "192.168.0.1:12345");
    assert(tmp[0 .. InetAddress(IPAddr(10, 0, 0, 0), 21).toString(tmp, null, null)] == "10.0.0.0:21");

    assert(tmp[0 .. InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 12345).toString(tmp, null, null)] == "[2001:db8:0:1::1]:12345");
    assert(tmp[0 .. InetAddress(IPv6Addr(), 21).toString(tmp, null, null)] == "[::]:21");

    InetAddress address;
    assert(address.fromString("192.168.0.1:21") == 14 && address == InetAddress(IPAddr(192, 168, 0, 1), 21));
    assert(address.fromString("10.0.0.1:12345") == 14 && address == InetAddress(IPAddr(10, 0, 0, 1), 12345));

//    assert(address.fromString("[2001:db8:0:1::1]:12345") == 14 && address == InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 12345));
//    assert(address.fromString("[::]:21") == 14 && address == InetAddress(IPv6Addr(), 21));
}
