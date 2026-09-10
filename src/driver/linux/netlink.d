module driver.linux.netlink;

version (linux):

import urt.array;
import urt.log;
import urt.time;

import manager;
import manager.plugin;

import driver.linux.fdwatch : add_fd_watcher;

import urt.internal.sys.posix;

nothrow @nogc:


// RTNetlink listener -- async hotplug, neighbour and (future) addr/route notifications for any
// module that wants them. One shared NETLINK_ROUTE socket on the reactor's fd pool; subscribers
// register handlers per message family. Adding RTM_NEWADDR / RTM_NEWROUTE is a matter of joining
// the RTNLGRP_* group at bind time and adding a handler list.

alias LinkChangedHandler = void delegate(uint ifindex, const(char)[] name, bool up, bool removed) nothrow @nogc;

void subscribe_link_changed(LinkChangedHandler handler)
{
    g_link_handlers ~= handler;
}

// One kernel neighbour entry as the kernel reports it; ip is 4 or 16 network-order bytes per family.
struct KernelNeighbour
{
    int       ifindex;
    ushort    state;        // NUD_*
    ubyte     flags;        // NTF_*
    ubyte     family;       // AF_INET / AF_INET6
    ubyte[16] ip;
    ubyte[6]  mac;
    bool      has_mac;
}

alias NeighbourChangedHandler = void delegate(ref const KernelNeighbour neighbour, bool removed) nothrow @nogc;

void subscribe_neighbour_changed(NeighbourChangedHandler handler)
{
    g_neighbour_handlers ~= handler;
}

private __gshared Array!LinkChangedHandler g_link_handlers;
private __gshared Array!NeighbourChangedHandler g_neighbour_handlers;


class LinuxNetlinkModule : Module
{
    mixin DeclareModule!"os.netlink";
nothrow @nogc:

    override void pre_init()
    {
        _fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
        if (_fd < 0)
        {
            log_error("os.netlink", "socket() failed: errno=", last_errno());
            return;
        }

        sockaddr_nl addr;
        addr.nl_family = AF_NETLINK;
        addr.nl_groups = (1 << (RTNLGRP_LINK - 1)) | (1 << (RTNLGRP_NEIGH - 1));
        if (bind(_fd, &addr, sockaddr_nl.sizeof) < 0)
        {
            log_error("os.netlink", "bind() failed: errno=", last_errno());
            close(_fd);
            _fd = -1;
            return;
        }

        int flags = fcntl(_fd, F_GETFL, 0);
        if (flags < 0 || fcntl(_fd, F_SETFL, flags | O_NONBLOCK) < 0)
        {
            log_error("os.netlink", "fcntl(O_NONBLOCK) failed: errno=", last_errno());
            close(_fd);
            _fd = -1;
            return;
        }

        if (!add_fd_watcher(&service, &collect_fds))
        {
            log_error("os.netlink", "no fd waiter; kernel notifications disabled");
            close(_fd);
            _fd = -1;
        }
    }

private:
    int _fd = -1;

    void collect_fds(ref Array!pollfd fds)
    {
        if (_fd >= 0)
            fds ~= pollfd(_fd, POLLIN);
    }

    void service()
    {
        ubyte[8192] buf = void;
        while (true)
        {
            ptrdiff_t n = recv(_fd, buf.ptr, buf.length, 0);
            if (n < 0)
            {
                int e = last_errno();
                if (e == EAGAIN_ || e == EWOULDBLOCK_ || e == EINTR_)
                    return;
                log_error("os.netlink", "recv failed: errno=", e);
                return;
            }
            if (n == 0)
                return;

            dispatch(buf[0 .. cast(size_t)n]);
        }
    }

    void dispatch(const(ubyte)[] data)
    {
        while (data.length >= nlmsghdr.sizeof)
        {
            const nlmsghdr* hdr = cast(const nlmsghdr*)data.ptr;
            uint len = hdr.nlmsg_len;
            if (len < nlmsghdr.sizeof || len > data.length)
                return;

            // The kernel may pack multiple messages into one datagram; messages
            // are 4-byte aligned. Stop on NLMSG_DONE; an inline NLMSG_ERROR is
            // logged but doesn't abort the batch.
            const(ubyte)[] msg = data[nlmsghdr.sizeof .. len];
            switch (hdr.nlmsg_type)
            {
                case NLMSG_DONE:
                    return;
                case NLMSG_ERROR:
                    log_warning("os.netlink", "kernel returned an error message");
                    break;
                case RTM_NEWLINK:
                case RTM_DELLINK:
                    handle_link(hdr.nlmsg_type == RTM_DELLINK, msg);
                    break;
                case RTM_NEWNEIGH:
                case RTM_DELNEIGH:
                    handle_neigh(hdr.nlmsg_type == RTM_DELNEIGH, msg);
                    break;
                default:
                    break;
            }

            uint aligned = (len + 3) & ~3u;
            if (aligned >= data.length)
                return;
            data = data[aligned .. $];
        }
    }

    void handle_link(bool removed, const(ubyte)[] msg)
    {
        if (msg.length < ifinfomsg.sizeof)
            return;
        const ifinfomsg* info = cast(const ifinfomsg*)msg.ptr;

        const(char)[] name;
        walk_attrs(msg[ifinfomsg.sizeof .. $], (ushort type, const(ubyte)[] payload) {
            if (type != IFLA_IFNAME)
                return;
            size_t l = 0;
            while (l < payload.length && payload[l] != 0)
                ++l;
            name = cast(const(char)[])payload[0 .. l];
        });

        bool up = (info.ifi_flags & IFF_UP) != 0;
        foreach (h; g_link_handlers[])
            h(cast(uint)info.ifi_index, name, up, removed);
    }

    void handle_neigh(bool removed, const(ubyte)[] msg)
    {
        if (msg.length < ndmsg.sizeof)
            return;
        const ndmsg* nd = cast(const ndmsg*)msg.ptr;
        if (nd.ndm_family != AF_INET && nd.ndm_family != AF_INET6)
            return;

        KernelNeighbour n;
        n.ifindex = nd.ndm_ifindex;
        n.state   = nd.ndm_state;
        n.flags   = nd.ndm_flags;
        n.family  = nd.ndm_family;
        size_t len = n.family == AF_INET6 ? 16 : 4;
        bool got_ip = false;
        walk_attrs(msg[ndmsg.sizeof .. $], (ushort type, const(ubyte)[] payload) {
            if (type == NDA_DST && payload.length >= len)
            {
                n.ip[0 .. len] = payload[0 .. len];
                got_ip = true;
            }
            else if (type == NDA_LLADDR && payload.length >= 6)
            {
                n.mac[] = payload[0 .. 6];
                n.has_mac = true;
            }
        });
        if (!got_ip)
            return;

        foreach (h; g_neighbour_handlers[])
            h(n, removed);
    }
}


// === netlink protocol ===

private:

void walk_attrs(const(ubyte)[] attrs, scope void delegate(ushort type, const(ubyte)[] payload) nothrow @nogc f)
{
    while (attrs.length >= rtattr.sizeof)
    {
        const rtattr* a = cast(const rtattr*)attrs.ptr;
        if (a.rta_len < rtattr.sizeof || a.rta_len > attrs.length)
            break;
        f(cast(ushort)(a.rta_type & 0x3FFF), attrs[rtattr.sizeof .. a.rta_len]);
        uint aligned = (a.rta_len + 3) & ~3u;
        if (aligned >= attrs.length)
            break;
        attrs = attrs[aligned .. $];
    }
}

enum AF_NETLINK    = 16;
enum SOCK_RAW      = 3;
enum NETLINK_ROUTE = 0;
enum AF_INET       = 2;
enum AF_INET6      = 10;

enum RTNLGRP_LINK         = 1;
enum RTNLGRP_NEIGH        = 3;
enum RTNLGRP_IPV4_IFADDR  = 5;
enum RTNLGRP_IPV6_IFADDR  = 9;
enum RTNLGRP_IPV4_ROUTE   = 7;
enum RTNLGRP_IPV6_ROUTE   = 11;

enum NLMSG_DONE  = 3;
enum NLMSG_ERROR = 2;

enum RTM_NEWLINK  = 16;
enum RTM_DELLINK  = 17;
enum RTM_NEWADDR  = 20;
enum RTM_DELADDR  = 21;
enum RTM_NEWNEIGH = 28;
enum RTM_DELNEIGH = 29;

enum IFLA_ADDRESS = 1;
enum IFLA_IFNAME  = 3;

enum NDA_DST    = 1;
enum NDA_LLADDR = 2;

enum IFF_UP = 0x1;

enum int EAGAIN_      = 11;
enum int EWOULDBLOCK_ = 11;
enum int EINTR_       = 4;

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

struct ifinfomsg
{
    ubyte  ifi_family;
    ubyte  __pad;
    ushort ifi_type;
    int    ifi_index;
    uint   ifi_flags;
    uint   ifi_change;
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

struct rtattr
{
    ushort rta_len;
    ushort rta_type;
}

extern(C) nothrow @nogc
{
    int socket(int domain, int type, int protocol);
    int bind(int fd, const(void)* addr, uint addrlen);
    ptrdiff_t recv(int fd, void* buf, size_t len, int flags);
    int* __errno_location();
}

int last_errno() => *__errno_location();
