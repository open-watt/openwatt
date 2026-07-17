module manager.element2;

import urt.array;
import urt.mem.alloc;
import urt.string;
import urt.time;
import urt.variant;

public import manager.series;

nothrow @nogc:


interface Observer
{
nothrow @nogc:
    void on_records(ref Element2 e, ref const RecordBlock records, Observer who);
    void on_event(ref Element2 e, SeriesEvent event, SysTime at, Observer who);
}

struct Subscription
{
    Observer observer;
    Subscription* next;
    // future: per-subscriber deadband band + anchor live here (see TODO.md element deadband)
}

struct Cursor
{
nothrow @nogc:

    Element2* element;  // TODO: becomes manager.id.EID (type exists at target shape) once resolution lands
    ulong position;
    ubyte bit;

    bool pending() const
        => element._history && element._history.head > position;

    RecordBlock next(uint max_records)
    {
        RecordBlock r = element._history.read(*element.format, position, max_records);
        position += r.count;
        if (!pending)
            element._dirty &= ~cast(ushort)(1 << bit);
        return r;
    }
}


struct Element2
{
nothrow @nogc:

    const(DataFormat)* format;

    this(this) @disable;

    ref const(Scalar) latest() const pure
        => _latest;

    SysTime last_update() const pure
        => _last_update;

    Variant value() const
    {
        Variant r;
        // TODO: box _latest per format.type, attach format.unit
        return r;
    }

    void observe(T)(T v, SysTime t = getSysTime(), Observer who = null)
    {
        static assert(is(typeof(value_type_of!T)));
        debug assert(value_type_of!T == format.type);

        Scalar s = Scalar.of(v);
        if (format.semantics == Semantics.held && _last_update != SysTime() && s.raw == _latest.raw)
        {
            _last_update = t;
            return;
        }
        _latest = s;
        _last_update = t;
        SysTime[1] time = t;
        append(s.raw[0 .. format.stride], time[], who);
    }

    void observe_record(const(void)[] record, SysTime t = getSysTime(), Observer who = null)
    {
        // TODO: untemplated path for samplers decoding at runtime-known format; same flow as observe()
    }

    void observe_block(const(void)[] samples, const(SysTime)[] times, Observer who = null)
    {
        debug assert(!format.regular);
        uint n = cast(uint)times.length;
        if (n == 0)
            return;
        debug assert(samples.length == n * format.stride);
        _latest.raw[] = 0;
        _latest.raw[0 .. format.stride] = (cast(const(ubyte)[])samples)[$ - format.stride .. $];
        _last_update = times[$-1];
        append(samples, times, who);
    }

    void observe_block(const(void)[] samples, const(ulong)[] ticks, Observer who = null)
    {
        debug assert(format.domain_native);
        uint n = cast(uint)ticks.length;
        if (n == 0)
            return;
        debug assert(samples.length == n * format.stride);
        _latest.raw[] = 0;
        _latest.raw[0 .. format.stride] = (cast(const(ubyte)[])samples)[$ - format.stride .. $];
        _last_update = format.clock.to_wall(ticks[$-1]);
        append(samples, ticks, ticks[0], who);
    }

    // TODO: we meed to rethink appending regular samples API; adding data, the api might assume the samples follow the last sample
    //       but if we're adding after a gap, then we need to synthesise a gap...
//    void append_block(const(void)[] samples, SysTime t0, Observer who = null)
//    {
//        debug assert(format.regular);
//        _latest.raw[] = 0;
//        _latest.raw[0 .. format.stride] = (cast(const(ubyte)[])samples)[$ - format.stride .. $];
//        _last_update = t0 + nsecs((samples.length / format.stride - 1) * 1_000_000_000L / format.rate);
//        append(samples, null, t0, who);
//    }

    void mark_gap(Observer who = null)
    {
        if (_flags & Flags.gap_open)
            return;
        _flags |= Flags.gap_open;
        signal_event(SeriesEvent.gap, _last_update, who);
    }

    void set_format(const(DataFormat)* f, Observer who = null)
    {
        // TODO: force bucket boundary, signal format_change; a format is a shared immutable,
        //       so change is a pointer swap
    }

    void subscribe(Observer o)
    {
        for (Subscription* s = _subs; s; s = s.next)
            if (s.observer is o)
                return;
        Subscription* n = cast(Subscription*)alloc(Subscription.sizeof).ptr;
        n.observer = o;
        n.next = _subs;
        _subs = n;
    }

    void unsubscribe(Observer o)
    {
        Subscription** p = &_subs;
        while (*p)
        {
            if ((*p).observer is o)
            {
                Subscription* dead = *p;
                *p = dead.next;
                free((cast(void*)dead)[0 .. Subscription.sizeof]);
                return;
            }
            p = &(*p).next;
        }
    }

    SeriesStore* ensure_history()
    {
        if (!_history)
        {
            // zero-fill rather than assign .init: SeriesStore holds an Array, whose opAssign
            // would try to release the garbage "previous" contents of raw memory
            void[] mem = alloc(SeriesStore.sizeof);
            (cast(ubyte[])mem)[] = 0;
            _history = cast(SeriesStore*)mem.ptr;
        }
        return _history;
    }

    Cursor open_cursor(ulong from_index = ulong.max)
    {
        SeriesStore* s = ensure_history();
        foreach (ubyte bit; 0 .. 16)
        {
            if (s.cursor_mask & (1 << bit))
                continue;
            s.cursor_mask |= cast(ushort)(1 << bit);
            return Cursor(&this, from_index > s.head ? s.head : from_index, bit);
        }
        assert(false, "out of cursors");
    }

    void close_cursor(ref Cursor c)
    {
        if (_history)
            _history.cursor_mask &= ~cast(ushort)(1 << c.bit);
        _dirty &= ~cast(ushort)(1 << c.bit);
        c.element = null;
    }

    ulong record_count() const pure
        => _history ? _history.head : 0;

    uint bucket_count() const pure
        => _history ? cast(uint)_history.buckets.length : 0;

private:
    enum Flags : ubyte
    {
        gap_open = 1 << 0,
    }

    Scalar _latest;
    SysTime _last_update;
    Subscription* _subs;
    SeriesStore* _history;
    ushort _dirty;
    ubyte _flags;

    enum bucket_capacity = 256; // TODO: scale with rate (target a time span, not a record count)

    void append(const(void)[] samples, const(SysTime)[] times, Observer who)
    {
        import urt.mem : alloca;

        ubyte stride = format.stride;
        uint n = cast(uint)(samples.length / stride);
        assert(times is null || times.length == n, "times array must match sample count");

        uint[] ts;
        if (times.length <= 512)
            ts = (cast(uint*)alloca(times.length * uint.sizeof))[0 .. times.length];
        else
            ts = cast(uint[])alloc(times.length * uint.sizeof, uint.sizeof, MemFlags.fastest);
        scope(exit) { if (times.length > 512) free(ts); }

        RecordBlock blk;
        blk.format = format;
        blk.data = samples.ptr;
        blk.ts = ts.ptr;
        blk.t0 = unix_time_ns(times[0]) / 1000;
        blk.count = n;
        foreach (i, t; times)
            ts[i] = cast(uint)((t - times[0]).as!"usecs");

        bool follows_gap = (_flags & Flags.gap_open) != 0;
        _flags &= ~Flags.gap_open;

        if (_history)
        {
            Bucket* b = writable_bucket(n, follows_gap, blk.t0 + ts[n - 1]);
            (cast(ubyte*)b.samples)[b.count*stride .. (b.count + n)*stride] = cast(const(ubyte)[])samples[];
            if (b.count == 0)
                b.first_tick = blk.t0;
            uint offset = cast(uint)(blk.t0 - b.first_tick);
            for (uint i = 0; i < n; ++i)
                b.offsets[b.count + i] = offset + ts[i];
            b.count += n;
            b.last_offset = b.offsets[b.count - 1];

            blk.first_index = _history.head;
            _history.head += n;
        }

        for (Subscription* s = _subs; s; s = s.next)
            if (s.observer !is who)
                s.observer.on_records(this, blk, who);
        mark_dirty();

        // TODO: reactor-thread producers must defer observer dispatch and dirty marking to the main loop
    }

    void append(const(void)[] samples, const(ulong)[] times, ulong t0, Observer who)
    {
        import urt.mem : alloca;

        ubyte stride = format.stride;
        uint n = cast(uint)(samples.length / stride);
        assert(times is null || times.length == n, "times array must match sample count");

        uint[] ts;
        if (times.length <= 512)
            ts = (cast(uint*)alloca(times.length * uint.sizeof))[0 .. times.length];
        else
            ts = cast(uint[])alloc(times.length * uint.sizeof, uint.sizeof, MemFlags.fastest);
        scope(exit) { if (times.length > 512) free(ts); }

        RecordBlock blk;
        blk.format = format;
        blk.data = samples.ptr;
        blk.ts = ts.ptr;
        blk.t0 = times.length ? times[0] : t0;
        blk.count = n;
        foreach (i, t; times)
            ts[i] = cast(uint)(t - t0);

        bool follows_gap = (_flags & Flags.gap_open) != 0;
        _flags &= ~Flags.gap_open;

        if (_history)
        {
            Bucket* b = writable_bucket(n, follows_gap, times.length ? times[n - 1] : t0);
            (cast(ubyte*)b.samples)[b.count*stride .. (b.count + n)*stride] = cast(const(ubyte)[])samples[];
            if (b.count == 0)
                b.first_tick = blk.t0;
            if (b.offsets)
            {
                for (uint i = 0; i < n; ++i)
                    b.offsets[b.count + i] = cast(uint)(times[i] - b.first_tick);
            }
            b.count += n;
            b.last_offset = times.length ? b.offsets[b.count - 1] : b.count - 1;

            blk.first_index = _history.head;
            _history.head += n;
        }

        for (Subscription* s = _subs; s; s = s.next)
            if (s.observer !is who)
                s.observer.on_records(this, blk, who);
        mark_dirty();

        // TODO: reactor-thread producers must defer observer dispatch and dirty marking to the main loop
    }

    Bucket* writable_bucket(uint n, bool follows_gap, ulong max_tick)
    {
        Bucket* b = _history.buckets.length ? _history.buckets[$-1] : null;
        // roll when the new block's offset from this bucket's base would exceed the uint offset field:
        // a slow stream spanning >~71 min at 1 MHz, or a base discontinuity that would underflow it
        bool overflow = b && b.offsets && b.count && max_tick - b.first_tick > uint.max;
        if (!b || b.count + n > b.capacity || follows_gap || overflow)
        {
            b = alloc_bucket(n > bucket_capacity ? n : bucket_capacity);
            b.first_index = _history.head;
            b.follows_gap = follows_gap;
            _history.buckets ~= b;
        }
        return b;
    }

    Bucket* alloc_bucket(uint capacity)
    {
        Bucket* b = cast(Bucket*)alloc(Bucket.sizeof).ptr;
        *b = Bucket.init;
        b.capacity = capacity;
        b.samples = alloc(capacity * format.stride).ptr;
        if (!format.regular)
            b.offsets = cast(uint*)alloc(capacity * uint.sizeof).ptr;
        return b;
    }

    void signal_event(SeriesEvent ev, SysTime at, Observer who)
    {
        for (Subscription* s = _subs; s; s = s.next)
            if (s.observer !is who)
                s.observer.on_event(this, ev, at, who);
    }

    void mark_dirty()
    {
        if (!_history || !_history.cursor_mask)
            return;
        if (!_dirty)
            g_dirty_elements ~= &this;
        _dirty = _history.cursor_mask;
    }
}

static assert(Element2.sizeof <= 48);


unittest
{
    import urt.time : from_unix_time_ns;

    static immutable DataFormat f64_held = DataFormat(ValueType.f64, Semantics.held);

    // retention=none: latest and last_update track, nothing is stored
    Element2 n;
    n.format = &f64_held;
    n.observe(9.0, from_unix_time_ns(500));
    assert(n.record_count == 0 && n.bucket_count == 0);
    assert(n.latest.f64_ == 9.0);
    assert(n.last_update == from_unix_time_ns(500));

    // held semantics: equal observations advance last_update but record nothing
    Element2 e;
    e.format = &f64_held;
    e.ensure_history();
    e.observe(1.0, from_unix_time_ns(1_000));
    e.observe(1.0, from_unix_time_ns(2_000));
    e.observe(2.0, from_unix_time_ns(3_000));
    assert(e.record_count == 2);
    assert(e.last_update == from_unix_time_ns(3_000));

    // a gap forces a bucket boundary and the successor bucket records it
    e.mark_gap();
    e.observe(3.0, from_unix_time_ns(10_000));
    assert(e.bucket_count == 2);
    assert(e._history.buckets[$-1].follows_gap);

    // cursor: backfill from zero, then tail; blocks never span buckets
    Cursor c = e.open_cursor(0);
    RecordBlock b = c.next(16);
    assert(b.count == 2 && b.get!double(0) == 1.0 && b.get!double(1) == 2.0);
    assert(b.time(1) == from_unix_time_ns(3_000));
    b = c.next(16);
    assert(b.count == 1 && b.get!double(0) == 3.0);
    assert(!c.pending);

    // irregular block append feeds the tail and updates latest
    double[3] vals = [4.0, 5.0, 6.0];
    SysTime[3] times = [from_unix_time_ns(11_000), from_unix_time_ns(12_000), from_unix_time_ns(13_000)];
    e.observe_block(vals[], times[]);
    assert(e.record_count == 6);
    assert(e.latest.f64_ == 6.0);
    b = c.next(16);
    assert(b.count == 3 && b.ts !is null && b.time(2) == from_unix_time_ns(13_000));
    e.close_cursor(c);

    // TODO: regular-series test returns once append_block is rebuilt and tick() is rate-aware
}


package:

__gshared Array!(Element2*) g_dirty_elements;

void sweep_dirty(scope void delegate(ref Element2) nothrow @nogc visit)
{
    foreach (e; g_dirty_elements)
        visit(*e);
    g_dirty_elements.clear();
}
