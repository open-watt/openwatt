module urt.util;

import urt.traits;


nothrow @nogc:

ref T swap(T)(ref T a, return ref T b)
{
    import urt.lifetime : move, moveEmplace;

    T t = a.move;
    b.move(a);
    t.move(b);
    return b;
}

T swap(T)(ref T a, T b)
{
    import urt.lifetime : move, moveEmplace;

    auto t = a.move;
    b.move(a);
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

T alignDown(size_t alignment, T)(T value)
    if (isSomeInt!T || is(T == U*, U))
{
    return cast(T)(cast(size_t)value & ~(alignment - 1));
}

T alignDown(T)(T value, size_t alignment)
	if (isSomeInt!T || is(T == U*, U))
{
	return cast(T)(cast(size_t)value & ~(alignment - 1));
}

T alignUp(size_t alignment, T)(T value)
    if (isSomeInt!T || is(T == U*, U))
{
    return cast(T)((cast(size_t)value + (alignment - 1)) & ~(alignment - 1));
}

T alignUp(T)(T value, size_t alignment)
	if (isSomeInt!T || is(T == U*, U))
{
	return cast(T)((cast(size_t)value + (alignment - 1)) & ~(alignment - 1));
}

bool isAligned(size_t alignment, T)(T value)
    if (isSomeInt!T || is(T == U*, U))
{
    static assert(T.sizeof > size_t.sizeof, "TODO");
    return (cast(size_t)value & (alignment - 1)) == 0;
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
	static if (T.sizeof > 4)
		if (x >= 1UL<<32)			{ x >>= 32; result += 32; }
	static if (T.sizeof > 2)
		if (x >= 1<<16)				{ x >>= 16; result += 16; }
	static if (T.sizeof > 1)
		if (x >= 1<<8)				{ x >>= 8;  result += 8; }
	if (x >= 1<<4)					{ x >>= 4;  result += 4; }
	if (x >= 1<<2)					{ x >>= 2;  result += 2; }
	if (x >= 1<<1)					{           result += 1; }
	return result;

/+
    // TODO: this might be better on systems with no branch predictor...
    Unsigned!(Unqual!T) v = x;
    ubyte shift;
    ubyte r;

    r =     (v > 0xFFFF) << 4; v >>= r;
    shift = (v > 0xFF  ) << 3; v >>= shift; r |= shift;
    shift = (v > 0xF   ) << 2; v >>= shift; r |= shift;
    shift = (v > 0x3   ) << 1; v >>= shift; r |= shift;
    r |= (v >> 1);
+/
}

ubyte clz(T)(T x)
    if (isSomeInt!T)
{
    static if (T.sizeof == 1)
        return x ? cast(ubyte)(7 - log2(cast(ubyte)x)) : 8;
    static if (T.sizeof == 2)
        return x ? cast(ubyte)(15 - log2(cast(ushort)x)) : 16;
    static if (T.sizeof == 4)
        return x ? cast(ubyte)(31 - log2(cast(uint)x)) : 32;
    static if (T.sizeof == 8)
        return x ? cast(ubyte)(63 - log2(cast(ulong)x)) : 64;
}

ubyte ctz(T)(T x)
    if (isSomeInt!T)
{
    Unsigned!(Unqual!T) t = x;

    // special case for odd v (assumed to happen ~half of the time)
    if (t <= 0x1)
        return t ? 0 : T.sizeof*8;

    ubyte result = 1;
    static if (T.sizeof > 4)
    {
        if ((t & 0xffffffff) == 0) 
        {  
            t >>= 32;  
            result += 32;
        }
    }
    static if (T.sizeof > 2)
    {
        if ((t & 0xffff) == 0) 
        {  
            t >>= 16;  
            result += 16;
        }
    }
    static if (T.sizeof > 1)
    {
        if ((t & 0xff) == 0) 
        {  
            t >>= 8;  
            result += 8;
        }
    }
    if ((t & 0xf) == 0) 
    {  
        t >>= 4;
        result += 4;
    }
    if ((t & 0x3) == 0) 
    {  
        t >>= 2;
        result += 2;
    }
    result -= t & 0x1;
    return result;
}

ubyte clo(T)(T x)
    => clz(~x);
ubyte cto(T)(T x)
    => ctz(~x);

ubyte popcnt(T)(T x)
    if (isSomeInt!T)
{
    enum fives = cast(Unsigned!T)-1/3;      // 0x5555...
    enum threes = cast(Unsigned!T)-1/15*3;  // 0x3333...
    enum effs = cast(Unsigned!T)-1/255*15;  // 0x0F0F...
    enum ones = cast(Unsigned!T)-1/255;     // 0x0101...

    auto t = x - ((x >>> 1) & fives);
    t = (t & threes) + ((t >>> 2) & threes);
    t = ((t + (t >>> 4)) & effs) * ones;
    return cast(ubyte)(t >>> (T.sizeof - 1)*8);
}

unittest
{
    assert(isPowerOf2(0) == true);
    assert(isPowerOf2(1) == true);
    assert(isPowerOf2(2) == true);
    assert(isPowerOf2(3) == false);
    assert(isPowerOf2(4) == true);
    assert(isPowerOf2(5) == false);

    assert(nextPowerOf2(0) == 0);
    assert(nextPowerOf2(1) == 1);
    assert(nextPowerOf2(2) == 2);
    assert(nextPowerOf2(3) == 4);
    assert(nextPowerOf2(4) == 4);
    assert(nextPowerOf2(5) == 8);

    assert(log2(ubyte(0)) == 0);
    assert(log2(ubyte(1)) == 0);
    assert(log2(ubyte(2)) == 1);
    assert(log2(ubyte(3)) == 1);
    assert(log2(ubyte(4)) == 2);
    assert(log2(ubyte(5)) == 2);
    assert(log2(ubyte(127)) == 6);
    assert(log2(ubyte(128)) == 7);
    assert(log2(ubyte(255)) == 7);

    assert(clz(ubyte(0)) == 8);
    assert(clz(ubyte(1)) == 7);
    assert(clz(ubyte(2)) == 6);
    assert(clz(ubyte(3)) == 6);
    assert(clz(ubyte(4)) == 5);
    assert(clz(ubyte(5)) == 5);
    assert(clz(uint(0)) == 32);
    assert(clz(uint(17)) == 27);
    assert(clz(uint.max) == 0);

    assert(ctz(ubyte(0)) == 8);
    assert(ctz(ubyte(1)) == 0);
    assert(ctz(ubyte(2)) == 1);
    assert(ctz(ubyte(3)) == 0);
    assert(ctz(ubyte(4)) == 2);
    assert(ctz(ubyte(5)) == 0);
    assert(ctz(ubyte(128)) == 7);
    assert(ctz(uint(0)) == 32);
    assert(ctz(uint(48)) == 4);

    assert(popcnt(ubyte(0)) == 0);
    assert(popcnt(ubyte(1)) == 1);
    assert(popcnt(ubyte(2)) == 1);
    assert(popcnt(ubyte(3)) == 2);
    assert(popcnt(ubyte(4)) == 1);
    assert(popcnt(ubyte(5)) == 2);
    assert(popcnt(byte.max) == 7);
    assert(popcnt(byte(-1)) == 8);
    assert(popcnt(int(0)) == 0);
    assert(popcnt(uint.max) == 32);
    assert(popcnt(ulong(0)) == 0);
    assert(popcnt(ulong.max) == 64);
    assert(popcnt(long.min) == 1);
}


enum Default = DefaultInit.init;

struct InPlace(C)
	if (is(C == class))
{
	import core.lifetime;

	alias value this;
	inout(C) value() inout pure nothrow @nogc => cast(inout(C))instance.ptr;

	this() @disable;

	this()(DefaultInit)
	{
		value.emplace();
	}

	this(Args...)(auto ref Args args)
	{
		value.emplace(forward!args);
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
