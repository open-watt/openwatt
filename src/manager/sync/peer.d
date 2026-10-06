module manager.sync.peer;

import urt.array;
import urt.endian : nativeToLittleEndian;
import urt.inet;
import urt.lifetime : move;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.meta.enuminfo : bitfield, VoidEnumInfo;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console.session : Session;
import manager.device : Device, DeviceBuilder, DeviceTable;
import manager.element : Access, Element;
import manager.features : is_tiny;
import manager.id : EID;
import manager.log;
import manager.series : FormatId;
import manager.syslog;
import manager.sync;
import manager.sync.binary_encoder : Verb;
import manager.sync.discovery : PeerRole;
import manager.sync.encoder;
import manager.sync.peering : SyncPeeringModule;

import router.iface;
import router.iface.endpoint : UDPEndpoint, UDPReceiveInfo, udp_open;
import router.iface.packet;
import router.iface.udp : UDPFrame;

nothrow @nogc:


alias log = Log!"sync";

// wide enough for a sibling transport's raw EIDs; foreign sessions allocate small dense values
alias SyncHandle = ulong;

// verb families served; negotiated by hello, build-time on each end
enum SyncCaps : ubyte
{
    objects = 1 << 0,   // legacy object mirror
    model   = 1 << 1,   // data-model space (add/val/sub)
    history = 1 << 2,
    console = 1 << 3,
    logs    = 1 << 4,
    time    = 1 << 5,
    console_session = 1 << 6,
    templates = 1 << 7, // understands `add {class:"component"}` shape refreshes
}

enum ubyte local_sync_caps = SyncCaps.objects | SyncCaps.model | SyncCaps.history | SyncCaps.console | SyncCaps.logs | SyncCaps.time | SyncCaps.console_session | SyncCaps.templates;

// reliability sublayer classification; values are the wire kind byte
enum TxQueue : ubyte
{
    control = 0,
    val     = 1,
    log     = 2,
}


class SyncPeer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("transport",      transport),
                                 Prop!("remote",         remote),
                                 Prop!("encoder",        encoder),
                                 Prop!("time-authority", time_authority),
                                 Prop!("claim",          claim));
nothrow @nogc:

    enum type_name = "peer";
    enum path = "/sync/peer";
    enum collection_id = CollectionType.sync_peer;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SyncPeer, id, flags);
    }

    // subscriptions outlive the session, so destruction from any state releases them
    ~this()
    {
        detach_transport();
        close_udp_endpoint();
    }

    // Properties

    final inout(BaseInterface) transport() inout pure
        => uses_udp_endpoint ? null : _transport.get;
    final void transport(BaseInterface value)
    {
        if (!uses_udp_endpoint && _transport is value)
            return;
        detach_transport();
        close_udp_endpoint();
        _peer_flags &= ~(PeerFlags.uses_udp_endpoint | PeerFlags.owns_udp_endpoint);
        _transport = value;
        _remote = InetAddress();
        _peer_flags &= ~PeerFlags.remote_bound;
        _remote_addr = InetAddress();
        mark_set!(typeof(this), [ "transport", "remote" ])();
        restart();
    }

    final InetAddress remote() const pure
        => _remote;
    final const(char)[] remote(InetAddress value)
    {
        if (value.family == AddressFamily.unspecified || value.addr_any || value.port == 0)
            return "remote needs a non-wildcard address and port";
        if (uses_udp_endpoint && owns_udp_endpoint && value == _remote)
            return null;

        detach_transport();
        close_udp_endpoint();
        _transport = null;
        _peer_flags |= PeerFlags.uses_udp_endpoint | PeerFlags.owns_udp_endpoint;
        _remote = value;
        _peer_flags &= ~PeerFlags.remote_bound;
        _remote_addr = InetAddress();
        mark_set!(typeof(this), [ "transport", "remote" ])();
        restart();
        return null;
    }

    final SyncEncoderKind encoder() const pure
        => _encoder;
    final void encoder(SyncEncoderKind value)
    {
        if (_encoder == value)
            return;
        _encoder = value;
        mark_set!(typeof(this), "encoder")();
        restart();
    }

    final bool time_authority() const pure
        => _time_authority;
    final void time_authority(bool value)
    {
        _time_authority_from_claim = false;
        set_time_authority(value);
    }

    // the hello announces authority on this session alone, whatever the node's peering role
    final bool claim() const pure
        => (_peer_flags & PeerFlags.claims) != 0;
    final void claim(bool value)
    {
        if (value == claim)
            return;
        if (value)
            _peer_flags |= PeerFlags.claims;
        else
            _peer_flags &= ~PeerFlags.claims;
        mark_set!(typeof(this), "claim")();
        restart();
    }

    final void bind_remote(ref const InetAddress addr)
    {
        _remote_addr = addr;
        _peer_flags |= PeerFlags.remote_bound;
    }

    final package void adopt_udp_endpoint(UDPEndpoint* endpoint)
    {
        remote(endpoint.remote);
        _udp_endpoint = endpoint;
    }

    final package void bind_udp_endpoint(UDPEndpoint* endpoint, ref const InetAddress remote)
    {
        assert(endpoint);
        detach_transport();
        close_udp_endpoint();
        _peer_flags |= PeerFlags.uses_udp_endpoint;
        _peer_flags &= ~(PeerFlags.owns_udp_endpoint | PeerFlags.remote_bound);
        _udp_endpoint = endpoint;
        _remote = remote;
        _remote_addr = InetAddress();
    }

    // Unreliable links wrap every frame with source/destination sessions and a kind.
    // Control uses ordered retransmission; val and log queues refold unacknowledged
    // records. Eviction bumps a durable queue epoch so the receiver declares the gap
    // and re-bases. Destination-session matching prevents stale streams from delivering
    // or acknowledging frames. Reliable, ordered transports skip this sublayer.

    // the largest sync frame one packet carries from here: the transport's limit less the carrier and the sublayer
    final uint local_segment()
    {
        import router.iface.udp : udp_carrier_ether, udp_carrier_v4, udp_carrier_v6;

        uint link;
        if (uses_udp_endpoint)
        {
            uint carrier = _remote.family == AddressFamily.ipv6 ? udp_carrier_v6 : _remote.family == AddressFamily.ether ? udp_carrier_ether : udp_carrier_v4;
            // a host stack routes for itself and names no egress; assume no more than the IPv6 minimum link
            BaseInterface egress = _udp_endpoint ? _udp_endpoint.egress_iface(_remote) : null;
            uint mtu = egress ? egress.actual_mtu : 1280;
            link = mtu > carrier ? mtu - carrier : 0;
        }
        else if (BaseInterface transport = _transport)
            link = transport.actual_mtu;
        uint overhead = sublayer_armed ? sublayer_overhead : 0;
        return link > overhead ? link - overhead : 0;
    }

    // what this side reassembles from fragments, never less than one segment
    final uint local_max_message()
    {
        uint segment = local_segment;
        return segment > reassembly_budget ? segment : reassembly_budget;
    }

    // the largest frame both ends carry in one packet
    final uint send_limit()
    {
        uint limit = local_segment;
        if (_remote_segment != 0 && _remote_segment < limit)
            limit = _remote_segment;
        if (_remote_max_message != 0 && _remote_max_message < limit)
            limit = _remote_max_message;
        return limit;
    }

    // the largest frame transmit_frame takes this session; past send_limit it travels as fragments
    final uint max_message(bool is_text)
        => is_text || _remote_version < fragments_since ? send_limit : _remote_max_message;

    final int transmit_frame(const(ubyte)[] frame, bool is_text = false, TxQueue queue = TxQueue.control)
    {
        if (!transport_ready)
        {
            _send_failed = true;
            return -1;
        }
        // refusals come before a frame is sequenced, so neither the session nor a burst fails with them
        if (frame.length > send_limit)
        {
            // the control plane carries it as fragments, toward a remote that reads them, one message at a time
            if (_frag_tx.length || frame.length > max_message(is_text))
                return -1;
            start_fragments(frame);
            return 0;
        }
        if (queue == TxQueue.control && _frag_tx.length)
            return -1;
        if (!sublayer_armed)
            return send_unwrapped(frame, is_text, queue == TxQueue.control);
        if (queue == TxQueue.control)
            return send_sequenced(frame);

        DataQueue* q = &_queues[queue - 1];
        DataEntry e;
        e.id = ++q.tx_id;
        e.first = getTime();
        e.payload ~= frame[];
        q.bytes += frame.length;
        q.backlog ~= e.move;
        // An acknowledged epoch starts a new declared gap; an unacknowledged epoch
        // absorbs later evictions so it never outruns the receiver by more than one.
        bool fresh_cycle = q.evicted == 0;
        bool evicted;
        while (q.backlog.length > 1 && (q.backlog.length > backlog_max_frames || q.bytes > backlog_limit))
        {
            q.bytes -= q.backlog[0].payload.length;
            q.backlog.remove(0);
            ++q.evicted;
            evicted = true;
        }
        if (evicted && (fresh_cycle || q.epoch_acked))
        {
            ++q.tx_epoch;
            q.epoch_acked = false;
        }
        send_data_frame(queue);
        return 0;
    }

    // Session name/handle binding. Local ids never travel: each side announces its
    // nodes by name (add_name) and allocates the session handle for the nodes it
    // introduces. A wire handle's low bit says who allocated it relative to the frame
    // it appears in: 0 = the frame's sender, 1 = the receiver, so the same handle value
    // flips its low bit crossing the wire. Handles are never reused; a slot whose
    // node dies resolves invalid forever, and a session (attach..detach) resets the
    // whole space.
    // The tables hold EIDs: element index 0 denotes the container itself, so one
    // handle space covers objects, devices and elements. SyncHandle is 64-bit because
    // sibling transports use raw EIDs as handles; foreign handles stay small dense ints.

    enum SyncHandle invalid_handle = SyncHandle.max;

    final SyncHandle introduce(BaseObject obj)
        => introduce(EID(obj.id));

    final SyncHandle introduce(EID node)
    {
        foreach (i, n; _introduced[])
            if (n == node)
                return SyncHandle(i) << 1;
        SyncHandle idx = _introduced.length;
        _introduced ~= node;
        return idx << 1;
    }

    // announced handles are sender-side, dense and ascending: a new one extends the table by exactly one
    final bool adoptable(SyncHandle handle) const pure
        => (handle & 1) == 0 && (handle >> 1) <= _adopted.length;

    final void adopt(SyncHandle handle, EID local)
    {
        if (!adoptable(handle))
        {
            log.warning("peer '", name[], "' announced an unusable handle ", handle);
            return;
        }
        size_t idx = cast(size_t)(handle >> 1);
        if (idx == _adopted.length)
            _adopted ~= EID.invalid;
        if (_adopted[idx] && _adopted[idx] != local)
        {
            log.warning("peer '", name[], "' re-announced handle ", handle, " for a different name");
            return;
        }
        _adopted[][idx] = local;
    }

    final SyncHandle handle_of(BaseObject obj)
        => handle_of(EID(obj.id));

    final SyncHandle handle_of(CID cid)
        => handle_of(EID(cid));

    final SyncHandle handle_of(EID node)
    {
        foreach (i, n; _adopted[])
            if (n == node)
                return (SyncHandle(i) << 1) | 1;
        foreach (i, n; _introduced[])
            if (n == node)
                return SyncHandle(i) << 1;
        return invalid_handle;
    }

    final EID node_of(SyncHandle handle)
    {
        size_t idx = cast(size_t)(handle >> 1);
        if (handle & 1)
            return idx < _introduced.length ? _introduced[idx] : EID.invalid;
        return idx < _adopted.length ? _adopted[idx] : EID.invalid;
    }

    // handles are announced in ascending order over the reliable in-order control
    // plane, so anything below the high-water mark has had its add delivered (even
    // if the node failed to materialise); anything above is still in flight
    final bool handle_announced(SyncHandle handle) const pure
        => (handle >> 1) < ((handle & 1) ? _introduced.length : _adopted.length);

    // legacy object-mirror accessor; dissolves with the mirror verbs
    final CID cid_of(SyncHandle handle)
        => node_of(handle).container;

    // Session schema interning: formats and named types push once per session,
    // always before the frame that first cites them. Interning is peer policy
    // (a sibling peer answers "always seen" and emits no type frames).

    // session ft for a local format; first=true when the definition must be pushed first
    final uint ft_of(FormatId f, out bool first)
    {
        size_t i = f;
        while (_ft_sent.length <= i)
            _ft_sent ~= ushort(0);
        if (_ft_sent[i] == 0)
        {
            first = true;
            _ft_sent[][i] = cast(ushort)++_next_ft;
        }
        return _ft_sent[i] - 1;
    }

    // true if this enum dictionary was already pushed; records it either way
    final bool enum_seen(const(VoidEnumInfo)* info)
    {
        foreach (e; _enums_sent[])
            if (e is info)
                return true;
        _enums_sent ~= info;
        return false;
    }

    final void forget(BaseObject obj)
    {
        EID node = EID(obj.id);
        foreach (ref n; _introduced[])
            if (n == node)
            {
                n = EID.invalid;
                return;
            }
    }

    // Log tap. request_logs asks the remote to stream us its logs (we hold the
    // desire and re-send on reconnect); set_log_sub is the remote asking us,
    // which registers our fan-out sink toward it. Both carry a severity + tag
    // filter; off clears.

    final void request_logs(Severity max_severity, bool off, const(char)[] tag)
    {
        _want_logs = !off;
        _want_log_severity = max_severity;
        _want_log_tag = tag.make_string();
        if (transport_ready)
            encoder_for(_encoder).encode_log_sub(this, max_severity, off, tag);
    }

    final void set_log_sub(Severity max_severity, bool off, const(char)[] tag)
    {
        if (off)
        {
            clear_log_sink();
            return;
        }

        _log_tag = tag.make_string();
        LogFilter filter;
        filter.max_severity = max_severity;
        filter.tag_prefix = _log_tag[];

        if (_log_active)
            get_module!LogModule.set_consumer_filter(_log_consumer, filter);
        else
        {
            _log_consumer = get_module!LogModule.register_consumer(filter);
            _log_active = _log_consumer.valid;
            if (!_log_active)
                log.warning("no free log sink slot for peer '", name[], "'");
        }
    }

    final void flush_logs()
    {
        if (!_log_active)
            return;

        SyncEncoder enc = encoder_for(_encoder);
        LogMessage msg;
        void* source;
        while (get_module!LogModule.next_message(_log_consumer, msg, source))
        {
            if (source !is cast(void*)this &&
                !enc.encode_log(this, format_syslog(msg)))
                break;
            get_module!LogModule.acknowledge(_log_consumer);
        }
    }

protected:

    override bool validate() const pure
        => uses_udp_endpoint || _transport !is null;

    // Idempotent; WS-spawned peers call this at accept time, because the client's
    // first frames can arrive before our first startup tick and unsubscribed
    // packets are dropped. Held across session restarts, until the transport is
    // destroyed or the peer stops.
    final package void subscribe_transport()
    {
        if (uses_udp_endpoint || (_peer_flags & PeerFlags.transport_subscribed) || !_transport)
            return;
        _transport.subscribe(&on_transport_state);
        // a remote-bound peer shares a multi-drop transport: its server routes rx by source
        // (deliver_frame). the interface holds few subscriber slots, so per-peer packet
        // subscriptions must not scale with peers.
        // unknown = all types; the handler takes raw and udp frames, so one peer object
        // sits on connected pipes and datagram transports alike
        if (!(_peer_flags & PeerFlags.remote_bound))
            _transport.subscribe(&on_transport_packet, PacketFilter(PacketType.unknown, PacketDirection.incoming));
        _peer_flags |= PeerFlags.transport_subscribed;
    }

    override CompletionStatus startup()
    {
        if (owns_udp_endpoint && !_udp_endpoint && !create_remote_endpoint())
            return CompletionStatus.error;
        subscribe_transport();
        if (!transport_ready)
            return CompletionStatus.continue_;

        if (_pre_start_overflow)
        {
            _pre_start_overflow = false;
            return CompletionStatus.error;   // gapped intake; establish from a fresh exchange
        }

        uint gen = begin_burst();
        int hello = encoder_for(_encoder).encode_hello(this);
        if (!send_ok(gen))
            return CompletionStatus.continue_;   // the refusal restarted us; a session without hello must not run
        if (hello < 0)
        {
            log.error("cannot fit hello in a ", send_limit, "-byte segment");
            return CompletionStatus.error;
        }
        get_module!SyncModule.attach_peer(this);
        _peer_flags |= PeerFlags.in_session;
        encoder_for(_encoder).encode_identity(this);

        // frames that arrived before the session existed join it now, in arrival order
        while (!_pre_start.empty)
        {
            Array!ubyte held = _pre_start[0].move;
            _pre_start.remove(0);
            _pre_start_bytes -= held.length;
            deliver_frame(held[]);
            if (_state != State.starting)
                return CompletionStatus.continue_;   // a refusal tore this fresh session down
        }

        if (_want_logs)
            encoder_for(_encoder).encode_log_sub(this, _want_log_severity, false, _want_log_tag[]);
        return CompletionStatus.complete;
    }

    override void online()
    {
        if (claim)
            get_module!SyncPeeringModule.claim_sibling(this, getTime());
    }

    override CompletionStatus shutdown()
    {
        if (get_module!SyncModule.cancel_inbound_cmds(this))
            return CompletionStatus.continue_;

        get_module!SyncModule.detach_peer(this);
        _peer_flags &= ~PeerFlags.in_session;
        // a session restart keeps its transport, and holds the next session's first frames for it
        if (_state == State.stopping || _state == State.destroying)
        {
            detach_transport();
            close_udp_endpoint();
        }
        else if (BaseInterface transport = _transport)
            transport.release_tx_handler(&produce_tx);

        // Peer-derived tap state dies with the stream; the desire to receive
        // (_want_*) persists so a reconnect re-subscribes.
        clear_log_sink();
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!transport_ready || !sublayer_armed)
            return;

        MonoTime now = getTime();
        foreach (ref s; _resend[])
        {
            if (now - s.sent < msecs(retransmit_ms << s.tries))
                continue;
            if (++s.tries > max_retries)
            {
                log.warning("peer '", name[], "' control frames unacknowledged; restarting session");
                restart();
                return;
            }
            s.sent = now;
            raw_tx(s.bytes[], false);
        }

        foreach (i, ref q; _queues)
        {
            bool fresh_cycle = q.evicted == 0;
            bool evicted;
            while (!q.backlog.empty && now - q.backlog[0].first > msecs(backlog_ttl_ms))
            {
                log.debug_("peer '", name[], "' aged out an unacked data frame");
                q.bytes -= q.backlog[0].payload.length;
                q.backlog.remove(0);
                ++q.evicted;
                evicted = true;
            }
            if (evicted && (fresh_cycle || q.epoch_acked))
            {
                ++q.tx_epoch;
                q.epoch_acked = false;
            }
            // an un-acked bump with nothing left to refold still needs announcing:
            // an empty frame carries the epoch until the receiver acks it
            if ((!q.backlog.empty || (q.evicted && !q.epoch_acked)) && now - q.last_tx >= msecs(data_flush_ms))
                send_data_frame(cast(TxQueue)(i + 1), true);
            // ageing freed room no ack will announce
            if (evicted)
                arm_tx();
        }

        ref DataQueue lq = _queues[TxQueue.log - 1];
        if (lq.evicted && lq.backlog.empty && lq.epoch_acked)
        {
            // the receiver stands on the bumped epoch: the repair can go out;
            // cleared first, the marker itself rides the log queue
            uint lost = lq.evicted;
            lq.evicted = 0;
            encoder_for(_encoder).encode_log(this, tconcat("[sync: ", lost, " log lines lost]"));
        }

        if ((_peer_flags & PeerFlags.ctl_ack_pending) || _queues[0].ack_pending || _queues[1].ack_pending)
        {
            begin_header(wire_ack);
            _rel_buf ~= _rx_delivered;
            _rel_buf ~= _queues[0].rx_epoch;
            _rel_buf ~= _queues[0].rx_seen;
            _rel_buf ~= _queues[1].rx_epoch;
            _rel_buf ~= _queues[1].rx_seen;
            _peer_flags &= ~PeerFlags.ctl_ack_pending;
            _queues[0].ack_pending = false;
            _queues[1].ack_pending = false;
            raw_tx(_rel_buf[], false);
        }
    }

    // Wait for the peer to acknowledge the gap before re-pushing current live values.
    final package bool take_val_repush()
    {
        ref DataQueue q = _queues[TxQueue.val - 1];
        if (!q.evicted || !q.backlog.empty || !q.epoch_acked)
            return false;
        q.evicted = 0;
        return true;
    }

package:
    struct PendingSub
    {
        String pattern;
        uint   res_seq;
        ulong  from_ms;
        ulong  to_ms;
        bool   arm;
        uint   device_cursor;
        uint   element_cursor;
        bool   device_sent;
        ulong  backfill_cursor = ulong.max;   // next unsent backfill record
    }

    // a device whose classification changed after this session may have been introduced to it
    struct PendingRefresh
    {
        CID  device;
        uint cursor;
    }

    final void attach_model_element(Device device, Element* element, Access access)
    {
        PeerBinding binding = model_binding(device);
        if (!binding)
        {
            binding = alloc!PeerBinding(this, device);
            _model_bindings ~= binding;
        }
        binding.attach(element, access);
        EID eid = element.ensure_eid();
        _live_nodes.remove(eid.raw);
        foreach (i, pending; _pending_vals[])
            if (pending == eid)
            {
                _pending_vals.remove(i);
                break;
            }
    }

    final void detach_model_bindings()
    {
        foreach (binding; _model_bindings)
        {
            binding.detach();
            free(binding);
        }
        _model_bindings.clear();
    }

    final void grant_claim_time_authority()
    {
        if (_time_authority)
            return;
        _time_authority_from_claim = true;
        set_time_authority(true);
    }

    final void revoke_claim_time_authority()
    {
        if (!_time_authority_from_claim)
            return;
        _time_authority_from_claim = false;
        set_time_authority(false);
    }

    Array!String     _subscriptions;
    Array!BaseObject _bound;             // objects we've sent bind{...} to this peer
    Array!BaseObject _authoritative;     // proxies we hold on this peer's behalf
    Array!EID        _introduced;        // handle table: nodes we announced (slot = handle >> 1)
    Array!EID        _adopted;           // handle table: local ids for names the peer announced
    uint[max_warned_names] _warned_names;
    ubyte            _warned_name_count;
    SyncEncoderKind  _encoder = SyncEncoderKind.binary;

    final bool first_sighting(const(char)[] name)
    {
        import urt.hash : fnv1a;
        uint h = fnv1a(cast(const(ubyte)[])name);
        foreach (t; _warned_names[0 .. _warned_name_count])
            if (t == h)
                return false;
        if (_warned_name_count == max_warned_names)
            return false;
        _warned_names[_warned_name_count++] = h;
        return true;
    }

    enum max_warned_names = 16;

    // bulk walks stop short of the window's end so the session's other control frames always find room
    enum control_reserve = 16;

    final bool control_starved()
        => sublayer_armed && _resend.length + control_reserve >= max_unacked;

    final bool control_room()
        => !control_starved() && (uses_udp_endpoint || _transport.tx_ready);

    // a bulk producer waits for the val backlog to take one more segment rather than evict
    final bool val_room()
        => !sublayer_armed || (_queues[TxQueue.val - 1].backlog.length < backlog_max_frames && _queues[TxQueue.val - 1].bytes + send_limit <= backlog_limit);

    // a pending fragmented message holds the control plane until its last fragment is submitted
    final bool tx_blocked()
        => _frag_tx.length != 0 || !control_room();

    // Transport readiness re-invites; control-window starvation waits for an ACK.
    final bool tx_full()
        => !control_starved() && !uses_udp_endpoint && !_transport.tx_ready;

    final bool produce_tx(BaseInterface)
    {
        _peer_flags |= PeerFlags.tx_producing;
        scope (exit) _peer_flags &= ~PeerFlags.tx_producing;
        if (!pump_fragments())
            return tx_full();
        return get_module!SyncModule.produce(this);
    }

    // fragments arrive in order and once each, on the session's control stream; a framing error resets the session
    final package void accept_fragment(ubyte flags, const(ubyte)[] slice)
    {
        bool first = (flags & fragment_first) != 0;
        if (slice.length == 0 || first == (_frag_rx.length != 0) || _frag_rx.length + slice.length > local_max_message)
        {
            log.warning("peer '", name[], "' sent a malformed fragment; restarting session");
            restart();
            return;
        }
        _frag_rx ~= slice;
        if (flags & fragment_more)
            return;
        Array!ubyte message = _frag_rx.move;
        if (message[0] == Verb.fragment)
        {
            log.warning("peer '", name[], "' nested a fragment; restarting session");
            restart();
            return;
        }
        encoder_for(_encoder).decode_and_dispatch(this, message[]);
    }

    final void arm_tx()
    {
        if ((_peer_flags & PeerFlags.tx_producing) || !transport_ready)
            return;
        if (uses_udp_endpoint)
            produce_tx(null);
        else
            _transport.tx_handler(&produce_tx);
    }

    // burst protocol: begin_burst, send, check send_ok after every send; refusal or teardown ends it
    final uint begin_burst()
    {
        // a condemned session stays failed until its replacement session starts
        if (_state == State.running || _state == State.starting)
            _send_failed = false;
        return _session_gen;
    }

    final bool send_ok(uint gen) const pure
        => !_send_failed && _session_gen == gen;

    uint             _intro_table;
    uint             _intro_slot;
    bool             _introducing;
    Array!(Array!ubyte) _pre_start;      // frames held until the session can process them
    uint             _pre_start_bytes;
    bool             _pre_start_overflow;
    enum pre_start_max = max_unacked;
    enum pre_start_max_bytes = 64 * 1024;
    bool             _send_failed;
    uint             _session_gen;       // bumped by detach_peer; a burst spanning it is dead

    enum uint min_segment = 32;   // below hello's size, so a peer that can handshake clears it

    ubyte            _remote_caps;       // hello negotiation; 0 = no hello received
    uint             _remote_version;    // 0 until hello
    uint             _remote_max_message; // 0 until hello
    uint             _remote_segment;    // 0 until hello, and from a peer that predates it
    ulong            _remote_node_id;    // hello identity; 0 = peer announced none
    PeerRole         _remote_role;
    String           _remote_cluster;
    ubyte[16]        _remote_nonce;      // session nonce from the peer's hello; anchors the claim HMAC
    bool             _remote_nonce_set;
    bool             _local_nonce_set;

    // our session nonce, sent in hello; fresh per session (cleared on detach)
    final const(ubyte)[] local_nonce()
    {
        if (!_local_nonce_set)
        {
            import urt.crypto.random : crypto_random_bytes;
            crypto_random_bytes(_local_nonce);
            _local_nonce_set = true;
        }
        return _local_nonce[];
    }
    Array!ushort     _ft_sent;           // FormatId -> session ft + 1; 0 = unsent
    uint             _next_ft;
    Array!(const(VoidEnumInfo)*) _enums_sent;
    Map!(uint, FormatId) _ft_recv;       // peer's session ft -> local format

    Array!String     _model_subs;        // armed live model patterns
    Map!(ulong, ulong) _live_nodes;      // EID.raw of armed nodes -> next unsent record index (point series)
    enum ulong live_parked = 1UL << 63;  // backfill owns the live cursor while parked
    Array!EID        _pending_vals;      // dirty matched nodes awaiting this tick's flush

    Array!PendingSub _pending_subs;
    Array!EID        _pending_live;
    Array!PendingRefresh _pending_refresh;
    bool             _live_rescan;
    uint             _rescan_cursor;
    enum max_pending_subs = 8;
    enum max_pending_live = 64;

    bool     _time_authority;
    bool     _time_authority_from_claim;
    bool     _time_subordinate;
    uint     _last_authority_version;
    uint     _time_seq;                  // 0 = no pull in flight
    MonoTime _time_t1;
    MonoTime _next_time_poll;

    LogConsumerHandle _log_consumer;
    bool _log_active;
    String _log_tag;

    // Inbound tap: we subscribed to the remote's logs. Persists across reconnect.
    bool     _want_logs;
    Severity _want_log_severity;
    String   _want_log_tag;

    Session _console_session;
    uint _console_seq;

private:
    PeerBinding model_binding(Device device)
    {
        foreach (binding; _model_bindings)
            if (binding.device is device)
                return binding;
        return null;
    }

    void set_time_authority(bool value)
    {
        if (_time_authority == value)
            return;
        _time_authority = value;
        _next_time_poll = getTime();
        mark_set!(typeof(this), "time-authority")();
    }

    enum retransmit_ms = 250;
    enum max_retries = 8;
    enum max_unacked = 64;
    enum reorder_cap = 16;
    enum reorder_span = 32;
    enum backlog_max_frames = 32;
    enum uint fragments_since = 2;
    enum uint reassembly_budget = is_tiny ? 8 * 1024 : ushort.max;
    enum ubyte fragment_first = 1 << 0;
    enum ubyte fragment_more = 1 << 1;
    // a data frame's header (sessions, kind, epochs and base) and one record's id and length; control's is smaller
    enum sublayer_overhead = 9 + 4 + 3;
    enum backlog_max_bytes = 1024;
    enum data_flush_ms = 300;
    // the retransmit schedule's full span: doubling intervals through max_retries
    // sends, plus the final wait before the session is declared dead
    enum control_horizon_ms = retransmit_ms * ((1 << (max_retries + 1)) - 1);
    // derived, not hand-picked: aging out a val whose add is still legitimately
    // retrying is real data loss, so the ttl must outlast any control-plane repair;
    // it exists only to unstick a poison orphan (add then destroy)
    enum backlog_ttl_ms = control_horizon_ms + 10_000;

    enum ubyte wire_ack = 3;   // TxQueue values are the other kind bytes

    @bitfield enum PeerFlags : ushort
    {
        none                       = 0,
        transport_subscribed       = 1 << 0,
        remote_bound               = 1 << 2,
        ctl_ack_pending            = 1 << 3,
        uses_udp_endpoint          = 1 << 4,
        owns_udp_endpoint          = 1 << 5,
        tx_producing               = 1 << 6,
        claims                     = 1 << 7,
        in_session                 = 1 << 8,
    }

    struct SentFrame
    {
        ubyte seq;
        ubyte tries;
        MonoTime sent;
        Array!ubyte bytes;   // full wire frame, header included; retransmit is a straight resend
    }
    struct HeldFrame
    {
        ubyte seq;
        Array!ubyte payload;
    }
    struct DataEntry
    {
        ubyte id;
        MonoTime first;
        Array!ubyte payload;
    }
    struct DataQueue
    {
        ubyte tx_id;         // last id assigned
        ubyte tx_epoch;      // bumped when an unacked entry is evicted: declared discontinuity
        ubyte rx_seen;       // watermark: last record accepted from the peer
        ubyte rx_epoch;      // the peer stream epoch the watermark belongs to
        bool  epoch_acked;   // the receiver has acked tx_epoch; gates repair and further bumps
        bool  ack_pending;
        ubyte tx_sent;       // last id a frame has carried
        uint  evicted;       // entries lost since the last repair (repush / lost marker)
        MonoTime last_tx;
        size_t bytes;
        Array!DataEntry backlog;   // unacked payloads, oldest first; every send refolds those one segment holds
    }

    union
    {
        ObjectRef!BaseInterface _transport;
        UDPEndpoint* _udp_endpoint;
    }
    InetAddress             _remote_addr;
    InetAddress             _remote;
    ubyte[16]               _local_nonce;
    uint                    _tx_session;
    uint                    _rx_session;
    ubyte                   _tx_seq;         // last sequence assigned
    ubyte                   _rx_delivered;   // cumulative in-order delivered
    PeerFlags               _peer_flags;
    Array!SentFrame         _resend;
    Array!HeldFrame         _reorder;
    Array!ubyte             _rel_buf;
    Array!ubyte             _frag_tx;        // the pending fragmented message, behind two spare bytes
    Array!ubyte             _frag_rx;        // the message being reassembled
    uint                    _frag_tx_sent;   // bytes of it submitted
    DataQueue[2]            _queues;         // val, log

    // two segments, so one can be in flight while the next is produced
    uint backlog_limit()
    {
        uint two = 2 * send_limit;
        return two > backlog_max_bytes ? two : backlog_max_bytes;
    }

    bool sublayer_armed()
    {
        enum promised = InterfaceCaps.reliable | InterfaceCaps.ordered;
        return uses_udp_endpoint || (_transport.caps & promised) != promised;
    }

    int raw_tx(const(ubyte)[] bytes, bool is_text)
    {
        if (uses_udp_endpoint)
            return _udp_endpoint.sendto(bytes, _remote) == bytes.length ? 0 : -1;

        Packet p;
        if (_peer_flags & PeerFlags.remote_bound)
            p.init!UDPFrame(bytes).address = _remote_addr;
        else
        {
            ref hdr = p.init!RawFrame(bytes);
            hdr.is_text = is_text;
        }
        return _transport.forward(p);
    }

    // a dispatched frame may restart the session and clear the hold, so each frame is taken
    // out before dispatch and the hold is re-read afterwards
    void drain_reorder()
    {
        for (;;)
        {
            size_t next = size_t.max;
            foreach (i, ref h; _reorder[])
            {
                if (h.seq == cast(ubyte)(_rx_delivered + 1))
                {
                    next = i;
                    break;
                }
            }
            if (next == size_t.max)
                return;
            HeldFrame h = _reorder[next].move;
            _reorder.remove(next);
            _rx_delivered = h.seq;
            encoder_for(_encoder).decode_and_dispatch(this, h.payload[]);
        }
    }

    void begin_header(ubyte kind)
    {
        if (_tx_session == 0)
            _tx_session = make_session_id();
        _rel_buf.clear();
        _rel_buf ~= nativeToLittleEndian(_tx_session);
        _rel_buf ~= nativeToLittleEndian(_rx_session);
        _rel_buf ~= kind;
    }

    // new records go out as they are queued and as acks free the segment; the flush timer resends
    void send_data_frame(TxQueue queue, bool resend = false)
    {
        DataQueue* q = &_queues[queue - 1];
        size_t budget = send_limit + sublayer_overhead;
        size_t take;
        size_t wire = sublayer_overhead - 3;
        while (take < q.backlog.length && (take == 0 || wire + 3 + q.backlog[take].payload.length <= budget))
            wire += 3 + q.backlog[take++].payload.length;
        ubyte last = take ? q.backlog[take - 1].id : q.tx_id;
        if (!resend && last == q.tx_sent)
            return;
        q.tx_sent = last;

        begin_header(queue);
        _rel_buf ~= q.tx_epoch;
        _rel_buf ~= q.rx_epoch;
        _rel_buf ~= q.rx_seen;
        // the id just before the refold: a newer epoch re-bases the receiver here,
        // which works even for the empty frame that announces a bump post-drain
        _rel_buf ~= q.backlog.empty ? q.tx_id : cast(ubyte)(q.backlog[0].id - 1);
        q.ack_pending = false;
        foreach (ref e; q.backlog[0 .. take])
        {
            _rel_buf ~= e.id;
            _rel_buf ~= cast(ubyte)e.payload.length;
            _rel_buf ~= cast(ubyte)(e.payload.length >> 8);
            _rel_buf ~= e.payload[];
        }
        q.last_tx = getTime();
        raw_tx(_rel_buf[], false);
    }

    void release_control(ubyte ack)
    {
        size_t held = _resend.length;
        while (!_resend.empty && cast(ubyte)(ack - _resend[0].seq) < 128)
            _resend.remove(0);
        if (_resend.length != held)
            arm_tx();
    }

    void release_data(TxQueue queue, ubyte ack)
    {
        DataQueue* q = &_queues[queue - 1];
        size_t held = q.backlog.length;
        while (!q.backlog.empty && cast(ubyte)(ack - q.backlog[0].id) < 128)
        {
            q.bytes -= q.backlog[0].payload.length;
            q.backlog.remove(0);
        }
        if (q.backlog.length == held)
            return;
        if (!q.backlog.empty)
            send_data_frame(queue);
        arm_tx();
    }

    static uint make_session_id()
    {
        import urt.crypto.random : crypto_random_bytes;
        align(size_t.sizeof) ubyte[4] b = void;
        uint id = 0;
        while (id == 0)
        {
            crypto_random_bytes(b);
            id = *cast(uint*)b.ptr;
        }
        return id;
    }

    void clear_log_sink()
    {
        if (!_log_active)
            return;
        get_module!LogModule.unregister_consumer(_log_consumer);
        _log_consumer = LogConsumerHandle.init;
        _log_active = false;
    }

    // control has no gap semantics: a refusal invalidates the session
    int send_unwrapped(const(ubyte)[] frame, bool is_text, bool control)
    {
        int r = raw_tx(frame, is_text);
        if (r < 0)
        {
            _send_failed = true;
            if (control && (_state == State.running || _state == State.starting))
            {
                log.warning("peer '", name[], "' control frame refused; restarting session");
                restart();
            }
        }
        return r;
    }

    int send_sequenced(const(ubyte)[] frame)
    {
        if (_resend.length >= max_unacked)
        {
            log.warning("peer '", name[], "' control queue overflow; restarting session");
            _send_failed = true;
            restart();
            return -1;
        }
        begin_header(TxQueue.control);
        _rel_buf ~= ++_tx_seq;
        _rel_buf ~= _rx_delivered;
        _peer_flags &= ~PeerFlags.ctl_ack_pending;
        _rel_buf ~= frame[];

        SentFrame s;
        s.seq = _tx_seq;
        s.sent = getTime();
        s.bytes ~= _rel_buf[];
        _resend ~= s.move;
        // accepted-means-enqueued: a failed first send just leaves the frame
        // to the retransmit path
        raw_tx(_rel_buf[], false);
        return 0;
    }

    void start_fragments(const(ubyte)[] message)
    {
        // two spare bytes in front: each fragment's verb and flags overwrite bytes already sent
        _frag_tx.resize(2 + message.length);
        _frag_tx[2 .. $] = message[];
        _frag_tx_sent = 0;
        if (!pump_fragments())
            arm_tx();
    }

    // true once the pending message has been submitted whole
    bool pump_fragments()
    {
        while (_frag_tx.length)
        {
            uint limit = send_limit;
            if (limit < min_segment)
            {
                log.warning("peer '", name[], "' segment fell to ", limit, " bytes mid-message; restarting session");
                _frag_tx.clear();
                restart();
                return true;
            }
            if (!control_room())
                return false;
            size_t remaining = _frag_tx.length - 2 - _frag_tx_sent;
            size_t slice = limit - 2;
            if (slice > remaining)
                slice = remaining;
            ubyte[] frame = _frag_tx[_frag_tx_sent .. _frag_tx_sent + 2 + slice];
            frame[0] = Verb.fragment;
            frame[1] = cast(ubyte)((_frag_tx_sent == 0 ? fragment_first : 0) | (slice < remaining ? fragment_more : 0));
            int sent = sublayer_armed ? send_sequenced(frame) : send_unwrapped(frame, false, true);
            _frag_tx_sent += cast(uint)slice;
            if (sent < 0 || slice == remaining)
                _frag_tx.clear();   // done, or the session is restarting
        }
        return true;
    }

    void detach_transport()
    {
        // the endpoint shares the transport's storage
        if (uses_udp_endpoint)
            return;
        BaseInterface transport = _transport;
        if (transport)
            transport.release_tx_handler(&produce_tx);
        if (!(_peer_flags & PeerFlags.transport_subscribed))
            return;
        if (transport)
        {
            transport.unsubscribe(&on_transport_state);
            transport.unsubscribe(&on_transport_packet);
        }
        _peer_flags &= ~PeerFlags.transport_subscribed;
    }

    bool transport_ready()
        => uses_udp_endpoint ? _udp_endpoint !is null : _transport && _transport.link_up;

    bool create_remote_endpoint()
    {
        _udp_endpoint = udp_open(null, &_remote, &on_udp_receive);
        return _udp_endpoint !is null;
    }

    void close_udp_endpoint()
    {
        if (uses_udp_endpoint && _udp_endpoint)
        {
            if (owns_udp_endpoint)
                _udp_endpoint.close();
            _udp_endpoint = null;
        }
    }

    final package void deliver_frame(const(ubyte)[] frame)
    {
        if (disabled)
            return;
        // frames are processed only inside a session; others wait for startup to drain them
        if (!(_peer_flags & PeerFlags.in_session))
        {
            if (_pre_start_overflow)
                return;
            if (_pre_start.length < pre_start_max && _pre_start_bytes + frame.length <= pre_start_max_bytes)
            {
                Array!ubyte held;
                held ~= frame[];
                _pre_start ~= held.move;
                _pre_start_bytes += frame.length;
            }
            else
            {
                // an unparsed drop may be control traffic, and this transport may not
                // retransmit: the whole prospective session is gapped, so refuse it
                log.warning("peer '", name[], "' pre-start frames overflowed; refusing the session");
                _pre_start.clear();
                _pre_start_bytes = 0;
                _pre_start_overflow = true;
                if (flags & ObjectFlags.dynamic)
                    disabled(true);   // reaped by the spawning server; the client reconnects fresh
            }
            return;
        }
        if (!sublayer_armed)
        {
            encoder_for(_encoder).decode_and_dispatch(this, frame);
            return;
        }

        if (frame.length < 10)
            return;
        uint src = frame[0] | frame[1] << 8 | frame[2] << 16 | frame[3] << 24;
        uint dst = frame[4] | frame[5] << 8 | frame[6] << 16 | frame[7] << 24;
        ubyte kind = frame[8];
        frame = frame[9 .. $];
        if (src == 0 || kind > wire_ack)
            return;

        if (dst != 0 && dst != _tx_session)
            return;   // straggler from a dead session, or not for us
        if (src != _rx_session)
        {
            // a matching dst proves freshness (no straggler knows our live session);
            // dst 0 passes only for a stream-opening hello
            if (dst == 0 && !(kind == TxQueue.control && frame[0] == 1))
                return;
            if (_rx_session != 0)
            {
                // the remote began a new stream: it rebooted, and the whole session
                // space (handles, interning, subs) must rebuild
                restart();
                return;
            }
            _rx_session = src;
        }

        if (kind == wire_ack)
        {
            if (frame.length < 5)
                return;
            release_control(frame[0]);
            if (frame[1] == _queues[0].tx_epoch)
            {
                release_data(TxQueue.val, frame[2]);
                _queues[0].epoch_acked = true;
            }
            if (frame[3] == _queues[1].tx_epoch)
            {
                release_data(TxQueue.log, frame[4]);
                _queues[1].epoch_acked = true;
            }
            return;
        }

        if (kind != TxQueue.control)
        {
            if (frame.length < 4)
                return;
            DataQueue* q = &_queues[kind - 1];
            ubyte epoch = frame[0];
            if (frame[1] == q.tx_epoch)
            {
                release_data(cast(TxQueue)kind, frame[2]);
                q.epoch_acked = true;
            }
            ubyte base = frame[3];
            frame = frame[4 .. $];

            byte age = cast(byte)(epoch - q.rx_epoch);
            if (age < 0)
                return;   // a stale-epoch straggler; its stream content is superseded
            q.ack_pending = true;
            if (age > 0)
            {
                // a declared discontinuity: whatever we never acked is gone, the
                // stream re-bases just below this frame's refold
                q.rx_epoch = epoch;
                q.rx_seen = base;
            }
            while (frame.length >= 3)
            {
                ubyte id = frame[0];
                size_t len = frame[1] | frame[2] << 8;
                frame = frame[3 .. $];
                if (len > frame.length)
                    return;
                ubyte dist = cast(ubyte)(id - q.rx_seen);
                if (dist != 0 && dist < 128)
                {
                    // an unapplicable record (val racing its add) stays unacked; the
                    // sender refolds it into its next frame, so stop at it and let
                    // that resupply this one's successors too
                    if (!encoder_for(_encoder).decode_and_dispatch(this, frame[0 .. len]))
                        return;
                    q.rx_seen = id;
                }
                frame = frame[len .. $];
            }
            return;
        }

        if (frame.length < 2)
            return;
        ubyte seq = frame[0];
        release_control(frame[1]);
        frame = frame[2 .. $];

        ubyte dist = cast(ubyte)(seq - _rx_delivered);
        if (dist == 0 || dist >= 128)
        {
            _peer_flags |= PeerFlags.ctl_ack_pending; // duplicate; our ack was lost
            return;
        }
        if (dist == 1)
        {
            _rx_delivered = seq;
            // raised before dispatch: a response transmitted from inside the decode
            // piggybacks the ack and lowers it again
            _peer_flags |= PeerFlags.ctl_ack_pending;
            encoder_for(_encoder).decode_and_dispatch(this, frame);
            drain_reorder();
        }
        else if (dist <= reorder_span && _reorder.length < reorder_cap)
        {
            foreach (ref h; _reorder[])
            {
                if (h.seq == seq)
                    return;
            }
            HeldFrame h;
            h.seq = seq;
            h.payload ~= frame[];
            _reorder ~= h.move;
        }
        // else: too far ahead or hold full; retransmission re-supplies it once the window moves
    }

    final package void reset_sublayer()
    {
        _frag_tx.clear();
        _frag_rx.clear();
        _frag_tx_sent = 0;
        _resend.clear();
        _reorder.clear();
        _tx_session = 0;
        _rx_session = 0;
        _tx_seq = 0;
        _rx_delivered = 0;
        _peer_flags &= ~PeerFlags.ctl_ack_pending;
        foreach (ref q; _queues)
        {
            q.backlog.clear();
            q.bytes = 0;
            q.tx_id = 0;
            q.tx_sent = 0;
            q.tx_epoch = 0;
            q.rx_seen = 0;
            q.rx_epoch = 0;
            q.epoch_acked = false;
            q.ack_pending = false;
            q.evicted = 0;
            q.last_tx = MonoTime.init;
        }
    }

    void on_transport_packet(ref const Packet p, BaseInterface, PacketDirection, void*) nothrow @nogc
    {
        if (p.type != PacketType.raw && p.type != PacketType.udp)
            return;
        deliver_frame(cast(const(ubyte)[])p.data);
    }

    final package void on_udp_receive(UDPEndpoint*, const(void)[] data, ref UDPReceiveInfo) nothrow @nogc
    {
        deliver_frame(cast(const(ubyte)[])data);
    }

    // a recreated transport is a new object, so a destroyed one takes the subscriptions with it
    void on_transport_state(ActiveObject, StateSignal sig) nothrow @nogc
    {
        if (sig == StateSignal.destroyed)
            _peer_flags &= ~PeerFlags.transport_subscribed;
        else if ((sig == StateSignal.offline || sig == StateSignal.link_down) && running)
            restart();
    }

    bool uses_udp_endpoint() const pure
        => (_peer_flags & PeerFlags.uses_udp_endpoint) != 0;

    bool owns_udp_endpoint() const pure
        => (_peer_flags & PeerFlags.owns_udp_endpoint) != 0;

    Array!PeerBinding _model_bindings;
}


private:

final class PeerBinding
{
nothrow @nogc:

    this(SyncPeer peer, Device device)
    {
        _peer = peer;
        _device = device;
    }

    inout(Device) device() inout pure
        => _device;

    void attach(Element* element, Access access)
    {
        EID eid = element.ensure_eid();
        assert(eid.container == _device.cid);
        ubyte index = _device.attach_binding(_peer, element, access, true);
        if (_binding_index == ubyte.max)
            _binding_index = index;
        else
            assert(_binding_index == index);
    }

    Access access(Element* element)
    {
        EID eid = element.ensure_eid();
        if (eid.container != _device.cid || _binding_index == ubyte.max || _binding_index >= _device.bindings.length)
            return Access.none;
        if (_device.bindings[_binding_index] !is _peer)
            return Access.none;
        foreach (entry; element.binding_entries)
        {
            if (entry == Element.binding_end)
                break;
            if (entry < Element.binding_destroyed && Element.binding_index(entry) == _binding_index)
                return Element.binding_access(entry);
        }
        return Access.none;
    }

    void detach()
    {
        _device.detach_binding(_peer);
        _binding_index = ubyte.max;
    }

private:
    SyncPeer _peer;
    Device _device;
    ubyte _binding_index = ubyte.max;
}


unittest
{
    SyncPeer peer = alloc!SyncPeer(CID(1));
    scope(exit) free(peer);

    peer.grant_claim_time_authority();
    assert(peer.time_authority);
    assert(peer._time_authority_from_claim);
    peer.revoke_claim_time_authority();
    assert(!peer.time_authority);
    assert(!peer._time_authority_from_claim);

    peer.time_authority(true);
    peer.grant_claim_time_authority();
    assert(!peer._time_authority_from_claim);
    peer.revoke_claim_time_authority();
    assert(peer.time_authority);

    peer.time_authority(false);
    peer.grant_claim_time_authority();
    peer.time_authority(true);
    assert(!peer._time_authority_from_claim);
    peer.revoke_claim_time_authority();
    assert(peer.time_authority);
}

unittest
{
    import urt.mem;

    SyncPeer a = alloc!SyncPeer(CID(1));
    scope(exit) free(a);
    SyncPeer b = alloc!SyncPeer(CID(2));
    scope(exit) free(b);

    // a refused transmit fails only its own peer's burst
    uint ga = a.begin_burst();
    uint gb = b.begin_burst();
    ubyte[3] frame = [1, 2, 3];
    assert(a.transmit_frame(frame[]) < 0);   // no transport
    assert(!a.send_ok(ga));
    assert(b.send_ok(gb));

    // a condemned session keeps its failure: begin_burst does not revive a detached peer
    // (revival happens only in a starting/running state, which startup() provides)
    a._send_failed = true;                   // detach_peer condemns...
    ++a._session_gen;                        // ...and bumps the generation
    ga = a.begin_burst();
    assert(!a.send_ok(ga));
    ga = a.begin_burst();
    assert(!a.send_ok(ga));                  // and it stays condemned across bursts

    // a teardown under an open burst on a live peer still ends it
    uint gb2 = b.begin_burst();
    assert(b.send_ok(gb2));
    ++b._session_gen;
    assert(!b.send_ok(gb2));

    // frames arriving before the session starts are held unprocessed; overflowing the
    // bound discards the intake and condemns the prospective session
    foreach (i; 0 .. SyncPeer.pre_start_max)
        b.deliver_frame(frame[]);
    assert(b._pre_start.length == SyncPeer.pre_start_max && !b._pre_start_overflow);
    b.deliver_frame(frame[]);
    assert(b._pre_start.empty && b._pre_start_overflow);
    b.deliver_frame(frame[]);
    assert(b._pre_start.empty);   // a condemned intake accepts nothing further

    // the byte bound condemns too: one oversized frame on a fresh peer
    SyncPeer c = alloc!SyncPeer(CID(3));
    scope(exit) free(c);
    ubyte[] big = alloc_array!ubyte(SyncPeer.pre_start_max_bytes + 1);
    scope(exit) free(big);
    assert(big.length == SyncPeer.pre_start_max_bytes + 1);
    c.deliver_frame(big);
    assert(c._pre_start.empty && c._pre_start_overflow);
}

unittest
{
    import manager.component : Component;
    import manager.device : DeviceTable;
    import manager.element : alloc_element;

    SyncPeer p = alloc!SyncPeer(CID(1));
    scope(exit) free(p);

    // announced handles extend the table by one; a sparse one can't size it
    assert(p.adoptable(0));
    assert(!p.adoptable(2));
    assert(!p.adoptable(1));
    assert(!p.adoptable(ulong.max - 1));

    p.adopt(0, EID(CID(2)));
    assert(p._adopted.length == 1);
    assert(p.adoptable(2));

    p.adopt(ulong.max - 1, EID(CID(3)));
    assert(p._adopted.length == 1);

    // an announcement that can't be resolved still advances, and resolves later
    p.adopt(2, EID.invalid);
    assert(p._adopted.length == 2);
    assert(p.adoptable(4));
    p.adopt(2, EID(CID(4)));
    assert(p._adopted[1] == EID(CID(4)));

    assert(p.first_sighting("wifi-ap"));
    assert(!p.first_sighting("wifi-ap"));
    assert(p.first_sighting("usb-serial"));

    foreach (i; 0 .. 16)
        p.first_sighting(tconcat("type", i));
    assert(p._warned_name_count == SyncPeer.max_warned_names);

    p._warned_name_count = 0;
    assert(p.first_sighting("wifi-ap"));

    char[] huge = alloc_array!char(40_000, 'x');
    scope(exit) free(huge);
    assert(huge.length == 40_000);
    assert(p.first_sighting(huge));
    assert(!p.first_sighting(huge));

    DeviceTable devices;
    DeviceBuilder builder = devices.create("peer-binding-test");
    Device device = builder.device;
    Component component = builder.component("status");
    Element* element = builder.element(component, "value");

    EID eid = element.ensure_eid();
    p._live_nodes.insert(eid.raw, 0);
    p._pending_vals ~= eid;
    p.attach_model_element(device, element, Access.read);
    assert(!p._live_nodes.exists(eid.raw) && p._pending_vals.empty);
    p.attach_model_element(device, element, Access.write);
    PeerBinding binding = p.model_binding(device);
    assert(device.bindings.length == 1 && device.bindings[0] is p);
    assert(device.binding_is_peer(0));
    enum relation = Element.binding_entry(0, Access.read_write);
    assert(element.binding_entries[] == [relation, ubyte.max, ubyte.max, ubyte.max]);
    assert(binding.access(element) == Access.read_write);
    p.detach_model_bindings();
    assert(device.bindings.length == 1 && !device.bindings[0]);
    assert(element.binding_entries[] == [Element.binding_destroyed, ubyte.max, ubyte.max, ubyte.max]);
}

unittest
{
    import urt.mem;
    import manager.series : register_value_format;
    import manager.sync.binary_encoder : Verb;

    static final class Narrow : BaseInterface
    {
        enum type_name = "sync-test-narrow";
    nothrow @nogc:

        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Narrow, id, flags);
            _caps = cast(InterfaceCaps)(InterfaceCaps.reliable | InterfaceCaps.ordered);
            _mtu = ushort.max;
            _state = State.running;
            set_link(true);
        }
        override bool tx_ready() const
            => pending < cap;
        override int transmit(ref Packet packet, MessageCallback, const(QueuePolicy)*)
        {
            pending += packet.length;
            if (pending > peak)
                peak = pending;
            if (packet.length > largest)
                largest = packet.length;
            ++frames;
            const(ubyte)[] f = cast(const(ubyte)[])packet.data;
            if (f.length && f[0] == Verb.val)
            {
                f = f[1 .. $];
                take_varint(f);
                lost += take_varint(f);
                delivered += take_varint(f);
            }
            return 0;
        }
        static ulong take_varint(ref const(ubyte)[] f)
        {
            ulong v;
            for (uint shift = 0; f.length; shift += 7)
            {
                ubyte b = f[0];
                f = f[1 .. $];
                v |= ulong(b & 0x7F) << shift;
                if (!(b & 0x80))
                    break;
            }
            return v;
        }
        size_t pending, peak, frames, largest;
        ulong delivered, lost;
        size_t cap = 4096;
    }

    Narrow link = Collection!Narrow().create("sync-test-narrow");
    SyncPeer peer = alloc!SyncPeer(CID(9));
    scope(exit)
    {
        free(peer);
        link.destroy();
        Collection!Narrow().table.free_pending();
    }
    peer._transport = link;

    DeviceTable devices;
    Element* power;
    {
        DeviceBuilder builder = devices.create("historian");
        power = builder.element(builder.component("meter"), "power", register_value_format!float());
        builder.commit();
    }
    enum records = 4000;
    power.retention(records);
    foreach (i; 0 .. records)
    {
        float[1] v = [float(i)];
        SysTime[1] t = [from_unix_time_ns((i + 1) * 1_000_000_000L)];
        power.write_samples(v[], t[]);
    }
    peer.introduce(power.ensure_eid());

    // Backfill spans multiple transport windows.
    import manager.sync.binary_encoder : BinaryEncoder;
    SyncEncoder enc = alloc!BinaryEncoder(null);
    scope(exit) free(enc);
    uint gen = peer.begin_burst();
    ulong resume = ulong.max;
    uint passes;
    ulong last = 0;
    while (!SyncModule.send_backfill(peer, enc, power, 1, 0, gen, resume))
    {
        assert(peer.send_ok(gen) && resume != ulong.max && resume > last);
        last = resume;
        link.pending = 0;
        ++passes;
    }
    assert(passes > 1 && resume == ulong.max && peer.send_ok(gen));
    assert(link.frames == (records + 255) / 256 && link.delivered == records && link.lost == 0);

    // The initial live cursor must not count as delivered history.
    peer._live_nodes.insert(power.ensure_eid().raw, power.record_count);
    ulong* live = power.ensure_eid().raw in peer._live_nodes;
    link.frames = 0;
    link.pending = link.cap;
    assert(!SyncModule.send_backfill(peer, enc, power, 1, 0, gen, resume) && link.frames == 0);
    assert(*live == (resume | SyncPeer.live_parked));

    // Live events wait behind a parked backfill.
    float[1] late = [float(records)];
    SysTime[1] late_time = [from_unix_time_ns((records + 1) * 1_000_000_000L)];
    power.write_samples(late[], late_time[]);
    SyncHandle handle = peer.handle_of(power.ensure_eid());
    SyncModule.send_live_events(peer, enc, power, handle, gen);
    assert(link.frames == 0 && *live == (resume | SyncPeer.live_parked));

    while (!SyncModule.send_backfill(peer, enc, power, 1, 0, gen, resume))
    {
        SyncModule.send_live_events(peer, enc, power, handle, gen);
        link.pending = 0;
    }
    assert(link.frames == (records + 1 + 255) / 256 && *live == records + 1);

    // The live flush must not duplicate the completed backfill.
    SyncModule.send_live_events(peer, enc, power, handle, gen);
    assert(link.frames == (records + 1 + 255) / 256);

    // Over a narrow link each block holds what one segment carries, and the walk still delivers every record.
    assert(link.mtu(200) is null && peer.send_limit == 200);
    link.frames = 0;
    link.pending = 0;
    link.largest = 0;
    link.delivered = 0;
    link.cap = size_t.max;
    resume = ulong.max;
    assert(SyncModule.send_backfill(peer, enc, power, 1, 0, gen, resume) && *live == records + 1);
    assert(link.largest <= 200 && link.frames > 4 * ((records + 1 + 255) / 256));
    assert(link.delivered == records + 1 && link.lost == 0);

    // A range ending mid-block stops at its last record, however the blocks were cut.
    resume = ulong.max;
    link.delivered = 0;
    assert(SyncModule.send_backfill(peer, enc, power, 1, 1000 * 1000, gen, resume) && *live == 1000);
    assert(link.delivered == 1000);

    // A record larger than any message the peer takes goes as an empty block declaring it lost, and the walk
    // and the live flush move past it instead of parking on it.
    assert(link.mtu(7) is null && peer.max_message(false) == 7);
    link.frames = 0;
    link.delivered = 0;
    resume = ulong.max;
    assert(SyncModule.send_backfill(peer, enc, power, 1, 1000 * 1000, gen, resume) && *live == 1000);
    assert(link.frames == 1000 && link.delivered == 0 && link.lost == 1000);
    assert(SyncModule.send_live_events(peer, enc, power, handle, gen) && *live == records + 1);
    assert(link.lost == records + 1 && peer.send_ok(gen));
    assert(link.mtu(200) is null);
    link.cap = 4096;
    assert(link.mtu(ushort.max) is null);

    // A frame over what both ends carry in one packet is refused before it is sequenced; the session stands.
    assert(peer.local_segment == ushort.max && peer.send_limit == ushort.max);
    peer._remote_segment = 1000;
    assert(peer.send_limit == 1000);
    ubyte[1001] frame;
    link.frames = 0;
    link.pending = 0;
    uint burst = peer.begin_burst();
    assert(peer.transmit_frame(frame[]) < 0 && peer.send_ok(burst) && link.frames == 0);
    assert(peer.transmit_frame(frame[0 .. 1000]) == 0 && link.frames == 1);
    assert(link.mtu(300) is null && peer.local_segment == 300 && peer.send_limit == 300);
    peer._remote_max_message = 200;
    assert(peer.send_limit == 200);

    // A server's peer shares its unconnected endpoint; the segment comes from the station toward the peer's own
    // destination, less the ether carrier and the sublayer.
    {
        import router.iface.bridge : BridgeInterface;
        import router.iface.endpoint : UDPReceiveInfo, udp_open;
        import router.iface.udp : udp_carrier_ether;

        static struct Sink
        {
            void recv(UDPEndpoint*, const(void)[], ref UDPReceiveInfo) nothrow @nogc {}
        }
        Sink sink;
        BridgeInterface station = Collection!BridgeInterface().create("sync-test-station");
        InetAddress local = InetAddress(station.mac.b, 4201);
        UDPEndpoint* shared_endpoint = udp_open(&local, null, &sink.recv, station);
        assert(shared_endpoint);
        SyncPeer served = alloc!SyncPeer(CID(10));
        scope (exit)
        {
            free(served);
            shared_endpoint.close();
            station.destroy();
            Collection!BridgeInterface().table.free_pending();
        }
        InetAddress destination = InetAddress(MACAddress(0x02, 0, 0, 0, 0, 9).b, 4201);
        served.bind_udp_endpoint(shared_endpoint, destination);
        assert(station.mtu(600) is null);
        assert(served.local_segment == 600 - udp_carrier_ether - SyncPeer.sublayer_overhead);
    }
}

unittest
{
    import manager.sync.binary_encoder : BinaryEncoder;

    static final class Capture : BaseInterface
    {
        enum type_name = "sync-test-capture";
    nothrow @nogc:

        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Capture, id, flags);
            _state = State.running;
            set_link(true);
        }
        void reliable(bool on)
        {
            _caps = on ? cast(InterfaceCaps)(InterfaceCaps.reliable | InterfaceCaps.ordered) : InterfaceCaps.none;
        }
        override bool tx_ready() const
            => frames.length < room;
        // a bounded link: the producer is invited when the test drains it, never inline
        override void tx_handler_changed() {}
        override int transmit(ref Packet packet, MessageCallback, const(QueuePolicy)*)
        {
            Array!ubyte f;
            f ~= cast(const(ubyte)[])packet.data;
            frames ~= f.move;
            return 0;
        }
        Array!(Array!ubyte) frames;
        size_t room = size_t.max;
    }

    static class Live : SyncPeer
    {
    nothrow @nogc:

        ~this() {}
        this(CID id)
        {
            super(id);
        }
        void live(bool v) { _state = v ? State.running : State.disabled; }

        // the session teardown needs the sync module; a reset is what the tests observe
        override CompletionStatus shutdown()
        {
            ++resets;
            return CompletionStatus.complete;
        }
        uint resets;
    }

    Capture link = Collection!Capture().create("sync-test-capture");
    Live peer = alloc!Live(CID(11));
    scope (exit)
    {
        peer.live(false);
        free(peer);
        link.destroy();
        Collection!Capture().table.free_pending();
    }
    peer._transport = link;
    link.reliable(true);
    assert(link.mtu(200) is null && peer.send_limit == 200);

    ubyte[1000] message;
    foreach (i, ref b; message)
        b = cast(ubyte)(i * 7);

    // toward a version-1 remote nothing is fragmented: an oversized message is refused as before
    peer._remote_version = 1;
    peer._remote_max_message = 65535;
    assert(peer.transmit_frame(message[]) < 0 && link.frames.length == 0);

    // a version-2 remote takes the message as flagged fragments that reassemble to it
    peer._remote_version = 2;
    assert(peer.transmit_frame(message[]) == 0 && !peer.tx_blocked());
    assert(link.frames.length == (message.length + 197) / 198);
    Array!ubyte joined;
    foreach (i, ref f; link.frames[])
    {
        assert(f.length <= 200 && f[0] == Verb.fragment);
        assert(((f[1] & SyncPeer.fragment_first) != 0) == (i == 0));
        assert(((f[1] & SyncPeer.fragment_more) != 0) == (i + 1 < link.frames.length));
        joined ~= f[2 .. $];
    }
    assert(joined[] == message[]);

    // backpressure halfway pauses it; another control message is refused meanwhile, data still flows
    link.frames.clear();
    link.room = 2;
    assert(peer.transmit_frame(message[]) == 0 && link.frames.length == 2 && peer.tx_blocked());
    ubyte[4] small = [1, 2, 3, 4];
    assert(peer.transmit_frame(small[]) < 0 && link.frames.length == 2);
    assert(peer.transmit_frame(small[], false, TxQueue.val) == 0 && link.frames.length == 3);
    link.room = size_t.max;
    assert(peer.pump_fragments() && !peer.tx_blocked());
    joined.clear();
    foreach (i, ref f; link.frames[])
        if (i != 2)
            joined ~= f[2 .. $];
    assert(joined[] == message[] && link.frames[2][] == small[]);

    // a message over the remote's budget is refused before its first fragment
    link.frames.clear();
    peer._remote_max_message = 500;
    assert(peer.transmit_frame(message[]) < 0 && link.frames.length == 0);

    // a limit with no room past the fragment header, met as a paused message resumes, restarts the session
    peer._remote_max_message = 65535;
    static immutable uint[3] limits = [1, 2, 3];
    foreach (limit; limits)
    {
        peer.live(true);
        peer._remote_segment = 0;
        link.frames.clear();
        link.room = 1;
        assert(peer.transmit_frame(message[]) == 0 && link.frames.length == 1 && peer._frag_tx.length);
        peer._remote_segment = limit;
        link.room = size_t.max;
        assert(peer.pump_fragments() && !peer._frag_tx.length && link.frames.length == 1);
        assert(!peer.running);
    }

    // two peers over lossy links, under the sublayer
    Capture link_b = Collection!Capture().create("sync-test-capture-b");
    Live remote = alloc!Live(CID(12));
    scope (exit)
    {
        remote.live(false);
        free(remote);
        link_b.destroy();
    }
    SyncEncoder enc = alloc!BinaryEncoder(null);
    scope (exit) free(enc);
    SyncEncoder previous = g_encoders[peer._encoder];
    g_encoders[peer._encoder] = enc;
    scope (exit) g_encoders[peer._encoder] = previous;

    remote._transport = link_b;
    link.reliable(false);
    link_b.reliable(false);
    peer._remote_segment = 0;
    assert(link_b.mtu(200) is null && peer.send_limit == 184 && remote.send_limit == 184);
    peer.live(true);
    remote.live(true);
    peer._tx_session = 0x1111;
    peer._rx_session = 0x2222;
    remote._tx_session = 0x2222;
    remote._rx_session = 0x1111;
    peer._peer_flags |= SyncPeer.PeerFlags.in_session;
    remote._peer_flags |= SyncPeer.PeerFlags.in_session;

    // a lost fragment, a lost last fragment and a duplicate: retransmission fills the gaps and the message arrives once
    ubyte[3000] lossy;
    foreach (i, ref b; lossy)
        b = cast(ubyte)(i * 5 + 1);
    lossy[0] = 0xFE;
    enum slice = 184 - 2;
    link.frames.clear();
    assert(peer.transmit_frame(lossy[]) == 0 && !peer._frag_tx.length);
    size_t count = link.frames.length;
    assert(count == (lossy.length + slice - 1) / slice);
    foreach (i, ref f; link.frames[])
    {
        if (i == 2 || i == count - 1)
            continue;
        remote.deliver_frame(f[]);
        if (i == 5)
            remote.deliver_frame(f[]);
    }
    assert(remote._frag_rx[] == lossy[0 .. 2 * slice] && remote._reorder.length == count - 4);

    link_b.frames.clear();
    remote.update();
    assert(link_b.frames.length == 1);
    peer.deliver_frame(link_b.frames[0][]);
    assert(peer._resend.length == count - 2);

    peer._resend[0].sent = getTime() - msecs(1000);
    peer._resend[$ - 1].sent = getTime() - msecs(1000);
    link.frames.clear();
    peer.update();
    assert(link.frames.length == 2);
    remote.deliver_frame(link.frames[0][]);
    assert(remote._frag_rx[] == lossy[0 .. (count - 1) * slice] && remote._reorder.empty);
    remote.deliver_frame(link.frames[1][]);
    assert(remote._frag_rx.empty && remote.running);

    // a message larger than the control window goes out a window at a time, each resumed by the remote's ack
    ubyte[65535] large;
    foreach (i, ref b; large)
        b = cast(ubyte)(i * 13);
    large[0] = 0xFE;
    link_b.frames.clear();
    remote.update();
    peer.deliver_frame(link_b.frames[0][]);
    link.frames.clear();
    assert(peer.transmit_frame(large[]) == 0 && peer.tx_blocked());
    enum window = SyncPeer.max_unacked - SyncPeer.control_reserve;
    size_t rounds;
    while (link.frames.length)
    {
        assert(link.frames.length <= window);
        foreach (ref f; link.frames[])
            remote.deliver_frame(f[]);
        link.frames.clear();
        assert(remote._frag_rx[] == large[0 .. remote._frag_rx.length]);
        link_b.frames.clear();
        remote.update();
        link.release_tx_handler(link.tx_handler);
        foreach (ref f; link_b.frames[])
            peer.deliver_frame(f[]);
        assert(peer._resend.empty && link.tx_handler !is null);
        peer.pump_fragments();
        ++rounds;
    }
    assert(rounds == ((large.length + slice - 1) / slice + window - 1) / window);
    assert(!peer._frag_tx.length && remote._frag_rx.empty && remote.running);

    // the val backlog sends what one segment holds; the next record waits for the ack that frees the segment
    ubyte[80] record;
    record[0] = 0xFE;
    link.frames.clear();
    foreach (i; 0 .. 3)
        assert(peer.transmit_frame(record[], false, TxQueue.val) == 0);
    assert(link.frames.length == 2 && link.frames[1].length <= 200 && peer._queues[0].backlog.length == 3);
    foreach (ref f; link.frames[])
        remote.deliver_frame(f[]);
    link.frames.clear();
    link_b.frames.clear();
    remote.update();
    link.release_tx_handler(link.tx_handler);
    peer.deliver_frame(link_b.frames[0][]);
    assert(link.frames.length == 1 && peer._queues[0].backlog.length == 1 && link.tx_handler !is null);

    // a bulk producer stops short of evicting: the backlog keeps room for one more segment or reports none
    assert(peer.val_room());
    while (peer.val_room())
        assert(peer.transmit_frame(record[], false, TxQueue.val) == 0);
    assert(peer._queues[0].evicted == 0 && peer._queues[0].bytes + peer.send_limit > peer.backlog_limit);

    // a session reset mid-message discards the partial message, and the next one starts clean
    link.frames.clear();
    assert(peer.transmit_frame(lossy[]) == 0);
    remote.deliver_frame(link.frames[0][]);
    assert(remote._frag_rx.length == slice);
    remote.reset_sublayer();
    assert(remote._frag_rx.empty);
    remote.accept_fragment(SyncPeer.fragment_first | SyncPeer.fragment_more, lossy[0 .. slice]);
    assert(remote._frag_rx[] == lossy[0 .. slice] && remote.running);

    // framing errors reset the session: a second first fragment, a stray continuation, a nested fragment
    remote.accept_fragment(SyncPeer.fragment_first, lossy[0 .. 10]);
    assert(!remote.running);
    remote.live(true);
    remote._frag_rx.clear();
    remote.accept_fragment(0, lossy[0 .. 10]);
    assert(!remote.running);
    remote.live(true);
    ubyte[3] nested = [Verb.fragment, SyncPeer.fragment_first, 0];
    remote.accept_fragment(SyncPeer.fragment_first, nested[]);
    assert(!remote.running && remote._frag_rx.empty);
}
