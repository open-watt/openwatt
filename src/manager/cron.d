module manager.cron;

import urt.mem;
import urt.mem.temp : tconcat;
import urt.result : StringResult;
import urt.string;
import urt.time;

import manager : g_app, get_module;
import manager.plugin;
import manager.signal;
import manager.system : apply_timezone;

nothrow @nogc:


enum Weekday : ubyte
{
    sun, mon, tue, wed, thu, fri, sat
}

enum TimeKind : ubyte
{
    duration,
    tod,
    absolute,
}

// The built-in time signal provider: schemes `every:<dur>`, `at:<hh:mm>?days=...`, `when:<datetime>`.
final class CronModule : Module, ISignalProvider
{
    mixin DeclareModule!"cron";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!Weekday();

        g_app.register_signal_provider(StringLit!"every", this);
        g_app.register_signal_provider(StringLit!"at", this);
        g_app.register_signal_provider(StringLit!"when", this);
    }

    override StringResult validate(ref const SignalUri uri) const
    {
        TimeSpec spec;
        return parse_time(uri, spec);
    }

    override StringResult subscribe(ref const SignalUri uri, SignalSink sink, out SignalSub handle)
    {
        TimeSpec spec;
        StringResult e = parse_time(uri, spec);
        if (!e)
            return e;

        TimeSub s = alloc!TimeSub();
        s.sink = sink;
        s.kind = spec.kind;
        s.schedule = spec.schedule;
        s.at = spec.at;
        s.when = spec.when;
        s.when_has_tz = spec.when_has_tz;
        s.days_mask = spec.days_mask;
        s.repeat = spec.repeat;

        s.arm();
        handle = s;
        return StringResult.success;
    }

    override void unsubscribe(SignalSub handle)
    {
        TimeSub s = cast(TimeSub)cast(void*)handle;
        s.disarm();
        free(s);
    }

    override SysTime next_run(SignalSub handle) const
    {
        TimeSub s = cast(TimeSub)cast(void*)handle;
        return s.next_run();
    }
}


private:

final class TimeSub : SignalSub
{
nothrow @nogc:

    SignalSink sink;
    TimeKind kind;
    Duration schedule;
    TimeOfDay at;
    DateTime when;
    bool when_has_tz;
    ubyte days_mask = 0x7F;
    bool repeat = true;

    override ISignalProvider provider()
        => get_module!CronModule;

    void arm()
    {
        if (kind == TimeKind.duration)
            _next = getSysTime() + schedule;
        else
            advance_wallclock(getSysTime());

        _done = false;
        schedule_fire(getTime());

        if (kind == TimeKind.tod || kind == TimeKind.absolute)
        {
            g_app.subscribe_wallclock_change(&on_wallclock_change);
            _wc_subscribed = true;
        }
    }

    void disarm()
    {
        if (_wc_subscribed)
        {
            g_app.unsubscribe_wallclock_change(&on_wallclock_change);
            _wc_subscribed = false;
        }
        if (_fire_scheduled)
        {
            g_app.cancel(&on_fire);
            _fire_scheduled = false;
        }
    }

    SysTime next_run() const
        => _done ? SysTime() : _next;

private:
    SysTime _next;
    Duration _offset;
    bool _fire_scheduled;
    bool _wc_subscribed;
    bool _done;
    bool _settling;

    void schedule_fire(MonoTime anchor)
    {
        Duration until;
        final switch (kind)
        {
            case TimeKind.duration:
                g_app.schedule(anchor + schedule, &on_fire);
                _fire_scheduled = true;
                return;
            case TimeKind.tod:
            case TimeKind.absolute:
                until = _next - getSysTime();
                if (until < Duration.zero)
                    until = Duration.zero;   // missed deadline -> fire immediately
                break;
        }
        g_app.schedule(getTime() + until, &on_fire);
        _fire_scheduled = true;
    }

    void on_fire(MonoTime scheduled)
    {
        _fire_scheduled = false;
        if (_done)
            return;
        if (kind != TimeKind.duration && !due(getSysTime()))
        {
            schedule_fire(getTime());
            return;
        }

        bool one_shot = false;
        final switch (kind)
        {
            case TimeKind.absolute:
                one_shot = true;
                break;
            case TimeKind.duration:
                one_shot = !repeat;
                if (!one_shot)
                    _next = _next + schedule;
                break;
            case TimeKind.tod:
                one_shot = !repeat;
                if (!one_shot)
                    advance_wallclock(getSysTime());
                break;
        }

        if (one_shot)
            _done = true;

        // consumed before emitting: a clock or timezone change made by the action re-arms only the next one
        SignalEvent ev = { source: "time" };
        sink(scheduled, ev);

        if (!_done && !_fire_scheduled)
            schedule_fire(scheduled);
    }

    void on_wallclock_change(Duration)
    {
        if (_done || _settling)
            return;
        if (_fire_scheduled)
        {
            g_app.cancel(&on_fire);
            _fire_scheduled = false;
        }
        retime(getSysTime());
        schedule_fire(getTime());
    }

    void advance_wallclock(SysTime now)
    {
        _offset = local_offset(now);
        if (kind == TimeKind.absolute)
            _next = when_has_tz ? get_sys_time(when) : cast(SysTime)get_local_time(when);
        else
            _next = next_local_occurrence(now, at, days_mask);
    }

    // a timezone change keeps the pending occurrence's wall time, so an occurrence the
    // change jumps over fires late rather than being lost; a UTC step recomputes from now
    void retime(SysTime now)
    {
        if (!rebase(now))
            advance_wallclock(now);
    }

    bool rebase(SysTime now)
    {
        Duration offset = local_offset(now);
        if (offset == _offset)
            return false;
        if (kind == TimeKind.tod)
        {
            _next = _next + (_offset - offset);
            _offset = offset;
        }
        else
            advance_wallclock(now);
        return true;
    }

    // the minute poll can lag an offset change, so settle it before consuming an occurrence;
    // the rebase is done here rather than by the change notification this raises
    bool due(SysTime now)
    {
        _settling = true;
        apply_timezone();
        _settling = false;
        rebase(now);
        return _next <= now;
    }
}

Duration local_offset(SysTime now)
    => SysTime((cast(LocalTime)now).ticks) - now;

SysTime next_local_occurrence(SysTime now, TimeOfDay at, ubyte days_mask)
{
    SysTime wall = next_occurrence(SysTime((cast(LocalTime)now).ticks), at, days_mask);
    return cast(SysTime)LocalTime(wall.ticks);
}

struct TimeSpec
{
    TimeKind kind;
    Duration schedule;
    TimeOfDay at;
    DateTime when;
    bool when_has_tz;
    ubyte days_mask = 0x7F;
    bool repeat = true;
}

// Parse a time URI's body and query into `spec`; error message on malformed input. Shared by
// validate() (discards the spec) and subscribe() (copies it into the allocated TimeSub).
StringResult parse_time(ref const SignalUri uri, out TimeSpec spec)
{
    switch (uri.scheme)
    {
        case "every":
            if (spec.schedule.fromString(uri.body) != cast(ptrdiff_t)uri.body.length)
                return StringResult(tconcat("bad duration: ", uri.body));
            spec.kind = TimeKind.duration;
            break;
        case "at":
            if (spec.at.fromString(uri.body) != cast(ptrdiff_t)uri.body.length)
                return StringResult(tconcat("bad time of day: ", uri.body));
            spec.kind = TimeKind.tod;
            if (const(char)[] d = uri_param(uri.query, "days"))
                spec.days_mask = parse_days(d);
            break;
        case "when":
            if (spec.when.from_string(uri.body, spec.when_has_tz) != cast(ptrdiff_t)uri.body.length)
                return StringResult(tconcat("bad date/time: ", uri.body));
            spec.kind = TimeKind.absolute;
            break;
        default:
            return StringResult(tconcat("unsupported time signal: ", uri.scheme));
    }

    if (const(char)[] r = uri_param(uri.query, "repeat"))
        spec.repeat = !(r == "false" || r == "0" || r == "no");
    return StringResult.success;
}

ubyte parse_days(const(char)[] s)
{
    ubyte mask = 0;
    while (s.length)
    {
        size_t c = 0;
        while (c < s.length && s[c] != ',')
            ++c;
        const(char)[] d = s[0 .. c];
        s = (c < s.length) ? s[c + 1 .. $] : null;
        switch (d)
        {
            case "sun": mask |= 1 << Weekday.sun; break;
            case "mon": mask |= 1 << Weekday.mon; break;
            case "tue": mask |= 1 << Weekday.tue; break;
            case "wed": mask |= 1 << Weekday.wed; break;
            case "thu": mask |= 1 << Weekday.thu; break;
            case "fri": mask |= 1 << Weekday.fri; break;
            case "sat": mask |= 1 << Weekday.sat; break;
            default: break;
        }
    }
    return mask ? mask : 0x7F;
}

unittest
{
    set_timezone(dur!"hours"(10));
    scope(exit) set_timezone(Duration.zero);

    DateTime dt = { year: 2026, month: Month.June, day: 15, hour: 7, minute: 30 };
    SysTime now = get_sys_time(dt);
    DateTime next = get_date_time(next_local_occurrence(now, TimeOfDay(18, 0, 0, 0), 0x7F));
    assert(next.day == 15 && next.hour == 8 && next.minute == 0);
    next = get_date_time(next_local_occurrence(now, TimeOfDay(17, 0, 0, 0), 0x7F));
    assert(next.day == 16 && next.hour == 7);
    next = get_date_time(next_local_occurrence(now, TimeOfDay(18, 0, 0, 0), 1 << Weekday.wed));
    assert(next.day == 17 && next.hour == 8);

    TimeSpec spec;
    SignalUri uri = SignalUri("when", "2026-06-16T00:00:00");
    assert(parse_time(uri, spec));
    assert(!spec.when_has_tz && cast(SysTime)get_local_time(spec.when) == get_sys_time(dt) + dur!"hours"(6) + dur!"minutes"(30));
    uri.body = "2026-06-16T00:00:00Z";
    assert(parse_time(uri, spec));
    assert(spec.when_has_tz && get_sys_time(spec.when) == get_sys_time(dt) + dur!"hours"(16) + dur!"minutes"(30));

    TimeSub s = alloc!TimeSub();
    scope(exit) free(s);
    s.kind = TimeKind.tod;
    DateTime day = { year: 2026, month: Month.March, day: 29 };

    // spring forward, UTC+1 -> +2 at 01:00 UTC, seen by the poll at 01:00:30
    set_timezone(dur!"hours"(1));
    s.at = TimeOfDay(3, 0, 0, 0);
    s.advance_wallclock(get_sys_time(day));
    assert(s._next == get_sys_time(day) + dur!"hours"(2));
    set_timezone(dur!"hours"(2));
    SysTime seen = get_sys_time(day) + dur!"hours"(1) + dur!"seconds"(30);
    s.retime(seen);
    assert(s._next == get_sys_time(day) + dur!"hours"(1));
    s.advance_wallclock(seen);
    assert(s._next == get_sys_time(day) + dur!"hours"(25));

    // the 02:30 the jump skips fires at the first moment after the gap
    set_timezone(dur!"hours"(1));
    s.at = TimeOfDay(2, 30, 0, 0);
    s.advance_wallclock(get_sys_time(day));
    set_timezone(dur!"hours"(2));
    s.retime(seen);
    assert(s._next <= seen);
    s.advance_wallclock(seen);
    assert(s._next == get_sys_time(day) + dur!"hours"(24) + dur!"minutes"(30));

    // fall back, UTC+2 -> +1 at 01:00 UTC; the repeated 02:30 fires once
    set_timezone(dur!"hours"(2));
    s.advance_wallclock(get_sys_time(day));
    assert(s._next == get_sys_time(day) + dur!"minutes"(30));
    s.advance_wallclock(s._next);
    set_timezone(dur!"hours"(1));
    s.retime(seen);
    assert(s._next == get_sys_time(day) + dur!"hours"(25) + dur!"minutes"(30));

    // an unchanged offset (a UTC step) recomputes from now
    s.retime(get_sys_time(day) + dur!"hours"(30));
    assert(s._next == get_sys_time(day) + dur!"hours"(49) + dur!"minutes"(30));

    // zone-less when: in the gap also fires as soon as the change is seen
    set_timezone(dur!"hours"(1));
    s.kind = TimeKind.absolute;
    s.when = day;
    s.when.hour = 2;
    s.when.minute = 30;
    s.advance_wallclock(get_sys_time(day));
    set_timezone(dur!"hours"(2));
    s.retime(seen);
    assert(s._next <= seen);

    // fall back reaching the fire before the poll: due at the transition instant, OS already +1
    import manager.system : timezone_override;
    scope(exit)
    {
        timezone_override = Duration.zero;
        apply_timezone();
        timezone_override = null;
    }
    SysTime edge = get_sys_time(day) + dur!"hours"(1);
    s.kind = TimeKind.tod;
    s.at = TimeOfDay(3, 0, 0, 0);
    s.when.hour = 3;
    s.when.minute = 0;
    foreach (kind; [ TimeKind.tod, TimeKind.absolute ])
    {
        timezone_override = dur!"hours"(2);
        apply_timezone();
        s.kind = kind;
        s.advance_wallclock(get_sys_time(day));
        assert(s._next == edge);
        timezone_override = dur!"hours"(1);
        assert(!s.due(edge));
        assert(s._next == edge + dur!"hours"(1));
        assert(s.due(edge + dur!"hours"(1)));
    }

    // an action that changes the timezone emits its occurrence once; the probe stands in for the
    // change notification, which re-arms the sub as on_wallclock_change would without an app
    static struct Probe
    {
    nothrow @nogc:
        TimeSub s;
        int count;
        void emit(MonoTime, ref const SignalEvent)
        {
            ++count;
            timezone_override = dur!"hours"(count & 1 ? 11 : 10);
            apply_timezone();
            if (s._done)
                return;
            s.retime(getSysTime());
            s._fire_scheduled = true;
        }
    }
    Probe probe = Probe(s);
    s.sink = &probe.emit;
    timezone_override = dur!"hours"(10);
    apply_timezone();

    s.kind = TimeKind.absolute;
    s.when_has_tz = true;
    s.when = get_date_time(getSysTime() - dur!"seconds"(1));
    s.advance_wallclock(getSysTime());
    s.on_fire(getTime());
    s.on_fire(getTime());
    assert(probe.count == 1 && s._done);

    s._done = false;
    s.kind = TimeKind.tod;
    s.at = time_of_day(get_date_time(get_local_time() + dur!"hours"(12)));
    s.advance_wallclock(getSysTime());
    s._next = getSysTime();
    probe.count = 0;
    s.on_fire(getTime());
    assert(probe.count == 1 && s._fire_scheduled);
    assert(!s.due(getSysTime()));
}
