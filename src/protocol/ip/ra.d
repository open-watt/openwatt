module protocol.ip.ra;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
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

import protocol.ip : IPModule, IPv6Header, IPProtocol, ipv6_multicast_mac, pseudo_header_checksum_v6, store_ipv6_address;
import protocol.ip.address;
import protocol.ip.icmp6;
import protocol.ip.mld;
import protocol.ip.nd;
import protocol.ip.pool;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

//version = DebugND;

nothrow @nogc:


// Router Advertisement service (RFC 4861): advertises one prefix on an
// interface for SLAAC, periodically and in response to Router Solicitations.
// The prefix comes from a pool (one slot allocated for the service's lifetime,
// so a DHCPv6-PD delegation flows straight through) or is given statically;
// either way this node takes prefix+EUI-64 as a dynamic address6 so the
// advertised subnet is routed and sourced correctly.
class RAService : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("pool", pool),
                                 Prop!("prefix", prefix),
                                 Prop!("interval", interval),
                                 Prop!("router-lifetime", router_lifetime),
                                 Prop!("valid-lifetime", valid_lifetime),
                                 Prop!("preferred-lifetime", preferred_lifetime),
                                 Prop!("managed", managed),
                                 Prop!("other-config", other_config),
                                 Prop!("dns", dns));
nothrow @nogc:

    enum type_name = "ipv6-ra";
    enum path = "/protocol/ip/ra";
    enum collection_id = CollectionType.ip_ra;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!RAService, id, flags);
        _interval = 200.seconds;
        _router_lifetime = 1800.seconds;
        _valid_lifetime = (30 * 86_400).seconds;
        _preferred_lifetime = (7 * 86_400).seconds;
    }

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
            _subscribed = false;
        }
        if (_joined)
        {
            mld_leave(get_module!IPModule.stack, IPv6Addr.linkLocal_routers, _iface);
            _joined = false;
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
        _static_prefix = IPv6NetworkAddress();
        mark_set!(typeof(this), "pool")();
        restart();
    }

    final IPv6NetworkAddress prefix() const pure
        => _static_prefix;
    final const(char)[] prefix(IPv6NetworkAddress value)
    {
        if (value.prefix_len != 64)
            return "SLAAC requires a /64 prefix";
        _static_prefix = value;
        _pool = null;
        mark_set!(typeof(this), "prefix")();
        restart();
        return null;
    }

    final Duration interval() const pure
        => _interval;
    final const(char)[] interval(Duration value)
    {
        if (value < 3.seconds)
            return "interval must be at least 3s";
        _interval = value;
        mark_set!(typeof(this), "interval")();
        restart();
        return null;
    }

    final Duration router_lifetime() const pure
        => _router_lifetime;
    final void router_lifetime(Duration value)
    {
        _router_lifetime = value;
        mark_set!(typeof(this), "router-lifetime")();
    }

    final Duration valid_lifetime() const pure
        => _valid_lifetime;
    final void valid_lifetime(Duration value)
    {
        _valid_lifetime = value;
        mark_set!(typeof(this), "valid-lifetime")();
    }

    final Duration preferred_lifetime() const pure
        => _preferred_lifetime;
    final void preferred_lifetime(Duration value)
    {
        _preferred_lifetime = value;
        mark_set!(typeof(this), "preferred-lifetime")();
    }

    final bool managed() const pure
        => _managed;
    final void managed(bool value)
    {
        _managed = value;
        mark_set!(typeof(this), "managed")();
    }

    final bool other_config() const pure
        => _other_config;
    final void other_config(bool value)
    {
        _other_config = value;
        mark_set!(typeof(this), "other-config")();
    }

    final IPv6Addr[] dns() pure
        => _dns[];
    final void dns(IPv6Addr[] value...)
    {
        _dns.clear();
        _dns ~= value;
        mark_set!(typeof(this), "dns")();
    }

    // An RS arrived on our interface; answer with a rate-limited advertisement.
    final void solicited()
    {
        if (!running)
            return;
        MonoTime now = getTime();
        if (now - _last_ra < 3.seconds)
            return;
        send_ra(cast(ushort)_router_lifetime.as!"seconds");
    }

protected:

    override bool validate() const pure
        => _iface !is null && (_pool !is null || _static_prefix.prefix_len == 64);

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;
        IPv6Addr link_local = link_local_of(_iface);
        if (link_local == IPv6Addr.any)
            return CompletionStatus.continue_;
        if (!_joined)
        {
            if (!mld_join(get_module!IPModule.stack, IPv6Addr.linkLocal_routers, _iface))
                return CompletionStatus.continue_;
            _joined = true;
        }

        if (_pool)
        {
            IPv6Pool p = _pool.get;
            if (p.delegation_length != 64)
            {
                log.warning("pool ", p.name, " delegation-length must be 64 for SLAAC");
                return CompletionStatus.continue_;
            }
            _prefix = p.allocate_prefix();
            if (_prefix == IPv6Addr.any)
            {
                log.warning("pool ", p.name, " has no free /64");
                return CompletionStatus.continue_;
            }
        }
        else
            _prefix = _static_prefix.get_network;

        IPv6Addr self = _prefix;
        self.s[4 .. 8] = link_local.s[4 .. 8];
        const(char)[] addr_name = Collection!IPv6Address().generate_name(name[]);
        _our_address = Collection!IPv6Address().create(
            addr_name,
            ObjectFlags.dynamic,
            NamedArgument("address", IPv6NetworkAddress(self, 64)),
            NamedArgument("interface", cast(BaseInterface)_iface));
        if (!_our_address)
            log.error("failed to create dynamic IPv6Address");

        if (!_subscribed)
        {
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }

        log.info("advertising ", _prefix, "/64 on ", _iface.name,
                 " every ", _interval.as!"seconds", "s");

        send_ra(cast(ushort)_router_lifetime.as!"seconds");
        g_app.schedule(getTime() + _interval, &on_timer);
        _scheduled = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_scheduled)
        {
            g_app.cancel(&on_timer);
            _scheduled = false;
        }

        // Withdraw: zero router-lifetime tells hosts to drop us as a gateway.
        if (_iface && _iface.running && _prefix != IPv6Addr.any)
            send_ra(0);

        if (auto a = _our_address.get)
            a.destroy();
        _our_address = null;

        if (_pool && _prefix != IPv6Addr.any)
            if (IPv6Pool p = _pool.get)
                p.release_prefix(_prefix);
        _prefix = IPv6Addr.any;

        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        if (_joined)
        {
            mld_leave(get_module!IPModule.stack, IPv6Addr.linkLocal_routers, _iface);
            _joined = false;
        }
        return CompletionStatus.complete;
    }

private:
    ObjectRef!BaseInterface _iface;
    ObjectRef!IPv6Pool _pool;
    IPv6NetworkAddress _static_prefix;
    Duration _interval;
    Duration _router_lifetime;
    Duration _valid_lifetime;
    Duration _preferred_lifetime;
    bool _managed;
    bool _other_config;
    bool _subscribed;
    bool _scheduled;
    bool _joined;
    Array!IPv6Addr _dns;

    IPv6Addr _prefix;
    MonoTime _last_ra;
    ObjectRef!IPv6Address _our_address;

    EthernetStation station()
        => dyn_cast!EthernetStation(_iface.get);

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void on_timer(MonoTime scheduled)
    {
        if (!running)
            return;
        send_ra(cast(ushort)_router_lifetime.as!"seconds");
        g_app.schedule(scheduled + _interval, &on_timer);
    }

    void send_ra(ushort lifetime)
    {
        EthernetStation s = station;
        if (!s)
            return;
        IPv6Addr source = link_local_of(s);
        if (source == IPv6Addr.any)
            return;

        align(size_t.sizeof) ubyte[IPv6Header.sizeof + 16 + 8 + 32 + 8 + 16 * 8] buffer = void;
        size_t dns_count = _dns.length > 8 ? 8 : _dns.length;
        size_t message_length = 16 + 8 + 32 + (dns_count ? 8 + 16 * dns_count : 0);

        auto header = cast(IPv6Header*)buffer.ptr;
        header.ver_tc_flow[] = 0;
        header.ver_tc_flow[0] = 0x60;
        storeBigEndian(cast(ushort*)header.payload_length.ptr, cast(ushort)message_length);
        header.next_header = IPProtocol.icmp6;
        header.hop_limit = 255;
        header.src_addr = source;
        header.dst_addr = IPv6Addr.linkLocal_allNodes;

        ubyte* message = buffer.ptr + IPv6Header.sizeof;
        message[0 .. message_length] = 0;
        message[0] = Icmp6Type.router_advert;
        message[4] = 64;
        message[5] = cast(ubyte)((_managed ? 0x80 : 0) | (_other_config ? 0x40 : 0));
        storeBigEndian(cast(ushort*)(message + 6), lifetime);

        ubyte* option = message + 16;
        option[0] = NDOption.source_link_addr;
        option[1] = 1;
        option[2 .. 8] = s.mac.b[];
        option += 8;

        option[0] = NDOption.prefix_info;
        option[1] = 4;
        option[2] = 64;
        option[3] = 0xC0;
        storeBigEndian(cast(uint*)(option + 4), cast(uint)_valid_lifetime.as!"seconds");
        storeBigEndian(cast(uint*)(option + 8), cast(uint)_preferred_lifetime.as!"seconds");
        option[12 .. 16] = 0;
        store_ipv6_address(option + 16, _prefix);
        option += 32;

        if (dns_count)
        {
            enum ubyte rdnss = 25;
            option[0] = rdnss;
            option[1] = cast(ubyte)(1 + 2 * dns_count);
            option[2 .. 4] = 0;
            storeBigEndian(cast(uint*)(option + 4), cast(uint)(_interval.as!"seconds" * 2));
            option += 8;
            foreach (n; 0 .. dns_count)
            {
                store_ipv6_address(option, _dns[n]);
                option += 16;
            }
        }

        ushort pseudo = pseudo_header_checksum_v6(header.src, header.dst, cast(uint)message_length, IPProtocol.icmp6);
        storeBigEndian(cast(ushort*)(message + 2), internet_checksum(message[0 .. message_length], pseudo));

        version (DebugND)
            log.debug_("tx router-advert ", _prefix, "/64 lifetime=", lifetime, "s on ", s.name);

        _last_ra = getTime();
        s.send(ipv6_multicast_mac(IPv6Addr.linkLocal_allNodes), buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
    }
}
