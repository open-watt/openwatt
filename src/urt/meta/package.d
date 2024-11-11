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

template InterleaveSeparator(alias sep, Args...)
{
    alias InterleaveSeparator = AliasSeq!();
    static foreach (i, A; Args)
        static if (i > 0)
            InterleaveSeparator = AliasSeq!(InterleaveSeparator, sep, A);
        else
            InterleaveSeparator = AliasSeq!(A);
}
