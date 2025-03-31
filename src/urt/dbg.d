module urt.dbg;

import urt.compiler;

version (X86_64)
    version = Intel;
else version (X86)
    version = Intel;

version (Intel)
{
    version (DigitalMars)
    {
//        pragma(inline, true) // DMD can't inline an asm function for some reason!
        extern(C) void breakpoint() pure nothrow @nogc
        {
            debug asm pure nothrow @nogc
            {
                int 3;
                ret;
            }
        }
    }
    else
    {
        pragma(inline, true)
        extern(C) void breakpoint() pure nothrow @nogc
        {
            debug asm pure nothrow @nogc
            {
                "int $3";
            }
        }
    }
}
else version (AArch64)
{
    pragma(inline, true)
    extern(C) void breakpoint() pure nothrow @nogc
    {
        debug asm pure nothrow @nogc
        {
            "brk #0";
        }
    }
}
else version (ARM)
{
    pragma(inline, true)
    extern(C) void breakpoint() pure nothrow @nogc
    {
        debug asm pure nothrow @nogc
        {
            "bkpt #0";
        }
    }
}
else
    static assert(0, "TODO: Unsupported architecture");


private:

package(urt) void setupAssertHandler()
{
    import core.exception : assertHandler;
    assertHandler = &urt_assert;
}

void urt_assert(string file, size_t line, string msg) nothrow @nogc
{
    import core.stdc.stdlib : exit;

    debug
    {
        import core.stdc.stdio;

        if (msg.length == 0)
            msg = "Assertion failed";

        version (Windows)
        {
            import core.sys.windows.winbase;
            char[1024] buffer;
            _snprintf(buffer.ptr, buffer.length, "%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
            OutputDebugStringA(buffer.ptr);

            // Windows can have it at stdout aswell?
            printf("%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
        }
        else
        {
            // TODO: write to stderr would be better...
            printf("%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
        }

        breakpoint();
//        exit(-1); // TODO: what if some systems don't support a software breakpoint?
    }
    else
        exit(-1);
}
