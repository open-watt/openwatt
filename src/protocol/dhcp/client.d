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
import protocol.ip : IPv4Header, IPProtocol;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

//version = DebugDHCP;

nothrow @nogc:


final class DHCPClient : ActiveObject
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
        if (!dyn_cast!EthernetStation(value))
            return "interface must be an ethernet interface";
        if (_iface is value)
            return null;
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&incoming_packet);
            _subscribed = false;
        }
        _iface = value;
        mark_set!(typeof(this), "interface")();
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
        mark_set!(typeof(this), "add-default-route")();
        restart();
    }

    // HACK: poll the hostname; manager.system has no change signal yet. A change while bound renews early so the server sees the new option 12.
    void heartbeat(MonoTime now)
    {
        if (_phase == Phase.bound && _sent_hostname[] != system_hostname[])
            begin_exchange(Phase.renewing);
    }

protected:

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

        if (_phase == Phase.init_)
            begin_exchange(Phase.selecting);

        return _phase == Phase.bound ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        cancel_timers();

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
    enum long min_renew_interval_ms = 60_000;

    ObjectRef!BaseInterface _iface;

    // TODO: delete this hack, promote _iface to EthernetStation...
    EthernetStation station()
        => dyn_cast!EthernetStation(_iface.get);
    bool _add_default_route = true;
    bool _subscribed;
    bool _retransmit_armed;
    bool _lease_timer_armed;

    Phase _phase;
    uint _xid;
    uint _retry_count;
    MonoTime _request_started;

    String _sent_hostname;      // last hostname we put in option 12; drives proactive renew on change

    // current offer / lease state
    IPAddr _address;
    IPAddr _server_id;
    IPAddr _subnet_mask;
    IPAddr _gateway;            // 0.0.0.0 if none

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

    void abandon(const(char)[] why)
    {
        log.warning(why, "; restarting");
        release_lease();
        _phase = Phase.init_;
        restart();
    }

    // A REQUEST answering an OFFER continues the DISCOVER's exchange (RFC 2131 4.4.1); every other phase is a new one
    void begin_exchange(Phase phase)
    {
        MonoTime now = getTime();
        _phase = phase;
        _retry_count = 0;
        if (phase != Phase.requesting)
        {
            _xid = rand();
            _request_started = now;
        }
        if (phase == Phase.selecting)
        {
            _address = IPAddr.any;
            _server_id = IPAddr.any;
        }
        arm_retransmit(now);
    }

    void arm_retransmit(MonoTime when)
    {
        if (_retransmit_armed)
            g_app.cancel(&retransmit);
        g_app.schedule(when, &retransmit);
        _retransmit_armed = true;
    }

    void retransmit(MonoTime now)
    {
        _retransmit_armed = false;
        final switch (_phase)
        {
            case Phase.init_:
            case Phase.bound:
                return;

            case Phase.selecting:
            case Phase.requesting:
                if (_retry_count >= max_retries)
                {
                    log.warning("no response after ", _retry_count, _phase == Phase.selecting ? " DISCOVER" : " REQUEST", " attempts; restarting");
                    begin_exchange(Phase.selecting);
                    return;
                }
                if (_phase == Phase.selecting)
                    send_discover();
                else
                    send_request_select();
                ++_retry_count;
                arm_retransmit(now + retry_backoff(_retry_count));
                return;

            case Phase.renewing:
            case Phase.rebinding:
                if (_phase == Phase.renewing)
                    send_request_renew();
                else
                    send_request_rebind();
                ++_retry_count;
                // halve the remaining time to T2/lease, RFC 2131 4.4.5
                MonoTime deadline = _phase == Phase.renewing ? _t2_deadline : _lease_deadline;
                long delay_ms = (deadline - now).as!"msecs" / 2;
                if (delay_ms < min_renew_interval_ms)
                    delay_ms = min_renew_interval_ms;
                arm_retransmit(now + delay_ms.msecs);
                return;
        }
    }

    void arm_lease_timer()
    {
        MonoTime next = _lease_deadline;
        if (_phase == Phase.bound && _t1_deadline < next)
            next = _t1_deadline;
        else if (_phase == Phase.renewing && _t2_deadline < next)
            next = _t2_deadline;

        if (_lease_timer_armed)
            g_app.cancel(&lease_timer);
        g_app.schedule(next, &lease_timer);
        _lease_timer_armed = true;
    }

    void lease_timer(MonoTime now)
    {
        _lease_timer_armed = false;

        if (now >= _lease_deadline)
        {
            abandon(tconcat("lease ", _address, " expired without renewal"));
            return;
        }
        if (_phase == Phase.bound && now >= _t1_deadline)
            begin_exchange(Phase.renewing);
        else if (_phase == Phase.renewing && now >= _t2_deadline)
            begin_exchange(Phase.rebinding);

        arm_lease_timer();
    }

    void cancel_timers()
    {
        if (_retransmit_armed)
        {
            g_app.cancel(&retransmit);
            _retransmit_armed = false;
        }
        if (_lease_timer_armed)
        {
            g_app.cancel(&lease_timer);
            _lease_timer_armed = false;
        }
    }

    static Duration retry_backoff(uint attempt) pure
    {
        // 4, 8, 16, 32, 64 seconds
        uint secs = 4u << (attempt > 4 ? 4 : attempt - 1);
        return secs.seconds;
    }

    // RFC 2131 4.4.5: 0 < T1 < T2 < lease; an absent, zero or out-of-order value falls back to 0.5 and 0.875
    // of the lease, and T1 to half of T2 when the lease default would not precede it
    static void lease_timers(Duration lease, ref Duration t1, ref Duration t2) pure
    {
        long lease_ms = lease.as!"msecs";
        if (t2 <= Duration.zero || t2 >= lease)
            t2 = (lease_ms * 7 / 8).msecs;
        if (t1 <= Duration.zero || t1 >= t2)
            t1 = (lease_ms / 2).msecs;
        if (t1 >= t2)
            t1 = (t2.as!"msecs" / 2).msecs;
    }

    ushort secs_field() const
    {
        long elapsed = (getTime() - _request_started).as!"seconds";
        if (elapsed < 0)
            return 0;
        if (elapsed > ushort.max)
            return ushort.max;
        return cast(ushort)elapsed;
    }

    // ---- packet build ----

    void send_discover()
    {
        version (DebugDHCP)
            log.debug_("tx DISCOVER xid=", _xid);

        DhcpBuild b;
        b.start(BootpRequest, station.mac, _xid, secs_field, true);
        b.add_message_type(DhcpMessageType.discover);
        b.add_client_identifier(station.mac);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        b.transmit(station, IPAddr.any, IPAddr.broadcast, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    void send_request_select()
    {
        version (DebugDHCP)
            log.debug_("tx REQUEST (selecting) xid=", _xid, " offered=", _address, " server=", _server_id);

        DhcpBuild b;
        b.start(BootpRequest, station.mac, _xid, secs_field, true);
        b.add_message_type(DhcpMessageType.request);
        b.add_client_identifier(station.mac);
        b.add_addr_option(DhcpOption.requested_address, _address);
        b.add_addr_option(DhcpOption.server_id, _server_id);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        b.transmit(station, IPAddr.any, IPAddr.broadcast, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    void send_request_renew()
    {
        version (DebugDHCP)
            log.debug_("tx REQUEST (renew) xid=", _xid, " ciaddr=", _address, " server=", _server_id);

        DhcpBuild b;
        b.start(BootpRequest, station.mac, _xid, secs_field, false);
        b.set_ciaddr(_address);
        b.add_message_type(DhcpMessageType.request);
        b.add_client_identifier(station.mac);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        // TODO: ARP-resolve _server_id MAC; for now broadcast renew too.
        b.transmit(station, _address, _server_id, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
    }

    void send_request_rebind()
    {
        version (DebugDHCP)
            log.debug_("tx REQUEST (rebind) xid=", _xid, " ciaddr=", _address);

        DhcpBuild b;
        b.start(BootpRequest, station.mac, _xid, secs_field, true);
        b.set_ciaddr(_address);
        b.add_message_type(DhcpMessageType.request);
        b.add_client_identifier(station.mac);
        add_hostname(b);
        add_vendor_class_id(b);
        b.add_parameter_request_list();
        b.finish();
        b.transmit(station, _address, IPAddr.broadcast, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
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
            log.debug_("tx RELEASE ciaddr=", _address, " server=", _server_id);

        // RFC 2131 4.4.4: RELEASE is unicast to the server with ciaddr set.
        // TODO: ARP-resolve _server_id MAC; for now broadcast at L2 (same shortcut as renew).
        DhcpBuild b;
        b.start(BootpRequest, station.mac, rand(), 0, false);
        b.set_ciaddr(_address);
        b.add_message_type(DhcpMessageType.release);
        b.add_client_identifier(station.mac);
        b.add_addr_option(DhcpOption.server_id, _server_id);
        b.finish();
        b.transmit(station, _address, _server_id, MACAddress.broadcast, DhcpClientPort, DhcpServerPort);
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
        if (ip.protocol != IPProtocol.udp)
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

        if (dh.chaddr[0 .. 6] != station.mac.b[])
            return;

        // verify magic cookie
        if (dh.magic[0] != 0x63 || dh.magic[1] != 0x82 || dh.magic[2] != 0x53 || dh.magic[3] != 0x63)
            return;

        DhcpParse p;
        p.options = dhcp[DhcpHeader.sizeof .. $];

        DhcpMessageType msg_type;
        if (!p.message_type(msg_type))
            return;
        IPAddr server;
        if (!p.server_id(server))
            return;

        version (DebugDHCP)
            log.debug_("rx ", msg_type, " xid=", _xid, " yiaddr=", IPAddr(dh.yiaddr), " server=", server);

        // a reply belongs to the exchange in flight, and outside REBINDING only the selected server may answer it
        switch (msg_type)
        {
            case DhcpMessageType.offer:
                if (_phase != Phase.selecting || IPAddr(dh.yiaddr) == IPAddr.any)
                    return;
                _address = IPAddr(dh.yiaddr);
                _server_id = server;
                begin_exchange(Phase.requesting);
                return;

            case DhcpMessageType.ack:
            case DhcpMessageType.nak:
                if (_phase != Phase.requesting && _phase != Phase.renewing && _phase != Phase.rebinding)
                    return;
                if (_phase != Phase.rebinding && server != _server_id)
                    return;
                if (msg_type == DhcpMessageType.nak)
                    abandon(tconcat("NAK from server ", server, " for ", _address));
                else
                    handle_ack(IPAddr(dh.yiaddr), server, p);
                return;

            default:
                return;
        }
    }

    void handle_ack(IPAddr yiaddr, IPAddr server, ref DhcpParse p)
    {
        // a renewal ACK may leave yiaddr clear and echo our ciaddr instead
        IPAddr address = yiaddr != IPAddr.any ? yiaddr : _address;
        if (address == IPAddr.any)
            return;

        IPAddr mask, gw;
        Duration lease;
        if (!p.subnet_mask(mask) || !p.lease_time(lease) || lease <= Duration.zero)
        {
            log.warning("ACK from ", server, " missing subnet-mask or lease-time; ignoring");
            return;
        }
        p.router(gw);

        Duration t1, t2;
        p.renewal_time(t1);
        p.rebinding_time(t2);
        lease_timers(lease, t1, t2);

        bool was_bound = _phase != Phase.requesting;
        MonoTime now = getTime();
        _address = address;
        _server_id = server;
        _subnet_mask = mask;
        _gateway = gw;
        _t1_deadline = now + t1;
        _t2_deadline = now + t2;
        _lease_deadline = now + lease;
        _phase = Phase.bound;
        if (_retransmit_armed)
        {
            g_app.cancel(&retransmit);
            _retransmit_armed = false;
        }

        log.notice(was_bound ? "lease renewed: " : "lease acquired: ",
                   _address, "/", subnet_prefix_len(mask),
                   " gw=", gw, " server=", _server_id, " lease=", lease.as!"seconds", "s");

        apply_lease();
        arm_lease_timer();
    }

    // ---- lease lifecycle ----

    // reconcile the owned address and routes with the accepted configuration: create, update in place, or destroy
    void apply_lease()
    {
        ubyte plen = subnet_prefix_len(_subnet_mask);
        IPNetworkAddress net_addr = IPNetworkAddress(_address, plen);

        if (IPAddress a = _our_address.get)
        {
            if (a.address != net_addr)
                a.address = net_addr;
        }
        else
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

        IPNetworkAddress subnet = IPNetworkAddress(_address & _subnet_mask, plen);
        if (IPRoute r = _network_route.get)
        {
            if (plen == 32)
            {
                r.destroy();
                _network_route = null;
            }
            else if (r.destination != subnet)
                r.destination = subnet;
        }
        else if (plen < 32)
        {
            const(char)[] rt_name = Collection!IPRoute().generate_name(name[]);
            _network_route = Collection!IPRoute().create(
                rt_name,
                ObjectFlags.dynamic,
                NamedArgument("destination", subnet),
                NamedArgument("out-interface", cast(BaseInterface)_iface));
            if (!_network_route)
                log.error("failed to create dynamic network route");
        }

        bool want_default = _add_default_route && _gateway != IPAddr.any;
        if (IPRoute r = _default_route.get)
        {
            if (!want_default)
            {
                r.destroy();
                _default_route = null;
            }
            else if (r.gateway != _gateway)
                r.gateway = _gateway;
        }
        else if (want_default)
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


unittest
{
    Duration t1, t2;

    // both absent: the RFC defaults
    DHCPClient.lease_timers(100.seconds, t1, t2);
    assert(t1 == 50.seconds && t2 == 87_500.msecs);

    // a supplied T2 pulls an absent T1 under it
    t1 = Duration.zero;
    t2 = 20.seconds;
    DHCPClient.lease_timers(100.seconds, t1, t2);
    assert(t1 == 10.seconds && t2 == 20.seconds);

    // a supplied pair in order is kept; zero and out-of-range values are unset
    t1 = 30.seconds;
    t2 = 60.seconds;
    DHCPClient.lease_timers(100.seconds, t1, t2);
    assert(t1 == 30.seconds && t2 == 60.seconds);
    t1 = 90.seconds;
    t2 = 100.seconds;
    DHCPClient.lease_timers(100.seconds, t1, t2);
    assert(t1 == 50.seconds && t2 == 87_500.msecs);
    t1 = 10.seconds;
    t2 = Duration.zero;
    DHCPClient.lease_timers(100.seconds, t1, t2);
    assert(t1 == 10.seconds && t2 == 87_500.msecs);
}
