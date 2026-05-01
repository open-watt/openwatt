module driver.linux.raw;

version (linux):

import urt.log;
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
    ptrdiff_t sendto(int fd, const(void)* buf, size_t len, int flags, const(void)* dest_addr, uint addrlen);
    int* __errno_location();
}

private int last_errno() => *__errno_location();

private ushort htons(ushort v) pure
{
    version (LittleEndian)
        return cast(ushort)((v << 8) | (v >> 8));
    else
        return v;
}


// AF_PACKET adapter wrapper. Mirrors driver.windows.pcap.PcapAdapter.
struct RawAdapter
{
nothrow @nogc:

    bool open(const(char)[] adapter_name)
    {
        fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
        if (fd < 0)
        {
            writeError("socket(AF_PACKET, SOCK_RAW) failed: errno=", last_errno());
            return false;
        }

        ifreq req;
        if (adapter_name.length >= IFNAMSIZ)
        {
            writeError("adapter name too long: ", adapter_name);
            close_fd();
            return false;
        }
        req.ifr_name[0 .. adapter_name.length] = adapter_name[];
        req.ifr_name[adapter_name.length] = 0;

        if (ioctl(fd, SIOCGIFINDEX, &req) < 0)
        {
            writeError("SIOCGIFINDEX failed for '", adapter_name, "': errno=", last_errno());
            close_fd();
            return false;
        }
        ifindex = req.ifru_ivalue;

        sockaddr_ll sll;
        sll.sll_family   = AF_PACKET;
        sll.sll_protocol = htons(ETH_P_ALL);
        sll.sll_ifindex  = ifindex;
        if (bind(fd, &sll, sockaddr_ll.sizeof) < 0)
        {
            writeError("bind(AF_PACKET) failed for '", adapter_name, "': errno=", last_errno());
            close_fd();
            return false;
        }

        // Promiscuous: kernel refcounts per-socket and auto-clears on close,
        // so a crashed process can't leave the NIC stuck in promisc.
        packet_mreq mr;
        mr.mr_ifindex = ifindex;
        mr.mr_type    = PACKET_MR_PROMISC;
        if (setsockopt(fd, SOL_PACKET, PACKET_ADD_MEMBERSHIP, &mr, packet_mreq.sizeof) < 0)
        {
            writeError("PACKET_ADD_MEMBERSHIP(PROMISC) failed for '", adapter_name, "': errno=", last_errno());
            close_fd();
            return false;
        }

        int flags_val = fcntl(fd, F_GETFL, 0);
        if (flags_val < 0 || fcntl(fd, F_SETFL, flags_val | O_NONBLOCK) < 0)
        {
            writeError("fcntl(O_NONBLOCK) failed for '", adapter_name, "': errno=", last_errno());
            close_fd();
            return false;
        }

        int rcvbuf = 4 * 1024 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, rcvbuf.sizeof);

        return true;
    }

    void close()
    {
        close_fd();
    }

    // returns:  1 = got a frame; data points into rx_buf, valid until next poll
    //           0 = no frame ready
    //          -1 = error (already logged)
    int poll(out const(ubyte)[] data, out uint wire_len, out SysTime timestamp)
    {
        ptrdiff_t n = recv(fd, rx_buf.ptr, rx_buf.length, 0);
        if (n < 0)
        {
            int e = last_errno();
            if (e == EAGAIN_ || e == EWOULDBLOCK_ || e == EINTR_)
                return 0;
            writeError("recv(AF_PACKET) failed: errno=", e);
            return -1;
        }
        if (n == 0)
            return 0;
        data = rx_buf[0 .. cast(size_t)n];
        wire_len = cast(uint)n;
        timestamp = getSysTime();
        return 1;
    }

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
            writeError("sendto(AF_PACKET) failed: errno=", last_errno());
            return false;
        }
        return true;
    }

    bool valid() const pure => fd >= 0;

    int fd = -1;
    int ifindex;

private:
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
