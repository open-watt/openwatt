module manager.element2;

import urt.array;
import urt.lifetime : move;
import urt.mem.alloc;
import urt.mem.allocator : defaultAllocator;
import urt.string;
import urt.time;
import urt.variant;

public import manager.series;

nothrow @nogc:


interface Observer
{
nothrow @nogc:
    void on_samples(ref const SampleCommit samples);
    void on_event(ref Element2 e, SeriesEvent event, SysTime at, Observer who);
}

struct SampleUpdate
{
nothrow @nogc:

    Element2* element;
    const(void)[] records;
    const(SysTime)[] times;
    const(ulong)[] ticks;
    Observer who;
    ulong first_index;

    uint count() const pure
        => cast(uint)(records.length / element.format.stride);

    SysTime time(size_t i) const
        => times.length ? times[i] : element.format.clock.to_wall(ticks[i]);

    Variant box(size_t i) const
        => box_record(cast(const(ubyte)*)records.ptr + i * element.format.stride,
                      *element.format);
}

struct SampleCommit
{
nothrow @nogc:

    const(SampleUpdate)[] updates;

    bool changed(ref const Element2 element) const pure
    {
        foreach (ref update; updates)
            if (update.element is &element)
                return true;
        return false;
    }
}

// A transaction borrows the supplied record and timestamp slices until commit returns.
// Nothing becomes visible and no observer runs before commit.
struct SampleTransaction
{
nothrow @nogc:

    this(this) @disable;

    void write_records(ref Element2 element, const(void)[] records,
                       const(SysTime)[] times, Observer who = null)
    {
        debug assert(!_committing);
        debug assert(times.length != 0);
        debug assert(records.length == times.length * element.format.stride);
        _updates ~= SampleUpdate(&element, records, times, null, who);
    }

    void write_records(ref Element2 element, const(void)[] records,
                       const(ulong)[] ticks, Observer who = null)
    {
        debug assert(!_committing);
        debug assert(ticks.length != 0);
        debug assert(element.format.uses_device_ticks);
        debug assert(records.length == ticks.length * element.format.stride);
        _updates ~= SampleUpdate(&element, records, null, ticks, who);
    }

    void write_samples(T)(ref Element2 element, const(T)[] samples,
                          const(SysTime)[] times, Observer who = null)
    {
        static assert(!is(T == String) && !is(T : const(char)[]),
                      "transactional text samples need owned record handles");
        element.check_sample_type!T(samples.length, times.length);
        write_records(element,
            (cast(const(void)*)samples.ptr)[0 .. samples.length * T.sizeof], times, who);
    }

    void write_samples(T)(ref Element2 element, const(T)[] samples,
                          const(ulong)[] ticks, Observer who = null)
    {
        static assert(!is(T == String) && !is(T : const(char)[]),
                      "transactional text samples need owned record handles");
        element.check_sample_type!T(samples.length, ticks.length);
        write_records(element,
            (cast(const(void)*)samples.ptr)[0 .. samples.length * T.sizeof], ticks, who);
    }

    void commit()
    {
        if (_updates.empty)
            return;
        assert(!_committing, "recursive sample transaction commit");
        _committing = true;
        scope(exit) _committing = false;

        foreach (ref update; _updates)
            update.element.apply(update);

        SampleCommit samples = SampleCommit(_updates[]);
        dispatch(samples);
        _updates.clear();
    }

    size_t length() const pure
        => _updates.length;

private:
    Array!SampleUpdate _updates;
    bool _committing;
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

    Element2* element;  // transient storage-level form; durable holders use manager.element.ElementCursor (EID)
    ulong position;
    ubyte bit;

    bool pending() const
        => element._history && element._history.head > position;

    void seek(ulong pos)
    {
        SeriesStore* h = element._history;
        if (pos > h.head)
            pos = h.head;
        position = pos;
        if (h.pin_mask & (1 << bit))
            h.pin_position[bit] = pos;
    }

    RecordBlock next(uint max_records)
    {
        SeriesStore* h = element._history;
        ulong first = h.first_index;
        ulong lost = 0;
        if (position < first)
        {
            lost = first - position;
            position = first;
        }
        RecordBlock r = h.read(*element.format, position, max_records);
        r.lost = lost;
        position += r.count;
        if (h.pin_mask & (1 << bit))
            h.pin_position[bit] = position;
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
        if (format)
        {
            if (format.is_scalar || format.is_text)
                return box_record(_latest.raw.ptr, *format);
            if (format.is_wide)
            {
                const(void)[] tail = tail_record();
                if (tail)
                    return box_record(tail.ptr, *format);
            }
        }
        return Variant();
    }

    // wide records don't fit the Scalar register: latest IS the tail record of the open bucket
    const(void)[] tail_record() const pure
    {
        if (!_history || !_history.buckets.length)
            return null;
        const(Bucket)* b = _history.buckets[$-1];
        if (!b.count)
            return null;
        return (cast(const(ubyte)*)b.samples)[(b.count - 1) * format.stride .. b.count * format.stride];
    }

    void write_sample(T)(T v, SysTime t = getSysTime(), Observer who = null)
    {
        static if (is(T == String))
            write_text_sample(v.move, t, who);
        else static if (is(T : const(char)[]))
            write_text_sample(v, t, who);
        else
        {
            static assert(is(typeof(value_type_of!T)));
            debug assert(value_type_of!T == format.type);
            debug assert(format.count == 1, "a single typed value must describe one record");
            Scalar s = Scalar.of(v);
            write_record(s.raw[0 .. format.stride], t, who);
        }
    }

    // untyped path for callers holding a record in a runtime-known DataFormat
    void write_record(const(void)[] record, SysTime t = getSysTime(), Observer who = null)
    {
        debug assert(record.length == format.stride);
        if (format.is_scalar)
        {
            Scalar s;
            s.raw[] = 0;
            s.raw[0 .. format.stride] = cast(const(ubyte)[])record;
            if (format.kind == SeriesKind.held && _last_update != SysTime() && s.raw == _latest.raw)
            {
                _last_update = t;
                return;
            }
        }
        else
        {
            assert(format.is_wide, "dynamic and non-pod records need their own entry");
            if (format.kind == SeriesKind.held && _last_update != SysTime())
            {
                const(void)[] tail = tail_record();
                if (tail && cast(const(ubyte)[])tail == cast(const(ubyte)[])record)
                {
                    _last_update = t;
                    return;
                }
            }
        }
        SysTime[1] time = t;
        SampleUpdate update = SampleUpdate(&this, record, time[], null, who);
        apply(update);
        SampleUpdate[1] updates;
        updates[0] = update;
        SampleCommit samples = SampleCommit(updates[]);
        dispatch(samples);
    }

    void write_samples(T)(const(T)[] samples, const(SysTime)[] times, Observer who = null)
    {
        static if (is(T == String) || is(T : const(char)[]))
        {
            debug assert(samples.length == times.length);
            foreach (i, ref sample; samples)
            {
                static if (is(T == String))
                    write_sample(sample[], times[i], who);
                else
                    write_sample(sample, times[i], who);
            }
        }
        else
        {
            check_sample_type!T(samples.length, times.length);
            write_records((cast(const(void)*)samples.ptr)[0 .. samples.length * T.sizeof], times, who);
        }
    }

    void write_samples(T)(const(T)[] samples, const(ulong)[] ticks, Observer who = null)
    {
        static assert(!is(T == String) && !is(T : const(char)[]),
                      "text samples cannot use device ticks");
        check_sample_type!T(samples.length, ticks.length);
        write_records((cast(const(void)*)samples.ptr)[0 .. samples.length * T.sizeof], ticks, who);
    }

    void write_records(const(void)[] records, const(SysTime)[] times, Observer who = null)
    {
        debug assert(!format.regular);
        debug assert(format.is_scalar || format.is_wide,
                     "managed records require typed sample handling");
        if (times.length == 0)
            return;
        debug assert(records.length == times.length * format.stride);
        SampleUpdate update = SampleUpdate(&this, records, times, null, who);
        apply(update);
        SampleUpdate[1] updates;
        updates[0] = update;
        SampleCommit samples = SampleCommit(updates[]);
        dispatch(samples);
    }

    void write_records(const(void)[] records, const(ulong)[] ticks, Observer who = null)
    {
        debug assert(format.uses_device_ticks);
        debug assert(format.is_scalar || format.is_wide,
                     "managed records require typed sample handling");
        if (ticks.length == 0)
            return;
        debug assert(records.length == ticks.length * format.stride);
        SampleUpdate update = SampleUpdate(&this, records, null, ticks, who);
        apply(update);
        SampleUpdate[1] updates;
        updates[0] = update;
        SampleCommit samples = SampleCommit(updates[]);
        dispatch(samples);
    }

    // TODO: rethink regular writes: data might follow the last record, or a gap may need synthesising.
//    void write_records(const(void)[] records, SysTime t0, Observer who = null)
//    {
//        debug assert(format.regular);
//        _latest.raw[] = 0;
//        _latest.raw[0 .. format.stride] = (cast(const(ubyte)[])records)[$ - format.stride .. $];
//        _last_update = t0 + nsecs((records.length / format.stride - 1) * 1_000_000_000L / format.rate);
//        append(records, null, t0, who);
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

    void retention(uint min_records, uint max_records = 0)
    {
        SeriesStore* h = ensure_history();
        h.min_records = min_records;
        h.max_records = max_records;
    }

    void retention(Duration min_age, Duration max_age = Duration())
    {
        SeriesStore* h = ensure_history();
        h.min_age = cast(ulong)min_age.as!"usecs";
        h.max_age = cast(ulong)max_age.as!"usecs";
    }

    // cursor-less block read of retained records; count 0 at/after head
    RecordBlock read_records(ulong from_index, uint max_records)
    {
        if (!_history)
        {
            RecordBlock r;
            r.format = format;
            return r;
        }
        return _history.read(*format, from_index, max_records);
    }

    // first retained index of the bucket covering wall time t, stepped back one bucket so
    // held state before t is included; ulong.max = nothing retained
    ulong index_for_time(SysTime t) const
    {
        if (!_history || !_history.buckets.length)
            return ulong.max;
        size_t lo = 0, hi = _history.buckets.length;
        while (lo < hi)
        {
            size_t mid = (lo + hi) / 2;
            if (_history.buckets[mid].last_time < t)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo)
            --lo;
        return _history.buckets[lo].first_index;
    }

    Cursor open_cursor(ulong from_index = ulong.max, bool pin = false)
    {
        SeriesStore* s = ensure_history();
        foreach (ubyte bit; 0 .. 16)
        {
            if (s.cursor_mask & (1 << bit))
                continue;
            s.cursor_mask |= cast(ushort)(1 << bit);
            ulong position = from_index > s.head ? s.head : from_index;
            if (pin)
            {
                s.pin_mask |= cast(ushort)(1 << bit);
                s.pin_position[bit] = position;
            }
            return Cursor(&this, position, bit);
        }
        assert(false, "out of cursors");
    }

    void close_cursor(ref Cursor c)
    {
        if (_history)
        {
            _history.cursor_mask &= ~cast(ushort)(1 << c.bit);
            _history.pin_mask &= ~cast(ushort)(1 << c.bit);
        }
        _dirty &= ~cast(ushort)(1 << c.bit);
        c.element = null;
    }

    bool has_history() const pure
        => _history !is null;

    ulong record_count() const pure
        => _history ? _history.head : 0;

    uint bucket_count() const pure
        => _history ? cast(uint)_history.buckets.length : 0;

    void teardown()
    {
        if (format && format.is_text)
            (cast(TextRecord*)_latest.raw.ptr).release();
        if (_history)
        {
            foreach (b; _history.buckets)
                free_bucket(b);
            destroy!false(*_history);
            free((cast(void*)_history)[0 .. SeriesStore.sizeof]);
            _history = null;
        }
        while (_subs)
        {
            Subscription* dead = _subs;
            _subs = dead.next;
            free((cast(void*)dead)[0 .. Subscription.sizeof]);
        }
    }

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

    void check_sample_type(T)(size_t value_count, size_t record_count) const
    {
        static assert(is(typeof(value_type_of!T)));
        debug assert(value_type_of!T == format.type);
        debug assert(format.count != 0, "dynamic records need type-specific sample handling");
        debug assert(value_count * T.sizeof == record_count * format.stride);
    }

    void apply(ref SampleUpdate update)
    {
        debug assert(update.element is &this);
        debug assert(update.count != 0);
        debug assert(format.is_scalar || format.is_wide,
                     "managed records require typed sample handling");

        if (format.is_scalar)
        {
            _latest.raw[] = 0;
            _latest.raw[0 .. format.stride] =
                (cast(const(ubyte)[])update.records)[$ - format.stride .. $];
        }
        else
            ensure_history();

        if (update.times.length)
        {
            _last_update = update.times[$-1];
            update.first_index = append(update.records, update.times, update.who);
        }
        else
        {
            _last_update = format.clock.to_wall(update.ticks[$-1]);
            update.first_index = append(update.records, update.ticks, update.ticks[0], update.who);
        }
    }

    void write_text_sample(String v, SysTime t, Observer who)
    {
        debug assert(format.is_text);
        TextRecord* slot = cast(TextRecord*)_latest.raw.ptr;
        if (format.kind == SeriesKind.held && _last_update != SysTime() && slot.view == v[])
        {
            _last_update = t;
            return;
        }
        slot.set(v.move);
        _last_update = t;
        append_text_record(t, who);
    }

    void write_text_sample(const(char)[] v, SysTime t, Observer who)
    {
        debug assert(format.is_text);
        TextRecord* slot = cast(TextRecord*)_latest.raw.ptr;
        if (format.kind == SeriesKind.held && _last_update != SysTime() && slot.view == v)
        {
            _last_update = t;
            return;
        }
        slot.set(v);
        _last_update = t;
        append_text_record(t, who);
    }

    void append_text_record(SysTime t, Observer who)
    {
        SysTime[1] time = t;
        if (_history)
        {
            // the ref settled here is owned by the bucket once append memcpys the bits
            TextRecord rec;
            rec.copy_from(*cast(const(TextRecord)*)_latest.raw.ptr);
            append(rec.raw[0 .. format.stride], time[], who, true);
        }
        else
            append(_latest.raw[0 .. format.stride], time[], who, true);
    }

    ulong append(const(void)[] samples, const(SysTime)[] times, Observer who, bool notify = false)
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

        ulong t0 = unix_time_ns(times[0]) / 1000;
        foreach (i, t; times)
            ts[i] = cast(uint)((t - times[0]).as!"usecs");

        bool follows_gap = (_flags & Flags.gap_open) != 0;
        _flags &= ~Flags.gap_open;

        ulong first_index = ulong.max;
        if (_history)
        {
            Bucket* b = writable_bucket(n, follows_gap, t0 + ts[n - 1]);
            (cast(ubyte*)b.samples)[b.count*stride .. (b.count + n)*stride] = cast(const(ubyte)[])samples[];
            if (b.count == 0)
                b.first_tick = t0;
            uint offset = cast(uint)(t0 - b.first_tick);
            for (uint i = 0; i < n; ++i)
                b.offsets[b.count + i] = offset + ts[i];
            b.count += n;
            b.last_offset = b.offsets[b.count - 1];

            first_index = _history.head;
            _history.head += n;
            evict_over_budget();
        }

        if (notify)
        {
            SampleUpdate update = SampleUpdate(&this, samples, times, null, who, first_index);
            SampleUpdate[1] updates;
            updates[0] = update;
            SampleCommit commit = SampleCommit(updates[]);
            dispatch(commit);
        }
        mark_dirty();
        return first_index;

        // TODO: reactor-thread producers must defer observer dispatch and dirty marking to the main loop
    }

    ulong append(const(void)[] samples, const(ulong)[] times, ulong t0, Observer who,
                 bool notify = false)
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

        foreach (i, t; times)
            ts[i] = cast(uint)(t - t0);

        bool follows_gap = (_flags & Flags.gap_open) != 0;
        _flags &= ~Flags.gap_open;

        ulong first_index = ulong.max;
        if (_history)
        {
            Bucket* b = writable_bucket(n, follows_gap, times.length ? times[n - 1] : t0);
            (cast(ubyte*)b.samples)[b.count*stride .. (b.count + n)*stride] = cast(const(ubyte)[])samples[];
            if (b.count == 0)
                b.first_tick = times.length ? times[0] : t0;
            if (b.offsets)
            {
                for (uint i = 0; i < n; ++i)
                    b.offsets[b.count + i] = cast(uint)(times[i] - b.first_tick);
            }
            b.count += n;
            b.last_offset = times.length ? b.offsets[b.count - 1] : b.count - 1;

            first_index = _history.head;
            _history.head += n;
            evict_over_budget();
        }

        if (notify)
        {
            SampleUpdate update = SampleUpdate(&this, samples, null, times, who, first_index);
            SampleUpdate[1] updates;
            updates[0] = update;
            SampleCommit commit = SampleCommit(updates[]);
            dispatch(commit);
        }
        mark_dirty();
        return first_index;

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
            if (b)
                seal(b);
            b = alloc_bucket(n > bucket_capacity ? n : bucket_capacity);
            b.first_index = _history.head;
            b.follows_gap = follows_gap;
            _history.buckets ~= b;
        }
        return b;
    }

    void seal(Bucket* b)
    {
        if (b.sealed)
            return;
        b.sealed = true;
        if (b.count && b.count < b.capacity)
        {
            b.samples = realloc(b.samples[0 .. b.capacity * format.stride], b.count * format.stride).ptr;
            if (b.offsets)
                b.offsets = cast(uint*)realloc((cast(void*)b.offsets)[0 .. b.capacity * uint.sizeof], b.count * uint.sizeof).ptr;
            b.capacity = b.count;
        }
        // TODO: pack (columnar codec) lands here
    }

    void evict_over_budget()
    {
        SeriesStore* h = _history;
        if (!h.min_records && !h.min_age && !h.max_records && !h.max_age)
            return;
        ulong to_ticks(ulong usecs)
            => format.clock ? usecs * format.clock.nominal_rate / 1_000_000 : usecs;
        ulong min_age_ticks = h.min_age ? to_ticks(h.min_age) : 0;
        ulong max_age_ticks = h.max_age ? to_ticks(h.max_age) : 0;
        ulong floor = h.pin_floor;
        while (h.buckets.length > 1)
        {
            Bucket* front = h.buckets[0];
            ulong newest = h.buckets[$-1].last_tick;
            bool forced = (h.max_records && h.head - front.first_index > h.max_records)
                       || (max_age_ticks && newest - front.last_tick > max_age_ticks);
            if (!forced)
            {
                if (!h.min_records && !h.min_age)
                    break;
                if (front.first_index + front.count > floor)
                    break;
                if (h.min_records && h.head - front.first_index - front.count < h.min_records)
                    break;
                if (min_age_ticks && newest - front.last_tick <= min_age_ticks)
                    break;
            }
            free_bucket(front);
            h.buckets.remove(0);
        }
    }

    void free_bucket(Bucket* b)
    {
        if (format.is_text)
            foreach (i; 0 .. b.count)
                (cast(TextRecord*)b.samples)[i].release();
        free(b.samples[0 .. b.capacity * format.stride]);
        if (b.offsets)
            free((cast(void*)b.offsets)[0 .. b.capacity * uint.sizeof]);
        free((cast(void*)b)[0 .. Bucket.sizeof]);
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

version (unittest)
private final class TransactionObserver : Observer
{
nothrow @nogc:

    Element2* a;
    Element2* b;
    uint calls;
    uint update_count;
    bool coherent;

    this(ref Element2 a, ref Element2 b)
    {
        this.a = &a;
        this.b = &b;
    }

    override void on_samples(ref const SampleCommit samples)
    {
        ++calls;
        update_count = cast(uint)samples.updates.length;
        coherent = a.latest.f64_ == 3.0 && b.latest.f64_ == 30.0;
    }

    override void on_event(ref Element2, SeriesEvent, SysTime, Observer)
    {
    }
}


unittest
{
    import urt.time : from_unix_time_ns;

    static immutable DataFormat f64_held = DataFormat(ValueType.f64, SeriesKind.held);

    // one protocol frame can publish several element batches without exposing partial state
    Element2 tx_a;
    Element2 tx_b;
    tx_a.format = &f64_held;
    tx_b.format = &f64_held;
    TransactionObserver observer = defaultAllocator().allocT!TransactionObserver(tx_a, tx_b);
    tx_a.subscribe(observer);
    tx_b.subscribe(observer);

    double[3] tx_a_values = [1.0, 2.0, 3.0];
    double[3] tx_b_values = [10.0, 20.0, 30.0];
    SysTime[3] tx_times = [from_unix_time_ns(100), from_unix_time_ns(200),
                           from_unix_time_ns(300)];
    SampleTransaction transaction;
    transaction.write_samples(tx_a, tx_a_values[], tx_times[]);
    transaction.write_samples(tx_b, tx_b_values[], tx_times[]);
    assert(observer.calls == 0);
    assert(tx_a.last_update == SysTime() && tx_b.last_update == SysTime());
    transaction.commit();
    assert(observer.calls == 1);
    assert(observer.update_count == 2 && observer.coherent);
    assert(transaction.length == 0);

    tx_a.teardown();
    tx_b.teardown();
    defaultAllocator().freeT(observer);

    // retention=none: latest and last_update track, nothing is stored
    Element2 n;
    n.format = &f64_held;
    n.write_sample(9.0, from_unix_time_ns(500));
    assert(n.record_count == 0 && n.bucket_count == 0);
    assert(n.latest.f64_ == 9.0);
    assert(n.last_update == from_unix_time_ns(500));

    // held series: equal observations advance last_update but record nothing
    Element2 e;
    e.format = &f64_held;
    e.ensure_history();
    e.write_sample(1.0, from_unix_time_ns(1_000));
    e.write_sample(1.0, from_unix_time_ns(2_000));
    e.write_sample(2.0, from_unix_time_ns(3_000));
    assert(e.record_count == 2);
    assert(e.last_update == from_unix_time_ns(3_000));

    // a gap forces a bucket boundary and the successor bucket records it
    e.mark_gap();
    e.write_sample(3.0, from_unix_time_ns(10_000));
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
    e.write_samples(vals[], times[]);
    assert(e.record_count == 6);
    assert(e.latest.f64_ == 6.0);
    b = c.next(16);
    assert(b.count == 3 && b.ts !is null && b.time(2) == from_unix_time_ns(13_000));
    e.close_cursor(c);

    // untyped record write: same flow as write_sample(), format known only at runtime
    double rv = 7.0;
    e.write_record((cast(const(void)*)&rv)[0 .. 8], from_unix_time_ns(14_000));
    assert(e.record_count == 7);
    assert(e.latest.f64_ == 7.0);

    // text: short strings embed in the record, long strings allocate a String; equal held values reuse it
    DataFormat text_fmt = DataFormat(ValueType.char_, SeriesKind.held);
    text_fmt.count = 0;
    Element2 te;
    te.format = &text_fmt;
    te.ensure_history();
    te.write_sample("run", from_unix_time_ns(500));
    assert(te.record_count == 1);
    assert((cast(const(TextRecord)*)te.latest.raw.ptr).embedded);
    assert(te.value().asString == "run");

    te.write_sample("a string too long to embed anywhere", from_unix_time_ns(1_000));
    assert(te.record_count == 2);
    assert(!(cast(const(TextRecord)*)te.latest.raw.ptr).embedded);
    assert(te.value().asString == "a string too long to embed anywhere");
    const(char)* allocated = (cast(const(String)*)te.latest.raw.ptr).ptr;
    te.write_sample("a string too long to embed anywhere", from_unix_time_ns(2_000));
    assert(te.record_count == 2);
    assert((cast(const(String)*)te.latest.raw.ptr).ptr is allocated);
    assert(te.last_update == from_unix_time_ns(2_000));

    // String ingress adopts the handle; refs = caller + latest slot + bucket record
    String src = "second value arriving as a shared handle".makeString(defaultAllocator());
    static ushort rc(ref const String s) => (cast(const(ushort)*)s.ptr)[-2] & 0x3FFF;
    assert(rc(src) == 0);
    te.write_sample(src, from_unix_time_ns(3_000));
    assert(te.record_count == 3);
    assert(rc(src) == 2);
    assert(te.value().asString == src[]);

    Cursor tcur = te.open_cursor(0);
    RecordBlock tblk = tcur.next(16);
    assert(tblk.count == 3);
    assert(tblk.box(0).asString == "run");
    assert(tblk.box(1).asString == "a string too long to embed anywhere");
    assert(tblk.box(2).asString == src[]);
    te.close_cursor(tcur);

    te.teardown();
    assert(rc(src) == 0);

    Element2 text_batch;
    text_batch.format = &text_fmt;
    text_batch.ensure_history();
    const(char)[][2] words = ["one", "two"];
    SysTime[2] word_times = [from_unix_time_ns(4_000), from_unix_time_ns(5_000)];
    text_batch.write_samples(words[], word_times[]);
    assert(text_batch.record_count == 2);
    assert(text_batch.value().asString == "two");
    text_batch.teardown();

    // retention: sealed buckets shrink to fit, the budget evicts from the front, lapped cursors report loss
    Element2 r;
    r.format = &f64_held;
    r.retention(4);
    Cursor lap = r.open_cursor(0);
    foreach (i; 0 .. 6)
    {
        r.write_sample(double(i), from_unix_time_ns(1_000 * (i + 1)));
        r.mark_gap();   // force one-record buckets
    }
    assert(r.record_count == 6);
    assert(r._history.first_index == 2);
    assert(r._history.buckets[0].sealed && r._history.buckets[0].capacity == 1);
    RecordBlock rb = lap.next(16);
    assert(rb.lost == 2 && rb.count == 1 && rb.get!double(0) == 2.0);
    r.close_cursor(lap);
    r.teardown();

    // pinned cursor: holds retention past the floor until consumed; consumption releases
    Element2 p;
    p.format = &f64_held;
    p.retention(2);
    Cursor pinc = p.open_cursor(0, true);
    foreach (i; 0 .. 6)
    {
        p.write_sample(double(i), from_unix_time_ns(1_000 * (i + 1)));
        p.mark_gap();
    }
    assert(p._history.first_index == 0);
    foreach (_; 0 .. 4)
        pinc.next(1);
    p.write_sample(6.0, from_unix_time_ns(7_000));
    assert(p._history.first_index == 4);
    p.close_cursor(pinc);
    p.teardown();

    // ceiling: max_records evicts past a stalled pin; the lapped cursor reports the loss
    Element2 x;
    x.format = &f64_held;
    x.retention(0, 3);
    Cursor stall = x.open_cursor(0, true);
    foreach (i; 0 .. 6)
    {
        x.write_sample(double(i), from_unix_time_ns(1_000 * (i + 1)));
        x.mark_gap();
    }
    assert(x._history.first_index == 3);
    RecordBlock xb = stall.next(16);
    assert(xb.lost == 3 && xb.count == 1 && xb.get!double(0) == 3.0);
    x.close_cursor(stall);
    x.teardown();

    // age floor: consumed-or-unpinned records older than the window evict
    Element2 a;
    a.format = &f64_held;
    a.retention(1.seconds);
    foreach (i; 0 .. 3)
    {
        a.write_sample(double(i), from_unix_time_ns(1_000_000L * (i + 1)));
        a.mark_gap();
    }
    assert(a._history.first_index == 0);
    a.write_sample(9.0, from_unix_time_ns(3_000_000_000L));
    assert(a._history.first_index == 3);
    a.teardown();

    // wide records: fixed vectors don't fit the Scalar register; latest is the open bucket tail
    DataFormat key_fmt = DataFormat(ValueType.u8, SeriesKind.held);
    key_fmt.count = 32;
    assert(!key_fmt.is_scalar && !key_fmt.is_text && key_fmt.is_wide && key_fmt.stride == 32);
    Element2 k;
    k.format = &key_fmt;
    ubyte[32] key1;
    foreach (i, ref byt; key1)
        byt = cast(ubyte)i;
    k.write_record(key1[], from_unix_time_ns(1_000));
    assert(k.record_count == 1);
    assert(cast(const(ubyte)[])k.value().asBuffer == key1[]);
    k.write_record(key1[], from_unix_time_ns(2_000));
    assert(k.record_count == 1 && k.last_update == from_unix_time_ns(2_000));   // held dedup vs the tail
    ubyte[32] key2 = key1;
    key2[0] = 0xFF;
    k.write_record(key2[], from_unix_time_ns(3_000));
    assert(k.record_count == 2);
    assert(cast(const(ubyte)[])k.value().asBuffer == key2[]);
    assert(cast(const(ubyte)[])k.tail_record() == key2[]);
    Cursor kc = k.open_cursor(0);
    RecordBlock kb = kc.next(16);
    assert(kb.count == 2);
    assert(cast(const(ubyte)[])kb.box(0).asBuffer == key1[]);
    assert(cast(const(ubyte)[])kb.box(1).asBuffer == key2[]);
    k.close_cursor(kc);
    k.teardown();

    // eviction releases text records
    Element2 tv;
    tv.format = &text_fmt;
    tv.retention(1);
    String evictee = "the first long string, soon evicted".makeString(defaultAllocator());
    tv.write_sample(evictee, from_unix_time_ns(1_000));
    assert(rc(evictee) == 2);
    tv.mark_gap();
    tv.write_sample("replacement value, also quite long", from_unix_time_ns(2_000));
    assert(rc(evictee) == 0);   // slot replaced, bucket evicted
    tv.teardown();

    // TODO: regular-series test returns once regular write_records() and rate-aware tick() are built
}


package:

__gshared Array!(Element2*) g_dirty_elements;

void sweep_dirty(scope void delegate(ref Element2) nothrow @nogc visit)
{
    foreach (e; g_dirty_elements)
        visit(*e);
    g_dirty_elements.clear();
}


private:

void dispatch(ref const SampleCommit samples)
{
    Array!Observer observers;
    foreach (ref update; samples.updates)
    {
        Element2* element = cast(Element2*)update.element;
        for (Subscription* subscription = element._subs;
             subscription; subscription = subscription.next)
        {
            Observer observer = subscription.observer;
            if (observer is update.who)
                continue;
            bool found;
            foreach (present; observers)
            {
                if (present is observer)
                {
                    found = true;
                    break;
                }
            }
            if (!found)
                observers ~= observer;
        }
    }

    foreach (observer; observers)
        observer.on_samples(samples);
}

// compile-time twin of ValueType for the typed write_sample() entry
template value_type_of(T)
{
    static if (is(T == bool))        enum value_type_of = ValueType.bool_;
    else static if (is(T == ubyte))  enum value_type_of = ValueType.u8;
    else static if (is(T == byte))   enum value_type_of = ValueType.s8;
    else static if (is(T == ushort)) enum value_type_of = ValueType.u16;
    else static if (is(T == short))  enum value_type_of = ValueType.s16;
    else static if (is(T == uint))   enum value_type_of = ValueType.u32;
    else static if (is(T == int))    enum value_type_of = ValueType.s32;
    else static if (is(T == ulong))  enum value_type_of = ValueType.u64;
    else static if (is(T == long))   enum value_type_of = ValueType.s64;
    else static if (is(T == float))  enum value_type_of = ValueType.f32;
    else static if (is(T == double)) enum value_type_of = ValueType.f64;
    else static if (is(T == char))   enum value_type_of = ValueType.char_;
}
