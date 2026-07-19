module manager.sample;

// The value gateway: the one decode/encode surface, composing wire layout (manager.wire),
// bespoke encodings (manager.codec), registered types (urt.typereg) and record formats
// (manager.series). All traffic is (DataFormat, void[]) records; Variant appears only at
// the mount's boxing edge. The gateway never allocates: dynamic values (text) return
// transient views and mint their String at the mount, where latest lives.

import urt.conv;
import urt.map : Map;
import urt.meta.enuminfo : enum_info_equal, enum_info_size, VoidEnumInfo;
import urt.mem.allocator : defaultAllocator;
import urt.si.unit : ScaledUnit;
import urt.string : ieq, makeString, String;
import urt.string.format : formatValue;
import urt.typereg : TypeDetails;
import urt.variant : Variant;

import manager.codec;
import manager.series;
import manager.wire;

nothrow @nogc:


// the compiled per-point desc: what profiles compile to, what bindings hold per element.
// pre_scale is runtime-mutable (SunSpec scale-factor registers poke it); format and
// encoding resolve through the global registries by index, keeping the desc at 12 bytes
struct SampleDesc
{
nothrow @nogc:

    WireLayout layout;
    float pre_scale = 1;
    ushort format = 0xFFFF;
    ushort encoding = 0xFFFF;

    bool valid() const
        => format != 0xFFFF;

    const(DataFormat)* fmt() const
        => format_by_index(format);

    const(Encoding)* enc() const
        => encoding == 0xFFFF ? null : encoding_by_index(encoding);
}

// Global format mint: one shared immutable instance per distinct shape, held forever.
// This is the durable home mounts point at - formats outlive profiles and bindings.
// Minting is config-time-cold (profile load); runtime resolves by index only.
ushort mint_format(DataFormat shape)
{
    foreach (i, f; g_formats)
    {
        if (format_equal(*f, shape))
            return cast(ushort)i;
    }
    assert(g_formats.length < 0xFFFF, "format mint full");
    DataFormat* f = defaultAllocator().allocT!DataFormat();
    *f = shape;
    g_formats ~= f;
    return cast(ushort)(g_formats.length - 1);
}

const(DataFormat)* format_by_index(ushort i)
{
    assert(i < g_formats.length, "invalid format index");
    return g_formats[i];
}

ushort mint_desc(ref const SampleDesc desc)
{
    foreach (i, ref d; g_descs)
    {
        if (d == desc)
            return cast(ushort)i;
    }
    assert(g_descs.length < 0xFFFF, "desc mint full");
    g_descs ~= desc;
    return cast(ushort)(g_descs.length - 1);
}

SampleDesc desc_by_index(ushort i)
{
    assert(i < g_descs.length, "invalid desc index");
    return g_descs[i];
}

const(VoidEnumInfo)* register_enum_info(const(char)[] name, const(VoidEnumInfo)* info, bool owned = true)
{
    if (const(VoidEnumInfo)** e = name in g_enums)
    {
        if (enum_info_equal(**e, *info))
        {
            if (owned && info !is *e)
                defaultAllocator().free((cast(void*)info)[0 .. enum_info_size(*info)]);
            return *e;
        }
        // rebind; the prior definition stays alive for existing mounts
        *e = info;
        return info;
    }
    g_enums.insert(name.makeString(defaultAllocator()), info);
    return info;
}

const(VoidEnumInfo)* find_enum_info(const(char)[] name)
{
    if (const(VoidEnumInfo)** e = name in g_enums)
        return *e;
    return null;
}

// binary wire -> one native record; false when the desc can't represent the bytes
bool sample_record(const(void)[] wire, ref const SampleDesc desc, void[] record)
{
    ubyte[256] image = void;

    const(Encoding)* enc = desc.enc;
    if (enc)
    {
        uint n = enc.wire_bytes;
        if (wire.length < n || !enc.decode)
            return false;
        wire_image(wire[0 .. n], desc.layout, image[0 .. n]);
        return enc.decode(image[0 .. n], record);
    }

    const(DataFormat)* fmt = desc.fmt;
    if (fmt.type == ValueType.user)
    {
        const(TypeDetails)* td = fmt.user_type;
        uint n = td.size;
        if (wire.length < n || record.length < n || n > image.length)
            return false;
        wire_image(wire[0 .. n], desc.layout, image[0 .. n]);
        if (td.serialise)
            return td.serialise(record.ptr, image[0 .. n], false) == n;
        if (member_flip(desc.layout))
        {
            if (!td.byte_reverse)
                return false;
            td.byte_reverse(image.ptr, record.ptr);
        }
        else
            (cast(ubyte*)record.ptr)[0 .. n] = image[0 .. n];
        return true;
    }

    if (fmt.count != 1)
        return false; // TODO: vectors land with their first producer
    if (wire.length < desc.layout.container_bytes || record.length < fmt.stride)
        return false;

    final switch (fmt.type) with (ValueType)
    {
        case bool_:
            *cast(bool*)record.ptr = wire_extract(wire, desc.layout) != 0;
            return true;

        case u8, s8, u16, s16, u32, s32, u64, s64:
        {
            assert(desc.pre_scale == 1, "scaled values record as f64");
            ulong raw = desc.layout.kind == WireKind.float_
                      ? cast(ulong)cast(long)wire_extract_float(wire, desc.layout)  // enumf32: float wire, integer record
                      : wire_extract(wire, desc.layout);
            store_int(record.ptr, fmt.type, raw);
            return true;
        }

        case f32, f64:
        {
            double v;
            if (desc.layout.kind == WireKind.float_)
                v = wire_extract_float(wire, desc.layout);
            else
            {
                ulong raw = wire_extract(wire, desc.layout);
                v = desc.layout.kind == WireKind.signed_ ? double(long(raw)) : double(raw);
            }
            v *= desc.pre_scale;
            if (fmt.type == f32)
                *cast(float*)record.ptr = cast(float)v;
            else
                *cast(double*)record.ptr = v;
            return true;
        }

        case char_, user:
            return false; // text via sample_text; user handled above
    }
}

// record -> wire bytes; read-modify-write, so decomposed fields sharing a container survive
bool emit_record(const(void)[] record, ref const SampleDesc desc, void[] wire)
{
    ubyte[256] image = void;

    const(Encoding)* enc = desc.enc;
    if (enc)
    {
        uint n = enc.wire_bytes;
        if (wire.length < n || !enc.encode || !enc.encode(record, image[0 .. n]))
            return false;
        wire_image_encode(image[0 .. n], desc.layout, wire[0 .. n]);
        return true;
    }

    const(DataFormat)* fmt = desc.fmt;
    if (fmt.type == ValueType.user)
    {
        const(TypeDetails)* td = fmt.user_type;
        uint n = td.size;
        if (wire.length < n || record.length < n || n > image.length)
            return false;
        if (td.serialise)
        {
            if (td.serialise(cast(void*)record.ptr, image[0 .. n], true) != n)
                return false;
        }
        else if (member_flip(desc.layout))
        {
            if (!td.byte_reverse)
                return false;
            td.byte_reverse(record.ptr, image.ptr);
        }
        else
            image[0 .. n] = (cast(const(ubyte)*)record.ptr)[0 .. n];
        wire_image_encode(image[0 .. n], desc.layout, wire[0 .. n]);
        return true;
    }

    if (fmt.count != 1)
        return false;
    if (wire.length < desc.layout.container_bytes || record.length < fmt.stride)
        return false;

    final switch (fmt.type) with (ValueType)
    {
        case bool_:
            wire_insert(wire, desc.layout, *cast(const(bool)*)record.ptr ? 1 : 0);
            return true;

        case u8, s8, u16, s16, u32, s32, u64, s64:
        {
            ulong raw = load_int(record.ptr, fmt.type);
            if (desc.layout.kind == WireKind.float_)
            {
                if (desc.layout.bit_width == 32)
                {
                    float f = float(long(raw));
                    raw = *cast(uint*)&f;
                }
                else
                {
                    double d = double(long(raw));
                    raw = *cast(ulong*)&d;
                }
            }
            wire_insert(wire, desc.layout, raw);
            return true;
        }

        case f32, f64:
        {
            double v = fmt.type == f32 ? *cast(const(float)*)record.ptr : *cast(const(double)*)record.ptr;
            v /= desc.pre_scale;
            ulong raw;
            if (desc.layout.kind == WireKind.float_)
            {
                if (desc.layout.bit_width == 32)
                {
                    float f = cast(float)v;
                    raw = *cast(uint*)&f;
                }
                else
                    raw = *cast(ulong*)&v;
            }
            else
                raw = cast(ulong)cast(long)(v < 0 ? v - 0.5 : v + 0.5);
            wire_insert(wire, desc.layout, raw);
            return true;
        }

        case char_, user:
            return false;
    }
}

// text token -> one native record
bool parse_record(const(char)[] token, ref const SampleDesc desc, void[] record)
{
    const(Encoding)* enc = desc.enc;
    if (enc)
        return enc.parse && enc.parse(token, record) > 0;

    const(DataFormat)* fmt = desc.fmt;
    if (fmt.type == ValueType.user)
    {
        const(TypeDetails)* td = fmt.user_type;
        if (record.length < td.size || !td.stringify)
            return false;
        return td.stringify(record.ptr, cast(char[])token, false, null, null) > 0;
    }
    if (fmt.count != 1 || record.length < fmt.stride)
        return false;

    final switch (fmt.type) with (ValueType)
    {
        case bool_:
            *cast(bool*)record.ptr = token.ieq("true") || token.ieq("1") || token.ieq("on");
            return true;

        case u8, s8, u16, s16, u32, s32, u64, s64:
        {
            size_t taken;
            long v = parse_int_with_base(token, &taken);
            if (taken != token.length)
            {
                const(VoidEnumInfo)* ei = fmt.desc == DataFormat.Desc.enum_ ? fmt.enum_info : null;
                if (!ei)
                    return false;
                if (ei.bitfield)
                {
                    bool ok;
                    v = ei.parse_flags(token, ok);
                    if (!ok)
                        return false;
                }
                else
                    v = ei.value_for(token).asLong;
            }
            store_int(record.ptr, fmt.type, cast(ulong)v);
            return true;
        }

        case f32, f64:
        {
            size_t taken;
            int e;
            uint base;
            long raw = parse_int_with_exponent_and_base(token, e, base, &taken);
            if (taken == 0)
                return false;
            double v = raw * double(base)^^e * desc.pre_scale;
            if (fmt.type == f32)
                *cast(float*)record.ptr = cast(float)v;
            else
                *cast(double*)record.ptr = v;
            return true;
        }

        case char_, user:
            return false;
    }
}

// record -> text; chars written, or -1 (legacy behaviour: enums write numbers)
ptrdiff_t format_record(const(void)[] record, ref const SampleDesc desc, char[] buffer)
{
    const(Encoding)* enc = desc.enc;
    if (enc)
        return enc.format_text ? enc.format_text(record, buffer) : -1;

    const(DataFormat)* fmt = desc.fmt;
    if (fmt.type == ValueType.user)
    {
        const(TypeDetails)* td = fmt.user_type;
        return td.stringify ? td.stringify(cast(void*)record.ptr, buffer, true, null, null) : -1;
    }
    if (fmt.count != 1)
        return -1;

    final switch (fmt.type) with (ValueType)
    {
        case bool_:
        {
            const(char)[] s = *cast(const(bool)*)record.ptr ? "true" : "false";
            if (buffer.length < s.length)
                return -1;
            buffer[0 .. s.length] = s[];
            return s.length;
        }

        case u8, u16, u32, u64:
            return formatValue(load_int(record.ptr, fmt.type), buffer, null, null);

        case s8, s16, s32, s64:
            return formatValue(long(load_int(record.ptr, fmt.type)), buffer, null, null);

        case f32, f64:
        {
            double v = fmt.type == f32 ? *cast(const(float)*)record.ptr : *cast(const(double)*)record.ptr;
            return formatValue(v / desc.pre_scale, buffer, null, null);
        }

        case char_, user:
            return -1;
    }
}

// swizzled text-field view; padding stripped, no allocation - the mount mints the String
const(char)[] sample_text(const(void)[] wire, ref const SampleDesc desc, char[] buf)
{
    size_t n = wire.length < buf.length ? wire.length : buf.length;
    wire_image(wire[0 .. n], desc.layout, buf[0 .. n]);
    const(char)[] s = buf[0 .. n];
    if (desc.layout.flags & WireFlags.space_padded)
    {
        while (s.length && (s[$-1] == ' ' || s[$-1] == '\0'))
            s = s[0 .. $-1];
    }
    else
    {
        size_t z = 0;
        while (z < s.length && s[z] != '\0')
            ++z;
        s = s[0 .. z];
    }
    return s;
}

// text -> fixed wire field; truncates to the field width and pads the remainder
bool emit_text(const(char)[] text, ref const SampleDesc desc, void[] wire)
{
    if (wire.length > 256)
        return false;
    ubyte[256] image = void;
    ubyte pad = desc.layout.flags & WireFlags.space_padded ? ' ' : 0;
    image[0 .. wire.length] = pad;
    size_t n = text.length < wire.length ? text.length : wire.length;
    image[0 .. n] = cast(const(ubyte)[])text[0 .. n];
    wire_image_encode(image[0 .. wire.length], desc.layout, wire);
    return true;
}


unittest
{
    import urt.meta.enuminfo : enum_info;
    import urt.si.unit : Volt;
    import urt.time : DateTime, get_date_time, Month, SysTime;
    import urt.typereg : TypeRecordFor, register_type_record, get_type_details;

    alias WK = WireKind;
    alias WF = WireFlags;

    // mint dedupe: same shape same index, different shape different index
    ushort fa = mint_format(DataFormat(ValueType.f64, Semantics.held, ScaledUnit(Volt)));
    ushort fb = mint_format(DataFormat(ValueType.f64, Semantics.held, ScaledUnit(Volt)));
    ushort fc = mint_format(DataFormat(ValueType.s16, Semantics.held));
    assert(fa == fb && fa != fc);
    assert(format_by_index(fa).unit == ScaledUnit(Volt));

    // scaled BE register -> f64 record (modbus shape)
    SampleDesc volts = SampleDesc(WireLayout(WK.signed_, 16, 0, WF.reverse), 0.1f, fa);
    ubyte[2] reg = [0x01, 0x00];  // 256 BE
    double d;
    assert(sample_record(reg, volts, (cast(void*)&d)[0 .. 8]));
    assert(d > 25.59 && d < 25.61);
    ubyte[2] back;
    assert(emit_record((cast(const(void)*)&d)[0 .. 8], volts, back));
    assert(back == reg);

    // bool@3 within a shared register; RMW preserves neighbours
    ushort fbool = mint_format(DataFormat(ValueType.bool_, Semantics.held));
    SampleDesc flag = SampleDesc(WireLayout(WK.bool_, 1, 3, WF.reverse, 2, 2), 1, fbool);
    ubyte[2] status = [0x9A, 0xBC];
    bool b;
    assert(sample_record(status, flag, (cast(void*)&b)[0 .. 1]));
    assert(b == ((0x9ABC >> 3) & 1));

    // enum register: names parse, numbers format
    enum Mode : ushort { off = 0, eco = 1, boost = 2 }
    ushort fmode = mint_format(DataFormat(ValueType.u16, Semantics.held, enum_info!Mode.make_void()));
    SampleDesc mode = SampleDesc(WireLayout(WK.unsigned_, 16, 0, WF.reverse), 1, fmode);
    ushort m;
    assert(parse_record("boost", mode, (cast(void*)&m)[0 .. 2]));
    assert(m == Mode.boost);
    assert(parse_record("1", mode, (cast(void*)&m)[0 .. 2]));
    assert(m == Mode.eco);
    char[16] txt;
    assert(format_record((cast(const(void)*)&m)[0 .. 2], mode, txt) == 1 && txt[0] == '1');

    // dt48 encoding: byte-image path, reading-order canonical
    if (!find_encoding("yymmddhhmmss"))
        register_builtin_encodings();
    const(Encoding)* dt48 = find_encoding("yymmddhhmmss");
    ubyte[6] dtw = [26, 7, 18, 13, 45, 30];  // wire yy MM dd hh mm ss
    SampleDesc when_be = SampleDesc(WireLayout(WK.char_, 8, 0, WF.none), 1,
                                    0xFFFF, encoding_index_of(*dt48));
    SysTime st;
    assert(sample_record(dtw, when_be, (cast(void*)&st)[0 .. SysTime.sizeof]));
    DateTime dt = get_date_time(st);
    assert(dt.year == 2026 && dt.month == Month.July && dt.day == 18 &&
           dt.hour == 13 && dt.minute == 45 && dt.second == 30);

    // pod user type, big-endian members: fused image->record flip
    static struct Pair { ushort a; ushort b; }
    ushort ti = register_type_record(TypeRecordFor!(Pair, 0xBEEF0001, 0, false, "pair"));
    ushort fpair = mint_format(DataFormat(ValueType.user, Semantics.held, &get_type_details(ti)));
    SampleDesc pair = SampleDesc(WireLayout(WK.char_, 8, 0, WF.members_be), 1, fpair);
    ubyte[4] pw = [0x01, 0x02, 0x03, 0x04];
    Pair p;
    assert(sample_record(pw, pair, (cast(void*)&p)[0 .. Pair.sizeof]));
    assert(p.a == 0x0102 && p.b == 0x0304);
    ubyte[4] pback;
    assert(emit_record((cast(const(void)*)&p)[0 .. Pair.sizeof], pair, pback));
    assert(pback == pw);

    // text fields: swizzled chars, padding stripped, no allocation
    ushort fstr = mint_format(DataFormat(ValueType.char_, Semantics.held));
    SampleDesc name = SampleDesc(WireLayout(WK.char_, 8, 0, WF.swap_word_bytes), 1, fstr);
    char[8] namebuf;
    immutable char[6] namewire = "EHLL!O";
    assert(sample_text(namewire, name, namebuf) == "HELLO!");
}


private:

import urt.array : Array;

__gshared Array!(DataFormat*) g_formats;
__gshared Array!SampleDesc g_descs;
__gshared Map!(String, const(VoidEnumInfo)*) g_enums;

// wire-member-endianness XOR host-endianness decides memcpy vs flip; static per build
bool member_flip(WireLayout l) pure
{
    version (LittleEndian)
        enum host_be = false;
    else
        enum host_be = true;
    return ((l.flags & WireFlags.members_be) != 0) != host_be;
}

bool format_equal(ref const DataFormat a, ref const DataFormat b) pure
{
    if (a.type != b.type || a.semantics != b.semantics || a.desc != b.desc ||
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

void store_int(void* p, ValueType t, ulong v) pure
{
    switch (g_atom_stride[t])
    {
        case 1: *cast(ubyte*)p = cast(ubyte)v; break;
        case 2: *cast(ushort*)p = cast(ushort)v; break;
        case 4: *cast(uint*)p = cast(uint)v; break;
        case 8: *cast(ulong*)p = v; break;
        default: assert(false);
    }
}

ulong load_int(const(void)* p, ValueType t) pure
{
    final switch (t) with (ValueType)
    {
        case u8:  return *cast(const(ubyte)*)p;
        case s8:  return cast(ulong)long(*cast(const(byte)*)p);
        case u16: return *cast(const(ushort)*)p;
        case s16: return cast(ulong)long(*cast(const(short)*)p);
        case u32: return *cast(const(uint)*)p;
        case s32: return cast(ulong)long(*cast(const(int)*)p);
        case u64: return *cast(const(ulong)*)p;
        case s64: return *cast(const(ulong)*)p;
        case bool_, f32, f64, char_, user:
            assert(false);
    }
}
