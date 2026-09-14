module protocol.dhcp.server;

version (NoGateway) {} else:

import urt.array;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.expression : NamedArgument;

import protocol.dhcp.lease;
import protocol.dhcp.message;
import protocol.dhcp.option;
import protocol.ip.address;
import protocol.ip.pool;
import protocol.ip : IPv4Header, IPProtocol;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

//version = DebugDHCP;

nothrow @nogc:


final class DHCPServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("pool", pool),
                                 Prop!("lease-time", lease_time),
                                 Prop!("mac-limit", mac_limit),
                                 Prop!("add-default-gateway", add_default_gateway),
                                 Prop!("options", options));
nothrow @nogc:

    enum type_name = "dhcp-server";
    enum path = "/protocol/dhcp/server";
    enum collection_id = CollectionType.dhcp_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DHCPServer, id, flags);
        _lease_time = (24 * 60 * 60).seconds;
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

    final inout(IPPool) pool() inout pure
        => _pool;
    final void pool(IPPool value)
    {
        if (_pool is value)
            return;
        _pool = value;
        mark_set!(typeof(this), "pool")();
        restart();
    }

    final Duration lease_time() const pure
        => _lease_time;
    final void lease_time(Duration value)
    {
        _lease_time = value;
        mark_set!(typeof(this), "lease-time")();
    }

    final uint mac_limit() const pure
        => _mac_limit;
    final void mac_limit(uint value)
    {
        _mac_limit = value;
        mark_set!(typeof(this), "mac-limit")();
    }

    final bool add_default_gateway() const pure
        => _add_default_gateway;
    final void add_default_gateway(bool value)
    {
        _add_default_gateway = value;
        mark_set!(typeof(this), "add-default-gateway")();
    }

    final inout(ObjectRef!DHCPOption)[] options() inout pure
        => _options[];
    final void options(DHCPOption[] value...)
    {
        _options.clear();
        _options.reserve(value.length);
        foreach (o; value)
            _options.emplaceBack(o);
        mark_set!(typeof(this), "options")();
    }

protected:

    override bool validate() const
    {
        if (!_iface)
            return false;

        auto self = cast(DHCPServer)cast(void*)this;
        auto reason = compute_config_reason();
        if (reason !is _config_reason)
        {
            if (reason !is null)
                self.log.warning(reason);
            self._config_reason = reason;
        }
        return reason is null;
    }

    override const(char)[] status_message() const pure
    {
        if (_config_reason !is null)
            return _config_reason;
        return super.status_message();
    }

    private const(char)[] compute_config_reason() const
    {
        if (!_pool)
            return null;    // static-only mode
        IPAddress addr = find_iface_address(_iface);
        if (!addr)
            return null;    // defer: iface not yet bound
        if (!addr.address.contains(_pool.start) || !addr.address.contains(_pool.end))
            return "pool addresses outside interface subnet";
        return null;
    }

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        // Locate our IPv4 binding on the interface; without one we can't answer.
        IPAddress server_addr = find_iface_address(_iface);
        if (!server_addr)
        {
            log.warning("interface ", _iface.name, " has no IP address; cannot serve");
            return CompletionStatus.continue_;
        }
        _server_ip = server_addr.address.addr;
        _subnet_mask = prefix_to_mask(server_addr.address.prefix_len);

        if (!_subscribed)
        {
            _iface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ip4), null);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }

        // Reconcile pool reservations with the leases this server answers for.
        if (_pool)
        {
            foreach (l; Collection!DHCPLease().values)
            {
                DHCPLease lease = l;
                if (owns(lease) && _pool.contains(lease.address))
                    _pool.reserve(lease.address);
            }
        }

        log.info("serving DHCP on ", _iface.name, " as ", _server_ip,
                 "/", server_addr.address.prefix_len,
                 _pool ? tconcat(" from pool ", _pool.name[]) : " (static leases only)");

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&incoming_packet);
            _subscribed = false;
        }
        return CompletionStatus.complete;
    }

private:
    enum Duration offer_hold = 30.seconds;
    enum Duration decline_quarantine = 600.seconds;

    ObjectRef!BaseInterface _iface;

    // TODO: remove this hack and promote _iface to EthernetStation...
    EthernetStation station()
        => dyn_cast!EthernetStation(_iface.get);
    ObjectRef!IPPool _pool;
    Duration _lease_time;       // initialised in ctor; default = 1 day
    uint _mac_limit;        // 0 = unlimited
    bool _subscribed;
    bool _add_default_gateway = true;
    Array!(ObjectRef!DHCPOption) _options;

    IPAddr _server_ip;
    IPAddr _subnet_mask;

    const(char)[] _config_reason;

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void incoming_packet(ref const Packet pkt, BaseInterface, PacketDirection dir, void* user_data)
    {
        if (!running)
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
        if (src_port != DhcpClientPort || dst_port != DhcpServerPort)
            return;

        ushort udp_len = (ushort(u.length[0]) << 8) | u.length[1];
        if (udp_len < UdpHeader.sizeof || ip_hdr_len + udp_len > frame.length)
            return;

        const(ubyte)[] dgram = frame[ip_hdr_len + UdpHeader.sizeof .. ip_hdr_len + udp_len];
        if (dgram.length < DhcpHeader.sizeof)
            return;

        const dh = cast(const DhcpHeader*)dgram.ptr;
        if (dh.op != BootpRequest || dh.htype != HType_Ethernet || dh.hlen != 6)
            return;
        if (dh.magic[0] != 0x63 || dh.magic[1] != 0x82 || dh.magic[2] != 0x53 || dh.magic[3] != 0x63)
            return;

        DhcpParse p;
        p.options = dgram[DhcpHeader.sizeof .. $];

        DhcpMessageType msg_type;
        if (!p.message_type(msg_type))
            return;

        MACAddress client_mac;
        client_mac.b[] = dh.chaddr[0 .. 6];

        version (DebugDHCP)
            log.debug_("received ", msg_type, " from ", client_mac);

        switch (msg_type)
        {
            case DhcpMessageType.discover:
                handle_discover(*dh, client_mac, p);
                break;
            case DhcpMessageType.request:
                handle_request(*dh, client_mac, p, IPAddr(ip.dst) == _server_ip);
                break;
            case DhcpMessageType.decline:
                handle_decline(*dh, client_mac, p);
                break;
            case DhcpMessageType.release:
                handle_release(*dh, client_mac, p);
                break;
            case DhcpMessageType.inform:
                // TODO: respond with config-only ACK; needs ciaddr handling
                break;
            default:
                break;
        }
    }

    // ---- handlers ----

    void handle_discover(ref const DhcpHeader req, MACAddress client_mac, ref DhcpParse p)
    {
        DHCPLease lease = find_lease_for_mac(client_mac);
        IPAddr offer;

        if (lease)
        {
            // Existing binding (static or dynamic): re-offer same address.
            offer = lease.address;
        }
        else
        {
            if (!_pool)
            {
                version (DebugDHCP)
                    log.debug_("no pool configured; ignoring discovery from ", client_mac);
                return;
            }
            if (over_mac_limit(client_mac))
            {
                log.info("refused ", client_mac, ": at mac-limit of ", _mac_limit);
                return;
            }

            IPAddr requested;
            p.requested_address(requested);
            offer = _pool.allocate(requested);
            if (offer == IPAddr.any)
            {
                log.warning("pool ", _pool.name[], " exhausted; cannot offer lease to ", client_mac);
                return;
            }

            const(char)[] lease_name = Collection!DHCPLease().generate_name(addr_string(offer));
            lease = Collection!DHCPLease().create(
                lease_name,
                ObjectFlags.dynamic,
                NamedArgument("address", offer),
                NamedArgument("mac", client_mac),
                NamedArgument("pool", cast(IPPool)_pool));
            if (!lease)
            {
                _pool.release(offer);
                log.error("failed to create lease for ", client_mac);
                return;
            }
        }

        // Hold a fresh offer briefly; a committed lease keeps whatever it already has (the REQUEST may be lost)
        if (!lease.is_static_lease() && lease.deadline < getTime() + offer_hold)
            lease.expire_in(offer_hold);

        const(char)[] hostname = p.hostname();
        if (hostname.length > 0)
            lease.hostname = hostname.make_string();

        send_reply(req, client_mac, offer, DhcpMessageType.offer);
    }

    // RFC 2131 4.3.2: SELECTING names a server, INIT-REBOOT names an address, RENEWING/REBINDING carry ciaddr;
    // a client we hold no lease for is refused only when it addressed us, a stranger's INIT-REBOOT or REBINDING gets silence
    void handle_request(ref const DhcpHeader req, MACAddress client_mac, ref DhcpParse p, bool unicast)
    {
        IPAddr requested;
        p.requested_address(requested);
        IPAddr server_id;
        bool has_server_id = p.server_id(server_id);
        IPAddr ciaddr;
        ciaddr.b = req.ciaddr;

        if (has_server_id && server_id != _server_ip)
        {
            version (DebugDHCP)
                log.debug_(client_mac, " chose another DHCP server (", server_id, "); ignoring");
            return;
        }

        IPAddr target = has_server_id || ciaddr == IPAddr.any ? requested : ciaddr;
        DHCPLease lease = find_lease_for_mac(client_mac);
        if (target == IPAddr.any || !lease)
        {
            if (has_server_id || (unicast && ciaddr != IPAddr.any))
                send_nak(req, client_mac, "no lease for client");
            return;
        }
        if (lease.address != target)
        {
            send_nak(req, client_mac, "wrong address");
            return;
        }

        // Bind / extend.
        if (!lease.is_static_lease())
            lease.expire_in(_lease_time);

        log.info("issued lease ", target, " to ", client_mac,
                 lease.hostname[].length ? tconcat(" (", lease.hostname[], ")") : "",
                 lease.is_static_lease() ? " (static)" : tconcat(" for ", _lease_time.as!"seconds", "s"));

        send_reply(req, client_mac, target, DhcpMessageType.ack);
    }

    // the lease stays as the reservation's owner, unmatchable, until its quarantine runs out
    void handle_decline(ref const DhcpHeader req, MACAddress client_mac, ref DhcpParse p)
    {
        IPAddr declined;
        if (!p.requested_address(declined))
            return;

        DHCPLease lease = find_lease_for_addr_and_mac(declined, client_mac);
        if (!lease || lease.is_static_lease())
            return;

        log.warning(client_mac, " declined ", declined, "; quarantined for ", decline_quarantine.as!"seconds", "s");
        lease.declined = true;
        lease.expire_in(decline_quarantine);
    }

    void handle_release(ref const DhcpHeader req, MACAddress client_mac, ref DhcpParse p)
    {
        IPAddr ciaddr;
        ciaddr.b = req.ciaddr;
        if (ciaddr == IPAddr.any)
            return;

        DHCPLease lease = find_lease_for_addr_and_mac(ciaddr, client_mac);
        if (!lease || lease.is_static_lease())
            return;

        log.info(client_mac, " released ", ciaddr);
        lease.destroy();
    }

    // ---- lookup / policy ----

    // a static lease is ours when it sits in our subnet; a dynamic one when our pool allocated it
    bool owns(const DHCPLease lease) const
    {
        if (lease.is_static_lease())
            return (lease.address & _subnet_mask) == (_server_ip & _subnet_mask);
        return _pool && lease.pool is _pool.get;
    }

    // a quarantined lease still owns its reservation but answers to no client
    bool matches(const DHCPLease lease, MACAddress mac) const
        => lease.mac == mac && !lease.declined && owns(lease);

    DHCPLease find_lease_for_mac(MACAddress mac)
    {
        // Prefer static leases (long-lived bindings) over dynamic ones.
        DHCPLease dynamic_match;
        foreach (l; Collection!DHCPLease().values)
        {
            DHCPLease lease = l;
            if (!matches(lease, mac))
                continue;
            if (lease.is_static_lease())
                return lease;
            dynamic_match = lease;
        }
        return dynamic_match;
    }

    DHCPLease find_lease_for_addr_and_mac(IPAddr addr, MACAddress mac)
    {
        foreach (l; Collection!DHCPLease().values)
        {
            DHCPLease lease = l;
            if (lease.address == addr && matches(lease, mac))
                return lease;
        }
        return null;
    }

    bool over_mac_limit(MACAddress mac)
    {
        if (_mac_limit == 0)
            return false;
        uint count = 0;
        foreach (l; Collection!DHCPLease().values)
        {
            DHCPLease lease = l;
            if (matches(lease, mac))
                ++count;
        }
        return count >= _mac_limit;
    }

    bool user_option_set(DhcpOption code) const
    {
        foreach (ref opt_ref; _options[])
        {
            const DHCPOption opt = opt_ref.get();
            if (opt && opt.code == cast(ubyte)code)
                return true;
        }
        return false;
    }

    // ---- reply build ----

    void send_reply(ref const DhcpHeader req, MACAddress client_mac, IPAddr yiaddr, DhcpMessageType type)
    {
        DhcpBuild b;
        b.start_reply_from(req);
        b.set_yiaddr(yiaddr);
        b.set_siaddr(_server_ip);

        b.add_message_type(type);
        b.add_addr_option(DhcpOption.server_id, _server_ip);
        b.add_addr_option(DhcpOption.subnet_mask, _subnet_mask);
        if (type == DhcpMessageType.ack || type == DhcpMessageType.offer)
            b.add_uint_option(DhcpOption.lease_time, cast(uint)_lease_time.as!"seconds");

        // Auto-advertise ourselves as the gateway unless the user supplied an explicit option 3.
        if (_add_default_gateway && !user_option_set(DhcpOption.router))
            b.add_addr_option(DhcpOption.router, _server_ip);

        // User-configured options (router, dns, domain, vendor-specific, ...).
        foreach (ref opt_ref; _options[])
        {
            DHCPOption opt = opt_ref.get();
            if (!opt)
                continue;
            if (!opt.to_wire(b))
                log.warning("option '", opt.name[], "' (code=", opt.code, ") failed to encode");
        }

        if (!b.finish())
        {
            log.error(type, " to ", client_mac, " does not fit the frame; dropped");
            return;
        }
        if (!send_to_client(b, req, client_mac, yiaddr))
            log.warning("failed to transmit ", type, " to ", client_mac);
    }

    void send_nak(ref const DhcpHeader req, MACAddress client_mac, const(char)[] reason)
    {
        log.info("NAK to ", client_mac, ": ", reason);

        DhcpBuild b;
        b.start_reply_from(req);
        b.add_message_type(DhcpMessageType.nak);
        b.add_addr_option(DhcpOption.server_id, _server_ip);
        if (reason.length > 0)
            b.add_string_option(DhcpOption.message, reason);
        b.finish();

        // NAK always broadcast (RFC 2131 4.3.2).
        if (!b.transmit(station, _server_ip, IPAddr.broadcast, MACAddress.broadcast, DhcpServerPort, DhcpClientPort))
            log.warning("failed to transmit NAK to ", client_mac);
    }

    bool send_to_client(ref DhcpBuild b, ref const DhcpHeader req, MACAddress client_mac, IPAddr yiaddr)
    {
        // Honour the BROADCAST flag; otherwise unicast to chaddr.
        bool broadcast = (req.flags[0] & 0x80) != 0;

        IPAddr ciaddr;
        ciaddr.b = req.ciaddr;
        if (!broadcast && ciaddr == IPAddr.any)
        {
            // No IP yet on the client; we can still ethernet-unicast to chaddr,
            // but the IP must be the offered yiaddr so the client receives it.
            broadcast = false;
        }

        if (broadcast)
            return b.transmit(station, _server_ip, IPAddr.broadcast, MACAddress.broadcast, DhcpServerPort, DhcpClientPort);
        IPAddr ip_dst = ciaddr != IPAddr.any ? ciaddr : yiaddr;
        return b.transmit(station, _server_ip, ip_dst, client_mac, DhcpServerPort, DhcpClientPort);
    }
}


private:

IPAddress find_iface_address(const BaseInterface iface)
{
    foreach (a; Collection!IPAddress().values)
    {
        IPAddress addr = a;
        if (addr.iface is iface)
            return addr;
    }
    return null;
}

const(char)[] addr_string(IPAddr a)
{
    return tconcat(a);
}
