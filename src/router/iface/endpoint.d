module router.iface.endpoint;

import urt.array;
import urt.endian;
import urt.map;
import urt.mem.allocator : defaultAllocator;
import urt.time;

import manager.base;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

nothrow @nogc:


// Transport segments carried directly over the segment: the OW header supplies the fields the
// IP header would have (addressing and protocol number); the payload is a regular transport
// header + data, so TCP/UDP machinery is unaware the network layer beneath it is not IP.
enum TransportProto : ubyte
{
    tcp = 6,    // IP protocol numbers
    udp = 17,
}

struct EtherTransport
{
    enum Type = PacketType.ether_transport;
nothrow @nogc:

    MACAddress dst;
    MACAddress src;
    ubyte protocol;

    static ulong extract_src(ref const Packet p) pure
        => ulong(Type) << 60 | ulong(p.vlan & 0xFFF) << 48 | p.hdr!EtherTransport().src.ul;

    static ulong extract_dst(ref const Packet p) pure
        => ulong(Type) << 60 | ulong(p.vlan & 0xFFF) << 48 | p.hdr!EtherTransport().dst.ul;

    alias is_multicast = Ethernet.is_multicast;

    // [dst:6][src:6][protocol:u8]
    static ptrdiff_t encode_ow_header(ref const Packet p, ubyte[] buffer)
    {
        if (buffer.length < 13)
            return -1;
        ref const h = p.hdr!EtherTransport;
        buffer[0 .. 6] = h.dst.b[];
        buffer[6 .. 12] = h.src.b[];
        buffer[12] = h.protocol;
        return 13;
    }

    static ptrdiff_t decode_ow_header(ref Packet p, const(ubyte)[] header)
    {
        if (header.length < 13)
            return -1;
        p.type = Type;
        ref h = p.hdr!EtherTransport;
        h.dst.b[] = header[0 .. 6];
        h.src.b[] = header[6 .. 12];
        h.protocol = header[12];
        return 13;
    }
}


alias EtherRecvHandler = void delegate(EtherEndpoint* ep, const(void)[] data, MACAddress src, ushort src_port, MonoTime rx_time) nothrow @nogc;
alias EtherTcpInput = void function(MACAddress src, MACAddress dst, const(void)[] segment, MonoTime rx_time) nothrow @nogc;


// TCP-over-ether segments are handed up through this hook; the IP module installs it
// when the internal TCP machinery is present.
void set_ether_tcp_input(EtherTcpInput handler)
{
    g_ether_tcp_input = handler;
}

// The station whose mac is `mac`, if any: ether local addresses name their interface.
EthernetStation find_ether_station(MACAddress mac)
{
    import manager.collection : Collection;
    foreach (i; Collection!BaseInterface().values)
    {
        if (!(i.caps & InterfaceCaps.ethernet))
            continue;
        EthernetStation s = cast(EthernetStation)i;
        if (s && s.mac == mac)
            return s;
    }
    return null;
}

void foreach_ether_station(scope void delegate(EthernetStation) nothrow @nogc sink)
{
    import manager.collection : Collection;
    foreach (i; Collection!BaseInterface().values)
    {
        if (!(i.caps & InterfaceCaps.ethernet))
            continue;
        if (EthernetStation s = cast(EthernetStation)i)
            sink(s);
    }
}

// Egress cache for unbound sources: (peer mac -> station) learned passively from tap
// ingress, the arp-cache analogue. A miss means the caller floods every segment
// (unknown-unicast flooding, self-limiting); the peer's reply populates the entry.
EthernetStation ether_neighbour_lookup(MACAddress mac)
{
    if (EtherNeighbour* e = mac.ul in _neighbours)
    {
        if (EthernetStation s = e.station.get)
        {
            if (s.running && getTime() - e.seen < ether_neighbour_ttl)
                return s;
        }
    }
    return null;
}

// Wildcard consumers (bind-any endpoints, unbound connects, any-listeners) need every
// segment tapped; once requested, the module sweep keeps taps on all stations.
void ether_request_tap_all()
{
    _tap_all = true;
}

// One ether_transport subscription per station, demuxing to endpoints and the tcp hook.
// Endpoints and pcbs bound to the station share it; the module sweep re-subscribes if
// the station is destroyed and recreated with the same name.
void ensure_ether_tap(EthernetStation station)
{
    foreach (t; _taps[])
    {
        if (t._iface.get is station)
            return;
    }
    EtherTap* tap = defaultAllocator().allocT!EtherTap();
    tap._iface = station;
    tap.try_subscribe();
    _taps ~= tap;
}


// Open an ether-UDP datagram endpoint bound to a local port (0 = ephemeral). A non-null
// iface binds the endpoint to that station; a null iface is a wildcard bind: datagrams
// are accepted on every ethernet segment, and egress uses the learned neighbour (or
// floods unknown unicast). Datagrams to the receiving station's MAC and broadcast are
// delivered; multicast groups via join(). A remote restricts delivery to that peer and
// enables send(). Bound endpoints track their interface by reference; they ride out
// restarts and re-attach if the interface is destroyed and recreated with the same name.
EtherEndpoint* ether_open(EthernetStation iface, ushort port, EtherRecvHandler on_recv,
                          MACAddress remote = MACAddress(), ushort remote_port = 0)
{
    if (on_recv is null)
        return null;
    if (cast(bool)remote != (remote_port != 0))
        return null;

    EtherEndpoint* ep = defaultAllocator().allocT!EtherEndpoint();
    ep._local_port = port ? port : allocate_ephemeral();
    ep._remote = remote;
    ep._remote_port = remote_port;
    ep._on_recv = on_recv;
    if (iface)
    {
        ep._iface = iface;
        ensure_ether_tap(iface);
    }
    else
    {
        ep._wildcard = true;
        ether_request_tap_all();
    }
    _ether_eps ~= ep;
    return ep;
}


struct EtherEndpoint
{
nothrow @nogc:

    inout(EthernetStation) iface() inout pure
        => _iface.get;

    ushort local_port() const pure
        => _local_port;

    MACAddress remote() const pure
        => _remote;

    ushort remote_port() const pure
        => _remote_port;

    MACAddress local()
    {
        EthernetStation i = _iface.get;
        return i ? i.mac : MACAddress();
    }

    // TODO: interfaces that filter multicast in hardware need an add-address hook
    bool join(MACAddress group)
    {
        if (!group.is_multicast || group.is_broadcast)
            return false;
        if (!_groups[].contains(group))
            _groups ~= group;
        return true;
    }

    void leave(MACAddress group)
    {
        _groups.removeFirstSwapLast(group);
    }

    // Send to the remote given at open. Returns bytes sent, or 0.
    ptrdiff_t send(scope const(void)[] data)
        => _remote ? sendto(_remote, _remote_port, data) : 0;

    ptrdiff_t sendto(MACAddress dst, ushort dst_port, scope const(void)[] data)
    {
        if (_closing || !dst || dst_port == 0)
            return 0;

        ubyte[1518] buf = void;
        if (UdpSegHeader.sizeof + data.length > buf.length)
            return 0;
        auto u = cast(UdpSegHeader*)buf.ptr;
        u.src_port = _local_port.nativeToBigEndian;
        u.dst_port = dst_port.nativeToBigEndian;
        u.length = nativeToBigEndian(cast(ushort)(UdpSegHeader.sizeof + data.length));
        u.checksum[] = 0;    // link CRC covers integrity
        buf[UdpSegHeader.sizeof .. UdpSegHeader.sizeof + data.length] = (cast(const(ubyte)[])data)[];
        const(ubyte)[] frame = buf[0 .. UdpSegHeader.sizeof + data.length];

        if (!_wildcard)
        {
            EthernetStation i = _iface.get;
            if (!i || !i.running)
                return 0;
            return emit(i, dst, frame) ? data.length : 0;
        }

        // wildcard: learned neighbour picks the segment; unknown (or multicast) floods them all
        if (EthernetStation i = ether_neighbour_lookup(dst))
            return emit(i, dst, frame) ? data.length : 0;
        bool sent = false;
        foreach_ether_station((EthernetStation s) {
            if (s.running && emit(s, dst, frame))
                sent = true;
        });
        return sent ? data.length : 0;
    }

    // Teardown is deferred to the module sweep; safe to call from the recv handler.
    void close()
    {
        _closing = true;
    }

private:
    ObjectRef!EthernetStation _iface;
    EtherRecvHandler _on_recv;
    Array!MACAddress _groups;
    MACAddress _remote;
    ushort _remote_port;
    ushort _local_port;
    bool _wildcard;
    bool _closing;

    bool emit(EthernetStation station, MACAddress dst, const(ubyte)[] frame)
    {
        ushort mtu = station.actual_mtu;
        if (mtu && frame.length + encap_overhead - UdpSegHeader.sizeof > mtu)
            return false;
        Packet p;
        ref h = p.init!EtherTransport(frame);
        h.dst = dst;
        h.src = station.mac;
        h.protocol = TransportProto.udp;
        return station.forward(p) >= 0;
    }

    void deliver(ref const Packet p, ref const EtherTransport h, EthernetStation station)
    {
        if (_closing)
            return;
        if (!_wildcard && _iface.get !is station)
            return;

        const(ubyte)[] seg = cast(const(ubyte)[])p.data;
        if (seg.length < UdpSegHeader.sizeof)
            return;
        const u = cast(const(UdpSegHeader)*)seg.ptr;
        if (u.dst_port.bigEndianToNative!ushort != _local_port)
            return;
        ushort len = u.length.bigEndianToNative!ushort;
        if (len < UdpSegHeader.sizeof || len > seg.length)
            return;

        if (h.dst != station.mac && !h.dst.is_broadcast && !(h.dst.is_multicast && _groups[].contains(h.dst)))
            return;
        ushort src_port = u.src_port.bigEndianToNative!ushort;
        if (_remote && (h.src != _remote || src_port != _remote_port))
            return;

        _on_recv(&this, seg[UdpSegHeader.sizeof .. len], h.src, src_port, p.creation_time);
    }
}


package:

void update_ether_endpoints()
{
    for (size_t i = _ether_eps.length; i-- > 0; )
    {
        EtherEndpoint* ep = _ether_eps[i];
        if (ep._closing)
        {
            defaultAllocator().freeT(ep);
            _ether_eps.removeSwapLast(i);
        }
    }
    if (_tap_all)
        foreach_ether_station((EthernetStation s) { ensure_ether_tap(s); });
    foreach (tap; _taps[])
    {
        if (!tap._subscribed)
            tap.try_subscribe();
    }
}


private:

enum encap_overhead = 5 + 13 + UdpSegHeader.sizeof;     // ow framing + ether-transport header + udp header

// standard UDP header; over ether the checksum is unused (transmitted zero, ignored on receive)
struct UdpSegHeader
{
    ubyte[2] src_port;      // big-endian
    ubyte[2] dst_port;      // big-endian
    ubyte[2] length;        // big-endian; header + data
    ubyte[2] checksum;
}
static assert(UdpSegHeader.sizeof == 8);


struct EtherTap
{
nothrow @nogc:

    ObjectRef!EthernetStation _iface;
    bool _subscribed;

    void try_subscribe()
    {
        EthernetStation i = _iface.get;
        if (!i || !i.running)
            return;
        PacketFilter filter;
        filter.type = PacketType.ether_transport;
        i.subscribe(&on_packet, filter);
        i.subscribe(&on_iface_state);
        _subscribed = true;
    }

    void on_packet(ref const Packet p, BaseInterface, PacketDirection dir, void*)
    {
        if (dir != PacketDirection.incoming)
            return;
        EthernetStation station = _iface.get;
        if (!station)
            return;
        ref const h = p.hdr!EtherTransport;
        ether_neighbour_learn(h.src, station);
        switch (h.protocol)
        {
            case TransportProto.udp:
                foreach (ep; _ether_eps[])
                    ep.deliver(p, h, station);
                break;

            case TransportProto.tcp:
                // tcp is point-to-point; only segments addressed to this station matter
                if (g_ether_tcp_input && h.dst == station.mac)
                    g_ether_tcp_input(h.src, h.dst, p.data, p.creation_time);
                break;

            default:
                break;
        }
    }

    void on_iface_state(ActiveObject, StateSignal signal)
    {
        // Subscriptions on the dying object vanish with it; the module sweep
        // re-subscribes if an interface with the same name reappears.
        if (signal == StateSignal.destroyed)
            _subscribed = false;
    }
}

enum ether_neighbour_ttl = 300.seconds;

struct EtherNeighbour
{
    ObjectRef!EthernetStation station;
    MonoTime seen;
}

void ether_neighbour_learn(MACAddress mac, EthernetStation station)
{
    if (mac.is_multicast)
        return;
    if (EtherNeighbour* e = mac.ul in _neighbours)
    {
        e.station = station;
        e.seen = getTime();
    }
    else
        _neighbours[mac.ul] = EtherNeighbour(ObjectRef!EthernetStation(station), getTime());
}

__gshared Array!(EtherEndpoint*) _ether_eps;
__gshared Array!(EtherTap*) _taps;
__gshared Map!(ulong, EtherNeighbour) _neighbours;
__gshared EtherTcpInput g_ether_tcp_input;
__gshared bool _tap_all;
__gshared ushort _next_ephemeral = 49_152;

ushort allocate_ephemeral()
{
    ushort port = _next_ephemeral;
    _next_ephemeral = port == 0xFFFF ? 49_152 : cast(ushort)(port + 1);
    return port;
}


unittest
{
    ubyte[12] payload = [ 0xC0, 0x00, 0x01, 0xF4, 0x00, 0x0C, 0x00, 0x00, 1, 2, 3, 4 ];
    Packet packet;
    ref EtherTransport t = packet.init!EtherTransport(payload[]);
    t.dst = MACAddress(0x02, 0x13, 0x37, 0xAA, 0xBB, 0x64);
    t.src = MACAddress(0x02, 0x13, 0x37, 0xCC, 0xDD, 0x65);
    t.protocol = TransportProto.udp;

    ubyte[13] header;
    assert(EtherTransport.encode_ow_header(packet, header[]) == 13);
    assert(EtherTransport.encode_ow_header(packet, header[0 .. 12]) == -1);

    Packet decoded;
    assert(EtherTransport.decode_ow_header(decoded, header[0 .. 12]) == -1);
    assert(EtherTransport.decode_ow_header(decoded, header[]) == 13);
    ref result = decoded.hdr!EtherTransport;
    assert(result.dst == t.dst && result.src == t.src && result.protocol == TransportProto.udp);
    assert(EtherTransport.extract_dst(packet) == EtherTransport.extract_dst(decoded));
    assert(EtherTransport.extract_dst(packet) >> 60 == ulong(PacketType.ether_transport));
    assert(MACAddress.from_ul(EtherTransport.extract_dst(packet)) == t.dst);
}
