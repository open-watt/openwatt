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

ptrdiff_t indexOfElement(T, U)(const(T)[] arr, const(U)* el)
{
    if (el < arr.ptr || el >= arr.ptr + arr.length)
        return -1;
    return el - arr.ptr;
}

inout(T)* search(T)(inout(T)[] arr, bool function(ref const T) nothrow @nogc pred)
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
    this(typeof(null)) {}
//    this(Alloc_T, size_t count);
//    this(Reserve_T, size_t count);
//    this(Items...)(Concat_T, auto ref Items items);
//    this(ref inout Array!(T, EmbedCount) val) inout;
//    this(Array!(T, EmbedCount) rval);

    // TODO: Array copy/move constructors for const promotion?
//    this(U)(U *ptr, size_t length);

    this(U)(U[] arr)
        if (is(U : T))
    {
        reserve(arr.length);
        foreach (ref e; arr)
            pushBack(e);
    }

//    this(U, size_t N)(ref U[N] arr);
    ~this()
    {
        if (hasAllocation())
            defaultAllocator().freeArray(array);
        else static if (!is(T == class))
            foreach (ref e; array)
                e.destroy!false();
    }

nothrow @nogc:

    // assignment
//    ref inout(Array!(T, EmbedCount)) opAssign(ref inout Array!(T, EmbedCount) rh) inout;
//    ref Array!(T, EmbedCount) opAssign(Array!(T, EmbedCount) rval);
//    ref Array!(T, EmbedCount) opAssign(U)(U[] rh);

    void opAssign(U)(U[] rh)
        if (is(U : T))
    {
        clear();
        reserve(rh.length);
        foreach (ref e; rh)
            pushBack(e);
    }

    // manipulation
    ref Array!(T, Count) concat(Things...)(auto ref Things things);

    bool empty() const
        => array.length == 0;
    size_t length() const
        => array.length;

    ref inout(T) front() inout
        => array[0];
    ref inout(T) back() inout
        => array[$ - 1];

    ref T pushFront()
        => pushFront(T.init);
    ref T pushBack()
        => pushBack(T.init);

    ref T pushFront(T item)
    {
        static if (is(T == class))
        {
            size_t len = array.length;
            reserve(len + 1);
            array = array.ptr[0 .. len + 1];
            for (size_t i = len; i > 0; --i)
                array[i] = array[i-1];
            array[0] = item;
            return array[0];
        }
        else
        {
            size_t len = array.length;
            reserve(len + 1);
            array = array.ptr[0 .. len + 1];
            for (size_t i = len; i > 0; --i)
            {
                emplace!T(&array.ptr[i], array.ptr[i-1].move);
                array.ptr[i-1].destroy!false();
            }
            emplace!T(&array.ptr[0], item.move);
            return array[0];
        }
    }

    ref T pushBack(T item)
    {
        static if (is(T == class))
        {
            size_t len = array.length;
            reserve(len + 1);
            array = array.ptr[0 .. len + 1];
            array[len] = item;
            return array[len];
        }
        else
        {
            size_t len = array.length;
            reserve(len + 1);
            array = array.ptr[0 .. len + 1];
            emplace!T(&array.ptr[len], item.move);
            return array[len];
        }
    }

    T popFront()
    {
        // TODO: this should be removed and uses replaced with a queue container
        static if (is(T == class))
        {
            T copy = array.ptr[0];
            for (size_t i = 1; i < array.length; ++i)
                array.ptr[i-1] = array.ptr[i];
            array.ptr[array.length-1] = null;
            array = array.ptr[0 .. array.length-1];
            return copy;
        }
        else
        {
            T copy = T(array.ptr[0].move);
            for (size_t i = 1; i < array.length; ++i)
            {
                array.ptr[i-1].destroy!false();
                emplace!T(&array.ptr[i-1], array.ptr[i].move);
            }
            array.ptr[array.length-1].destroy!false();
            array = array.ptr[0 .. array.length-1];
            return copy.move;
        }
    }

    T popBack()
    {
        static if (is(T == class))
        {
            size_t last = array.length-1;
            T copy = array.ptr[last];
            array.ptr[last] = null;
            array = array.ptr[0 .. last];
            return copy;
        }
        else
        {
            size_t last = array.length-1;
            T copy = T(array.ptr[last].move);
            array.ptr[last].destroy!false();
            array = array.ptr[0 .. last];
            return copy.move;
        }
    }

    void remove(size_t i)
    {
        assert(false);
    }

    void remove(const(T)* pItem)                { remove(array.indexOfElement(pItem)); }
    void removeFirst(ref const T item)          { remove(array.findFirst(item)); }

    void removeSwapLast(size_t i)
    {
        assert(false);
    }

    void removeSwapLast(const(T)* pItem)        { removeSwapLast(array.indexOfElement(pItem)); }
    void removeFirstSwapLast(ref const T item)  { removeSwapLast(array.findFirst(item)); }

    inout(T)[] getBuffer() inout
        => hasAllocation() ? array.ptr[0 .. ec.allocCount] : EmbedCount ? ec.embed[] : null;

    bool opCast(T : bool)() const
        => array.length != 0;

    size_t opDollar() const
        => array.length;

    // full slice: arr[]
    inout(T)[] opIndex() inout
        => array[];

    // array indexing: arr[i]
    ref inout(T) opIndex(size_t i) inout
        => array[i];

    // array slicing: arr[a .. b]
    inout(T)[] opIndex(size_t[2] i) inout
        => array[i[0] .. i[1]];

    size_t[2] opSlice(size_t dim : 0)(size_t a, size_t b)
        => [a, b];

    void opOpAssign(string op : "~", U)(ref U el)
        if (is(U : T))
    {
        pushBack(el);
    }
    void opOpAssign(string op : "~", U)(U[] arr)
        if (is(U : T))
    {
        reserve(array.length + arr.length);
        foreach (ref e; arr)
            pushBack(e);
    }

    void reserve(size_t count)
    {
        if (count > EmbedCount && count > allocCount())
        {
            T[] newArray = cast(T[])defaultAllocator().alloc(T.sizeof * count, T.alignof);

            // TODO: POD should memcpy... (including class)

            static if (is(T == class))
            {
                for (size_t i = 0; i < array.length; ++i)
                    newArray.ptr[i] = array.ptr[i];
            }
            else
            {
                for (size_t i = 0; i < array.length; ++i)
                {
                    emplace!T(&newArray[i], array[i].move);
                    array[i].destroy!false();
                }
            }

            if (hasAllocation())
                defaultAllocator().free(array);

            ec.allocCount = count;
            array = newArray.ptr[0 .. array.length];
        }
    }

    void alloc(size_t count)
    {
        assert(false);
    }

    void resize(size_t count)
    {
        assert(false);
    }

    void clear()
    {
        static if (!is(T == class))
            for (size_t i = 0; i < array.length; ++i)
                array[i].destroy!false();
        array = array[0..0];
    }

private:
    T[] array;

    union EC
    {
        T[EmbedCount] embed = void;
        size_t allocCount;
    }
    EC ec;

    bool hasAllocation() const
        => array.ptr && (EmbedCount == 0 || array.ptr != ec.embed.ptr);
    size_t allocCount() const
        => hasAllocation() ? ec.allocCount : EmbedCount;

    pragma(inline, true)
    static size_t numToAlloc(size_t i)
    {
        // TODO: i'm sure we can imagine a better heuristic...
        return i > 16 ? i * 2 : 16;
    }

    auto __debugExpanded() const pure => this[];
}


private:

pragma(inline, true)
bool elCmp(T)(const T a, const T b)
    if (is(T == class))
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
    if (!is(T == class) && !is(T == U[], U))
{
    return a == b;
}
