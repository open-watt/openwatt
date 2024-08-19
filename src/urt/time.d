module urt.time;

import urt.traits : isSomeFloat;


nothrow @nogc:

struct MonoTime
{
nothrow @nogc:

	ulong ticks;

	bool opEquals(MonoTime b) const pure
		=> ticks == b.ticks;

	int opCmp(MonoTime b) const pure
		=> ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

	Duration opBinary(string op)(MonoTime rhs) const pure if (op == "-")
		=> Duration(ticks - rhs.ticks);

	Duration opBinary(string op)(Duration rhs) const pure if (op == "+" || op == "-")
		=> MonoTime(mixin("ticks " ~ op ~ " rhs.ticks"));

	MonoTime opBinary(string op)(Duration rhs) const pure if (op == "+" || op == "-")
		=> MonoTime(mixin("ticks " ~ op ~ " rhs.ticks"));

	void opOpAssign(string op)(Duration rhs) pure if (op == "+" || op == "-")
		=> mixin("ticks " ~ op ~ "= rhs.ticks;");

	import urt.string.format : FormatArg;
	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
	{
		size_t len = timeToString(appTime(this).as!"msecs", buffer.length > 2 ? buffer[2..$] : buffer);
		if (len)
		{
			if (buffer.length > 2)
				buffer[0 .. 2] = "T+";
			return len + 2;
		}
		return 0;
	}
}

struct Duration
{
pure nothrow @nogc:

	long ticks;

	enum Duration zero = Duration(0);
	enum Duration max = Duration(long.max);
	enum Duration min = Duration(long.min);

	bool opCast(T)() const if (is(T == bool))
		=> ticks != 0;

	bool opCast(T)() const if (isSomeFloat!T)
		=> cast(T)ticks / cast(T)ticksPerSecond;

	bool opEquals(Duration b) const
		=> ticks == b.ticks;

	int opCmp(Duration b) const
		=> ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

	Duration opUnary(string op)() const if (op == "-")
		=> Duration(-ticks);

	Duration opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
		=> Duration(mixin("ticks " ~ op ~ " rhs.ticks"));

	void opOpAssign(string op)(Duration rhs)
		if (op == "+" || op == "-")
	{
		mixin("ticks " ~ op ~ "= rhs.ticks;");
	}

	long as(string base)() const
	{
		static if (base == "nsecs")
			return ticks*nsecMultiplier;
		else static if (base == "usecs")
			return ticks*nsecMultiplier / 1_000;
		else static if (base == "msecs")
			return ticks*nsecMultiplier / 1_000_000;
		else static if (base == "seconds")
			return ticks*nsecMultiplier / 1_000_000_000;
		else static if (base == "minutes")
			return ticks*nsecMultiplier / 60_000_000_000;
		else static if (base == "hours")
			return ticks*nsecMultiplier / 3_600_000_000_000;
		else static if (base == "days")
			return ticks*nsecMultiplier / 86_400_000_000_000;
		else static if (base == "weeks")
			return ticks*nsecMultiplier / 604_800_000_000_000;
		else
			static assert(false, "Invalid base");
	}

	import urt.string.format : FormatArg;
	ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
	{
		return timeToString(as!"msecs", buffer);
	}
}

Duration dur(string base)(long value)
{
	static if (base == "nsecs")
		return Duration(value / nsecMultiplier);
	else static if (base == "usecs")
		return Duration(value*1_000 / nsecMultiplier);
	else static if (base == "msecs")
		return Duration(value*1_000_000 / nsecMultiplier);
	else static if (base == "seconds")
		return Duration(value*1_000_000_000 / nsecMultiplier);
	else static if (base == "minutes")
		return Duration(value*60_000_000_000 / nsecMultiplier);
	else static if (base == "hours")
		return Duration(value*3_600_000_000_000 / nsecMultiplier);
	else static if (base == "days")
		return Duration(value*86_400_000_000_000 / nsecMultiplier);
	else static if (base == "weeks")
		return Duration(value*604_800_000_000_000 / nsecMultiplier);
	else
		static assert(false, "Invalid base");
}

Duration nsecs(long value) pure => dur!"msecs"(value);
Duration usecs(long value) pure => dur!"usecs"(value);
Duration msecs(long value) pure => dur!"msecs"(value);
Duration seconds(long value) pure => dur!"seconds"(value);

MonoTime getTime()
{
	version (Windows)
	{
		import core.sys.windows.windows;

		LARGE_INTEGER now;
		QueryPerformanceCounter(&now);
		return MonoTime(now.QuadPart);
	}
	else
	{
		static assert(false, "TODO");
	}
}

Duration getAppTime()
{
	return getTime() - bootTime;
}

Duration appTime(MonoTime t)
{
	return t - bootTime;
}

Duration abs(Duration d) pure
{
	return Duration(d.ticks < 0 ? -d.ticks : d.ticks);
}

long toNanoseconds(Duration dur) pure
{
	return dur.ticks *= nsecMultiplier;
}

private:

immutable uint ticksPerSecond;
immutable uint nsecMultiplier;
immutable MonoTime bootTime;

package(urt) void initClock()
{
	cast()bootTime = getTime();

	version (Windows)
	{
		import core.sys.windows.windows;

		LARGE_INTEGER freq;
		QueryPerformanceFrequency(&freq);
		cast()ticksPerSecond = cast(uint)freq.QuadPart;
		cast()nsecMultiplier = 1_000_000_000 / ticksPerSecond;
	}
	else
	{
		static assert(false, "TODO");
	}
}

ptrdiff_t timeToString(long ms, char[] buffer) pure
{
	import urt.conv : formatInt;

	long hr = ms / 3_600_000;

	if (!buffer.ptr)
		return hr.formatInt(null, 10, 2, '0') + 10;

	size_t len = hr.formatInt(buffer, 10, 2, '0');
	if (len == 0 || buffer.length < len + 10)
		return 0;

	ubyte min = cast(ubyte)(ms / 60_000 % 60);
	ubyte sec = cast(ubyte)(ms / 1000 % 60);
	ms %= 1000;

	buffer.ptr[len++] = ':';
	buffer.ptr[len++] = cast(char)('0' + (min / 10));
	buffer.ptr[len++] = cast(char)('0' + (min % 10));
	buffer.ptr[len++] = ':';
	buffer.ptr[len++] = cast(char)('0' + (sec / 10));
	buffer.ptr[len++] = cast(char)('0' + (sec % 10));
	buffer.ptr[len++] = '.';
	buffer.ptr[len++] = cast(char)('0' + (ms / 100));
	buffer.ptr[len++] = cast(char)('0' + ((ms/10) % 10));
	buffer.ptr[len++] = cast(char)('0' + (ms % 10));
	return len;
}

unittest
{
	import urt.mem.temp;

	assert(tconcat(msecs(3_600_000*3 + 60_000*47 + 1000*34 + 123))[] == "03:47:34.123");
	assert(tconcat(msecs(3_600_000*-123))[] == "-123:00:00.000");

	assert(MonoTime().toString(null, null, null) == 14);
	assert(tconcat(getTime())[0..2] == "T+");
}
