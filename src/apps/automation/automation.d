module apps.automation.automation;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.result : StringResult;
import urt.si.quantity : PerSecond;
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


enum Edge : ubyte
{
    level,
    rising,
    falling,
}


class Automation : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("on", on),
                                 Prop!("schedule", schedule),
                                 Prop!("at", at),
                                 Prop!("when", when),
                                 Prop!("if", condition),
                                 Prop!("edge", edge),
                                 Prop!("for", hold),
                                 Prop!("do", script),
                                 Prop!("debounce", debounce),
                                 Prop!("throttle", throttle),
                                 Prop!("rate", rate),
                                 Prop!("burst", burst),
                                 Prop!("run_count", run_count, "status", "d"),
                                 Prop!("next_run", next_run, "status", "d"),
                                 Prop!("last_run", last_run, "status", "d"));
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

    // edge/for complete the condition leg: edge picks which transitions of if= fire, for requires
    // the qualifying state to hold for the window before firing (once per qualifying episode).
    // Both hot-apply; changing them resets any episode in progress.
    Edge edge() const { return _edge; }
    void edge(Edge value)
    {
        if (_edge == value)
            return;
        _edge = value;
        reset_condition_state();
    }

    Duration hold() const { return _hold; }
    const(char)[] hold(Duration value)
    {
        if (value < Duration())
            return "for must not be negative";
        if (_hold != value)
        {
            _hold = value;
            reset_condition_state();
        }
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

    // shaping properties hot-apply; they only affect how future triggers are treated
    Duration debounce() const { return _debounce; }
    const(char)[] debounce(Duration value)
    {
        if (value < Duration())
            return "debounce must not be negative";
        _debounce = value;
        return null;
    }

    Duration throttle() const { return _throttle; }
    const(char)[] throttle(Duration value)
    {
        if (value < Duration())
            return "throttle must not be negative";
        _throttle = value;
        return null;
    }

    // any per-time spelling ("12/h", "4/min", "0.2/s") converts to canonical /s at the boundary
    PerSecond rate() const { return _rate; }
    const(char)[] rate(PerSecond value)
    {
        if (value.is_nan || value.value < 0)
            return "rate must not be negative";
        _rate = value;
        _tokens = _burst;
        _tokens_stamp = getTime();
        return null;
    }

    uint burst() const { return _burst; }
    const(char)[] burst(uint value)
    {
        if (value < 1)
            return "burst must be at least 1";
        _burst = value;
        if (_tokens > value)
            _tokens = value;
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
        if (_debounce_armed)
        {
            SysTime settle = getSysTime() + (_debounce_deadline - getTime());
            if (best == SysTime() || settle < best)
                best = settle;
        }
        if (_hold_armed)
        {
            SysTime qualify = getSysTime() + (_hold_deadline - getTime());
            if (best == SysTime() || qualify < best)
                best = qualify;
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

        // without a condition there is no truth value to edge-detect or hold
        if ((_edge != Edge.level || _hold != Duration()) && _condition.length == 0)
        {
            writeError("automation '", name, "': edge=/for= require if=");
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
        _tokens = _burst;
        _tokens_stamp = getTime();

        if (_condition_expr && (_edge != Edge.level || _hold != Duration()))
        {
            // seed the tracker so an already-true condition doesn't read as an edge on arm
            _last_condition = condition_holds();
            // a level for= qualifies from state, so "open for 5m" spans a restart;
            // rising/falling qualify only from an observed transition
            if (_hold != Duration() && _edge == Edge.level && _last_condition)
            {
                SignalEvent seed;
                arm_hold(getTime(), seed);
            }
        }

        log.info("armed ", _signals.length, " signal(s)");
        if (next_run() != SysTime())
            mark_set!(typeof(this), "next_run")();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        teardown_signals();
        _status_detail = String();

        if (_debounce_armed)
        {
            g_app.cancel(&on_debounce);
            _debounce_armed = false;
        }
        _pending_value = Variant();
        _pending_source = String();
        _last_action = MonoTime();
        cancel_hold();

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

    Edge _edge;
    Duration _hold;              // for=: the qualifying state must hold this long before firing
    bool _last_condition;        // condition as last observed; seeded at arm
    bool _hold_armed;
    bool _hold_satisfied;        // episode already qualified; resets when the state drops
    MonoTime _hold_deadline;
    Variant _hold_value;         // owned snapshot of the event that began the qualifying episode
    String _hold_source;

    Script _script;

    Duration _debounce;          // trailing edge: act once the trigger stream settles
    Duration _throttle;          // leading edge: act, then lock out for the window
    PerSecond _rate;             // token bucket refill; capacity is _burst
    uint _burst = 1;
    double _tokens = 0;
    MonoTime _tokens_stamp;
    MonoTime _last_action;

    bool _debounce_armed;
    MonoTime _debounce_deadline;
    Variant _pending_value;      // owned snapshot of the latest trigger while the settle window runs
    String _pending_source;

    SysTime _last_run;
    uint _run_count;

    String _status_detail;       // while Starting: why the rule can't arm yet

    Array!RunningCommand _running_commands;
    bool _cleanup_scheduled;

    void fire(MonoTime when, ref const SignalEvent ev)
    {
        if (_debounce != Duration())
        {
            // trailing edge: hold the latest event and (re)start the settle window
            _pending_value = ev.value;
            _pending_source = ev.source.makeString(g_app.allocator);
            if (_debounce_armed)
                g_app.cancel(&on_debounce);
            _debounce_deadline = when + _debounce;
            g_app.schedule(_debounce_deadline, &on_debounce);
            _debounce_armed = true;
            return;
        }

        attempt_run(when, ev);
    }

    void on_debounce(MonoTime scheduled)
    {
        _debounce_armed = false;
        SignalEvent ev;
        ev.source = _pending_source[];
        ev.value = _pending_value.move;
        attempt_run(scheduled, ev);
        _pending_source = String();
    }

    void attempt_run(MonoTime when, ref const SignalEvent ev)
    {
        if (_edge == Edge.level && _hold == Duration())
        {
            // plain level gate: shaping peeks first so bursts drop before the condition is
            // evaluated; commit_run stamps the lockout / spends the token only on a real run
            if (!shaping_available(when))
                return;
            if (_condition_expr && !condition_holds())
                return;
            commit_run(when, ev);
            return;
        }

        // edge/for must observe the condition on every settled trigger or transitions are
        // missed; here shaping guards only the run itself
        bool cond = _condition_expr ? condition_holds() : true;
        bool was = _last_condition;
        _last_condition = cond;
        bool qualifying = _edge == Edge.falling ? !cond : cond;

        if (_hold == Duration())
        {
            bool transition = _edge == Edge.rising ? (cond && !was) : (!cond && was);
            if (!transition || !shaping_available(when))
                return;
            commit_run(when, ev);
            return;
        }

        // for=: the qualifying state must hold for the window; one run per qualifying episode
        if (!qualifying)
        {
            cancel_hold();   // an armed window dies, a satisfied episode resets
            return;
        }
        if (_hold_armed || _hold_satisfied)
            return;
        bool begin = _edge == Edge.level ? true
                   : _edge == Edge.rising ? (cond && !was)
                                          : (!cond && was);
        if (begin)
            arm_hold(when, ev);
    }

    bool shaping_available(MonoTime when)
    {
        if (_throttle != Duration() && _last_action != MonoTime() && when - _last_action < _throttle)
            return false;

        if (_rate.value > 0)
        {
            if (when > _tokens_stamp)
            {
                _tokens += (when - _tokens_stamp).as!"nsecs" * (_rate.value / 1_000_000_000.0);
                if (_tokens > _burst)
                    _tokens = _burst;
                _tokens_stamp = when;
            }
            if (_tokens < 1)
                return false;
        }
        return true;
    }

    void commit_run(MonoTime when, ref const SignalEvent ev)
    {
        _last_action = when;
        if (_rate.value > 0)
            _tokens -= 1;

        _last_run = getSysTime();
        ++_run_count;
        mark_set!(typeof(this), ["last_run", "run_count"])();
        if (next_run() != SysTime())
            mark_set!(typeof(this), "next_run")();   // repeating time trigger just rearmed; encoder re-reads the advanced value

        execute_action(ev);

        if (_running_commands.length > 0)
            schedule_cleanup();
    }

    void arm_hold(MonoTime when, ref const SignalEvent ev)
    {
        _hold_value = ev.value;
        _hold_source = ev.source.makeString(g_app.allocator);
        _hold_deadline = when + _hold;
        g_app.schedule(_hold_deadline, &on_hold);
        _hold_armed = true;
    }

    void cancel_hold()
    {
        if (_hold_armed)
        {
            g_app.cancel(&on_hold);
            _hold_armed = false;
        }
        _hold_satisfied = false;
        _hold_value = Variant();
        _hold_source = String();
    }

    void on_hold(MonoTime scheduled)
    {
        _hold_armed = false;

        // final authoritative check: catches a silent drop since the last observed trigger
        bool cond = _condition_expr ? condition_holds() : true;
        _last_condition = cond;
        bool qualifying = _edge == Edge.falling ? !cond : cond;
        if (qualifying)
        {
            _hold_satisfied = true;   // the episode qualified, even if shaping vetoes the run
            if (shaping_available(scheduled))
            {
                SignalEvent ev;
                ev.source = _hold_source[];
                ev.value = _hold_value.move;
                commit_run(scheduled, ev);
            }
        }
        _hold_value = Variant();
        _hold_source = String();
    }

    void reset_condition_state()
    {
        cancel_hold();
        _last_condition = _condition_expr ? condition_holds() : true;
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
