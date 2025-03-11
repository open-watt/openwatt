module urt.compiler;

version (LDC)
    public import ldc.attributes;
else version (GDC)
    static assert(false, "TODO: how to do naked functions, other intrinsics in GDC?");
