module protocol.ip.ra;

version (NoIPv6) {} else:
version (NoGateway) {} else:
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

import protocol.ip : IPv6Header, IPProtocol;
import protocol.ip.address;
import protocol.ip.icmp6;
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
        self.s[4 .. 8] = link_local_for(station.mac).s[4 .. 8];
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
    Array!IPv6Addr _dns;

    IPv6Addr _prefix;
    MonoTime _last_ra;
    ObjectRef!IPv6Address _our_address;

    EthernetStation station()
        => cast(EthernetStation)_iface.get;

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

        // header(16) + SLLA(8) + PIO(32) + RDNSS(8 + 16*n)
        ubyte[IPv6Header.sizeof + 16 + 8 + 32 + 8 + 16 * 8] buf = void;
        size_t dns_count = _dns.length > 8 ? 8 : _dns.length;
        size_t icmp_len = 16 + 8 + 32 + (dns_count ? 8 + 16 * dns_count : 0);

        auto hdr = cast(IPv6Header*)buf.ptr;
        hdr.ver_tc_flow[] = 0;
        hdr.ver_tc_flow[0] = 0x60;
        hdr.payload_length = nativeToBigEndian(cast(ushort)icmp_len);
        hdr.next_header = IPProtocol.icmp6;
        hdr.hop_limit = 255;
        hdr.src_addr = link_local_for(s.mac);
        hdr.dst_addr = IPv6Addr.linkLocal_allNodes;

        ubyte* icmp = buf.ptr + IPv6Header.sizeof;
        icmp[0] = Icmp6Type.router_advert;
        icmp[1] = 0;
        icmp[2] = 0;
        icmp[3] = 0;
        icmp[4] = 64;   // cur hop limit
        icmp[5] = cast(ubyte)((_managed ? 0x80 : 0) | (_other_config ? 0x40 : 0));
        icmp[6 .. 8] = lifetime.nativeToBigEndian;
        icmp[8 .. 16] = 0;      // reachable time / retrans timer: unspecified

        ubyte* o = icmp + 16;
        o[0] = NDOption.source_link_addr;
        o[1] = 1;
        o[2 .. 8] = s.mac.b[];
        o += 8;

        o[0] = NDOption.prefix_info;
        o[1] = 4;
        o[2] = 64;
        o[3] = 0xC0;    // L | A
        o[4 .. 8] = (cast(uint)_valid_lifetime.as!"seconds").nativeToBigEndian;
        o[8 .. 12] = (cast(uint)_preferred_lifetime.as!"seconds").nativeToBigEndian;
        o[12 .. 16] = 0;
        foreach (i; 0 .. 8)
        {
            o[16 + i*2] = cast(ubyte)(_prefix.s[i] >> 8);
            o[17 + i*2] = cast(ubyte)_prefix.s[i];
        }
        o += 32;

        if (dns_count)
        {
            enum ubyte rdnss = 25;
            o[0] = rdnss;
            o[1] = cast(ubyte)(1 + 2 * dns_count);
            o[2 .. 4] = 0;
            o[4 .. 8] = (cast(uint)(_interval.as!"seconds" * 2)).nativeToBigEndian;
            o += 8;
            foreach (n; 0 .. dns_count)
            {
                foreach (i; 0 .. 8)
                {
                    o[i*2] = cast(ubyte)(_dns[n].s[i] >> 8);
                    o[i*2 + 1] = cast(ubyte)_dns[n].s[i];
                }
                o += 16;
            }
        }

        ushort pseudo = pseudo_header_checksum_v6(hdr.src, hdr.dst, cast(uint)icmp_len, IPProtocol.icmp6);
        ushort cc = internet_checksum(icmp[0 .. icmp_len], pseudo);
        icmp[2] = cast(ubyte)(cc >> 8);
        icmp[3] = cast(ubyte)cc;

        version (DebugND)
            log.debug_("tx router-advert ", _prefix, "/64 lifetime=", lifetime, "s on ", s.name);

        _last_ra = getTime();
        s.send(ether_multicast(IPv6Addr.linkLocal_allNodes), buf[0 .. IPv6Header.sizeof + icmp_len], EtherType.ip6);
    }
}
