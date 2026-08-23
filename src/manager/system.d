module manager.system;

import urt.array;
import urt.log;
import urt.mem;
import urt.meta.nullable;
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

// Factory identity: an out-of-box device names itself after its node id, so a fleet of
// fresh units is tellable-apart at every surface that shows the name (beacons, the
// provisioning AP's SSID, BLE advertising). startup.conf's set-hostname overrides it.
void apply_factory_hostname()
{
    import urt.conv : format_uint;

    if (hostname[] != "OpenWatt")
        return;
    char[13] buf = "openwatt-0000";
    format_uint(node_id() & 0xFFFF, buf[9 .. 13], 16, 4, '0');
    hostname = buf[].make_string();
}


// Stable node identity for peering: random 64-bit id, generated on first boot and
// persisted in conf/node.id (the one piece of peering state outside startup.conf).
// Discovery and claims key on this; hostname is display only.
ulong node_id()
{
    import urt.conv : format_uint, parse_uint;
    import urt.file : load_file, save_file;

    if (_node_id != 0)
        return _node_id;

    // a chip-burned hardware id wins where the platform has one (micros: identity
    // survives reflash, no storage needed); computers carry the software id below
    {
        import driver.system : unique_device_id;
        ulong hw = unique_device_id();
        if (hw)
        {
            import urt.hash : fnv1a64;
            _node_id = fnv1a64(cast(const(ubyte)[])(&hw)[0 .. 1]);
            if (_node_id == 0)
                _node_id = hw;
            return _node_id;
        }
    }

    char[] stored = cast(char[])load_file(node_id_path);
    if (stored.length >= 16)
    {
        size_t taken;
        ulong id = parse_uint(stored[0 .. 16], &taken, 16);
        if (taken == 16 && id != 0)
            _node_id = id;
    }
    if (stored)
        free(stored);
    if (_node_id != 0)
        return _node_id;

    _node_id = generate_node_id();

    char[17] buf = void;
    format_uint(_node_id, buf[0 .. 16], 16, 16, '0');
    buf[16] = '\n';
    if (save_file(node_id_path, buf[]).failed)
        log_warning("system", "couldn't persist node id to ", node_id_path, "; identity is ephemeral this boot");
    return _node_id;
}


void log_level(Session session, Severity severity)
{
    get_module!LogModule.set_max_severity(severity);
}

void set_hostname(Session session, const(char)[] hostname)
{
    .hostname = hostname.make_string();
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

    __gshared const String[13] properties = [
        StringLit!"hostname",
        StringLit!"node-id",
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
        session.write_line("Node-Id:  ", format_node_id());
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
        else if (icmp(prop, "node-id") == 0)
            session.write_line(format_node_id());
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
        import urt.mem;

        void[] data = load_file(name);
        if (data is null)
        {
            session.write_line("read failed / not found: '", name, "'");
            return;
        }
        session.write_line(data.length, " bytes: ", cast(const(char)[])data);
        free(data);
    }

    void fs_ls(Session session, Nullable!(const(char)[]) path)
    {
        import urt.file : Directory, DirEntry, open, read, close;

        const(char)[] dir_path = path ? path.value : null;

        Directory dir;
        if (!dir.open(dir_path))
        {
            session.write_line("cannot list '", dir_path, "'");
            return;
        }

        uint count;
        ulong total;
        DirEntry entry;
        while (dir.read(entry))
        {
            session.write_line(entry.is_directory ? "d " : "  ", entry.size, "\t", entry.name);
            total += entry.size;
            ++count;
        }
        dir.close();
        session.write_line(count, " entries, ", total, " bytes");
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
        return alloc!FormatCommandState(session);
    }
}

version (AllocTracking)
{
    import urt.mem.profile.record;

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

version (AllocProfile)
{
    import urt.mem.profile.log;

    void alloc_profile_cmd(Session session)
    {
        alloc_profile_stats((const(char)[] line) { session.write_line(line); });
    }

    void alloc_reset_cmd(Session session)
    {
        alloc_profile_reset_peaks();
        session.write_line("allocation peaks reset");
    }

    void alloc_log_cmd(Session session, bool enable)
    {
        alloc_profile_logging(enable);
        session.write_line("allocation event stream ", enable ? "on" : "off");
    }

    void alloc_mark_point_cmd(Session session, const(char)[] label)
    {
        alloc_profile_mark(label);
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

    return alloc!SleepCommandState(session, duration);
}

private:

__gshared ulong _node_id;
enum node_id_path = "conf/node.id";

const(char)[] format_node_id()
{
    import urt.conv : format_uint;
    import urt.mem.temp : talloc;

    char[] buf = cast(char[])talloc(16);
    format_uint(node_id(), buf, 16, 16, '0');
    return buf;
}

ulong generate_node_id()
{
    import urt.crypto.random : crypto_random_bytes;
    import urt.rand : Rand, rand, srand;

    ulong id;
    while (true)
    {
        if (crypto_random_bytes((cast(ubyte*)&id)[0 .. id.sizeof]).failed)
        {
            // no system RNG on this build; PCG over the clocks is good enough for a one-time id
            Rand rng;
            srand(getSysTime().ticks, getTime().ticks, rng);
            id = ulong(rand(rng)) << 32 | rand(rng);
        }
        if (id != 0)
            return id;
    }
}


// Helper function to format bytes with appropriate unit
auto format_bytes(ulong bytes) nothrow @nogc
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
