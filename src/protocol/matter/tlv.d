module protocol.matter.tlv;

import urt.endian;

nothrow @nogc:


enum TLVType : ubyte
{
    int8 = 0x00,
    int16 = 0x01,
    int32 = 0x02,
    int64 = 0x03,
    uint8 = 0x04,
    uint16 = 0x05,
    uint32 = 0x06,
    uint64 = 0x07,
    false_ = 0x08,
    true_ = 0x09,
    float32 = 0x0A,
    float64 = 0x0B,
    utf8_1 = 0x0C,
    utf8_2 = 0x0D,
    utf8_4 = 0x0E,
    utf8_8 = 0x0F,
    bytes_1 = 0x10,
    bytes_2 = 0x11,
    bytes_4 = 0x12,
    bytes_8 = 0x13,
    null_ = 0x14,
    structure = 0x15,
    array = 0x16,
    list = 0x17,
    end_of_container = 0x18,
}

enum TLVTagControl : ubyte
{
    anonymous = 0x00,
    context = 0x20,
    common_2 = 0x40,
    common_4 = 0x60,
    implicit_2 = 0x80,
    implicit_4 = 0xA0,
    fully_qualified_6 = 0xC0,
    fully_qualified_8 = 0xE0,
}

enum TLVTagKind : ubyte
{
    anonymous,
    context,
    common,
    implicit,
    fully_qualified,
}

struct TLVTag
{
    TLVTagKind kind;
    ushort vendor;
    ushort profile;
    uint number;

nothrow @nogc:
    static TLVTag anonymous() pure
        => TLVTag(TLVTagKind.anonymous);

    static TLVTag context(ubyte number) pure
        => TLVTag(TLVTagKind.context, 0, 0, number);

    static TLVTag common(uint number) pure
        => TLVTag(TLVTagKind.common, 0, 0, number);

    static TLVTag implicit(uint number) pure
        => TLVTag(TLVTagKind.implicit, 0, 0, number);

    static TLVTag fully_qualified(ushort vendor, ushort profile, uint number) pure
        => TLVTag(TLVTagKind.fully_qualified, vendor, profile, number);

    bool is_context(ubyte number) const pure
        => kind == TLVTagKind.context && this.number == number;

    bool opEquals(ref const TLVTag rh) const pure
        => kind == rh.kind && vendor == rh.vendor && profile == rh.profile && number == rh.number;
}

bool is_signed(TLVType type) pure
    => type <= TLVType.int64;

bool is_unsigned(TLVType type) pure
    => type >= TLVType.uint8 && type <= TLVType.uint64;

bool is_integer(TLVType type) pure
    => type <= TLVType.uint64;

bool is_bool(TLVType type) pure
    => type == TLVType.false_ || type == TLVType.true_;

bool is_float(TLVType type) pure
    => type == TLVType.float32 || type == TLVType.float64;

bool is_utf8(TLVType type) pure
    => type >= TLVType.utf8_1 && type <= TLVType.utf8_8;

bool is_bytes(TLVType type) pure
    => type >= TLVType.bytes_1 && type <= TLVType.bytes_8;

bool is_string(TLVType type) pure
    => type >= TLVType.utf8_1 && type <= TLVType.bytes_8;

bool is_container(TLVType type) pure
    => type >= TLVType.structure && type <= TLVType.list;


struct TLVReader
{
nothrow @nogc:
    this(const(void)[] data)
    {
        _data = cast(const(ubyte)[])data;
    }

    TLVType type() const pure
        => _type;

    ref const(TLVTag) tag() const pure
        => _tag;

    size_t depth() const pure
        => _depth;

    bool at_end() const pure
        => _offset >= _data.length;

    const(ubyte)[] remaining() const pure
        => _data[_offset .. $];

    bool next()
    {
        if (_offset >= _data.length)
            return false;

        ubyte control = _data[_offset];
        TLVType type = cast(TLVType)(control & 0x1F);
        if (type > TLVType.end_of_container)
            return false;

        size_t pos = _offset + 1;
        TLVTag tag;
        final switch (cast(TLVTagControl)(control & 0xE0))
        {
            case TLVTagControl.anonymous:
                break;
            case TLVTagControl.context:
                if (!read_uint(pos, 1, tag.number))
                    return false;
                tag.kind = TLVTagKind.context;
                break;
            case TLVTagControl.common_2:
            case TLVTagControl.common_4:
                if (!read_uint(pos, control & 0x20 ? 4 : 2, tag.number))
                    return false;
                tag.kind = TLVTagKind.common;
                break;
            case TLVTagControl.implicit_2:
            case TLVTagControl.implicit_4:
                if (!read_uint(pos, control & 0x20 ? 4 : 2, tag.number))
                    return false;
                tag.kind = TLVTagKind.implicit;
                break;
            case TLVTagControl.fully_qualified_6:
            case TLVTagControl.fully_qualified_8:
            {
                uint v, p;
                if (!read_uint(pos, 2, v) || !read_uint(pos, 2, p) || !read_uint(pos, control & 0x20 ? 4 : 2, tag.number))
                    return false;
                tag.kind = TLVTagKind.fully_qualified;
                tag.vendor = cast(ushort)v;
                tag.profile = cast(ushort)p;
                break;
            }
        }

        _payload = null;
        _uvalue = 0;
        switch (type) with (TLVType)
        {
            case int8, uint8:
                if (!read_uint(pos, 1, _uvalue))
                    return false;
                if (type == int8)
                    _ivalue = cast(byte)_uvalue;
                break;
            case int16, uint16:
                if (!read_uint(pos, 2, _uvalue))
                    return false;
                if (type == int16)
                    _ivalue = cast(short)_uvalue;
                break;
            case int32, uint32:
                if (!read_uint(pos, 4, _uvalue))
                    return false;
                if (type == int32)
                    _ivalue = cast(int)_uvalue;
                break;
            case int64, uint64:
                if (!read_uint(pos, 8, _uvalue))
                    return false;
                break;
            case float32:
            {
                if (!read_uint(pos, 4, _uvalue))
                    return false;
                uint bits = cast(uint)_uvalue;
                _fvalue = *cast(float*)&bits;
                break;
            }
            case float64:
            {
                ulong bits;
                if (!read_uint(pos, 8, bits))
                    return false;
                _fvalue = *cast(double*)&bits;
                break;
            }
            case utf8_1, bytes_1:
            case utf8_2, bytes_2:
            case utf8_4, bytes_4:
            case utf8_8, bytes_8:
            {
                ulong len;
                if (!read_uint(pos, 1 << ((type - utf8_1) & 3), len))
                    return false;
                if (len > _data.length - pos)
                    return false;
                _payload = _data[pos .. pos + cast(size_t)len];
                pos += cast(size_t)len;
                break;
            }
            case structure, array, list:
                ++_depth;
                break;
            case end_of_container:
                if (_depth == 0)
                    return false;
                --_depth;
                break;
            default:
                break;
        }

        _type = type;
        _tag = tag;
        _offset = pos;
        return true;
    }

    bool skip()
    {
        if (!is_container(_type))
            return true;
        size_t target = _depth - 1;
        while (next())
        {
            if (_depth == target)
                return true;
        }
        return false;
    }

    bool exit_container()
    {
        if (_depth == 0)
            return false;
        size_t target = _depth - 1;
        while (next())
        {
            if (_depth == target)
                return true;
        }
        return false;
    }

    bool as_bool() const pure
        => _type == TLVType.true_;

    long as_int() const pure
        => is_signed(_type) ? _ivalue : cast(long)_uvalue;

    ulong as_uint() const pure
        => is_unsigned(_type) ? _uvalue : cast(ulong)_ivalue;

    double as_float() const pure
    {
        if (is_float(_type))
            return _fvalue;
        if (is_signed(_type))
            return cast(double)_ivalue;
        return cast(double)_uvalue;
    }

    const(char)[] as_utf8() const pure
        => cast(const(char)[])_payload;

    const(ubyte)[] as_bytes() const pure
        => _payload;

    bool get(T)(out T value) const pure
    {
        static if (is(T == bool))
        {
            if (!is_bool(_type))
                return false;
            value = as_bool();
        }
        else static if (is(T : long) && __traits(isUnsigned, T))
        {
            if (!is_unsigned(_type) || _uvalue > T.max)
                return false;
            value = cast(T)_uvalue;
        }
        else static if (is(T : long))
        {
            if (is_signed(_type))
            {
                if (_ivalue < T.min || _ivalue > T.max)
                    return false;
                value = cast(T)_ivalue;
            }
            else if (is_unsigned(_type))
            {
                if (_uvalue > T.max)
                    return false;
                value = cast(T)_uvalue;
            }
            else
                return false;
        }
        else static if (is(T : double))
        {
            if (!is_float(_type))
                return false;
            value = cast(T)_fvalue;
        }
        else static if (is(T : const(char)[]))
        {
            if (!is_utf8(_type))
                return false;
            value = as_utf8();
        }
        else static if (is(T : const(ubyte)[]))
        {
            if (!is_bytes(_type))
                return false;
            value = _payload;
        }
        else
            static assert(false, "Unsupported TLV value type: " ~ T.stringof);
        return true;
    }

private:
    const(ubyte)[] _data;
    size_t _offset;
    size_t _depth;
    TLVType _type = TLVType.null_;
    TLVTag _tag;
    const(ubyte)[] _payload;
    union
    {
        ulong _uvalue;
        long _ivalue;
        double _fvalue;
    }

    bool read_uint(T)(ref size_t pos, size_t width, out T value)
    {
        if (width > _data.length - pos)
            return false;
        ulong r;
        foreach (i; 0 .. width)
            r |= cast(ulong)_data[pos + i] << (8*i);
        pos += width;
        value = cast(T)r;
        return true;
    }
}


struct TLVWriter
{
nothrow @nogc:
    this(void[] buffer)
    {
        _buffer = cast(ubyte[])buffer;
    }

    ubyte[] data() pure
        => _buffer[0 .. _offset];

    size_t length() const pure
        => _offset;

    size_t depth() const pure
        => _depth;

    bool overflow() const pure
        => _overflow;

    bool put_null(TLVTag tag = TLVTag.anonymous)
        => put_control(TLVType.null_, tag);

    bool put(TLVTag tag, bool value)
        => put_control(value ? TLVType.true_ : TLVType.false_, tag);

    bool put(TLVTag tag, ulong value)
    {
        if (value <= ubyte.max)
            return put_control(TLVType.uint8, tag) && put_raw(value, 1);
        if (value <= ushort.max)
            return put_control(TLVType.uint16, tag) && put_raw(value, 2);
        if (value <= uint.max)
            return put_control(TLVType.uint32, tag) && put_raw(value, 4);
        return put_control(TLVType.uint64, tag) && put_raw(value, 8);
    }

    bool put(TLVTag tag, uint value)
        => put(tag, cast(ulong)value);

    bool put(TLVTag tag, ushort value)
        => put(tag, cast(ulong)value);

    bool put(TLVTag tag, ubyte value)
        => put(tag, cast(ulong)value);

    bool put(TLVTag tag, long value)
    {
        if (value >= byte.min && value <= byte.max)
            return put_control(TLVType.int8, tag) && put_raw(cast(ulong)value, 1);
        if (value >= short.min && value <= short.max)
            return put_control(TLVType.int16, tag) && put_raw(cast(ulong)value, 2);
        if (value >= int.min && value <= int.max)
            return put_control(TLVType.int32, tag) && put_raw(cast(ulong)value, 4);
        return put_control(TLVType.int64, tag) && put_raw(cast(ulong)value, 8);
    }

    bool put(TLVTag tag, int value)
        => put(tag, cast(long)value);

    bool put(TLVTag tag, short value)
        => put(tag, cast(long)value);

    bool put(TLVTag tag, byte value)
        => put(tag, cast(long)value);

    bool put(TLVTag tag, float value)
        => put_control(TLVType.float32, tag) && put_raw(*cast(uint*)&value, 4);

    bool put(TLVTag tag, double value)
        => put_control(TLVType.float64, tag) && put_raw(*cast(ulong*)&value, 8);

    bool put(TLVTag tag, const(char)[] value)
        => put_string(TLVType.utf8_1, tag, cast(const(ubyte)[])value);

    bool put(TLVTag tag, const(ubyte)[] value)
        => put_string(TLVType.bytes_1, tag, value);

    bool start_structure(TLVTag tag = TLVTag.anonymous)
        => start_container(TLVType.structure, tag);

    bool start_array(TLVTag tag = TLVTag.anonymous)
        => start_container(TLVType.array, tag);

    bool start_list(TLVTag tag = TLVTag.anonymous)
        => start_container(TLVType.list, tag);

    bool end_container()
    {
        if (_depth == 0)
            return false;
        --_depth;
        return put_byte(TLVType.end_of_container);
    }

private:
    ubyte[] _buffer;
    size_t _offset;
    size_t _depth;
    bool _overflow;

    bool start_container(TLVType type, TLVTag tag)
    {
        if (!put_control(type, tag))
            return false;
        ++_depth;
        return true;
    }

    bool put_string(TLVType base, TLVTag tag, const(ubyte)[] value)
    {
        ubyte width_bits = value.length <= ubyte.max ? 0 : value.length <= ushort.max ? 1 : value.length <= uint.max ? 2 : 3;
        if (!put_control(cast(TLVType)(base + width_bits), tag) || !put_raw(value.length, 1 << width_bits))
            return false;
        if (value.length > _buffer.length - _offset)
        {
            _overflow = true;
            return false;
        }
        _buffer[_offset .. _offset + value.length] = value[];
        _offset += value.length;
        return true;
    }

    bool put_control(TLVType type, ref TLVTag tag)
    {
        final switch (tag.kind)
        {
            case TLVTagKind.anonymous:
                return put_byte(type);
            case TLVTagKind.context:
                return put_byte(type | TLVTagControl.context) && put_raw(tag.number, 1);
            case TLVTagKind.common:
                if (tag.number <= ushort.max)
                    return put_byte(type | TLVTagControl.common_2) && put_raw(tag.number, 2);
                return put_byte(type | TLVTagControl.common_4) && put_raw(tag.number, 4);
            case TLVTagKind.implicit:
                if (tag.number <= ushort.max)
                    return put_byte(type | TLVTagControl.implicit_2) && put_raw(tag.number, 2);
                return put_byte(type | TLVTagControl.implicit_4) && put_raw(tag.number, 4);
            case TLVTagKind.fully_qualified:
                bool wide = tag.number > ushort.max;
                return put_byte(type | (wide ? TLVTagControl.fully_qualified_8 : TLVTagControl.fully_qualified_6)) &&
                       put_raw(tag.vendor, 2) && put_raw(tag.profile, 2) && put_raw(tag.number, wide ? 4 : 2);
        }
    }

    bool put_byte(ubyte b)
    {
        if (_offset >= _buffer.length)
        {
            _overflow = true;
            return false;
        }
        _buffer[_offset++] = b;
        return true;
    }

    bool put_raw(ulong value, size_t width)
    {
        if (width > _buffer.length - _offset)
        {
            _overflow = true;
            return false;
        }
        foreach (i; 0 .. width)
            _buffer[_offset + i] = cast(ubyte)(value >> (8*i));
        _offset += width;
        return true;
    }
}


unittest
{
    // Matter spec appendix A worked examples
    ubyte[64] buf;

    TLVWriter w = TLVWriter(buf[]);
    assert(w.put(TLVTag.anonymous, 42u));
    assert(w.data == [0x04, 0x2A]);

    w = TLVWriter(buf[]);
    assert(w.put(TLVTag.anonymous, -17));
    assert(w.data == [0x00, 0xEF]);

    w = TLVWriter(buf[]);
    assert(w.put(TLVTag.anonymous, 40000u));
    assert(w.data == [0x05, 0x40, 0x9C]);

    w = TLVWriter(buf[]);
    assert(w.put(TLVTag.anonymous, "Hello!"));
    assert(w.data == [0x0C, 0x06, 'H', 'e', 'l', 'l', 'o', '!']);

    w = TLVWriter(buf[]);
    static immutable ubyte[5] octets = [0x00, 0x01, 0x02, 0x03, 0x04];
    assert(w.put(TLVTag.anonymous, octets[]));
    assert(w.data == [0x10, 0x05, 0x00, 0x01, 0x02, 0x03, 0x04]);

    w = TLVWriter(buf[]);
    assert(w.put(TLVTag.context(1), true));
    assert(w.data == [0x29, 0x01]);

    w = TLVWriter(buf[]);
    assert(w.put(TLVTag.fully_qualified(0xFFF1, 0xDEED, 1), 42u));
    assert(w.data == [0xC4, 0xF1, 0xFF, 0xED, 0xDE, 0x01, 0x00, 0x2A]);

    w = TLVWriter(buf[]);
    assert(w.put(TLVTag.fully_qualified(0xFFF1, 0xDEED, 0xAA55FEED), 42u));
    assert(w.data == [0xE4, 0xF1, 0xFF, 0xED, 0xDE, 0xED, 0xFE, 0x55, 0xAA, 0x2A]);

    w = TLVWriter(buf[]);
    assert(w.put(TLVTag.anonymous, 17.9f));
    assert(w.data == [0x0A, 0x33, 0x33, 0x8F, 0x41]);

    // nested containers round-trip
    w = TLVWriter(buf[]);
    assert(w.start_structure());
    assert(w.put(TLVTag.context(0), 42u));
    assert(w.put(TLVTag.context(1), -17));
    assert(w.start_array(TLVTag.context(2)));
    assert(w.put(TLVTag.anonymous, 1u));
    assert(w.put(TLVTag.anonymous, 2u));
    assert(w.end_container());
    assert(w.put(TLVTag.context(3), "abc"));
    assert(w.end_container());
    assert(w.depth == 0);
    assert(w.data == [0x15, 0x24, 0x00, 0x2A, 0x20, 0x01, 0xEF, 0x36, 0x02, 0x04, 0x01, 0x04, 0x02, 0x18, 0x2C, 0x03, 0x03, 'a', 'b', 'c', 0x18]);

    TLVReader r = TLVReader(w.data);
    assert(r.next() && r.type == TLVType.structure && r.depth == 1);
    assert(r.next() && r.tag.is_context(0) && r.as_uint == 42);
    ubyte u8;
    assert(r.get(u8) && u8 == 42);
    assert(r.next() && r.tag.is_context(1) && r.as_int == -17);
    int i32;
    assert(r.get(i32) && i32 == -17);
    assert(!r.get(u8));
    assert(r.next() && r.type == TLVType.array && r.tag.is_context(2) && r.depth == 2);
    assert(r.skip() && r.depth == 1);
    assert(r.next() && r.tag.is_context(3) && r.as_utf8 == "abc");
    assert(r.next() && r.type == TLVType.end_of_container && r.depth == 0);
    assert(!r.next());

    // exit_container from inside the array
    r = TLVReader(w.data);
    assert(r.next() && r.next() && r.next() && r.next() && r.next());
    assert(r.as_uint == 1);
    assert(r.exit_container() && r.depth == 1);
    assert(r.next() && r.as_utf8 == "abc");

    // truncated input and overflow are rejected
    static immutable ubyte[2] short_int = [0x05, 0x40];
    static immutable ubyte[4] short_str = [0x0C, 0x06, 0x48, 0x69];
    static immutable ubyte[1] stray_end = [0x18];
    r = TLVReader(short_int[]);
    assert(!r.next());
    r = TLVReader(short_str[]);
    assert(!r.next());
    r = TLVReader(stray_end[]);
    assert(!r.next());

    ubyte[3] small;
    w = TLVWriter(small[]);
    assert(!w.put(TLVTag.anonymous, "Hello!"));
    assert(w.overflow);
}
