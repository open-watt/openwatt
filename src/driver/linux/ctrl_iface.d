module driver.linux.ctrl_iface;

version (linux):

import urt.conv;
import urt.log;
import urt.string;
import urt.time;

import urt.internal.sys.posix;

nothrow @nogc:


// Shared client for the wpa_supplicant / hostapd "ctrl_iface" protocol.
// Both daemons expose a Unix SOCK_DGRAM socket per managed interface; the
// command/response wire format is identical (single ASCII datagram in,
// single datagram out, async events prefixed with "<N>"). The only thing
// that differs between them is the socket directory and a tag we use for
// our local-end bind path.
//
// We bind our own end too so the daemon knows where to deliver replies.
// We don't ATTACH for events -- callers poll STATUS / SIGNAL_POLL / STA from
// their own update() loop. This keeps the model synchronous and avoids
// kernel-level event queuing surprises.

struct CtrlIface
{
nothrow @nogc:

    // remote_dir: e.g. "/var/run/wpa_supplicant" (no trailing slash).
    // local_tag:  short tag used in /tmp/openwatt_<tag>_... so two clients
    //             (one for wpa_supplicant, one for hostapd) on the same
    //             iface don't collide on their bind paths.
    bool open(const(char)[] iface, const(char)[] remote_dir, const(char)[] local_tag)
    {
        if (iface.length == 0 || iface.length >= 64)
        {
            writeError("ctrl_iface: iface name invalid: '", iface, "'");
            return false;
        }

        fd = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (fd < 0)
        {
            writeError("ctrl_iface(", local_tag, "): socket() failed: errno=", last_errno());
            return false;
        }

        sockaddr_un local;
        local.sun_family = AF_UNIX;
        size_t lp = format_local_path(local.sun_path[], local_tag, iface);
        if (lp == 0 || lp >= local.sun_path.length)
        {
            writeError("ctrl_iface(", local_tag, "): local path overflow");
            close_fd();
            return false;
        }
        _local_path[0 .. lp] = local.sun_path[0 .. lp];
        _local_path_len = lp;

        unlink(local.sun_path.ptr);  // stale leftover from a previous run
        if (bind(fd, &local, cast(uint)(ushort.sizeof + lp + 1)) < 0)
        {
            writeError("ctrl_iface(", local_tag, "): bind('", local.sun_path.ptr[0 .. lp], "') failed: errno=", last_errno());
            close_fd();
            return false;
        }

        sockaddr_un remote;
        remote.sun_family = AF_UNIX;
        size_t rp = format_remote_path(remote.sun_path[], remote_dir, iface);
        if (rp == 0 || rp >= remote.sun_path.length)
        {
            writeError("ctrl_iface(", local_tag, "): remote path overflow");
            close_fd();
            return false;
        }
        if (connect(fd, &remote, cast(uint)(ushort.sizeof + rp + 1)) < 0)
        {
            // Connect failures are spammy on retries (open() runs every tick
            // when the daemon isn't reachable). Log once per failure cycle.
            int e = last_errno();
            if (!_logged_connect_fail || _last_logged_errno != e)
            {
                writeError("ctrl_iface(", local_tag, "): connect('", remote.sun_path.ptr[0 .. rp], "') failed (is the daemon running on '", iface, "'?): errno=", e);
                _logged_connect_fail = true;
                _last_logged_errno = e;
            }
            close_fd();
            return false;
        }
        _logged_connect_fail = false;

        // Cap recv blocking. STATUS/SIGNAL_POLL respond instantly; CONNECT-
        // class commands return "OK" before association completes (state
        // changes are observable via subsequent STATUS polls).
        timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 200_000;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, timeval.sizeof);

        return true;
    }

    void close()
    {
        close_fd();
    }

    bool valid() const pure
        => fd >= 0;

    // Send `cmd`, read response into `buf`. Drops <N>-prefixed unsolicited
    // events that may have been queued (defensive -- we don't ATTACH, but
    // the kernel still buffers).
    bool send_command(const(char)[] cmd, char[] buf, out size_t out_len)
    {
        if (fd < 0)
            return false;

        if (send(fd, cmd.ptr, cmd.length, 0) != cast(ptrdiff_t)cmd.length)
        {
            writeError("ctrl_iface: send failed: errno=", last_errno());
            return false;
        }

        for (uint tries = 0; tries < 4; ++tries)
        {
            ptrdiff_t n = recv(fd, buf.ptr, buf.length, 0);
            if (n < 0)
            {
                int e = last_errno();
                if (e == EAGAIN_ || e == EWOULDBLOCK_)
                    return false;
                if (e == EINTR_)
                    continue;
                writeError("ctrl_iface: recv failed: errno=", e);
                return false;
            }
            if (n == 0)
                continue;
            if (buf[0] == '<')
                continue;
            out_len = cast(size_t)n;
            return true;
        }
        return false;
    }

    int fd = -1;

private:
    char[108] _local_path;
    size_t _local_path_len;
    bool _logged_connect_fail;
    int _last_logged_errno;

    void close_fd()
    {
        if (fd >= 0)
        {
            urt.internal.sys.posix.close(fd);
            fd = -1;
        }
        if (_local_path_len > 0)
        {
            char[109] tmp;
            tmp[0 .. _local_path_len] = _local_path[0 .. _local_path_len];
            tmp[_local_path_len] = 0;
            unlink(tmp.ptr);
            _local_path_len = 0;
        }
    }
}


// Walk a "key=value\n"-style response and yield (key, value) for each
// non-empty line. Used for STATUS, SIGNAL_POLL, and most hostapd queries.
void foreach_kv(const(char)[] response, scope void delegate(const(char)[] key, const(char)[] value) nothrow @nogc on_kv)
{
    while (response.length > 0)
    {
        size_t nl = 0;
        while (nl < response.length && response[nl] != '\n')
            ++nl;
        auto line = response[0 .. nl];
        if (nl < response.length)
            response = response[nl + 1 .. $];
        else
            response = null;

        size_t eq = 0;
        while (eq < line.length && line[eq] != '=')
            ++eq;
        if (eq == 0 || eq == line.length)
            continue;
        on_kv(line[0 .. eq], line[eq + 1 .. $]);
    }
}


// RSSI dBm -> 0..100 quality scale (Windows-style). -50 or better -> 100,
// -100 or worse -> 0, linear in between.
ubyte rssi_to_quality(int rssi_dbm) pure
{
    if (rssi_dbm >= -50)
        return 100;
    if (rssi_dbm <= -100)
        return 0;
    return cast(ubyte)(2 * (rssi_dbm + 100));
}


private:

enum AF_UNIX     = 1;
enum SOCK_DGRAM  = 2;
enum SOL_SOCKET  = 1;
enum SO_RCVTIMEO = 20;

enum int EAGAIN_      = 11;
enum int EWOULDBLOCK_ = 11;
enum int EINTR_       = 4;

struct sockaddr_un
{
    ushort sun_family;
    char[108] sun_path = 0;
}

struct timeval
{
    long tv_sec;
    long tv_usec;
}

extern(C) nothrow @nogc
{
    int socket(int domain, int type, int protocol);
    int bind(int fd, const(void)* addr, uint addrlen);
    int connect(int fd, const(void)* addr, uint addrlen);
    int setsockopt(int fd, int level, int optname, const(void)* optval, uint optlen);
    ptrdiff_t send(int fd, const(void)* buf, size_t len, int flags);
    ptrdiff_t recv(int fd, void* buf, size_t len, int flags);
    int getpid();
    int* __errno_location();
}

int last_errno() => *__errno_location();

__gshared uint g_local_counter;

size_t format_local_path(char[] dst, const(char)[] tag, const(char)[] iface)
{
    enum prefix = "/tmp/openwatt_";
    size_t need = prefix.length + tag.length + 1 + 12 /*pid*/ + 1 + 12 /*counter*/ + 1 + iface.length;
    if (need > dst.length)
        return 0;

    int pid = getpid();
    uint n = g_local_counter++;

    size_t i = 0;
    dst[i .. i + prefix.length] = prefix;
    i += prefix.length;
    foreach (c; tag)
    {
        if (c == '/' || c == 0)
            return 0;
        dst[i++] = c;
    }
    if (i >= dst.length) return 0;
    dst[i++] = '_';
    ptrdiff_t r = format_uint(pid, dst[i .. $]);
    if (r < 0) return 0;
    i += r;
    if (i >= dst.length) return 0;
    dst[i++] = '_';
    r = format_uint(n, dst[i .. $]);
    if (r < 0) return 0;
    i += r;
    if (i >= dst.length) return 0;
    dst[i++] = '_';
    if (i + iface.length >= dst.length)
        return 0;
    foreach (c; iface)
    {
        if (c == '/' || c == 0)
            return 0;
        dst[i++] = c;
    }
    return i;
}

size_t format_remote_path(char[] dst, const(char)[] dir, const(char)[] iface)
{
    if (dir.length + 1 + iface.length >= dst.length)
        return 0;
    size_t i = 0;
    dst[i .. i + dir.length] = dir;
    i += dir.length;
    dst[i++] = '/';
    foreach (c; iface)
    {
        if (c == '/' || c == 0)
            return 0;
        dst[i++] = c;
    }
    return i;
}

