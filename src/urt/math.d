module urt.math;

import urt.intrinsic;
import core.stdc.stdio; // For writeDebugf
import std.format;      // For format

version (LDC) version = GDC_OR_LDC;
version (GNU) version = GDC_OR_LDC;

version (X86)
{
    version = Intel;
    version (DigitalMars) version = DMD_32;
    version (GNU) version = GDC_X86;
    version (LDC) version = LDC_X86;
    version (GDC_OR_LDC) version = GDC_OR_LDC_X86;
}
version (X86_64)
{
    version = Intel;
    version (DigitalMars) version = DMD_X86_64;
    version (GNU) version = GDC_X86_64;
    version (LDC) version = LDC_X86_64;
    version (GDC_OR_LDC) version = GDC_OR_LDC_X86_64;
}
version (Intel)
{
    import urt.intrinsic.x86;

    version (GNU) version = GDC_Intel;
    version (LDC) version = LDC_Intel;
    version (GDC_OR_LDC) version = GDC_OR_LDC_Intel;
}

enum real E =          0x1.5bf0a8b1457695355fb8ac404e7a8p+1L; /** e = 2.718281... */
enum real LOG2T =      0x1.a934f0979a3715fc9257edfe9b5fbp+1L; /** $(SUB log, 2)10 = 3.321928... */
enum real LOG2E =      0x1.71547652b82fe1777d0ffda0d23a8p+0L; /** $(SUB log, 2)e = 1.442695... */
enum real LOG2 =       0x1.34413509f79fef311f12b35816f92p-2L; /** $(SUB log, 10)2 = 0.301029... */
enum real LOG10E =     0x1.bcb7b1526e50e32a6ab7555f5a67cp-2L; /** $(SUB log, 10)e = 0.434294... */
enum real LN2 =        0x1.62e42fefa39ef35793c7673007e5fp-1L; /** ln 2  = 0.693147... */
enum real LN10 =       0x1.26bb1bbb5551582dd4adac5705a61p+1L; /** ln 10 = 2.302585... */
enum real PI =         0x1.921fb54442d18469898cc51701b84p+1L; /** &pi; = 3.141592... */
enum real PI_2 =       PI/2;                                  /** $(PI) / 2 = 1.570796... */
enum real PI_4 =       PI/4;                                  /** $(PI) / 4 = 0.785398... */
enum real M_1_PI =     0x1.45f306dc9c882a53f84eafa3ea69cp-2L; /** 1 / $(PI) = 0.318309... */
enum real M_2_PI =     2*M_1_PI;                              /** 2 / $(PI) = 0.636619... */
enum real M_2_SQRTPI = 0x1.20dd750429b6d11ae3a914fed7fd8p+0L; /** 2 / $(SQRT)$(PI) = 1.128379... */
enum real SQRT2 =      0x1.6a09e667f3bcc908b2fb1366ea958p+0L; /** $(SQRT)2 = 1.414213... */
enum real SQRT1_2 =    SQRT2/2;                               /** $(SQRT)$(HALF) = 0.707106... */
// Note: Make sure the magic numbers in compiler backend for x87 match these.

pure nothrow @nogc:


// CRT functions; often hooked by intrinsics
extern(C)
{
    double sqrt(double x);
    double fabs(double x);
    double sin(double x);
    double cos(double x);
    double exp(double x);
    double log(double x);
    double acos(double x);
}


pragma(inline, true)
bool addc(T = uint)(T a, T b, out T r, bool c_in)
{
    static assert(is(T == uint) || is(T == ulong), "Only uint or ulong!");
    version (LDC)
    {
        version (Intel)
        {
            version (X86)
                enum X86Hack = is(T == ulong);
            else
                enum X86Hack = false;
            static if (X86Hack)
            {
                auto cr1 = _x86_addcarry(c_in, cast(uint)a, cast(uint)b);
                auto cr2 = _x86_addcarry(cr1.c, uint(a >> 32), uint(b >> 32));
                r = (ulong(cr2.r) << 32) | cr1.r;
                return cr2.c != 0;
            }
            else
            {
                auto cr = _x86_addcarry(c_in, a, b);
                r = cr.r;
                return cr.c != 0;
            }
        }
        else
        {
            auto r1 = _llvm_add_overflow(a, b);
            auto r2 = _llvm_add_overflow(r1.r, c_in);
            r = r2.r;
            return r1.c || r2.c;
        }
    }
    else version (GNU)
    {
        T c = c_in;
        static if (is(T == uint))
            r = __builtin_addc(a, b, c, &c);
        else
            r = __builtin_addcll(a, b, c, &c);
        return c != 0;
    }
    else
    {
        T t = b + c_in;
        r = a + t;
        return (t < c_in) | (r < t);
    }
}
pragma(inline, true)
bool addc(T = uint)(T a, T b, out T r)
{
    static assert(is(T == uint) || is(T == ulong), "Only uint or ulong!");
    version (LDC)
    {
        auto t = _llvm_add_overflow(a, b);
        r = t.r;
        return t.c != 0;
    }
    else version (GNU)
    {
        T c;
        static if (is(T == uint))
            r = __builtin_addc(a, b, 0, &c);
        else
            r = __builtin_addcll(a, b, 0, &c);
        return c != 0;
    }
    else
    {
        r = a + b;
        return r < b;
    }
}

unittest
{
    uint u32;
    bool c;

    // No carry in, no carry out
    c = addc(10u, 20u, u32); assert(!c && u32 == 30u);
    c = addc(10u, 20u, u32, false); assert(!c && u32 == 30u);

    // Carry in, no carry out
    c = addc(10u, 20u, u32, true); assert(!c && u32 == 31u);

    // No carry in, carry out
    c = addc(uint.max, 1u, u32); assert(c && u32 == 0u);
    c = addc(uint.max, 1u, u32, false); assert(c && u32 == 0u);
    c = addc(uint.max - 5u, 10u, u32); assert(c && u32 == 4u);
    c = addc(uint.max - 5u, 10u, u32, false); assert(c && u32 == 4u);

    // Carry in, carry out
    c = addc(uint.max, 0u, u32, true); assert(c && u32 == 0u);
    c = addc(uint.max, 1u, u32, true); assert(c && u32 == 1u);
    c = addc(uint.max - 5u, 10u, u32, true); assert(c && u32 == 5u);

    ulong u64;

    // No carry in, no carry out
    c = addc(10UL, 20UL, u64); assert(!c && u64 == 30UL);
    c = addc(10UL, 20UL, u64, false); assert(!c && u64 == 30UL);

    // Carry in, no carry out
    c = addc(10UL, 20UL, u64, true); assert(!c && u64 == 31UL);

    // No carry in, carry out
    c = addc(ulong.max, 1UL, u64); assert(c && u64 == 0UL);
    c = addc(ulong.max, 1UL, u64, false); assert(c && u64 == 0UL);
    c = addc(ulong.max - 5UL, 10UL, u64); assert(c && u64 == 4UL);
    c = addc(ulong.max - 5UL, 10UL, u64, false); assert(c && u64 == 4UL);

    // Carry in, carry out
    c = addc(ulong.max, 0UL, u64, true); assert(c && u64 == 0UL);
    c = addc(ulong.max, 1UL, u64, true); assert(c && u64 == 1UL);
    c = addc(ulong.max - 5UL, 10UL, u64, true); assert(c && u64 == 5UL);
}


pragma(inline, true)
bool subb(T)(T a, T b, out T r, bool c_in)
{
    static assert(is(T == uint) || is(T == ulong), "Only uint or ulong!");
    version (LDC)
    {
        version (Intel)
        {
            version (X86)
                enum X86Hack = is(T == ulong);
            else
                enum X86Hack = false;
            static if (X86Hack)
            {
                auto cr1 = _x86_subborrow(c_in, cast(uint)a, cast(uint)b);
                auto cr2 = _x86_subborrow(cr1.c, uint(a >> 32), uint(b >> 32));
                r = (ulong(cr2.r) << 32) | cr1.r;
                return cr2.c != 0;
            }
            else
            {
                auto cr = _x86_subborrow(c_in, a, b);
                r = cr.r;
                return cr.c != 0;
            }
        }
        else
        {
            auto r1 = _llvm_sub_overflow(a, b);
            auto r2 = _llvm_sub_overflow(r1.r, c_in);
            r = r2.r;
            return r1.c | r2.c;
        }
    }
    else version (GNU)
    {
        T c = c_in;
        static if (is(T == uint))
            r = __builtin_subc(a, b, c, &c);
        else
            r = __builtin_subcll(a, b, c, &c);
        return c != 0;
    }
    else
    {
        T t = a - b;
        r = t - c_in;
        return (a < b) | (t < c_in);
    }
}
pragma(inline, true)
bool subb(T)(T a, T b, out T r)
{
    static assert(is(T == uint) || is(T == ulong), "Only uint or ulong!");
    version (LDC)
    {
        auto t = _llvm_sub_overflow(a, b);
        r = t.r;
        return t.c != 0;
    }
    else version (GNU)
    {
        T c;
        static if (is(T == uint))
            r = __builtin_subc(a, b, 0, &c);
        else
            r = __builtin_subcll(a, b, 0, &c);
        return c != 0;
    }
    else
    {
        r = a - b;
        return a < b;
    }
}

unittest
{
    uint u32;
    bool c; // Borrow out

    // No borrow in, no borrow out
    c = subb(30u, 10u, u32); assert(!c && u32 == 20u);
    c = subb(30u, 10u, u32, false); assert(!c && u32 == 20u);

    // Borrow in, no borrow out
    c = subb(30u, 10u, u32, true); assert(!c && u32 == 19u);

    // No borrow in, borrow out
    c = subb(10u, 20u, u32); assert(c && u32 == uint.max - 9u);
    c = subb(10u, 20u, u32, false); assert(c && u32 == uint.max - 9u);
    c = subb(0u, 1u, u32); assert(c && u32 == uint.max);
    c = subb(0u, 1u, u32, false); assert(c && u32 == uint.max);

    // Borrow in, borrow out
    c = subb(10u, 10u, u32, true); assert(c && u32 == uint.max);
    c = subb(10u, 20u, u32, true); assert(c && u32 == uint.max - 10u);
    c = subb(0u, 0u, u32, true); assert(c && u32 == uint.max);
    c = subb(0u, 1u, u32, true); assert(c && u32 == uint.max - 1u);

    ulong u64;

    // No borrow in, no borrow out
    c = subb(30UL, 10UL, u64); assert(!c && u64 == 20UL);
    c = subb(30UL, 10UL, u64, false); assert(!c && u64 == 20UL);

    // Borrow in, no borrow out
    c = subb(30UL, 10UL, u64, true); assert(!c && u64 == 19UL);

    // No borrow in, borrow out
    c = subb(10UL, 20UL, u64); assert(c && u64 == ulong.max - 9UL);
    c = subb(10UL, 20UL, u64, false); assert(c && u64 == ulong.max - 9UL);
    c = subb(0UL, 1UL, u64); assert(c && u64 == ulong.max);
    c = subb(0UL, 1UL, u64, false); assert(c && u64 == ulong.max);

    // Borrow in, borrow out
    c = subb(10UL, 10UL, u64, true); assert(c && u64 == ulong.max);
    c = subb(10UL, 20UL, u64, true); assert(c && u64 == ulong.max - 10UL);
    c = subb(0UL, 0UL, u64, true); assert(c && u64 == ulong.max);
    c = subb(0UL, 1UL, u64, true); assert(c && u64 == ulong.max - 1UL);
}


pragma(inline, true)
ulong mul32to64(uint a, uint b)
{
    return cast(ulong)a * b;
}
pragma(inline, true)
long mul32to64(int a, int b)
{
    return cast(long)a * b;
}
pragma(inline, true)
long mul32to64(uint a, int b)
{
    version (LDC_X86)
    {
        ulong r = __asm!(ulong)("mul $1", "=A,r,{eax},~{flags}", uint(b), a);
        r -= ulong(a & (b >> 31)) << 32;
        return r;
    }
    else version (GDC_X86)
    {
        uint hi = void, lo = void;
        asm pure nothrow @nogc {
            "mul     %3;"
            : "=a"(lo), "=d"(hi)
            : "a"(a), "r"(uint(b))
            : "cc";
        }
        hi -= a & (b >> 31);
        return ulong(hi) << 32 | lo;
    }
    else
        return cast(long)a * b;
}
pragma(inline, true)
long mul32to64(int a, uint b)
{
    version (GDC_OR_LDC_X86)
        return mul32to64(b, a);
    else
        return a * cast(long)b;
}

unittest
{
    // uint * uint -> ulong
    assert(mul32to64(10u, 20u) == 200UL);
    assert(mul32to64(uint.max, 2u) == 0x1_FFFF_FFFEUL);
    assert(mul32to64(uint.max, uint.max) == 0xFFFF_FFFE_0000_0001UL);
    assert(mul32to64(0u, uint.max) == 0UL);
    assert(mul32to64(uint.max, 0u) == 0UL);

    // int * int -> long
    assert(mul32to64(10, 20) == 200L);
    assert(mul32to64(-10, 20) == -200L);
    assert(mul32to64(10, -20) == -200L);
    assert(mul32to64(-10, -20) == 200L);
    assert(mul32to64(int.max, 2) == 0xFFFFFFFE); // Stays within 32 bits
    assert(mul32to64(int.max, int.max) == 0x3FFF_FFFF_0000_0001L);
    assert(mul32to64(int.min, int.min) == 0x4000_0000_0000_0000L); // (-2^31)^2 = 2^62
    assert(mul32to64(int.min, -1) == 0x8000_0000L); // Becomes positive, but needs 33 bits, overflows long
    assert(mul32to64(int.max, -1) == -int.max);
    assert(mul32to64(0, int.max) == 0L);
    assert(mul32to64(int.min, 0) == 0L);

    // uint * int -> long
    assert(mul32to64(10u, 20) == 200L);
    assert(mul32to64(10u, -20) == -200L);
    assert(mul32to64(uint.max, 1) == uint.max);
    assert(mul32to64(uint.max, -1) == -cast(long)uint.max); // -(2^32-1)
    assert(mul32to64(uint.max, int.min) == 0x8000_0000_8000_0000L); // (2^32-1) * (-2^31) = -2^63 + 2^31
    assert(mul32to64(0u, int.min) == 0L);
    assert(mul32to64(uint.max, 0) == 0L);

    // int * uint -> long
    assert(mul32to64(10, 20u) == 200L);
    assert(mul32to64(-10, 20u) == -200L);
    assert(mul32to64(1, uint.max) == uint.max);
    assert(mul32to64(-1, uint.max) == -cast(long)uint.max);
    assert(mul32to64(int.min, uint.max) == 0x8000_0000_8000_0000L);
    assert(mul32to64(int.min, 0u) == 0L);
    assert(mul32to64(0, uint.max) == 0L);
}


ulong[2] mul64to128(ulong a, ulong b)
{
    version (DMD_X86_64)
    {
        version (Windows)
        {
            asm pure nothrow @nogc
            {
                naked;
                mov RAX, RDX;
                mul RCX;
                ret;
            }
        }
        else
        {
            asm pure nothrow @nogc
            {
                naked;
                mov RAX, RSI;
                mul RDI;
                ret;
            }
        }
    }
    else version (LDC)
    {
        ulong[2] r = void;
        __ir_pure!(
                   "%a = load i64, ptr %0, align 8\n" ~
                   "%ax = zext i64 %a to i128 \n" ~
                   "%b = load i64, ptr %1, align 8\n" ~
                   "%bx = zext i64 %b to i128\n" ~
                   "%r = mul i128 %ax, %bx\n" ~
                   "store i128 %r, ptr %2, align 8\n", void)(&a, &b, &r);
        return r;
    }
    else
    {
        ulong[2] r = void;
        r[0] = mul32to64(cast(uint)a, cast(uint)b);
        r[1] = mul32to64(uint(a >> 32), uint(b >> 32));
        ulong t0 = mul32to64(uint(a >> 32), cast(uint)b);
        ulong t1 = mul32to64(cast(uint)a, uint(b >> 32));
        ulong t;
        bool c1 = addc(t0, t1, t);
        ulong lh = t << 32;
        ulong hl = t >> 32;
        bool c2 = addc(r[0], lh, r[0]);
        addc(r[1], hl, r[1], c2);
        r[1] += ulong(c1) << 32;
        return r;
    }
}
ulong[2] mul64to128(long a, long b)
{
    assert(false, "TODO");
}
ulong[2] mul64to128(long a, ulong b)
{
    assert(false, "TODO");
}
pragma(inline, true)
ulong[2] mul64to128(ulong a, long b)
    => mul64to128(b, a);

unittest
{
    ulong[2] r128;

    // Simple cases
    r128 = mul64to128(0UL, 0UL); assert(r128 == [0UL, 0UL]);
    r128 = mul64to128(1UL, 0UL); assert(r128 == [0UL, 0UL]);
    r128 = mul64to128(0UL, 1UL); assert(r128 == [0UL, 0UL]);
    r128 = mul64to128(1UL, 1UL); assert(r128 == [1UL, 0UL]);
    r128 = mul64to128(10UL, 20UL); assert(r128 == [200UL, 0UL]);

    // Cases involving carry between 32-bit halves (if using the fallback implementation)
    r128 = mul64to128(0x1_0000_0000UL, 2UL); assert(r128 == [0x2_0000_0000UL, 0UL]);
    r128 = mul64to128(0xFFFF_FFFFUL, 0xFFFF_FFFFUL); assert(r128 == [0xFFFF_FFFE_0000_0001UL, 0UL]); // (2^32-1)^2

    // Cases resulting in a non-zero high word
    r128 = mul64to128(0x1_0000_0000UL, 0x1_0000_0000UL); assert(r128 == [0UL, 1UL]); // 2^32 * 2^32 = 2^64
    r128 = mul64to128(ulong.max, 2UL); assert(r128 == [ulong.max - 1, 1UL]); // (2^64-1)*2 = 2^65 - 2
    r128 = mul64to128(ulong.max, ulong.max); assert(r128 == [1UL, ulong.max - 1UL]); // (2^64-1)^2 = 2^128 - 2*2^64 + 1

    // Test with specific values
    ulong a = 0x12345678_9ABCDEF0UL;
    ulong b = 0xFEDCBA98_76543210UL;
    r128 = mul64to128(a, b);
    assert(r128[0] == 0x236d88fe5618cf00UL);
    assert(r128[1] == 0x121fa00ad77d7422UL);
}


uint divrem2x1(uint[2] a, uint b, out uint rem)
{
    assert(b != 0, "Division by zero");
    assert(a[1] < b, "Quotient overflow");
    version (DigitalMars)
    {
        uint hi = a[1], lo = a[0];
        uint q = void, r = void;
        asm pure nothrow @nogc
        {
            mov EDX, hi;
            mov EAX, lo;
            div b;
            mov r, EDX;
            mov q, EAX;
        }
        rem = r;
        return q;
    }
    else version (GDC_OR_LDC_Intel)
    {
        uint q = void;
        asm pure nothrow @nogc
        {
            "div     %4;"
            : "=a"(q), "=d"(rem)
            : "a"(a[0]), "d"(a[1]), "r"(b);
        }
        return q;
    }
    else static if (size_t.sizeof == 8)
    {
        ulong t = a[0] | (cast(ulong)a[1] << 32);
        if (t < b)
        {
            rem = cast(uint)t;
            return 0;
        }
        rem = cast(uint)(t % b);
        return cast(uint)(t / b);
    }
    else
        return _divrem2x1_impl!uint(a, b, rem);
}

ulong divrem2x1(ulong[2] a, ulong b, out ulong rem)
{
    assert(b != 0, "Division by zero");
    assert(a[1] < b, "Quotient overflow");
    version (DMD_X86_64)
    {
        ulong hi = a[1], lo = a[0];
        ulong q = void, r = void;
        asm pure nothrow @nogc
        {
            mov RDX, hi;
            mov RAX, lo;
            div b;
            mov r, RDX;
            mov q, RAX;
        }
        rem = r;
        return q;
    }
    else version (GDC_OR_LDC_X86_64)
    {
        ulong q = void;
        asm pure nothrow @nogc
        {
            "div     %4;"
            : "=a"(q), "=d"(rem)
            : "a"(a[0]), "d"(a[1]), "r"(b); // Inputs: low(rax), high(rdx), divisor(r)
        }
        return q;
    }
    else
        return _divrem2x1_impl!ulong(a, b, rem);
}

// fallback implementations...
private T _divrem2x1_impl(T)(T[2] a, T b, out T rem)
    if (is(T == uint) || is(T == ulong))
{
    debug assert(a[1] < b, "Quotient overflow");

    // this was already handled in the `uint` calling function...
    static if (is(T == ulong))
    {
        if (a[1] == 0)
        {
            if (a[0] < b)
            {
                rem = a[0];
                return 0;
            }
            rem = a[0] % b;
            return a[0] / b;
        }
    }

    static if (is(T == uint))
    {
        static assert(false, "TODO!");
    }
    else
    {
        // !!! THIS IS EFFICIENT FOR 32-BIT MACHINES !!!
        // A 64BIT OPTIMISED IMPLEMENTATION SHOULD BE POSSIBLE....

        import urt.util : clz;

        ulong qhat;  // A quotient.
        ulong rhat;  // A remainder.
        ulong uhat;  // A dividend digit pair.
        uint q0, q1; // Quotient digits.
        uint s;      // Shift amount for norm.

        s = clz(b);  // 0 <= s <= 63.
        if (s != 0U)
        {
            b <<= s;    // Normalize divisor.
            a[1] <<= s; // Shift dividend left.
            a[1] |= a[0] >> (64U - s);
            a[0] <<= s;
        }

        // Compute high quotient digit.
        qhat = a[1] / uint(b >> 32);
        rhat = a[1] % uint(b >> 32);

        while (cast(uint) (qhat >> 32) != 0U ||
                // Both qhat and rhat are less 2^^32 here!
                cast(ulong) cast(uint) (qhat & ~0U) * cast(uint) (b & ~0U) >
                ((rhat << 32) | uint(a[0] >> 32)))
        {
            qhat -= 1U;
            rhat += uint(b >> 32);
            if (uint(rhat >> 32) != 0U)
                break;
        }

        q1 = cast(uint) (qhat & ~0U);
        // Multiply and subtract.
        uhat = ((a[1] << 32) | uint(a[0] >> 32)) - q1 * b;

        // Compute low quotient digit.
        qhat = uhat / uint(b >> 32);
        rhat = uhat % uint(b >> 32);

        while (uint(qhat >> 32) != 0U ||
                // Both qhat and rhat are less 2^^32 here!
                cast(ulong) cast(uint) (qhat & ~0U) * cast(uint) (b & ~0U) >
                ((rhat << 32) | cast(uint) (a[0] & ~0U)))
        {
            qhat -= 1U;
            rhat += cast(uint) (b >> 32);
            if (uint(rhat >> 32) != 0U)
                break;
        }

        q0 = cast(uint) (qhat & ~0U);
        rem = (((uhat << 32) | cast(uint) (a[0] & ~0U)) - q0 * b) >> s;
        return (cast(ulong) q1 << 32) | q0;
    }
}

unittest
{
    uint q32, r32;
    uint[2] a32;

    // Basic test
    a32 = [10, 0]; // 10
    q32 = divrem2x1(a32, 3, r32);
    assert(q32 == 3 && r32 == 1);

    // Larger dividend (fits in lower word)
    a32 = [0xFFFFFFFF, 0]; // 2^32 - 1
    q32 = divrem2x1(a32, 3, r32);
    assert(q32 == 0x55555555 && r32 == 0);

    // Dividend uses high word
    a32 = [0, 1]; // 2^32
    q32 = divrem2x1(a32, 3, r32);
    assert(q32 == 0x55555555 && r32 == 1); // (2^32)/3 = 1431655765 rem 1

    a32 = [2, 1]; // 2^32 + 2
    q32 = divrem2x1(a32, 3, r32);
    assert(q32 == 0x55555556 && r32 == 0); // (2^32+2)/3 = 1431655766 rem 0

    // TODO: TEST QUOTIENT OVERFLOW ASSERT?
    // Max dividend / small divisor
//    a32 = [uint.max, uint.max >> 1]; // (2^63 - 1) approx
//    q32 = divrem2x1(a32, 2, r32);
    // Expected q = (2^64 - 1) / 2 = 2^63 - 1 / 2 -> floor is 2^63 - 1
    // Expected r = 1
    // This should overflow the uint quotient! Test the assert.
    // assert(q32 == uint.max && r32 == 1); // This test depends on overflow check

    // Max dividend / max divisor
    a32 = [uint.max, uint.max - 1]; // Dividend slightly less than 2^64
    q32 = divrem2x1(a32, uint.max, r32);
    assert(q32 == uint.max && r32 == uint.max - 1); // q = floor((U-1)*B + U-1 / (U-1)) = B
                                                    // r = (U-1)*B + U-1 % (U-1) = 0 + U-1 = U-1

    ulong q64, r64;
    ulong[2] a64;

    // Basic test
    a64 = [10, 0]; // 10
    q64 = divrem2x1(a64, 3, r64);
    assert(q64 == 3 && r64 == 1);

    // Larger dividend (fits in lower word)
    a64 = [ulong.max, 0]; // 2^64 - 1
    q64 = divrem2x1(a64, 3, r64);
    assert(q64 == 0x5555555555555555 && r64 == 0);

    // Dividend uses high word
    a64 = [0, 1]; // 2^64
    q64 = divrem2x1(a64, 3, r64);
    assert(q64 == 0x5555555555555555 && r64 == 1);

    a64 = [2, 1]; // 2^64 + 2
    q64 = divrem2x1(a64, 3, r64);
    assert(q64 == 0x5555555555555556 && r64 == 0);

    // TODO: TEST QUOTIENT OVERFLOW ASSERT?
    // Max dividend / small divisor
//    a64 = [ulong.max, ulong.max >> 1]; // (2^127 - 1) approx
//    q64 = divrem2x1(a64, 2, r64);
    // Expected q = (2^128 - 1) / 2 = 2^127 - 1/2 -> floor is 2^127 - 1
    // Expected r = 1
    // This should overflow the ulong quotient! Test the assert.
    // assert(q64 == ulong.max && r64 == 1); // This test depends on overflow check

    // Max dividend / max divisor
    a64 = [ulong.max, ulong.max - 1]; // Dividend slightly less than 2^128
    q64 = divrem2x1(a64, ulong.max, r64);
    assert(q64 == ulong.max && r64 == ulong.max - 1);
}
