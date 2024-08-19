module urt.conv;

import urt.string;

// on error or not-a-number cases, bytesTaken will contain 0
long parseInt(const(char)[] str, size_t* bytesTaken = null, ulong* fixedPointDivisor = null, int base = 10)
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
			// i guess we should error if we encounter a digit out-of-base???
			value = 0;
			i = 0;
			break;
		}
		value = value*base + digit;
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
	assert(parseInt("123.456", null, &divisor, 10) == 123456);
	assert(divisor == 1000);
	assert(parseInt("123.456.789", &taken, &divisor, 16) == 1193046);
	assert(taken == 7);
	assert(divisor == 4096);
	assert(parseInt("11001", null, null, 2) == 25);
	assert(parseInt("-AbCdE.f", null, &divisor, 16) == -11259375);
	assert(divisor == 16);
	assert(parseInt("123abc", &taken, null, 10) == 0);
	assert(taken == 0);
	assert(parseInt("!!!", &taken, null, 10) == 0);
	assert(taken == 0);
	assert(parseInt("-!!!", &taken, null, 10) == 0);
	assert(taken == 0);
	assert(parseInt("Wow", &taken, null, 36) == 42368);
	assert(taken == 3);
}


// on error or not-a-number, result will be nan and bytesTaken will contain 0
double parseFloat(const(char)[] str, size_t* bytesTaken = null, int base = 10)
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
	assert(parseFloat("1101.11", &taken, 2) == 13.75);
	assert(taken == 7);
	assert(parseFloat("xyz", &taken) is double.nan);
	assert(taken == 0);
}
