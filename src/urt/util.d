module urt.util;

import urt.traits;


nothrow @nogc:

ref T swap(T)(ref T a, return ref T b)
{
	import core.lifetime : move;

	auto t = a.move;
	a = b.move;
	b = t.move;
	return b;
}

T swap(T)(ref T a, T b)
{
	import core.lifetime : move;

	auto t = a.move;
	a = b.move;
	return t.move;
}

pure:

auto min(T, U)(auto ref inout T a, auto ref inout U b)
{
	return a < b ? a : b;
}

auto max(T, U)(auto ref inout T a, auto ref inout U b)
{
	return a > b ? a : b;
}

template Align(size_t value, size_t alignment = size_t.sizeof)
{
	static assert(isPowerOf2(alignment), "Alignment must be a power of two: ", alignment);
	enum Align = alignTo(value, alignment);
}

enum IsAligned(size_t value) = isAligned(value);
enum IsPowerOf2(size_t value) = isPowerOf2(value);
enum NextPowerOf2(size_t value) = nextPowerOf2(value);


bool isPowerOf2(T)(T x)
	if (isSomeInt!T)
{
	return (x & (x - 1)) == 0;
}

T nextPowerOf2(T)(T x)
	if (isSomeInt!T)
{
	x -= 1;
	x |= x >> 1;
	x |= x >> 2;
	x |= x >> 4;
	static if (T.sizeof >= 2)
		x |= x >> 8;
	static if (T.sizeof >= 4)
		x |= x >> 16;
	static if (T.sizeof >= 8)
		x |= x >> 32;
	return cast(T)(x + 1);
}

T alignDown(T)(T value, size_t alignment)
	if (isSomeInt!T || is(T == U*, U))
{
	return cast(T)(cast(size_t)value & ~(alignment - 1));
}

T alignUp(T)(T value, size_t alignment)
	if (isSomeInt!T || is(T == U*, U))
{
	return cast(T)((cast(size_t)value + (alignment - 1)) & ~(alignment - 1));
}

bool isAligned(T)(T value, size_t alignment)
	if (isSomeInt!T || is(T == U*, U))
{
	static assert(T.sizeof > size_t.sizeof, "TODO");
	return (cast(size_t)value & (alignment - 1)) == 0;
}

/+
ubyte log2(ubyte val)
{
	if (val >> 4)
	{
		if (val >> 6)
			if (val >> 7)
				return 7;
			else
				return 6;
		else
			if (val >> 5)
				return 5;
			else
				return 4;
	}
	else
	{
		if (val >> 2)
			if (val >> 3)
				return 3;
			else
				return 2;
		else
			if (val >> 1)
				return 1;
			else
				return 0;
	}
}

ubyte log2(T)(T val)
	if (isSomeInt!T && T.sizeof > 1)
{
	if (T.sizeof > 4 && val >> 32)
	{
		if (val >> 48)
			if (val >> 56)
				return 56 + log2(cast(ubyte)(val >> 56));
			else
				return 48 + log2(cast(ubyte)(val >> 48));
		else
			if (val >> 40)
				return 40 + log2(cast(ubyte)(val >> 40));
			else
				return 32 + log2(cast(ubyte)(val >> 32));
	}
	else
	{
		if (T.sizeof > 2 && val >> 16)
			if (val >> 24)
				return 24 + log2(cast(ubyte)(val >> 24));
			else
				return 16 + log2(cast(ubyte)(val >> 16));
		else
			if (val >> 8)
				return 8 + log2(cast(ubyte)(val >> 8));
			else
				return log2(cast(ubyte)val);
	}
}
+/

ubyte log2(T)(T x)
	if (isSomeInt!T)
{
	ubyte result = 0;
	if (T.sizeof > 4 && x >= 1<<32) { x >>= 32; result += 32; }
	if (T.sizeof > 2 && x >= 1<<16) { x >>= 16; result += 16; }
	if (T.sizeof > 1 && x >= 1<<8)  { x >>= 8;  result += 8; }
	if (x >= 1<<4)					{ x >>= 4;  result += 4; }
	if (x >= 1<<2)					{ x >>= 2;  result += 2; }
	if (x >= 1<<1)					{           result += 1; }
	return result;
}


enum Default = DefaultInit.init;

struct Value(C)
	if (is(C == class))
{
	import core.lifetime;

	alias value this;
	inout(C) value() inout pure nothrow @nogc => cast(inout(C))instance.ptr;

	this() @disable;

	this(DefaultInit)
	{
		value.emplace();
	}

	this(Args...)(auto ref Args args)
	{
		value.emplace(args.forward);
	}

	~this()
	{
		value.destroy();
	}

private:
	align(__traits(classInstanceAlignment, C))
	ubyte[__traits(classInstanceSize, C)] instance;
}


private:

enum DefaultInit { def }

unittest
{
	int x = 10, y = 20;
	assert(x.swap(y) == 10);
	assert(x.swap(30) == 20);
}
