module manager.log;

import urt.array;
import urt.log;
import urt.string;
import urt.variant;

import manager.console;
import manager.console.command;
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
    }
}


private:

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
