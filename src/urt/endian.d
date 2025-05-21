module urt.endian;

import urt.processor;
import urt.traits;

public import urt.processor : LittleEndian;
public import urt.util : byteReverse;

pure nothrow @nogc:


// load from byte arrays
pragma(inline, true) T endianToNative(T, bool little)(ref const ubyte[1] bytes)
    if (T.sizeof == 1 && isIntegral!T)
{
    return cast(T)bytes[0];
}

ushort endianToNative(T, bool little)(ref const ubyte[2] bytes)
    if (T.sizeof == 2 && isIntegral!T)
{
    if (__ctfe || !SupportUnalignedLoadStore)
    {
        // ctfe can't do the memory reinterpreting
        static if (little)
            return cast(T)(bytes[0] | bytes[1] << 8);
        else
            return cast(T)(bytes[0] << 8 | bytes[1]);
    }
    static if (SupportUnalignedLoadStore)
    {
        pragma(inline, true);
        static if (LittleEndian == little)
            return *cast(ushort*)bytes.ptr;
        else
            return byteReverse(*cast(ushort*)bytes.ptr);
    }
}

uint endianToNative(T, bool little)(ref const ubyte[4] bytes)
    if (T.sizeof == 4 && isIntegral!T)
{
    if (__ctfe || !SupportUnalignedLoadStore)
    {
        // ctfe can't do the memory reinterpreting
        static if (little)
            return cast(T)(bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24);
        else
            return cast(T)(bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]);
    }
    static if (SupportUnalignedLoadStore)
    {
        pragma(inline, true);
        static if (LittleEndian == little)
            return *cast(uint*)bytes.ptr;
        else
            return byteReverse(*cast(uint*)bytes.ptr);
    }
}

ulong endianToNative(T, bool little)(ref const ubyte[8] bytes)
    if (T.sizeof == 8 && isIntegral!T)
{
    if (__ctfe || !SupportUnalignedLoadStore)
    {
        // ctfe can't do the memory reinterpreting
        static if (little)
            return cast(T)(bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24 | cast(ulong)bytes[4] << 32 | cast(ulong)bytes[5] << 40 | cast(ulong)bytes[6] << 48 | cast(ulong)bytes[7] << 56);
        else
            return cast(T)(cast(ulong)bytes[0] << 56 | cast(ulong)bytes[1] << 48 | cast(ulong)bytes[2] << 40 | cast(ulong)bytes[3] << 32 | bytes[4] << 24 | bytes[5] << 16 | bytes[6] << 8 | bytes[7]);
    }
    static if (SupportUnalignedLoadStore)
    {
        pragma(inline, true);
        static if (LittleEndian == little)
            return *cast(ulong*)bytes.ptr;
        else
            return byteReverse(*cast(ulong*)bytes.ptr);
    }
}

pragma(inline, true) T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (!isIntegral!T && !is(T == struct) && !is(T == U[N], U, size_t N))
{
    import urt.meta : intForWidth;
    alias U = intForWidth!(T.sizeof*8);
    U u = endianToNative!(U, little)(bytes);
    return *cast(T*)&u;
}

T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (is(T == U[N], U, size_t N))
{
    static if (is(T == U[N], U, size_t N))
    {
        static assert(!is(U == class) && !is(U == interface) && !is(U == V*, V), T.stringof ~ " is not POD");

        static if (U.sizeof == 1)
            r = *cast(T*)&bytes;
        else
        {
            T r;
            for (size_t i = 0, j = 0; i < N; ++i, j += T.sizeof)
                r[i] = endianToNative!(U, little)(bytes.ptr[j .. j + T.sizeof][0 .. T.sizeof]);
            return r;
        }
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


// store to byte arrays
pragma(inline, true) ubyte[1] nativeToEndian(bool little)(ubyte u)
{
    return [ u ];
}

ubyte[2] nativeToEndian(bool little)(ushort u)
{
    if (__ctfe || !SupportUnalignedLoadStore)
    {
        // ctfe can't do the memory reinterpreting
        static if (little)
            return [ u & 0xFF, u >> 8 ];
        else
            return [ u >> 8, u & 0xFF ];
    }
    static if (SupportUnalignedLoadStore)
    {
        static if (LittleEndian != little)
            u = byteReverse(u);
        else
            pragma(inline, true);
        return *cast(ubyte[2]*)&u;
    }
}

ubyte[4] nativeToEndian(bool little)(uint u)
{
    if (__ctfe || !SupportUnalignedLoadStore)
    {
        // ctfe can't do the memory reinterpreting
        static if (little)
            return [ u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF, u >> 24 ];
        else
            return [ u >> 24, (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF ];
    }
    static if (SupportUnalignedLoadStore)
    {
        static if (LittleEndian != little)
            u = byteReverse(u);
        else
            pragma(inline, true);
        return *cast(ubyte[4]*)&u;
    }
}

ubyte[8] nativeToEndian(bool little)(ulong u)
{
    if (__ctfe || !SupportUnalignedLoadStore)
    {
        // ctfe can't do the memory reinterpreting
        static if (little)
            return [ u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF, (u >> 24) & 0xFF, (u >> 32) & 0xFF, (u >> 40) & 0xFF, (u >> 48) & 0xFF, u >> 56 ];
        else
            return [ u >> 56, (u >> 48) & 0xFF, (u >> 40) & 0xFF, (u >> 32) & 0xFF, (u >> 24) & 0xFF, (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF ];
    }
    static if (SupportUnalignedLoadStore)
    {
        static if (LittleEndian != little)
            u = byteReverse(u);
        else
            pragma(inline, true);
        return *cast(ubyte[8]*)&u;
    }
}

pragma(inline, true) auto nativeToEndian(bool little, T)(T val)
    if (!isIntegral!T && !is(T == struct) && !is(T == U[N], U, size_t N))
{
    import urt.meta : intForWidth;
    alias U = intForWidth!(T.sizeof*8);
    U r = nativeToEndian!little(*cast(U*)&val);
    return *cast(T*)&r;
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == U[N], U, size_t N))
{
    static assert(is(T == U[N], U, size_t N) && !is(U == class) && !is(U == interface) && !is(U == V*, V), T.stringof ~ " is not POD");

    static if (U.sizeof == 1)
        return *cast(ubyte[T.sizeof])&data;
    else
    {
        ubyte[T.sizeof] buffer = void;
        for (size_t i = 0; i < N*T.sizeof; i += T.sizeof)
           buffer.ptr[i .. i + T.sizeof][0 .. T.sizeof] = nativeToEndian!little(data[i]);
        return buffer;
    }
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == struct))
{
    // assert that T is POD

    ubyte[T.sizeof] buffer = void;

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


// load/store from/to memory
void storeBigEndian(T)(T* target, const T val)
    if (isSomeInt!T || is(T == float))
{
    version (BigEndian)
        *target = val;
    else
        *target = byteReverse(val);
}
void storeLittleEndian(T)(T* target, const T val)
    if (isSomeInt!T || is(T == float))
{
    version (LittleEndian)
        *target = val;
    else
        *target = byteReverse(val);
}
T loadBigEndian(T)(const(T)* src)
    if (isSomeInt!T || is(T == float))
{
    version (BigEndian)
        return *src;
    else
        return byteReverse(*src);
}
T loadLittleEndian(T)(const(T)* src)
    if (isSomeInt!T || is(T == float))
{
    version (LittleEndian)
        return *src;
    else
        return byteReverse(*src);
}


unittest
{
    ubyte[8] test = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0];

    assert(endianToNative!(ubyte,   LittleEndian)(test[0..1]) == 0x12);
    assert(endianToNative!(ushort,  LittleEndian)(test[0..2]) == 0x3412);
    assert(endianToNative!(uint,    LittleEndian)(test[0..4]) == 0x78563412);
    assert(endianToNative!(ulong,   LittleEndian)(test) == 0xF0DEBC9A78563412);
    assert(endianToNative!(ubyte,  !LittleEndian)(test[0..1]) == 0x12);
    assert(endianToNative!(ushort, !LittleEndian)(test[0..2]) == 0x1234);
    assert(endianToNative!(uint,   !LittleEndian)(test[0..4]) == 0x12345678);
    assert(endianToNative!(ulong,  !LittleEndian)(test) == 0x123456789ABCDEF0);

    assert(nativeToEndian!( LittleEndian)(0x12) == test[0..1]);
    assert(nativeToEndian!( LittleEndian)(0x3412) == test[0..2]);
    assert(nativeToEndian!( LittleEndian)(0x78563412) == test[0..4]);
    assert(nativeToEndian!( LittleEndian)(0xF0DEBC9A78563412) == test);
    assert(nativeToEndian!(!LittleEndian)(0x12) == test[0..1]);
    assert(nativeToEndian!(!LittleEndian)(0x1234) == test[0..2]);
    assert(nativeToEndian!(!LittleEndian)(0x12345678) == test[0..4]);
    assert(nativeToEndian!(!LittleEndian)(0x123456789ABCDEF0) == test);
}
