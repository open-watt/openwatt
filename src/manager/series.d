module manager.series;

// The series contract: the typed record format shared by every host of observed data.
// Element is the first host; the recorder's owsig containers and waveform/byte/packet taps
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
import urt.meta.enuminfo : enum_info, VoidEnumInfo;
import urt.si.quantity : Quantity;
import urt.si.unit : Nanosecond, ScaledUnit;
import urt.string : makeString, String;
import urt.time;
import urt.traits : is_boolean, is_some_float, is_some_int, Unqual;
import urt.typereg : find_type_details, TypeDetails;
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

enum FormatId : ushort
{
    invalid = ushort.max
}
static assert(FormatId.sizeof == ushort.sizeof);

// TODO: Allocate FormatIds from ordered integer, floating-point, and exact ranges
// so the value class can be determined directly from the ID. Each range needs an
// independent allocator because numeric formats may be registered at any time.

bool valid(FormatId id) pure
    => id != FormatId.invalid;

// FormatIds are process-local identities. Registered descriptors remain alive for the process
// lifetime, so equality is an integer comparison after registration. A hash-valued enum may
// replace the descriptor at its existing ID when its key set changes; old records remain valid.
FormatId register_format(in DataFormat format)
{
    foreach (i, f; g_formats)
    {
        if (format_equal(*f, format))
            return cast(FormatId)i;
    }
    assert(g_formats.length < FormatId.invalid, "format registry full");
    DataFormat* f = defaultAllocator().allocT!DataFormat();
    *f = cast(DataFormat)format;
    g_formats ~= f;
    return cast(FormatId)(g_formats.length - 1);
}

void update_enum_format(FormatId id, const(VoidEnumInfo)* info)
{
    assert(id.valid && cast(size_t)id < g_formats.length, "invalid format id");
    const(DataFormat)* current = g_formats[cast(size_t)id];
    assert(current.desc == DataFormat.Desc.enum_, "format is not an enum");
    if (current.enum_info is info)
        return;

    DataFormat* replacement = defaultAllocator().allocT!DataFormat();
    *replacement = cast(DataFormat)*current;
    replacement.enum_info = info;
    g_formats[][cast(size_t)id] = replacement;
}

const(DataFormat)* format_info(FormatId id) pure
{
    auto formats = (cast(immutable(typeof(g_formats)*) function() pure nothrow @nogc)&format_registry)();
    assert(id.valid && cast(size_t)id < formats.length, "invalid format id");
    return (*formats)[cast(size_t)id];
}

template value_type_of(T)
{
    alias U = Unqual!T;
    static if (is(U == bool))        enum value_type_of = ValueType.bool_;
    else static if (is(U == ubyte))  enum value_type_of = ValueType.u8;
    else static if (is(U == byte))   enum value_type_of = ValueType.s8;
    else static if (is(U == ushort)) enum value_type_of = ValueType.u16;
    else static if (is(U == short))  enum value_type_of = ValueType.s16;
    else static if (is(U == uint))   enum value_type_of = ValueType.u32;
    else static if (is(U == int))    enum value_type_of = ValueType.s32;
    else static if (is(U == ulong))  enum value_type_of = ValueType.u64;
    else static if (is(U == long))   enum value_type_of = ValueType.s64;
    else static if (is(U == float))  enum value_type_of = ValueType.f32;
    else static if (is(U == double)) enum value_type_of = ValueType.f64;
    else static if (is(U == char))   enum value_type_of = ValueType.char_;
}

FormatId register_value_format(T)(auto ref T value)
{
    alias U = Unqual!T;
    static if (is(U == Variant))
        return register_variant_format(value);
    else static if (is_boolean!U || is_some_int!U || is_some_float!U)
        return register_format(DataFormat(value_type_of!U, SeriesKind.held));
    else static if (is(U Base == enum))
        return register_format(DataFormat(value_type_of!Base, SeriesKind.held, enum_info!U.make_void()));
    else static if (is(U == String) || is(T : const(char)[]))
    {
        DataFormat format = DataFormat(ValueType.char_, SeriesKind.held);
        format.count = 0;
        return register_format(format);
    }
    else static if (is(U == Duration))
        return register_format(DataFormat(ValueType.s64, SeriesKind.held, Nanosecond));
    else static if (is(U == Quantity!(N, scale), N, ScaledUnit scale))
        return register_format(DataFormat(value_type_of!N, SeriesKind.held, value.unit));
    else static if (ValidUserType!U)
    {
        Variant register_type = Variant(value);
        return register_format(DataFormat(ValueType.user, SeriesKind.held,
                                          &find_type_details(TypeDetailsFor!U.type_id)));
    }
    else
        static assert(false, "value needs an explicit record format");
}

FormatId register_value_format(T)()
{
    alias U = Unqual!T;
    static if (is_boolean!U || is_some_int!U || is_some_float!U)
        return register_format(DataFormat(value_type_of!U, SeriesKind.held));
    else static if (is(U Base == enum))
        return register_format(DataFormat(value_type_of!Base, SeriesKind.held, enum_info!U.make_void()));
    else static if (is(U == String) || is(U : const(char)[]))
    {
        DataFormat format = DataFormat(ValueType.char_, SeriesKind.held);
        format.count = 0;
        return register_format(format);
    }
    else static if (is(U == Duration))
        return register_format(DataFormat(ValueType.s64, SeriesKind.held, Nanosecond));
    else
        static assert(false, "value-dependent formats require a value");
}

// machine numerics fit the Scalar register when count is one
bool is_scalar_type(ValueType t) pure
    => t <= ValueType.f64;

enum ValueClass : ubyte
{
    integer,
    floating,
    exact
}

ValueClass value_class(ValueType type) pure
{
    final switch (type) with (ValueType)
    {
        case u8, s8, u16, s16, u32, s32, u64, s64:
            return ValueClass.integer;
        case f32, f64:
            return ValueClass.floating;
        case bool_, char_, user:
            return ValueClass.exact;
    }
}

bool value_compatible(ref const DataFormat source, ref const DataFormat destination) pure
{
    if (source.count != destination.count)
        return false;

    ValueClass sc = source.type.value_class;
    ValueClass dc = destination.type.value_class;
    if (sc == ValueClass.exact || dc == ValueClass.exact)
    {
        if (source.type != destination.type)
            return false;
        return source.type != ValueType.user || source.user_type is destination.user_type;
    }

    if (source.desc != destination.desc)
        return false;
    final switch (source.desc) with (DataFormat.Desc)
    {
        case none:
            return true;
        case quantity:
            return source.unit.unit == destination.unit.unit;
        case enum_:
            return source.enum_info is destination.enum_info;
    }
}

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
        if ((has & Has.min) && compare_scalar(v, min, fmt.type) < 0)
            return "below minimum";
        if ((has & Has.max) && compare_scalar(v, max, fmt.type) > 0)
            return "above maximum";
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
        static if (is(immutable T == immutable bool))
            s.b = v;
        else static if (is(immutable T == immutable float))
            s.f32_ = v;
        else static if (is(immutable T == immutable double))
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
    FormatId format;
    uint count;

    const(DataFormat)* data_format() const pure
        => format_info(format);

    const(void)[] records() const pure
        => data[0 .. count * data_format.stride];

    SysTime time(size_t i) const
        => data_format.clock ? data_format.clock.to_wall(tick(i)) : from_unix_time_ns(tick(i) * 1000);

    ulong tick(size_t i) const pure
        => t0 + (ts ? ts[i] : i);

    ref const(T) get(T)(uint i) const pure
        => (cast(const(T)*)data)[i];

    Variant box(uint i) const
        => box_record(cast(const(ubyte)*)data + i*data_format.stride, *data_format);
}

enum SeriesEvent : ubyte
{
    none,
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

    RecordBlock read(FormatId format, ulong from_index, uint max_records)
    {
        RecordBlock r;
        r.format = format;
        const(DataFormat)* fmt = format_info(format);
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
    if (!unbox_scalar_value(v, fmt, s))
        return false;
    return !fmt.constraint || !fmt.constraint.check(s, fmt);
}

private FormatId register_variant_format(ref const Variant value)
{
    DataFormat format;
    if (value.isBool)
        format = DataFormat(ValueType.bool_, SeriesKind.held);
    else if (value.isString)
    {
        format = DataFormat(ValueType.char_, SeriesKind.held);
        format.count = 0;
    }
    else if (value.isNumber)
    {
        ValueType type;
        if (value.isFloat)
            type = ValueType.f32;
        else if (value.isDouble)
            type = ValueType.f64;
        else if (value.isUlong && !value.isLong)
            type = ValueType.u64;
        else
            type = ValueType.s64;

        if (value.is_enum)
            format = DataFormat(type, SeriesKind.held, value.get_enum_info());
        else if (value.isQuantity)
            format = DataFormat(type, SeriesKind.held, value.asQuantity.unit);
        else
            format = DataFormat(type, SeriesKind.held);
    }
    else if (value.isBuffer)
    {
        assert(value.asBuffer.length > 1 && value.asBuffer.length <= ubyte.max,
               "dynamic and single-byte buffers need an explicit format");
        format = DataFormat(ValueType.u8, SeriesKind.held);
        format.count = cast(ubyte)value.asBuffer.length;
    }
    else
        assert(false, "value has no stable element format");

    return register_format(format);
}

private bool unbox_scalar_value(ref const Variant v, ref const DataFormat fmt, out Scalar s)
{
    if (!fmt.is_scalar)
        return false;

    if (fmt.desc == DataFormat.Desc.quantity)
    {
        if (!v.isQuantity || v.asQuantity!double().unit.unit != fmt.unit.unit)
            return false;
    }
    else if (fmt.desc == DataFormat.Desc.enum_)
    {
        if (!v.is_enum || v.get_enum_info() !is fmt.enum_info)
            return false;
    }
    else if (v.isQuantity || v.is_enum)
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
            if (fmt.desc != DataFormat.Desc.quantity || v.asQuantity!double().unit == fmt.unit)
                return store_integer(v, fmt.type, s);
            double d;
            if (!unbox_double(v, fmt, d))
                return false;
            Variant scaled = Variant(d);
            return store_integer(scaled, fmt.type, s);
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

    DataFormat u16 = DataFormat(ValueType.u16, SeriesKind.held);
    DataFormat u32 = DataFormat(ValueType.u32, SeriesKind.sampled);
    assert(value_compatible(u16, u32));
    Variant small = Variant(ushort(65_000));
    assert(unbox_scalar(small, u32, sc) && sc.u == 65_000);
    Variant large = Variant(100_000U);
    assert(!unbox_scalar(large, u16, sc));
    Variant negative = Variant(-1);
    assert(!unbox_scalar(negative, u16, sc));
    Constraint range;
    range.min = Scalar.of(ushort(10));
    range.max = Scalar.of(ushort(20));
    range.has = Constraint.Has.min | Constraint.Has.max;
    u16.constraint = &range;
    Variant inside = Variant(ushort(15));
    Variant outside = Variant(ushort(21));
    assert(unbox_scalar(inside, u16, sc));
    assert(!unbox_scalar(outside, u16, sc));

    import urt.si.unit : Ampere, Volt;
    DataFormat amps = DataFormat(ValueType.u16, SeriesKind.held, ScaledUnit(Ampere));
    DataFormat milliamps = DataFormat(ValueType.u16, SeriesKind.held, ScaledUnit(Ampere, -3));
    DataFormat volts = DataFormat(ValueType.u16, SeriesKind.held, ScaledUnit(Volt));
    assert(value_compatible(amps, milliamps));
    assert(!value_compatible(amps, volts));
    Variant one_amp = Variant(Quantity!ushort(1_000, ScaledUnit(Ampere, -3)));
    assert(unbox_scalar(one_amp, amps, sc) && sc.u == 1);

    enum ModeA : ushort { off, on }
    enum ModeB : ushort { off, on }
    import urt.meta.enuminfo : enum_info;
    DataFormat mode_a = DataFormat(ValueType.u16, SeriesKind.held, enum_info!ModeA.make_void());
    DataFormat mode_b = DataFormat(ValueType.u16, SeriesKind.held, enum_info!ModeB.make_void());
    assert(value_compatible(mode_a, mode_a));
    assert(!value_compatible(mode_a, mode_b));
}


private:

package immutable ubyte[ValueType.max + 1] g_type_stride = [ 1, 1, 1, 2, 2, 4, 4, 8, 8, 4, 8, 1, 0 ];

__gshared Array!(DataFormat*) g_formats;

typeof(g_formats)* format_registry()
    => &g_formats;

bool format_equal(ref const DataFormat a, ref const DataFormat b) pure
{
    if (a.type != b.type || a.kind != b.kind || a.desc != b.desc ||
        a.count != b.count || a.rate != b.rate || a.clock !is b.clock || a.constraint !is b.constraint)
        return false;
    if (a.type == ValueType.user)
        return a.user_type is b.user_type;
    final switch (a.desc) with (DataFormat.Desc)
    {
        case none:     return true;
        case quantity: return a.unit == b.unit;
        case enum_:    return a.enum_info is b.enum_info;
    }
}

int compare_scalar(ref const Scalar a, ref const Scalar b, ValueType type) pure
{
    final switch (type) with (ValueType)
    {
        case bool_:
            return int(a.b) - int(b.b);
        case u8:
            return compare(*cast(const(ubyte)*)a.raw.ptr, *cast(const(ubyte)*)b.raw.ptr);
        case s8:
            return compare(*cast(const(byte)*)a.raw.ptr, *cast(const(byte)*)b.raw.ptr);
        case u16:
            return compare(*cast(const(ushort)*)a.raw.ptr, *cast(const(ushort)*)b.raw.ptr);
        case s16:
            return compare(*cast(const(short)*)a.raw.ptr, *cast(const(short)*)b.raw.ptr);
        case u32:
            return compare(*cast(const(uint)*)a.raw.ptr, *cast(const(uint)*)b.raw.ptr);
        case s32:
            return compare(*cast(const(int)*)a.raw.ptr, *cast(const(int)*)b.raw.ptr);
        case u64:
            return compare(a.u, b.u);
        case s64:
            return compare(a.i, b.i);
        case f32:
            return compare(a.f32_, b.f32_);
        case f64:
            return compare(a.f64_, b.f64_);
        case char_, user:
            return 0;
    }
}

int compare(T)(T a, T b) pure
    => a < b ? -1 : a > b;

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

bool store_integer(ref const Variant v, ValueType type, out Scalar s)
{
    final switch (type) with (ValueType)
    {
        case u8:
            if (!v.canFitInt!ubyte) return false;
            s = Scalar.of(cast(ubyte)v.asUlong);
            return true;
        case s8:
            if (!v.canFitInt!byte) return false;
            s = Scalar.of(cast(byte)v.asLong);
            return true;
        case u16:
            if (!v.canFitInt!ushort) return false;
            s = Scalar.of(cast(ushort)v.asUlong);
            return true;
        case s16:
            if (!v.canFitInt!short) return false;
            s = Scalar.of(cast(short)v.asLong);
            return true;
        case u32:
            if (!v.canFitInt!uint) return false;
            s = Scalar.of(v.asUint);
            return true;
        case s32:
            if (!v.canFitInt!int) return false;
            s = Scalar.of(v.asInt);
            return true;
        case u64:
            if (!v.canFitInt!ulong) return false;
            s = Scalar.of(v.asUlong);
            return true;
        case s64:
            if (!v.canFitInt!long) return false;
            s = Scalar.of(v.asLong);
            return true;
        case bool_, f32, f64, char_, user:
            return false;
    }
}

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
