module driver.linux.fdwatch;

version (linux):

import urt.array;

import manager;
import manager.plugin;
import manager.reactor : Reactor;

import urt.internal.sys.posix : pollfd;

nothrow @nogc:


alias FdWatchService = void delegate() nothrow @nogc;
alias FdWatchCollect = void delegate(ref Array!pollfd fds) nothrow @nogc;

bool add_fd_watcher(FdWatchService service, FdWatchCollect collect)
    => g_fdwatch.add(service, collect, g_app.reactor);

void remove_fd_watcher(FdWatchService service)
{
    g_fdwatch.remove(service);
}

void fd_watch_changed()
{
    g_fdwatch.rebuild();
}


final class LinuxFdWatchModule : Module
{
    mixin DeclareModule!"os.fdwatch";
nothrow @nogc:

    override void deinit()
    {
        g_fdwatch.stop();
    }
}


private:

__gshared FdWatch g_fdwatch;

struct FdWatch
{
nothrow @nogc:

    struct Watcher
    {
        FdWatchService service;
        FdWatchCollect collect;
    }

    Array!Watcher _watchers;
    Array!pollfd _desired;
    Reactor* _reactor;
    bool _servicing;

    bool add(FdWatchService service, FdWatchCollect collect, ref Reactor reactor)
    {
        if (_reactor is null)
        {
            _reactor = &reactor;
            _reactor.set_pool_drain(&service_all);
        }
        assert(_reactor is &reactor);
        _watchers ~= Watcher(service, collect);
        rebuild();
        return true;
    }

    void remove(FdWatchService service)
    {
        foreach (i, ref w; _watchers[])
        {
            if (w.service is service)
            {
                if (_servicing)
                    w = Watcher.init;
                else
                    _watchers.remove(i);
                rebuild();
                return;
            }
        }
    }

    void rebuild()
    {
        _desired.clear();
        foreach (ref w; _watchers[])
            if (w.collect)
                w.collect(_desired);
        if (_reactor)
            _reactor.set_pool_fds(_desired[]);
    }

    void service_all()
    {
        _servicing = true;
        // Removals leave tombstones until the pass ends; additions wait for the next pass.
        size_t count = _watchers.length;
        for (size_t i = 0; i < count; ++i)
            if (auto service = _watchers[i].service)
                service();
        _servicing = false;
        for (size_t i = _watchers.length; i-- > 0;)
            if (!_watchers[i].service)
                _watchers.remove(i);
        rebuild();
    }

    void stop()
    {
        if (_servicing)
        {
            foreach (ref w; _watchers[])
                w = Watcher.init;
        }
        else
            _watchers.clear();
        _desired.clear();
        if (_reactor)
        {
            _reactor.set_pool_fds(null);
            _reactor.set_pool_drain(null);
            _reactor = null;
        }
    }
}

unittest
{
    struct Test
    {
    nothrow @nogc:
        FdWatch watches;
        Reactor reactor;
        uint second_calls, third_calls, added_calls;

        void collect(ref Array!pollfd)
        {
        }
        void first()
        {
            watches.remove(&first);
            watches.remove(&third);
            watches.add(&added, &collect, reactor);
        }
        void second()
        {
            ++second_calls;
        }

        void third()
        {
            ++third_calls;
        }

        void added()
        {
            ++added_calls;
        }
    }

    Test t;
    assert(t.reactor.init());
    scope(exit)
    {
        t.watches.stop();
        t.reactor.destroy();
    }
    t.watches.add(&t.first, &t.collect, t.reactor);
    t.watches.add(&t.second, &t.collect, t.reactor);
    t.watches.add(&t.third, &t.collect, t.reactor);
    t.watches.service_all();
    assert(t.second_calls == 1 && t.third_calls == 0 && t.added_calls == 0);
    t.watches.service_all();
    assert(t.second_calls == 2 && t.third_calls == 0 && t.added_calls == 1);
}
