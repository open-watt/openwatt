module manager.element;

import urt.array;
import urt.lifetime;
import urt.mem.alloc;
import urt.mem.allocator : defaultAllocator;
import urt.mem.string;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.time;
import urt.variant;

import manager.component;
import manager.device;
public import manager.series;
import manager.id : EID;

nothrow @nogc:


alias Subscriber = void delegate(ref const SampleUpdate update) nothrow @nogc;

struct SampleUpdate
{
nothrow @nogc:

    Element* element;
    const(void)[] records;
    const(SysTime)[] times;
    const(ulong)[] ticks;
    Subscriber who;
    ulong first_index;
    Variant value;
    Variant previous;
    SysTime timestamp;
    SysTime previous_timestamp;
    SeriesEvent event;
    bool value_ready;

    uint count() const pure
        => records.length ? cast(uint)(records.length / element.data_format.stride) : value_ready;

    SysTime time(size_t i) const
        => records.length
            ? (times.length ? times[i] : element.data_format.clock.to_wall(ticks[i]))
            : timestamp;

    Variant box(size_t i) const
        => records.length
            ? box_record(cast(const(ubyte)*)records.ptr + i * element.data_format.stride, *element.data_format)
            : value;
}

// A commit scope defers subscriber delivery: writes between begin_commit and end_commit apply
// to their elements immediately through the normal write paths, and their updates deliver when
// the outermost scope closes, so subscribers only ever run against a fully applied frame.
// Batch record/time slices written inside a scope are borrowed until the scope closes;
// single-sample writes travel as their boxed value.
void begin_commit()
{
    ++g_commit_depth;
}

void end_commit()
{
    assert(g_commit_depth != 0, "unbalanced end_commit");
    if (--g_commit_depth != 0)
        return;
    if (g_pending_updates.empty)
        return;
    Array!SampleUpdate updates = g_pending_updates.move;
    foreach (ref update; updates)
        deliver(update);
}

struct CommitScope
{
nothrow @nogc:

    @disable this();
    @disable this(this);

    ~this()
    {
        end_commit();
    }

private:
    this(int)
    {
        begin_commit();
    }
}

CommitScope open_commit()
    => CommitScope(0);

struct Subscription
{
    Subscriber callback;
    Subscription* next;
    // future: per-subscriber deadband band + anchor live here (see TODO.md element deadband)
}

struct Cursor
{
nothrow @nogc:

    Element* element;  // transient storage-level form; durable holders use manager.element.ElementCursor (EID)
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
        RecordBlock r = h.read(element.format, position, max_records);
        r.lost = lost;
        position += r.count;
        if (h.pin_mask & (1 << bit))
            h.pin_position[bit] = position;
        if (!pending)
            element._dirty &= ~cast(ushort)(1 << bit);
        return r;
    }
}
enum Access : ubyte
{
    none = 0,
    read = 1,
    write = 2,
    read_write = 3
}

enum SamplingMode : ubyte
{
    manual,
    constant,
    dependent,

    // these signal how bindings intend to interact with the element
    poll,
    report,
    on_demand,
    config
}

struct Element
{
nothrow @nogc:

    String id;
    String name;
    String desc;
    String display_unit;

    SysTime last_update;

    package EID _eid;

    Component parent;

    Access access;
    SamplingMode sampling_mode;

    this(this) @disable;

    double normalised_value() const
    {
        return value.asQuantity().normalise().value;
    }

    double scaled_value(ScaledUnit unit)() const
    {
        import urt.si.quantity : Quantity;
        return Quantity!(double, unit)(value.asQuantity()).value;
    }

    double scaled_value(ScaledUnit unit) const
    {
        return value.asQuantity().adjust_scale(unit).value;
    }

    Variant value() @property const
        => record_value();

    void value(T)(auto ref T v, SysTime timestamp = getSysTime(), Subscriber who = null)
    {
        assert(format.valid, "element has no data format");
        static if (is(immutable T == immutable Variant))
        {
            update_typed_series(v, timestamp, who);
        }
        else
        {
            Variant boxed = Variant(v);
            update_typed_series(boxed, timestamp, who);
        }
    }

    void write_sample(T)(T v, SysTime t = getSysTime(), Subscriber who = null)
    {
        static if (is(T == String))
            store_sample(v.move, t, who);
        else static if (is(T : const(char)[]))
            store_sample(v, t, who);
        else
        {
            static assert(is(typeof(value_type_of!T)));
            if (value_type_of!T == data_format.type)
                store_sample(v, t, who);
            else
            {
                Variant boxed = Variant(v);
                update_typed_series(boxed, t, who);
            }
        }
    }

    void write_record(const(void)[] record, SysTime t = getSysTime(), Subscriber who = null)
    {
        store_record(record, t, who);
    }

    // TB selects the timebase: SysTime wall timestamps, or ulong ticks in the format's clock domain
    void write_samples(T, TB)(const(T)[] samples, const(TB)[] times, Subscriber who = null)
        if (is(immutable TB == immutable SysTime) || is(immutable TB == immutable ulong))
    {
        enum wall = is(immutable TB == immutable SysTime);
        static if (is(T == String) || is(T : const(char)[]))
        {
            static assert(wall, "text samples cannot use device ticks");
            store_samples(samples, times, who);
        }
        else
        {
            static assert(is(typeof(value_type_of!T)));
            if (value_type_of!T == data_format.type)
                store_samples(samples, times, who);
            else
            {
                debug assert(samples.length == times.length);
                foreach (i, sample; samples)
                {
                    static if (wall)
                        write_sample(sample, times[i], who);
                    else
                        write_sample(sample, data_format.clock.to_wall(times[i]), who);
                }
            }
        }
    }

    void write_records(const(void)[] records, const(SysTime)[] times, Subscriber who = null)
    {
        store_records(records, times, who);
    }

    void write_records(const(void)[] records, const(ulong)[] ticks, Subscriber who = null)
    {
        store_records(records, ticks, who);
    }

    void mark_gap(Subscriber who = null)
    {
        mark_series_gap(who);
    }

    EID eid() const pure
        => _eid;

    EID ensure_eid()
    {
        if (_eid)
            return _eid;
        Component c = parent;
        while (c && !c.is_device)
            c = c.parent;
        if (!c)
            return EID.invalid;
        Device d = cast(Device)cast(void*)c;    // extern(C++) has no dynamic cast; is_device checked above
        if (!d.cid)
            return EID.invalid;
        _eid = d.cid.element(d.element_ids.allocate(&this));
        return _eid;
    }

    ElementCursor open_cursor(ulong from_index = ulong.max, bool pin = false)
    {
        EID handle = ensure_eid();
        if (!handle)
            return ElementCursor();
        Cursor c = open_series_cursor(from_index, pin);
        return ElementCursor(handle, c.position, c.bit);
    }

    private bool update_typed_series(ref const Variant v, SysTime timestamp, Subscriber who)
    {
        if (data_format.is_text)
        {
            if (v.isString)
            {
                store_sample(v.asString(), timestamp, who);
                return true;
            }
            return false;
        }
        if (data_format.is_wide)
        {
            if (v.isBuffer)
            {
                const(void)[] b = v.asBuffer;
                if (b.length == data_format.stride)
                {
                    store_record(b, timestamp, who);
                    return true;
                }
            }
            return false;
        }
        Scalar s;
        if (unbox_scalar(v, *data_format, s))
        {
            store_record(s.raw[0 .. data_format.stride], timestamp, who);
            return true;
        }
        return false;
    }

    // boxed value/previous only serve subscriber payloads; unwatched elements never box
    private void prepare_before(ref SampleUpdate update)
    {
        if (!_subs)
            return;
        update.previous = record_value();
        update.previous_timestamp = last_update;
    }

    private void prepare_after(ref SampleUpdate update)
    {
        SysTime t = record_update;
        if (t > last_update)
            last_update = t;
        update.timestamp = t;
        if (!_subs)
            return;
        update.value = record_value();
        update.value_ready = true;
    }

    void force_update(SysTime timestamp)
    {
        if (timestamp <= last_update)
            return;
        SysTime previous_timestamp = last_update;
        last_update = timestamp;
        if (!_subs)
            return;

        Variant current = record_value();
        SampleUpdate update;
        update.element = &this;
        update.value = current;
        update.previous = current.move;
        update.timestamp = timestamp;
        update.previous_timestamp = previous_timestamp;
        update.value_ready = true;
        submit(update, false);
    }

    ptrdiff_t full_path(char[] buf) const nothrow @nogc
    {
        size_t pos;
        if (parent)
        {
            pos = parent.full_path(buf);
            if (pos < buf.length)
                buf[pos] = '.';
            ++pos;
        }
        if (pos + id.length <= buf.length)
            buf[pos .. pos + id.length] = id[];
        return pos + id.length;
    }

public:

    FormatId format;

    const(DataFormat)* data_format() const pure
        => format_info(format);


    ref const(Scalar) latest_record() const pure
        => _latest;

    SysTime record_update() const pure
        => _last_update;

    Variant record_value() const
    {
        if (format.valid && _last_update != SysTime())
        {
            if (data_format.is_scalar || data_format.is_text)
                return box_record(_latest.raw.ptr, *data_format);
            if (data_format.is_wide)
            {
                const(void)[] tail = tail_record();
                if (tail)
                    return box_record(tail.ptr, *data_format);
            }
        }
        return Variant();
    }

    const(char)[] text_value() const pure
    {
        if (!format.valid || !data_format.is_text || _last_update == SysTime())
            return null;
        return (cast(const(TextRecord)*)_latest.raw.ptr).view;
    }

    // wide records don't fit the Scalar register: latest IS the tail record of the open bucket
    const(void)[] tail_record() const pure
    {
        if (!_history || !_history.buckets.length)
            return null;
        const(Bucket)* b = _history.buckets[$-1];
        if (!b.count)
            return null;
        return (cast(const(ubyte)*)b.samples)[(b.count - 1) * data_format.stride .. b.count * data_format.stride];
    }

    void store_sample(T)(T v, SysTime t = getSysTime(), Subscriber who = null)
    {
        static if (is(T == String))
            write_text_sample(v.move, t, who);
        else static if (is(T : const(char)[]))
            write_text_sample(v, t, who);
        else
        {
            static assert(is(typeof(value_type_of!T)));
            debug assert(value_type_of!T == data_format.type);
            debug assert(data_format.count == 1, "a single typed value must describe one record");
            Scalar s = Scalar.of(v);
            store_record(s.raw[0 .. data_format.stride], t, who);
        }
    }

    // untyped path for callers holding a record in a runtime-known DataFormat
    void store_record(const(void)[] record, SysTime t = getSysTime(), Subscriber who = null)
    {
        debug assert(record.length == data_format.stride);
        if (data_format.is_scalar)
        {
            Scalar s;
            s.raw[] = 0;
            s.raw[0 .. data_format.stride] = cast(const(ubyte)[])record;
            if (held_repeat(s.raw == _latest.raw, t))
                return;
        }
        else
        {
            assert(data_format.is_wide, "dynamic and non-pod records need their own entry");
            if (held_repeat(tail_equals(record), t))
                return;
        }
        SysTime[1] time = t;
        SampleUpdate update = SampleUpdate(&this, record, time[], null, who);
        commit_update(update, false);
    }

    void store_samples(T, TB)(const(T)[] samples, const(TB)[] times, Subscriber who = null)
        if (is(immutable TB == immutable SysTime) || is(immutable TB == immutable ulong))
    {
        static if (is(T == String) || is(T : const(char)[]))
        {
            static assert(is(immutable TB == immutable SysTime), "text samples cannot use device ticks");
            debug assert(samples.length == times.length);
            foreach (i, ref sample; samples)
            {
                static if (is(T == String))
                    store_sample(sample[], times[i], who);
                else
                    store_sample(sample, times[i], who);
            }
        }
        else
        {
            check_sample_type!T(samples.length, times.length);
            store_records((cast(const(void)*)samples.ptr)[0 .. samples.length * T.sizeof], times, who);
        }
    }

    void store_records(TB)(const(void)[] records, const(TB)[] times, Subscriber who = null)
        if (is(immutable TB == immutable SysTime) || is(immutable TB == immutable ulong))
    {
        enum wall = is(immutable TB == immutable SysTime);
        static if (wall)
            debug assert(!data_format.regular);
        else
            debug assert(data_format.uses_device_ticks);
        if (times.length == 0)
            return;
        debug assert(records.length == times.length * data_format.stride);
        static if (wall)
            SampleUpdate update = SampleUpdate(&this, records, times, null, who);
        else
            SampleUpdate update = SampleUpdate(&this, records, null, times, who);
        commit_update(update, true);
    }

    // TODO: rethink regular writes: data might follow the last record, or a gap may need synthesising.
//    void store_records(const(void)[] records, SysTime t0, Subscriber who = null)
//    {
//        debug assert(format.regular);
//        _latest.raw[] = 0;
//        _latest.raw[0 .. format.stride] = (cast(const(ubyte)[])records)[$ - format.stride .. $];
//        _last_update = t0 + nsecs((records.length / format.stride - 1) * 1_000_000_000L / format.rate);
//        append_block(records, t0, null);
//    }

    void mark_series_gap(Subscriber who = null)
    {
        if (_flags & Flags.gap_open)
            return;
        _flags |= Flags.gap_open;
        SampleUpdate update;
        update.element = &this;
        update.who = who;
        update.event = SeriesEvent.gap;
        update.timestamp = _last_update;
        submit(update, false);
    }

    void subscribe(Subscriber callback)
    {
        for (Subscription* s = _subs; s; s = s.next)
            if (s.callback == callback)
                return;
        Subscription* n = cast(Subscription*)alloc(Subscription.sizeof).ptr;
        n.callback = callback;
        n.next = _subs;
        _subs = n;
    }

    void unsubscribe(Subscriber callback)
    {
        Subscription** p = &_subs;
        while (*p)
        {
            if ((*p).callback == callback)
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
        return _history.read(format, from_index, max_records);
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

    Cursor open_series_cursor(ulong from_index = ulong.max, bool pin = false)
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

    void close_series_cursor(ref Cursor c)
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
        if (format.valid && data_format.is_text)
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
        debug assert(value_type_of!T == data_format.type);
        debug assert(data_format.count != 0, "dynamic records need type-specific sample handling");
        debug assert(value_count * T.sizeof == record_count * data_format.stride);
    }

    // held series: an equal observation only advances the timestamps
    bool held_repeat(bool equal, SysTime t)
    {
        if (data_format.kind != SeriesKind.held || _last_update == SysTime() || !equal)
            return false;
        _last_update = t;
        if (t > last_update)
            last_update = t;
        return true;
    }

    bool tail_equals(const(void)[] record) const pure
    {
        const(void)[] tail = tail_record();
        return tail && cast(const(ubyte)[])tail == cast(const(ubyte)[])record;
    }

    void commit_update(ref SampleUpdate update, bool batch)
    {
        debug assert(update.element is &this);
        debug assert(update.count != 0);
        debug assert(data_format.is_scalar || data_format.is_wide,
                     "managed records require typed sample handling");
        prepare_before(update);
        apply(update);
        prepare_after(update);
        submit(update, batch);
    }

    void apply(ref SampleUpdate update)
    {
        if (data_format.is_scalar)
        {
            _latest.raw[] = 0;
            _latest.raw[0 .. data_format.stride] =
                (cast(const(ubyte)[])update.records)[$ - data_format.stride .. $];
        }
        else
            ensure_history();

        if (update.times.length)
        {
            _last_update = update.times[$-1];
            update.first_index = append(update.records, update.times);
        }
        else
        {
            _last_update = data_format.clock.to_wall(update.ticks[$-1]);
            update.first_index = append(update.records, update.ticks);
        }
    }

    void write_text_sample(String v, SysTime t, Subscriber who)
    {
        debug assert(data_format.is_text);
        TextRecord* slot = cast(TextRecord*)_latest.raw.ptr;
        if (held_repeat(slot.view == v[], t))
            return;
        Variant previous;
        if (_subs)
            previous = record_value();
        SysTime previous_timestamp = last_update;
        slot.set(v.move);
        _last_update = t;
        append_text_record(t, who, previous.move, previous_timestamp);
    }

    void write_text_sample(const(char)[] v, SysTime t, Subscriber who)
    {
        debug assert(data_format.is_text);
        TextRecord* slot = cast(TextRecord*)_latest.raw.ptr;
        if (held_repeat(slot.view == v, t))
            return;
        Variant previous;
        if (_subs)
            previous = record_value();
        SysTime previous_timestamp = last_update;
        slot.set(v);
        _last_update = t;
        append_text_record(t, who, previous.move, previous_timestamp);
    }

    void append_text_record(SysTime t, Subscriber who, Variant previous,
                            SysTime previous_timestamp)
    {
        SysTime[1] time = t;
        const(void)[] record;
        TextRecord rec;
        if (_history)
        {
            // the ref settled here is owned by the bucket once append memcpys the bits
            rec.copy_from(*cast(const(TextRecord)*)_latest.raw.ptr);
            record = rec.raw[0 .. data_format.stride];
            append(record, time[]);
        }
        else
        {
            record = _latest.raw[0 .. data_format.stride];
            append(record, time[]);
        }

        SampleUpdate update = SampleUpdate(&this, record, time[], null, who);
        update.previous = previous.move;
        update.previous_timestamp = previous_timestamp;
        prepare_after(update);
        submit(update, false);
    }

    ulong append(const(void)[] samples, const(SysTime)[] times)
    {
        import urt.mem : alloca;

        uint[] ts;
        if (times.length <= 512)
            ts = (cast(uint*)alloca(times.length * uint.sizeof))[0 .. times.length];
        else
            ts = cast(uint[])alloc(times.length * uint.sizeof, uint.sizeof, MemFlags.fastest);
        scope(exit) { if (times.length > 512) free(ts); }

        foreach (i, t; times)
            ts[i] = cast(uint)((t - times[0]).as!"usecs");
        return append_block(samples, unix_time_ns(times[0]) / 1000, ts);
    }

    ulong append(const(void)[] samples, const(ulong)[] ticks)
    {
        import urt.mem : alloca;

        uint[] ts;
        if (ticks.length <= 512)
            ts = (cast(uint*)alloca(ticks.length * uint.sizeof))[0 .. ticks.length];
        else
            ts = cast(uint[])alloc(ticks.length * uint.sizeof, uint.sizeof, MemFlags.fastest);
        scope(exit) { if (ticks.length > 512) free(ts); }

        foreach (i, t; ticks)
            ts[i] = cast(uint)(t - ticks[0]);
        return append_block(samples, ticks[0], ts);
    }

    // t0 is the batch base tick, ts the batch-relative offsets; empty ts = regular series,
    // where the record index is the offset
    ulong append_block(const(void)[] samples, ulong t0, const(uint)[] ts)
    {
        ubyte stride = data_format.stride;
        uint n = cast(uint)(samples.length / stride);
        assert(ts.length == 0 || ts.length == n, "times array must match sample count");

        bool follows_gap = (_flags & Flags.gap_open) != 0;
        _flags &= ~Flags.gap_open;

        ulong first_index = ulong.max;
        if (_history)
        {
            Bucket* b = writable_bucket(n, follows_gap, t0 + (ts.length ? ts[$-1] : 0));
            (cast(ubyte*)b.samples)[b.count*stride .. (b.count + n)*stride] = cast(const(ubyte)[])samples[];
            if (b.count == 0)
                b.first_tick = t0;
            if (b.offsets)
            {
                uint base = cast(uint)(t0 - b.first_tick);
                foreach (i; 0 .. n)
                    b.offsets[b.count + i] = base + (ts.length ? ts[i] : i);
            }
            b.count += n;
            b.last_offset = b.offsets ? b.offsets[b.count - 1] : b.count - 1;

            first_index = _history.head;
            _history.head += n;
            evict_over_budget();
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
            b.samples = realloc(b.samples[0 .. b.capacity * data_format.stride], b.count * data_format.stride).ptr;
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
            => data_format.clock ? usecs * data_format.clock.nominal_rate / 1_000_000 : usecs;
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
        if (data_format.is_text)
            foreach (i; 0 .. b.count)
                (cast(TextRecord*)b.samples)[i].release();
        free(b.samples[0 .. b.capacity * data_format.stride]);
        if (b.offsets)
            free((cast(void*)b.offsets)[0 .. b.capacity * uint.sizeof]);
        free((cast(void*)b)[0 .. Bucket.sizeof]);
    }

    Bucket* alloc_bucket(uint capacity)
    {
        Bucket* b = cast(Bucket*)alloc(Bucket.sizeof).ptr;
        *b = Bucket.init;
        b.capacity = capacity;
        b.samples = alloc(capacity * data_format.stride).ptr;
        if (!data_format.regular)
            b.offsets = cast(uint*)alloc(capacity * uint.sizeof).ptr;
        return b;
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


package:

__gshared Array!(Element*) g_dirty_elements;

void sweep_dirty(scope void delegate(ref Element) nothrow @nogc visit)
{
    foreach (e; g_dirty_elements)
        visit(*e);
    g_dirty_elements.clear();
}


private:

__gshared uint g_commit_depth;
__gshared Array!SampleUpdate g_pending_updates;

// batch updates keep their record/time slices (borrowed until the scope closes); single
// updates reference write-path temporaries, so deferred they travel as their boxed value
void submit(ref SampleUpdate update, bool batch)
{
    if (g_commit_depth)
    {
        if (!batch)
        {
            update.records = null;
            update.times = null;
            update.ticks = null;
        }
        g_pending_updates ~= update;
        return;
    }
    deliver(update);
}

void deliver(ref SampleUpdate update)
{
    for (Subscription* s = update.element._subs; s; )
    {
        Subscription* next = s.next;    // a callback may unsubscribe itself
        if (s.callback != update.who)
            s.callback(update);
        s = next;
    }
}

public:

// the durable cursor: holds an EID, never a pointer - resolves per call and goes quiet
// when the element dies
struct ElementCursor
{
nothrow @nogc:

    EID eid;
    ulong position;
    ubyte bit;

    bool opCast(T : bool)() const pure
        => eid != EID.invalid;

    bool pending()
    {
        Element* e = eid.deref;
        if (!e)
            return false;
        auto c = Cursor(e, position, bit);
        return c.pending;
    }

    RecordBlock next(uint max_records)
    {
        Element* e = eid.deref;
        if (!e)
            return RecordBlock();
        auto c = Cursor(e, position, bit);
        RecordBlock r = c.next(max_records);
        position = c.position;
        return r;
    }

    void close()
    {
        if (Element* e = eid.deref)
        {
            auto c = Cursor(e, position, bit);
            e.close_series_cursor(c);
        }
        eid = EID.invalid;
    }
}


bool sample_to_double(ref const Variant v, out double value)
{
    if (v.isBool)
        value = v.asBool ? 1 : 0;
    else if (v.isQuantity)
        value = v.asQuantity!double().normalise().value;
    else if (v.isNumber)
        value = v.asDouble;
    else
        return false;
    return value == value; // reject NaN
}


unittest
{
    import urt.time : from_unix_time_ns;

    // Element observations always feed their typed series.
    static immutable DataFormat bool_held = DataFormat(ValueType.bool_, SeriesKind.held);
    Element n;
    n.format = register_format(bool_held);
    n.ensure_history();
    bool[2] lv = [true, false];
    SysTime[2] tm = [from_unix_time_ns(1_000_000), from_unix_time_ns(2_000_000)];
    n.write_samples(lv[], tm[]);
    assert(n.record_count == 2);
    assert(n.value.isBool && !n.value.asBool);
    assert(n.last_update == from_unix_time_ns(2_000_000));

    // a boxed write to an Element with a typed series lands in the series too
    n.value(Variant(true), from_unix_time_ns(3_000_000));
    assert(n.record_count == 3);
    assert(n.latest_record.b);
    assert(n.value.asBool);

    // quantity writes to a typed series use the format's unit scale (the
    // profile-binding write format: sample_value produces unit-carrying Variants)
    import urt.si.quantity : Quantity;
    import urt.si.unit : Volt;
    static immutable DataFormat volts_held = DataFormat(ValueType.f64, SeriesKind.held, ScaledUnit(Volt));
    Element q;
    q.format = register_format(volts_held);
    q.value(Variant(Quantity!double(23.05, ScaledUnit(Volt))), from_unix_time_ns(1_000_000));
    assert(q.latest_record.f64_ == 23.05);
    assert(q.value.isQuantity);

    static immutable DataFormat u32_held = DataFormat(ValueType.u32, SeriesKind.held);
    Element widened;
    widened.format = register_format(u32_held);
    widened.write_sample(ushort(42), from_unix_time_ns(1_000_000));
    assert(widened.latest_record.u == 42);
    widened.value(ulong.max, from_unix_time_ns(2_000_000));
    assert(widened.latest_record.u == 42);
}


version (unittest)
private final class CommitReceiver
{
nothrow @nogc:

    Element* a;
    Element* b;
    uint calls;
    uint events;
    SeriesEvent last_event;
    bool coherent = true;

    this(ref Element a, ref Element b)
    {
        this.a = &a;
        this.b = &b;
    }

    void receive(ref const SampleUpdate update)
    {
        ++calls;
        if (update.event != SeriesEvent.none)
        {
            ++events;
            last_event = update.event;
            return;
        }
        // every delivery must see the whole frame already applied
        coherent = coherent && a.latest_record.f64_ == 3.0 && b.latest_record.f64_ == 30.0
                && a.value.asDouble == 3.0 && b.value.asDouble == 30.0;
    }
}


unittest
{
    import urt.time : from_unix_time_ns;

    static immutable DataFormat f64_held = DataFormat(ValueType.f64, SeriesKind.held);

    // one protocol frame can publish several element batches without exposing partial state
    Element tx_a;
    Element tx_b;
    tx_a.format = register_format(f64_held);
    tx_b.format = register_format(f64_held);
    CommitReceiver receiver = defaultAllocator().allocT!CommitReceiver(tx_a, tx_b);
    tx_a.subscribe(&receiver.receive);
    tx_b.subscribe(&receiver.receive);

    double[3] tx_a_values = [1.0, 2.0, 3.0];
    double[3] tx_b_values = [10.0, 20.0, 30.0];
    SysTime[3] tx_times = [from_unix_time_ns(100), from_unix_time_ns(200),
                           from_unix_time_ns(300)];
    {
        CommitScope frame = open_commit();
        tx_a.write_samples(tx_a_values[], tx_times[]);
        tx_b.write_samples(tx_b_values[], tx_times[]);
        assert(receiver.calls == 0);
        assert(tx_a.latest_record.f64_ == 3.0);   // applied eagerly, delivered lazily
    }
    assert(receiver.calls == 2 && receiver.coherent);   // one delivery per update, all post-frame

    // the bare pair is the same machinery; held dedup and event deferral apply inside a scope
    begin_commit();
    tx_a.write_sample(3.0, from_unix_time_ns(400));   // equal held value publishes nothing
    tx_b.write_sample(40.0, from_unix_time_ns(400));
    tx_b.mark_gap();
    assert(receiver.calls == 2);
    end_commit();
    assert(receiver.calls == 4);
    assert(receiver.events == 1 && receiver.last_event == SeriesEvent.gap);

    tx_a.write_sample(4.0, from_unix_time_ns(500), &receiver.receive);
    assert(receiver.calls == 4);

    tx_a.unsubscribe(&receiver.receive);
    tx_b.unsubscribe(&receiver.receive);
    tx_a.teardown();
    tx_b.teardown();
    defaultAllocator().freeT(receiver);

    // retention=none: latest and last_update track, nothing is stored
    Element n;
    n.format = register_format(f64_held);
    n.write_sample(9.0, from_unix_time_ns(500));
    assert(n.record_count == 0 && n.bucket_count == 0);
    assert(n.latest_record.f64_ == 9.0);
    assert(n.last_update == from_unix_time_ns(500));

    // held series: equal observations advance last_update but record nothing
    Element e;
    e.format = register_format(f64_held);
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
    Cursor c = e.open_series_cursor(0);
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
    assert(e.latest_record.f64_ == 6.0);
    b = c.next(16);
    assert(b.count == 3 && b.ts !is null && b.time(2) == from_unix_time_ns(13_000));
    e.close_series_cursor(c);

    // untyped record write: same flow as write_sample(), format known only at runtime
    double rv = 7.0;
    e.write_record((cast(const(void)*)&rv)[0 .. 8], from_unix_time_ns(14_000));
    assert(e.record_count == 7);
    assert(e.latest_record.f64_ == 7.0);

    // text: short strings embed in the record, long strings allocate a String; equal held values reuse it
    DataFormat text_fmt = DataFormat(ValueType.char_, SeriesKind.held);
    text_fmt.count = 0;
    Element te;
    te.format = register_format(text_fmt);
    te.ensure_history();
    te.write_sample("run", from_unix_time_ns(500));
    assert(te.record_count == 1);
    assert((cast(const(TextRecord)*)te.latest_record.raw.ptr).embedded);
    assert(te.value().asString == "run");

    te.write_sample("a string too long to embed anywhere", from_unix_time_ns(1_000));
    assert(te.record_count == 2);
    assert(!(cast(const(TextRecord)*)te.latest_record.raw.ptr).embedded);
    assert(te.value().asString == "a string too long to embed anywhere");
    const(char)* allocated = (cast(const(String)*)te.latest_record.raw.ptr).ptr;
    te.write_sample("a string too long to embed anywhere", from_unix_time_ns(2_000));
    assert(te.record_count == 2);
    assert((cast(const(String)*)te.latest_record.raw.ptr).ptr is allocated);
    assert(te.last_update == from_unix_time_ns(2_000));

    // String ingress adopts the handle; retained refs are the typed latest slot
    // and the bucket record.
    String src = "second value arriving as a shared handle".makeString(defaultAllocator());
    static ushort rc(ref const String s) => (cast(const(ushort)*)s.ptr)[-2] & 0x3FFF;
    assert(rc(src) == 0);
    te.write_sample(src, from_unix_time_ns(3_000));
    assert(te.record_count == 3);
    assert(rc(src) == 2);
    assert(te.value().asString == src[]);

    Cursor tcur = te.open_series_cursor(0);
    RecordBlock tblk = tcur.next(16);
    assert(tblk.count == 3);
    assert(tblk.box(0).asString == "run");
    assert(tblk.box(1).asString == "a string too long to embed anywhere");
    assert(tblk.box(2).asString == src[]);
    te.close_series_cursor(tcur);

    te.teardown();
    assert(rc(src) == 0);

    Element text_batch;
    text_batch.format = register_format(text_fmt);
    text_batch.ensure_history();
    const(char)[][2] words = ["one", "two"];
    SysTime[2] word_times = [from_unix_time_ns(4_000), from_unix_time_ns(5_000)];
    text_batch.write_samples(words[], word_times[]);
    assert(text_batch.record_count == 2);
    assert(text_batch.value().asString == "two");
    text_batch.teardown();

    // retention: sealed buckets shrink to fit, the budget evicts from the front, lapped cursors report loss
    Element r;
    r.format = register_format(f64_held);
    r.retention(4);
    Cursor lap = r.open_series_cursor(0);
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
    r.close_series_cursor(lap);
    r.teardown();

    // pinned cursor: holds retention past the floor until consumed; consumption releases
    Element p;
    p.format = register_format(f64_held);
    p.retention(2);
    Cursor pinc = p.open_series_cursor(0, true);
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
    p.close_series_cursor(pinc);
    p.teardown();

    // ceiling: max_records evicts past a stalled pin; the lapped cursor reports the loss
    Element x;
    x.format = register_format(f64_held);
    x.retention(0, 3);
    Cursor stall = x.open_series_cursor(0, true);
    foreach (i; 0 .. 6)
    {
        x.write_sample(double(i), from_unix_time_ns(1_000 * (i + 1)));
        x.mark_gap();
    }
    assert(x._history.first_index == 3);
    RecordBlock xb = stall.next(16);
    assert(xb.lost == 3 && xb.count == 1 && xb.get!double(0) == 3.0);
    x.close_series_cursor(stall);
    x.teardown();

    // age floor: consumed-or-unpinned records older than the window evict
    Element a;
    a.format = register_format(f64_held);
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
    Element k;
    k.format = register_format(key_fmt);
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
    Cursor kc = k.open_series_cursor(0);
    RecordBlock kb = kc.next(16);
    assert(kb.count == 2);
    assert(cast(const(ubyte)[])kb.box(0).asBuffer == key1[]);
    assert(cast(const(ubyte)[])kb.box(1).asBuffer == key2[]);
    k.close_series_cursor(kc);
    k.teardown();

    // eviction releases text records
    Element tv;
    tv.format = register_format(text_fmt);
    tv.retention(1);
    String evictee = "the first long string, soon evicted".makeString(defaultAllocator());
    tv.write_sample(evictee, from_unix_time_ns(1_000));
    assert(rc(evictee) == 2);
    tv.mark_gap();
    tv.write_sample("replacement value, also quite long", from_unix_time_ns(2_000));
    assert(rc(evictee) == 0);
    tv.teardown();
    assert(rc(evictee) == 0);

    // TODO: regular-series test returns once regular write_records() and rate-aware tick() are built
}
