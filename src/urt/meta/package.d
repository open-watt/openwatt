module urt.meta;


alias Alias(alias a) = a;
alias Alias(T) = T;

alias AliasSeq(TList...) = TList;

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
