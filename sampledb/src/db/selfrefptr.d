module db.selfrefptr;

// TODO: oh no fail! dlang can't do this because you can't correct the pointer's base on move operations!

struct SelfRefPtr(T)
{
    this(T* ptr)
	{
        __offset = cast(ubyte*)ptr - cast(ubyte*)&this;
	}

    void opAssign(T* ptr) pure nothrow @nogc @trusted
	{
        __offset = cast(ubyte*)ptr - cast(ubyte*)&this;
	}

    ref inout(T) opUnary(string op : "*")() inout pure nothrow @nogc @trusted
	{
        return *__ptr();
	}

    alias __ptr this;

private:
    ptrdiff_t __offset = 0;
    pragma(inline, true) inout(T)* __ptr() inout pure nothrow @nogc @trusted { return cast(inout(T)*)(cast(inout(ubyte)*)&this + __offset); }
}

struct SelfRefSlice(T)
{
    alias ptr = __ptr;
	size_t length;

    alias __slice this;

private:
    pragma(inline, true) inout(T)[] __slice() inout pure nothrow @nogc @trusted { return __ptr[length]; }
}
