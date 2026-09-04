module protocol.matter.exchange;

import urt.time;

nothrow @nogc:


enum mrp_max_transmissions = 5;
enum mrp_backoff_threshold = 1;
enum mrp_standalone_ack_delay = 200.msecs;

struct MrpConfig
{
    Duration idle_interval = 500.msecs;
    Duration active_interval = 300.msecs;
}

// Spec 4.11.2.1: interval * 1.1 * 1.6^max(0, send_count - threshold) * (1 + jitter), jitter in [0, 25]%.
Duration mrp_backoff(Duration interval, uint send_count, uint jitter_percent)
{
    ulong ms = cast(ulong)interval.as!"msecs" * 11 / 10;
    uint exponent = send_count > mrp_backoff_threshold ? send_count - mrp_backoff_threshold : 0;
    foreach (i; 0 .. exponent)
        ms = ms * 16 / 10;
    ms += ms * jitter_percent / 100;
    return ms.msecs;
}

enum ExchangeAction : ubyte
{
    none,
    retransmit,
    send_ack,
    timeout,
}

struct Exchange
{
    ushort id;
    ushort session_id;
    bool initiator;
    bool open;

nothrow @nogc:
    bool awaiting_ack() const pure
        => _pending.length != 0;

    const(ubyte)[] pending_message() const pure
        => _pending;

    uint pending_counter() const pure
        => _pending_counter;

    ubyte send_count() const pure
        => _send_count;

    // The caller keeps message alive until the ack arrives or the exchange times out.
    void sent_reliable(const(ubyte)[] message, uint counter, MonoTime now, ref const MrpConfig config, bool peer_active, uint jitter_percent)
    {
        _pending = message;
        _pending_counter = counter;
        _send_count = 1;
        _interval = peer_active ? config.active_interval : config.idle_interval;
        _next_retransmit = now + mrp_backoff(_interval, 0, jitter_percent);
    }

    bool on_ack(uint counter)
    {
        if (_pending.length == 0 || counter != _pending_counter)
            return false;
        _pending = null;
        return true;
    }

    void received_reliable(uint counter, MonoTime now)
    {
        _ack_owed = true;
        _ack_counter = counter;
        _ack_deadline = now + mrp_standalone_ack_delay;
    }

    // Takes the owed ack so it can ride on an outgoing message.
    bool take_ack(out uint counter)
    {
        if (!_ack_owed)
            return false;
        counter = _ack_counter;
        _ack_owed = false;
        return true;
    }

    bool ack_owed() const pure
        => _ack_owed;

    ExchangeAction poll(MonoTime now, uint jitter_percent)
    {
        if (_pending.length && now >= _next_retransmit)
        {
            if (_send_count >= mrp_max_transmissions)
            {
                _pending = null;
                return ExchangeAction.timeout;
            }
            _next_retransmit = now + mrp_backoff(_interval, _send_count, jitter_percent);
            ++_send_count;
            return ExchangeAction.retransmit;
        }
        if (_ack_owed && now >= _ack_deadline)
            return ExchangeAction.send_ack;
        return ExchangeAction.none;
    }

    // Earliest time poll() could return something other than none, for the caller's timer.
    bool next_deadline(out MonoTime when) const pure
    {
        bool any;
        if (_pending.length)
        {
            when = _next_retransmit;
            any = true;
        }
        if (_ack_owed && (!any || _ack_deadline < when))
        {
            when = _ack_deadline;
            any = true;
        }
        return any;
    }

private:
    const(ubyte)[] _pending;
    uint _pending_counter;
    uint _ack_counter;
    Duration _interval;
    MonoTime _next_retransmit;
    MonoTime _ack_deadline;
    ubyte _send_count;
    bool _ack_owed;
}

struct ExchangeTable(size_t capacity)
{
nothrow @nogc:
    Exchange* open(ushort session_id, bool initiator, ushort id)
    {
        foreach (ref e; _slots)
        {
            if (!e.open)
            {
                e = Exchange.init;
                e.id = id;
                e.session_id = session_id;
                e.initiator = initiator;
                e.open = true;
                return &e;
            }
        }
        return null;
    }

    Exchange* open_initiator(ushort session_id)
        => open(session_id, true, next_id());

    // A received message's initiator flag is from the peer's perspective.
    Exchange* find(ushort session_id, ushort id, bool peer_initiator)
    {
        foreach (ref e; _slots)
        {
            if (e.open && e.session_id == session_id && e.id == id && e.initiator != peer_initiator)
                return &e;
        }
        return null;
    }

    void close(Exchange* e)
    {
        e.open = false;
    }

    void close_session(ushort session_id)
    {
        foreach (ref e; _slots)
        {
            if (e.open && e.session_id == session_id)
                e.open = false;
        }
    }

    size_t open_count() const pure
    {
        size_t n;
        foreach (ref e; _slots)
            n += e.open;
        return n;
    }

    bool next_deadline(out MonoTime when) const pure
    {
        bool any;
        foreach (ref e; _slots)
        {
            MonoTime t;
            if (e.open && e.next_deadline(t) && (!any || t < when))
            {
                when = t;
                any = true;
            }
        }
        return any;
    }

    ushort next_id()
        => ++_next_id;

private:
    Exchange[capacity] _slots;
    ushort _next_id;
}


unittest
{
    assert(mrp_backoff(500.msecs, 0, 0) == 550.msecs);
    assert(mrp_backoff(500.msecs, 1, 0) == 550.msecs);
    assert(mrp_backoff(500.msecs, 2, 0) == 880.msecs);
    assert(mrp_backoff(500.msecs, 3, 0) == 1408.msecs);
    assert(mrp_backoff(300.msecs, 0, 25) == 412.msecs);

    MrpConfig config;
    ExchangeTable!4 table;
    Exchange* e = table.open_initiator(0x1234);
    assert(e && e.initiator && e.id == 1 && table.open_count == 1);
    assert(table.find(0x1234, 1, false) is e);
    assert(table.find(0x1234, 1, true) is null);
    assert(table.find(0x1235, 1, false) is null);

    MonoTime t0 = MonoTime(1_000_000);
    static immutable ubyte[4] msg = [1, 2, 3, 4];
    e.sent_reliable(msg[], 77, t0, config, false, 0);
    assert(e.awaiting_ack && e.pending_counter == 77 && e.send_count == 1);
    assert(e.poll(t0, 0) == ExchangeAction.none);
    assert(e.poll(t0 + 549.msecs, 0) == ExchangeAction.none);
    assert(e.poll(t0 + 550.msecs, 0) == ExchangeAction.retransmit);
    assert(e.send_count == 2);
    MonoTime deadline;
    assert(e.next_deadline(deadline) && deadline == t0 + 550.msecs + 550.msecs);
    assert(!e.on_ack(78));
    assert(e.on_ack(77) && !e.awaiting_ack);
    assert(e.poll(t0 + 10.seconds, 0) == ExchangeAction.none);

    // exhaustion after the last transmission
    e.sent_reliable(msg[], 78, t0, config, true, 0);
    MonoTime t = t0;
    uint retransmits;
    while (true)
    {
        assert(e.next_deadline(t));
        ExchangeAction a = e.poll(t, 0);
        if (a == ExchangeAction.timeout)
            break;
        assert(a == ExchangeAction.retransmit);
        ++retransmits;
    }
    assert(retransmits == mrp_max_transmissions - 1);
    assert(!e.awaiting_ack);

    // owed ack is piggybacked, or sent standalone after the delay
    e.received_reliable(5, t0);
    assert(e.ack_owed);
    assert(e.poll(t0 + 100.msecs, 0) == ExchangeAction.none);
    assert(e.poll(t0 + 200.msecs, 0) == ExchangeAction.send_ack);
    uint ack;
    assert(e.take_ack(ack) && ack == 5 && !e.ack_owed);
    assert(!e.take_ack(ack));
    assert(!e.next_deadline(deadline));

    Exchange* r = table.open(0x1234, false, 9);
    assert(table.find(0x1234, 9, true) is r);
    assert(table.next_deadline(deadline) == false);
    table.close_session(0x1234);
    assert(table.open_count == 0);
}
