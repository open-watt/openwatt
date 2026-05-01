module manager.os.sysfs;

version (linux):

import urt.conv;
import urt.log;
import urt.mem.temp : tconcat;
import urt.string;

import router.iface : BaseInterface;
import router.iface.mac : MACAddress;
import router.status;

import urt.internal.sys.posix;

nothrow @nogc:


enum linux_max_l2mtu = 9000;

enum AdapterChange : uint
{
    none      = 0,
    mtu       = 1 << 0,
    max_mtu   = 1 << 1,
    connected = 1 << 2,
    tx_speed  = 1 << 3,
    rx_speed  = 1 << 4,
}

AdapterChange apply_os_adapter_info(BaseInterface iface, ref ushort l2mtu, ref ushort max_l2mtu, ref IfStatus status, ref const OSAdapterInfo info)
{
    AdapterChange changed;

    if (info.mtu != 0 && info.mtu != l2mtu)
    {
        l2mtu = cast(ushort)info.mtu;
        changed |= AdapterChange.mtu;
    }
    if (max_l2mtu != linux_max_l2mtu)
    {
        max_l2mtu = linux_max_l2mtu;
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


// Linux adapter introspection backed by /sys/class/net/<iface>/*.
// Pulls MAC, MTU, carrier, link speed for an existing netdev, and walks the
// directory to enumerate candidate ethernet adapters.

struct OSAdapterInfo
{
    bool valid;
    MACAddress mac;
    uint mtu;
    ConnectionStatus connection = ConnectionStatus.unknown;
    ulong tx_link_speed;    // bps
    ulong rx_link_speed;    // bps
}


// Reads /sys/class/net/<iface>/ifindex. Returns 0 on failure.
uint read_ifindex(const(char)[] adapter_name)
{
    if (adapter_name.length == 0 || adapter_name.length > 32)
        return 0;
    char[32] buf = void;
    auto p = build_path(adapter_name, "/ifindex");
    auto data = read_file(p, buf[]);
    if (data is null)
        return 0;
    auto s = data.trimBack;
    size_t consumed;
    ulong v = parse_uint(s, &consumed);
    if (consumed != s.length || consumed == 0)
        return 0;
    return cast(uint)v;
}


bool query_adapter(const(char)[] adapter_name, out OSAdapterInfo info)
{
    if (adapter_name.length == 0 || adapter_name.length > 32)
        return false;

    char[64] buf  = void;

    // MAC address
    auto p = build_path(adapter_name, "/address");
    auto data = read_file(p, buf[]);
    if (data is null)
        return false;
    if (info.mac.fromString(data.trimBack) != MACAddress.StringLen)
        return false;

    // MTU
    p = build_path(adapter_name, "/mtu");
    data = read_file(p, buf[]);
    if (data !is null)
    {
        auto s = data.trimBack;
        size_t consumed;
        ulong mtu = parse_uint(s, &consumed);
        if (consumed == s.length && consumed > 0)
            info.mtu = cast(uint)mtu;
    }

    // carrier (1=up, 0=down). May fail with EINVAL if interface is admin-down.
    p = build_path(adapter_name, "/carrier");
    data = read_file(p, buf[]);
    if (data !is null)
    {
        auto s = data.trimBack;
        info.connection = (s.length == 1 && s[0] == '1')
            ? ConnectionStatus.connected
            : ConnectionStatus.disconnected;
    }
    else
    {
        info.connection = ConnectionStatus.unknown;
    }

    // speed in Mbit/s; -1 (or read failure) when down or unknown
    p = build_path(adapter_name, "/speed");
    data = read_file(p, buf[]);
    if (data !is null)
    {
        auto s = data.trimBack;
        size_t consumed;
        long spd = parse_int(s, &consumed);
        if (consumed == s.length && spd > 0)
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

const(char)* build_path(const(char)[] iface, const(char)[] suffix)
    => tconcat("/sys/class/net/", iface, suffix, '\0').ptr;

const(char)[] read_file(const(char)* path, char[] dst)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return null;
    scope(exit) close(fd);

    ssize_t n = read(fd, dst.ptr, dst.length);
    if (n < 0)
        return null;
    return cast(const(char)[])dst[0 .. cast(size_t)n];
}

// Stat /sys/class/net/<iface>/device to detect virtual netdevs (bridges,
// veths, dummies, tun/tap, vlans, bonding, loopback all lack the /device
// symlink that physical NICs expose).
bool has_device_symlink(const(char)[] iface)
{
    auto p = build_path(iface, "/device");
    if (p is null)
        return false;
    stat_t st;
    return stat(p, &st) == 0;
}

bool has_wireless_subdir(const(char)[] iface)
{
    auto p = build_path(iface, "/wireless");
    if (p is null)
        return false;
    stat_t st;
    return stat(p, &st) == 0;
}

// /sys/class/net/<iface>/device/driver is a symlink to the driver dir;
// readlink + basename gives e.g. "e1000e", "r8169", "igb".
const(char)[] read_driver_name(const(char)[] iface, char[] buf)
{
    auto p = build_path(iface, "/device/driver");
    if (p is null)
        return null;
    char[256] link = void;
    ssize_t n = readlink(p, link.ptr, link.length);
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
