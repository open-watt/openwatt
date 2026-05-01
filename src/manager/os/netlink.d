module manager.os.netlink;

version (linux):

import urt.array;
import urt.log;
import urt.time;

import manager;
import manager.plugin;

import urt.internal.sys.posix;

nothrow @nogc:


// RTNetlink listener -- async hotplug + addr/route notifications for any
// module that wants them. Single shared NETLINK_ROUTE socket, subscribers
// register handlers, the module pumps once per tick (non-blocking recv).
//
// Today only link-change is exposed (RTM_NEWLINK / RTM_DELLINK) since that's
// what the ethernet/wifi backends need. Adding RTM_NEWADDR / RTM_DELADDR /
// RTM_NEWROUTE / RTM_DELROUTE is a matter of subscribing to the relevant
// RTNLGRP_* multicast group at bind time and adding a handler list -- the
// IP stack work in src/protocol/ip/ will likely want them for the route /
// neighbour tables.

alias LinkChangedHandler = void delegate(uint ifindex, const(char)[] name, bool up, bool removed) nothrow @nogc;

void subscribe_link_changed(LinkChangedHandler handler)
{
    g_link_handlers ~= handler;
}

private __gshared Array!LinkChangedHandler g_link_handlers;


class LinuxNetlinkModule : Module
{
    mixin DeclareModule!"os.netlink";
nothrow @nogc:

    override void pre_init()
    {
        _fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
        if (_fd < 0)
        {
            writeError("netlink socket() failed: errno=", last_errno());
            return;
        }

        sockaddr_nl addr;
        addr.nl_family = AF_NETLINK;
        addr.nl_groups = (1 << (RTNLGRP_LINK - 1));
        if (bind(_fd, &addr, sockaddr_nl.sizeof) < 0)
        {
            writeError("netlink bind() failed: errno=", last_errno());
            close(_fd);
            _fd = -1;
            return;
        }

        int flags = fcntl(_fd, F_GETFL, 0);
        if (flags < 0 || fcntl(_fd, F_SETFL, flags | O_NONBLOCK) < 0)
        {
            writeError("netlink fcntl(O_NONBLOCK) failed: errno=", last_errno());
            close(_fd);
            _fd = -1;
            return;
        }
    }

    override void update()
    {
        if (_fd < 0)
            return;

        ubyte[8192] buf = void;
        while (true)
        {
            ptrdiff_t n = recv(_fd, buf.ptr, buf.length, 0);
            if (n < 0)
            {
                int e = last_errno();
                if (e == EAGAIN_ || e == EWOULDBLOCK_ || e == EINTR_)
                    return;
                writeError("netlink recv failed: errno=", e);
                return;
            }
            if (n == 0)
                return;

            dispatch(buf[0 .. cast(size_t)n]);
        }
    }

private:
    int _fd = -1;

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
            if (hdr.nlmsg_type == NLMSG_DONE)
                return;
            if (hdr.nlmsg_type == NLMSG_ERROR)
                writeWarning("netlink reported an error message");
            else if (hdr.nlmsg_type == RTM_NEWLINK || hdr.nlmsg_type == RTM_DELLINK)
                handle_link(hdr.nlmsg_type == RTM_DELLINK, data[nlmsghdr.sizeof .. len]);

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

        const(ubyte)[] attrs = msg[ifinfomsg.sizeof .. $];
        const(char)[] name;
        while (attrs.length >= rtattr.sizeof)
        {
            const rtattr* a = cast(const rtattr*)attrs.ptr;
            if (a.rta_len < rtattr.sizeof || a.rta_len > attrs.length)
                break;

            if (a.rta_type == IFLA_IFNAME)
            {
                const(ubyte)[] payload = attrs[rtattr.sizeof .. a.rta_len];
                size_t l = 0;
                while (l < payload.length && payload[l] != 0)
                    ++l;
                name = cast(const(char)[])payload[0 .. l];
            }

            uint aligned = (a.rta_len + 3) & ~3u;
            if (aligned >= attrs.length)
                break;
            attrs = attrs[aligned .. $];
        }

        bool up = (info.ifi_flags & IFF_UP) != 0;
        foreach (h; g_link_handlers[])
            h(cast(uint)info.ifi_index, name, up, removed);
    }
}


// === netlink protocol ===

private:

enum AF_NETLINK    = 16;
enum SOCK_RAW      = 3;
enum NETLINK_ROUTE = 0;

enum RTNLGRP_LINK         = 1;
enum RTNLGRP_IPV4_IFADDR  = 5;
enum RTNLGRP_IPV6_IFADDR  = 9;
enum RTNLGRP_IPV4_ROUTE   = 7;
enum RTNLGRP_IPV6_ROUTE   = 11;

enum NLMSG_DONE  = 3;
enum NLMSG_ERROR = 2;

enum RTM_NEWLINK = 16;
enum RTM_DELLINK = 17;
enum RTM_NEWADDR = 20;
enum RTM_DELADDR = 21;

enum IFLA_ADDRESS = 1;
enum IFLA_IFNAME  = 3;

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
