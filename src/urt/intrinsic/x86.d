module urt.intrinsic.x86;

pure nothrow @nogc:

version (LDC)
{
    struct CR32 { ubyte c; uint r; }
    struct CR64 { ubyte c; ulong r; }

    pragma(LDC_intrinsic, "llvm.x86.addcarry.32")
    CR32 _x86_addcarry(ubyte c_in, uint a, uint b) @safe;
    pragma(LDC_intrinsic, "llvm.x86.addcarry.64")
    CR64 _x86_addcarry(ubyte c_in, ulong a, ulong b) @safe;

    pragma(LDC_intrinsic, "llvm.x86.subborrow.32")
    CR32 _x86_subborrow(ubyte c_in, uint a, uint b) @safe;
    pragma(LDC_intrinsic, "llvm.x86.subborrow.64")
    CR64 _x86_subborrow(ubyte c_in, ulong a, ulong b) @safe;
}
