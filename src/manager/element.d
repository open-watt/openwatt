module manager.element;

import urt.array;
import urt.lifetime;
import urt.mem.alloc;
import urt.mem.string;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.time;
import urt.variant;

import manager.component;
import manager.device;
import manager.element2;
import manager.id : EID;
import manager.subscriber;

nothrow @nogc:


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

alias OnChangeCallback = void delegate(ref Element e, ref const Variant val, SysTime timestamp, ref const Variant prev, SysTime prev_timestamp) nothrow @nogc;

// Best-effort recent-sample cache: if it wraps before the recorder ships, those
// samples are lost; the db is the authoritative store.
enum uint recent_capacity = 16;

struct ElementSample
{
nothrow @nogc:

    MonoTime time;
    Variant value;

    this(ref const ElementSample rh)
    {
        time = rh.time;
        value = rh.value;
    }
}


struct Element
{
nothrow @nogc:

    // null or indirect format = legacy mount: the boxed Variant below is authoritative
    // and the core lies dormant until a producer assigns a format
    Element2 series;

    package Variant latest;
    package Variant prev;

    String id;
    String name;
    String desc;
    String display_unit;

    SysTime last_update;
    SysTime prev_update;

    package Array!ElementSample recent;
    package uint recent_head;
    package uint recent_count;

    Array!Subscriber subscribers;
    Array!OnChangeCallback subscribers_2;
    ushort subscribers_dirty;

    package EID _eid;

    Component parent;

    Access access;
    SamplingMode sampling_mode;

    this(this) @disable;

    void add_subscriber(Subscriber s)
    {
        if (subscribers[].findFirst(s) == subscribers.length)
            subscribers ~= s;
    }
    void add_subscriber(OnChangeCallback s)
    {
        if (subscribers_2[].findFirst(s) == subscribers_2.length)
            subscribers_2 ~= s;
    }

    void remove_subscriber(Subscriber s)
    {
        subscribers.removeFirstSwapLast(s);
    }
    void remove_subscriber(OnChangeCallback s)
    {
        subscribers_2.removeFirstSwapLast(s);
    }

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

    ref inout(Variant) value() @property inout pure
        => latest;

    bool native() const pure
        => series.format !is null && series.format.is_scalar;

    void value(T)(auto ref T v, SysTime timestamp = getSysTime(), Subscriber who = null)
    {
        if (native)
        {
            static if (is(immutable T == immutable Variant))
                feed_native(v, timestamp);
            else
            {
                Variant boxed = Variant(v);
                feed_native(boxed, timestamp);
            }
        }

        bool is_newer = timestamp > last_update;
        if (is_newer)
        {
            prev_update = last_update;
            last_update = timestamp;
        }

        if (latest != v)
        {
            if (is_newer)
                prev = latest.move;
            latest = forward!v;
            signal(latest, timestamp, prev, prev_update, who);
            if (is_newer)
                capture_sample(timestamp);
        }
    }

    void observe(T)(T v, SysTime t = getSysTime(), Observer who = null)
    {
        series.observe(v, t, who);
        sync_from_series();
    }

    void observe_record(const(void)[] record, SysTime t = getSysTime(), Observer who = null)
    {
        series.observe_record(record, t, who);
        sync_from_series();
    }

    void observe_block(const(void)[] samples, const(SysTime)[] times, Observer who = null)
    {
        series.observe_block(samples, times, who);
        sync_from_series();
    }

    void observe_block(const(void)[] samples, const(ulong)[] ticks, Observer who = null)
    {
        series.observe_block(samples, ticks, who);
        sync_from_series();
    }

    void mark_gap(Observer who = null)
    {
        series.mark_gap(who);
    }

    // minted lazily on first demand; unmounted elements have none
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
        _eid = d.cid.element(d.element_ids.mint(&this));
        return _eid;
    }

    ElementCursor open_cursor(ulong from_index = ulong.max)
    {
        EID handle = ensure_eid();
        if (!handle)
            return ElementCursor();
        Cursor c = series.open_cursor(from_index);
        return ElementCursor(handle, c.position, c.bit);
    }

    ref const(ElementSample) recent_at(uint i) const pure
        => recent[(recent_head + i) % cast(uint)recent.length];

    ulong recent_oldest() const pure
        => recent_count ? unixTimeNs(cast(SysTime)recent_at(0).time) : ulong.max;

    ulong recent_newest() const pure
        => recent_count ? unixTimeNs(cast(SysTime)recent_at(recent_count - 1).time) : 0;

    private void feed_native(ref const Variant v, SysTime timestamp)
    {
        Scalar s;
        if (unbox_scalar(v, *series.format, s))
            series.observe_scalar(s, timestamp);
        // else the boxed side still takes it and the core diverges until the next
        // representable observation (transitional)
    }

    private void sync_from_series()
    {
        Variant v = series.value();
        SysTime t = series.last_update;
        bool is_newer = t > last_update;
        if (is_newer)
        {
            prev_update = last_update;
            last_update = t;
        }
        if (latest != v)
        {
            if (is_newer)
                prev = latest.move;
            latest = v.move;
            signal(latest, t, prev, prev_update, null);
            if (is_newer)
                capture_sample(t);
        }
    }

    private void capture_sample(SysTime timestamp)
    {
        if (recent.length == 0)
            recent.resize(recent_capacity);
        uint cap = cast(uint)recent.length;
        uint idx;
        if (recent_count == cap)
        {
            idx = recent_head;
            recent_head = (recent_head + 1) % cap;
        }
        else
        {
            idx = (recent_head + recent_count) % cap;
            ++recent_count;
        }
        recent[][idx].time = cast(MonoTime)timestamp;
        recent[][idx].value = latest;
    }

    void signal(ref const Variant v, SysTime timestamp, ref const Variant prev, SysTime prev_timestamp, Subscriber who)
    {
        foreach (s; subscribers)
            if (s !is who)
                s.on_change(&this, v, timestamp, who);
        foreach (s; subscribers_2)
            s(this, v, timestamp, prev, prev_timestamp);
    }

    void force_update(SysTime timestamp)
    {
        if (timestamp <= last_update)
            return;
        prev_update = last_update;
        last_update = timestamp;
        prev = latest;
        signal(latest, timestamp, prev, prev_update, null); // TODO: who made the change? so we can break cycles...
        capture_sample(timestamp);
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
}


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
        auto c = Cursor(&e.series, position, bit);
        return c.pending;
    }

    RecordBlock next(uint max_records)
    {
        Element* e = eid.deref;
        if (!e)
            return RecordBlock();
        auto c = Cursor(&e.series, position, bit);
        RecordBlock r = c.next(max_records);
        position = c.position;
        return r;
    }

    void close()
    {
        if (Element* e = eid.deref)
        {
            auto c = Cursor(&e.series, position, bit);
            e.series.close_cursor(c);
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

    // value() captures into the recent buffer; it wraps, keeping the newest N
    Element e;
    foreach (i; 0 .. recent_capacity + 4)
        e.value(Variant(cast(double)i), from_unix_time_ns((i + 1) * 1_000_000UL));

    assert(e.recent_count == recent_capacity);
    assert(e.recent_oldest() == 5 * 1_000_000UL); // i=0..3 dropped; oldest kept is i=4
    assert(e.recent_at(recent_capacity - 1).value.asDouble == recent_capacity + 3);

    // non-numeric values are still captured as raw Variants (db/graph skip them)
    Element s;
    s.value(Variant(StringLit!"hi"), from_unix_time_ns(1_000_000));
    assert(s.recent_count == 1);
    double d;
    assert(!sample_to_double(s.recent_at(0).value, d));

    // native mount: observations feed the series and mirror into the boxed legacy path
    static immutable DataFormat bool_held = DataFormat(ValueType.bool_, Semantics.held);
    Element n;
    n.series.format = &bool_held;
    n.series.ensure_history();
    bool[2] lv = [true, false];
    SysTime[2] tm = [from_unix_time_ns(1_000_000), from_unix_time_ns(2_000_000)];
    n.observe_block(lv[], tm[]);
    assert(n.series.record_count == 2);
    assert(n.value.isBool && !n.value.asBool);
    assert(n.last_update == from_unix_time_ns(2_000_000));
    assert(n.recent_count == 1);

    // a boxed write to a native mount lands in the series too
    n.value(Variant(true), from_unix_time_ns(3_000_000));
    assert(n.series.record_count == 3);
    assert(n.series.latest.b);
    assert(n.value.asBool);

    // quantity writes to a typed mount store natively in the format's unit scale (the
    // profile-binding write shape: sample_value produces unit-carrying Variants)
    import urt.si.quantity : Quantity;
    import urt.si.unit : Volt;
    static immutable DataFormat volts_held = DataFormat(ValueType.f64, Semantics.held, ScaledUnit(Volt));
    Element q;
    q.series.format = &volts_held;
    q.value(Variant(Quantity!double(23.05, ScaledUnit(Volt))), from_unix_time_ns(1_000_000));
    assert(q.series.latest.f64_ == 23.05);
    assert(q.value.isQuantity);
}
