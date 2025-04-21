module urt.time;

import urt.traits : isSomeFloat;

version (Windows)
{
    import core.sys.windows.windows;

    extern (Windows) void GetSystemTimePreciseAsFileTime(FILETIME* lpSystemTimeAsFileTime) nothrow @nogc;
}
else version (Posix)
{
    import core.sys.posix.time;
}

nothrow @nogc:

enum Day : ubyte
{
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
}

enum Month : ubyte
{
    January = 1,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
}

enum Clock
{
    SystemTime,
    Monotonic,
}

alias MonoTime = Time!(Clock.Monotonic);
alias SysTime = Time!(Clock.SystemTime);

struct Time(Clock clock)
{
pure nothrow @nogc:

    ulong ticks;

    bool opCast(T : bool)() const
        => ticks != 0;

    T opCast(T)() const
        if (is(T == Time!c, Clock c) && c != clock)
    {
        static if (clock == Clock.Monotonic && c == Clock.SystemTime)
            return SysTime(ticks + ticksSinceBoot);
        else
            return MonoTime(ticks - ticksSinceBoot);
    }

    bool opEquals(Time!clock b) const
        => ticks == b.ticks;

    int opCmp(Time!clock b) const
        => ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

    Duration opBinary(string op, Clock c)(Time!c rhs) const if (op == "-")
    {
        ulong t1 = ticks;
        ulong t2 = rhs.ticks;
        static if (clock != c)
        {
            static if (clock == Clock.Monotonic)
                t1 += ticksSinceBoot;
            else
                t2 += ticksSinceBoot;
        }
        return Duration(t1 - t2);
    }

    Time opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
        => Time(mixin("ticks " ~ op ~ " rhs.ticks"));

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
    {
        mixin("ticks " ~ op ~ "= rhs.ticks;");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        long ms = (ticks != 0 ? appTime(this) : Duration()).as!"msecs";
        if (!buffer.ptr)
            return 2 + timeToString(ms, null);
        if (buffer.length < 2)
            return -1;
        buffer[0..2] = "T+";
        ptrdiff_t len = timeToString(ms, buffer[2..$]);
        return len < 0 ? len : 2 + len;
    }

    auto __debugOverview() const
    {
        debug
        {
            import urt.mem.temp;
            char[] b = cast(char[])talloc(64);
            ptrdiff_t len = toString(b, null, null);
            return b[0..len];
        }
        else
            return appTime(this).as!"msecs";
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

alias Timer = FixedTimer!();

struct FixedTimer(uint milliseconds = 0)
{
nothrow @nogc:
    MonoTime startTime;

    static if (milliseconds == 0)
    {
        Duration timeout;

        this(Duration timeout)
        {
            setTimeout(timeout);
            reset();
        }

        void setTimeout(Duration timeout) pure
        {
            this.timeout = timeout;
        }
    }

    void reset(MonoTime now = getTime()) pure
    {
        startTime = now;
    }

    bool expired(MonoTime now = getTime()) const pure
    {
        static if (milliseconds != 0)
            return now - startTime >= milliseconds.msecs;
        else
            return now - startTime >= timeout;
    }

    Duration elapsed(MonoTime now = getTime()) const pure
        => now - startTime;

    Duration remaining(MonoTime now = getTime()) const pure
    {
        static if (milliseconds != 0)
            return milliseconds.msecs - (now - startTime);
        else
            return timeout - (now - startTime);
    }

    Duration expiredDuration(MonoTime now = getTime()) const pure
        => -remaining(now);
}

struct DateTime
{
pure nothrow @nogc:

    short year;
    Month month;
    Day wday;
    ubyte day;
    ubyte hour;
    ubyte minute;
    ubyte second;
    uint ns;

    ushort msec() const => ns / 1_000_000;
    uint usec() const => ns / 1_000;

    bool leapYear() const => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0); // && year >= -44; <- this is the year leap years were invented...

    Duration opBinary(string op)(DateTime rhs) const if (op == "-")
    {
        // complicated...
        assert(false);
    }

    DateTime opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
    {
        // complicated...
        assert(false);
    }

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
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
                return -1;
            y = -year + 1;
            buffer[0 .. 3] = "BC ";
            offset += 3;
        }
        ptrdiff_t len = year.formatInt(buffer[offset..$]);
        if (len < 0 || len == buffer.length)
            return -1;
        offset += len;
        buffer[offset++] = '-';
        len = month.formatInt(buffer[offset..$]);
        if (len < 0 || len == buffer.length)
            return -1;
        offset += len;
        buffer[offset++] = '-';
        len = day.formatInt(buffer[offset..$]);
        if (len < 0 || len == buffer.length)
            return -1;
        offset += len;
        buffer[offset++] = ' ';
        len = hour.formatInt(buffer[offset..$], 10, 2, '0');
        if (len < 0 || len == buffer.length)
            return -1;
        offset += len;
        buffer[offset++] = ':';
        len = minute.formatInt(buffer[offset..$], 10, 2, '0');
        if (len < 0 || len == buffer.length)
            return -1;
        offset += len;
        buffer[offset++] = ':';
        len = second.formatInt(buffer[offset..$], 10, 2, '0');
        if (len < 0 || len == buffer.length)
            return -1;
        offset += len;
        buffer[offset++] = '.';
        len = (ns / 1_000_000).formatInt(buffer[offset..$], 10, 3, '0');
        if (len < 0)
            return len;
        return offset + len;
    }
}

Duration dur(string base)(long value) pure
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
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return MonoTime(ts.tv_sec * 1_000_000_000 + ts.tv_nsec);
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
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return SysTime(ts.tv_sec * 1_000_000_000 + ts.tv_nsec);
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
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return realtimeToDateTime(ts);
    }
    else
        static assert(false, "TODO");
}

DateTime getDateTime(SysTime time)
{
    version (Windows)
        return fileTimeToDateTime(time);
    else version (Posix)
    {
        timespec ts;
        ts.tv_sec = cast(time_t)(time.ticks / 1_000_000_000);
        ts.tv_nsec = cast(uint)(time.ticks % 1_000_000_000);
        return realtimeToDateTime(ts);
    }
    else
        static assert(false, "TODO");
}

Duration getAppTime()
    => getTime() - startTime;

Duration appTime(MonoTime t) pure
    => t - startTime;
Duration appTime(SysTime t) pure
    => cast(MonoTime)t - startTime;

ulong unixTimeNs(SysTime t) pure
{
    version (Windows)
        return (t.ticks - 116444736000000000UL) * 100UL;
    else version (Posix)
        return t.ticks;
    else
        static assert(false, "TODO");
}

Duration abs(Duration d) pure
    => Duration(d.ticks < 0 ? -d.ticks : d.ticks);


private:

immutable MonoTime startTime;

version (Windows)
{
    immutable uint ticksPerSecond;
    immutable uint nsecMultiplier;
    immutable ulong ticksSinceBoot;
}
else version (Posix)
{
    enum uint ticksPerSecond = 1_000_000_000;
    enum uint nsecMultiplier = 1;
    immutable ulong ticksSinceBoot;
}

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
        cast()ticksSinceBoot = bootTime;
    }
    else version (Posix)
    {
        import urt.util : min;

        // this doesn't really give time since boot, since MONOTIME is not guaranteed to be zero at system startup...
        timespec mt, rt;
        ulong bootTime = ulong.max;
        foreach (i; 0 .. 100)
        {
            clock_gettime(CLOCK_MONOTONIC, &mt);
            clock_gettime(CLOCK_REALTIME, &rt);
            bootTime = min(bootTime, rt.tv_sec*1_000_000_000 + rt.tv_nsec - mt.tv_sec*1_000_000_000 - mt.tv_nsec);
        }
        cast()ticksSinceBoot = bootTime;
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

    ptrdiff_t len = hr.formatInt(buffer, 10, 2, '0');
    if (len < 0 || buffer.length < len + 10)
        return -1;

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
        dt.month = cast(Month)stime.wMonth;
        dt.wday = cast(Day)stime.wDayOfWeek;
        dt.day = cast(ubyte)stime.wDay;
        dt.hour = cast(ubyte)stime.wHour;
        dt.minute = cast(ubyte)stime.wMinute;
        dt.second = cast(ubyte)stime.wSecond;
        dt.ns = (ftime.ticks % 10_000_000) * 100;

        debug assert(stime.wMilliseconds == dt.msec);

        return dt;
    }
}
else version (Posix)
{
    DateTime realtimeToDateTime(timespec ts)
    {
        tm t;
        gmtime_r(&ts.tv_sec, &t);

        DateTime dt;
        dt.year = cast(short)(t.tm_year + 1900);
        dt.month = cast(Month)(t.tm_mon + 1);
        dt.wday = cast(Day)t.tm_wday;
        dt.day = cast(ubyte)t.tm_mday;
        dt.hour = cast(ubyte)t.tm_hour;
        dt.minute = cast(ubyte)t.tm_min;
        dt.second = cast(ubyte)t.tm_sec;
        dt.ns = cast(uint)ts.tv_nsec;

        return dt;
    }
}
