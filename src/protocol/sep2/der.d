module protocol.sep2.der;

import urt.array;
import urt.lifetime;
import urt.rand : rand;

import protocol.sep2.schema;

nothrow @nogc:


alias Responder = void delegate(ref const DERControl control, ResponseStatus status) nothrow @nogc;

struct ScheduledEvent
{
    DERControl control;
    long start;
    long end;
    ubyte primacy;
    bool started;
    bool done;
}

// A refresh is staged and touches nothing until commit(), so evaluate() always sees a whole timeline.
struct DERSchedule
{
nothrow @nogc:

    ref const(DERControlBase) applied() const pure
        => _applied;

    const(ScheduledEvent)* active() const pure
        => _active < _events.length ? &_events[_active] : null;

    size_t length() const pure
        => _events.length;

    void begin_sync()
    {
        _staged.clear();
        _staged_default = DERControlBase();
        _staged_primacy = ubyte.max;
    }

    void offer_default(ref const DERControlBase base, ubyte primacy)
    {
        if (primacy > _staged_primacy)
            return;
        _staged_primacy = primacy;
        _staged_default = base;
    }

    // An mRID is one event however many program lists reach it.
    void offer(ref DERControl control, ubyte primacy)
    {
        if (Staged* s = find_staged(control.mrid))
        {
            if (primacy < s.primacy)
                s.primacy = primacy;
            return;
        }
        _staged ~= Staged(control.move, primacy);
    }

    // Finished events are kept until the server stops listing them, so a re-listing cannot resurrect one.
    // True when a new event carries a setpoint this client does not act on.
    bool commit(scope Responder respond)
    {
        for (size_t i = 0; i < _events.length; )
        {
            ScheduledEvent* e = &_events[i];
            Staged* s = find_staged(e.control.mrid);
            if (s)
            {
                s.matched = true;
                e.primacy = s.primacy;
                e.control.status = s.control.status;
                e.control.reply_to = s.control.reply_to.move;
            }
            else if (!e.done)
                e.control.status = EventState.cancelled;
            else
            {
                if (_active != size_t.max && _active > i)
                    --_active;
                _events.remove(i);
                continue;
            }
            ++i;
        }

        bool setpoint = false;
        foreach (ref s; _staged)
        {
            if (s.matched)
                continue;
            ScheduledEvent e;
            e.control = s.control.move;
            e.primacy = s.primacy;
            e.start = e.control.start + jitter(e.control.randomize_start);
            e.end = e.control.start + e.control.duration + jitter(e.control.randomize_duration);
            setpoint |= e.control.base.has(ControlField.setpoint);
            _events ~= e.move;
            if (_events.back.control.response_required & ResponseRequired.received)
                respond(_events.back.control, ResponseStatus.received);
        }

        _default = _staged_default;
        begin_sync();
        return setpoint;
    }

    // The next boundary after `now`, or 0 when nothing is pending.
    long evaluate(long now, scope Responder respond, out bool changed)
    {
        size_t winner = size_t.max;
        foreach (i, ref e; _events)
        {
            if (e.done)
                continue;
            if (e.control.status == EventState.cancelled || e.control.status == EventState.cancelled_random)
            {
                finish(e, ResponseStatus.cancelled, respond);
                continue;
            }
            if (e.control.status == EventState.superseded)
            {
                finish(e, ResponseStatus.superseded, respond);
                continue;
            }
            if (now >= e.end)
            {
                finish(e, e.started ? ResponseStatus.completed : ResponseStatus.expired, respond);
                continue;
            }
            if (now < e.start)
                continue;
            if (winner == size_t.max || better(e, _events[winner]))
                winner = i;
        }

        if (winner != size_t.max)
        {
            foreach (i, ref e; _events)
            {
                if (i != winner && !e.done && now >= e.start && e.started)
                    finish(e, ResponseStatus.superseded, respond);
            }
            ScheduledEvent* w = &_events[winner];
            if (!w.started)
            {
                w.started = true;
                if (w.control.response_required & ResponseRequired.specific)
                    respond(w.control, ResponseStatus.started);
            }
        }
        _active = winner;

        DERControlBase next = _default;
        MRID event;
        if (winner != size_t.max)
        {
            next = next.merge(_events[winner].control.base);
            event = _events[winner].control.mrid;
        }
        bool has_event = winner != size_t.max;
        changed = next != _applied || has_event != _applied_has_event || event != _applied_event;
        _applied = next;
        _applied_event = event;
        _applied_has_event = has_event;

        long boundary = 0;
        foreach (ref e; _events)
        {
            if (e.done)
                continue;
            long t = now < e.start ? e.start : e.end;
            if (boundary == 0 || t < boundary)
                boundary = t;
        }
        return boundary;
    }

private:
    struct Staged
    {
        DERControl control;
        ubyte primacy;
        bool matched;
    }

    Array!ScheduledEvent _events;
    Array!Staged _staged;
    DERControlBase _default;
    DERControlBase _staged_default;
    DERControlBase _applied;
    MRID _applied_event;
    size_t _active = size_t.max;
    ubyte _staged_primacy = ubyte.max;
    bool _applied_has_event;

    Staged* find_staged(ref const MRID mrid)
    {
        foreach (ref s; _staged)
        {
            if (!s.matched && s.control.mrid == mrid)
                return &s;
        }
        return null;
    }

    static long jitter(int range)
    {
        if (range == 0)
            return 0;
        long r = rand() % (range < 0 ? -cast(long)range : range);
        return range < 0 ? -r : r;
    }

    // Lower primacy value wins; within a program the newer event supersedes the older.
    static bool better(ref const ScheduledEvent a, ref const ScheduledEvent b) pure
    {
        if (a.primacy != b.primacy)
            return a.primacy < b.primacy;
        return a.control.creation_time > b.control.creation_time;
    }

    static void finish(ref ScheduledEvent e, ResponseStatus status, scope Responder respond)
    {
        e.done = true;
        bool tell = status != ResponseStatus.expired && (e.control.response_required & ResponseRequired.specific) != 0;
        if (tell && (e.started || status == ResponseStatus.cancelled || status == ResponseStatus.superseded))
            respond(e.control, status);
    }
}


unittest
{
    static DERControl make(ubyte id, long start, uint duration, long created, int exp_w, EventState status = EventState.scheduled)
    {
        DERControl c;
        c.mrid[15] = id;
        c.start = start;
        c.duration = duration;
        c.creation_time = created;
        c.status = status;
        c.response_required = ResponseRequired.received | ResponseRequired.specific;
        c.base.fields = ControlField.export_limit;
        c.base.limit_w[Limit.export_] = exp_w;
        return c;
    }

    struct Log { ubyte id; ResponseStatus status; }
    Log[32] log;
    size_t n;
    void respond(ref const DERControl c, ResponseStatus s) nothrow @nogc
    {
        if (n < log.length)
            log[n++] = Log(c.mrid[15], s);
    }

    DERSchedule s;
    DERControlBase def;
    def.fields = ControlField.export_limit | ControlField.import_limit;
    def.limit_w[Limit.export_] = 5000;
    def.limit_w[Limit.import_] = 9000;

    void sync(DERControl[] controls...) nothrow @nogc
    {
        s.begin_sync();
        s.offer_default(def, 1);
        foreach (ref c; controls)
            s.offer(c, 1);
    }

    sync(make(1, 100, 100, 10, 1500), make(2, 150, 100, 20, 0));
    assert(s.length == 0 && n == 0);
    assert(!s.commit(&respond));
    assert(n == 2 && log[0].id == 1 && log[0].status == ResponseStatus.received && log[1].id == 2);

    bool changed;
    assert(s.evaluate(50, &respond, changed) == 100);
    assert(changed && s.active is null && s.applied.limit_w[Limit.export_] == 5000 && s.applied.limit_w[Limit.import_] == 9000);

    assert(s.evaluate(100, &respond, changed) == 150);
    assert(changed && s.active.control.mrid[15] == 1 && s.applied.limit_w[Limit.export_] == 1500 && s.applied.limit_w[Limit.import_] == 9000);
    assert(n == 3 && log[2].id == 1 && log[2].status == ResponseStatus.started);

    // a refresh in flight, or one abandoned half way, leaves the committed timeline running
    s.begin_sync();
    assert(s.evaluate(120, &respond, changed) == 150);
    assert(!changed && s.active.control.mrid[15] == 1 && s.applied.limit_w[Limit.export_] == 1500 && s.applied.limit_w[Limit.import_] == 9000);

    // b is newer in the same program: it supersedes a while both are in window
    assert(s.evaluate(150, &respond, changed) == 250);
    assert(changed && s.active.control.mrid[15] == 2 && s.applied.limit_w[Limit.export_] == 0);
    assert(n == 5 && log[3].id == 1 && log[3].status == ResponseStatus.superseded && log[4].id == 2 && log[4].status == ResponseStatus.started);
    assert(s.length == 2);

    // a is still listed by the server: it must not come back
    sync(make(1, 100, 100, 10, 1500), make(2, 150, 100, 20, 0));
    s.commit(&respond);
    assert(n == 5 && s.length == 2);
    assert(s.evaluate(160, &respond, changed) == 250);
    assert(!changed && s.active.control.mrid[15] == 2);

    // the server cancels b and drops a: revert to the default
    sync(make(2, 150, 100, 20, 0, EventState.cancelled));
    s.commit(&respond);
    assert(s.length == 1);
    assert(s.evaluate(160, &respond, changed) == 0);
    assert(changed && s.active is null && s.applied.limit_w[Limit.export_] == 5000);
    assert(n == 6 && log[5].id == 2 && log[5].status == ResponseStatus.cancelled);
    sync();
    s.commit(&respond);
    assert(s.length == 0);

    // an event that runs to its end completes
    sync(make(3, 200, 50, 30, 100));
    s.commit(&respond);
    s.evaluate(200, &respond, changed);
    assert(s.applied.limit_w[Limit.export_] == 100);
    assert(s.evaluate(250, &respond, changed) == 0);
    assert(changed && s.applied.limit_w[Limit.export_] == 5000 && log[n - 1].status == ResponseStatus.completed);

    // an event the server drops from the list is treated as cancelled
    sync(make(4, 300, 50, 40, 7));
    s.commit(&respond);
    s.evaluate(300, &respond, changed);
    assert(s.applied.limit_w[Limit.export_] == 7);
    sync();
    s.commit(&respond);
    s.evaluate(310, &respond, changed);
    assert(changed && s.applied.limit_w[Limit.export_] == 5000 && log[n - 1].id == 4 && log[n - 1].status == ResponseStatus.cancelled);

    // a change of event is a change even when the limits are identical, or only restate the default
    sync(make(5, 400, 100, 50, 5000), make(6, 450, 100, 60, 5000));
    s.commit(&respond);
    assert(s.evaluate(390, &respond, changed) == 400 && !changed);
    assert(s.evaluate(400, &respond, changed) == 450);
    assert(changed && s.active.control.mrid[15] == 5 && s.applied.limit_w[Limit.export_] == 5000);
    assert(s.evaluate(450, &respond, changed) == 550);
    assert(changed && s.active.control.mrid[15] == 6 && s.applied.limit_w[Limit.export_] == 5000);
    assert(s.evaluate(550, &respond, changed) == 0);
    assert(changed && s.active is null && s.applied.limit_w[Limit.export_] == 5000);

    // the same event reached twice in one walk is one event, under the strongest primacy offered
    s.begin_sync();
    s.offer_default(def, 1);
    auto twice = make(8, 700, 100, 80, 42);
    s.offer(twice, 3);
    twice = make(8, 700, 100, 80, 42);
    s.offer(twice, 2);
    twice = make(8, 700, 100, 80, 42);
    s.offer(twice, 4);
    size_t before = n;
    s.commit(&respond);
    assert(s.length == 1 && n == before + 1 && log[n - 1].id == 8 && log[n - 1].status == ResponseStatus.received);
    s.evaluate(700, &respond, changed);
    assert(s.active.control.mrid[15] == 8 && s.active.primacy == 2 && s.applied.limit_w[Limit.export_] == 42);
    sync(make(8, 700, 100, 80, 42));
    s.commit(&respond);
    s.evaluate(710, &respond, changed);
    assert(!changed && s.length == 1 && s.active.control.mrid[15] == 8);
    sync();
    s.commit(&respond);
    s.evaluate(720, &respond, changed);
    sync();
    s.commit(&respond);
    assert(s.length == 0);

    // a setpoint the client ignores is reported once, when the event is new
    DERControl fixed = make(7, 600, 10, 70, 1);
    fixed.base.fields |= ControlField.setpoint;
    sync(fixed);
    assert(s.commit(&respond));
    fixed = make(7, 600, 10, 70, 1);
    fixed.base.fields |= ControlField.setpoint;
    sync(fixed);
    assert(!s.commit(&respond));
}
