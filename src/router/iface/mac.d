module router.iface.mac;

import urt.string.format : FormatArg;

nothrow @nogc:


enum MACAddress MACLit(string addr) = (){ MACAddress a; assert(a.fromString(addr) == a.length, "Not a mac address"); return a; }();
enum EUI64 EUILit(string addr) = (){ EUI64 a; assert(a.fromString(addr) == a.length, "Not an eui64 address"); return a; }();

alias MACAddress = EUI!48;
alias EUI64 = EUI!64;

struct EUI(int width)
{
    static assert(width == 48 || width == 64, "Invalid EUI width");
    enum Bytes = width / 8;

    static if (width == 48)
    {
        // well-known mac addresses
        enum broadcast      = MACAddress(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
        enum lldp_multicast = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E);

        align(2) ubyte[6] b;

        version (BigEndian)
            ulong ul() @property const pure => *cast(ulong*)b.ptr >> 16;
        else
            ulong ul() @property const pure => (*cast(ulong*)b.ptr << 16) >> 16;
    }
    else
    {
        enum broadcast = EUI64(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);

        union {
            ulong ul;
            ubyte[8] b;
        }
    }

    this(ubyte[Bytes] b...) pure
    {
        this.b = b;
    }

    EUI64 makeEui64()() const pure if (width == 48)
        => EUI64(b[0] | 2, b[1], b[2], 0xFF, 0xFE, b[3], b[4], b[5]);

    bool opCast(T : bool)() const pure
        => ul != 0;

    bool opEquals(ref const EUI!width rhs) const pure
        => ul == rhs.ul;

    bool opEquals(const(ubyte)[Bytes] bytes) const pure
        => b == bytes;

    int opCmp(ref const EUI!width rhs) const pure
    {
        for (size_t i = 0; i < Bytes; ++i)
        {
            int c = rhs.b[i] - b[i];
            if (c != 0)
                return c;
        }
        return 0;
    }

    bool isBroadcast() const pure
        => ul == broadcast.ul;

    bool isMulticast() const pure
        => (b[0] & 0x01) != 0;

    bool isLocal() const pure
        => (b[0] & 0x02) != 0;

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
            static if (Bytes == 8)
                hash ^= (cast(ulong)s[3] << 21) ^ (cast(ulong)s[3] << 44);

            // bonus rotation
            hash ^= (hash >> 13);
            hash ^= (hash << 51);
//            hash ^= 0xA5A5A5A5A5A5A5A5;
        }
        else
        {
            hash = 0xDEADB33F ^ s[0];
            hash ^= (cast(uint)s[1] << 16);
            hash = (hash << 5) | (hash >> 27);  // 5-bit rotate left
            hash ^= s[2];
            static if (Bytes == 8)
                hash ^= (cast(uint)s[3] << 16);
//            hash ^= 0xA5A5A5A5;
        }
        return hash;
    }

    enum StringLen = Bytes == 6 ? 17 : 23;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        import urt.string.ascii : hex_digits;

        if (!buffer.ptr)
            return StringLen;
        if (buffer.length < StringLen)
            return -1;
        buffer[0]  = hex_digits[b[0] >> 4];
        buffer[1]  = hex_digits[b[0] & 0xF];
        buffer[2]  = ':';
        buffer[3]  = hex_digits[b[1] >> 4];
        buffer[4]  = hex_digits[b[1] & 0xF];
        buffer[5]  = ':';
        buffer[6]  = hex_digits[b[2] >> 4];
        buffer[7]  = hex_digits[b[2] & 0xF];
        buffer[8]  = ':';
        buffer[9]  = hex_digits[b[3] >> 4];
        buffer[10] = hex_digits[b[3] & 0xF];
        buffer[11] = ':';
        buffer[12] = hex_digits[b[4] >> 4];
        buffer[13] = hex_digits[b[4] & 0xF];
        buffer[14] = ':';
        buffer[15] = hex_digits[b[5] >> 4];
        buffer[16] = hex_digits[b[5] & 0xF];
        static if (Bytes == 8)
        {
            buffer[17] = ':';
            buffer[18] = hex_digits[b[6] >> 4];
            buffer[19] = hex_digits[b[6] & 0xF];
            buffer[20] = ':';
            buffer[21] = hex_digits[b[7] >> 4];
            buffer[22] = hex_digits[b[7] & 0xF];
        }
        return StringLen;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv;
        import urt.string.ascii;

        if (s.length < StringLen)
            return -1;
        for (size_t n = 0; n < StringLen; ++n)
        {
            if (n % 3 == 2)
            {
                if (s[n] != ':')
                    return -1;
            }
            else if (!is_hex(s[n]))
                return -1;
        }

        for (size_t i = 0; i < Bytes; ++i)
            b[i] = cast(ubyte)parse_int(s[i*3 .. i*3 + 2], null, 16);

        return StringLen;
    }

    auto __debugOverview()
    {
        debug {
            char[] buffer = new char[StringLen];
            ptrdiff_t len = toString(buffer, null, null);
            return buffer[0 .. len];
        }
        else
            return b;
    }
    auto __debugExpanded() => b[];
}


struct MACTable
{
    import urt.mem;
    import urt.time;
nothrow @nogc:

    this(ushort minElements, ushort maxElements, ubyte ttl)
    {
        import urt.util : is_power_of_2;
        assert(maxElements < 2^^12 && minElements <= maxElements && minElements.is_power_of_2 && maxElements.is_power_of_2);

        this.maxElements = maxElements;
        this.ttl = ttl;
        freeListHead = 0;

        elements = defaultAllocator().allocArray!Entry(minElements);
        size_t i = 0;
        for (; i < minElements - 1; ++i)
            elements[i].next = cast(short)(i + 1);
        elements[i].next = -1;

        update();
    }

    ~this()
    {
        if (elements)
            defaultAllocator().freeArray(elements);
    }

    bool insert(MACAddress mac, ubyte port, ushort vlan)
    {
        assert(port < 256 && vlan < 4096);

        ubyte h = hash(mac);
        short element = table[h];
        if (element >= 0)
        {
            while (1)
            {
                if (elements[element].mac == mac)
                {
                    elements[element].detail = (curTime << 24) | (elements[element].detail & 0xFFFFF);
                    return false;
                }
                element = elements[element].next;
                if (element < 0)
                    break;
            }
        }

        // make sure there is enough space (NOTE: should we just delete this?)
        if (freeListHead < 0)
        {
            size_t numElements = elements.length;
            if (numElements >= maxElements)
                return false;

            // expand the allocation
            void[] mem = cast(void[])elements;
            mem = defaultAllocator().realloc(mem, mem.length * 2);
            elements = cast(Entry[])mem;
            freeListHead = cast(short)numElements;
            for (; numElements < elements.length - 1; ++numElements)
                elements[numElements].next = cast(short)(numElements + 1);
            elements[numElements].next = -1;
        }

        // insert the new address
        element = freeListHead;
        freeListHead = elements[element].next;
        elements[element].mac = mac;
        elements[element].next = table[h];
        elements[element].detail = (curTime << 24) | (vlan << 8) | port;
        table[h] = element;

        return true;
    }

    bool get(MACAddress mac, out ubyte port, out ushort vlan) pure
    {
        ubyte slot = hash(mac);
        short first = table[slot];
        if (first < 0)
            return false;
        short element = first;
        while (1)
        {
            if (elements[element].mac == mac)
            {
                port = elements[element].detail & 0xFF;
                vlan = (elements[element].detail >> 8) & 0xFFF; // TODO: shift left then right?
                if (element != first)
                {
                    // shift it to the front of the bucket...? 
                    removeWithinSlot(slot, element);
                    elements[element].next = table[slot];
                    table[slot] = element;
                }
                return true;
            }
            element = elements[element].next;
            if (element < 0)
                return false;
        }
    }

    void update()
    {
        // update once per second...
        ubyte newTime = (getTime() - MonoTime()).as!"seconds" & 0xFF;
        if (newTime == curTime)
            return;

        curTime = newTime;

        // we'll just scan one hash map slot each update cycle
        // get through them all every ~4 minutes
        short element = table[scanSlot];
        while (element >= 0)
        {
            uint elementTime = elements[element].detail >> 24;
            int age = elementTime <= curTime ? curTime - elementTime : (0x100 - elementTime) + curTime;

            if (age > ttl)
            {
                removeFromSlot(scanSlot, element);
                ushort next = elements[element].next;
                elements[element].next = freeListHead;
                freeListHead = element;
                element = next;
            }
            else
                element = elements[element].next;
        }
        if (++scanSlot >= table.length)
            scanSlot = 0;
    }

private:
    struct Entry
    {
        MACAddress mac;
        short next;
        uint detail; // 8:4:12:8 = time:reserved:vlan:port
    }

    Entry[] elements;
    short freeListHead = -1;
    ubyte curTime; // in minutes? 10s? what?
    ubyte ttl;
    short[256] table = -1;
    ushort maxElements;
    ubyte scanSlot = 0;

    ubyte hash(MACAddress mac) const pure
    {
        ushort* s = cast(ushort*)mac.b.ptr;
        ushort hash = s[0] ^ s[1] ^ (0xF1 * (mac.b[4] >> 8)) ^ (0x25 * (mac.b[5] & 0xFF));
        return cast(ubyte)(hash ^ (hash >> 8));
    }

    void removeFromSlot(ubyte slot, ushort element) pure
    {
        if (table[slot] == element)
            table[slot] = elements[element].next;
        else if (table[slot] >= 0)
            removeWithinSlot(slot, element);
    }

    void removeWithinSlot(ubyte slot, ushort element) pure
    {
        Entry* prev = &elements[table[slot]];
        while (prev.next >= 0 && prev.next != element)
            prev = &elements[prev.next];
        if (prev.next >= 0)
            prev.next = elements[element].next;
    }
}
