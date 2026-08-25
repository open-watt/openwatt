module driver.linux.raw;

version (linux):

import urt.endian;
import urt.mem.temp;
import urt.result;
import urt.string;
import urt.time;

import urt.internal.sys.posix;

nothrow @nogc:


// Linux-specific bindings. AF_PACKET / linux/if_packet.h are not in posix and
// not pulled into urt.internal.os, so we hand-roll the bits we need.

enum AF_PACKET = 17;
enum SOCK_RAW  = 3;
enum SOL_PACKET = 263;

enum PACKET_ADD_MEMBERSHIP    = 1;
enum PACKET_DROP_MEMBERSHIP   = 2;
enum PACKET_MR_PROMISC        = 1;

// sll_pkttype values (linux/if_packet.h). PACKET_OUTGOING marks frames we
// transmitted that the kernel echoes back to AF_PACKET listeners.
enum PACKET_HOST              = 0;
enum PACKET_OUTGOING          = 4;

enum SIOCGIFINDEX             = 0x8933;
enum SIOCGIFMTU               = 0x8921;
enum SIOCGIFHWADDR            = 0x8927;
enum SIOCGIFFLAGS             = 0x8913;

enum IFF_UP                   = 0x1;
enum IFF_RUNNING              = 0x40;
enum IFF_LOOPBACK             = 0x8;

enum IFNAMSIZ                 = 16;

enum ETH_P_ALL                = 0x0003;

enum SO_RCVBUF                = 8;
enum SOL_SOCKET               = 1;

enum int EAGAIN_      = 11;
enum int EWOULDBLOCK_ = 11;
enum int EINTR_       = 4;

struct sockaddr_ll
{
    ushort sll_family;
    ushort sll_protocol;    // network byte order
    int    sll_ifindex;
    ushort sll_hatype;
    ubyte  sll_pkttype;
    ubyte  sll_halen;
    ubyte[8] sll_addr;
}

struct packet_mreq
{
    int    mr_ifindex;
    ushort mr_type;
    ushort mr_alen;
    ubyte[8] mr_address;
}

struct ifreq_addr
{
    ushort family;
    ubyte[14] data;
}

struct ifreq
{
    char[IFNAMSIZ] ifr_name = 0;
    union
    {
        ifreq_addr   ifru_addr;
        short        ifru_flags;
        int          ifru_ivalue;
        ubyte[24]    ifru_raw;
    }
}

// `ioctl` request is `unsigned long`, which is 64-bit on LP64 and 32-bit on ILP32.
version (D_LP64)
    alias c_ulong = ulong;
else
    alias c_ulong = uint;

extern(C) nothrow @nogc
{
    int socket(int domain, int type, int protocol);
    int bind(int fd, const(void)* addr, uint addrlen);
    int setsockopt(int fd, int level, int optname, const(void)* optval, uint optlen);
    int ioctl(int fd, c_ulong request, ...);
    ptrdiff_t recv(int fd, void* buf, size_t len, int flags);
    ptrdiff_t recvfrom(int fd, void* buf, size_t len, int flags, void* src_addr, uint* addrlen);
    ptrdiff_t recvmsg(int fd, msghdr* msg, int flags);
    ptrdiff_t sendto(int fd, const(void)* buf, size_t len, int flags, const(void)* dest_addr, uint addrlen);
}

// AF_PACKET adapter wrapper. Mirrors driver.windows.pcap.PcapAdapter.
struct RawAdapter
{
nothrow @nogc:

    StringResult open(const(char)[] adapter_name, bool promisc = true)
    {
        ushort protocol = ETH_P_ALL;
        protocol = loadBigEndian(&protocol);
        fd = socket(AF_PACKET, SOCK_RAW, protocol);
        if (fd < 0)
            return StringResult(tconcat("socket(AF_PACKET, SOCK_RAW) failed: errno=", errno_result().system_code));

        int on = 1;
        if (setsockopt(fd, SOL_PACKET, PACKET_AUXDATA, &on, on.sizeof) < 0)
        {
            auto msg = tconcat("PACKET_AUXDATA failed: errno=", errno_result().system_code);
            close_fd();
            return StringResult(msg);
        }

        ifreq req;
        if (adapter_name.length >= IFNAMSIZ)
        {
            close_fd();
            return StringResult(tconcat("adapter name '", adapter_name, "' too long"));
        }
        req.ifr_name[0 .. adapter_name.length] = adapter_name[];
        req.ifr_name[adapter_name.length] = 0;

        if (ioctl(fd, SIOCGIFINDEX, &req) < 0)
        {
            auto msg = tconcat("SIOCGIFINDEX('", adapter_name, "') failed: errno=", errno_result().system_code);
            close_fd();
            return StringResult(msg);
        }
        ifindex = req.ifru_ivalue;

        sockaddr_ll sll;
        sll.sll_family   = AF_PACKET;
        sll.sll_protocol = protocol;
        sll.sll_ifindex  = ifindex;
        if (bind(fd, &sll, sockaddr_ll.sizeof) < 0)
        {
            auto msg = tconcat("bind(AF_PACKET, '", adapter_name, "') failed: errno=", errno_result().system_code);
            close_fd();
            return StringResult(msg);
        }

        // Promiscuous (opt-out): kernel refcounts per-socket and auto-clears on
        // close, so a crashed process can't leave the NIC stuck in promisc. The
        // CPU port of an offloaded bridge opens non-promisc and toggles on demand.
        if (promisc)
        {
            StringResult r = set_promisc(true);
            if (r.failed)
            {
                close_fd();
                return r;
            }
        }

        int flags_val = fcntl(fd, F_GETFL, 0);
        if (flags_val < 0 || fcntl(fd, F_SETFL, flags_val | O_NONBLOCK) < 0)
        {
            auto msg = tconcat("fcntl(O_NONBLOCK, '", adapter_name, "') failed: errno=", errno_result().system_code);
            close_fd();
            return StringResult(msg);
        }

        int rcvbuf = 4 * 1024 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, rcvbuf.sizeof);

        return StringResult.success;
    }

    void close()
    {
        close_fd();
    }

    // Add/drop PACKET_MR_PROMISC. Idempotent via _promisc so repeated calls
    // don't churn the kernel refcount.
    StringResult set_promisc(bool on)
    {
        if (fd < 0)
            return StringResult("set_promisc on a closed socket");
        if (on == _promisc)
            return StringResult.success;

        packet_mreq mr;
        mr.mr_ifindex = ifindex;
        mr.mr_type    = PACKET_MR_PROMISC;
        int op = on ? PACKET_ADD_MEMBERSHIP : PACKET_DROP_MEMBERSHIP;
        if (setsockopt(fd, SOL_PACKET, op, &mr, packet_mreq.sizeof) < 0)
            return StringResult(tconcat("PACKET membership (PROMISC) failed: errno=", errno_result().system_code));

        _promisc = on;
        return StringResult.success;
    }

    // returns:  1 = got a frame; data points into rx_buf, valid until next poll
    //           0 = no frame ready (EAGAIN / EWOULDBLOCK / EINTR)
    //          -1 = error -- caller can read last_recv_error.system_code for errno
    // pkttype exposes sll_pkttype so the caller can drop PACKET_OUTGOING echoes
    // of frames transmitted on the netdev (its own sendto injections included).
    int poll_ll(out const(ubyte)[] data, out uint wire_len, out MonoTime timestamp, out ubyte pkttype)
    {
        // AF_PACKET receives hardware-stripped VLAN tags only through PACKET_AUXDATA.
        sockaddr_ll sll;
        iovec iov = iovec(rx_buf.ptr + 4, rx_buf.length - 4);
        size_t[32] control = void;
        msghdr msg;
        msg.msg_name = &sll;
        msg.msg_namelen = sockaddr_ll.sizeof;
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.ptr;
        msg.msg_controllen = control.sizeof;

        ptrdiff_t n = recvmsg(fd, &msg, 0);
        if (n < 0)
        {
            Result e = errno_result();
            if (e.system_code == EAGAIN_ || e.system_code == EWOULDBLOCK_ || e.system_code == EINTR_)
                return 0;
            last_recv_error = e;
            return -1;
        }
        if (n == 0)
            return 0;

        size_t offset = 4;
        size_t len = cast(size_t)n;
        if (restore_vlan_tag(rx_buf[], len, msg))
            offset = 0;

        data = rx_buf[offset .. offset + len];
        wire_len = cast(uint)len;
        timestamp = getTime();
        pkttype = sll.sll_pkttype;
        return 1;
    }

    // Caller is responsible for tracking tx_drop counters; failures are not
    // logged here (per-packet spam). Inspect last_send_error for diagnostics.
    bool send(const(ubyte)[] frame)
    {
        sockaddr_ll sll;
        sll.sll_family  = AF_PACKET;
        sll.sll_ifindex = ifindex;
        sll.sll_halen   = 6;
        if (frame.length >= 6)
            sll.sll_addr[0 .. 6] = frame[0 .. 6];
        ptrdiff_t n = sendto(fd, frame.ptr, frame.length, 0, &sll, sockaddr_ll.sizeof);
        if (n != cast(ptrdiff_t)frame.length)
        {
            last_send_error = errno_result();
            return false;
        }
        return true;
    }

    bool read_mac(const(char)[] adapter_name, out ubyte[6] mac)
    {
        if (fd < 0 || adapter_name.length >= IFNAMSIZ)
            return false;
        ifreq req;
        req.ifr_name[0 .. adapter_name.length] = adapter_name[];
        req.ifr_name[adapter_name.length] = 0;
        if (ioctl(fd, SIOCGIFHWADDR, &req) < 0)
            return false;
        mac[] = req.ifru_addr.data[0 .. 6];
        return true;
    }

    Result last_send_error;
    Result last_recv_error;

    bool valid() const pure => fd >= 0;

    int fd = -1;
    int ifindex;

private:
    bool _promisc;
    void close_fd()
    {
        if (fd >= 0)
        {
            urt.internal.sys.posix.close(fd);
            fd = -1;
        }
    }

    // Linux delivers one frame per recv(); jumbo-sized buffer.
    ubyte[16 * 1024] rx_buf = void;
}


private:

struct iovec
{
    void*  iov_base;
    size_t iov_len;
}

struct msghdr
{
    void*   msg_name;
    uint    msg_namelen;
    version (D_LP64) uint _pad;
    iovec*  msg_iov;
    size_t  msg_iovlen;
    void*   msg_control;
    size_t  msg_controllen;
    int     msg_flags;
}

struct cmsghdr
{
    size_t cmsg_len;
    int    cmsg_level;
    int    cmsg_type;
}

// Linux 3.14 replaced padding with tp_vlan_tpid; the validity bit distinguishes older kernels.
struct tpacket_auxdata
{
    uint   tp_status;
    uint   tp_len;
    uint   tp_snaplen;
    ushort tp_mac;
    ushort tp_net;
    ushort tp_vlan_tci;
    ushort tp_vlan_tpid;
}

enum PACKET_AUXDATA = 8;
enum TP_STATUS_VLAN_VALID = 1 << 4;
enum TP_STATUS_VLAN_TPID_VALID = 1 << 6;

size_t cmsg_align(size_t len) pure
    => (len + size_t.sizeof - 1) & ~(size_t.sizeof - 1);

size_t cmsg_len(size_t len) pure
    => cmsg_align(cmsghdr.sizeof) + len;

const(tpacket_auxdata)* packet_auxdata(ref const msghdr msg)
{
    if (msg.msg_controllen < cmsghdr.sizeof)
        return null;

    const(ubyte)* end = cast(const(ubyte)*)msg.msg_control + msg.msg_controllen;
    for (const(cmsghdr)* c = cast(const(cmsghdr)*)msg.msg_control; c !is null;)
    {
        const(ubyte)* current = cast(const(ubyte)*)c;
        size_t remaining = cast(size_t)(end - current);
        if (c.cmsg_len < cmsghdr.sizeof || c.cmsg_len > remaining)
            return null;
        if (c.cmsg_level == SOL_PACKET && c.cmsg_type == PACKET_AUXDATA)
        {
            if (c.cmsg_len < cmsg_len(tpacket_auxdata.sizeof))
                return null;
            return cast(const(tpacket_auxdata)*)(current + cmsg_align(cmsghdr.sizeof));
        }

        size_t step = cmsg_align(c.cmsg_len);
        if (step > remaining || remaining - step < cmsghdr.sizeof)
            return null;
        c = cast(const(cmsghdr)*)(current + step);
    }
    return null;
}

bool restore_vlan_tag(ubyte[] buffer, ref size_t len, ref const msghdr msg)
{
    if (len < 12 || buffer.length < len + 4)
        return false;
    const(tpacket_auxdata)* aux = packet_auxdata(msg);
    if (!aux || !(aux.tp_status & TP_STATUS_VLAN_VALID))
        return false;

    ushort tpid = aux.tp_status & TP_STATUS_VLAN_TPID_VALID ? aux.tp_vlan_tpid : 0x8100;
    foreach (i; 0 .. 12)
        buffer[i] = buffer[i + 4];
    buffer[12] = cast(ubyte)(tpid >> 8);
    buffer[13] = cast(ubyte)tpid;
    buffer[14] = cast(ubyte)(aux.tp_vlan_tci >> 8);
    buffer[15] = cast(ubyte)aux.tp_vlan_tci;
    len += 4;
    return true;
}


unittest
{
    assert(tpacket_auxdata.sizeof == 20);
    assert(tpacket_auxdata.tp_vlan_tci.offsetof == 16);
    assert(tpacket_auxdata.tp_vlan_tpid.offsetof == 18);
    version (D_LP64)
        assert(msghdr.sizeof == 56);
    else
        assert(msghdr.sizeof == 28);

    size_t[8] control;
    cmsghdr* header = cast(cmsghdr*)control.ptr;
    header.cmsg_len = cmsg_len(tpacket_auxdata.sizeof);
    header.cmsg_level = SOL_PACKET;
    header.cmsg_type = PACKET_AUXDATA;
    tpacket_auxdata* aux = cast(tpacket_auxdata*)(cast(ubyte*)control.ptr + cmsg_align(cmsghdr.sizeof));
    aux.tp_status = TP_STATUS_VLAN_VALID;
    aux.tp_vlan_tci = 0xA123;
    aux.tp_vlan_tpid = 0x88A8;

    msghdr msg;
    msg.msg_control = control.ptr;
    msg.msg_controllen = header.cmsg_len;

    ubyte[14] untagged = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0x08, 0x00];
    ubyte[64] frame;
    frame[4 .. 18] = untagged[];
    size_t len = untagged.length;
    assert(restore_vlan_tag(frame[], len, msg));
    assert(len == 18);
    ubyte[6] dot1q = [0x81, 0x00, 0xA1, 0x23, 0x08, 0x00];
    assert(frame[0 .. 12] == untagged[0 .. 12]);
    assert(frame[12 .. 18] == dot1q[]);

    frame[] = 0;
    frame[4 .. 18] = untagged[];
    len = untagged.length;
    aux.tp_status |= TP_STATUS_VLAN_TPID_VALID;
    assert(restore_vlan_tag(frame[], len, msg));
    ubyte[6] dot1ad = [0x88, 0xA8, 0xA1, 0x23, 0x08, 0x00];
    assert(frame[12 .. 18] == dot1ad[]);

    frame[] = 0;
    frame[4 .. 18] = untagged[];
    len = untagged.length;
    header.cmsg_len = msg.msg_controllen + 1;
    assert(!restore_vlan_tag(frame[], len, msg));
    assert(len == untagged.length);
}
