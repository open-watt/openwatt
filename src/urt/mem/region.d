module urt.mem.region;

import urt.util;


static Region* makeRegion(void[] mem) pure nothrow @nogc
{
    assert(mem.length >= Region.sizeof, "Memory block too small");
    Region* region = cast(Region*)mem.ptr.alignUp(Region.alignof);
    size_t alignBytes = cast(void*)region - mem.ptr;
    if (size_t.sizeof > 4 && mem.length > uint.max + alignBytes + Region.sizeof)
        region.length = uint.max;
    else
        region.length = cast(uint)(mem.length - alignBytes - Region.sizeof);
    region.offset = 0;
    return region;
}

struct Region
{
    void[] alloc(size_t size, size_t alignment = size_t.sizeof) pure nothrow @nogc
    {
        size_t ptr = cast(size_t)&this + Region.sizeof + offset;
        size_t alignedPtr = ptr.alignUp(alignment);
        size_t alignBytes = alignedPtr - ptr;
        if (offset + alignBytes + size > length)
            return null;
        offset += alignBytes + size;
        return (cast(void*)alignedPtr)[0 .. size];
    }

    T* alloc(T, Args...)(auto ref Args args) @nogc
        if (is(T == struct))
    {
        import urt.lifetime : emplace, forward;
        return (cast(T*)alloc(T.sizeof, T.alignof).ptr).emplace(forward!args);
    }

    C alloc(C, Args...)(auto ref Args args) @nogc
        if (is(C == class))
    {
        import urt.lifetime : emplace, forward;
        return (cast(C)alloc(__traits(classInstanceSize, C), __traits(classInstanceAlignment, C)).ptr).emplace(forward!Args(args));
    }

    T[] allocArray(T)(size_t count) @nogc
    {
        import urt.lifetime : emplace;
        T* r = cast(T*)alloc(T.sizeof * count, T.alignof).ptr;
        if (!r)
            return null;
        foreach (i; 0 .. count)
            emplace(r + i);
        return r[0 .. count];
    }

private:
    uint offset, length;
}
