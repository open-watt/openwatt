module manager.reactor;

import urt.array;
import urt.atomic;
import urt.mem.allocator : defaultAllocator;
import urt.time;

version (Windows)
{
    import urt.internal.sys.windows.basetsd : HANDLE, ULONG_PTR;
    import urt.internal.sys.windows.windef : DWORD;
    import urt.internal.sys.windows.winbase : OVERLAPPED, INVALID_HANDLE_VALUE, INFINITE, CancelIoEx,
        CloseHandle, CreateIoCompletionPort, GetLastError, GetQueuedCompletionStatus,
        PostQueuedCompletionStatus, ReadFile;
    import urt.internal.sys.windows.winerror : ERROR_IO_PENDING, ERROR_OPERATION_ABORTED;

    enum bool has_reactor_io = true;
    alias OsFile = HANDLE;
}
else version (linux)
{
    import urt.internal.stdc.errno : EAGAIN, EWOULDBLOCK, EINTR;
    import urt.internal.sys.posix;
    import urt.result : errno_result;

    enum bool has_reactor_io = true;
    alias OsFile = int;
}
else
{
    import urt.sync.event;

    enum bool has_reactor_io = false;
}

nothrow @nogc:


// Delivery callbacks run on the main thread, from inside Reactor.wait().
alias IoDataHandler  = void delegate(const(void)[] data, MonoTime rx_time) nothrow @nogc;
alias IoErrorHandler = void delegate() nothrow @nogc;

version (Windows)
{
    // The layer under watch_io: callers associate() a handle with the reactor's completion port,
    // submit their own overlapped ops to it, and get each op's completion delivered on the main
    // thread. IoOp must be the FIRST member of the caller's op struct so a completion's
    // OVERLAPPED* casts back to it, and the op must stay alive until its completion (or
    // cancellation completion) has been delivered.
    struct IoOp
    {
        OVERLAPPED ov;
        void delegate(IoOp* op, bool ok, uint bytes, uint err) nothrow @nogc on_complete;
    }
}
else version (linux)
{
    enum IoReady : ubyte
    {
        readable = 1 << 0,
        writable = 1 << 1,
        error    = 1 << 2,
    }

    // The layer under watch_io: raw level-triggered readiness; the handler does its own I/O on
    // the main thread and must drain to would-block (or unwatch on error) or the loop respins hot.
    alias IoReadyHandler = void delegate(IoReady ready) nothrow @nogc;
}

// The main loop's wake primitive AND its I/O wait. The wake keeps the manual-reset latch semantics
// of urt.sync.event.Event (set/reset/wait), and the same wait dispatches watched I/O inline on the
// main thread: readiness from an epoll set on linux (registration is persistent - epoll_ctl once
// per fd lifecycle, O(ready) re-entry), completions from an IO completion port on windows (one
// overlapped read pending per watch). No standing reader threads, no cross-thread marshalling.
// See TODO.md "Async I/O end-state: the main loop's wait primitive IS the reactor".
//
// The latch is the _signalled flag; the kernel-side signal exists only to break the sleep. set()
// emits at most one kernel signal per latch cycle, so a burst of posts costs one syscall total.
// set() is safe from any thread; everything else belongs to the main thread.
//
// watch_io() delivers a byte source: on_data fires per chunk, on_error asks the owner to
// recover/restart (the reactor stops watching an errored file; the owner still unwatches it).
// The owner closes the file AFTER unwatch_io(). The read path is tuned for non-blocking byte
// devices (VMIN=0 ttys): a 0-byte read means drained, not EOF - sockets get their own event
// vocabulary when they migrate here.
struct Reactor
{
nothrow @nogc:
    @disable this(this);

    bool init()
    {
        version (Windows)
        {
            _iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
            return _iocp !is null;
        }
        else version (linux)
        {
            _epoll = epoll_create1(EPOLL_CLOEXEC);
            if (_epoll < 0)
                return false;
            _wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
            if (_wake_fd < 0)
            {
                close(_epoll);
                _epoll = -1;
                return false;
            }
            epoll_event ev;
            ev.events = EPOLLIN;
            ev.data.ptr = null;             // null marks the wake eventfd
            if (epoll_ctl(_epoll, EPOLL_CTL_ADD, _wake_fd, &ev) != 0)
            {
                close(_wake_fd);
                _wake_fd = -1;
                close(_epoll);
                _epoll = -1;
                return false;
            }
            return true;
        }
        else
            return _event.init();
    }

    void destroy()
    {
        version (Windows)
        {
            if (_iocp is null)
                return;
            // owners should have unwatched already; cancel and reap any stragglers so their
            // entries can be freed without the kernel completing into freed memory
            uint outstanding = 0;
            foreach (e; _watches[])
            {
                if (e.outstanding)
                {
                    CancelIoEx(e.file, null);
                    ++outstanding;
                }
            }
            while (outstanding > 0)
            {
                DWORD bytes;
                ULONG_PTR key;
                OVERLAPPED* ov;
                int ok = GetQueuedCompletionStatus(_iocp, &bytes, &key, &ov, 1000);
                if (ov is null)
                {
                    if (!ok)
                        break;      // timeout: don't hang shutdown on a wedged driver
                    continue;       // stray wake packet
                }
                // only reap our own byte-source reads; foreign IoOps at teardown just leak
                // (their owners should have drained before the reactor is destroyed)
                foreach (e; _watches[])
                {
                    if (cast(OVERLAPPED*)&e.op is ov)
                    {
                        e.outstanding = false;
                        --outstanding;
                        break;
                    }
                }
            }
            foreach (e; _watches[])
                defaultAllocator().freeT(e);
            _watches.clear();
            CloseHandle(_iocp);
            _iocp = null;
        }
        else version (linux)
        {
            foreach (e; _watches[])
                defaultAllocator().freeT(e);
            _watches.clear();
            _pool_fds.clear();          // pooled fds are owned/closed by their watchers, not us
            if (_wake_fd >= 0)
            {
                close(_wake_fd);
                _wake_fd = -1;
            }
            if (_epoll >= 0)
            {
                close(_epoll);
                _epoll = -1;
            }
        }
        else
            _event.destroy();
    }

    void set()
    {
        version (Windows)
        {
            if (cas(&_signalled, false, true))
                PostQueuedCompletionStatus(_iocp, 0, 0, null);
        }
        else version (linux)
        {
            if (cas(&_signalled, false, true))
            {
                ulong one = 1;
                write(_wake_fd, &one, one.sizeof);
            }
        }
        else
            _event.set();
    }

    void reset()
    {
        version (Windows)
        {
            // any stale wake packet is consumed by wait()'s sweep; only the latch clears here
            atomicStore!(MemoryOrder.release)(_signalled, false);
        }
        else version (linux)
        {
            atomicStore!(MemoryOrder.release)(_signalled, false);
            ulong count = void;
            read(_wake_fd, &count, count.sizeof);
        }
        else
            _event.reset();
    }

    bool wait(Duration timeout)
    {
        version (Windows)
        {
            // always sweep queued completions first so I/O never starves behind a latched wake;
            // dispatched I/O counts as a wake so the loop can service any follow-up promptly
            if (sweep() | atomicLoad!(MemoryOrder.acquire)(_signalled))
                return true;
            if (timeout <= Duration.zero)
                return false;

            long ms = wait_ms(timeout);
            if (ms >= INFINITE)
                ms = INFINITE - 1;
            DWORD bytes;
            ULONG_PTR key;
            OVERLAPPED* ov;
            int ok = GetQueuedCompletionStatus(_iocp, &bytes, &key, &ov, cast(DWORD)ms);
            if (!ok && ov is null)
                return atomicLoad!(MemoryOrder.acquire)(_signalled);    // timeout
            handle_completion(ov, ok != 0, bytes);
            sweep();
            return true;
        }
        else version (linux)
        {
            compact_watches();

            // always sweep ready fds first so I/O never starves behind a latched wake;
            // dispatched I/O counts as a wake so the loop can service any follow-up promptly
            epoll_event[16] evs = void;
            bool did_io = false;
            int n = epoll_wait(_epoll, evs.ptr, cast(int)evs.length, 0);
            if (n > 0)
                did_io = dispatch(evs.ptr, n);
            if (did_io || atomicLoad!(MemoryOrder.acquire)(_signalled))
                return true;
            if (timeout <= Duration.zero)
                return false;

            long ms = wait_ms(timeout);
            if (ms > int.max)
                ms = int.max;
            n = epoll_wait(_epoll, evs.ptr, cast(int)evs.length, cast(int)ms);
            if (n > 0)
                dispatch(evs.ptr, n);
            return n > 0 || atomicLoad!(MemoryOrder.acquire)(_signalled);
        }
        else
        {
            if (atomicLoad!(MemoryOrder.acquire)(_signalled))
                return true;
            return _event.wait(timeout);
        }
    }

    static if (has_reactor_io)
    {
        // eof_on_zero flips the read-of-0 meaning: on a byte device 0 means drained (VMIN=0 tty),
        // on a stream socket it means the peer closed - fire on_error so the owner can recover.
        bool watch_io(OsFile file, IoDataHandler on_data, IoErrorHandler on_error, bool eof_on_zero = false)
        {
            version (Windows)
            {
                if (!associate(file))
                    return false;
                WatchEntry* e = defaultAllocator().allocT!WatchEntry();
                if (!e)
                    return false;
                e.op.on_complete = &e.complete;
                e.owner = &this;
                e.file = file;
                e.on_data = on_data;
                e.on_error = on_error;
                e.eof_on_zero = eof_on_zero;
                if (!e.post_read())
                {
                    defaultAllocator().freeT(e);
                    return false;
                }
                _watches ~= e;
                return true;
            }
            else
            {
                if (_epoll < 0)
                    return false;
                WatchEntry* e = defaultAllocator().allocT!WatchEntry();
                if (!e)
                    return false;
                e.file = file;
                e.on_data = on_data;
                e.on_error = on_error;
                e.eof_on_zero = eof_on_zero;
                epoll_event ev;
                ev.events = EPOLLIN;
                ev.data.ptr = e;
                if (epoll_ctl(_epoll, EPOLL_CTL_ADD, file, &ev) != 0)
                {
                    defaultAllocator().freeT(e);
                    return false;
                }
                _watches ~= e;
                return true;
            }
        }

        version (Windows)
        {
            // associate a handle with the completion port so pending IoOps deliver through wait()
            bool associate(HANDLE file)
                => _iocp !is null && CreateIoCompletionPort(file, _iocp, 0, 0) !is null;
        }
        else
        {
            // raw readiness watch; interest is EPOLLOUT while want_write (a connecting socket),
            // EPOLLIN otherwise. errors are always reported; the handler must act on them.
            bool watch_fd(int fd, bool want_write, IoReadyHandler on_ready)
            {
                if (_epoll < 0)
                    return false;
                WatchEntry* e = defaultAllocator().allocT!WatchEntry();
                if (!e)
                    return false;
                e.file = fd;
                e.on_ready = on_ready;
                epoll_event ev;
                ev.events = want_write ? EPOLLOUT : EPOLLIN;
                ev.data.ptr = e;
                if (epoll_ctl(_epoll, EPOLL_CTL_ADD, fd, &ev) != 0)
                {
                    defaultAllocator().freeT(e);
                    return false;
                }
                _watches ~= e;
                return true;
            }

            // switch interest (a connected socket moves from write-wait to read)
            void modify_fd(int fd, bool want_write)
            {
                foreach (e; _watches[])
                {
                    if (e.file != fd || e.dead)
                        continue;
                    epoll_event ev;
                    ev.events = want_write ? EPOLLOUT : EPOLLIN;
                    ev.data.ptr = e;
                    epoll_ctl(_epoll, EPOLL_CTL_MOD, fd, &ev);
                    return;
                }
            }

            // The fd-watcher pool (driver.linux.fdwatch): a dynamic set of readiness-only fds that
            // share ONE coalesced drain. Any pooled fd becoming ready runs drain() once at the end
            // of the epoll batch. All pooled fds carry the same epoll sentinel (&_pool_tag), so the
            // pool needs no per-fd allocation - membership is reconciled by fd number.
            void set_pool_drain(void delegate() nothrow @nogc drain)
            {
                _pool_drain = drain;
            }

            void set_pool_fds(scope const(pollfd)[] desired)
            {
                if (_epoll < 0)
                    return;
                for (size_t i = _pool_fds.length; i-- > 0; )
                {
                    bool keep = false;
                    foreach (ref d; desired)
                        if (d.fd == _pool_fds[i].fd) { keep = true; break; }
                    if (!keep)
                    {
                        epoll_ctl(_epoll, EPOLL_CTL_DEL, _pool_fds[i].fd, null);
                        _pool_fds.removeSwapLast(i);
                    }
                }
                foreach (ref d; desired)
                {
                    uint want = (d.events & POLLOUT) ? EPOLLOUT : EPOLLIN;
                    bool found = false;
                    foreach (ref p; _pool_fds[])
                    {
                        if (p.fd != d.fd)
                            continue;
                        found = true;
                        if (p.events != want)
                        {
                            epoll_event ev;
                            ev.events = want;
                            ev.data.ptr = &_pool_tag;
                            if (epoll_ctl(_epoll, EPOLL_CTL_MOD, d.fd, &ev) == 0)
                                p.events = want;
                        }
                        break;
                    }
                    if (!found)
                    {
                        epoll_event ev;
                        ev.events = want;
                        ev.data.ptr = &_pool_tag;
                        if (epoll_ctl(_epoll, EPOLL_CTL_ADD, d.fd, &ev) == 0)
                            _pool_fds ~= PoolFd(d.fd, want);
                    }
                }
            }
        }

        void unwatch_io(OsFile file)
        {
            version (Windows)
            {
                foreach (i; 0 .. _watches.length)
                {
                    WatchEntry* e = _watches[i];
                    if (e.file != file || e.dead)
                        continue;
                    if (e.outstanding)
                    {
                        // reaped (and freed) when the cancelled read's completion arrives
                        CancelIoEx(e.file, null);
                        e.dead = true;
                    }
                    else
                    {
                        _watches.removeSwapLast(i);
                        defaultAllocator().freeT(e);
                    }
                    return;
                }
            }
            else
            {
                foreach (i; 0 .. _watches.length)
                {
                    WatchEntry* e = _watches[i];
                    if (e.file != file || e.dead)
                        continue;
                    epoll_ctl(_epoll, EPOLL_CTL_DEL, file, null);
                    e.dead = true;      // freed by compact_watches; a fetched batch may still hold it
                    return;
                }
            }
        }
    }

private:
    shared bool _signalled;

    version (Windows)
    {
        // a byte-source watch: the reactor's own client of the IoOp layer
        struct WatchEntry
        {
        nothrow @nogc:
            IoOp op;            // the pending read; must be first so its completion finds us
            Reactor* owner;
            HANDLE file;
            IoDataHandler on_data;
            IoErrorHandler on_error;
            bool outstanding;
            bool dead;
            bool eof_on_zero;
            ubyte[2048] buf;

            // submit (or resubmit) the persistent overlapped read. a synchronous success still
            // queues a completion packet, so it needs no special handling here.
            bool post_read()
            {
                op.ov = OVERLAPPED.init;
                outstanding = true;
                DWORD got;
                if (!ReadFile(file, buf.ptr, cast(DWORD)buf.length, &got, &op.ov) &&
                    GetLastError() != ERROR_IO_PENDING)
                {
                    outstanding = false;
                    return false;
                }
                return true;
            }

            void complete(IoOp*, bool ok, uint bytes, uint err)
            {
                outstanding = false;
                if (dead)
                {
                    // unwatched while the read was in flight; reap the entry
                    owner.reap(&this);
                    return;
                }
                if (ok && bytes > 0)
                {
                    on_data(buf[0 .. bytes], getTime());
                    if (!dead && !post_read())
                        on_error();
                }
                else if (ok && bytes == 0 && eof_on_zero)
                {
                    // stream socket peer closed: stop reading, let the owner recover
                    on_error();
                }
                else if (ok || err == ERROR_OPERATION_ABORTED)
                {
                    // device idle tick, or a purge with the port still live: re-arm
                    if (!post_read())
                        on_error();
                }
                else
                {
                    // genuine error (device removed etc.): stop reading, let the owner recover.
                    // the entry stays until the owner unwatches; nothing is outstanding on it.
                    on_error();
                }
            }
        }

        HANDLE _iocp;
        Array!(WatchEntry*) _watches;

        void reap(WatchEntry* e)
        {
            foreach (i; 0 .. _watches.length)
                if (_watches[i] is e) { _watches.removeSwapLast(i); break; }
            defaultAllocator().freeT(e);
        }
    }
    else version (linux)
    {
        struct WatchEntry
        {
            int file;
            IoDataHandler on_data;
            IoErrorHandler on_error;
            IoReadyHandler on_ready;    // set for raw readiness watches; on_data/on_error unused
            bool dead;
            bool eof_on_zero;
        }

        struct PoolFd { int fd; uint events; }

        int _epoll = -1;
        int _wake_fd = -1;
        Array!(WatchEntry*) _watches;
        Array!PoolFd _pool_fds;
        void delegate() nothrow @nogc _pool_drain;
        bool _pool_pending;
    }
    else
        Event _event;

    // both waits are millisecond-granular; round up so a sub-ms deadline sleeps rather than
    // spinning the loop (timers fire against getTime(), so the sub-ms oversleep is harmless)
    static long wait_ms(Duration timeout)
        => (timeout.as!"nsecs" + 999_999) / 1_000_000;

    version (Windows)
    {
        // drain everything already queued, without blocking; true if any I/O completion was handled
        bool sweep()
        {
            bool did_io = false;
            while (true)
            {
                DWORD bytes;
                ULONG_PTR key;
                OVERLAPPED* ov;
                int ok = GetQueuedCompletionStatus(_iocp, &bytes, &key, &ov, 0);
                if (!ok && ov is null)
                    return did_io;
                did_io |= ov !is null;
                handle_completion(ov, ok != 0, bytes);
            }
        }

        void handle_completion(OVERLAPPED* ov, bool ok, DWORD bytes)
        {
            if (ov is null)
                return;             // wake packet: its arrival already broke the sleep
            uint err = ok ? 0 : GetLastError();
            IoOp* op = cast(IoOp*)ov;
            op.on_complete(op, ok, bytes, err);
        }
    }
    else version (linux)
    {
        // true if any entry event (not just the wake eventfd) was handled
        bool dispatch(epoll_event* evs, int n)
        {
            bool did_io = false;
            MonoTime now = getTime();
            foreach (i; 0 .. n)
            {
                void* ptr = evs[i].data.ptr;
                if (ptr is null)
                    continue;       // the wake eventfd, drained at reset()
                if (ptr is &_pool_tag)
                {
                    // pooled fd: coalesce; the single drain runs once after the batch. Any event
                    // (incl. EPOLLERR/EPOLLHUP) runs the drain so the watcher reacts - the same
                    // contract as the old poll() waiter. The reactor can't DEL a specific pool fd
                    // here (all share &_pool_tag, no fd), so a watcher that keeps collecting a
                    // persistently-errored fd will keep the loop from idling; watchers must drop a
                    // dead fd from their collect (or restart). See TODO.md.
                    did_io = true;
                    _pool_pending = true;
                    continue;
                }
                WatchEntry* e = cast(WatchEntry*)ptr;
                if (e.dead)
                    continue;       // unwatched mid-batch
                did_io = true;
                uint evt = evs[i].events;
                if (e.on_ready !is null)
                {
                    // raw readiness watch: the owner does its own I/O (and must unwatch on error)
                    uint flags;
                    if (evt & EPOLLIN)
                        flags |= IoReady.readable;
                    if (evt & EPOLLOUT)
                        flags |= IoReady.writable;
                    if (evt & (EPOLLERR | EPOLLHUP))
                        flags |= IoReady.error;
                    e.on_ready(cast(IoReady)flags);
                    continue;
                }
                if (evt & (EPOLLERR | EPOLLHUP))
                {
                    // stop reporting immediately so a hup'd fd can't spin the loop while the
                    // owner's restart works through the state machine; the owner still unwatches
                    epoll_ctl(_epoll, EPOLL_CTL_DEL, e.file, null);
                    e.on_error();
                    continue;
                }
                if (evt & EPOLLIN)
                    drain(e, now);
            }
            if (_pool_pending)
            {
                _pool_pending = false;
                if (_pool_drain !is null)
                    _pool_drain();      // fans out to every fd-watcher's service() and re-collects
            }
            return did_io;
        }

        void drain(WatchEntry* e, MonoTime now)
        {
            ubyte[2048] buf = void;
            while (!e.dead)
            {
                ssize_t n = read(e.file, buf.ptr, buf.length);
                if (n > 0)
                {
                    e.on_data(buf[0 .. n], now);
                    continue;
                }
                // VMIN=0/VTIME=0 ttys return 0 (not EAGAIN) when no data is ready: not an error.
                // A stream socket returns 0 on peer close, which eof_on_zero routes to on_error.
                if (n == 0 && !e.eof_on_zero)
                    return;
                if (n < 0 && is_transient_errno())
                    return;
                epoll_ctl(_epoll, EPOLL_CTL_DEL, e.file, null);
                e.on_error();
                return;
            }
        }

        // dead entries are only marked during a dispatch batch; free them before the next wait
        void compact_watches()
        {
            for (size_t i = _watches.length; i-- > 0; )
            {
                if (_watches[i].dead)
                {
                    defaultAllocator().freeT(_watches[i]);
                    _watches.removeSwapLast(i);
                }
            }
        }

        static bool is_transient_errno()
        {
            uint e = errno_result().system_code;
            return e == EAGAIN || e == EWOULDBLOCK || e == EINTR;
        }
    }
}


unittest
{
    Reactor r;
    assert(r.init());

    // unset: immediate timeout, and a real (short) sleep times out
    assert(!r.wait(Duration.zero));
    assert(!r.wait(msecs(10)));

    // set latches: wait returns immediately and stays latched until reset
    r.set();
    assert(r.wait(seconds(1)));
    assert(r.wait(Duration.zero));

    r.reset();
    assert(!r.wait(Duration.zero));

    // set after a reset latches again (fresh kernel signal each latch cycle)
    r.set();
    assert(r.wait(seconds(1)));
    r.reset();

    version (linux)
    {
        // watch a pipe: data pushed through it is delivered from inside wait()
        static struct Sink
        {
        nothrow @nogc:
            char[64] got;
            size_t len;
            uint errors;
            void on_data(const(void)[] data, MonoTime)
            {
                got[len .. len + data.length] = cast(const(char)[])data[];
                len += data.length;
            }
            void on_error() { ++errors; }
        }
        Sink sink;

        int[2] p;
        assert(pipe2(p.ptr, O_NONBLOCK) == 0);
        assert(r.watch_io(p[0], &sink.on_data, &sink.on_error));

        write(p[1], "hello".ptr, 5);
        assert(r.wait(seconds(1)));

        write(p[1], " reactor".ptr, 8);
        assert(r.wait(seconds(1)));
        assert(sink.got[0 .. sink.len] == "hello reactor");
        assert(sink.errors == 0);

        r.unwatch_io(p[0]);
        close(p[0]);
        close(p[1]);

        // unwatched: no further delivery, wait times out quietly
        assert(!r.wait(msecs(10)));
        assert(sink.len == 13);

        // fd-watcher pool: two pipes share one coalesced drain that reads whatever is ready
        static struct Pool
        {
        nothrow @nogc:
            int[2] a, b;
            uint drains;
            char[64] got;
            size_t len;
            void collect(ref Array!pollfd fds)
            {
                fds ~= pollfd(a[0], POLLIN);
                fds ~= pollfd(b[0], POLLIN);
            }
            void drain_one(int fd)
            {
                char[32] buf = void;
                for (;;)
                {
                    ssize_t n = read(fd, buf.ptr, buf.length);
                    if (n <= 0)
                        return;
                    got[len .. len + n] = buf[0 .. n];
                    len += n;
                }
            }
            void service()
            {
                ++drains;
                drain_one(a[0]);
                drain_one(b[0]);
            }
        }
        Pool pool;
        assert(pipe2(pool.a.ptr, O_NONBLOCK) == 0);
        assert(pipe2(pool.b.ptr, O_NONBLOCK) == 0);
        r.set_pool_drain(&pool.service);

        Array!pollfd desired;
        pool.collect(desired);
        r.set_pool_fds(desired[]);

        // both pipes ready in one batch -> a single coalesced service() call
        write(pool.a[1], "aa".ptr, 2);
        write(pool.b[1], "bbb".ptr, 3);
        assert(r.wait(seconds(1)));
        assert(pool.drains == 1);
        assert(pool.len == 5);

        // drained to empty -> no further wake
        assert(!r.wait(msecs(10)));
        assert(pool.drains == 1);

        // remove one fd from the set; the other still delivers
        Array!pollfd shrunk;
        shrunk ~= pollfd(pool.b[0], POLLIN);
        r.set_pool_fds(shrunk[]);
        write(pool.a[1], "x".ptr, 1);       // a is no longer watched
        assert(!r.wait(msecs(10)));
        assert(pool.drains == 1);
        write(pool.b[1], "y".ptr, 1);
        assert(r.wait(seconds(1)));
        assert(pool.drains == 2);

        r.set_pool_fds(null);
        r.set_pool_drain(null);
        close(pool.a[0]); close(pool.a[1]);
        close(pool.b[0]); close(pool.b[1]);
    }

    r.destroy();
}


private:

version (linux)
{
    extern(C) nothrow @nogc
    {
        int eventfd(uint initval, int flags);
        int epoll_create1(int flags);
        int epoll_ctl(int epfd, int op, int fd, epoll_event* event);
        int epoll_wait(int epfd, epoll_event* events, int maxevents, int timeout);
        int pipe2(int* pipefd, int flags);      // unittest only
    }

    enum EFD_NONBLOCK   = 0x800;
    enum EFD_CLOEXEC    = 0x80000;
    enum EPOLL_CLOEXEC  = 0x80000;

    enum EPOLL_CTL_ADD  = 1;
    enum EPOLL_CTL_DEL  = 2;
    enum EPOLL_CTL_MOD  = 3;

    enum EPOLLIN    = 0x001;
    enum EPOLLOUT   = 0x004;
    enum EPOLLERR   = 0x008;
    enum EPOLLHUP   = 0x010;

    enum O_NONBLOCK = 0x800;                    // unittest only

    // shared epoll data.ptr sentinel for every fd-watcher-pool fd; its address just has to be
    // distinct from null (the wake eventfd) and from any WatchEntry* (heap-allocated elsewhere)
    __gshared ubyte _pool_tag;

    union EpollData
    {
        void*   ptr;
        int     fd;
        uint    u32;
        ulong   u64;
    }

    // packed on x86_64 (glibc __EPOLL_PACKED); natural alignment everywhere else (arm64 = the Pi)
    version (X86_64)
    {
        align(1) struct epoll_event
        {
        align(1):
            uint events;
            EpollData data;
        }
    }
    else
    {
        struct epoll_event
        {
            uint events;
            EpollData data;
        }
    }
}
