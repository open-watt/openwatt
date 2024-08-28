module urt.endian;

import urt.traits;

nothrow @nogc:


ushort bigEndianToNative(T)(ref const ubyte[2] bytes)
	if (is(T == ushort))
{
	return cast(ushort)bytes[0] << 8 | bytes[1];
}
ushort littleEndianToNative(T)(ref const ubyte[2] bytes)
	if (is(T == ushort))
{
	return bytes[0] | cast(ushort)bytes[1] << 8;
}
uint bigEndianToNative(T)(ref const ubyte[4] bytes)
	if (is(T == uint))
{
	return cast(uint)bytes[0] << 24 | cast(uint)bytes[1] << 16 | cast(uint)bytes[2] << 8 | bytes[3];
}
uint littleEndianToNative(T)(ref const ubyte[4] bytes)
	if (is(T == uint))
{
	return bytes[0] | cast(uint)bytes[1] << 8 | cast(uint)bytes[2] << 16 | cast(uint)bytes[3] << 24;
}

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


void storeBigEndian(T)(T* target, T val) if (isSomeInt!T)
{
	(cast(ubyte*)target)[0..T.sizeof] = nativeToBigEndian(val);
}
void storeLittleEndian(T)(T* target, T val) if (isSomeInt!T)
{
	(cast(ubyte*)target)[0..T.sizeof] = nativeToLittle(val);
}
T loadBigEndian(T)(const(T)* src) if (isSomeInt!T)
{
	return bigEndianToNative!T((cast(ubyte*)src)[0..T.sizeof]);
}
T loadLittleEndian(T)(const(T)* src) if (isSomeInt!T)
{
	return littleEndianToNative!T((cast(ubyte*)src)[0..T.sizeof]);
}
