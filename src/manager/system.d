module manager.system;

import urt.array;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.system;
import urt.time;

import manager.console.session;
import manager.console.function_command : TabComplete;
import urt.variant : Variant;

nothrow @nogc:


String hostname = StringLit!("OpenWatt"); // TODO: we need to make this thing...


void log_level(Session session, Level level)
{
    logLevel = level;
}

void set_hostname(Session session, const(char)[] hostname)
{
    .hostname = hostname.makeString(defaultAllocator());
}

void get_hostname(Session session)
{
    session.writeLine(hostname);
}

void uptime(Session session)
{
    session.writeLine(getAppTime());
}

Array!String sysinfo_suggest(bool, const(char)[] arg_name, const(char)[]) nothrow @nogc
{
    import urt.string : startsWith;

    __gshared const String[6] properties = [
        StringLit!"hostname",
        StringLit!"os",
        StringLit!"processor",
        StringLit!"total-memory",
        StringLit!"available-memory",
        StringLit!"uptime"
    ];

    Array!String completions;
    foreach (ref prop; properties)
    {
        if (prop.startsWith(arg_name))
            completions ~= prop;
    }
    return completions;
}

@TabComplete(&sysinfo_suggest)
void sysinfo(Session session, const(Variant)[] args)
{
    import urt.string : icmp;

    SystemInfo info = get_sysinfo();

    if (args.length == 0)
    {
        session.writeLine("Hostname:     ", hostname[]);
        session.writeLine("OS:           ", info.os_name);
        session.writeLine("Processor:    ", info.processor);
        session.writeLine("Total Memory: ", info.total_memory.format_bytes());
        session.writeLine("Available:    ", info.available_memory.format_bytes());
        session.writeLine("Uptime:       ", seconds(getAppTime().as!"seconds"));
    }
    else foreach (ref arg; args)
    {
        if (!arg.isString)
        {
            session.writeLine("Error: Arguments must be property names");
            continue;
        }

        const(char)[] prop = arg.asString;
        if (icmp(prop, "hostname") == 0)
            session.writeLine(hostname[]);
        else if (icmp(prop, "os") == 0)
            session.writeLine(info.os_name);
        else if (icmp(prop, "processor") == 0)
            session.writeLine(info.processor);
        else if (icmp(prop, "total-memory") == 0)
            session.writeLine(info.total_memory.format_bytes());
        else if (icmp(prop, "available-memory") == 0)
            session.writeLine(info.available_memory.format_bytes());
        else if (icmp(prop, "uptime") == 0)
            session.writeLine(seconds(getAppTime().as!"seconds"));
        else
            session.writeLine("Unknown property: ", prop);
    }
}

void show_time(Session session)
{
    session.writeLine(getDateTime());
}

auto sleep(Session session, Duration duration)
{
    import manager.console.command : CommandCompletionState;
    import manager.console.function_command : FunctionCommandState;

    static class SleepCommandState : FunctionCommandState
    {
    nothrow @nogc:
        MonoTime wake_time;

        this(Session session, Duration duration)
        {
            super(session);
            wake_time = getTime() + duration;
        }

        override CommandCompletionState update()
        {
            if (getTime() >= wake_time)
                return CommandCompletionState.Finished;
            return CommandCompletionState.InProgress;
        }
    }

    return defaultAllocator().allocT!SleepCommandState(session, duration);
}

// Helper function to format bytes with appropriate unit
private auto format_bytes(ulong bytes) nothrow @nogc
{
    import urt.mem.temp : tconcat;

    if (bytes < 1024)
        return tconcat(bytes, " B");
    else if (bytes < 1024 * 1024)
        return tconcat(bytes / 1024, " KB");
    else if (bytes < 1024 * 1024 * 1024)
        return tconcat(bytes / (1024 * 1024), " MB");
    else
        return tconcat(bytes / (1024 * 1024 * 1024), " GB");
}
