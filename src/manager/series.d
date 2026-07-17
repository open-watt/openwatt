module manager.series;

// The series contract: the typed record vocabulary shared by every host of observed data.
// Element2 (the device tree's mount points) is the first host; the recorder's owsig
// containers and waveform/byte/packet taps host the same shapes without becoming elements.
// The three-facet device surface (attributes / commands / events) converges here too:
// elements and property projections carry these formats today, and Event! payloads and
// device-function params/results will describe themselves with the same DataFormat
// vocabulary, boxed through Variant only at the console/API edges.

import urt.array;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.si.quantity : Quantity;
import urt.si.unit : ScaledUnit;
import urt.time;
import urt.variant;

nothrow @nogc:


enum Semantics : ubyte
{
    held,
    sampled,
    point
}

enum ValueType : ubyte
{
    bool_,
    u8, s8,
    u16, s16,
    u32, s32,
    u64, s64,
    f32, f64,
    // indirect types...
    string_,
    variant
}

bool is_scalar_type(ValueType t) pure
    => t <= ValueType.f64;

ubyte value_stride(ValueType t) pure
{
    final switch (t) with (ValueType)
    {
        case bool_, u8, s8:     return 1;
        case u16, s16:          return 2;
        case u32, s32, f32:     return 4;
        case u64, s64, f64:     return 8;
        // indirect types are just pointers
        case string_:           return size_t.sizeof;
        // this one is special; `Scalar` will be indirect, but buffers will be by-value
        case variant:           return Variant.sizeof;
    }
}

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
}

struct ClockAnchor
{
    ulong index;
    SysTime observed;
}

struct ClockDomain
{
nothrow @nogc:

    uint nominal_rate;
    Array!ClockAnchor anchors;

    void add_anchor(ulong index, SysTime observed)
    {
        anchors ~= ClockAnchor(index, observed);
        // TODO: discipline: smooth to (offset, skew) segments, min-latency filtered; bound the raw history
    }

    SysTime to_wall(ulong index) const
    {
        if (anchors.empty)
            return SysTime();
        ClockAnchor a = anchors[$-1];
        return a.observed + nsecs((long(index) - long(a.index)) * 1_000_000_000L / nominal_rate);
    }

    ulong from_wall(SysTime t) const
    {
        if (anchors.empty)
            return 0;
        ClockAnchor a = anchors[$-1];
        long dt = (t - a.observed).as!"nsecs";
        long i = long(a.index) + dt * nominal_rate / 1_000_000_000L;
        return i > 0 ? ulong(i) : 0;
    }
}

// Validation beside the format: shared immutable per declaration, like DataFormat itself, so
// constraint metadata costs nothing per element. The declarative range is machine-readable
// (UI clamps before submit, API exports schema); the function is the escape hatch for rules
// data can't express. Constraints gate WRITES (setpoints, config, sinks) - observations are
// never validated or clamped, a measurement is truth even when out of spec.
struct Constraint
{
nothrow @nogc:

    alias CheckFn = const(char)[] function(ref const Scalar value, ref const DataFormat fmt) nothrow @nogc;

    enum Has : ubyte
    {
        min  = 1 << 0,
        max  = 1 << 1,
        step = 1 << 2,
    }

    Scalar min;
    Scalar max;
    CheckFn check_fn;   // null = range only
    ubyte has;

    const(char)[] check(ref const Scalar v, ref const DataFormat fmt) const
    {
        // TODO: typed range compare, then check_fn
        return check_fn ? check_fn(v, fmt) : null;
    }
}

// One shared immutable instance per declared shape: a Prop! declaration, a profile element
// template, or a collector's static format. Elements point at it; they never own one.
struct DataFormat
{
nothrow @nogc:

    ValueType type;
    Semantics semantics;
    ScaledUnit unit;
    uint rate;                     // frames/sec; 0 = irregular, records carry explicit timestamps
    ClockDomain* clock;            // null = wall-native; regular device series index in their own domain
    const(Constraint)* constraint; // null = unconstrained; write-path validation + UI/schema metadata
    const(VoidEnumInfo)* enum_info; // integer types box as enum Variants when set

    bool regular() const pure => rate != 0;
    bool domain_native() const pure => rate == 0 && clock !is null;
    ubyte stride() const pure => value_stride(type);
}

enum SeriesEvent : ubyte
{
    online,
    offline,
    gap,
    format_change
}

union Scalar
{
nothrow @nogc:

    bool b;
    long i;
    ulong u;
    float f32_;
    double f64_;
    ubyte[8] raw;

    static Scalar of(T)(T v)
    {
        Scalar s;
        s.raw[] = 0;
        static if (is(T == bool))
            s.b = v;
        else static if (is(T == float))
            s.f32_ = v;
        else static if (is(T == double))
            s.f64_ = v;
        else static if (__traits(isUnsigned, T))
            s.u = v;
        else
            s.i = v;
        return s;
    }
}

struct RecordBlock
{
nothrow @nogc:

    ulong first_index;
    ulong t0;           // time base
    const(uint)* ts;    // null if the series is regular
    const(void)* data;
    const(DataFormat)* format;
    uint count;

    const(void)[] records() const pure
        => data[0 .. count * format.stride];

    SysTime time(size_t i) const
        => format.clock ? format.clock.to_wall(tick(i)) : from_unix_time_ns(tick(i) * 1000);

    ulong tick(size_t i) const pure
        => t0 + (ts ? ts[i] : i);

    ref const(T) get(T)(uint i) const pure
        => (cast(const(T)*)data)[i];

    Variant box(uint i) const
        => box_record(cast(const(ubyte)*)data + i*format.stride, *format);
}


Variant box_record(const(void)* record, ref const DataFormat fmt)
{
    final switch (fmt.type) with (ValueType)
    {
        case bool_: return Variant(*cast(const(bool)*)record);
        case u8:    return box_int(*cast(const(ubyte)*)record, fmt);
        case s8:    return box_int(*cast(const(byte)*)record, fmt);
        case u16:   return box_int(*cast(const(ushort)*)record, fmt);
        case s16:   return box_int(*cast(const(short)*)record, fmt);
        case u32:   return box_int(*cast(const(uint)*)record, fmt);
        case s32:   return box_int(*cast(const(int)*)record, fmt);
        case u64:   return box_int(cast(long)*cast(const(ulong)*)record, fmt);
        case s64:   return box_int(*cast(const(long)*)record, fmt);
        case f32:   return box_float(*cast(const(float)*)record, fmt);
        case f64:   return box_float(*cast(const(double)*)record, fmt);
        case string_:
        case variant:
            assert(false, "indirect types box at the mount, not the record");
    }
}

// inverse of box_record; false when the format can't represent the value
bool unbox_scalar(ref const Variant v, ref const DataFormat fmt, out Scalar s)
{
    final switch (fmt.type) with (ValueType)
    {
        case bool_:
            if (!v.isBool)
                return false;
            s = Scalar.of(v.asBool);
            return true;

        case u8, u16, u32, u64:
        case s8, s16, s32, s64:
        {
            double d;
            if (!unbox_double(v, fmt, d))
                return false;
            s = Scalar.of(cast(long)d);
            return true;
        }
        case f32:
        {
            double d;
            if (!unbox_double(v, fmt, d))
                return false;
            s = Scalar.of(cast(float)d);
            return true;
        }
        case f64:
        {
            double d;
            if (!unbox_double(v, fmt, d))
                return false;
            s = Scalar.of(d);
            return true;
        }

        case string_:
        case variant:
            return false;
    }
}

private Variant box_int(long v, ref const DataFormat fmt)
{
    if (fmt.enum_info)
        return Variant(cast(ulong)v, fmt.enum_info);
    return fmt.unit == ScaledUnit() ? Variant(v) : Variant(Quantity!long(v, fmt.unit));
}

private Variant box_float(double v, ref const DataFormat fmt)
    => fmt.unit == ScaledUnit() ? Variant(v) : Variant(Quantity!double(v, fmt.unit));

private bool unbox_double(ref const Variant v, ref const DataFormat fmt, out double d)
{
    if (v.isQuantity)
        d = fmt.unit == ScaledUnit() ? v.asQuantity!double().normalise().value
                                     : v.asQuantity!double().adjust_scale(fmt.unit).value;
    else if (v.isBool)
        d = v.asBool ? 1 : 0;
    else if (v.isNumber)
        d = v.asDouble;
    else
        return false;
    return d == d; // reject NaN
}


struct Bucket
{
    ulong first_index;
    ulong first_tick;
    uint last_offset;
    uint count;
    uint capacity;
    bool follows_gap;  // <- we should steal a bit for this!
    void* samples;
    uint* offsets;     // null when regular

pure nothrow @nogc:
    ulong last_tick() const => first_tick + last_offset;
    SysTime first_time() const => from_unix_time_ns(first_tick * 1000);
    SysTime last_time() const => from_unix_time_ns(last_tick * 1000);
    SysTime get_time(size_t i) const => from_unix_time_ns((first_tick + (offsets ? offsets[i] : i)) * 1000);
}

struct SeriesStore
{
nothrow @nogc:

    Array!(Bucket*) buckets;
    ulong head;
    ushort cursor_mask;

    // TODO: retention policy (ring vs history, record/byte/age budgets) and eviction; a
    //       cursor lapped by eviction takes a records_lost gap

    Bucket* find_by_time(SysTime t)
    {
        // domain-clocked series: map through fmt.clock.from_wall and use find_by_index instead;
        // bucket first/last_time are anchor estimates, not truth

        size_t lo = 0, hi = buckets.length;
        while (lo < hi)
        {
            size_t mid = (lo + hi) / 2;
            if (buckets[mid].last_time < t)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo < buckets.length ? buckets[lo] : null;
    }

    Bucket* find_by_index(ulong index)
    {
        size_t lo = 0, hi = buckets.length;
        while (lo < hi)
        {
            size_t mid = (lo + hi) / 2;
            if (buckets[mid].first_index + buckets[mid].count <= index)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo < buckets.length ? buckets[lo] : null;
    }

    RecordBlock read(ref const DataFormat fmt, ulong from_index, uint max_records)
    {
        RecordBlock r;
        r.format = &fmt;
        Bucket* b = find_by_index(from_index);
        if (!b || from_index < b.first_index)
            return r;
        uint offset = cast(uint)(from_index - b.first_index);
        uint n = b.count - offset;
        if (n > max_records)
            n = max_records;
        r.data = cast(const(ubyte)*)b.samples + offset*fmt.stride;
        r.count = n;
        r.ts = b.offsets ? b.offsets + offset : null;
        r.t0 = b.offsets ? b.first_tick : b.first_tick + offset;
        r.first_index = from_index;
        return r;
    }
}
