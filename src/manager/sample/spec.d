module manager.sample.spec;

// The value-spec grammar compiler: profile type spellings -> compiled SampleDesc.
//
//   <family><width>[_mods][@bit][:name][[N]]
//
// Separator semantics: `_` introduces closed layout-mod vocabulary (context-gated), `:` an
// open registry-name reference (enum/bitfield declarations, encodings), `@` a bit position
// within the context word, [N] a count. Bare registered type names sit in type position.
// Element access is outside this grammar: profiles carry optional R/W/RW in the following
// column, with omitted access meaning read.
//
// Contexts gate the mods: worded contexts (word_bytes > 1) offer _bs (byte-swap within
// word) and _wr (word order swapped); byte-stream contexts offer _le/_be (value
// endianness); _sp (space padding) wherever text appears; _be on a bare registered name
// means members-stored-big-endian.
//
// Legacy spellings parse as aliases until the conf sweep: i* = s*, glued or underscored
// le/be = ABSOLUTE value endianness (overrides context), _r = byte-swap-within-word on
// strings and word-swap on scalars, matching the old parse_data_type semantics.
// Bare `str` is protocol-framed dynamic text (zero wire span); fixed binary maps use strN.

import urt.meta.enuminfo : VoidEnumInfo;
import urt.si.unit : ScaledUnit;
import urt.typereg : find_type_by_name, TypeDetails;

import manager.sample.codec;
import manager.sample;
import manager.series;
import manager.sample.wire;

nothrow @nogc:


struct LayoutContext
{
nothrow @nogc:

    ubyte word_bytes = 1;        // 1 = byte stream
    bool word_be;                // worded: bytes within each word are BE (modbus: true)
    bool words_hi_first = true;  // worded: high word first
    bool stream_be;              // byte stream: values are BE

    bool worded() const pure => word_bytes > 1;
}

enum LayoutContext modbus_context = LayoutContext(2, true, true, false);
enum LayoutContext stream_le_context = LayoutContext(1, false, true, false);
enum LayoutContext stream_be_context = LayoutContext(1, false, true, true);

alias EnumResolver = const(VoidEnumInfo)* delegate(const(char)[] name) nothrow @nogc;

// compile one spelling against a context; unit/pre_scale/enum_info are the profile's
// separate fields (a `:name` in the spec overrides enum_info via the resolver)
bool compile_spec(const(char)[] spec, ref const LayoutContext ctx, ScaledUnit unit, float pre_scale,
                  const(VoidEnumInfo)* enum_info, scope EnumResolver resolve_enum, out SampleDesc desc)
{
    // [N] count suffix
    uint count = 1;
    if (spec.length && spec[$-1] == ']')
    {
        size_t open = spec.length;
        while (open > 0 && spec[open-1] != '[')
            --open;
        if (open == 0)
            return false;
        count = parse_uint(spec[open .. $-1]);
        if (count == 0 || count > 255)
            return false;
        spec = spec[0 .. open-1];
    }

    // :name reference
    const(char)[] name;
    foreach (i, c; spec)
    {
        if (c == ':')
        {
            name = spec[i+1 .. $];
            spec = spec[0 .. i];
            break;
        }
    }

    // @bit position
    uint bit_offset = 0;
    bool sliced = false;
    foreach (i, c; spec)
    {
        if (c == '@')
        {
            bit_offset = parse_uint(spec[i+1 .. $]);
            if (bit_offset >= 64)
                return false;
            spec = spec[0 .. i];
            sliced = true;
            break;
        }
    }

    // A registered name is an atom even when it contains digits (`ipv4`). Otherwise
    // split a built-in family into its letters and width digits.
    size_t atom_len = spec.length;
    foreach (i, c; spec)
    {
        if (c == '_')
        {
            atom_len = i;
            break;
        }
    }
    const(TypeDetails)* named_type = find_type_by_name(spec[0 .. atom_len]);
    const(char)[] family;
    size_t dl;
    uint width;
    if (named_type)
    {
        family = spec[0 .. atom_len];
        dl = atom_len;
    }
    else
    {
        size_t fl = 0;
        while (fl < spec.length && (spec[fl] < '0' || spec[fl] > '9') && spec[fl] != '_')
            ++fl;
        family = spec[0 .. fl];
        dl = fl;
        while (dl < spec.length && spec[dl] >= '0' && spec[dl] <= '9')
            ++dl;
        width = fl < dl ? parse_uint(spec[fl .. dl]) : 0;
    }
    const(char)[] tail = spec[dl .. $];

    // mods: glued le/be first (legacy), then underscore tokens
    bool abs_endian = false, abs_be = false;
    bool mod_bs = false, mod_wr = false, mod_sp = false, mod_be = false, legacy_r = false;
    if (tail.length >= 2 && (tail[0 .. 2] == "le" || tail[0 .. 2] == "be"))
    {
        abs_endian = true;
        abs_be = tail[0] == 'b';
        tail = tail[2 .. $];
    }
    while (tail.length)
    {
        if (tail[0] != '_')
            return false;
        tail = tail[1 .. $];
        size_t ml = 0;
        while (ml < tail.length && tail[ml] != '_')
            ++ml;
        const(char)[] mod = tail[0 .. ml];
        tail = tail[ml .. $];
        switch (mod)
        {
            case "le": abs_endian = true; abs_be = false; break;
            case "be":
                // on a bare registered name this is member endianness, not transport
                if (family.length && width == 0 && find_type_by_name(family))
                    mod_be = true;
                else
                {
                    abs_endian = true;
                    abs_be = true;
                }
                break;
            case "bs":
                if (!ctx.worded)
                    return false;
                mod_bs = true;
                break;
            case "wr":
                if (!ctx.worded)
                    return false;
                mod_wr = true;
                break;
            case "r":  legacy_r = true; break;
            case "sp": mod_sp = true; break;
            default:   return false;
        }
    }

    // resolved swizzle flags. Scalars have value endianness (context base includes it,
    // explicit le/be is absolute); byte-image families (str/dt/user) have only word
    // structure - reading order is canonical, so the context's BE-ness never applies.
    // Legacy _r is family-dependent: word-swap on scalars, byte-swap-in-word on strings.
    WireFlags scalar_flags()
    {
        uint f;
        if (abs_endian)
            f = (abs_be ? WireFlags.reverse : 0) | (legacy_r ? WireFlags.swap_words : 0);
        else
        {
            if (ctx.worded)
                f = (ctx.word_be ? WireFlags.reverse : 0)
                  | ((ctx.word_be != ctx.words_hi_first) ? WireFlags.swap_words : 0);
            else
                f = ctx.stream_be ? WireFlags.reverse : 0;
            if (mod_bs)
                f ^= WireFlags.swap_word_bytes;
            if (mod_wr)
                f ^= WireFlags.swap_words;
            if (legacy_r)
                f ^= WireFlags.swap_words;
        }
        return cast(WireFlags)f;
    }
    WireFlags image_flags()
    {
        uint f = ctx.worded && !ctx.words_hi_first ? WireFlags.swap_words : 0;
        if (mod_bs || legacy_r)
            f ^= WireFlags.swap_word_bytes;
        if (mod_wr)
            f ^= WireFlags.swap_words;
        if (mod_sp)
            f |= WireFlags.space_padded;
        if (mod_be)
            f |= WireFlags.members_be;
        return cast(WireFlags)f;
    }
    uint wb = ctx.worded ? ctx.word_bytes : 2;
    uint container = sliced ? (ctx.worded ? ctx.word_bytes : 0) : 0;

    const(VoidEnumInfo)* ei = enum_info;

    switch (family)
    {
        case "bool":
        {
            uint w = sliced ? 1 : (ctx.worded ? ctx.word_bytes * 8 : 8);
            desc = SampleDesc(WireLayout(WireKind.bool_, w, bit_offset, scalar_flags(), wb, container), pre_scale, mint_format(DataFormat(ValueType.bool_, Semantics.held)));
            return true;
        }

        case "u", "s", "i": // deprecate 's' or 'i'
        {
            if (width < 1 || width > 64)
                return false;
            if (name.length && unit.parseUnit(name, pre_scale) != name.length)
                return false;
            bool signed_ = family[0] != 'u';
            ValueType at = pre_scale != 1 ? ValueType.f64 : int_atom(width, signed_);
            DataFormat fmt = ei ? DataFormat(at, Semantics.held, ei) : DataFormat(at, Semantics.held, unit);
            fmt.count = cast(ubyte)count;
            desc = SampleDesc(WireLayout(signed_ ? WireKind.signed_ : WireKind.unsigned_, width, bit_offset, scalar_flags(), wb, container), pre_scale, mint_format(fmt));
            return true;
        }

        case "f":
        {
            if (width != 32 && width != 64)
                return false; // TODO: half-float
            if (name.length && unit.parseUnit(name, pre_scale) != name.length)
                return false;
            ValueType at = (width == 32 && pre_scale == 1) ? ValueType.f32 : ValueType.f64;
            DataFormat fmt = DataFormat(at, Semantics.held, unit);
            fmt.count = cast(ubyte)count;
            desc = SampleDesc(WireLayout(WireKind.float_, width, 0, scalar_flags(), wb), pre_scale, mint_format(fmt));
            return true;
        }

        case "enum", "bf", "enumf":
        {
            if (name.length)
            {
                if (!resolve_enum)
                    return false;
                ei = resolve_enum(name);
                if (!ei)
                    return false;
            }
            if (width < 1 || width > 64)
                return false;
            ValueType at = int_atom(width, false);
            DataFormat fmt = ei ? DataFormat(at, Semantics.held, ei) : DataFormat(at, Semantics.held);
            desc = SampleDesc(WireLayout(family == "enumf" ? WireKind.float_ : WireKind.unsigned_, width, bit_offset, scalar_flags(), wb, container), pre_scale, mint_format(fmt));
            return true;
        }

        case "str":
        {
            DataFormat fmt = DataFormat(ValueType.char_, Semantics.held);
            fmt.count = 0; // dynamic: the record is a TextRecord; wire span is the field width
            // width is per-char; the field's byte span comes from the register map
            desc = SampleDesc(WireLayout(WireKind.char_, 8, 0, image_flags(), wb), pre_scale, mint_format(fmt));
            return true;
        }

        case "dt":
        {
            if (!width && !name.length)
            {
                const(TypeDetails)* td = find_type_by_name("dt");
                if (!td)
                    return false;
                DataFormat fmt = DataFormat(ValueType.user, Semantics.held, td);
                desc = SampleDesc(WireLayout(WireKind.char_, 8, 0, image_flags(), wb), pre_scale, mint_format(fmt));
                return true;
            }
            const(Encoding)* enc = name.length ? find_encoding(name) : null;
            if (!enc || !width || enc.wire_bytes * 8 != width)
                return false;
            DataFormat shape = DataFormat(enc.format.type, enc.format.semantics, enc.format.user_type);
            desc = SampleDesc(WireLayout(WireKind.char_, 8, 0, image_flags(), wb), pre_scale, mint_format(shape), encoding_index_of(*enc));
            return true;
        }

        default:
        {
            // bare registered type name
            const(TypeDetails)* td = named_type ? named_type : find_type_by_name(family);
            if (!td || width)
                return false;
            DataFormat fmt = DataFormat(ValueType.user, Semantics.held, td);
            fmt.count = cast(ubyte)count;
            desc = SampleDesc(WireLayout(WireKind.char_, 8, 0, image_flags(), wb), pre_scale, mint_format(fmt));
            return true;
        }
    }
}


unittest
{
    import urt.meta.enuminfo : enum_info;
    import urt.typereg : get_type_details, register_type_record, TypeRecordFor;

    alias WF = WireFlags;

    assert(!find_encoding("yymmddhhmmss"));
    register_builtin_encodings();
    scope(exit) clear_encoding_registry();

    static uint fl(ref const SampleDesc d) pure
        => d.layout.flags;

    SampleDesc d;

    // modbus context: type-first, deviation-only, quartet resolution
    assert(compile_spec("u16", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.layout.kind == WireKind.unsigned_ && d.layout.bit_width == 16 && fl(d) == WF.reverse);
    assert(compile_spec("s32", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.layout.kind == WireKind.signed_ && fl(d) == WF.reverse);
    assert(compile_spec("u32_wr", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == (WF.reverse | WF.swap_words));
    assert(compile_spec("u32_bs", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == (WF.reverse | WF.swap_word_bytes));
    assert(compile_spec("u32_bs_wr", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == (WF.reverse | WF.swap_words | WF.swap_word_bytes));

    // byte-exact Modbus quartet: every layout decodes the same value and re-emits unchanged
    static void round_trip(const(char)[] spelling, ubyte[4] wire)
    {
        SampleDesc sd;
        assert(compile_spec(spelling, modbus_context, ScaledUnit(), 1, null, null, sd));
        uint record;
        assert(sample_record(wire, sd, (cast(void*)&record)[0 .. uint.sizeof]));
        assert(record == 0x12345678);
        ubyte[4] emitted;
        assert(emit_record((cast(const(void)*)&record)[0 .. uint.sizeof], sd, emitted));
        assert(emitted == wire);
    }
    round_trip("u32",       [0x12, 0x34, 0x56, 0x78]);
    round_trip("u32_wr",    [0x56, 0x78, 0x12, 0x34]);
    round_trip("u32_bs",    [0x34, 0x12, 0x78, 0x56]);
    round_trip("u32_bs_wr", [0x78, 0x56, 0x34, 0x12]);

    // legacy high/low-byte register aliases translate to these slices in the protocol hook
    assert(compile_spec("u8@8", modbus_context, ScaledUnit(), 1, null, null, d));
    ubyte high;
    ubyte[2] word = [0xAB, 0xCD];
    assert(sample_record(word, d, (cast(void*)&high)[0 .. 1]) && high == 0xAB);
    assert(compile_spec("u8@0", modbus_context, ScaledUnit(), 1, null, null, d));
    ubyte low;
    assert(sample_record(word, d, (cast(void*)&low)[0 .. 1]) && low == 0xCD);

    // byte-stream context: value endianness only; worded mods illegal
    assert(compile_spec("u32", stream_le_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == 0);
    assert(compile_spec("u32_be", stream_le_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == WF.reverse);
    assert(!compile_spec("u32_bs", stream_le_context, ScaledUnit(), 1, null, null, d));

    // big-endian byte-stream protocols carry their default in the context
    assert(compile_spec("u32", stream_be_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == WF.reverse);
    assert(compile_spec("u32_le", stream_be_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == 0);

    // legacy aliases: i* = s*, glued le/be absolute, _r word-swap
    assert(compile_spec("i16be", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.layout.kind == WireKind.signed_ && fl(d) == WF.reverse);
    assert(compile_spec("u32le", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == 0);
    assert(compile_spec("u32le_r", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == WF.swap_words);
    assert(compile_spec("u32be_r", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == (WF.reverse | WF.swap_words));

    // record shaping: scaled ints record f64, unscaled keep their width
    assert(compile_spec("s16", modbus_context, ScaledUnit(), 0.1f, null, null, d));
    assert(d.fmt.type == ValueType.f64 && d.pre_scale == 0.1f);
    assert(compile_spec("u24", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.fmt.type == ValueType.u32);

    // slices: width from the type, container from the context word
    assert(compile_spec("bool@3", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.layout.kind == WireKind.bool_ && d.layout.bit_width == 1 && d.layout.bit_offset == 3
        && d.layout.container_bytes == 2);
    assert(compile_spec("u3@5", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.layout.bit_width == 3 && d.layout.bit_offset == 5 && d.layout.container_bytes == 2);

    // enum via resolver; bf shares the path
    enum Mode : ushort { off = 0, eco = 1 }
    const(VoidEnumInfo)* mi = enum_info!Mode.make_void();
    const(VoidEnumInfo)* resolver(const(char)[] n) nothrow @nogc
        => n == "mode" ? mi : null;
    assert(compile_spec("enum16:mode", modbus_context, ScaledUnit(), 1, null, &resolver, d));
    assert(d.fmt.desc == DataFormat.Desc.enum_ && d.fmt.enum_info is mi);
    assert(!compile_spec("enum16:nope", modbus_context, ScaledUnit(), 1, null, &resolver, d));

    // dt48 encoding: family + width validated against the entry
    assert(compile_spec("dt48:yymmddhhmmss", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.enc !is null && d.fmt.type == ValueType.user);
    assert(!compile_spec("dt32:yymmddhhmmss", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(compile_spec("dt", stream_le_context, ScaledUnit(), 1, null, null, d));
    assert(d.enc is null && d.fmt.type == ValueType.user && d.fmt.user_type.name == "dt");

    // strings: dynamic char records, reading-order canonical (no value endianness);
    // _r aliases _bs on byte data; _sp pads with spaces
    assert(compile_spec("str8_r_sp", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.fmt.type == ValueType.char_ && d.fmt.count == 0
        && fl(d) == (WF.swap_word_bytes | WF.space_padded));
    assert(compile_spec("str8_bs", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == WF.swap_word_bytes);
    char[8] textbuf = void;
    ubyte[8] swapped_text = ['B', 'A', 'D', 'C', 'F', 'E', 0, 'G'];
    assert(sample_text(swapped_text, d, textbuf) == "ABCDEFG");
    ubyte[8] emitted_text;
    assert(emit_text("ABCDEFG", d, emitted_text));
    assert(emitted_text == swapped_text);
    assert(compile_spec("str", stream_le_context, ScaledUnit(), 1, null, null, d));
    assert(d.fmt.is_text);

    // bare registered type; _be marks member endianness
    static struct Pt { ushort x; ushort y; }
    register_type_record(TypeRecordFor!(Pt, 0xBEEF0002, 0, false, "pt"));
    assert(compile_spec("pt", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.fmt.type == ValueType.user && d.fmt.user_type.name == "pt");
    assert(compile_spec("pt_be", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(fl(d) == WF.members_be);
    assert(compile_spec("ipv4", stream_le_context, ScaledUnit(), 1, null, null, d));
    assert(d.fmt.type == ValueType.user && d.fmt.user_type.name == "ipv4");

    // counts
    assert(compile_spec("u8[8]", modbus_context, ScaledUnit(), 1, null, null, d));
    assert(d.fmt.count == 8 && d.fmt.type == ValueType.u8);

    // unit in the reference position: scalar families resolve `:` in the unit namespace
    {
        assert(compile_spec("u16:0.1V", modbus_context, ScaledUnit(), 1, null, null, d));
        ScaledUnit su;
        float ps = 1;
        su.parseUnit("0.1V", ps);
        assert(d.fmt.unit == su && d.pre_scale == ps);
        assert(compile_spec("f32:W", modbus_context, ScaledUnit(), 1, null, null, d));
        assert(d.fmt.type == ValueType.f32);
        assert(!compile_spec("u16:nonsense", modbus_context, ScaledUnit(), 1, null, null, d));
    }
}


private:

uint parse_uint(const(char)[] s) pure
{
    if (!s.length)
        return 0;
    uint v = 0;
    foreach (c; s)
    {
        uint d = c - '0';
        if (d > 9)
            return 0;
        v = v*10 + d;
    }
    return v;
}

ValueType int_atom(uint bits, bool signed_) pure
{
    if (bits <= 8)
        return signed_ ? ValueType.s8 : ValueType.u8;
    if (bits <= 16)
        return signed_ ? ValueType.s16 : ValueType.u16;
    if (bits <= 32)
        return signed_ ? ValueType.s32 : ValueType.u32;
    return signed_ ? ValueType.s64 : ValueType.u64;
}
