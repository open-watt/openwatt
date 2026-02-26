module protocol.esphome.protobuf;

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
    import protocol.esphome.protobuf.parse;
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


size_t buffer_len(T)(ref const T msg) pure nothrow @nogc
{
    static assert(is(typeof(T.syntax)) && is(typeof(T.id)), "T must be a protobuf message struct");
    enum pack = T.syntax == 3;

    size_t len = 0;
    static foreach (i; 0 .. msg.tupleof.length)
    {{
        enum info = __traits(getAttributes, msg.tupleof[i])[0];
        // TODO: there are options to pack or not pack per item... (i think?)
        len += 1 + encode_len!(pack, info.wire)(msg.tupleof[i]);
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
        offset += put_varint(buffer[offset .. $], tag);
        offset += buffer[offset .. $].encode_value!(pack, info.wire)(msg.tupleof[i]);
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
        member: switch (cast(uint)(tag >> 3))
        {
            static foreach (i; 0 .. msg.tupleof.length)
            {{
                enum info = __traits(getAttributes, msg.tupleof[i])[0];
                case info.id:
                    if ((info.wire & 7) != (tag & 7))
                        goto default; // wire type mismatch, skip this field
                    ptrdiff_t taken = decode_value!(pack, info.wire)(buffer[offset..$], msg.tupleof[i]);
                    if (taken < 0)
                        return -1; // error
                    offset += taken;
                    break member;
            }}
            default:
                // unknown field in the bitstream, skip it...
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
                        return -1; // error: unknown wire type
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
                return 4;
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
        debug assert(proto_serialise(buffer[offset .. $], value) == len);
        return offset + len;
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
        value.extend(len)[] = block[];
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
            else static if (ty == WireType.fixed64)
                value = cast(T)cast(long)val;
        }
        else
            static assert(false, "Unsupported integer type");
    }
    else static if (is(T == String))
    {
        import urt.mem : defaultAllocator;
        value = (cast(char[])block).makeString(defaultAllocator);
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
