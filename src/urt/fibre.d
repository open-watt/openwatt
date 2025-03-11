module urt.fibre;

import urt.mem;
import urt.system;
import urt.time;

version (Windows)
    version = UseWindowsFibreAPI;

@nogc:


extern(C++) class AwakenEvent
{
extern(D):
nothrow @nogc:
    abstract bool ready() { return true; }
    void update() {}
}


alias FibreEntryFunc = void function(void*) @nogc;
alias FibreEntryDelegate = void delegate() @nogc;
alias YieldHandler = void function(ref Fibre yielding, AwakenEvent awakenEvent) nothrow @nogc;

struct Fibre
{
nothrow @nogc:

    this() @disable;

    this(FibreEntryDelegate fibreEntry, YieldHandler yieldHandler, size_t stackSize = 16*1024)
    {
        this(cast(FibreEntryFunc)fibreEntry.funcptr, yieldHandler, fibreEntry.ptr, stackSize);
        isDelegate = true;
    }

    this(FibreEntryFunc fibreEntry, YieldHandler yieldHandler, void* userData = null, size_t stackSize = 16*1024)
    {
        if (!mainFibre)
            mainFibre = co_active();

        this.fibreEntry = fibreEntry;
        this.yieldHandler = yieldHandler;
        this.userData = userData;

        static void fibreFunc()
        {
            auto thisFibre = cast(Fibre*)co_data();
            try {
                if (thisFibre.isDelegate)
                {
                    FibreEntryDelegate dg;
                    dg.ptr = thisFibre.userData;
                    dg.funcptr = cast(void function() @nogc)thisFibre.fibreEntry;
                    dg();
                }
                else
                    thisFibre.fibreEntry(thisFibre.userData);
            }
            catch (Exception e) {
                // catch the exception... and?
                assert(false, "Unhandled exception!");
            }
            catch (Throwable e)
                abort();

            thisFibre.finished = true;

            // fibre is finished; we'll just yield immediately anytime it is awakened...
            // or should we do something more aggressive, like assert that it's done?
            while(true)
                yield();
        }

        fibre = co_create(stackSize, &fibreFunc, &this);
    }

    ~this()
    {
        assert(co_active() != fibre, "Can't delete the current fibre!");
        co_delete(fibre);
    }

    void resume()
    {
        co_switch(fibre);
    }

    bool isFinished()
        => finished;

    void* userData;

private:
    FibreEntryFunc fibreEntry;
    YieldHandler yieldHandler;

    cothread_t fibre;
    bool finished;
    bool isDelegate;
}


nothrow:

ref Fibre getFibre()
{
    return *cast(Fibre*)co_data();
}

bool isInFibre()
{
    return co_active() != mainFibre;
}

void yield(AwakenEvent ev = null)
{
    debug assert(isInFibre(), "Can't yield the main thread!");

    Fibre* thisFibre = &getFibre();
    thisFibre.yieldHandler(*thisFibre, ev);

    co_switch(mainFibre);
}

void sleep(Duration dur)
{
    debug assert(isInFibre(), "Can't sleep from the main thread!");

    static class SleepEvent : AwakenEvent
    {
    nothrow @nogc:
        import urt.time;

        Timer timer;

        this(Duration dur)
        {
            timer.setTimeout(dur);
            timer.reset();
        }

        final override bool ready()
            => timer.expired();
    }

    // record the timer somewhere...
    import urt.util : InPlace;
    auto ev = InPlace!SleepEvent(dur);

    yield(ev);
}


private:

void* mainFibre = null;


unittest
{
    __gshared x = 0;

    static void entry(void* userData) @nogc
    {
        x = 1;
        yield();
        assert(x == 2);
        x = 3;
        yield();
    }

    static void yield(ref Fibre yielding, AwakenEvent awakenEvent) nothrow @nogc
    {
        x += 10;
    }

    auto f = Fibre(&entry, &yield);
    f.resume();
    assert(x == 11);
    x = 2;
    f.resume();
    assert(x == 13);
}


// internal implementations inspired by libco
//-------------------------------------------

alias cothread_t = void*;
alias coentry_t = void function() @nogc;

version (UseWindowsFibreAPI)
{
    import core.sys.windows.winbase;

    version (X86_64)
    {
        import urt.system : NT_TIB, __readgsqword;

        void* GetCurrentFiber()
            => cast(void*)__readgsqword(NT_TIB.FiberData.offsetof);

        void* GetFiberData()
            => *cast(void**)__readgsqword(NT_TIB.FiberData.offsetof);
    }
    else version (X86)
    {
        import urt.system : NT_TIB, __readfsdword;

        void* GetCurrentFiber()
            => cast(void*)__readfsdword(NT_TIB.FiberData.offsetof);

        void* GetFiberData()
            => *cast(void**)__readfsdword(NT_TIB.FiberData.offsetof);
    }

    struct co_fibre_data
    {
        void* fiber;
        void* user_data;
        coentry_t coentry;
    }
    co_fibre_data thread_fiber_data;

    cothread_t co_active()
    {
        if(!thread_fiber_data.fiber)
            thread_fiber_data.fiber = ConvertThreadToFiber(&thread_fiber_data);
        return GetFiberData();
    }

    void* co_data()
    {
        return (cast(co_fibre_data*)GetFiberData()).user_data;
    }

    cothread_t co_derive(void[] memory, coentry_t entry, void* data)
    {
        // Windows fibers do not allow users to supply their own memory
        return null;
    }

    cothread_t co_create(size_t stack_size, coentry_t entry, void* data)
    {
        assert(stack_size <= uint.max, "Stack size too large");

        co_active();

        extern(Windows) static void co_thunk(void* codata)
        {
            (cast(co_fibre_data*)codata).coentry();
            assert(false, "Error: returned from fibre!");
        }

        auto fdata = defaultAllocator().allocT!co_fibre_data();
        fdata.user_data = data;
        fdata.coentry = entry;
        fdata.fiber = CreateFiber(stack_size, &co_thunk, fdata);
        return fdata;
    }

    void co_delete(cothread_t cothread)
    {
        auto fdata = cast(co_fibre_data*)cothread;
        DeleteFiber(fdata.fiber);
        defaultAllocator().freeT(fdata);
    }

    void co_switch(cothread_t cothread)
    {
        auto fdata = cast(co_fibre_data*)cothread;
        SwitchToFiber(fdata.fiber);
    }
}
else
{
    align(16) struct co_fibre_data
    {
        void* user_data;
        uint stack_size;
        uint flags;
    }

    align(16) size_t[SaveStateLen] co_active_buffer;
    cothread_t co_active_handle = null;

    cothread_t co_active()
    {
        if(!co_active_handle)
            co_active_handle = &co_active_buffer;
        return co_active_handle;
    }

    void* co_data()
    {
        return (cast(co_fibre_data*)co_active_handle - 1).user_data;
    }

    cothread_t co_derive(void[] memory, coentry_t entry, void* data)
    {
        if(!co_active_handle)
            co_active_handle = &co_active_buffer;

        if (!memory.ptr)
            return null;

        co_fibre_data* fdata = cast(co_fibre_data*)memory.ptr;
        fdata.user_data = data;
        fdata.stack_size = cast(uint)(memory.length - co_fibre_data.sizeof);
        fdata.flags = 0;

        cothread_t handle = fdata + 1;
        co_init_stack(handle, memory.ptr + memory.length, entry);
        return handle;
    }

    cothread_t co_create(size_t stack_size, coentry_t entry, void* data)
    {
        assert(stack_size <= uint.max, "Stack size too large");

        void[] memory = defaultAllocator().alloc(stack_size, co_fibre_data.alignof);
        if(!memory)
            return null;

        cothread_t co = co_derive(memory, entry, data);
        co_fibre_data* fdata = cast(co_fibre_data*)co - 1;
        fdata.flags = 1;
        return co;
    }

    void co_delete(cothread_t handle)
    {
        co_fibre_data* fdata = cast(co_fibre_data*)handle - 1;
        if (fdata.flags & 1)
            defaultAllocator().free((cast(void*)fdata)[0 .. co_fibre_data.sizeof + fdata.stack_size]);
    }

    void co_switch(cothread_t handle)
    {
        cothread_t co_previous_handle = co_active_handle;
        co_active_handle = handle;
        co_swap(co_active_handle, co_previous_handle);
    }


    // platform specific parts...

    import urt.compiler;
    import urt.processor;

    version (X86_64)
        version = Intel;
    else version (X86)
        version = Intel;

    version (Intel)
    {
        void crash()
        {
            assert(false, "Error: returned from fibre!");  // called only if cothread_t entrypoint returns
        }

        void co_init_stack(void* base, void* top, coentry_t entry)
        {
            size_t stack_top = cast(size_t)top;
            stack_top -= 32;                    // TODO: lib_co; why subtract 32 bytes here???
            stack_top &= ~size_t(15);

            void** sp = cast(void**)stack_top;  // seek to top of stack
            *--sp = &crash;                     // crash if entrypoint returns
            *--sp = entry;                      // entry function at return address

            void** p = cast(void**)base;
            p[0] = sp;                          // starting (e/r)sp
        }

        version (X86_64)
        {
            version (Windows)
            {
                // Windows calling convention specifies a bunch of SSE save-regs
                // TODO: we may want a version that omits the SSE stuff if we know SSE is not in use...

                // State: rsp, rbp, rsi, rdi, rbx, r12-r15, [padd], xmm6-xmm15 (16-bytes each)
                enum SaveStateLen = 30;

                pragma(inline, false)
                extern(C) void co_swap(cothread_t newCtx, cothread_t oldCtx)
                {
                    asm nothrow @nogc
                    {
                        naked;
                        mov [RDX],RSP;
                        mov RSP,[RCX];
                        pop RAX;
                        mov [RDX+ 8],RBP;
                        mov [RDX+16],RSI;
                        mov [RDX+24],RDI;
                        mov [RDX+32],RBX;
                        mov [RDX+40],R12;
                        mov [RDX+48],R13;
                        mov [RDX+56],R14;
                        mov [RDX+64],R15;
                        movaps [RDX+ 80],XMM6;
                        movaps [RDX+ 96],XMM7;
                        movaps [RDX+112],XMM8;
                        add RDX,112;
                        movaps [RDX+ 16],XMM9;
                        movaps [RDX+ 32],XMM10;
                        movaps [RDX+ 48],XMM11;
                        movaps [RDX+ 64],XMM12;
                        movaps [RDX+ 80],XMM13;
                        movaps [RDX+ 96],XMM14;
                        movaps [RDX+112],XMM15;
                        mov RBP,[RCX+ 8];
                        mov RSI,[RCX+16];
                        mov RDI,[RCX+24];
                        mov RBX,[RCX+32];
                        mov R12,[RCX+40];
                        mov R13,[RCX+48];
                        mov R14,[RCX+56];
                        mov R15,[RCX+64];
                        movaps XMM6, [RCX+ 80];
                        movaps XMM7, [RCX+ 96];
                        movaps XMM8, [RCX+112];
                        add RCX,112;
                        movaps XMM9, [RCX+ 16];
                        movaps XMM10,[RCX+ 32];
                        movaps XMM11,[RCX+ 48];
                        movaps XMM12,[RCX+ 64];
                        movaps XMM13,[RCX+ 80];
                        movaps XMM14,[RCX+ 96];
                        movaps XMM15,[RCX+112];
                        jmp RAX;
                    }
                }
            }
            else
            {
                // SystemV has way less save-regs

                // State: rsp, rbp, rbx, r12-r15
                enum SaveStateLen = 7;

                pragma(inline, false)
                extern(C) void co_swap(cothread_t newCtx, cothread_t oldCtx)
                {
                    asm nothrow @nogc
                    {
                        naked;
                        mov [RSI],RSP;
                        mov RSP,[RDI];
                        pop RAX;
                        mov [RSI+ 8],RBP;
                        mov [RSI+16],RBX;
                        mov [RSI+24],R12;
                        mov [RSI+32],R13;
                        mov [RSI+40],R14;
                        mov [RSI+48],R15;
                        mov RBP,[RDI+ 8];
                        mov RBX,[RDI+16];
                        mov R12,[RDI+24];
                        mov R13,[RDI+32];
                        mov R14,[RDI+40];
                        mov R15,[RDI+48];
                        jmp RAX;
                    }
                }
            }
        }
        else version (X86)
        {
            // State: esp, ebp, esi, edi, ebx
            enum SaveStateLen = 5;

            // x86 cdecl and fastcall are the same for Windows and SystemV
            // DMD doesn't support `fastcall` though
            version (DigitalMars)
            {
                pragma(inline, false)
                extern(C) void co_swap(cothread_t newCtx, cothread_t oldCtx)
                {
                    asm nothrow @nogc
                    {
                        naked;
                        mov ECX, [ESP + 4]; // load newCtx (no fastcall)
                        mov EDX, [ESP + 8]; // load oldCtx
                        mov [EDX], ESP;
                        mov ESP, [ECX];
                        pop EAX;
                        mov [EDX + 4], EBP;
                        mov [EDX + 8], ESI;
                        mov [EDX + 12], EDI;
                        mov [EDX + 16], EBX;
                        mov EBP, [ECX + 4];
                        mov ESI, [ECX + 8];
                        mov EDI, [ECX + 12];
                        mov EBX, [ECX + 16];
                        jmp EAX;
                    }
                }
            }
            else
            {
                pragma(inline, false)
                @callingConvention("fastcc") // `fastcall` calling convention
                extern(C) void co_swap(cothread_t newCtx, cothread_t oldCtx) @naked
                {
                    asm nothrow @nogc
                    {
                        `
                        movl %%esp, 0(%%edx)
                        movl 0(%%ecx), %%esp
                        popl %%eax
                        movl %%ebp, 4(%%edx)
                        movl %%esi, 8(%%edx)
                        movl %%edi, 12(%%edx)
                        movl %%ebx, 16(%%edx)
                        movl 4(%%ecx), %%ebp
                        movl 8(%%ecx), %%esi
                        movl 12(%%ecx), %%edi
                        movl 16(%%ecx), %%ebx
                        jmp *%%eax
                        `;
                    }
                }
            }
        }
    }
    else
        static assert(false, "TODO: implement for other architectures!");
}

unittest
{
    __gshared cothread_t main;
    __gshared uint x = 0;

    static void fibre()
    {
        x = cast(uint)cast(size_t)co_data();
        co_switch(main);
        assert(x == 2);
        x = 3;
        co_switch(main);
    }

    main = co_active();
    cothread_t fib = co_create(16*1024, &fibre, cast(void*)1);
    co_switch(fib);
    assert(x == 1);
    x = 2;
    co_switch(fib);
    assert(x == 3);
    co_delete(fib);
}
