module urt.mem.string;

import urt.mem;
import urt.string;


// TODO: THIS IS TEMP!! REMOVE ME!!
shared static this()
{
    initStringHeap(ushort.max);
}


struct StringCache
{
}


struct CacheString
{
    alias toString this;

    this(typeof(null)) pure nothrow @nogc
    {
        offset = 0;
    }

    string toString() const nothrow @nogc
    {
        ushort len = *cast(ushort*)(stringHeap.ptr + offset);
        return cast(string)stringHeap[offset + 2 .. offset + 2 + len];
    }

    immutable(char)* ptr() const nothrow @nogc
        => cast(immutable(char)*)(stringHeap.ptr + offset + 2);

    size_t length() const nothrow @nogc
        => *cast(ushort*)(stringHeap.ptr + offset);

    bool opCast(T : bool)() const pure nothrow @nogc
        => offset != 0;

    void opAssign(typeof(null)) pure nothrow @nogc
    {
        offset = 0;
    }

    bool opEquals(const(char)[] rhs) const nothrow @nogc
    {
        string s = toString();
        return s.length == rhs.length && (s.ptr == rhs.ptr || s[] == rhs[]);
    }

    size_t toHash() const nothrow @nogc
    {
        import urt.hash;

        static if (size_t.sizeof == 4)
            return fnv1aHash(cast(ubyte[])toString());
        else
            return fnv1aHash64(cast(ubyte[])toString());
    }

private:
    ushort offset;

    this(ushort offset) pure nothrow @nogc
    {
        this.offset = offset;
    }

    auto __debugOverview() => toString;
    auto __debugExpanded() => toString;
    auto __debugStringView() => toString;
}

void initStringHeap(uint stringHeapSize) nothrow
{
    assert(stringHeapInitialised == false, "String heap already initialised!");
    assert(stringHeapSize <= ushort.max, "String heap too large!");

    stringHeap = new char[stringHeapSize];

    // write the null string to the start
    stringHeapCursor = 0;
    stringHeap[stringHeapCursor++] = 0;
    stringHeap[stringHeapCursor++] = 0;
    numStrings = 1;

    stringHeapInitialised = true;
}

void deinitStringHeap() nothrow
{
}

uint getStringHeapAllocated() nothrow @nogc
{
    return stringHeapCursor;
}

uint getStringHeapRemaining() nothrow @nogc
{
    return cast(uint)stringHeap.length - stringHeapCursor;
}

CacheString addString(const(char)[] str, bool dedup = true) nothrow @nogc
{
    // null string
    if (str.length == 0)
        return CacheString(0);

    assert(str.length < 2^^14, "String longer than max string len (32768 chars)");

    if (dedup)
    {
        // first we scan to see if it's already in here...
        for (ushort i = 1; i < stringHeapCursor;)
        {
            ushort offset = i;
            ushort len = stringHeap[i++];
            if (len >= 128)
                len = (len & 0x7F) | ((stringHeap[i++] << 7) & 0x7F);
            if (len == str.length && stringHeap[i .. i + len] == str[])
                return CacheString(offset);
            i += len;
        }
    }

    if (stringHeapCursor & 1)
        stringHeap[stringHeapCursor++] = '\0';

    // add the string to the heap...
    assert(stringHeapCursor + str.length < stringHeap.length, "String heap overflow!");

    ushort offset = stringHeapCursor;
    str.makeString(stringHeap[stringHeapCursor .. $]);
    stringHeapCursor += str.length + 2;
    ++numStrings;

    return CacheString(offset);
}


void* allocWithStringCache(size_t bytes, String[] cachedStrings, const(char[])[] strings) nothrow @nogc
{
    import urt.mem.alloc;

    size_t extra = 0;
    foreach (s; strings)
        extra += 2 + s.length + (s.length & 1);

    void* ptr = alloc(bytes + extra).ptr;
    char* buffer = cast(char*)ptr + bytes;
    foreach (size_t i, str; strings)
    {
        cachedStrings[i] = str.makeString(buffer[0..extra]);
        buffer += 2 + str.length + (str.length & 1);
    }

    return ptr;
}

//T* allocWithStringCache(T)(char*[] cachedStrings, const(char)[] strings...)
//{
//    T* item = cast(T*)allocWithStringCache(T.sizeof, cachedStrings, strings);
//    // construct!
//    return item;
//}

class StringAllocator : NoGCAllocator
{
    override void[] alloc(size_t bytes, size_t alignment = 1) nothrow @nogc
    {
        assert(stringHeapCursor + bytes < stringHeap.length, "String heap overflow!");

        char[] heap = cast(char[])stringHeap;
        return heap[stringHeapCursor .. stringHeapCursor + bytes];
    }

    override void free(void[] mem) nothrow @nogc
    {
        // you don't free cached strings!
    }
}



private:

__gshared bool stringHeapInitialised = false;
__gshared char[] stringHeap = null;
__gshared ushort stringHeapCursor = 0;
__gshared uint numStrings = 0;


unittest
{
    // TODO: uncomment this when all the global/static boot-time string allocations are removed
/+
    initStringHeap(1024);

    CacheString s1 = addString("hello");
    assert(s1.offset == 1);
    assert(s1.length == 5);
    assert(s1[] == "hello");
    assert(!!s1 == true);
    CacheString s2 = addString("hello");
    assert(s2.offset == 1);
    CacheString s3 = addString("hello", false);
    assert(s3.offset == 7);
    CacheString s4 = addString(null);
    assert(s4.offset == 0);
    assert(s4.ptr == stringHeap.ptr + 1);
    assert(!!s4 == false);
    CacheString s5 = addString("");
    assert(s5.offset == 0);
    CacheString s6 = addString("really really really really really really really really really really really really really really really really really long string!");
    assert(s6.length == 131);
    assert(s6.ptr == stringHeap.ptr + s6.offset + 2);
    assert(s6[] == "really really really really really really really really really really really really really really really really really long string!");
    CacheString s7 = addString("really really really really really really really really really really really really really really really really really long string!");
    assert(s7.offset == s6.offset);
+/
}
