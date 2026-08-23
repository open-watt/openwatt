module tools.protobuf;

import urt.array;
import urt.conv;
import urt.string;
import urt.traits;


mixin template LoadProtobuf(string name)
{
    static foreach (i; 0 .. spec.enums.length)
        mixin(generate_enum(spec.enums[i]));

    static foreach (i; 0 .. spec.messages.length)
        mixin(generate_message(spec.messages[i], spec.syntax));

private:
    import tools.protobuf.parse;
    import urt.array;
    import urt.string;

    enum text = import(name);
    enum ProtoSpec spec = parse_proto(text, null);
}


enum WireType : ubyte
{
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    fixed32 = 5,
    zigzag = 8
}

struct FieldInfo
{
    uint id;
    ubyte wire;
    ushort ty;
}

enum uint max_field_id = 536_870_911;

struct ProtoOptional(T)
{
    bool present;
    T value;

    ref T ensure() return
    {
        present = true;
        return value;
    }

    static if (!is(T == struct))
    {
        void set(T value)
        {
            present = true;
            this.value = value;
        }
    }

    void clear()
    {
        present = false;
        value = T.init;
    }
}

size_t buffer_len(T)(ref const T msg) pure nothrow @nogc
{
    static assert(is(typeof(T.syntax)), "T must be a protobuf message struct");
    enum pack = T.syntax == 3;

    size_t len = 0;
    static foreach (i; 0 .. msg.tupleof.length)
    {{
        enum info = __traits(getAttributes, msg.tupleof[i])[0];
        alias Field = typeof(msg.tupleof[i]);
        enum tag = (ulong(info.id) << 3) | (info.wire & 7);
        static if (is(Field == ProtoOptional!U, U))
        {
            if (msg.tupleof[i].present)
                len += varint_len(tag) + encode_len!(pack, info.wire)(msg.tupleof[i].value);
        }
        else
            len += varint_len(tag) + encode_len!(pack, info.wire)(msg.tupleof[i]);
    }}
    return len;
}

size_t proto_serialise(T)(ubyte[] buffer, ref const T msg) pure nothrow @nogc
{
    static assert(is(typeof(msg.syntax)), "T must be a protobuf message struct");
    enum pack = T.syntax == 3;

    size_t offset = 0;
    static foreach (i; 0 .. msg.tupleof.length)
    {{
        enum info = __traits(getAttributes, msg.tupleof[i])[0];
        ulong tag = (ulong(info.id) << 3) | (info.wire & 7);
        alias Field = typeof(msg.tupleof[i]);
        static if (is(Field == ProtoOptional!U, U))
        {
            if (msg.tupleof[i].present)
            {
                offset += put_varint(buffer[offset .. $], tag);
                offset += buffer[offset .. $].encode_value!(pack, info.wire)(msg.tupleof[i].value);
            }
        }
        else
        {
            offset += put_varint(buffer[offset .. $], tag);
            offset += buffer[offset .. $].encode_value!(pack, info.wire)(msg.tupleof[i]);
        }
    }}
    return offset;
}

ptrdiff_t proto_deserialise(T)(const(ubyte)[] buffer, out T msg) nothrow @nogc
{
    static assert(is(typeof(msg.syntax)), "T must be a protobuf message struct");
    enum pack = T.syntax == 3;

    size_t offset = 0;
    while (offset < buffer.length)
    {
        ulong tag;
        offset += buffer[offset..$].get_varint(tag);
        ulong field_id = tag >> 3;
        if (field_id == 0 || field_id > max_field_id)
            return -1;
        member: switch (cast(uint)field_id)
        {
            static foreach (i; 0 .. msg.tupleof.length)
            {{
                enum info = __traits(getAttributes, msg.tupleof[i])[0];
                case info.id:
                    if ((info.wire & 7) != (tag & 7))
                        goto default; // wire type mismatch, skip this field
                    alias Field = typeof(msg.tupleof[i]);
                    static if (is(Field == ProtoOptional!U, U))
                    {
                        msg.tupleof[i].present = true;
                        ptrdiff_t taken = decode_value!(pack, info.wire)(buffer[offset..$], msg.tupleof[i].value);
                    }
                    else
                        ptrdiff_t taken = decode_value!(pack, info.wire)(buffer[offset..$], msg.tupleof[i]);
                    if (taken < 0)
                        return -1;
                    offset += taken;
                    break member;
            }}
            default:
                switch (tag & 7)
                {
                    case WireType.varint:
                        while (buffer[offset++] >= 0x80) {}
                        break;
                    case WireType.fixed64:
                        offset += 8;
                        break;
                    case WireType.length_delimited:
                        ulong len;
                        offset += buffer[offset..$].get_varint(len) + len;
                        break;
                    case WireType.fixed32:
                        offset += 4;
                        break;
                    default:
                        return -1;
                }
                break;
        }
    }
    return offset;
}

size_t encode_len(bool pack, ubyte ty, T)(auto ref const T value) pure nothrow @nogc
{
    static if (is(T == Array!ubyte))
    {
        size_t len = value.length;
        return varint_len(len) + len;
    }
    else static if (is(T == Array!U, U))
    {
        static if (pack)
        {
            assert(false);
        }
        else
        {
            assert(false);
        }
    }
    else static if (is_boolean!T)
        return 1;
    else static if (is_some_int!T || is_enum!T)
    {
        static if (is_enum!T)
            alias I = EnumType!T;
        else
            alias I = T;
        static if (is(I == uint))
        {
            static if (ty == WireType.fixed32)
                return 4;
            else
                return varint_len(value);
        }
        else static if (is(I == int))
        {
            static if (ty == WireType.zigzag)
                return varint_len((value << 1) ^ (value >> 31));
            else static if (ty == WireType.fixed32)
                return 4;
            else
                return varint_len(value);
        }
        else static if (is(I == ulong))
        {
            static if (ty == WireType.fixed64)
                return 8;
            else
                return varint_len(value);
        }
        else static if (is(I == long))
        {
            static if (ty == WireType.zigzag)
                return varint_len((value << 1) ^ (value >> 63));
            else static if (ty == WireType.fixed64)
                return 8;
            else
                return varint_len(value);
        }
        else
            static assert(false, "Unsupported integer type");
    }
    else static if (is(T == float))
        return 4;
    else static if (is(T == double))
        return 8;
    else static if (is(T == String))
    {
        size_t len = value.length;
        return varint_len(len) + len;
    }
    else static if (is(T == struct))
    {
        size_t len = buffer_len(value);
        return varint_len(len) + len;
    }
    else
        static assert(false, "Unsupported type");
}

size_t encode_value(bool pack, ubyte ty, T)(ubyte[] buffer, auto ref const T value) pure nothrow @nogc
{
    import urt.endian;
    static if (is(T == Array!ubyte))
    {
        size_t len = value.length;
        size_t offset = buffer.put_varint(len);
        buffer[offset .. offset + len] = value[];
        return offset + len;
    }
    else static if (is(T == Array!U, U))
    {
        static if (pack)
        {
            assert(false);
        }
        else
        {
            assert(false);
        }
    }
    else static if (is_boolean!T)
    {
        buffer[0] = value ? 1 : 0;
        return 1;
    }
    else static if (is_some_int!T || is_enum!T)
    {
        static if (is_enum!T)
            alias I = EnumType!T;
        else
            alias I = T;
        static if (is(I == uint))
        {
            static if (ty == WireType.fixed32)
            {
                buffer[0..4] = value.nativeToLittleEndian;
                return 4;
            }
            else
                return put_varint(buffer, value);
        }
        else static if (is(I == int))
        {
            static if (ty == WireType.zigzag)
                return put_varint(buffer, (value << 1) ^ (value >> 31));
            else static if (ty == WireType.fixed32)
            {
                buffer[0..4] = value.nativeToLittleEndian;
                return 4;
            }
            else
                return put_varint(buffer, value);
        }
        else static if (is(I == ulong))
        {
            static if (ty == WireType.fixed64)
            {
                buffer[0..8] = value.nativeToLittleEndian;
                return 8;
            }
            else
                return put_varint(buffer, value);
        }
        else static if (is(I == long))
        {
            static if (ty == WireType.zigzag)
                return put_varint(buffer, (value << 1) ^ (value >> 63));
            else static if (ty == WireType.fixed64)
            {
                buffer[0..8] = value.nativeToLittleEndian;
                return 8;
            }
            else
                return put_varint(buffer, value);
        }
        else
            static assert(false, "Unsupported integer type");
    }
    else static if (is(T == float))
    {
        buffer[0..4] = value.nativeToLittleEndian;
        return 4;
    }
    else static if (is(T == double))
    {
        buffer[0..8] = value.nativeToLittleEndian;
        return 8;
    }
    else static if (is(T == String))
    {
        size_t len = value.length;
        size_t offset = buffer.put_varint(len);
        buffer[offset .. offset + len] = cast(ubyte[])value[];
        return offset + len;
    }
    else static if (is(T == struct))
    {
        size_t len = buffer_len(value);
        size_t offset = buffer.put_varint(len);
        size_t written = proto_serialise(buffer[offset .. $], value);
        debug assert(written == len);
        return offset + written;
    }
    else
        static assert(false, "Unsupported type");
}

ptrdiff_t decode_value(bool pack, ubyte ty, T)(const(ubyte)[] buffer, ref T value) nothrow @nogc
{
    import urt.endian;
    static if ((ty & 7) == WireType.varint || ty == WireType.length_delimited)
    {
        ulong val;
        size_t offset = get_varint(buffer, val);
        static if (ty == WireType.length_delimited)
        {
            const(ubyte)[] block = buffer[offset .. offset + cast(size_t)val];
            offset += val;
        }
    }
    else static if (is(T == float))
    {
        value = buffer[0..4].littleEndianToNative!float;
        size_t offset = 4;
    }
    else static if (is(T == double))
    {
        value = buffer[0..8].littleEndianToNative!double;
        size_t offset = 8;
    }
    else static if (ty == WireType.fixed32)
    {
        uint val = buffer[0..4].littleEndianToNative!uint;
        size_t offset = 4;
    }
    else static if (ty == WireType.fixed64)
    {
        ulong val = buffer[0..8].littleEndianToNative!ulong;
        size_t offset = 8;
    }

    static if (is(T == Array!ubyte))
    {
        value.clear();
        value.extend(block.length)[] = block[];
    }
    else static if (is(T == Array!U, U))
    {
        static if (pack)
        {
            assert(false);
        }
        else
        {
            assert(false);
        }
    }
    else static if (is_boolean!T)
        value = val != 0;
    else static if (is_some_int!T || is_enum!T)
    {
        static if (is_enum!T)
            alias I = EnumType!T;
        else
            alias I = T;
        static if (is(I == uint))
            value = cast(T)val;
        else static if (is(I == int))
        {
            static if (ty == WireType.zigzag)
                value = cast(T)(cast(int)(val >> 1) ^ -int(val & 1));
            else
                value = cast(T)cast(long)val;
        }
        else static if (is(I == ulong))
            value = cast(T)val;
        else static if (is(I == long))
        {
            static if (ty == WireType.zigzag)
                value = cast(T)(long(val >> 1) ^ -long(val & 1));
            else
                value = cast(T)cast(long)val;
        }
        else
            static assert(false, "Unsupported integer type");
    }
    else static if (is(T == String))
    {
        import urt.mem;
        value = (cast(char[])block).make_string();
    }
    else static if (is(T == struct))
    {
        size_t sub_len = block.proto_deserialise(value);
        debug assert(sub_len == val);
    }
    else static if (!is(T == float) && !is(T == double))
        static assert(false, "Unsupported type: " ~ T.stringof);
    return offset;
}

size_t varint_len(ulong value) pure nothrow @nogc
{
    size_t len = 1;
    while (value >>= 7)
        ++len;
    return len;
}

size_t put_varint(ubyte[] buffer, ulong value) pure nothrow @nogc
{
    size_t len = 0;
    while (true)
    {
        if (value < 0x80)
        {
            buffer[len++] = cast(ubyte)value;
            break;
        }
        buffer[len++] = 0x80 | (value & 0x7F);
        value >>= 7;
    }
    return len;
}

size_t get_varint(const(ubyte)[] buffer, out ulong i) pure nothrow @nogc
{
    i = buffer[0];
    if ((i & 0x80) == 0)
        return 1;
    i &= 0x7F;
    size_t offset = 1;
    uint shift = 7;
    while (true)
    {
        i |= ulong(buffer[offset] & 0x7F) << shift;
        if ((buffer[offset++] & 0x80) == 0)
            return offset;
        shift += 7;
    }
}

version (unittest)
{
    private struct LargeTagMessage
    {
        enum syntax = 3;
        @FieldInfo(16, WireType.varint, 0) uint value;
    }

    private struct MaxTagMessage
    {
        enum syntax = 3;
        @FieldInfo(max_field_id, WireType.varint, 0) uint value;
    }

    private struct OptionalIntMessage
    {
        enum syntax = 3;
        @FieldInfo(2, WireType.varint, 0) ProtoOptional!int value;
    }

    private struct OptionalBytesMessage
    {
        enum syntax = 3;
        @FieldInfo(3, WireType.length_delimited, 0) ProtoOptional!(Array!ubyte) value;
    }

    private struct NestedMessage
    {
        enum syntax = 3;
        this(this) @disable;
        @FieldInfo(1, WireType.varint, 0) uint value;
    }

    private struct OptionalMessage
    {
        enum syntax = 3;
        @FieldInfo(4, WireType.length_delimited, 0) ProtoOptional!NestedMessage value;
    }

    private struct BytesMessage
    {
        enum syntax = 3;
        @FieldInfo(1, WireType.length_delimited, 0) Array!ubyte value;
    }

    private struct Int64Message
    {
        enum syntax = 3;
        @FieldInfo(1, WireType.varint, 0) long value;
    }

    private struct SFixed64Message
    {
        enum syntax = 3;
        @FieldInfo(1, WireType.fixed64, 0) long value;
    }
}

unittest
{
    LargeTagMessage large_tag;
    large_tag.value = 150;
    ubyte[4] large_tag_wire;
    assert(buffer_len(large_tag) == large_tag_wire.length);
    assert(proto_serialise(large_tag_wire[], large_tag) == large_tag_wire.length);
    ubyte[4] expected_large_tag_wire = [0x80, 0x01, 0x96, 0x01];
    assert(large_tag_wire == expected_large_tag_wire);

    MaxTagMessage max_tag;
    max_tag.value = 1;
    ubyte[6] max_tag_wire;
    assert(buffer_len(max_tag) == max_tag_wire.length);
    assert(proto_serialise(max_tag_wire[], max_tag) == max_tag_wire.length);
    ubyte[6] expected_max_tag_wire = [0xF8, 0xFF, 0xFF, 0xFF, 0x0F, 0x01];
    assert(max_tag_wire == expected_max_tag_wire);

    ubyte[2] zero_tag_wire = [0x00, 0x01];
    LargeTagMessage invalid_tag;
    assert(proto_deserialise(zero_tag_wire[], invalid_tag) == -1);
    ubyte[6] oversized_tag_wire = [0x80, 0x80, 0x80, 0x80, 0x10, 0x01];
    assert(proto_deserialise(oversized_tag_wire[], invalid_tag) == -1);

    OptionalIntMessage optional;
    ubyte[2] optional_wire;
    assert(buffer_len(optional) == 0);
    assert(proto_serialise(optional_wire[], optional) == 0);
    optional.value.set(0);
    assert(buffer_len(optional) == optional_wire.length);
    assert(proto_serialise(optional_wire[], optional) == optional_wire.length);
    ubyte[2] expected_optional_wire = [0x10, 0x00];
    assert(optional_wire == expected_optional_wire);

    OptionalIntMessage decoded_optional;
    assert(proto_deserialise(optional_wire[], decoded_optional) == optional_wire.length);
    assert(decoded_optional.value.present);
    assert(decoded_optional.value.value == 0);
    decoded_optional.value.clear();
    assert(!decoded_optional.value.present);
    assert(decoded_optional.value.value == 0);

    OptionalBytesMessage optional_bytes;
    ubyte[2] optional_bytes_value = [0xAA, 0xBB];
    optional_bytes.value.ensure().extend(2)[] = optional_bytes_value[];
    ubyte[4] optional_bytes_wire;
    assert(buffer_len(optional_bytes) == optional_bytes_wire.length);
    assert(proto_serialise(optional_bytes_wire[], optional_bytes) == optional_bytes_wire.length);
    ubyte[4] expected_optional_bytes_wire = [0x1A, 0x02, 0xAA, 0xBB];
    assert(optional_bytes_wire == expected_optional_bytes_wire);
    OptionalBytesMessage decoded_optional_bytes;
    assert(proto_deserialise(optional_bytes_wire[], decoded_optional_bytes) == optional_bytes_wire.length);
    assert(decoded_optional_bytes.value.present);
    assert(decoded_optional_bytes.value.value[] == optional_bytes_value[]);

    OptionalMessage optional_message;
    optional_message.value.ensure().value = 7;
    ubyte[4] optional_message_wire;
    assert(buffer_len(optional_message) == optional_message_wire.length);
    assert(proto_serialise(optional_message_wire[], optional_message) == optional_message_wire.length);
    ubyte[4] expected_optional_message_wire = [0x22, 0x02, 0x08, 0x07];
    assert(optional_message_wire == expected_optional_message_wire);
    OptionalMessage decoded_optional_message;
    assert(proto_deserialise(optional_message_wire[], decoded_optional_message) == optional_message_wire.length);
    assert(decoded_optional_message.value.present);
    assert(decoded_optional_message.value.value.value == 7);
    decoded_optional_message.value.clear();
    assert(!decoded_optional_message.value.present);
    assert(decoded_optional_message.value.value.value == 0);

    ubyte[8] bytes_wire = [0x0A, 0x03, 0x01, 0x02, 0x03, 0x0A, 0x01, 0x09];
    BytesMessage decoded_bytes;
    assert(proto_deserialise(bytes_wire[], decoded_bytes) == bytes_wire.length);
    ubyte[1] expected_bytes = [0x09];
    assert(decoded_bytes.value[] == expected_bytes[]);

    Int64Message int64_message;
    int64_message.value = -2;
    ubyte[11] int64_wire;
    assert(buffer_len(int64_message) == int64_wire.length);
    assert(proto_serialise(int64_wire[], int64_message) == int64_wire.length);
    ubyte[11] expected_int64_wire = [
        0x08, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x01
    ];
    assert(int64_wire == expected_int64_wire);
    Int64Message decoded_int64;
    assert(proto_deserialise(int64_wire[], decoded_int64) == int64_wire.length);
    assert(decoded_int64.value == -2);

    SFixed64Message sfixed64_message;
    sfixed64_message.value = -2;
    ubyte[9] sfixed64_wire;
    assert(buffer_len(sfixed64_message) == sfixed64_wire.length);
    assert(proto_serialise(sfixed64_wire[], sfixed64_message) == sfixed64_wire.length);
    ubyte[9] expected_sfixed64_wire = [
        0x09, 0xFE, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF
    ];
    assert(sfixed64_wire == expected_sfixed64_wire);
    SFixed64Message decoded_sfixed64;
    assert(proto_deserialise(sfixed64_wire[], decoded_sfixed64) == sfixed64_wire.length);
    assert(decoded_sfixed64.value == -2);
}
