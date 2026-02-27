module manager.log;

import urt.array;
import urt.log;
import urt.mem : defaultAllocator;
import urt.mem.temp : tconcat;
import urt.meta.nullable;
import urt.string;
import urt.variant;

import manager;
import manager.console;
import manager.console.command;
import manager.console.function_command;
import manager.console.session;
import manager.plugin;


class LogModule : Module
{
    mixin DeclareModule!"log";
nothrow @nogc

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


auto log_print(Session session, Nullable!Severity level, Nullable!(const(char)[]) tag, Nullable!(const(char)[]) match)
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

__gshared bool g_in_follow_sink;


class LogFollowState : FunctionCommandState
{
nothrow @nogc:

    LogSinkHandle _sink_handle;
    const(char)[] _match;
    bool _cancelled;

    this(Session session, LogFilter filter, const(char)[] match)
    {
        super(session);
        _match = match;
        _sink_handle = register_log_sink(&sink_callback, cast(void*)this, filter);
    }

    ~this()
    {
        unregister_log_sink(_sink_handle);
    }

    override CommandCompletionState update()
    {
        if (_cancelled)
            return CommandCompletionState.cancelled;
        return CommandCompletionState.in_progress;
    }

    override void request_cancel()
    {
        unregister_log_sink(_sink_handle);
        _sink_handle = LogSinkHandle.init;
        _cancelled = true;
    }

    static void sink_callback(void* context, scope ref const LogMessage msg) nothrow @nogc
    {
        if (g_in_follow_sink)
            return;
        g_in_follow_sink = true;
        scope(exit) g_in_follow_sink = false;

        auto self = cast(LogFollowState)context;

        if (self._match.length > 0)
        {
            if (!msg.message.contains_i(self._match) && !msg.tag.contains_i(self._match))
                return;
        }

        self.session.write_line(format_log_line(msg));
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
