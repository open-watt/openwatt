module manager.sync.peer;

import urt.array;
import urt.inet;
import urt.lifetime : move;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.string;
import urt.string.format : tstring;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.id : EID;
import manager.log;
import manager.series : FormatId;
import manager.syslog;
import manager.sync;
import manager.sync.discovery : PeerRole;
import manager.sync.encoder;

import router.iface;
import router.iface.packet;
import router.iface.udp : UDPFrame, UDPInterface;

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
}

enum ubyte local_sync_caps = SyncCaps.objects | SyncCaps.model | SyncCaps.history | SyncCaps.console | SyncCaps.logs | SyncCaps.time;

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
                                 Prop!("time-authority", time_authority));
nothrow @nogc:

    enum type_name = "peer";
    enum path = "/sync/peer";
    enum collection_id = CollectionType.sync_peer;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SyncPeer, id, flags);
    }

    // Properties

    final inout(BaseInterface) transport() inout pure
        => _transport;
    final void transport(BaseInterface value)
    {
        if (_transport is value && !_owned_transport)
            return;
        detach_transport();
        destroy_owned_transport();
        _transport = value;
        _remote = InetAddress();
        _remote_bound = false;
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
        if (value == _remote)
            return null;

        detach_transport();
        destroy_owned_transport();
        _transport = null;
        _remote = value;
        _remote_bound = false;
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

    void bind_remote(ref const InetAddress addr)
    {
        _remote_addr = addr;
        _remote_bound = true;
    }

    // Unreliable links wrap every frame with source/destination sessions and a kind.
    // Control uses ordered retransmission; val and log queues refold unacknowledged
    // records. Eviction bumps a durable queue epoch so the receiver declares the gap
    // and re-bases. Destination-session matching prevents stale streams from delivering
    // or acknowledging frames. Reliable, ordered transports skip this sublayer.

    int transmit_frame(const(ubyte)[] frame, bool is_text = false, TxQueue queue = TxQueue.control)
    {
        if (!_transport || !_transport.running)
        {
            _send_failed = true;
            return -1;
        }
        if (!sublayer_armed)
        {
            int r = raw_tx(frame, is_text);
            if (r < 0)
            {
                _send_failed = true;
                // control has no gap semantics: a refusal invalidates the session
                if (queue == TxQueue.control && (_state == State.running || _state == State.starting))
                {
                    log.warning("peer '", name[], "' control frame refused; restarting session");
                    restart();
                }
            }
            return r;
        }

        if (queue == TxQueue.control)
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
            _ctl_ack_pending = false;
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
        while (q.backlog.length > 1 && (q.backlog.length > backlog_max_frames || q.bytes > backlog_max_bytes))
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

    SyncHandle introduce(BaseObject obj)
        => introduce(EID(obj.id));

    SyncHandle introduce(EID node)
    {
        foreach (i, n; _introduced[])
            if (n == node)
                return SyncHandle(i) << 1;
        SyncHandle idx = _introduced.length;
        _introduced ~= node;
        return idx << 1;
    }

    // announced handles are sender-side, dense and ascending: a new one extends the table by exactly one
    bool adoptable(SyncHandle handle) const pure
        => (handle & 1) == 0 && (handle >> 1) <= _adopted.length;

    void adopt(SyncHandle handle, EID local)
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

    SyncHandle handle_of(BaseObject obj)
        => handle_of(EID(obj.id));

    SyncHandle handle_of(CID cid)
        => handle_of(EID(cid));

    SyncHandle handle_of(EID node)
    {
        foreach (i, n; _adopted[])
            if (n == node)
                return (SyncHandle(i) << 1) | 1;
        foreach (i, n; _introduced[])
            if (n == node)
                return SyncHandle(i) << 1;
        return invalid_handle;
    }

    EID node_of(SyncHandle handle)
    {
        size_t idx = cast(size_t)(handle >> 1);
        if (handle & 1)
            return idx < _introduced.length ? _introduced[idx] : EID.invalid;
        return idx < _adopted.length ? _adopted[idx] : EID.invalid;
    }

    // handles are announced in ascending order over the reliable in-order control
    // plane, so anything below the high-water mark has had its add delivered (even
    // if the node failed to materialise); anything above is still in flight
    bool handle_announced(SyncHandle handle) const pure
        => (handle >> 1) < ((handle & 1) ? _introduced.length : _adopted.length);

    // legacy object-mirror accessor; dissolves with the mirror verbs
    CID cid_of(SyncHandle handle)
        => node_of(handle).container;

    // Session schema interning: formats and named types push once per session,
    // always before the frame that first cites them. Interning is peer policy
    // (a sibling peer answers "always seen" and emits no type frames).

    // session ft for a local format; first=true when the definition must be pushed first
    uint ft_of(FormatId f, out bool first)
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
    bool enum_seen(const(VoidEnumInfo)* info)
    {
        foreach (e; _enums_sent[])
            if (e is info)
                return true;
        _enums_sent ~= info;
        return false;
    }

    void forget(BaseObject obj)
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

    void request_logs(Severity max_severity, bool off, const(char)[] tag)
    {
        _want_logs = !off;
        _want_log_severity = max_severity;
        _want_log_tag = tag.make_string();
        if (_transport && _transport.running)
            encoder_for(_encoder).encode_log_sub(this, max_severity, off, tag);
    }

    void set_log_sub(Severity max_severity, bool off, const(char)[] tag)
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

    void flush_logs()
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
        => _transport !is null || _remote.family != AddressFamily.unspecified;

    // Idempotent; WS-spawned peers call this at accept time, because the client's
    // first frames can arrive before our first startup tick and unsubscribed
    // packets are dropped.
    package void subscribe_transport()
    {
        if (_transport_subscribed || !_transport)
            return;
        // a remote-bound peer shares a multi-drop transport: its server routes rx by source
        // (deliver_frame). the interface holds few subscriber slots, so per-peer packet
        // subscriptions must not scale with peers.
        if (_remote_bound)
            return;
        // unknown = all types; the handler takes raw and udp frames, so one peer object
        // sits on connected pipes and datagram transports alike
        _transport.subscribe(&on_transport_packet, PacketFilter(PacketType.unknown, PacketDirection.incoming));
        _transport_subscribed = true;
    }

    override CompletionStatus startup()
    {
        if (!_transport && _remote.family != AddressFamily.unspecified && !create_remote_transport())
            return CompletionStatus.error;
        if (!_transport || !_transport.running)
            return CompletionStatus.continue_;

        if (_pre_start_overflow)
        {
            _pre_start_overflow = false;
            return CompletionStatus.error;   // gapped intake; establish from a fresh exchange
        }

        subscribe_transport();

        uint gen = begin_burst();
        encoder_for(_encoder).encode_hello(this);
        if (!send_ok(gen))
            return CompletionStatus.continue_;   // the refusal restarted us; a session without hello must not run
        get_module!SyncModule.attach_peer(this);

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

    // the transport's state matters to a live session only: the subscription is the running window
    override void online()
    {
        if (BaseInterface transport = _transport)
        {
            transport.subscribe(&on_transport_state);
            _transport_state_subscribed = true;
        }
    }

    override void offline()
    {
        release_transport_state();
    }

    override CompletionStatus shutdown()
    {
        if (get_module!SyncModule.cancel_inbound_cmds(this))
            return CompletionStatus.continue_;

        get_module!SyncModule.detach_peer(this);
        detach_transport();
        destroy_owned_transport();

        // Peer-derived tap state dies with the stream; the desire to receive
        // (_want_*) persists so a reconnect re-subscribes.
        clear_log_sink();
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_transport || !_transport.running || !sublayer_armed)
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
                send_data_frame(cast(TxQueue)(i + 1));
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

        if (_ctl_ack_pending || _queues[0].ack_pending || _queues[1].ack_pending)
        {
            begin_header(wire_ack);
            _rel_buf ~= _rx_delivered;
            _rel_buf ~= _queues[0].rx_epoch;
            _rel_buf ~= _queues[0].rx_seen;
            _rel_buf ~= _queues[1].rx_epoch;
            _rel_buf ~= _queues[1].rx_seen;
            _ctl_ack_pending = false;
            _queues[0].ack_pending = false;
            _queues[1].ack_pending = false;
            raw_tx(_rel_buf[], false);
        }
    }

    // Wait for the peer to acknowledge the gap before re-pushing current live values.
    package bool take_val_repush()
    {
        ref DataQueue q = _queues[TxQueue.val - 1];
        if (!q.evicted || !q.backlog.empty || !q.epoch_acked)
            return false;
        q.evicted = 0;
        return true;
    }

package:
    void grant_claim_time_authority()
    {
        if (_time_authority)
            return;
        _time_authority_from_claim = true;
        set_time_authority(true);
    }

    void revoke_claim_time_authority()
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
    uint[max_unknown_types] _unknown_types;   // hashed type names this peer announced that we lack
    ubyte            _unknown_type_count;
    SyncEncoderKind  _encoder = SyncEncoderKind.binary;

    // a peer that carries a type we lack announces every object of it; warn once per type.
    // the name is hashed, never retained: it is peer-controlled and unbounded on the wire
    bool first_sighting_of_unknown_type(const(char)[] type)
    {
        import urt.hash : fnv1a;
        uint h = fnv1a(cast(const(ubyte)[])type);
        foreach (t; _unknown_types[0 .. _unknown_type_count])
            if (t == h)
                return false;
        if (_unknown_type_count == max_unknown_types)
            return false;
        _unknown_types[_unknown_type_count++] = h;
        return true;
    }

    enum max_unknown_types = 8;

    // bulk walks stop short of the window's end so the session's other control frames always find room
    enum control_reserve = 16;

    size_t control_window_free()
        => !sublayer_armed ? size_t.max : (_resend.length >= max_unacked ? 0 : max_unacked - _resend.length);

    // burst protocol: begin_burst, send, check send_ok after every send; refusal or teardown ends it
    uint begin_burst()
    {
        // a condemned session stays failed until its replacement session starts
        if (_state == State.running || _state == State.starting)
            _send_failed = false;
        return _session_gen;
    }

    bool send_ok(uint gen) const pure
        => !_send_failed && _session_gen == gen;

    uint             _intro_table;
    uint             _intro_slot;
    bool             _introducing;
    Array!(Array!ubyte) _pre_start;      // frames held until the session can process them
    uint             _pre_start_bytes;
    bool             _pre_start_overflow;
    // sized for a full control window arriving before the first tick starts the peer
    enum pre_start_max = max_unacked;
    enum pre_start_max_bytes = 64 * 1024;
    bool             _send_failed;
    uint             _session_gen;       // bumped by detach_peer; a burst spanning it is dead

    ubyte            _remote_caps;       // hello negotiation; 0 = no hello received
    ulong            _remote_node_id;    // hello identity; 0 = peer announced none
    PeerRole         _remote_role;
    String           _remote_cluster;
    ubyte[16]        _remote_nonce;      // session nonce from the peer's hello; anchors the claim HMAC
    bool             _remote_nonce_set;
    bool             _local_nonce_set;

    // our session nonce, sent in hello; fresh per session (cleared on detach)
    const(ubyte)[] local_nonce()
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
    Array!EID        _pending_vals;      // dirty matched nodes awaiting this tick's flush

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

private:
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
        uint  evicted;       // entries lost since the last repair (repush / lost marker)
        MonoTime last_tx;
        size_t bytes;
        Array!DataEntry backlog;   // unacked payloads, oldest first; every send refolds them all
    }

    ObjectRef!BaseInterface _transport;
    ObjectRef!UDPInterface  _owned_transport;
    bool                    _transport_subscribed;
    bool                    _transport_state_subscribed;
    bool                    _remote_bound;
    bool                    _ctl_ack_pending;
    InetAddress             _remote_addr;
    InetAddress             _remote;
    ubyte[16]               _local_nonce;
    uint                    _tx_session;
    uint                    _rx_session;
    ubyte                   _tx_seq;         // last sequence assigned
    ubyte                   _rx_delivered;   // cumulative in-order delivered
    Array!SentFrame         _resend;
    Array!HeldFrame         _reorder;
    Array!ubyte             _rel_buf;
    DataQueue[2]            _queues;         // val, log

    bool sublayer_armed()
    {
        enum promised = InterfaceCaps.reliable | InterfaceCaps.ordered;
        return (_transport.caps & promised) != promised;
    }

    int raw_tx(const(ubyte)[] bytes, bool is_text)
    {
        Packet p;
        if (_remote_bound)
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
        put_u32(_rel_buf, _tx_session);
        put_u32(_rel_buf, _rx_session);
        _rel_buf ~= kind;
    }

    void send_data_frame(TxQueue queue)
    {
        DataQueue* q = &_queues[queue - 1];
        begin_header(queue);
        _rel_buf ~= q.tx_epoch;
        _rel_buf ~= q.rx_epoch;
        _rel_buf ~= q.rx_seen;
        // the id just before the refold: a newer epoch re-bases the receiver here,
        // which works even for the empty frame that announces a bump post-drain
        _rel_buf ~= q.backlog.empty ? q.tx_id : cast(ubyte)(q.backlog[0].id - 1);
        q.ack_pending = false;
        foreach (ref e; q.backlog[])
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
        while (!_resend.empty && cast(ubyte)(ack - _resend[0].seq) < 128)
            _resend.remove(0);
    }

    static void release_data(ref DataQueue q, ubyte ack)
    {
        while (!q.backlog.empty && cast(ubyte)(ack - q.backlog[0].id) < 128)
        {
            q.bytes -= q.backlog[0].payload.length;
            q.backlog.remove(0);
        }
    }

    static uint make_session_id()
    {
        import urt.crypto.random : crypto_random_bytes;
        ubyte[4] b = void;
        uint id = 0;
        while (id == 0)
        {
            crypto_random_bytes(b);
            id = *cast(uint*)b.ptr;
        }
        return id;
    }

    static void put_u32(ref Array!ubyte buf, uint v)
    {
        buf ~= cast(ubyte)v;
        buf ~= cast(ubyte)(v >> 8);
        buf ~= cast(ubyte)(v >> 16);
        buf ~= cast(ubyte)(v >> 24);
    }

    void clear_log_sink()
    {
        if (!_log_active)
            return;
        get_module!LogModule.unregister_consumer(_log_consumer);
        _log_consumer = LogConsumerHandle.init;
        _log_active = false;
    }

    void detach_transport()
    {
        release_transport_state();
        if (!_transport_subscribed)
            return;
        if (BaseInterface transport = _transport)
            transport.unsubscribe(&on_transport_packet);
        _transport_subscribed = false;
    }

    void release_transport_state()
    {
        if (!_transport_state_subscribed)
            return;
        if (BaseInterface transport = _transport)
            transport.unsubscribe(&on_transport_state);
        _transport_state_subscribed = false;
    }

    bool create_remote_transport()
    {
        const(char)[] transport_name = Collection!UDPInterface().generate_name(tconcat(name[], "-udp"));
        UDPInterface transport = Collection!UDPInterface().create(transport_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
        if (!transport)
            return false;

        transport.remote_host(tstring(_remote).make_string());
        transport.remote_port(_remote.port);
        _owned_transport = transport;
        _transport = transport;
        return true;
    }

    void destroy_owned_transport()
    {
        if (UDPInterface transport = _owned_transport)
        {
            _owned_transport = null;
            transport.destroy();
        }
    }

    package void deliver_frame(const(ubyte)[] frame)
    {
        if (disabled)
            return;
        // frames are processed only inside a session; pre-start arrivals wait for startup to drain them
        if (_state != State.starting && _state != State.running)
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
                release_data(_queues[0], frame[2]);
                _queues[0].epoch_acked = true;
            }
            if (frame[3] == _queues[1].tx_epoch)
            {
                release_data(_queues[1], frame[4]);
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
                release_data(*q, frame[2]);
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
            _ctl_ack_pending = true;   // duplicate; our ack was lost
            return;
        }
        if (dist == 1)
        {
            _rx_delivered = seq;
            // raised before dispatch: a response transmitted from inside the decode
            // piggybacks the ack and lowers it again
            _ctl_ack_pending = true;
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

    package void reset_sublayer()
    {
        _resend.clear();
        _reorder.clear();
        _tx_session = 0;
        _rx_session = 0;
        _tx_seq = 0;
        _rx_delivered = 0;
        _ctl_ack_pending = false;
        foreach (ref q; _queues)
        {
            q.backlog.clear();
            q.bytes = 0;
            q.tx_id = 0;
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

    void on_transport_state(ActiveObject, StateSignal sig) nothrow @nogc
    {
        if (sig == StateSignal.offline)
            restart();
    }
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
    ubyte[SyncPeer.pre_start_max_bytes + 1] big;
    c.deliver_frame(big[]);
    assert(c._pre_start.empty && c._pre_start_overflow);
}

unittest
{
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
}

unittest
{
    SyncPeer p = alloc!SyncPeer(CID(1));
    scope(exit) free(p);

    assert(p.first_sighting_of_unknown_type("wifi-ap"));
    assert(!p.first_sighting_of_unknown_type("wifi-ap"));
    assert(p.first_sighting_of_unknown_type("usb-serial"));

    // a peer cannot grow the table, whatever it announces
    foreach (i; 0 .. 16)
        p.first_sighting_of_unknown_type(tconcat("type", i));
    assert(p._unknown_type_count == SyncPeer.max_unknown_types);

    p._unknown_type_count = 0;
    assert(p.first_sighting_of_unknown_type("wifi-ap"));

    // a name the wire allows but String cannot hold is hashed like any other
    char[40_000] huge = 'x';
    assert(p.first_sighting_of_unknown_type(huge[]));
    assert(!p.first_sighting_of_unknown_type(huge[]));
}
