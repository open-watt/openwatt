module urt.string.string;

import urt.lifetime : forward;
import urt.mem;
import urt.mem.string : CacheString;
import urt.string : fnv1aHash, fnv1aHash64;
import urt.string.tailstring : TailString;

import core.lifetime : move;

public import urt.array : Alloc_T, Alloc, Reserve_T, Reserve, Concat_T, Concat;
enum Format_T { Value }
alias Format = Format_T.Value;


enum MaxStringLen = 0x7FFF;

enum StringAlloc : ubyte
{
    Default,
    User1,
    User2,
    Explicit,   // carries an allocator with the string

    TempString, // allocates in the temp ring buffer; could be overwritten at any time!

    // these must be last... (because comparison logic)
    StringCache,        // writes to the immutable string cache
    StringCacheDedup,   // writes to the immutable string cache with de-duplication
}

struct StringAllocator
{
    char* delegate(ushort bytes, void* userData) nothrow @nogc alloc;
    void delegate(char* s) nothrow @nogc free;
}


//enum String StringLit(string s) = s.makeString;
template StringLit(const(char)[] lit, bool zeroTerminate = true)
{
    static assert(lit.length <= MaxStringLen, "String too long");

    private enum LitLen = 2 + lit.length + (zeroTerminate ? 1 : 0);
    private enum char[LitLen] LiteralData = () {
        pragma(aligned, 2) char[LitLen] buffer;
        version (LittleEndian)
        {
            buffer[0] = lit.length & 0xFF;
            buffer[1] = cast(ubyte)(lit.length >> 8);
        }
        else
        {
            buffer[0] = cast(ubyte)(lit.length >> 8);
            buffer[1] = lit.length & 0xFF;
        }
        buffer[2 .. 2 + lit.length] = lit[];
        static if (zeroTerminate)
            buffer[$-1] = '\0'; // add a zero terminator for good measure
        return buffer;
    }();
    pragma(aligned, 2)
    private __gshared literal = LiteralData;

    enum String StringLit = String(literal.ptr + 2, false);
}


String makeString(const(char)[] s) nothrow
{
    if (s.length == 0)
        return String(null);
    return makeString(s, new char[2 + s.length]);
}

String makeString(const(char)[] s, StringAlloc allocator, void* userData = null) nothrow @nogc
{
    if (s.length == 0)
        return String(null);

    assert(s.length <= MaxStringLen, "String too long");
    assert(allocator <= StringAlloc.max, "String allocator index must be < 3");

    if (allocator < stringAllocators.length)
    {
        return String(writeString(stringAllocators[allocator].alloc(cast(ushort)s.length, null), s), true);
    }
    else if (allocator == StringAlloc.TempString)
    {
        return String(writeString(cast(char*)tempAllocator().alloc(2 + s.length, 2).ptr + 2, s), false);
    }
    else if (allocator >= StringAlloc.StringCache)
    {
        import urt.mem.string : CacheString, addString;

        CacheString cs = s.addString(allocator == StringAlloc.StringCacheDedup);
        return String(cs.ptr, false);
    }
    assert(false, "Invalid string allocator");
}

String makeString(const(char)[] s, NoGCAllocator a) nothrow @nogc
{
    if (s.length == 0)
        return String(null);

    assert(s.length <= MaxStringLen, "String too long");

    return String(writeString(stringAllocators[StringAlloc.Explicit].alloc(cast(ushort)s.length, cast(void*)a), s), true);
}

String makeString(const(char)[] s, char[] buffer) nothrow @nogc
{
    if (s.length == 0)
        return String(null);

    debug assert((cast(size_t)buffer.ptr & 1) == 0, "Buffer must be 2-byte aligned");
    assert(buffer.length >= 2 + s.length, "Not enough memory for string");

    return String(writeString(buffer.ptr + 2, s), false);
}


struct String
{
nothrow @nogc:

    alias toString this;

    const(char)* ptr;

    this(typeof(null)) inout pure
    {
        this.ptr = null;
    }

    this(ref inout typeof(this) rhs) inout pure
    {
        ptr = rhs.ptr;
        if (ptr)
        {
            ushort* rc = ((cast(ushort*)ptr)[-1] >> 15) ? cast(ushort*)ptr - 2 : null;
            if (rc)
            {
                assert((*rc & 0x3FFF) < 0x3FFF, "Reference count overflow");
                ++*rc;
            }
        }
    }

    this(size_t Embed)(MutableString!Embed str) inout //pure TODO: PUT THIS BACK!!
    {
        if (!str.ptr)
            return;

        static if (Embed > 0)
        {
            if (Embed > 0 && str.ptr == str.embed.ptr + 2)
            {
                // clone the string
                this(writeString(stringAllocators[0].alloc(cast(ushort)str.length, null), str[]), true);
                return;
            }
        }

        // take the buffer
        ptr = cast(inout(char*))str.ptr;
        *cast(ushort*)(ptr - 4) = 0; // rc = 0, allocator = 0 (default)
        str.ptr = null;
    }

    this(TS)(inout TailString!TS ts) inout pure
    {
        ptr = ts.ptr;
    }

    this(inout CacheString cs) inout
    {
        ptr = cs.ptr;
    }

    ~this()
    {
        if (ptr)
            decRef();
    }

    const(char)[] toString() const pure
        => ptr[0 .. length()];

    // TODO: I made this return ushort, but normally length() returns size_t
    ushort length() const pure
        => ptr ? ((cast(ushort*)ptr)[-1] & 0x7FFF) : 0;

    bool opCast(T : bool)() const pure
        => ptr != null && ((cast(ushort*)ptr)[-1] & 0x7FFF) != 0;

    void opAssign(typeof(null))
    {
        if (ptr)
        {
            decRef();
            ptr = null;
        }
    }

    void opAssign(TS)(const(TailString!TS) ts) pure
    {
        if (ptr)
            decRef();

        ptr = ts.ptr;
    }

    void opAssign(const(CacheString) cs)
    {
        if (ptr)
            decRef();

        ptr = cs.ptr;
    }


    bool opEquals(const(char)[] rhs) const pure
    {
        if (!ptr)
            return rhs.length == 0;
        ushort len = (cast(ushort*)ptr)[-1] & 0x7FFF;
        return len == rhs.length && (ptr == rhs.ptr || ptr[0 .. len] == rhs[]);
    }

    size_t toHash() const pure
    {
        if (!ptr)
            return 0;
        static if (size_t.sizeof == 4)
            return fnv1aHash(cast(ubyte[])ptr[0 .. length]);
        else
            return fnv1aHash64(cast(ubyte[])ptr[0 .. length]);
    }

    const(char)[] opIndex() const pure
        => ptr[0 .. length()];

    char opIndex(size_t i) const pure
    {
        debug assert(i < length());
        return ptr[i];
    }

    const(char)[] opSlice(size_t x, size_t y) const pure
    {
        debug assert(y <= length(), "Range error");
        return ptr[x .. y];
    }

    size_t opDollar() const pure
        => length();

private:
    auto __debugOverview() const pure => ptr[0 .. length];
    auto __debugExpanded() const pure => ptr[0 .. length];
    auto __debugStringView() const pure => ptr[0 .. length];

    ushort* refCounter() const pure
        => ((cast(ushort*)ptr)[-1] >> 15) ? cast(ushort*)ptr - 2 : null;

    void addRef() pure
    {
        if (ushort* rc = refCounter())
        {
            assert((*rc & 0x3FFF) < 0x3FFF, "Reference count overflow");
            ++*rc;
        }
    }

    void decRef()
    {
        if (ushort* rc = refCounter())
        {
            if ((*rc & 0x3FFF) == 0)
                stringAllocators[*rc >> 14].free(cast(char*)ptr);
            else
                --*rc;
        }
    }

    this(inout(char)* str, bool refCounted) inout pure
    {
        ptr = str;
        if (refCounted)
            *cast(ushort*)(ptr - 2) |= 0x8000;
    }
}

struct MutableString(size_t Embed = 0)
{
nothrow @nogc:

    static assert(Embed == 0, "Not without move semantics!");

    alias toString this;

    char* ptr;

    // TODO: DELETE POSTBLIT!
    this(this)
    {
        // HACK! THIS SHOULDN'T EXIST, USE COPY-CTOR INSTEAD
        const(char)[] t = this[];
        ptr = null;
        this = t[];
    }

    this(ref const typeof(this) rh)
    {
        this(rh[]);
    }
    this(size_t E)(ref const MutableString!E rh)
        if (E != Embed)
    {
        this(rh[]);
    }

    this(typeof(null)) pure
    {
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

    this(Alloc_T, size_t length, char pad = '\0')
    {
        debug assert(length <= MaxStringLen, "String too long");
        reserve(cast(ushort)length);
        writeLength(length);
        ptr[0 .. length] = pad;
    }

    this(Reserve_T, size_t length)
    {
        debug assert(length <= MaxStringLen, "String too long");
        reserve(cast(ushort)length);
    }

    this(Things...)(Concat_T, auto ref Things things)
    {
        append(forward!things);
    }

    this(Args...)(Format_T, auto ref Args args)
    {
        format(forward!args);
    }

    ~this()
    {
        freeStringBuffer(ptr);
    }

    inout(char)[] toString() inout pure
        => ptr[0 .. length()];

    // TODO: I made this return ushort, but normally length() returns size_t
    ushort length() const pure
        => ptr ? ((cast(ushort*)ptr)[-1] & 0x7FFF) : 0;

    bool opCast(T : bool)() const pure
        => ptr != null && ((cast(ushort*)ptr)[-1] & 0x7FFF) != 0;

    void opAssign(ref const typeof(this) rh)
    {
        opAssign(rh[]);
    }
    void opAssign(size_t E)(ref const MutableString!E rh)
    {
        opAssign(rh[]);
    }

    void opAssign(typeof(null))
    {
        clear();
    }

    void opAssign(char c)
    {
        reserve(1);
        writeLength(1);
        ptr[0] = c;
    }

    void opAssign(const(char)[] s)
    {
        if (s == null)
        {
            clear();
            return;
        }
        debug assert(s.length <= MaxStringLen, "String too long");
        reserve(cast(ushort)s.length);
        writeLength(s.length);
        ptr[0 .. s.length] = s[];
    }

    void opOpAssign(string op: "~", Things)(Things things)
    {
        insert(length(), forward!things);
    }

    size_t opDollar() const pure
        => length();

    inout(char)[] opIndex() inout pure
        => ptr[0 .. length()];

    ref char opIndex(size_t i) pure
    {
        debug assert(i < length());
        return ptr[i];
    }

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

    ref MutableString!Embed append(Things...)(auto ref Things things)
    {
        insert(length(), forward!things);
        return this;
    }

    ref MutableString!Embed appendFormat(Things...)(auto ref Things things)
    {
        insertFormat(length(), forward!things);
        return this;
    }

    ref MutableString!Embed concat(Things...)(auto ref Things things)
    {
        if (ptr)
            writeLength(0);
        insert(0, forward!things);
        return this;
    }

    ref MutableString!Embed format(Args...)(auto ref Args args)
    {
        if (ptr)
            writeLength(0);
        insertFormat(0, forward!args);
        return this;
    }

    ref MutableString!Embed insert(Things...)(size_t offset, auto ref Things things)
    {
        import urt.string.format : _concat = concat;
        import urt.util : max, nextPowerOf2;

        char* oldPtr = ptr;
        size_t oldLen = length();

        size_t insertLen = _concat(null, things).length;
        size_t newLen = oldLen + insertLen;
        if (newLen == oldLen)
            return this;
        debug assert(newLen <= MaxStringLen, "String too long");

        size_t oldAlloc = allocated();
        ptr = newLen <= oldAlloc ? oldPtr : allocStringBuffer(max(16, cast(ushort)newLen + 4).nextPowerOf2 - 4);
        memmove(ptr + offset + insertLen, oldPtr + offset, oldLen - offset);
        _concat(ptr[offset .. offset + insertLen], forward!things);
        writeLength(newLen);

        if (oldPtr && ptr != oldPtr)
        {
            ptr[0 .. offset] = oldPtr[0 .. offset];
            freeStringBuffer(oldPtr);
        }
        return this;
    }

    ref MutableString!Embed insertFormat(Things...)(size_t offset, auto ref Things things)
    {
        import urt.string.format : _format = format;
        import urt.util : max, nextPowerOf2;

        char* oldPtr = ptr;
        size_t oldLen = length();

        size_t insertLen = _format(null, things).length;
        size_t newLen = oldLen + insertLen;
        if (newLen == oldLen)
            return this;
        debug assert(newLen <= MaxStringLen, "String too long");

        size_t oldAlloc = allocated();
        ptr = newLen <= oldAlloc ? oldPtr : allocStringBuffer(max(16, cast(ushort)newLen + 4).nextPowerOf2 - 4);
        memmove(ptr + offset + insertLen, oldPtr + offset, oldLen - offset);
        _format(ptr[offset .. offset + insertLen], forward!things);
        writeLength(newLen);

        if (oldPtr && ptr != oldPtr)
        {
            ptr[0 .. offset] = oldPtr[0 .. offset];
            freeStringBuffer(oldPtr);
        }
        return this;
    }

    ref MutableString!Embed erase(ptrdiff_t offset, size_t count)
    {
        size_t len = length();
        if (offset < 0)
            offset = len + offset;
        size_t eraseEnd = offset + count;
        debug assert(eraseEnd <= len, "Out of bounds");
        memmove(ptr + offset, ptr + eraseEnd, len - eraseEnd);
        writeLength(len - count);
        return this;
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

    char[] extend(size_t length)
    {
        size_t oldLen = this.length;
        debug assert(oldLen + length <= MaxStringLen, "String too long");

        reserve(cast(ushort)(oldLen + length));
        writeLength(oldLen + length);
        return ptr[oldLen .. oldLen + length];
    }

    void clear()
    {
        if (ptr)
            writeLength(0);
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
        return (cast(ushort*)ptr)[-2];
    }

    void writeLength(size_t len)
    {
        (cast(ushort*)ptr)[-1] = cast(ushort)len;
    }

    char* allocStringBuffer(size_t len)
    {
        static if (Embed > 0)
            if (len <= Embed - 2)
                return embed.ptr + 2;
        char* buffer = cast(char*)defaultAllocator().alloc(len + 4, 2).ptr;
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
        defaultAllocator().free(buffer[0 .. 4 + *cast(ushort*)buffer]);
    }

    auto __debugOverview() const pure => ptr[0 .. length];
    auto __debugExpanded() const pure => ptr[0 .. length];
    auto __debugStringView() const pure => ptr[0 .. length];
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


private:

__gshared StringAllocator[4] stringAllocators;
static assert(stringAllocators.length <= 4, "Only 2 bits reserved to store allocator index");

char* writeString(char* buffer, const(char)[] str) pure nothrow @nogc
{
    // TODO: assume the calling code has confirmed the length is within spec
    (cast(ushort*)buffer)[-1] = cast(ushort)str.length;
    buffer[0 .. str.length] = str[];
    return buffer;
}

package(urt) void initStringAllocators()
{
    stringAllocators[StringAlloc.Default].alloc = (ushort bytes, void* userData) {
        char* buffer = cast(char*)defaultAllocator().alloc(bytes + 4, ushort.alignof).ptr;
        *cast(ushort*)buffer = StringAlloc.Default << 14; // allocator = default, rc = 0
        return buffer + 4;
    };
    stringAllocators[StringAlloc.Default].free = (char* str) {
        ushort len = (cast(ushort*)str)[-1] & 0x7FFF;
        str -= 4;
        defaultAllocator().free(str[0 .. 4 + len]);
    };

    stringAllocators[StringAlloc.Explicit].alloc = (ushort bytes, void* userData) {
        NoGCAllocator a = cast(NoGCAllocator)userData;
        char* buffer = cast(char*)a.alloc(size_t.sizeof*2 + bytes, size_t.alignof).ptr;
        *cast(NoGCAllocator*)buffer = a;
        buffer += size_t.sizeof*2;
        (cast(ushort*)buffer)[-2] = StringAlloc.Explicit << 14; // allocator = explicit, rc = 0
        return buffer;
    };
    stringAllocators[StringAlloc.Explicit].free = (char* str) {
        NoGCAllocator a = *cast(NoGCAllocator*)(str - size_t.sizeof*2);
        ushort len = (cast(ushort*)str)[-1] & 0x7FFF;
        str -= size_t.sizeof*2;
        a.free(str[0 .. size_t.sizeof*2 + len]);
    };
}
