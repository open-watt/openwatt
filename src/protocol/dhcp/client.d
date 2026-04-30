module protocol.dhcp.client;

import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat;
import urt.rand;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.expression : NamedArgument;
import manager.system : system_hostname = hostname;

import protocol.dhcp.message;
import protocol.ip.address;
import protocol.ip.route;
import protocol.ip.stack : IPv4Header, IpProtocol;

import router.iface;
import router.iface.mac;
import router.iface.packet;

version = DebugDHCP;

nothrow @nogc:


class DHCPClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("add-default-route", add_default_route));
nothrow @nogc:

    enum type_name = "dhcp-client";
    enum path = "/protocol/dhcp/client";
    enum collection_id = CollectionType.dhcp_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DHCPClient, id, flags);
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure
        => _iface;
    final const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_iface is value)
            return null;
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&incoming_packet);
            _subscribed = false;
        }
        _iface = value;
        restart();
        return null;
    }

    final bool add_default_route() const pure
        => _add_default_route;
    final void add_default_route(bool value)
    {
        if (_add_default_route == value)
            return;
        _add_default_route = value;
        restart();
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _iface !is null;

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _iface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ip4), null);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }

        MonoTime now = getTime();

        if (_phase == Phase.init_)
        {
            begin_discover(now);
            return CompletionStatus.continue_;
        }

        if (_phase == Phase.bound)
        {
            apply_lease();
            return CompletionStatus.complete;
        }

        // selecting / requesting -- retransmit on timeout
        if (now >= _next_action)
        {
            if (_retry_count >= max_retries)
            {
                version (DebugDHCP)
                    log.warning("giving up after ", _retry_count, " retries; will retry from INIT");
                begin_discover(now);
                return CompletionStatus.continue_;
            }

            if (_phase == Phase.selecting)
                send_discover();
            else if (_phase == Phase.requesting)
                send_request_select();

            ++_retry_count;
            _next_action = now + retry_backoff(_retry_count);
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        bool held_lease = _phase == Phase.bound || _phase == Phase.renewing || _phase == Phase.rebinding;
        if (held_lease && _iface && _iface.running && _server_id != IPAddr.any)
            send_release();

        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&incoming_packet);
            _subscribed = false;
        }

        release_lease();

        _phase = Phase.init_;
        _xid = 0;
        _retry_count = 0;

        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        MonoTime now = getTime();

        // HACK: poll system_hostname for changes; manager.system has no signal yet.
        // On change while bound, fire an early renew so the server picks up the new option 12.
        if (_phase == Phase.bound && _sent_hostname[] != system_hostname[])
        {
            _phase = Phase.renewing;
            _retry_count = 0;
            _next_action = now;
        }

        // T1 reached: try to renew unicast to server
        if (_phase == Phase.bound && now >= _t1_deadline)
        {
            _phase = Phase.renewing;
            _retry_count = 0;
            _next_action = now;
        }

        // T2 reached: rebind via broadcast
        if (_phase == Phase.renewing && now >= _t2_deadline)
        {
            _phase = Phase.rebinding;
            _retry_count = 0;
            _next_action = now;
        }

        // Lease expired: drop everything and start over
        if ((_phase == Phase.renewing || _phase == Phase.rebinding) && now >= _lease_deadline)
        {
            version (DebugDHCP)
                log.warning("lease expired without renewal; restarting");
            release_lease();
            restart();
            return;
        }

        if ((_phase == Phase.renewing || _phase == Phase.rebinding) && now >= _next_action)
        {
            if (_phase == Phase.renewing)
                send_request_renew();
            else
                send_request_rebind();
            ++_retry_count;
            // halve the remaining time to T2/lease, RFC 2131 4.4.5
            MonoTime deadline = _phase == Phase.renewing ? _t2_deadline : _lease_deadline;
            long remaining_s = (deadline - now).as!"seconds";
            long delay_s = remaining_s / 2;
            if (delay_s < 60)
                delay_s = 60;
            _next_action = now + delay_s.seconds;
        }
    }

private:
    enum Phase : ubyte
    {
        init_,
        selecting,      // DISCOVER sent, awaiting OFFER
        requesting,     // REQUEST sent (selecting state), awaiting ACK
        bound,          // lease active
        renewing,       // T1 reached, unicast REQUEST to server
        rebinding,      // T2 reached, broadcast REQUEST
    }

    enum size_t max_retries = 5;

    ObjectRef!BaseInterface _iface;
    bool _add_default_route = true;
    bool _subscribed;

    Phase _phase;
    uint _xid;
    uint _retry_count;
    MonoTime _request_started;
    MonoTime _next_action;

    String _sent_hostname;      // last hostname we put in option 12; drives proactive renew on change

    // current offer / lease state
    IPAddr _offered_addr;
    IPAddr _server_id;
    IPAddr _subnet_mask;
    IPAddr _gateway;            // 0.0.0.0 if none

    Duration _lease_duration;
    MonoTime _t1_deadline;
    MonoTime _t2_deadline;
    MonoTime _lease_deadline;

    // dynamic objects we own (created on bind, destroyed on release)
    ObjectRef!IPAddress _our_address;
    ObjectRef!IPRoute _network_route;
    ObjectRef!IPRoute _default_route;

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void begin_discover(MonoTime now)
    {
        _phase = Phase.selecting;
        _xid = rand();
        _request_started = now;
        _retry_count = 1;
        _offered_addr = IPAddr.any;
        _server_id = IPAddr.any;
        send_discover();
        _next_action = now + retry_backoff(_retry_count);
    }

    static Duration retry_backoff(uint attempt) pure
    {
        // 4, 8, 16, 32, 64 seconds
        uint secs = 4u << (attempt > 4 ? 4 : attempt - 1);
        return secs.seconds;
    }

    ushort secs_field() const
    {
        long elapsed = (getTime() - _request_started).as!"seconds";
        if (elapsed < 0) return 0;
        if (elapsed > ushort.max) return ushort.max;
        return cast(ushort)elapsed;
    }

    // ---- packet build ----

    void send_discover()
    {
        version (DebugDHCP)
            log.debug_("tx DISCOVER xid=", _xid);

        DhcpBuild b;
        b.start(BootpRequest, _iface.mac, _xid, secs_field, true);
        b.add_message_type(DhcpMessageType.discover);
        b.add_client_identifier(_iface.mac);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        b.transmit(_iface, IPAddr.any, IPAddr.broadcast, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    void send_request_select()
    {
        version (DebugDHCP)
            log.debug_("tx REQUEST (selecting) xid=", _xid, " offered=", _offered_addr, " server=", _server_id);

        DhcpBuild b;
        b.start(BootpRequest, _iface.mac, _xid, secs_field, true);
        b.add_message_type(DhcpMessageType.request);
        b.add_client_identifier(_iface.mac);
        b.add_addr_option(DhcpOption.requested_address, _offered_addr);
        b.add_addr_option(DhcpOption.server_id, _server_id);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        b.transmit(_iface, IPAddr.any, IPAddr.broadcast, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    void send_request_renew()
    {
        version (DebugDHCP)
            log.debug_("tx REQUEST (renew) xid=", _xid, " ciaddr=", _offered_addr, " server=", _server_id);

        DhcpBuild b;
        b.start(BootpRequest, _iface.mac, _xid, secs_field, false);
        b.set_ciaddr(_offered_addr);
        b.add_message_type(DhcpMessageType.request);
        b.add_client_identifier(_iface.mac);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        // TODO: ARP-resolve _server_id MAC; for now broadcast renew too.
        b.transmit(_iface, _offered_addr, _server_id, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    void send_request_rebind()
    {
        version (DebugDHCP)
            log.debug_("tx REQUEST (rebind) xid=", _xid, " ciaddr=", _offered_addr);

        DhcpBuild b;
        b.start(BootpRequest, _iface.mac, _xid, secs_field, true);
        b.set_ciaddr(_offered_addr);
        b.add_message_type(DhcpMessageType.request);
        b.add_client_identifier(_iface.mac);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        b.transmit(_iface, _offered_addr, IPAddr.broadcast, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    void add_hostname(ref DhcpBuild b)
    {
        if (system_hostname[].length == 0)
            return;
        b.add_string_option(DhcpOption.hostname, system_hostname[]);
        _sent_hostname = system_hostname;
    }

    static void add_vendor_class_id(ref DhcpBuild b)
    {
        b.add_string_option(DhcpOption.vendor_class_id, "OpenWatt");
    }

    void send_release()
    {
        version (DebugDHCP)
            log.debug_("tx RELEASE ciaddr=", _offered_addr, " server=", _server_id);

        // RFC 2131 §4.4.4: RELEASE is unicast to the server with ciaddr set.
        // TODO: ARP-resolve _server_id MAC; for now broadcast at L2 (same shortcut as renew).
        DhcpBuild b;
        b.start(BootpRequest, _iface.mac, rand(), 0, false);
        b.set_ciaddr(_offered_addr);
        b.add_message_type(DhcpMessageType.release);
        b.add_client_identifier(_iface.mac);
        b.add_addr_option(DhcpOption.server_id, _server_id);
        b.finish();
        b.transmit(_iface, _offered_addr, _server_id, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    // ---- packet parse ----

    void incoming_packet(ref const Packet pkt, BaseInterface, PacketDirection dir, void* user_data)
    {
        if (!(_state == State.starting || _state == State.running))
            return;
        if (pkt.type != PacketType.ethernet || pkt.eth.ether_type != EtherType.ip4)
            return;

        const(ubyte)[] frame = cast(const(ubyte)[])pkt.data;
        if (frame.length < IPv4Header.sizeof + UdpHeader.sizeof + DhcpHeader.sizeof)
            return;

        const ip = cast(const IPv4Header*)frame.ptr;
        if (ip.version_ != 4 || ip.ihl < 5)
            return;
        size_t ip_hdr_len = ip.ihl * 4;
        size_t ip_total = (size_t(ip.total_length[0]) << 8) | ip.total_length[1];
        if (ip_total < ip_hdr_len + UdpHeader.sizeof || ip_total > frame.length)
            return;
        if (ip.protocol != IpProtocol.udp)
            return;

        const u = cast(const UdpHeader*)(frame.ptr + ip_hdr_len);
        ushort src_port = (ushort(u.src_port[0]) << 8) | u.src_port[1];
        ushort dst_port = (ushort(u.dst_port[0]) << 8) | u.dst_port[1];
        if (src_port != DhcpServerPort || dst_port != DhcpClientPort)
            return;

        ushort udp_len = (ushort(u.length[0]) << 8) | u.length[1];
        if (udp_len < UdpHeader.sizeof || ip_hdr_len + udp_len > frame.length)
            return;

        const(ubyte)[] dhcp = frame[ip_hdr_len + UdpHeader.sizeof .. ip_hdr_len + udp_len];
        if (dhcp.length < DhcpHeader.sizeof)
            return;

        const dh = cast(const DhcpHeader*)dhcp.ptr;
        if (dh.op != BootpReply || dh.htype != HType_Ethernet || dh.hlen != 6)
            return;

        uint xid = (uint(dh.xid[0]) << 24) | (uint(dh.xid[1]) << 16) | (uint(dh.xid[2]) << 8) | dh.xid[3];
        if (xid != _xid)
            return;

        if (dh.chaddr[0 .. 6] != _iface.mac.b[])
            return;

        // verify magic cookie
        if (dh.magic[0] != 0x63 || dh.magic[1] != 0x82 || dh.magic[2] != 0x53 || dh.magic[3] != 0x63)
            return;

        DhcpParse p;
        p.options = dhcp[DhcpHeader.sizeof .. $];

        DhcpMessageType msg_type;
        if (!p.message_type(msg_type))
            return;

        version (DebugDHCP)
            log.debug_("rx ", msg_type, " xid=", _xid, " yiaddr=", IPAddr(dh.yiaddr));

        switch (msg_type)
        {
            case DhcpMessageType.offer:
                handle_offer(IPAddr(dh.yiaddr), p);
                return;
            case DhcpMessageType.ack:
                handle_ack(IPAddr(dh.yiaddr), p);
                return;
            case DhcpMessageType.nak:
                handle_nak();
                return;
            default:
                return;
        }
    }

    void handle_offer(IPAddr yiaddr, ref DhcpParse p)
    {
        if (_phase != Phase.selecting)
            return;
        if (yiaddr == IPAddr.any)
            return;

        IPAddr server;
        if (!p.server_id(server))
            return;

        _offered_addr = yiaddr;
        _server_id = server;
        _phase = Phase.requesting;
        _retry_count = 1;
        send_request_select();
        _next_action = getTime() + retry_backoff(_retry_count);
    }

    void handle_ack(IPAddr yiaddr, ref DhcpParse p)
    {
        // Renewal/rebinding ACKs may carry the same yiaddr; selecting ACK must.
        if (_phase == Phase.requesting && yiaddr == IPAddr.any)
            return;

        IPAddr mask, gw;
        Duration lease;
        if (!p.subnet_mask(mask) || !p.lease_time(lease))
        {
            version (DebugDHCP)
                log.warning("ACK missing subnet-mask or lease-time; ignoring");
            return;
        }
        p.router(gw);

        // Trust the offered yiaddr from selecting; for renew/rebind, server may echo our ciaddr
        if (yiaddr != IPAddr.any)
            _offered_addr = yiaddr;
        IPAddr server;
        if (p.server_id(server))
            _server_id = server;

        _subnet_mask = mask;
        _gateway = gw;
        _lease_duration = lease;

        long lease_s = lease.as!"seconds";
        Duration t1, t2;
        if (!p.renewal_time(t1))
            t1 = (lease_s / 2).seconds;
        if (!p.rebinding_time(t2))
            t2 = (lease_s * 7 / 8).seconds;

        MonoTime now = getTime();
        _t1_deadline = now + t1;
        _t2_deadline = now + t2;
        _lease_deadline = now + lease;

        bool was_bound = _phase == Phase.bound || _phase == Phase.renewing || _phase == Phase.rebinding;
        _phase = Phase.bound;

        version (DebugDHCP)
            log.info("lease bound: ", _offered_addr, "/", subnet_prefix_len(mask),
                     " gw=", gw, " server=", _server_id, " lease=", lease.as!"seconds", "s");

        if (!was_bound)
            apply_lease();
    }

    void handle_nak()
    {
        version (DebugDHCP)
            log.warning("rx NAK; restarting from INIT");
        release_lease();
        _phase = Phase.init_;
        _xid = 0;
        _retry_count = 0;
        _next_action = getTime();
    }

    // ---- lease lifecycle ----

    void apply_lease()
    {
        ubyte plen = subnet_prefix_len(_subnet_mask);
        IPNetworkAddress net_addr = IPNetworkAddress(_offered_addr, plen);

        // /protocol/ip/address — dynamic
        if (!_our_address)
        {
            const(char)[] addr_name = Collection!IPAddress().generate_name(name[]);
            _our_address = Collection!IPAddress().create(
                addr_name,
                ObjectFlags.dynamic,
                NamedArgument("address", net_addr),
                NamedArgument("interface", cast(BaseInterface)_iface));
            if (!_our_address)
                log.error("failed to create dynamic IPAddress");
        }

        // connected route for the subnet
        if (!_network_route && plen < 32)
        {
            IPNetworkAddress subnet = IPNetworkAddress(_offered_addr & _subnet_mask, plen);
            const(char)[] rt_name = Collection!IPRoute().generate_name(name[]);
            _network_route = Collection!IPRoute().create(
                rt_name,
                ObjectFlags.dynamic,
                NamedArgument("destination", subnet),
                NamedArgument("out-interface", cast(BaseInterface)_iface));
            if (!_network_route)
                log.error("failed to create dynamic network route");
        }

        // optional default route
        if (_add_default_route && _gateway != IPAddr.any && !_default_route)
        {
            IPNetworkAddress default_dst = IPNetworkAddress(IPAddr.any, 0);
            const(char)[] rt_name = Collection!IPRoute().generate_name(tconcat(name[], ".default"));
            _default_route = Collection!IPRoute().create(
                rt_name,
                ObjectFlags.dynamic,
                NamedArgument("destination", default_dst),
                NamedArgument("gateway", _gateway));
            if (!_default_route)
                log.error("failed to create dynamic default route");
        }
    }

    void release_lease()
    {
        if (auto a = _our_address.get())
            a.destroy();
        _our_address = null;
        if (auto r = _network_route.get())
            r.destroy();
        _network_route = null;
        if (auto r = _default_route.get())
            r.destroy();
        _default_route = null;
    }
}
