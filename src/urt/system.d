module urt.system;

import urt.platform;
import urt.processor;

nothrow @nogc:


enum IdleParams : ubyte
{
    SystemRequired = 1,     // stop the system from going to sleep
    DisplayRequired = 2,    // keep the display turned on
}

extern(C) void abort();
extern(C) void exit(int status);

struct SystemInfo
{
    string osName;
    string processor;
    ulong totalMemory;
    ulong availableMemory;
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
    else
        static assert(0, "Not implemented");
}


version (Windows)
{
    import core.sys.windows.winbase : GlobalMemoryStatusEx, MEMORYSTATUSEX;

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
