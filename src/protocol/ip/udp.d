module protocol.ip.udp;

version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.mem;
import urt.time;

import manager.base : ObjectRef;
import manager.features : has_ipv6;

import router.iface;
import router.iface.endpoint : UdpHeader;
import router.iface.packet;

import protocol.ip : IPv4Header, IPProtocol;
import protocol.ip.address;
import protocol.ip.icmp;
import protocol.ip.stack;

static if (has_ipv6)
{
    import protocol.ip : IPv6Header, pseudo_header_checksum_v6;
    import protocol.ip.icmp6;
}

nothrow @nogc:


// One datagram waiting in a UdpPcb's receive queue.
// `data` is owned; freed on dequeue or PCB destruction.
struct UdpDatagram
{
    InetAddress src;
    ubyte[] data;
}

static if (has_ipv6)
struct UdpGroup6
{
    IPv6Addr group;
    ObjectRef!BaseInterface iface;
}


struct UdpPcb
{
    AddressFamily family;
    IPAddr  local_addr;     // 0.0.0.0 = bound to any
    ushort  local_port;     // 0 = unbound
    IPAddr  remote_addr;    // 0.0.0.0 = unconnected
    ushort  remote_port;    // 0 = unconnected
    IPAddr  multicast_group;
    IPAddr  outbound_interface;
    bool    connected;

    Array!UdpDatagram recv_queue;
    Array!IPAddr multicast_interfaces;
    enum size_t max_queued = 16;

    static if (has_ipv6)
    {
        IPv6Addr local_addr6;
        IPv6Addr remote_addr6;
        ObjectRef!BaseInterface outbound_iface6;
        Array!UdpGroup6 groups6;
    }

    version (UseInternalIPStack)
    {
        import protocol.ip : IPUDPState;
        IPUDPState* owner;
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

bool udp_bind_available(UdpPcb* self, IPAddr address, ushort port)
{
    foreach (pcb; _pcbs[])
    {
        if (pcb is self || pcb.family != AddressFamily.ipv4 || pcb.local_port != port)
            continue;
        if (udp_bindings_overlap(pcb.local_addr, address))
            return false;
    }
    return true;
}

bool udp_bindings_overlap(IPAddr a, IPAddr b) pure
    => a == IPAddr.any || b == IPAddr.any || a == b;

static if (has_ipv6)
{
    bool udp_bind_available(UdpPcb* self, IPv6Addr address, ushort port)
    {
        foreach (pcb; _pcbs[])
        {
            if (pcb is self || pcb.family != AddressFamily.ipv6 || pcb.local_port != port)
                continue;
            if (udp_bindings_overlap(pcb.local_addr6, address))
                return false;
        }
        return true;
    }

    bool udp_bindings_overlap(IPv6Addr a, IPv6Addr b) pure
        => a == IPv6Addr.any || b == IPv6Addr.any || a == b;

    bool udp_joined(UdpPcb* pcb, IPv6Addr group, BaseInterface iface)
    {
        foreach (ref membership; pcb.groups6[])
            if (membership.group == group && membership.iface.get is iface)
                return true;
        return false;
    }
}


// Demux a locally-delivered v4 UDP datagram to a matching PCB.
// pkt.data is the entire IP datagram.
void udp_input(ref IPStack stack, ref Packet pkt, BaseInterface iface, bool group_destination)
{
    if (pkt.data.length < IPv4Header.sizeof + UdpHeader.sizeof)
        return;

    const ip = cast(const IPv4Header*)pkt.data.ptr;
    size_t ip_hdr_len = ip.ihl * 4;
    size_t ip_total = loadBigEndian(cast(const(ushort)*)&ip.total_length);
    if (ip_total < ip_hdr_len + UdpHeader.sizeof || ip_total > pkt.data.length)
        return;

    const(ubyte)[] payload = (cast(const(ubyte)*)pkt.data.ptr)[ip_hdr_len .. ip_total];
    const u = cast(const UdpHeader*)payload.ptr;

    ushort udp_len = loadBigEndian(&u.length);
    if (udp_len < UdpHeader.sizeof || udp_len > payload.length)
        return;

    // Verify checksum if present (zero means sender opted out).
    ushort wire_csum = loadBigEndian(&u.checksum);
    if (wire_csum != 0)
    {
        ushort pseudo = pseudo_header_checksum(IPAddr(ip.src), IPAddr(ip.dst), IPProtocol.udp, udp_len);
        ushort calc = internet_checksum(payload[0 .. udp_len], pseudo);
        if (calc != 0)
            return;     // bad checksum
    }

    ushort dst_port = loadBigEndian(&u.dst_port);
    ushort src_port = loadBigEndian(&u.src_port);
    IPAddr dst = IPAddr(ip.dst);
    bool multicast = dst.is_multicast;
    bool broadcast = is_broadcast_for_interface(iface, dst);
    bool delivered;

    foreach (pcb; _pcbs[])
    {
        if (pcb.family != AddressFamily.ipv4 || pcb.local_port != dst_port)
            continue;
        if (multicast)
        {
            if (pcb.multicast_group != dst)
                continue;
            bool joined;
            foreach (local; pcb.multicast_interfaces[])
            {
                if (interface_has_address(iface, local))
                {
                    joined = true;
                    break;
                }
            }
            if (!joined)
                continue;
        }
        else if (broadcast)
        {
            if (pcb.local_addr != IPAddr.any || pcb.connected)
                continue;
        }
        else if (pcb.local_addr != IPAddr.any && pcb.local_addr != dst)
            continue;
        if (pcb.connected)
        {
            if (pcb.remote_addr != IPAddr(ip.src) || pcb.remote_port != src_port)
                continue;
        }

        InetAddress src = InetAddress(IPAddr(ip.src), src_port);
        InetAddress dst_address = InetAddress(dst, dst_port);
        if (!deliver_to_pcb(pcb, src, dst_address, iface, payload[UdpHeader.sizeof .. udp_len], pkt.creation_time))
            continue;
        delivered = true;
        if (!multicast && !broadcast)
            return;
    }

    if (!delivered && !group_destination)
        icmp_send_error(stack, IcmpType.dest_unreachable, IcmpDestUnreachableCode.port, pkt);
}

static if (has_ipv6)
{
    // Demux a locally-delivered v6 UDP datagram; l4_offset is past any extension headers.
    void udp_input6(ref IPStack stack, ref Packet pkt, size_t l4_offset, BaseInterface iface)
    {
        const(ubyte)[] datagram = cast(const(ubyte)[])pkt.data;
        ushort src_port, dst_port;
        const(ubyte)[] body_;
        if (!parse_udp6(datagram, l4_offset, src_port, dst_port, body_))
            return;

        const ip = cast(const IPv6Header*)datagram.ptr;
        IPv6Addr src_addr = ip.src_addr;
        IPv6Addr dst_addr = ip.dst_addr;
        bool multicast = dst_addr.is_multicast;
        bool delivered;

        foreach (pcb; _pcbs[])
        {
            if (pcb.family != AddressFamily.ipv6 || pcb.local_port != dst_port)
                continue;
            if (multicast)
            {
                if (!udp_joined(pcb, dst_addr, iface))
                    continue;
            }
            else if (pcb.local_addr6 != IPv6Addr.any && pcb.local_addr6 != dst_addr)
                continue;
            if (pcb.connected && (pcb.remote_addr6 != src_addr || pcb.remote_port != src_port))
                continue;

            InetAddress src = InetAddress(src_addr, src_port);
            InetAddress dst = InetAddress(dst_addr, dst_port);
            if (!deliver_to_pcb(pcb, src, dst, iface, body_, pkt.creation_time))
                continue;
            delivered = true;
            if (!multicast)
                return;
        }

        if (!delivered && !multicast)
            icmp6_send_error(stack, Icmp6Type.dest_unreachable, Icmp6DestUnreachableCode.port, pkt, iface);
    }
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
    if (src_addr == IPAddr.any)
    {
        IPAddr selected = stack.select_source_v4(dst_addr);
        if (selected != IPAddr.any)
            src_addr = selected;
    }

    align(size_t.sizeof) ubyte[max_size] buf = void;

    auto ip = cast(IPv4Header*)buf.ptr;
    ip.ver_ihl  = 0x45;
    ip.tos      = 0;
    storeBigEndian(cast(ushort*)&ip.total_length, cast(ushort)total);
    ushort ip_id = next_ip_id();
    storeBigEndian(cast(ushort*)&ip.ident, ip_id);
    storeBigEndian(cast(ushort*)&ip.flags_frag, ushort(0));
    ip.ttl      = 64;
    ip.protocol = IPProtocol.udp;
    storeBigEndian(cast(ushort*)&ip.checksum, ushort(0));
    ip.src      = src_addr.b;
    ip.dst      = dst_addr.b;
    ushort ihc = internet_checksum(buf[0 .. IPv4Header.sizeof]);
    storeBigEndian(cast(ushort*)&ip.checksum, ihc);

    auto u = cast(UdpHeader*)(buf.ptr + IPv4Header.sizeof);
    storeBigEndian(&u.src_port, src_port);
    storeBigEndian(&u.dst_port, dst_port);
    ushort udp_len = cast(ushort)(UdpHeader.sizeof + payload.length);
    storeBigEndian(&u.length, udp_len);
    storeBigEndian(&u.checksum, ushort(0));

    if (payload.length > 0)
        buf[IPv4Header.sizeof + UdpHeader.sizeof .. total] = payload[];

    ushort pseudo = pseudo_header_checksum(src_addr, dst_addr, IPProtocol.udp, udp_len);
    ushort cc = internet_checksum(buf[IPv4Header.sizeof .. total], pseudo);
    if (cc == 0)
        cc = 0xFFFF;    // RFC 768: zero means "no checksum"; use all-ones to mean "checksum is zero"
    storeBigEndian(&u.checksum, cc);

    Packet pkt;
    pkt.init!RawFrame(buf[0 .. total]);
    if (src_addr != IPAddr.any)
    {
        BaseInterface iface = interface_for_address(src_addr);
        if (dst_addr.is_multicast)
        {
            if (!iface)
                return false;
            stack.output_v4_routed(pkt, iface, dst_addr);
            return true;
        }
        if (iface && is_broadcast_for_interface(iface, dst_addr))
        {
            stack.output_v4_routed(pkt, iface, dst_addr);
            return true;
        }
    }
    stack.output_v4(pkt);
    return true;
}

static if (has_ipv6)
{
    // `iface` pins the link for link-local and multicast destinations; it is derived from
    // `src_addr` when null, and global destinations are routed normally.
    bool udp_output6(ref IPStack stack, IPv6Addr src_addr, ushort src_port, IPv6Addr dst_addr, ushort dst_port, BaseInterface iface, const(ubyte)[] payload)
    {
        enum size_t max_size = 1500;
        if (IPv6Header.sizeof + UdpHeader.sizeof + payload.length > max_size || dst_addr == IPv6Addr.any)
            return false;

        if (!iface && src_addr != IPv6Addr.any)
            iface = interface_for_address6(src_addr);
        if (src_addr == IPv6Addr.any)
            src_addr = stack.select_source_v6(dst_addr, iface);
        if (src_addr == IPv6Addr.any)
            return false;

        bool scoped = dst_addr.is_link_local || dst_addr.is_multicast;
        if (scoped && !iface)
            return false;

        align(size_t.sizeof) ubyte[max_size] buf = void;
        size_t total = write_udp6(buf[], src_addr, src_port, dst_addr, dst_port, payload);
        if (total == 0)
            return false;

        Packet pkt;
        pkt.init!RawFrame(buf[0 .. total]);
        if (scoped)
            stack.output_v6_routed(pkt, iface, dst_addr);
        else
            stack.output_v6(pkt);
        return true;
    }

    size_t write_udp6(ubyte[] buffer, IPv6Addr src_addr, ushort src_port, IPv6Addr dst_addr, ushort dst_port, const(ubyte)[] payload, ubyte hop_limit = 64)
    {
        size_t udp_len = UdpHeader.sizeof + payload.length;
        size_t total = IPv6Header.sizeof + udp_len;
        if (udp_len > ushort.max || buffer.length < total)
            return 0;

        auto ip = cast(IPv6Header*)buffer.ptr;
        ip.ver_tc_flow[] = 0;
        ip.ver_tc_flow[0] = 0x60;
        storeBigEndian(cast(ushort*)ip.payload_length.ptr, cast(ushort)udp_len);
        ip.next_header = IPProtocol.udp;
        ip.hop_limit = hop_limit;
        ip.src_addr = src_addr;
        ip.dst_addr = dst_addr;

        auto u = cast(UdpHeader*)(buffer.ptr + IPv6Header.sizeof);
        storeBigEndian(&u.src_port, src_port);
        storeBigEndian(&u.dst_port, dst_port);
        storeBigEndian(&u.length, cast(ushort)udp_len);
        storeBigEndian(&u.checksum, ushort(0));
        if (payload.length > 0)
            buffer[IPv6Header.sizeof + UdpHeader.sizeof .. total] = payload[];

        ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)udp_len, IPProtocol.udp);
        ushort cc = internet_checksum(buffer[IPv6Header.sizeof .. total], pseudo);
        if (cc == 0)
            cc = 0xFFFF;
        storeBigEndian(&u.checksum, cc);
        return total;
    }

    // RFC 8200: the checksum is mandatory over v6, so a zero checksum is a discard.
    bool parse_udp6(const(ubyte)[] datagram, size_t l4_offset, out ushort src_port, out ushort dst_port, out const(ubyte)[] payload)
    {
        if (datagram.length < IPv6Header.sizeof || l4_offset < IPv6Header.sizeof || l4_offset + UdpHeader.sizeof > datagram.length)
            return false;

        const ip = cast(const IPv6Header*)datagram.ptr;
        size_t end = IPv6Header.sizeof + loadBigEndian(cast(const(ushort)*)ip.payload_length.ptr);
        if (end > datagram.length || end < l4_offset + UdpHeader.sizeof)
            return false;

        const(ubyte)[] segment = datagram[l4_offset .. end];
        const u = cast(const UdpHeader*)segment.ptr;
        ushort udp_len = loadBigEndian(&u.length);
        if (udp_len < UdpHeader.sizeof || udp_len > segment.length || loadBigEndian(&u.checksum) == 0)
            return false;

        ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, udp_len, IPProtocol.udp);
        if (internet_checksum(segment[0 .. udp_len], pseudo) != 0)
            return false;

        src_port = loadBigEndian(&u.src_port);
        dst_port = loadBigEndian(&u.dst_port);
        payload = segment[UdpHeader.sizeof .. udp_len];
        return true;
    }
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
        free(cast(void[])d.data);
        d.data = null;
    }
}


private:

bool deliver_to_pcb(UdpPcb* pcb, ref InetAddress src, ref InetAddress dst, BaseInterface iface, const(ubyte)[] body_, MonoTime rx_time)
{
    version (UseInternalIPStack)
    {
        if (pcb.owner)
        {
            pcb.owner.deliver(src, dst, iface, body_, rx_time);
            return true;
        }
    }

    if (pcb.recv_queue.length >= UdpPcb.max_queued)
        return false;

    UdpDatagram dgm;
    dgm.src = src;
    if (body_.length > 0)
    {
        dgm.data = cast(ubyte[])alloc(body_.length);
        dgm.data[] = body_[];
    }
    pcb.recv_queue ~= dgm;
    return true;
}

ushort pseudo_header_checksum(IPAddr src, IPAddr dst, ubyte protocol, ushort transport_length) pure
{
    align(size_t.sizeof) ubyte[12] ph = void;
    ph[0..4]   = src.b;
    ph[4..8]   = dst.b;
    ph[8]      = 0;
    ph[9]      = protocol;
    storeBigEndian(cast(ushort*)(ph.ptr + 10), transport_length);
    return internet_checksum(ph[]);
}


unittest
{
    IPAddr a = IPAddr(192, 168, 0, 10);
    IPAddr b = IPAddr(192, 168, 0, 11);
    assert(udp_bindings_overlap(IPAddr.any, a));
    assert(udp_bindings_overlap(a, IPAddr.any));
    assert(udp_bindings_overlap(a, a));
    assert(!udp_bindings_overlap(a, b));

    static if (has_ipv6)
    {
        IPv6Addr src = IPv6AddrLit!"fe80::1";
        IPv6Addr dst = IPv6AddrLit!"ff02::fb";
        assert(udp_bindings_overlap(IPv6Addr.any, src));
        assert(udp_bindings_overlap(src, src));
        assert(!udp_bindings_overlap(src, dst));

        static immutable ubyte[4] payload = [ 1, 2, 3, 4 ];
        align(size_t.sizeof) ubyte[64] buffer;
        size_t total = write_udp6(buffer[], src, 5353, dst, 5353, payload[]);
        assert(total == IPv6Header.sizeof + UdpHeader.sizeof + payload.length);
        assert(buffer[0] == 0x60 && buffer[6] == IPProtocol.udp && buffer[7] == 64);
        assert(loadBigEndian(cast(const(ushort)*)(buffer.ptr + 4)) == UdpHeader.sizeof + payload.length);
        // hand-computed over the RFC 8200 pseudo-header for this exact datagram
        assert(loadBigEndian(cast(const(ushort)*)(buffer.ptr + IPv6Header.sizeof + 6)) == 0xD37E);

        ushort src_port, dst_port;
        const(ubyte)[] body_;
        assert(parse_udp6(buffer[0 .. total], IPv6Header.sizeof, src_port, dst_port, body_));
        assert(src_port == 5353 && dst_port == 5353 && body_ == payload[]);

        assert(!parse_udp6(buffer[0 .. total - 1], IPv6Header.sizeof, src_port, dst_port, body_));
        buffer[IPv6Header.sizeof + UdpHeader.sizeof] ^= 0xFF;
        assert(!parse_udp6(buffer[0 .. total], IPv6Header.sizeof, src_port, dst_port, body_));
        buffer[IPv6Header.sizeof + UdpHeader.sizeof] ^= 0xFF;
        buffer[IPv6Header.sizeof + 6] = 0;
        buffer[IPv6Header.sizeof + 7] = 0;
        assert(!parse_udp6(buffer[0 .. total], IPv6Header.sizeof, src_port, dst_port, body_));

        assert(write_udp6(buffer[0 .. 8], src, 1, dst, 2, payload[]) == 0);

        IPStack stack;
        UdpPcb pcb;
        pcb.family = AddressFamily.ipv6;
        pcb.local_port = 5540;
        udp_register(&pcb);
        assert(!udp_bind_available(null, IPv6Addr.any, 5540));
        assert(udp_bind_available(null, IPv6Addr.any, 5541));
        assert(udp_bind_available(null, IPAddr.any, 5540));

        Packet pkt;
        total = write_udp6(buffer[], src, 4000, IPv6AddrLit!"fe80::2", 5540, payload[]);
        pkt.init!RawFrame(buffer[0 .. total]);
        udp_input6(stack, pkt, IPv6Header.sizeof, null);
        assert(pcb.recv_queue.length == 1);
        assert(pcb.recv_queue[0].src == InetAddress(src, 4000) && pcb.recv_queue[0].data == payload[]);

        total = write_udp6(buffer[], src, 4000, IPv6AddrLit!"fe80::2", 5541, payload[]);
        pkt.init!RawFrame(buffer[0 .. total]);
        udp_input6(stack, pkt, IPv6Header.sizeof, null);
        total = write_udp6(buffer[], src, 4000, dst, 5540, payload[]);
        pkt.init!RawFrame(buffer[0 .. total]);
        udp_input6(stack, pkt, IPv6Header.sizeof, null);
        assert(pcb.recv_queue.length == 1);

        udp_free_datagram_data(pcb.recv_queue[0]);
        udp_unregister(&pcb);
    }
}
