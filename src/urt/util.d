module urt.util;

import urt.compiler;
import urt.intrinsic;
import urt.traits;

nothrow @nogc:


ref T swap(T)(ref T a, return ref T b)
{
    import urt.lifetime : move, moveEmplace;

    T t = a.move;
    b.move(a);
    t.move(b);
    return b;
}

T swap(T)(ref T a, T b)
{
    import urt.lifetime : move, moveEmplace;

    auto t = a.move;
    b.move(a);
    return t.move;
}

pure:

auto min(T, U)(auto ref inout T a, auto ref inout U b)
{
    return a < b ? a : b;
}

auto max(T, U)(auto ref inout T a, auto ref inout U b)
{
    return a > b ? a : b;
}

template Align(size_t value, size_t alignment = size_t.sizeof)
{
    static assert(isPowerOf2(alignment), "Alignment must be a power of two: ", alignment);
    enum Align = alignTo(value, alignment);
}

enum IsAligned(size_t value) = isAligned(value);
enum IsPowerOf2(size_t value) = isPowerOf2(value);
enum NextPowerOf2(size_t value) = nextPowerOf2(value);


bool isPowerOf2(T)(T x)
    if (isSomeInt!T)
{
    return (x & (x - 1)) == 0;
}

T nextPowerOf2(T)(T x)
    if (isSomeInt!T)
{
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    static if (T.sizeof >= 2)
        x |= x >> 8;
    static if (T.sizeof >= 4)
        x |= x >> 16;
    static if (T.sizeof >= 8)
        x |= x >> 32;
    return cast(T)(x + 1);
}

T alignDown(size_t alignment, T)(T value)
    if (isSomeInt!T || is(T == U*, U))
{
    return cast(T)(cast(size_t)value & ~(alignment - 1));
}

T alignDown(T)(T value, size_t alignment)
    if (isSomeInt!T || is(T == U*, U))
{
    return cast(T)(cast(size_t)value & ~(alignment - 1));
}

T alignUp(size_t alignment, T)(T value)
    if (isSomeInt!T || is(T == U*, U))
{
    return cast(T)((cast(size_t)value + (alignment - 1)) & ~(alignment - 1));
}

T alignUp(T)(T value, size_t alignment)
    if (isSomeInt!T || is(T == U*, U))
{
    return cast(T)((cast(size_t)value + (alignment - 1)) & ~(alignment - 1));
}

bool isAligned(size_t alignment, T)(T value)
    if (isSomeInt!T || is(T == U*, U))
{
    static assert(IsPowerOf2!alignment, "Alignment must be a power of two!");
    return (cast(size_t)value & (alignment - 1)) == 0;
}

bool isAligned(T)(T value, size_t alignment)
    if (isSomeInt!T || is(T == U*, U))
{
    return (cast(size_t)value & (alignment - 1)) == 0;
}

/+
ubyte log2(ubyte val)
{
    if (val >> 4)
    {
        if (val >> 6)
            if (val >> 7)
                return 7;
            else
                return 6;
        else
            if (val >> 5)
                return 5;
            else
                return 4;
    }
    else
    {
        if (val >> 2)
            if (val >> 3)
                return 3;
            else
                return 2;
        else
            if (val >> 1)
                return 1;
            else
                return 0;
    }
}

ubyte log2(T)(T val)
    if (isSomeInt!T && T.sizeof > 1)
{
    if (T.sizeof > 4 && val >> 32)
    {
        if (val >> 48)
            if (val >> 56)
                return 56 + log2(cast(ubyte)(val >> 56));
            else
                return 48 + log2(cast(ubyte)(val >> 48));
        else
            if (val >> 40)
                return 40 + log2(cast(ubyte)(val >> 40));
            else
                return 32 + log2(cast(ubyte)(val >> 32));
    }
    else
    {
        if (T.sizeof > 2 && val >> 16)
            if (val >> 24)
                return 24 + log2(cast(ubyte)(val >> 24));
            else
                return 16 + log2(cast(ubyte)(val >> 16));
        else
            if (val >> 8)
                return 8 + log2(cast(ubyte)(val >> 8));
            else
                return log2(cast(ubyte)val);
    }
}
+/

ubyte log2(T)(T x)
    if (isIntegral!T)
{
    ubyte result = 0;
    static if (T.sizeof > 4)
        if (x >= 1UL<<32)       { x >>= 32; result += 32; }
    static if (T.sizeof > 2)
        if (x >= 1<<16)         { x >>= 16; result += 16; }
    static if (T.sizeof > 1)
        if (x >= 1<<8)          { x >>= 8;  result += 8; }
    if (x >= 1<<4)              { x >>= 4;  result += 4; }
    if (x >= 1<<2)              { x >>= 2;  result += 2; }
    if (x >= 1<<1)              {           result += 1; }
    return result;

/+
    // TODO: this might be better on systems with no branch predictor...
    Unsigned!(Unqual!T) v = x;
    ubyte shift;
    ubyte r;

    r =     (v > 0xFFFF) << 4; v >>= r;
    shift = (v > 0xFF  ) << 3; v >>= shift; r |= shift;
    shift = (v > 0xF   ) << 2; v >>= shift; r |= shift;
    shift = (v > 0x3   ) << 1; v >>= shift; r |= shift;
    r |= (v >> 1);
+/
}

ubyte clz(bool nonZero = false, T)(T x)
    if (isIntegral!T)
{
    static if (nonZero)
        debug assert(x != 0);
    if (__ctfe || !IS_LDC_OR_GDC)
    {
        static if (T.sizeof == 1)
            return x ? cast(ubyte)(7 - log2(cast(ubyte)x)) : 8;
        static if (T.sizeof == 2)
            return x ? cast(ubyte)(15 - log2(cast(ushort)x)) : 16;
        static if (T.sizeof == 4)
            return x ? cast(ubyte)(31 - log2(cast(uint)x)) : 32;
        static if (T.sizeof == 8)
            return x ? cast(ubyte)(63 - log2(cast(ulong)x)) : 64;
    }
    else
    {
        version (GNU)
        {
            static if (T.sizeof < 8)
            {
                static if (T.sizeof == 1)
                    return cast(ubyte)__builtin_clz((x << 24) | 0x800000);
                static if (T.sizeof == 2)
                    return cast(ubyte)__builtin_clz((x << 16) | 0x8000);
                static if (T.sizeof == 4)
                {
                    // TODO: hard to guess which variant is superior...
                    static if (size_t.sizeof == 8)
                        return cast(ubyte)__builtin_clzll(ulong(x) << 32 | 0x80000000);
                    else
                    {
                        if (x == 0)
                            return 32;
                        return cast(ubyte)__builtin_clz(x);
                    }
                }
            }
            else
            {
                static if (size_t.sizeof == 8)
                {
                    // TODO: which machines can skip this check?
                    if (x == 0)
                        return 64;
                    return cast(ubyte)__builtin_clzll(x);
                }
                else
                {
                    uint u = x >> 32;
                    if (u != 0)
                        return cast(ubyte)__builtin_clz(u);
                    u = cast(uint)x;
                    if (u != 0)
                        return 32 + cast(ubyte)__builtin_clz(u);
                    return 64;
                }
            }
        }
        else version (LDC)
            return cast(ubyte)_llvm_ctlz(x, nonZero);
        else
            assert(false, "Unreachable");
    }
}
ubyte clz(T : bool)(T x)
    => x ? 7 : 8;

ubyte ctz(bool nonZero = false, T)(T x)
    if (isIntegral!T)
{
    static if (nonZero)
        debug assert(x != 0);
    if (__ctfe || !IS_LDC_OR_GDC)
    {
        Unsigned!(Unqual!T) t = x;

        // special case for odd v (assumed to happen ~half of the time)
        if (t & 0x1)
            return 0;
        else if (t == 0)
            return T.sizeof * 8;

        ubyte result = 1;
        static if (T.sizeof > 4)
        {
            if ((t & 0xffffffff) == 0) 
            {  
                t >>= 32;  
                result += 32;
            }
        }
        static if (T.sizeof > 2)
        {
            if ((t & 0xffff) == 0) 
            {  
                t >>= 16;  
                result += 16;
            }
        }
        static if (T.sizeof > 1)
        {
            if ((t & 0xff) == 0) 
            {  
                t >>= 8;  
                result += 8;
            }
        }
        if ((t & 0xf) == 0) 
        {  
            t >>= 4;
            result += 4;
        }
        if ((t & 0x3) == 0) 
        {  
            t >>= 2;
            result += 2;
        }
        result -= t & 0x1;
        return result;
    }
    else
    {
        version (GNU)
        {
            static if (T.sizeof == 1)
                return cast(ubyte)__builtin_ctz(0x100u | x);
            static if (T.sizeof == 2)
                return cast(ubyte)__builtin_ctz(0x10000u | x);
            static if (T.sizeof == 4)
            {
                // TODO: hard to know which version is superior...
                static if (size_t.sizeof == 8)
                    return cast(ubyte)__builtin_ctzll(0x100000000 | x);
                else
                {
                    if (x == 0)
                        return 32;
                    return cast(ubyte)__builtin_ctz(x);
                }
            }
            static if (T.sizeof == 8)
            {
                static if (size_t.sizeof == 8)
                {
                    // TODO: which machines can skip this check?
                    if (x == 0)
                        return 64;
                    return cast(ubyte)__builtin_ctzll(x);
                }
                else
                {
                    uint u = cast(uint)x;
                    if (u != 0)
                        return cast(ubyte)__builtin_ctz(u);
                    u = x >> 32;
                    if (u != 0) // TODO: if the machine behaves sensible, then we can omit this `if`
                        return 32 + cast(ubyte)__builtin_ctz(u);
                    return 64;
                }
            }
        }
        else version (LDC)
        {
            version (X86_64)
                static if (T.sizeof == 4 && !nonZero)
                    return cast(ubyte)_llvm_cttz(0x100000000 | x, true); // TODO: confirm this is actually superior?!
            return cast(ubyte)_llvm_cttz(x, nonZero);
        }
        else
            assert(false, "Unreachable");
    }
}
ubyte ctz(T : bool)(T x)
    => x ? 0 : 8;

ubyte popcnt(T)(T x)
    if (isIntegral!T)
{
    if (__ctfe || !IS_LDC_OR_GDC)
    {
        enum fives = cast(Unsigned!T)-1/3;      // 0x5555...
        enum threes = cast(Unsigned!T)-1/15*3;  // 0x3333...
        enum effs = cast(Unsigned!T)-1/255*15;  // 0x0F0F...
        enum ones = cast(Unsigned!T)-1/255;     // 0x0101...

        auto t = x - ((x >>> 1) & fives);
        t = (t & threes) + ((t >>> 2) & threes);
        t = ((t + (t >>> 4)) & effs) * ones;
        return cast(ubyte)(t >>> (T.sizeof - 1)*8);
    }
    else
    {
        version (GNU)
        {
            static if (T.sizeof == 8)// && size_t.sizeof == 8)
                return cast(ubyte)__builtin_popcountll(x);
            else
                return cast(ubyte)__builtin_popcount(x);
        }
        else version (LDC)
            return cast(ubyte)_llvm_ctpop(x);
        else
            assert(false, "Unreachable");
    }
}
ubyte popcnt(T : bool)(T x)
    => x ? 1 : 0;

ubyte byteReverse(ubyte v)
    => v;
ushort byteReverse(ushort v)
{
    if (__ctfe || !IS_LDC_OR_GDC)
        return cast(ushort)((v << 8) | (v >> 8));
    else static if (IS_LDC_OR_GDC)
        return __builtin_bswap16(v);
    else
        assert(false, "Unreachable");
}
uint byteReverse(uint v)
{
    if (__ctfe || !IS_LDC_OR_GDC)
        return cast(uint)((v << 24) | ((v & 0xFF00) << 8) | ((v >> 8) & 0xFF00) | (v >> 24));
    else static if (IS_LDC_OR_GDC)
        return __builtin_bswap32(v);
    else
        assert(false, "Unreachable");
}
ulong byteReverse(ulong v)
{
    if (__ctfe || !IS_LDC_OR_GDC)
        return cast(ulong)((v << 56) | ((v & 0xFF00) << 40) | ((v & 0xFF0000) << 24) | ((v & 0xFF000000) << 8) | ((v >> 8) & 0xFF000000) | ((v >> 24) & 0xFF0000) | ((v >> 40) & 0xFF00) | (v >> 56));
    else static if (IS_LDC_OR_GDC)
        return __builtin_bswap64(v);
    else
        assert(false, "Unreachable");
}
pragma(inline, true) T byteReverse(T)(T val)
    if (!isIntegral!T)
{
    import urt.meta : intForWidth;
    alias U = intForWidth!(T.sizeof*8);
    U r = byteReverse(*cast(U*)&val);
    return *cast(T*)&r;
}

T bitReverse(T)(T x)
    if (isSomeInt!T)
{
    if (__ctfe || !IS_LDC)
    {
        static if (T.sizeof == 1)
        {
            // TODO: these may be inferior on platforms where mul is slow...
            static if (size_t.sizeof == 8)
            {
                //                return cast(ubyte)((b*0x0202020202ULL & 0x010884422010ULL) % 1023; // only 3 ops, but uses div!
                return cast(ubyte)(cast(ulong)(x*0x80200802UL & 0x0884422110)*0x0101010101 >> 32);
            }
            else
                return cast(ubyte)(cast(uint)((x*0x0802 & 0x22110) | (x*0x8020 & 0x88440))*0x10101 >> 16);
        }
        else
        {
            enum T fives  = cast(T)0x5555555555555555;
            enum T threes = cast(T)0x3333333333333333;
            enum T effs   = cast(T)0x0F0F0F0F0F0F0F0F;

            x = ((x >> 1) & fives)  | ((x & fives)  << 1);
            x = ((x >> 2) & threes) | ((x & threes) << 2);
            x = ((x >> 4) & effs)   | ((x & effs)   << 4);
            static if (T.sizeof == 1)
                return x;
            else
                return byteReverse(x);
        }
    }
    else
    {
        version (LDC)
            return _llvm_bitreverse(x);
        else
            assert(false, "Unreachable");
    }
}

enum Default = DefaultInit.init;

struct InPlace(C)
    if (is(C == class))
{
    import urt.lifetime;

    alias value this;
    inout(C) value() inout pure nothrow @nogc => cast(inout(C))instance.ptr;

    this() @disable;

    this()(DefaultInit)
    {
        value.emplace();
    }

    this(Args...)(auto ref Args args)
    {
        value.emplace(forward!args);
    }

    ~this()
    {
        value.destroy();
    }

private:
    align(__traits(classInstanceAlignment, C))
    ubyte[__traits(classInstanceSize, C)] instance;
}


private:

enum DefaultInit { def }

unittest
{
    int x = 10, y = 20;
    assert(x.swap(y) == 10);
    assert(x.swap(30) == 20);

    static assert(isPowerOf2(0) == true);
    static assert(isPowerOf2(1) == true);
    static assert(isPowerOf2(2) == true);
    static assert(isPowerOf2(3) == false);
    static assert(isPowerOf2(4) == true);
    static assert(isPowerOf2(5) == false);
    static assert(isPowerOf2(ulong(uint.max) + 1) == true);
    static assert(isPowerOf2(ulong.max) == false);
    assert(isPowerOf2(0) == true);
    assert(isPowerOf2(1) == true);
    assert(isPowerOf2(2) == true);
    assert(isPowerOf2(3) == false);
    assert(isPowerOf2(4) == true);
    assert(isPowerOf2(5) == false);
    assert(isPowerOf2(ulong(uint.max) + 1) == true);
    assert(isPowerOf2(ulong.max) == false);

    static assert(nextPowerOf2(0) == 0);
    static assert(nextPowerOf2(1) == 1);
    static assert(nextPowerOf2(2) == 2);
    static assert(nextPowerOf2(3) == 4);
    static assert(nextPowerOf2(4) == 4);
    static assert(nextPowerOf2(5) == 8);
    static assert(nextPowerOf2(uint.max) == 0);
    static assert(nextPowerOf2(ulong(uint.max)) == ulong(uint.max) + 1);
    assert(nextPowerOf2(0) == 0);
    assert(nextPowerOf2(1) == 1);
    assert(nextPowerOf2(2) == 2);
    assert(nextPowerOf2(3) == 4);
    assert(nextPowerOf2(4) == 4);
    assert(nextPowerOf2(5) == 8);
    assert(nextPowerOf2(uint.max) == 0);
    assert(nextPowerOf2(ulong(uint.max)) == ulong(uint.max) + 1);

    static assert(log2(ubyte(0)) == 0);
    static assert(log2(ubyte(1)) == 0);
    static assert(log2(ubyte(2)) == 1);
    static assert(log2(ubyte(3)) == 1);
    static assert(log2(ubyte(4)) == 2);
    static assert(log2(ubyte(5)) == 2);
    static assert(log2(ubyte(127)) == 6);
    static assert(log2(ubyte(128)) == 7);
    static assert(log2(ubyte(255)) == 7);
    static assert(log2(uint.max) == 31);
    static assert(log2(ulong.max) == 63);
    static assert(log2('D') == 6); // 0x44
    assert(log2(ubyte(0)) == 0);
    assert(log2(ubyte(1)) == 0);
    assert(log2(ubyte(2)) == 1);
    assert(log2(ubyte(3)) == 1);
    assert(log2(ubyte(4)) == 2);
    assert(log2(ubyte(5)) == 2);
    assert(log2(ubyte(127)) == 6);
    assert(log2(ubyte(128)) == 7);
    assert(log2(ubyte(255)) == 7);
    assert(log2(uint.max) == 31);
    assert(log2(ulong.max) == 63);
    assert(log2('D') == 6); // 0x44

    static assert(clz(ubyte(0)) == 8);
    static assert(clz(ubyte(1)) == 7);
    static assert(clz(ubyte(2)) == 6);
    static assert(clz(ubyte(3)) == 6);
    static assert(clz(ubyte(4)) == 5);
    static assert(clz(ubyte(5)) == 5);
    static assert(clz(uint(0)) == 32);
    static assert(clz(uint(17)) == 27);
    static assert(clz(ushort.max) == 0);
    static assert(clz(uint(ushort.max)) == 16);
    static assert(clz(uint.max) == 0);
    static assert(clz(ulong(uint.max)) == 32);
    static assert(clz(ulong.max) == 0);
    static assert(clz(true) == 7);
    static assert(clz('D') == 1); // 0x44
    assert(clz(ubyte(0)) == 8);
    assert(clz(ubyte(1)) == 7);
    assert(clz(ubyte(2)) == 6);
    assert(clz(ubyte(3)) == 6);
    assert(clz(ubyte(4)) == 5);
    assert(clz(ubyte(5)) == 5);
    assert(clz(uint(0)) == 32);
    assert(clz(uint(17)) == 27);
    assert(clz(ushort.max) == 0);
    assert(clz(uint(ushort.max)) == 16);
    assert(clz(uint.max) == 0);
    assert(clz(ulong(uint.max)) == 32);
    assert(clz(ulong.max) == 0);
    assert(clz(true) == 7);
    assert(clz('D') == 1); // 0x44

    static assert(ctz(ubyte(0)) == 8);
    static assert(ctz(ubyte(1)) == 0);
    static assert(ctz(ubyte(2)) == 1);
    static assert(ctz(ubyte(3)) == 0);
    static assert(ctz(ubyte(4)) == 2);
    static assert(ctz(ubyte(5)) == 0);
    static assert(ctz(ubyte(128)) == 7);
    static assert(ctz(uint(0)) == 32);
    static assert(ctz(uint(48)) == 4);
    static assert(ctz(ulong(1) << 60) == 60);
    static assert(ctz(true) == 0);
    static assert(ctz('D') == 2); // 0x44
    assert(ctz(ubyte(0)) == 8);
    assert(ctz(ubyte(1)) == 0);
    assert(ctz(ubyte(2)) == 1);
    assert(ctz(ubyte(3)) == 0);
    assert(ctz(ubyte(4)) == 2);
    assert(ctz(ubyte(5)) == 0);
    assert(ctz(ubyte(128)) == 7);
    assert(ctz(uint(0)) == 32);
    assert(ctz(uint(48)) == 4);
    assert(ctz(ulong(1) << 60) == 60);
    assert(ctz(true) == 0);
    assert(ctz('D') == 2); // 0x44

    static assert(popcnt(ubyte(0)) == 0);
    static assert(popcnt(ubyte(1)) == 1);
    static assert(popcnt(ubyte(2)) == 1);
    static assert(popcnt(ubyte(3)) == 2);
    static assert(popcnt(ubyte(4)) == 1);
    static assert(popcnt(ubyte(5)) == 2);
    static assert(popcnt(byte.max) == 7);
    static assert(popcnt(byte(-1)) == 8);
    static assert(popcnt(int(0)) == 0);
    static assert(popcnt(uint.max) == 32);
    static assert(popcnt(ulong(0)) == 0);
    static assert(popcnt(ulong.max) == 64);
    static assert(popcnt(long.min) == 1);
    static assert(popcnt(true) == 1);
    static assert(popcnt('D') == 2); // 0x44
    assert(popcnt(ubyte(0)) == 0);
    assert(popcnt(ubyte(1)) == 1);
    assert(popcnt(ubyte(2)) == 1);
    assert(popcnt(ubyte(3)) == 2);
    assert(popcnt(ubyte(4)) == 1);
    assert(popcnt(ubyte(5)) == 2);
    assert(popcnt(byte.max) == 7);
    assert(popcnt(byte(-1)) == 8);
    assert(popcnt(int(0)) == 0);
    assert(popcnt(uint.max) == 32);
    assert(popcnt(ulong(0)) == 0);
    assert(popcnt(ulong.max) == 64);
    assert(popcnt(long.min) == 1);
    assert(popcnt(true) == 1);
    assert(popcnt('D') == 2); // 0x44

    static assert(bitReverse(ubyte(0)) == 0);
    static assert(bitReverse(ubyte(1)) == 128);
    static assert(bitReverse(ubyte(2)) == 64);
    static assert(bitReverse(ubyte(3)) == 192);
    static assert(bitReverse(ubyte(4)) == 32);
    static assert(bitReverse(ubyte(5)) == 160);
    static assert(bitReverse(ubyte(6)) == 96);
    static assert(bitReverse(ubyte(7)) == 224);
    static assert(bitReverse(ubyte(8)) == 16);
    static assert(bitReverse(ubyte(255)) == 255);
    static assert(bitReverse(ushort(0b1101100010000000)) == 0b0000000100011011);
    static assert(bitReverse(uint(0x73810000)) == 0x000081CE);
    static assert(bitReverse(ulong(0x7381000000000000)) == 0x00000000000081CE);
    assert(bitReverse(ubyte(0)) == 0);
    assert(bitReverse(ubyte(1)) == 128);
    assert(bitReverse(ubyte(2)) == 64);
    assert(bitReverse(ubyte(3)) == 192);
    assert(bitReverse(ubyte(4)) == 32);
    assert(bitReverse(ubyte(5)) == 160);
    assert(bitReverse(ubyte(6)) == 96);
    assert(bitReverse(ubyte(7)) == 224);
    assert(bitReverse(ubyte(8)) == 16);
    assert(bitReverse(ubyte(255)) == 255);
    assert(bitReverse(ushort(0b1101100010000000)) == 0b0000000100011011);
    assert(bitReverse(uint(0x73810000)) == 0x000081CE);
    assert(bitReverse(ulong(0x7381000000000000)) == 0x00000000000081CE);

    static assert(byteReverse(0x12) == 0x12);
    static assert(byteReverse(0x1234) == 0x3412);
    static assert(byteReverse(0x12345678) == 0x78563412);
    static assert(byteReverse(0x123456789ABCDEF0) == 0xF0DEBC9A78563412);
    static assert(byteReverse(true) == true);
    static assert(byteReverse(char(0x12)) == char(0x12));
    static assert(byteReverse(wchar(0x1234)) == wchar(0x3412));
    static assert(byteReverse(cast(dchar)0x12345678) == cast(dchar)0x78563412);
    assert(byteReverse(0x12) == 0x12);
    assert(byteReverse(0x1234) == 0x3412);
    assert(byteReverse(0x12345678) == 0x78563412);
    assert(byteReverse(0x123456789ABCDEF0) == 0xF0DEBC9A78563412);
    assert(byteReverse(true) == true);
    assert(byteReverse(char(0x12)) == char(0x12));
    assert(byteReverse(wchar(0x1234)) == wchar(0x3412));
    assert(byteReverse(cast(dchar)0x12345678) == cast(dchar)0x78563412);
    float frev;
    *cast(uint*)&frev = 0x0000803F;
    assert(byteReverse(1.0f) is frev);
}
