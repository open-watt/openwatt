module manager.sampler;

import urt.conv : parse_int_fast;
import urt.endian;
import urt.meta;
import urt.si.unit;
import urt.string;
import urt.util : max, byte_reverse;
import urt.variant;

import manager.element;
import manager.subscriber;

nothrow @nogc:


class Sampler : Subscriber
{
nothrow @nogc:

    void update()
    {
    }

    abstract void remove_element(Element* element);
}


// data sampling helper
// we have a data descriptor and some sampling functions

template data_type(const(char)[] str)
{
    private enum DataType value = parse_data_type(str);
    static assert(value != DataType.invalid, "invalid data type: " ~ str);
    alias data_type = value;
}

enum data_type(ushort flags, DataKind kind, ushort length = 0) = make_data_type(flags, kind, length);

DataType make_data_type(uint flags, DataKind kind, ushort length = 0) pure
    => cast(DataType)(flags | (kind << 12) | (length << 16));

enum DataType : uint
{
    bytes = 0x7,
    signed = 0x8,
    word_reverse = 0x10,
    little_endian = 0x20,
    big_endian = 0x40,
    enumeration = 0x80,
    array = 0x100,
    kind = 0xF000,
    length = 0xFFFF0000,

    // common types
    u8 = 0,
    i8 = 0 | signed,
    u16 = 1,
    i16 = 1 | signed,
    u32 = 3,
    i32 = 3 | signed,
    u64 = 7,
    i64 = 7 | signed,

    custom = 0xFFFE,
    invalid = 0xFFFFFFFF
}

enum DataKind : ubyte
{
    // integer types first
    integer = 0,
    bitfield = 1,
    date_time = 2,
    // special-cases after
    floating = 3,
    low_byte = 4,
    high_byte = 5,
    string_z = 6,
    string_sp = 7,
}

enum DateFormat : ubyte
{
    yymmddhhmmss,
}

ubyte data_bytes(DataType type) pure
    => (type & 7) + 1;

DataKind data_kind(DataType type) pure
    => cast(DataKind)((type >> 12) & 0xF);

ushort data_length(DataType type) pure
    => cast(ushort)(type.data_bytes * max(type.data_count, ushort(1)));

ushort data_count(DataType type) pure
    => cast(ushort)(type >> 16);

alias CustomSample = Variant function(const void[] data, ushort user_data) nothrow @nogc;

struct ValueDesc
{
nothrow @nogc:
    this(DataType type) pure
    {
        _type = type;
        if (type & DataType.enumeration)
            _enum_info = null;
    }

    this(DataType type, ScaledUnit unit, float pre_scale = 1) pure
    {
        assert(!(type & DataType.enumeration), "can't scale enumeration types");
        _type = type;
        _unit = unit;
        _pre_scale = pre_scale;
    }

    this(DataType type, DateFormat date_format) pure
    {
        assert(type.data_kind == DataKind.date_time, "dates require date_time");
        _type = type;
        _enum_info = null; // HACK: clear the high bits
        _date_format = date_format;
    }

    this(DataType type, const VoidEnumInfo* enum_info) pure
    {
        assert(type & DataType.enumeration, "enum_info requires enumeration data type");
        _type = type;
        _enum_info = enum_info;
    }

    this(CustomSample custom_sample, ushort user_data) pure
    {
        _type = cast(DataType)(DataType.custom | (user_data << 16));
        _custom_sample = custom_sample;
    }

    bool parse_units(const(char)[] units) pure
    {
        if (_type & DataType.enumeration)
        {
            if (units is null)
            {
                _enum_info = null;
                return true;
            }
            // TODO: if the enum registry were global (or supplied?), we could look it up here...
            //...???
            return false;
        }

        if (units is null)
        {
            _unit = ScaledUnit();
            _pre_scale = 1;
            return true;
        }

        ptrdiff_t taken = _unit.parseUnit(units, _pre_scale);
        if (taken != units.length)
            return false;
        return true;
    }

    DataType data_type() const pure
        => _type;

    ushort data_length() const pure
        => _type.data_length;

    bool is_enum() const pure
        => (_type & DataType.enumeration) != 0;

    bool is_custom() const pure
        => (_type & 0xFFFF) == 0xFFFE;

    const(VoidEnumInfo)* enum_info() const pure
        => is_enum() ? _enum_info : null;

private:
    DataType _type;
    union {
        struct {
            ScaledUnit _unit;
            float _pre_scale = 1;
        }
        DateFormat _date_format;
        const(VoidEnumInfo)* _enum_info; // these padd the struct; booo!
        CustomSample _custom_sample;
    }
}

Variant sample_value(const void* data, ref const ValueDesc desc)
{
    const bptr = cast(byte*)data;
    const ubptr = cast(ubyte*)data;
    const sptr = cast(short*)data;
    const usptr = cast(ushort*)data;
    const iptr = cast(int*)data;
    const uiptr = cast(uint*)data;
    const ulptr = cast(ulong*)data;

    version (LittleEndian)
        bool load_little_endian = (desc._type & DataType.big_endian) == 0;
    else
        bool load_little_endian = (desc._type & DataType.little_endian) != 0;

    ulong raw_value = void;
    double f_value = void;
    DataKind kind = desc._type.data_kind;
    final switch (kind) with (DataKind)
    {
        case integer, bitfield, date_time:
            if (load_little_endian)
            {
                final switch (desc._type & 0x1F)
                {
                    // unsigned
                    case 0x0, 0x10: raw_value = ubptr[0]; break;
                    case 0x1, 0x11: raw_value = loadLittleEndian(usptr); break;
                    case 0x2: raw_value = loadLittleEndian(usptr) | (ubptr[2] << 16); break;
                    case 0x3: raw_value = loadLittleEndian(uiptr); break;
                    case 0x4: raw_value = loadLittleEndian(uiptr) | (ulong(ubptr[4]) << 32); break;
                    case 0x5: raw_value = loadLittleEndian(uiptr) | (ulong(loadLittleEndian(usptr + 2)) << 32); break;
                    case 0x6: raw_value = loadLittleEndian(uiptr) | (ulong(loadLittleEndian(usptr + 2)) << 32) | (ulong(ubptr[6]) << 48); break;
                    // signed
                    case 0x8, 0x18: raw_value = long(bptr[0]); break;
                    case 0x9, 0x19: raw_value = long(loadLittleEndian(sptr)); break;
                    case 0xA: raw_value = loadLittleEndian(usptr) | (long(bptr[2]) << 16); break;
                    case 0xB: raw_value = long(loadLittleEndian(iptr)); break;
                    case 0xC: raw_value = loadLittleEndian(uiptr) | (long(bptr[4]) << 32); break;
                    case 0xD: raw_value = loadLittleEndian(uiptr) | (long(loadLittleEndian(sptr + 2)) << 32); break;
                    case 0xE: raw_value = loadLittleEndian(uiptr) | (ulong(loadLittleEndian(usptr + 2)) << 32) | (long(bptr[6]) << 48); break;
                    case 0x7, 0xF: raw_value = loadLittleEndian(ulptr); break;
                    // unsigned word-reverse
                    case 0x13: raw_value = (ulong(loadLittleEndian(usptr)) << 16) | loadLittleEndian(usptr + 1); goto check_float;
                    case 0x15: raw_value = (ulong(loadLittleEndian(usptr)) << 32) | (ulong(loadLittleEndian(usptr + 1)) << 16) | loadLittleEndian(usptr + 2); break;
                    // signed word-reverse
                    case 0x1B: raw_value = long(loadLittleEndian(sptr) << 16) | loadLittleEndian(usptr + 1); goto check_float;
                    case 0x1D: raw_value = (long(loadLittleEndian(sptr)) << 32) | (ulong(loadLittleEndian(usptr + 1)) << 16) | loadLittleEndian(usptr + 2); break;
                    case 0x17, 0x1F: raw_value = (ulong(loadLittleEndian(usptr)) << 48) | (ulong(loadLittleEndian(usptr + 1)) << 32) | (ulong(loadLittleEndian(usptr + 2)) << 16) | loadLittleEndian(usptr + 3); goto check_double;
                    case 0x12, 0x14, 0x16, 0x1A, 0x1C, 0x1E: assert(false, "not a word multiple");
                }
            }
            else
            {
                final switch (desc._type & 0x1F)
                {
                    // unsigned
                    case 0x0, 0x10: raw_value = ubptr[0]; break;
                    case 0x1, 0x11: raw_value = loadBigEndian(usptr); break;
                    case 0x2: raw_value = (loadBigEndian(usptr) << 8) | ubptr[2]; break;
                    case 0x3: raw_value = loadBigEndian(uiptr); break;
                    case 0x4: raw_value = (ulong(loadBigEndian(uiptr)) << 8) | ubptr[4]; break;
                    case 0x5: raw_value = (ulong(loadBigEndian(uiptr)) << 16) | loadBigEndian(usptr + 2); break;
                    case 0x6: raw_value = (ulong(loadBigEndian(uiptr)) << 24) | (loadBigEndian(usptr + 2) << 8) | ubptr[6]; break;
                    // signed
                    case 0x8, 0x18: raw_value = long(bptr[0]); break;
                    case 0x9, 0x19: raw_value = long(loadBigEndian(sptr)); break;
                    case 0xA: raw_value = long(loadBigEndian(sptr) << 8) | ubptr[2]; break;
                    case 0xB: raw_value = long(loadBigEndian(iptr)); break;
                    case 0xC: raw_value = (long(loadBigEndian(iptr)) << 8) | ubptr[4]; break;
                    case 0xD: raw_value = (long(loadBigEndian(iptr)) << 16) | loadBigEndian(usptr + 2); break;
                    case 0xE: raw_value = (long(loadBigEndian(iptr)) << 24) | (loadBigEndian(usptr + 2) << 8) | ubptr[6]; break;
                    case 0x7, 0xF: raw_value = loadBigEndian(ulptr); break;
                    // unsigned word-reverse
                    case 0x13: raw_value = loadBigEndian(usptr) | (ulong(loadBigEndian(usptr + 1)) << 16); goto check_float;
                    case 0x15: raw_value = loadBigEndian(usptr) | (ulong(loadBigEndian(usptr + 1)) << 16) | (ulong(loadBigEndian(usptr + 2)) << 32); break;
                    // signed word-reverse
                    case 0x1B: raw_value = loadBigEndian(usptr) | long(loadBigEndian(sptr + 1) << 16); goto check_float;
                    case 0x1D: raw_value = loadBigEndian(usptr) | (ulong(loadBigEndian(usptr + 1)) << 16) | (long(loadBigEndian(sptr + 2)) << 32); break;
                    case 0x17, 0x1F: raw_value = loadBigEndian(usptr) | (ulong(loadBigEndian(usptr + 1)) << 16) | (ulong(loadBigEndian(usptr + 2)) << 32) | (ulong(loadBigEndian(usptr + 3)) << 48); goto check_double;
                    case 0x12, 0x14, 0x16, 0x1A, 0x1C, 0x1E: assert(false, "not a word multiple");
                }
            }
            break;

        check_float:
            if (kind == floating)
            {
                uint i = cast(uint)raw_value;
                f_value = *cast(float*)&i * desc._pre_scale;
            }
            break;

        check_double:
            if (kind == floating)
                f_value = *cast(double*)&raw_value * desc._pre_scale;
            break;

        case floating:
            if ((desc._type & 0x7) == 3)
            {
                if (desc._type & DataType.word_reverse)
                    goto case integer;
                if (LittleEndian == load_little_endian)
                    f_value = *cast(float*)data * desc._pre_scale;
                else
                {
                    uint i = byte_reverse(*cast(uint*)data);
                    f_value = *cast(float*)&i * desc._pre_scale;
                }
                break;
            }
            else if ((desc._type & 0x7) == 7)
            {
                if (desc._type & DataType.word_reverse)
                    goto case integer;
                if (LittleEndian == load_little_endian)
                    f_value = *cast(double*)data * desc._pre_scale;
                else
                {
                    ulong i = byte_reverse(*cast(ulong*)data);
                    f_value = *cast(double*)&i * desc._pre_scale;
                }
                break;
            }
            else
            {
                assert((desc._type & 0x7) != 1, "TODO: half-float");
                assert(false, "invalid floating point size");
            }
            break;

        case low_byte, high_byte:
            assert((desc._type & 7) == 1, "high/low_byte requires word data");
            ubyte index = (kind == low_byte) ^ load_little_endian;
            raw_value = (desc._type & DataType.signed) ? long(bptr[index]) : ubptr[index];
            break;

        case string_z, string_sp:
            const(char)[] str_buffer = (cast(char*)data)[0 .. desc._type.data_length];

            size_t len = str_buffer.strlen_s();
            if (kind == string_sp)
            {
                // space-padded string
                while (len > 0 && ubptr[len - 1] == ' ')
                    --len;
            }
            return Variant(str_buffer[0..len]);
    }

    assert((desc._type & DataType.array) == 0, "TODO: we don't know how to support array data yet");

    if (desc._type & DataType.enumeration)
    {
        if (kind == DataKind.floating)
            raw_value = cast(ulong)f_value;

        // TODO: we want to associate the enum with the variant somehow?

        return Variant(raw_value);
    }

    Variant r;
    final switch (kind) with (DataKind)
    {
        case integer, low_byte, high_byte:
            if (desc._pre_scale != 1)
            {
                // if we have a pre-scale, we'll convert to floating point
                // TODO: if the pre-scale is an integer, we could keep it integral...
                f_value = (desc._type & DataType.signed) ? long(raw_value) * desc._pre_scale : raw_value * desc._pre_scale;
                goto case floating;
            }
            else if (desc._type & DataType.signed)
                r = Variant(long(raw_value));
            else
                r = Variant(raw_value);
            break;
        case floating:
            r = Variant(f_value);
            break;

        case date_time:
            import urt.time;
            DateTime dt;
            switch (desc._date_format) with (DateFormat)
            {
                case yymmddhhmmss:
                    dt.year = 2000 + cast(ushort)((raw_value >> 40) & 0xFF);
                    dt.month = cast(Month)((raw_value >> 32) & 0xFF);
                    dt.day = cast(ushort)((raw_value >> 24) & 0xFF);
                    dt.hour = cast(ushort)((raw_value >> 16) & 0xFF);
                    dt.minute = cast(ushort)((raw_value >> 8) & 0xFF);
                    dt.second = cast(ushort)(raw_value & 0xFF);
                    dt.ns = 0;
                    break;

                default:
                    assert(false, "unknown date_time format");
            }
            return Variant(dt);

        case bitfield:
        case string_z:
        case string_sp:
            assert(false, "should have been captured by an earlier case");
    }
    r.set_unit(desc._unit);
    return r;
}

ptrdiff_t write_value(const void[] data, ref const Variant value, ref const ValueDesc desc)
{
    assert(false, "TODO");
}


DataType parse_data_type(const(char)[] desc) pure
{
    if (desc.length < 2)
        return DataType.invalid;

    ubyte flags;
    DataKind kind = DataKind.integer;
    if (desc[0] == 'u' || desc[0] == 'i')
    {
        flags = desc[0] == 'i' ? DataType.signed : 0;
        desc = desc[1 .. $];
    }
    else if (desc[0] == 'f')
    {
        kind = DataKind.floating;
        desc = desc[1 .. $];
    }
    else if (desc[0 .. 2] == "bf")
    {
        flags |= DataType.enumeration;
        kind = DataKind.bitfield;
        desc = desc[2 .. $];
    }
    else if (desc[0 .. 2] == "dt")
    {
        kind = DataKind.date_time;
        desc = desc[2 .. $];
    }
    else if (desc.length > 4 && desc[0 .. 4] == "enum")
    {
        flags |= DataType.enumeration;
        desc = desc[4 .. $];
        if (desc[0] == 'f')
        {
            kind = DataKind.floating;
            desc = desc[1 .. $];
        }
    }
    else if (desc.length >= 3 && desc[0 .. 3] == "str")
    {
        desc = desc[3 .. $];
        bool success;
        int len = desc.parse_int_fast(success);
        if (!success || len <= 0)
            return DataType.invalid;
        if (desc.length >= 3 && desc[0 .. 3] == "_sp")
        {
            kind = DataKind.string_sp;
            desc = desc[3 .. $];
        }
        else
            kind = DataKind.string_z;
        if (desc.length > 0)
            return DataType.invalid;
        return cast(DataType)(DataType.array | (kind << 12) | len << 16);
    }
    else
        return DataType.invalid;

    bool success;
    int width = desc.parse_int_fast(success);
    if (!success || (width & 7))
        return DataType.invalid;
    uint bytes = (width / 8) - 1;
    if (bytes > 7)
        return DataType.invalid;

    if (desc.length >= 2)
    {
        if (desc[0..2] == "le")
        {
            flags |= DataType.little_endian;
            desc = desc[2 .. $];
        }
        else if (desc[0 .. 2] == "be")
        {
            flags |= DataType.big_endian;
            desc = desc[2 .. $];
        }
        if (desc.length >= 3)
        {
            if (desc[0 .. 3] == "_le")
            {
                if ((flags & (DataType.little_endian | DataType.big_endian)) == 0)
                    return DataType.invalid;
                if (flags & DataType.big_endian)
                    flags |= DataType.word_reverse;
                desc = desc[3 .. $];
            }
            else if (desc[0 .. 3] == "_be")
            {
                if ((flags & (DataType.little_endian | DataType.big_endian)) == 0)
                    return DataType.invalid;
                if (flags & DataType.little_endian)
                    flags |= DataType.word_reverse;
                desc = desc[3 .. $];
            }
        }
    }

    if (desc.length > 0)
        return DataType.invalid;
    return cast(DataType)(bytes | flags | (kind << 12));
}


unittest
{
    ubyte[16] buffer = [ 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F ];

    // test all the endian permutations...
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u8le")) == 0x80);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u8be")) == 0x80);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i8le")) == -0x80);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i8be")) == -0x80);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u16le")) == 0x8180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u16be")) == 0x8081);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i16le")) == long(0xFFFFFFFFFFFF8180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i16be")) == long(0xFFFFFFFFFFFF8081));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u24le")) == 0x828180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u24be")) == 0x808182);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i24le")) == long(0xFFFFFFFFFF828180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i24be")) == long(0xFFFFFFFFFF808182));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u32le")) == 0x83828180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u32be")) == 0x80818283);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i32le")) == long(0xFFFFFFFF83828180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i32be")) == long(0xFFFFFFFF80818283));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u40le")) == 0x8483828180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u40be")) == 0x8081828384);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i40le")) == long(0xFFFFFF8483828180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i40be")) == long(0xFFFFFF8081828384));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u48le")) == 0x858483828180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u48be")) == 0x808182838485);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i48le")) == long(0xFFFF858483828180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i48be")) == long(0xFFFF808182838485));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u56le")) == 0x86858483828180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u56be")) == 0x80818283848586);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i56le")) == long(0xFF86858483828180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i56be")) == long(0xFF80818283848586));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u64le")) == 0x8786858483828180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u64be")) == 0x8081828384858687);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i64le")) == long(0x8786858483828180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i64be")) == long(0x8081828384858687));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u16le_be")) == 0x8180);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u16be_le")) == 0x8081);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i16le_be")) == long(0xFFFFFFFFFFFF8180));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i16be_le")) == long(0xFFFFFFFFFFFF8081));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u32le_be")) == 0x81808382);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u32be_le")) == 0x82838081);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i32le_be")) == long(0xFFFFFFFF81808382));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i32be_le")) == long(0xFFFFFFFF82838081));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u48le_be")) == 0x818083828584);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u48be_le")) == 0x848582838081);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i48le_be")) == long(0xFFFF818083828584));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i48be_le")) == long(0xFFFF848582838081));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u64le_be")) == 0x8180838285848786);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"u64be_le")) == 0x8687848582838081);
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i64le_be")) == long(0x8180838285848786));
    assert(sample_value(buffer.ptr, ValueDesc(data_type!"i64be_le")) == long(0x8687848582838081));
}
