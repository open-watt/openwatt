module urt.async;

import urt.fibre;
import urt.lifetime;
import urt.mem.allocator;
import urt.mem.freelist;
import urt.meta.tuple;
import urt.traits;

public import urt.fibre : yield, sleep;

nothrow @nogc:


void async(alias Fun)(auto ref Parameters!Fun args)
    if (is(typeof(Fun) == function))
{
    async(&Fun, forward!args);
}

void async(Fun, Args...)(Fun fun, auto ref Args args)
    if (is(Fun == R function(Args), R, Args...) || is(Fun == R delegate(Args), R, Args...))
{
    AsyncCall* call = freeCalls;
    if (!call)
        call = defaultAllocator().allocT!AsyncCall(0);
    else
        freeCalls = call.next;

    // this call-shim will copy the arguments to the fibre's stack so they can survive this call...
    struct Shim
    {
        Fun fun = void;
        Tuple!Args tup = void;

        void call() nothrow @nogc
        {
            import urt.mem : alloca;
            import urt.util : alignUp;

            // copy the args to the fibre stack; when we yield, `this` will be gone
            void* mem = alloca(Tuple!Args.sizeof + Tuple!Args.alignof);
            Tuple!Args* args = cast(Tuple!Args*)alignUp(mem, Tuple!Args.alignof);
            *args = tup;

            fun(args.expand);
        }
    }
    Shim shim;
    shim.fun = fun;
    emplace(&shim.tup, forward!args);

    // launch the shim in the fibre
    call.userEntry = &shim.call;
    call.fibre.resume();
}

void asyncUpdate()
{
    AsyncWait* wait = waiting;
    while (wait)
    {
        AsyncWait* t = wait;
        wait = wait.next;

        t.event.update();
        if (t.event.ready())
        {
            AsyncCall* resume = t.call;

            if (waiting == t)
                waiting = wait;
            waitingPool.free(t);

            resume.fibre.resume();
        }
    }
}


private:

import urt.util : InPlace, Default;

struct AsyncCall
{
nothrow @nogc:
    Fibre fibre;
    AsyncCall* next;
    void delegate() userEntry;

    this() @disable;
    this(int)
    {
        fibre = Fibre(&entry, &doYield, userData: &this);
    }

    static void entry(void* p)
    {
        AsyncCall* this_ = cast(AsyncCall*)p;
        while (this_.userEntry)
        {
            this_.userEntry();
            yield(finishToken);
        }
    }
}

struct AsyncWait
{
    AsyncCall* call;
    AwakenEvent event;
    AsyncWait* next;
}

class FinishEvent : AwakenEvent {}
__gshared FinishEvent finishToken = new FinishEvent;

AsyncWait* waiting;
AsyncCall* freeCalls;

FreeList!AsyncWait waitingPool;

void doYield(ref Fibre yielding, AwakenEvent awakenEvent)
{
    if (awakenEvent is finishToken)
    {
        AsyncCall* call = cast(AsyncCall*)yielding.userData;
        call.next = freeCalls;
        freeCalls = call;
    }
    else
    {
        AsyncWait* wait = waitingPool.alloc();
        wait.call = cast(AsyncCall*)yielding.userData;
        wait.event = awakenEvent;
        wait.next = waiting;
        waiting = wait;
    }
}
