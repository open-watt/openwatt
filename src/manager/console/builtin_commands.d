module manager.console.builtin_commands;

import urt.array;
import urt.file : load_file;
import urt.mem;
import urt.string;
import urt.string.format : tconcat;
import urt.variant;

import manager.console;
import manager.console.command;
import manager.expression : NamedArgument, ScriptBody, is_truthy, make_script;

nothrow @nogc:


class ExitCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"exit");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        session.close_session();
        return null;
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Terminate the console session.\nUsage: :exit";
}


version (ExcludeHelpText) {} else
class HelpCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"help");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length == 0)
        {
            session.write_output("Available commands:", true);
            list_scope(session, _console.script_scope, ':');
            list_scope(session, _console.root, '/');
            session.write_output("Type `:help <name>` for details on a specific command.", true);
            return null;
        }

        if (!args[0].isString)
        {
            session.write_output("Usage: :help [command]", true);
            return null;
        }

        const(char)[] name = args[0].asString;
        Command cmd;
        if (name.front_is(':'))
            cmd = _console.script_scope.find_command(name[1 .. $]);
        else if (name.front_is('/'))
            cmd = _console.root.find_command(name[1 .. $]);
        else
        {
            if (session._cur_scope !is null)
                cmd = session._cur_scope.find_command(name);
            if (cmd is null)
                cmd = _console.script_scope.find_command(name);
            if (cmd is null && session._cur_scope !is _console.root)
                cmd = _console.root.find_command(name);
        }
        if (cmd is null)
        {
            session.write_output(tconcat("Unknown command: `", name, "`"), true);
            return null;
        }
        session.write_output(cmd.help(null), true);
        return null;
    }

    override Array!String suggest(const(char)[] cmdLine, Scope*, Scope* user_scope = null)
    {
        size_t lastToken = cmdLine.length;
        while (lastToken > 0 && !is_separator(cmdLine[lastToken - 1]))
            --lastToken;
        foreach (c; cmdLine[0 .. lastToken])
            if (!is_separator(c))
                return Array!String();
        const(char)[] arg = cmdLine[lastToken .. $];

        Array!String r;
        if (arg.front_is(':'))
            list_matching(r, _console.script_scope, arg[1 .. $], ':');
        else if (arg.front_is('/'))
            list_matching(r, _console.root, arg[1 .. $], '/');
        else if (user_scope !is null)
            list_matching(r, user_scope, arg, '\0');
        return r;
    }

    override const(char)[] help(const(char)[] args) const
        => "Print help text for console commands. With no argument, lists\n"
         ~ "all available commands.\n"
         ~ "Usage: :help [command]";

private:
    void list_scope(Session session, Scope* s, char prefix)
    {
        foreach (ref Scope sub; s.sub_scopes)
            session.write_output(tconcat("  ", prefix, sub.name[]), true);
        foreach (Command c; s.commands)
            session.write_output(tconcat("  ", prefix, c.name[]), true);
    }

    static void list_matching(ref Array!String r, Scope* s, const(char)[] partial, char prefix)
    {
        foreach (ref Scope sub; s.sub_scopes)
        {
            if (!sub.name[].startsWith(partial))
                continue;
            if (prefix)
                r ~= String(MutableString!0(Concat, prefix, sub.name));
            else
                r ~= sub.name;
        }
        foreach (Command c; s.commands)
        {
            if (!c.name[].startsWith(partial))
                continue;
            if (prefix)
                r ~= String(MutableString!0(Concat, prefix, c.name));
            else
                r ~= c.name;
        }
    }
}


class SetCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"set");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        Context ctx = session._executing_context;
        if (ctx is null)
        {
            session.write_output("Error: :set has no execution context", true);
            return null;
        }

        foreach (ref na; namedArgs)
        {
            if (auto p = na.name in *ctx.locals)
                *p = Variant(na.value);
            else
                (*ctx.locals)[makeString(na.name, _console._allocator)] = Variant(na.value);
        }

        return null;
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Set one or more local variables. Variables created here are\n"
         ~ "visible to the rest of the running script and to nested :if /\n"
         ~ ":while bodies.\n"
         ~ "Usage: :set name=value [name=value ...]";
}


class PutCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"put");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        Array!char buf;
        foreach (i, ref a; args)
        {
            if (i > 0)
                buf ~= ' ';
            if (a.isString)
                buf ~= a.asString;
            else
            {
                ptrdiff_t l = a.toString(null, null, null);
                if (l > 0)
                    a.toString(buf.extend(l), null, null);
            }
        }
        session.write_output(buf[], true);
        return null;
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Print one or more values, separated by spaces and followed by\n"
         ~ "a newline.\n"
         ~ "Usage: :put <value> [<value> ...]";
}


class EvalCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"eval");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length > 0)
            result = Variant(args[0]);
        return null;
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Evaluate an expression and yield its value as the script's\n"
         ~ "result. Useful for the cond= of :while.\n"
         ~ "Usage: :eval <expr>";
}


class ReturnCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"return");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length > 0)
            session._return_value = Variant(args[0]);
        else
            session._return_value = Variant(null);
        session._returning = true;
        return null;
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Stop running the current script and return <value> to whatever\n"
         ~ "called it. From inside :if or :while, this exits the surrounding\n"
         ~ "script too.\n"
         ~ "Usage: :return [<value>]";
}


class RunCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"run");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        Context parent = session._executing_context;
        if (parent is null)
            return null;

        ScriptBody body_;
        foreach (ref na; namedArgs)
        {
            if (na.name == "file" && na.value.isString)
            {
                const(char)[] path = na.value.asString;
                void[] buf = load_file(path);
                if (buf is null)
                {
                    session.write_output(tconcat("Error: cannot read `", path, "`"), true);
                    return null;
                }
                body_ = make_script(cast(const(char)[])buf);
                defaultAllocator().free(buf);
                break;
            }
        }

        if (body_.empty)
            body_ = find_script(args, namedArgs, "script");

        if (body_.empty)
        {
            session.write_output("Error: :run requires script= or file=", true);
            return null;
        }

        return _console._allocator.allocT!Context(
            session, parent.root_scope, parent.script_scope,
            body_, parent.locals, Context.FrameKind.function_);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Execute a script value, or load and execute a script file from\n"
         ~ "disk.\n"
         ~ "Usage: :run script=<script-value>\n"
         ~ "       :run file=<path>";
}


class IfCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"if");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        Context parent = session._executing_context;
        if (parent is null)
            return null;

        bool cond = false;
        foreach (ref na; namedArgs)
        {
            if (na.name == "cond")
            {
                cond = is_truthy(na.value);
                break;
            }
        }

        ScriptBody chosen = cond ? find_script_named(namedArgs, "then") : find_script_named(namedArgs, "else");
        if (chosen.empty)
            return null;

        return _console._allocator.allocT!Context(session, parent.root_scope, parent.script_scope, chosen, parent.locals, Context.FrameKind.block);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Run the then-branch if cond is truthy; otherwise run the\n"
         ~ "else-branch (if given).\n"
         ~ "Usage: :if cond=<value> then={ ... } [else={ ... }]";
}


class WhileCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"while");
    }

    override CommandState execute(Session session, Scope*, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        Context parent = session._executing_context;
        if (parent is null)
            return null;

        ScriptBody cond_body = find_script_named(namedArgs, "cond");
        ScriptBody do_body = find_script_named(namedArgs, "do");

        if (cond_body.empty || do_body.empty)
        {
            session.write_output("Error: :while requires cond=<script> and do=<script>", true);
            return null;
        }

        return _console._allocator.allocT!WhileLoopState(session, parent, cond_body, do_body);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Repeat the do-block while cond returns truthy. Use :return to\n"
         ~ "break out early.\n"
         ~ "Usage: :while cond={ ... } do={ ... }";
}


// Drives a `:while` loop: alternates between the cond script and the do script.
class WhileLoopState : CommandState
{
nothrow @nogc:

    this(Session session, Context parent, ref ScriptBody cond_body, ref ScriptBody do_body)
    {
        super(session, null);
        this.parent = parent;
        this.cond_body = cond_body;
        this.do_body = do_body;
    }

    override CommandCompletionState update()
    {
        for (;;)
        {
            if (session._returning)
            {
                // Same invariant as Context.update: children settle _returning before returning,
                // so current_iter must have already been consumed and cleared.
                assert(current_iter is null, "in-flight iter should have settled _returning before returning");
                return CommandCompletionState.finished;
            }

            if (current_iter is null)
            {
                if (_cancelled)
                    return CommandCompletionState.cancelled;
                current_iter = session._console._allocator.allocT!Context(
                    session, parent.root_scope, parent.script_scope,
                    evaluating_cond ? cond_body : do_body, parent.locals, Context.FrameKind.block);
            }

            CommandCompletionState cs = current_iter.update();
            if (cs < CommandCompletionState.finished)
                return cs;

            Variant iter_result = current_iter.result.move;
            session._console._allocator.freeT(current_iter);
            current_iter = null;

            if (evaluating_cond)
            {
                if (!is_truthy(iter_result))
                    return CommandCompletionState.finished;
                evaluating_cond = false;
            }
            else
            {
                evaluating_cond = true;
            }
        }
    }

    override void request_cancel()
    {
        _cancelled = true;
        if (current_iter)
            current_iter.request_cancel();
    }

private:
    Context parent;
    ScriptBody cond_body;
    ScriptBody do_body;
    Context current_iter;
    bool evaluating_cond = true;
    bool _cancelled = false;
}


private ScriptBody find_script(const Variant[] args, const NamedArgument[] namedArgs, const(char)[] name)
{
    if (args.length > 0 && args[0].isUser!ScriptBody)
        return ScriptBody(args[0].asUser!ScriptBody);
    return find_script_named(namedArgs, name);
}

private ScriptBody find_script_named(const NamedArgument[] namedArgs, const(char)[] name)
{
    foreach (ref na; namedArgs)
        if (na.name == name && na.value.isUser!ScriptBody)
            return ScriptBody(na.value.asUser!ScriptBody);
    return ScriptBody.init;
}


void RegisterBuiltinCommands(ref Console console)
{
    Scope* s = console.script_scope;
    console.add_command(s, console._allocator.allocT!ExitCommand(console));
    version (ExcludeHelpText) {} else
        console.add_command(s, console._allocator.allocT!HelpCommand(console));
    console.add_command(s, console._allocator.allocT!SetCommand(console));
    console.add_command(s, console._allocator.allocT!PutCommand(console));
    console.add_command(s, console._allocator.allocT!EvalCommand(console));
    console.add_command(s, console._allocator.allocT!ReturnCommand(console));
    console.add_command(s, console._allocator.allocT!RunCommand(console));
    console.add_command(s, console._allocator.allocT!IfCommand(console));
    console.add_command(s, console._allocator.allocT!WhileCommand(console));
}
