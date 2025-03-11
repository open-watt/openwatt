module urt;

// maybe we should delete this, but a global import with the tool stuff is kinda handy...

// This enabled the use of move semantics in new compilers
//version = EnableMoveSemantics;

// Enable this to get extra but possibly slow debug info
version = ExtraDebug;

// I reckon this stuff should always be available...
// ...but we really need to keep these guys under control!
public import urt.compiler;
public import urt.platform;
public import urt.processor;
public import urt.meta : Alias, AliasSeq;
public import urt.util : min, max, swap;

private:

pragma(crt_constructor)
void crt_bootup()
{
    import urt.time : initClock;
    initClock();

    import urt.rand;
    initRand();

    import urt.dbg : setupAssertHandler;
    setupAssertHandler();

    import urt.string.string : initStringAllocators;
    initStringAllocators();
}
