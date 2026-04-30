module manager.os.sysfs;

version (linux):

import urt.log;

import router.iface : BaseInterface;
import router.status;

import urt.internal.sys.posix;

nothrow @nogc:


// Linux adapter introspection backed by /sys/class/net/<iface>/*.
// Pulls MAC, MTU, carrier, link speed for an existing netdev, and walks the
// directory to enumerate candidate ethernet adapters.

struct OSAdapterInfo
{
    bool valid;
    ubyte[6] mac;
    ubyte mac_len;
    uint mtu;
    ConnectionStatus connection = ConnectionStatus.unknown;
    ulong tx_link_speed;    // bps
    ulong rx_link_speed;    // bps
}


bool query_adapter(const(char)[] adapter_name, out OSAdapterInfo info)
{
    if (adapter_name.length == 0 || adapter_name.length > 32)
        return false;

    char[256] path = void;
    char[64] buf  = void;

    // MAC address
    auto p = build_path(path, adapter_name, "/address");
    if (read_file(p, buf[]) is null)
        return false;
    if (!parse_mac(strip_line(buf[0 .. read_len]), info.mac))
        return false;
    info.mac_len = 6;

    // MTU
    p = build_path(path, adapter_name, "/mtu");
    if (read_file(p, buf[]) !is null)
    {
        uint mtu;
        if (parse_uint(strip_line(buf[0 .. read_len]), mtu))
            info.mtu = mtu;
    }

    // carrier (1=up, 0=down). May fail with EINVAL if interface is admin-down.
    p = build_path(path, adapter_name, "/carrier");
    if (read_file(p, buf[]) !is null)
    {
        auto s = strip_line(buf[0 .. read_len]);
        info.connection = (s.length == 1 && s[0] == '1')
            ? ConnectionStatus.connected
            : ConnectionStatus.disconnected;
    }
    else
    {
        info.connection = ConnectionStatus.unknown;
    }

    // speed in Mbit/s; -1 (or read failure) when down or unknown
    p = build_path(path, adapter_name, "/speed");
    if (read_file(p, buf[]) !is null)
    {
        int spd;
        if (parse_int(strip_line(buf[0 .. read_len]), spd) && spd > 0)
        {
            info.tx_link_speed = cast(ulong)spd * 1_000_000UL;
            info.rx_link_speed = info.tx_link_speed;
        }
    }

    info.valid = true;
    return true;
}


void enumerate_adapters(scope void delegate(const(char)[] name, const(char)[] description) nothrow @nogc on_adapter)
{
    walk_netdevs((const(char)[] name, const(char)[] desc) nothrow @nogc {
        if (has_wireless_subdir(name))
            return;
        on_adapter(name, desc);
    });
}

void enumerate_wifi_adapters(scope void delegate(const(char)[] name, const(char)[] description) nothrow @nogc on_adapter)
{
    walk_netdevs((const(char)[] name, const(char)[] desc) nothrow @nogc {
        if (!has_wireless_subdir(name))
            return;
        on_adapter(name, desc);
    });
}

private void walk_netdevs(scope void delegate(const(char)[] name, const(char)[] description) nothrow @nogc on_netdev)
{
    DIR* dir = opendir("/sys/class/net".ptr);
    if (dir is null)
    {
        writeError("Failed to open /sys/class/net");
        return;
    }
    scope(exit) closedir(dir);

    char[64] desc_buf = void;

    while (true)
    {
        dirent* ent = readdir(dir);
        if (ent is null)
            break;

        size_t len = 0;
        while (len < ent.d_name.length && ent.d_name[len] != 0)
            ++len;
        if (len == 0)
            continue;

        const(char)[] name = ent.d_name[0 .. len];

        if (name == "." || name == "..")
            continue;

        // Cheap virtual / loopback filter -- bridges, dummies, veths, tun/tap,
        // bonding, vlan, lo all lack the /device symlink that physical NICs and
        // wifi radios expose.
        if (!has_device_symlink(name))
            continue;

        // No real "friendly name" on Linux. Use the driver name as a
        // best-effort description; operators can rename via console.
        const(char)[] desc = read_driver_name(name, desc_buf[]);

        on_netdev(name, desc);
    }
}


private:

extern(C) nothrow @nogc
{
    struct DIR;

    struct dirent
    {
        ulong d_ino;
        long  d_off;
        ushort d_reclen;
        ubyte  d_type;
        char[256] d_name;
    }

    DIR* opendir(const(char)* name);
    int  closedir(DIR* dir);
    dirent* readdir(DIR* dir);

    int* __errno_location();
}

__gshared size_t read_len;  // out-band length from last read_file() call

const(char)[] build_path(scope return ref char[256] buf, const(char)[] iface, const(char)[] suffix)
{
    enum prefix = "/sys/class/net/";
    size_t total = prefix.length + iface.length + suffix.length + 1;
    if (total > buf.length)
        return null;
    size_t i = 0;
    buf[i .. i + prefix.length] = prefix;       i += prefix.length;
    buf[i .. i + iface.length]  = iface;        i += iface.length;
    buf[i .. i + suffix.length] = suffix;       i += suffix.length;
    buf[i] = 0;
    return buf[0 .. i];  // length excludes the NUL we just wrote
}

// Reads up to dst.length bytes from a NUL-terminated path. Stores the byte
// count in module-level `read_len` (avoids the caller juggling out-params for
// the trivial cases). Returns null on failure, dst[0..read_len] on success.
const(char)[] read_file(const(char)[] path, char[] dst)
{
    int fd = open(path.ptr, O_RDONLY);
    if (fd < 0)
        return null;
    scope(exit) close(fd);

    ssize_t n = read(fd, dst.ptr, dst.length);
    if (n < 0)
        return null;
    read_len = cast(size_t)n;
    return cast(const(char)[])dst[0 .. read_len];
}

// /sys/class/net/<iface>/{address,mtu,...} files always end with a newline.
const(char)[] strip_line(const(char)[] s) pure
{
    while (s.length > 0 && (s[$ - 1] == '\n' || s[$ - 1] == '\r' || s[$ - 1] == ' '))
        s = s[0 .. $ - 1];
    return s;
}

bool parse_mac(const(char)[] s, ref ubyte[6] mac) pure
{
    // expect "xx:xx:xx:xx:xx:xx"
    if (s.length != 17)
        return false;
    foreach (i; 0 .. 6)
    {
        size_t off = i * 3;
        if (i < 5 && s[off + 2] != ':')
            return false;
        ubyte hi, lo;
        if (!hex_nibble(s[off],     hi)) return false;
        if (!hex_nibble(s[off + 1], lo)) return false;
        mac[i] = cast(ubyte)((hi << 4) | lo);
    }
    return true;
}

bool hex_nibble(char c, out ubyte v) pure
{
    if (c >= '0' && c <= '9') { v = cast(ubyte)(c - '0');      return true; }
    if (c >= 'a' && c <= 'f') { v = cast(ubyte)(c - 'a' + 10); return true; }
    if (c >= 'A' && c <= 'F') { v = cast(ubyte)(c - 'A' + 10); return true; }
    return false;
}

bool parse_uint(const(char)[] s, out uint v) pure
{
    if (s.length == 0)
        return false;
    uint acc = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        acc = acc * 10 + (c - '0');
    }
    v = acc;
    return true;
}

bool parse_int(const(char)[] s, out int v) pure
{
    bool neg = false;
    if (s.length > 0 && s[0] == '-')
    {
        neg = true;
        s = s[1 .. $];
    }
    uint u;
    if (!parse_uint(s, u))
        return false;
    v = neg ? -cast(int)u : cast(int)u;
    return true;
}

// Stat /sys/class/net/<iface>/device to detect virtual netdevs (bridges,
// veths, dummies, tun/tap, vlans, bonding, loopback all lack the /device
// symlink that physical NICs expose).
bool has_device_symlink(const(char)[] iface)
{
    char[256] path = void;
    auto p = build_path(path, iface, "/device");
    if (p is null)
        return false;
    stat_t st;
    return stat(p.ptr, &st) == 0;
}

bool has_wireless_subdir(const(char)[] iface)
{
    char[256] path = void;
    auto p = build_path(path, iface, "/wireless");
    if (p is null)
        return false;
    stat_t st;
    return stat(p.ptr, &st) == 0;
}

// /sys/class/net/<iface>/device/driver is a symlink to the driver dir;
// readlink + basename gives e.g. "e1000e", "r8169", "igb".
const(char)[] read_driver_name(const(char)[] iface, char[] buf)
{
    char[256] path = void;
    auto p = build_path(path, iface, "/device/driver");
    if (p is null)
        return null;
    char[256] link = void;
    ssize_t n = readlink(p.ptr, link.ptr, link.length);
    if (n <= 0)
        return null;
    auto target = link[0 .. cast(size_t)n];
    // basename
    size_t slash = target.length;
    foreach_reverse (i, c; target)
    {
        if (c == '/')
        {
            slash = i + 1;
            break;
        }
    }
    auto base = target[slash .. $];
    if (base.length == 0 || base.length > buf.length)
        return null;
    buf[0 .. base.length] = base;
    return cast(const(char)[])buf[0 .. base.length];
}


// Translate sysfs-derived OSAdapterInfo into BaseInterface state. Mirrors
// the iphlpapi.d apply_os_adapter_info shape so the driver code is symmetric
// with the Windows path.

enum LINUX_MAX_L2MTU = 9000;

enum AdapterChange : uint
{
    none      = 0,
    mtu       = 1 << 0,
    max_mtu   = 1 << 1,
    connected = 1 << 2,
    tx_speed  = 1 << 3,
    rx_speed  = 1 << 4,
}

public AdapterChange apply_os_adapter_info(BaseInterface iface, ref ushort l2mtu, ref ushort max_l2mtu, ref IfStatus status, ref const OSAdapterInfo info)
{
    AdapterChange changed;

    if (info.mtu != 0 && info.mtu != l2mtu)
    {
        l2mtu = cast(ushort)info.mtu;
        changed |= AdapterChange.mtu;
    }
    if (max_l2mtu != LINUX_MAX_L2MTU)
    {
        max_l2mtu = LINUX_MAX_L2MTU;
        changed |= AdapterChange.max_mtu;
    }

    if (status.connected != info.connection)
    {
        status.connected = info.connection;
        changed |= AdapterChange.connected;
    }

    if (status.tx_link_speed != info.tx_link_speed)
    {
        status.tx_link_speed = info.tx_link_speed;
        changed |= AdapterChange.tx_speed;
    }
    if (status.rx_link_speed != info.rx_link_speed)
    {
        status.rx_link_speed = info.rx_link_speed;
        changed |= AdapterChange.rx_speed;
    }

    return changed;
}
