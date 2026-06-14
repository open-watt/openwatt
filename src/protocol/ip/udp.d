module protocol.ip.udp;

version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.mem.allocator : defaultAllocator;
import urt.time;

import router.iface;
import router.iface.packet;

import protocol.ip : IPv4Header, IPProtocol;
import protocol.ip.icmp;
import protocol.ip.stack;

nothrow @nogc:


struct UdpHeader
{
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

    version (UseInternalIPStack)
    {
        import protocol.ip : UDPEndpoint;
        UDPEndpoint* owner;
    }

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
    size_t ip_total = ip.total_length.bigEndianToNative!ushort;
    if (ip_total < ip_hdr_len + UdpHeader.sizeof || ip_total > pkt.data.length)
        return;

    const(ubyte)[] payload = (cast(const(ubyte)*)pkt.data.ptr)[ip_hdr_len .. ip_total];
    const u = cast(const UdpHeader*)payload.ptr;

    ushort udp_len = u.length.bigEndianToNative!ushort;
    if (udp_len < UdpHeader.sizeof || udp_len > payload.length)
        return;

    // Verify checksum if present (zero means sender opted out).
    ushort wire_csum = u.checksum.bigEndianToNative!ushort;
    if (wire_csum != 0)
    {
        ushort pseudo = pseudo_header_checksum(IPAddr(ip.src), IPAddr(ip.dst), IPProtocol.udp, udp_len);
        ushort calc = internet_checksum(payload[0 .. udp_len], pseudo);
        if (calc != 0)
            return;     // bad checksum
    }

    ushort dst_port = u.dst_port.bigEndianToNative!ushort;
    ushort src_port = u.src_port.bigEndianToNative!ushort;

    foreach (pcb; _pcbs[])
    {
        if (pcb.local_port != dst_port)
            continue;
        if (pcb.local_addr != IPAddr.any && pcb.local_addr != ip.dst)
            continue;
        if (pcb.connected)
        {
            if (pcb.remote_addr != IPAddr(ip.src) || pcb.remote_port != src_port)
                continue;
        }

        const(ubyte)[] body_ = payload[UdpHeader.sizeof .. udp_len];

        version (UseInternalIPStack)
        {
            if (pcb.owner)
            {
                pcb.owner.deliver(IPAddr(ip.src), src_port, body_, pkt.creation_time);
                return;
            }
        }

        if (pcb.recv_queue.length >= UdpPcb.max_queued)
            return;     // queue full, drop newest

        UdpDatagram dgm;
        dgm.src_addr = IPAddr(ip.src);
        dgm.src_port = src_port;
        if (body_.length > 0)
        {
            dgm.data = cast(ubyte[])defaultAllocator().alloc(body_.length);
            dgm.data[] = body_[];
        }
        pcb.recv_queue ~= dgm;
        return;
    }

    icmp_send_error(stack, IcmpType.dest_unreachable, IcmpDestUnreachableCode.port, pkt);
}


// Build and emit a UDP datagram with IP header.
// Caller supplies destination, source (typically 0.0.0.0 -> stack picks egress IP),
// and the payload bytes. Returns true on success; false if no route, no source, etc.
bool udp_output(ref IPStack stack, IPAddr src_addr, ushort src_port, IPAddr dst_addr, ushort dst_port, const(ubyte)[] payload)
{
    enum size_t max_size = 1500;
    size_t total = IPv4Header.sizeof + UdpHeader.sizeof + payload.length;
    if (total > max_size)
        return false;

    ubyte[max_size] buf = void;

    auto ip = cast(IPv4Header*)buf.ptr;
    ip.ver_ihl  = 0x45;
    ip.tos      = 0;
    ip.total_length = nativeToBigEndian(cast(ushort)total);
    ushort ip_id = next_ip_id();
    ip.ident = nativeToBigEndian(ip_id);
    ip.flags_frag[0] = 0;
    ip.flags_frag[1] = 0;
    ip.ttl      = 64;
    ip.protocol = IPProtocol.udp;
    ip.checksum[] = 0;
    ip.src      = src_addr.b;
    ip.dst      = dst_addr.b;
    ushort ihc = internet_checksum(buf[0 .. IPv4Header.sizeof]);
    ip.checksum = nativeToBigEndian(ihc);

    auto u = cast(UdpHeader*)(buf.ptr + IPv4Header.sizeof);
    u.src_port = nativeToBigEndian(src_port);
    u.dst_port = nativeToBigEndian(dst_port);
    ushort udp_len = cast(ushort)(UdpHeader.sizeof + payload.length);
    u.length = nativeToBigEndian(udp_len);
    u.checksum[] = 0;

    if (payload.length > 0)
        buf[IPv4Header.sizeof + UdpHeader.sizeof .. total] = payload[];

    ushort pseudo = pseudo_header_checksum(src_addr, dst_addr, IPProtocol.udp, udp_len);
    ushort cc = internet_checksum(buf[IPv4Header.sizeof .. total], pseudo);
    if (cc == 0)
        cc = 0xFFFF;    // RFC 768: zero means "no checksum"; use all-ones to mean "checksum is zero"
    u.checksum[0..2] = cc.nativeToBigEndian;

    Packet pkt;
    pkt.init!RawFrame(buf[0 .. total]);
    stack.output_v4(pkt);
    return true;
}


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

ushort pseudo_header_checksum(IPAddr src, IPAddr dst, ubyte protocol, ushort transport_length) pure
{
    ubyte[12] ph = void;
    ph[0..4]   = src.b;
    ph[4..8]   = dst.b;
    ph[8]      = 0;
    ph[9]      = protocol;
    ph[10..12] = transport_length.nativeToBigEndian;
    return internet_checksum(ph[]);
}
