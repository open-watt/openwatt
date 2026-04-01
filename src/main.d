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
            import urt.internal.sys.windows : GetStdHandle, GetConsoleMode, STD_OUTPUT_HANDLE, DWORD;
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
            import urt.internal.sys.posix : isatty, STDOUT_FILENO;
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

    // System config: baked-in platform defaults that run before user config.
    // String-imported at compile time (no filesystem on bare-metal targets).
    version (BL808)
        static immutable system_conf = import("system.conf");
    else
        enum system_conf = "";

    import urt.file : load_file;
    char[] conf = cast(char[])load_file(config_path);

    if (system_conf.length > 0 || conf !is null)
    {
        startup_session = defaultAllocator().allocT!SimpleSession(g_app.console);

        // Feed system config first, then user config
        static if (system_conf.length > 0)
        {
            if (conf !is null)
            {
                import urt.string.format : tconcat;
                startup_session.set_input(tconcat(system_conf, "\n", conf));
                defaultAllocator().free(conf);
            }
            else
                startup_session.set_input(system_conf);
        }
        else
        {
            startup_session.set_input(conf);
            defaultAllocator().free(conf);
        }

        active_session = startup_session;
    }
    else
    {
        log_error("system", "Failed to load startup configuration file: ", config_path);
        if (!interactive_mode)
            return -1;
    }

    // stop the computer from sleeping while this application is running...
    set_system_idle_params(IdleParams.system_required);

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

                version (BL808)
                {
                    // Bind a SerialSession to the "console" stream created by system.conf
                    import manager : get_module;
                    import router.stream : StreamModule;

                    if (auto stream = get_module!StreamModule.streams.get("console"))
                        active_session = defaultAllocator().allocT!SerialSession(g_app.console, stream, ClientFeatures.ansi);
                    else
                        log_error("system", "No 'console' stream — serial console unavailable");
                }
                else if (interactive_mode)
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
    auto line = format_log_line(msg);
    version (FreeStanding)
    {} // TODO: redirect to UART
    else
    {
        import urt.io;
        writeln_err(line);
    }
}
