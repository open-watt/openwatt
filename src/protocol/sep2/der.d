module protocol.sep2.der;

import urt.array;
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
    bool seen;
}

// The event timeline for one EndDevice across all its programs. Events are offered on every poll;
// evaluate() picks the winner at `now`, emits the responses the server asked for, and returns the
// next instant the answer can change.
struct DERSchedule
{
nothrow @nogc:

    DERControlBase default_control;
    bool has_default;

    ref const(DERControlBase) applied() const pure
        => _applied;

    const(ScheduledEvent)* active() const pure
        => _active < _events.length ? &_events[_active] : null;

    size_t length() const pure
        => _events.length;

    void begin_sync()
    {
        foreach (ref e; _events)
            e.seen = false;
        has_default = false;
        default_control = DERControlBase();
        _lowest_primacy = ubyte.max;
    }

    // Programs are walked in list order; the lowest primacy value wins the default.
    void offer_default(ref const DERControlBase base, ubyte primacy)
    {
        if (primacy > _lowest_primacy)
            return;
        _lowest_primacy = primacy;
        default_control = base;
        has_default = true;
    }

    void offer(ref DERControl control, ubyte primacy, scope Responder respond)
    {
        foreach (ref e; _events)
        {
            if (e.control.mrid != control.mrid)
                continue;
            e.seen = true;
            e.primacy = primacy;
            e.control.status = control.status;
            e.control.reply_to = control.reply_to.move;
            return;
        }

        ScheduledEvent e;
        e.control = control.move;
        e.primacy = primacy;
        e.start = e.control.start + jitter(e.control.randomize_start);
        e.end = e.control.start + e.control.duration + jitter(e.control.randomize_duration);
        e.seen = true;
        _events ~= e.move;
        if (_events.back.control.response_required & ResponseRequired.received)
            respond(_events.back.control, ResponseStatus.received);
    }

    // Events the server no longer lists are over as far as it is concerned; finished ones are
    // remembered until then so a re-listing cannot resurrect them.
    void end_sync()
    {
        for (size_t i = 0; i < _events.length; )
        {
            ScheduledEvent* e = &_events[i];
            if (e.seen || !e.done)
            {
                if (!e.seen)
                    e.control.status = EventState.cancelled;
                ++i;
                continue;
            }
            if (_active != size_t.max && _active > i)
                --_active;
            _events.remove(i);
        }
    }

    // Returns the next boundary after `now`, or 0 when nothing is pending. `changed` reports whether
    // the applied control differs from the previous evaluation.
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

        DERControlBase next = has_default ? default_control : DERControlBase();
        if (_active != size_t.max)
            next = next.merge(_events[_active].control.base);
        changed = next != _applied;
        _applied = next;

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

    void clear()
    {
        _events.clear();
        _active = size_t.max;
        _applied = DERControlBase();
        has_default = false;
    }

private:
    Array!ScheduledEvent _events;
    DERControlBase _applied;
    size_t _active = size_t.max;
    ubyte _lowest_primacy = ubyte.max;

    static long jitter(int range)
    {
        if (range == 0)
            return 0;
        long r = rand() % (range < 0 ? -range : range);
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
        bool tell = status == ResponseStatus.expired ? false : (e.control.response_required & ResponseRequired.specific) != 0;
        if (tell && (e.started || status == ResponseStatus.cancelled || status == ResponseStatus.superseded))
            respond(e.control, status);
    }
}


unittest
{
    static DERControl make(ubyte id, long start, uint duration, long created, int exp_w)
    {
        DERControl c;
        c.mrid[15] = id;
        c.start = start;
        c.duration = duration;
        c.creation_time = created;
        c.response_required = ResponseRequired.received | ResponseRequired.specific;
        c.base.fields = ControlField.export_limit;
        c.base.export_limit_w = exp_w;
        return c;
    }

    struct Log { ubyte id; ResponseStatus status; }
    Log[16] log;
    size_t n;
    void respond(ref const DERControl c, ResponseStatus s) nothrow @nogc
    {
        if (n < log.length)
            log[n++] = Log(c.mrid[15], s);
    }

    DERSchedule s;
    DERControlBase def;
    def.fields = ControlField.export_limit | ControlField.import_limit;
    def.export_limit_w = 5000;
    def.import_limit_w = 9000;

    s.begin_sync();
    s.offer_default(def, 1);
    auto a = make(1, 100, 100, 10, 1500);
    auto b = make(2, 150, 100, 20, 0);
    s.offer(a, 1, &respond);
    s.offer(b, 1, &respond);
    s.end_sync();
    assert(n == 2 && log[0].id == 1 && log[0].status == ResponseStatus.received && log[1].id == 2);

    bool changed;
    assert(s.evaluate(50, &respond, changed) == 100);
    assert(changed && s.active is null && s.applied.export_limit_w == 5000 && s.applied.import_limit_w == 9000);

    assert(s.evaluate(100, &respond, changed) == 150);
    assert(changed && s.active.control.mrid[15] == 1 && s.applied.export_limit_w == 1500 && s.applied.import_limit_w == 9000);
    assert(n == 3 && log[2].id == 1 && log[2].status == ResponseStatus.started);

    // b is newer in the same program: it supersedes a while both are in window
    assert(s.evaluate(150, &respond, changed) == 250);
    assert(changed && s.active.control.mrid[15] == 2 && s.applied.export_limit_w == 0);
    assert(n == 5 && log[3].id == 1 && log[3].status == ResponseStatus.superseded && log[4].id == 2 && log[4].status == ResponseStatus.started);
    assert(s.length == 2);

    // a is still listed by the server: it must not come back
    s.begin_sync();
    s.offer_default(def, 1);
    a = make(1, 100, 100, 10, 1500);
    b = make(2, 150, 100, 20, 0);
    s.offer(a, 1, &respond);
    s.offer(b, 1, &respond);
    s.end_sync();
    assert(n == 5 && s.length == 2);
    assert(s.evaluate(160, &respond, changed) == 250);
    assert(!changed && s.active.control.mrid[15] == 2);

    // the server cancels b and drops a: revert to the default
    s.begin_sync();
    s.offer_default(def, 1);
    b = make(2, 150, 100, 20, 0);
    b.status = EventState.cancelled;
    s.offer(b, 1, &respond);
    s.end_sync();
    assert(s.length == 1);
    assert(s.evaluate(160, &respond, changed) == 0);
    assert(changed && s.active is null && s.applied.export_limit_w == 5000);
    assert(n == 6 && log[5].id == 2 && log[5].status == ResponseStatus.cancelled);
    s.begin_sync();
    s.end_sync();
    assert(s.length == 0);

    // an event that runs to its end completes
    auto c = make(3, 200, 50, 30, 100);
    s.begin_sync();
    s.offer_default(def, 1);
    s.offer(c, 1, &respond);
    s.end_sync();
    s.evaluate(200, &respond, changed);
    assert(s.applied.export_limit_w == 100);
    assert(s.evaluate(250, &respond, changed) == 0);
    assert(changed && s.applied.export_limit_w == 5000 && log[n - 1].status == ResponseStatus.completed);

    // an event the server drops from the list is treated as cancelled
    auto d = make(4, 300, 50, 40, 7);
    s.begin_sync();
    s.offer_default(def, 1);
    s.offer(d, 1, &respond);
    s.end_sync();
    s.evaluate(300, &respond, changed);
    assert(s.applied.export_limit_w == 7);
    s.begin_sync();
    s.offer_default(def, 1);
    s.end_sync();
    s.evaluate(310, &respond, changed);
    assert(changed && s.applied.export_limit_w == 5000 && log[n - 1].id == 4 && log[n - 1].status == ResponseStatus.cancelled);
}
