module manager.series;

// The series contract: the typed record format shared by every host of observed data.
// Element is the first host; the recorder's ows containers and waveform/byte/packet taps
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
// dynamic record. A string is dynamic char data; a blob is dynamic u8 data with opaque display.
// Storage rule: every record is raw bytes. A dynamic record is a u16 offset into its bucket's
// byte heap, where the value lives as a u15 length prefix (top bit reserved) and its bytes,
// 2-aligned, de-duplicated within the bucket. The record plane stays fixed-stride and the whole
// image is context-free, so RAM buckets and serialised blocks are byte-identical. Values are
// capped at MaxStringLen (32K); anything larger is content, not an observation - that's a tap.
// Non-pod user types copy and drop through their registry hooks.

import urt.array;
import urt.mem.alloc;
import urt.mem.allocator : defaultAllocator;
import urt.meta.enuminfo : enum_info, VoidEnumInfo;
import urt.si.quantity : Quantity;
import urt.si.unit : Nanosecond, ScaledUnit;
import urt.string : String;
import urt.time;
import urt.traits : is_boolean, is_some_float, is_some_int, Unqual;
import urt.typereg : find_type_details, TypeDetails;
import urt.variant;

import manager.ows : SeriesContainer;

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

// FormatIds are process-local identities. Registered descriptors are immutable and remain
// alive for the process lifetime, so equality is an integer comparison after registration.
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

FormatId register_value_format(T)(auto ref const T value)
{
    static if (is(Unqual!T == Variant))
        return register_variant_format(value);
    else
        return register_value_format!T();
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
    else static if (is(U == Quantity!(N, scale), N, ScaledUnit scale))
        return register_format(DataFormat(value_type_of!N, SeriesKind.held, scale));
    else static if (ValidUserType!U)
    {
        alias registered = MakeTypeDetails!U;   // registration rides its shared static this
        return register_format(DataFormat(ValueType.user, SeriesKind.held,
                                          &find_type_details(TypeDetailsFor!U.type_id)));
    }
    else
        static assert(false, "value needs an explicit record format");
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
            return 2; // dynamic records are u16 offsets into the bucket heap
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

// a dynamic value in a bucket heap: u15 length prefix (top bit reserved, must be zero),
// bytes follow, entries 2-aligned so the prefix read is always aligned. The prefix counts
// BYTES regardless of element type - the format's element stride divides it and the item
// count derives - so heaps walk blind, without a format in hand.
uint heap_entry_bytes(size_t length) pure
    => cast(uint)(ushort.sizeof + length + (length & 1));

const(void)[] heap_view(const(void)* heap, uint offset) pure
{
    const(ushort)* p = cast(const(ushort)*)(cast(const(ubyte)*)heap + offset);
    return (cast(const(void)*)(p + 1))[0 .. *p & 0x7FFF];
}

struct RecordBlock
{
nothrow @nogc:

    ulong first_index;
    ulong t0;           // time base
    ulong lost;         // records evicted between the reader's position and this block
    const(uint)* ts;    // null if the series is regular
    const(void)* data;
    const(void)* heap;  // dynamic-record series: the byte heap the records' offsets resolve in
    FormatId format;
    uint count;
    uint heap_bytes;

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

    // dynamic records resolve through the heap as opaque bytes - the format is their context,
    // applied at the boxing edge; the view borrows the block's lifetime
    const(void)[] dynamic(uint i) const pure
        => heap_view(heap, (cast(const(ushort)*)data)[i]);

    const(char)[] text(uint i) const pure
    {
        debug assert(data_format.is_text);
        return cast(const(char)[])dynamic(i);
    }

    Variant box(uint i) const
    {
        const(DataFormat)* f = data_format;
        if (f.count == 0)
        {
            if (f.type == ValueType.char_)
                return Variant(cast(const(char)[])dynamic(i));
            if (f.type == ValueType.u8)
                return Variant(dynamic(i));
            assert(false, "TODO: typed dynamic arrays box as Variant arrays");
        }
        return box_record(cast(const(ubyte)*)data + i*f.stride, *f);
    }
}

// One codec vocabulary, three residencies: a packed image is the same bytes whether it lives
// behind a RAM bucket, in an ows block, or in flight. The raw image layout is
// [offsets plane?][record plane][heap], identical to the ows payload. Codecs register with
// a selection predicate; the first match packs and RAW is the mandatory fallback (a codec
// that doesn't beat raw is ignored). Ids 0/1 are reserved (raw, zlib); registered ids are
// process-local: TODO bind them by NAME before any ships.
enum ubyte ows_codec_raw = 0;
enum ubyte ows_codec_zlib = 1;
enum ubyte first_registered_codec = 2;

struct SeriesCodec
{
    const(char)[] name;
    bool function(ref const DataFormat fmt, ref const RecordBlock blk) nothrow @nogc match;
    // pack the raw image into dst; bytes written, or -1 to decline (raw applies)
    ptrdiff_t function(ref const RecordBlock blk, const(void)[] raw, void[] dst) nothrow @nogc pack;
    // unpack a payload into the raw image; false = corrupt
    bool function(const(void)[] src, ref const DataFormat fmt, uint count, bool irregular,
                  uint heap_bytes, void[] dst) nothrow @nogc unpack;
}

ubyte register_series_codec(ref const SeriesCodec codec)
{
    assert(g_num_codecs < g_codecs.length, "too many series codecs");
    g_codecs[g_num_codecs] = codec;
    return cast(ubyte)(first_registered_codec + g_num_codecs++);
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
    ulong file_offset; // container file offset of the encoded image; 0 = never flushed
    uint last_offset;
    uint count;
    uint capacity;     // open builder only; == count once sealed
    FormatId format = FormatId.invalid; // stamped at creation; a format change rolls the bucket
    bool follows_gap;  // <- we should steal a bit for this!
    bool sealed;       // tail retired: the raw side is one immutable image

    // The residency entry: samples/offsets/heap are the raw side, packed the encoded side,
    // file_offset the same encoded image on disk. An open bucket is a builder whose planes
    // grow independently; a sealed bucket's raw side is one allocation in
    // [offsets | records | heap] order, byte-identical to the ows payload. A sealed bucket
    // packs on its last release; with another residency present the raw side is a cache,
    // dropped at refs==0 and reconstituted on demand for late readers. A bucket with no
    // resident bytes is recoverable through its file_offset.
    void* samples;
    uint* offsets;     // null when regular
    void* heap;        // dynamic-record series: 2-aligned len-prefixed values, dedup'd per bucket
    uint heap_used;
    uint heap_capacity;
    void* packed;
    uint packed_bytes;  // size of the encoded image, in RAM and/or on disk
    ushort refs;        // readers borrowing the raw side; the open tail is implicitly protected
    ubyte codec;        // codec of the encoded image; ows_codec_raw = the raw image itself
    bool pack_declined; // codecs tried and beaten by raw, or the file holds it raw; don't retry

pure nothrow @nogc:
    ulong last_tick() const => first_tick + last_offset;
    SysTime first_time() const => from_unix_time_ns(first_tick * 1000);
    SysTime last_time() const => from_unix_time_ns(last_tick * 1000);
    SysTime get_time(size_t i) const => from_unix_time_ns((first_tick + (offsets ? offsets[i] : i)) * 1000);

    bool resident() const => samples !is null || packed !is null;

    // sealed raw image size; the offsets plane's presence follows the format, not the
    // (possibly dropped) pointer
    uint image_bytes() const
    {
        const(DataFormat)* f = format_info(format);
        return (f.regular ? 0 : count * cast(uint)uint.sizeof) + count * f.stride + heap_used;
    }
}

struct SeriesStore
{
nothrow @nogc:

    // retention model, min/max per axis: floors (min_*) KEEP records even after consumption
    // (for rendering), pins EXTEND retention until the consumer advances past, ceilings (max_*)
    // FORCE eviction regardless of pins (stalled or undriven consumers get lapped and the
    // cursor reports records_lost); between floor and ceiling, consumption governs
    Array!(Bucket*) buckets;
    SeriesContainer* container; // backing store; buckets evicted to disk reconstitute through it
    ulong head;
    ulong min_age;      // usecs (converted to domain ticks at evict time); 0 = none
    ulong max_age;      // usecs; 0 = no ceiling
    uint min_records;   // 0 = none
    uint max_records;   // 0 = no ceiling
    ushort cursor_mask;
    ushort pin_mask;    // cursors voluntary eviction must not pass; consumption = advancing the cursor
    ulong[16] pin_position;
    Bucket*[16] cursor_ref; // the bucket each cursor's raw-side borrow guards; ref moves as the cursor does

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

    // cursor_bit tracks the reader's raw-side borrow: the cursor's ref moves to the bucket it
    // reads, so a view stays valid until the next read. Bit-less reads (queries) reconstitute
    // without a ref; their loose raws drop at the next cursor close (byte budgets own the rest).
    // `format` only labels an empty result; a found bucket speaks for itself. When from_index
    // falls in an evicted hole the read serves from the next surviving bucket and reports the
    // skip through r.first_index.
    RecordBlock read(FormatId format, ulong from_index, uint max_records, ubyte cursor_bit = ubyte.max)
    {
        RecordBlock r;
        r.format = format;
        Bucket* b = find_by_index(from_index);
        if (cursor_bit != ubyte.max)
            move_ref(cursor_bit, b);
        if (!b)
            return r;
        if (!b.samples && !reconstitute(b))
            return r;
        if (from_index < b.first_index)
            from_index = b.first_index;
        const(DataFormat)* fmt = format_info(b.format);
        r.format = b.format;
        uint offset = cast(uint)(from_index - b.first_index);
        uint n = b.count - offset;
        if (n > max_records)
            n = max_records;
        r.data = cast(const(ubyte)*)b.samples + offset*fmt.stride;
        r.count = n;
        r.ts = b.offsets ? b.offsets + offset : null;
        r.t0 = b.offsets ? b.first_tick : b.first_tick + offset;
        r.first_index = from_index;
        r.heap = b.heap;
        r.heap_bytes = b.heap_used;
        return r;
    }

    void move_ref(ubyte bit, Bucket* b)
    {
        Bucket* old = cursor_ref[bit];
        if (old is b)
            return;
        cursor_ref[bit] = b;
        if (b)
            ++b.refs;
        if (old)
            release_ref(old);
    }

    void release_ref(Bucket* b)
    {
        debug assert(b.refs);
        if (--b.refs)
            return;
        if (b.packed || b.file_offset)
            drop_raw(b);
        else
            try_pack(b);
    }

    // retire the open tail: shrink the builder planes into one immutable image in
    // [offsets | records | heap] order, byte-identical to the ows payload
    void seal(Bucket* b)
    {
        if (b.sealed)
            return;
        debug assert(b.count, "empty buckets are recycled, not sealed");
        const(DataFormat)* fmt = format_info(b.format);
        uint offs_bytes = b.offsets ? b.count * cast(uint)uint.sizeof : 0;
        uint rec_bytes = b.count * fmt.stride;
        uint total = offs_bytes + rec_bytes + b.heap_used;
        void[] img = alloc(total);
        ubyte* p = cast(ubyte*)img.ptr;
        p[0 .. offs_bytes] = (cast(const(ubyte)*)b.offsets)[0 .. offs_bytes];
        p[offs_bytes .. offs_bytes + rec_bytes] = (cast(const(ubyte)*)b.samples)[0 .. rec_bytes];
        p[offs_bytes + rec_bytes .. total] = (cast(const(ubyte)*)b.heap)[0 .. b.heap_used];
        free(b.samples[0 .. b.capacity * fmt.stride]);
        if (b.offsets)
            free((cast(void*)b.offsets)[0 .. b.capacity * uint.sizeof]);
        if (b.heap)
            free(b.heap[0 .. b.heap_capacity]);
        b.sealed = true;
        b.offsets = offs_bytes ? cast(uint*)p : null;
        b.samples = p + offs_bytes;
        b.heap = b.heap_used ? p + offs_bytes + rec_bytes : null;
        b.capacity = b.count;
        b.heap_capacity = b.heap_used;
        // pack now if nothing borrows the raw side; otherwise the last release_ref packs
        try_pack(b);
    }

    // packing only reads the raw side, so it may run on any sealed bucket regardless of
    // readers (a disk writer can pack what the UX is still rendering); only DROPPING raw
    // waits for the last borrow to release. A flushed bucket never re-packs: the file is
    // the canonical encoded copy and codec/packed_bytes describe it.
    void try_pack(Bucket* b)
    {
        if (b.packed || b.pack_declined || b.file_offset || !b.sealed || !b.count || !g_num_codecs)
            return;
        const(DataFormat)* fmt = format_info(b.format);
        RecordBlock blk = block_view(b);
        void* base = b.offsets ? cast(void*)b.offsets : b.samples;
        const(void)[] img = base[0 .. b.image_bytes];

        foreach (i; 0 .. g_num_codecs)
        {
            if (!g_codecs[i].match || !g_codecs[i].match(*fmt, blk))
                continue;
            void[] dst = alloc(img.length);
            ptrdiff_t packed_size = g_codecs[i].pack(blk, img, dst);
            if (packed_size > 0 && packed_size < img.length)
            {
                b.packed = realloc(dst, packed_size).ptr;
                b.packed_bytes = cast(uint)packed_size;
                b.codec = cast(ubyte)(first_registered_codec + i);
                if (!b.refs)
                    drop_raw(b);
            }
            else
                free(dst);
            break;
        }
        if (!b.packed)
            b.pack_declined = true;
    }

    // repopulate the raw side from the packed image, or from the container for a bucket
    // evicted to disk: one combined allocation in the shared image layout, shared by every
    // reader positioned in the bucket until the last ref drops it again
    bool reconstitute(Bucket* b)
    {
        if (b.samples)
            return true;
        const(DataFormat)* fmt = format_info(b.format);
        bool irregular = !fmt.regular;
        uint offs_bytes = irregular ? b.count * cast(uint)uint.sizeof : 0;
        uint rec_bytes = b.count * fmt.stride;
        uint total = offs_bytes + rec_bytes + b.heap_used;

        const(void)[] encoded = b.packed ? b.packed[0 .. b.packed_bytes] : null;
        void[] fetched;
        if (!encoded)
        {
            if (!b.file_offset || !container)
                return false;
            debug assert(b.packed_bytes, "flushed bucket lost its payload size");
            fetched = alloc(b.packed_bytes);
            if (!container.read_payload(*b, fetched))
            {
                free(fetched);
                return false;
            }
            if (b.codec == ows_codec_raw)
            {
                debug assert(b.packed_bytes == total, "raw payload size disagrees with the headers");
                mount_raw(b, fetched.ptr, offs_bytes, rec_bytes, irregular);
                return true;
            }
            encoded = fetched;
        }
        if (b.codec < first_registered_codec || b.codec >= first_registered_codec + g_num_codecs)
        {
            if (fetched)
                free(fetched);
            return false;
        }
        void[] img = alloc(total);
        bool ok = g_codecs[b.codec - first_registered_codec].unpack(encoded, *fmt, b.count,
                                                                    irregular, b.heap_used, img);
        if (fetched)
            free(fetched);
        if (!ok)
        {
            free(img);
            debug assert(false, "packed bucket failed to reconstitute");
            return false;
        }
        mount_raw(b, img.ptr, offs_bytes, rec_bytes, irregular);
        return true;
    }

    // free the raw side; entered with another residency present, or from bucket teardown
    void drop_raw(Bucket* b)
    {
        if (!b.samples)
            return;
        const(DataFormat)* fmt = format_info(b.format);
        if (b.sealed)
        {
            void* base = b.offsets ? cast(void*)b.offsets : b.samples;
            free(base[0 .. b.image_bytes]);
        }
        else
        {
            free(b.samples[0 .. b.capacity * fmt.stride]);
            if (b.offsets)
                free((cast(void*)b.offsets)[0 .. b.capacity * uint.sizeof]);
            if (b.heap)
                free(b.heap[0 .. b.heap_capacity]);
        }
        b.samples = null;
        b.offsets = null;
        b.heap = null;
        b.capacity = 0;
        b.heap_capacity = 0;
    }

    void free_bucket(Bucket* b)
    {
        drop_raw(b);
        if (b.packed)
        {
            free(b.packed[0 .. b.packed_bytes]);
            b.packed = null;
        }
        foreach (bit; 0 .. 16)
            if (cursor_ref[bit] is b)
                cursor_ref[bit] = null;    // lapped reader; its borrow dies with the bucket
        free((cast(void*)b)[0 .. Bucket.sizeof]);
    }

    // sweep raws reconstituted by bit-less readers (queries); called from cursor close
    void drop_loose_raws()
    {
        foreach (b; buckets[])
            if (b.sealed && b.samples && !b.refs && (b.packed || b.file_offset))
                drop_raw(b);
    }

    // the backing store is going away: descriptors whose only residency was the file are
    // unreachable and drop; survivors forget their file copy and stand alone again
    void detach_container()
    {
        container = null;
        for (size_t i = 0; i < buckets.length; )
        {
            Bucket* b = buckets[i];
            if (!b.resident && b.file_offset)
            {
                free_bucket(b);
                buckets.remove(i);
                continue;
            }
            b.file_offset = 0;
            if (!b.packed)
            {
                b.packed_bytes = 0;
                b.codec = 0;
            }
            ++i;
        }
    }

    RecordBlock block_view(Bucket* b)
    {
        RecordBlock blk;
        blk.format = b.format;
        blk.count = b.count;
        blk.first_index = b.first_index;
        blk.t0 = b.first_tick;
        blk.ts = b.offsets;
        blk.data = b.samples;
        blk.heap = b.heap;
        blk.heap_bytes = b.heap_used;
        return blk;
    }

private:
    void mount_raw(Bucket* b, void* base, uint offs_bytes, uint rec_bytes, bool irregular)
    {
        b.offsets = irregular ? cast(uint*)base : null;
        b.samples = cast(ubyte*)base + offs_bytes;
        b.heap = b.heap_used ? cast(ubyte*)base + offs_bytes + rec_bytes : null;
        b.capacity = b.count;
        b.heap_capacity = b.heap_used;
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
            assert(false, "dynamic records resolve through their heap; box at the host (RecordBlock.box)");
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
    => unbox_scalar_checked(v, fmt, s) is null;

// as unbox_scalar, but reports WHY a value is refused; null = accepted
const(char)[] unbox_scalar_checked(ref const Variant v, ref const DataFormat fmt, out Scalar s)
{
    if (!unbox_scalar_value(v, fmt, s))
        return "incompatible value";
    return fmt.constraint ? fmt.constraint.check(s, fmt) : null;
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
        // wrong dimensions never store; unitless numbers adopt the format's unit
        if (v.isQuantity && v.asQuantity!double().unit.unit != fmt.unit.unit)
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
    assert(s.stride == 2 && !s.is_scalar && s.is_text);

    // heap entries: len-prefixed, 2-aligned; views resolve through the offset
    assert(heap_entry_bytes(3) == 6 && heap_entry_bytes(4) == 6 && heap_entry_bytes(0) == 2);
    ushort[7] mini = [3, 0, 0, 5, 0, 0, 0];
    (cast(char*)mini.ptr)[2 .. 5] = "abc";
    (cast(char*)mini.ptr)[8 .. 13] = "hello";
    assert(cast(const(char)[])heap_view(mini.ptr, 0) == "abc");
    assert(cast(const(char)[])heap_view(mini.ptr, 6) == "hello");

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
    Variant under = Variant(ushort(5));
    assert(unbox_scalar(inside, u16, sc));
    assert(!unbox_scalar(outside, u16, sc));
    assert(unbox_scalar_checked(outside, u16, sc) == "above maximum");
    assert(unbox_scalar_checked(under, u16, sc) == "below minimum");
    assert(unbox_scalar_checked(negative, u16, sc) == "incompatible value");

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

package __gshared SeriesCodec[8] g_codecs;
package __gshared ubyte g_num_codecs;

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
            if (!v.canFitInt!ubyte)
                return false;
            s = Scalar.of(cast(ubyte)v.asUlong);
            return true;
        case s8:
            if (!v.canFitInt!byte)
                return false;
            s = Scalar.of(cast(byte)v.asLong);
            return true;
        case u16:
            if (!v.canFitInt!ushort)
                return false;
            s = Scalar.of(cast(ushort)v.asUlong);
            return true;
        case s16:
            if (!v.canFitInt!short)
                return false;
            s = Scalar.of(cast(short)v.asLong);
            return true;
        case u32:
            if (!v.canFitInt!uint)
                return false;
            s = Scalar.of(v.asUint);
            return true;
        case s32:
            if (!v.canFitInt!int)
                return false;
            s = Scalar.of(v.asInt);
            return true;
        case u64:
            if (!v.canFitInt!ulong)
                return false;
            s = Scalar.of(v.asUlong);
            return true;
        case s64:
            if (!v.canFitInt!long)
                return false;
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
