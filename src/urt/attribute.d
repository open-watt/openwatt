module urt.attribute;

version (GNU)
    public import gcc.attributes;
version (LDC)
    public import ldc.attributes;

version (DigitalMars)
{
    enum restrict;
    enum weak;
}
