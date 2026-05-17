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
    enum bytes = width / 8;
nothrow @nogc:

    static if (width == 48)
    {
        // well-known mac addresses
        enum broadcast          = MACAddress(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
        enum stp_multicast      = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x00);
        enum pause_multicast    = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x01);
        enum lacp_multicast     = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x02);
        enum eapol_multicast    = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x03);
        enum lldp_multicast     = MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E);

        align(2) ubyte[6] b;

        version (BigEndian)
        {
            ulong ul() @property const pure => *cast(ulong*)b.ptr >> 16;
            bool is_link_local() const pure
                => *cast(uint*)b.ptr == 0x0180C200 && ((*cast(ushort*)(b.ptr + 4) & 0xFFF0) == 0x0000);
        }
        else
        {
            ulong ul() @property const pure => (*cast(ulong*)b.ptr << 16) >> 16;
            bool is_link_local() const pure
                => *cast(uint*)b.ptr == 0x00C28001 && ((*cast(ushort*)(b.ptr + 4) & 0xF0FF) == 0x0000);
        }
    }
    else
    {
        enum broadcast = EUI64(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);

        union {
            ulong ul;
            ubyte[8] b;
        }
    }

    this(ubyte[bytes] b...) pure
    {
        this.b = b;
    }

    EUI64 make_eui64()() const pure if (width == 48)
        => EUI64(b[0] | 2, b[1], b[2], 0xFF, 0xFE, b[3], b[4], b[5]);

    bool opCast(T : bool)() const pure
        => ul != 0;

    bool opEquals(ref const EUI!width rhs) const pure
        => ul == rhs.ul;

    bool opEquals(ref const(ubyte)[bytes] bytes) const pure
        => b == bytes;

    int opCmp(ref const EUI!width rhs) const pure
    {
        for (size_t i = 0; i < bytes; ++i)
        {
            int c = rhs.b[i] - b[i];
            if (c != 0)
                return c;
        }
        return 0;
    }

    bool is_broadcast() const pure
        => ul == broadcast.ul;

    bool is_multicast() const pure
        => (b[0] & 0x01) != 0;

    bool is_local() const pure
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
            static if (bytes == 8)
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
            static if (bytes == 8)
                hash ^= (cast(uint)s[3] << 16);
//            hash ^= 0xA5A5A5A5;
        }
        return hash;
    }

    enum StringLen = bytes == 6 ? 17 : 23;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const
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
        static if (bytes == 8)
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
        const len = s.length;
        if (len < bytes*2)
            return -1;
        size_t n = 0, i = 0, j = 0;
        while (true)
        {
            if (n >= len)
                return -1;
            char c = s[n++];

            if (i == 2)
            {
                i = 0;
                if (c == ':')
                    continue;
            }

            uint digit = c - '0';
            if (digit > 9)
            {
                digit = (c | 0x20) - 'a';
                if (digit > 5)
                    return -1;
                digit += 10;
            }

            if (i++ == 0)
                b[j] = cast(ubyte)(digit << 4);
            else
            {
                b[j] |= cast(ubyte)digit;
                if (++j == bytes)
                    break;
            }
        }
        return n;
    }

    version (Windows)
    {
        auto __debugOverview()
        {
            debug {
                import urt.mem;
                char[] buffer = debug_alloc!char(StringLen);
                ptrdiff_t len = toString(buffer, null, null);
                return buffer[0 .. len];
            }
            else
                return b;
        }
        auto __debugExpanded() => b[];
    }
}


unittest
{
    static immutable ubyte[6] kMac = [0x24, 0x0A, 0xC4, 0x12, 0x34, 0x56];

    // construction and accessors
    MACAddress mac = MACAddress(0x24, 0x0A, 0xC4, 0x12, 0x34, 0x56);
    assert(mac.b == kMac);
    assert(cast(bool)mac);
    assert(!cast(bool)MACAddress.init);

    // bit-flag predicates
    assert(!mac.is_multicast);
    assert(!mac.is_local);
    assert(!mac.is_broadcast);
    assert(MACAddress.broadcast.is_broadcast);
    assert(MACAddress.broadcast.is_multicast);
    assert(MACAddress.stp_multicast.is_multicast);
    assert(MACAddress(0x02, 0, 0, 0, 0, 0).is_local);
    assert(MACAddress.stp_multicast.is_link_local);
    assert(MACAddress.lacp_multicast.is_link_local);
    assert(MACAddress.lldp_multicast.is_link_local);
    assert(!MACAddress(0x01, 0x80, 0xC2, 0x00, 0x00, 0x10).is_link_local);
    assert(!mac.is_link_local);

    // toString
    char[MACAddress.StringLen] buf;
    assert(mac.toString(null, null, null) == MACAddress.StringLen);
    assert(mac.toString(buf[], null, null) == MACAddress.StringLen);
    assert(buf[] == "24:0A:C4:12:34:56");
    char[5] short_buf;
    assert(mac.toString(short_buf[], null, null) == -1);

    MACAddress p;

    // canonical colon-delimited form
    assert(p.fromString("24:0a:c4:12:34:56") == 17);
    assert(p.b == kMac);

    // uppercase hex
    p = MACAddress.init;
    ubyte[6] expected_upper = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF];
    assert(p.fromString("AA:BB:CC:DD:EE:FF") == 17);
    assert(p.b == expected_upper);

    // new compact form: no separators
    p = MACAddress.init;
    assert(p.fromString("240ac4123456") == 12);
    assert(p.b == kMac);

    // separators are optional between any byte boundary
    p = MACAddress.init;
    assert(p.fromString("240a:c412:3456") == 14);
    assert(p.b == kMac);
    p = MACAddress.init;
    assert(p.fromString("24:0ac412:3456") == 14);
    assert(p.b == kMac);

    // returns consumed length so callers can keep parsing trailing input
    p = MACAddress.init;
    assert(p.fromString("24:0a:c4:12:34:56/24") == 17);
    assert(p.b == kMac);
    p = MACAddress.init;
    assert(p.fromString("240ac4123456tail") == 12);
    assert(p.b == kMac);

    // rejected inputs
    assert(p.fromString("") == -1);
    assert(p.fromString("24:0a:c4:12:34") == -1);     // ran out before last byte
    assert(p.fromString("24567890123") == -1);        // shorter than minimum
    assert(p.fromString("24:0a:c4:12:34:gg") == -1);  // invalid hex digit
    assert(p.fromString("24:0a:c4:12:34:5") == -1);   // truncated last byte

    // make_eui64 sets the U/L bit and inserts FF:FE in the middle
    EUI64 eui = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55).make_eui64();
    ubyte[8] expected_eui = [0x02, 0x11, 0x22, 0xFF, 0xFE, 0x33, 0x44, 0x55];
    assert(eui.b == expected_eui);

    // EUI64 accepts both parse styles
    ubyte[8] kEui = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF];
    EUI64 e;
    assert(e.fromString("01:23:45:67:89:ab:cd:ef") == 23);
    assert(e.b == kEui);
    e = EUI64.init;
    assert(e.fromString("0123456789abcdef") == 16);
    assert(e.b == kEui);

    // hashing distinguishes neighbours
    assert(MACAddress(0, 0, 0, 0, 0, 0x01).toHash() != MACAddress(0, 0, 0, 0, 0, 0x02).toHash());
}


struct MACTable
{
    import urt.mem;
    import urt.time;
    import urt.util : min;
nothrow @nogc:

    this(ushort min_elements, ushort max_elements, ubyte ttl)
    {
        import urt.util : is_power_of_2;
        assert(max_elements < ushort.max && min_elements <= max_elements);

        _max_elements = max_elements;
        _ttl = ttl;
        _free_list_head = 0;

        _elements = defaultAllocator().allocArray!Entry(min_elements);
        size_t i = 0;
        for (; i < min_elements - 1; ++i)
            _elements[i].next = cast(ushort)(i + 1);
        _elements[i].next = 0xFFFF;

        update();
    }

    ~this()
    {
        if (_elements)
            defaultAllocator().freeArray(_elements);
    }

    bool insert(MACAddress mac, ushort vlan, byte port)
    {
        const k = Entry.Key(mac, vlan).k;
        ubyte h = hash(k);
        ushort element = _table[h];
        if (element != 0xFFFF)
        {
            while (1)
            {
                if (_elements[element].key.k == k)
                {
                    _elements[element].time = _cur_time;
                    return false;
                }
                element = _elements[element].next;
                if (element == 0xFFFF)
                    break;
            }
        }

        // make sure there is enough space (NOTE: should we just delete this?)
        if (_free_list_head == 0xFFFF)
        {
            size_t numElements = _elements.length;
            if (numElements >= _max_elements)
                return false;

            // expand the allocation
            void[] mem = cast(void[])_elements;
            mem = defaultAllocator().realloc(mem, min(mem.length * 2, _max_elements * Entry.sizeof));
            _elements = cast(Entry[])mem;
            _free_list_head = cast(ushort)numElements;
            for (; numElements < _elements.length - 1; ++numElements)
                _elements[numElements].next = cast(ushort)(numElements + 1);
            _elements[numElements].next = 0xFFFF;
        }

        // insert the new address
        element = _free_list_head;
        _free_list_head = _elements[element].next;
        _elements[element].key.k = k;
        _elements[element].next = _table[h];
        _elements[element].time = _cur_time;
        _elements[element].port = port;
        _table[h] = element;

        return true;
    }

    bool get(MACAddress mac, ushort vlan, out byte port) pure
    {
        const k = Entry.Key(mac, vlan).k;
        ubyte slot = hash(k);
        ushort first = _table[slot];
        if (first == 0xFFFF)
            return false;
        ushort element = first;
        while (1)
        {
            if (_elements[element].key.k == k)
            {
                port = _elements[element].port;
                if (element != first)
                {
                    // shift it to the front of the bucket...? 
                    remove_within_slot(slot, element);
                    _elements[element].next = _table[slot];
                    _table[slot] = element;
                }
                return true;
            }
            element = _elements[element].next;
            if (element == 0xFFFF)
                return false;
        }
    }

    void update()
    {
        // update once per second...
        ubyte newTime = (getTime() - MonoTime()).as!"seconds" & 0xFF;
        if (newTime == _cur_time)
            return;

        _cur_time = newTime;

        // we'll just scan one hash map slot each update cycle
        // get through them all every ~4 minutes
        ushort element = _table[_scan_slot];
        while (element != 0xFFFF)
        {
            ubyte elementTime = _elements[element].time;
            int age = elementTime <= _cur_time ? _cur_time - elementTime : (0x100 - elementTime) + _cur_time;

            if (age > _ttl)
            {
                remove_from_slot(_scan_slot, element);
                ushort next = _elements[element].next;
                _elements[element].next = _free_list_head;
                _free_list_head = element;
                element = next;
            }
            else
                element = _elements[element].next;
        }
        if (++_scan_slot >= _table.length)
            _scan_slot = 0;
    }

private:
    struct Entry
    {
        union Key
        {
            struct {
                MACAddress mac;
                ushort vlan;
            }
            ulong k;
        }
        Key key;
        byte port;
        ubyte time;
        ushort next;
        // TODO: let's not waste this 4 bytes padding! that ulong is holding space...
    }

    Entry[] _elements;
    ushort _free_list_head = 0xFFFF;
    ubyte _cur_time; // in minutes? 10s? what?
    ubyte _ttl;
    ushort[256] _table = 0xFFFF;
    ushort _max_elements;
    ubyte _scan_slot = 0;

    ubyte hash(ulong x) const pure
    {
        x ^= x >> 32;
        x ^= x >> 20;
        x ^= x >> 12;
        x ^= x >> 7;
        return cast(ubyte)(x ^ (x >> 8));
    }

    void remove_from_slot(ubyte slot, ushort element) pure
    {
        if (_table[slot] == element)
            _table[slot] = _elements[element].next;
        else if (_table[slot] != 0xFFFF)
            remove_within_slot(slot, element);
    }

    void remove_within_slot(ubyte slot, ushort element) pure
    {
        Entry* prev = &_elements[_table[slot]];
        while (prev.next != 0xFFFF && prev.next != element)
            prev = &_elements[prev.next];
        if (prev.next != 0xFFFF)
            prev.next = _elements[element].next;
    }
}
