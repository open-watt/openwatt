module protocol.dhcp.server6;

version (NoIPv6) {} else:

import urt.array;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat, talloc;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.expression : NamedArgument;

import protocol.dhcp.lease6;
import protocol.dhcp.message6;
import protocol.ip.pool;
import protocol.ip : IPv6Header, IPProtocol;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

//version = DebugDHCP6;

nothrow @nogc:


class DHCP6Server : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("pool", pool),
                                 Prop!("lease-time", lease_time),
                                 Prop!("dns", dns));
nothrow @nogc:

    enum type_name = "dhcp6-server";
    enum path = "/protocol/dhcp/server6";
    enum collection_id = CollectionType.dhcp6_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DHCP6Server, id, flags);
        _lease_time = (24 * 60 * 60).seconds;
    }

    // Properties...

    final inout(BaseInterface) iface() inout pure
        => _iface;
    final const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (!cast(EthernetStation)value)
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

    final inout(IPv6Pool) pool() inout pure
        => _pool;
    final void pool(IPv6Pool value)
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

    final IPv6Addr[] dns() pure
        => _dns[];
    final void dns(IPv6Addr[] value...)
    {
        _dns.clear();
        _dns ~= value;
        mark_set!(typeof(this), "dns")();
    }

protected:

    override bool validate() const pure
        => _iface !is null && _pool !is null;

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        import protocol.ip.nd : link_local_for;
        _server_ll = link_local_for(station.mac);
        _duid = duid_ll(station.mac);

        if (!_subscribed)
        {
            _iface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ip6), null);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }

        foreach (l; Collection!DHCP6Lease().values)
        {
            DHCP6Lease lease = cast(DHCP6Lease)l;
            if (!_pool.contains(lease.address))
                continue;
            if (lease.is_prefix)
                _pool.reserve_prefix(lease.address);
            else
                _pool.reserve_address(lease.address);
        }

        log.info("serving DHCPv6 on ", _iface.name, " from pool ", _pool.name[]);
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

    override void update()
    {
        super.update();

        SysTime now = getSysTime();
        foreach (l; Collection!DHCP6Lease().values)
        {
            DHCP6Lease lease = cast(DHCP6Lease)l;
            if (!lease.is_expired(now))
                continue;
            if (_pool && _pool.contains(lease.address))
            {
                if (lease.is_prefix)
                    _pool.release_prefix(lease.address);
                else
                    _pool.release_address(lease.address);
            }
            version (DebugDHCP6)
                log.debug_("lease ", lease.address, "/", lease.prefix_length, " expired");
            lease.destroy();
        }
    }

private:
    enum size_t offer_hold_seconds = 60;

    ObjectRef!BaseInterface _iface;
    ObjectRef!IPv6Pool _pool;
    Duration _lease_time;
    Array!IPv6Addr _dns;
    bool _subscribed;

    IPv6Addr _server_ll;
    ubyte[DuidLLSize] _duid;

    EthernetStation station()
        => cast(EthernetStation)_iface.get;

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void incoming_packet(ref const Packet pkt, BaseInterface, PacketDirection dir, void* user_data)
    {
        if (!running)
            return;
        if (pkt.type != PacketType.ethernet || pkt.eth.ether_type != EtherType.ip6)
            return;

        const(ubyte)[] frame = cast(const(ubyte)[])pkt.data;
        if (frame.length < IPv6Header.sizeof + 8 + 4)
            return;

        const ip = cast(const IPv6Header*)frame.ptr;
        if (ip.version_ != 6 || ip.next_header != IPProtocol.udp)
            return;
        size_t udp_len = ip.payload_length.bigEndianToNative!ushort;
        if (IPv6Header.sizeof + udp_len > frame.length || udp_len < 8)
            return;

        const(ubyte)[] udp = frame[IPv6Header.sizeof .. IPv6Header.sizeof + udp_len];
        ushort src_port = udp[0 .. 2].bigEndianToNative!ushort;
        ushort dst_port = udp[2 .. 4].bigEndianToNative!ushort;
        if (src_port != Dhcp6ClientPort || dst_port != Dhcp6ServerPort)
            return;

        Dhcp6Parse p;
        if (!p.init(udp[8 .. $]))
            return;

        const(ubyte)[] client_duid = p.client_id();
        if (client_duid.length == 0 || client_duid.length > MaxDuidSize)
            return;

        // Messages carrying a server-id for a different server aren't for us.
        const(ubyte)[] sid = p.server_id();
        switch (p.type) with (Dhcp6MsgType)
        {
            case solicit:
            case rebind:
            case confirm:
                if (sid.length)
                    return;     // must not carry a server-id
                break;
            case request:
            case renew:
            case release_:
            case decline:
                if (sid != _duid[])
                    return;
                break;
            case info_request:
                if (sid.length && sid != _duid[])
                    return;
                break;
            default:
                return;         // server-originated or unknown; not ours to handle
        }

        IPv6Addr client_ip = ip.src_addr;
        MACAddress client_mac = pkt.eth.src;

        version (DebugDHCP6)
            log.debug_("received ", p.type, " from ", client_ip);

        switch (p.type) with (Dhcp6MsgType)
        {
            case solicit:
                handle_solicit_request(p, client_duid, client_ip, client_mac, advertise);
                break;
            case request:
            case renew:
            case rebind:
                handle_solicit_request(p, client_duid, client_ip, client_mac, reply);
                break;
            case release_:
                handle_release(p, client_duid, client_ip, client_mac);
                break;
            case decline:
                handle_decline(p, client_duid, client_ip, client_mac);
                break;
            case info_request:
                send_info_reply(p, client_ip, client_mac);
                break;
            default:
                break;
        }
    }

    // ---- handlers ----

    // Solicit offers, request/renew/rebind commit; the flow is identical apart
    // from the reply type and the lease duration applied.
    void handle_solicit_request(ref Dhcp6Parse p, const(ubyte)[] client_duid,
                                IPv6Addr client_ip, MACAddress client_mac, Dhcp6MsgType reply_type)
    {
        bool committing = reply_type == Dhcp6MsgType.reply;
        Duration hold = committing ? _lease_time : offer_hold_seconds.seconds;
        uint valid_s = cast(uint)_lease_time.as!"seconds";

        Dhcp6Build b;
        b.start(reply_type, p.txid);
        b.add_option(Dhcp6Option.server_id, _duid[]);
        b.add_option(Dhcp6Option.client_id, client_duid);

        const(char)[] duid_str = duid_hex(client_duid);

        Ia ia;
        if (p.ia(Dhcp6Option.ia_na, ia))
        {
            IaAddr requested;
            bool has_hint = Dhcp6Parse.ia_addr(ia, requested);
            DHCP6Lease lease = find_lease(duid_str, ia.iaid, false);
            IPv6Addr addr = lease ? lease.address
                          : _pool.allocate_address(has_hint ? requested.addr : IPv6Addr.any);

            size_t body_ = b.begin_ia(Dhcp6Option.ia_na, ia.iaid, valid_s / 2, valid_s * 4 / 5);
            if (addr == IPv6Addr.any)
            {
                b.add_status(Dhcp6Status.no_addrs_avail, "pool exhausted");
                log.warning("pool ", _pool.name[], " out of addresses for ", client_ip);
            }
            else
            {
                if (!lease)
                    lease = make_lease(addr, 128, duid_str, ia.iaid);
                if (lease)
                {
                    touch_lease(lease, hold);
                    b.add_ia_addr(addr, valid_s, valid_s);
                    if (committing)
                        log.info("issued ", addr, " to ", duid_str, " iaid=", ia.iaid);
                }
                else
                {
                    _pool.release_address(addr);
                    b.add_status(Dhcp6Status.unspec_fail);
                }
            }
            b.end_option(body_);
        }

        if (p.ia(Dhcp6Option.ia_pd, ia))
        {
            IaPrefix requested;
            bool has_hint = Dhcp6Parse.ia_prefix(ia, requested);
            DHCP6Lease lease = find_lease(duid_str, ia.iaid, true);
            IPv6Addr prefix = lease ? lease.address
                            : _pool.allocate_prefix(has_hint ? requested.prefix : IPv6Addr.any);

            size_t body_ = b.begin_ia(Dhcp6Option.ia_pd, ia.iaid, valid_s / 2, valid_s * 4 / 5);
            if (prefix == IPv6Addr.any)
            {
                b.add_status(Dhcp6Status.no_prefix_avail, "no prefixes available");
                log.warning("pool ", _pool.name[], " out of prefixes for ", client_ip);
            }
            else
            {
                if (!lease)
                    lease = make_lease(prefix, _pool.delegation_length, duid_str, ia.iaid);
                if (lease)
                {
                    touch_lease(lease, hold);
                    b.add_ia_prefix(prefix, _pool.delegation_length, valid_s, valid_s);
                    if (committing)
                        log.info("delegated ", prefix, "/", _pool.delegation_length, " to ", duid_str, " iaid=", ia.iaid);
                }
                else
                {
                    _pool.release_prefix(prefix);
                    b.add_status(Dhcp6Status.unspec_fail);
                }
            }
            b.end_option(body_);
        }

        add_dns(b);
        b.transmit(station, _server_ll, client_ip, client_mac, Dhcp6ServerPort, Dhcp6ClientPort);
    }

    void handle_release(ref Dhcp6Parse p, const(ubyte)[] client_duid, IPv6Addr client_ip, MACAddress client_mac)
    {
        const(char)[] duid_str = duid_hex(client_duid);

        Ia ia;
        if (p.ia(Dhcp6Option.ia_na, ia))
        {
            if (DHCP6Lease lease = find_lease(duid_str, ia.iaid, false))
            {
                log.info(duid_str, " released ", lease.address);
                if (!lease.is_static_lease())
                {
                    _pool.release_address(lease.address);
                    lease.destroy();
                }
            }
        }
        if (p.ia(Dhcp6Option.ia_pd, ia))
        {
            if (DHCP6Lease lease = find_lease(duid_str, ia.iaid, true))
            {
                log.info(duid_str, " released ", lease.address, "/", lease.prefix_length);
                if (!lease.is_static_lease())
                {
                    _pool.release_prefix(lease.address);
                    lease.destroy();
                }
            }
        }

        Dhcp6Build b;
        b.start(Dhcp6MsgType.reply, p.txid);
        b.add_option(Dhcp6Option.server_id, _duid[]);
        b.add_option(Dhcp6Option.client_id, client_duid);
        b.add_status(Dhcp6Status.success);
        b.transmit(station, _server_ll, client_ip, client_mac, Dhcp6ServerPort, Dhcp6ClientPort);
    }

    void handle_decline(ref Dhcp6Parse p, const(ubyte)[] client_duid, IPv6Addr client_ip, MACAddress client_mac)
    {
        const(char)[] duid_str = duid_hex(client_duid);

        Ia ia;
        if (p.ia(Dhcp6Option.ia_na, ia))
        {
            if (DHCP6Lease lease = find_lease(duid_str, ia.iaid, false))
            {
                // Keep the pool slot reserved as a cheap quarantine; drop the binding.
                log.warning(duid_str, " declined ", lease.address, "; quarantining");
                if (!lease.is_static_lease())
                    lease.destroy();
            }
        }

        Dhcp6Build b;
        b.start(Dhcp6MsgType.reply, p.txid);
        b.add_option(Dhcp6Option.server_id, _duid[]);
        b.add_option(Dhcp6Option.client_id, client_duid);
        b.add_status(Dhcp6Status.success);
        b.transmit(station, _server_ll, client_ip, client_mac, Dhcp6ServerPort, Dhcp6ClientPort);
    }

    void send_info_reply(ref Dhcp6Parse p, IPv6Addr client_ip, MACAddress client_mac)
    {
        Dhcp6Build b;
        b.start(Dhcp6MsgType.reply, p.txid);
        b.add_option(Dhcp6Option.server_id, _duid[]);
        const(ubyte)[] cid = p.client_id();
        if (cid.length)
            b.add_option(Dhcp6Option.client_id, cid);
        add_dns(b);
        b.transmit(station, _server_ll, client_ip, client_mac, Dhcp6ServerPort, Dhcp6ClientPort);
    }

    // ---- lease helpers ----

    DHCP6Lease find_lease(const(char)[] duid_str, uint iaid, bool prefix)
    {
        foreach (l; Collection!DHCP6Lease().values)
        {
            DHCP6Lease lease = cast(DHCP6Lease)l;
            if (lease.duid[] != duid_str || lease.iaid != iaid || lease.is_prefix != prefix)
                continue;
            if (!_pool.contains(lease.address))
                continue;       // another server's scope
            return lease;
        }
        return null;
    }

    DHCP6Lease make_lease(IPv6Addr addr, ubyte plen, const(char)[] duid_str, uint iaid)
    {
        const(char)[] lease_name = Collection!DHCP6Lease().generate_name(tconcat(addr));
        DHCP6Lease lease = Collection!DHCP6Lease().create(
            lease_name,
            ObjectFlags.dynamic,
            NamedArgument("address", addr),
            NamedArgument("prefix-length", plen),
            NamedArgument("duid", duid_str),
            NamedArgument("iaid", iaid),
            NamedArgument("pool", cast(IPv6Pool)_pool));
        if (!lease)
            log.error("failed to create lease for ", duid_str);
        return lease;
    }

    void touch_lease(DHCP6Lease lease, Duration hold)
    {
        if (!lease.is_static_lease())
            lease.expires = getSysTime() + hold;
    }

    void add_dns(ref Dhcp6Build b)
    {
        if (_dns.length == 0)
            return;
        size_t body_ = b.begin_option(Dhcp6Option.dns_servers);
        foreach (a; _dns[])
            b.put_addr(a);
        b.end_option(body_);
    }
}


// Render a DUID as lowercase hex in temp memory.
const(char)[] duid_hex(const(ubyte)[] d)
{
    char[] s = cast(char[])talloc(d.length * 2);
    static immutable char[16] hexd = "0123456789abcdef";
    foreach (i, b; d)
    {
        s[i*2] = hexd[b >> 4];
        s[i*2 + 1] = hexd[b & 15];
    }
    return s;
}
