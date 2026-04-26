module manager.id;

import urt.algorithm : binary_search;
import urt.array;
import urt.hash : fnv1a;
import urt.mem.alloc : alloc, free;
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
