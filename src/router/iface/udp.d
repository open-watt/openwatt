module router.iface.udp;

// Raw-packet interface over UDP datagrams: one datagram = one packet, peers addressed per-frame via the
// UDPFrame header.
//
// Operating modes:
//   - unicast remote: point-to-point; the endpoint is opened connected, so rx is filtered to that peer
//   - broadcast/multicast remote, or no remote: multi-drop; the endpoint is opened unconnected, datagrams
//     arrive from any peer with the source carried in the UDPFrame, and tx may address peers per-frame
//
// The peer may be any address family, including ether ([mac]:port over the OW ethertype), which is
// why this is a router-layer interface: UDP datagrams ride raw ethernet with no IP configured, so
// ip-less tiers get the interface too. With the ip stack linked, udp_open dispatches every family;
// without it, the interface lowers straight onto the ether datagram service and carries ether peers.
//
// TODO: broadcast tx needs SO_BROADCAST and multicast rx needs a group join; UDPEndpoint exposes neither yet
// TODO: l2mtu assumes a 1500-byte link MTU; query the real path MTU from the endpoint when it can report one
// TODO: raw-frame compatibility. rx delivers UDPFrame, so PacketFilter(raw) consumers that sit happily on
//   ASH or a CPCEndpoint see nothing here (tx already accepts raw). Reconcile along CPC's trunk/leaf split:
//   [ ] connected mode (unicast remote) should deliver RawFrame on rx: the peer is fixed by configuration,
//       so the UDPFrame header adds nothing, and the interface becomes a drop-in raw pipe. Multi-drop keeps
//       UDPFrame; a consumer with no notion of peers can't sit on a multi-drop segment anyway.
//   [ ] if a consumer ever needs per-peer sessions over one socket: peer sub-interfaces bound to a
//       multi-drop trunk, each presenting one peer as a raw pipe (the CPCEndpoint shape), possibly spawned
//       dynamically on first datagram from an unknown peer like the TCP server spawns streams.

import urt.inet;
import urt.lifetime;
import urt.socket;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.features;
import manager.plugin;

import router.iface;
import router.iface.endpoint;
import router.iface.ethernet;

static if (has_ip)
    import protocol.ip;

nothrow @nogc:


// Peer address header: the datagram source on rx, the destination on tx (unspecified = configured remote).
struct UDPFrame
{
nothrow @nogc:
    enum Type = PacketType.udp;

    ubyte[16] addr;
    ushort port;
    AddressFamily family = AddressFamily.unspecified;

    InetAddress address() const
    {
        if (family == AddressFamily.ipv4)
            return InetAddress(IPAddr(addr[0 .. 4]), port);
        if (family == AddressFamily.ipv6)
        {
            IPv6Addr a;
            (cast(ubyte*)a.s.ptr)[0 .. 16] = addr[];
            return InetAddress(a, port);
        }
        if (family == AddressFamily.ether)
            return InetAddress(*cast(const(ubyte)[6]*)addr.ptr, port);
        return InetAddress();
    }

    void address(ref const InetAddress a) pure
    {
        family = a.family;
        if (a.family == AddressFamily.ipv4)
        {
            addr[0 .. 4] = a._a.ipv4.addr.b[];
            port = a._a.ipv4.port;
        }
        else if (a.family == AddressFamily.ipv6)
        {
            addr[] = (cast(const(ubyte)*)a._a.ipv6.addr.s.ptr)[0 .. 16];
            port = a._a.ipv6.port;
        }
        else if (a.family == AddressFamily.ether)
        {
            addr[0 .. 6] = a._a.ether.addr[];
            port = a._a.ether.port;
        }
    }
}

class UDPInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("local-host", local_host),
                                 Prop!("local-port", local_port),
                                 Prop!("remote-host", remote_host),
                                 Prop!("remote-port", remote_port));
nothrow @nogc:

    enum type_name = "udp";
    enum path = "/interface/udp";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!UDPInterface, id, flags);
        _max_l2mtu = max_udp_payload;
        l2mtu = default_payload_v4;
        mark_set!(typeof(this), "max-l2mtu")();
    }

    // Properties...

    final inout(EthernetStation) iface() inout pure
        => _iface.get;
    final void iface(EthernetStation value)
    {
        if (_bound == (value !is null) && _iface.get is value)
            return;
        if (_subscribed)
        {
            if (EthernetStation s = _iface.get)
                s.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        _iface = value;
        _bound = value !is null;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    final ref const(String) local_host() const pure
        => _local_host;
    final void local_host(String value)
    {
        if (value == _local_host)
            return;
        _local_host = value.move;
        mark_set!(typeof(this), "local-host")();
        restart();
    }

    final ushort local_port() const pure
        => _local_port;
    final void local_port(ushort value)
    {
        if (value == _local_port)
            return;
        _local_port = value;
        mark_set!(typeof(this), "local-port")();
        restart();
    }

    final ref const(String) remote_host() const pure
        => _remote_host;
    final void remote_host(String value)
    {
        if (value == _remote_host)
            return;
        _remote_host = value.move;
        mark_set!(typeof(this), "remote-host")();
        restart();
    }

    final ushort remote_port() const pure
        => _remote_port;
    final void remote_port(ushort value)
    {
        if (value == _remote_port)
            return;
        _remote_port = value;
        mark_set!(typeof(this), "remote-port")();
        restart();
    }

protected:

    override bool validate() const pure
        => _remote_host.empty == (_remote_port == 0) && (!_remote_host.empty || _local_port != 0);

    override CompletionStatus startup()
    {
        _remote = InetAddress();
        bool have_remote = false;
        bool multidrop = false;
        if (!_remote_host.empty)
        {
            if (!resolve(_remote_host[], _remote_port, _remote))
            {
                log.error("failed to resolve remote '", _remote_host, "'");
                return CompletionStatus.error;
            }
            have_remote = true;
            if (_remote.family == AddressFamily.ipv4)
                multidrop = _remote._a.ipv4.addr.is_multicast || _remote._a.ipv4.addr == IPAddr.broadcast;
            else if (_remote.family == AddressFamily.ipv6)
                multidrop = _remote._a.ipv6.addr.is_multicast;
            else if (_remote.family == AddressFamily.ether)
                multidrop = MACAddress(_remote._a.ether.addr).is_multicast;
        }

        InetAddress local;
        bool have_local = false;
        if (!_local_host.empty)
        {
            if (!resolve(_local_host[], _local_port, local))
            {
                log.error("failed to resolve local '", _local_host, "'");
                return CompletionStatus.error;
            }
            have_local = true;
        }
        else if (_local_port != 0)
        {
            // wildcard local in the remote's family; the zero mac is ether's any-station
            if (_remote.family == AddressFamily.ether)
                local = InetAddress(MACAddress().b, _local_port);
            else
                local = _remote.family == AddressFamily.ipv6 ? InetAddress(IPv6Addr.any, _local_port)
                                                             : InetAddress(IPAddr.any, _local_port);
            have_local = true;
        }

        AddressFamily family = have_remote ? _remote.family : local.family;

        // a bound station is a dependency: wait for it, never degrade to a wildcard endpoint
        EthernetStation bind_station;
        if (_bound)
        {
            if (family != AddressFamily.ether)
            {
                log.error("interface= binds an ether-family peer; '", _remote_host, "' is not an ether address");
                return CompletionStatus.error;
            }
            bind_station = _iface.get;
            if (!bind_station || !bind_station.running)
                return CompletionStatus.continue_;
        }

        static if (has_ip)
        {
            // a unicast remote connects the endpoint (rx filtered to the peer); broadcast/multicast or no
            // remote leaves it unconnected so any peer can be heard - the multi-drop case
            const(InetAddress)* peer = have_remote && !multidrop ? &_remote : null;
            _ep = udp_open(have_local ? &local : null, peer, &on_recv, bind_station);
            if (!_ep)
            {
                log.error("failed to open UDP endpoint");
                return CompletionStatus.error;
            }
        }
        else
        {
            // ip-less tier: ether peers only, straight onto the router-layer datagram service
            if (family != AddressFamily.ether)
            {
                log.error("this build carries ether peers only; '", _remote_host, "' needs the IP stack");
                return CompletionStatus.error;
            }
            EthernetStation station = bind_station;
            if (!station && have_local && !local.addr_any)
            {
                station = find_ether_station(MACAddress(local._a.ether.addr));
                if (!station)
                {
                    log.error("no ethernet station with address ", local);
                    return CompletionStatus.error;
                }
            }
            bool connected = have_remote && !multidrop;
            _ether = ether_open(station, have_local ? local.port : 0, &on_ether_recv,
                                connected ? MACAddress(_remote._a.ether.addr) : MACAddress(),
                                connected ? _remote._a.ether.port : 0);
            if (!_ether)
            {
                log.error("failed to open ether datagram endpoint");
                return CompletionStatus.error;
            }
        }

        if (family == AddressFamily.ipv6 && _l2mtu == default_payload_v4)
            l2mtu = default_payload_v6;
        else if (family == AddressFamily.ether && _l2mtu == default_payload_v4)
            l2mtu = default_payload_ether;

        if (_bound)
        {
            bind_station.subscribe(&iface_state_change);
            _subscribed = true;
        }
        return CompletionStatus.complete;
    }

    override void online()
    {
        super.online();

        // a multi-drop endpoint has no single egress, so this only resolves for a connected peer
        BaseInterface egress;
        static if (has_ip)
            egress = _ep ? _ep.egress_iface : null;
        else
            egress = _ether ? _ether.iface : null;
        if (egress)
            set_link_speed(egress.tx_link_speed, egress.rx_link_speed);
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            if (EthernetStation s = _iface.get)
                s.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        static if (has_ip)
        {
            if (_ep)
            {
                _ep.close();
                _ep = null;
            }
        }
        else
        {
            if (_ether)
            {
                _ether.close();
                _ether = null;
            }
        }
        _remote = InetAddress();
        return CompletionStatus.complete;
    }

    override int transmit(ref Packet packet, MessageCallback callback = null, const(QueuePolicy)* queue_policy = null)
    {
        InetAddress dst = _remote;
        if (packet.type == PacketType.udp)
        {
            ref const frame = packet.hdr!UDPFrame;
            if (frame.family != AddressFamily.unspecified)
                dst = frame.address;
        }
        else if (packet.type != PacketType.raw)
        {
            add_tx_drop();
            return -1;
        }

        if (dst.family <= AddressFamily.unspecified || packet.data.length > actual_mtu)
        {
            add_tx_drop();
            return -1;
        }

        static if (has_ip)
        {
            if (!_ep || _ep.sendto(packet.data, dst) != packet.data.length)
            {
                add_tx_drop();
                return -1;
            }
        }
        else
        {
            const(InetAddress.Ether)* e = dst.as_ether;
            if (!_ether || !e || _ether.sendto(MACAddress(e.addr), e.port, packet.data) != packet.data.length)
            {
                add_tx_drop();
                return -1;
            }
        }
        add_tx_frame(packet.data.length);
        return 0;
    }

private:
    enum max_udp_payload = 65_507;
    enum default_payload_v4 = 1500 - 28; // 1500 link MTU less IPv4 + UDP headers
    enum default_payload_v6 = 1500 - 48;
    enum default_payload_ether = 1500 - 26; // ow framing + ether-transport + UDP headers

    ObjectRef!EthernetStation _iface;
    bool _bound;        // iface was configured; a detached ref must wait for rebind, not go wildcard
    bool _subscribed;
    String _local_host;
    String _remote_host;
    ushort _local_port;
    ushort _remote_port;
    InetAddress _remote;
    static if (has_ip)
        UDPEndpoint* _ep;
    else
        EtherEndpoint* _ether;

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    static bool resolve(const(char)[] host, ushort port, out InetAddress addr)
    {
        // literals first: mac (and v4/v6) parse without a resolver
        if (host.length && addr.fromString(host) == host.length && addr.family != AddressFamily.unspecified)
        {
            addr.port = port;
            return true;
        }

        AddressInfoResolver resolver;
        if (!host.get_address_info(tconcat(port), null, resolver))
            return false;
        AddressInfo info;
        if (!resolver.next_address(info))
            return false;
        addr = info.address;
        return true;
    }

    static if (has_ip)
    {
        void on_recv(UDPEndpoint*, const(void)[] data, ref const InetAddress from, MonoTime rx_time)
        {
            Packet packet;
            packet.init!UDPFrame(data, rx_time).address = from;
            incoming_packet(packet);
        }
    }
    else
    {
        void on_ether_recv(EtherEndpoint*, const(void)[] data, MACAddress src, ushort src_port, MonoTime rx_time)
        {
            Packet packet;
            packet.init!UDPFrame(data, rx_time).address = InetAddress(src.b, src_port);
            incoming_packet(packet);
        }
    }
}


unittest
{
    UDPFrame f;
    InetAddress v4 = InetAddress(IPAddr(192, 168, 1, 20), 502);
    f.address = v4;
    assert(f.family == AddressFamily.ipv4 && f.port == 502);
    assert(f.address == v4);

    InetAddress v6 = InetAddress(IPv6Addr.linkLocal_allNodes, 5353);
    f.address = v6;
    assert(f.family == AddressFamily.ipv6 && f.port == 5353);
    assert(f.address == v6);

    static immutable ubyte[6] kMac = [0x02, 0x13, 0x37, 0xAA, 0xBB, 0x64];
    InetAddress em = InetAddress(kMac, 7000);
    f.address = em;
    assert(f.family == AddressFamily.ether && f.port == 7000);
    assert(f.address == em);

    // a bound station that detaches holds the binding; only an explicit clear un-binds
    {
        import urt.mem.allocator : defaultAllocator;
        import router.iface.bridge : BridgeInterface;

        UDPInterface u = defaultAllocator().allocT!UDPInterface(CID(1));
        BridgeInterface b = defaultAllocator().allocT!BridgeInterface(CID(2));
        scope(exit) { defaultAllocator().freeT(b); defaultAllocator().freeT(u); }

        u.iface(b);
        assert(u._bound && u.iface is null);    // configured, but unresolvable: detached, not wildcard
        u.iface(null);
        assert(!u._bound);                      // the null-vs-detached ambiguity must not block the clear
    }
}
