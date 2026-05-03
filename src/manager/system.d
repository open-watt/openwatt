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


void log_level(Session session, Severity severity)
{
    // TODO: should this be deleted?
    //       this command is a global log filter, but i reckon we should move filtering to the clients
    foreach (i; 0 .. 16)
    {
        set_sink_filter(LogSinkHandle(i), LogFilter(severity));
    }
}

void set_hostname(Session session, const(char)[] hostname)
{
    .hostname = hostname.makeString(defaultAllocator());
}

void get_hostname(Session session)
{
    session.write_line(hostname);
}

void uptime(Session session)
{
    session.write_line(getAppTime());
}

Array!String sysinfo_suggest(bool, const(char)[] arg_name, const(char)[]) nothrow @nogc
{
    import urt.string : startsWith;

    __gshared const String[12] properties = [
        StringLit!"hostname",
        StringLit!"os",
        StringLit!"processor",
        StringLit!"total",
        StringLit!"used",
        StringLit!"peak",
        StringLit!"largest",
        StringLit!"ext-total",
        StringLit!"ext-used",
        StringLit!"ext-peak",
        StringLit!"ext-largest",
        StringLit!"uptime"
    ];

    Array!String completions;
    foreach (ref prop; properties)
    {
        if (prop[].startsWith(arg_name))
            completions ~= prop;
    }
    return completions;
}

private void write_pool_line(Session session, const(char)[] label, ref const MemoryPool p) nothrow @nogc
{
    if (p.largest_free > 0)
        session.write_line(label,
            p.used.format_bytes(), " / ", p.total.format_bytes(),
            " (peak ", p.peak_used.format_bytes(),
            ", max ", p.largest_free.format_bytes(), ")");
    else
        session.write_line(label,
            p.used.format_bytes(), " / ", p.total.format_bytes(),
            " (peak ", p.peak_used.format_bytes(), ")");
}

@TabComplete(&sysinfo_suggest)
void sysinfo(Session session, const(Variant)[] args)
{
    import urt.string : icmp;

    SystemInfo info = get_sysinfo();

    if (args.length == 0)
    {
        session.write_line("Hostname:  ", hostname[]);
        session.write_line("OS:        ", info.os_name);
        session.write_line("Processor: ", info.processor);
        session. write_pool_line("RAM:      ", info.fast_ram);
        if (info.ext_ram.total > 0)
            session. write_pool_line("Ext RAM:  ", info.ext_ram);
        session.write_line("Uptime:    ", seconds(getAppTime().as!"seconds"));
    }
    else foreach (ref arg; args)
    {
        if (!arg.isString)
        {
            session.write_line("Error: Arguments must be property names");
            continue;
        }

        const(char)[] prop = arg.asString;
        if (icmp(prop, "hostname") == 0)
            session.write_line(hostname[]);
        else if (icmp(prop, "os") == 0)
            session.write_line(info.os_name);
        else if (icmp(prop, "processor") == 0)
            session.write_line(info.processor);
        else if (icmp(prop, "total") == 0)
            session.write_line(info.fast_ram.total.format_bytes());
        else if (icmp(prop, "used") == 0)
            session.write_line(info.fast_ram.used.format_bytes());
        else if (icmp(prop, "peak") == 0)
            session.write_line(info.fast_ram.peak_used.format_bytes());
        else if (icmp(prop, "largest") == 0)
            session.write_line(info.fast_ram.largest_free.format_bytes());
        else if (icmp(prop, "ext-total") == 0)
            session.write_line(info.ext_ram.total.format_bytes());
        else if (icmp(prop, "ext-used") == 0)
            session.write_line(info.ext_ram.used.format_bytes());
        else if (icmp(prop, "ext-peak") == 0)
            session.write_line(info.ext_ram.peak_used.format_bytes());
        else if (icmp(prop, "ext-largest") == 0)
            session.write_line(info.ext_ram.largest_free.format_bytes());
        else if (icmp(prop, "uptime") == 0)
            session.write_line(seconds(getAppTime().as!"seconds"));
        else
            session.write_line("Unknown property: ", prop);
    }
}

void show_time(Session session)
{
    session.write_line(getDateTime());
}

version (AllocTracking)
{
    import urt.mem.tracking;

    void alloc_stats_cmd(Session session)
    {
        alloc_print_stats((const(char)[] line) { session.write_line(line); });
    }

    void alloc_mark_cmd(Session session)
    {
        alloc_mark_baseline();
        session.write_line("alloc baseline marked at serial ", alloc_baseline());
    }

    void alloc_leaks_cmd(Session session, Duration age = seconds(60))
    {
        alloc_print_leaks(age, (const(char)[] line) { session.write_line(line); });
    }
}

auto sleep(Session session, Duration duration)
{
    import manager.console.command;

    static class SleepCommandState : CommandState
    {
    nothrow @nogc:
        MonoTime wake_time;

        this(Session session, Duration duration)
        {
            super(session, null);
            wake_time = getTime() + duration;
        }

        override CommandCompletionState update()
        {
            if (getTime() >= wake_time)
                return CommandCompletionState.finished;
            return CommandCompletionState.in_progress;
        }

        override void request_cancel()
        {
            wake_time = MonoTime();
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
