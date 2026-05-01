module manager.os.nl80211;

version (linux):

import urt.log;

import urt.internal.sys.posix;

nothrow @nogc:


// One-shot synchronous queries against the nl80211 generic-netlink family.
// Today we expose just the chipset-capability query a wifi radio runs at
// startup -- enough to refuse incompatible STA/AP/multi-AP configurations
// at validate time with a useful status message.
//
// The protocol path:
//   1. Open AF_NETLINK / NETLINK_GENERIC, bind (kernel auto-assigns port id).
//   2. CTRL_CMD_GETFAMILY against the genl controller (well-known id 0x10)
//      with CTRL_ATTR_FAMILY_NAME="nl80211" -> reply carries the dynamic
//      family id we'll use for nl80211 commands.
//   3. NL80211_CMD_GET_WIPHY (NLM_F_DUMP) for the radio's ifindex. Walk the
//      multipart reply for NL80211_ATTR_SUPPORTED_IFTYPES and
//      NL80211_ATTR_INTERFACE_COMBINATIONS, boil down to PhyCapabilities.
//
// On any failure (kernel too old, generic netlink unavailable, ifindex not
// a wireless device, query timeout) we return a struct with valid=false and
// the caller treats that as "unknown chipset, validate optimistically".


struct PhyCapabilities
{
    bool valid;             // false if the query failed -- caller should not gate on the rest.
    bool supports_sta;      // any combination allows the chipset to act as a STA.
    bool supports_ap;       // any combination allows the chipset to act as an AP.
    bool supports_sta_ap;   // some single combination allows STA + AP simultaneously.
    ubyte max_aps;          // largest AP count any combination admits (regardless of STA).
}


bool query_phy_capabilities(uint ifindex, out PhyCapabilities caps)
{
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    if (fd < 0)
    {
        writeWarning("nl80211: socket() failed: errno=", last_errno());
        return false;
    }
    scope(exit) urt.internal.sys.posix.close(fd);

    sockaddr_nl addr;
    addr.nl_family = AF_NETLINK;
    if (bind(fd, &addr, sockaddr_nl.sizeof) < 0)
    {
        writeWarning("nl80211: bind() failed: errno=", last_errno());
        return false;
    }

    // Cap blocking. Real kernel responses come back in microseconds; this is
    // just a backstop so a misbehaving netlink path can't hang the main loop.
    timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 200_000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, timeval.sizeof);

    ushort family_id;
    if (!resolve_family(fd, "nl80211\0", family_id))
        return false;

    return get_wiphy(fd, family_id, ifindex, caps);
}


private:


__gshared uint g_seq;


bool resolve_family(int fd, const(char)[] name, out ushort family_id)
{
    ubyte[64] buf = void;
    sockaddr_nl kernel;
    kernel.nl_family = AF_NETLINK;

    size_t off = 0;
    nlmsghdr* hdr = cast(nlmsghdr*)buf.ptr;
    hdr.nlmsg_type  = GENL_ID_CTRL;
    hdr.nlmsg_flags = NLM_F_REQUEST;
    hdr.nlmsg_seq   = ++g_seq;
    hdr.nlmsg_pid   = 0;
    off += nlmsghdr.sizeof;

    genlmsghdr* gh = cast(genlmsghdr*)(buf.ptr + off);
    gh.cmd      = CTRL_CMD_GETFAMILY;
    gh.gen_version = 1;
    gh.reserved = 0;
    off += genlmsghdr.sizeof;

    nlattr* na = cast(nlattr*)(buf.ptr + off);
    na.nla_len  = cast(ushort)(nlattr.sizeof + name.length);
    na.nla_type = CTRL_ATTR_FAMILY_NAME;
    off += nlattr.sizeof;
    buf[off .. off + name.length] = cast(const(ubyte)[])name;
    off += name.length;
    off = (off + 3) & ~3UL;

    hdr.nlmsg_len = cast(uint)off;

    if (sendto(fd, buf.ptr, off, 0, &kernel, sockaddr_nl.sizeof) != cast(ptrdiff_t)off)
    {
        writeWarning("nl80211: family-resolve sendto failed: errno=", last_errno());
        return false;
    }

    ubyte[1024] reply = void;
    ptrdiff_t n = recv(fd, reply.ptr, reply.length, 0);
    if (n < 0)
    {
        writeWarning("nl80211: family-resolve recv failed: errno=", last_errno());
        return false;
    }

    return parse_family_id(reply[0 .. cast(size_t)n], family_id);
}

bool parse_family_id(const(ubyte)[] data, out ushort family_id)
{
    if (data.length < nlmsghdr.sizeof) return false;
    const nlmsghdr* hdr = cast(const nlmsghdr*)data.ptr;
    if (hdr.nlmsg_type == NLMSG_ERROR) return false;
    if (hdr.nlmsg_len < nlmsghdr.sizeof + genlmsghdr.sizeof || hdr.nlmsg_len > data.length) return false;

    const(ubyte)[] attrs = data[nlmsghdr.sizeof + genlmsghdr.sizeof .. hdr.nlmsg_len];
    while (attrs.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)attrs.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > attrs.length) break;
        ushort type = a.nla_type & NLA_TYPE_MASK;
        const(ubyte)[] payload = attrs[nlattr.sizeof .. len];

        if (type == CTRL_ATTR_FAMILY_ID && payload.length >= 2)
        {
            family_id = *cast(const(ushort)*)payload.ptr;
            return true;
        }

        uint aligned = (len + 3) & ~3u;
        if (aligned >= attrs.length) break;
        attrs = attrs[aligned .. $];
    }
    return false;
}


bool get_wiphy(int fd, ushort family_id, uint ifindex, out PhyCapabilities caps)
{
    ubyte[64] buf = void;
    sockaddr_nl kernel;
    kernel.nl_family = AF_NETLINK;

    size_t off = 0;
    nlmsghdr* hdr = cast(nlmsghdr*)buf.ptr;
    hdr.nlmsg_type  = family_id;
    hdr.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    hdr.nlmsg_seq   = ++g_seq;
    hdr.nlmsg_pid   = 0;
    off += nlmsghdr.sizeof;

    genlmsghdr* gh = cast(genlmsghdr*)(buf.ptr + off);
    gh.cmd      = NL80211_CMD_GET_WIPHY;
    gh.gen_version = 1;
    gh.reserved = 0;
    off += genlmsghdr.sizeof;

    nlattr* na = cast(nlattr*)(buf.ptr + off);
    na.nla_len  = nlattr.sizeof + 4;
    na.nla_type = NL80211_ATTR_IFINDEX;
    off += nlattr.sizeof;
    *cast(uint*)(buf.ptr + off) = ifindex;
    off += 4;

    // SPLIT_WIPHY_DUMP requests one wiphy info chunk per message rather than
    // a single huge message; required to receive complete attributes on
    // recent kernels (>= 3.10) for some chipsets.
    na = cast(nlattr*)(buf.ptr + off);
    na.nla_len  = nlattr.sizeof;
    na.nla_type = NL80211_ATTR_SPLIT_WIPHY_DUMP;
    off += nlattr.sizeof;
    off = (off + 3) & ~3UL;

    hdr.nlmsg_len = cast(uint)off;

    if (sendto(fd, buf.ptr, off, 0, &kernel, sockaddr_nl.sizeof) != cast(ptrdiff_t)off)
    {
        writeWarning("nl80211: get-wiphy sendto failed: errno=", last_errno());
        return false;
    }

    bool done = false;
    while (!done)
    {
        ubyte[16384] reply = void;
        ptrdiff_t n = recv(fd, reply.ptr, reply.length, 0);
        if (n < 0)
        {
            writeWarning("nl80211: get-wiphy recv failed: errno=", last_errno());
            return false;
        }
        if (n == 0)
            return false;

        const(ubyte)[] data = reply[0 .. cast(size_t)n];
        while (data.length >= nlmsghdr.sizeof)
        {
            const nlmsghdr* mh = cast(const nlmsghdr*)data.ptr;
            uint len = mh.nlmsg_len;
            if (len < nlmsghdr.sizeof || len > data.length)
                return false;

            if (mh.nlmsg_type == NLMSG_DONE)
            {
                done = true;
                break;
            }
            if (mh.nlmsg_type == NLMSG_ERROR)
                return false;

            // genl message: nlmsghdr | genlmsghdr | nl80211 attributes
            if (len >= nlmsghdr.sizeof + genlmsghdr.sizeof)
            {
                const(ubyte)[] attrs = data[nlmsghdr.sizeof + genlmsghdr.sizeof .. len];
                parse_wiphy_attrs(attrs, caps);
            }

            uint aligned = (len + 3) & ~3u;
            if (aligned >= data.length) break;
            data = data[aligned .. $];
        }
    }

    caps.valid = caps.supports_sta || caps.supports_ap || caps.max_aps > 0;
    return true;
}


void parse_wiphy_attrs(const(ubyte)[] attrs, ref PhyCapabilities caps)
{
    while (attrs.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)attrs.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > attrs.length) break;
        ushort type = a.nla_type & NLA_TYPE_MASK;
        const(ubyte)[] payload = attrs[nlattr.sizeof .. len];

        if (type == NL80211_ATTR_SUPPORTED_IFTYPES)
            parse_iftype_set(payload, caps.supports_sta, caps.supports_ap);
        else if (type == NL80211_ATTR_INTERFACE_COMBINATIONS)
            parse_combinations(payload, caps);

        uint aligned = (len + 3) & ~3u;
        if (aligned >= attrs.length) break;
        attrs = attrs[aligned .. $];
    }
}

// Walks a SUPPORTED_IFTYPES- or LIMIT_TYPES-style nested attribute. Each child
// has its TYPE field set to an NL80211_IFTYPE_* value and no payload (flag).
void parse_iftype_set(const(ubyte)[] data, ref bool has_sta, ref bool has_ap)
{
    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        ushort iftype = a.nla_type & NLA_TYPE_MASK;
        if (iftype == NL80211_IFTYPE_STATION) has_sta = true;
        if (iftype == NL80211_IFTYPE_AP)      has_ap = true;
        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }
}

void parse_combinations(const(ubyte)[] data, ref PhyCapabilities caps)
{
    // Outer is a list of combinations; the kernel uses 1-based positional
    // indices in the TYPE field, which we ignore -- we walk every child.
    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        const(ubyte)[] combo = data[nlattr.sizeof .. len];
        parse_one_combination(combo, caps);
        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }
}

void parse_one_combination(const(ubyte)[] data, ref PhyCapabilities caps)
{
    uint maxnum = 0;
    bool combo_has_sta = false;
    bool combo_has_ap = false;
    uint sum_ap_max = 0;

    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        ushort type = a.nla_type & NLA_TYPE_MASK;
        const(ubyte)[] payload = data[nlattr.sizeof .. len];

        if (type == NL80211_IFACE_COMB_MAXNUM && payload.length >= 4)
            maxnum = *cast(const(uint)*)payload.ptr;
        else if (type == NL80211_IFACE_COMB_LIMITS)
            parse_limits(payload, combo_has_sta, combo_has_ap, sum_ap_max);

        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }

    if (combo_has_ap)
    {
        // sum_ap_max overcounts when a single limit covers {STA, AP, ...}, but
        // that's a worst-case overestimate; cap by MAXNUM, which represents
        // the combination's overall slot budget.
        uint cap = sum_ap_max < maxnum ? sum_ap_max : maxnum;
        if (cap > 0xFF) cap = 0xFF;
        if (cap > caps.max_aps) caps.max_aps = cast(ubyte)cap;
    }
    if (combo_has_sta && combo_has_ap && maxnum >= 2)
        caps.supports_sta_ap = true;
}

void parse_limits(const(ubyte)[] data, ref bool combo_has_sta, ref bool combo_has_ap, ref uint sum_ap_max)
{
    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        const(ubyte)[] limit = data[nlattr.sizeof .. len];
        parse_one_limit(limit, combo_has_sta, combo_has_ap, sum_ap_max);
        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }
}

void parse_one_limit(const(ubyte)[] data, ref bool combo_has_sta, ref bool combo_has_ap, ref uint sum_ap_max)
{
    uint max_count = 0;
    bool limit_has_sta = false;
    bool limit_has_ap = false;

    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        ushort type = a.nla_type & NLA_TYPE_MASK;
        const(ubyte)[] payload = data[nlattr.sizeof .. len];

        if (type == NL80211_IFACE_LIMIT_MAX && payload.length >= 4)
            max_count = *cast(const(uint)*)payload.ptr;
        else if (type == NL80211_IFACE_LIMIT_TYPES)
            parse_iftype_set(payload, limit_has_sta, limit_has_ap);

        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }

    if (limit_has_sta) combo_has_sta = true;
    if (limit_has_ap)
    {
        combo_has_ap = true;
        sum_ap_max += max_count;
    }
}


// === protocol constants and structures ===

enum AF_NETLINK      = 16;
enum SOCK_RAW        = 3;
enum NETLINK_GENERIC = 16;

enum SOL_SOCKET  = 1;
enum SO_RCVTIMEO = 20;

enum NLM_F_REQUEST = 1;
enum NLM_F_MULTI   = 2;
enum NLM_F_ACK     = 4;
enum NLM_F_ROOT    = 0x100;
enum NLM_F_MATCH   = 0x200;
enum NLM_F_DUMP    = NLM_F_ROOT | NLM_F_MATCH;

enum NLMSG_DONE   = 3;
enum NLMSG_ERROR  = 2;

// nla_type carries two flag bits in its high half (NESTED, NET_BYTEORDER);
// the low 14 bits are the actual attribute type.
enum NLA_TYPE_MASK = 0x3FFF;

enum GENL_ID_CTRL = 0x10;

enum CTRL_CMD_GETFAMILY    = 3;
enum CTRL_ATTR_FAMILY_ID   = 1;
enum CTRL_ATTR_FAMILY_NAME = 2;

enum NL80211_CMD_GET_WIPHY               = 1;
enum NL80211_ATTR_IFINDEX                = 3;
enum NL80211_ATTR_SUPPORTED_IFTYPES      = 32;
enum NL80211_ATTR_INTERFACE_COMBINATIONS = 120;
enum NL80211_ATTR_SPLIT_WIPHY_DUMP       = 174;

enum NL80211_IFTYPE_STATION = 2;
enum NL80211_IFTYPE_AP      = 3;

enum NL80211_IFACE_COMB_LIMITS = 1;
enum NL80211_IFACE_COMB_MAXNUM = 2;

enum NL80211_IFACE_LIMIT_MAX   = 1;
enum NL80211_IFACE_LIMIT_TYPES = 2;

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

struct genlmsghdr
{
    ubyte  cmd;
    ubyte  gen_version;
    ushort reserved;
}

struct nlattr
{
    ushort nla_len;
    ushort nla_type;
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
    int setsockopt(int fd, int level, int optname, const(void)* optval, uint optlen);
    ptrdiff_t sendto(int fd, const(void)* buf, size_t len, int flags, const(void)* dest_addr, uint addrlen);
    ptrdiff_t recv(int fd, void* buf, size_t len, int flags);
    int* __errno_location();
}

int last_errno() => *__errno_location();
