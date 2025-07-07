module urt.string.tailstring;

import urt.string;


alias TailString1 = TailString!ubyte;
alias TailString2 = TailString!ushort;

struct TailString(T)
    if (is(T == ubyte) || is(T == ushort))
{
    alias toString this;

    this(typeof(null)) pure nothrow @nogc
    {
        offset = 0;
    }

    this(ref const(String) s) pure nothrow @nogc
    {
        if (!s)
            offset = 0;
        else
        {
            const(char)* thisptr = cast(const(char)*)&this;
            const(char)* sptr = s.ptr - (s.ptr[-1] < 128 ? 1 : 2);
            assert(sptr > thisptr && sptr - thisptr <= offset.max, "!!");
            offset = cast(ubyte)(sptr - thisptr);
        }
    }

    const(char)[] toString() const nothrow @nogc
    {
        return offset == 0 ? null : _getString((cast(const(char)*)&this) + offset);
    }

    const(char)* ptr() const nothrow @nogc
    {
        if (offset == 0)
            return null;
        const(char)* ptr = (cast(const(char)*)&this) + offset;
        return ptr[0] < 128 ? ptr + 1 : ptr + 2;
    }

    size_t length() const nothrow @nogc
    {
        return offset == 0 ? 0 : _length((cast(const(char)*)&this) + offset);
    }

    bool opCast(T : bool)() const pure nothrow @nogc
    {
        return offset != 0;
    }

    void opAssign(typeof(null)) pure nothrow @nogc
    {
        offset = 0;
    }

    void opAssign(ref const(String) s) pure nothrow @nogc
    {
        if (!s)
            offset = 0;
        else
        {
            const(char)* thisptr = cast(const(char)*)&this;
            const(char)* sptr = s.ptr - (s.ptr[-1] < 128 ? 1 : 2);
            assert(sptr > thisptr && sptr - thisptr <= offset.max, "!!");
            offset = cast(ubyte)(sptr - thisptr);
        }
    }

    bool opEquals(const(char)[] rhs) const pure nothrow @nogc
    {
        const(char)[] s = toString();
        return s.length == rhs.length && (s.ptr == rhs.ptr || s[] == rhs[]);
    }

    size_t toHash() const pure nothrow @nogc
    {
        import urt.hash;

        static if (size_t.sizeof == 4)
            return fnv1aHash(cast(ubyte[])toString());
        else
            return fnv1aHash64(cast(ubyte[])toString());
    }

private:
    T offset;

    this(ubyte offset) pure nothrow @nogc
    {
        this.offset = offset;
    }

    auto __debugOverview() => toString;
    auto __debugExpanded() => toString;
    auto __debugStringView() => toString;
}


private:

static inout(char)[] _getString(inout(char)* ptr) pure nothrow @nogc
{
    ushort len = ptr[0];
    if (len < 128)
        return (ptr + 1)[0 .. len];
    return (ptr + 2)[0 .. (len ^ 0x80) | ((ptr[1] ^ 0x80) << 7)];
}

static size_t _length(const(char)* ptr) pure nothrow @nogc
{
    ushort len = ptr[0];
    if (len < 128)
        return len;
    return (len & 0x7F) | ((ptr[1] << 7) & 0x7F);
}
