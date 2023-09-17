module sampledb.selfrefptr;

struct SelfRefPtr(T)
{
	void opAssign(U)(SelfRefPtr!U ptr) pure nothrow @nogc @trusted
		if (is(U*  : T*))
	{
		__offset = ptr.offset;
	}

	void opAssign(T* ptr) pure nothrow @nogc @trusted
	{
		__offset = cast(ubyte*) ptr - cast(ubyte*)&this;
	}

	T* opUnary(string op : "*")() const pure nothrow @nogc @trusted
	{
		return __ptr();
	}

	alias __ptr this;

private:
	ptrdiff_t __offset;
	pragma(inline, true) T* __ptr() const pure nothrow @nogc @trusted
	{
		return cast(T*)(cast(ubyte*)&this + __offset);
	}
}
