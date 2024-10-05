module urt.string.string;

import urt.lifetime : forward;
import urt.mem;
import urt.mem.string : CacheString;
import urt.string : fnv1aHash, fnv1aHash64;
import urt.string.tailstring : TailString;

import core.lifetime : move;


enum MaxStringLen = 0x3FFF;


//enum String StringLit(string s) = s.makeString;
template StringLit(S...) if (S.length == 1 && is(typeof(S[0]) : const(char)[]))
{
    enum String StringLit = S.makeString;
}


String makeString(const(char)[] s) nothrow
{
    if (s.length == 0)
        return String(null);
    return makeString(s, new char[s.length + (s.length < 128 ? 1 : 2)]);
}

String makeString(const(char)[] s, NoGCAllocator a) nothrow @nogc
{
    if (s.length == 0)
        return String(null);
    return makeString(s, cast(char[])a.alloc(s.length + (s.length < 128 ? 1 : 2)));
}

String makeString(const(char)[] s, char[] buffer, size_t* bytes = null) nothrow @nogc
{
    if (s.length == 0)
    {
        if (bytes)
            *bytes = 0;
        return String(null);
    }

    size_t lenBytes = s.length < 128 ? 1 : 2;
    assert(buffer.length >= s.length + lenBytes, "Not enough memory for string");
    writeString(buffer.ptr, s);
    if (bytes)
        *bytes = s.length + lenBytes;
    return String(buffer.ptr + lenBytes, null);
}


struct BaseString(C = char)
{
nothrow @nogc:

    alias toString this;

    C* ptr;

    this(typeof(null)) pure
    {
        ptr = null;
    }

/+
    ~this()
    {
        // TODO: uncomment this when we allow strings to carry an allocator...
        if (!ptr)
            return;
        uint preamble = ptr[-1];
        uint preambleLen = void;
        uint len = void;
        uint allocIndex = void;
        if ((preamble >> 6) < 3)
        {
            preambleLen = 1;
            len = preamble & 0x3F;
            allocIndex = preamble >> 6;
        }
        else
        {
            // get the prior byte...
        }

        if (allocIndex == 0)
            return;

        // free the string...
        stringAllocators[allocIndex - 1].free(cast(char[])ptr[0 .. preambleLen + len]);
    }
+/

    inout(C)[] toString() inout pure
        => ptr[0 .. length()];

    size_t length() const pure
    {
        if (!ptr)
            return 0;
        ushort len = ptr[-1];
        if (len < 128)
            return len;
        return ((len ^ 0x80) << 7) | (ptr[-2] ^ 0x80);
    }

    bool opCast(T : bool)() const pure
        => ptr != null && ptr[-1] != 0;

    void opAssign(typeof(null)) pure
    {
        ptr = null;
    }

    bool opEquals(const(char)[] rhs) const pure
    {
        size_t len = length();
        return len == rhs.length && (ptr == rhs.ptr || ptr[0 .. len] == rhs[]);
    }

    size_t toHash() const pure
    {
        static if (size_t.sizeof == 4)
            return fnv1aHash(cast(ubyte[])ptr[0 .. length]);
        else
            return fnv1aHash64(cast(ubyte[])ptr[0 .. length]);
    }

    inout(C)[] opIndex() inout pure
        => ptr[0 .. length()];

    C opIndex(size_t i) const pure
    {
        debug assert(i < length());
        return ptr[i];
    }

    inout(C)[] opSlice(size_t x, size_t y) inout pure
    {
        debug assert(y <= length(), "Range error");
        return ptr[x .. y];
    }

    size_t opDollar() const pure
        => length();

    // const String can hold CacheString, and TailString references...
    static if (is(C == const(T), T))
    {
        this(TS)(const(TailString!TS) ts) pure
        {
            ptr = ts.ptr;
        }

        this(const(CacheString) cs)
        {
            ptr = cs.ptr;
        }

        void opAssign(TS)(const(TailString!TS) ts) pure
        {
            ptr = ts.ptr;
        }

        void opAssign(const(CacheString) cs)
        {
            ptr = cs.ptr;
        }
    }

private:
    auto __debugOverview() const pure => toString;
    auto __debugExpanded() const pure => toString;
    auto __debugStringView() const pure => toString;

    this(inout(char)* str, typeof(null)) inout pure
    {
        ptr = str;
    }
}

alias String = BaseString!(const(char));

struct MutableString(size_t Embed = 0)
{
nothrow @nogc:

    static assert(Embed == 0, "Not without move semantics!");

    BaseString!char _super;
    alias _super this;

    this(typeof(null)) pure
    {
    }

    this(ref MutableString!Embed rh)
    {
        this(rh[]);
    }

    this(const(char)[] s)
    {
        if (s.length == 0)
            return;
        debug assert(s.length <= MaxStringLen, "String too long");
        reserve(cast(ushort)s.length);
        writeLength(s.length);
        ptr[0 .. s.length] = s[];
    }

    this(size_t reserve)
    {
        debug assert(reserve <= MaxStringLen, "`reserve` exceeds max string length");
        this.reserve(cast(ushort)reserve);
    }

    ~this()
    {
        clear();
    }

    void opAssign(char c)
    {
        if (length() == 0)
            reserve(1);
        writeLength(1);
        ptr[0] = c;
    }
    void opAssign(const(char)[] s)
    {
        if (s == null)
        {
            // NOTE: assigning null frees allocated buffers... is that what we want?
            clear();
            return;
        }
        if (s.length > length())
        {
            debug assert(s.length <= MaxStringLen, "String too long");
            reserve(cast(ushort)s.length);
        }
        writeLength(s.length);
        ptr[0 .. s.length] = s[];
    }

    void opOpAssign(string op: "~", Args)(Args args)
    {
        append(forward!args);
    }

    size_t opDollar() const pure
        => length();

    inout(char)[] opIndex() inout pure
        => ptr[0 .. length()];

    char opIndex(size_t i) const pure
    {
        debug assert(i < length());
        return ptr[i];
    }

    inout(char)[] opSlice(size_t x, size_t y) inout pure
    {
        debug assert(y <= length(), "Range error");
        return ptr[x .. y];
    }

    void append(Things...)(auto ref Things things)
    {
        insert(length(), forward!things);
    }

    void appendFormat(Things...)(auto ref Things things)
    {
        insertFormat(length(), forward!things);
    }

    void concat(Things...)(auto ref Things things)
    {
        if (ptr)
            zeroLength();
        insert(0, forward!things);
    }

    void format(Things...)(auto ref Things things)
    {
        if (ptr)
            zeroLength();
        insertFormat(0, forward!things);
    }

    void insert(Things...)(size_t offset, auto ref Things things)
    {
        import urt.string.format : _concat = concat;
        import urt.util : max, nextPowerOf2;

        char* oldPtr = ptr;
        size_t oldLen = length();

        size_t insertLen = _concat(null, things).length;
        size_t newLen = oldLen + insertLen;
        if (newLen == oldLen)
            return;
        debug assert(newLen <= MaxStringLen, "String too long");

        size_t oldAlloc = allocated();
        ptr = newLen <= oldAlloc ? oldPtr : allocStringBuffer(max(16, cast(ushort)newLen + 4).nextPowerOf2 - 4);
        memmove(ptr + offset + insertLen, ptr + offset, oldLen - offset);
        _concat(ptr[offset .. offset + insertLen], forward!things);
        writeLength(newLen);

        if (oldPtr && ptr != oldPtr)
        {
            ptr[0 .. offset] = oldPtr[0 .. offset];
            freeStringBuffer(oldPtr);
        }
    }

    void insertFormat(Things...)(size_t offset, auto ref Things things)
    {
        import urt.string.format : _format = format;
        import urt.util : max, nextPowerOf2;

        char* oldPtr = ptr;
        size_t oldLen = length();

        size_t insertLen = _format(null, things).length;
        size_t newLen = oldLen + insertLen;
        if (newLen == oldLen)
            return;
        debug assert(newLen <= MaxStringLen, "String too long");

        size_t oldAlloc = allocated();
        ptr = newLen <= oldAlloc ? oldPtr : allocStringBuffer(max(16, cast(ushort)newLen + 4).nextPowerOf2 - 4);
        memmove(ptr + offset + insertLen, ptr + offset, oldLen - offset);
        _format(ptr[offset .. offset + insertLen], forward!things);
        writeLength(newLen);

        if (oldPtr && ptr != oldPtr)
        {
            ptr[0 .. offset] = oldPtr[0 .. offset];
            freeStringBuffer(oldPtr);
        }
    }

    void erase(ptrdiff_t offset, size_t count)
    {
        size_t len = length();
        if (offset < 0)
            offset = len + offset;
        size_t eraseEnd = offset + count;
        debug assert(eraseEnd <= len, "Out of bounds");
        memmove(ptr + offset, ptr + eraseEnd, len - eraseEnd);
        writeLength(len - count);
    }

    void reserve(ushort bytes)
    {
        if (bytes > allocated())
        {
            char* newPtr = allocStringBuffer(bytes);
            if (ptr != newPtr)
            {
                size_t len = length();
                newPtr[0 .. len] = ptr[0 .. len];
                freeStringBuffer(ptr);
                ptr = newPtr;
                writeLength(len);
            }
        }
    }

    void clear()
    {
        freeStringBuffer(ptr);
        ptr = null;
    }

private:
    static if (Embed > 0)
    {
        static assert((Embed & (size_t.sizeof - 1)) == 0, "Embed must be multiple of size_t.sizeof bytes");
        char[Embed] embed;
    }

    ushort allocated() const pure nothrow @nogc
    {
        if (!ptr)
            return Embed > 0 ? Embed - 2 : 0;
        static if (Embed > 0)
        {
            if (ptr == embed.ptr + 2)
                return Embed - 2;
        }
        return *cast(ushort*)(ptr - 4);
    }

    void writeLength(size_t len)
    {
        ushort l = void;
        if (len < 128)
        {
            version (LittleEndian)
                l = cast(ushort)(len << 8);
            else
                l = cast(ushort)len;
        }
        else
        {
            version (LittleEndian)
                l = cast(ushort)(((len << 1) & 0xFF00) | (len & 0xFF) | 0x8080);
            else
                l = cast(ushort)((len << 8) | (len >> 7) | 0x8080);
        }
        *cast(ushort*)(ptr - 2) = l;
    }
    void zeroLength()
    {
        *cast(ushort*)(ptr - 2) = 0;
    }

    char* allocStringBuffer(size_t len)
    {
        static if (Embed > 0)
            if (len <= Embed - 2)
                return embed.ptr + 2;
        char* buffer = cast(char*)defaultAllocator().alloc(len + 4).ptr;
        *cast(ushort*)buffer = cast(ushort)len;
        return buffer + 4;
    }

    void freeStringBuffer(char* buffer)
    {
        if (!buffer)
            return;
        static if (Embed > 0)
            if (buffer == embed.ptr + 2)
                return;
        buffer -= 4;
        defaultAllocator().free(buffer[0 .. *cast(ushort*)buffer + 4]);
    }

    auto __debugOverview() const pure => toString;
    auto __debugExpanded() const pure => toString;
    auto __debugStringView() const pure => toString;
}

unittest
{
    MutableString!0 s;
    s.reserve(4567);
    s = "Hello, world!\n";
    foreach (i; 0 .. 100)
    {
        assert(s.length == i*13 + 14);
        s.append("Hello world!\n");
    }
    s.clear();
    s = "wow!";
}


struct SharedString
{
nothrow @nogc:

    String _super;
    alias _super this;

    ~this()
    {
        clear();
    }

    // TODO... we can move-construct from mutable string, etc...

    void clear()
    {
        if (!ptr)
            return;
        ushort* rc = &refCount();
        if (*rc == 0)
            defaultAllocator().free((cast(void*)rc)[0 .. 4 + length()]);
        else
            --*rc;
        ptr = null;
    }

private:
    ref ushort refCount() const pure nothrow @nogc
        => *cast(ushort*)(ptr - 4);

    auto __debugOverview() const pure => toString;
    auto __debugExpanded() const pure => toString;
    auto __debugStringView() const pure => toString;
}


private:

__gshared NoGCAllocator[4] stringAllocators;

void writeString(char* buffer, const(char)[] str) pure nothrow @nogc
{
    size_t lenBytes = str.length < 128 ? 1 : 2;
    if (lenBytes == 1)
        buffer[0] = cast(char)str.length;
    else
    {
        buffer[0] = cast(char)(str.length & 0x7F) | 0x80;
        buffer[1] = cast(char)(str.length >> 7) | 0x80;
    }
    buffer[lenBytes .. lenBytes + str.length] = str[];
}
