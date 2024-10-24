module urt.array;

import urt.mem;


nothrow @nogc:


bool beginsWith(T, U)(const(T)[] arr, U[] rh)
    => rh.length <= arr.length && arr[0 .. rh.length] == rh[];

bool endsWith(T, U)(const(T)[] arr, U[] rh)
    => rh.length <= arr.length && arr[$ - rh.length .. $] == rh[];

T[] pop(T)(ref T[] arr, ptrdiff_t n)
{
    T[] r = arr[0 .. n];
    arr = arr[n .. $];
    return r;
}

//Slice<T> take(ptrdiff_t n)
//Slice<T> drop(ptrdiff_t n)

bool exists(T)(const(T)[] arr, auto ref const T el, size_t *pIndex = null)
{
    foreach (i, ref e; arr)
    {
        if (e.elCmp(el))
        {
            if (pIndex)
                *pIndex = i;
            return true;
        }
    }
    return false;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findFirst(T, U)(const(T)[] arr, auto ref const U el)
{
    size_t i = 0;
    while (i < arr.length && !arr[i].elCmp(el))
        ++i;
    return i;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findLast(T, U)(const(T)[] arr, auto ref const U el)
{
    ptrdiff_t last = length-1;
    while (last >= 0 && !arr[last].elCmp(el))
        --last;
    return last < 0 ? length : last;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findFirst(T, U)(const(T)[] arr, U[] seq)
{
    if (seq.length == 0)
        return 0;
    size_t i = 0;
    for (; i < arr.length - seq.length; ++i)
    {
        if (arr[i .. i + seq.length] == seq[])
            return i;
    }
    return arr.length;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findLast(T, U)(const(T)[] arr, U[] seq)
{
    if (seq.length == 0)
        return arr.length;
    ptrdiff_t i = arr.length - seq.length;
    for (; i >= 0; --i)
    {
        if (arr[i .. i + seq.length] == seq[])
            return i;
    }
    return arr.length;
}

size_t findFirst(T)(const(T)[] arr, bool delegate(auto ref const T) nothrow @nogc pred)
{
    size_t i = 0;
    while (i < arr.length && !pred(arr[i]))
        ++i;
    return i;
}

ptrdiff_t indexOfElement(T, U)(const(T)[] arr, const(U)* el)
{
    if (el < arr.ptr || el >= arr.ptr + arr.length)
        return -1;
    return el - arr.ptr;
}

inout(T)* search(T)(inout(T)[] arr, bool delegate(ref const T) nothrow @nogc pred)
{
    foreach (ref e; arr)
    {
        if (pred(e))
            return &e;
    }
    return null;
}

U[] copyTo(T, U)(T[] arr, U[] dest)
{
    assert(dest.length >= arr.length);
    dest[0 .. arr.length] = arr[];
    return dest[0 .. arr.length];
}


// Array introduces static-sized and/or stack-based ownership. this is useful anywhere that fixed-length arrays are appropriate
// Array will fail-over to an allocated buffer if the contents exceed the fixed size
struct Array(T, size_t EmbedCount = 0)
{
    static assert(EmbedCount == 0, "Not without move semantics!");

    static if (is(T == void))
        alias ElementType = ubyte;
    else
        alias ElementType = T;

    // constructors

    this(this) @disable;

    this(ref typeof(this) val)
    {
        this(val[]);
    }
    this(size_t EC)(ref Array!(T, EC) val)
        if (EC != EmbedCount)
    {
        this(val[]);
    }

    this(typeof(null)) {}

    this(U)(U[] arr)
        if (is(U : T))
    {
        debug assert(arr.length <= uint.max);
        reserve(arr.length);
        for (uint i = 0; i < arr.length; ++i)
            emplace!T(&ptr[i], arr.ptr[i]);
        _length = cast(uint)arr.length;
    }

    this(U, size_t N)(ref U[N] arr)
        if (is(U : T))
    {
        this(arr[]);
    }

//    this(Alloc_T, size_t count);
//    this(Reserve_T, size_t count);
//    this(Items...)(Concat_T, auto ref Items items);

    ~this()
    {
        clear();
        if (hasAllocation())
            defaultAllocator().free(ptr[0 .. _length]);
    }

nothrow @nogc:

    // assignment

    void opAssign(ref typeof(this) val)
    {
        opAssign(val[]);
    }
    void opAssign(size_t EC)(ref Array!(T, EC) val)
        if (EC != EmbedCount)
    {
        opAssign(val[]);
    }

    void opAssign(typeof(null))
    {
        clear();
    }

    void opAssign(U)(U[] arr)
        if (is(U : T))
    {
        debug assert(arr.length <= uint.max);
        clear();
        reserve(arr.length);
        for (uint i = 0; i < arr.length; ++i)
            emplace!T(&ptr[i], arr.ptr[i]);
        _length = cast(uint)arr.length;
    }

    void opAssign(U, size_t N)(U[N] arr)
        if (is(U : T))
    {
        opAssign(arr[]);
    }

    // manipulation
    ref Array!(T, Count) concat(Things...)(auto ref Things things);

    bool empty() const
        => _length == 0;
    size_t length() const
        => _length;

    ref inout(T) front() inout
    {
        debug assert(_length > 0, "Range error");
        return ptr[0];
    }
    ref inout(T) back() inout
    {
        debug assert(_length > 0, "Range error");
        return ptr[_length - 1];
    }

    static if (is(T == class) || is(T == interface))
    {
        ref T pushFront()
            => pushFront(null);
        ref T pushBack()
            => pushBack(null);
    }
    else
    {
        ref T pushFront()
            => pushFront(T.init);
        ref T pushBack()
            => pushBack(T.init);
    }

    ref T pushFront(U)(auto ref U item)
        if (is(U : T))
    {
        static if (is(T == class) || is(T == interface))
        {
            uint len = _length;
            reserve(len + 1);
            _length = len + 1;
            for (uint i = len; i > 0; --i)
                ptr[i] = ptr[i-1];
            ptr[0] = item;
            return ptr[0];
        }
        else
        {
            uint len = _length;
            reserve(len + 1);
            _length = len + 1;
            for (uint i = len; i > 0; --i)
            {
                emplace!T(&ptr[i], ptr[i-1].move);
                ptr[i-1].destroy!false();
            }
            emplace!T(&ptr[0], forward!item);
            return ptr[0];
        }
    }

    ref T pushBack(U)(auto ref U item)
        if (is(U : T))
    {
        static if (is(T == class) || is(T == interface))
        {
            uint len = _length;
            reserve(len + 1);
            _length = len + 1;
            ptr[len] = item;
            return ptr[len];
        }
        else
        {
            uint len = _length;
            reserve(len + 1);
            _length = len + 1;
            emplace!T(&ptr[len], forward!item);
            return ptr[len];
        }
    }

    T popFront()
    {
        // TODO: this should be removed and uses replaced with a queue container
        static if (is(T == class) || is(T == interface))
        {
            T copy = ptr[0];
            for (uint i = 1; i < _length; ++i)
                ptr[i-1] = ptr[i];
            ptr[--_length] = null;
            return copy;
        }
        else
        {
            T copy = ptr[0].move;
            for (uint i = 1; i < _length; ++i)
            {
                ptr[i-1].destroy!false();
                emplace!T(&ptr[i-1], ptr[i].move);
            }
            ptr[--_length].destroy!false();
            return copy.move;
        }
    }

    T popBack()
    {
        static if (is(T == class) || is(T == interface))
        {
            uint last = _length-1;
            T copy = ptr[last];
            ptr[last] = null;
            _length = last;
            return copy;
        }
        else
        {
            uint last = _length-1;
            T copy = ptr[last].move;
            ptr[last].destroy!false();
            _length = last;
            return copy.move;
        }
    }

    void remove(size_t i)
    {
        static if (is(T == class) || is(T == interface))
        {
            for (size_t j = i + 1; j < _length; ++j)
                ptr[j-1] = ptr[j];
            ptr[--_length] = null;
        }
        else
        {
            ptr[i].destroy!false();
            for (size_t j = i + 1; j < _length; ++j)
            {
                emplace!T(&ptr[j-1], ptr[j].move);
                ptr[j].destroy!false();
            }
            --_length;
        }
    }

    void remove(const(T)* pItem)                { remove(ptr[0 .. _length].indexOfElement(pItem)); }
    void removeFirst(ref const T item)          { remove(ptr[0 .. _length].findFirst(item)); }

    void removeSwapLast(size_t i)
    {
        static if (is(T == class) || is(T == interface))
        {
            ptr[i] = ptr[--_length];
            ptr[_length] = null;
        }
        else
        {
            ptr[i].destroy!false();
            emplace!T(&ptr[i], ptr[--_length].move);
            ptr[_length].destroy!false();
        }
    }

    void removeSwapLast(const(T)* pItem)        { removeSwapLast(ptr[0 .. _length].indexOfElement(pItem)); }
    void removeFirstSwapLast(ref const T item)  { removeSwapLast(ptr[0 .. _length].findFirst(item)); }

    inout(T)[] getBuffer() inout
    {
        static if (EmbedCount > 0)
            return hasAllocation() ? ptr[0 .. ec.allocCount] : ec.embed[];
        else
            return hasAllocation() ? ptr[0 .. ec.allocCount] : null;
    }

    bool opCast(T : bool)() const
        => _length != 0;

    size_t opDollar() const
        => _length;

    // full slice: arr[]
    inout(T)[] opIndex() inout
        => ptr[0 .. _length];

    // array indexing: arr[i]
    ref inout(T) opIndex(size_t i) inout
    {
        debug assert(i < _length, "Range error");
        return ptr[i];
    }

    // array slicing: arr[x .. y]
    inout(T)[] opIndex(uint[2] i) inout
        => ptr[i[0] .. i[1]];

    uint[2] opSlice(size_t dim : 0)(size_t x, size_t y)
    {
        debug assert(y <= _length, "Range error");
        return [cast(uint)x, cast(uint)y];
    }

    void opOpAssign(string op : "~", U)(auto ref U el)
        if (is(U : T))
    {
        pushBack(forward!el);
    }

    void opOpAssign(string op : "~", U)(U[] arr)
        if (is(U : T))
    {
        reserve(_length + arr.length);
        foreach (ref e; arr)
            pushBack(e);
    }

    void reserve(size_t count)
    {
        if (count > EmbedCount && count > allocCount())
        {
            debug assert(count <= uint.max, "Exceed maximum size");
            T[] newArray = cast(T[])defaultAllocator().alloc(T.sizeof * count, T.alignof);

            // TODO: POD should memcpy... (including class)

            static if (is(T == class) || is(T == interface))
            {
                for (uint i = 0; i < _length; ++i)
                    newArray.ptr[i] = ptr[i];
            }
            else
            {
                for (uint i = 0; i < _length; ++i)
                {
                    emplace!T(&newArray[i], ptr[i].move);
                    ptr[i].destroy!false();
                }
            }

            if (hasAllocation())
                defaultAllocator().free(ptr[0 .. _length]);

            ec.allocCount = cast(uint)count;
            ptr = newArray.ptr;
        }
    }

    void alloc(size_t count)
    {
        assert(false);
    }

    void resize(size_t count)
    {
        if (count < _length)
        {
            static if (is(T == class) || is(T == interface))
            {
                for (ptrdiff_t i = _length - 1; i >= count; --i)
                    ptr[i] = null;
            }
            else
            {
                for (ptrdiff_t i = _length - 1; i >= count; --i)
                    ptr[i].destroy!false();
            }
            _length = cast(uint)count;
        }
        else
        {
            reserve(count);
            static if (is(T == class) || is(T == interface))
            {
                foreach (i; _length .. count)
                    ptr[i] = null;
            }
            else
            {
                foreach (i; _length .. count)
                    emplace!T(&ptr[i]);
            }
            _length = cast(uint)count;
        }
    }

    void clear()
    {
        static if (!is(T == class) && !is(T == interface))
            for (uint i = 0; i < _length; ++i)
                ptr[i].destroy!false();
        _length = 0;
    }

private:
    union EC
    {
        static if (EmbedCount > 0)
            T[EmbedCount] embed = void;
        uint allocCount;
    }

    T* ptr;
    uint _length;
    EC ec;

    bool hasAllocation() const
    {
        static if (EmbedCount > 0)
            return ptr && ptr != ec.embed.ptr;
        else
            return ptr != null;
    }
    uint allocCount() const
        => hasAllocation() ? ec.allocCount : EmbedCount;

    pragma(inline, true)
    static uint numToAlloc(uint i)
    {
        // TODO: i'm sure we can imagine a better heuristic...
        return i > 16 ? i * 2 : 16;
    }

    auto __debugExpanded() const pure => ptr[0 .. _length];
}


private:

pragma(inline, true)
bool elCmp(T)(const T a, const T b)
    if (is(T == class) || is(T == interface))
{
    return a is b;
}

pragma(inline, true)
bool elCmp(T)(const T a, const T b)
    if (is(T == U[], U))
{
    return a[] == b[];
}

pragma(inline, true)
bool elCmp(T)(auto ref const T a, auto ref const T b)
    if (!is(T == class) && !is(T == interface) && !is(T == U[], U))
{
    return a == b;
}
