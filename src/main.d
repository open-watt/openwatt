module main;

import urt.log;
import urt.mem.allocator;
import urt.system;
import urt.time;

import manager;
import manager.console.session;
import manager.log : format_log_line;

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
