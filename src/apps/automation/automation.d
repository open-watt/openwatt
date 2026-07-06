module apps.automation.automation;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.result : StringResult;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.console;
import manager.console.command;
import manager.console.session;
import manager.expression : Script, Expression, EvalContext, parse_expression, free_expression, is_truthy;
import manager.signal;

nothrow @nogc:


class Automation : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("on", on),
                                 Prop!("schedule", schedule),
                                 Prop!("at", at),
                                 Prop!("when", when),
                                 Prop!("if", condition),
                                 Prop!("do", script),
                                 Prop!("last_run", last_run),
                                 Prop!("next_run", next_run),
                                 Prop!("run_count", run_count));
@nogc nothrow:

    enum type_name = "automation";
    enum path = "/automation";
    enum collection_id = CollectionType.automation;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Automation, id, flags);
    }

    const(char)[][] on() const
    {
        size_t n = _signal_uris.length + (_time.length ? 1 : 0);
        auto buf = tempAllocator().allocArray!(const(char)[])(n);
        size_t i = 0;
        foreach (ref u; _signal_uris)
            buf[i++] = u[];
        if (_time.length)
            buf[i++] = _time[];
        return buf;
    }
    const(char)[] on(const(char)[][] value...)
    {
        foreach (uri; value)
        {
            StringResult err = check_uri(uri);
            if (!err)
                return err.message;
        }

        _signal_uris.clear();
        foreach (uri; value)
            _signal_uris ~= uri.makeString(g_app.allocator);
        _time = String();   // an explicit on= is the full trigger set, sugar included
        restart();
        return null;
    }

    // schedule/at/when are thin write-only shorthands for the matching on= URIs; finer detail
    // (weekday masks, one-shot via ?repeat=false, ...) is expressed with the URI form directly.
    void schedule(Duration value) { set_time(tconcat("every:", value)); }
    void at(TimeOfDay value)      { set_time(tconcat("at:", value)); }
    void when(SysTime value)      { set_time(tconcat("when:", value)); }

    const(char)[] condition() const { return _condition[]; }
    const(char)[] condition(const(char)[] value)
    {
        if (value.length)
        {
            const(char)[] cursor = value;
            Expression* e;
            try
                e = parse_expression(cursor);
            catch (Exception)
                return "invalid condition expression";
            const bool ok = e !is null && cursor.length == 0;
            if (e)
                free_expression(e);
            if (!ok)
                return "invalid condition expression";
        }
        _condition = value.makeString(g_app.allocator);
        restart();
        return null;
    }

    Script script() const { return Script(_script); }
    const(char)[] script(Script value)
    {
        if (value.empty)
            return "action cannot be empty";
        _script = value;
        return null;
    }

    SysTime last_run() const { return _last_run; }
    uint run_count() const { return _run_count; }

    SysTime next_run()
    {
        SysTime best;
        foreach (sub; _signals)
        {
            SysTime n = sub.provider.next_run(sub);
            if (n != SysTime() && (best == SysTime() || n < best))
                best = n;
        }
        return best;
    }

    override const(char)[] status_message() const pure
    {
        if (_status_detail.length)
            return _status_detail[];
        return super.status_message();
    }

protected:
    override bool validate() const
    {
        // validate() is const, so the identity-attaching log.* is unavailable here.
        if (_time.length == 0 && _signal_uris.length == 0)
        {
            writeError("automation '", name, "': no trigger specified");
            return false;
        }

        if (_script.empty)
        {
            writeError("automation '", name, "': no action specified");
            return false;
        }

        if (_time.length)
        {
            StringResult e = check_uri(_time[]);
            if (!e)
            {
                writeError("automation '", name, "': ", e.message);
                return false;
            }
        }

        foreach (ref u; _signal_uris)
        {
            StringResult e = check_uri(u[]);
            if (!e)
            {
                writeError("automation '", name, "': ", e.message);
                return false;
            }
        }

        return true;
    }

    override CompletionStatus startup()
    {
        if (_condition.length && !_condition_expr)
        {
            const(char)[] cursor = _condition[];
            try
                _condition_expr = parse_expression(cursor);
            catch (Exception)
                _condition_expr = null;   // validated in the setter; a failure here just skips gating
        }

        if (_time.length)
        {
            StringResult r = subscribe_uri(_time[]);
            if (!r)
                return wait(r.message);
        }

        foreach (ref u; _signal_uris)
        {
            StringResult r = subscribe_uri(u[]);
            if (!r)
                return wait(r.message);
        }

        _status_detail = String();
        log.info("armed ", _signals.length, " signal(s)");
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        teardown_signals();
        _status_detail = String();

        if (_condition_expr)
        {
            free_expression(_condition_expr);
            _condition_expr = null;
        }

        if (_cleanup_scheduled)
        {
            g_app.cancel(&on_cleanup);
            _cleanup_scheduled = false;
        }

        foreach (ref cmd; _running_commands)
            cmd.command.request_cancel();

        update_running_commands();

        if (_running_commands.length > 0)
        {
            schedule_cleanup();
            return CompletionStatus.continue_;
        }

        return CompletionStatus.complete;
    }

private:
    struct RunningCommand
    {
        Session session;
        CommandState command;
    }

    Array!String _signal_uris;   // on= triggers
    String _time;                // the time sugar's translated URI (schedule=/at=/when=), or empty
    Array!SignalSub _signals;

    String _condition;           // if= source expression
    Expression* _condition_expr; // parsed from _condition at startup

    Script _script;

    SysTime _last_run;
    uint _run_count;

    String _status_detail;       // while Starting: why the rule can't arm yet

    Array!RunningCommand _running_commands;
    bool _cleanup_scheduled;

    void fire(MonoTime when, ref const SignalEvent ev)
    {
        if (_condition_expr && !condition_holds())
            return;

        _last_run = getSysTime();
        ++_run_count;

        execute_action(ev);

        if (_running_commands.length > 0)
            schedule_cleanup();
    }

    bool condition_holds()
    {
        EvalContext ctx = { null, null, null };
        Variant v = _condition_expr.evaluate(ctx);
        return is_truthy(v);
    }

    void teardown_signals()
    {
        foreach (sub; _signals)
            sub.provider.unsubscribe(sub);
        _signals.clear();
    }

    CompletionStatus wait(const(char)[] reason)
    {
        teardown_signals();
        if (_status_detail[] != reason)
        {
            _status_detail = reason.makeString(g_app.allocator);
            log.info("waiting: ", reason);
        }
        return CompletionStatus.continue_;
    }

    StringResult check_uri(const(char)[] uri) const
    {
        SignalUri su;
        StringResult e = parse_signal_uri(uri, su);
        if (!e)
            return e;
        ISignalProvider p = g_app.find_signal_provider(su.scheme);
        if (!p)
            return StringResult(tconcat("unknown signal provider: ", su.scheme));
        return p.validate(su);
    }

    StringResult subscribe_uri(const(char)[] uri)
    {
        SignalUri su;
        StringResult e = parse_signal_uri(uri, su);
        if (!e)
            return e;
        ISignalProvider p = g_app.find_signal_provider(su.scheme);
        if (!p)
            return StringResult(tconcat("unknown signal provider: ", su.scheme));
        SignalSub h;
        StringResult r = p.subscribe(su, &fire, h);
        if (r)
            _signals ~= h;
        return r;
    }

    void set_time(const(char)[] uri)
    {
        if (_time[] == uri)
            return;
        _time = uri.makeString(g_app.allocator);
        restart();
    }

    void schedule_cleanup()
    {
        if (_cleanup_scheduled)
            return;
        g_app.schedule(getTime() + msecs(50), &on_cleanup);
        _cleanup_scheduled = true;
    }

    void on_cleanup(MonoTime scheduled)
    {
        _cleanup_scheduled = false;
        update_running_commands();
        if (_running_commands.length > 0)
            schedule_cleanup();
    }

    void update_running_commands()
    {
        for (size_t i = 0; i < _running_commands.length; )
        {
            RunningCommand* cmd = &_running_commands[i];
            CommandCompletionState state = cmd.command.update();
            if (state >= CommandCompletionState.finished)
            {
                g_app.allocator.freeT(cmd.session);
                _running_commands.remove(i);
            }
            else
                ++i;
        }
    }

    void execute_action(ref const SignalEvent ev)
    {
        log.info("executing action: ", _script.source);

        Variant result;
        Session session = g_app.allocator.allocT!Session(g_app.console);
        session.set_local("value", ev.value);   // $value = the datum that fired (element snapshot; null for time)

        CommandState command = g_app.console.execute(session, _script, result);

        if (command)
            _running_commands ~= RunningCommand(session, command);
        else
            g_app.allocator.freeT(session);
    }
}
