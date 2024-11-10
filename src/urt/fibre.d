module urt.fibre;

import urt.system;
import urt.time;

version (Windows)
{
    import core.sys.windows.winbase;
}

nothrow @nogc:


extern(C++) class AwakenEvent
{
extern(D):
nothrow @nogc:
    abstract bool ready() { return true; }
    void update() {}
}


alias FibreEntry = void function(void* userData) @nogc;
alias YieldHandler = void function(ref Fibre yielding, AwakenEvent awakenEvent) nothrow @nogc;

struct Fibre
{
nothrow @nogc:

    this() @disable;

    this(FibreEntry fibreEntry, YieldHandler yieldHandler, size_t stackSize = 16*1024, void* userData = null)
    {
        this.fibreEntry = fibreEntry;
        this.yieldHandler = yieldHandler;
        this.userData = userData;

        version (Windows)
        {
            extern (Windows) static void fibreFunc(void* arg)
            {
                Fibre* thisFibre = cast(Fibre*)arg;
                try {
                    thisFibre.fibreEntry(thisFibre.userData);
//                    DeleteFiber(GetCurrentFiber());
                }
                catch (Exception e) {
                    // catch the exception... and?
                    assert(false, "Unhandled exception!");
                }
                catch (Throwable e)
                    abort();
            }

            fibre = CreateFiber(stackSize, &fibreFunc, &this);
        }
    }

    ~this()
    {
        version (Windows)
        {
            assert(GetCurrentFiber() != fibre, "Can't delete the current fibre!");
            DeleteFiber(fibre);
        }
    }

    void resume()
    {
        version (Windows)
            SwitchToFiber(fibre);
    }

private:
    FibreEntry fibreEntry;
    YieldHandler yieldHandler;
    public void* userData;

    version (Windows)
    {
        void* fibre;
    }
}

ref Fibre getFibre()
{
    version (Windows)
        return *cast(Fibre*)GetFiberData();
}

bool isInFibre()
{
    version (Windows)
        return GetCurrentFiber() != mainFibre;
}

void yield(AwakenEvent ev = null)
{
    debug assert(isInFibre(), "Can't yield the main thread!");

    Fibre* thisFibre = &getFibre();
    thisFibre.yieldHandler(*thisFibre, ev);

    version (Windows)
        SwitchToFiber(mainFibre);
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

version (Windows)
{
    import urt.system : NT_TIB, __readgsqword;

    __gshared void* mainFibre = null;

    package(urt) void initFibre()
    {
        mainFibre = ConvertThreadToFiber(null);
    }

    void* GetCurrentFiber()
        => cast(void*)__readgsqword(NT_TIB.FiberData.offsetof);

    void* GetFiberData()
        => *cast(void**)__readgsqword(NT_TIB.FiberData.offsetof);
}
