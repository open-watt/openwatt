module driver.linux.netlink_dump;

version (linux):

// Read-side netlink DUMP queries (RTM_GET* + NLM_F_DUMP) -> an in-memory model of
// the kernel's live L2/L3 network state, rendered by /system/linux/print in
// approximately /etc/network/interfaces (ifupdown) form: native directives where
// they exist (address, bridge_ports, vlan-raw-device, mtu, hwaddress) and the
// standard `up ip ... add` hook idiom for what ifupdown can't say declaratively
// (extra routes, static neighbours, secondary addresses) -- preserving the route
// `proto` so OpenWatt-owned entries (proto 80) stay identifiable.
//
// IPv4 only for now (addresses/routes/neighbours); links are family-agnostic.
//
// The wire structs/constants below duplicate driver.linux.netlink{,_write}.
// TODO: hoist the shared netlink protocol definitions into one module.

import urt.array;
import urt.log;
import urt.mem.temp;
import urt.meta.nullable;
import urt.string;

import manager;
import manager.collection;
import manager.plugin;
import manager.console;
import manager.console.session;

import router.iface.bridge : BridgeInterface;

import driver.linux.ethernet : LinuxRawEthernet;
import driver.linux.nl80211 : query_wifi_interfaces, WifiIfInfo, wifi_iftype_name;

import urt.internal.sys.posix : close;

nothrow @nogc:


// `ip` -- imperative `ip -b`-runnable script (default; lossless, 1:1 with our
// netlink writes). `interfaces` -- declarative /etc/network/interfaces form.
enum LinuxPrintFormat
{
    ip,
    interfaces,
}


// === console module ===

class LinuxNetConfModule : Module
{
    mixin DeclareModule!"os.linux.netconf";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_command!print_cmd("/system/linux", this, "print");
    }

    // /system/linux/print [format=ip|interfaces] -- dump the live kernel network
    // state. Default `ip` is an `ip -b`-runnable reproduction script.
    void print_cmd(Session session, Nullable!LinuxPrintFormat format)
    {
        g_links.clear();
        g_addrs.clear();
        g_routes.clear();
        g_neighs.clear();

        bool ok = nl_dump(RTM_GETLINK,  AF_PACKET, &on_link)
                & nl_dump(RTM_GETADDR,  AF_INET,   &on_addr)
                & nl_dump(RTM_GETROUTE, AF_INET,   &on_route)
                & nl_dump(RTM_GETNEIGH, AF_INET,   &on_neigh);
        if (!ok)
        {
            session.write_line("# failed to query kernel netlink state (see log)");
            return;
        }

        resolve_ow_names();
        resolve_wifi();

        if (format && format.value == LinuxPrintFormat.interfaces)
            format_interfaces(session);
        else
            format_ip_batch(session);
    }
}


private:


// === in-memory model ===

struct NetLink
{
    int      index;
    int      master;        // bridge/bond master ifindex (0 = none)
    int      link;          // parent ifindex for vlans (IFLA_LINK)
    ushort   vlan_id;
    uint     mtu;
    ubyte[6] mac;
    bool     up;
    bool     loopback;
    char[16] name; ubyte name_len;
    char[16] kind; ubyte kind_len;     // "bridge" / "vlan" / "" (real device)
    char[32] ow_name; ubyte ow_name_len;   // the OpenWatt interface backing this netdev, if any

    // wifi VIF state from nl80211 (NL80211_CMD_GET_INTERFACE), if this is a radio VIF
    bool     wifi;
    uint     wifi_iftype;
    uint     wifi_freq;            // MHz
    char[32] ssid; ubyte ssid_len;

    const(char)[] name_s() const nothrow @nogc return => name[0 .. name_len];
    const(char)[] kind_s() const nothrow @nogc return => kind[0 .. kind_len];
    const(char)[] ow_name_s() const nothrow @nogc return => ow_name[0 .. ow_name_len];
    const(char)[] ssid_s() const nothrow @nogc return => ssid[0 .. ssid_len];
}

struct NetAddr
{
    int      index;
    ubyte[4] addr;
    ubyte    prefix;
}

struct NetRoute
{
    ubyte[4] dst;
    ubyte    dst_len;
    ubyte[4] gateway;
    int      oif;
    ubyte    protocol;
    ubyte    table;
    ubyte    rtype;
    bool     has_gateway;
}

struct NetNeigh
{
    int      index;
    ubyte[4] ip;
    ubyte[6] mac;
    ushort   state;
    bool     has_mac;
}

__gshared Array!NetLink  g_links;
__gshared Array!NetAddr  g_addrs;
__gshared Array!NetRoute g_routes;
__gshared Array!NetNeigh g_neighs;


// === dump message handlers ===

void on_link(const(ubyte)[] payload)
{
    if (payload.length < ifinfomsg.sizeof)
        return;
    const(ifinfomsg)* info = cast(const(ifinfomsg)*)payload.ptr;

    NetLink l;
    l.index    = info.ifi_index;
    l.up       = (info.ifi_flags & IFF_UP) != 0;
    l.loopback = (info.ifi_flags & IFF_LOOPBACK) != 0;

    walk_attrs(payload[ifinfomsg.sizeof .. $], (ushort type, const(ubyte)[] d) {
        switch (type)
        {
            case IFLA_IFNAME:   copy_cstr(l.name, l.name_len, d); break;
            case IFLA_ADDRESS:  if (d.length >= 6) l.mac[] = d[0 .. 6]; break;
            case IFLA_MTU:      if (d.length >= 4) l.mtu = load_u32(d); break;
            case IFLA_MASTER:   if (d.length >= 4) l.master = cast(int)load_u32(d); break;
            case IFLA_LINK:     if (d.length >= 4) l.link = cast(int)load_u32(d); break;
            case IFLA_LINKINFO: parse_linkinfo(l, d); break;
            default: break;
        }
    });

    g_links ~= l;
}

void parse_linkinfo(ref NetLink l, const(ubyte)[] d)
{
    walk_attrs(d, (ushort type, const(ubyte)[] v) {
        if (type == IFLA_INFO_KIND)
            copy_cstr(l.kind, l.kind_len, v);
        else if (type == IFLA_INFO_DATA)
            walk_attrs(v, (ushort t2, const(ubyte)[] v2) {
                if (t2 == IFLA_VLAN_ID && v2.length >= 2)
                    l.vlan_id = load_u16(v2);
            });
    });
}

void on_addr(const(ubyte)[] payload)
{
    if (payload.length < ifaddrmsg.sizeof)
        return;
    const(ifaddrmsg)* ifa = cast(const(ifaddrmsg)*)payload.ptr;
    if (ifa.ifa_family != AF_INET)
        return;

    NetAddr a;
    a.index  = cast(int)ifa.ifa_index;
    a.prefix = ifa.ifa_prefixlen;
    bool got = false;
    walk_attrs(payload[ifaddrmsg.sizeof .. $], (ushort type, const(ubyte)[] d) {
        // IFA_LOCAL is the host's own address (point-to-point aware); prefer it.
        if ((type == IFA_LOCAL || (type == IFA_ADDRESS && !got)) && d.length >= 4)
        {
            a.addr[] = d[0 .. 4];
            if (type == IFA_LOCAL)
                got = true;
        }
    });
    g_addrs ~= a;
}

void on_route(const(ubyte)[] payload)
{
    if (payload.length < rtmsg.sizeof)
        return;
    const(rtmsg)* rt = cast(const(rtmsg)*)payload.ptr;
    if (rt.rtm_family != AF_INET)
        return;

    NetRoute r;
    r.dst_len  = rt.rtm_dst_len;
    r.protocol = rt.rtm_protocol;
    r.table    = rt.rtm_table;
    r.rtype    = rt.rtm_type;
    walk_attrs(payload[rtmsg.sizeof .. $], (ushort type, const(ubyte)[] d) {
        switch (type)
        {
            case RTA_DST:     if (d.length >= 4) r.dst[] = d[0 .. 4]; break;
            case RTA_GATEWAY: if (d.length >= 4) { r.gateway[] = d[0 .. 4]; r.has_gateway = true; } break;
            case RTA_OIF:     if (d.length >= 4) r.oif = cast(int)load_u32(d); break;
            default: break;
        }
    });
    g_routes ~= r;
}

void on_neigh(const(ubyte)[] payload)
{
    if (payload.length < ndmsg.sizeof)
        return;
    const(ndmsg)* nd = cast(const(ndmsg)*)payload.ptr;
    if (nd.ndm_family != AF_INET)
        return;

    NetNeigh n;
    n.index = nd.ndm_ifindex;
    n.state = nd.ndm_state;
    walk_attrs(payload[ndmsg.sizeof .. $], (ushort type, const(ubyte)[] d) {
        if (type == NDA_DST && d.length >= 4)
            n.ip[] = d[0 .. 4];
        else if (type == NDA_LLADDR && d.length >= 6)
        {
            n.mac[] = d[0 .. 6];
            n.has_mac = true;
        }
    });
    g_neighs ~= n;
}


// === OpenWatt-name correlation ===

// Tag each dumped netdev with the OpenWatt interface that backs it, so the print
// shows what's what. Ethernet interfaces map by their `adapter` (kernel netdev
// name); offloaded bridges map by the kernel ifindex the offload module recorded.
void resolve_ow_names()
{
    foreach (ref l; g_links[])
    {
        foreach (e; Collection!LinuxRawEthernet().values)
        {
            if (e.adapter == l.name_s)
            {
                copy_ow(l, e.name[]);
                break;
            }
        }
        if (l.ow_name_len)
            continue;
        foreach (b; Collection!BridgeInterface().values)
        {
            if (b.kernel_ifindex() != 0 && b.kernel_ifindex() == l.index)
            {
                copy_ow(l, b.name[]);
                break;
            }
        }
    }
}

void copy_ow(ref NetLink l, const(char)[] s)
{
    size_t n = s.length < l.ow_name.length ? s.length : l.ow_name.length;
    l.ow_name[0 .. n] = s[0 .. n];
    l.ow_name_len = cast(ubyte)n;
}

// Annotate the wifi VIF netdevs with their live nl80211 state (mode / SSID /
// frequency). rtnetlink only sees them as netdevs; this is the radio view.
void resolve_wifi()
{
    query_wifi_interfaces((ref const WifiIfInfo w) {
        foreach (ref l; g_links[])
        {
            if (l.index != w.ifindex)
                continue;
            l.wifi        = true;
            l.wifi_iftype = w.iftype;
            l.wifi_freq   = w.freq;
            size_t c = w.ssid_len < l.ssid.length ? w.ssid_len : l.ssid.length;
            l.ssid[0 .. c] = w.ssid_s[0 .. c];
            l.ssid_len = cast(ubyte)c;
            return;
        }
    });
}

// e.g. `AP ssid="myap" 2437MHz` -- null for non-wifi netdevs.
const(char)[] wifi_desc(ref const NetLink l)
{
    if (!l.wifi)
        return null;
    const(char)[] s = wifi_iftype_name(l.wifi_iftype);
    if (l.ssid_len)
        s = tconcat(s, " ssid=\"", l.ssid_s, "\"");
    if (l.wifi_freq)
        s = tconcat(s, " ", l.wifi_freq, "MHz");
    return s;
}


// === ifupdown formatter ===

void format_interfaces(Session session)
{
    session.write_line("# Generated by OpenWatt from live kernel state (netlink).");
    session.write_line("# Route `proto` is preserved -- proto 80 marks OpenWatt-owned entries.");

    foreach (ref l; g_links[])
    {
        session.write_line("");

        if (l.ow_name_len)
            session.write_line("# OpenWatt: ", l.ow_name_s);
        if (auto w = wifi_desc(l))
            session.write_line("# wifi: ", w);

        const(char)[] method = l.loopback ? "loopback" : (link_has_addr(l.index) ? "static" : "manual");
        session.write_line("auto ", l.name_s);
        session.write_line("iface ", l.name_s, " inet ", method);

        if (l.loopback)
            continue;   // `inet loopback` implies 127.0.0.1/::1 -- no further directives

        if (l.kind_s == "bridge")
            session.write_line("    bridge_ports ", bridge_ports(l.index));
        else if (l.kind_s == "vlan" && l.link != 0)
            session.write_line("    vlan-raw-device ", ifname(l.link));

        if (l.kind_s == "bridge")
            session.write_line("    hwaddress ether ", mac_str(l.mac));

        if (l.mtu != 0 && l.mtu != 1500)
            session.write_line("    mtu ", l.mtu);

        // addresses: first as the native `address`, the rest as up-hooks
        bool first = true;
        foreach (ref a; g_addrs[])
        {
            if (a.index != l.index)
                continue;
            if (first)
            {
                session.write_line("    address ", ip4(a.addr), "/", a.prefix);
                first = false;
            }
            else
                session.write_line("    up ip addr add ", ip4(a.addr), "/", a.prefix, " dev ", l.name_s);
        }

        // routes egressing this interface (skip kernel-auto / non-main / non-unicast)
        foreach (ref r; g_routes[])
        {
            if (r.oif != l.index || !route_is_config(r))
                continue;
            write_route(session, r, l.name_s);
        }

        // static (permanent) neighbours on this interface
        foreach (ref n; g_neighs[])
        {
            if (n.index != l.index || !n.has_mac || !(n.state & NUD_PERMANENT))
                continue;
            session.write_line("    up ip neigh add ", ip4(n.ip), " lladdr ", mac_str(n.mac), " dev ", l.name_s, " nud permanent");
        }
    }

    // routes with no explicit egress interface (gateway-only)
    bool header = false;
    foreach (ref r; g_routes[])
    {
        if (r.oif != 0 || !route_is_config(r))
            continue;
        if (!header)
        {
            session.write_line("");
            session.write_line("# routes without an explicit egress interface");
            header = true;
        }
        write_route(session, r, null);
    }
}

// === iproute2 `ip -b` batch formatter ===
//
// Imperative, lossless, 1:1 with our netlink writes -- runnable as `ip -b <file>`
// against a clean namespace to reproduce the L2/L3 state. Ordered create ->
// enslave -> up -> address -> route -> neigh so the replay succeeds. (The wifi
// radio layer -- iw VIF creation, hostapd/wpa_supplicant -- is out of `ip`'s scope.)
void format_ip_batch(Session session)
{
    session.write_line("# Generated by OpenWatt from live kernel state (netlink).");
    session.write_line("# Reproduce on a clean namespace with:  ip -b <file>");

    const(char)[] legend;
    foreach (ref l; g_links[])
        if (l.ow_name_len)
            legend = legend.length ? tconcat(legend, "  ", l.ow_name_s, "=", l.name_s) : tconcat(l.ow_name_s, "=", l.name_s);
    if (legend.length)
        session.write_line("# OpenWatt interfaces:  ", legend);

    // wifi VIF state -- the radio layer (iw / hostapd / wpa_supplicant) is out of
    // `ip`'s scope, so it's reported as comments, not reproducible commands.
    bool wifi_hdr = false;
    foreach (ref l; g_links[])
    {
        if (auto w = wifi_desc(l))
        {
            if (!wifi_hdr)
            {
                session.write_line("# wifi (radio layer is iw/hostapd/wpa_supplicant, not ip):");
                wifi_hdr = true;
            }
            session.write_line("#   ", l.name_s, "  ", w);
        }
    }
    session.write_line("");

    // 1. create virtual devices (bridges before vlans, in case a vlan rides a bridge)
    foreach (ref l; g_links[])
        if (l.kind_s == "bridge")
            session.write_line("link add name ", l.name_s, " address ", mac_str(l.mac), " type bridge");
    foreach (ref l; g_links[])
        if (l.kind_s == "vlan" && l.link != 0)
            session.write_line("link add link ", ifname(l.link), " name ", l.name_s, " type vlan id ", l.vlan_id);

    // 2. enslave members to their bridge
    foreach (ref l; g_links[])
        if (l.master != 0)
            session.write_line("link set ", l.name_s, " master ", ifname(l.master));

    // 3. bring links up (loopback is the kernel's)
    foreach (ref l; g_links[])
        if (l.up && !l.loopback)
            session.write_line("link set ", l.name_s, " up");

    // 4. addresses (skip loopback's kernel-assigned 127.0.0.1/::1)
    foreach (ref a; g_addrs[])
        if (!link_is_loopback(a.index))
            session.write_line("addr add ", ip4(a.addr), "/", a.prefix, " dev ", ifname(a.index));

    // 5. routes we'd configure (skip kernel-auto / non-main / non-unicast)
    foreach (ref r; g_routes[])
        if (route_is_config(r))
            write_ip_route(session, r);

    // 6. static (permanent) neighbours
    foreach (ref n; g_neighs[])
        if (n.has_mac && (n.state & NUD_PERMANENT))
            session.write_line("neigh add ", ip4(n.ip), " lladdr ", mac_str(n.mac), " dev ", ifname(n.index), " nud permanent");
}

void write_ip_route(Session session, ref const NetRoute r)
{
    const(char)[] dst = r.dst_len == 0 ? "default" : tconcat(ip4(r.dst), "/", r.dst_len);
    const(char)[] dev = r.oif != 0 ? ifname(r.oif) : null;

    if (r.has_gateway && dev)
        session.write_line("route add ", dst, " via ", ip4(r.gateway), " dev ", dev, " proto ", r.protocol);
    else if (r.has_gateway)
        session.write_line("route add ", dst, " via ", ip4(r.gateway), " proto ", r.protocol);
    else if (dev)
        session.write_line("route add ", dst, " dev ", dev, " proto ", r.protocol);
    else
        session.write_line("route add ", dst, " proto ", r.protocol);
}

bool link_is_loopback(int index)
{
    foreach (ref l; g_links[])
        if (l.index == index)
            return l.loopback;
    return false;
}

void write_route(Session session, ref const NetRoute r, const(char)[] dev)
{
    const(char)[] indent = dev ? "    up ip route add " : "up ip route add ";
    const(char)[] dst = r.dst_len == 0 ? "default" : tconcat(ip4(r.dst), "/", r.dst_len);
    const(char)[] owned = r.protocol == RTPROT_OPENWATT ? "   # OpenWatt-owned" : "";

    if (r.has_gateway && dev)
        session.write_line(indent, dst, " via ", ip4(r.gateway), " dev ", dev, " proto ", r.protocol, owned);
    else if (r.has_gateway)
        session.write_line(indent, dst, " via ", ip4(r.gateway), " proto ", r.protocol, owned);
    else if (dev)
        session.write_line(indent, dst, " dev ", dev, " proto ", r.protocol, owned);
    else
        session.write_line(indent, dst, " proto ", r.protocol, owned);
}

bool route_is_config(ref const NetRoute r)
    => r.table == RT_TABLE_MAIN && r.protocol != RTPROT_KERNEL && r.rtype == RTN_UNICAST;

bool link_has_addr(int index)
{
    foreach (ref a; g_addrs[])
        if (a.index == index)
            return true;
    return false;
}

const(char)[] bridge_ports(int bridge_index)
{
    const(char)[] ports;
    foreach (ref l; g_links[])
    {
        if (l.master != bridge_index)
            continue;
        ports = ports.length ? tconcat(ports, " ", l.name_s) : l.name_s;
    }
    return ports.length ? ports : "none";
}

const(char)[] ifname(int index)
{
    foreach (ref l; g_links[])
        if (l.index == index)
            return l.name_s;
    return tconcat("if", index);
}

const(char)[] ip4(ubyte[4] a)
    => tconcat(a[0], ".", a[1], ".", a[2], ".", a[3]);

// Lowercase aa:bb:.. -- the ip/ifupdown convention (MACAddress renders uppercase).
// Built from char args so tconcat materialises the result in temp memory (a single
// slice arg would just alias it, dangling once a stack buffer goes out of scope).
const(char)[] mac_str(ubyte[6] m)
{
    static immutable char[16] h = "0123456789abcdef";
    return tconcat(h[m[0] >> 4], h[m[0] & 15], ':', h[m[1] >> 4], h[m[1] & 15], ':',
                   h[m[2] >> 4], h[m[2] & 15], ':', h[m[3] >> 4], h[m[3] & 15], ':',
                   h[m[4] >> 4], h[m[4] & 15], ':', h[m[5] >> 4], h[m[5] & 15]);
}


// === netlink dump transport ===

bool nl_dump(ushort type, ubyte family, scope void function(const(ubyte)[] payload) nothrow @nogc on_msg)
{
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (fd < 0)
    {
        log_error("os.linux.netconf", "socket(AF_NETLINK) failed");
        return false;
    }
    scope(exit) close(fd);

    sockaddr_nl local;
    local.nl_family = AF_NETLINK;
    if (bind(fd, &local, sockaddr_nl.sizeof) < 0)
        return false;

    struct Req { align(1) nlmsghdr h; rtgenmsg g; }
    Req req;
    req.h.nlmsg_len   = cast(uint)(nlmsghdr.sizeof + rtgenmsg.sizeof);
    req.h.nlmsg_type  = type;
    req.h.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    req.h.nlmsg_seq   = ++g_seq;
    req.g.rtgen_family = family;

    sockaddr_nl kernel;
    kernel.nl_family = AF_NETLINK;
    if (sendto(fd, &req, Req.sizeof, 0, &kernel, sockaddr_nl.sizeof) < 0)
        return false;

    ubyte[16 * 1024] buf = void;
    while (true)
    {
        ptrdiff_t n = recv(fd, buf.ptr, buf.length, 0);
        if (n <= 0)
            return false;

        const(ubyte)[] data = buf[0 .. cast(size_t)n];
        while (data.length >= nlmsghdr.sizeof)
        {
            const(nlmsghdr)* h = cast(const(nlmsghdr)*)data.ptr;
            if (h.nlmsg_len < nlmsghdr.sizeof || h.nlmsg_len > data.length)
                return false;
            if (h.nlmsg_type == NLMSG_DONE)
                return true;
            if (h.nlmsg_type == NLMSG_ERROR)
                return false;

            on_msg(data[nlmsghdr.sizeof .. h.nlmsg_len]);

            uint aligned = (h.nlmsg_len + 3u) & ~3u;
            if (aligned > data.length)
                break;
            data = data[aligned .. $];
        }
    }
}

void walk_attrs(const(ubyte)[] d, scope void delegate(ushort type, const(ubyte)[] data) nothrow @nogc f)
{
    while (d.length >= rtattr.sizeof)
    {
        const(rtattr)* a = cast(const(rtattr)*)d.ptr;
        if (a.rta_len < rtattr.sizeof || a.rta_len > d.length)
            break;
        f(cast(ushort)(a.rta_type & 0x3FFF), d[rtattr.sizeof .. a.rta_len]);
        uint aligned = (a.rta_len + 3u) & ~3u;
        if (aligned > d.length)
            break;
        d = d[aligned .. $];
    }
}

void copy_cstr(ref char[16] dst, ref ubyte len, const(ubyte)[] src)
{
    size_t n = 0;
    while (n < src.length && n < dst.length && src[n] != 0)
    {
        dst[n] = cast(char)src[n];
        ++n;
    }
    len = cast(ubyte)n;
}

uint load_u32(const(ubyte)[] d)
    => d[0] | (uint(d[1]) << 8) | (uint(d[2]) << 16) | (uint(d[3]) << 24);

ushort load_u16(const(ubyte)[] d)
    => cast(ushort)(d[0] | (ushort(d[1]) << 8));


// === netlink protocol (subset; duplicates driver.linux.netlink{,_write}) ===

__gshared uint g_seq;

enum AF_NETLINK    = 16;
enum SOCK_RAW      = 3;
enum NETLINK_ROUTE = 0;
enum AF_UNSPEC     = 0;
enum AF_INET       = 2;
enum AF_PACKET     = 17;

enum NLM_F_REQUEST = 0x01;
enum NLM_F_ROOT    = 0x100;
enum NLM_F_MATCH   = 0x200;
enum NLM_F_DUMP    = NLM_F_ROOT | NLM_F_MATCH;

enum NLMSG_ERROR   = 2;
enum NLMSG_DONE    = 3;

enum RTM_GETLINK   = 18;
enum RTM_GETADDR   = 22;
enum RTM_GETROUTE  = 26;
enum RTM_GETNEIGH  = 30;

enum IFF_UP        = 0x1;
enum IFF_LOOPBACK  = 0x8;

enum IFLA_ADDRESS   = 1;
enum IFLA_IFNAME    = 3;
enum IFLA_MTU       = 4;
enum IFLA_LINK      = 5;
enum IFLA_MASTER    = 10;
enum IFLA_LINKINFO  = 18;
enum IFLA_INFO_KIND = 1;
enum IFLA_INFO_DATA = 2;
enum IFLA_VLAN_ID   = 1;

enum IFA_ADDRESS = 1;
enum IFA_LOCAL   = 2;

enum RTA_DST     = 1;
enum RTA_OIF     = 4;
enum RTA_GATEWAY = 5;

enum NDA_DST    = 1;
enum NDA_LLADDR = 2;

enum RT_TABLE_MAIN   = 254;
enum RTPROT_KERNEL   = 2;
enum RTPROT_OPENWATT = 80;
enum RTN_UNICAST     = 1;

enum NUD_PERMANENT = 0x80;

struct sockaddr_nl
{
    ushort nl_family;
    ushort nl_pad;
    uint   nl_pid;
    uint   nl_groups;
}

struct nlmsghdr
{
    uint   nlmsg_len;
    ushort nlmsg_type;
    ushort nlmsg_flags;
    uint   nlmsg_seq;
    uint   nlmsg_pid;
}

struct rtgenmsg
{
    ubyte rtgen_family;
}

struct rtattr
{
    ushort rta_len;
    ushort rta_type;
}

struct ifinfomsg
{
    ubyte  ifi_family;
    ubyte  __pad;
    ushort ifi_type;
    int    ifi_index;
    uint   ifi_flags;
    uint   ifi_change;
}

struct ifaddrmsg
{
    ubyte ifa_family;
    ubyte ifa_prefixlen;
    ubyte ifa_flags;
    ubyte ifa_scope;
    uint  ifa_index;
}

struct rtmsg
{
    ubyte rtm_family;
    ubyte rtm_dst_len;
    ubyte rtm_src_len;
    ubyte rtm_tos;
    ubyte rtm_table;
    ubyte rtm_protocol;
    ubyte rtm_scope;
    ubyte rtm_type;
    uint  rtm_flags;
}

struct ndmsg
{
    ubyte  ndm_family;
    ubyte  ndm_pad1;
    ushort ndm_pad2;
    int    ndm_ifindex;
    ushort ndm_state;
    ubyte  ndm_flags;
    ubyte  ndm_type;
}

extern(C) nothrow @nogc
{
    int socket(int domain, int type, int protocol);
    int bind(int fd, const(void)* addr, uint addrlen);
    ptrdiff_t sendto(int fd, const(void)* buf, size_t len, int flags, const(void)* dest_addr, uint addrlen);
    ptrdiff_t recv(int fd, void* buf, size_t len, int flags);
}
