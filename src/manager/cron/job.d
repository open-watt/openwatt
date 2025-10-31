module manager.cron.job;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import manager.base;
import manager.console;
import manager.console.command;
import manager.console.session;

nothrow @nogc:


class CronJob : BaseObject
{
    __gshared Property[6] Properties = [ Property.create!("schedule", schedule)(),
                                         Property.create!("repeat", repeat)(),
                                         Property.create!("command", command)(),
                                         Property.create!("last_run", last_run)(),
                                         Property.create!("next_run", next_run)(),
                                         Property.create!("run_count", run_count)() ];
@nogc nothrow:

    alias TypeName = StringLit!"cron-job";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CronJob, name.move, flags);
    }

    Duration schedule() const { return _schedule; }
    void schedule(Duration value)
    {
        if (_schedule == value)
            return;
        _schedule = value;
        _schedule_type = ScheduleType.duration;
        restart();
    }

    bool repeat() const { return _repeat; }
    void repeat(bool value)
    {
        if (_repeat == value)
            return;
        _repeat = value;
    }

    ref const(String) command() const { return _command; }
    const(char)[] command(String value)
    {
        if (value.empty)
            return "command cannot be empty";
        _command = value.move;
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

        if (_command.length == 0)
        {
            writeError("CronJob '", name, "': No command specified");
            return false;
        }

        return true;
    }

    override CompletionStatus startup()
    {
        SysTime now = getSysTime();

        if (_schedule_type == ScheduleType.duration)
            _next_run = now + _schedule;

        writeInfo("CronJob '", name, "': Scheduled, next run at ", _next_run);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        foreach (ref cmd; _running_commands)
            cmd.command.request_cancel();

        update_running_commands();

        if (_running_commands.length > 0)
            return CompletionStatus.continue_;

        if (_flags & ObjectFlags.temporary)
            destroy();

        return CompletionStatus.complete;
    }

    override void update()
    {
        update_running_commands();

        SysTime now = getSysTime();

        if (now < _next_run)
            return;

        execute_command();

        _last_run = now;
        ++_run_count;

        if (_repeat)
            _next_run = _next_run + _schedule;
        else if (_running_commands.length == 0)
        {
            writeInfo("CronJob '", name, "': One-shot job completed, disabling");
            disabled = true;
        }
    }

private:
    enum ScheduleType
    {
        none,
        duration,
    }

    struct RunningCommand
    {
        ConsoleSession session;
        CommandState command;
    }

    Duration _schedule;
    ScheduleType _schedule_type;
    bool _repeat = true;

    String _command;

    SysTime _last_run;
    SysTime _next_run;
    uint _run_count;

    Array!RunningCommand _running_commands;

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
        writeInfo("CronJob '", name, "': Executing command: ", _command);

        ConsoleSession session = g_app.allocator.allocT!ConsoleSession(g_app.console);
        CommandState command = g_app.console.execute(session, _command[]);

        if (command)
            _running_commands ~= RunningCommand(session, command);
        else
            g_app.allocator.freeT(session);
    }
}
