module manager.system;

import urt.array;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.system;
import urt.time;
import urt.variant : Variant;

import driver.system : system_reboot;

import manager : get_module;
import manager.console.session;
import manager.console.function_command : TabComplete;
import manager.log;

nothrow @nogc:


__gshared String hostname = StringLit!("OpenWatt"); // TODO: we need to make this thing...


void log_level(Session session, Severity severity)
{
    get_module!LogModule.set_max_severity(severity);
}

void set_hostname(Session session, const(char)[] hostname)
{
    .hostname = hostname.makeString(defaultAllocator());
    set_log_hostname(.hostname[]);   // keep log HOSTNAME stamping in sync
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

private void write_pool_line(Session session, ref const MemoryPool p) nothrow @nogc
{
    // Pad pool name to a fixed width so columns line up across pools
    // (BL808 M0 prints DTCM/OCRAM/PSRAM stacked).
    enum size_t label_width = 8;
    char[label_width] label_buf = ' ';
    auto n = p.name.length < label_width - 1 ? p.name.length : label_width - 1;
    label_buf[0 .. n] = p.name[0 .. n];
    label_buf[n] = ':';

    if (p.largest_free > 0)
        session.write_line(label_buf[],
            p.used.format_bytes(), " / ", p.total.format_bytes(),
            " (peak ", p.peak_used.format_bytes(),
            ", max ", p.largest_free.format_bytes(), ")");
    else
        session.write_line(label_buf[],
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
        session.write_line("Hostname: ", hostname[]);
        session.write_line("OS:       ", info.os_name);
        session.write_line("CPU:      ", info.processor);
        foreach (ref p; info.pools)
        {
            if (p.total > 0)
                session.write_pool_line(p);
        }
        session.write_line("Uptime:   ", seconds(getAppTime().as!"seconds"));
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
            session.write_line(info.pools[0].total.format_bytes());
        else if (icmp(prop, "used") == 0)
            session.write_line(info.pools[0].used.format_bytes());
        else if (icmp(prop, "peak") == 0)
            session.write_line(info.pools[0].peak_used.format_bytes());
        else if (icmp(prop, "largest") == 0)
            session.write_line(info.pools[0].largest_free.format_bytes());
        else if (icmp(prop, "ext-total") == 0)
            session.write_line(info.pools[1].total.format_bytes());
        else if (icmp(prop, "ext-used") == 0)
            session.write_line(info.pools[1].used.format_bytes());
        else if (icmp(prop, "ext-peak") == 0)
            session.write_line(info.pools[1].peak_used.format_bytes());
        else if (icmp(prop, "ext-largest") == 0)
            session.write_line(info.pools[1].largest_free.format_bytes());
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

void reboot(Session session)
{
    session.write_line("reboot: rebooting...");
    system_reboot();
}

version (UseSpiffs)   version = HasFilesystem;
version (UseLittleFS) version = HasFilesystem;

version (HasFilesystem)
{
    import urt.file : delete_file, load_file, save_file;
    import urt.result : Result;
    import manager.console.command : CommandState, CommandCompletionState;

    // Whichever backend is built; littlefs wins when both are.
    version (UseLittleFS)
    {
        import urt.fs.littlefs;
        private alias Fs = LittleFsBackend;
        private alias FsFormatState = LittleFsFormatState;
    }
    else
    {
        import urt.fs.spiffs;
        private alias Fs = SpiffsBackend;
        private alias FsFormatState = SpiffsFormatState;
    }

    void fs_info(Session session)
    {
        ulong total, used;
        if (!Fs.info(total, used))
        {
            session.write_line(Fs.name, ": not mounted (last error ", Fs.last_error(), ")");
            return;
        }
        session.write_line(Fs.name, ": ", used, " / ", total, " bytes used, ", total - used, " free");
        version (UseLittleFS)
            session.write_line("open handles: ", Fs.open_handles());
    }

    void fs_write(Session session, const(char)[] name, const(char)[] text)
    {
        Result r = save_file(name, cast(const(void)[])text);
        if (r)
            session.write_line("wrote ", text.length, " bytes to '", name, "'");
        else
            session.write_line("write failed: ", r.system_code, " (backend error ", Fs.last_error(), ")");
    }

    void fs_read(Session session, const(char)[] name)
    {
        import urt.mem.allocator : defaultAllocator;

        void[] data = load_file(name);
        if (data is null)
        {
            session.write_line("read failed / not found: '", name, "'");
            return;
        }
        session.write_line(data.length, " bytes: ", cast(const(char)[])data);
        defaultAllocator().free(data);
    }

    void fs_rm(Session session, const(char)[] name)
    {
        Result r = delete_file(name);
        session.write_line(r ? "deleted" : "delete failed");
    }

    // The format runs on its own task, because on a multi-megabyte partition it
    // blocks for long enough to starve the watchdog.
    class FormatCommandState : CommandState
    {
    nothrow @nogc:

        this(Session session)
        {
            super(session, null);
        }

        override CommandCompletionState update()
        {
            final switch (format_state())
            {
                case FsFormatState.running:
                    return CommandCompletionState.in_progress;
                case FsFormatState.complete:
                    session.write_line("format: complete");
                    return CommandCompletionState.finished;
                case FsFormatState.failed:
                    session.write_line("format: failed");
                    return CommandCompletionState.error;
                case FsFormatState.idle:
                    return CommandCompletionState.finished;
            }
        }

        // A partition rewrite has no safe interruption point.
        override void request_cancel()
        {
        }
    }

    CommandState fs_format(Session session)
    {
        if (format_state() != FsFormatState.running && !format_begin())
        {
            session.write_line("format: could not start");
            return null;
        }
        session.write_line("format: erasing filesystem...");
        return session.allocator.allocT!FormatCommandState(session);
    }
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
