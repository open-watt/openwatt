module urt;

// maybe we should delete this, but a global import with the tool stuff is kinda handy...


// Enable this to get extra but possibly slow debug info
version = ExtraDebug;


// Different arch may define this differently...
// question is; is it worth a branch to avoid a redundant store?
enum bool BranchMoreExpensiveThanStore = false;


// I reckon this stuff should always be available...
// ...but we really need to keep these guys under control!
public import urt.compiler;
public import urt.meta;
public import urt.platform;
public import urt.processor;
public import urt.traits;
public import urt.util;


pragma(crt_constructor)
void crt_bootup()
{
    import urt.time : initClock;
    initClock();

    import urt.dbg : setupAssertHandler;
    setupAssertHandler();

    import urt.string.string : initStringAllocators;
    initStringAllocators();
}
