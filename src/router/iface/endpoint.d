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

bool parse_ow_transport(ref const Packet packet, out ubyte protocol, out const(ubyte)[] segment)
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

alias UDPRecvHandler = void delegate(UDPEndpoint* ep, const(void)[] data, ref const UDPReceiveInfo info) nothrow @nogc;
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

void ether_transport_input(ref Packet packet, BaseInterface iface)
{
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
    ep._family = family;
    ep._remote = remote ? *remote : InetAddress();
    ep._connected = remote !is null;
    ep._on_recv = on_recv;

    if (family == AddressFamily.ether)
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

    InetAddress local()
    {
        if (_family == AddressFamily.ether)
            return _ether.local_address();
        static if (has_ip)
            return _ip.local_address();
        else
            return InetAddress();
    }

    InetAddress remote() const pure
        => _remote;

    BaseInterface egress_iface()
    {
        if (_family == AddressFamily.ether)
            return _ether.egress_iface(_remote);
        static if (has_ip)
            return _ip.egress_iface(_remote);
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
            return _family != AddressFamily.ether && _ip.join(group, interface_);
        else
            return false;
    }

    bool outbound_interface(IPAddr interface_)
    {
        static if (has_ip)
            return _family != AddressFamily.ether && _ip.outbound_interface(interface_);
        else
            return false;
    }

    bool enable_broadcast()
    {
        if (_family == AddressFamily.ether)
            return _ether.enable_broadcast();
        static if (has_ip)
            return _ip.enable_broadcast();
        else
            return false;
    }

    ptrdiff_t send(scope const(void)[] data)
    {
        if (_closing || !_connected)
            return 0;
        return sendto_backend(data, _remote);
    }

    ptrdiff_t sendto(scope const(void)[] data, InetAddress dst)
    {
        if (_closing || dst.family != _family || (_connected && dst != _remote))
            return 0;
        return sendto_backend(data, dst);
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
            _ip.close();
    }

private:

    void deliver_ether(ref const Packet packet, const(ubyte)[] segment, EthernetStation station)
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

        BaseInterface egress_iface(InetAddress)
            => _iface.get;

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

        ptrdiff_t sendto(scope const(void)[] data, InetAddress dst)
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

            if (!_wildcard)
            {
                EthernetStation station = _iface.get;
                if (station)
                {
                    if (!station.running || (station.flags & ObjectFlags.slave))
                        return 0;
                    return emit(station, mac, ow) ? data.length : 0;
                }
                if (EthernetStation learned = ether_neighbour_lookup(mac))
                    if (learned.mac == _local)
                        return emit(learned, mac, ow) ? data.length : 0;
                bool sent;
                foreach_ether_station((EthernetStation candidate)
                {
                    if (candidate.running && candidate.mac == _local && emit(candidate, mac, ow))
                        sent = true;
                });
                return sent ? data.length : 0;
            }

            if (EthernetStation station = ether_neighbour_lookup(mac))
                return emit(station, mac, ow) ? data.length : 0;
            bool sent;
            foreach_ether_station((EthernetStation station)
            {
                if (station.running && emit(station, mac, ow))
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

        void deliver(UDPEndpoint* owner, ref const Packet packet, const(ubyte)[] segment, EthernetStation station)
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
        bool emit(EthernetStation station, MACAddress dst, const(ubyte)[] frame)
        {
            ushort mtu = station.actual_mtu;
            if (mtu && frame.length > mtu)
                return false;
            Packet packet;
            ref ether = packet.init!Ethernet(frame);
            ether.dst = dst;
            ether.src = station.mac;
            ether.ether_type = EtherType.ow;
            return station.forward(packet) >= 0;
        }

        ObjectRef!EthernetStation _iface;
        Array!MACAddress* _groups;
        MACAddress _local;
        ushort _local_port;
        bool _wildcard;
    }

    bool reclaimable() const
    {
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
            _ip.release();
    }

    ptrdiff_t sendto_backend(scope const(void)[] data, InetAddress dst)
    {
        if (_family == AddressFamily.ether)
            return _ether.sendto(data, dst);
        static if (has_ip)
            return _ip.sendto(data, dst);
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
        static if (has_ip)
            IPUDPState _ip;
    }
}


void udp_deliver(UDPEndpoint* endpoint, const(void)[] data, ref const UDPReceiveInfo info)
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

        void recv(UDPEndpoint*, const(void)[] data, ref const UDPReceiveInfo info) nothrow @nogc
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

        void input(ref Packet packet, BaseInterface iface) nothrow @nogc
        {
            ether_transport_input(packet, iface);
        }
    }

    class TestEtherStation : BridgeInterface
    {
nothrow @nogc:

        this(CID id)
        {
            super(id);
        }

        void receive(ref Packet packet)
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

    Packet packet;
    ref eth = packet.init!Ethernet(ow);
    eth.dst = MACAddress(0x02, 0x13, 0x37, 0xAA, 0xBB, 0x64);
    eth.src = MACAddress(0x02, 0x13, 0x37, 0xCC, 0xDD, 0x65);
    eth.ether_type = EtherType.ow;

    ubyte protocol;
    const(ubyte)[] segment;
    assert(parse_ow_transport(packet, protocol, segment));
    assert(protocol == TransportProto.udp);
    assert(segment == ow[ow_transport_header_size .. $]);
    assert(loadBigEndian(cast(const(ushort)*)ow.ptr) == ow_transport_discriminator(TransportProto.udp));

    UDPEndpoint ip_endpoint;
    ip_endpoint._family = AddressFamily.ipv4;
    ip_endpoint.deliver_ether(packet, segment, null);

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

    TestEtherStation station = alloc!TestEtherStation(CID(0xF001));
    BridgeInterface master = alloc!BridgeInterface(CID(0xF002));
    sink.expected_ingress = station;
    InetAddress station_local = InetAddress(station.mac.b, 500);
    UDPEndpoint* bound = udp_open(&station_local, null, &sink.recv, station);
    assert(bound);

    assert(register_frame_handler(PacketType.ethernet, &sink.input));
    eth.dst = station.mac;
    station.receive(packet);
    unregister_frame_handler(PacketType.ethernet);
    assert(sink.received == 1 && sink.payload == [1, 2, 3, 4]);
    assert(sink.source == eth.src && sink.source_port == 49_152);
    assert(sink.destination == eth.dst && sink.destination_port == 500 && sink.ingress_matches);

    bound.close();
    update_udp_endpoints();
    assert(master.add_member(station));
    assert(station.flags & ObjectFlags.slave);
    assert(!udp_open(&station_local, null, &sink.recv, station));
    station.set_master(null, 0);
    free(master);
    free(station);

    ephemeral.close();
    wildcard.close();
    update_udp_endpoints();
}
