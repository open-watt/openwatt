module main;

import urt.file : load_file;
import urt.log;
import urt.mem.allocator;
import urt.array;
import urt.string.format : tconcat;
import urt.system;
import urt.time;

import manager;
import manager.bootguard;
import manager.collection;
import manager.console.session : Session, default_console_session_name;
import manager.log : default_log_sink_name, format_log_text,
                     retire_bootstrap_log_sink, set_bootstrap_log_sink;

import driver.watchdog;

import driver.system : reboot_pending;

version (Embedded) version = ImportSystemConf;

version (Windows)    version = SoftwareWatchdogFeed;
else version (linux) version = SoftwareWatchdogFeed;

nothrow @nogc:


int main(string[] args)
{
    version (linux)
    {
        import driver.linux.system : ignore_sigpipe;
        ignore_sigpipe();

        foreach (a; args.length > 1 ? args[1 .. $] : null)
        {
            if (a == "--supervise")
            {
                import driver.linux.supervisor : run_supervisor;
                return run_supervisor(args);
            }
        }
    }

    // parse command line arguments
    bool interactive_mode = false;
    const(char)[] config_path = "conf/startup.conf";
    bool config_path_explicit = false;
    const(char)[] profile_path;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (args[i] == "--interactive" || args[i] == "-i")
            interactive_mode = true;
        else if (args[i] == "--config" || args[i] == "-c")
        {
            if (i + 1 < args.length)
            {
                config_path = args[++i];
                config_path_explicit = true;
            }
        }
        else if (args[i] == "--profile-path")
        {
            if (i + 1 < args.length)
                profile_path = args[++i];
        }
    }

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
    }

    bool stderr_redirected;
    version (Embedded) {}
    else if (interactive_mode)
    {
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
    }

    // This sink exists before the command system does. The startup commands
    // replace it with managed streams and sinks as soon as they can.
    version (Embedded)
        set_bootstrap_log_sink(register_log_sink(&default_log_sink, null));
    else if (!interactive_mode || stderr_redirected)
        set_bootstrap_log_sink(register_log_sink(&stderr_log_sink, null));

    create_application();
    if (profile_path && !g_app.override_profile_path(profile_path))
    {
        log_error("system", "Invalid profile path override: ", profile_path);
        return -1;
    }

    version (SoftwareWatchdogFeed)
    {
        watchdog_set_feed_request(() {
            g_app.post_event((MonoTime) { watchdog_feed(); }, getTime(), EventPriority.control);
        });
    }
    else
        g_app.register_heartbeat_handler((MonoTime) { watchdog_feed(); });

    watchdog_init(5.seconds);

    Session startup_session = g_app.console.createSession!Session();

    // Config layering:
    //   1. process defaults - generated CLI commands
    //   2. system.conf      - the platform itself; always applies
    //   3. default.conf     - bring-up state, used only when there is no startup.conf
    //      or startup.conf  - regular configuration (--config overrides path)
    //   4. user.conf        - personal overrides
    //   5. process session  - generated CLI commands

    version (ImportSystemConf)
        static immutable system_conf = import("system.conf");
    else
        enum system_conf = "";

    // Not every platform has split its bring-up state out yet.
    static if (__traits(compiles, import("default.conf")))
        static immutable default_conf = import("default.conf");
    else
        enum default_conf = "";

    // combine all layers
    Array!char combined_config;
    bool loaded_configuration;

    version (Embedded) {}
    else
    {
        append_process_defaults(combined_config, !interactive_mode || stderr_redirected);
        if (interactive_mode)
            append_interactive_session_defaults(combined_config);
    }

    // An explicit --config is a human decision and is not second-guessed.
    bool trust_config = true;
    if (!config_path_explicit && !boot_config_trusted())
    {
        trust_config = false;
        retire_config(config_path);
    }
    char[] conf = trust_config ? cast(char[])load_file(config_path) : null;

    if (conf is null && config_path_explicit)
        log_error("system", "config '", config_path, "' could not be loaded");

    static if (system_conf.length > 0)
    {
        combined_config ~= system_conf;
        combined_config ~= '\n';
        loaded_configuration = true;
    }
    else
    {
        char[] sys_conf = cast(char[])load_file("conf/system.conf");
        if (sys_conf !is null)
        {
            combined_config ~= sys_conf;
            combined_config ~= '\n';
            defaultAllocator().free(sys_conf);
            loaded_configuration = true;
        }
    }

    if (conf !is null)
    {
        static if (default_conf.length > 0)
            log_info("system", "using startup.conf from the filesystem; bring-up defaults skipped");
        combined_config ~= conf;
        combined_config ~= '\n';
        defaultAllocator().free(conf);
        loaded_configuration = true;
    }
    else if (!config_path_explicit)
    {
        static if (default_conf.length > 0)
        {
            combined_config ~= default_conf;
            combined_config ~= '\n';
            loaded_configuration = true;
        }
    }

    char[] user_conf = cast(char[])load_file("conf/user.conf");
    if (user_conf is null)
        user_conf = cast(char[])load_file("user.conf");
    if (user_conf !is null)
    {
        combined_config ~= user_conf;
        combined_config ~= '\n';
        defaultAllocator().free(user_conf);
        loaded_configuration = true;
    }

    version (Embedded) {}
    else if (interactive_mode)
        activate_interactive_session(combined_config);

    if (!loaded_configuration)
    {
        log_error("system", "No configuration loaded (tried system.conf, ", config_path, ", user.conf)");
        if (!interactive_mode)
            return -1;
    }

    bool startup_pending = false;
    if (combined_config.length > 0)
    {
        import urt.lifetime : move;
        if (!g_app.console.execute_script(startup_session, combined_config.move))
            return -1;
        startup_pending = !startup_session.is_idle();
    }

    // stop the computer from sleeping while this application is running...
    set_system_idle_params(IdleParams.system_required);

    version (Embedded)
        log_info("system", "Entering main loop");

    ObjectRef!Session interactive_session;
    bool keep_running = true;
    int exit_code;

    if (!startup_pending)
    {
        finish_startup(startup_session, interactive_mode, interactive_session);
        if (interactive_mode && !interactive_session)
        {
            log_error("system", "Interactive console session failed to start");
            keep_running = false;
            exit_code = -1;
        }
    }

    while (keep_running)
    {
        boot_guard_update();

        // handle any expired timers (heartbeat-driven update() lives in here).
        MonoTime next_deadline = g_app.process_due();

        if (reboot_pending())
            break;

        if (startup_pending && startup_session.is_idle())
        {
            startup_pending = false;
            finish_startup(startup_session, interactive_mode, interactive_session);
            if (interactive_mode && !interactive_session)
            {
                log_error("system", "Interactive console session failed to start");
                exit_code = -1;
                break;
            }
        }
        else if (!startup_pending && interactive_mode &&
                 (!interactive_session || !interactive_session.attached()))
            break;

        // sleep until either the next timer deadline or an event fires.
        g_app.wait_for_wake(next_deadline);
        g_app.process_events();
    }

    watchdog_stop();

    shutdown_application();

    if (reboot_pending())
    {
        version (linux)
        {
            import driver.linux.system : exit_restart;
            return exit_restart;
        }
    }

    return exit_code;
}


private:

void append_process_defaults(ref Array!char config, bool log_enabled)
{
    config ~= "/stream/console/add name=stderr input=none output=stderr\n";
    config ~= "/log/sink/add name=";
    config ~= default_log_sink_name;
    config ~= " stream=stderr format=text max-severity=info";
    if (!log_enabled)
        config ~= " disabled=true";
    config ~= '\n';
}

void append_interactive_session_defaults(ref Array!char config)
{
    config ~= "/stream/console/add name=stdio input=stdin output=stdout\n";
    config ~= "/console/session/add name=";
    config ~= default_console_session_name;
    version (Windows)
        config ~= " stream=stdio profile=windows history=.history disabled=true\n";
    else
        config ~= " stream=stdio profile=ansi history=.history disabled=true\n";
}

void activate_interactive_session(ref Array!char config)
{
    config ~= "/console/session/set ";
    config ~= default_console_session_name;
    config ~= " disabled=false\n";
}

void finish_startup(ref Session startup_session, bool interactive_mode, ref ObjectRef!Session interactive_session)
{
    g_app.console.destroy_session(startup_session);
    startup_session = null;
    retire_bootstrap_log_sink();

    if (interactive_mode)
        interactive_session = Collection!Session().get(default_console_session_name);
}

void default_log_sink(void*, scope ref const LogMessage msg) nothrow @nogc
{
    import urt.io;
    writeln(format_log_text(msg));
    flush();
}

void stderr_log_sink(void*, scope ref const LogMessage msg) nothrow @nogc
{
    auto line = format_log_text(msg);
    version (Embedded)
    {}
    else
    {
        import urt.io;
        writeln_err(line);
    }
}
