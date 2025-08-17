module urt.async;

import urt.fibre;
import urt.lifetime;
import urt.mem.allocator;
import urt.mem.freelist;
import urt.meta.tuple;
import urt.traits;

public import urt.fibre : yield, sleep;

nothrow @nogc:


Promise!(ReturnType!Fun)* async(alias Fun, size_t stackSize = DefaultStackSize, Args...)(auto ref Args args)
    if (is(typeof(&Fun) == R function(auto ref Args) @nogc, R))
{
    return async!stackSize(&Fun, forward!args);
}

// TODO: nice to rework this; maybe make stackSize a not-template-arg, and receive a function call/closure object which stores the args
Promise!(ReturnType!Fun)* async(size_t stackSize = DefaultStackSize, Fun, Args...)(Fun fun, auto ref Args args)
    if (isSomeFunction!Fun)
{
    alias Result = ReturnType!Fun;
    Promise!Result* r = cast(Promise!Result*)defaultAllocator().alloc(Promise!Result.sizeof, Promise!Result.alignof);

    // this shim is used as the entry-point for the async call
    // the function arguments must be copied to the fibre's stack:
    // 1 - we copy the args to this shim object in the calling stack
    // 2 - the shim becomes the entrypoint to the fibre
    // 3 - the shim's entrypoint copies the args from the shim object (calling stack) to the fibre stack
    // 4 - the shim then calls the async function with the args on the fibre stack
    struct Shim
    {
        Tuple!Args calling_args = void;
        Fun fn = void;
        Promise!Result* promise = void;

        static void entry(void* userData) @nogc
        {
            Shim* this_ = cast(Shim*)userData;

            ref Promise!Result r = *this_.promise;
            Tuple!Args args = this_.calling_args.move;
            static if (is(Result == void))
                this_.fn(args.expand);
            else
                r.value = this_.fn(args.expand);
        }
    }
    auto shim = Shim(Tuple!Args(forward!args), fun, r);

    // TODO: DMD bug causes palcement new to fail on x86! uncomment when the bug is fixed...
//    new(*r) Promise!Result(&shim.entry, &shim, stackSize);
    *r = Promise!Result(&shim.entry, &shim, stackSize);
    r.async.fibre.resume();
    return r;
}

void freePromise(T)(ref Promise!T* promise)
{
    assert(promise.state() != Promise!T.State.Pending, "Promise still pending!");
    defaultAllocator().freeT(promise);
    promise = null;
}

void asyncUpdate()
{
    AsyncWait* wait = waiting;
    while (wait)
    {
        AsyncWait* t = wait;
        wait = wait.next;

        if (t.event)
        {
            t.event.update();
            if (!t.event.ready())
                continue;
        }
        t.resume();
    }
}


struct Promise(Result)
{
    enum State
    {
        Pending,
        Ready,
        Failed,
    }

    // construct using `async()` functions...
    this() @disable;
    this(ref typeof(this)) @disable; // disable copy constructor
    this(typeof(this)) @disable; // disable move constructor

    // HACK: delete this when the placement new bug is fixed!
    void opAssign(typeof(this) rh) nothrow @nogc
    {
        this.async = rh.async;
        rh.async = null;
        static if (!is(Result == void))
            this.value = rh.value.move;
    }

    ~this()
    {
        if (async)
        {
            assert(async.fibre.isFinished());
            async.next = freeList;
            freeList = async;
        }
    }

    State state() const
    {
        if (async.fibre.wasAborted())
            return State.Failed;
        else if (async.fibre.isFinished())
            return State.Ready;
        else
            return State.Pending;
    }

    bool finished() const
        => state() != State.Pending;

    ref Result result()
    {
        assert(state() == State.Ready, "Promise not fulfilled!");
        static if (!is(Result == void))
            return value;
    }

    void abort()
    {
        assert(state() == State.Pending, "Promise already fulfilled!");
        async.fibre.abort();
    }

private:
    AsyncCall* async;
    static if (!is(Result == void))
        Result value;

    this(void function(void*) @nogc entry, void* userData, size_t stackSize = DefaultStackSize) nothrow @nogc
    {
        if (freeList)
        {
            async = freeList;
            freeList = async.next;

            // TODO: if we end up with a pool of mixed stack sizes; maybe we want to find the smallest one that fits the requested stack...
            assert(async.fibre.stackSize >= stackSize, "Stack size too small!");
            async.fibre.reset();
        }
        else
            async = defaultAllocator().allocT!AsyncCall(stackSize);
        async.setEntry(entry, userData);

        // TODO: HACK, this should be void-init, and then result emplaced at the assignment
        //       ...but palcement new doesn't work with default initialisation yet!
        static if (!is(Result == void))
            value = Result.init;
    }
}


unittest
{
    // Test simple case
    static int fun(int a, int b) @nogc
    {
        return a + b;
    }

    auto p = async!fun(1, 2);
    assert(p.state() == p.State.Ready);
    assert(p.result() == 3);
    freePromise(p);
    p = async!fun(10, 20);
    assert(p.state() == p.State.Ready);
    assert(p.result() == 30);
    freePromise(p);

    // Test with yielding
    __gshared int val = 0;
    static int fun_yield() @nogc
    {
        val = 1;
        yield();
        val = 2;
        yield();
        val = 3;
        return 4;
    }

    auto p_yield = async(&fun_yield);
    assert(p_yield.state() == p_yield.State.Pending);
    assert(val == 1);
    asyncUpdate();
    assert(p_yield.state() == p_yield.State.Pending);
    assert(val == 2);
    asyncUpdate();
    assert(p_yield.state() == p_yield.State.Ready);
    assert(val == 3);
    assert(p_yield.result() == 4);
    freePromise(p_yield);
}


private:

import urt.util : InPlace, Default;

struct AsyncCall
{
    Fibre fibre = void;
    union {
        AsyncCall* next;
        void* userData;
    }
    void function(void*) @nogc userEntry;

@nogc:
    this() @disable;
    this(ref typeof(this)) @disable; // disable copy constructor
    this(typeof(this)) @disable;     // disable move constructor

    void setEntry(void function(void*) @nogc entry, void* userData) nothrow
    {
        this.userEntry = entry;
        this.userData = userData;
    }

    this(size_t stackSize) nothrow
    {
        new(fibre) Fibre(&this.entry, &doYield, cast(void*)&this, stackSize);
    }

    static void entry(void* p)
    {
        AsyncCall* this_ = cast(AsyncCall*)p;
        this_.userEntry(this_.userData);
    }
}

struct AsyncWait
{
    AsyncWait* next;
    AsyncCall* call;
    AwakenEvent event;

    void resume() nothrow @nogc
    {
        AsyncCall* call = this.call;

        if (waiting == &this)
            waiting = this.next;
        else
        {
            for (AsyncWait* t = waiting; t; t = t.next)
            {
                if (t.next == &this)
                {
                    t.next = this.next;
                    break;
                }
            }
        }
        waitingPool.free(&this);

        call.fibre.resume();
    }
}


__gshared FreeList!AsyncWait waitingPool;
__gshared AsyncWait* waiting;   // list of active yielded/waiting fibres
__gshared AsyncCall* freeList;  // free-list of AsyncCall objects

shared static ~this()
{
    assert(!waiting, "There are non-terminated fibres... unclean shutdown.");

    while (freeList)
    {
        AsyncCall* t = freeList;
        freeList = freeList.next;
        defaultAllocator().freeT(t);
    }
}

ResumeHandler doYield(ref Fibre yielding, AwakenEvent awakenEvent)
{
    AsyncWait* wait = waitingPool.alloc();
    wait.call = cast(AsyncCall*)yielding.userData;
    wait.event = awakenEvent;
    wait.next = waiting;
    waiting = wait;

    return &wait.resume;
}
