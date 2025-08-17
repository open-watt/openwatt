module urt.system;

import urt.platform;
import urt.processor;
import urt.time;

nothrow @nogc:


enum IdleParams : ubyte
{
    SystemRequired = 1,     // stop the system from going to sleep
    DisplayRequired = 2,    // keep the display turned on
}

extern(C) noreturn abort();
extern(C) noreturn exit(int status);

void sleep(Duration duration)
{
//    enum Duration spinThreshold = 10.msecs;
//    if (duration < spinThreshold)
//    {
//        // spin lock...
//    }

    version (Windows)
    {
        import core.sys.windows.winbase : Sleep;
        Sleep(cast(uint)duration.as!"msecs");
    }
    else
    {
        // TODO: use nanosleep; usleep is deprecated!

        usleep(cast(uint)duration.as!"usecs");
    }
}

struct SystemInfo
{
    string osName;
    string processor;
    ulong totalMemory;
    ulong availableMemory;
    Duration uptime;
}

SystemInfo getSysInfo()
{
    SystemInfo r;
    r.osName = Platform;
    r.processor = ProcessorFamily;
    version (Windows)
    {
        MEMORYSTATUSEX mem;
        mem.dwLength = MEMORYSTATUSEX.sizeof;
        if (GlobalMemoryStatusEx(&mem))
        {
            r.totalMemory = mem.ullTotalPhys;
            r.availableMemory = mem.ullAvailPhys;
        }
        r.uptime = msecs(GetTickCount64());
    }
    else version (linux)
    {
        import core.sys.linux.sys.sysinfo;

        sysinfo_ info;
        if (sysinfo(&info) < 0)
            assert(false, "sysinfo() failed!");

        r.totalMemory = cast(ulong)info.totalram * info.mem_unit;
        r.availableMemory = cast(ulong)info.freeram * info.mem_unit;
        r.uptime = seconds(info.uptime);
    }
    else version (Posix)
    {
        import core.sys.posix.unistd;

        int pages = sysconf(_SC_PHYS_PAGES);
        int page_size = sysconf(_SC_PAGE_SIZE);

        assert(pages >= 0 && page_size >= 0, "sysconf() failed!");

        r.totalMemory = cast(ulong)pages * page_size;
        static assert(false, "TODO: need `availableMemory`");
    }
    return r;
}

void setSystemIdleParams(IdleParams params)
{
    version (Windows)
    {
        import core.sys.windows.winbase;

        enum EXECUTION_STATE ES_SYSTEM_REQUIRED = 0x00000001;
        enum EXECUTION_STATE ES_DISPLAY_REQUIRED = 0x00000002;
        enum EXECUTION_STATE ES_CONTINUOUS = 0x80000000;

        SetThreadExecutionState(ES_CONTINUOUS | (params.SystemRequired ? ES_SYSTEM_REQUIRED : 0) | (params.DisplayRequired ? ES_DISPLAY_REQUIRED : 0));
    }
    else version (Posix)
    {
        // TODO: ...we're not likely to run on a POSIX desktop system any time soon...
    }
    else
        static assert(0, "Not implemented");
}


unittest
{
    SystemInfo info = getSysInfo();
    assert(info.uptime > Duration.zero);

    import urt.io;
    writelnf("System info: {0} - {1}, mem: {2}kb ({3}kb)", info.osName, info.processor, info.totalMemory / (1024), info.availableMemory / (1024));
}


package:

version (Windows)
{
    import core.sys.windows.winbase : GlobalMemoryStatusEx, MEMORYSTATUSEX;

    extern(Windows) ulong GetTickCount64();

    alias _EXCEPTION_REGISTRATION_RECORD = void;
    struct NT_TIB
    {
        _EXCEPTION_REGISTRATION_RECORD* ExceptionList;
        void* StackBase;
        void* StackLimit;
        void* SubSystemTib;
        void* FiberData;
        void* ArbitraryUserPointer;
        NT_TIB* Self;
    }

    version (X86_64)
    {
        extern(C) ubyte __readgsbyte(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, GS:[ECX];
                ret;
            }
        }
        extern(C) ushort __readgsword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, GS:[ECX];
                ret;
            }
        }
        extern(C) uint __readgsdword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, GS:[ECX];
                ret;
            }
        }
        extern(C) ulong __readgsqword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov RAX, GS:[ECX];
                ret;
            }
        }

        extern(C) void __writegsbyte(uint Offset, ubyte Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], DL;
                ret;
            }
        }
        extern(C) void __writegsword(uint Offset, ushort Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], DX;
                ret;
            }
        }
        extern(C) void __writegsdword(uint Offset, uint Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], EDX;
                ret;
            }
        }
        extern(C) void __writegsqword(uint Offset, ulong Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], RDX;
                ret;
            }
        }
    }
    else version (X86)
    {
        extern(C) ubyte __readfsbyte(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov AL, FS:[EAX];
                ret;
            }
        }
        extern(C) ushort __readfsword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov AX, FS:[EAX];
                ret;
            }
        }
        extern(C) uint __readfsdword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EAX, FS:[EAX];
                ret;
            }
        }

        extern(C) void __writefsbyte(uint Offset, ubyte Data) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EDX, [ESP + 8];
                mov FS:[EAX], DL;
                ret;
            }
        }
        extern(C) void __writefsword(uint Offset, ushort Data) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EDX, [ESP + 8];
                mov FS:[EAX], DX;
                ret;
            }
        }
        extern(C) void __writefsdword(uint Offset, uint Data) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EDX, [ESP + 8];
                mov FS:[EAX], EDX;
                ret;
            }
        }
    }
    else
        static assert(0, "TODO");
}
else
{
    extern(C) int usleep(uint usec) nothrow @nogc;
}
