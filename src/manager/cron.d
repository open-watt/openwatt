module manager.cron;

import urt.mem.temp : tconcat;
import urt.result : StringResult;
import urt.string;
import urt.time;

import manager : g_app, get_module;
import manager.plugin;
import manager.signal;

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
class CronModule : Module, ISignalProvider
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

        TimeSub s = g_app.allocator.allocT!TimeSub();
        s.sink = sink;
        s.kind = spec.kind;
        s.schedule = spec.schedule;
        s.at = spec.at;
        s.when = spec.when;
        s.days_mask = spec.days_mask;
        s.repeat = spec.repeat;

        s.arm();
        handle = s;
        return StringResult.success;
    }

    override void unsubscribe(SignalSub handle)
    {
        TimeSub s = cast(TimeSub)handle;
        s.disarm();
        g_app.allocator.freeT(s);
    }

    override SysTime next_run(SignalSub handle) const
    {
        TimeSub s = cast(TimeSub)handle;
        return s.next_run();
    }
}


private:

class TimeSub : SignalSub
{
nothrow @nogc:

    SignalSink sink;
    TimeKind kind;
    Duration schedule;
    TimeOfDay at;
    SysTime when;
    ubyte days_mask = 0x7F;
    bool repeat = true;

    override ISignalProvider provider()
        => get_module!CronModule;

    void arm()
    {
        SysTime now = getSysTime();
        final switch (kind)
        {
            case TimeKind.duration: _next = now + schedule; break;
            case TimeKind.tod:      _next = next_occurrence(now, at, days_mask); break;
            case TimeKind.absolute: _next = when; break;
        }

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
    bool _fire_scheduled;
    bool _wc_subscribed;
    bool _done;

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

        SignalEvent ev = { source: "time" };
        sink(scheduled, ev);

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
                    _next = next_occurrence(getSysTime(), at, days_mask);
                break;
        }

        if (one_shot)
            _done = true;
        else
            schedule_fire(scheduled);
    }

    void on_wallclock_change(Duration)
    {
        if (_done)
            return;
        if (_fire_scheduled)
        {
            g_app.cancel(&on_fire);
            _fire_scheduled = false;
        }
        if (kind == TimeKind.tod)
            _next = next_occurrence(getSysTime(), at, days_mask);
        schedule_fire(getTime());
    }
}

struct TimeSpec
{
    TimeKind kind;
    Duration schedule;
    TimeOfDay at;
    SysTime when;
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
            if (spec.when.fromString(uri.body) != cast(ptrdiff_t)uri.body.length)
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
