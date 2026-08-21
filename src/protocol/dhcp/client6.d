module protocol.dhcp.client6;

version (NoIPv6) {} else:

import urt.array;
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

import protocol.dhcp.message6;
import protocol.ip.address;
import protocol.ip.pool;
import protocol.ip : IPv6Header, IPProtocol;

import router.iface;
import router.iface.ethernet;
import router.iface.mac;
import router.iface.packet;

//version = DebugDHCP6;

nothrow @nogc:


// DHCPv6 client: obtains a host address (IA_NA) and/or a delegated prefix
// (IA_PD). A delegated prefix materialises as a dynamic IPv6Pool so downstream
// consumers (RA/SLAAC advertisement, a downstream dhcp6-server) can draw from
// it by name. The default route still comes from RA; DHCPv6 carries none.
class DHCP6Client : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("request-address", request_address),
                                 Prop!("request-prefix", request_prefix),
                                 Prop!("pool-name", pool_name),
                                 Prop!("delegation-length", delegation_length));
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

    final ubyte delegation_length() const pure
        => _delegation_length;
    final const(char)[] delegation_length(ubyte value)
    {
        if (value > 64)
            return "delegation-length must be <= 64";
        _delegation_length = value;
        mark_set!(typeof(this), "delegation-length")();
        return null;
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

        MonoTime now = getTime();

        if (_phase == Phase.init_)
        {
            begin_solicit(now);
            return CompletionStatus.continue_;
        }

        if (_phase == Phase.bound)
        {
            apply_lease();
            return CompletionStatus.complete;
        }

        if (now >= _next_action)
        {
            if (_retry_count >= max_retries)
            {
                log.warning("no response after ", _retry_count,
                            _phase == Phase.soliciting ? " SOLICIT" : " REQUEST",
                            " attempts; restarting");
                begin_solicit(now);
                return CompletionStatus.continue_;
            }

            if (_phase == Phase.soliciting)
                send_ia_message(Dhcp6MsgType.solicit);
            else if (_phase == Phase.requesting)
                send_ia_message(Dhcp6MsgType.request);

            ++_retry_count;
            _next_action = now + retry_backoff(_retry_count);
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        bool held = _phase == Phase.bound || _phase == Phase.renewing || _phase == Phase.rebinding;
        if (held && _iface && _iface.running && _server_duid_len)
            send_ia_message(Dhcp6MsgType.release_);

        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&incoming_packet);
            _subscribed = false;
        }

        release_lease();

        _phase = Phase.init_;
        _txid = 0;
        _retry_count = 0;
        _server_duid_len = 0;

        return CompletionStatus.complete;
    }

    override void update()
    {
        super.update();

        MonoTime now = getTime();

        if (_phase == Phase.bound && now >= _t1_deadline)
        {
            _phase = Phase.renewing;
            _retry_count = 0;
            _next_action = now;
            _txid = rand() & 0xFFFFFF;
            _request_started = now;
        }

        if (_phase == Phase.renewing && now >= _t2_deadline)
        {
            _phase = Phase.rebinding;
            _retry_count = 0;
            _next_action = now;
            _txid = rand() & 0xFFFFFF;
            _request_started = now;
        }

        if ((_phase == Phase.renewing || _phase == Phase.rebinding) && now >= _lease_deadline)
        {
            log.warning("lease expired without renewal; restarting");
            release_lease();
            restart();
            return;
        }

        if ((_phase == Phase.renewing || _phase == Phase.rebinding) && now >= _next_action)
        {
            send_ia_message(_phase == Phase.renewing ? Dhcp6MsgType.renew : Dhcp6MsgType.rebind);
            ++_retry_count;
            MonoTime deadline = _phase == Phase.renewing ? _t2_deadline : _lease_deadline;
            long delay_s = (deadline - now).as!"seconds" / 2;
            if (delay_s < 10)
                delay_s = 10;
            _next_action = now + delay_s.seconds;
        }
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

    enum size_t max_retries = 5;
    enum uint iaid = 1;

    ObjectRef!BaseInterface _iface;
    bool _request_address = true;
    bool _request_prefix;
    bool _subscribed;
    ubyte _delegation_length = 64;
    String _pool_name;

    Phase _phase;
    uint _txid;
    uint _retry_count;
    MonoTime _request_started;
    MonoTime _next_action;

    ubyte[MaxDuidSize] _server_duid;
    ubyte _server_duid_len;

    // bound state
    IPv6Addr _addr;             // IA_NA result; :: if none
    IPv6Addr _pd_prefix;        // IA_PD result; :: if none
    ubyte _pd_prefix_len;
    MonoTime _t1_deadline;
    MonoTime _t2_deadline;
    MonoTime _lease_deadline;

    ObjectRef!IPv6Address _our_address;
    ObjectRef!IPv6Pool _pd_pool;

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

    void begin_solicit(MonoTime now)
    {
        _phase = Phase.soliciting;
        _txid = rand() & 0xFFFFFF;
        _retry_count = 0;
        _request_started = now;
        _next_action = now;
        _server_duid_len = 0;
        _addr = IPv6Addr.any;
        _pd_prefix = IPv6Addr.any;
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
        ubyte[DuidLLSize] duid = duid_ll(s.mac);
        b.add_option(Dhcp6Option.client_id, duid[]);
        if (type != Dhcp6MsgType.solicit && type != Dhcp6MsgType.rebind && _server_duid_len)
            b.add_option(Dhcp6Option.server_id, _server_duid[0 .. _server_duid_len]);
        b.add_elapsed_time(elapsed_centiseconds());
        b.add_oro(cast(ushort)Dhcp6Option.dns_servers);

        if (_request_address)
        {
            size_t body_ = b.begin_ia(Dhcp6Option.ia_na, iaid, 0, 0);
            if (_addr != IPv6Addr.any)
                b.add_ia_addr(_addr, 0, 0);
            b.end_option(body_);
        }
        if (_request_prefix)
        {
            size_t body_ = b.begin_ia(Dhcp6Option.ia_pd, iaid, 0, 0);
            if (_pd_prefix != IPv6Addr.any)
                b.add_ia_prefix(_pd_prefix, _pd_prefix_len, 0, 0);
            b.end_option(body_);
        }

        version (DebugDHCP6)
            log.debug_("send ", type, " txid=", _txid);

        b.transmit(s, link_local_for(s.mac), Dhcp6Multicast, ether_multicast_dhcp6,
                   Dhcp6ClientPort, Dhcp6ServerPort);
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
        if (udp[0 .. 2].bigEndianToNative!ushort != Dhcp6ServerPort)
            return;
        if (udp[2 .. 4].bigEndianToNative!ushort != Dhcp6ClientPort)
            return;

        Dhcp6Parse p;
        if (!p.init(udp[8 .. $]))
            return;
        if (p.txid != _txid)
            return;

        EthernetStation s = station;
        if (!s)
            return;
        import protocol.ip.nd : link_local_for;
        ubyte[DuidLLSize] our_duid = duid_ll(s.mac);
        if (p.client_id() != our_duid[])
            return;

        const(ubyte)[] sid = p.server_id();
        if (sid.length == 0 || sid.length > MaxDuidSize)
            return;

        version (DebugDHCP6)
            log.debug_("received ", p.type, " txid=", p.txid);

        switch (p.type)
        {
            case Dhcp6MsgType.advertise:
                if (_phase != Phase.soliciting)
                    return;
                if (!accept_bindings(p, false))
                    return;
                _server_duid[0 .. sid.length] = sid[];
                _server_duid_len = cast(ubyte)sid.length;
                _phase = Phase.requesting;
                _retry_count = 0;
                _next_action = getTime();
                return;

            case Dhcp6MsgType.reply:
                if (_phase != Phase.requesting && _phase != Phase.renewing && _phase != Phase.rebinding)
                    return;
                if (_phase != Phase.rebinding && _server_duid_len && sid != _server_duid[0 .. _server_duid_len])
                    return;
                if (!accept_bindings(p, true))
                {
                    log.warning("server declined our bindings; restarting");
                    release_lease();
                    begin_solicit(getTime());
                    return;
                }
                _server_duid[0 .. sid.length] = sid[];
                _server_duid_len = cast(ubyte)sid.length;
                _phase = Phase.bound;
                apply_lease();
                return;

            default:
                return;
        }
    }

    // Extract IA results and, on commit, arm the timers. Returns false if the
    // message carries no usable binding for anything we asked for.
    bool accept_bindings(ref Dhcp6Parse p, bool commit)
    {
        bool got_any;
        uint t1, t2, valid;

        Ia ia;
        if (_request_address && p.ia(Dhcp6Option.ia_na, ia))
        {
            IaAddr a;
            if (Dhcp6Parse.status_of(ia.options) == Dhcp6Status.success && Dhcp6Parse.ia_addr(ia, a) && a.valid)
            {
                _addr = a.addr;
                got_any = true;
                accumulate_timers(ia, a.valid, t1, t2, valid);
            }
        }
        if (_request_prefix && p.ia(Dhcp6Option.ia_pd, ia))
        {
            IaPrefix pf;
            if (Dhcp6Parse.status_of(ia.options) == Dhcp6Status.success && Dhcp6Parse.ia_prefix(ia, pf) && pf.valid)
            {
                _pd_prefix = pf.prefix;
                _pd_prefix_len = pf.prefix_len;
                got_any = true;
                accumulate_timers(ia, pf.valid, t1, t2, valid);
            }
        }

        if (!got_any)
            return false;

        if (commit)
        {
            MonoTime now = getTime();
            if (t1 == 0)
                t1 = valid / 2;
            if (t2 == 0)
                t2 = valid * 4 / 5;
            _t1_deadline = now + t1.seconds;
            _t2_deadline = now + t2.seconds;
            _lease_deadline = now + valid.seconds;
        }
        return true;
    }

    static void accumulate_timers(ref const Ia ia, uint ia_valid, ref uint t1, ref uint t2, ref uint valid)
    {
        if (ia.t1 && (t1 == 0 || ia.t1 < t1))
            t1 = ia.t1;
        if (ia.t2 && (t2 == 0 || ia.t2 < t2))
            t2 = ia.t2;
        if (valid == 0 || ia_valid < valid)
            valid = ia_valid;
    }

    // ---- lease lifecycle ----

    void apply_lease()
    {
        if (_addr != IPv6Addr.any && !_our_address)
        {
            const(char)[] addr_name = Collection!IPv6Address().generate_name(name[]);
            _our_address = Collection!IPv6Address().create(
                addr_name,
                ObjectFlags.dynamic,
                NamedArgument("address", IPv6NetworkAddress(_addr, 128)),
                NamedArgument("interface", cast(BaseInterface)_iface));
            if (!_our_address)
                log.error("failed to create dynamic IPv6Address");
            else
                log.info("bound ", _addr, " on ", _iface.name);
        }

        if (_pd_prefix != IPv6Addr.any)
        {
            if (IPv6Pool pool = _pd_pool.get)
            {
                pool.prefix = _pd_prefix;
                pool.prefix_length = _pd_prefix_len;
            }
            else
            {
                const(char)[] pn = _pool_name.empty ? tconcat(name[], ".pd") : _pool_name[];
                _pd_pool = Collection!IPv6Pool().create(
                    pn,
                    ObjectFlags.dynamic,
                    NamedArgument("prefix", _pd_prefix),
                    NamedArgument("prefix-length", _pd_prefix_len),
                    NamedArgument("delegation-length", _delegation_length));
                if (!_pd_pool)
                    log.error("failed to create delegated-prefix pool");
                else
                    log.info("delegated ", _pd_prefix, "/", _pd_prefix_len, " -> pool ", pn);
            }
        }
    }

    void release_lease()
    {
        if (auto a = _our_address.get())
            a.destroy();
        _our_address = null;
        if (auto pool = _pd_pool.get())
            pool.destroy();
        _pd_pool = null;
        _addr = IPv6Addr.any;
        _pd_prefix = IPv6Addr.any;
    }
}


// 33:33 mapping of ff02::1:2
enum MACAddress ether_multicast_dhcp6 = MACAddress(0x33, 0x33, 0x00, 0x01, 0x00, 0x02);
