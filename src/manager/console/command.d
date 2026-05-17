module manager.console.command;

import manager;
import manager.console;
import manager.console.builtin_commands;
import manager.console.session;
import manager.expression : NamedArgument, ScriptCommand, Script, Expression, EvalContext, parse_commands;

import urt.array;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format : tconcat;
import urt.variant;


//version = ExcludeAutocomplete;
//version = ExcludeHelpText;


enum CommandCompletionState : ubyte
{
    in_progress,        ///< Command is still in progress
    cancel_requested,   ///< A cancel has been requested
    cancel_pending,     ///< Waiting for cancellation to complete

    // These are finishing states, command will stop
    finished,           ///< Command execution has finished
    cancelled,          ///< Command was aborted for some reason
    error,              ///< Command was aborted for some reason
    timeout,            ///< Command was aborted for some reason
}

class CommandState
{
nothrow @nogc:

    Session session;
    Command command;
    Variant result;

    this(Session session, Command command)
    {
        this.session = session;
        this.command = command;
    }

    CommandCompletionState update()
    {
        return CommandCompletionState.finished;
    }

    abstract void request_cancel();

    bool consumes_input() const pure
        => false;

    void receive_input(const(char)[]) {}
}


class Context : CommandState
{
nothrow @nogc:

    enum FrameKind : ubyte
    {
        block,          // :if/:while body, sub-eval [...] sub-context's siblings: propagates :return
        function_,      // :run, top-level, [...] substitution: absorbs :return into its result
    }

    Array!char source;                          // owned text buffer that owned_script[] borrows from (top-level only)
    Array!ScriptCommand owned_script;           // owned parsed commands (top-level only)
    Script held_script;                     // refcount holder for child contexts created from a Script value
    const(ScriptCommand)[] script;              // iterated view (owned_script[], held_script.commands, or borrowed from parent)
    Scope* root_scope;                          // root for /-prefixed commands
    Scope* script_scope;                        // root for :-prefixed scripting verbs
    Map!(String, Variant) owned_locals;         // backing for top-level locals
    Map!(String, Variant)* locals;              // active locals; points at own, session, or parent's
    FrameKind frame_kind = FrameKind.block;     // determines whether :return propagates or absorbs here

    enum State : ubyte
    {
        next_stmt,
        resolving_subs,
        awaiting_sub,
        dispatching,
        awaiting_result,
        done,
    }

    this(Session session, Scope* root_scope, Scope* script_scope, Array!char source, Array!ScriptCommand script)
    {
        super(session, null);
        this.root_scope = root_scope;
        this.script_scope = script_scope;
        this.source = source.move;
        this.owned_script = script.move;
        this.script = this.owned_script[];
        this.locals = (session !is null) ? &session._session_locals : &this.owned_locals;
        this.frame_kind = FrameKind.function_;
    }

    this(Session session, Scope* root_scope, Scope* script_scope, const(ScriptCommand)[] script, Map!(String, Variant)* locals, FrameKind frame_kind)
    {
        super(session, null);
        this.root_scope = root_scope;
        this.script_scope = script_scope;
        this.script = script;
        this.locals = locals;
        this.frame_kind = frame_kind;
    }

    this(Session session, Scope* root_scope, Scope* script_scope, ref const Script body_, Map!(String, Variant)* locals, FrameKind frame_kind)
    {
        super(session, null);
        this.root_scope = root_scope;
        this.script_scope = script_scope;
        this.held_script = body_;
        this.script = this.held_script.commands;
        this.locals = locals;
        this.frame_kind = frame_kind;
    }

    override CommandCompletionState update()
    {
        while (true)
        {
            if (session !is null && session._returning)
            {
                assert(_waiting_on is null, "in-flight child should have settled _returning before returning");
                if (frame_kind == FrameKind.function_)
                {
                    result = session._return_value.move;
                    session._returning = false;
                }
                _state = State.done;
                return CommandCompletionState.finished;
            }

            final switch (_state)
            {
                case State.next_stmt:
                    if (_stmt >= script.length)
                    {
                        _state = State.done;
                        return CommandCompletionState.finished;
                    }
                    _pending_subs.clear();
                    _sub_results.clear();
                    _sub_index = 0;
                    collect_pending_subs(script[_stmt]);
                    _state = _pending_subs.length > 0 ? State.resolving_subs : State.dispatching;
                    break;

                case State.resolving_subs:
                    if (_sub_index >= _pending_subs.length)
                    {
                        _state = State.dispatching;
                        break;
                    }
                    const(Expression)* node = _pending_subs[_sub_index];
                    _waiting_on = session._console._allocator.allocT!Context(session, root_scope, script_scope, node.cmd_list(), locals, FrameKind.function_);
                    _state = State.awaiting_sub;
                    goto case State.awaiting_sub;

                case State.awaiting_sub:
                    CommandCompletionState cs = _waiting_on.update();
                    if (cs < CommandCompletionState.finished)
                        return cs;
                    _sub_results[_pending_subs[_sub_index]] = _waiting_on.result.move;
                    session._console._allocator.freeT(_waiting_on);
                    _waiting_on = null;
                    ++_sub_index;
                    _state = State.resolving_subs;
                    break;

                case State.dispatching:
                    if (dispatch_current())
                    {
                        ++_stmt;
                        _state = State.next_stmt;
                    }
                    else
                    {
                        _state = State.awaiting_result;
                        return CommandCompletionState.in_progress;
                    }
                    break;

                case State.awaiting_result:
                    CommandCompletionState cs = _waiting_on.update();
                    if (cs < CommandCompletionState.finished)
                        return cs;
                    result = _waiting_on.result.move;
                    session._console._allocator.freeT(_waiting_on);
                    _waiting_on = null;
                    ++_stmt;
                    _state = State.next_stmt;
                    break;

                case State.done:
                    return CommandCompletionState.finished;
            }
        }
        assert(false);
    }

    override void request_cancel()
    {
        if (_waiting_on)
            _waiting_on.request_cancel();
    }

private:
    State _state = State.next_stmt;
    size_t _stmt = 0;
    CommandState _waiting_on;

    Array!(const(Expression)*) _pending_subs;
    Map!(const(Expression)*, Variant) _sub_results;
    size_t _sub_index = 0;

    bool dispatch_current()
    {
        const(ScriptCommand)* cmd = &script[_stmt];

        Scope* node;
        if (cmd.command.front_is('/'))
            node = root_scope;
        else if (cmd.command.front_is(':'))
            node = script_scope;
        else
            node = session._cur_scope;

        EvalContext ctx;
        ctx.locals = locals;
        ctx.sub_results = &_sub_results;

        Array!Variant vars;
        Array!NamedArgument named_vars;
        vars ~= Variant(cmd.command);
        foreach (ref arg; cmd.args)
            vars ~= arg.evaluate(ctx);
        foreach (ref arg; cmd.named_args)
            named_vars ~= NamedArgument(arg.name.get_str(), arg.value.evaluate(ctx));

        Variant stmt_result;
        Context saved = session._executing_context;
        session._executing_context = this;
        scope(exit) session._executing_context = saved;

        // walk path segments. descend() checks sub-scopes; on miss we fall back
        // to find_command at the current node to catch leaves. Run out of
        // segments on a pure namespace = cd into it.
        const(Variant)[] args = vars[];
        Command leaf = null;
        while (args.length > 0)
        {
            if (!args[0].isString)
                assert(false, "path segment must be an identifier");
            const(char)[] seg = args[0].asString;

            Scope* next = node.descend(seg);
            if (next is null)
            {
                const(char)[] core = seg;
                if (core.front_is('/') || core.front_is(':'))
                    core = core[1..$];

                if (core != "..")
                {
                    if (Command found = node.find_command(core))
                    {
                        leaf = found;
                        args = args[1..$];
                        break;
                    }
                    session.write_output(tconcat("Error: no command `", core, "`"), true);
                }
                else
                    session.write_output("Error: '..' used at top level", true);
                result = stmt_result.move;
                return true;
            }

            args = args[1..$];
            if (next is node)
                continue;       // lone '/' or ':' — stayed put
            node = next;
        }

        if (leaf is null)
        {
            session.set_scope(node);
            result = stmt_result.move;
            return true;
        }

        _waiting_on = leaf.execute(session, node, args, named_vars[], stmt_result);
        if (_waiting_on is null)
        {
            result = stmt_result.move;
            return true;
        }
        return false;
    }

    void collect_pending_subs(ref const ScriptCommand cmd)
    {
        foreach (ref arg; cmd.args)
            arg.gather_command_evals(_pending_subs);
        foreach (ref arg; cmd.named_args)
            arg.value.gather_command_evals(_pending_subs);
    }
}

class Command
{
nothrow @nogc:

    const String name;

    this(ref Console console, String name) nothrow @nogc
    {
        _console = &console;
        this.name = name.move;
    }

    final Application app() pure nothrow @nogc => _console.appInstance;
    final ref Console console() pure nothrow @nogc => *_console;

    abstract CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result);

    MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            MutableString!0 result = cmdLine;
            Array!String tokens = suggest(cmdLine, _scope, user_scope);
            if (tokens.empty)
                return result;
            size_t lastToken = cmdLine.length;
            while (lastToken > 0 && !is_separator(cmdLine[lastToken - 1]))
                --lastToken;
            result ~= get_completion_suffix(cmdLine[lastToken .. cmdLine.length], tokens);
            return result;
        }
    }

    Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
        => Array!String();

    version (ExcludeHelpText) {} else
    const(char)[] help(const(char)[] args) const
        => "No help available for this command.";


package:
    final NoGCAllocator allocator() => _console._allocator;
    final NoGCAllocator tempAllocator() => _console._tempAllocator;

    Console* _console;
}


nothrow @nogc:

inout(char)[] take_identifier(ref inout(char)[] s) pure
{
    if (s.length == 0)
        return s[0..0];
    if (!is_alpha(s[0]) && s[0] != '-' && s[0] != '_')
        return s[0..0];
    size_t i = 1;
    for (; i < s.length; ++i)
    {
        if (!is_alpha_numeric(s[i]) && s[i] != '-' && s[i] != '_')
            break;
    }
    inout(char)[] r = s[0 .. i];
    s = s[i .. $];
    return r;
}

bool front_is(const(char)[] s, char c) pure
{
    return s.length > 0 && s[0] == c;
}

bool front_is(const(char)[] s, const(char)[] s2) pure
{
    return s.length >= s2.length && s[0..s2.length] == s2[];
}


version (unittest):

// Run a script string against a fresh StringSession; returns the captured output and the script's result Variant.
// Output includes both `:put` writes and the auto-echo of the final result Variant (matching the prompt loop).
private void run_script(const(char)[] script_text, out MutableString!0 output, out Variant result)
{
    import manager : g_app;

    auto s = g_app.console._allocator.allocT!StringSession(g_app.console);
    scope(exit) g_app.console._allocator.freeT(s);

    // Drive the command to completion, in case it's latent.
    CommandState cmd = g_app.console.execute(s, script_text, result);
    for (int i = 0; cmd !is null && i < 1024; ++i)
    {
        auto cs = cmd.update();
        if (cs >= CommandCompletionState.finished)
        {
            result = cmd.result.move;
            g_app.console._allocator.freeT(cmd);
            cmd = null;
            break;
        }
    }
    assert(cmd is null, "command did not finish in 1024 iterations");

    // Mirror the prompt loop's auto-echo of a non-null result Variant.
    if (!result.isNull)
    {
        ptrdiff_t l = result.toString(null, null, null);
        if (l > 0)
        {
            Array!char buffer;
            l = result.toString(buffer.extend(l), null, null);
            s.write_line(buffer[0..l]);
        }
    }

    output = s.takeOutput();
}

unittest
{
    import manager : g_app, Application;
    import urt.mem : defaultAllocator;

    // Build a real Application for the test (sets g_app for the duration).
    auto app = defaultAllocator().allocT!Application();
    scope(exit) defaultAllocator().freeT(app);
    assert(g_app !is null);

    MutableString!0 out_;
    Variant r;

    // :set writes locals; $var reads them in the same script.
    run_script(":set x=42; :set y=$x; :put $y", out_, r);
    assert(out_[] == "42\n");

    // :if takes the then-branch when cond is truthy, else-branch otherwise.
    run_script(":if cond=1 then={ :put yes } else={ :put no }", out_, r);
    assert(out_[] == "yes\n");
    run_script(":if cond=0 then={ :put yes } else={ :put no }", out_, r);
    assert(out_[] == "no\n");

    // :run executes a script value, sharing the parent's locals.
    run_script(":set x=99; :set s={ :put $x }; :run script=$s", out_, r);
    assert(out_[] == "99\n");

    // :while loops until cond returns false; each iteration sees current locals.
    run_script(":set i=0; :while cond={ :eval ($i < 3) } do={ :put $i; :set i=($i + 1) }", out_, r);
    assert(out_[] == "0\n1\n2\n");

    // The script's last statement's result is returned via the out-param AND auto-echoed.
    run_script(":set x=10; :eval ($x * 2)", out_, r);
    assert(r.asLong == 20);
    assert(out_[] == "20\n");

    // :put produces no result Variant, so no auto-echo line follows the put output.
    run_script(":put hello", out_, r);
    assert(r.isNull);
    assert(out_[] == "hello\n");

    // :return unwinds the enclosing function frame, setting its result.
    run_script(":return 42", out_, r);
    assert(r.asLong == 42);
    assert(out_[] == "42\n");

    // :return propagates through :if (block frame) up to the enclosing top-level (function frame).
    run_script(":if cond=1 then={ :return 7 }; :put unreached", out_, r);
    assert(r.asLong == 7);
    assert(out_[] == "7\n");

    // :return breaks :while early without spinning the loop further.
    run_script(":set i=0; :while cond={ :eval 1 } do={ :put $i; :return done }", out_, r);
    assert(out_[] == "0\ndone\n");

    // :return inside [...] is absorbed by the substitution (function frame), value flows out.
    run_script(":put [ :return 9 ]", out_, r);
    assert(out_[] == "9\n");

    // Session locals persist across separate Console.execute calls on the same session.
    auto s = g_app.console._allocator.allocT!StringSession(g_app.console);
    scope(exit) g_app.console._allocator.freeT(s);
    g_app.console.execute(s, ":set x=42", r);
    g_app.console.execute(s, ":put $x", r);
    assert(s.getOutput() == "42\n");

    // :run file= reads and executes a script from disk.
    {
        import urt.file : get_temp_filename, save_file, delete_file;
        import urt.mem.temp : tconcat;
        char[256] buffer = void;
        char[] filename = buffer[];
        assert(get_temp_filename(filename, "", "owt"));
        scope(exit) filename.delete_file();
        assert(save_file(filename, ":put from-file"));
        run_script(tconcat(":run file=\"", filename, "\""), out_, r);
        assert(out_[] == "from-file\n");
    }

    // :help <name> prints meaningful text for known commands; unknown names produce an error.
    version (ExcludeHelpText) {} else
    {
        run_script(":help return", out_, r);
        assert(out_[].contains("Stop running"), "help return should mention stopping");

        run_script(":help bogus", out_, r);
        assert(out_[].contains("Unknown command"));
    }
}
