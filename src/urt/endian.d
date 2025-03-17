module urt.endian;

import urt.traits;

version (X86)
    enum SupportUnalignedLoadStore = true;
else version (X86_64)
    enum SupportUnalignedLoadStore = true;
else version (AArch64)
    enum SupportUnalignedLoadStore = true;
else version (ARM)
{
    import urt.processor;
    enum SupportUnalignedLoadStore = !ProcFeatures.strict_align;
}
else
{
    // TODO: I think MIPS R6 can do native unalogned loads/stores

    enum SupportUnalignedLoadStore = false;
}

// TODO: ARM has REV, REV16, REV32, REV64
//       MIPS has wsbh, dsbh, dshd
//       POWERPC has lwbrx/stbrx lhbrx/sthbrx
//       x86 has XCHG and BSWAP
//       RISC-V has grev if the B (Bitmanip extension) is present
//       GCC/LLVM have __builtin_bswap32/__builtin_bswap16 intrinsics...

version (LittleEndian)
    enum IsLittleEndian = true;
else
    enum IsLittleEndian = false;


nothrow @nogc:


pragma(inline, true) T endianToNative(T, bool little)(ref const ubyte[1] bytes)
    if (is(T == ubyte) || is(T == byte) || is(T == bool) || is(T == char))
{
    return (cast(T*)bytes.ptr)[0];
}

T endianToNative(T, bool little)(ref const ubyte[2] bytes)
    if (is(T == ushort) || is(T == short) || is(T == wchar))
{
    static if (SupportUnalignedLoadStore && IsLittleEndian == little)
        return *cast(T*)bytes.ptr;
    else static if (little)
        return bytes[0] | bytes[1] << 8;
    else
        return bytes[0] << 8 | bytes[1];
}

T endianToNative(T, bool little)(ref const ubyte[4] bytes)
    if (is(T == uint) || is(T == int) || is(T == dchar) || is(T == float))
{
    static if (SupportUnalignedLoadStore && IsLittleEndian == little)
        return *cast(T*)bytes.ptr;
    else static if (little)
    {
        uint i = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24;
        static if (is(T == float))
            return *cast(float*)&i;
        else
            return i;
    }
    else
    {
        uint i = bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3];
        static if (is(T == float))
            return *cast(float*)&i;
        else
            return i;
    }
}

T endianToNative(T, bool little)(ref const ubyte[8] bytes)
    if (is(T == ulong) || is(T == long) || is(T == double))
{
    static if (SupportUnalignedLoadStore && IsLittleEndian == little)
        return *cast(T*)bytes.ptr;
    else static if (little)
    {
        ulong i = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | cast(ulong)bytes[3] << 24 | cast(ulong)bytes[4] << 32 | cast(ulong)bytes[5] << 40 | cast(ulong)bytes[6] << 48 | cast(ulong)bytes[7] << 56;
        static if (is(T == double))
            return *cast(double*)&i;
        else
            return i;
    }
    else
    {
        ulong i = cast(ulong)bytes[0] << 56 | cast(ulong)bytes[1] << 48 | cast(ulong)bytes[2] << 40 | cast(ulong)bytes[3] << 32 | cast(ulong)bytes[4] << 24 | bytes[5] << 16 | bytes[6] << 8 | bytes[7];
        static if (is(T == double))
            return *cast(double*)&i;
        else
            return i;
    }
}

auto endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (isEnum!T)
{
    return cast(T)endianToNative!(enumType!T, little)(bytes);
}

T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (is(T == U[N], U, size_t N))
{
    static if (is(T == U[N], U, size_t N))
    {
        static assert(!is(U == class) && !is(U == interface) && !is(U == V*, V), T.stringof ~ " is not POD");

        T r;

        static if (U.sizeof == 1)
            r = (cast(U[])bytes)[0..N];
        else
        {
            for (size_t i = 0, j = 0; i < N; ++i, j += T.sizeof)
                r[i] = endianToNative!(U, little)(bytes.ptr[j .. j + T.sizeof][0 .. T.sizeof]);
        }

        return r;
    }
}

T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (is(T == struct))
{
    // assert that T is POD

    T r;

    size_t offset = 0;
    alias members = r.tupleof;
    static foreach(i; 0 .. members.length)
    {{
        enum Len = members[i].sizeof;
        members[i] = endianToNative!(typeof(members[i]), little)(bytes.ptr[offset .. offset + Len][0 .. Len]);
        offset += Len;
    }}

    return r;
}

T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (is(T == U[], U) || is(T == U*, U) || is(T == class) || is(T == interface))
{
    static assert(false, "Invalid call for " ~ T.stringof);
}


alias bigEndianToNative(T) = endianToNative!(T, false);
alias littleEndianToNative(T) = endianToNative!(T, true);


pragma(inline, true) ubyte[1] nativeToEndian(bool little, T)(const T u8)
    if (is(T == ubyte) || is(T == byte) || is(T == bool))
{
    return (cast(ubyte*)&u8)[0..1];
}

ubyte[2] nativeToEndian(bool little, T)(const T u16)
    if (is(T == ushort) || is(T == short) || is(T == wchar))
{
    static if (SupportUnalignedLoadStore && IsLittleEndian == little)
    {
        ubyte[2] res = void;
        *cast(T*)res.ptr = u16; // this should perform an unaligned store to the destination via NRVO
        return res;
    }
    else
    {
        ushort i = u16;
        static if (little)
        {
            ubyte[2] res = [ i & 0xFF, i >> 8 ];
            return res;
        }
        else
        {
            ubyte[2] res = [ i >> 8, i & 0xFF ];
            return res;
        }
    }
}

ubyte[4] nativeToEndian(bool little, T)(const T u32)
    if (is(T == uint) || is(T == int) || is(T == dchar) || is(T == float))
{
    static if (SupportUnalignedLoadStore && IsLittleEndian == little)
    {
        ubyte[4] res = void;
        *cast(T*)res.ptr = u32; // this should perform an unaligned store to the destination via NRVO
        return res;
    }
    else
    {
        uint i;
        static if (is(T == float))
            i = *cast(uint*)&u32;
        else
            i = u32;
        static if (little)
        {
            ubyte[4] res = [ i & 0xFF, (i >> 8) & 0xFF, (i >> 16) & 0xFF, i >> 24 ];
            return res;
        }
        else
        {
            ubyte[4] res = [ i >> 24, (i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF ];
            return res;
        }
    }
}

ubyte[8] nativeToEndian(bool little, T)(const T u64)
    if (is(T == ulong) || is(T == long) || is(T == double))
{
    static if (SupportUnalignedLoadStore && IsLittleEndian == little)
    {
        ubyte[8] res = void;
        *cast(T*)res.ptr = u64; // this should perform an unaligned store to the destination via NRVO
        return res;
    }
    else
    {
        ulong i;
        static if (is(T == double))
            i = *cast(ulong*)&u64;
        else
            i = u64;
        static if (little)
        {
            ubyte[8] res = [ i & 0xFF, (i >> 8) & 0xFF, (i >> 16) & 0xFF, (i >> 24) & 0xFF, (i >> 32) & 0xFF, (i >> 40) & 0xFF, (i >> 48) & 0xFF, i >> 56 ];
            return res;
        }
        else
        {
            ubyte[8] res = [ i >> 56, (i >> 48) & 0xFF, (i >> 40) & 0xFF, (i >> 32) & 0xFF, (i >> 24) & 0xFF, (i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF ];
            return res;
        }
    }
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(const T data)
    if (isEnum!T)
{
    return nativeToEndian!little(cast(enumType!T)data);
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == U[N], U, size_t N))
{
    static assert(is(T == U[N], U, size_t N) && !is(U == class) && !is(U == interface) && !is(U == V*, V), T.stringof ~ " is not POD");

    ubyte[T.sizeof] buffer;

    static if (T.sizeof == 1)
        buffer[0 .. N] = cast(ubyte[])data[];
    else
    {
        for (size_t i = 0; i < N*T.sizeof; i += T.sizeof)
           buffer.ptr[i .. i + T.sizeof][0 .. T.sizeof] = nativeToEndian!little(data[i]);
    }

    return buffer;
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == struct))
{
    // assert that T is POD

    ubyte[T.sizeof] buffer;

    size_t offset = 0;
    alias members = data.tupleof;
    static foreach(i; 0 .. members.length)
    {{
        enum Len = members[i].sizeof;
        buffer.ptr[offset .. offset + Len][0 .. Len] = nativeToEndian!little(members[i]);
        offset += Len;
    }}

    return buffer;
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == U[], U) || is(T == U*, U) || is(T == class) || is(T == interface))
{
    static assert(false, "Invalid call for " ~ T.stringof);
}

ubyte[T.sizeof] nativeToBigEndian(T)(auto ref const T data)
    => nativeToEndian!false(data);
ubyte[T.sizeof] nativeToLittleEndian(T)(auto ref const T data)
    => nativeToEndian!true(data);


void storeBigEndian(T)(T* target, const T val)
    if (isSomeInt!T || is(T == float))
{
    (cast(ubyte*)target)[0..T.sizeof] = nativeToBigEndian(val);
}
void storeLittleEndian(T)(T* target, const T val)
    if (isSomeInt!T || is(T == float))
{
    (cast(ubyte*)target)[0..T.sizeof] = nativeToLittleEndian(val);
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


unittest
{
    ubyte[8] test = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0];

    assert(endianToNative!(ubyte,   IsLittleEndian)(test[0..1]) == 0x12);
    assert(endianToNative!(ushort,  IsLittleEndian)(test[0..2]) == 0x3412);
    assert(endianToNative!(uint,    IsLittleEndian)(test[0..4]) == 0x78563412);
    assert(endianToNative!(ulong,   IsLittleEndian)(test) == 0xF0DEBC9A78563412);
    assert(endianToNative!(ubyte,  !IsLittleEndian)(test[0..1]) == 0x12);
    assert(endianToNative!(ushort, !IsLittleEndian)(test[0..2]) == 0x1234);
    assert(endianToNative!(uint,   !IsLittleEndian)(test[0..4]) == 0x12345678);
    assert(endianToNative!(ulong,  !IsLittleEndian)(test) == 0x123456789ABCDEF0);

    assert(nativeToEndian!( IsLittleEndian,  ubyte)(0x12) == test[0..1]);
    assert(nativeToEndian!( IsLittleEndian, ushort)(0x3412) == test[0..2]);
    assert(nativeToEndian!( IsLittleEndian,   uint)(0x78563412) == test[0..4]);
    assert(nativeToEndian!( IsLittleEndian,  ulong)(0xF0DEBC9A78563412) == test);
    assert(nativeToEndian!(!IsLittleEndian,  ubyte)(0x12) == test[0..1]);
    assert(nativeToEndian!(!IsLittleEndian, ushort)(0x1234) == test[0..2]);
    assert(nativeToEndian!(!IsLittleEndian,   uint)(0x12345678) == test[0..4]);
    assert(nativeToEndian!(!IsLittleEndian,  ulong)(0x123456789ABCDEF0) == test);
}
