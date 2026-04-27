module protocol.ip.udp;

import urt.array;
import urt.hash;
import urt.inet;
import urt.mem.allocator : defaultAllocator;

import router.iface;
import router.iface.packet;

import protocol.ip.icmp;
import protocol.ip.stack;

nothrow @nogc:


struct UdpHeader
{
align(1):
    ubyte[2] src_port;      // big-endian
    ubyte[2] dst_port;      // big-endian
    ubyte[2] length;        // big-endian; UDP header + data
    ubyte[2] checksum;      // big-endian; 0 = unchecked (v4 only)
}
static assert(UdpHeader.sizeof == 8);


// One datagram parked in a UdpPcb's recv queue.
// `data` is owned; freed on dequeue or PCB destruction.
struct UdpDatagram
{
    IPAddr src_addr;
    ushort src_port;
    ubyte[] data;
}


struct UdpPcb
{
    IPAddr  local_addr;     // 0.0.0.0 = bound to any
    ushort  local_port;     // 0 = unbound
    IPAddr  remote_addr;    // 0.0.0.0 = unconnected
    ushort  remote_port;    // 0 = unconnected
    bool    connected;

    Array!UdpDatagram recv_queue;
    enum size_t max_queued = 16;

    // Owner socket handle (filled in when wrapped by socket layer).
    int handle;
}


// Module-global PCB list. Walked on ingress for demux.
__gshared Array!(UdpPcb*) _pcbs;


void udp_register(UdpPcb* pcb)
{
    _pcbs ~= pcb;
}

void udp_unregister(UdpPcb* pcb)
{
    foreach (i, p; _pcbs[])
    {
        if (p is pcb)
        {
            _pcbs.remove(i);
            return;
        }
    }
}


// Demux a locally-delivered v4 UDP datagram to a matching PCB.
// pkt.data is the entire IP datagram.
void udp_input(ref IPStack stack, ref Packet pkt)
{
    if (pkt.data.length < IPv4Header.sizeof + UdpHeader.sizeof)
        return;

    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t ip_hdr_len = ip.ihl * 4;
    if (pkt.data.length < ip_hdr_len + UdpHeader.sizeof)
        return;

    const(ubyte)[] payload = (cast(const(ubyte)*)pkt.data.ptr)[ip_hdr_len .. pkt.data.length];
    const u = cast(const UdpHeader*)payload.ptr;

    ushort udp_len = (ushort(u.length[0]) << 8) | u.length[1];
    if (udp_len < UdpHeader.sizeof || udp_len > payload.length)
        return;

    // Verify checksum if present (zero means sender opted out).
    ushort wire_csum = (ushort(u.checksum[0]) << 8) | u.checksum[1];
    if (wire_csum != 0)
    {
        ushort calc = pseudo_header_checksum(ip.src, ip.dst, IpProtocol.udp, udp_len);
        calc = internet_checksum(payload[0 .. udp_len], cast(ushort)~calc);
        if (calc != 0)
            return;     // bad checksum
    }

    ushort dst_port = (ushort(u.dst_port[0]) << 8) | u.dst_port[1];
    ushort src_port = (ushort(u.src_port[0]) << 8) | u.src_port[1];

    foreach (pcb; _pcbs[])
    {
        if (pcb.local_port != dst_port)
            continue;
        if (pcb.local_addr != IPAddr.any && pcb.local_addr != ip.dst)
            continue;
        if (pcb.connected)
        {
            if (pcb.remote_addr != ip.src || pcb.remote_port != src_port)
                continue;
        }

        if (pcb.recv_queue.length >= UdpPcb.max_queued)
            return;     // queue full, drop newest

        const(ubyte)[] body_ = payload[UdpHeader.sizeof .. udp_len];

        UdpDatagram dgm;
        dgm.src_addr = ip.src;
        dgm.src_port = src_port;
        if (body_.length > 0)
        {
            dgm.data = cast(ubyte[])defaultAllocator().alloc(body_.length);
            dgm.data[] = body_[];
        }
        pcb.recv_queue ~= dgm;
        return;
    }

    icmp_send_error(stack, IcmpType.dest_unreachable,
                    IcmpDestUnreachableCode.port, pkt);
}


// Build and emit a UDP datagram with IP header.
// Caller supplies destination, source (typically 0.0.0.0 -> stack picks egress IP),
// and the payload bytes. Returns true on success; false if no route, no source, etc.
bool udp_output(ref IPStack stack,
                IPAddr src_addr, ushort src_port,
                IPAddr dst_addr, ushort dst_port,
                const(ubyte)[] payload)
{
    enum size_t max_size = 1500;
    size_t total = IPv4Header.sizeof + UdpHeader.sizeof + payload.length;
    if (total > max_size)
        return false;

    ubyte[max_size] buf = void;

    auto ip = cast(IPv4Header*)buf.ptr;
    ip.ver_ihl  = 0x45;
    ip.tos      = 0;
    ip.total_length[0] = cast(ubyte)(total >> 8);
    ip.total_length[1] = cast(ubyte)total;
    ip.ident[0] = 0;
    ip.ident[1] = 0;
    ip.flags_frag[0] = 0;
    ip.flags_frag[1] = 0;
    ip.ttl      = 64;
    ip.protocol = IpProtocol.udp;
    ip.checksum[] = 0;
    ip.src      = src_addr;
    ip.dst      = dst_addr;
    ushort ihc = internet_checksum(buf[0 .. IPv4Header.sizeof]);
    ip.checksum[0] = cast(ubyte)(ihc >> 8);
    ip.checksum[1] = cast(ubyte)ihc;

    auto u = cast(UdpHeader*)(buf.ptr + IPv4Header.sizeof);
    u.src_port[0] = cast(ubyte)(src_port >> 8);
    u.src_port[1] = cast(ubyte)src_port;
    u.dst_port[0] = cast(ubyte)(dst_port >> 8);
    u.dst_port[1] = cast(ubyte)dst_port;
    ushort udp_len = cast(ushort)(UdpHeader.sizeof + payload.length);
    u.length[0] = cast(ubyte)(udp_len >> 8);
    u.length[1] = cast(ubyte)udp_len;
    u.checksum[] = 0;

    if (payload.length > 0)
        buf[IPv4Header.sizeof + UdpHeader.sizeof .. total] = payload[];

    ushort pseudo = pseudo_header_checksum(src_addr, dst_addr, IpProtocol.udp, udp_len);
    ushort cc = internet_checksum(buf[IPv4Header.sizeof .. total], cast(ushort)~pseudo);
    if (cc == 0)
        cc = 0xFFFF;    // RFC 768: zero means "no checksum"; use all-ones to mean "checksum is zero"
    u.checksum[0] = cast(ubyte)(cc >> 8);
    u.checksum[1] = cast(ubyte)cc;

    Packet pkt;
    pkt.init!RawFrame(buf[0 .. total]);
    stack.output_v4(pkt);
    return true;
}


// Pop the oldest queued datagram off `pcb`. Caller takes ownership of `data`
// and must free it with `udp_free_datagram_data(d)`.
bool udp_recv(UdpPcb* pcb, out UdpDatagram d)
{
    if (pcb.recv_queue.length == 0)
        return false;
    d = pcb.recv_queue[0];
    pcb.recv_queue.remove(0);
    return true;
}

void udp_free_datagram_data(ref UdpDatagram d)
{
    if (d.data.length > 0)
    {
        defaultAllocator().free(cast(void[])d.data);
        d.data = null;
    }
}


private:

// IPv4 pseudo-header checksum: sum of src_addr, dst_addr, zero+protocol, transport_length.
// Returned as the *one's-complement final* value; pass through `~` (cast(ushort)~x) to
// re-use as `initial` for `internet_checksum` over the transport segment.
ushort pseudo_header_checksum(IPAddr src, IPAddr dst, ubyte protocol, ushort transport_length) pure
{
    ubyte[12] ph = void;
    ph[0..4]  = src.b[];
    ph[4..8]  = dst.b[];
    ph[8]     = 0;
    ph[9]     = protocol;
    ph[10]    = cast(ubyte)(transport_length >> 8);
    ph[11]    = cast(ubyte)transport_length;
    return internet_checksum(ph[]);
}
