module manager.element;

// Elements host the typed series (manager.series) and publish changes to subscribers.
//
// Readers take one of two forms. A Cursor is an incremental reader: it holds a stable id into
// the store's CursorSlot array, where its retention hold lives, so a pinned cursor keeps
// buckets alive until it has consumed them. read_records() is the cursor-less form: random
// access by index, no pin, subject to eviction between calls.
//
// TODO: durable cursor holders keep a raw Element* across frames (the recorder is the only
// one). That is safe solely because elements are never destroyed today - teardown() has no
// production caller, Device.~this only clears computations, and ElementLifecycleEvent.destroyed
// is never signalled, so a removed device leaks its elements rather than freeing them. When
// element destruction becomes real (device removal, profile reload, dynamic per-VIN sessions),
// durable holders must key by EID and deref per use, or they dangle. An EID-keyed cursor
// wrapper existed for exactly this, went unused for lack of a lifecycle to defend against,
// and was deleted; rebuild it there rather than inferring the pattern anew.

import urt.array;
import urt.lifetime;
import urt.log : writeWarning;
import urt.mem.alloc;
import urt.mem.allocator : defaultAllocator;
import urt.mem.string;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.time;
import urt.traits : Unqual;
import urt.variant;

import manager.component;
import manager.device;
public import manager.series;
import manager.id : EID;

nothrow @nogc:


alias Subscriber = void delegate(ref const SampleUpdate update) nothrow @nogc;

enum ElementLifecycleEvent : ubyte
{
    created,
    destroyed,
}

alias ElementLifecycleHandler = void delegate(Element* e, ElementLifecycleEvent event) nothrow @nogc;

void register_element_lifecycle_handler(ElementLifecycleHandler handler)
{
    _on_element_lifecycle ~= handler;
}

// Live model feeds: while any listener is registered, every element write enlists in
// the per-tick dirty sweep; otherwise only cursor-bearing elements do.
void add_feed_listener()
{
    ++g_feed_listeners;
}

void remove_feed_listener()
{
    debug assert(g_feed_listeners, "unbalanced remove_feed_listener");
    --g_feed_listeners;
}

void sweep_dirty(scope void delegate(ref Element) nothrow @nogc visit)
{
    // writes during a visit re-enlist into a fresh list for the next sweep
    Array!(Element*) list = g_dirty_elements.move;
    foreach (e; list)
    {
        e._status &= ~Element.Flags.dirty_listed;
        visit(*e);
    }
}

struct SampleUpdate
{
nothrow @nogc:

    Element* element;
    const(void)[] records;
    const(SysTime)[] times;
    const(ulong)[] ticks;
    Subscriber who;
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
// Writes made by subscribers during the flush queue into a follow-up wave, so cascades
// (links, computations) also deliver whole frames.
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
    flush_pending();
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
    // TODO: per-subscriber deadband band + anchor live here (see TODO.md element deadband)
}

struct Cursor
{
nothrow @nogc:

    Element* element;
    ulong position;
    ubyte id;

    bool pending() const
        => element._history && element._history.head > position;

    void seek(ulong pos)
    {
        SeriesStore* h = element._history;
        if (pos > h.head)
            pos = h.head;
        position = pos;
        CursorSlot* slot = h.find_cursor(id);
        if (slot.pinned)
            slot.pin_position = pos;
    }

    RecordBlock next(uint max_records)
    {
        SeriesStore* h = element._history;
        CursorSlot* slot = h.find_cursor(id);
        RecordBlock r = h.read(element.format, position, max_records, slot);
        if (r.count)
        {
            r.lost = r.first_index - position;  // records evicted or destroyed below the block
            position = r.first_index + r.count;
        }
        if (slot.pinned)
            slot.pin_position = position;
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

    // access, sampling_mode and Flags share one byte: it sits in the alignment hole before
    // `format`, so a separate flags byte would cost 8. Hand-packed because DMD's
    // -preview=bitfields silently drops `|=` and `&=` on bitfield members (LDC honours them).
    private ubyte _status;
    private FormatId _format = FormatId.invalid;    // paired with _status to fill one slot

    static assert(Access.max <= 3 && SamplingMode.max <= 7 && Flags.min >= 1 << 5,
                  "the status byte is full");

    Access access() const pure
        => cast(Access)(_status & 3);
    void access(Access value)
    {
        _status = cast(ubyte)((_status & ~3) | value);
    }

    SamplingMode sampling_mode() const pure
        => cast(SamplingMode)((_status >> 2) & 7);
    void sampling_mode(SamplingMode value)
    {
        _status = cast(ubyte)((_status & ~0x1C) | (value << 2));
    }

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

    T read(T)() const
    {
        static if (is(T == String))
        {
            debug assert(data_format.is_text, "element does not hold text");
            debug assert(!_history, "text series has no String handle; read const(char)[]");
            return _last_update == SysTime() ? String() : text_register;
        }
        else static if (is(T : const(char)[]))
        {
            debug assert(data_format.is_text, "element does not hold text");
            return text_value();
        }
        else
        {
            debug assert(data_format.is_scalar, "element record does not fit the scalar register");
            debug assert(scalar_type!T == data_format.type, "element type mismatch");
            static if (is(Unqual!T == Duration))
                return nsecs(*cast(const(long)*)_latest.raw.ptr);
            else
                return *cast(const(T)*)_latest.raw.ptr;
        }
    }

    const(char)[] try_write(T)(auto ref T v, SysTime t = getSysTime(), Subscriber who = null)
    {
        assert(format.valid, "element has no data format");
        static if (is(T == String) || is(T : const(char)[]))
        {
            if (!data_format.is_text)
                return "incompatible value";
            store_sample(v, t, who);
            return null;
        }
        else
        {
            if (!data_format.is_scalar || scalar_type!T != data_format.type)
                return "incompatible value";
            static if (is(T Base == enum))
                Scalar s = Scalar.of(cast(Base)v);
            else
                Scalar s = Scalar.of(v);
            if (const(char)[] error = data_format.constraint ? data_format.constraint.check(s, *data_format) : null)
                return error;
            store_record(s.raw[0 .. data_format.stride], t, who);
            return null;
        }
    }

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

    // checked write for external writers (console, sync set, property setters); null = stored
    const(char)[] try_set(ref const Variant v, SysTime timestamp = getSysTime(), Subscriber who = null)
    {
        assert(format.valid, "element has no data format");
        return update_typed_series(v, timestamp, who);
    }

    private const(char)[] update_typed_series(ref const Variant v, SysTime timestamp, Subscriber who)
    {
        if (data_format.is_text)
        {
            if (!v.isString)
                return "incompatible value";
            store_sample(v.asString(), timestamp, who);
            return null;
        }
        if (data_format.is_wide)
        {
            if (v.isBuffer)
            {
                const(void)[] b = v.asBuffer;
                if (b.length == data_format.stride)
                {
                    store_record(b, timestamp, who);
                    return null;
                }
            }
            return "incompatible value";
        }
        Scalar s;
        if (const(char)[] error = unbox_scalar_checked(v, *data_format, s))
            return error;
        store_record(s.raw[0 .. data_format.stride], timestamp, who);
        return null;
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

    FormatId format() const pure
        => _format;

    // the format decides how _latest is read, so a change has to hand the register over:
    // a text register holds an owned String, and releasing scalar bytes as one corrupts the heap
    void format(FormatId value)
    {
        if (value == _format)
            return;
        release_register();
        _latest.raw[] = 0;
        _format = value;
    }

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
            if (data_format.is_scalar)
                return box_record(_latest.raw.ptr, *data_format);
            if (data_format.is_text)
                return Variant(text_value());
            if (data_format.is_wide)
            {
                const(void)[] tail = tail_record();
                if (tail)
                    return box_record(tail.ptr, *data_format);
            }
        }
        return Variant();
    }

    // Without a store the value is a String held in the record register, and the slice is stable
    // until the next write to this element. With a store it borrows the open bucket's heap, which
    // the next write may reallocate.
    const(char)[] text_value() const pure
    {
        if (!format.valid || !data_format.is_text || _last_update == SysTime())
            return null;
        if (!_history)
            return text_register[];
        if (!_history.buckets.length)
            return null;
        const(Bucket)* b = _history.buckets[$-1];
        if (!b.count || !b.samples)
            return null;
        return cast(const(char)[])heap_view(b.heap, (cast(const(ushort)*)b.samples)[b.count - 1]);
    }

    // Wide records don't fit the Scalar register. Without a store the register points at one
    // owned stride-sized buffer, overwritten in place; with a store latest is the open bucket's
    // tail record.
    const(void)[] tail_record() const pure
    {
        if (!format.valid || !data_format.is_wide)
            return null;
        if (!_history)
        {
            const(void)* held = wide_register();
            return held ? held[0 .. data_format.stride] : null;
        }
        if (!_history.buckets.length)
            return null;
        const(Bucket)* b = _history.buckets[$-1];
        if (!b.count || !b.samples)
            return null;
        ubyte stride = format_info(b.format).stride;
        return (cast(const(ubyte)*)b.samples)[(b.count - 1) * stride .. b.count * stride];
    }

    void store_sample(T)(T v, SysTime t = getSysTime(), Subscriber who = null)
    {
        static if (is(T == String))
            write_text_sample(v[], t, who, v);
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
        {
            debug assert(!data_format.regular);
        }
        else
        {
            debug assert(data_format.uses_device_ticks);
        }
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

    void mark_series_gap(Subscriber who = null)
    {
        if (_status & Flags.gap_open)
            return;
        _status |= Flags.gap_open;
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

            // a held register value becomes record 0; the store owns it from here and the
            // register releases, so only one of the two ever holds the value
            if (format.valid && _last_update != SysTime())
            {
                if (data_format.is_text)
                {
                    if (text_register().length)
                    {
                        append_text(text_register()[], unix_time_ns(_last_update) / 1000);
                        release_register();
                    }
                }
                else if (data_format.is_wide && wide_register())
                {
                    SysTime[1] held_time = _last_update;
                    append(wide_register()[0 .. data_format.stride], held_time[]);
                    release_register();
                }
            }
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
        ulong position = from_index > s.head ? s.head : from_index;
        return Cursor(&this, position, s.open_cursor(position, pin));
    }

    void close_series_cursor(ref Cursor c)
    {
        if (_history)
        {
            _history.release_cursor(c.id);
            _history.drop_loose_raws();
        }
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
        // deferred machinery holds raw Element pointers; a dying element must vanish from both
        if (_status & Flags.dirty_listed)
        {
            g_dirty_elements.removeFirstSwapLast(&this);
            _status &= ~Flags.dirty_listed;
        }
        for (size_t i = 0; i < g_pending_updates.length; )
        {
            if (g_pending_updates[i].element is &this)
                g_pending_updates.remove(i);
            else
                ++i;
        }

        release_register();
        if (_history)
        {
            foreach (b; _history.buckets)
                _history.free_bucket(b);
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
    // the top three bits of _status; access and sampling_mode own the low five
    enum Flags : ubyte
    {
        gap_open     = 1 << 5,
        dirty_listed = 1 << 6,
    }

    Scalar _latest;
    SysTime _last_update;
    Subscription* _subs;
    SeriesStore* _history;

    enum bucket_capacity = 256; // TODO: scale with rate (target a time span, not a record count)
    enum text_bucket_capacity = 64;     // text series are low-rate; keep resident buckets small
    enum text_heap_limit = 0x1_0000;    // u16 record offsets address the bucket heap

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
        if (t > _last_update)
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
        else if (!_history)
        {
            // no history: the newest record overwrites the register buffer in place, so a value
            // rewritten forever (a display buffer, a key) neither appends nor reallocates
            set_wide_register((cast(const(ubyte)[])update.records)[$ - data_format.stride .. $]);
        }

        if (update.times.length)
        {
            _last_update = update.times[$-1];
            append(update.records, update.times);
        }
        else
        {
            _last_update = data_format.clock.to_wall(update.ticks[$-1]);
            append(update.records, update.ticks);
        }
    }

    // `handle` is the caller's String when it has one: with no store the register keeps it
    // rather than copying, which is what makes a profile literal cost nothing at all
    void write_text_sample(const(char)[] v, SysTime t, Subscriber who, String handle = String())
    {
        debug assert(data_format.is_text);
        if (v.length > MaxStringLen)
        {
            writeWarning("text sample refused (exceeds 32k): element '", id, "'");
            return;
        }
        if (held_repeat(text_value() == v, t))
            return;
        Variant previous;
        if (_subs)
            previous = record_value();
        SysTime previous_timestamp = last_update;

        if (_history)
            append_text(v, unix_time_ns(t) / 1000);
        else
        {
            set_text_register(handle ? handle.move : v.makeString(defaultAllocator()));
            _status &= ~Flags.gap_open;
            mark_dirty();
        }
        _last_update = t;

        SampleUpdate update;
        update.element = &this;
        update.who = who;
        update.previous = previous.move;
        update.previous_timestamp = previous_timestamp;
        prepare_after(update);
        submit(update, false);
    }

    // A non-scalar element with no store keeps its latest value in the record register instead:
    // text as an owned String handle, wide as one stride-sized buffer. The register and the store
    // are never both live, so there is one value and one write path at any moment.
    ref inout(String) text_register() inout pure
        => *cast(inout(String)*)_latest.raw.ptr;

    void set_text_register(String v)
    {
        String* p = &text_register();
        *p = null;
        moveEmplace(v, *p);
    }

    ref inout(void)* wide_register() inout pure
        => *cast(inout(void)**)_latest.raw.ptr;

    void set_wide_register(const(void)[] record)
    {
        void** p = cast(void**)_latest.raw.ptr;
        if (!*p)
            *p = alloc(record.length).ptr;      // stride is fixed per format; allocated once
        (cast(ubyte*)*p)[0 .. record.length] = cast(const(ubyte)[])record;
    }

    void release_register()
    {
        if (!format.valid)
            return;
        if (data_format.is_text)
            text_register() = null;
        else if (data_format.is_wide)
        {
            if (void* held = wide_register())
                free(held[0 .. data_format.stride]);
            wide_register() = null;
        }
    }

    ulong append_text(const(char)[] v, ulong tick)
    {
        bool follows_gap = (_status & Flags.gap_open) != 0;
        _status &= ~Flags.gap_open;

        SeriesStore* h = _history;
        Bucket* b = h.buckets.length ? h.buckets[$-1] : null;

        uint entry = uint.max;
        if (b)
        {
            bool format_changed = b.format != format;
            bool roll = b.count + 1 > b.capacity || follows_gap || format_changed
                     || (b.count && tick - b.first_tick > uint.max);
            if (!roll)
            {
                entry = find_heap_entry(*b, v);
                if (entry == uint.max && b.heap_used + heap_entry_bytes(v.length) > text_heap_limit)
                    roll = true;
            }
            if (roll)
            {
                retire_tail(b);
                if (format_changed)
                    fire_format_change();
                b = null;
                entry = uint.max;
            }
        }
        if (!b)
        {
            b = alloc_bucket(text_bucket_capacity);
            b.first_index = h.head;
            b.follows_gap = follows_gap;
            h.buckets ~= b;
        }
        if (b.count == 0)
            b.first_tick = tick;
        if (entry == uint.max)
            entry = add_heap_entry(*b, v);
        (cast(ushort*)b.samples)[b.count] = cast(ushort)entry;
        b.offsets[b.count] = cast(uint)(tick - b.first_tick);
        ++b.count;
        b.last_offset = b.offsets[b.count - 1];

        ulong first_index = h.head;
        ++h.head;
        evict_over_budget();
        mark_dirty();
        return first_index;
    }

    // the bucket heap: 2-aligned len-prefixed values, content-matched so repeated values
    // share one entry; the record plane stays fixed-stride u16 offsets
    static uint find_heap_entry(ref const Bucket b, const(void)[] v) pure
    {
        uint pos = 0;
        while (pos < b.heap_used)
        {
            const(void)[] e = heap_view(b.heap, pos);
            if (e == v)
                return pos;
            pos += heap_entry_bytes(e.length);
        }
        return uint.max;
    }

    static uint add_heap_entry(ref Bucket b, const(void)[] v)
    {
        uint need = heap_entry_bytes(v.length);
        if (b.heap_used + need > b.heap_capacity)
        {
            uint cap = b.heap_capacity ? b.heap_capacity : 64;
            while (cap < b.heap_used + need)
                cap *= 2;
            if (cap > text_heap_limit)
                cap = text_heap_limit;
            b.heap = b.heap ? realloc(b.heap[0 .. b.heap_capacity], cap).ptr : alloc(cap).ptr;
            b.heap_capacity = cap;
        }
        ushort* p = cast(ushort*)(cast(ubyte*)b.heap + b.heap_used);
        *p = cast(ushort)v.length;
        (cast(ubyte*)(p + 1))[0 .. v.length] = cast(const(ubyte)[])v[];
        if (v.length & 1)
            (cast(ubyte*)(p + 1))[v.length] = 0;
        uint offset = b.heap_used;
        b.heap_used += need;
        return offset;
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

        bool follows_gap = (_status & Flags.gap_open) != 0;
        _status &= ~Flags.gap_open;

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
        bool format_changed = b && b.format != format;
        if (!b || b.count + n > b.capacity || follows_gap || overflow || format_changed)
        {
            if (b)
            {
                retire_tail(b);
                if (format_changed)
                    fire_format_change();
            }
            b = alloc_bucket(n > bucket_capacity ? n : bucket_capacity);
            b.first_index = _history.head;
            b.follows_gap = follows_gap;
            _history.buckets ~= b;
        }
        return b;
    }

    // roll the tail out of the write path: a non-empty tail seals, an empty one is recycled
    // so sealed buckets always carry records
    void retire_tail(Bucket* b)
    {
        debug assert(_history.buckets.length && _history.buckets[$-1] is b);
        if (b.count || b.sealed)
            _history.seal(b);
        else
        {
            _history.free_bucket(b);
            _history.buckets.popBack();
        }
    }

    void fire_format_change()
    {
        SampleUpdate update;
        update.element = &this;
        update.event = SeriesEvent.format_change;
        update.timestamp = _last_update;
        submit(update, false);
    }

    // Retention splits by residency: a flushed bucket's eviction drops its bytes and keeps
    // the descriptor (recoverable through the container), so the policy governs what stays
    // decoded in RAM. Where there is no backing copy, eviction destroys, exactly as before;
    // under a container, unflushed sealed buckets are held for the recorder.
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
        for (size_t i = 0; i + 1 < h.buckets.length; )
        {
            Bucket* front = h.buckets[i];
            bool flushed = front.file_offset != 0;
            if (flushed && !front.resident)
            {
                ++i;
                continue;
            }
            if (!front.sealed)
                break;
            ulong newest = h.buckets[$-1].last_tick;
            bool forced = (h.max_records && h.head - front.first_index > h.max_records)
                       || (max_age_ticks && newest - front.last_tick > max_age_ticks);
            if (!forced)
            {
                if (!h.min_records && !h.min_age)
                    break;
                if (!flushed && front.first_index + front.count > floor)
                    break;
                if (h.min_records && h.head - front.first_index - front.count < h.min_records)
                    break;
                if (min_age_ticks && newest - front.last_tick <= min_age_ticks)
                    break;
            }
            if (flushed)
            {
                if (front.refs)
                {
                    ++i;    // borrowed; the release drops it
                    continue;
                }
                if (front.packed)
                {
                    free(front.packed[0 .. front.packed_bytes]);
                    front.packed = null;
                }
                h.drop_raw(front);
                ++i;
            }
            else if (h.container)
                break;      // the only copy; the recorder flushes it shortly
            else
            {
                h.free_bucket(front);
                h.buckets.remove(i);
            }
        }
    }

    Bucket* alloc_bucket(uint capacity)
    {
        Bucket* b = cast(Bucket*)alloc(Bucket.sizeof).ptr;
        *b = Bucket.init;
        b.format = format;
        b.capacity = capacity;
        b.samples = alloc(capacity * data_format.stride).ptr;
        if (!data_format.regular)
            b.offsets = cast(uint*)alloc(capacity * uint.sizeof).ptr;
        return b;
    }

    void mark_dirty()
    {
        if (!(_history && _history.cursors.length) && !g_feed_listeners)
            return;
        if (!(_status & Flags.dirty_listed))
        {
            g_dirty_elements ~= &this;
            _status |= Flags.dirty_listed;
        }
    }
}


package:

__gshared Array!(Element*) g_dirty_elements;

void signal_element_lifecycle(Element* e, ElementLifecycleEvent event)
{
    foreach (h; _on_element_lifecycle[])
        h(e, event);
}



private:

__gshared Array!ElementLifecycleHandler _on_element_lifecycle;
__gshared uint g_feed_listeners;
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
    ++g_commit_depth;
    deliver(update);
    --g_commit_depth;
    flush_pending();
}

void flush_pending()
{
    while (!g_pending_updates.empty)
    {
        Array!SampleUpdate updates = g_pending_updates.move;
        ++g_commit_depth;
        foreach (ref update; updates)
            deliver(update);
        --g_commit_depth;
    }
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

    // try_set reports refusals and stores nothing; in-range values store
    __gshared Constraint volt_range;
    volt_range.min = Scalar.of(1.0);
    volt_range.max = Scalar.of(5.0);
    volt_range.has = Constraint.Has.min | Constraint.Has.max;
    DataFormat constrained_fmt = DataFormat(ValueType.f64, SeriesKind.held);
    constrained_fmt.constraint = &volt_range;
    Element ce;
    ce.format = register_format(constrained_fmt);
    Variant too_big = Variant(9.0);
    assert(ce.try_set(too_big) == "above maximum");
    assert(ce.last_update == SysTime());
    Variant in_range = Variant(3.0);
    assert(ce.try_set(in_range) is null);
    assert(ce.latest_record.f64_ == 3.0);
    Variant wrong_type = Variant("volts");
    assert(ce.try_set(wrong_type) == "incompatible value");
    assert(ce.latest_record.f64_ == 3.0);
}


version (unittest)
{
    // byte-level RLE test codec: [run u8][value u8]*; enough to exercise pack/reconstitute
    private __gshared bool g_rle_codec_on;

    private bool rle_match(ref const DataFormat, ref const RecordBlock) nothrow @nogc
        => g_rle_codec_on;

    private ptrdiff_t rle_pack(ref const RecordBlock, const(void)[] raw, void[] dst) nothrow @nogc
    {
        const(ubyte)[] s = cast(const(ubyte)[])raw;
        ubyte[] d = cast(ubyte[])dst;
        size_t o;
        for (size_t i = 0; i < s.length; )
        {
            size_t run = 1;
            while (i + run < s.length && s[i + run] == s[i] && run < 255)
                ++run;
            if (o + 2 > d.length)
                return -1;
            d[o++] = cast(ubyte)run;
            d[o++] = s[i];
            i += run;
        }
        return o;
    }

    private bool rle_unpack(const(void)[] src, ref const DataFormat, uint, bool, uint, void[] dst) nothrow @nogc
    {
        const(ubyte)[] s = cast(const(ubyte)[])src;
        ubyte[] d = cast(ubyte[])dst;
        size_t o;
        for (size_t i = 0; i + 2 <= s.length; i += 2)
        {
            size_t run = s[i];
            if (o + run > d.length)
                return false;
            d[o .. o + run] = s[i + 1];
            o += run;
        }
        return o == d.length;
    }
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

    // text: records are u16 heap offsets; repeated values share one dedup'd heap entry
    enum long_str = "a string much too long for any embedding tricks";
    DataFormat text_fmt = DataFormat(ValueType.char_, SeriesKind.held);
    text_fmt.count = 0;
    Element te;
    te.format = register_format(text_fmt);
    te.ensure_history();
    te.write_sample("run", from_unix_time_ns(500));
    assert(te.record_count == 1);
    assert(te.text_value == "run");
    assert(te.value().asString == "run");

    te.write_sample(long_str, from_unix_time_ns(1_000));
    assert(te.record_count == 2);
    assert(te.value().asString == long_str);
    te.write_sample(long_str, from_unix_time_ns(2_000));
    assert(te.record_count == 2);   // held repeat records nothing
    assert(te.last_update == from_unix_time_ns(2_000));

    // a bouncing value reuses its heap entry: 3 records, 2 entries
    te.write_sample("run", from_unix_time_ns(3_000));
    assert(te.record_count == 3);
    const(Bucket)* tb = te._history.buckets[$-1];
    assert(tb.heap_used == heap_entry_bytes(3) + heap_entry_bytes(long_str.length));
    assert((cast(const(ushort)*)tb.samples)[0] == (cast(const(ushort)*)tb.samples)[2]);

    // String ingress stores content; the series retains no handles
    String src = "second value arriving as a shared handle".makeString(defaultAllocator());
    static ushort rc(ref const String s) => (cast(const(ushort)*)s.ptr)[-2] & 0x3FFF;
    assert(rc(src) == 0);
    te.write_sample(src, from_unix_time_ns(4_000));
    assert(te.record_count == 4);
    assert(rc(src) == 0);
    assert(te.value().asString == src[]);

    Cursor tcur = te.open_series_cursor(0);
    RecordBlock tblk = tcur.next(16);
    assert(tblk.count == 4);
    assert(tblk.box(0).asString == "run");
    assert(tblk.text(1) == long_str);
    assert(tblk.box(2).asString == "run");
    assert(tblk.box(3).asString == src[]);
    te.close_series_cursor(tcur);

    te.teardown();

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

    // concurrent cursors: a reader's id stays bound to it as other slots come and go
    Element m;
    m.format = register_format(f64_held);
    m.retention(1);
    Cursor pinned = m.open_series_cursor(0, true);
    Cursor tail = m.open_series_cursor(0);
    assert(pinned.id != tail.id);
    foreach (i; 0 .. 4)
    {
        m.write_sample(double(i), from_unix_time_ns(1_000 * (i + 1)));
        m.mark_gap();
    }
    assert(m._history.first_index == 0);
    assert(tail.next(16).get!double(0) == 0.0);
    assert(tail.next(16).get!double(0) == 1.0);
    assert(m._history.first_index == 0);     // an unpinned reader moves no floor

    // closing the front slot shifts the survivor down; its id must still find it
    m.close_series_cursor(pinned);
    assert(tail.next(16).get!double(0) == 2.0);
    m.write_sample(9.0, from_unix_time_ns(9_000));
    assert(m._history.first_index == 4);     // the pin left with its cursor, and the lapped
                                             // reader's borrow died with its bucket
    Cursor reused = m.open_series_cursor(0);
    assert(reused.id == pinned.id);
    m.close_series_cursor(reused);
    m.close_series_cursor(tail);
    m.teardown();

    // two pins: the floor follows the laggard, not the leader
    Element mp;
    mp.format = register_format(f64_held);
    mp.retention(1);
    Cursor lead = mp.open_series_cursor(0, true);
    Cursor lag = mp.open_series_cursor(0, true);
    foreach (i; 0 .. 4)
    {
        mp.write_sample(double(i), from_unix_time_ns(1_000 * (i + 1)));
        mp.mark_gap();
    }
    foreach (_; 0 .. 3)
        lead.next(1);
    mp.write_sample(4.0, from_unix_time_ns(5_000));
    assert(mp._history.first_index == 0);
    mp.close_series_cursor(lag);
    mp.write_sample(5.0, from_unix_time_ns(6_000));
    assert(mp._history.first_index == 3);
    mp.close_series_cursor(lead);
    mp.teardown();

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

    // wide records: fixed vectors don't fit the Scalar register. With no history the register
    // owns one buffer that every write overwrites in place, so a value rewritten forever
    // (a display buffer, a key) never appends and never reallocates.
    DataFormat key_fmt = DataFormat(ValueType.u8, SeriesKind.held);
    key_fmt.count = 32;
    assert(!key_fmt.is_scalar && !key_fmt.is_text && key_fmt.is_wide && key_fmt.stride == 32);
    Element k;
    k.format = register_format(key_fmt);
    ubyte[32] key1;
    foreach (i, ref byt; key1)
        byt = cast(ubyte)i;
    k.write_record(key1[], from_unix_time_ns(1_000));
    assert(!k.has_history && k.record_count == 0);
    assert(cast(const(ubyte)[])k.value().asBuffer == key1[]);
    k.write_record(key1[], from_unix_time_ns(2_000));
    assert(k.last_update == from_unix_time_ns(2_000));   // held dedup vs the register
    ubyte[32] key2 = key1;
    key2[0] = 0xFF;
    const(void)* key_buffer = k.wide_register;
    foreach (i; 0 .. 64)
        k.write_record(i & 1 ? key2[] : key1[], from_unix_time_ns(3_000 + i));
    assert(!k.has_history && k.record_count == 0);       // rewritten 64 times, still no store
    assert(k.wide_register is key_buffer);               // and still the same buffer
    assert(cast(const(ubyte)[])k.value().asBuffer == key2[]);
    assert(cast(const(ubyte)[])k.tail_record() == key2[]);

    // expressing history interest migrates the held record into record 0, and the store owns
    // it from there: the register releases its buffer
    k.retention(4);
    assert(k.record_count == 1 && k.wide_register is null);
    assert(cast(const(ubyte)[])k.tail_record() == key2[]);
    k.write_record(key1[], from_unix_time_ns(4_000));
    assert(k.record_count == 2);
    Cursor kc = k.open_series_cursor(0);
    RecordBlock kb = kc.next(16);
    assert(kb.count == 2);
    assert(cast(const(ubyte)[])kb.box(0).asBuffer == key2[]);
    assert(cast(const(ubyte)[])kb.box(1).asBuffer == key1[]);
    k.close_series_cursor(kc);
    k.teardown();

    // text without requested history: the value lives in the record register, no store at all
    Element tv;
    tv.format = register_format(text_fmt);
    tv.write_sample("first", from_unix_time_ns(1_000));
    assert(!tv.has_history && tv.record_count == 0);
    assert(tv.text_value == "first");
    assert(tv.value().asString == "first");
    tv.write_sample("a rather longer second value", from_unix_time_ns(2_000));
    assert(!tv.has_history);
    assert(tv.text_value == "a rather longer second value");
    assert(tv.last_update == from_unix_time_ns(2_000));

    // held dedup still applies against the register
    tv.write_sample("a rather longer second value", from_unix_time_ns(2_500));
    assert(tv.last_update == from_unix_time_ns(2_500));

    // expressing history interest migrates the held value into record 0, and the store owns
    // it from there: the register drops its reference
    tv.retention(4);
    assert(tv.record_count == 1 && tv.bucket_count == 1);
    assert(tv.text_register[].length == 0);
    assert(tv.text_value == "a rather longer second value");
    tv.write_sample("third", from_unix_time_ns(3_000));
    assert(tv.record_count == 2);
    Cursor tvc = tv.open_series_cursor(0);
    RecordBlock tvb = tvc.next(16);
    assert(tvb.count == 2 && tvb.text(0) == "a rather longer second value" && tvb.text(1) == "third");
    tv.close_series_cursor(tvc);
    tv.teardown();

    // a String handle is kept, not copied: the element takes a reference and releases it
    Element th_lit;
    th_lit.format = register_format(text_fmt);
    String shared_value = "a shared handle".makeString(defaultAllocator());
    assert(rc(shared_value) == 0);
    th_lit.write_sample(shared_value, from_unix_time_ns(1_000));
    assert(!th_lit.has_history);
    assert(rc(shared_value) == 1);                      // stored by reference, no copy
    assert(th_lit.text_value.ptr is shared_value.ptr);
    th_lit.teardown();
    assert(rc(shared_value) == 0);                      // teardown released it

    // a literal costs no allocation and touches no refcount
    Element lit;
    lit.format = register_format(text_fmt);
    String brand = StringLit!"Fronius";
    assert(!brand.has_rc);
    lit.write_sample(brand, from_unix_time_ns(1_000));
    assert(lit.text_value == "Fronius" && lit.text_value.ptr is brand.ptr);
    lit.teardown();

    // a register write still enlists in the dirty sweep: no store must not mean no live feed
    Element text_feed;
    Element wide_feed;
    text_feed.format = register_format(text_fmt);
    wide_feed.format = register_format(key_fmt);
    uint swept;
    void count_swept(ref Element) nothrow @nogc { ++swept; }
    sweep_dirty(&count_swept);      // drain anything earlier tests enlisted
    swept = 0;
    add_feed_listener();
    text_feed.write_sample("online", from_unix_time_ns(1_000));
    wide_feed.write_record(key1[], from_unix_time_ns(1_000));
    remove_feed_listener();
    sweep_dirty(&count_swept);
    assert(swept == 2);
    assert(!text_feed.has_history && !wide_feed.has_history);
    text_feed.teardown();
    wide_feed.teardown();

    // heap exhaustion seals the bucket and rolls to a fresh one
    Element th;
    th.format = register_format(text_fmt);
    th.ensure_history();
    char[1200] big = 'x';
    foreach (i; 0 .. 60)
    {
        big[0] = cast(char)('a' + i);
        th.write_sample(big[], from_unix_time_ns(1_000 * (i + 1)));
    }
    assert(th.record_count == 60 && th.bucket_count == 2);
    assert(th._history.buckets[0].sealed);
    assert(th._history.buckets[0].count == 54);   // 54 * 1202-byte entries is all a 64k heap holds
    assert(th._history.buckets[0].heap_capacity == th._history.buckets[0].heap_used);
    assert(th.text_value[0] == cast(char)('a' + 59));

    // oversize samples are refused at the gateway
    char[] huge = cast(char[])alloc(40_000);
    huge[] = 'x';
    th.write_sample(cast(const(char)[])huge, from_unix_time_ns(100_000));
    assert(th.record_count == 60);
    free(huge);
    th.teardown();

    // {raw,packed} entries: a sealed bucket packs when its last reader releases (immediately,
    // when nothing was reading); late cursors reconstitute a shared raw side and drop it again
    {
        static bool codec_registered;
        if (!codec_registered)
        {
            codec_registered = true;
            SeriesCodec rle = SeriesCodec("test-rle", &rle_match, &rle_pack, &rle_unpack);
            register_series_codec(rle);
        }
        g_rle_codec_on = true;
        scope(exit) g_rle_codec_on = false;

        static immutable DataFormat f64_sampled = DataFormat(ValueType.f64, SeriesKind.sampled);
        Element z;
        z.format = register_format(f64_sampled);
        z.ensure_history();
        z.write_sample(1.0, from_unix_time_ns(1_000));
        z.write_sample(1.0, from_unix_time_ns(2_000));
        z.mark_gap();
        z.write_sample(1.0, from_unix_time_ns(3_000));
        assert(z.bucket_count == 2);
        Bucket* pb = z._history.buckets[0];
        assert(pb.sealed && pb.packed !is null && pb.samples is null);   // packed at seal, raw dropped

        Cursor zc = z.open_series_cursor(0);
        RecordBlock zb = zc.next(16);
        assert(zb.count == 2 && zb.get!double(0) == 1.0 && zb.time(1) == from_unix_time_ns(2_000));
        assert(pb.samples !is null && pb.refs == 1);  // reconstituted, borrowed
        zb = zc.next(16);
        assert(zb.count == 1);
        assert(pb.samples is null && pb.refs == 0 && pb.packed !is null); // ref moved on, raw dropped
        z.close_series_cursor(zc);
        z.teardown();

        // the heap plane rides the same image: text buckets pack and reconstitute identically
        Element zt;
        zt.format = register_format(text_fmt);
        zt.ensure_history();
        zt.write_sample("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", from_unix_time_ns(1_000));
        zt.mark_gap();
        zt.write_sample("bbbb", from_unix_time_ns(2_000));
        Bucket* tb0 = zt._history.buckets[0];
        assert(tb0.packed !is null && tb0.samples is null);
        Cursor ztc = zt.open_series_cursor(0);
        RecordBlock ztb = ztc.next(16);
        assert(ztb.count == 1 && ztb.text(0) == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        zt.close_series_cursor(ztc);
        zt.teardown();

        // bit-less reads (queries) reconstitute without a borrow; cursor close sweeps the loose raw
        Element q;
        q.format = register_format(f64_sampled);
        q.ensure_history();
        q.write_sample(2.0, from_unix_time_ns(1_000));
        q.mark_gap();
        q.write_sample(2.0, from_unix_time_ns(2_000));
        Bucket* qb = q._history.buckets[0];
        assert(qb.packed !is null && qb.samples is null);
        RecordBlock qr = q.read_records(0, 16);
        assert(qr.count == 1 && qr.get!double(0) == 2.0);
        assert(qb.samples !is null && qb.refs == 0);
        Cursor qc = q.open_series_cursor(ulong.max);
        q.close_series_cursor(qc);
        assert(qb.samples is null && qb.packed !is null);
        q.teardown();

        // packing only reads raw: a bucket sealed under a live borrow packs immediately
        // (e.g. for the disk writer) and the raw side drops when the reader moves on
        Element w;
        w.format = register_format(f64_sampled);
        w.ensure_history();
        w.write_sample(3.0, from_unix_time_ns(1_000));
        Cursor wc = w.open_series_cursor(0);
        RecordBlock wb = wc.next(16);
        assert(wb.count == 1);
        Bucket* wb0 = w._history.buckets[0];
        assert(wb0.refs == 1);
        w.mark_gap();
        w.write_sample(3.0, from_unix_time_ns(2_000));
        assert(wb0.sealed && wb0.packed !is null && wb0.samples !is null);
        wb = wc.next(16);
        assert(wb.count == 1 && wb0.samples is null && wb0.packed !is null);
        w.close_series_cursor(wc);
        w.teardown();
    }

    // teardown mid-commit: the dying element's pending updates and dirty listing must vanish
    add_feed_listener();
    Element dying;
    dying.format = register_format(f64_held);
    begin_commit();
    dying.write_sample(1.0, from_unix_time_ns(1_000));
    assert(g_pending_updates.length == 1);
    assert(g_dirty_elements[].contains(&dying));
    dying.teardown();
    assert(g_pending_updates.empty);
    assert(!g_dirty_elements[].contains(&dying));
    end_commit();
    remove_feed_listener();

    // TODO: regular-series test returns once regular write_records() and rate-aware tick() are built
}

unittest
{
    static struct Watcher
    {
        Element* seen;
        ElementLifecycleEvent seen_event;
        void handler(Element* el, ElementLifecycleEvent event) nothrow @nogc
        {
            seen = el;
            seen_event = event;
        }
    }
    Element e;
    Watcher w;
    register_element_lifecycle_handler(&w.handler);
    signal_element_lifecycle(&e, ElementLifecycleEvent.created);
    assert(w.seen is &e && w.seen_event == ElementLifecycleEvent.created);
    signal_element_lifecycle(&e, ElementLifecycleEvent.destroyed);
    assert(w.seen_event == ElementLifecycleEvent.destroyed);
    _on_element_lifecycle.popBack();
}
