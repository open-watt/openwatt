module urt.mem.alloc;

import core.stdc.stdlib;

nothrow @nogc:

void[] alloc(size_t size) nothrow @nogc
{

    // TODO: we might pin the length to a debug table somewhere...
    return malloc(size)[0 .. size];
}

void[] allocAligned(size_t size, size_t alignment) nothrow @nogc
{
    import urt.util : isPowerOf2, max;
    alignment = max(alignment, (void*).sizeof);
    assert(isPowerOf2(alignment), "Alignment must be a power of two!");

    version (Windows)
    {
        import urt.util : alignDown;

        // This is how Visual Studio's _aligned_malloc works...
        // see C:\Program Files (x86)\Windows Kits\10\Source\10.0.15063.0\ucrt\heap\align.cpp
        //
        // This is implemented so memsize() can return the correct result.
        //
        size_t header_size = (void*).sizeof + alignment;
        size_t total = header_size + size;

        void* mem = malloc(total);
        if (mem is null)
            return null;

        size_t ptr = cast(size_t)mem;
        size_t allocptr = alignDown(ptr + header_size, alignment);
        (cast(void**)allocptr)[-1] = mem;

        return (cast(void*)allocptr)[0 .. size];
    }
    else version (Posix)
    {
        import core.sys.posix.stdlib;
        void* mem;
        return posix_memalign(&mem, alignment, size) ? null : mem[0 .. size];
    }
    else
    {
        void[] mem = malloc(size)[0 .. size];
        // HACK: just for now...
        assert((cast(size_t)mem.ptr & (alignment - 1)) == 0, "Memory not aligned!");
        return mem;
    }
}

void[] realloc(void[] mem, size_t newSize) nothrow @nogc
{
    // TODO: we might pin the length to a debug table somewhere...
    return core.stdc.stdlib.realloc(mem.ptr, newSize)[0 .. newSize];
}

void[] reallocAligned(void[] mem, size_t newSize, size_t alignment) nothrow @nogc
{
    import urt.util : isPowerOf2, min, max;

    alignment = max(alignment, (void*).sizeof);
    assert(isPowerOf2(alignment), "Alignment must be a power of two!");

    void[] newAlloc = newSize > 0 ? allocAligned(newSize, alignment) : null;
    if (newAlloc !is null && mem !is null)
    {
        size_t toCopy = min(mem.length, newSize);
        newAlloc[0 .. toCopy] = mem[0 .. toCopy];
    }
    freeAligned(mem);
    return newAlloc;
}

// NOTE: This function is only compatible with allocAligned!
void[] expand(void[] mem, size_t newSize) nothrow @nogc
{
    version (Windows)
    {
        if (mem.ptr is null)
            return null;
        void* ptr = (cast(void**)mem.ptr)[-1];
        size_t head = (cast(size_t)mem.ptr - cast(size_t)ptr);
        void* r = _expand(ptr, head + newSize);
        if (r is null)
            return null;
        return mem.ptr[0 .. newSize];
    }
    else
    {
        if (newSize <= memsize(mem.ptr))
            return mem.ptr[0 .. newSize];
        return null;
    }
}

void free(void[] mem) nothrow @nogc
{
    // maybe check the length passed to free matches the alloc?
    // ... or you know, just don't do that.

    core.stdc.stdlib.free(mem.ptr);
}

void freeAligned(void[] mem) nothrow @nogc
{
    version (Windows)
    {
        if (mem.ptr is null)
            return;
        void* p = (cast(void**)mem.ptr)[-1];
        core.stdc.stdlib.free(p);
    }
    else
        core.stdc.stdlib.free(mem.ptr);
}

size_t memsize(void* ptr) nothrow @nogc
{
    version (Windows)
    {
        if (ptr is null)
            return 0;
        void* mem = (cast(void**)ptr)[-1];
        return _msize(mem) - (cast(size_t)ptr - cast(size_t)mem);
    }
    else version (Posix)
        return malloc_usable_size(ptr);
    else version (Darwin)
        return malloc_size(ptr);
    else
        assert(false, "Unsupported platform");
}


unittest
{
    void[] mem = allocAligned(16, 8);
    size_t s = memsize(mem.ptr);
    mem = expand(mem, 8);
    mem = expand(mem, 16);
    freeAligned(mem);
}


version (Windows)
{
    extern(C) void* _expand(void* memblock, size_t size) nothrow @nogc;
    extern(C) size_t _msize(void* _Block);
}

version (Posix)
{
    extern(C) size_t malloc_usable_size(void *__ptr);
}
