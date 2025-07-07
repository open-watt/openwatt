module urt.mem.allocator;

import urt.lifetime;


// TODO: this should be defined by platform/compiler/etc...
enum DefaultAlign = size_t.sizeof;

NoGCAllocator defaultAllocator() nothrow @nogc
{
    return Mallocator.instance;
}

NoGCAllocator tempAllocator() nothrow @nogc
{
    import urt.mem.temp;

    return TempAllocator.instance;
}


class Allocator
{
    abstract void[] alloc(size_t bytes, size_t alignment = DefaultAlign) nothrow;

    void[] realloc(void[] mem, size_t newSize, size_t alignment = DefaultAlign) nothrow
    {
        void[] newMem = alloc(newSize, alignment);
        if (newMem != null)
        {
            if (newSize > mem.length)
                newMem[0..mem.length] = mem[];
            else
                newMem[] = mem[0..newSize];
            free(mem);
        }
        return newMem;
    }

    void[] expand(void[] mem, size_t newSize) nothrow
    {
        return null;
    }

    abstract void free(void[] mem) nothrow;

//    abstract size_t getUsableSize(void* p); // get the usable size for an allocation...

    final T* allocT(T, Args...)(auto ref Args args) nothrow
        if (!is(T == class))
    {
        T* item = cast(T*)alloc(T.sizeof, T.alignof).ptr;
        try
            item.emplace(forward!args);
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        return item;
    }

    final T allocT(T, Args...)(auto ref Args args) nothrow
        if (is(T == class))
    {
        T item = cast(T)alloc(__traits(classInstanceSize, T), __traits(classInstanceAlignment, T)).ptr;
        try
            item.emplace(forward!args);
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        return item;
    }

    final void freeT(T)(T* item) nothrow
        if (!is(T == class))
    {
        try
            destroy!false(*item);
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        free((cast(void*)item)[0..T.sizeof]);
    }

    final void freeT(T)(T item) nothrow
        if (is(T == class))
    {
        try
            item.destroy!false;
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        free((cast(void*)item)[0..__traits(classInstanceSize, T)]);
    }

    final T[] allocArray(T, Args...)(size_t count, auto ref Args args) nothrow
        if (!is(T == class))
    {
        if (count == 0)
            return null;

        T[] items = cast(T[])alloc(T.sizeof * count, T.alignof);
        try
        {
            for (size_t i = 0; i < count - 1; ++i)
                emplace(&items[i], args);
            emplace(&items[$-1], forward!args);
        }
        catch(Exception e)
            assert(false, e.msg);
        return items;
    }

    final T[] reallocArray(T, Args...)(T[] arr, size_t newCount, auto ref Args args) nothrow
        if (!is(T == class))
    {
        if (newCount < arr.length)
        {
            try
            {
                foreach(ref i; arr[newCount..$])
                    destroy!false(i);
            }
            catch(Exception e)
                assert(false, e.msg);
            return arr[0..newCount];
        }
        else if (newCount > arr.length)
        {
            T[] newArr = cast(T[])alloc(T.sizeof * newCount, T.alignof);
            try
            {
                size_t i = 0;
                for (; i < arr.length; ++i)
                    emplace(&newArr[i], arr[i].move);
                for (; i < newCount - 1; ++i)
                    emplace(&newArr[i], args);
                emplace(&newArr[$-1], forward!args);
            }
            catch(Exception e)
                assert(false, e.msg);
            free(arr);
            return newArr;
        }
        return arr;
    }

    final void freeArray(T)(T[] items) nothrow
        if (!is(T == class))
    {
        try
        {
            foreach(ref i; items)
                i.destroy!false;
        }
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        free(cast(void[])items[]);
    }
}

class GCAllocator : Allocator
{
    static GCAllocator instance() nothrow @nogc => _instance;

    override void[] alloc(size_t bytes, size_t alignment = DefaultAlign) nothrow
    {
        // TODO: can/should we enforce alignment?
        return new void[bytes];
    }

    override void free(void[] mem) nothrow
    {
        // GC will take care of it...
    }

private:
    __gshared GCAllocator _instance = new GCAllocator;
}

class NoGCAllocator : Allocator
{
    abstract override void[] alloc(size_t bytes, size_t alignment = DefaultAlign) nothrow @nogc;

    override void[] realloc(void[] mem, size_t newSize, size_t alignment = DefaultAlign) nothrow @nogc
    {
        void[] newMem = alloc(newSize, alignment);
        if (newMem != null)
        {
            if (newSize > mem.length)
                newMem[0..mem.length] = mem[];
            else
                newMem[] = mem[0..newSize];
            free(mem);
        }
        return newMem;
    }

    override void[] expand(void[] mem, size_t newSize) nothrow @nogc
    {
        return null;
    }

    abstract override void free(void[] mem) nothrow @nogc;

    final T* allocT(T, Args...)(auto ref Args args) nothrow @nogc
        if (!is(T == class))
    {
        T* item = cast(T*)alloc(T.sizeof, T.alignof).ptr;
        try
            item.emplace(forward!args);
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        return item;
    }

    final T allocT(T, Args...)(auto ref Args args) nothrow @nogc
        if (is(T == class))
    {
        T item = cast(T)alloc(__traits(classInstanceSize, T), __traits(classInstanceAlignment, T)).ptr;
        try
            item.emplace(forward!args);
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        return item;
    }

    final void freeT(T)(T* item) nothrow @nogc
        if (!is(T == class))
    {
        try
            destroy!false(*item);
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        free((cast(void*)item)[0..T.sizeof]);
    }

    final void freeT(T)(T item) nothrow @nogc
        if (is(T == class))
    {
        // HACK: since druntime can't actually destroy a @nogc class!
        void function(T) nothrow destroyFun = &destroy!(false, T);
        auto forceDestroy = cast(void function(T) nothrow @nogc)destroyFun;

        try
            forceDestroy(item);
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        free((cast(void*)item)[0..__traits(classInstanceSize, T)]);
    }

    final T[] allocArray(T, Args...)(size_t count, auto ref Args args) nothrow @nogc
        if (!is(T == class))
    {
        if (count == 0)
            return null;
        T[] items = cast(T[])alloc(T.sizeof * count, T.alignof);
        try
        {
            for (size_t i = 0; i < count - 1; ++i)
                emplace(&items[i], args);
            emplace(&items[$-1], forward!args);
        }
        catch(Exception e)
            assert(false, e.msg);
        return items;
    }

    final T[] allocArray(T)(size_t count) nothrow @nogc
        if (is(T == class))
    {
        if (count == 0)
            return null;

        T[] items = cast(T[])alloc(T.sizeof * count, T.alignof);
        for (size_t i = 0; i < count - 1; ++i)
            items[i] = null;
        return items;
    }

    final T[] reallocArray(T, Args...)(T[] arr, size_t newCount, auto ref Args args) nothrow @nogc
        if (!is(T == class))
    {
        if (newCount < arr.length)
        {
            try
            {
                foreach(ref i; arr[newCount..$])
                    destroy!false(i);
            }
            catch(Exception e)
                assert(false, e.msg);
            return arr[0..newCount];
        }
        else if (newCount > arr.length)
        {
            T[] newArr = cast(T[])alloc(T.sizeof * newCount, T.alignof);
            try
            {
                size_t i = 0;
                for (; i < arr.length; ++i)
                    emplace(&newArr[i], arr[i].move);
                for (; i < newCount - 1; ++i)
                    emplace(&newArr[i], args);
                emplace(&newArr[$-1], forward!args);
            }
            catch(Exception e)
                assert(false, e.msg);
            if (arr)
                free(arr);
            return newArr;
        }
        return arr;
    }

    final void freeArray(T)(T[] items) nothrow @nogc
        if (!is(T == class))
    {
        try
        {
            foreach(ref i; items)
                destroy!false(i);
        }
        catch(Exception e)
        {
            assert(false, e.msg);
        }
        free(cast(void[])items[]);
    }

    final void freeArray(T)(T[] items) nothrow @nogc
        if (is(T == class))
    {
        free(cast(void[])items[]);
    }
}

class Mallocator : NoGCAllocator
{
    static import urt.mem.alloc;

    static Mallocator instance() nothrow @nogc => _instance;

    override void[] alloc(size_t size, size_t alignment = DefaultAlign) nothrow @nogc
    {
        return urt.mem.alloc.allocAligned(size, alignment);
    }

    override void[] realloc(void[] mem, size_t newSize, size_t alignment = DefaultAlign) nothrow @nogc
    {
        return urt.mem.alloc.reallocAligned(mem, newSize, alignment);
    }

    override void[] expand(void[] mem, size_t newSize) nothrow
    {
        return urt.mem.alloc.expand(mem, newSize);
    }

    override void free(void[] mem) nothrow @nogc
    {
        urt.mem.alloc.freeAligned(mem);
    }

private:
    __gshared Mallocator _instance = new Mallocator;
}

class RegionAllocator : NoGCAllocator
{
    import urt.mem.region;

    static RegionAllocator getRegionAllocator(void[] region) pure nothrow @nogc
    {
        Region* r = makeRegion(region);
        return r.alloc!RegionAllocator(r);
    }


    this(Region* region) pure nothrow @nogc
    {
        this.region = region;
    }

    override void[] alloc(size_t bytes, size_t alignment = DefaultAlign) pure nothrow @nogc
    {
        return region.alloc(bytes, alignment);
    }

    override void free(void[] mem) pure nothrow @nogc
    {
    }

    Region* region;
}


unittest
{
    struct S
    {
        int x;
        this(int arg)
        {
            x = arg;
        }
        ~this()
        {
            x = 0;
        }
    }
    class C
    {
        int x;
        this()
        {
            x = 10;
        }
        ~this()
        {
            x = 0;
        }
    }

    Allocator a = new Mallocator;
    S* s = a.allocT!S(10);
    a.freeT(s);
    C c = a.allocT!C();
    a.freeT(c);
    S[] arr = a.allocArray!S(10, 10);
    a.freeArray(arr[]);
}
