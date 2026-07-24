module manager.id;

import urt.algorithm : binary_search;
import urt.array;
import urt.hash : fnv1a;
import urt.map;
import urt.mem.alloc : alloc, free;
import urt.mem.allocator : defaultAllocator;
import urt.string.string;

import manager.base;
import manager.element : Element;

nothrow @nogc:


struct ID(uint _type_bits)
{
    alias This = typeof(this);

    uint raw;

    enum This invalid = This(0);

    bool opCast(T : bool)() const pure
        => raw != 0;

    bool opEquals(This rhs) const pure
        => raw == rhs.raw;

    ptrdiff_t opCmp(This rhs) const pure
    {
        static if (ptrdiff_t.sizeof > 4)
            return cast(ptrdiff_t)raw - cast(ptrdiff_t)rhs.raw;
        else
            return (raw > rhs.raw) - (raw < rhs.raw);
    }

    size_t toHash() const pure
        => raw;

    static if (_type_bits > 0)
    {
        enum uint type_bits = _type_bits;
        enum uint id_bits = 32 - _type_bits;
        enum uint id_mask = (1u << id_bits) - 1;

        uint type_index() const pure
            => raw >> id_bits;

        uint slot() const pure
            => raw & id_mask;
    }
}

// container CID in the low 32 bits, element part above it; part 0 is the container itself, so
// object refs and element refs share one type. Never persisted, never on the wire.
struct EID
{
nothrow @nogc:

    ulong raw;

    enum EID invalid = EID();

    this(CID container, ushort part = 0) pure
    {
        raw = container.raw | (ulong(part) << 32);
    }

    CID container() const pure
        => CID(cast(uint)raw);

    ushort part() const pure
        => cast(ushort)(raw >> 32);

    bool opCast(T : bool)() const pure
        => raw != 0;

    bool opEquals(EID rhs) const pure
        => raw == rhs.raw;

    size_t toHash() const pure
        => cast(size_t)(raw ^ (raw >> 32));
}

// Dense immortal slots (v1: no reclamation), one tagged word each:
//     0              dormant - reserved on a name, awaiting a claimant
//     T   (bit0 = 0) bound to a live object
//     fwd (bit0 = 1) permanent forward to slot (word >> 1), write-once
// Names are a separate map; a name entry always holds a terminal (never forwarded) id.
struct IdAllocator(T) if (is(T == class) || is(T == U*, U))
{
nothrow @nogc:

    // forward reference: reserve a fresh id on the name
    uint reserve(const(char)[] name)
    {
        if (uint* p = name in _names)
            return *p;
        uint id = allocate();
        _names.insert(name.makeString(defaultAllocator), id);
        return id;
    }

    // create at a name: absent allocates, reserved claims, live is a duplicate (returns 0)
    uint claim(const(char)[] name, T obj)
    {
        debug assert(obj !is null);
        if (uint* p = name in _names)
        {
            uint id = *p;
            size_t w = _slots[][id];
            debug assert(!(w & 1), "name entry holds a forwarded id");
            if (w)
                return 0;
            _slots[][id] = cast(size_t)cast(void*)obj;
            return id;
        }
        uint id = allocate();
        _slots[][id] = cast(size_t)cast(void*)obj;
        _names.insert(name.makeString(defaultAllocator), id);
        return id;
    }

    // ids never move, so held refs follow for free; renaming onto a reserved name forwards it
    // to the primary, onto a live name fails
    bool rename(uint id, const(char)[] old_name, const(char)[] new_name)
    {
        if (uint* p = new_name in _names)
        {
            uint j = *p;
            if (j != id)
            {
                size_t w = _slots[][j];
                debug assert(!(w & 1), "name entry holds a forwarded id");
                if (w)
                    return false;
                _slots[][j] = (size_t(id) << 1) | 1;
                *p = id;
            }
        }
        else
            _names.insert(new_name.makeString(defaultAllocator), id);
        if (old_name[] != new_name[])
            _names.remove(old_name);
        return true;
    }

    // death reserves the primary on the object's final name; refs deref null until the next
    // object created at that name claims it
    void release(uint id)
    {
        debug assert(id && id < _slots.length && !(_slots[][id] & 1), "release of invalid or forwarded id");
        _slots[][id] = 0;
    }

    // follow forwards to the terminal slot and update the held id in place
    T deref(ref uint id)
    {
        uint i = id;
        if (!i || i >= _slots.length)
            return null;
        size_t w = _slots[][i];
        while (w & 1)
        {
            i = cast(uint)(w >> 1);
            w = _slots[][i];
        }
        if (i != id)
            id = i;
        return cast(T)cast(void*)w;
    }

    uint find(const(char)[] name)
    {
        uint* p = name in _names;
        return p ? *p : 0;
    }

    uint high_watermark() const
    {
        uint n = cast(uint)_slots.length;
        return n ? n - 1 : 0;
    }

private:
    Array!size_t _slots;        // slot 0 reserved as the invalid id
    Map!(String, uint) _names;

    uint allocate()
    {
        if (_slots.empty)
            _slots ~= 0;
        uint id = cast(uint)_slots.length;
        _slots ~= 0;
        return id;
    }
}

unittest
{
    static struct Thing { int x; }
    Thing a, b, c;

    IdAllocator!(Thing*) m;

    // forward reference reserves; creation claims; the reserved id resurrects
    uint held = m.reserve("motor");
    assert(held && m.deref(held) is null);
    assert(m.claim("motor", &a) == held);
    assert(m.deref(held) is &a);

    // creating at a live name is a duplicate error
    assert(m.claim("motor", &b) == 0);

    // rename: held ids follow the object with no repair; the old name dies
    assert(m.rename(held, "motor", "pump"));
    assert(m.deref(held) is &a);
    assert(m.find("motor") == 0 && m.find("pump") == held);

    // death reserves on the final name; recreation rebinds every old ref
    m.release(held);
    assert(m.deref(held) is null);
    assert(m.claim("pump", &b) == held);
    assert(m.deref(held) is &b);

    // rename onto a reserved name: the waiter's id forwards to the primary and updates on deref
    uint waiter = m.reserve("valve");
    assert(waiter != held);
    assert(m.rename(held, "pump", "valve"));
    assert(m.deref(waiter) is &b);
    assert(waiter == held);
    assert(m.find("valve") == held);

    // rename onto a live name fails
    uint other = m.claim("fan", &c);
    assert(other != 0);
    assert(!m.rename(held, "valve", "fan"));

    // a forwarded slot never rebinds: creating at the merged name claims the primary
    m.release(held);
    assert(m.claim("valve", &a) == held);

    // forward chains survive reserve-then-claim-by-rename cycles and update to the terminal
    uint chain = m.reserve("gate");
    assert(m.rename(held, "valve", "gate"));
    uint stale = waiter & ~0u;   // a copy that still holds the pre-merge id value
    assert(m.deref(stale) is &a && stale == held);
    assert(m.deref(chain) is &a && chain == held);
}


void id_init()
{
    id_table().init();
}

ref StringTable!12 id_table() pure
{
    static StringTable!12* hack() => &g_id_table;
    return *(cast(StringTable!12* function() pure nothrow @nogc)&hack)();
}

_ID hash_id(_ID : ID!n, size_t n)(const(char)[] name, ubyte type_idx = 0) pure
{
    static if (is(_ID : ID!n, size_t n) && n == 0)
        return _ID(fnv1a(cast(ubyte[])name));
    else
        return _ID((uint(type_idx) << _ID.id_bits) | (fnv1a(cast(ubyte[])name) & _ID.id_mask));
}

_ID rehash(_ID : ID!n, size_t n)(_ID id) pure
{
    static if (n > 0)
    {
        uint ty = id.raw & ~_ID.id_mask;
        return _ID(ty | ((id.slot * 0x01000193) & _ID.id_mask));
    }
    else
        return _ID(id.raw * 0x01000193);
}


private:

__gshared StringTable!12 g_id_table;

struct StringTable(uint page_bits)
{
    import urt.string.string;
nothrow @nogc:

    static assert(page_size <= ushort.max);
    enum uint page_size = 1u << page_bits;
    enum uint offset_mask = page_size - 1;

    ~this()
    {
        free_all();
    }

    void init()
    {
        auto page = cast(char*)alloc(page_size);
        assert(page !is null);
        _pages ~= page;
        _pages[0][0..2] = 0;
        _fill = 2;
    }

    uint insert(const(char)[] s)
    {
        if (s.length == 0)
            return 0;
        assert(s.length <= page_size);

        uint needed = 2 + cast(uint)(s.length + (s.length & 1));

        if (_fill + needed > page_size)
        {
            auto page = cast(char*)alloc(page_size);
            assert(page !is null);
            _pages ~= page;
            _fill = 0;
        }

        _fill += 2;
        writeString(_pages[$-1] + _fill, s);
        uint offset = (cast(uint)(_pages.length - 1) << page_bits) | _fill;
        _fill += cast(uint)(s.length + (s.length & 1));
        return offset;
    }

    const(char)[] get_dstring(uint offset) const pure
    {
        if (!offset)
            return null;
        const(char)* p = _pages[offset >> page_bits] + (offset & offset_mask);
        return p[0 .. (cast(ushort*)p)[-1]];
    }

    String get_string(uint offset) const pure
    {
        debug assert(offset != 0, "Invalid string offset");
        return as_string(_pages[offset >> page_bits] + (offset & offset_mask));
    }

    void free_all()
    {
        foreach (page; _pages[])
            free(page[0..page_size]);
        _pages.clear();
        _fill = 0;
    }

private:
    Array!(char*) _pages;
    uint _fill;
}
