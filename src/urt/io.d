module urt.io;

import core.stdc.stdio;


nothrow @nogc:

int write(const(char)[] str)
{
    return printf("%.*s", cast(int)str.length, str.ptr);
}
int writeln(const(char)[] str)
{
    return printf("%.*s\n", cast(int)str.length, str.ptr);
}

int write(Args...)(ref Args args)
    if (Args.length != 1 || !is(Args[0] : const(char)[]))
{
    import urt.string.format;
    import urt.mem.temp;

    size_t len = concat(null, args).length;
    const(char)[] t = concat(cast(char[])talloc(len), args);
    return write(t);
}

int writeln(Args...)(ref Args args)
    if (Args.length != 1 || !is(Args[0] : const(char)[]))
{
    import urt.string.format;
    import urt.mem.temp;

    return tconcat(args).writeln;
}

int writef(Args...)(const(char)[] fmt, ref Args args)
    if (Args.length > 0)
{
    import urt.string.format;
    import urt.mem.temp;

    size_t len = format(null, fmt, args).length;
    const(char)[] t = format(cast(char[])talloc(len), fmt, args);
    return write(t);
}

int writelnf(Args...)(const(char)[] fmt, ref Args args)
    if (Args.length > 0)
{
    import urt.string.format;
    import urt.mem.temp;

    size_t len = format(null, fmt, args).length;
    const(char)[] t = format(cast(char[])talloc(len), fmt, args);
    return writeln(t);
}

unittest
{
    writeln("Hello, World!");
    writeln("Hello", " World!");
    writelnf("Hello, World! {0}", "wow!");

    writeln();
    writeln(10u, " why count ", 20, '?');

    write("Hello there ");
    write("mister ", "robot ");
    writef("how do {0} do?\n", "you");
}
