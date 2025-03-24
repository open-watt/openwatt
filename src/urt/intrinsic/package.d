module urt.intrinsic;

import urt.compiler;
import urt.platform;
import urt.processor;

nothrow @nogc:

version (GNU)
    public import gcc.builtins;

version (LDC)
{
    public import ldc.llvmasm;

    struct RO32 { uint r; bool c; }
    struct RO64 { ulong r; bool c; }

    pragma(LDC_intrinsic, "llvm.uadd.with.overflow.i32")
    RO32 _llvm_add_overflow(uint, uint) pure @safe;
    pragma(LDC_intrinsic, "llvm.uadd.with.overflow.i64")
    RO64 _llvm_add_overflow(ulong, ulong) pure @safe;

    pragma(LDC_intrinsic, "llvm.usub.with.overflow.i32")
    RO32 _llvm_sub_overflow(uint, uint) pure @safe;
    pragma(LDC_intrinsic, "llvm.usub.with.overflow.i64")
    RO64 _llvm_sub_overflow(ulong, ulong) pure @safe;

    pragma(LDC_intrinsic, "llvm.bswap.i16")
    ushort __builtin_bswap16(ushort) pure @safe;
    pragma(LDC_intrinsic, "llvm.bswap.i32")
    uint __builtin_bswap32(uint) pure @safe;
    pragma(LDC_intrinsic, "llvm.bswap.i64")
    ulong __builtin_bswap64(ulong) pure @safe;

    pragma(LDC_intrinsic, "llvm.bitreverse.i8")
    ubyte _llvm_bitreverse(ubyte) pure @safe;
    pragma(LDC_intrinsic, "llvm.bitreverse.i16")
    ushort _llvm_bitreverse(ushort) pure @safe;
    pragma(LDC_intrinsic, "llvm.bitreverse.i32")
    uint _llvm_bitreverse(uint) pure @safe;
    pragma(LDC_intrinsic, "llvm.bitreverse.i64")
    ulong _llvm_bitreverse(ulong) pure @safe;

    pragma(LDC_intrinsic, "llvm.ctlz.i8")
    ubyte _llvm_ctlz(ubyte, bool) pure @safe;
    pragma(LDC_intrinsic, "llvm.ctlz.i16")
    ushort _llvm_ctlz(ushort, bool) pure @safe;
    pragma(LDC_intrinsic, "llvm.ctlz.i32")
    uint _llvm_ctlz(uint, bool) pure @safe;
    pragma(LDC_intrinsic, "llvm.ctlz.i64")
    ulong _llvm_ctlz(ulong, bool) pure @safe;
    pragma(LDC_intrinsic, "llvm.cttz.i8")
    ubyte _llvm_cttz(ubyte, bool) pure @safe;
    pragma(LDC_intrinsic, "llvm.cttz.i16")
    ushort _llvm_cttz(ushort, bool) pure @safe;
    pragma(LDC_intrinsic, "llvm.cttz.i32")
    uint _llvm_cttz(uint, bool) pure @safe;
    pragma(LDC_intrinsic, "llvm.cttz.i64")
    ulong _llvm_cttz(ulong, bool) pure @safe;

    pragma(LDC_intrinsic, "llvm.ctpop.i8")
    ubyte _llvm_ctpop(ubyte) pure @safe;
    pragma(LDC_intrinsic, "llvm.ctpop.i16")
    ushort _llvm_ctpop(ushort) pure @safe;
    pragma(LDC_intrinsic, "llvm.ctpop.i32")
    uint _llvm_ctpop(uint) pure @safe;
    pragma(LDC_intrinsic, "llvm.ctpop.i64")
    ulong _llvm_ctpop(ulong) pure @safe;
}
