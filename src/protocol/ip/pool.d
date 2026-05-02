module protocol.ip.pool;

import urt.array;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;

nothrow @nogc:


class IPPool : BaseObject
{
    alias Properties = AliasSeq!(Prop!("start", start),
                                 Prop!("end", end));
nothrow @nogc:

    enum type_name = "ip-pool";
    enum path = "/protocol/ip/pool";
    enum collection_id = CollectionType.ip_pool;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPPool, id, flags);
    }

    // Properties
    IPAddr start() const pure
        => _start;
    const(char)[] start(IPAddr value)
    {
        if (value == IPAddr.any)
            return "start cannot be 0.0.0.0";
        _start = value;
        _allocated.clear();
        _next_search = 0;
        _used = 0;
        mark_set!(typeof(this), "start")();
        return null;
    }

    IPAddr end() const pure
        => _end;
    const(char)[] end(IPAddr value)
    {
        if (value == IPAddr.any)
            return "end cannot be 0.0.0.0";
        _end = value;
        _allocated.clear();
        _next_search = 0;
        _used = 0;
        mark_set!(typeof(this), "end")();
        return null;
    }

    bool contains(IPAddr addr) const pure
        => addr >= _start && addr <= _end;

    uint capacity() const pure
    {
        if (!validate())
            return 0;
        return host_order(_end) - host_order(_start) + 1;
    }

    uint used() const pure
        => _used;

    uint available() const pure
        => capacity - _used;

    bool is_allocated(IPAddr addr)
    {
        if (!contains(addr))
            return false;
        ensure_bitmap();
        if (_allocated.length == 0)
            return false;
        uint idx = host_order(addr) - host_order(_start);
        return (_allocated[idx >> 3] & (1 << (idx & 7))) != 0;
    }

    // Mark addr as allocated. Returns true if the bit transitioned 0->1,
    // false if the address was already allocated or out of range.
    bool reserve(IPAddr addr)
    {
        if (!contains(addr))
            return false;
        ensure_bitmap();
        if (_allocated.length == 0)
            return false;
        uint idx = host_order(addr) - host_order(_start);
        ubyte mask = cast(ubyte)(1 << (idx & 7));
        if (_allocated[idx >> 3] & mask)
            return false;
        _allocated[idx >> 3] |= mask;
        ++_used;
        return true;
    }

    // Return addr to the pool. No-op if not currently allocated.
    void release(IPAddr addr)
    {
        if (!contains(addr) || _allocated.length == 0)
            return;
        uint idx = host_order(addr) - host_order(_start);
        ubyte mask = cast(ubyte)(1 << (idx & 7));
        if (!(_allocated[idx >> 3] & mask))
            return;
        _allocated[idx >> 3] &= ~mask;
        --_used;
        if (idx < _next_search)
            _next_search = idx;
    }

    // Allocate a free address. If `preferred` lies in the pool and is free, return it;
    // otherwise round-robin from `_next_search`. Returns IPAddr.any if pool is full.
    IPAddr allocate(IPAddr preferred = IPAddr.any)
    {
        uint cap = capacity;
        if (cap == 0 || _used >= cap)
            return IPAddr.any;

        ensure_bitmap();
        if (_allocated.length == 0)
            return IPAddr.any;

        if (preferred != IPAddr.any && contains(preferred))
        {
            uint idx = host_order(preferred) - host_order(_start);
            ubyte mask = cast(ubyte)(1 << (idx & 7));
            if (!(_allocated[idx >> 3] & mask))
            {
                _allocated[idx >> 3] |= mask;
                ++_used;
                return preferred;
            }
        }

        for (uint i = 0; i < cap; ++i)
        {
            uint idx = (_next_search + i) % cap;
            ubyte mask = cast(ubyte)(1 << (idx & 7));
            if (!(_allocated[idx >> 3] & mask))
            {
                _allocated[idx >> 3] |= mask;
                ++_used;
                _next_search = (idx + 1) % cap;
                IPAddr r;
                storeBigEndian(&r.address, host_order(_start) + idx);
                return r;
            }
        }

        return IPAddr.any;
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _start != IPAddr.any && _end != IPAddr.any && _start <= _end;

private:
    enum uint max_pool_capacity = 1 << 20; // 1M addresses ~ 128KB bitmap

    IPAddr _start;
    IPAddr _end;
    Array!ubyte _allocated;
    uint _used;
    uint _next_search;

    static uint host_order(IPAddr a) pure
        => loadBigEndian(&a.address);

    void ensure_bitmap()
    {
        if (_allocated.length != 0)
            return;
        uint cap = capacity;
        if (cap == 0 || cap > max_pool_capacity)
            return;
        size_t bytes = (cap + 7) >> 3;
        _allocated.resize(bytes);
    }
}


class IPv6Pool : BaseObject
{
    alias Properties = AliasSeq!(Prop!("prefix", prefix),
                                 Prop!("prefix-length", prefix_length));
nothrow @nogc:

    enum type_name = "ipv6-pool";
    enum path = "/protocol/ip/pool6";
    enum collection_id = CollectionType.ip_pool6;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPv6Pool, id, flags);
    }

    // Properties
    IPv6Addr prefix() const pure
        => _prefix;
    void prefix(IPv6Addr value)
    {
        _prefix = value;
        mark_set!(typeof(this), "prefix")();
    }

    ubyte prefix_length() const pure
        => _prefix_length;
    const(char)[] prefix_length(ubyte value)
    {
        if (value > 128)
            return "prefix-length must be <= 128";
        _prefix_length = value;
        mark_set!(typeof(this), "prefix-length")();
        return null;
    }

    bool contains(IPv6Addr addr) const pure
    {
        ubyte n = _prefix_length;
        for (size_t i = 0; i < 8 && n > 0; ++i)
        {
            ushort mask = n >= 16 ? 0xFFFF : cast(ushort)(0xFFFF << (16 - n));
            if ((addr.s[i] & mask) != (_prefix.s[i] & mask))
                return false;
            n = n >= 16 ? cast(ubyte)(n - 16) : 0;
        }
        return true;
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _prefix_length > 0 && _prefix_length <= 128;

private:
    IPv6Addr _prefix;
    ubyte _prefix_length;
}
