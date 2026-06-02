/**
 * @file protocol.ip.tcp.ip
 * Adapter between lwIP TCP's `ip_addr_t` / `netif` / `ip_*` helpers and the
 * project's IPStack + BaseInterface + urt.inet address types.
 *
 * Type substitutions:
 *   - ip4_addr_t = urt.inet.IPAddr
 *   - ip6_addr_t = urt.inet.IPv6Addr
 *   - ip_addr_t  = struct { u_addr { IPAddr ip4; IPv6Addr ip6; } type } -- the
 *                  lwIP shape, reusing our address types as the union arms.
 *                  Always the dual-stack form regardless of LWIP_IPV6 (~16
 *                  bytes per PCB cost; keeps layout stable across builds).
 *   - netif      = router.iface.BaseInterface (class reference)
 *
 * The lwIP TCP code does not take an IPStack* parameter; we dispatch through
 * `g_stack`, set by tcp_attach_stack() during IP-stack init.
 */
module protocol.ip.tcp.ip;

version (UseInternalIPStack):

import urt.inet : IPAddr, IPv6Addr;

import router.iface : BaseInterface;

import manager.collection : Collection;

import protocol.ip.address : IPAddress;
import protocol.ip.tcp : err_t, ERR_OK, ERR_RTE, ERR_BUF;
import protocol.ip.tcp.opt : IPADDR_TYPE_V4, IPADDR_TYPE_V6, IPADDR_TYPE_ANY;
import protocol.ip.tcp.pbuf : pbuf, pbuf_copy_partial;
import protocol.ip.stack : IPStack, IPv4Header, IpProtocol, next_ip_id, RouteResult;

import urt.hash : internet_checksum;

nothrow @nogc:


/* -- Address types ---------------------------------------------------------- */

alias ip4_addr_t = IPAddr;
alias ip6_addr_t = IPv6Addr;

/* Mirrors lwIP's dual-stack ip_addr_t layout exactly. We keep this shape even
   in v4-only builds so PCB layout doesn't change with feature flags. */
struct ip_addr_t
{
nothrow @nogc:
    union u_addr_t {
        ip4_addr_t ip4;
        ip6_addr_t ip6;
    }
    u_addr_t u_addr;
    ubyte type;     /* IPADDR_TYPE_V4 / V6 / ANY */
}

ip4_addr_t* ip_2_ip4(ip_addr_t* a) pure => &a.u_addr.ip4;
const(ip4_addr_t)* ip_2_ip4(const(ip_addr_t)* a) pure => &a.u_addr.ip4;
ip6_addr_t* ip_2_ip6(ip_addr_t* a) pure => &a.u_addr.ip6;
const(ip6_addr_t)* ip_2_ip6(const(ip_addr_t)* a) pure => &a.u_addr.ip6;


/* -- Stack hookup ----------------------------------------------------------- */

__gshared IPStack* g_stack;

void tcp_attach_stack(IPStack* stack) { g_stack = stack; }


/* -- "current packet" globals (set by the IP layer pre-tcp_input) ----------- */

struct ip_data_t
{
    netif current_input_netif;
    ip_addr_t current_src;
    ip_addr_t current_dst;
}
__gshared ip_data_t ip_data;

const(ip_addr_t)* ip_current_src_addr()  => &ip_data.current_src;
const(ip_addr_t)* ip_current_dest_addr() => &ip_data.current_dst;
netif              ip_current_netif()    => ip_data.current_input_netif;
bool               ip_current_is_v6()    => ip_data.current_src.type == IPADDR_TYPE_V6;


/* -- netif handle ----------------------------------------------------------- */

alias netif = BaseInterface;

/* VLAN PCP / MAC-filter hint. The router fabric carries VLAN PCP via
   PriorityPacketQueue; this slot is a per-PCB placeholder for the day we wire
   it through. */
struct netif_hint { ushort tci; }


/* -- Constants -------------------------------------------------------------- */

enum NETIF_NO_INDEX                = 0;
enum IP_PROTO_TCP                  = 6;
enum IP_HLEN                       = 20;
enum IP6_HLEN                      = 40;
enum TCP_TTL                       = 255;
enum LWIP_TCP_RTO_TIME             = 3000;     /* ms */
enum TCP_RCV_SCALE                 = 0;
enum NETIF_CHECKSUM_GEN_TCP        = 0x0040;
enum NETIF_CHECKSUM_CHECK_TCP      = 0x0080;
enum SOF_REUSEADDR                 = 0x04;
enum SOF_KEEPALIVE                 = 0x08;
enum SOF_INHERITED                 = SOF_KEEPALIVE;

__gshared const(ip_addr_t)* IP4_ADDR_ANY = &_ip4_any;
private __gshared ip_addr_t _ip4_any = ip_addr_t(ip_addr_t.u_addr_t(IPAddr.any), IPADDR_TYPE_V4);


/* -- Address helpers -------------------------------------------------------- */

bool ip_addr_isany(const(ip_addr_t)* addr)
{
    if (addr is null)
        return true;
    if (addr.type == IPADDR_TYPE_V4)
        return addr.u_addr.ip4.address == 0;
    if (addr.type == IPADDR_TYPE_V6)
        return !cast(bool)addr.u_addr.ip6;
    return true;   /* ANY */
}

bool ip_addr_isbroadcast(const(ip_addr_t)* addr, const(netif) nif)
{
    if (addr is null || addr.type != IPADDR_TYPE_V4)
        return false;
    return addr.u_addr.ip4.address == 0xFFFFFFFF;
    /* TODO: check directed broadcast for nif's subnet. */
}

bool ip_addr_ismulticast(const(ip_addr_t)* addr)
{
    if (addr is null)
        return false;
    if (addr.type == IPADDR_TYPE_V4)
        return addr.u_addr.ip4.is_multicast;
    if (addr.type == IPADDR_TYPE_V6)
        return addr.u_addr.ip6.is_multicast;
    return false;
}

bool ip_addr_eq(const(ip_addr_t)* a, const(ip_addr_t)* b)
{
    if (a is b)
        return true;
    if (a is null || b is null || a.type != b.type)
        return false;
    if (a.type == IPADDR_TYPE_V4)
        return a.u_addr.ip4 == b.u_addr.ip4;
    if (a.type == IPADDR_TYPE_V6)
        return a.u_addr.ip6 == b.u_addr.ip6;
    return true;
}

void ip_addr_copy(ref ip_addr_t dst, const ref ip_addr_t src) { dst = src; }
void ip_addr_set(ip_addr_t* dst, const(ip_addr_t)* src)
{
    if (dst is null) return;
    *dst = src ? *src : ip_addr_t(ip_addr_t.u_addr_t.init, IPADDR_TYPE_ANY);
}

bool IP_IS_V6(const(ip_addr_t)* addr) => addr !is null && addr.type == IPADDR_TYPE_V6;
bool IP_IS_V6_VAL(const ref ip_addr_t addr) => addr.type == IPADDR_TYPE_V6;
bool IP_IS_V4_VAL(const ref ip_addr_t addr) => addr.type == IPADDR_TYPE_V4;
bool IP_IS_ANY_TYPE_VAL(const ref ip_addr_t addr) => addr.type == IPADDR_TYPE_ANY;
void IP_SET_TYPE_VAL(ref ip_addr_t addr, ubyte type) { addr.type = type; }
ubyte IP_GET_TYPE(const(ip_addr_t)* addr) => addr is null ? IPADDR_TYPE_ANY : addr.type;

/* Always true in single-stack; in dual-stack it discriminates v4 PCBs from
   v6 PCBs at bind/connect time. For now we accept everything; once v6 ships
   we'll compare pcb.local_ip.type against addr.type. */
template IP_ADDR_PCB_VERSION_MATCH_EXACT(T)
{
    bool IP_ADDR_PCB_VERSION_MATCH_EXACT(const(T)* pcb, const(ip_addr_t)* addr) => true;
}


/* -- Routing / egress ------------------------------------------------------- */

netif ip_route(const(ip_addr_t)* src, const(ip_addr_t)* dst)
{
    if (g_stack is null || dst is null)
        return null;
    version (LWIP_IPV6) {
        if (dst.type == IPADDR_TYPE_V6)
        {
            /* TODO: g_stack.route_lookup_v6_dst(dst.u_addr.ip6); */
            return null;
        }
    }
    RouteResult r = g_stack.route_lookup_v4_dst(dst.u_addr.ip4);
    if (r.kind == RouteResult.Kind.local || r.kind == RouteResult.Kind.forward)
        return r.out_iface;
    return null;
}

/* Return the first IP address bound to `nif`. lwIP passes `dst` for v4/v6
   family selection; we only have v4 today so dst is unused. Result lives in
   a per-call __gshared slot — caller copies it into pcb.local_ip immediately,
   single-threaded so the next call overwriting is safe. */
const(ip_addr_t)* ip_netif_get_local_ip(netif nif, const(ip_addr_t)* dst)
{
    if (nif is null)
        return null;
    foreach (a; Collection!IPAddress().values)
    {
        if (a.iface is nif)
        {
            __gshared ip_addr_t slot;
            slot.u_addr.ip4 = a.address.addr;
            slot.type = IPADDR_TYPE_V4;
            return &slot;
        }
    }
    return null;
}


/* Emit a TCP segment carried in pbuf chain `p` out interface `nif` to
   destination `dst` with source `src`. Assembles the IPv4 header, linearises
   the chain into a single buffer, hands off to the IP stack's routed-output
   path. */
err_t ip_output_if(pbuf* p,
                   const(ip_addr_t)* src, const(ip_addr_t)* dst,
                   ubyte ttl, ubyte tos, ubyte proto, netif nif)
{
    import router.iface.packet : Packet, RawFrame;

    if (g_stack is null || p is null || src is null || dst is null || nif is null)
        return ERR_RTE;

    version (LWIP_IPV6) {
        if (dst.type == IPADDR_TYPE_V6)
        {
            /* TODO: build v6 header, call g_stack.output_v6_routed. */
            return ERR_RTE;
        }
    }

    size_t total = IPv4Header.sizeof + p.tot_len;

    enum size_t max_size = 1600;
    if (total > max_size)
        return ERR_BUF;     /* TODO: fragmentation */

    ubyte[max_size] buf = void;

    auto ip = cast(IPv4Header*)buf.ptr;
    ip.ver_ihl  = 0x45;
    ip.tos      = tos;
    ip.total_length[0] = cast(ubyte)(total >> 8);
    ip.total_length[1] = cast(ubyte)total;
    ushort ip_id = next_ip_id();
    ip.ident[0] = cast(ubyte)(ip_id >> 8);
    ip.ident[1] = cast(ubyte)ip_id;
    ip.flags_frag[0] = 0;
    ip.flags_frag[1] = 0;
    ip.ttl      = ttl;
    ip.protocol = proto;
    ip.checksum[0] = 0;
    ip.checksum[1] = 0;
    ip.src = src.u_addr.ip4;
    ip.dst = dst.u_addr.ip4;
    ushort ihc = internet_checksum(buf[0 .. IPv4Header.sizeof]);
    ip.checksum[0] = cast(ubyte)(ihc >> 8);
    ip.checksum[1] = cast(ubyte)ihc;

    pbuf_copy_partial(p, buf.ptr + IPv4Header.sizeof, p.tot_len, 0);

    /* For cross-subnet destinations the L2 next-hop is the gateway, not `dst`.
       lwIP's ip_route API returns only the egress iface so we re-resolve here
       to recover the next-hop. */
    IPAddr next_hop = dst.u_addr.ip4;
    RouteResult rr = g_stack.route_lookup_v4_dst(dst.u_addr.ip4);
    if (rr.kind == RouteResult.Kind.forward && rr.next_hop != IPAddr.any)
        next_hop = rr.next_hop;

    Packet pkt;
    pkt.init!RawFrame(buf[0 .. total]);
    g_stack.output_v4_routed(pkt, nif, next_hop);
    return ERR_OK;
}


/* -- Socket options (PCBs carry a so_options bitfield) ---------------------- */

bool ip_get_option(T)(const(T)* pcb, ubyte opt) => (pcb.so_options & opt) != 0;


/* -- Netif registry --------------------------------------------------------- */

/* lwIP indexes netifs 1..N for compact storage in PCBs. BaseInterface uses
   pointer identity; we round-trip via a small registry built lazily by
   netif_get_index() and read by netif_get_by_index(). */
private __gshared netif[256] _netif_by_idx;
private __gshared ubyte _netif_count;

netif netif_get_by_index(ubyte idx)
{
    if (idx == NETIF_NO_INDEX || idx > _netif_count)
        return null;
    return _netif_by_idx[idx - 1];
}

ubyte netif_get_index(const(netif) nif)
{
    if (nif is null)
        return NETIF_NO_INDEX;
    foreach (i; 0 .. _netif_count)
        if (_netif_by_idx[i] is nif)
            return cast(ubyte)(i + 1);
    if (_netif_count == 255)
        return NETIF_NO_INDEX;
    _netif_by_idx[_netif_count] = cast(netif)nif;
    return ++_netif_count;
}


/* -- Netif hints (VLAN PCP) — no-op until PriorityPacketQueue is wired ----- */

void NETIF_SET_HINTS(netif nif, netif_hint* hints) {}
void NETIF_RESET_HINTS(netif nif) {}

void pcb_tci_init(T)(T* pcb) {}


/* -- Checksum-on-copy enable-check (per-netif) ------------------------------ */

bool IF__NETIF_CHECKSUM_ENABLED(const(netif) nif, uint type) => true;
