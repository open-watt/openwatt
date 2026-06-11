module driver.linux.fdwatch;

version (linux):

// Generic fd readiness waiter for linux backends -- one thread sleeping in
// poll() across every registered watcher's fds. On readiness it posts a
// single coalesced service event to the main loop and blocks until the drain
// completes, so all I/O happens on the main thread and level-triggered poll
// never spins. Watchers provide a collect hook (append fds, called on the
// main thread under the snapshot lock) and a service hook (drain until
// EAGAIN). Call fd_watch_changed() after any change to a watcher's fd set.
//
// This is the readiness-only model: the waiter never touches the fds beyond
// poll(). protocol/ip's SocketWorker is the other model (reads on the worker,
// ships buffers over SPSC rings, IOCP twin on windows); whether the IP stack
// migrates here or BLE migrates there is a dataplane-thread decision for
// later -- this at least gives linux backends one shared waiter.

import urt.array;
import urt.atomic;
import urt.log;
import urt.sync.semaphore;
import urt.sync.spinlock;
import urt.thread;
import urt.time;

import manager;
import manager.plugin;

import urt.internal.sys.posix;

nothrow @nogc:


alias FdWatchService = void delegate() nothrow @nogc;
alias FdWatchCollect = void delegate(ref Array!pollfd fds) nothrow @nogc;

// Register a watcher; the waiter thread starts on first registration.
bool add_fd_watcher(FdWatchService service, FdWatchCollect collect)
    => g_fdwatch.add(service, collect);

void remove_fd_watcher(FdWatchService service)
{
    g_fdwatch.remove(service);
}

// Rebuild the waiter's fd snapshot; call after any fd set change.
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

    Thread _waiter;
    Semaphore _drained;
    Spinlock _lock;
    Array!Watcher _watchers;
    Array!pollfd _snapshot;
    int _wake_fd = -1;
    shared bool _stop;
    shared uint _pending;

    bool add(FdWatchService service, FdWatchCollect collect)
    {
        if (!start())
            return false;
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
        if (_wake_fd < 0)
            return;

        _lock.lock();
        _snapshot.clear();
        foreach (ref w; _watchers[])
            w.collect(_snapshot);
        _lock.unlock();

        wake();
    }

    bool start()
    {
        if (_waiter !is null)
            return true;

        _wake_fd = eventfd(0, efd_nonblock);
        if (_wake_fd < 0)
        {
            log_error("os.fdwatch", "eventfd failed: errno=", last_errno());
            return false;
        }
        _drained.init();
        _waiter = thread_spawn(&run);
        return true;
    }

    void stop()
    {
        if (_waiter)
        {
            atomicStore(_stop, true);
            _drained.signal();
            wake();
            thread_join(_waiter);
            _waiter = null;
        }
        if (_wake_fd >= 0)
        {
            close(_wake_fd);
            _wake_fd = -1;
        }
        _watchers.clear();
    }

    void wake()
    {
        if (_wake_fd < 0)
            return;
        ulong one = 1;
        write(_wake_fd, &one, one.sizeof);
    }

    // main-loop handler posted by the waiter; drains every watcher then re-arms
    void service_all(MonoTime)
    {
        atomicStore(_pending, 0u);

        foreach (ref w; _watchers[])
            w.service();

        rebuild();
        _drained.signal();
    }

    void run()
    {
        Array!pollfd fds;

        while (!atomicLoad(_stop))
        {
            fds.clear();
            fds ~= pollfd(_wake_fd, POLLIN);
            _lock.lock();
            foreach (ref w; _snapshot[])
                fds ~= w;
            _lock.unlock();

            int n = poll(fds[].ptr, fds.length, 1000);
            if (atomicLoad(_stop))
                return;
            if (n <= 0)
                continue;

            if (fds[0].revents != 0)
            {
                ulong v = void;
                read(_wake_fd, &v, v.sizeof);
            }

            bool ready = false;
            foreach (ref f; fds[1 .. $])
            {
                if (f.revents != 0)
                {
                    ready = true;
                    break;
                }
            }
            if (!ready)
                continue;

            if (cas(&_pending, 0u, 1u))
            {
                if (g_app.post_event(&service_all, getTime(), EventPriority.bulk))
                    _drained.wait(); // block until the main loop has drained, or poll respins hot
                else
                    atomicStore(_pending, 0u);
            }
        }
    }
}

enum efd_nonblock = 0x800;

extern(C) nothrow @nogc
{
    int eventfd(uint initval, int flags);
    int* __errno_location();
}

int last_errno() => *__errno_location();
