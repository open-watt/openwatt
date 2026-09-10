module protocol.ip.ra;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.rand;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.features : has_gateway;

import protocol.ip : IPModule, IPv6Header, IPProtocol, ipv6_multicast_mac, pseudo_header_checksum_v6, store_ipv6_address;
import protocol.ip.icmp6;
import protocol.ip.mld;
import protocol.ip.nd;
import protocol.ip.pool;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

//version = DebugND;

private alias log = Log!"ra";

nothrow @nogc:


static if (has_gateway)
{

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
        _interval = 600.seconds;
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
        _static_prefix = IPv6NetworkAddress(value.get_network, 64);
        _pool = null;
        mark_set!(typeof(this), "prefix")();
        restart();
        return null;
    }

    final Duration interval() const pure
        => _interval;
    final const(char)[] interval(Duration value)
    {
        if (value < min_interval || value > max_interval)
            return "interval must be between 4s and 1800s";
        _interval = value;
        mark_set!(typeof(this), "interval")();
        restart();
        return null;
    }

    final Duration router_lifetime() const pure
        => _router_lifetime;
    final const(char)[] router_lifetime(Duration value)
    {
        if (value < Duration.zero || value > max_router_lifetime)
            return "router-lifetime must be between 0s and 9000s";
        _router_lifetime = value;
        mark_set!(typeof(this), "router-lifetime")();
        restart();
        return null;
    }

    final Duration valid_lifetime() const pure
        => _valid_lifetime;
    final const(char)[] valid_lifetime(Duration value)
    {
        if (value < Duration.zero || value > max_prefix_lifetime)
            return "valid-lifetime must fit the 32-bit second field";
        _valid_lifetime = value;
        mark_set!(typeof(this), "valid-lifetime")();
        restart();
        return null;
    }

    final Duration preferred_lifetime() const pure
        => _preferred_lifetime;
    final const(char)[] preferred_lifetime(Duration value)
    {
        if (value < Duration.zero || value > max_prefix_lifetime)
            return "preferred-lifetime must fit the 32-bit second field";
        _preferred_lifetime = value;
        mark_set!(typeof(this), "preferred-lifetime")();
        restart();
        return null;
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

    // RFC 4861 6.2.6: a solicited advertisement is delayed at random and never within MIN_DELAY_BETWEEN_RAS of the last
    final void solicited()
    {
        if (!running)
            return;
        MonoTime now = getTime();
        MonoTime due = now + (rand() % max_ra_delay.as!"msecs").msecs;
        if (due < _last_ra + min_delay_between_ras)
            due = _last_ra + min_delay_between_ras;
        if (due < _next_ra)
            arm(due);
    }

protected:

    override bool validate() const pure
        => _iface !is null && (_pool !is null || _static_prefix.prefix_len == 64)
           && (_router_lifetime == Duration.zero || _router_lifetime >= _interval)
           && _preferred_lifetime <= _valid_lifetime;

    override CompletionStatus startup()
    {
        EthernetStation s = dyn_cast!EthernetStation(_iface.get);
        if (!s || !s.running || link_local_of(s) == IPv6Addr.any)
            return CompletionStatus.continue_;
        _station = s;
        if (!_joined)
        {
            if (!mld_join(get_module!IPModule.stack, IPv6Addr.linkLocal_routers, s))
                return CompletionStatus.continue_;
            _joined = true;
        }

        if (_pool)
        {
            IPv6Pool p = _pool.get;
            if (!p.running)
                return CompletionStatus.continue_;
            _prefix = p.allocate_prefix(IPv6NetworkAddress(IPv6Addr.any, 64));
            if (_prefix.prefix_len == 0)
            {
                _fail_reason = "pool has no free /64";
                return CompletionStatus.error;
            }
            _lease = p;
            p.subscribe(&pool_state_change);
        }
        else
            _prefix = _static_prefix;

        s.subscribe(&iface_state_change);
        _subscribed = true;

        log.info("advertising ", _prefix, " on ", s.name, " every ", _interval.as!"seconds", "s");

        _initial_left = max_initial_rtr_adverts;
        MonoTime now = getTime();
        arm(now > _last_ra + min_delay_between_ras ? now : _last_ra + min_delay_between_ras);
        return CompletionStatus.complete;
    }

    // Withdrawal is a multicast RA too, so it waits out MIN_DELAY_BETWEEN_RAS; the lease is held until the link state is gone
    override CompletionStatus shutdown()
    {
        g_app.cancel(&on_timer);
        if (_subscribed)
        {
            _station.unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        EthernetStation s = _station.get;
        if (_prefix.prefix_len)
        {
            MonoTime now = getTime();
            if (s && s.running)
            {
                if (now < _last_ra + min_delay_between_ras)
                    return CompletionStatus.continue_;
                send_ra(s, now, 0);
            }
            if (s)
                slaac_withdraw(get_module!IPModule.stack, s, _prefix, now);
            if (IPv6Pool p = _lease.get)
            {
                p.unsubscribe(&pool_state_change);
                p.release_prefix(_prefix);
            }
            _lease = null;
            _prefix = IPv6NetworkAddress();
        }
        if (_joined)
        {
            if (s)
                mld_leave(get_module!IPModule.stack, IPv6Addr.linkLocal_routers, s);
            _joined = false;
        }
        _station = null;
        return CompletionStatus.complete;
    }

private:
    enum Duration min_interval           = 4.seconds;
    enum Duration max_interval           = 1800.seconds;
    enum Duration max_router_lifetime    = 9000.seconds;
    enum Duration max_prefix_lifetime    = uint.max.seconds;
    enum Duration max_ra_delay           = 500.msecs;
    enum Duration min_delay_between_ras  = 3.seconds;
    enum Duration max_initial_interval   = 16.seconds;
    enum ubyte max_initial_rtr_adverts   = 3;

    ObjectRef!BaseInterface _iface;
    ObjectRef!IPv6Pool _pool;
    ObjectRef!EthernetStation _station;
    ObjectRef!IPv6Pool _lease;
    IPv6NetworkAddress _static_prefix;
    IPv6NetworkAddress _prefix;
    Duration _interval;
    Duration _router_lifetime;
    Duration _valid_lifetime;
    Duration _preferred_lifetime;
    MonoTime _last_ra;
    MonoTime _next_ra;
    Array!IPv6Addr _dns;
    ubyte _initial_left;
    bool _managed;
    bool _other_config;
    bool _subscribed;
    bool _joined;

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline && running)
            restart();
    }

    // The pool's tree is gone with it; whatever it hands out next is a fresh reservation
    void pool_state_change(ActiveObject, StateSignal signal)
    {
        if (signal != StateSignal.offline)
            return;
        _lease.unsubscribe(&pool_state_change);
        _lease = null;
        if (running)
            restart();
    }

    void arm(MonoTime when)
    {
        g_app.cancel(&on_timer);
        g_app.schedule(when, &on_timer);
        _next_ra = when;
    }

    void on_timer(MonoTime)
    {
        advertise(getTime());
    }

    // RFC 4861 6.2.1/6.2.4: unsolicited gap is uniform in [MaxRtrAdvInterval/3, MaxRtrAdvInterval] (fixed below 9s), the first few capped at 16s
    void advertise(MonoTime now)
    {
        EthernetStation s = _station.get;
        if (!s)
            return;
        send_ra(s, now, cast(ushort)_router_lifetime.as!"seconds");
        slaac_apply(get_module!IPModule.stack, s, _prefix, cast(uint)_valid_lifetime.as!"seconds", cast(uint)_preferred_lifetime.as!"seconds", now);
        long max_ms = _interval.as!"msecs";
        long min_ms = max_ms >= 9000 ? max_ms / 3 : max_ms;
        Duration next = (min_ms + rand() % (max_ms - min_ms + 1)).msecs;
        if (_initial_left)
        {
            --_initial_left;
            if (next > max_initial_interval)
                next = max_initial_interval;
        }
        arm(now + next);
    }

    void send_ra(EthernetStation s, MonoTime now, ushort lifetime)
    {
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
        store_ipv6_address(option + 16, _prefix.addr);
        option += 32;

        if (dns_count)
        {
            enum ubyte rdnss = 25;
            option[0] = rdnss;
            option[1] = cast(ubyte)(1 + 2 * dns_count);
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
            log.debug_("tx router-advert ", _prefix, " lifetime=", lifetime, "s on ", s.name);

        _last_ra = now;
        s.send(ipv6_multicast_mac(IPv6Addr.linkLocal_allNodes), buffer[0 .. IPv6Header.sizeof + message_length], EtherType.ip6);
    }
}

}
