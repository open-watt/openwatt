module urt.endian;

import urt.traits;

nothrow @nogc:


T bigEndianToNative(T)(ref const ubyte[1] bytes)
    if (is(T == ubyte) || is(T == byte) || is(T == bool))
        => (cast(T*)bytes.ptr)[0];
T littleEndianToNative(T)(ref const ubyte[1] bytes)
    if (is(T == ubyte) || is(T == byte) || is(T == bool))
        => (cast(T*)bytes.ptr)[0];
T bigEndianToNative(T)(ref const ubyte[2] bytes)
    if (is(T == ushort) || is(T == short))
{
    return bytes[0] << 8 | bytes[1];
}
T littleEndianToNative(T)(ref const ubyte[2] bytes)
    if (is(T == ushort) || is(T == short))
{
    return bytes[0] | bytes[1] << 8;
}
T bigEndianToNative(T)(ref const ubyte[4] bytes)
    if (is(T == uint) || is(T == int) || is(T == float))
{
    uint i = bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3];
    static if (is(T == float))
        return *cast(float*)&i;
    else
        return i;
}
T littleEndianToNative(T)(ref const ubyte[4] bytes)
    if (is(T == uint) || is(T == int) || is(T == float))
{
    uint i = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24;
    static if (is(T == float))
        return *cast(float*)&i;
    else
        return i;
}
ulong bigEndianToNative(T)(ref const ubyte[8] bytes)
    if (is(T == ulong))
{
    ulong i = cast(ulong)bytes[0] << 56 | cast(ulong)bytes[1] << 48 | cast(ulong)bytes[2] << 48 | cast(ulong)bytes[3] << 32 | bytes[4] << 24 | bytes[5] << 16 | bytes[6] << 8 | bytes[7];
    static if (is(T == double))
        return *cast(double*)&i;
    else
        return i;
}
ulong littleEndianToNative(T)(ref const ubyte[8] bytes)
    if (is(T == ulong))
{
    ulong i = bytes[0] | cast(ulong)bytes[1] << 8 | cast(ulong)bytes[2] << 16 | cast(ulong)bytes[3] << 24 | cast(ulong)bytes[4] << 32 | cast(ulong)bytes[5] << 40 | cast(ulong)bytes[6] << 48 | cast(ulong)bytes[7] << 56;
    static if (is(T == double))
        return *cast(double*)&i;
    else
        return i;
}
auto bigEndianToNative(T)(ref const ubyte[T.sizeof] bytes)
    if (isEnum!T)
        => cast(T)bigEndianToNative!(enumType!T)(bytes);
auto littleEndianToNative(T)(ref const ubyte[T.sizeof] bytes)
    if (isEnum!T)
        => cast(T)littleEndianToNative!(enumType!T)(bytes);


ubyte[1] nativeToBigEndian(bool b) => (cast(ubyte*)&b)[0..1];
ubyte[1] nativeToLittleEndian(bool b) => (cast(ubyte*)&b)[0..1];
ubyte[1] nativeToBigEndian(ubyte u8) => (&u8)[0..1];
ubyte[1] nativeToLittleEndian(ubyte u8) => (&u8)[0..1];
ubyte[2] nativeToBigEndian(ushort u16)
{
    ubyte[2] res = [ u16 >> 8, u16 & 0xFF ];
    return res;
}
ubyte[2] nativeToLittleEndian(ushort u16)
{
    ubyte[2] res = [ u16 & 0xFF, u16 >> 8 ];
    return res;
}
ubyte[4] nativeToBigEndian(uint u32)
{
    ubyte[4] res = [ u32 >> 24, (u32 >> 16) & 0xFF, (u32 >> 8) & 0xFF, u32 & 0xFF ];
    return res;
}
ubyte[4] nativeToLittleEndian(uint u32)
{
    ubyte[4] res = [ u32 & 0xFF, (u32 >> 8) & 0xFF, (u32 >> 16) & 0xFF, u32 >> 24 ];
    return res;
}
ubyte[4] nativeToBigEndian(float f32)
{
    uint u32 = *cast(uint*)&f32;
    ubyte[4] res = [ u32 >> 24, (u32 >> 16) & 0xFF, (u32 >> 8) & 0xFF, u32 & 0xFF ];
    return res;
}
ubyte[4] nativeToLittleEndian(float f32)
{
    uint u32 = *cast(uint*)&f32;
    ubyte[4] res = [ u32 & 0xFF, (u32 >> 8) & 0xFF, (u32 >> 16) & 0xFF, u32 >> 24 ];
    return res;
}


void storeBigEndian(T)(T* target, T val)
    if (isSomeInt!T || is(T == float))
{
    (cast(ubyte*)target)[0..T.sizeof] = nativeToBigEndian(val);
}
void storeLittleEndian(T)(T* target, T val)
    if (isSomeInt!T || is(T == float))
{
    (cast(ubyte*)target)[0..T.sizeof] = nativeToLittle(val);
}
T loadBigEndian(T)(const(T)* src)
    if (isSomeInt!T || is(T == float))
{
    return bigEndianToNative!T((cast(ubyte*)src)[0..T.sizeof]);
}
T loadLittleEndian(T)(const(T)* src)
    if (isSomeInt!T || is(T == float))
{
    return littleEndianToNative!T((cast(ubyte*)src)[0..T.sizeof]);
}
