module driver.linux.supervisor;

version (linux):

import urt.internal.sys.posix : open, close, read, write, fsync, unlink,
                                ssize_t, O_RDONLY, O_WRONLY, O_CREAT, O_TRUNC, O_APPEND,
                                O_NONBLOCK, F_SETFL, fcntl, poll, pollfd, POLLIN, usleep,
                                stat, stat_t;
import urt.io : writeln;
import urt.string.format : tconcat;

import driver.linux.system : install_dir, exit_restart, mode_0755;

nothrow @nogc:

private extern(C) nothrow @nogc
{
    alias pid_t = int;
    pid_t fork();
    int execv(scope const(char)* path, scope const(char*)* argv);
    pid_t waitpid(pid_t pid, int* status, int options);
    int kill(pid_t pid, int sig);
    int pipe(int* fds);
    int dup2(int oldfd, int newfd);
    int setenv(scope const(char)* name, scope const(char)* value, int overwrite);
    int rename(scope const(char)* oldp, scope const(char)* newp);
    void _exit(int code);
}

private enum int SIGKILL = 9;
private enum int backoff_ms = 1000;

// OTA policy: built-in defaults used until (and unless) a running OTA object pushes a
// `cfg` line; once pushed they're adopted and persisted in openwatt.state, so a later
// probationary build that crashes before reporting still gets the last good policy.
private enum int default_commit_secs = 30;   // soak before a probationary slot is trusted
private enum int default_watchdog_ms = 5000;  // no heartbeat within this => app is hung
private enum int default_max_fail = 3;        // probation failures before rollback
__gshared int g_commit_secs = default_commit_secs;
__gshared int g_watchdog_ms = default_watchdog_ms;
__gshared int g_max_fail = default_max_fail;

// The watchdog/launcher. Picks the slot to run (staged update on probation, else
// last-known-good), runs it, and rolls back to good if a probationary slot crashes,
// hangs, or exits early before it proves itself healthy. Never returns while the app
// keeps restarting; returns only on a clean (exit 0) stop or fatal setup error.
int run_supervisor(string[] args)
{
    if (!install_dir().length)
    {
        slog("cannot resolve install directory");
        return 1;
    }

    setup_logging();

    int good, fail;
    int backoff_streak;
    if (!read_state(good, fail))
    {
        if (!bootstrap_slot1())
        {
            slog("bootstrap of slot 1 failed");
            return 1;
        }
        good = 1;
        fail = 0;
        write_state(good, fail);
        slog("bootstrapped slot 1 from running image");
    }

    for (;;)
    {
        int pending = read_next();
        bool probation = false;
        int target;
        if (pending >= 0 && fail < max_fail)
        {
            target = pending;
            probation = true;
        }
        else
        {
            if (pending >= 0)
            {
                slog(tconcat("slot ", pending, " failed ", fail, "x; rolling back to slot ", good));
                clear_next();
                fail = 0;
                write_state(good, fail);
            }
            target = good;
        }

        slog(tconcat("launching slot ", target, probation ? " (on probation)" : ""));

        bool committed;
        EndKind end = launch_and_monitor(target, probation, good, fail, args, committed);

        final switch (end)
        {
            case EndKind.clean:
                slog("app exited cleanly; supervisor stopping");
                return 0;

            case EndKind.restart:
                continue;

            case EndKind.failed:
                if (!committed && probation)
                {
                    ++fail;
                    write_state(good, fail);
                }
                else
                    fail = 0; // good (or already-committed) slot crashed; just relaunch it

                // a slot that soaked (committed) before crashing restarts promptly;
                // one that keeps crashing on startup backs off, capped, to avoid a hot loop.
                backoff_streak = committed ? 0 : backoff_streak + 1;
                int shift = backoff_streak < 5 ? backoff_streak : 5;
                int delay_ms = backoff_ms << shift;
                if (delay_ms > 30_000)
                    delay_ms = 30_000;
                usleep(delay_ms * 1000);
                continue;
        }
    }
}


private:

enum EndKind { clean, restart, failed }

EndKind launch_and_monitor(int target, bool probation, ref int good, ref int fail, string[] args, ref bool committed)
{
    committed = false;

    int[2] fds;
    if (pipe(fds.ptr) != 0)
    {
        slog("pipe() failed");
        return EndKind.failed;
    }
    int rd = fds[0], wr = fds[1];

    pid_t pid = fork();
    if (pid < 0)
    {
        close(rd);
        close(wr);
        slog("fork() failed");
        return EndKind.failed;
    }

    if (pid == 0)
    {
        close(rd);

        char[24] fdbuf = void, slotbuf = void;
        setenv("OW_WATCHDOG_FD", int_to_z(fdbuf, wr), 1);
        setenv("OW_SLOT", int_to_z(slotbuf, target), 1);

        char[4096] pathbuf = void;
        const(char)* slot = slot_path_z(pathbuf, target);

        // argv = slot binary + forwarded args (drop argv[0] and the --supervise flag)
        char[4096] argbuf = void;
        const(char)*[64] argv = void;
        size_t ab = 0, ai = 0;
        argv[ai++] = slot;
        foreach (a; args.length > 1 ? args[1 .. $] : null)
        {
            if (a == "--supervise" || a.length == 0)
                continue;
            if (ab + a.length + 1 > argbuf.length || ai + 1 >= argv.length)
                break;
            argbuf[ab .. ab + a.length] = a[];
            argbuf[ab + a.length] = '\0';
            argv[ai++] = &argbuf[ab];
            ab += a.length + 1;
        }
        argv[ai] = null;

        execv(slot, argv.ptr);
        _exit(127); // exec failed
    }

    close(wr);
    fcntl(rd, F_SETFL, O_NONBLOCK);

    EndKind result = monitor_child(pid, rd, target, probation, good, fail, committed);
    close(rd);
    return result;
}

EndKind monitor_child(pid_t pid, int rd, int target, bool probation, ref int good, ref int fail, ref bool committed)
{
    for (;;)
    {
        pollfd pfd;
        pfd.fd = rd;
        pfd.events = POLLIN;
        int pr = poll(&pfd, 1, watchdog_ms);
        if (pr < 0)
            continue; // EINTR; retry
        if (pr == 0)
        {
            slog(tconcat("no heartbeat for ", watchdog_ms, "ms; killing app"));
            kill(pid, SIGKILL);
            reap(pid);
            return EndKind.failed;
        }

        ubyte[256] buf = void;
        for (;;)
        {
            ssize_t n = read(rd, buf.ptr, buf.length);
            if (n > 0)
            {
                foreach (b; buf[0 .. n])
                {
                    if (b == 'c' && !committed)
                    {
                        committed = true;
                        // promote a probationary slot to good the moment it proves
                        // healthy. A redundant 'c' from an already-good slot must NOT
                        // clear a freshly-staged next-file from a concurrent OTA.
                        if (probation)
                        {
                            good = target;
                            fail = 0;
                            clear_next();
                            write_state(good, fail);
                            slog(tconcat("slot ", target, " committed; now good"));
                        }
                    }
                }
                continue;
            }
            if (n == 0)
                return reap_status(pid); // EOF: app closed the pipe (exited)
            break; // EAGAIN: nothing more right now
        }
    }
}

EndKind reap_status(pid_t pid)
{
    int status;
    waitpid(pid, &status, 0);
    if ((status & 0x7f) == 0) // WIFEXITED
    {
        int code = (status >> 8) & 0xff;
        if (code == 0)
            return EndKind.clean;
        if (code == exit_restart)
            return EndKind.restart;
        slog(tconcat("app exited with code ", code));
        return EndKind.failed;
    }
    slog(tconcat("app terminated by signal ", status & 0x7f));
    return EndKind.failed;
}

void reap(pid_t pid)
{
    int status;
    waitpid(pid, &status, 0);
}


// ---- state / staging files (the supervisor solely owns openwatt.state) ----

bool read_state(ref int good, ref int fail)
{
    char[4096] pb = void;
    const(char)* p = zname(pb, "openwatt.state");
    int fd = open(p, O_RDONLY, 0);
    if (fd < 0)
        return false;
    char[256] buf = void;
    ssize_t n = read(fd, buf.ptr, buf.length);
    close(fd);
    if (n <= 0)
        return false;
    good = parse_field(buf[0 .. n], "good=");
    fail = parse_field(buf[0 .. n], "fail=");
    return good > 0;
}

void write_state(int good, int fail)
{
    char[4096] tb = void, pb = void;
    const(char)* tmp = zname(tb, "openwatt.state.tmp");
    const(char)* dst = zname(pb, "openwatt.state");
    if (!tmp || !dst)
        return;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, mode_0755);
    if (fd < 0)
        return;
    const(char)[] txt = tconcat("good=", good, "\nfail=", fail, "\n");
    write(fd, txt.ptr, txt.length);
    fsync(fd);
    close(fd);
    rename(tmp, dst); // atomic swap; a concurrent reader never sees a half-written file
}

int read_next()
{
    char[4096] pb = void;
    const(char)* p = zname(pb, "openwatt.next");
    int fd = open(p, O_RDONLY, 0);
    if (fd < 0)
        return -1;
    char[64] buf = void;
    ssize_t n = read(fd, buf.ptr, buf.length);
    close(fd);
    if (n <= 0)
        return -1;
    int v = 0;
    bool any = false;
    foreach (c; buf[0 .. n])
    {
        if (c >= '0' && c <= '9')
        {
            v = v * 10 + (c - '0');
            any = true;
        }
        else
            break;
    }
    return any ? v : -1;
}

void clear_next()
{
    char[4096] pb = void;
    const(char)* p = zname(pb, "openwatt.next");
    unlink(p);
}

bool bootstrap_slot1()
{
    char[4096] db = void;
    const(char)* dst = slot_path_z(db, 1);
    if (!dst)
        return false;
    int in_ = open("/proc/self/exe", O_RDONLY, 0);
    if (in_ < 0)
        return false;
    int out_ = open(dst, O_WRONLY | O_CREAT | O_TRUNC, mode_0755);
    if (out_ < 0)
    {
        close(in_);
        return false;
    }
    bool ok = true;
    ubyte[65536] buf = void;
    for (;;)
    {
        ssize_t n = read(in_, buf.ptr, buf.length);
        if (n < 0) { ok = false; break; }
        if (n == 0) break;
        ssize_t off = 0;
        while (off < n)
        {
            ssize_t w = write(out_, buf.ptr + off, n - off);
            if (w <= 0) { ok = false; break; }
            off += w;
        }
        if (!ok) break;
    }
    fsync(out_);
    close(out_);
    close(in_);
    return ok;
}


// ---- small helpers ----

int parse_field(const(char)[] s, const(char)[] key)
{
    for (size_t i = 0; i + key.length <= s.length; ++i)
    {
        if (s[i .. i + key.length] == key)
        {
            int v = 0;
            size_t j = i + key.length;
            while (j < s.length && s[j] >= '0' && s[j] <= '9')
                v = v * 10 + (s[j++] - '0');
            return v;
        }
    }
    return 0;
}

size_t cstrlen(const(char)* s)
{
    size_t n = 0;
    while (s[n])
        ++n;
    return n;
}

const(char)* int_to_z(char[] buf, int v)
{
    size_t i = buf.length;
    buf[--i] = '\0';
    if (v == 0)
        buf[--i] = '0';
    else
    {
        uint x = v;
        while (x)
        {
            buf[--i] = cast(char)('0' + x % 10);
            x /= 10;
        }
    }
    return &buf[i];
}

const(char)* zname(char[] buf, const(char)[] name)
{
    const(char)[] dir = install_dir();
    if (dir.length + name.length + 1 > buf.length)
        return null;
    buf[0 .. dir.length] = dir[];
    buf[dir.length .. dir.length + name.length] = name[];
    buf[dir.length + name.length] = '\0';
    return buf.ptr;
}

const(char)* slot_path_z(char[] buf, int n)
{
    char[24] nb = void;
    const(char)* ns = int_to_z(nb, n);
    size_t nlen = cstrlen(ns);
    const(char)[] dir = install_dir();
    const(char)[] base = "openwatt.";
    if (dir.length + base.length + nlen + 1 > buf.length)
        return null;
    size_t o = 0;
    buf[o .. o + dir.length] = dir[]; o += dir.length;
    buf[o .. o + base.length] = base[]; o += base.length;
    buf[o .. o + nlen] = ns[0 .. nlen]; o += nlen;
    buf[o] = '\0';
    return buf.ptr;
}

// Redirect our (and inherited children's) stdout+stderr to a persistent log so app
// output and crash dumps survive across restarts for follow-up investigation.
void setup_logging()
{
    char[4096] pb = void, ob = void;
    const(char)* logp = zname(pb, "openwatt.log");
    if (!logp)
        return;

    stat_t st;
    if (stat(logp, &st) == 0 && st.st_size > 16 * 1024 * 1024)
    {
        const(char)* oldp = zname(ob, "openwatt.log.1");
        if (oldp)
            rename(logp, oldp);
    }

    int fd = open(logp, O_WRONLY | O_CREAT | O_APPEND, mode_0755);
    if (fd < 0)
        return;
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2)
        close(fd);
}

void slog(const(char)[] msg)
{
    import urt.io : flush;
    import urt.time : getDateTime;
    writeln(getDateTime(), " [ota-supervisor] ", msg);
    flush();
}
