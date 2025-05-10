module urt.meta;


alias Alias(alias a) = a;
alias Alias(T) = T;

alias AliasSeq(TList...) = TList;

template intForWidth(size_t width, bool signed = false)
{
    static if (width <= 8 && !signed)
        alias intForWidth = ubyte;
    else static if (width <= 8 && signed)
        alias intForWidth = byte;
    else static if (width <= 16 && !signed)
        alias intForWidth = ushort;
    else static if (width <= 16 && signed)
        alias intForWidth = short;
    else static if (width <= 32 && !signed)
        alias intForWidth = uint;
    else static if (width <= 32 && signed)
        alias intForWidth = int;
    else static if (width <= 64 && !signed)
        alias intForWidth = ulong;
    else static if (width <= 64 && signed)
        alias intForWidth = long;
}

template staticMap(alias fun, args...)
{
    alias staticMap = AliasSeq!();
    static foreach (arg; args)
        staticMap = AliasSeq!(staticMap, fun!arg);
}

template staticIndexOf(args...)
    if (args.length >= 1)
{
    enum staticIndexOf = {
        static foreach (idx, arg; args[1 .. $])
            static if (isSame!(args[0], arg))
                // `if (__ctfe)` is redundant here but avoids the "Unreachable code" warning.
                if (__ctfe) return idx;
        return -1;
    }();
}

template InterleaveSeparator(alias sep, Args...)
{
    alias InterleaveSeparator = AliasSeq!();
    static foreach (i, A; Args)
        static if (i > 0)
            InterleaveSeparator = AliasSeq!(InterleaveSeparator, sep, A);
        else
            InterleaveSeparator = AliasSeq!(A);
}


template EnumKeys(E)
{
    static assert(is(E == enum), "EnumKeys only works with enums!");
    __gshared immutable string[EnumStrings.length] EnumKeys = [ EnumStrings ];
    private alias EnumStrings = __traits(allMembers, E);
}

E enumFromString(E)(const(char)[] key)
if (is(E == enum))
{
    foreach (i, k; EnumKeys!E)
        if (key[] == k[])
            return cast(E)i;
    return cast(E)-1;
}


private:

template isSame(alias a, alias b)
{
    static if (!is(typeof(&a && &b)) // at least one is an rvalue
               && __traits(compiles, { enum isSame = a == b; })) // c-t comparable
        enum isSame = a == b;
    else
        enum isSame = __traits(isSame, a, b);
}
// TODO: remove after https://github.com/dlang/dmd/pull/11320 and https://issues.dlang.org/show_bug.cgi?id=21889 are fixed
template isSame(A, B)
{
    enum isSame = is(A == B);
}
