module router.iface.address_table;

import urt.map;
import urt.mem.allocator;

nothrow @nogc:

bool is_multicast_address(ulong address) pure
    => address >> 63 != 0;

struct AddressTable
{
nothrow @nogc:

    this(ubyte cache_capacity)
    {
        size_t total = cache_capacity * (ulong.sizeof + ubyte.sizeof + ubyte.sizeof);
        void[] block = defaultAllocator().alloc(total, ulong.alignof);
        ubyte* p = cast(ubyte*)block.ptr;
        _keys = cast(ulong*)p;
        p += cache_capacity * ulong.sizeof;
        _values = p;
        p += cache_capacity;
        _gen = p;
        _capacity = cache_capacity;
    }

    ~this()
    {
        if (_keys)
        {
            size_t total = _capacity * (ulong.sizeof + ubyte.sizeof + ubyte.sizeof);
            defaultAllocator().free((cast(ubyte*)_keys)[0 .. total]);
        }
        _backing.destroy();
    }

    int get(ulong key)
    {
        auto idx = cache_scan(key);
        if (idx < _len)
        {
            _gen[idx] = ++_clock;
            return _values[idx];
        }
        if (ubyte* p = _backing.get(key))
        {
            ubyte port = *p;
            cache_promote(key, port);
            return port;
        }
        return -1;
    }

    void insert(ulong key, ubyte port)
    {
        auto idx = cache_scan(key);
        if (idx < _len)
        {
            _values[idx] = port;
            _gen[idx] = ++_clock;
            return;
        }
        if (ubyte* p = _backing.get(key))
        {
            *p = port;
            cache_promote(key, port);
            return;
        }
        cache_insert(key, port);
    }

    void remove_port(ubyte port_index)
    {
        ulong[64] remove_buf = void;
        size_t remove_count = 0;
        // re-index survivors in the first pass
        foreach (ref kvp; _backing)
        {
            if (kvp.value == port_index)
            {
                if (remove_count < remove_buf.length)
                    remove_buf[remove_count++] = kvp.key;
            }
            else if (kvp.value > port_index)
                --kvp.value;
        }
        do
        {
            foreach (k; remove_buf[0 .. remove_count])
                _backing.remove(k);
            if (remove_count < remove_buf.length)
                break;
            // drain excess removals in following batches
            remove_count = 0;
            foreach (ref kvp; _backing)
                if (kvp.value == port_index)
                    if (remove_count < remove_buf.length)
                        remove_buf[remove_count++] = kvp.key;
        }
        while (remove_count > 0);

        for (ubyte i = 0; i < _len;)
        {
            if (_values[i] == port_index)
                cache_remove(i);
            else
            {
                if (_values[i] > port_index)
                    --_values[i];
                ++i;
            }
        }
    }

private:
    ulong* _keys;
    ubyte* _values;
    ubyte* _gen;
    Map!(ulong, ubyte) _backing;
    ubyte _capacity;
    ubyte _len;
    ubyte _clock;

    ubyte cache_scan(ulong key) const
    {
        foreach (i; 0 .. _len)
            if (_keys[i] == key)
                return cast(ubyte)i;
        return _len;
    }

    ubyte find_coldest() const
    {
        ubyte oldest = 0;
        ubyte max_age = 0;
        foreach (i; 0 .. _len)
        {
            ubyte age = cast(ubyte)(_clock - _gen[i]);
            if (age > max_age)
            {
                max_age = age;
                oldest = cast(ubyte)i;
            }
        }
        return oldest;
    }

    void cache_promote(ulong key, ubyte port)
    {
        if (_len < _capacity)
        {
            cache_append(key, port);
        }
        else
        {
            ubyte slot = find_coldest();
            _backing.replace(_keys[slot], _values[slot]);
            _keys[slot] = key;
            _values[slot] = port;
            _gen[slot] = ++_clock;
        }
        _backing.remove(key);
    }

    void cache_insert(ulong key, ubyte port)
    {
        if (_len < _capacity)
        {
            cache_append(key, port);
            return;
        }

        ubyte slot = find_coldest();
        _backing.replace(_keys[slot], _values[slot]);
        _keys[slot] = key;
        _values[slot] = port;
        _gen[slot] = ++_clock;
    }

    void cache_append(ulong key, ubyte port)
    {
        ubyte slot = _len++;
        _keys[slot] = key;
        _values[slot] = port;
        _gen[slot] = ++_clock;
    }

    void cache_remove(ubyte idx)
    {
        ubyte last = cast(ubyte)(_len - 1);
        if (idx != last)
        {
            _keys[idx] = _keys[last];
            _values[idx] = _values[last];
            _gen[idx] = _gen[last];
        }
        --_len;
    }
}
