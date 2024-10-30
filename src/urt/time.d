module urt.time;

import urt.traits : isSomeFloat;

version (Windows)
{
    import core.sys.windows.windows;
    extern (C) void GetSystemTimePreciseAsFileTime(FILETIME* lpSystemTimeAsFileTime) nothrow @nogc;
}

nothrow @nogc:


enum Clock
{
    SystemTime,
    Monotonic,
}

alias MonoTime = Time!(Clock.Monotonic);
alias SysTime = Time!(Clock.SystemTime);

struct Time(Clock clock)
{
nothrow @nogc:

    ulong ticks;

    bool opCast(T : bool)() const
        => ticks != 0;

    T opCast(T)() const
        if (is(T == Time!c, Clock c) && c != clock)
    {
        static if (clock == Clock.Monotonic && c == Clock.SystemTime)
            return SysTime(ticks + bootFileTime);
        else
            return MonoTime(ticks - bootFileTime);
    }

    bool opEquals(MonoTime b) const pure
        => ticks == b.ticks;

    int opCmp(MonoTime b) const pure
        => ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

    Duration opBinary(string op, Clock c)(Time!c rhs) const pure if (op == "-")
    {
        ulong t1 = ticks;
        ulong t2 = rhs.ticks;
        static if (clock != c)
        {
            static if (clock == Clock.Monotonic)
                t1 += bootFileTime;
            else
                t2 += bootFileTime;
        }
        return Duration(t1 - t2);
    }

    Time opBinary(string op)(Duration rhs) const pure if (op == "+" || op == "-")
        => Time(mixin("ticks " ~ op ~ " rhs.ticks"));

    void opOpAssign(string op)(Duration rhs) pure if (op == "+" || op == "-")
    {
        mixin("ticks " ~ op ~ "= rhs.ticks;");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        size_t len = timeToString((ticks != 0 ? appTime(this) : Duration()).as!"msecs", buffer.length > 2 ? buffer[2..$] : buffer);
        if (len)
        {
            if (buffer.length > 2)
                buffer[0 .. 2] = "T+";
            return len + 2;
        }
        return 0;
    }

    auto __debugOverview() const
    {
        import urt.mem.temp;
        char[] b = cast(char[])talloc(64);
        size_t len = toString(b, null, null);
        return b[0..len];
    }
}

struct Duration
{
    pure nothrow @nogc:

    long ticks;

    enum zero = Duration(0);
    enum max = Duration(long.max);
    enum min = Duration(long.min);

    bool opCast(T : bool)() const
        => ticks != 0;

    T opCast(T)() const if (isSomeFloat!T)
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

    auto __debugOverview() const
        => cast(double)this;
}

struct DateTime
{
nothrow @nogc:

    short year;
    ubyte month;
    ubyte wday;
    ubyte day;
    ubyte hour;
    ubyte minute;
    ubyte second;
    uint ns;

    ushort msec() const => ns / 1_000_000;
    uint usec() const => ns / 1_000;

    bool leapYear() => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0); // && year >= -44; <- this is the year leap years were invented...

    Duration opBinary(string op)(DateTime rhs) const pure if (op == "-")
    {
        // complicated...
        assert(false);
    }

    DateTime opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
    {
        // complicated...
        assert(false);
    }

    void opOpAssign(string op)(Duration rhs) pure if (op == "+" || op == "-")
    {
        this = mixin("this " ~ op ~ " rhs;");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        import urt.conv : formatInt;

        size_t offset = 0;
        uint y = year;
        if (year <= 0)
        {
            if (buffer.length < 3)
                return 0;
            y = -year + 1;
            buffer[0 .. 3] = "BC ";
            offset += 3;
        }
        offset += year.formatInt(buffer[offset..$]);
        if (offset + 1 > buffer.length)
            return offset;
        buffer[offset++] = '-';
        offset += month.formatInt(buffer[offset..$]);
        if (offset + 1 > buffer.length)
            return offset;
        buffer[offset++] = '-';
        offset += day.formatInt(buffer[offset..$]);
        if (offset + 1 > buffer.length)
            return offset;
        buffer[offset++] = ' ';
        offset += hour.formatInt(buffer[offset..$], 10, 2, '0');
        if (offset + 1 > buffer.length)
            return offset;
        buffer[offset++] = ':';
        offset += minute.formatInt(buffer[offset..$], 10, 2, '0');
        if (offset + 1 > buffer.length)
            return offset;
        buffer[offset++] = ':';
        offset += second.formatInt(buffer[offset..$], 10, 2, '0');
        if (offset + 1 > buffer.length)
            return offset;
        buffer[offset++] = '.';
        offset += (ns / 1_000_000).formatInt(buffer[offset..$], 10, 3, '0');
        return offset;
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

alias nsecs   = dur!"nsecs";
alias usecs   = dur!"usecs";
alias msecs   = dur!"msecs";
alias seconds = dur!"seconds";

MonoTime getTime()
{
    version (Windows)
    {
        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        return MonoTime(now.QuadPart);
    }
    else
    {
        static assert(false, "TODO");
    }
}

SysTime getSysTime()
{
    version (Windows)
    {
        FILETIME ft;
        GetSystemTimePreciseAsFileTime(&ft);
        return SysTime(*cast(ulong*)&ft);
    }
    else
    {
        static assert(false, "TODO");
    }
}


DateTime getDateTime()
{
    version (Windows)
        return fileTimeToDateTime(getSysTime());
    else
        static assert(false, "TODO");
}

DateTime getDateTime(SysTime time)
{
    version (Windows)
        return fileTimeToDateTime(time);
    else
        static assert(false, "TODO");
}

Duration getAppTime()
    => getTime() - startTime;

Duration appTime(MonoTime t)
    => t - startTime;
Duration appTime(SysTime t)
    => cast(MonoTime)t - startTime;

Duration abs(Duration d) pure
    => Duration(d.ticks < 0 ? -d.ticks : d.ticks);


private:

immutable uint ticksPerSecond;
immutable uint nsecMultiplier;
immutable MonoTime startTime;

version (Windows)
    immutable ulong bootFileTime;


package(urt) void initClock()
{
    cast()startTime = getTime();

    version (Windows)
    {
        import core.sys.windows.windows;
        import urt.util : min;

        LARGE_INTEGER freq;
        QueryPerformanceFrequency(&freq);
        cast()ticksPerSecond = cast(uint)freq.QuadPart;
        cast()nsecMultiplier = 1_000_000_000 / ticksPerSecond;

        // we want the ftime for QPC 0; which should be the boot time
        // we'll repeat this 100 times and take the minimum, and we should be within probably nanoseconds of the correct value
        LARGE_INTEGER qpc;
        ulong ftime, bootTime = ulong.max;
        foreach (i; 0 .. 100)
        {
            QueryPerformanceCounter(&qpc);
            GetSystemTimePreciseAsFileTime(cast(FILETIME*)&ftime);
            bootTime = min(bootTime, ftime - qpc.QuadPart);
        }
        cast()bootFileTime = bootTime;
    }
    else
        static assert(false, "TODO");
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

    assert(getTime().toString(null, null, null) == 14);
    assert(tconcat(getTime())[0..2] == "T+");
}


version (Windows)
{
    DateTime fileTimeToDateTime(SysTime ftime)
    {
        version (BigEndian)
            static assert(false, "Only works in little endian!");

        SYSTEMTIME stime;
        FileTimeToSystemTime(cast(FILETIME*)&ftime.ticks, &stime);

        DateTime dt;
        dt.year = stime.wYear;
        dt.month = cast(ubyte)stime.wMonth;
        dt.wday = cast(ubyte)stime.wDayOfWeek;
        dt.day = cast(ubyte)stime.wDay;
        dt.hour = cast(ubyte)stime.wHour;
        dt.minute = cast(ubyte)stime.wMinute;
        dt.second = cast(ubyte)stime.wSecond;
        dt.ns = (ftime.ticks % 10_000_000) * 100;

        debug assert(stime.wMilliseconds == dt.msec);

        return dt;
    }
}
