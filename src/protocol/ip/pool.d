module protocol.ip.pool;

import urt.array;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.map;
import urt.mem;
import urt.string;
import urt.util : ctz, log2;

import manager;
import manager.base;
import manager.collection;
import manager.features : has_ipv6, is_tiny;

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


static if (has_ipv6)
{

class IPv6Pool : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("prefix", prefix),
                                 Prop!("pool", pool));
nothrow @nogc:

    enum type_name = "ipv6-pool";
    enum path = "/protocol/ip/pool6";
    enum collection_id = CollectionType.ip_pool6;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!IPv6Pool, id, flags);
    }

    IPv6NetworkAddress prefix() const pure
        => _prefix;
    const(char)[] prefix(IPv6NetworkAddress value)
    {
        if (value.prefix_len > 64)
            return "prefix length must be <= 64";
        if (!is_remote)
        {
            release_acquisition();
            if (value.addr != IPv6Addr.any)
            {
                _pool = null;
                mark_set!(typeof(this), "pool")();
            }
            else if (_pool.name.length != 0)
                value.addr = _prefix.addr;
        }
        _prefix = value;
        mark_set!(typeof(this), "prefix")();
        restart();
        return null;
    }

    inout(IPv6Pool) pool() inout pure
        => _pool;
    const(char)[] pool(IPv6Pool value)
    {
        for (IPv6Pool parent = value; parent; parent = parent._pool.get)
            if (parent is this || parent._pool.name == name)
                return "pool dependency cycle";
        if (_pool.get is value && (value !is null || _pool.name.length == 0))
            return null;
        release_acquisition();
        _pool = value;
        mark_set!(typeof(this), "pool")();
        restart();
        return null;
    }

    bool contains(IPv6Addr addr) const pure
    {
        if (!_tree.ready)
            return false;
        return (hi_bits(addr) & high_mask(_prefix.prefix_len)) == _tree.base;
    }

    IPv6NetworkAddress allocate_prefix(IPv6NetworkAddress preferred)
    {
        ubyte len = preferred.prefix_len;
        if (len <= _prefix.prefix_len || len > 64 || !_tree.ready)
            return IPv6NetworkAddress.init;
        if (preferred.addr != IPv6Addr.any)
        {
            ulong hi = hi_bits(preferred.addr) & high_mask(len);
            if (_tree.reserve(hi, len))
                return IPv6NetworkAddress(make_addr(hi, 0), len);
        }
        ulong hi;
        if (!_tree.allocate(len, hi))
            return IPv6NetworkAddress.init;
        return IPv6NetworkAddress(make_addr(hi, 0), len);
    }

    bool reserve_prefix(IPv6NetworkAddress prefix)
    {
        if (prefix.prefix_len <= _prefix.prefix_len || prefix.prefix_len > 64 || !_tree.ready)
            return false;
        return _tree.reserve(hi_bits(prefix.addr), prefix.prefix_len);
    }

    void release_prefix(IPv6NetworkAddress prefix)
    {
        if (prefix.prefix_len <= _prefix.prefix_len || prefix.prefix_len > 64 || !_tree.ready)
            return;
        _tree.release(hi_bits(prefix.addr), prefix.prefix_len);
    }

    uint prefixes_used() const pure
        => _tree.used - cast(uint)_hosts.length;

    IPv6Addr allocate_address(IPv6Addr preferred = IPv6Addr.any)
    {
        if (!_tree.ready)
            return IPv6Addr.any;
        if (preferred != IPv6Addr.any && reserve_address(preferred))
            return preferred;
        foreach (ref r; _hosts)
        {
            uint id = host_alloc(r);
            if (id)
                return make_addr(r.subnet, id);
        }
        ulong subnet;
        if (!_tree.allocate(64, subnet))
            return IPv6Addr.any;
        HostRange* r = add_host_range(subnet);
        return make_addr(subnet, host_alloc(*r));
    }

    bool reserve_address(IPv6Addr addr)
    {
        if (!contains(addr))
            return false;
        ulong id = lo_bits(addr);
        if (id == 0)
            return false;
        ulong subnet = hi_bits(addr);
        HostRange* r = find_host_range(subnet);
        if (!r)
        {
            if (!_tree.reserve(subnet, 64))
                return false;
            r = add_host_range(subnet);
        }
        return host_set(*r, id);
    }

    void release_address(IPv6Addr addr)
    {
        ulong id = lo_bits(addr);
        if (id == 0)
            return;
        HostRange* r = find_host_range(hi_bits(addr));
        if (!r || !host_clear(*r, id))
            return;
        if (r.used == 0)
        {
            _tree.release(r.subnet, 64);
            _hosts.remove(r);
        }
    }

    uint addresses_used() const pure
    {
        uint n = 0;
        foreach (ref r; _hosts)
            n += r.used;
        return n;
    }

protected:

    override bool validate() const
    {
        if (_prefix.prefix_len == 0 || _prefix.prefix_len > 64)
            return false;
        return _pool.name.length != 0 || _prefix.addr != IPv6Addr.any;
    }

    override CompletionStatus startup()
    {
        if (_pool.name.length != 0)
        {
            IPv6Pool p = _pool.get;
            if (!p || !p.running)
                return CompletionStatus.continue_;
            if (_prefix.prefix_len <= p.prefix.prefix_len)
            {
                _fail_reason = "prefix length must be longer than the parent pool's";
                return CompletionStatus.error;
            }
            IPv6NetworkAddress got = p.allocate_prefix(_prefix);
            if (got.prefix_len == 0)
            {
                _fail_reason = "parent pool exhausted";
                return CompletionStatus.error;
            }
            _prefix = got;
            mark_set!(typeof(this), "prefix")();
            _acquired = true;
        }
        _tree.reset(hi_bits(_prefix.addr), _prefix.prefix_len);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        release_acquisition();
        _tree.clear();
        _hosts.clear();
        return CompletionStatus.complete;
    }

    override void online()
    {
        foreach (child; Collection!IPv6Pool().values)
        {
            if (child.is_remote || !child.running || child._pool.get !is this)
                continue;
            if (reserve_prefix(child._prefix))
                child._acquired = true;
            else
                child.invalidate();
        }
    }

    override void offline()
    {
        foreach (child; Collection!IPv6Pool().values)
            if (!child.is_remote && child._pool.get is this)
                child._acquired = false;
    }

private:
    enum uint host_id_cap = 1 << 16;

    static struct HostRange
    {
        ulong subnet;
        Map!(ulong, ulong) bits;
        uint used;
        uint next = 1;
    }

    IPv6NetworkAddress _prefix;
    bool _acquired;
    ObjectRef!IPv6Pool _pool;
    PrefixTree!() _tree;
    Array!HostRange _hosts;

    void invalidate()
    {
        foreach (child; Collection!IPv6Pool().values)
            if (!child.is_remote && child.running && child._pool.get is this)
                child.invalidate();
        restart();
    }

    void release_acquisition()
    {
        if (_acquired)
        {
            IPv6Pool p = _pool.get;
            if (p)
                p.release_prefix(_prefix);
            _acquired = false;
        }
    }

    HostRange* find_host_range(ulong subnet)
    {
        foreach (ref r; _hosts)
            if (r.subnet == subnet)
                return &r;
        return null;
    }

    HostRange* add_host_range(ulong subnet)
    {
        HostRange* r = &_hosts.pushBack();
        r.subnet = subnet;
        return r;
    }

    static uint host_alloc(ref HostRange r)
    {
        for (uint wi = r.next >> 6; wi < host_id_cap >> 6; ++wi)
        {
            ulong* stored = ulong(wi) in r.bits;
            ulong word = stored ? *stored : 0;
            if (wi == 0)
                word |= 1;
            if (~word == 0)
                continue;
            uint id = (wi << 6) + ctz(~word);
            host_set(r, id);
            r.next = id + 1;
            return id;
        }
        return 0;
    }

    static bool host_set(ref HostRange r, ulong id)
    {
        ulong wi = id >> 6;
        ulong* word = wi in r.bits;
        if (!word)
            word = r.bits.insert(wi, 0UL);
        ulong mask = 1UL << (id & 63);
        if (*word & mask)
            return false;
        *word |= mask;
        ++r.used;
        return true;
    }

    static bool host_clear(ref HostRange r, ulong id)
    {
        ulong wi = id >> 6;
        ulong* word = wi in r.bits;
        ulong mask = 1UL << (id & 63);
        if (!word || !(*word & mask))
            return false;
        *word &= ~mask;
        if (!*word)
            r.bits.remove(wi);
        --r.used;
        if (id < r.next)
            r.next = cast(uint)id;
        return true;
    }
}


private:

ulong hi_bits(IPv6Addr a) pure
    => (ulong(a.s[0]) << 48) | (ulong(a.s[1]) << 32) | (ulong(a.s[2]) << 16) | a.s[3];

ulong lo_bits(IPv6Addr a) pure
    => (ulong(a.s[4]) << 48) | (ulong(a.s[5]) << 32) | (ulong(a.s[6]) << 16) | a.s[7];

IPv6Addr make_addr(ulong hi, ulong lo) pure
    => IPv6Addr(cast(ushort)(hi >> 48), cast(ushort)(hi >> 32), cast(ushort)(hi >> 16), cast(ushort)hi,
                cast(ushort)(lo >> 48), cast(ushort)(lo >> 32), cast(ushort)(lo >> 16), cast(ushort)lo);

ulong high_mask(uint len) pure
    => len == 0 ? 0 : ~0UL << (64 - len);


struct PrefixTree(uint block_depth = is_tiny ? 8 : 12)
{
nothrow @nogc:

    uint used() const pure
        => _used;

    ~this()
    {
        clear();
    }

    bool ready() const pure
        => _root_len != 0;

    ulong base() const pure
        => _base;

    void reset(ulong base, uint root_len)
    {
        clear();
        _base = base & high_mask(root_len);
        _root_len = root_len;
    }

    void clear()
    {
        if (_root)
        {
            free_block(_root);
            _root = null;
        }
        _used = 0;
        _root_len = 0;
    }

    bool allocate(uint len, out ulong hi)
    {
        if (!prepare(len))
            return false;
        Block* b;
        uint node, alen;
        find_best(_root, len, b, node, alen);
        if (b is null)
            return false;
        while (alen < len)
        {
            if (node_depth(node) == b.depth)
            {
                Block* c = make_block(node_base(b, node), alen);
                mark_split_path(b, node);
                b.children[node ^ (1u << b.depth)] = c;
                b = c;
                node = 1;
                continue;
            }
            set_split(b, node);
            node <<= 1;
            ++alen;
        }
        set_alloc(b, node);
        mark_split_path(b, node >> 1);
        ++_used;
        hi = node_base(b, node);
        return true;
    }

    bool reserve(ulong hi, uint len)
    {
        if (!prepare(len))
            return false;
        hi &= high_mask(len);
        if ((hi & high_mask(_root_len)) != _base)
            return false;
        return reserve_in(_root, hi, len);
    }

    bool release(ulong hi, uint len)
    {
        if (!_root || len < _root_len || len > 64)
            return false;
        hi &= high_mask(len);
        if ((hi & high_mask(_root_len)) != _base)
            return false;
        return release_in(_root, hi, len);
    }

private:
    ulong _base;
    uint _used;
    uint _root_len;
    Block* _root;

    static struct Block
    {
        ulong base;
        uint base_len;
        uint depth;             // leaves at base_len + depth
        Array!ulong planes;     // split plane then alloc plane
        Map!(uint, Block*) children;
    }

    bool prepare(uint len)
    {
        if (!ready || len < _root_len || len > 64)
            return false;
        if (!_root)
            _root = make_block(_base, _root_len);
        return true;
    }

    static Block* make_block(ulong base, uint base_len)
    {
        Block* b = alloc!Block;
        b.base = base;
        b.base_len = base_len;
        b.depth = 64 - base_len < block_depth ? 64 - base_len : block_depth;
        b.planes.resize(2 * plane_words(b.depth));
        return b;
    }

    static void free_block(Block* b)
    {
        foreach (c; b.children.values)
            free_block(c);
        free(b);
    }

    static uint plane_words(uint depth) pure
        => (2u << depth) <= 64 ? 1 : (2u << depth) >> 6;

    static uint node_depth(uint i) pure
        => log2(i);

    static uint node_at(const Block* b, ulong hi, uint k) pure
        => (1u << k) | cast(uint)((hi >> (64 - b.base_len - k)) & ((1UL << k) - 1));

    static ulong node_base(const Block* b, uint i) pure
    {
        uint d = node_depth(i);
        return b.base | (ulong(i ^ (1u << d)) << (64 - b.base_len - d));
    }

    static bool split_bit(const Block* b, uint i) pure
        => (b.planes[i >> 6] >> (i & 63)) & 1;
    static bool alloc_bit(const Block* b, uint i) pure
        => (b.planes[plane_words(b.depth) + (i >> 6)] >> (i & 63)) & 1;
    static void set_split(Block* b, uint i)
    {
        b.planes[i >> 6] |= 1UL << (i & 63);
    }
    static void clear_split(Block* b, uint i)
    {
        b.planes[i >> 6] &= ~(1UL << (i & 63));
    }
    static void set_alloc(Block* b, uint i)
    {
        b.planes[plane_words(b.depth) + (i >> 6)] |= 1UL << (i & 63);
    }
    static void clear_alloc(Block* b, uint i)
    {
        b.planes[plane_words(b.depth) + (i >> 6)] &= ~(1UL << (i & 63));
    }

    static void mark_split_path(Block* b, uint i)
    {
        for (; i >= 1; i >>= 1)
            set_split(b, i);
    }

    static ulong spread_pairs(uint x) pure
    {
        ulong v = x;
        v = (v | (v << 16)) & 0x0000FFFF0000FFFF;
        v = (v | (v << 8)) & 0x00FF00FF00FF00FF;
        v = (v | (v << 4)) & 0x0F0F0F0F0F0F0F0F;
        v = (v | (v << 2)) & 0x3333333333333333;
        v = (v | (v << 1)) & 0x5555555555555555;
        return v | (v << 1);
    }

    static uint find_candidate(const Block* b, uint d)
    {
        if (d == 0)
            return !split_bit(b, 1) && !alloc_bit(b, 1) ? 1 : 0;
        uint lo = 1u << d, hi = 2u << d;
        uint words = plane_words(b.depth);
        for (uint w = lo >> 6; w <= (hi - 1) >> 6; ++w)
        {
            ulong m = ~0UL;
            if (w == lo >> 6 && (lo & 63))
                m &= ~0UL << (lo & 63);
            if (w == (hi - 1) >> 6 && (hi & 63))
                m &= (1UL << (hi & 63)) - 1;
            ulong parents = spread_pairs(cast(uint)(b.planes[w >> 1] >> ((w & 1) << 5)));
            ulong cand = ~b.planes[w] & ~b.planes[words + w] & parents & m;
            if (cand)
                return (w << 6) + ctz(cand);
        }
        return 0;
    }

    static uint find_window(const Block* b, uint want, out uint alen)
    {
        uint kmax = want - b.base_len;
        if (kmax > b.depth)
            kmax = b.depth;
        for (int d = cast(int)kmax; d >= 0; --d)
        {
            uint n = find_candidate(b, cast(uint)d);
            if (n)
            {
                alen = b.base_len + d;
                return n;
            }
        }
        return 0;
    }

    static bool find_best(Block* b, uint want, ref Block* bb, ref uint bnode, ref uint balen)
    {
        if (want > b.base_len + b.depth)
        {
            foreach (c; b.children.values)
                if (find_best(c, want, bb, bnode, balen))
                    return true;
        }
        uint alen;
        uint n = find_window(b, want, alen);
        if (n && (bb is null || alen > balen))
        {
            bb = b;
            bnode = n;
            balen = alen;
            if (alen == want)
                return true;
        }
        return false;
    }

    bool reserve_in(Block* b, ulong hi, uint len)
    {
        uint k = len - b.base_len;
        if (k <= b.depth)
        {
            uint i = node_at(b, hi, k);
            for (uint a = i >> 1; a >= 1; a >>= 1)
                if (alloc_bit(b, a))
                    return false;
            if (alloc_bit(b, i) || split_bit(b, i))
                return false;
            set_alloc(b, i);
            mark_split_path(b, i >> 1);
            ++_used;
            return true;
        }
        uint leaf = node_at(b, hi, b.depth);
        for (uint a = leaf; a >= 1; a >>= 1)
            if (alloc_bit(b, a))
                return false;
        uint j = leaf ^ (1u << b.depth);
        Block** pc = j in b.children;
        Block* c = pc ? *pc : null;
        if (!c)
        {
            c = make_block(node_base(b, leaf), b.base_len + b.depth);
            b.children[j] = c;
            mark_split_path(b, leaf);
        }
        return reserve_in(c, hi, len);
    }

    bool release_in(Block* b, ulong hi, uint len)
    {
        uint k = len - b.base_len;
        if (k <= b.depth)
        {
            uint i = node_at(b, hi, k);
            if (!alloc_bit(b, i) || split_bit(b, i))
                return false;
            clear_alloc(b, i);
            --_used;
            coalesce(b, i >> 1);
            return true;
        }
        uint leaf = node_at(b, hi, b.depth);
        uint j = leaf ^ (1u << b.depth);
        Block** pc = j in b.children;
        if (!pc)
            return false;
        Block* c = *pc;
        if (!release_in(c, hi, len))
            return false;
        if (!split_bit(c, 1) && !alloc_bit(c, 1))
        {
            b.children.remove(j);
            free_block(c);
            clear_split(b, leaf);
            coalesce(b, leaf >> 1);
        }
        return true;
    }

    static void coalesce(Block* b, uint i)
    {
        for (; i >= 1; i >>= 1)
        {
            uint l = i << 1;
            if (split_bit(b, l) || alloc_bit(b, l) || split_bit(b, l | 1) || alloc_bit(b, l | 1))
                return;
            clear_split(b, i);
        }
    }
}

unittest
{
    static class TestPool : IPv6Pool
    {
    nothrow @nogc:
        IPv6Addr reservation;
        uint online_count;
        uint offline_count;
        bool exhausted;

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(id, flags);
        }

        bool prefix_marked() const pure
            => (_props_set & (1UL << prop_index!(IPv6Pool, "prefix"))) != 0;

        override CompletionStatus startup()
        {
            auto result = super.startup();
            if (result == CompletionStatus.complete && reservation != IPv6Addr.any)
                assert(reserve_prefix(IPv6NetworkAddress(reservation, 56)));
            if (result == CompletionStatus.complete && exhausted)
            {
                assert(allocate_prefix(IPv6NetworkAddress(IPv6Addr.any, 49)).prefix_len == 49);
                assert(allocate_prefix(IPv6NetworkAddress(IPv6Addr.any, 49)).prefix_len == 49);
            }
            return result;
        }

        override void online()
        {
            ++online_count;
            super.online();
        }

        override void offline()
        {
            ++offline_count;
            super.offline();
        }
    }

    enum ulong base = 0xfd00_0012_0034_0000;
    auto pools = Collection!IPv6Pool();
    auto parent = Collection!TestPool().create("pool-test-parent", ObjectFlags.none, NamedArgument("prefix", "fd00:12:34::/48"));
    auto child = Collection!TestPool().create("pool-test-child", ObjectFlags.none, NamedArgument("pool", parent), NamedArgument("prefix", "::/56"));
    auto grandchild = Collection!TestPool().create("pool-test-grandchild", ObjectFlags.none, NamedArgument("pool", child), NamedArgument("prefix", "::/60"));
    assert(parent.running && child.running && grandchild.running);
    assert(parent.pool(grandchild) !is null && parent.pool is null);
    assert(child.prefix.addr == make_addr(base, 0) && child.pool is parent && child.prefix_marked);
    ushort delta_slot = child.attach_delta_slot(parent);
    enum prefix_mask = 1UL << prop_index!(IPv6Pool, "prefix");
    auto address = grandchild.allocate_address();
    auto delegated = child.allocate_prefix(IPv6NetworkAddress(IPv6Addr.any, 64));
    assert(address != IPv6Addr.any && delegated.prefix_len == 64);

    parent.disabled(true);
    pools.update_all();
    assert(!parent.running && child.running && grandchild.running);
    assert(child.offline_count == 0 && grandchild.offline_count == 0);
    assert(!grandchild.reserve_address(address) && !child.reserve_prefix(delegated));
    auto offline_address = grandchild.allocate_address();
    assert(offline_address != IPv6Addr.any && offline_address != address);
    parent.disabled(false);
    pools.update_all();
    assert(parent.running && child.running && child._acquired);
    assert(parent.prefixes_used == 1 && child.offline_count == 0 && grandchild.offline_count == 0);
    assert(child.online_count == 1 && grandchild.online_count == 1);
    assert(!(sync_state(delta_slot).props_dirty & prefix_mask));
    assert(!grandchild.reserve_address(address) && !grandchild.reserve_address(offline_address));

    parent.destroy();
    pools.update_all();
    assert(child.running && grandchild.running && child.pool is null);
    auto replacement = pools.alloc("pool-test-parent");
    assert(replacement.pool(grandchild) !is null);
    pools.add(replacement);
    replacement.destroy();
    pools.update_all();
    parent = Collection!TestPool().create("pool-test-parent", ObjectFlags.none, NamedArgument("prefix", "fd00:12:34::/48"));
    assert(child.pool is parent && child._acquired && parent.prefixes_used == 1);
    assert(child.offline_count == 0 && grandchild.offline_count == 0 && !grandchild.reserve_address(address));

    parent.reservation = make_addr(base, 0);
    parent.restart();
    assert(child.running && grandchild.running);
    pools.update_all();
    assert(parent.running && child.running && grandchild.running);
    assert(child.offline_count == 1 && grandchild.offline_count == 1);
    assert(child.online_count == 2 && grandchild.online_count == 2);
    assert(sync_state(delta_slot).props_dirty & prefix_mask);
    assert(child._tree.base != base && !grandchild.contains(address));
    assert(parent.prefixes_used == 2 && grandchild.addresses_used == 0);
    assert(child.prefix.addr == make_addr(base + 0x100, 0));

    parent.reservation = IPv6Addr.any;
    sync_state(delta_slot).props_dirty = 0;
    parent.prefix(IPv6NetworkAddress(make_addr(0xfd00_0022_0000_0000, 0), 48));
    pools.update_all();
    assert(child.running && grandchild.running && child.offline_count == 2 && grandchild.offline_count == 2);
    assert(child.prefix.addr == make_addr(0xfd00_0022_0000_0000, 0));
    assert(sync_state(delta_slot).props_dirty & prefix_mask);

    parent.exhausted = true;
    parent.restart();
    pools.update_all();
    assert(parent.running && !child.running && !grandchild.running);
    assert(parent.prefixes_used == 2 && !child._tree.ready && !grandchild._tree.ready);
    parent.exhausted = false;
    parent.restart();
    pools.update_all();
    child.restart();
    pools.update_all();
    assert(child.running && grandchild.running && parent.prefixes_used == 1);

    grandchild.destroy();
    pools.update_all();
    child.prefix(IPv6NetworkAddress(make_addr(base, 0), 56));
    pools.update_all();
    assert(child.running && child.pool is null && parent.prefixes_used == 0);
    assert(child.pool(parent) is null);
    pools.update_all();
    assert(child.running && child.pool is parent && child.prefix.addr == parent.prefix.addr && parent.prefixes_used == 1);
    child.prefix(IPv6NetworkAddress(IPv6Addr.any, 60));
    pools.update_all();
    assert(child.running && parent.prefixes_used == 1);
    assert(parent.reserve_prefix(IPv6NetworkAddress(make_addr(child._tree.base + 0x10, 0), 60)));
    parent.release_prefix(IPv6NetworkAddress(make_addr(child._tree.base + 0x10, 0), 60));

    foreach (ulong id; [1UL, 63, 64, 65535, 65536, 0x1234_5678_9abc_def0, ulong.max])
    {
        auto host = make_addr(child._tree.base, id);
        assert(child.reserve_address(host) && !child.reserve_address(host));
        assert(!child.reserve_prefix(IPv6NetworkAddress(make_addr(child._tree.base, 0), 64)));
        child.release_address(host);
        assert(child.addresses_used == 0);
    }
    assert(!child.reserve_address(make_addr(child._tree.base, 0)));
    assert(child.reserve_address(make_addr(child._tree.base, ulong.max)));
    assert(child.allocate_address() == make_addr(child._tree.base, 1));
    child.release_address(make_addr(child._tree.base, 1));
    assert(child.allocate_address() == make_addr(child._tree.base, 1));

    auto proxy = pools.create("pool-test-proxy", ObjectFlags.remote);
    assert(proxy.pool(parent) is null);
    assert(proxy.set("prefix", child.get("prefix")));
    assert(proxy.prefix == child.prefix && proxy.pool is parent && !proxy._tree.ready);
    proxy.prefix(IPv6NetworkAddress(make_addr(base, 0), 56));
    assert(proxy.pool(child) is null);
    assert(proxy.prefix.addr == make_addr(base, 0) && proxy.pool is child && !proxy._tree.ready);
    proxy.destroy();
    parent.destroy();
    pools.update_all();
    assert(child.running && child.pool is null);
    assert(child.pool(null) is null);
    pools.update_all();
    assert(child.running && child._pool.name.length == 0);
    assert(child.prefix(IPv6NetworkAddress.init) is null);
    pools.update_all();
    assert(!child.running);
    assert(child.prefix(IPv6NetworkAddress(make_addr(base, 0), 65)) !is null);
    assert(child.prefix(IPv6NetworkAddress(make_addr(base, 0), 64)) is null);
    pools.update_all();
    assert(child.running);
    assert(child.allocate_prefix(IPv6NetworkAddress(IPv6Addr.any, 64)).prefix_len == 0);
    assert(child.allocate_address() == make_addr(base, 1));
    child.detach_delta_slot(delta_slot);
    child.destroy();
    pools.update_all();

    IPv6Pool.HostRange hosts;
    assert(IPv6Pool.host_set(hosts, ulong.max));
    foreach (uint id; 1 .. IPv6Pool.host_id_cap)
        assert(IPv6Pool.host_alloc(hosts) == id);
    assert(IPv6Pool.host_alloc(hosts) == 0);
    assert(IPv6Pool.host_clear(hosts, 1234));
    assert(IPv6Pool.host_alloc(hosts) == 1234);

    static foreach (depth; [8, 12])
    {{
        PrefixTree!depth tree;
        static if (size_t.sizeof == 8)
            static assert(tree.sizeof == 24);
        tree.reset(base, 48);
        ulong a, b, c;
        assert(tree.allocate(56, a) && a == base);
        assert(tree.allocate(56, b) && b == base + 0x100);
        assert(tree.reserve(base + 0x4321, 64));
        assert(tree.allocate(64, c) && c == base + 0x4320);
        assert(tree.allocate(63, c) && c == base + 0x4322);
        assert(tree.allocate(56, c) && c == base + 0x4200);
        assert(!tree.reserve(base + 0x4321, 64));
        assert(!tree.reserve(base + 0x4300, 56));
        assert(!tree.reserve(base + 0x50, 64));
        assert(tree.used == 6);
        foreach (reservation; [base, base + 0x100, base + 0x4200])
            assert(tree.release(reservation, 56));
        assert(tree.release(base + 0x4321, 64));
        assert(!tree.release(base + 0x4321, 64));
        assert(tree.release(base + 0x4320, 64));
        assert(tree.release(base + 0x4322, 63));
        assert(tree.used == 0);
        assert(tree.allocate(49, c) && c == base);
        tree.reset(base, 62);
        foreach (i; 0 .. 4)
            assert(tree.allocate(64, c) && c == base + i);
        assert(!tree.allocate(64, c));
        assert(tree.release(base + 2, 64));
        assert(tree.allocate(64, c) && c == base + 2);
        tree.reset(base, 64);
        assert(tree.allocate(64, c) && c == base);
        assert(!tree.allocate(64, c));
        foreach (uint length; [1, 2, 12, 13, 51, 52, 53, 63, 64])
        {
            tree.reset(base, length);
            assert(tree.allocate(64, c) && c == (base & high_mask(length)));
            assert(tree.release(c, 64) && tree.used == 0);
            assert(tree.allocate(length, c) && c == (base & high_mask(length)));
            assert(!tree.allocate(64, c));
        }
        tree.reset(base, 48);

        bool[65536] occupied;
        struct Reservation
        {
            ulong hi;
            uint len;
        }
        Array!Reservation reservations;
        uint rng = 666;
        uint random()
        {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            return rng;
        }
        foreach (step; 0 .. 4000)
        {
            if (reservations.length && random() % 3 == 0)
            {
                auto index = random() % reservations.length;
                auto reservation = reservations[index];
                assert(tree.release(reservation.hi, reservation.len));
                uint offset = cast(uint)(reservation.hi - base);
                uint size = 1u << (64 - reservation.len);
                occupied[offset .. offset + size] = false;
                reservations.remove(index);
            }
            else
            {
                uint len = 49 + random() % 16;
                uint size = 1u << (64 - len);
                ulong hi;
                bool found;
                if (random() & 1)
                {
                    hi = base + ((random() % 65536) & ~(size - 1));
                    bool expected = true;
                    uint offset = cast(uint)(hi - base);
                    foreach (bit; occupied[offset .. offset + size])
                        expected &= !bit;
                    found = tree.reserve(hi, len);
                    assert(found == expected);
                }
                else
                {
                    found = tree.allocate(len, hi);
                    if (!found)
                    {
                        for (uint offset = 0; offset < 65536; offset += size)
                        {
                            bool free_window = true;
                            foreach (bit; occupied[offset .. offset + size])
                                free_window &= !bit;
                            assert(!free_window);
                        }
                    }
                }
                if (found)
                {
                    uint offset = cast(uint)(hi - base);
                    assert((offset & (size - 1)) == 0);
                    foreach (bit; occupied[offset .. offset + size])
                        assert(!bit);
                    occupied[offset .. offset + size] = true;
                    reservations ~= Reservation(hi, len);
                }
            }
            assert(tree.used == reservations.length);
        }
    }}
}

}
