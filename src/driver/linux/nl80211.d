module driver.linux.nl80211;

version (linux):

import urt.log;

import urt.internal.sys.posix;

import driver.linux.raw : ioctl, ifreq, SIOCGIFFLAGS, IFF_UP, IFNAMSIZ;

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
    bool supports_monitor;  // any combination allows a monitor VIF.
    bool supports_sta_ap;   // some single combination allows STA + at least one AP.
    bool supports_sta_monitor;
    bool supports_ap_monitor;
    bool supports_sta_ap_monitor;
    ubyte max_aps;          // largest AP count when no STA is present.
    ubyte max_aps_with_sta; // largest AP count in a combination that also admits one STA.
    ubyte max_aps_with_monitor;
    ubyte max_aps_with_sta_monitor;
    ubyte max_monitors;     // largest monitor count when no STA/AP constraints are applied.
}


// Live state of one wifi VIF, from NL80211_CMD_GET_INTERFACE.
struct WifiIfInfo
{
    uint     ifindex;
    uint     iftype;        // NL80211_IFTYPE_* (name via wifi_iftype_name)
    uint     freq;          // operating frequency in MHz (0 if not on a channel)
    char[32] ssid;
    ubyte    ssid_len;

    const(char)[] ssid_s() const nothrow @nogc return => ssid[0 .. ssid_len];
}

alias WifiSink = void delegate(ref const WifiIfInfo info) nothrow @nogc;

const(char)[] wifi_iftype_name(uint t)
{
    switch (t)
    {
        case NL80211_IFTYPE_ADHOC:      return "adhoc";
        case NL80211_IFTYPE_STATION:    return "STA";
        case NL80211_IFTYPE_AP:         return "AP";
        case NL80211_IFTYPE_AP_VLAN:    return "AP-VLAN";
        case NL80211_IFTYPE_WDS:        return "WDS";
        case NL80211_IFTYPE_MONITOR:    return "monitor";
        case NL80211_IFTYPE_MESH_POINT: return "mesh";
        case NL80211_IFTYPE_P2P_CLIENT: return "P2P-client";
        case NL80211_IFTYPE_P2P_GO:     return "P2P-GO";
        default:                        return "wifi";
    }
}

// Dump every wifi VIF's live state (mode / SSID / frequency). The radio layer
// (VIF creation via iw, AP/STA association via hostapd/wpa_supplicant) is not in
// rtnetlink; this is the nl80211 view that makes /system/linux/print honest about
// wifi. Returns false (and sinks nothing) on any failure -- callers treat the
// absence as "no wifi state to report".
bool query_wifi_interfaces(scope WifiSink sink)
{
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    if (fd < 0)
    {
        log_warning("os.nl80211", "socket() failed: errno=", last_errno());
        return false;
    }
    scope(exit) urt.internal.sys.posix.close(fd);

    sockaddr_nl addr;
    addr.nl_family = AF_NETLINK;
    if (bind(fd, &addr, sockaddr_nl.sizeof) < 0)
        return false;

    timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 200_000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, timeval.sizeof);

    ushort family_id;
    if (!resolve_family(fd, "nl80211\0", family_id))
        return false;

    return get_interfaces(fd, family_id, sink);
}

bool query_phy_capabilities(uint ifindex, out PhyCapabilities caps)
{
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    if (fd < 0)
    {
        log_warning("os.nl80211", "socket() failed: errno=", last_errno());
        return false;
    }
    scope(exit) urt.internal.sys.posix.close(fd);

    sockaddr_nl addr;
    addr.nl_family = AF_NETLINK;
    if (bind(fd, &addr, sockaddr_nl.sizeof) < 0)
    {
        log_warning("os.nl80211", "bind() failed: errno=", last_errno());
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
    {
        log_warning("os.nl80211", "failed to resolve the nl80211 genl family");
        return false;
    }

    return get_wiphy(fd, family_id, ifindex, caps);
}

// Reset a wifi netdev to a clean station-mode slate before any STA/AP logic uses
// it. Tears down any AP or association left running by hostapd / wpa_supplicant /
// NetworkManager / a previous run, and leaves the link admin-up in managed mode.
// Mode-agnostic device preparation: the radio (WiFiInterface) owns the adapter
// and calls this on bring-up so we never inherit foreign state. Best-effort --
// STOP_AP/DISCONNECT legitimately fail when not currently AP/associated.
void reset_device(const(char)[] adapter, uint ifindex)
{
    if (ifindex == 0 || adapter.length >= IFNAMSIZ)
        return;

    int nl_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    scope(exit)
        if (nl_fd >= 0) urt.internal.sys.posix.close(nl_fd);
    if (nl_fd < 0)
        return;

    sockaddr_nl addr;
    addr.nl_family = AF_NETLINK;
    if (bind(nl_fd, &addr, sockaddr_nl.sizeof) < 0)
        return;
    timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 500_000;
    setsockopt(nl_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, timeval.sizeof);

    ushort family_id;
    if (!resolve_family(nl_fd, "nl80211\0", family_id))
        return;

    nl_device_cmd(nl_fd, family_id, NL80211_CMD_STOP_AP, ifindex, 0);
    nl_device_cmd(nl_fd, family_id, NL80211_CMD_DISCONNECT, ifindex, 0);

    // Force managed (station) mode -- the iftype change cycles the link down/up.
    set_device_iftype(adapter, ifindex, NL80211_IFTYPE_STATION);

    log_info("os.nl80211", "reset wifi device '", adapter, "' to clean station mode");
}

// Switch a wifi netdev to a specific iftype. The kernel requires the link
// admin-down for an iftype change, so this cycles it down/up around the
// SET_INTERFACE. AP bring-up calls this with NL80211_IFTYPE_AP before START_AP.
void set_device_iftype(const(char)[] adapter, uint ifindex, uint iftype)
{
    if (ifindex == 0 || adapter.length >= IFNAMSIZ)
        return;

    int io_fd = socket(AF_INET, SOCK_DGRAM, 0);
    int nl_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    scope(exit)
    {
        if (io_fd >= 0) urt.internal.sys.posix.close(io_fd);
        if (nl_fd >= 0) urt.internal.sys.posix.close(nl_fd);
    }
    if (io_fd < 0 || nl_fd < 0)
        return;

    sockaddr_nl addr;
    addr.nl_family = AF_NETLINK;
    if (bind(nl_fd, &addr, sockaddr_nl.sizeof) < 0)
        return;
    timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 500_000;
    setsockopt(nl_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, timeval.sizeof);

    ushort family_id;
    if (!resolve_family(nl_fd, "nl80211\0", family_id))
        return;

    set_if_up(io_fd, adapter, false);
    nl_device_cmd(nl_fd, family_id, NL80211_CMD_SET_INTERFACE, ifindex, iftype);
    set_if_up(io_fd, adapter, true);
}

// The wiphy (phy) index a netdev belongs to, or uint.max on failure. Needed to
// create sibling VIFs on the same radio (NL80211_CMD_NEW_INTERFACE).
uint read_wiphy(uint ifindex)
{
    int fd = nl_open_socket(false);
    if (fd < 0)
        return uint.max;
    scope(exit) nl_close(fd);

    ushort family; uint scan_grp, mlme_grp;
    if (!resolve_nl80211(fd, family, scan_grp, mlme_grp))
        return uint.max;

    NlBuilder b;
    b.start(family, NLM_F_REQUEST, ++g_seq, NL80211_CMD_GET_INTERFACE);
    b.put_u32(NL80211_ATTR_IFINDEX, ifindex);

    ubyte[2048] reply = void;
    size_t n;
    if (!nl_request(fd, b, reply[], n))
        return uint.max;
    const nlmsghdr* mh = cast(const nlmsghdr*)reply.ptr;
    if (n < nlmsghdr.sizeof + genlmsghdr.sizeof || mh.nlmsg_len > n)
        return uint.max;
    const(ubyte)[] attrs = reply[nlmsghdr.sizeof + genlmsghdr.sizeof .. mh.nlmsg_len];
    const(ubyte)[] w = find_attr(attrs, NL80211_ATTR_WIPHY);
    return w.length >= 4 ? *cast(const(uint)*)w.ptr : uint.max;
}

// Create an admin-up virtual interface `name` on `wiphy`. Used for multi-BSS
// and monitor capture: each peer gets its own netdev on the radio's phy. The
// kernel assigns the VIF's MAC. Returns false on failure.
bool create_vif(uint wiphy, const(char)[] name, uint iftype)
{
    if (name.length == 0 || name.length >= IFNAMSIZ)
        return false;

    int fd = nl_open_socket(false);
    if (fd < 0)
        return false;
    scope(exit) nl_close(fd);

    ushort family; uint scan_grp, mlme_grp;
    if (!resolve_nl80211(fd, family, scan_grp, mlme_grp))
        return false;

    char[IFNAMSIZ] nbuf = void;
    nbuf[0 .. name.length] = name[];
    nbuf[name.length] = 0;

    NlBuilder b;
    b.start(family, NLM_F_REQUEST | NLM_F_ACK, ++g_seq, NL80211_CMD_NEW_INTERFACE);
    b.put_u32(NL80211_ATTR_WIPHY, wiphy);
    b.put_bytes(NL80211_ATTR_IFNAME, cast(const(ubyte)[])nbuf[0 .. name.length + 1]);
    b.put_u32(NL80211_ATTR_IFTYPE, iftype);
    if (!nl_ack(fd, b, "NEW_INTERFACE"))
        return false;

    int io = socket(AF_INET, SOCK_DGRAM, 0);
    if (io >= 0)
    {
        set_if_up(io, name, true);
        urt.internal.sys.posix.close(io);
    }
    return true;
}

bool create_ap_vif(uint wiphy, const(char)[] name)
{
    return create_vif(wiphy, name, NL80211_IFTYPE_AP);
}

bool create_monitor_vif(uint wiphy, const(char)[] name)
{
    return create_vif(wiphy, name, NL80211_IFTYPE_MONITOR);
}

void delete_vif(uint ifindex)
{
    if (ifindex == 0)
        return;
    int fd = nl_open_socket(false);
    if (fd < 0)
        return;
    scope(exit) nl_close(fd);
    ushort family; uint scan_grp, mlme_grp;
    if (!resolve_nl80211(fd, family, scan_grp, mlme_grp))
        return;
    nl_device_cmd(fd, family, NL80211_CMD_DEL_INTERFACE, ifindex, 0);
}

bool set_vif_channel(uint ifindex, uint freq_mhz)
{
    if (ifindex == 0 || freq_mhz == 0)
        return false;

    int fd = nl_open_socket(false);
    if (fd < 0)
        return false;
    scope(exit) nl_close(fd);

    ushort family; uint scan_grp, mlme_grp;
    if (!resolve_nl80211(fd, family, scan_grp, mlme_grp))
        return false;

    NlBuilder b;
    b.start(family, NLM_F_REQUEST | NLM_F_ACK, ++g_seq, NL80211_CMD_SET_CHANNEL);
    b.put_u32(NL80211_ATTR_IFINDEX, ifindex);
    b.put_u32(NL80211_ATTR_WIPHY_FREQ, freq_mhz);
    return nl_ack(fd, b, "SET_CHANNEL");
}


private:

__gshared uint g_seq;

struct IfTypeSet
{
    bool sta;
    bool ap;
    bool monitor;
}

struct IfaceLimit
{
    uint max_count;
    IfTypeSet types;
}

// Send an nl80211 command carrying IFINDEX (and IFTYPE when iftype != 0) and
// drain its ACK. Used by reset_device / set_device_iftype; not-applicable
// errors are expected.
void nl_device_cmd(int fd, ushort family_id, ubyte cmd, uint ifindex, uint iftype)
{
    ubyte[128] buf = void;
    size_t off = 0;
    nlmsghdr* hdr = cast(nlmsghdr*)buf.ptr;
    hdr.nlmsg_type  = family_id;
    hdr.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    hdr.nlmsg_seq   = ++g_seq;
    hdr.nlmsg_pid   = 0;
    off += nlmsghdr.sizeof;

    genlmsghdr* gh = cast(genlmsghdr*)(buf.ptr + off);
    gh.cmd = cmd;
    gh.gen_version = 1;
    gh.reserved = 0;
    off += genlmsghdr.sizeof;

    nlattr* na = cast(nlattr*)(buf.ptr + off);
    na.nla_len  = nlattr.sizeof + 4;
    na.nla_type = NL80211_ATTR_IFINDEX;
    off += nlattr.sizeof;
    *cast(uint*)(buf.ptr + off) = ifindex;
    off += 4;

    if (iftype != 0)
    {
        na = cast(nlattr*)(buf.ptr + off);
        na.nla_len  = nlattr.sizeof + 4;
        na.nla_type = NL80211_ATTR_IFTYPE;
        off += nlattr.sizeof;
        *cast(uint*)(buf.ptr + off) = iftype;
        off += 4;
    }

    hdr.nlmsg_len = cast(uint)off;

    sockaddr_nl k;
    k.nl_family = AF_NETLINK;
    if (sendto(fd, buf.ptr, off, 0, &k, sockaddr_nl.sizeof) != cast(ptrdiff_t)off)
        return;
    ubyte[1024] reply = void;
    recv(fd, reply.ptr, reply.length, 0);   // drain ack (ignored)
}

void set_if_up(int fd, const(char)[] adapter, bool up)
{
    ifreq req;
    req.ifr_name[0 .. adapter.length] = adapter[];
    req.ifr_name[adapter.length] = 0;
    if (ioctl(fd, SIOCGIFFLAGS, &req) < 0)
        return;
    if (up)
        req.ifru_flags |= IFF_UP;
    else
        req.ifru_flags &= ~IFF_UP;
    ioctl(fd, SIOCSIFFLAGS, &req);
}

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
        log_warning("os.nl80211", "family-resolve sendto failed: errno=", last_errno());
        return false;
    }

    // The GETFAMILY reply carries the family's full op and mcast-group lists
    // (~2.5KB for nl80211) and a short recv truncates the datagram.
    ubyte[8192] reply = void;
    ptrdiff_t n = recv(fd, reply.ptr, reply.length, 0);
    if (n < 0)
    {
        log_warning("os.nl80211", "family-resolve recv failed: errno=", last_errno());
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
        log_warning("os.nl80211", "get-wiphy sendto failed: errno=", last_errno());
        return false;
    }

    bool done = false;
    while (!done)
    {
        ubyte[16_384] reply = void;
        ptrdiff_t n = recv(fd, reply.ptr, reply.length, 0);
        if (n < 0)
        {
            log_warning("os.nl80211", "get-wiphy recv failed: errno=", last_errno());
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
            {
                log_warning("os.nl80211", "get-wiphy reply truncated (len=", len, " avail=", data.length, ")");
                return false;
            }

            if (mh.nlmsg_type == NLMSG_DONE)
            {
                done = true;
                break;
            }
            if (mh.nlmsg_type == NLMSG_ERROR)
            {
                int err = len >= nlmsghdr.sizeof + int.sizeof ? *cast(const(int)*)(data.ptr + nlmsghdr.sizeof) : 0;
                log_warning("os.nl80211", "get-wiphy rejected by kernel (err=", err, ")");
                return false;
            }

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

    if (caps.supports_ap && caps.max_aps == 0)
        caps.max_aps = 1;
    if (caps.supports_monitor && caps.max_monitors == 0)
        caps.max_monitors = 1;

    caps.valid = caps.supports_sta || caps.supports_ap || caps.supports_monitor ||
                 caps.max_aps > 0 || caps.max_monitors > 0;
    return true;
}


bool get_interfaces(int fd, ushort family_id, scope WifiSink sink)
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
    gh.cmd         = NL80211_CMD_GET_INTERFACE;
    gh.gen_version = 1;
    gh.reserved    = 0;
    off += genlmsghdr.sizeof;

    hdr.nlmsg_len = cast(uint)off;

    if (sendto(fd, buf.ptr, off, 0, &kernel, sockaddr_nl.sizeof) != cast(ptrdiff_t)off)
    {
        log_warning("os.nl80211", "get-interface sendto failed: errno=", last_errno());
        return false;
    }

    bool done = false;
    while (!done)
    {
        ubyte[8192] reply = void;
        ptrdiff_t n = recv(fd, reply.ptr, reply.length, 0);
        if (n <= 0)
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

            if (len >= nlmsghdr.sizeof + genlmsghdr.sizeof)
                parse_interface_attrs(data[nlmsghdr.sizeof + genlmsghdr.sizeof .. len], sink);

            uint aligned = (len + 3) & ~3u;
            if (aligned >= data.length) break;
            data = data[aligned .. $];
        }
    }
    return true;
}

void parse_interface_attrs(const(ubyte)[] attrs, scope WifiSink sink)
{
    WifiIfInfo info;
    bool have_ifindex = false;

    while (attrs.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)attrs.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > attrs.length) break;
        ushort type = a.nla_type & NLA_TYPE_MASK;
        const(ubyte)[] payload = attrs[nlattr.sizeof .. len];

        switch (type)
        {
            case NL80211_ATTR_IFINDEX:
                if (payload.length >= 4) { info.ifindex = *cast(const(uint)*)payload.ptr; have_ifindex = true; }
                break;
            case NL80211_ATTR_IFTYPE:
                if (payload.length >= 4) info.iftype = *cast(const(uint)*)payload.ptr;
                break;
            case NL80211_ATTR_WIPHY_FREQ:
                if (payload.length >= 4) info.freq = *cast(const(uint)*)payload.ptr;
                break;
            case NL80211_ATTR_SSID:
                size_t c = payload.length < info.ssid.length ? payload.length : info.ssid.length;
                info.ssid[0 .. c] = cast(const(char)[])payload[0 .. c];
                info.ssid_len = cast(ubyte)c;
                break;
            default:
                break;
        }

        uint aligned = (len + 3) & ~3u;
        if (aligned >= attrs.length) break;
        attrs = attrs[aligned .. $];
    }

    if (have_ifindex)
        sink(info);
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
        {
            IfTypeSet types;
            parse_iftype_set(payload, types);
            if (types.sta)     caps.supports_sta = true;
            if (types.ap)      caps.supports_ap = true;
            if (types.monitor) caps.supports_monitor = true;
        }
        else if (type == NL80211_ATTR_INTERFACE_COMBINATIONS)
            parse_combinations(payload, caps);

        uint aligned = (len + 3) & ~3u;
        if (aligned >= attrs.length) break;
        attrs = attrs[aligned .. $];
    }
}

// Walks a SUPPORTED_IFTYPES- or LIMIT_TYPES-style nested attribute. Each child
// has its TYPE field set to an NL80211_IFTYPE_* value and no payload (flag).
void parse_iftype_set(const(ubyte)[] data, ref IfTypeSet types)
{
    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        ushort iftype = a.nla_type & NLA_TYPE_MASK;
        if (iftype == NL80211_IFTYPE_STATION) types.sta = true;
        if (iftype == NL80211_IFTYPE_AP)      types.ap = true;
        if (iftype == NL80211_IFTYPE_MONITOR) types.monitor = true;
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
    IfaceLimit[16] limits;
    size_t limit_count;

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
            parse_limits(payload, limits, limit_count);

        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }

    bool combo_has_sta;
    bool combo_has_ap;
    bool combo_has_monitor;
    uint sum_ap_max;
    uint sum_monitor_max;

    foreach (ref const limit; limits[0 .. limit_count])
    {
        if (limit.types.sta) combo_has_sta = true;
        if (limit.types.ap)
        {
            combo_has_ap = true;
            sum_ap_max += limit.max_count;
        }
        if (limit.types.monitor)
        {
            combo_has_monitor = true;
            sum_monitor_max += limit.max_count;
        }
    }

    if (combo_has_sta)     caps.supports_sta = true;
    if (combo_has_ap)      caps.supports_ap = true;
    if (combo_has_monitor) caps.supports_monitor = true;

    if (combo_has_ap)
    {
        uint cap = cap_by_maxnum(sum_ap_max, maxnum);
        if (cap > 0xFF) cap = 0xFF;
        if (cap > caps.max_aps) caps.max_aps = cast(ubyte)cap;
    }
    if (combo_has_monitor)
    {
        uint cap = cap_by_maxnum(sum_monitor_max, maxnum);
        if (cap > 0xFF) cap = 0xFF;
        if (cap > caps.max_monitors) caps.max_monitors = cast(ubyte)cap;
    }

    if (combo_has_sta && combo_has_ap && (maxnum == 0 || maxnum >= 2))
    {
        bool possible;
        uint best_with_sta = max_aps_with_reserved(limits, limit_count, maxnum, true, false, possible);
        if (best_with_sta > 0)
        {
            if (best_with_sta > 0xFF) best_with_sta = 0xFF;
            caps.supports_sta_ap = true;
            if (best_with_sta > caps.max_aps_with_sta)
                caps.max_aps_with_sta = cast(ubyte)best_with_sta;
        }
    }

    if (combo_has_sta && combo_has_monitor && (maxnum == 0 || maxnum >= 2))
    {
        bool possible;
        max_aps_with_reserved(limits, limit_count, maxnum, true, true, possible);
        if (possible)
            caps.supports_sta_monitor = true;
    }

    if (combo_has_ap && combo_has_monitor && (maxnum == 0 || maxnum >= 2))
    {
        bool possible;
        uint best_with_monitor = max_aps_with_reserved(limits, limit_count, maxnum, false, true, possible);
        if (possible && best_with_monitor > 0)
        {
            if (best_with_monitor > 0xFF) best_with_monitor = 0xFF;
            caps.supports_ap_monitor = true;
            if (best_with_monitor > caps.max_aps_with_monitor)
                caps.max_aps_with_monitor = cast(ubyte)best_with_monitor;
        }
    }

    if (combo_has_sta && combo_has_ap && combo_has_monitor && (maxnum == 0 || maxnum >= 3))
    {
        bool possible;
        uint best_with_sta_monitor = max_aps_with_reserved(limits, limit_count, maxnum, true, true, possible);
        if (possible && best_with_sta_monitor > 0)
        {
            if (best_with_sta_monitor > 0xFF) best_with_sta_monitor = 0xFF;
            caps.supports_sta_ap_monitor = true;
            if (best_with_sta_monitor > caps.max_aps_with_sta_monitor)
                caps.max_aps_with_sta_monitor = cast(ubyte)best_with_sta_monitor;
        }
    }
}

uint cap_by_maxnum(uint count, uint maxnum)
{
    return maxnum != 0 && count > maxnum ? maxnum : count;
}

uint max_aps_with_reserved(ref const IfaceLimit[16] limits, size_t limit_count, uint maxnum, bool need_sta, bool need_monitor, ref bool possible)
{
    uint best;
    size_t sta_choices = need_sta ? limit_count : 1;
    size_t monitor_choices = need_monitor ? limit_count : 1;

    foreach (sta_choice; 0 .. sta_choices)
    {
        size_t sta_i = need_sta ? sta_choice : size_t.max;
        if (need_sta && (!limits[sta_i].types.sta || limits[sta_i].max_count == 0))
            continue;

        foreach (monitor_choice; 0 .. monitor_choices)
        {
            size_t monitor_i = need_monitor ? monitor_choice : size_t.max;
            if (need_monitor && (!limits[monitor_i].types.monitor || limits[monitor_i].max_count == 0))
                continue;

            uint reserved_total;
            bool ok = true;
            foreach (i; 0 .. limit_count)
            {
                uint reserved_here;
                if (need_sta && i == sta_i) ++reserved_here;
                if (need_monitor && i == monitor_i) ++reserved_here;
                reserved_total += reserved_here;
                if (reserved_here > limits[i].max_count)
                {
                    ok = false;
                    break;
                }
            }
            if (!ok || (maxnum > 0 && reserved_total > maxnum))
                continue;

            uint ap_count;
            foreach (i; 0 .. limit_count)
            {
                if (!limits[i].types.ap)
                    continue;
                uint reserved_here;
                if (need_sta && i == sta_i) ++reserved_here;
                if (need_monitor && i == monitor_i) ++reserved_here;
                ap_count += limits[i].max_count - reserved_here;
            }
            if (maxnum > 0)
                ap_count = cap_by_maxnum(ap_count, maxnum - reserved_total);
            possible = true;
            if (ap_count > best)
                best = ap_count;
        }
    }

    return best;
}

void parse_limits(const(ubyte)[] data, ref IfaceLimit[16] limits, ref size_t limit_count)
{
    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        const(ubyte)[] limit = data[nlattr.sizeof .. len];
        if (limit_count < limits.length)
        {
            parse_one_limit(limit, limits[limit_count]);
            ++limit_count;
        }
        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }
}

void parse_one_limit(const(ubyte)[] data, ref IfaceLimit limit)
{
    while (data.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)data.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > data.length) break;
        ushort type = a.nla_type & NLA_TYPE_MASK;
        const(ubyte)[] payload = data[nlattr.sizeof .. len];

        if (type == NL80211_IFACE_LIMIT_MAX && payload.length >= 4)
            limit.max_count = *cast(const(uint)*)payload.ptr;
        else if (type == NL80211_IFACE_LIMIT_TYPES)
            parse_iftype_set(payload, limit.types);

        uint aligned = (len + 3) & ~3u;
        if (aligned >= data.length) break;
        data = data[aligned .. $];
    }
}


// === protocol constants and structures ===
// Public so driver.linux.nl80211_sta reuses this genl/netlink plumbing (structs,
// NLM_F_*/CTRL_*/NL80211_* enums, extern(C) socket bindings) instead of
// duplicating the ABI. The query helpers above stay private.
public:

enum AF_NETLINK      = 16;
enum AF_INET         = 2;
enum SOCK_RAW        = 3;
enum SOCK_DGRAM      = 2;
enum NETLINK_GENERIC = 16;
enum SIOCSIFFLAGS    = 0x8914;   // SIOCGIFFLAGS + IFF_UP come from driver.linux.raw

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
enum NL80211_CMD_GET_INTERFACE           = 5;
enum NL80211_CMD_SET_INTERFACE           = 6;
enum NL80211_CMD_NEW_INTERFACE           = 7;
enum NL80211_CMD_DEL_INTERFACE           = 8;
enum NL80211_CMD_STOP_AP                 = 16;
enum NL80211_CMD_DISCONNECT              = 48;
enum NL80211_CMD_SET_CHANNEL             = 65;
enum NL80211_ATTR_WIPHY                  = 1;
enum NL80211_ATTR_IFINDEX                = 3;
enum NL80211_ATTR_IFNAME                 = 4;
enum NL80211_ATTR_IFTYPE                 = 5;
enum NL80211_ATTR_SUPPORTED_IFTYPES      = 32;
enum NL80211_ATTR_WIPHY_FREQ             = 38;
enum NL80211_ATTR_SSID                   = 52;
enum NL80211_ATTR_INTERFACE_COMBINATIONS = 120;
enum NL80211_ATTR_SPLIT_WIPHY_DUMP       = 174;

enum NL80211_IFTYPE_ADHOC      = 1;
enum NL80211_IFTYPE_STATION    = 2;
enum NL80211_IFTYPE_AP         = 3;
enum NL80211_IFTYPE_AP_VLAN    = 4;
enum NL80211_IFTYPE_WDS        = 5;
enum NL80211_IFTYPE_MONITOR    = 6;
enum NL80211_IFTYPE_MESH_POINT = 7;
enum NL80211_IFTYPE_P2P_CLIENT = 8;
enum NL80211_IFTYPE_P2P_GO     = 9;

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


// RSSI dBm -> 0..100 quality scale. -50 or better -> 100, -100 or worse -> 0,
// linear in between.
ubyte rssi_to_quality(int rssi_dbm) pure
{
    if (rssi_dbm >= -50)
        return 100;
    if (rssi_dbm <= -100)
        return 0;
    return cast(ubyte)(2 * (rssi_dbm + 100));
}


// === shared generic-netlink toolkit ===
// Used by both the STA session (driver.linux.nl80211_sta) and the radio scan
// (driver.linux.wifi). The device-level home so neither duplicates the ABI.

enum SOL_NETLINK            = 270;
enum NETLINK_ADD_MEMBERSHIP = 1;

enum CTRL_ATTR_MCAST_GROUPS   = 7;
enum CTRL_ATTR_MCAST_GRP_NAME = 1;
enum CTRL_ATTR_MCAST_GRP_ID   = 2;

enum NL80211_CMD_GET_SCAN         = 32;
enum NL80211_CMD_TRIGGER_SCAN     = 33;
enum NL80211_CMD_NEW_SCAN_RESULTS = 34;
enum NL80211_CMD_SCAN_ABORTED     = 35;

enum NL80211_ATTR_SCAN_SSIDS = 45;
enum NL80211_ATTR_BSS        = 47;

enum NL80211_BSS_BSSID                = 1;
enum NL80211_BSS_FREQUENCY            = 2;
enum NL80211_BSS_CAPABILITY           = 5;
enum NL80211_BSS_INFORMATION_ELEMENTS = 6;
enum NL80211_BSS_SIGNAL_MBM           = 7;
enum NL80211_BSS_STATUS               = 9;


// === shared WPA key / cipher / auth ABI (STA session + AP session) ===

enum NL80211_CMD_NEW_KEY = 11;

enum NL80211_ATTR_MAC                    = 6;
enum NL80211_ATTR_KEY_DATA               = 7;
enum NL80211_ATTR_KEY_IDX                = 8;
enum NL80211_ATTR_KEY_CIPHER             = 9;
enum NL80211_ATTR_KEY_SEQ                = 10;
enum NL80211_ATTR_IE                     = 42;
enum NL80211_ATTR_AUTH_TYPE              = 53;
enum NL80211_ATTR_REASON_CODE            = 54;
enum NL80211_ATTR_KEY_TYPE               = 55;
enum NL80211_ATTR_CONTROL_PORT           = 68;
enum NL80211_ATTR_CIPHER_SUITES_PAIRWISE = 73;
enum NL80211_ATTR_CIPHER_SUITE_GROUP     = 74;
enum NL80211_ATTR_WPA_VERSIONS           = 75;
enum NL80211_ATTR_AKM_SUITES             = 76;

enum NL80211_KEYTYPE_GROUP        = 0;
enum NL80211_KEYTYPE_PAIRWISE     = 1;
enum NL80211_AUTHTYPE_OPEN_SYSTEM = 0;
enum NL80211_WPA_VERSION_2        = 2;

// IEEE 802.11 cipher / AKM suite selectors (00-0F-AC OUI).
enum uint rsn_cipher_ccmp = 0x000fac04;
enum uint rsn_akm_psk     = 0x000fac02;

// WPA2-PSK / CCMP RSN IE. Byte-identical between the STA assoc request
// (NL80211_ATTR_IE), the AP beacon tail, and the in-process 4-way MIC input.
static immutable ubyte[22] wpa2_psk_ccmp_rsn_ie = [
    0x30, 0x14,             // RSN element, length 20
    0x01, 0x00,             // version 1
    0x00, 0x0f, 0xac, 0x04, // group cipher: CCMP
    0x01, 0x00,             // pairwise count 1
    0x00, 0x0f, 0xac, 0x04, // pairwise: CCMP
    0x01, 0x00,             // AKM count 1
    0x00, 0x0f, 0xac, 0x02, // AKM: PSK
    0x00, 0x00,             // RSN capabilities
];

// Fixed-buffer generic-netlink message builder.
struct NlBuilder
{
nothrow @nogc:
    ubyte[2048] buf = void;
    size_t off;

    void start(ushort type, ushort flags, uint seq, ubyte cmd)
    {
        nlmsghdr* h = cast(nlmsghdr*)buf.ptr;
        h.nlmsg_type  = type;
        h.nlmsg_flags = flags;
        h.nlmsg_seq   = seq;
        h.nlmsg_pid   = 0;
        off = nlmsghdr.sizeof;

        genlmsghdr* g = cast(genlmsghdr*)(buf.ptr + off);
        g.cmd         = cmd;
        g.gen_version = 1;
        g.reserved    = 0;
        off += genlmsghdr.sizeof;
    }

    private void* put_hdr(ushort type, size_t payload_len)
    {
        nlattr* a = cast(nlattr*)(buf.ptr + off);
        a.nla_len  = cast(ushort)(nlattr.sizeof + payload_len);
        a.nla_type = type;
        off += nlattr.sizeof;
        void* p = buf.ptr + off;
        off += (payload_len + 3) & ~3UL;
        return p;
    }

    void put_u32(ushort type, uint v)   { *cast(uint*)put_hdr(type, 4) = v; }
    void put_u16(ushort type, ushort v) { *cast(ushort*)put_hdr(type, 2) = v; }
    void put_u8(ushort type, ubyte v)   { *cast(ubyte*)put_hdr(type, 1) = v; }
    void put_flag(ushort type)          { put_hdr(type, 0); }

    void put_bytes(ushort type, const(ubyte)[] d)
    {
        ubyte* p = cast(ubyte*)put_hdr(type, d.length);
        p[0 .. d.length] = d[];
    }

    // Begin a nested attribute; returns the offset to close with nest_end().
    size_t nest_start(ushort type)
    {
        nlattr* a = cast(nlattr*)(buf.ptr + off);
        a.nla_type = cast(ushort)(type | 0x8000);   // NLA_F_NESTED
        size_t at = off;
        off += nlattr.sizeof;
        return at;
    }

    void nest_end(size_t at)
    {
        nlattr* a = cast(nlattr*)(buf.ptr + at);
        a.nla_len = cast(ushort)(off - at);
    }

    const(void)[] finish()
    {
        (cast(nlmsghdr*)buf.ptr).nlmsg_len = cast(uint)off;
        return buf[0 .. off];
    }
}

void foreach_attr(const(ubyte)[] attrs, scope void delegate(ushort type, const(ubyte)[] payload) nothrow @nogc fn)
{
    while (attrs.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)attrs.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > attrs.length)
            break;
        fn(a.nla_type & NLA_TYPE_MASK, attrs[nlattr.sizeof .. len]);
        uint aligned = (len + 3) & ~3u;
        if (aligned >= attrs.length)
            break;
        attrs = attrs[aligned .. $];
    }
}

const(ubyte)[] find_attr(const(ubyte)[] attrs, ushort want)
{
    while (attrs.length >= nlattr.sizeof)
    {
        const nlattr* a = cast(const nlattr*)attrs.ptr;
        ushort len = a.nla_len;
        if (len < nlattr.sizeof || len > attrs.length)
            break;
        if ((a.nla_type & NLA_TYPE_MASK) == want)
            return attrs[nlattr.sizeof .. len];
        uint aligned = (len + 3) & ~3u;
        if (aligned >= attrs.length)
            break;
        attrs = attrs[aligned .. $];
    }
    return null;
}

const(char)[] trim_nul(const(char)[] s) pure
{
    size_t n = s.length;
    while (n > 0 && s[n - 1] == '\0')
        --n;
    return s[0 .. n];
}

// Open a generic-netlink socket. nonblock=true for an async event socket;
// otherwise a 500ms recv timeout backstops synchronous command/reply use.
int nl_open_socket(bool nonblock)
{
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    if (fd < 0)
        return -1;
    sockaddr_nl a;
    a.nl_family = AF_NETLINK;
    if (bind(fd, &a, sockaddr_nl.sizeof) < 0)
    {
        urt.internal.sys.posix.close(fd);
        return -1;
    }
    if (nonblock)
    {
        int fl = fcntl(fd, F_GETFL, 0);
        if (fl >= 0)
            fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }
    else
    {
        timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 500_000;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, timeval.sizeof);
    }
    return fd;
}

// Resolve the nl80211 family id and the "scan"/"mlme" multicast group ids.
bool resolve_nl80211(int fd, out ushort family_id, out uint scan_grp, out uint mlme_grp)
{
    NlBuilder b;
    b.start(GENL_ID_CTRL, NLM_F_REQUEST, ++g_seq, CTRL_CMD_GETFAMILY);
    b.put_bytes(CTRL_ATTR_FAMILY_NAME, cast(const(ubyte)[])"nl80211\0");

    ubyte[8192] reply = void;
    size_t n;
    if (!nl_request(fd, b, reply[], n))
        return false;

    const nlmsghdr* mh = cast(const nlmsghdr*)reply.ptr;
    if (n < nlmsghdr.sizeof + genlmsghdr.sizeof || mh.nlmsg_len > n)
        return false;
    const(ubyte)[] attrs = reply[nlmsghdr.sizeof + genlmsghdr.sizeof .. mh.nlmsg_len];

    ushort fam;
    uint scan, mlme;
    foreach_attr(attrs, (ushort type, const(ubyte)[] payload) {
        if (type == CTRL_ATTR_FAMILY_ID && payload.length >= 2)
            fam = *cast(const(ushort)*)payload.ptr;
        else if (type == CTRL_ATTR_MCAST_GROUPS)
        {
            foreach_attr(payload, (ushort, const(ubyte)[] grp) {
                const(char)[] gname;
                uint gid;
                foreach_attr(grp, (ushort gt, const(ubyte)[] gp) {
                    if (gt == CTRL_ATTR_MCAST_GRP_NAME)
                        gname = trim_nul(cast(const(char)[])gp);
                    else if (gt == CTRL_ATTR_MCAST_GRP_ID && gp.length >= 4)
                        gid = *cast(const(uint)*)gp.ptr;
                });
                if (gname == "scan")
                    scan = gid;
                else if (gname == "mlme")
                    mlme = gid;
            });
        }
    });

    family_id = fam;
    scan_grp = scan;
    mlme_grp = mlme;
    return fam != 0;
}

// Send a request expecting an ACK (NLMSG_ERROR with code 0). Returns false and
// logs on a non-zero error. `what` labels the op in the log.
// `quiet` suppresses the warning for best-effort ops that legitimately fail on
// some drivers (e.g. PORT_AUTHORIZED is EOPNOTSUPP on brcmfmac).
bool nl_ack(int fd, ref NlBuilder b, const(char)[] what, bool quiet = false)
{
    const(void)[] msg = b.finish();
    sockaddr_nl k;
    k.nl_family = AF_NETLINK;
    if (sendto(fd, msg.ptr, msg.length, 0, &k, sockaddr_nl.sizeof) != cast(ptrdiff_t)msg.length)
    {
        if (!quiet) log_warning("os.nl80211", what, " sendto failed: errno=", last_errno());
        return false;
    }
    ubyte[1024] rbuf = void;
    ptrdiff_t n = recv(fd, rbuf.ptr, rbuf.length, 0);
    if (n < cast(ptrdiff_t)nlmsghdr.sizeof)
    {
        if (!quiet) log_warning("os.nl80211", what, " no ack: errno=", last_errno());
        return false;
    }
    const nlmsghdr* h = cast(const nlmsghdr*)rbuf.ptr;
    if (h.nlmsg_type == NLMSG_ERROR)
    {
        int err = n >= cast(ptrdiff_t)(nlmsghdr.sizeof + int.sizeof) ? *cast(const(int)*)(rbuf.ptr + nlmsghdr.sizeof) : -1;
        if (err == 0)
            return true;
        if (!quiet) log_warning("os.nl80211", what, " rejected: err=", err);
        return false;
    }
    return true;
}

void nl_close(ref int fd)
{
    if (fd >= 0)
    {
        urt.internal.sys.posix.close(fd);
        fd = -1;
    }
}

// Send a request and return its single reply message (not for multipart dumps).
bool nl_request(int fd, ref NlBuilder b, ubyte[] out_buf, out size_t out_n)
{
    const(void)[] msg = b.finish();
    sockaddr_nl k;
    k.nl_family = AF_NETLINK;
    if (sendto(fd, msg.ptr, msg.length, 0, &k, sockaddr_nl.sizeof) != cast(ptrdiff_t)msg.length)
        return false;
    ptrdiff_t n = recv(fd, out_buf.ptr, out_buf.length, 0);
    if (n < cast(ptrdiff_t)nlmsghdr.sizeof)
        return false;
    const nlmsghdr* h = cast(const nlmsghdr*)out_buf.ptr;
    if (h.nlmsg_type == NLMSG_ERROR)
        return false;
    out_n = cast(size_t)n;
    return true;
}
