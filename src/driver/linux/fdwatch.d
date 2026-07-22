module driver.linux.fdwatch;

version (linux):

// Fans a dynamic set of fds out to collect/service watchers, backed by the main loop's reactor
// (manager.reactor) rather than a thread. Each watcher provides a collect hook (append its fds)
// and a service hook (drain them). All watchers' fds live in the reactor's epoll set as one pool
// sharing a single coalesced drain: when any pooled fd is ready, the reactor runs service_all()
// once per wait pass, which services every watcher and re-collects. Call fd_watch_changed() after
// any change to a watcher's fd set.
//
// This is the readiness-only model: the reactor never touches the fds beyond epoll; the watcher's
// service() does the actual I/O on the main thread. protocol/ip drives sockets through the same
// reactor via the completion-shaped watch_io/IoOp layer instead.

import urt.array;

import manager;
import manager.plugin;

import urt.internal.sys.posix : pollfd;

nothrow @nogc:


alias FdWatchService = void delegate() nothrow @nogc;
alias FdWatchCollect = void delegate(ref Array!pollfd fds) nothrow @nogc;

bool add_fd_watcher(FdWatchService service, FdWatchCollect collect)
    => g_fdwatch.add(service, collect);

void remove_fd_watcher(FdWatchService service)
{
    g_fdwatch.remove(service);
}

void fd_watch_changed()
{
    g_fdwatch.rebuild();
}


class LinuxFdWatchModule : Module
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
    bool _drain_set;

    bool add(FdWatchService service, FdWatchCollect collect)
    {
        if (!_drain_set)
        {
            g_app.reactor.set_pool_drain(&service_all);
            _drain_set = true;
        }
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
            w.collect(_desired);
        g_app.reactor.set_pool_fds(_desired[]);
    }

    // reactor-driven: any pooled fd ready runs this once per wait pass. Drain every watcher then
    // re-collect (a service() may have opened/closed fds, matching the old post-service rebuild).
    void service_all()
    {
        foreach (ref w; _watchers[])
            w.service();
        rebuild();
    }

    void stop()
    {
        _watchers.clear();
        _desired.clear();
        if (_drain_set)
        {
            g_app.reactor.set_pool_fds(null);
            g_app.reactor.set_pool_drain(null);
            _drain_set = false;
        }
    }
}
