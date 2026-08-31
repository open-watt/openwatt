module protocol.ip.pool;

import urt.array;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.features : has_ipv6;

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


// A v6 pool serves two allocation shapes from one prefix: individual host
// addresses (DHCPv6 IA_NA) as interface-id offsets within the prefix, and
// delegated sub-prefixes (DHCPv6 IA_PD) of `delegation-length` carved from it.
static if (has_ipv6)
class IPv6Pool : BaseObject
{
    alias Properties = AliasSeq!(Prop!("prefix", prefix),
                                 Prop!("prefix-length", prefix_length),
                                 Prop!("delegation-length", delegation_length));
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
        reset_state();
        mark_set!(typeof(this), "prefix")();
    }

    ubyte prefix_length() const pure
        => _prefix_length;
    const(char)[] prefix_length(ubyte value)
    {
        if (value > 128)
            return "prefix-length must be <= 128";
        _prefix_length = value;
        reset_state();
        mark_set!(typeof(this), "prefix-length")();
        return null;
    }

    ubyte delegation_length() const pure
        => _delegation_length;
    const(char)[] delegation_length(ubyte value)
    {
        if (value > 64)
            return "delegation-length must be <= 64";
        _delegation_length = value;
        reset_state();
        mark_set!(typeof(this), "delegation-length")();
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

    // ---- host address allocation (IA_NA) ----
    // Addresses are prefix | interface-id, ids handed out from 1 upward.

    uint address_capacity() const pure
    {
        if (_prefix_length == 0 || _prefix_length > 64)
            return 0;
        return max_pool_capacity;
    }

    IPv6Addr address_at(uint idx) const pure
    {
        IPv6Addr a = network();
        a.s[6] |= cast(ushort)(idx >> 16);
        a.s[7] |= cast(ushort)idx;
        return a;
    }

    // Interface-id of addr if it lies in the allocatable range, else 0.
    uint address_index(IPv6Addr addr) const pure
    {
        if (!contains(addr))
            return 0;
        foreach (i; 4 .. 6)
            if (addr.s[i] != _prefix.s[i])
                return 0;
        uint idx = (uint(addr.s[6]) << 16) | addr.s[7];
        return idx < max_pool_capacity ? idx : 0;
    }

    IPv6Addr allocate_address(IPv6Addr preferred = IPv6Addr.any)
    {
        uint idx = alloc_index(_addresses, address_capacity, _addr_used, _addr_next,
                               preferred != IPv6Addr.any ? address_index(preferred) : 0);
        return idx ? address_at(idx) : IPv6Addr.any;
    }

    bool reserve_address(IPv6Addr addr)
        => reserve(_addresses, address_capacity, _addr_used, address_index(addr));

    void release_address(IPv6Addr addr)
    {
        release(_addresses, _addr_used, _addr_next, address_index(addr));
    }

    uint addresses_used() const pure
        => _addr_used;

    // ---- sub-prefix allocation (IA_PD) ----
    // Sub-prefixes of delegation-length, numbered by the bits between
    // prefix-length and delegation-length. Slot 0 is withheld: it contains the
    // pool's own address range above.

    uint prefix_capacity() const pure
    {
        if (_delegation_length <= _prefix_length)
            return 0;
        uint bits = _delegation_length - _prefix_length;
        if (bits >= 21)
            return max_pool_capacity;
        return 1u << bits;
    }

    IPv6Addr prefix_at(uint idx) const pure
    {
        IPv6Addr p = network();
        ulong hi = (ulong(p.s[0]) << 48) | (ulong(p.s[1]) << 32) | (ulong(p.s[2]) << 16) | p.s[3];
        hi |= ulong(idx) << (64 - _delegation_length);
        p.s[0] = cast(ushort)(hi >> 48);
        p.s[1] = cast(ushort)(hi >> 32);
        p.s[2] = cast(ushort)(hi >> 16);
        p.s[3] = cast(ushort)hi;
        return p;
    }

    uint prefix_index(IPv6Addr p) const pure
    {
        if (!contains(p) || _delegation_length <= _prefix_length)
            return 0;
        ulong hi = (ulong(p.s[0]) << 48) | (ulong(p.s[1]) << 32) | (ulong(p.s[2]) << 16) | p.s[3];
        uint bits = _delegation_length - _prefix_length;
        uint idx = cast(uint)((hi >> (64 - _delegation_length)) & ((1UL << bits) - 1));
        return idx < prefix_capacity ? idx : 0;
    }

    IPv6Addr allocate_prefix(IPv6Addr preferred = IPv6Addr.any)
    {
        uint idx = alloc_index(_prefixes, prefix_capacity, _prefix_used, _prefix_next,
                               preferred != IPv6Addr.any ? prefix_index(preferred) : 0);
        return idx ? prefix_at(idx) : IPv6Addr.any;
    }

    bool reserve_prefix(IPv6Addr p)
        => reserve(_prefixes, prefix_capacity, _prefix_used, prefix_index(p));

    void release_prefix(IPv6Addr p)
    {
        release(_prefixes, _prefix_used, _prefix_next, prefix_index(p));
    }

    uint prefixes_used() const pure
        => _prefix_used;

protected:

    override bool validate() const pure
    {
        if (_prefix_length == 0 || _prefix_length > 128)
            return false;
        if (_delegation_length && _delegation_length <= _prefix_length)
            return false;
        return true;
    }

private:
    enum uint max_pool_capacity = 1 << 20;

    IPv6Addr _prefix;
    ubyte _prefix_length;
    ubyte _delegation_length;

    Array!ubyte _addresses;
    uint _addr_used;
    uint _addr_next = 1;
    Array!ubyte _prefixes;
    uint _prefix_used;
    uint _prefix_next = 1;

    IPv6Addr network() const pure
    {
        IPv6Addr net = _prefix;
        ubyte n = _prefix_length;
        foreach (i; 0 .. 8)
        {
            ushort mask = n >= 16 ? 0xFFFF : n ? cast(ushort)(0xFFFF << (16 - n)) : 0;
            net.s[i] &= mask;
            n = n >= 16 ? cast(ubyte)(n - 16) : 0;
        }
        return net;
    }

    void reset_state()
    {
        _addresses.clear();
        _addr_used = 0;
        _addr_next = 1;
        _prefixes.clear();
        _prefix_used = 0;
        _prefix_next = 1;
    }

    // shared bitmap machinery; index 0 is never allocatable
    static bool ensure_bitmap(ref Array!ubyte bits, uint cap)
    {
        if (bits.length != 0)
            return true;
        if (cap == 0)
            return false;
        bits.resize((cap + 7) >> 3);
        return true;
    }

    static bool test(ref const Array!ubyte bits, uint idx) pure
        => (bits[idx >> 3] & (1 << (idx & 7))) != 0;
    static void set(ref Array!ubyte bits, uint idx)
    {
        bits[idx >> 3] |= cast(ubyte)(1 << (idx & 7));
    }
    static void clear_bit(ref Array!ubyte bits, uint idx)
    {
        bits[idx >> 3] &= ~cast(ubyte)(1 << (idx & 7));
    }

    // Returns the allocated index, or 0 for exhausted/invalid.
    uint alloc_index(ref Array!ubyte bits, uint cap, ref uint used, ref uint next, uint preferred)
    {
        if (cap < 2 || used >= cap - 1)
            return 0;
        if (!ensure_bitmap(bits, cap))
            return 0;

        if (preferred != 0 && preferred < cap && !test(bits, preferred))
        {
            set(bits, preferred);
            ++used;
            return preferred;
        }

        foreach (i; 0 .. cap)
        {
            uint idx = (next + i) % cap;
            if (idx == 0)
                continue;
            if (!test(bits, idx))
            {
                set(bits, idx);
                ++used;
                next = (idx + 1) % cap;
                return idx;
            }
        }
        return 0;
    }

    bool reserve(ref Array!ubyte bits, uint cap, ref uint used, uint idx)
    {
        if (idx == 0 || idx >= cap || !ensure_bitmap(bits, cap))
            return false;
        if (test(bits, idx))
            return false;
        set(bits, idx);
        ++used;
        return true;
    }

    void release(ref Array!ubyte bits, ref uint used, ref uint next, uint idx)
    {
        if (idx == 0 || bits.length == 0 || idx >= bits.length * 8)
            return;
        if (!test(bits, idx))
            return;
        clear_bit(bits, idx);
        --used;
        if (idx < next)
            next = idx;
    }
}
