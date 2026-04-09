module main;

import urt.file : load_file;
import urt.log;
import urt.mem.allocator;
import urt.array;
import urt.string.format : tconcat;
import urt.system;
import urt.time;

import manager;
import manager.console.session;
import manager.log : format_log_line;

import router.stream : Stream;
import router.stream.console : ConsoleStream, ConsoleStreamModule;

version (Embedded) version = ImportSystemConf;

version (ESP32_S3)
    private extern(C) void ow_watchdog_feed() nothrow @nogc;

nothrow @nogc:


int main(string[] args)
{
    // parse command line arguments
    bool interactive_mode = false;
    const(char)[] config_path = "conf/startup.conf";
    for (size_t i = 1; i < args.length; ++i)
    {
        if (args[i] == "--interactive" || args[i] == "-i")
            interactive_mode = true;
        else if (args[i] == "--config" || args[i] == "-c")
        {
            if (i + 1 < args.length)
                config_path = args[++i];
        }
    }

    // route log output
    if (!interactive_mode)
    {
        register_log_sink(&default_log_sink, null);
    }
    else
    {
        // if stderr is piped away from the console output: register the sink so logs are captured
        bool stderr_redirected = false;
        version (Posix)
        {
            import urt.internal.sys.posix : isatty, STDERR_FILENO;
            stderr_redirected = !isatty(STDERR_FILENO);
        }
        version (Windows)
        {
            import urt.internal.sys.windows : GetStdHandle, GetConsoleMode, STD_ERROR_HANDLE, DWORD;
            DWORD mode;
            stderr_redirected = GetConsoleMode(GetStdHandle(STD_ERROR_HANDLE), &mode) == 0;
        }
        if (stderr_redirected)
            register_log_sink(&stderr_log_sink, null);
    }

    create_application();

    ConsoleStream console_stream;
    version (Embedded) {}
    else if (interactive_mode)
    {
        version (Posix)
        {
            import urt.internal.sys.posix : isatty, STDIN_FILENO;
            if (!isatty(STDIN_FILENO))
                interactive_mode = false;
        }
        version (Windows)
        {
            import urt.internal.sys.windows : GetStdHandle, GetConsoleMode, STD_INPUT_HANDLE, DWORD;
            DWORD mode;
            if (GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode) == 0)
                interactive_mode = false;
        }

        if (interactive_mode)
            console_stream = get_module!ConsoleStreamModule.consoles.create("console-io");
    }

    Session session = g_app.console.createSession!Session(console_stream);

    // Config layering:
    //   1. system.conf  — system defaults (string-imported on embedded, disk on desktop)
    //   2. startup.conf — regular configuration (--config overrides path)
    //   3. user.conf    — personal overrides (not committed)

    version (ImportSystemConf)
        static immutable system_conf = import("system.conf");
    else
        enum system_conf = "";

    // combine all layers
    Array!char combined_config;

    static if (system_conf.length > 0)
        combined_config ~= system_conf;
    else
    {
        char[] sys_conf = cast(char[])load_file("conf/system.conf");
        if (sys_conf !is null)
        {
            combined_config ~= sys_conf;
            combined_config ~= '\n';
            defaultAllocator().free(sys_conf);
        }
    }

    char[] conf = cast(char[])load_file(config_path);
    if (conf !is null)
    {
        combined_config ~= conf;
        combined_config ~= '\n';
        defaultAllocator().free(conf);
    }

    char[] user_conf = cast(char[])load_file("conf/user.conf");
    if (user_conf is null)
        user_conf = cast(char[])load_file("user.conf");
    if (user_conf !is null)
    {
        combined_config ~= user_conf;
        combined_config ~= '\n';
        defaultAllocator().free(user_conf);
    }

    bool startup_pending = false;
    if (combined_config.length > 0)
    {
        import urt.lifetime : move;
        session.feed_input(combined_config.move);
        startup_pending = true;
    }
    else
    {
        log_error("system", "No configuration loaded (tried system.conf, ", config_path, ", user.conf)");
        if (!interactive_mode)
            return -1;
    }

    // stop the computer from sleeping while this application is running...
    set_system_idle_params(IdleParams.system_required);

    version (Embedded)
    {
        log_info("system", "Entering main loop");
        MonoTime last_heartbeat = getTime();
    }

    while (true)
    {
        MonoTime start = getTime();
        g_app.update();

        version (ESP32_S3)
            ow_watchdog_feed();

        version (Embedded)
        {
            if ((start - last_heartbeat).as!"seconds" >= 10)
            {
                log_info("system", "Heartbeat");
                last_heartbeat = start;
            }
        }

        if (startup_pending && session.is_idle())
        {
            startup_pending = false;

            version (Embedded)
            {
                // rebind session to the serial console stream created by system.conf
                // TODO: config can create the whole session and this one goes away
                import manager : get_module;
                import router.stream : StreamModule;

                if (auto stream = get_module!StreamModule.streams.get("console"))
                {
                    session = g_app.console.createSession!Session(stream);
                    session.set_features(ClientFeatures.ansi);
                    session.show_prompt(true);
                    session.load_history(".telnet_history");
                }
                else
                    log_error("system", "No 'console' stream — serial console unavailable");
            }
            else if (interactive_mode)
            {
                session.show_prompt(true);
                session.load_history(".history");
            }
        }
        else if (!startup_pending && interactive_mode && !session.is_attached())
            break;

        if (session && session.is_attached())
            session.update();

        Duration frame_time = getTime() - start;

        long sleep_usecs = 1000_000 / g_app.update_rate_hz;
        sleep_usecs -= frame_time.as!"usecs";
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
    version (Embedded)
    {} // TODO: redirect to UART
    else
    {
        import urt.io;
        writeln_err(line);
    }
}
