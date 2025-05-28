module urt.string.string;

import urt.lifetime : forward, move;
import urt.mem;
import urt.mem.string : CacheString;
import urt.hash : fnv1aHash, fnv1aHash64;
import urt.string.tailstring : TailString;

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

    int opCmp(const(char)[] rhs) const pure
    {
        import urt.algorithm : compare;
        if (!ptr)
            return rhs.length == 0 ? 0 : -1;
        return compare(ptr[0 .. length()], rhs);
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
    auto __debugOverview() const pure { debug return ptr[0 .. length].debugExcapeString(); else return ptr[0 .. length]; }
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

unittest
{
    // Test StringLit
    enum hello = StringLit!"Hello";
    assert(hello.length == 5);
    assert(hello == "Hello");
    assert(hello.toString == "Hello");
    assert(hello.opDollar() == 5);

    // Test empty StringLit
    enum emptyLit = StringLit!"";
    assert(emptyLit.length == 0);
    assert(emptyLit == "");
    assert(!emptyLit); // opCast!bool

    // Test makeString (default allocator)
    String s1 = makeString("World");
    assert(s1.length == 5);
    assert(s1 == "World");

    // Test makeString (temp allocator)
    // Note: Temp strings are volatile, use with care in real code
    String s2 = makeString("Temporary", StringAlloc.TempString);
    assert(s2.length == 9);
    assert(s2 == "Temporary");

    // Test empty string creation
    String emptyStr = makeString("");
    assert(emptyStr.ptr is null);
    assert(emptyStr.length == 0);
    assert(emptyStr == "");
    assert(!emptyStr);

    String nullStr = String(null);
    assert(nullStr.ptr is null);
    assert(nullStr.length == 0);
    assert(nullStr == "");
    assert(!nullStr);

    // Test assignment and reference counting (basic check)
    String s3 = s1; // s3 references the same data as s1
    assert(s3.ptr == s1.ptr);
    assert(s3 == "World");
    s1 = null; // s1 releases its reference
    assert(s3 == "World"); // s3 should still be valid
    assert(s3.length == 5);

    // Test equality
    String s4 = makeString("World");
    assert(s3 == s4); // Different allocations, same content
    assert(s3 != "world"); // Case sensitive
    assert(s3 != "Worl");
    assert(s3 != "Worlds");

    // Test opIndex and opSlice
    String s5 = StringLit!"Testing";
    assert(s5[0] == 'T');
    assert(s5[6] == 'g');
    assert(s5[1 .. 4] == "est");
    assert(s5[] == "Testing");
    assert(s5[1 .. $] == "esting");
    assert(s5[0 .. $-1] == "Testin");

    // Test hashing (basic check - ensure it runs)
    size_t hash1 = s3.toHash();
    size_t hash2 = s4.toHash();
    size_t hashEmpty = emptyStr.toHash();
    assert(hash1 == hash2);
    assert(hashEmpty == 0);
    assert(StringLit!"abc".toHash() != StringLit!"abd".toHash());

    // Test conversion from MutableString
    MutableString!0 mut = "Mutable";
    String s6 = move(mut); // Takes ownership
    assert(s6 == "Mutable");
    assert(mut.ptr is null); // Original mutable string should be empty

    // Test copy construction
    String s7 = s6;
    assert(s7 == "Mutable");
    assert(s6.ptr == s7.ptr); // Should share the buffer initially
    s6 = null; // Release s6's reference
    assert(s7 == "Mutable"); // s7 should still be valid

    // Test assignment from null
    s7 = null;
    assert(s7.ptr is null);
    assert(s7.length == 0);

    // Test opCmp
    assert(StringLit!"abc".opCmp("abc") == 0);
    assert(StringLit!"abc".opCmp("abd") < 0);
    assert(StringLit!"abd".opCmp("abc") > 0);
    assert(StringLit!"ab".opCmp("abc") < 0);
    assert(StringLit!"abc".opCmp("ab") > 0);
    assert(String(null).opCmp("") == 0);
    assert(String(null).opCmp("a") < 0);
    assert(StringLit!"a".opCmp("") > 0);


    // Test assignment from CacheString/TailString (conceptual - requires setup)
    // import urt.mem.string : addString;
    // auto cs = "Cached".addString();
    // String s8;
    // s8 = cs;
    // assert(s8 == "Cached");
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

    char popFront()
    {
        char c = this[0];
        erase(0, 1);
        return c;
    }

    char popBack()
    {
        char c = this[$-1];
        erase(-1, 1);
        return c;
    }

    MutableString!E takeFront(size_t E = Embed)(size_t count)
    {
        auto r = MutableString!E(this[0 .. count]);
        erase(0, count);
        return r;
    }

    MutableString!N takeFront(size_t N)()
    {
        auto r = MutableString!N(this[0 .. N]);
        erase(0, N);
        return r;
    }

    MutableString!E takeBack(size_t E = Embed)(size_t count)
    {
        auto r = MutableString!E(this[$-count .. $]);
        erase(-count, count);
        return r;
    }

    MutableString!N takeBack(size_t N)()
    {
        auto r = MutableString!N(this[$-N .. $]);
        erase(-N, N);
        return r;
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
        debug assert(count <= len, "Out of bounds");

        if (offset < 0)
            offset = len + offset;
        if (offset != len - count)
        {
            debug assert(size_t(offset) <= len - count, "Out of bounds");
            size_t eraseEnd = offset + count;
            memmove(ptr + offset, ptr + eraseEnd, len - eraseEnd);
        }
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

    auto __debugOverview() const pure { debug return ptr[0 .. length].debugExcapeString(); else return ptr[0 .. length]; }
    auto __debugExpanded() const pure => ptr[0 .. length];
    auto __debugStringView() const pure => ptr[0 .. length];
}

unittest
{
    // Initial tests from previous version
    MutableString!0 s;
    s.reserve(10); // Reserve some initial space
    assert(s.allocated >= 10);
    s = "Hello";
    assert(s == "Hello");
    assert(s.length == 5);

    s.append(", world!\n");
    assert(s == "Hello, world!\n");
    assert(s.length == 14);

    MutableString!0 s_long;
    s_long.reserve(4567);
    s_long = "Start";
    foreach (i; 0 .. 100)
    {
        s_long.append(" Loop ");
        assert(s_long.length == 5 + (i + 1) * 6);
    }
    s_long.clear();
    assert(s_long.length == 0);
    assert(s_long == "");
    s_long = "wow!";
    assert(s_long == "wow!");

    // New tests for missing methods
    MutableString!0 m;

    // opAssign(char)
    m = 'X';
    assert(m == "X");
    assert(m.length == 1);

    // opAssign(const(char)[]) - already tested implicitly

    // opOpAssign("~", ...) / append
    m ~= '!';
    assert(m == "X!");
    m ~= " More";
    assert(m == "X! More");
    m.append(" Text");
    assert(m == "X! More Text");

    // appendFormat
    m.clear();
    m.appendFormat("Value: {0}", 123);
    assert(m == "Value: 123");
    m.appendFormat(", String: {0}", "abc");
    assert(m == "Value: 123, String: abc");

    // concat
    m.concat("New", ' ', "String");
    assert(m == "New String");
    assert(m.length == 10);

    // format
    m.format("Formatted: {0} {1}", "test", 456);
    assert(m == "Formatted: test 456");

    // insert
    m = "String";
    m.insert(0, "My ");   // Beginning
    assert(m == "My String");
    m.insert(3, "Super "); // Middle
    assert(m == "My Super String");
    m.insert(m.length, "!"); // End (same as append)
    assert(m == "My Super String!");

    // insertFormat
    m = "Data";
    m.insertFormat(0, "[{0}] ", 1);
    assert(m == "[1] Data");
    m.insertFormat(4, "\\{{0}\\}", "fmt");
    assert(m == "[1] {fmt}Data");
    m.insertFormat(m.length, " End");
    assert(m == "[1] {fmt}Data End");

    // erase
    m = "RemoveStuff";
    m.erase(0, 6); // Remove "Remove"
    assert(m == "Stuff");
    m = "RemoveStuff";
    m.erase(6, 5); // Remove "Stuff"
    assert(m == "Remove");
    m = "RemoveStuff";
    m.erase(3, 4); // Remove "oveS"
    assert(m == "Remtuff");
    m.erase(0, m.length); // Erase all
    assert(m == "");

    // reserve - already tested implicitly

    // extend
    m = "Init";
    char[] extended = m.extend(3);
    assert(m.length == 7);
    assert(extended.length == 3);
    extended[] = "ial";
    assert(m == "Initial");

    // clear - already tested

    // opIndex, opSlice
    m = "Access";
    assert(m[0] == 'A');
    assert(m[5] == 's');
    m[1] = 'k'; // Modify via ref opIndex
    assert(m == "Akcess");
    assert(m[1..4] == "kce");
    assert(m[] == "Akcess");
    assert(m[1 .. $] == "kcess");
    assert(m[0 .. $ - 1] == "Akces");

    // opDollar
    assert(m.opDollar() == m.length);

    // Constructor variations
    auto m_alloc = MutableString!0(Alloc, 5, 'Z');
    assert(m_alloc == "ZZZZZ");

    auto m_reserve = MutableString!0(Reserve, 20);
    assert(m_reserve.length == 0);
    assert(m_reserve.allocated >= 20);

    auto m_concat = MutableString!0(Concat, "One", "Two", "Three");
    assert(m_concat == "OneTwoThree");

    auto m_format = MutableString!0(Format, "Num: {0}", 99);
    assert(m_format == "Num: 99");

    // Copy construction / assignment
    MutableString!0 m_copy_src = "Copy Me";
    MutableString!0 m_copy_dst = m_copy_src; // Uses copy constructor (or postblit hack)
    assert(m_copy_dst == "Copy Me");
    m_copy_src[0] = 'X'; // Modify original
    assert(m_copy_src == "Xopy Me");
    assert(m_copy_dst == "Copy Me"); // Destination should be independent

    MutableString!0 m_assign_dst;
    m_assign_dst = m_copy_src; // Assignment operator
    assert(m_assign_dst == "Xopy Me");
    m_copy_src[1] = 'Y';
    assert(m_copy_src == "XYpy Me");
    assert(m_assign_dst == "Xopy Me"); // Assignment should also copy
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

debug
{
    char[] debugExcapeString(const char[] s) pure nothrow
    {
        char[] t = new char[s.length*2];
        int d;
        foreach (i; 0 .. s.length)
        {
            switch (s.ptr[i])
            {
                case '\0':  t[d++] = '\\', t[d++] = '0';    break;
                case '\a':  t[d++] = '\\', t[d++] = 'a';    break;
                case '\b':  t[d++] = '\\', t[d++] = 'b';    break;
                case '\f':  t[d++] = '\\', t[d++] = 'f';    break;
                case '\n':  t[d++] = '\\', t[d++] = 'n';    break;
                case '\r':  t[d++] = '\\', t[d++] = 'r';    break;
                case '\t':  t[d++] = '\\', t[d++] = 't';    break;
                case '\v':  t[d++] = '\\', t[d++] = 'v';    break;
                default:    t[d++] = s.ptr[i];              break;
            }
        }
        return t[0..d];
    }
}
