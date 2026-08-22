module manager.console.builtin_commands;

import urt.array;
import urt.file : load_file;
import urt.mem;
import urt.result : StringResult;
import urt.string;
import urt.string.format : tconcat;
import urt.time;
import urt.variant;

import manager;
import manager.console;
import manager.console.command;
import manager.expression : NamedArgument, Script, is_truthy, make_script;
import manager.signal;
import manager.value : from_variant;

nothrow @nogc:


void RegisterBuiltinCommands(ref Console console)
{
    Scope* s = console.script_scope;
    console.add_command(s, Command(&exit_desc));
    version (ExcludeHelpText) {} else
        console.add_command(s, Command(&help_desc));
    console.add_command(s, Command(&set_desc));
    console.add_command(s, Command(&put_desc));
    console.add_command(s, Command(&eval_desc));
    console.add_command(s, Command(&return_desc));
    console.add_command(s, Command(&run_desc));
    console.add_command(s, Command(&if_desc));
    console.add_command(s, Command(&while_desc));
    console.add_command(s, Command(&wait_desc));
}


private:

static immutable CommandClass exit_class = {
    exec: &exit_exec,
};

static immutable CommandDesc exit_desc = {
    cls: &exit_class,
    name: StringLit!"exit",
    help_text: StringLit!("Terminate the console session.\nUsage: :exit"),
};

CommandState exit_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    session.close_session();
    return null;
}


version (ExcludeHelpText) {} else
{
    static immutable CommandClass help_class = {
        exec: &help_exec,
        suggest: &help_suggest,
    };

    static immutable CommandDesc help_desc = {
        cls: &help_class,
        name: StringLit!"help",
        help_text: StringLit!("Print help text for console commands. With no argument, lists\n"
                            ~ "all available commands.\n"
                            ~ "Usage: :help [command]"),
    };

    CommandState help_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
    {
        Console* console = session._console;

        if (args.length == 0)
        {
            session.write_output("Available commands:", true);
            list_scope(session, *console, console.script_scope, ':');
            list_scope(session, *console, console.root, '/');
            session.write_output("Type `:help <name>` for details on a specific command.", true);
            return null;
        }

        if (!args[0].isString)
        {
            session.write_output("Usage: :help [command]", true);
            return null;
        }

        const(char)[] name = args[0].asString;
        Command* cmd;
        if (name.front_is(':'))
            cmd = console.script_scope.find_command(*console, name[1 .. $]);
        else if (name.front_is('/'))
            cmd = console.root.find_command(*console, name[1 .. $]);
        else
        {
            if (session._cur_scope !is null)
                cmd = session._cur_scope.find_command(*console, name);
            if (cmd is null)
                cmd = console.script_scope.find_command(*console, name);
            if (cmd is null && session._cur_scope !is console.root)
                cmd = console.root.find_command(*console, name);
        }
        if (cmd is null)
        {
            session.write_output(tconcat("Unknown command: `", name, "`"), true);
            return null;
        }
        session.write_output(cmd.help(null), true);
        return null;
    }

    Array!String help_suggest(ref Command, ref Console console, const(char)[] cmd_line, Scope*, Scope* user_scope)
    {
        size_t lastToken = cmd_line.length;
        while (lastToken > 0 && !is_separator(cmd_line[lastToken - 1]))
            --lastToken;
        foreach (c; cmd_line[0 .. lastToken])
            if (!is_separator(c))
                return Array!String();
        const(char)[] arg = cmd_line[lastToken .. $];

        Array!String r;
        if (arg.front_is(':'))
            list_matching(console, r, console.script_scope, arg[1 .. $], ':');
        else if (arg.front_is('/'))
            list_matching(console, r, console.root, arg[1 .. $], '/');
        else if (user_scope !is null)
            list_matching(console, r, user_scope, arg, '\0');
        return r;
    }

    void list_scope(Session session, ref Console console, Scope* s, char prefix)
    {
        foreach (ref Scope sub; s.sub_scopes(console))
            session.write_output(tconcat("  ", prefix, sub.name[]), true);
        foreach (ref Command c; s.commands(console))
            session.write_output(tconcat("  ", prefix, c.name[]), true);
    }

    void list_matching(ref Console console, ref Array!String r, Scope* s, const(char)[] partial, char prefix)
    {
        foreach (ref Scope sub; s.sub_scopes(console))
        {
            if (!sub.name[].startsWith(partial))
                continue;
            if (prefix)
                r ~= String(MutableString!0(Concat, prefix, sub.name));
            else
                r ~= String(MutableString!0(sub.name));
        }
        foreach (ref Command c; s.commands(console))
        {
            if (!c.name[].startsWith(partial))
                continue;
            if (prefix)
                r ~= String(MutableString!0(Concat, prefix, c.name));
            else
                r ~= String(MutableString!0(c.name));
        }
    }
}


static immutable CommandClass set_class = {
    exec: &set_exec,
};

static immutable CommandDesc set_desc = {
    cls: &set_class,
    name: StringLit!"set",
    help_text: StringLit!("Set one or more local variables. Variables created here are\n"
             ~ "visible to the rest of the running script and to nested :if /\n"
             ~ ":while bodies.\n"
             ~ "Usage: :set name=value [name=value ...]"),
};

CommandState set_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    Context ctx = session._executing_context;
    if (ctx is null)
    {
        session.write_output("Error: :set has no execution context", true);
        return null;
    }

    foreach (ref na; named_args)
    {
        if (auto p = na.name in *ctx.locals)
            *p = Variant(na.value);
        else
            (*ctx.locals)[makeString(na.name, session._console._allocator)] = Variant(na.value);
    }

    return null;
}


static immutable CommandClass put_class = {
    exec: &put_exec,
};

static immutable CommandDesc put_desc = {
    cls: &put_class,
    name: StringLit!"put",
    help_text: StringLit!("Print one or more values, separated by spaces and followed by\n"
             ~ "a newline.\n"
             ~ "Usage: :put <value> [<value> ...]"),
};

CommandState put_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
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


static immutable CommandClass eval_class = {
    exec: &eval_exec,
};

static immutable CommandDesc eval_desc = {
    cls: &eval_class,
    name: StringLit!"eval",
    help_text: StringLit!("Evaluate an expression and yield its value as the script's\n"
             ~ "result. Useful for the cond= of :while.\n"
             ~ "Usage: :eval <expr>"),
};

CommandState eval_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    if (args.length > 0)
        result = Variant(args[0]);
    return null;
}


static immutable CommandClass return_class = {
    exec: &return_exec,
};

static immutable CommandDesc return_desc = {
    cls: &return_class,
    name: StringLit!"return",
    help_text: StringLit!("Stop running the current script and return <value> to whatever\n"
             ~ "called it. From inside :if or :while, this exits the surrounding\n"
             ~ "script too.\n"
             ~ "Usage: :return [<value>]"),
};

CommandState return_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    if (args.length > 0)
        session._return_value = Variant(args[0]);
    else
        session._return_value = Variant(null);
    session._returning = true;
    return null;
}


static immutable CommandClass run_class = {
    exec: &run_exec,
};

static immutable CommandDesc run_desc = {
    cls: &run_class,
    name: StringLit!"run",
    help_text: StringLit!("Execute a script value, or load and execute a script file from\n"
             ~ "disk.\n"
             ~ "Usage: :run script=<script-value>\n"
             ~ "       :run file=<path>"),
};

CommandState run_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    Context parent = session._executing_context;
    if (parent is null)
        return null;

    Script body_;
    foreach (ref na; named_args)
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
        body_ = find_script(args, named_args, "script");

    if (body_.empty)
    {
        session.write_output("Error: :run requires script= or file=", true);
        return null;
    }

    return session._console._allocator.allocT!Context(
        session, parent.root_scope, parent.script_scope,
        body_, parent.locals, Context.FrameKind.function_);
}


static immutable CommandClass if_class = {
    exec: &if_exec,
};

static immutable CommandDesc if_desc = {
    cls: &if_class,
    name: StringLit!"if",
    help_text: StringLit!("Run the then-branch if cond is truthy; otherwise run the\n"
             ~ "else-branch (if given).\n"
             ~ "Usage: :if cond=<value> then={ ... } [else={ ... }]"),
};

CommandState if_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    Context parent = session._executing_context;
    if (parent is null)
        return null;

    bool cond = false;
    foreach (ref na; named_args)
    {
        if (na.name == "cond")
        {
            cond = is_truthy(na.value);
            break;
        }
    }

    Script chosen = cond ? find_script_named(named_args, "then") : find_script_named(named_args, "else");
    if (chosen.empty)
        return null;

    return session._console._allocator.allocT!Context(session, parent.root_scope, parent.script_scope, chosen, parent.locals, Context.FrameKind.block);
}


static immutable CommandClass while_class = {
    exec: &while_exec,
};

static immutable CommandDesc while_desc = {
    cls: &while_class,
    name: StringLit!"while",
    help_text: StringLit!("Repeat the do-block while cond returns truthy. Use :return to\n"
             ~ "break out early.\n"
             ~ "Usage: :while cond={ ... } do={ ... }"),
};

CommandState while_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    Context parent = session._executing_context;
    if (parent is null)
        return null;

    Script cond_body = find_script_named(named_args, "cond");
    Script do_body = find_script_named(named_args, "do");

    if (cond_body.empty || do_body.empty)
    {
        session.write_output("Error: :while requires cond=<script> and do=<script>", true);
        return null;
    }

    return session._console._allocator.allocT!WhileLoopState(session, parent, cond_body, do_body);
}


// Drives a `:while` loop: alternates between the cond script and the do script.
class WhileLoopState : CommandState
{
nothrow @nogc:

    this(Session session, Context parent, ref const Script cond_body, ref const Script do_body)
    {
        super(session);
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
    Script cond_body;
    Script do_body;
    Context current_iter;
    bool evaluating_cond = true;
    bool _cancelled = false;
}


static immutable CommandClass wait_class = {
    exec: &wait_exec,
};

static immutable CommandDesc wait_desc = {
    cls: &wait_class,
    name: StringLit!"wait",
    help_text: StringLit!("Wait for a registered signal while the main loop continues to run.\n"
             ~ "The optional timeout is implemented through the time signal provider.\n"
             ~ "Usage: :wait on=<signal-uri> [timeout=<duration>]"),
};

CommandState wait_exec(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    const(char)[] signal;
    Duration timeout;
    foreach (ref argument; named_args)
    {
        if (argument.name == "on")
        {
            if (!argument.value.isString)
            {
                session.write_output("Error: :wait on= must be a signal URI", true);
                return null;
            }
            signal = argument.value.asString;
        }
        else if (argument.name == "timeout")
        {
            if (const(char)[] error = from_variant(argument.value, timeout))
            {
                session.write_output(tconcat("Error: ", error), true);
                return null;
            }
        }
        else
        {
            session.write_output(tconcat("Error: unknown :wait argument: ", argument.name), true);
            return null;
        }
    }

    if (args.length != 0 || signal.length == 0 || timeout < Duration.zero)
    {
        session.write_output("Usage: :wait on=<signal-uri> [timeout=<duration>]", true);
        return null;
    }

    WaitCommandState state = session._console._allocator.allocT!WaitCommandState(session, signal, timeout);
    StringResult started = state.start();
    if (!started)
    {
        session.write_output(tconcat("Error: ", started.message), true);
        session._console._allocator.freeT(state);
        return null;
    }
    return state;
}


class WaitCommandState : CommandState
{
nothrow @nogc:

    this(Session session, const(char)[] signal, Duration timeout)
    {
        super(session);
        _signal_uri = signal.makeString(g_app.allocator);
        _timeout = timeout;
    }

    StringResult start()
    {
        SignalUri uri;
        StringResult parsed = parse_signal_uri(_signal_uri[], uri);
        if (!parsed)
            return parsed;
        ISignalProvider provider = g_app.find_signal_provider(uri.scheme);
        if (!provider)
            return StringResult(tconcat("unknown signal provider: ", uri.scheme));
        StringResult subscribed = provider.subscribe(uri, &on_signal, _signal);
        if (!subscribed)
            return subscribed;

        if (_timeout > Duration.zero)
        {
            const(char)[] timeout_uri = tconcat("every:", _timeout, "?repeat=false");
            parsed = parse_signal_uri(timeout_uri, uri);
            if (!parsed)
            {
                cleanup();
                return parsed;
            }
            provider = g_app.find_signal_provider(uri.scheme);
            if (!provider)
            {
                cleanup();
                return StringResult("time signal provider is unavailable");
            }
            subscribed = provider.subscribe(uri, &on_timeout, _timeout_signal);
            if (!subscribed)
            {
                cleanup();
                return subscribed;
            }
        }
        return StringResult.success;
    }

    override CommandCompletionState update()
    {
        if (_cancelled)
        {
            cleanup();
            return CommandCompletionState.cancelled;
        }
        if (_timed_out)
        {
            cleanup();
            result = Variant(false);
            return CommandCompletionState.timeout;
        }
        if (_fired)
        {
            cleanup();
            result = Variant(true);
            return CommandCompletionState.finished;
        }
        return CommandCompletionState.in_progress;
    }

    override void request_cancel()
    {
        _cancelled = true;
    }

private:
    String _signal_uri;
    Duration _timeout;
    SignalSub _signal;
    SignalSub _timeout_signal;
    bool _fired;
    bool _timed_out;
    bool _cancelled;

    void on_signal(MonoTime, ref const SignalEvent)
    {
        _fired = true;
    }

    void on_timeout(MonoTime, ref const SignalEvent)
    {
        _timed_out = true;
    }

    void cleanup()
    {
        if (_signal)
        {
            _signal.provider.unsubscribe(_signal);
            _signal = null;
        }
        if (_timeout_signal)
        {
            _timeout_signal.provider.unsubscribe(_timeout_signal);
            _timeout_signal = null;
        }
    }
}


Script find_script(const Variant[] args, const NamedArgument[] namedArgs, const(char)[] name)
{
    if (args.length > 0 && args[0].isUser!Script)
        return Script(args[0].asUser!Script);
    return find_script_named(namedArgs, name);
}

Script find_script_named(const NamedArgument[] namedArgs, const(char)[] name)
{
    foreach (ref na; namedArgs)
        if (na.name == name && na.value.isUser!Script)
            return Script(na.value.asUser!Script);
    return Script.init;
}
