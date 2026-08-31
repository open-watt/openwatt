module protocol.dhcp.client6;

version (NoIPv6) {} else:
version (UseInternalIPStack):

import urt.array;
import urt.endian;
import urt.hash : internet_checksum;
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

import protocol.dhcp.message6;
import protocol.ip.address;
import protocol.ip.pool;
import protocol.ip : IPv6Header, IPProtocol, pseudo_header_checksum_v6;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

//version = DebugDHCP6;

nothrow @nogc:


// DHCPv6 client: obtains host addresses (IA_NA) and/or a delegated prefix
// (IA_PD). The delegated prefix materialises as a dynamic IPv6Pool so downstream
// consumers (RA/SLAAC advertisement, a downstream dhcp6-server) can draw from
// it by name. The default route still comes from RA; DHCPv6 carries none.
class DHCP6Client : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("request-address", request_address),
                                 Prop!("request-prefix", request_prefix),
                                 Prop!("pool-name", pool_name));
nothrow @nogc:

    enum type_name = "dhcp6-client";
    enum path = "/protocol/dhcp/client6";
    enum collection_id = CollectionType.dhcp6_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DHCP6Client, id, flags);
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

    final bool request_address() const pure
        => _request_address;
    final void request_address(bool value)
    {
        if (_request_address == value)
            return;
        _request_address = value;
        mark_set!(typeof(this), "request-address")();
        restart();
    }

    final bool request_prefix() const pure
        => _request_prefix;
    final void request_prefix(bool value)
    {
        if (_request_prefix == value)
            return;
        _request_prefix = value;
        mark_set!(typeof(this), "request-prefix")();
        restart();
    }

    final ref const(String) pool_name() const pure
        => _pool_name;
    final void pool_name(String value)
    {
        _pool_name = value.move;
        mark_set!(typeof(this), "pool-name")();
        restart();
    }

protected:

    override bool validate() const pure
        => _iface !is null && (_request_address || _request_prefix);

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _iface.subscribe(&incoming_packet, PacketFilter(ether_type: EtherType.ip6), null);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }

        if (_phase == Phase.init_)
            begin_exchange(Phase.soliciting);

        return _phase == Phase.bound ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        cancel_timers();

        if (_iface && _iface.running && _server_duid_len && !_lease.empty)
            send_ia_message(Dhcp6MsgType.release_);

        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&incoming_packet);
            _subscribed = false;
        }

        _lease.clear();
        _na_hints.clear();
        _pd_hints.clear();
        reconcile();

        _phase = Phase.init_;
        _txid = 0;
        _retry_count = 0;
        _server_duid_len = 0;

        return CompletionStatus.complete;
    }

private:
    enum Phase : ubyte
    {
        init_,
        soliciting,
        requesting,
        bound,
        renewing,
        rebinding,
    }

    struct OwnedAddress
    {
        IPv6NetworkAddress id;
        ObjectRef!IPv6Address object;
    }

    enum size_t max_retries = 5;
    enum uint iaid = 1;
    enum long min_renew_interval_ms = 10_000;

    ObjectRef!BaseInterface _iface;
    bool _request_address = true;
    bool _request_prefix;
    bool _subscribed;
    bool _retransmit_armed;
    bool _lease_timer_armed;
    String _pool_name;

    Phase _phase;
    uint _txid;
    uint _retry_count;
    MonoTime _request_started;

    ubyte[max_duid_size] _server_duid;
    ubyte _server_duid_len;

    Array!IPv6NetworkAddress _na_hints;     // advertised identities, echoed in the Request
    Array!IPv6NetworkAddress _pd_hints;
    Lease6 _lease;

    Array!OwnedAddress _addresses;
    ObjectRef!IPv6Pool _pool;

    EthernetStation station()
        => cast(EthernetStation)_iface.get;

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    static Duration retry_backoff(uint attempt)
    {
        uint s = 1 << (attempt > 5 ? 5 : attempt);
        return s.seconds;
    }

    void abandon(const(char)[] why)
    {
        log.warning(why, "; restarting");
        _lease.clear();
        _phase = Phase.init_;
        restart();
    }

    void begin_exchange(Phase phase)
    {
        MonoTime now = getTime();
        _phase = phase;
        _txid = rand() & 0xFFFFFF;
        _retry_count = 0;
        _request_started = now;
        if (phase == Phase.soliciting)
        {
            _server_duid_len = 0;
            _na_hints.clear();
            _pd_hints.clear();
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

            case Phase.soliciting:
            case Phase.requesting:
                if (_retry_count >= max_retries)
                {
                    log.warning("no response after ", _retry_count, _phase == Phase.soliciting ? " SOLICIT" : " REQUEST", " attempts; restarting");
                    begin_exchange(Phase.soliciting);
                    return;
                }
                send_ia_message(_phase == Phase.soliciting ? Dhcp6MsgType.solicit : Dhcp6MsgType.request);
                ++_retry_count;
                arm_retransmit(now + retry_backoff(_retry_count));
                return;

            case Phase.renewing:
            case Phase.rebinding:
                send_ia_message(_phase == Phase.renewing ? Dhcp6MsgType.renew : Dhcp6MsgType.rebind);
                ++_retry_count;
                MonoTime deadline = _phase == Phase.renewing ? _lease.t2 : _lease.earliest_expiry();
                long delay_ms = deadline == no_expiry ? min_renew_interval_ms : (deadline - now).as!"msecs" / 2;
                if (delay_ms < min_renew_interval_ms)
                    delay_ms = min_renew_interval_ms;
                arm_retransmit(now + delay_ms.msecs);
                return;
        }
    }

    void arm_lease_timer(MonoTime now)
    {
        MonoTime next = _lease.earliest_expiry();
        if (_phase == Phase.bound && _lease.t1 < next)
            next = _lease.t1;
        else if (_phase == Phase.renewing && _lease.t2 < next)
            next = _lease.t2;
        MonoTime deprecation = _lease.next_deprecation(now);
        if (deprecation < next)
            next = deprecation;

        if (_lease_timer_armed)
        {
            g_app.cancel(&lease_timer);
            _lease_timer_armed = false;
        }
        if (next == no_expiry)
            return;
        g_app.schedule(next, &lease_timer);
        _lease_timer_armed = true;
    }

    void lease_timer(MonoTime now)
    {
        _lease_timer_armed = false;

        if (!_lease.expire(now))
        {
            abandon("lease expired without renewal");
            return;
        }
        reconcile();

        if (_phase == Phase.bound && now >= _lease.t1)
            begin_exchange(Phase.renewing);
        else if (_phase == Phase.renewing && now >= _lease.t2)
            begin_exchange(Phase.rebinding);

        arm_lease_timer(now);
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

    ushort elapsed_centiseconds()
    {
        long cs = (getTime() - _request_started).as!"msecs" / 10;
        return cs > 0xFFFF ? 0xFFFF : cast(ushort)cs;
    }

    // All client messages share a shape: header, ids, elapsed-time, and the
    // IAs we want, carrying current bindings as hints where we have them.
    void send_ia_message(Dhcp6MsgType type)
    {
        import protocol.ip.nd : link_local_for;

        EthernetStation s = station;
        if (!s)
            return;

        Dhcp6Build b;
        b.start(type, _txid);
        ubyte[duid_ll_size] duid = duid_ll(s.mac);
        b.add_option(Dhcp6Option.client_id, duid[]);
        if (type != Dhcp6MsgType.solicit && type != Dhcp6MsgType.rebind && _server_duid_len)
            b.add_option(Dhcp6Option.server_id, _server_duid[0 .. _server_duid_len]);
        b.add_elapsed_time(elapsed_centiseconds());
        b.add_oro(cast(ushort)Dhcp6Option.dns_servers);

        bool offered = _phase == Phase.requesting;
        if (_request_address)
        {
            size_t body_ = b.begin_ia(Dhcp6Option.ia_na, iaid, 0, 0);
            if (offered)
            {
                foreach (ref id; _na_hints[])
                    b.add_ia_addr(id.addr, 0, 0);
            }
            else
            {
                foreach (ref x; _lease.na.bindings[])
                    b.add_ia_addr(x.id.addr, 0, 0);
            }
            b.end_option(body_);
        }
        if (_request_prefix)
        {
            size_t body_ = b.begin_ia(Dhcp6Option.ia_pd, iaid, 0, 0);
            if (offered)
            {
                foreach (ref id; _pd_hints[])
                    b.add_ia_prefix(id.addr, id.prefix_len, 0, 0);
            }
            else
            {
                foreach (ref x; _lease.pd.bindings[])
                    b.add_ia_prefix(x.id.addr, x.id.prefix_len, 0, 0);
            }
            b.end_option(body_);
        }

        version (DebugDHCP6)
            log.debug_("send ", type, " txid=", _txid);

        b.transmit(s, link_local_for(s.mac), dhcp6_multicast, ether_multicast_dhcp6, dhcp6_client_port, dhcp6_server_port);
    }

    void incoming_packet(ref const Packet pkt, BaseInterface, PacketDirection dir, void* user_data)
    {
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
        if (udp[0 .. 2].bigEndianToNative!ushort != dhcp6_server_port)
            return;
        if (udp[2 .. 4].bigEndianToNative!ushort != dhcp6_client_port)
            return;
        if (udp[4 .. 6].bigEndianToNative!ushort != udp_len)
            return;
        ushort pseudo = pseudo_header_checksum_v6(ip.src, ip.dst, cast(uint)udp_len, IPProtocol.udp);
        if (internet_checksum(udp, pseudo) != 0)
            return;

        Dhcp6Parse p;
        if (!p.init(udp[8 .. $]))
            return;
        if (p.txid != _txid)
            return;

        EthernetStation s = station;
        if (!s)
            return;
        ubyte[duid_ll_size] our_duid = duid_ll(s.mac);
        if (p.client_id() != our_duid[])
            return;

        const(ubyte)[] sid = p.server_id();
        if (sid.length == 0 || sid.length > max_duid_size)
            return;

        version (DebugDHCP6)
            log.debug_("received ", p.type, " txid=", p.txid);

        Dhcp6Status status;
        if (Dhcp6Parse.status_of(p.options, status) && status != Dhcp6Status.success)
            return;

        MonoTime now = getTime();
        switch (p.type)
        {
            case Dhcp6MsgType.advertise:
                if (_phase != Phase.soliciting)
                    return;
                _na_hints.clear();
                _pd_hints.clear();
                if (_request_address)
                    Lease6.live_identities(p, Dhcp6Option.ia_na, _na_hints);
                if (_request_prefix)
                    Lease6.live_identities(p, Dhcp6Option.ia_pd, _pd_hints);
                if (_na_hints.length == 0 && _pd_hints.length == 0)
                    return;
                _server_duid[0 .. sid.length] = sid[];
                _server_duid_len = cast(ubyte)sid.length;
                begin_exchange(Phase.requesting);
                return;

            case Dhcp6MsgType.reply:
                if (_phase != Phase.requesting && _phase != Phase.renewing && _phase != Phase.rebinding)
                    return;
                if (_phase != Phase.rebinding && _server_duid_len && sid != _server_duid[0 .. _server_duid_len])
                    return;
                bool renewal = _phase != Phase.requesting;
                bool complete;
                if (!_lease.commit(p, _request_address, _request_prefix, renewal, now, complete))
                {
                    abandon("server declined our bindings");
                    return;
                }
                _server_duid[0 .. sid.length] = sid[];
                _server_duid_len = cast(ubyte)sid.length;
                reconcile();
                // RFC 8415 18.2.10.1: an IA the server left out of a renewal is renewed again by the same exchange
                if (!renewal || complete)
                {
                    if (_retransmit_armed)
                    {
                        g_app.cancel(&retransmit);
                        _retransmit_armed = false;
                    }
                    _phase = Phase.bound;
                }
                arm_lease_timer(now);
                return;

            default:
                return;
        }
    }

    // Bring the owned objects into line with the lease: one address object per address binding, and the
    // one pool, a stable name for downstream consumers, carrying the freshest delegated prefix.
    void reconcile()
    {
        MonoTime now = getTime();

        for (size_t i = _addresses.length; i > 0; --i)
        {
            if (Lease6.find(_lease.na.bindings, _addresses[i - 1].id))
                continue;
            if (IPv6Address address = _addresses[i - 1].object.get)
                address.destroy();
            _addresses.remove(i - 1);
        }
        foreach (ref b; _lease.na.bindings[])
        {
            IPv6Address address = owned_address(b.id);
            if (!address)
            {
                const(char)[] n = Collection!IPv6Address().generate_name(name[]);
                address = Collection!IPv6Address().create(n, ObjectFlags.dynamic, NamedArgument("address", b.id), NamedArgument("interface", cast(BaseInterface)_iface));
                if (!address)
                {
                    log.error("failed to create dynamic IPv6Address");
                    continue;
                }
                _addresses.push_back(OwnedAddress(b.id, ObjectRef!IPv6Address(address)));
                log.info("bound ", b.id.addr, " on ", _iface.name);
            }
            address.deprecated_ = now >= b.preferred_until;
        }

        IPv6Pool pool = _pool.get;
        const(Binding6)* prefix = _lease.freshest_prefix();
        if (!prefix)
        {
            if (pool)
                pool.destroy();
            _pool = null;
            return;
        }
        if (!pool)
        {
            const(char)[] n = _pool_name.empty ? tconcat(name[], ".pd") : _pool_name[];
            IPv6NetworkAddress id = prefix.id;
            pool = Collection!IPv6Pool().create(n, ObjectFlags.dynamic, NamedArgument("prefix", id));
            if (!pool)
            {
                log.error("failed to create delegated-prefix pool");
                return;
            }
            _pool = pool;
            log.info("delegated ", prefix.id, " -> pool ", n);
        }
        else if (pool.prefix != prefix.id)
        {
            pool.prefix = prefix.id;
            log.info("renumbered pool ", pool.name, " to ", prefix.id);
        }
        pool.lifetimes(prefix.preferred_until, prefix.valid_until);
    }

    IPv6Address owned_address(IPv6NetworkAddress id)
    {
        foreach (ref o; _addresses[])
        {
            if (o.id == id)
                return o.object.get;
        }
        return null;
    }
}


struct Binding6
{
    IPv6NetworkAddress id;
    MonoTime preferred_until;
    MonoTime valid_until;
}

// One IA's bindings, keyed by address or prefix identity, with its own renewal deadlines
struct Ia6
{
    Array!Binding6 bindings;
    MonoTime t1 = no_expiry;
    MonoTime t2 = no_expiry;
}

// A Reply grants, refreshes or withdraws each entry on its own, so a renumbering overlap (the old entry
// deprecated beside its replacement) holds both until the old one lapses. Lifetime 0xFFFFFFFF is
// infinite (RFC 8415 7.7) and maps to no_expiry.
struct Lease6
{
nothrow @nogc:
    Ia6 na;
    Ia6 pd;

    bool empty() const pure
        => na.bindings.length == 0 && pd.bindings.length == 0;

    void clear()
    {
        reset(na);
        reset(pd);
    }

    MonoTime t1() const pure
        => na.t1 < pd.t1 ? na.t1 : pd.t1;

    MonoTime t2() const pure
        => na.t2 < pd.t2 ? na.t2 : pd.t2;

    // A Reply to a Request binds only what it grants; a Reply to a Renew or Rebind keeps the IAs it is
    // silent about, and reports them through `complete`. Returns false when nothing remains bound.
    bool commit(ref const Dhcp6Parse p, bool want_address, bool want_prefix, bool renewal, MonoTime now, out bool complete)
    {
        complete = true;
        if (want_address && !apply_ia(p, Dhcp6Option.ia_na, na, renewal, now))
            complete = false;
        if (want_prefix && !apply_ia(p, Dhcp6Option.ia_pd, pd, renewal, now))
            complete = false;
        return !empty;
    }

    // drops lapsed bindings; true while any remain
    bool expire(MonoTime now)
    {
        expire_ia(na, now);
        expire_ia(pd, now);
        return !empty;
    }

    MonoTime earliest_expiry() const
    {
        MonoTime e = earliest(na.bindings);
        MonoTime f = earliest(pd.bindings);
        return f < e ? f : e;
    }

    MonoTime next_deprecation(MonoTime now) const
    {
        MonoTime d = no_expiry;
        foreach (ref b; na.bindings[])
        {
            if (b.preferred_until > now && b.preferred_until < d)
                d = b.preferred_until;
        }
        return d;
    }

    // the prefix a downstream consumer should use: the one preferred longest, then valid longest
    const(Binding6)* freshest_prefix() const
    {
        const(Binding6)* best;
        foreach (ref b; pd.bindings[])
        {
            if (!best || b.preferred_until > best.preferred_until || (b.preferred_until == best.preferred_until && b.valid_until > best.valid_until))
                best = &b;
        }
        return best;
    }

    static inout(Binding6)* find(ref inout Array!Binding6 set, IPv6NetworkAddress id)
    {
        foreach (ref b; set[])
        {
            if (b.id == id)
                return &b;
        }
        return null;
    }

    // identities of the live entries in an IA, as Request hints
    static void live_identities(ref const Dhcp6Parse p, Dhcp6Option code, ref Array!IPv6NetworkAddress hints)
    {
        Ia ia;
        Dhcp6Status status;
        if (!p.ia(code, ia) || (Dhcp6Parse.status_of(ia.options, status) && status != Dhcp6Status.success))
            return;
        Dhcp6Options entries = Dhcp6Options(ia.options);
        Dhcp6Option option;
        const(ubyte)[] value;
        while (entries.next(option, value))
        {
            IPv6NetworkAddress id;
            uint preferred, valid;
            if (decode_entry(code, option, value, id, preferred, valid) && valid)
                hints.push_back(id);
        }
    }

private:
    // returns whether the Reply carried this IA at all
    static bool apply_ia(ref const Dhcp6Parse p, Dhcp6Option code, ref Ia6 state, bool renewal, MonoTime now)
    {
        Ia ia;
        if (!p.ia(code, ia))
        {
            if (!renewal)
                reset(state);
            return false;
        }
        Dhcp6Status status;
        if (Dhcp6Parse.status_of(ia.options, status) && status != Dhcp6Status.success)
        {
            reset(state);
            return true;
        }
        if (!renewal)
            reset(state);

        Dhcp6Options entries = Dhcp6Options(ia.options);
        Dhcp6Option option;
        const(ubyte)[] value;
        while (entries.next(option, value))
        {
            IPv6NetworkAddress id;
            uint preferred, valid;
            if (!decode_entry(code, option, value, id, preferred, valid))
                continue;
            Binding6* b = find(state.bindings, id);
            if (valid == 0)
            {
                if (b)
                    state.bindings.remove(b);
                continue;
            }
            if (!b)
                b = &state.bindings.push_back(Binding6(id));
            b.preferred_until = deadline(now, preferred);
            b.valid_until = deadline(now, valid);
        }
        if (state.bindings.length == 0)
        {
            reset(state);
            return true;
        }

        // RFC 8415 18.2.4: an unset T2 is 80% of the shortest valid lifetime and an unset T1 half of T2
        MonoTime expiry = earliest(state.bindings);
        if (ia.t2 == uint.max)
            state.t2 = no_expiry;
        else if (ia.t2)
            state.t2 = now + ia.t2.seconds;
        else
            state.t2 = expiry == no_expiry ? no_expiry : now + ((expiry - now).as!"msecs" / 5 * 4).msecs;
        if (ia.t1 == uint.max)
            state.t1 = no_expiry;
        else if (ia.t1 && (state.t2 == no_expiry || now + ia.t1.seconds < state.t2))
            state.t1 = now + ia.t1.seconds;
        else
            state.t1 = state.t2 == no_expiry ? no_expiry : now + ((state.t2 - now).as!"msecs" / 2).msecs;
        return true;
    }

    // RFC 8415 21.6/21.22: an entry whose preferred lifetime exceeds its valid lifetime is discarded
    static bool decode_entry(Dhcp6Option ia_code, Dhcp6Option option, const(ubyte)[] value, out IPv6NetworkAddress id, out uint preferred, out uint valid)
    {
        if (ia_code == Dhcp6Option.ia_na)
        {
            IaAddr a;
            if (option != Dhcp6Option.ia_addr || !Dhcp6Parse.parse_ia_addr(value, a))
                return false;
            id = IPv6NetworkAddress(a.addr, 128);
            preferred = a.preferred;
            valid = a.valid;
        }
        else
        {
            IaPrefix pf;
            if (option != Dhcp6Option.ia_prefix || !Dhcp6Parse.parse_ia_prefix(value, pf))
                return false;
            id = IPv6NetworkAddress(pf.prefix, pf.prefix_len);
            preferred = pf.preferred;
            valid = pf.valid;
        }
        return preferred <= valid;
    }

    static MonoTime deadline(MonoTime now, uint seconds) pure
        => seconds == uint.max ? no_expiry : now + seconds.seconds;

    static MonoTime earliest(ref const Array!Binding6 set)
    {
        MonoTime e = no_expiry;
        foreach (ref b; set[])
        {
            if (b.valid_until < e)
                e = b.valid_until;
        }
        return e;
    }

    static void reset(ref Ia6 state)
    {
        state.bindings.clear();
        state.t1 = no_expiry;
        state.t2 = no_expiry;
    }

    // an IA with no bindings left has nothing to renew
    static void expire_ia(ref Ia6 state, MonoTime now)
    {
        for (size_t i = state.bindings.length; i > 0; --i)
        {
            if (now >= state.bindings[i - 1].valid_until)
                state.bindings.remove(i - 1);
        }
        if (state.bindings.length == 0)
            reset(state);
    }
}


// 33:33 mapping of ff02::1:2
enum MACAddress ether_multicast_dhcp6 = MACAddress(0x33, 0x33, 0x00, 0x01, 0x00, 0x02);


unittest
{
    MonoTime now = MonoTime(1_000_000_000_000);
    IPv6Addr a = IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
    IPv6Addr b = IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2);
    IPv6Addr pd = IPv6Addr(0x2001, 0xdb8, 0x100, 0, 0, 0, 0, 0);
    IPv6Addr pd2 = IPv6Addr(0x2001, 0xdb8, 0x200, 0, 0, 0, 0, 0);
    Dhcp6Build build;
    Dhcp6Parse p;
    Lease6 lease;
    bool complete;

    // renumbering overlap: A deprecated (preferred 0) beside its replacement B, both bound
    build.start(Dhcp6MsgType.reply, 1);
    size_t ia = build.begin_ia(Dhcp6Option.ia_na, 1, 0, 0);
    build.add_ia_addr(a, 0, 300);
    build.add_ia_addr(b, 200, 300);
    build.end_option(ia);
    assert(p.init(build.payload) && lease.commit(p, true, false, false, now, complete) && complete);
    assert(lease.na.bindings.length == 2 && lease.pd.bindings.length == 0);
    assert(lease.na.bindings[0].id == IPv6NetworkAddress(a, 128) && lease.na.bindings[0].preferred_until == now);
    assert(lease.na.bindings[1].id == IPv6NetworkAddress(b, 128) && lease.na.bindings[1].preferred_until == now + 200.seconds);
    assert(lease.earliest_expiry() == now + 300.seconds);
    assert(lease.next_deprecation(now) == now + 200.seconds);
    assert(lease.t2 == now + 240.seconds && lease.t1 == now + 120.seconds);

    // renewal withdraws A (valid 0) and refreshes B
    build.start(Dhcp6MsgType.reply, 2);
    ia = build.begin_ia(Dhcp6Option.ia_na, 1, 100, 200);
    build.add_ia_addr(a, 0, 0);
    build.add_ia_addr(b, 400, 600);
    build.end_option(ia);
    assert(p.init(build.payload) && lease.commit(p, true, false, true, now, complete) && complete);
    assert(lease.na.bindings.length == 1 && lease.na.bindings[0].id.addr == b && lease.na.bindings[0].valid_until == now + 600.seconds);
    assert(lease.t1 == now + 100.seconds && lease.t2 == now + 200.seconds);

    // a renewal silent about IA_NA keeps it, deadlines included, and is reported incomplete;
    // infinite prefix lifetimes never expire and never renew
    build.start(Dhcp6MsgType.reply, 3);
    ia = build.begin_ia(Dhcp6Option.ia_pd, 1, uint.max, uint.max);
    build.add_ia_prefix(pd, 56, uint.max, uint.max);
    build.end_option(ia);
    assert(p.init(build.payload) && lease.commit(p, true, true, true, now, complete) && !complete);
    assert(lease.na.bindings.length == 1 && lease.pd.bindings.length == 1);
    assert(lease.pd.bindings[0].id == IPv6NetworkAddress(pd, 56) && lease.pd.bindings[0].valid_until == no_expiry);
    assert(lease.pd.t1 == no_expiry && lease.pd.t2 == no_expiry);
    assert(lease.t1 == now + 100.seconds && lease.t2 == now + 200.seconds);

    // prefix overlap: the replacement is the freshest, the deprecated old one stays bound
    build.start(Dhcp6MsgType.reply, 4);
    ia = build.begin_ia(Dhcp6Option.ia_pd, 1, 0, 0);
    build.add_ia_prefix(pd, 56, 0, 100);
    build.add_ia_prefix(pd2, 56, 100, 100);
    build.end_option(ia);
    assert(p.init(build.payload) && lease.commit(p, false, true, true, now, complete) && complete);
    assert(lease.pd.bindings.length == 2 && lease.freshest_prefix().id == IPv6NetworkAddress(pd2, 56));
    assert(lease.pd.t2 == now + 80.seconds && lease.pd.t1 == now + 40.seconds);
    assert(lease.t1 == now + 40.seconds);

    // expiry drops only the lapsed bindings, and an emptied IA no longer contributes deadlines
    assert(lease.expire(now + 100.seconds) && lease.na.bindings.length == 1 && lease.pd.bindings.length == 0);
    assert(lease.freshest_prefix() is null);
    assert(lease.pd.t1 == no_expiry && lease.pd.t2 == no_expiry);
    assert(lease.t1 == now + 100.seconds && lease.t2 == now + 200.seconds);

    // an IA-level failure drops that IA
    build.start(Dhcp6MsgType.reply, 5);
    ia = build.begin_ia(Dhcp6Option.ia_na, 1, 0, 0);
    build.add_status(Dhcp6Status.no_addrs_avail);
    build.end_option(ia);
    assert(p.init(build.payload) && !lease.commit(p, true, true, true, now, complete) && lease.empty);

    // preferred above valid is discarded; a Request Reply binds nothing it does not grant
    build.start(Dhcp6MsgType.reply, 6);
    ia = build.begin_ia(Dhcp6Option.ia_na, 1, 0, 0);
    build.add_ia_addr(a, 500, 300);
    build.end_option(ia);
    assert(p.init(build.payload) && !lease.commit(p, true, false, false, now, complete));

    // Advertise hints carry identities of live entries only
    build.start(Dhcp6MsgType.advertise, 7);
    ia = build.begin_ia(Dhcp6Option.ia_na, 1, 0, 0);
    build.add_ia_addr(a, 0, 0);
    build.add_ia_addr(b, 10, 20);
    build.end_option(ia);
    Array!IPv6NetworkAddress hints;
    assert(p.init(build.payload));
    Lease6.live_identities(p, Dhcp6Option.ia_na, hints);
    assert(hints.length == 1 && hints[0].addr == b);
}
