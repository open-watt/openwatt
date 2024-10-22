module router.iface.mac;

import urt.string.format : FormatArg;

nothrow @nogc:


enum MACAddress MAC(string addr) = (){ MACAddress a; assert(a.fromString(addr), "Not a mac address"); return a; }();


struct MACAddress
{
nothrow @nogc:

    // well-known mac addresses
    enum broadcast      = MACAddress(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
    enum lldp_multicast = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E);

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

    bool isMulticast() const pure
        => (b[0] & 0x01) != 0;

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
//            hash ^= 0xA5A5A5A5A5A5A5A5;
        }
        else
        {
            hash = 0xDEADB33F ^ s[0];
            hash ^= (cast(uint)s[1] << 16);
            hash = (hash << 5) | (hash >> 27);  // 5-bit rotate left
            hash ^= s[2];
//            hash ^= 0xA5A5A5A5;
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
        debug {
            char[] buffer = new char[17];
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
        import urt.util : isPowerOf2;
        assert(maxElements < 2^^12 && minElements <= maxElements && minElements.isPowerOf2 && maxElements.isPowerOf2);

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


private:

__gshared immutable char[16] hexDigits = "0123456789ABCDEF";
