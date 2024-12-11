module urt.conv;

import urt.meta;
import urt.string;
public import urt.string.format : toString;

nothrow @nogc:


// on error or not-a-number cases, bytesTaken will contain 0
long parseInt(const(char)[] str, size_t* bytesTaken = null, ulong* fixedPointDivisor = null, int base = 10) pure
{
	assert(base > 1 && base <= 36, "Invalid base");

	static uint getDigit(char c)
	{
		uint zeroBase = c - '0';
		if (zeroBase < 10)
			return zeroBase;
		uint ABase = c - 'A';
		if (ABase < 26)
			return ABase + 10;
		uint aBase = c - 'a';
		if (aBase < 26)
			return aBase + 10;
		return -1;
	}

	size_t i = 0;
	long value = 0;
	ulong divisor = 1;
	bool neg = false;
	bool hasPoint = false;
	bool atLeastOneDigit = false;

	if (str.length == 0)
		goto done;

	neg = str[0] == '-';
	if (neg || str[0] == '+')
	{
		if (str.length < 2 || getDigit(str[1]) >= base)
			goto done;
		i++;
	}

	for (; i < str.length; ++i)
	{
		char c = str[i];

		if (c == '.')
		{
			if (fixedPointDivisor && !hasPoint)
			{
				hasPoint = true;
				continue;
			}
			break;
		}

		uint digit = getDigit(str[i]);
		if (digit >= base)
		{
			// if we have taken at least 1 digit, then we can consider this the end of the string...
			if (!atLeastOneDigit)
			{
				value = 0;
				i = 0;
			}
			break;
		}
		value = value*base + digit;
		atLeastOneDigit = true;
		if (hasPoint)
			divisor *= base;
	}

	done:
	if (bytesTaken)
		*bytesTaken = i;
	if (fixedPointDivisor)
		*fixedPointDivisor = divisor;
	return neg ? -value : value;
}

unittest
{
	size_t taken;
	ulong divisor;
	assert(parseInt("123") == 123);
	assert(parseInt("+123.456") == 123);
	assert(parseInt("-123.456", null, null, 10) == -123);
	assert(parseInt("123.456", null, &divisor, 10) == 123456 && divisor == 1000);
	assert(parseInt("123.456.789", &taken, &divisor, 16) == 1193046 && taken == 7 && divisor == 4096);
	assert(parseInt("11001", null, null, 2) == 25);
	assert(parseInt("-AbCdE.f", null, &divisor, 16) == -11259375 && divisor == 16);
	assert(parseInt("123abc", &taken, null, 10) == 123 && taken == 3);
	assert(parseInt("!!!", &taken, null, 10) == 0 && taken == 0);
	assert(parseInt("-!!!", &taken, null, 10) == 0 && taken == 0);
	assert(parseInt("Wow", &taken, null, 36) == 42368 && taken == 3);
}


// on error or not-a-number, result will be nan and bytesTaken will contain 0
double parseFloat(const(char)[] str, size_t* bytesTaken = null, int base = 10) pure
{
	size_t taken = void;
	ulong div = void;
	long value = str.parseInt(&taken, &div, base);
	if (bytesTaken)
		*bytesTaken = taken;
	if (taken == 0)
		return double.nan;
	return cast(double)value / div;
}

unittest
{
	size_t taken;
	assert(parseFloat("123.456") == 123.456);
	assert(parseFloat("+123.456") == 123.456);
	assert(parseFloat("-123.456.789") == -123.456);
	assert(parseFloat("1101.11", &taken, 2) == 13.75 && taken == 7);
	assert(parseFloat("xyz", &taken) is double.nan && taken == 0);
}


ptrdiff_t formatInt(long value, char[] buffer, uint base = 10, uint width = 0, char fill = ' ', bool showSign = false) pure
{
	import urt.util : isPowerOf2, log2, max;

	assert(base >= 2 && base <= 36, "Invalid base");

	const bool neg = value < 0;
	showSign |= neg;

	long i = neg ? -value : value;

	// HACK: we could special case this one special number...
	assert(i >= 0, "Value can not be long.min");

	char[64] t = void;
	uint numLen = 0;
	// TODO: if this is a hot function, the if's could be hoisted outside the loop.
	//       there are 8 permutations...
	//       also, some platforms might prefer a lookup table than `d < 10 ? ... : ...`
	for (; i != 0; i /= base)
	{
		if (buffer.ptr)
		{
			int d = cast(int)(i % base);
			t.ptr[numLen] = cast(char)((d < 10 ? '0' : 'A' - 10) + d);
		}
		++numLen;
	}
	if (numLen == 0)
	{
		if (buffer.length > 0)
			t.ptr[0] = '0';
		numLen = 1;
	}

	uint len = max(numLen + showSign, width);
	uint padding = width > numLen ? width - numLen - showSign : 0;

	if (buffer.ptr)
	{
		if (buffer.length < len)
			return -1;

		size_t offset = 0;
		if (showSign && fill == '0')
			buffer.ptr[offset++] = neg ? '-' : '+';
		while (padding--)
			buffer.ptr[offset++] = fill;
		if (showSign && fill != '0')
			buffer.ptr[offset++] = neg ? '-' : '+';
		for (uint j = numLen; j > 0; )
			buffer.ptr[offset++] = t[--j];
	}

	return len;
}

unittest
{
	char[64] buffer;
	assert(formatInt(0, null) == 1);
	assert(formatInt(14, null) == 2);
	assert(formatInt(14, null, 16) == 1);
	assert(formatInt(-14, null) == 3);
	assert(formatInt(-14, null, 16) == 2);
	size_t len = formatInt(0, buffer);
	assert(buffer[0 .. len] == "0");
	len = formatInt(14, buffer);
	assert(buffer[0 .. len] == "14");
	len = formatInt(14, buffer, 2);
	assert(buffer[0 .. len] == "1110");
	len = formatInt(14, buffer, 8, 3);
	assert(buffer[0 .. len] == " 16");
	len = formatInt(14, buffer, 16, 4, '0');
	assert(buffer[0 .. len] == "000E");
	len = formatInt(-14, buffer, 16, 3, '0');
	assert(buffer[0 .. len] == "-0E");
	len = formatInt(12345, buffer, 10, 3);
	assert(buffer[0 .. len] == "12345");
	len = formatInt(-123, buffer, 10, 6);
	assert(buffer[0 .. len] == "  -123");
}


ptrdiff_t formatFloat(double value, char[] buffer, const(char)[] format = null) // pure
{
    // TODO: this function should be oblitereated and implemented natively...
    //       CRT call can't CTFE, which is a shame

    import core.stdc.stdio;
    import urt.string.format : concat;

    char[16] fmt = void;
    assert(format.length <= fmt.sizeof - 3, "Format string buffer overflow");

    concat(fmt, "%", format, "g\0");
    int len = snprintf(buffer.ptr, buffer.length, fmt.ptr, value);
    if (len < 0)
        return -2;
    if (buffer.ptr && len >= buffer.length)
        return -1;
    return len;
}



template to(T)
{
    import urt.traits;

    static if (is(T == long))
    {
        long to(const(char)[] str)
        {
            int base = parseBasePrefix(str);
            size_t taken;
            long r = parseInt(str, &taken, null, base);
            assert(taken == str.length, "String is not numeric");
            return r;
        }
    }
    else static if (is(T == double))
    {
        double to(const(char)[] str)
        {
            int base = parseBasePrefix(str);
            size_t taken;
            double r = parseFloat(str, &taken, base);
            assert(taken == str.length, "String is not numeric");
            return r;
        }
    }
    else static if (isSomeInt!T) // call-through for other int types; reduce instantiation bloat
    {
        T to(const(char)[] str)
            => cast(T)to!long(str);
    }
    else static if (isSomeFloat!T) // call-through for other float types; reduce instantiation bloat
    {
        T to(const(char)[] str)
            => cast(T)to!double(str);
    }
    else static if (is(T == struct) || is(T == class))
    {
        // if aggregates have a fromString() function, we can use it to parse the string...
        static assert(is(typeof(&(T.init).fromString) == bool delegate(const(char)[], ulong*) nothrow @nogc), "Aggregate requires 'fromString' member");

        T to(const(char)[] str)
        {
            T r;
            ptrdiff_t taken = r.fromString(str);
            assert(taken == str.length, "Failed to parse string as " ~ T.stringof);
            return r;
        }
    }
    else static if (is(T : const(char)[]))
    {
        import urt.mem.allocator;

        const(char)[] to(ref T, NoGCAllocator allocator = tempAllocator())
        {
            static assert(false, "TODO");
        }
    }
}


private:

int parseBasePrefix(ref const(char)[] str)
{
    int base = 10;
    if (str.length >= 2)
    {
        if (str[0..2] == "0x")
            base = 16, str = str[2..$];
        else if (str[0..2] == "0b")
            base = 2, str = str[2..$];
        else if (str[0..2] == "0o")
            base = 8, str = str[2..$];
    }
    return base;
}


/+
size_t formatStruct(T)(ref T value, char[] buffer) nothrow @nogc
{
	import urt.string.format;

	static assert(is(T == struct), "T must be some struct");

	alias args = value.tupleof;
//	alias args = AliasSeq!(value.tupleof);
//	alias args = InterleaveSeparator!(", ", value.tupleof);
//	pragma(msg, args);
	return concat(buffer, args).length;
}

unittest
{
	import router.iface;

	Packet p;

	char[1024] buffer;
	size_t len = formatStruct(p, buffer);
	assert(buffer[0 .. len] == "Packet()");

}
+/
