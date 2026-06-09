module driver.linux.netlink_write;

version (linux):

import urt.log;

import manager;
import manager.plugin;
import manager.console;
import manager.console.session;

import urt.internal.sys.posix;

nothrow @nogc:


// RTNetlink WRITE path -- the keystone of the Linux data-plane trajectory
// (see docs/LINUX_DATAPLANE.md). Programs the kernel's routes, neighbours and
// addresses from OpenWatt's own tables. Consumed by protocol.ip.linux_mirror,
// and exposed directly via the /system/netlink console commands for poking.
//
// The wire structs/constants below duplicate a handful from the read-only
// driver.linux.netlink. TODO: hoist the shared netlink protocol definitions
// into a common module and have both sides import it.
//
// Every route we add is tagged with RTPROT_OPENWATT so our writes are
// identifiable and ownable -- that is what makes deterministic teardown /
// reconcile possible. Rule: never touch what isn't tagged ours.


// === public writer API ===

// Neighbour state / flags the caller chooses (ndm_state / ndm_flags).
enum : ushort
{
    NUD_PERMANENT = 0x80,   // static, never aged or probed by the kernel
    NUD_REACHABLE = 0x02,   // confirmed; pair with NTF_EXT_LEARNED for control-plane entries
}
enum : ubyte
{
    NTF_PROXY        = 0x08,    // proxy ARP/NDP for this entry
    NTF_EXT_LEARNED  = 0x10,    // learned by a userspace control plane (we own its lifecycle)
}

// All return: 0 on kernel ACK (success); a negative value is the kernel's
// netlink error (-errno); TRANSPORT_ERROR means the request never round-tripped
// (socket/bind/send/recv failed -- see log).

// gateway == [0,0,0,0] means an on-link (connected) route; oif == 0 means "let
// the kernel resolve the egress from the gateway".
int netlink_add_route(ubyte[4] dst, ubyte prefix, ubyte[4] gateway, int oif)
    => route_msg(RTM_NEWROUTE, NLM_F_CREATE | NLM_F_REPLACE, dst, prefix, gateway, oif);

int netlink_del_route(ubyte[4] dst, ubyte prefix, ubyte[4] gateway, int oif)
    => route_msg(RTM_DELROUTE, 0, dst, prefix, gateway, oif);

int netlink_add_neighbour(int ifindex, ubyte[4] ip, ubyte[6] mac, ushort state, ubyte flags)
{
    uint seq = ++g_seq;
    NlBuilder b;
    ndmsg nd;
    nd.ndm_family  = AF_INET;
    nd.ndm_ifindex = ifindex;
    nd.ndm_state   = state;
    nd.ndm_flags   = flags;
    nd.ndm_type    = RTN_UNICAST;
    b.family(nd);
    b.attr(NDA_DST, ip[]);
    b.attr(NDA_LLADDR, mac[]);
    return nl_send_ack(b.finalise(RTM_NEWNEIGH, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE, seq), seq);
}

int netlink_del_neighbour(int ifindex, ubyte[4] ip)
{
    uint seq = ++g_seq;
    NlBuilder b;
    ndmsg nd;
    nd.ndm_family  = AF_INET;
    nd.ndm_ifindex = ifindex;
    b.family(nd);
    b.attr(NDA_DST, ip[]);
    return nl_send_ack(b.finalise(RTM_DELNEIGH, NLM_F_REQUEST | NLM_F_ACK, seq), seq);
}

int netlink_add_address(int ifindex, ubyte[4] addr, ubyte prefix)
    => addr_msg(RTM_NEWADDR, NLM_F_CREATE | NLM_F_REPLACE, ifindex, addr, prefix);

int netlink_del_address(int ifindex, ubyte[4] addr, ubyte prefix)
    => addr_msg(RTM_DELADDR, 0, ifindex, addr, prefix);

// === link ops (kernel-bridge offload, see docs/LINUX_DATAPLANE.md Phase 3) ===

// Create a kernel bridge netdev `name` carrying `mac` as its hardware address.
// EXCL so we never silently adopt a pre-existing link; -EEXIST is the caller's
// to interpret. Resolve the new ifindex afterwards with netlink_ifindex(name).
int netlink_add_bridge(const(char)[] name, ubyte[6] mac)
{
    uint seq = ++g_seq;
    NlBuilder b;
    ifinfomsg ifi;
    b.family(ifi);
    b.attr(IFLA_ADDRESS, mac[]);
    b.attr_str(IFLA_IFNAME, name);
    size_t li = b.nest_begin(IFLA_LINKINFO);
    b.attr_str(IFLA_INFO_KIND, "bridge");
    b.nest_end(li);
    return nl_send_ack(b.finalise(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq), seq);
}

int netlink_del_link(int ifindex)
{
    uint seq = ++g_seq;
    NlBuilder b;
    ifinfomsg ifi;
    ifi.ifi_index = ifindex;
    b.family(ifi);
    return nl_send_ack(b.finalise(RTM_DELLINK, NLM_F_REQUEST | NLM_F_ACK, seq), seq);
}

// Enslave `ifindex` to bridge `master_ifindex`; master_ifindex == 0 detaches.
int netlink_set_master(int ifindex, int master_ifindex)
{
    uint seq = ++g_seq;
    NlBuilder b;
    ifinfomsg ifi;
    ifi.ifi_index = ifindex;
    b.family(ifi);
    uint m = master_ifindex;
    b.attr(IFLA_MASTER, as_bytes(m));
    return nl_send_ack(b.finalise(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK, seq), seq);
}

int netlink_set_link_up(int ifindex, bool up)
{
    uint seq = ++g_seq;
    NlBuilder b;
    ifinfomsg ifi;
    ifi.ifi_index  = ifindex;
    ifi.ifi_flags  = up ? IFF_UP : 0;
    ifi.ifi_change = IFF_UP;
    b.family(ifi);
    return nl_send_ack(b.finalise(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK, seq), seq);
}

// Resolve a kernel netdev name to its ifindex; 0 if unknown.
int netlink_ifindex(const(char)[] name)
{
    char[16] namebuf = 0;
    if (name.length == 0 || name.length >= namebuf.length)
        return 0;
    namebuf[0 .. name.length] = name[];
    return cast(int)if_nametoindex(namebuf.ptr);
}


// === console-facing module ===

class LinuxNetlinkWriteModule : Module
{
    mixin DeclareModule!"os.netlink.write";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_command!add_route("/system/netlink", this, "add-route");
        g_app.console.register_command!add_neighbour("/system/netlink", this, "add-neighbour");
    }

    // /system/netlink/add-route <destination[/prefix]> <gateway>
    void add_route(Session session, const(char)[] destination, const(char)[] gateway)
    {
        ubyte[4] dst, gw;
        ubyte prefix;
        if (!parse_cidr(destination, dst, prefix))
        {
            session.write_line("Invalid destination (expected a.b.c.d or a.b.c.d/len): ", destination);
            return;
        }
        if (!parse_ipv4(gateway, gw))
        {
            session.write_line("Invalid gateway (expected a.b.c.d): ", gateway);
            return;
        }

        int r = netlink_add_route(dst, prefix, gw, 0);
        report(session, r, "route ", destination);
    }

    // /system/netlink/add-neighbour <ip> <mac> <interface>
    void add_neighbour(Session session, const(char)[] address, const(char)[] mac, const(char)[] iface)
    {
        ubyte[4] ip;
        ubyte[6] hw;
        if (!parse_ipv4(address, ip))
        {
            session.write_line("Invalid address (expected a.b.c.d): ", address);
            return;
        }
        if (!parse_mac(mac, hw))
        {
            session.write_line("Invalid MAC (expected aa:bb:cc:dd:ee:ff): ", mac);
            return;
        }
        int idx = netlink_ifindex(iface);
        if (idx == 0)
        {
            session.write_line("Unknown interface: ", iface);
            return;
        }

        int r = netlink_add_neighbour(idx, ip, hw, NUD_PERMANENT, 0);
        report(session, r, "neighbour ", address);
    }
}


private:


__gshared uint g_seq;


int route_msg(ushort type, ushort extra_flags, ubyte[4] dst, ubyte prefix, ubyte[4] gateway, int oif)
{
    uint seq = ++g_seq;
    bool has_gw = gateway != cast(ubyte[4])[0, 0, 0, 0];

    NlBuilder b;
    rtmsg rt;
    rt.rtm_family   = AF_INET;
    rt.rtm_dst_len  = prefix;
    rt.rtm_table    = RT_TABLE_MAIN;
    rt.rtm_protocol = RTPROT_OPENWATT;
    rt.rtm_scope    = has_gw ? RT_SCOPE_UNIVERSE : RT_SCOPE_LINK;
    rt.rtm_type     = RTN_UNICAST;
    b.family(rt);
    b.attr(RTA_DST, dst[]);
    if (has_gw)
        b.attr(RTA_GATEWAY, gateway[]);
    if (oif != 0)
    {
        uint idx = oif;
        b.attr(RTA_OIF, as_bytes(idx));
    }
    return nl_send_ack(b.finalise(type, cast(ushort)(NLM_F_REQUEST | NLM_F_ACK | extra_flags), seq), seq);
}

int addr_msg(ushort type, ushort extra_flags, int ifindex, ubyte[4] addr, ubyte prefix)
{
    uint seq = ++g_seq;

    NlBuilder b;
    ifaddrmsg ifa;
    ifa.ifa_family    = AF_INET;
    ifa.ifa_prefixlen = prefix;
    ifa.ifa_scope     = RT_SCOPE_UNIVERSE;
    ifa.ifa_index     = ifindex;
    b.family(ifa);
    b.attr(IFA_LOCAL, addr[]);
    b.attr(IFA_ADDRESS, addr[]);
    return nl_send_ack(b.finalise(type, cast(ushort)(NLM_F_REQUEST | NLM_F_ACK | extra_flags), seq), seq);
}


// Open a dedicated NETLINK_ROUTE socket, send one request, wait for the ACK,
// close. Mirrors the per-query pattern in driver.linux.nl80211.
int nl_send_ack(const(ubyte)[] msg, uint seq)
{
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (fd < 0)
    {
        log_error("os.netlink.write", "socket() failed: errno=", last_errno());
        return TRANSPORT_ERROR;
    }
    scope(exit) close(fd);

    sockaddr_nl local;
    local.nl_family = AF_NETLINK;
    if (bind(fd, &local, sockaddr_nl.sizeof) < 0)
    {
        log_error("os.netlink.write", "bind() failed: errno=", last_errno());
        return TRANSPORT_ERROR;
    }

    // Backstop so a malformed request can't wedge the main loop waiting on an
    // ACK that never comes. Real kernel ACKs return in microseconds.
    timeval tv;
    tv.tv_sec  = 1;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, timeval.sizeof);

    sockaddr_nl kernel;
    kernel.nl_family = AF_NETLINK;
    if (sendto(fd, msg.ptr, msg.length, 0, &kernel, sockaddr_nl.sizeof) != cast(ptrdiff_t)msg.length)
    {
        log_error("os.netlink.write", "sendto() failed: errno=", last_errno());
        return TRANSPORT_ERROR;
    }

    ubyte[1024] buf = void;
    ptrdiff_t n = recv(fd, buf.ptr, buf.length, 0);
    if (n < 0)
    {
        log_error("os.netlink.write", "recv(ack) failed: errno=", last_errno());
        return TRANSPORT_ERROR;
    }

    const(ubyte)[] data = buf[0 .. cast(size_t)n];
    while (data.length >= nlmsghdr.sizeof)
    {
        const(nlmsghdr)* h = peek!nlmsghdr(data);
        if (!h || h.nlmsg_len < nlmsghdr.sizeof || h.nlmsg_len > data.length)
            break;

        // NLMSG_ERROR carries `int error` immediately after the header:
        // 0 means a pure ACK (success), negative is -errno.
        if (h.nlmsg_type == NLMSG_ERROR)
        {
            const(int)* err = peek!int(data[nlmsghdr.sizeof .. $]);
            return err ? *err : TRANSPORT_ERROR;
        }

        uint aligned = (h.nlmsg_len + 3u) & ~3u;
        if (aligned >= data.length)
            break;
        data = data[aligned .. $];
    }

    log_warning("os.netlink.write", "no ACK in kernel reply (seq=", seq, ")");
    return TRANSPORT_ERROR;
}


// Minimal netlink message builder over a stack buffer. The two reinterpret
// boundaries are confined to as_bytes() (value -> bytes) and peek() (bytes ->
// struct); call sites build typed struct values and stay cast-free.
struct NlBuilder
{
nothrow @nogc:
    ubyte[512] buf = 0;
    size_t     len;

    // Place the family header (rtmsg/ndmsg/ifaddrmsg) right after the nlmsghdr.
    void family(T)(ref const T v)
    {
        len = nlmsghdr.sizeof;
        raw(as_bytes(v));
    }

    void attr(ushort type, const(ubyte)[] data)
    {
        rtattr a;
        a.rta_len  = cast(ushort)(rtattr.sizeof + data.length);
        a.rta_type = type;
        raw(as_bytes(a));
        raw(data);
        while ((len & 3) != 0)      // pad to 4 (buffer is zeroed; just advance)
            ++len;
    }

    // String attribute, NUL-terminated (IFLA_IFNAME / IFLA_INFO_KIND want the
    // trailing NUL counted in rta_len).
    void attr_str(ushort type, const(char)[] s)
    {
        ubyte[16] tmp = 0;
        size_t n = s.length < tmp.length ? s.length : tmp.length - 1;
        tmp[0 .. n] = cast(const(ubyte)[])s[0 .. n];
        attr(type, tmp[0 .. n + 1]);
    }

    // Open a nested attribute; returns the offset to back-patch in nest_end.
    // Children are appended with attr()/attr_str() between the two calls.
    size_t nest_begin(ushort type)
    {
        size_t at = len;
        rtattr a;
        a.rta_len  = 0;     // patched by nest_end
        a.rta_type = cast(ushort)(type | NLA_F_NESTED);
        raw(as_bytes(a));
        return at;
    }

    void nest_end(size_t at)
    {
        // Patch the nested attr's rta_len (first 2 bytes at `at`) -- same
        // in-place style as finalise()'s nlmsghdr write, confined to as_bytes.
        ushort total = cast(ushort)(len - at);
        buf[at .. at + ushort.sizeof] = as_bytes(total)[];
    }

    void raw(const(ubyte)[] b)
    {
        buf[len .. len + b.length] = b[];
        len += b.length;
    }

    const(ubyte)[] finalise(ushort type, ushort flags, uint seq)
    {
        nlmsghdr h;
        h.nlmsg_len   = cast(uint)len;
        h.nlmsg_type  = type;
        h.nlmsg_flags = flags;
        h.nlmsg_seq   = seq;
        buf[0 .. nlmsghdr.sizeof] = as_bytes(h)[];
        return buf[0 .. len];
    }
}

const(ubyte)[] as_bytes(T)(ref const T v)
    => (cast(const(ubyte)*)&v)[0 .. T.sizeof];

const(T)* peek(T)(const(ubyte)[] d)
    => d.length >= T.sizeof ? cast(const(T)*)d.ptr : null;


void report(Session session, int r, const(char)[] what, const(char)[] detail)
{
    if (r == 0)
        session.write_line("OK: ", what, detail);
    else if (r == TRANSPORT_ERROR)
        session.write_line("FAILED (netlink transport error, see log): ", what, detail);
    else
        session.write_line("REJECTED by kernel (errno=", -r, "): ", what, detail);
}


// --- string parsing (dependency-free) ---

bool parse_u8(const(char)[] s, out ubyte v)
{
    if (s.length == 0 || s.length > 3)
        return false;
    uint n = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        n = n * 10 + (c - '0');
    }
    if (n > 255)
        return false;
    v = cast(ubyte)n;
    return true;
}

bool parse_ipv4(const(char)[] s, out ubyte[4] ip)
{
    size_t start = 0, part = 0;
    for (size_t i = 0; i <= s.length; ++i)
    {
        if (i == s.length || s[i] == '.')
        {
            if (part >= 4)
                return false;
            if (!parse_u8(s[start .. i], ip[part]))
                return false;
            ++part;
            start = i + 1;
        }
    }
    return part == 4;
}

bool parse_cidr(const(char)[] s, out ubyte[4] ip, out ubyte prefix)
{
    prefix = 32;
    size_t slash = s.length;
    foreach (i, c; s)
    {
        if (c == '/')
        {
            slash = i;
            break;
        }
    }
    if (!parse_ipv4(s[0 .. slash], ip))
        return false;
    if (slash < s.length)
    {
        ubyte p;
        if (!parse_u8(s[slash + 1 .. $], p) || p > 32)
            return false;
        prefix = p;
    }
    return true;
}

bool parse_hex_nibble(char c, out ubyte v)
{
    if (c >= '0' && c <= '9')
        v = cast(ubyte)(c - '0');
    else if (c >= 'a' && c <= 'f')
        v = cast(ubyte)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F')
        v = cast(ubyte)(c - 'A' + 10);
    else
        return false;
    return true;
}

bool parse_mac(const(char)[] s, out ubyte[6] mac)
{
    size_t start = 0, part = 0;
    for (size_t i = 0; i <= s.length; ++i)
    {
        if (i == s.length || s[i] == ':' || s[i] == '-')
        {
            if (part >= 6)
                return false;
            const(char)[] tok = s[start .. i];
            ubyte hi, lo;
            if (tok.length != 2 || !parse_hex_nibble(tok[0], hi) || !parse_hex_nibble(tok[1], lo))
                return false;
            mac[part] = cast(ubyte)((hi << 4) | lo);
            ++part;
            start = i + 1;
        }
    }
    return part == 6;
}


// === netlink protocol (subset; duplicates a few defs from driver.linux.netlink
//     -- consolidate into a shared module as the writer grows) ===

enum AF_NETLINK    = 16;
enum SOCK_RAW      = 3;
enum NETLINK_ROUTE = 0;
enum AF_INET       = 2;

enum SOL_SOCKET    = 1;
enum SO_RCVTIMEO   = 20;

enum NLMSG_ERROR   = 2;

enum NLM_F_REQUEST = 0x01;
enum NLM_F_ACK     = 0x04;
enum NLM_F_EXCL    = 0x200;
enum NLM_F_REPLACE = 0x100;
enum NLM_F_CREATE  = 0x400;

enum RTM_NEWLINK   = 16;
enum RTM_DELLINK   = 17;
enum RTM_NEWROUTE  = 24;
enum RTM_DELROUTE  = 25;
enum RTM_NEWNEIGH  = 28;
enum RTM_DELNEIGH  = 29;
enum RTM_NEWADDR   = 20;
enum RTM_DELADDR   = 21;

enum IFF_UP        = 0x1;
enum NLA_F_NESTED  = 0x8000;

enum IFLA_ADDRESS   = 1;
enum IFLA_IFNAME    = 3;
enum IFLA_MASTER    = 10;
enum IFLA_LINKINFO  = 18;
enum IFLA_INFO_KIND = 1;    // nested under IFLA_LINKINFO

enum RT_TABLE_MAIN     = 254;
enum RTPROT_OPENWATT   = 80;    // private protocol id -- our routes are tagged with this
enum RT_SCOPE_UNIVERSE = 0;
enum RT_SCOPE_LINK     = 253;
enum RTN_UNICAST       = 1;

enum RTA_DST     = 1;
enum RTA_OIF     = 4;
enum RTA_GATEWAY = 5;

enum NDA_DST     = 1;
enum NDA_LLADDR  = 2;

enum IFA_ADDRESS = 1;
enum IFA_LOCAL   = 2;

enum int TRANSPORT_ERROR = int.min;

version (D_LP64)
    alias c_long = long;
else
    alias c_long = int;

struct timeval
{
    c_long tv_sec;
    c_long tv_usec;
}

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

struct ifaddrmsg
{
    ubyte ifa_family;
    ubyte ifa_prefixlen;
    ubyte ifa_flags;
    ubyte ifa_scope;
    uint  ifa_index;
}

extern(C) nothrow @nogc
{
    int socket(int domain, int type, int protocol);
    int bind(int fd, const(void)* addr, uint addrlen);
    int setsockopt(int fd, int level, int optname, const(void)* optval, uint optlen);
    ptrdiff_t sendto(int fd, const(void)* buf, size_t len, int flags, const(void)* dest_addr, uint addrlen);
    ptrdiff_t recv(int fd, void* buf, size_t len, int flags);
    uint if_nametoindex(const(char)* ifname);
    int* __errno_location();
}

int last_errno() => *__errno_location();
