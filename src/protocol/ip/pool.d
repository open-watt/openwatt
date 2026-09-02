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


// A v6 pool owns a covering prefix and carves it two ways: delegated sub-prefixes of any
// width down to /64 (DHCPv6 IA_PD), best-fit packed, and individual host addresses (IA_NA)
// issued from /64s the pool draws for itself. The prefix is configured directly, or
// acquired at startup from a parent pool.
static if (has_ipv6)
{

class IPv6Pool : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("prefix", prefix),
                                 Prop!("prefix-length", prefix_length),
                                 Prop!("pool", pool));
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
        => _parent_mode ? _acquired_prefix : _prefix;
    void prefix(IPv6Addr value)
    {
        release_acquisition(false);
        _prefix = value;
        _parent_mode = false;
        mark_set!(typeof(this), "prefix")();
        restart();
    }

    ubyte prefix_length() const pure
        => _prefix_length;
    const(char)[] prefix_length(ubyte value)
    {
        if (value == 0 || value > 64)
            return "prefix-length must be 1 to 64";
        _prefix_length = value;
        mark_set!(typeof(this), "prefix-length")();
        restart();
        return null;
    }

    inout(IPv6Pool) pool() inout pure
        => _pool;
    const(char)[] pool(IPv6Pool value)
    {
        if (value is this)
            return "pool cannot reference itself";
        if (_pool.get is value)
            return null;
        unsubscribe_parent();
        release_acquisition(false);
        _pool = value;
        _parent_mode = true;
        mark_set!(typeof(this), "pool")();
        restart();
        return null;
    }

    bool contains(IPv6Addr addr) const pure
    {
        if (!_tree.ready)
            return false;
        return (hi_bits(addr) & high_mask(_prefix_length)) == _tree.base;
    }

    // ---- sub-prefix allocation (IA_PD) ----

    IPv6Addr allocate_prefix(ubyte len, IPv6Addr preferred = IPv6Addr.any)
    {
        if (len <= _prefix_length || len > 64 || !_tree.ready)
            return IPv6Addr.any;
        if (preferred != IPv6Addr.any)
        {
            ulong hi = hi_bits(preferred) & high_mask(len);
            if (_tree.reserve(hi, len))
                return make_addr(hi, 0);
        }
        ulong hi;
        if (!_tree.allocate(len, hi))
            return IPv6Addr.any;
        return make_addr(hi, 0);
    }

    bool reserve_prefix(IPv6Addr p, ubyte len)
    {
        if (len <= _prefix_length || len > 64 || !_tree.ready)
            return false;
        return _tree.reserve(hi_bits(p) & high_mask(len), len);
    }

    void release_prefix(IPv6Addr p, ubyte len)
    {
        if (len <= _prefix_length || len > 64 || !_tree.ready)
            return;
        _tree.release(hi_bits(p) & high_mask(len), len);
    }

    uint prefixes_used() const pure
        => _tree.used - cast(uint)_hosts.length;

    // ---- host address allocation (IA_NA) ----
    // Addresses come from /64s the pool reserves for itself; ids are issued from 1 upward,
    // so a subnet's network address is never handed out.

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
        if (id == 0 || id >= host_id_cap)
            return false;
        ulong subnet = hi_bits(addr);
        HostRange* r = find_host_range(subnet);
        if (!r)
        {
            if (!_tree.reserve(subnet, 64))
                return false;
            r = add_host_range(subnet);
        }
        return host_set(*r, cast(uint)id);
    }

    void release_address(IPv6Addr addr)
    {
        ulong id = lo_bits(addr);
        if (id == 0 || id >= host_id_cap)
            return;
        HostRange* r = find_host_range(hi_bits(addr));
        if (!r || !host_clear(*r, cast(uint)id))
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
        if (_prefix_length == 0 || _prefix_length > 64)
            return false;
        if (_parent_mode)
            return _pool !is null;
        return _prefix != IPv6Addr.any;
    }

    override CompletionStatus startup()
    {
        if (_parent_mode)
        {
            IPv6Pool p = _pool.get;
            if (!p || !p.running)
                return CompletionStatus.continue_;
            if (_prefix_length <= p.prefix_length)
            {
                _fail_reason = "prefix-length must be longer than the parent pool's";
                return CompletionStatus.error;
            }
            if (!_acquired)
            {
                if (_acquired_prefix != IPv6Addr.any && p.reserve_prefix(_acquired_prefix, _prefix_length))
                    _acquired = true;
                else
                {
                    IPv6Addr got = p.allocate_prefix(_prefix_length);
                    if (got == IPv6Addr.any)
                    {
                        _fail_reason = "parent pool exhausted";
                        return CompletionStatus.error;
                    }
                    _acquired_prefix = got;
                    _acquired = true;
                }
                _acquired_length = _prefix_length;
            }
            if (!_subscribed)
            {
                p.subscribe(&parent_state_change);
                _subscribed = true;
            }
        }
        _tree.reset(hi_bits(prefix()), _prefix_length);
        _hosts.clear();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_parent();
        release_acquisition(true);
        _tree.clear();
        _hosts.clear();
        return CompletionStatus.complete;
    }

private:
    enum uint host_id_cap = 1 << 16;

    static struct HostRange
    {
        ulong subnet;
        Array!ulong bits;
        uint used;
        uint next = 1;
    }

    IPv6Addr _prefix;
    IPv6Addr _acquired_prefix;  // retained across restarts as a sticky re-reservation hint
    ubyte _prefix_length;
    ubyte _acquired_length;
    bool _parent_mode;
    bool _acquired;
    bool _subscribed;
    ObjectRef!IPv6Pool _pool;
    PrefixTree _tree;
    Array!HostRange _hosts;

    void parent_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
        {
            _acquired = false;
            restart();
        }
    }

    void unsubscribe_parent()
    {
        if (_subscribed)
        {
            _pool.unsubscribe(&parent_state_change);
            _subscribed = false;
        }
    }

    void release_acquisition(bool keep_hint)
    {
        if (_acquired)
        {
            IPv6Pool p = _pool.get;
            if (p)
                p.release_prefix(_acquired_prefix, _acquired_length);
            _acquired = false;
        }
        if (!keep_hint)
            _acquired_prefix = IPv6Addr.any;
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
        if (r.used >= host_id_cap - 1)
            return 0;
        for (uint wi = r.next >> 6; wi < host_id_cap >> 6; ++wi)
        {
            ulong word = wi < r.bits.length ? r.bits[wi] : 0;
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

    static bool host_set(ref HostRange r, uint id)
    {
        uint wi = id >> 6;
        if (r.bits.length <= wi)
            r.bits.resize(wi + 1);
        else if (r.bits[wi] & (1UL << (id & 63)))
            return false;
        r.bits[wi] |= 1UL << (id & 63);
        ++r.used;
        return true;
    }

    static bool host_clear(ref HostRange r, uint id)
    {
        uint wi = id >> 6;
        if (r.bits.length <= wi || !(r.bits[wi] & (1UL << (id & 63))))
            return false;
        r.bits[wi] &= ~(1UL << (id & 63));
        --r.used;
        if (id < r.next)
            r.next = id;
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


// Paged buddy allocator over the prefix space [root_len .. 64]. Each block is a complete
// binary tree of up to `block_depth` levels in heap layout: two bit planes (split, alloc),
// node i's children at 2i/2i+1. A leaf that subdivides further hangs a child block.
struct PrefixTree
{
nothrow @nogc:

    enum block_depth = is_tiny ? 8 : 12;

    uint used;

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
        used = 0;
        _root_len = 0;
    }

    // Best-fit: take an exact-size free buddy of existing allocations if one exists,
    // else split the narrowest free window. `len` in [root_len .. 64].
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
        ++used;
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

    // duplicate each of 32 bits into a pair: bit j -> bits 2j, 2j+1
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

    // Leftmost maximal free node at level d: free, and buddy of something occupied
    // (i.e. its parent is split). Junk below allocations self-excludes: an allocated
    // node's split bit is clear, so nothing beneath it passes the parent mask.
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

    // deepest in-block window no deeper than absolute length `want`
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

    // returns true when an exact-fit window was found
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
            ++used;
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
            --used;
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
    enum ulong base = 0xfd00_0012_0034_0000;

    PrefixTree t;
    t.reset(base, 48);

    ulong a, b, c;
    assert(t.allocate(56, a) && a == base);
    assert(t.allocate(56, b) && b == base + 0x100);
    assert(t.used == 2);

    // a static /64 mid-pool attracts its buddy, then the adjacent /63
    assert(t.reserve(base + 0x4321, 64));
    assert(t.allocate(64, c) && c == base + 0x4320);
    assert(t.allocate(63, c) && c == base + 0x4322);

    // next /56 is the exact-fit buddy of the fragmented 0x43 path, not a split of pristine space
    assert(t.allocate(56, c) && c == base + 0x4200);

    // conflicts
    assert(!t.reserve(base + 0x4321, 64));          // already allocated
    assert(!t.reserve(base + 0x4300, 56));          // covers allocations
    assert(!t.reserve(base + 0x50, 64));            // inside delegated /56
    assert(t.used == 6);

    // release everything and coalesce back to a pristine pool
    assert(t.release(base + 0x4321, 64));
    assert(!t.release(base + 0x4321, 64));          // double release
    assert(t.release(base + 0x4320, 64));
    assert(t.release(base + 0x4322, 63));
    assert(t.release(base, 56));
    assert(t.release(base + 0x100, 56));
    assert(t.release(base + 0x4200, 56));
    assert(t.used == 0);
    assert(t.allocate(49, c) && c == base);
    assert(t.release(base, 49));

    // exhaustion of a small pool
    t.reset(base, 62);
    foreach (i; 0 .. 4)
        assert(t.allocate(64, c) && c == base + i);
    assert(!t.allocate(64, c));
    assert(t.release(base + 2, 64));
    assert(t.allocate(64, c) && c == base + 2);

    // whole-pool window (host /64 of a /64 pool)
    t.reset(base, 64);
    assert(t.allocate(64, c) && c == base);
    assert(!t.allocate(64, c));
    t.clear();
}

}  // static if (has_ipv6)
