module main;

import urt.log;
import urt.mem.allocator;
import urt.system;
import urt.time;

import manager;
import manager.console.session;

nothrow @nogc:


int main(string[] args)
{
    // init the string heap with 1mb!
//    initStringHeap(1024*1024); // TODO: uncomment when remove the module constructor...

    // TODO: prime the string cache with common strings, like unit names and common variable names
    //       the idea is to make dedup lookups much faster...

    bool interactive_mode = false;
    const(char)[] config_path = "conf/startup.conf";
    foreach (i, arg; args[1 .. $])
    {
        if (arg == "--interactive" || arg == "-i")
            interactive_mode = true;
        else if (arg == "--config" || arg == "-c")
        {
            if (i < args.length - 1)
                config_path = args[i + 2]; // i+2 because we're indexing from args[1..$]
        }
    }

    if (interactive_mode)
    {
        // check if stdout is redirected
        version (Windows)
        {
            import core.sys.windows.windows : GetStdHandle, GetConsoleMode, STD_OUTPUT_HANDLE, DWORD;
            auto h_stdout = GetStdHandle(STD_OUTPUT_HANDLE);

            DWORD mode;
            bool is_console = GetConsoleMode(h_stdout, &mode) != 0;
            if (!is_console)
            {
                // piped output - log to stderr so stdout stays clean for command output
                register_log_sink(&stderr_log_sink, null);
            }
        }
        else version (Posix)
        {
            import core.sys.posix.unistd : isatty, STDOUT_FILENO;
            if (!isatty(STDOUT_FILENO))
            {
                // piped - log to stderr
                register_log_sink(&stderr_log_sink, null);
            }
        }
    }
    else
        register_log_sink(&default_log_sink, null);

    Application app = create_application();
    Session active_session = null;
    SimpleSession startup_session = null;

    import urt.file : load_file;
    char[] conf = cast(char[])load_file(config_path);
    if (!conf)
    {
        import urt.string.format;
        log_error("system", "Failed to load startup configuration file: ", config_path);
        if (!interactive_mode)
            return -1;
    }
    else
    {
        startup_session = defaultAllocator().allocT!SimpleSession(g_app.console);
        startup_session.set_input(conf);
        active_session = startup_session;

        defaultAllocator().free(conf);
    }

    // stop the computer from sleeping while this application is running...
    set_system_idle_params(IdleParams.SystemRequired);

    while (true)
    {
        // update the application
        MonoTime start = getTime();
        g_app.update();

        // check to see if startup is finished...
        if (startup_session)
        {
            // SimpleSession is done when it has no active commands and no more buffered input
            if (startup_session.is_idle())
            {
                defaultAllocator().freeT(startup_session);
                startup_session = null;

                if (interactive_mode)
                    active_session = defaultAllocator().allocT!ConsoleSession(g_app.console);
                else
                    active_session = null;
            }
        }
        else if (interactive_mode && !active_session.is_attached())
            break; // exit if interactive session was closed

        // update the startup/interactive session
        if (active_session && active_session.is_attached())
            active_session.update();

        Duration frame_time = getTime() - start;

        // work out how long to sleep
        long sleep_usecs = 1000_000 / g_app.update_rate_hz;
        sleep_usecs -= frame_time.as!"usecs";
        // only sleep if we need to sleep >20us or so...
        if (sleep_usecs > 20)
            sleep(sleep_usecs.usecs);
    }

    shutdown_application();

    return 0;
}


private:

struct SeverityStyle { string badge, color; }

immutable SeverityStyle[9] severity_styles = [
    SeverityStyle("\x1b[5;1;97;101m ! \x1b[0m", "\x1b[1;91m"),  // emergency — blink bold white on bright red
    SeverityStyle("\x1b[1;97;101m A \x1b[0m",   "\x1b[91m"),    // alert — white on bright red
    SeverityStyle("\x1b[1;97;41m C \x1b[0m",    "\x1b[91m"),    // critical — bold white on red
    SeverityStyle("\x1b[97;41m E \x1b[0m",      "\x1b[31m"),    // error — white on red
    SeverityStyle("\x1b[30;43m W \x1b[0m",      "\x1b[33m"),    // warning — black on yellow
    SeverityStyle("\x1b[30;46m N \x1b[0m",      "\x1b[36m"),    // notice — black on cyan
    SeverityStyle("\x1b[7m I \x1b[0m",          "\x1b[0m"),     // info — inverse
    SeverityStyle("\x1b[97;100m D \x1b[0m",     "\x1b[90m"),    // debug — white on gray
    SeverityStyle("\x1b[3;37;100m T \x1b[0m",   "\x1b[3;90m"),  // trace — italic white on gray
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

const(char)[] format_log_line(scope ref const LogMessage msg) nothrow @nogc
{
    import urt.mem.temp : tconcat;

    auto sev = severity_styles[msg.severity];
    enum reset = "\x1b[0m";

    if (msg.tag.length > 0)
    {
        size_t h = 5381;
        foreach (c; msg.tag)
            h = h * 33 + c;
        auto tag_fg = tag_colors[h % tag_colors.length];

        // Left-justify tag in a 12-char field; minimum 1 space after tag
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

void default_log_sink(void*, scope ref const LogMessage msg) nothrow @nogc
{
    import urt.io;
    writeln(format_log_line(msg));
}

void stderr_log_sink(void*, scope ref const LogMessage msg) nothrow @nogc
{
    import core.stdc.stdio : fprintf, stderr;
    auto line = format_log_line(msg);
    fprintf(stderr, "%.*s\n", cast(int)line.length, line.ptr);
}
