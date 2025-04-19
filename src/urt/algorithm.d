module urt.algorithm;

import urt.traits : lvalueOf;
import urt.util : swap;

version = SmallSize;

nothrow @nogc:


auto compare(T, U)(auto ref T a, auto ref U b)
{
    static if (__traits(compiles, lvalueOf!T.opCmp(lvalueOf!U)))
        return a.opCmp(b);
    else static if (__traits(compiles, lvalueOf!U.opCmp(lvalueOf!T)))
        return -b.opCmp(a);
    else static if (is(T : A[], A))
    {
        import urt.traits : isPrimitive;

        auto ai = a.ptr;
        auto bi = b.ptr;
        size_t len = a.length < b.length ? a.length : b.length;
        static if (isPrimitive!A)
        {
            // compare strings
            foreach (i; 0 .. len)
            {
                if (ai[i] != bi[i])
                    return ai[i] < bi[i] ? -1 : 1;
            }
        }
        else
        {
            // compare arrays
            foreach (i; 0 .. len)
            {
                auto cmp = compare(ai[i], bi[i]);
                if (cmp != 0)
                    return cmp;
            }
        }
        if (a.length == b.length)
            return 0;
        return a.length < b.length ? -1 : 1;
    }
    else
        return a < b ? -1 : (a > b ? 1 : 0);
}

size_t binarySearch(alias pred = void, T, Cmp...)(T[] arr, auto ref Cmp cmpArgs)
{
    T* p = arr.ptr;
    size_t low = 0;
    size_t high = arr.length;
    while (low < high)
    {
        size_t mid = low + (high - low) / 2;
        static if (is(pred == void))
        {
            // should we chase the first in a sequence of same values?
            if (p[mid] < cmpArgs[0])
                low = mid + 1;
            else
                high = mid;
        }
        else
        {
            // should we chase the first in a sequence of same values?
            int cmp = pred(p[mid], cmpArgs);
            if (cmp < 0)
                low = mid + 1;
            else
                high = mid;
        }
    }
    static if (is(pred == void))
    {
        if (p[low] == cmpArgs[0])
            return low;
    }
    else
    {
        if (pred(p[low], cmpArgs) == 0)
            return low;
    }
    return arr.length;
}


void qsort(alias pred = void, T)(T[] arr)
{
    version (SmallSize)
    {
        static if (is(pred == void))
            static if (__traits(compiles, lvalueOf!T.opCmp(lvalueOf!T)))
                static int compare(const void* a, const void* b) nothrow @nogc
                    => (*cast(const T*)a).opCmp(*cast(const T*)b);
            else
                static int compare(const void* a, const void* b) nothrow @nogc
                    => *cast(const T*)a < *cast(const T*)b ? -1 : *cast(const T*)a > *cast(const T*)b ? 1 : 0;
        else
            static int compare(const void* a, const void* b) nothrow @nogc
                => pred(*cast(T*)a, *cast(T*)b);

        qsort(arr[], T.sizeof, &compare, (void* a, void* b) nothrow @nogc {
                  swap(*cast(T*)a, *cast(T*)b);
              });
    }
    else
    {
        T* p = arr.ptr;
        if (arr.length > 1)
        {
            size_t pivotIndex = arr.length / 2;
            T* pivot = &p[pivotIndex];

            size_t i = 0;
            size_t j = arr.length - 1;

            while (i <= j)
            {
                static if (is(pred == void))
                {
                    while (p[i] < *pivot) i++;
                    while (p[j] > *pivot) j--;
                }
                else
                {
                    while (pred(*cast(T*)&p[i], *cast(T*)pivot) < 0) i++;
                    while (pred(*cast(T*)&p[j], *cast(T*)pivot) > 0) j--;
                }
                if (i <= j)
                {
                    swap(p[i], p[j]);
                    i++;
                    j--;
                }
            }

            if (j > 0)
                qsort(p[0 .. j + 1]);
            if (i < arr.length)
                qsort(p[i .. arr.length]);
        }
    }
}

unittest
{
    struct S
    {
        int x;
        int opCmp(ref const S rh) const nothrow @nogc
            => x < rh.x ? -1 : x > rh.x ? 1 : 0;
    }

    int[5] arr = [3, 100, -1, 17, 30];
    qsort(arr);
    assert(arr == [-1, 3, 17, 30, 100]);

    S[5] arr2 = [ S(3), S(100), S(-1), S(17), S(30)];
    qsort(arr2);
    foreach (i, ref s; arr2)
        assert(s.x == arr[i]);

    // test binary search, not that they're sorted...
    assert(binarySearch(arr, -1) == 0);
    assert(binarySearch!(s => s.x < 30 ? -1 : s.x > 30 ? 1 : 0)(arr2) == 3);
    assert(binarySearch(arr, 0) == arr.length);

    int[10] rep = [1, 10, 10, 10, 10, 10, 10, 10, 10, 100];
    assert(binarySearch(rep, 10) == 1);
}


private:

version (SmallSize)
{
    // just one generic implementation to minimise the code...
    // kinda slow though... look at all those multiplies!
    // maybe there's some way to make this faster :/
    void qsort(void[] arr, size_t elementSize, int function(const void* a, const void* b) nothrow @nogc compare, void function(void* a, void* b) nothrow @nogc swap)
    {
        void* p = arr.ptr;
        size_t length = arr.length / elementSize;
        if (length > 1)
        {
            size_t pivotIndex = length / 2;
            void* pivot = p + pivotIndex*elementSize;

            size_t i = 0;
            size_t j = length - 1;

            while (i <= j)
            {
                while (compare(p + i*elementSize, pivot) < 0) i++;
                while (compare(p + j*elementSize, pivot) > 0) j--;
                if (i <= j)
                {
                    swap(p + i*elementSize, p + j*elementSize);
                    i++;
                    j--;
                }
            }

            if (j > 0)
                qsort(p[0 .. (j + 1)*elementSize], elementSize, compare, swap);
            if (i < length)
                qsort(p[i*elementSize .. length*elementSize], elementSize, compare, swap);
        }
    }
}
