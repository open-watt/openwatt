module urt.mem.temp;

import urt.mem;

version = DebugTempAlloc;


enum size_t TempMemSize = 4096;


void[] talloc(size_t size) nothrow @nogc
{
    debug version (DebugTempAlloc)
    {
        import urt.string.format : InFormatFunction;
        assert(InFormatFunction == false, "It is illegal to use the temp allocator inside string conversion functions. Consider using stack or scratchpad.");
    }

    if (size >= TempMemSize / 2)
    {
        assert(false, "Requested temp memory size is too large");
        return null;
    }

    if (allocOffset + size > TempMemSize)
        allocOffset = 0;

    void[] mem = tempMem[allocOffset .. allocOffset + size];
    allocOffset += size;

    return mem;
}

void[] tallocAligned(size_t size, size_t alignment) nothrow @nogc
{
    assert(false);
}

void[] trealloc(void[] mem, size_t newSize) nothrow @nogc
{
    if (newSize <= mem.length)
        return mem[0 .. newSize];
    void[] r = texpand(mem, newSize);
    if (!r)
    {
        r = talloc(newSize);
        if (r !is null)
            r[0 .. mem.length] = mem[];
    }
    return r;
}

void[] treallocAligned(void[] mem, size_t newSize, size_t alignment) nothrow @nogc
{
    assert(false);
}

void[] texpand(void[] mem, size_t newSize) nothrow @nogc
{
    if (mem.ptr + mem.length != tempMem.ptr + allocOffset)
        return null;
    ptrdiff_t grow = newSize - mem.length;
    if (cast(size_t)(allocOffset + grow) > TempMemSize)
        return null;
    allocOffset += grow;
    return mem.ptr[0 .. newSize];
}

void tfree(void[] mem) nothrow @nogc
{
    // maybe do some debug accounting...?
}

char* tstringz(const(char)[] str) nothrow @nogc
{
    if (str.length > TempMemSize / 2)
        return null;

    size_t len = str.length;
    if (allocOffset + len + 1 > TempMemSize)
        allocOffset = 0;

    char* r = cast(char*)tempMem.ptr + allocOffset;
    r[0 .. len] = str[];
    r[len] = '\0';
    allocOffset += len + 1;
    return r;
}

char[] tstring(T)(auto ref T value)
{
    import urt.string.format : toString;
    ptrdiff_t r = toString(value, cast(char[])tempMem[allocOffset..$]);
    if (r < 0)
    {
        allocOffset = 0;
        r = toString(value, cast(char[])tempMem[0..TempMemSize / 2]);
        if (r < 0)
        {
//            assert(false, "Formatted string is too large for the temp buffer!");
            return null;
        }
    }
    char[] result = cast(char[])tempMem[allocOffset .. allocOffset + r];
    allocOffset += r;
    return result;
}

char[] tconcat(Args...)(ref Args args)
{
    import urt.string.format : concat;
    char[] r = concat(cast(char[])tempMem[allocOffset..$], args);
    if (!r)
    {
        allocOffset = 0;
        r = concat(cast(char[])tempMem[0..TempMemSize / 2], args);
    }
    allocOffset += r.length;
    return r;
}

char[] tformat(Args...)(const(char)[] fmt, ref Args args)
{
    import urt.string.format : format;
    char[] r = format(cast(char[])tempMem[allocOffset..$], fmt, args);
    if (!r)
    {
        allocOffset = 0;
        r = format(cast(char[])tempMem[0..TempMemSize / 2], fmt, args);
    }
    allocOffset += r.length;
    return r;
}


class TempAllocator : NoGCAllocator
{
    static import urt.mem.alloc;

    static TempAllocator instance() nothrow @nogc => _instance;

    override void[] alloc(size_t bytes, size_t alignment = DefaultAlign) nothrow @nogc
    {
        return talloc(bytes);
    }

    override void[] realloc(void[] mem, size_t newSize, size_t alignment = DefaultAlign) nothrow @nogc
    {
        return trealloc(mem, newSize);
        // TODO...
//        return realloc(mem.ptr, newSize)[0..newSize];
        return null;
    }

    override void[] expand(void[] mem, size_t newSize) nothrow
    {
        return texpand(mem, newSize);
    }

    override void free(void[] mem) nothrow @nogc
    {
        tfree(mem);
    }

private:
    __gshared TempAllocator _instance = new TempAllocator;
}


private:

static void[TempMemSize] tempMem;
static ushort allocOffset = 0;
