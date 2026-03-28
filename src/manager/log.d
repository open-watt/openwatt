module manager.log;

import urt.array;
import urt.log;
import urt.mem : defaultAllocator;
import urt.mem.temp : tconcat;
import urt.meta.nullable;
import urt.string;
import urt.string.ansi : visible_width;
import urt.variant;

import manager;
import manager.console;
import manager.console.command;
import manager.console.function_command;
import manager.console.live_view;
import manager.console.session;
import manager.plugin;


class LogModule : Module
{
    mixin DeclareModule!"log";
nothrow @nogc:

    // Ring buffer for log history
    enum log_history_size = 1024;
    Array!(char, 0)[log_history_size] log_history;
    uint log_write_pos;
    uint log_count;

    override void init()
    {
        Command[9] commands = [
            g_app.allocator.allocT!LogCommand(g_app.console, "emergency", Severity.emergency, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "alert", Severity.alert, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "critical", Severity.critical, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "error", Severity.error, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "warning", Severity.warning, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "notice", Severity.notice, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "info", Severity.info, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "debug", Severity.debug_, this),
            g_app.allocator.allocT!LogCommand(g_app.console, "trace", Severity.trace, this),
        ];

        g_app.console.register_commands("/log", commands);
        g_app.console.register_command!log_print("/log", this, "print");

        register_log_sink(&history_sink, cast(void*)this);
    }

    final void push_log(const(char)[] formatted_line)
    {
        log_history[log_write_pos].clear();
        log_history[log_write_pos] ~= formatted_line;
        log_write_pos = (log_write_pos + 1) % log_history_size;
        if (log_count < log_history_size)
            ++log_count;
    }

    final const(char)[] get_log_line(uint index)
    {
        if (index >= log_count)
            return null;
        uint start = log_count < log_history_size ? 0 : log_write_pos;
        uint actual = (start + index) % log_history_size;
        return log_history[actual][];
    }

    static void history_sink(void* context, scope ref const LogMessage msg) nothrow @nogc
    {
        auto self = cast(LogModule)context;
        self.push_log(format_log_line(msg));
    }
}


nothrow @nogc:


const(char)[] format_log_line(scope ref const LogMessage msg)
{
    auto sev = severity_styles[msg.severity];
    enum reset = "\x1b[0m";

    if (msg.tag.length > 0)
    {
        size_t h = 5381;
        foreach (c; msg.tag)
            h = h * 33 + c;
        auto tag_fg = tag_colors[h % tag_colors.length];

        enum tag_width = 12;
        char[tag_width + 1] pad_buf = ' ';
        size_t pad = tag_width > msg.tag.length ? tag_width - msg.tag.length + 1 : 1;

        if (msg.object_name.length > 0)
            return tconcat(sev.badge, ' ', tag_fg, msg.tag, pad_buf[0 .. pad], sev.color, '\'', msg.object_name, "': ", msg.message, reset);
        else
            return tconcat(sev.badge, ' ', tag_fg, msg.tag, sev.color, pad_buf[0 .. pad], msg.message, reset);
    }
    else
        return tconcat(sev.badge, ' ', sev.color, msg.message, reset);
}


CommandState log_print(Session session, Nullable!Severity level, Nullable!(const(char)[]) tag, Nullable!(const(char)[]) match)
{
    LogFilter filter;
    filter.max_severity = level ? level.value : Severity.trace;
    if (tag)
        filter.tag_prefix = tag.value;

    return defaultAllocator().allocT!LogFollowState(session, filter, match ? match.value : null);
}


private:


struct SeverityStyle { string badge, color; }

immutable SeverityStyle[9] severity_styles = [
    SeverityStyle("\x1b[5;1;97;101m ! \x1b[0m", "\x1b[1;91m"),  // emergency
    SeverityStyle("\x1b[1;97;101m A \x1b[0m",   "\x1b[91m"),    // alert
    SeverityStyle("\x1b[1;97;41m C \x1b[0m",    "\x1b[91m"),    // critical
    SeverityStyle("\x1b[97;41m E \x1b[0m",      "\x1b[31m"),    // error
    SeverityStyle("\x1b[30;43m W \x1b[0m",      "\x1b[33m"),    // warning
    SeverityStyle("\x1b[30;46m N \x1b[0m",      "\x1b[36m"),    // notice
    SeverityStyle("\x1b[7m I \x1b[0m",          "\x1b[0m"),     // info
    SeverityStyle("\x1b[97;100m D \x1b[0m",     "\x1b[90m"),    // debug
    SeverityStyle("\x1b[3;37;100m T \x1b[0m",   "\x1b[3;90m"),  // trace
];

immutable string[16] tag_colors = [
    "\x1b[38;2;220;100;100m",  "\x1b[38;2;220;160;100m",
    "\x1b[38;2;200;200;100m",  "\x1b[38;2;130;200;100m",
    "\x1b[38;2;100;200;100m",  "\x1b[38;2;100;200;150m",
    "\x1b[38;2;100;200;200m",  "\x1b[38;2;100;150;220m",
    "\x1b[38;2;100;100;220m",  "\x1b[38;2;150;100;220m",
    "\x1b[38;2;200;100;200m",  "\x1b[38;2;220;100;150m",
    "\x1b[38;2;190;130;80m",   "\x1b[38;2;100;190;190m",
    "\x1b[38;2;190;100;190m",  "\x1b[38;2;170;190;100m",
];

class LogFollowState : LiveViewState
{
nothrow @nogc:

    this(Session session, LogFilter filter, const(char)[] match)
    {
        super(session, null, LiveViewMode.auto_);
        _log_module = get_module!LogModule;
        _match = match;
        _filter = filter;
        _follow = true;
    }

    override uint content_height()
    {
        rebuild_filtered_indices();
        uint w = session.width();
        if (w == 0)
            w = 80;
        uint total = 0;
        foreach (idx; _filtered[])
        {
            const(char)[] line = _log_module.get_log_line(idx);
            uint visible = cast(uint)visible_width(line);
            total += visible == 0 ? 1 : (visible + w - 1) / w;
        }
        return total;
    }

    override void render_content(uint offset, uint count, uint width)
    {
        if (width == 0) width = 80;

        // Find which logical entry corresponds to physical row 'offset'
        uint phys = 0;
        uint src = 0;
        uint sub_offset = 0;
        while (src < _filtered.length && phys < offset)
        {
            const(char)[] line = _log_module.get_log_line(_filtered[src]);
            uint visible = cast(uint)visible_width(line);
            uint rows = visible == 0 ? 1 : (visible + width - 1) / width;
            if (phys + rows > offset)
            {
                sub_offset = offset - phys;
                phys = offset;
                break;
            }
            phys += rows;
            ++src;
        }

        uint drawn = 0;
        while (drawn < count && src < _filtered.length)
        {
            const(char)[] line = _log_module.get_log_line(_filtered[src]);
            if (!line)
                line = "";

            uint visible = cast(uint)visible_width(line);
            uint rows = visible == 0 ? 1 : (visible + width - 1) / width;

            // For wrapped lines, we need to emit full line and let terminal wrap,
            // but count physical rows used
            if (sub_offset == 0 && drawn + rows <= count)
            {
                session.write_output("\r", false);
                session.write_output(line, false);
                session.write_output("\x1b[K\r\n", false);
                drawn += rows;
            }
            else
            {
                // Partial line (scrolled into middle of a wrapped entry)
                // Emit the visible portion starting from sub_offset
                uint start_col = sub_offset * width;
                uint remaining_rows = rows - sub_offset;
                if (remaining_rows > count - drawn)
                    remaining_rows = count - drawn;

                session.write_output("\r", false);
                import urt.string.ansi : visible_slice;
                char[512] slice_buf = void;
                const(char)[] segment = line.visible_slice(slice_buf, start_col, start_col + width);
                session.write_output(segment, false);
                session.write_output("\x1b[K\r\n", false);
                drawn += remaining_rows;
                sub_offset = 0;
            }
            ++src;
        }

        while (drawn < count)
        {
            session.write_output("\x1b[K\r\n", false);
            ++drawn;
        }
    }

    override const(char)[] status_text()
    {
        if (_filtered.length != _log_module.log_count)
            return tconcat(_filtered.length, "/", _log_module.log_count, " entries (filtered)");
        return tconcat(_log_module.log_count, " log entries");
    }

private:
    LogModule _log_module;
    const(char)[] _match;
    LogFilter _filter;
    Array!uint _filtered;
    uint _last_log_count;

    void rebuild_filtered_indices()
    {
        uint current = _log_module.log_count;
        if (current == _last_log_count)
            return;

        _filtered.clear();
        foreach (i; 0 .. current)
        {
            const(char)[] line = _log_module.get_log_line(i);
            if (line is null)
                continue;

            if (_match.length > 0)
            {
                import urt.string : contains_i;
                if (!line.contains_i(_match))
                    continue;
            }

            _filtered ~= i;
        }
        _last_log_count = current;
    }
}


class LogCommand : Command
{
nothrow @nogc:

    LogModule instance;
    Severity severity;

    this(ref Console console, const(char)[] name, Severity severity, LogModule instance)
    {
        import urt.mem.string;

        super(console, String(name.addString));
        this.instance = instance;
        this.severity = severity;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length == 0 || args.length > 1)
        {
            session.write_line("/log command expected string argument");
            return null;
        }

        write_log(severity, "console", null, args[0]);
        return null;
    }

    version (ExcludeAutocomplete) {} else
    {
        override MutableString!0 complete(const(char)[] cmdLine) const
        {
            assert(false);
            return MutableString!0();
        }


        override Array!String suggest(const(char)[] cmdLine) const
        {
            return Array!String();
        }
    }

    version (ExcludeHelpText) {} else
    {
        override const(char)[] help(const(char)[] args) const
        {
            assert(false);
            return null;
        }
    }
}
