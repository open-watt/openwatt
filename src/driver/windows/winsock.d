module driver.windows.winsock;

version (Windows):

// direct Winsock bindings for IOCP endpoints; they drive their own overlapped I/O and hand
// completions to the reactor's IO completion port (see manager.reactor) rather than going
// via urt.socket

import urt.inet;
import urt.log;

public import urt.internal.sys.windows.basetsd : HANDLE;
public import urt.internal.sys.windows.winbase : OVERLAPPED, CancelIoEx;
public import urt.internal.sys.windows.winsock2 : AF_INET, sockaddr_in;

nothrow @nogc:


alias IOCP_SOCKET = size_t;
struct WSABUF { uint len; ubyte* buf; }     // ULONG len; CHAR* buf
struct IOCP_GUID { uint Data1; ushort Data2, Data3; ubyte[8] Data4; }

extern (Windows) int WSARecv (IOCP_SOCKET, WSABUF*, uint, uint*, uint*, OVERLAPPED*, void*) nothrow @nogc;
extern (Windows) int WSASend (IOCP_SOCKET, WSABUF*, uint, uint*, uint,  OVERLAPPED*, void*) nothrow @nogc;
extern (Windows) int WSAIoctl(IOCP_SOCKET, uint, void*, uint, void*, uint, uint*, OVERLAPPED*, void*) nothrow @nogc;
extern (Windows) int WSARecvFrom(IOCP_SOCKET, WSABUF*, uint, uint*, uint*, void*, int*, OVERLAPPED*, void*) nothrow @nogc;

alias LPFN_CONNECTEX = extern(Windows) int function(IOCP_SOCKET, const(void)*, int, const(void)*, uint, uint*, OVERLAPPED*) nothrow @nogc;
alias LPFN_ACCEPTEX  = extern(Windows) int function(IOCP_SOCKET, IOCP_SOCKET, void*, uint, uint, uint, uint*, OVERLAPPED*) nothrow @nogc;

enum uint SIO_GET_EXTENSION_FUNCTION_POINTER = 0xC8000006;
enum int  SO_UPDATE_CONNECT_CONTEXT = 0x7010;
enum int  SO_UPDATE_ACCEPT_CONTEXT  = 0x700B;

__gshared immutable IOCP_GUID WSAID_CONNECTEX = IOCP_GUID(0x25a207b9, 0xddf3, 0x4660, [0x8e,0xe9,0x76,0xe5,0x8c,0x74,0x06,0x3e]);
__gshared immutable IOCP_GUID WSAID_ACCEPTEX  = IOCP_GUID(0xb5367df1, 0xcbac, 0x11cf, [0x95,0xca,0x00,0x80,0x5f,0x48,0xa1,0x92]);

enum IOCP_SOCKET INVALID_IOCP_SOCKET = ~IOCP_SOCKET(0);
enum int WSA_AF_INET = 2, WSA_SOCK_STREAM = 1, WSA_SOCK_DGRAM = 2, WSA_IPPROTO_TCP = 6, WSA_IPPROTO_UDP = 17;
enum int SOL_SOCKET_ = 0xffff, SO_REUSEADDR_ = 0x0004, SO_ERROR_ = 0x1007;

// raw winsock; pragma(mangle) keeps the common names from clashing with urt.socket's exports
enum uint WSA_FLAG_OVERLAPPED = 0x01;
pragma(mangle, "WSASocketW")  extern(Windows) IOCP_SOCKET ws_socket(int af, int type, int protocol, void* protoInfo, uint group, uint flags) nothrow @nogc;
pragma(mangle, "bind")        extern(Windows) int ws_bind(IOCP_SOCKET, const(void)*, int) nothrow @nogc;
pragma(mangle, "connect")     extern(Windows) int ws_connect(IOCP_SOCKET, const(void)*, int) nothrow @nogc;
pragma(mangle, "listen")      extern(Windows) int ws_listen(IOCP_SOCKET, int) nothrow @nogc;
pragma(mangle, "closesocket") extern(Windows) int ws_closesocket(IOCP_SOCKET) nothrow @nogc;
pragma(mangle, "shutdown")    extern(Windows) int ws_shutdown(IOCP_SOCKET, int) nothrow @nogc;
pragma(mangle, "WSAGetLastError") extern(Windows) int ws_lasterror() nothrow @nogc;
pragma(mangle, "setsockopt")  extern(Windows) int ws_setsockopt(IOCP_SOCKET, int, int, const(void)*, int) nothrow @nogc;
pragma(mangle, "getsockopt")  extern(Windows) int ws_getsockopt(IOCP_SOCKET, int, int, void*, int*) nothrow @nogc;
pragma(mangle, "htons")       extern(Windows) ushort ws_htons(ushort) nothrow @nogc;
pragma(mangle, "getpeername") extern(Windows) int ws_getpeername(IOCP_SOCKET, void*, int*) nothrow @nogc;
pragma(mangle, "sendto")      extern(Windows) int ws_sendto(IOCP_SOCKET, const(void)*, int, int, const(void)*, int) nothrow @nogc;

enum int WSA_IO_PENDING = 997;

__gshared LPFN_CONNECTEX g_connect_ex;
__gshared LPFN_ACCEPTEX  g_accept_ex;

// build a v4 sockaddr_in from an InetAddress (IOCP TCP/UDP is v4-only for now)
sockaddr_in to_sockaddr_in(ref const InetAddress a) nothrow @nogc
{
    sockaddr_in sa;
    sa.sin_family = cast(short)WSA_AF_INET;
    sa.sin_port = ws_htons(a._a.ipv4.port);
    sa.sin_addr.s_addr = a._a.ipv4.addr.address;   // octets in memory order == network order
    return sa;
}

InetAddress from_sockaddr_in(ref const sockaddr_in sa) nothrow @nogc
{
    IPAddr ip;
    ip.address = sa.sin_addr.s_addr;
    return InetAddress(ip, ws_htons(sa.sin_port));   // htons is its own inverse (16-bit swap)
}

void load_socket_extensions()
{
    if (g_connect_ex !is null && g_accept_ex !is null)
        return;
    IOCP_SOCKET s = ws_socket(WSA_AF_INET, WSA_SOCK_STREAM, WSA_IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
    if (s == INVALID_IOCP_SOCKET)
    {
        writeError("IOCPWorker: probe socket for extension fns failed");
        return;
    }
    uint bytes;
    IOCP_GUID cx = WSAID_CONNECTEX;
    WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, cast(void*)&cx, cast(uint)IOCP_GUID.sizeof, cast(void*)&g_connect_ex, cast(uint)g_connect_ex.sizeof, &bytes, null, null);
    IOCP_GUID ax = WSAID_ACCEPTEX;
    WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, cast(void*)&ax, cast(uint)IOCP_GUID.sizeof, cast(void*)&g_accept_ex, cast(uint)g_accept_ex.sizeof, &bytes, null, null);
    ws_closesocket(s);
    if (g_connect_ex is null || g_accept_ex is null)
        writeError("IOCPWorker: failed to resolve ConnectEx/AcceptEx");
}
