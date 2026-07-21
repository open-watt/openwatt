module manager.series;

// The series contract: the typed record format shared by every host of observed data.
// Element2 is the first host; the recorder's owsig containers and waveform/byte/packet taps
// host the same formats without becoming elements.
// Event! payloads and device-function params/results will describe themselves with the
// same DataFormat vocabulary, boxed through Variant only at the console/API edges.
//
// DataFormat contains the properties shared by every record in a series: value type, count,
// unit, names, and clock. Each record stores only the bytes that vary. box_record combines
// the record bytes with their format to make a self-describing Variant.
//
// The value types are machine scalars, char, and `user` (a registered type identified by the
// format's descriptor slot). count is one for a scalar, N for a fixed vector, or zero for a
// dynamic record whose length is stored in the record. A string is dynamic char data; a blob
// is dynamic u8 data with opaque display. Storage rule: a record is memcpy iff its type is trivial - dynamic
// records hold immutable refcounted handles (String for text), non-pod user types copy
// and drop through their registry hooks.

import urt.array;
import urt.lifetime : move;
import urt.mem.allocator : defaultAllocator;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.si.quantity : Quantity;
import urt.si.unit : ScaledUnit;
import urt.string : makeString, String;
import urt.time;
import urt.typereg : TypeDetails;
import urt.variant;

nothrow @nogc:


enum ValueType : ubyte
{
    bool_,
    u8, s8,
    u16, s16,
    u32, s32,
    u64, s64,
    f32, f64,
    char_,
    user
}

// machine numerics fit the Scalar register when count is one
bool is_scalar_type(ValueType t) pure
    => t <= ValueType.f64;

enum SeriesKind : ubyte
{
    held,
    sampled,
    point
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
    Scalar step;
    CheckFn check_fn;   // null = range only
    ubyte has;

    const(char)[] check(ref const Scalar v, ref const DataFormat fmt) const
    {
        // TODO: typed range compare, then check_fn
        return check_fn ? check_fn(v, fmt) : null;
    }
}

struct DataFormat
{
nothrow @nogc:

    enum Desc : ubyte
    {
        none,
        quantity,
        enum_
    }

    ValueType type;
    SeriesKind kind;
    Desc desc;
    ubyte count = 1;               // 1 = scalar, N = fixed vector, 0 = dynamic (length in the record)
    uint rate;                     // frames/sec; 0 = irregular, records carry explicit timestamps
    ClockDomain* clock;            // null = wall-clock timestamps; regular device series index in their own domain
    const(Constraint)* constraint; // null = unconstrained; write-path validation + UI/schema metadata
    union
    {
        ScaledUnit unit;                // desc == quantity
        const(VoidEnumInfo)* enum_info; // desc == enum_
        const(TypeDetails)* user_type;  // type == user
    }

    this(ValueType t, SeriesKind kind_) pure
    {
        type = t;
        kind = kind_;
    }

    this(ValueType t, SeriesKind kind_, ScaledUnit u) pure
    {
        type = t;
        kind = kind_;
        if (u != ScaledUnit())
        {
            unit = u;
            desc = Desc.quantity;
        }
    }

    this(ValueType t, SeriesKind kind_, const(VoidEnumInfo)* ei) pure
    {
        type = t;
        kind = kind_;
        if (ei)
        {
            enum_info = ei;
            desc = Desc.enum_;
        }
    }

    this(ValueType t, SeriesKind kind_, const(TypeDetails)* td) pure
    {
        assert(t == ValueType.user, "user_type requires ValueType.user");
        type = t;
        kind = kind_;
        user_type = td;
    }

    bool regular() const pure => rate != 0;
    bool uses_device_ticks() const pure => rate == 0 && clock !is null;

    // fits the 8-byte Scalar register: machine numerics or trivial user pods
    bool is_scalar() const pure
        => count == 1 && (is_scalar_type(type) || (type == ValueType.user && user_type.pod && user_type.size <= 8));

    bool is_text() const pure
        => type == ValueType.char_ && count == 0;

    // fixed-size trivial records wider than the Scalar register; latest reads the open bucket tail
    bool is_wide() const pure
        => count != 0 && !is_scalar && (type != ValueType.user || user_type.pod);

    ubyte stride() const pure
    {
        if (count == 0)
            return 8; // dynamic records are TextRecords on all targets
        uint s = type == ValueType.user ? user_type.size : g_type_stride[type];
        s *= count;
        assert(s <= ubyte.max, "record stride exceeds 255 bytes");
        return cast(ubyte)s;
    }
}

// the 8-byte fast-path register: single records of scalar formats pass through here; wider
// records travel as (format, void[])
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

// text record: a String handle in the low bytes, or <=7 chars embedded with the length in
// the top byte - a canonical user pointer never has its top byte set, and 32-bit handles
// leave the high half zeroed
struct TextRecord
{
nothrow @nogc:

    version (BigEndian) static assert(false, "embedded text discriminant assumes little-endian");

    enum embed_capacity = 7;

    ubyte[8] raw;

    bool embedded() const pure
        => raw[7] != 0;

    const(char)[] view() const pure return
        => embedded ? cast(const(char)[])raw[0 .. raw[7]] : (*cast(const(String)*)raw.ptr)[];

    void set(String s)
    {
        if (s.length <= embed_capacity)
            set(s[]);
        else
        {
            release();
            *cast(String*)raw.ptr = s.move;
        }
    }

    void set(const(char)[] s)
    {
        if (s.length <= embed_capacity)
        {
            release();
            raw[0 .. s.length] = cast(const(ubyte)[])s;
            raw[7] = cast(ubyte)s.length;
        }
        else
        {
            release();
            *cast(String*)raw.ptr = s.makeString(defaultAllocator());
        }
    }

    // target must be initialised; the ref taken here is owned by whoever memcpys the bits away
    void copy_from(ref const TextRecord src)
    {
        release();
        if (src.embedded)
            raw = src.raw;
        else
            *cast(String*)raw.ptr = *cast(String*)src.raw.ptr;
    }

    void release()
    {
        if (!embedded)
            *cast(String*)raw.ptr = null;
        raw[] = 0;
    }
}

static assert(TextRecord.sizeof == 8);

struct RecordBlock
{
nothrow @nogc:

    ulong first_index;
    ulong t0;           // time base
    ulong lost;         // records evicted between the reader's position and this block
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

enum SeriesEvent : ubyte
{
    online,
    offline,
    gap,
    format_change
}

struct Bucket
{
    ulong first_index;
    ulong first_tick;
    uint last_offset;
    uint count;
    uint capacity;
    bool follows_gap;  // <- we should steal a bit for this!
    bool sealed;       // tail retired: shrunk to fit, immutable (packing lands here)
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

    // retention model, min/max per axis: floors (min_*) KEEP records even after consumption
    // (for rendering), pins EXTEND retention until the consumer advances past, ceilings (max_*)
    // FORCE eviction regardless of pins (stalled or undriven consumers get lapped and the
    // cursor reports records_lost); between floor and ceiling, consumption governs
    Array!(Bucket*) buckets;
    ulong head;
    ulong min_age;      // usecs (converted to domain ticks at evict time); 0 = none
    ulong max_age;      // usecs; 0 = no ceiling
    uint min_records;   // 0 = none
    uint max_records;   // 0 = no ceiling
    ushort cursor_mask;
    ushort pin_mask;    // cursors voluntary eviction must not pass; consumption = advancing the cursor
    ulong[16] pin_position;

    ulong first_index() const pure
        => buckets.length ? buckets[0].first_index : head;

    ulong pin_floor() const pure
    {
        ulong floor = ulong.max;
        foreach (bit; 0 .. 16)
            if ((pin_mask & (1 << bit)) && pin_position[bit] < floor)
                floor = pin_position[bit];
        return floor;
    }

    // TODO: byte budgets (== records * stride until variable-stride records land) and ring tier

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


// the reunion: records are context-free bytes, the format is their context, a Variant is
// self-describing; this edge is the only place the three meet
Variant box_record(const(void)* record, ref const DataFormat fmt)
{
    if (fmt.count > 1)
    {
        // fixed vectors: u8 = blob, char = text; other types await Variant arrays
        if (fmt.type == ValueType.u8)
            return Variant(cast(const(void)[])record[0 .. fmt.count]);
        if (fmt.type == ValueType.char_)
            return Variant(cast(const(char)[])record[0 .. fmt.count]);
        assert(false, "TODO: vector records box as Variant arrays");
    }
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
        case char_:
        {
            assert(fmt.count == 0, "fixed char vectors box at the Element, not the record");
            const(TextRecord)* tr = cast(const(TextRecord)*)record;
            if (tr.embedded)
                return Variant(tr.view);
            return Variant(*cast(String*)record);
        }
        case user:
        {
            const(TypeDetails)* td = fmt.user_type;
            if (td.variant)
            {
                Variant var;
                if (td.variant(cast(void*)record, var, true))
                    return var;
            }
            assert(false, "TODO: structural user boxing lands with the gateway");
        }
    }
}

// inverse of box_record; false when the format can't represent the value
bool unbox_scalar(ref const Variant v, ref const DataFormat fmt, out Scalar s)
{
    if (!fmt.is_scalar)
        return false;
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

        case user:
        {
            const(TypeDetails)* td = fmt.user_type;
            if (!td.variant)
                return false;
            s.raw[] = 0;
            return td.variant(s.raw.ptr, *cast(Variant*)&v, false);
        }

        case char_:
            return false;
    }
}


unittest
{
    // count multiplies stride; 0 is a dynamic handle and scalar records require count == 1
    DataFormat f = DataFormat(ValueType.s32, SeriesKind.held);
    assert(f.stride == 4 && f.is_scalar);
    f.count = 8;
    assert(f.stride == 32 && !f.is_scalar);
    DataFormat s = DataFormat(ValueType.char_, SeriesKind.held);
    s.count = 0;
    assert(s.stride == 8 && !s.is_scalar && s.is_text);

    int v = -5;
    assert(box_record(&v, DataFormat(ValueType.s32, SeriesKind.held)).asLong == -5);

    // trivial user pods ride the Scalar register and box through their variant marshal
    import urt.time : from_unix_time_ns, SysTime;
    import urt.typereg : find_type_by_name;
    const(TypeDetails)* dt = find_type_by_name("dt");
    assert(dt && dt.pod && dt.size == 8 && dt.variant);
    DataFormat fdt = DataFormat(ValueType.user, SeriesKind.held, dt);
    assert(fdt.is_scalar && fdt.stride == 8);
    SysTime t = from_unix_time_ns(1_700_000_000_000_000_000);
    Variant bt = box_record(&t, fdt);
    assert(bt.isUser!SysTime && bt.as!SysTime == t);
    Scalar sc;
    assert(unbox_scalar(bt, fdt, sc));
    assert(*cast(SysTime*)sc.raw.ptr == t);
}


private:

package immutable ubyte[ValueType.max + 1] g_type_stride = [ 1, 1, 1, 2, 2, 4, 4, 8, 8, 4, 8, 1, 0 ];

Variant box_int(long v, ref const DataFormat fmt)
{
    if (fmt.desc == DataFormat.Desc.enum_)
        return Variant(cast(ulong)v, fmt.enum_info);
    if (fmt.desc == DataFormat.Desc.quantity)
        return Variant(Quantity!long(v, fmt.unit));
    return Variant(v);
}

Variant box_float(double v, ref const DataFormat fmt)
    => fmt.desc == DataFormat.Desc.quantity ? Variant(Quantity!double(v, fmt.unit)) : Variant(v);

bool unbox_double(ref const Variant v, ref const DataFormat fmt, out double d)
{
    if (v.isQuantity)
        d = fmt.desc == DataFormat.Desc.quantity ? v.asQuantity!double().adjust_scale(fmt.unit).value
                                                 : v.asQuantity!double().normalise().value;
    else if (v.isBool)
        d = v.asBool ? 1 : 0;
    else if (v.isNumber)
        d = v.asDouble;
    else
        return false;
    return d == d; // reject NaN
}
