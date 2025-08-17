module urt.fibre;

import urt.mem;
import urt.time;
import urt.util : isAligned, max;

version (Windows)
    version = UseWindowsFibreAPI;

debug
{
    enum DefaultStackSize = 64*1024;
    enum GuardBand = 1024;
}
else
{
    enum DefaultStackSize = 16*1024;
    enum GuardBand = 0;
}

@nogc:


extern(C++) class AwakenEvent
{
extern(D):
nothrow @nogc:
    bool abort;
    abstract bool ready() { return true; }
    void update() {}
}

alias FibreEntryFunc = void function(void*) @nogc;
alias FibreEntryDelegate = void delegate() @nogc;
alias ResumeHandler = void delegate() nothrow @nogc;
alias YieldHandler = ResumeHandler function(ref Fibre yielding, AwakenEvent awakenEvent) nothrow @nogc;

struct Fibre
{
@nogc:

    this() @disable;
    this(ref typeof(this)) @disable;    // disable copy
    this(typeof(this)) @disable;        // disable move

    this(size_t stackSize) nothrow
    {
        if (!mainFibre)
            mainFibre = co_active();

        // TODO: i think it's a bug that this stuff isn't initialised!
        isDelegate = false;
        abortRequested = false;
        finished = true; // init in a state ready to be recycled...
        aborted = false;

        static void fibreFunc()
        {
            import urt.system : abort;

            auto thisFibre = cast(Fibre*)co_data();
            while (true)
            {
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
                catch (AbortException e)
                {
                    thisFibre.abortRequested = false;
                    thisFibre.aborted = true;
                }
                catch (Exception e)
                {
                    assert(false, "Unhandled exception!");
                    abort();
                }
                catch (Throwable e)
                {
                    abort();
                }

                thisFibre.finished = true;

                // fibre is finished; we'll just yield immediately anytime it is awakened...
                while (thisFibre.finished)
                    co_switch(mainFibre);

                // fibre was recycled...
            }
        }

        fibre = co_create(stackSize, &fibreFunc, &this);
    }

    this(FibreEntryDelegate fibreEntry, YieldHandler yieldHandler, size_t stackSize = DefaultStackSize) nothrow
    {
        this(cast(FibreEntryFunc)fibreEntry.funcptr, yieldHandler, fibreEntry.ptr, stackSize);

        isDelegate = true;
    }

    this(FibreEntryFunc fibreEntry, YieldHandler yieldHandler, void* userData = null, size_t stackSize = DefaultStackSize) nothrow
    {
        this(stackSize);

        this.fibreEntry = fibreEntry;
        this.yieldHandler = yieldHandler;
        this.userData = userData;

        finished = false;
    }

    ~this() nothrow
    {
        assert(co_active() != fibre, "Can't delete the current fibre!");

        if (!finished)
        {
            abort();
            assert(finished && aborted, "Fibre did not abort!");
        }

        co_delete(fibre);
    }

    void resume() nothrow
    {
        co_switch(fibre);
    }

    void abort() nothrow
    {
        assert(co_active() == mainFibre, "Can't abort when active; use urt.fibre.abort() instead.");

        // request abort and switch to the fibre
        abortRequested = true;
        co_switch(fibre);
    }

    void recycle(FibreEntryDelegate fibreEntry) pure nothrow
    {
        assert(isFinished(), "Can't recycle a fibre that hasn't finished yet!");

        this.fibreEntry = cast(FibreEntryFunc)fibreEntry.funcptr;
        userData = fibreEntry.ptr;
        isDelegate = true;
        abortRequested = false;
        finished = false;
        aborted = false;
    }

    void recycle(FibreEntryFunc fibreEntry, void* userData = null) pure nothrow
    {
        assert(isFinished(), "Can't recycle a fibre that hasn't finished yet!");

        this.fibreEntry = fibreEntry;
        this.userData = userData;
        isDelegate = false;
        abortRequested = false;
        finished = false;
        aborted = false;
    }

    void reset() pure nothrow
    {
        assert(isFinished(), "Can't restart a fibre that hasn't finished yet!");

        abortRequested = false;
        finished = false;
        aborted = false;
    }

    bool isFinished() const pure nothrow
        => finished;

    bool wasAborted() const pure nothrow
        => aborted;

    size_t stackSize() const pure nothrow
    {
        assert(fibre, "Fibre not created!");
        auto fdata = co_get_fibre_data(fibre);
        return fdata.stack_size;
    }

    void* userData;

private:
    FibreEntryFunc fibreEntry;
    YieldHandler yieldHandler;

    cothread_t fibre;
    bool isDelegate;
    bool abortRequested;
    bool finished;
    bool aborted;
}


void yield(AwakenEvent ev = null)
{
    debug assert(isInFibre(), "Can't yield the main thread!");

    Fibre* thisFibre = &getFibre();
    assert(!thisFibre.wasAborted(), "Can't yield during fibre abort!");

    ResumeHandler resume = null;
    if (thisFibre.yieldHandler)
        resume = thisFibre.yieldHandler(*thisFibre, ev);

    co_switch(mainFibre);

    if (resume)
        resume();

    if (thisFibre.abortRequested)
        abort("Abort requested");
}

void sleep(Duration dur)
{
    debug assert(isInFibre(), "Can't sleep from the main thread!");

    static class SleepEvent : AwakenEvent
    {
    nothrow @nogc:
        import urt.time;

        Timer timer;

        this() @disable;
        this(Duration dur)
        {
            timer = Timer(dur);
        }

        final override bool ready() const
            => timer.expired();
    }

    // record the timer somewhere...
    import urt.util : InPlace;
    auto ev = InPlace!SleepEvent(dur);

    yield(ev);
}

noreturn abort(string message)
{
    version (Windows)
    {
        version (UseWindowsFibreAPI) {} else
            assert(false, "TODO: Windows raw fibres don't support exceptions (yet - needs more work!)");
    }

    debug assert(isInFibre(), "Can't abort the main thread!");

    if (!abortException)
        abortException = defaultAllocator().allocT!AbortException(message);
    else
        abortException.msg = message;
    throw abortException;
}

ref Fibre getFibre() nothrow
{
    return *cast(Fibre*)co_data();
}

bool isInFibre() nothrow
{
    return co_active() != mainFibre;
}


private:

class AbortException : Exception
{
    this(string msg) nothrow @nogc
    {
        super(msg);
    }
}

void* mainFibre = null;

AbortException abortException;


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

    static ResumeHandler yield(ref Fibre yielding, AwakenEvent awakenEvent) nothrow @nogc
    {
        x += 10;
        return null;
    }

    auto f = Fibre(&entry, &yield);
    f.resume();
    assert(x == 11);
    x = 2;
    f.resume();
    assert(x == 13);
    f.resume();
    assert(f.isFinished);

    f.reset();
    f.resume();
    assert(x == 11);
    f.abort();
    assert(f.isFinished);
    assert(f.wasAborted);
}


// internal implementations inspired by libco
//-------------------------------------------
nothrow:

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
        uint stack_size;
        coentry_t coentry;
    }
    co_fibre_data thread_fiber_data;

    private inout(co_fibre_data)* co_get_fibre_data(inout cothread_t fibre) pure
        => cast(co_fibre_data*)fibre;

    cothread_t co_active()
    {
        if(!thread_fiber_data.fiber)
            thread_fiber_data.fiber = ConvertThreadToFiber(&thread_fiber_data);
        return GetFiberData();
    }

    void* co_data()
        => (cast(co_fibre_data*)GetFiberData()).user_data;

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
        fdata.stack_size = cast(uint)stack_size;
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

    private inout(co_fibre_data)* co_get_fibre_data(inout cothread_t fibre) pure
        => cast(co_fibre_data*)fibre - 1;

    align(16) size_t[SaveStateLen] co_active_buffer;
    cothread_t co_active_handle = null;

    cothread_t co_active()
    {
        if(!co_active_handle)
            co_active_handle = &co_active_buffer;
        return co_active_handle;
    }

    void* co_data()
        => (cast(co_fibre_data*)co_active_handle - 1).user_data;

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

        // TODO: (chatgpt suggestions...)

        // On Windows
        //  reserve = VirtualAlloc(NULL, reserve_size, MEM_RESERVE, PAGE_READWRITE)
        //  commit_top = VirtualAlloc(reserve_top - commit_size, commit_size, MEM_COMMIT, PAGE_READWRITE)
        //  mark the page below commit_top with PAGE_GUARD via VirtualProtect
        //
        //  write:
        //    TEB->NtTib.StackBase = reserve_top;
        //    TEB->NtTib.StackLimit = commit_top - commit_size; (or wherever the current low committed limit ends up after guard)
        //    TEB->DeallocationStack = reserve_base;
        //
        //  (x86) TEB->NtTib.ExceptionList = (EXCEPTION_REGISTRATION_RECORD*)-1;
        //  set RSP to StackBase - red_zone - shadow_space (x64), maintain 16-byte alignment
        //  touch a few pages downward to arm the guard

        // On Linux:
        //  mmap(size + page) + mprotect(lowest page, PROT_NONE) instead of guard band
        //
        //  Alignment + call discipline:
        //    On x86-64 SysV: maintain 16-byte RSP alignment at call sites.
        //    Enter the fiber by doing a call into a normal C/C++ function (or an asm thunk with CFI), not a jmp. A call pushes a return address and gives the unwinder a sane CFA.
        //    Provide any ABI-required call scratch (no shadow space on SysV x86-64; AArch64 also needs 16-byte SP alignment).
        //
        //  CFI / unwind info at the top frame:
        //    If your first frame is compiled C/C++, you’re good: GCC/Clang emit DWARF CFI the unwinder can use.
        //    If your first frame is hand-written asm, add .cfi_startproc, .cfi_def_cfa %rsp, 8 (after the call), and proper .cfi_offset/.cfi_def_cfa_offset as you adjust RSP.
        //
        //  Red zone awareness (x86-64 SysV):
        //    The 128-byte red zone exists below RSP. Don’t place your fiber’s SP so close to the guard that normal red-zone use immediately hits the guard. Leave ≥128 B slack above the guard.
        //
        //  Signals (optional but practical).
        //    If your fibers have small stacks, install a signal alt-stack (sigaltstack) so signal handlers don’t blow the fiber stack.
        //    If you intend to throw across a signal frame (rare), ensure handlers are compiled with unwind tables.
        //
        //  Stack overflow behavior.
        //    Linux won’t auto-grow your ad-hoc stack. The guard page gives you a deterministic SIGSEGV instead of silent corruption. Consider pre-touching a page or two to establish mapping.

        // Bare metal:
        //  this code should be fine, check the guard-band from time to time...?

        void[] memory = defaultAllocator().alloc(stack_size + co_fibre_data.sizeof + GuardBand, max(co_fibre_data.alignof, 16));
        if(!memory)
            return null;

        static if (GuardBand > 0)
        {
            (cast(uint[])memory[0 .. GuardBand/2])[] = 0x0DF0ADBA;
            (cast(uint[])memory[$-GuardBand/2 .. $])[] = 0x0DF0ADBA;
            memory = memory[GuardBand/2 .. $-GuardBand/2];
        }

        cothread_t co = co_derive(memory, entry, data);
        co_fibre_data* fdata = cast(co_fibre_data*)co - 1;
        fdata.flags = 1;
        return co;
    }

    void co_delete(cothread_t handle)
    {
        co_fibre_data* fdata = cast(co_fibre_data*)handle - 1;
        if (fdata.flags & 1)
        {
            void[] memory = (cast(void*)fdata)[0 .. co_fibre_data.sizeof + fdata.stack_size];
            static if (GuardBand > 0)
                memory = (memory.ptr - GuardBand/2)[0 .. memory.length + GuardBand];
            defaultAllocator().free(memory);
        }
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
            assert(false, "Error: returned from fibre!"); // called only if cothread_t entrypoint returns
        }

        void co_init_stack(void* base, void* top, coentry_t entry)
        {
            assert(isAligned!16(base) && isAligned!16(top), "Stack must be aligned to 16 bytes");

            void** sp = cast(void**)top;    // seek to top of stack
            *--sp = &crash;                 // crash if entrypoint returns
            *--sp = entry;                  // entry function at return address

            void** p = cast(void**)base;
            p[0] = sp;                      // starting (e/r)sp
            p[1] = null;
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
    else version (ARM)
    {
        // State: r4-r11, sp, lr
        enum SaveStateLen = 10;

        void co_init_stack(void* base, void* top, coentry_t entry)
        {
            assert(isAligned!16(base) && isAligned!16(top), "Stack must be aligned to 16 bytes");

            void** p = cast(void**)base;
            p[8] = cast(void*)top;  // starting sp
            p[9] = entry;           // starting lr
        }

        pragma(inline, false)
        extern(C) void co_swap(cothread_t newCtx, cothread_t oldCtx) @naked
        {
            // just for thumb-1, thumb-2 can to the 32bit thing below.. somehow... apparently...?
            static if (ProcFeatures.thumb && !ProcFeatures.thumb2)
            {
                static assert(false, "TODO: this needs to be tested somehow... thumb instructions are offset by 1 byte.");
                asm nothrow @nogc
                {
                    `
                    stmia r1!, {r4-r7}
                    mov r2, r8
                    mov r3, r9
                    mov r4, r10
                    mov r5, r11
                    mov r6, sp
                    mov r7, lr
                    stmia r1!, {r2-r7}
                    add r1, r0, #16
                    ldmia r1!, {r2-r6}
                    mov r8, r2
                    mov r9, r3
                    mov r10, r4
                    mov r11, r5
                    mov sp, r6
                    ldmia r0!, {r4-r7}
                    ldmia r1!, {pc}
                    `
    //                bx lr ; TODO: why is this even here? the prior instruction loads `pc`... maybe it's a hint to the branch predictor?
                    : // no outputs
                    : // "r"(newCtx), "r"(oldCtx) // function is @naked, so the ABI takes care of this
                    : "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "sp", "lr", "memory";
                }
            }
            else
            {
                asm nothrow @nogc
                {
                    `
                    stmia r1!, {r4-r11,sp,lr}
                    ldmia r0!, {r4-r11,sp,pc}
                    `
                    : // no outputs
                    : // "r"(newCtx), "r"(oldCtx) // function is @naked, so the ABI takes care of this
                    : "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "sp", "lr", "memory";
                }
            }
        }
    }
    else version (AArch64)
    {
        // State: x19-x30 (x29=fp, x30=lr), sp, [padd], v8-v15 (128bits each)
        enum SaveStateLen = 12 + 1 + 1 + 8*2;

        void co_init_stack(void* base, void* top, coentry_t entry)
        {
            assert(isAligned!16(base) && isAligned!16(top), "Stack must be aligned to 16 bytes");

            void** p = cast(void**)base;
            p[0]  = cast(void*)top; // x16 (stack pointer)
            p[1]  = entry;          // x30 (link register)
            p[12] = cast(void*)top; // x29 (frame pointer)
        }

        pragma(inline, false)
        extern(C) void co_swap(cothread_t newCtx, cothread_t oldCtx) @naked
        {
            asm nothrow @nogc
            {
                `
                mov x16,sp
                stp x16,x30,[x1]
                ldp x16,x30,[x0]
                mov sp,x16
                stp x19,x20,[x1, 16]
                stp x21,x22,[x1, 32]
                stp x23,x24,[x1, 48]
                stp x25,x26,[x1, 64]
                stp x27,x28,[x1, 80]
                str x29,    [x1, 96]
                stp q8, q9, [x1,112]
                stp q10,q11,[x1,144]
                stp q12,q13,[x1,176]
                stp q14,q15,[x1,208]
                ldp x19,x20,[x0, 16]
                ldp x21,x22,[x0, 32]
                ldp x23,x24,[x0, 48]
                ldp x25,x26,[x0, 64]
                ldp x27,x28,[x0, 80]
                ldr x29,    [x0, 96]
                ldp q8, q9, [x0,112]
                ldp q10,q11,[x0,144]
                ldp q12,q13,[x0,176]
                ldp q14,q15,[x0,208]
                br x30
                `
                : // no outputs
                : // "r"(newCtx), "r"(oldCtx) // function is @naked, so the ABI takes care of this
                : "x16", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "memory";
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
