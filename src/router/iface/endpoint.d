module router.iface.endpoint;

import urt.array;
import urt.endian;
import urt.inet;
import urt.map;
import urt.mem;
import urt.time;

import manager.base;
import manager.collection : Collection, dyn_cast;
import manager.features;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

static if (has_ip)
    import protocol.ip : IPUDPState;

nothrow @nogc:


enum TransportProto : ubyte
{
    tcp = 6,    // IP protocol numbers
    udp = 17,
}

enum size_t ow_transport_header_size = 6;

bool write_ow_transport_header(ubyte[] buffer, ubyte protocol, size_t segment_length)
{
    if (segment_length > ushort.max || buffer.length < ow_transport_header_size + segment_length)
        return false;
    storeBigEndian(cast(ushort*)buffer.ptr, ow_transport_discriminator(protocol));
    storeBigEndian(cast(ushort*)(buffer.ptr + 2), cast(ushort)segment_length);
    buffer[4] = 1; // keeps the transport header aligned after the Ethernet header
    buffer[5] = 0;
    return true;
}

bool parse_ow_transport(const(Packet)* packet, out ubyte protocol, out const(ubyte)[] segment)
{
    if (packet.type != PacketType.ethernet || packet.eth.ether_type != EtherType.ow)
        return false;
    if (packet.data.length < ow_transport_header_size)
        return false;

    const(ubyte)[] content = cast(const(ubyte)[])packet.data;
    ushort discriminator = loadBigEndian(cast(const(ushort)*)content.ptr);
    if (!is_ow_transport(discriminator))
        return false;
    ushort segment_length = loadBigEndian(cast(const(ushort)*)(content.ptr + 2));
    ubyte extra_length = content[4];
    if ((extra_length & 3) != 1)
        return false;
    size_t offset = 5 + extra_length;
    if (offset + segment_length > content.length)
        return false;

    protocol = cast(ubyte)discriminator;
    segment = content[offset .. offset + segment_length];
    return true;
}


struct UDPReceiveInfo
{
    InetAddress source;
    InetAddress destination;
    MonoTime rx_time;
    BaseInterface ingress;
}

alias UDPRecvHandler = void delegate(UDPEndpoint* ep, const(void)[] data, ref UDPReceiveInfo info) nothrow @nogc;
alias EtherTcpInput = void function(MACAddress src, MACAddress dst, const(void)[] segment, MonoTime rx_time) nothrow @nogc;

struct UdpHeader
{
    ushort src_port;
    ushort dst_port;
    ushort length;
    ushort checksum;
}
static assert(UdpHeader.sizeof == 8);


// null unless the IP module installs it; switch builds carry no TCP
void set_ether_tcp_input(EtherTcpInput handler)
{
    g_ether_tcp_input = handler;
}

void ether_transport_input(Packet* packet, BaseInterface iface)
{
    scope (exit) packet_free(packet);
    EthernetStation station = dyn_cast!EthernetStation(iface);
    if (!station)
        return;

    ubyte protocol;
    const(ubyte)[] segment;
    if (!parse_ow_transport(packet, protocol, segment))
        return;

    ether_neighbour_learn(packet.eth.src, station);
    switch (protocol)
    {
        case TransportProto.udp:
            foreach (endpoint; _udp_eps[])
                endpoint.deliver_ether(packet, segment, station);
            break;

        case TransportProto.tcp:
            if (g_ether_tcp_input && packet.eth.dst == station.mac)
                g_ether_tcp_input(packet.eth.src, packet.eth.dst, segment, packet.creation_time);
            break;

        default:
            break;
    }
}

// a frame a point-to-point link dispatched locally; a reliable UDP interface hands up udp frames
void link_input(Packet* packet, BaseInterface link)
{
    scope (exit) packet_free(packet);
    immutable bool dedicated = UDPEndpoint.LinkUDPState.dedicated(link);
    const(ubyte)[] frame = cast(const(ubyte)[])packet.data;
    if (!dedicated && frame.length < UDPEndpoint.LinkUDPState.link_header_size)
        return;
    ushort port = dedicated ? 0 : frame[0 .. 2].bigEndianToNative!ushort;
    foreach (ep; _udp_eps[])
    {
        if (ep._family == AddressFamily.link && !ep._closing && ep._link._iface is link && (dedicated || ep._link._port == port))
            return ep._link.deliver(ep, packet, link);
    }
}

void link_state_change(ActiveObject object, StateSignal signal)
{
    if (signal != StateSignal.destroyed)
        return;
    foreach (ep; _udp_eps[])
    {
        if (ep._family == AddressFamily.link && ep._link._iface is object)
            ep._link._iface = null;
    }
}

EthernetStation find_ether_station(MACAddress mac)
{
    foreach (i; Collection!BaseInterface().values)
    {
        if (!(i.caps & InterfaceCaps.ethernet) || (i.flags & ObjectFlags.slave))
            continue;
        EthernetStation s = dyn_cast!EthernetStation(i);
        if (s && s.mac == mac)
            return s;
    }
    return null;
}

void foreach_ether_station(scope void delegate(EthernetStation) nothrow @nogc sink)
{
    foreach (i; Collection!BaseInterface().values)
    {
        if (!(i.caps & InterfaceCaps.ethernet) || (i.flags & ObjectFlags.slave))
            continue;
        if (EthernetStation s = dyn_cast!EthernetStation(i))
            sink(s);
    }
}

// fdb for ow speakers: mac -> station that heard it; a miss means the caller floods
EthernetStation ether_neighbour_lookup(MACAddress mac)
{
    if (EtherNeighbour* e = mac.ul in _neighbours)
    {
        if (EthernetStation s = e.station.get)
        {
            if (s.running && !(s.flags & ObjectFlags.slave) && getTime() - e.seen < ether_neighbour_ttl)
                return s;
        }
    }
    return null;
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

// `local` binds a receive address/port (null binds any:ephemeral); when `remote` is set,
// send() targets it and the endpoint only delivers datagrams from that peer.
UDPEndpoint* udp_open(const(InetAddress)* local, const(InetAddress)* remote, UDPRecvHandler on_recv, EthernetStation iface = null)
{
    if (on_recv is null)
        return null;

    AddressFamily family = AddressFamily.unspecified;
    if (local)
        family = local.family;
    if (remote)
    {
        if (family != AddressFamily.unspecified && family != remote.family)
            return null;
        family = remote.family;
    }
    if (family == AddressFamily.unspecified)
    {
        static if (has_ip)
            family = AddressFamily.ipv4;
        else
            return null;
    }

    UDPEndpoint* ep = alloc!UDPEndpoint();
    if (!ep)
        return null;
    ep._family = family;
    ep._remote = remote ? *remote : InetAddress();
    ep._connected = remote !is null;
    ep._on_recv = on_recv;

    if (family == AddressFamily.link)
    {
        ep._link = UDPEndpoint.LinkUDPState.init;
        if (!ep._link.open(ep, local, remote))
        {
            free(ep);
            return null;
        }
    }
    else if (family == AddressFamily.ether)
    {
        if (!ep._ether.open(ep, local, remote, iface))
        {
            free(ep);
            return null;
        }
    }
    else
    {
        static if (has_ip)
        {
            ep._ip = IPUDPState.init;
            if (!ep._ip.open(ep, local, remote))
            {
                free(ep);
                return null;
            }
        }
        else
        {
            free(ep);
            return null;
        }
    }
    _udp_eps ~= ep;
    return ep;
}


struct UDPEndpoint
{
nothrow @nogc:

    inout(EthernetStation) iface() inout pure
        => _family == AddressFamily.ether ? _ether._iface.get : null;

    // a link endpoint outlives its interface detached, sending and receiving nothing
    bool attached() const pure
        => _family != AddressFamily.link || _link._iface !is null;

    // a link datagram goes as a text frame, for carriers that tell text from binary
    void text(bool value)
    {
        if (_family == AddressFamily.link)
            _link._text = value;
    }

    InetAddress local()
    {
        if (_family == AddressFamily.link)
            return InetAddress.link(_link._iface ? _link._iface.scope_id : 0, _link._port);
        if (_family == AddressFamily.ether)
            return _ether.local_address();
        static if (has_ip)
            return _ip.local_address();
        else
            return InetAddress();
    }

    InetAddress remote() const pure
        => _remote;

    // a server's unconnected endpoint serves many destinations, so the caller names one
    BaseInterface egress_iface(InetAddress destination)
    {
        if (_family == AddressFamily.link)
            return _link.egress_iface(destination);
        if (_family == AddressFamily.ether)
            return _ether.egress_iface(destination);
        static if (has_ip)
            return _ip.egress_iface(destination);
        else
            return null;
    }

    // TODO: interfaces that filter multicast in hardware need an add-address hook
    bool join(MACAddress group)
    {
        return _family == AddressFamily.ether && _ether.join(group);
    }

    void leave(MACAddress group)
    {
        if (_family == AddressFamily.ether)
            _ether.leave(group);
    }

    bool join(IPAddr group, IPAddr interface_ = IPAddr.any)
    {
        static if (has_ip)
            return is_ip && _ip.join(group, interface_);
        else
            return false;
    }

    bool outbound_interface(IPAddr interface_)
    {
        static if (has_ip)
            return is_ip && _ip.outbound_interface(interface_);
        else
            return false;
    }

    static if (has_ipv6)
    {
        bool join(IPv6Addr group, BaseInterface iface)
            => _family == AddressFamily.ipv6 && _ip.join(group, iface);

        // Pins the link for link-local and multicast sends; join() sets it on first membership.
        bool outbound_interface(BaseInterface iface)
            => _family == AddressFamily.ipv6 && _ip.outbound_interface(iface);
    }

    bool enable_broadcast()
    {
        if (_family == AddressFamily.ether)
            return _ether.enable_broadcast();
        static if (has_ip)
            return is_ip && _ip.enable_broadcast();
        else
            return false;
    }

    ptrdiff_t send(scope const(void)[] data, PCP pcp = PCP.be)
    {
        if (_closing || !_connected)
            return 0;
        return sendto_backend(data, _remote, pcp);
    }

    ptrdiff_t sendto(scope const(void)[] data, InetAddress dst, PCP pcp = PCP.be)
    {
        if (_closing || dst.family != _family || (_connected && dst != _remote))
            return 0;
        return sendto_backend(data, dst, pcp);
    }

    // A destination with no egress interface to ask (a flood, or a kernel socket) is always ready.
    bool tx_ready(InetAddress dst, PCP pcp = PCP.be)
    {
        BaseInterface egress = egress_iface(dst);
        return !egress || egress.tx_ready(pcp);
    }

    void wait_tx(InetAddress dst, ref TxWaiter waiter)
    {
        if (BaseInterface egress = egress_iface(dst))
            egress.wait_tx(waiter);
    }

    size_t frame_room(InetAddress dst)
    {
        if (_family == AddressFamily.link)
            return _link.frame_room(dst);
        BaseInterface egress = egress_iface(dst);
        size_t mtu = egress ? egress.actual_mtu : default_frame;
        if (mtu > default_frame)
            mtu = default_frame;
        size_t overhead = UdpHeader.sizeof + (_family == AddressFamily.ether ? ow_transport_header_size : _family == AddressFamily.ipv6 ? 40 : 20);
        return mtu > overhead ? mtu - overhead : 0;
    }

    // Deferred to the module sweep; safe to call from the receive handler.
    void close()
    {
        if (_closing)
            return;
        _closing = true;
        if (_family == AddressFamily.ether)
            _ether.close();
        else static if (has_ip)
        {
            if (is_ip)
                _ip.close();
        }
    }

private:

    void deliver_ether(const(Packet)* packet, const(ubyte)[] segment, EthernetStation station)
    {
        if (_family != AddressFamily.ether || _closing)
            return;
        _ether.deliver(&this, packet, segment, station);
    }

    struct EtherUDPState
    {
nothrow @nogc:

        bool open(UDPEndpoint*, const(InetAddress)* local_address, const(InetAddress)* remote_address, EthernetStation station)
        {
            if ((local_address && local_address.family != AddressFamily.ether) || (remote_address && remote_address.family != AddressFamily.ether))
                return false;
            if (station && (station.flags & ObjectFlags.slave))
                return false;
            MACAddress local = local_address ? MACAddress(local_address._a.ether.addr) : MACAddress();
            MACAddress remote = remote_address ? MACAddress(remote_address._a.ether.addr) : MACAddress();
            ushort remote_port = remote_address ? remote_address._a.ether.port : 0;
            if (cast(bool)remote != (remote_port != 0))
                return false;
            if (station && local && station.mac != local)
                return false;
            if (!station && local && !find_ether_station(local))
                return false;

            ushort port = local_address ? local_address._a.ether.port : 0;
            if (port == 0)
                port = allocate_ephemeral(station, local);
            if (port == 0 || !ether_bind_available(station, local, port))
                return false;

            _local = local ? local : (station ? station.mac : MACAddress());
            _local_port = port;
            if (station)
                _iface = station;
            else if (!local)
                _wildcard = true;
            return true;
        }

        InetAddress local_address()
        {
            EthernetStation station = _iface.get;
            MACAddress address = station ? station.mac : _local;
            return InetAddress(address.b, _local_port);
        }

        BaseInterface egress_iface(InetAddress dst)
        {
            const(InetAddress.Ether)* address = dst.as_ether;
            return address ? unicast_egress(MACAddress(address.addr)) : null;
        }

        bool join(MACAddress group)
        {
            if (!group.is_multicast || group.is_broadcast)
                return false;
            if (!_groups)
                _groups = alloc!(Array!MACAddress)();
            if (!_groups)
                return false;
            if (!(*_groups)[].contains(group))
                (*_groups) ~= group;
            return true;
        }

        void leave(MACAddress group)
        {
            if (_groups)
                (*_groups).removeFirstSwapLast(group);
        }

        bool enable_broadcast()
            => true;

        ptrdiff_t sendto(scope const(void)[] data, InetAddress dst, PCP pcp)
        {
            const(InetAddress.Ether)* address = dst.as_ether;
            if (!address)
                return 0;
            MACAddress mac = MACAddress(address.addr);
            if (!mac || address.port == 0)
                return 0;

            enum size_t prefix = 2;
            align(size_t.sizeof) ubyte[1518] buf = void;
            size_t segment_length = UdpHeader.sizeof + data.length;
            if (prefix + ow_transport_header_size + segment_length > buf.length)
                return 0;
            ubyte[] ow = buf[prefix .. prefix + ow_transport_header_size + segment_length];
            if (!write_ow_transport_header(ow, TransportProto.udp, segment_length))
                return 0;
            auto udp = cast(UdpHeader*)(ow.ptr + ow_transport_header_size);
            storeBigEndian(&udp.src_port, _local_port);
            storeBigEndian(&udp.dst_port, address.port);
            storeBigEndian(&udp.length, cast(ushort)segment_length);
            storeBigEndian(&udp.checksum, ushort(0));
            ow[ow_transport_header_size + UdpHeader.sizeof .. $] = (cast(const(ubyte)[])data)[];

            if (EthernetStation station = unicast_egress(mac))
            {
                if (!station.running || (station.flags & ObjectFlags.slave))
                    return 0;
                return emit(station, mac, ow, pcp) ? data.length : 0;
            }
            if (!_wildcard)
                return 0;
            bool sent;
            foreach_ether_station((EthernetStation station)
            {
                if (station.running && emit(station, mac, ow, pcp))
                    sent = true;
            });
            return sent ? data.length : 0;
        }

        void close()
        {
        }

        bool reclaimable() const
            => true;

        void release()
        {
            if (_groups)
            {
                free(_groups);
                _groups = null;
            }
        }

        void deliver(UDPEndpoint* owner, const(Packet)* packet, const(ubyte)[] segment, EthernetStation station)
        {
            if (!_wildcard)
            {
                EthernetStation bound_iface = _iface.get;
                if (bound_iface ? bound_iface !is station : station.mac != _local)
                    return;
            }

            if (segment.length < UdpHeader.sizeof)
                return;
            const udp = cast(const(UdpHeader)*)segment.ptr;
            if (loadBigEndian(&udp.dst_port) != _local_port)
                return;
            ushort length = loadBigEndian(&udp.length);
            if (length < UdpHeader.sizeof || length > segment.length)
                return;

            bool joined = _groups && (*_groups)[].contains(packet.eth.dst);
            if (packet.eth.dst != station.mac && !packet.eth.dst.is_broadcast && !(packet.eth.dst.is_multicast && joined))
                return;

            UDPReceiveInfo info;
            info.source = InetAddress(packet.eth.src.b, loadBigEndian(&udp.src_port));
            info.destination = InetAddress(packet.eth.dst.b, _local_port);
            info.rx_time = packet.creation_time;
            info.ingress = station;
            udp_deliver(owner, segment[UdpHeader.sizeof .. length], info);
        }

    private:
        // null floods every station: a wildcard endpoint that has not heard the destination
        EthernetStation unicast_egress(MACAddress dst)
        {
            if (EthernetStation station = _iface.get)
                return station;
            EthernetStation learned = ether_neighbour_lookup(dst);
            if (learned && (_wildcard || learned.mac == _local))
                return learned;
            return _wildcard ? null : find_ether_station(_local);
        }

        bool emit(EthernetStation station, MACAddress dst, const(ubyte)[] frame, PCP pcp)
        {
            StackPacket packet;
            ref ether = packet.init!Ethernet(frame);
            ether.dst = dst;
            ether.src = station.mac;
            ether.ether_type = EtherType.ow;
            packet.pcp = pcp;
            return station.forward(&packet.packet) >= 0;
        }

        ObjectRef!EthernetStation _iface;
        Array!MACAddress* _groups;
        MACAddress _local;
        ushort _local_port;
        bool _wildcard;
    }

    // a dedicated link's frame is the payload alone; any other carries its ports ahead of it
    struct LinkUDPState
    {
nothrow @nogc:

        bool open(UDPEndpoint* owner, const(InetAddress)* local_address, const(InetAddress)* remote_address)
        {
            const(InetAddress.Link)* local = local_address ? local_address.as_link : null;
            const(InetAddress.Link)* remote = remote_address ? remote_address.as_link : null;
            if (!local || local.port == 0 || (remote_address && !remote))
                return false;
            if (remote && (remote.scope_id != local.scope_id || remote.port == 0))
                return false;
            BaseInterface link = interface_for_scope(local.scope_id);
            if (!link || link.destroying || !link_bind_available(link, local.port))
                return false;
            // a dedicated link carries one port, so a connected remote can only be on it
            if (remote && dedicated(link) && remote.port != local.port)
                return false;
            _iface = link;
            _port = local.port;
            return true;
        }

        BaseInterface egress_iface(InetAddress dst)
        {
            const(InetAddress.Link)* address = dst.as_link;
            return address && _iface && address.scope_id == _iface.scope_id ? _iface : null;
        }

        size_t frame_room(InetAddress dst)
        {
            BaseInterface link = egress_iface(dst);
            if (!link)
                return 0;
            size_t header = dedicated(link) ? 0 : link_header_size;
            return link.actual_mtu > header ? link.actual_mtu - header : 0;
        }

        ptrdiff_t sendto(scope const(void)[] data, InetAddress dst, PCP pcp)
        {
            BaseInterface link = egress_iface(dst);
            if (!link || !link.running || dst.port == 0 || (dedicated(link) && dst.port != _port))
                return 0;
            StackPacket lent;
            Packet* packet = &lent.packet;
            if (dedicated(link))
                lent.init!RawFrame(data);
            else
            {
                packet = alloc_packet!RawFrame(data, link_header_size);
                if (!packet)
                    return 0;
                ubyte[] header = cast(ubyte[])packet.alloc_prefix(link_header_size);
                header[0 .. 2] = dst.port.nativeToBigEndian;
                header[2 .. 4] = _port.nativeToBigEndian;
            }
            packet.hdr!RawFrame().is_text = _text;
            packet.pcp = pcp;
            return link.forward(packet) >= 0 ? data.length : 0;
        }

        // the demux checked the frame and picked this endpoint for it
        void deliver(UDPEndpoint* owner, const(Packet)* packet, BaseInterface link)
        {
            const(ubyte)[] frame = cast(const(ubyte)[])packet.data;
            ushort dst_port = _port, src_port = _port;
            if (!dedicated(link))
            {
                src_port = frame[2 .. 4].bigEndianToNative!ushort;
                frame = frame[link_header_size .. $];
            }
            UDPReceiveInfo info;
            info.source = InetAddress.link(link.scope_id, src_port);
            info.destination = InetAddress.link(link.scope_id, dst_port);
            info.rx_time = packet.creation_time;
            info.ingress = link;
            udp_deliver(owner, frame, info);
        }

        enum size_t link_header_size = 4;

        static bool dedicated(const BaseInterface link) pure
            => (link.caps & InterfaceCaps.dedicated) != 0;

        BaseInterface _iface;   // the instance bound, never a same-name successor
        ushort _port;
        bool _text;
    }

    bool reclaimable() const
    {
        if (_family == AddressFamily.link)
            return true;
        if (_family == AddressFamily.ether)
            return _ether.reclaimable();
        static if (has_ip)
            return _ip.reclaimable();
        else
            return true;
    }

    void release()
    {
        if (_family == AddressFamily.ether)
            _ether.release();
        else static if (has_ip)
        {
            if (is_ip)
                _ip.release();
        }
    }

    bool is_ip() const pure
        => _family == AddressFamily.ipv4 || _family == AddressFamily.ipv6;

    enum size_t default_frame = 1500;

    ptrdiff_t sendto_backend(scope const(void)[] data, InetAddress dst, PCP pcp)
    {
        if (_family == AddressFamily.link)
            return _link.sendto(data, dst, pcp);
        if (_family == AddressFamily.ether)
            return _ether.sendto(data, dst, pcp);
        static if (has_ip)
            return _ip.sendto(data, dst, pcp);
        else
            return 0;
    }

    AddressFamily _family;
    bool _closing;
    bool _connected;
    InetAddress _remote;
    UDPRecvHandler _on_recv;
    union
    {
        EtherUDPState _ether;
        LinkUDPState _link;
        static if (has_ip)
            IPUDPState _ip;
    }
}


void udp_deliver(UDPEndpoint* endpoint, const(void)[] data, ref UDPReceiveInfo info)
{
    if (!endpoint || endpoint._closing || (endpoint._connected && info.source != endpoint._remote))
        return;
    endpoint._on_recv(endpoint, data, info);
}


package:

void update_udp_endpoints()
{
    for (size_t i = _udp_eps.length; i-- > 0; )
    {
        UDPEndpoint* ep = _udp_eps[i];
        if (ep._closing && ep.reclaimable)
        {
            ep.release();
            free(ep);
            _udp_eps.removeSwapLast(i);
        }
    }
    MonoTime now = getTime();
    if (now - _last_neighbour_sweep >= ether_neighbour_ttl)
    {
        _last_neighbour_sweep = now;
        Array!ulong expired;
        foreach (ref kvp; _neighbours)
        {
            if (!kvp.value.station.get || now - kvp.value.seen >= ether_neighbour_ttl)
                expired ~= kvp.key;
        }
        foreach (k; expired[])
            _neighbours.remove(k);
    }
}

void close_udp_endpoints()
{
    foreach (ep; _udp_eps[])
        ep.close();
    update_udp_endpoints();
}


private:

enum ether_neighbour_ttl = 300.seconds;

struct EtherNeighbour
{
    ObjectRef!EthernetStation station;
    MonoTime seen;
}

__gshared Array!(UDPEndpoint*) _udp_eps;
__gshared Map!(ulong, EtherNeighbour) _neighbours;
__gshared MonoTime _last_neighbour_sweep;
__gshared EtherTcpInput g_ether_tcp_input;
__gshared ushort _next_ephemeral = 49_152;
bool ether_bind_available(EthernetStation iface, MACAddress local, ushort port)
{
    foreach (ep; _udp_eps[])
    {
        if (ep._family != AddressFamily.ether || ep._closing || ep._ether._local_port != port)
            continue;
        EthernetStation bound_iface = ep._ether._iface.get;
        if (bound_iface && iface)
        {
            if (bound_iface is iface)
                return false;
            continue;
        }
        MACAddress existing = bound_iface ? bound_iface.mac : ep._ether._local;
        MACAddress requested = iface ? iface.mac : local;
        if (ether_addresses_overlap(existing, requested))
            return false;
    }
    return true;
}

// a dedicated link serves one endpoint; any other, one per port
bool link_bind_available(BaseInterface link, ushort port)
{
    foreach (ep; _udp_eps[])
    {
        if (ep._family == AddressFamily.link && !ep._closing && ep._link._iface is link && (ep._link._port == port || UDPEndpoint.LinkUDPState.dedicated(link)))
            return false;
    }
    return true;
}

bool ether_addresses_overlap(MACAddress a, MACAddress b) pure
    => !a || !b || a == b;

ushort allocate_ephemeral(EthernetStation iface, MACAddress local)
{
    foreach (_; 0 .. 16_384)
    {
        ushort port = _next_ephemeral;
        _next_ephemeral = port == 0xFFFF ? 49_152 : cast(ushort)(port + 1);
        if (ether_bind_available(iface, local, port))
            return port;
    }
    return 0;
}

unittest
{
    import router.iface.bridge : BridgeInterface;

    struct TestEtherSink
    {
        BaseInterface expected_ingress;
        size_t received;
        MACAddress source;
        MACAddress destination;
        ushort source_port;
        ushort destination_port;
        ubyte[4] payload;
        bool ingress_matches;

        void recv(UDPEndpoint*, const(void)[] data, ref UDPReceiveInfo info) nothrow @nogc
        {
            ++received;
            assert(data.length == payload.length);
            payload[] = cast(const(ubyte)[])data;
            source = MACAddress(info.source._a.ether.addr);
            destination = MACAddress(info.destination._a.ether.addr);
            source_port = info.source._a.ether.port;
            destination_port = info.destination._a.ether.port;
            ingress_matches = info.ingress is expected_ingress;
        }

        void input(Packet* packet, BaseInterface iface) nothrow @nogc
        {
            ether_transport_input(packet, iface);
        }
    }

    class TestEtherStation : BridgeInterface
    {
nothrow @nogc:

        ~this() {}

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(id, flags);
        }

        void start_test()
        {
            assert(startup() == CompletionStatus.complete);
            _state = State.running;
        }

        void stop_test()
        {
            assert(shutdown() == CompletionStatus.complete);
            _state = State.destroyed;
        }

        void receive(Packet* packet)
        {
            incoming_packet(packet);
        }
    }

    enum size_t prefix = 2;
    align(size_t.sizeof) ubyte[prefix + ow_transport_header_size + 12] buffer = void;
    ubyte[] ow = buffer[prefix .. $];
    assert(write_ow_transport_header(ow, TransportProto.udp, 12));
    assert(!write_ow_transport_header(ow[0 .. ow_transport_header_size - 1], TransportProto.udp, 12));
    static immutable ubyte[12] wire_segment = [ 0xC0, 0x00, 0x01, 0xF4, 0x00, 0x0C, 0x00, 0x00, 1, 2, 3, 4 ];
    ow[ow_transport_header_size .. $] = wire_segment[];

    StackPacket packet;
    ref eth = packet.init!Ethernet(ow);
    eth.dst = MACAddress(0x02, 0x13, 0x37, 0xAA, 0xBB, 0x64);
    eth.src = MACAddress(0x02, 0x13, 0x37, 0xCC, 0xDD, 0x65);
    eth.ether_type = EtherType.ow;

    ubyte protocol;
    const(ubyte)[] segment;
    assert(parse_ow_transport(&packet.packet, protocol, segment));
    assert(protocol == TransportProto.udp);
    assert(segment == ow[ow_transport_header_size .. $]);
    assert(loadBigEndian(cast(const(ushort)*)ow.ptr) == ow_transport_discriminator(TransportProto.udp));

    UDPEndpoint ip_endpoint;
    ip_endpoint._family = AddressFamily.ipv4;
    ip_endpoint.deliver_ether(&packet.packet, segment, null);

    MACAddress local_a = MACAddress(0x02, 0, 0, 0, 0, 1);
    MACAddress local_b = MACAddress(0x02, 0, 0, 0, 0, 2);
    assert(ether_addresses_overlap(MACAddress(), local_a));
    assert(ether_addresses_overlap(local_a, MACAddress()));
    assert(ether_addresses_overlap(local_a, local_a));
    assert(!ether_addresses_overlap(local_a, local_b));

    TestEtherSink sink;
    InetAddress local = InetAddress(MACAddress().b, 61_234);
    UDPEndpoint* wildcard = udp_open(&local, null, &sink.recv);
    assert(wildcard);
    assert(!udp_open(&local, null, &sink.recv));

    InetAddress ephemeral_local = InetAddress(MACAddress().b, 0);
    UDPEndpoint* ephemeral = udp_open(&ephemeral_local, null, &sink.recv);
    assert(ephemeral && ephemeral._family == AddressFamily.ether && ephemeral.local.port != 0);
    MACAddress group = MACAddress(0x01, 0, 0x5E, 0, 0, 1);
    assert(ephemeral.join(group));
    assert(ephemeral._ether._groups && (*ephemeral._ether._groups)[].contains(group));

    TestEtherStation station = Collection!TestEtherStation().create("ether-test-station");
    TestEtherStation master = Collection!TestEtherStation().create("ether-test-master");
    sink.expected_ingress = station;
    InetAddress station_local = InetAddress(station.mac.b, 500);
    UDPEndpoint* bound = udp_open(&station_local, null, &sink.recv, station);
    assert(bound);

    assert(register_frame_handler(PacketType.ethernet, &sink.input));
    eth.dst = station.mac;
    station.receive(&packet.packet);
    unregister_frame_handler(PacketType.ethernet);
    assert(sink.received == 1 && sink.payload == [1, 2, 3, 4]);
    assert(sink.source == eth.src && sink.source_port == 49_152);
    assert(sink.destination == eth.dst && sink.destination_port == 500 && sink.ingress_matches);

    bound.close();
    update_udp_endpoints();
    master.start_test();
    station.set_master(ObjectRef!BaseInterface(master), 0);
    assert(station.flags & ObjectFlags.slave);
    assert(!udp_open(&station_local, null, &sink.recv, station));
    master.stop_test();
    assert(station.flags & ObjectFlags.slave);
    station.set_master(ObjectRef!BaseInterface.init, 0);
    assert(!(station.flags & ObjectFlags.slave));
    station.stop_test();
    Collection!TestEtherStation().remove(master);
    Collection!TestEtherStation().remove(station);
    free(master);
    free(station);

    // a datagram's class rides its frame, and the egress answers readiness and room for it
    static struct TxProbe
    {
        PCP pcp;
        size_t sent;
        void tx(const(Packet)* p, BaseInterface, PacketDirection, void*) nothrow @nogc
        {
            pcp = p.pcp;
            ++sent;
        }
    }
    TxProbe probe;
    TestEtherStation egress = Collection!TestEtherStation().create("ether-test-egress");
    egress.start_test();
    PacketFilter outgoing = PacketFilter(PacketType.ethernet, PacketDirection.outgoing);
    egress.subscribe(&probe.tx, outgoing);
    InetAddress egress_local = InetAddress(egress.mac.b, 600);
    InetAddress peer = InetAddress(local_b.b, 700);
    UDPEndpoint* sender = udp_open(&egress_local, null, &sink.recv, egress);
    assert(sender);
    assert(sender.frame_room(peer) == 1500 - ow_transport_header_size - UdpHeader.sizeof);
    assert(sender.tx_ready(peer, PCP.bk));
    ubyte[4] datagram = [5, 6, 7, 8];
    assert(sender.sendto(datagram[], peer, PCP.vo) == datagram.length);
    assert(probe.sent == 1 && probe.pcp == PCP.vo);

    // an endpoint opened by local address finds the station it sends from
    assert(egress.mtu(512) is null);
    InetAddress by_mac = InetAddress(egress.mac.b, 601);
    UDPEndpoint* unbound = udp_open(&by_mac, null, &sink.recv);
    assert(unbound && unbound.egress_iface(peer) is egress);
    assert(unbound.frame_room(peer) == 512 - ow_transport_header_size - UdpHeader.sizeof);
    assert(unbound.sendto(datagram[], peer, PCP.ca) == datagram.length && probe.sent == 2 && probe.pcp == PCP.ca);
    unbound.close();

    egress.unsubscribe(&probe.tx);
    sender.close();
    egress.stop_test();
    Collection!TestEtherStation().remove(egress);
    free(egress);

    ephemeral.close();
    wildcard.close();
    update_udp_endpoints();

    // a point-to-point link: ports ride ahead of the payload, unless one service owns the link
    static final class TestLink : BaseInterface
    {
        enum type_name = "udp-test-link";
    nothrow @nogc:

        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!TestLink, id, flags);
            _mtu = 256;
            _state = State.running;
            set_link(true);
        }
        void dedicate()
        {
            _caps = InterfaceCaps.dedicated;
        }
        void stop_test()
        {
            _state = State.destroyed;
        }
        void retiring(bool on)
        {
            _state = on ? State.destroying : State.running;
        }
        override int transmit(Packet* packet, MessageCallback, const(QueuePolicy)*)
        {
            scope (exit) packet_free(packet);
            sent.clear();
            sent ~= cast(const(ubyte)[])packet.data;
            text = packet.hdr!RawFrame().is_text;
            return 0;
        }
        void receive(const(ubyte)[] frame)
        {
            StackPacket p;
            p.init!RawFrame(frame);
            incoming_packet(&p.packet);
        }
        Array!ubyte sent;
        bool text;
    }

    static struct LinkSink
    {
        Array!ubyte got;
        InetAddress source;
        size_t received;
        void recv(UDPEndpoint*, const(void)[] data, ref UDPReceiveInfo info) nothrow @nogc
        {
            ++received;
            got.clear();
            got ~= cast(const(ubyte)[])data;
            source = info.source;
        }
        void input(Packet* packet, BaseInterface link) nothrow @nogc
        {
            link_input(packet, link);
        }
    }

    TestLink link = Collection!TestLink().create("udp-test-link");
    LinkSink link_sink;
    assert(register_frame_handler(PacketType.raw, &link_sink.input));
    scope (exit) unregister_frame_handler(PacketType.raw);
    InetAddress at = InetAddress.link(link.scope_id, 4827);
    InetAddress far = InetAddress.link(link.scope_id, 4828);
    UDPEndpoint* ported = udp_open(&at, null, &link_sink.recv);
    assert(ported && ported.local == at && ported.egress_iface(far) is link);
    assert(!udp_open(&at, null, &link_sink.recv), "one endpoint per port");
    InetAddress no_port = InetAddress.link(link.scope_id, 0);
    InetAddress no_link = InetAddress.link(0, 4827);
    assert(!udp_open(&no_port, null, &link_sink.recv) && !udp_open(&no_link, null, &link_sink.recv));
    assert(ported.frame_room(far) == 256 - 4);
    assert(ported.sendto(datagram[], far) == datagram.length);
    assert(link.sent[] == [0x12, 0xDC, 0x12, 0xDB, 5, 6, 7, 8]);

    static immutable ubyte[6] to_us = [0x12, 0xDB, 0x12, 0xDC, 9, 10];
    static immutable ubyte[6] to_other = [0x12, 0xDD, 0x12, 0xDC, 9, 10];
    link.receive(to_us[]);
    assert(link_sink.received == 1 && link_sink.got[] == [9, 10] && link_sink.source == far);
    link.receive(to_other[]);
    link.receive(to_us[0 .. 3]);
    assert(link_sink.received == 1, "another port's datagram and a runt are not ours");
    ported.close();
    update_udp_endpoints();

    // a handler that closes and rebinds its port mid-receive does not get the same datagram again
    static struct Rebinder
    {
        InetAddress at;
        UDPEndpoint* replacement;
        size_t calls;
        void recv(UDPEndpoint* ep, const(void)[], ref UDPReceiveInfo) nothrow @nogc
        {
            ++calls;
            if (replacement)
                return;
            ep.close();
            replacement = udp_open(&at, null, &recv);
        }
    }
    Rebinder rebinder = Rebinder(at);
    UDPEndpoint* first = udp_open(&at, null, &rebinder.recv);
    UDPEndpoint* neighbour = udp_open(&far, null, &link_sink.recv);
    assert(first && neighbour);
    link.receive(to_us[]);
    assert(rebinder.calls == 1 && rebinder.replacement, "one delivery, to the endpoint chosen before the call");
    link.receive(to_us[]);
    assert(rebinder.calls == 2 && link_sink.received == 1);
    rebinder.replacement.close();
    neighbour.close();
    update_udp_endpoints();

    // destroy() has signalled, but an asynchronous shutdown keeps the link registered
    link.retiring(true);
    assert(interface_for_scope(link.scope_id) is link && !udp_open(&at, null, &link_sink.recv), "a retiring link takes no bind");
    link.retiring(false);

    // a master cannot switch a link datagram, so a slaved link still terminates it
    TestEtherStation bridge = Collection!TestEtherStation().create("udp-test-link-master");
    bridge.start_test();
    UDPEndpoint* enslaved = udp_open(&at, null, &link_sink.recv);
    assert(enslaved);
    link.set_master(ObjectRef!BaseInterface(bridge), 0);
    assert(link.flags & ObjectFlags.slave);
    size_t heard = link_sink.received;
    link.receive(to_us[]);
    assert(link_sink.received == heard + 1, "a slaved link delivers its datagrams locally");
    assert(enslaved.sendto(datagram[], far) == datagram.length);
    link.set_master(ObjectRef!BaseInterface.init, 0);
    enslaved.close();
    update_udp_endpoints();
    bridge.stop_test();
    Collection!TestEtherStation().remove(bridge);
    free(bridge);

    link.dedicate();
    assert(!udp_open(&at, &far, &link_sink.recv), "a dedicated link's one port is both ends'");
    UDPEndpoint* owner = udp_open(&at, &at, &link_sink.recv);
    assert(owner && !udp_open(&far, null, &link_sink.recv), "a dedicated link serves one endpoint");
    assert(owner.frame_room(at) == 256);
    owner.text(true);
    assert(owner.send(datagram[]) == datagram.length && link.sent[] == datagram[] && link.text);
    size_t before = link_sink.received;
    link.receive(to_us[]);
    assert(link_sink.received == before + 1 && link_sink.got[] == to_us[] && link_sink.source == at);
    owner.close();
    update_udp_endpoints();

    UDPEndpoint* loose = udp_open(&at, null, &link_sink.recv);
    assert(loose);
    link.sent.clear();
    assert(loose.sendto(datagram[], far) == 0 && link.sent.length == 0, "a dedicated link sends on its one port only");
    assert(loose.sendto(datagram[], at) == datagram.length && link.sent[] == datagram[]);
    loose.close();
    update_udp_endpoints();
    link.stop_test();
    Collection!TestLink().remove(link);
    free(link);
}
