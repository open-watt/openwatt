module urt.compiler;

public import urt.attribute;

version (DigitalMars)
    enum IS_DMD = true;
else
    enum IS_DMD = false;

version (LDC)
{
    version = LDC_OR_GDC;

    enum IS_LDC = true;
}
else
    enum IS_LDC = false;

version (GNU)
{
    version = LDC_OR_GDC;

    static assert(false, "TODO: how to do naked functions, other intrinsics in GDC?");

    enum IS_GDC = true;
}
else
    enum IS_GDC = false;

version (LDC_OR_GDC)
    enum IS_LDC_OR_GDC = true;
else
    enum IS_LDC_OR_GDC = false;
