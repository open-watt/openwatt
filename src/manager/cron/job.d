module manager.cron.job;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.string;
import urt.time;
import urt.util : popcnt;
import urt.variant;

import manager;
import manager.base;
import manager.console;
import manager.console.command;
import manager.console.session;
import manager.expression : Script;

nothrow @nogc:


enum Weekday : ubyte
{
    sun, mon, tue, wed, thu, fri, sat
}


class CronJob : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("schedule", schedule),
                                 Prop!("at", at),
                                 Prop!("days", days),
                                 Prop!("when", when),
                                 Prop!("repeat", repeat),
                                 Prop!("do", script),
                                 Prop!("last_run", last_run),
                                 Prop!("next_run", next_run),
                                 Prop!("run_count", run_count));
@nogc nothrow:

    enum type_name = "cron-job";
    enum path = "/system/cron";
    enum collection_id = CollectionType.cron_job;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CronJob, id, flags);
    }

    Duration schedule() const { return _schedule; }
    void schedule(Duration value)
    {
        if (_schedule_type == ScheduleType.duration && _schedule == value)
            return;
        _schedule = value;
        _schedule_type = ScheduleType.duration;
        restart();
    }

    TimeOfDay at() const { return _at; }
    void at(TimeOfDay value)
    {
        if (_schedule_type == ScheduleType.tod && _at == value)
            return;
        _at = value;
        _schedule_type = ScheduleType.tod;
        restart();
    }

    Weekday[] days() const
    {
        auto buf = tempAllocator().allocArray!Weekday(popcnt(_days_mask));
        size_t i = 0;
        foreach (ubyte w; 0 .. 7)
        {
            if (_days_mask & (1 << w))
                buf[i++] = cast(Weekday)w;
        }
        return buf;
    }
    void days(Weekday[] value)
    {
        ubyte mask = 0;
        foreach (w; value)
            mask |= cast(ubyte)(1 << w);
        if (_days_mask == mask)
            return;
        _days_mask = mask;
        restart();
    }

    SysTime when() const { return _when; }
    void when(SysTime value)
    {
        if (_schedule_type == ScheduleType.absolute && _when == value)
            return;
        _when = value;
        _schedule_type = ScheduleType.absolute;
        restart();
    }

    bool repeat() const { return _repeat; }
    void repeat(bool value)
    {
        if (_repeat == value)
            return;
        _repeat = value;
    }

    Script script() const { return Script(_script); }
    const(char)[] script(Script value)
    {
        if (value.empty)
            return "script cannot be empty";
        _script = value;
        return null;
    }

    SysTime last_run() const { return _last_run; }
    SysTime next_run() const { return _next_run; }
    uint run_count() const { return _run_count; }

protected:
    override bool validate() const
    {
        if (_schedule_type == ScheduleType.none)
        {
            writeError("CronJob '", name, "': No schedule specified");
            return false;
        }

        if (_script.empty)
        {
            writeError("CronJob '", name, "': No script specified");
            return false;
        }

        return true;
    }

    override CompletionStatus startup()
    {
        SysTime now = getSysTime();

        final switch (_schedule_type)
        {
            case ScheduleType.none:
                break;
            case ScheduleType.duration:
                _next_run = now + _schedule;
                break;
            case ScheduleType.tod:
                _next_run = next_occurrence(now, _at, _days_mask);
                break;
            case ScheduleType.absolute:
                _next_run = _when;
                break;
        }

        _done_firing = false;
        if (_schedule_type != ScheduleType.none)
            schedule_fire(getTime());

        if (_schedule_type == ScheduleType.tod || _schedule_type == ScheduleType.absolute)
        {
            g_app.subscribe_wallclock_change(&on_wallclock_change);
            _wc_subscribed = true;
        }

        writeInfo("CronJob '", name, "': Scheduled, next run at ", _next_run);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
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
        if (_cleanup_scheduled)
        {
            g_app.cancel(&on_cleanup);
            _cleanup_scheduled = false;
        }

        foreach (ref cmd; _running_commands)
            cmd.command.request_cancel();

        update_running_commands();

        if (_running_commands.length > 0)
        {
            // commands still draining - keep cleanup scheduled until they
            // finish; the state machine will re-enter shutdown() until we
            // return complete
            schedule_cleanup();
            return CompletionStatus.continue_;
        }

        return CompletionStatus.complete;
    }

private:
    enum ScheduleType
    {
        none,
        duration,
        tod,
        absolute,
    }

    struct RunningCommand
    {
        Session session;
        CommandState command;
    }

    Duration _schedule;
    TimeOfDay _at;
    SysTime _when;
    ubyte _days_mask;
    ScheduleType _schedule_type;
    bool _repeat = true;

    Script _script;

    SysTime _last_run;
    SysTime _next_run;
    uint _run_count;

    Array!RunningCommand _running_commands;

    bool _done_firing;
    bool _fire_scheduled;
    bool _cleanup_scheduled;
    bool _wc_subscribed;

    void schedule_fire(MonoTime anchor)
    {
        Duration until;
        final switch (_schedule_type)
        {
            case ScheduleType.none:
                return;
            case ScheduleType.duration:
                g_app.schedule(anchor + _schedule, &on_fire);
                _fire_scheduled = true;
                return;
            case ScheduleType.tod:
            case ScheduleType.absolute:
                until = _next_run - getSysTime();
                if (until < Duration.zero)
                    until = Duration.zero;   // missed deadline -> fire immediately
                break;
        }
        g_app.schedule(getTime() + until, &on_fire);
        _fire_scheduled = true;
    }

    void on_wallclock_change()
    {
        if (_done_firing)
            return;

        if (_fire_scheduled)
        {
            g_app.cancel(&on_fire);
            _fire_scheduled = false;
        }

        if (_schedule_type == ScheduleType.tod)
            _next_run = next_occurrence(getSysTime(), _at, _days_mask);

        schedule_fire(getTime());
    }

    void schedule_cleanup()
    {
        if (_cleanup_scheduled)
            return;
        g_app.schedule(getTime() + msecs(50), &on_cleanup);
        _cleanup_scheduled = true;
    }

    void on_fire(MonoTime scheduled)
    {
        _fire_scheduled = false;

        execute_command();

        _last_run = getSysTime();
        ++_run_count;

        bool one_shot = false;
        final switch (_schedule_type)
        {
            case ScheduleType.none:
            case ScheduleType.absolute:
                one_shot = true;
                break;
            case ScheduleType.duration:
                one_shot = !_repeat;
                if (!one_shot)
                    _next_run = _next_run + _schedule;
                break;
            case ScheduleType.tod:
                one_shot = !_repeat;
                if (!one_shot)
                    _next_run = next_occurrence(_last_run, _at, _days_mask);
                break;
        }

        if (one_shot)
            _done_firing = true;
        else
            schedule_fire(scheduled);

        if (_running_commands.length > 0)
            schedule_cleanup();
        else if (_done_firing)
            complete_one_shot();
    }

    void on_cleanup(MonoTime scheduled)
    {
        _cleanup_scheduled = false;

        update_running_commands();

        if (_running_commands.length > 0)
            schedule_cleanup();
        else if (_done_firing)
            complete_one_shot();
    }

    void complete_one_shot()
    {
        writeInfo("CronJob '", name, "': One-shot job completed, disabling");
        disabled = true;
    }

    void update_running_commands()
    {
        for (size_t i = 0; i < _running_commands.length; )
        {
            RunningCommand* cmd = &_running_commands[i];
            CommandCompletionState state = cmd.command.update();
            if (state >= CommandCompletionState.finished)
            {
                g_app.allocator.freeT(cmd.session);
                _running_commands.remove(i);
            }
            else
                ++i;
        }
    }

    void execute_command()
    {
        writeInfo("CronJob '", name, "': Executing script: ", _script.source);

        Variant result;
        Session session = g_app.allocator.allocT!Session(g_app.console);
        CommandState command = g_app.console.execute(session, _script, result);

        if (command)
            _running_commands ~= RunningCommand(session, command);
        else
            g_app.allocator.freeT(session);
    }
}
