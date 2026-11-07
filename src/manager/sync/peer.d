module manager.sync.peer;

import urt.array;
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
import manager.features : has_rdp, is_tiny;
import manager.id : EID;
import manager.log;
import manager.series : FormatId;
import manager.syslog;
import manager.sync;
import manager.sync.binary_encoder : Verb;
import manager.sync.console : SyncConsoleStream;
import manager.sync.discovery : PeerRole;
import manager.sync.encoder;
import manager.sync.peering : SyncPeeringModule;

import router.iface;
import router.iface.endpoint : UDPReceiveInfo;
import router.iface.packet;
import router.stream : max_tx_page;

static if (has_rdp)
    import router.iface.rdp;

nothrow @nogc:


alias log = Log!"sync";

// wide enough for a sibling transport's raw EIDs; foreign sessions allocate small dense values
alias SyncHandle = ulong;

// verb families served; negotiated by hello, build-time on each end
enum SyncCaps : ubyte
{
    objects = 1 << 0,   // legacy object mirror
    model   = 1 << 1,   // data-model space (add/val/sub)
    console = 1 << 2,
    logs    = 1 << 3,
    time    = 1 << 4,
    console_session = 1 << 5,
    templates = 1 << 6, // understands `add {class:"component"}` shape refreshes
}

enum ubyte local_sync_caps = SyncCaps.objects | SyncCaps.model | SyncCaps.console | SyncCaps.logs | SyncCaps.time | SyncCaps.console_session | SyncCaps.templates;

// a refused control frame ends the session; a refused val or log is backpressure its producer keeps
enum TxQueue : ubyte
{
    control,
    val,
    log,
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
        _tx_waiter = TxWaiter(&produce_tx);
    }

    // subscriptions outlive the session, so destruction from any state releases them
    ~this()
    {
        detach_transport();
        close_rdp();
    }

    // Properties

    final inout(BaseInterface) transport() inout pure
        => uses_rdp ? null : _transport.get;
    final void transport(BaseInterface value)
    {
        if (!uses_rdp && _transport is value)
            return;
        detach_transport();
        close_rdp();
        _peer_flags &= ~(PeerFlags.uses_rdp | PeerFlags.owns_rdp);
        _transport = value;
        _remote = InetAddress();
        mark_set!(typeof(this), [ "transport", "remote" ])();
        restart();
    }

    final InetAddress remote() const pure
        => _remote;
    final const(char)[] remote(InetAddress value)
    {
        static if (!has_rdp)
            return "this build has no RDP sessions";
        else
        {
            if (value.family == AddressFamily.unspecified || value.addr_any || value.port == 0)
                return "remote needs a non-wildcard address and port";
            if (uses_rdp && owns_rdp && value == _remote)
                return null;

            detach_transport();
            close_rdp();
            _transport = null;
            _peer_flags |= PeerFlags.uses_rdp | PeerFlags.owns_rdp;
            _remote = value;
            mark_set!(typeof(this), [ "transport", "remote" ])();
            restart();
            return null;
        }
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

    static if (has_rdp)
    {
        // a dialled endpoint, opened with this peer's handlers; the peer owns it from here
        final package void adopt_rdp(RDPEndpoint* endpoint, ref const InetAddress remote)
        {
            this.remote(remote);
            _rdp = endpoint;
        }

        // one session of a server's listening endpoint, which the server owns
        final package void bind_rdp_session(RDPEndpoint* endpoint, ref const InetAddress remote)
        {
            assert(endpoint);
            detach_transport();
            close_rdp();
            _peer_flags |= PeerFlags.uses_rdp;
            _peer_flags &= ~PeerFlags.owns_rdp;
            _rdp = endpoint;
            _remote = remote;
        }

        final package void on_rdp_message(RDPEndpoint*, const(void)[] message, PCP, ref UDPReceiveInfo)
        {
            deliver_frame(cast(const(ubyte)[])message);
        }

        final package void on_rdp_event(RDPEndpoint*, ref const InetAddress, RDPEvent event)
        {
            if (event == RDPEvent.writable)
                arm_tx();
            else if (event == RDPEvent.closed && running)
                restart();
        }
    }

    // the largest sync frame one message carries from here
    final uint local_segment()
    {
        static if (has_rdp)
            if (uses_rdp)
                return _rdp ? _rdp.message_limit(_remote) : rdp_max_message;
        BaseInterface transport = _transport;
        return transport ? transport.actual_mtu : 0;
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
        => is_text || !_remote_max_message ? send_limit : _remote_max_message;

    // a value bundle goes ahead of the control frame that may cite its handles; a log bundle has its own lane
    final int transmit_frame(const(ubyte)[] frame, bool is_text = false, TxQueue queue = TxQueue.control)
    {
        if (queue == TxQueue.control && transport_ready && _bundle_queue != TxQueue.log && flush_bundle(true) < 0)
            return refused(true);
        return transmit_unbundled(frame, is_text, queue);
    }

    // a bundle goes out through here, as it cannot wait behind itself
    final int transmit_unbundled(const(ubyte)[] frame, bool is_text, TxQueue queue)
    {
        if (!transport_ready)
        {
            _send_failed = true;
            return -1;
        }
        // refusals come before a frame is sent, so neither the session nor a burst fails with them
        if (queue != TxQueue.control && !control_room())
            return -1;
        if (_frag_tx.length && queue != TxQueue.log)
        {
            // the model lane is ordered behind the train; values wait in their producers
            if (queue == TxQueue.val || frame.length > max_message(is_text))
                return -1;
            size_t held_bytes = frame.length;
            foreach (ref h; _frag_hold[])
                held_bytes += h.length;
            if (_frag_hold.length >= frag_hold_max || held_bytes > frag_hold_max_bytes)
                return refused(true);
            Array!ubyte held;
            held ~= frame[];
            _frag_hold ~= held.move;
            return 0;
        }
        if (frame.length > send_limit)
        {
            // the model lane carries it as fragments, toward a remote that reads them, one message at a time
            if (_frag_tx.length || frame.length > max_message(is_text))
                return -1;
            start_fragments(frame);
            return 0;
        }
        int r = raw_tx(frame, is_text, queue);
        return r < 0 ? refused(queue == TxQueue.control) : r;
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
        LogModule logs = get_module!LogModule;
        if (uint lost = logs.lost(_log_consumer))
        {
            if (!enc.encode_log(this, tconcat("[sync: ", lost, " log lines lost]")))
                return;
            logs.clear_lost(_log_consumer);
        }
        LogMessage msg;
        void* source;
        while (logs.next_message(_log_consumer, msg, source))
        {
            if (source !is cast(void*)this &&
                !enc.encode_log(this, format_syslog(msg)))
                break;
            logs.acknowledge(_log_consumer);
        }
    }

protected:

    override bool validate() const pure
        => uses_rdp || _transport !is null;

    // Idempotent; WS-spawned peers call this at accept time, because the client's
    // first frames can arrive before our first startup tick and unsubscribed
    // packets are dropped. Held across session restarts, until the transport is
    // destroyed or the peer stops.
    final package void subscribe_transport()
    {
        if (uses_rdp || (_peer_flags & PeerFlags.transport_subscribed) || !_transport)
            return;
        _transport.subscribe(&on_transport_state);
        // unknown = all types; the handler takes raw and udp frames, so one peer object
        // sits on connected pipes and datagram transports alike
        _transport.subscribe(&on_transport_packet, PacketFilter(PacketType.unknown, PacketDirection.incoming));
        _peer_flags |= PeerFlags.transport_subscribed;
    }

    override CompletionStatus startup()
    {
        static if (has_rdp)
            if (owns_rdp && !_rdp && !open_rdp())
                return CompletionStatus.error;
        subscribe_transport();
        if (!transport_ready)
            return CompletionStatus.continue_;

        enum promised = InterfaceCaps.reliable | InterfaceCaps.ordered;
        if (!uses_rdp && (_transport.caps & promised) != promised)
        {
            log.error("peer '", name[], "': transport '", _transport.name[], "' is not reliable and ordered; use remote= for a session over it");
            return CompletionStatus.error;
        }

        if (_pre_start_overflow)
        {
            _pre_start_overflow = false;
            return CompletionStatus.error;   // gapped intake; establish from a fresh exchange
        }

        _send_failed = false;
        uint gen = begin_burst();
        int hello = encoder_for(_encoder).encode_hello(this);
        if (!send_ok(gen))
            return CompletionStatus.error;
        if (hello < 0)
        {
            log.error("cannot fit hello in a ", send_limit, "-byte segment");
            return CompletionStatus.error;
        }
        get_module!SyncModule.attach_peer(this);
        _peer_flags |= PeerFlags.in_session;
        encoder_for(_encoder).encode_identity(this);

        // frames that arrived before the session existed join it now, in arrival order
        while (!_pre_start.empty && send_ok(gen))
        {
            Array!ubyte held = _pre_start[0].move;
            _pre_start.remove(0);
            _pre_start_bytes -= held.length;
            deliver_frame(held[]);
            if (_state != State.starting)
                return CompletionStatus.continue_;   // a dispatched frame tore this fresh session down
        }

        if (_want_logs && send_ok(gen))
            encoder_for(_encoder).encode_log_sub(this, _want_log_severity, false, _want_log_tag[]);
        // a refusal while starting fails startup, which the state machine retries after its backoff
        return send_ok(gen) ? CompletionStatus.complete : CompletionStatus.error;
    }

    override void online()
    {
        if (claim)
            get_module!SyncPeeringModule.claim_sibling(this, getTime());
    }

    override CompletionStatus shutdown()
    {
        _bundle.clear();
        _peer_flags &= ~PeerFlags.bundle_closed;
        // the module's drain reaps the cancelled commands once they finish
        foreach (cmd; _commands)
        {
            if (cmd.command)
                cmd.command.request_cancel();
            cmd.cancelled = true;
        }
        if (!_commands.empty)
            return CompletionStatus.continue_;

        get_module!SyncModule.detach_peer(this);
        _peer_flags &= ~PeerFlags.in_session;
        // a session restart keeps its transport, and holds the next session's first frames for it
        if (_state == State.stopping || _state == State.destroying)
        {
            detach_transport();
            close_rdp();
        }
        else
        {
            _tx_waiter.cancel();
            // the RDP session ends with this one, so the remote rebuilds too; a dialled endpoint reopens itself
            static if (has_rdp)
                if (owns_rdp && _rdp && _rdp.established(_remote))
                    _rdp.close_session(_remote);
        }

        // Peer-derived tap state dies with the stream; the desire to receive
        // (_want_*) persists so a reconnect re-subscribes.
        clear_log_sink();
        return CompletionStatus.complete;
    }

package:
    struct PendingSub
    {
        String pattern;
        ulong  from_ms;
        ulong  to_ms;
        ulong  range_cursor = ulong.max;   // the element's next record or span; max until its add is sent
        uint   seq;
        uint   points;                     // spans a one-shot range reduces to; 0 sends every record
        uint   device_cursor;
        uint   element_cursor;
        bool   arm;
        bool   device_sent;
    }

    // a device whose classification changed after this session may have been introduced to it
    struct PendingRefresh
    {
        CID  device;
        uint cursor;
    }

    final void arm(Element* e, EID node, ulong position)
    {
        if (node.raw in _live_nodes)
            return;
        _live_nodes.insert(node.raw, LiveNode(position));
        e.sync_arm();
    }

    // e is null once the element is gone
    final void disarm(Element* e, EID node)
    {
        if ((node.raw in _live_nodes) is null)
            return;
        _live_nodes.remove(node.raw);
        if (e)
            e.sync_disarm();
    }

    final void disarm_all()
    {
        foreach (raw; _live_nodes.keys)
        {
            EID node;
            node.raw = raw;
            if (Element* e = resolve_element(node))
                e.sync_disarm();
        }
        _live_nodes.clear();
    }

    struct LiveNode
    {
        ulong position;
        bool pending;   // listed in _pending_vals
        bool told_gap;  // the peer has the value as unknown since the gap before position
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
        disarm(element, eid);
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

    // producers stop at bulk's floor, so the session's control frames always find room above it
    final bool control_room()
    {
        static if (has_rdp)
            if (uses_rdp)
                return _rdp && _rdp.tx_ready(_remote, PCP.be);
        return _transport.tx_ready;
    }

    // a pending fragmented message holds the control plane until its last fragment is submitted
    final bool tx_blocked()
        => _frag_tx.length != 0 || bundle_kept() || !control_room();

    // the transport re-invites the producer once it has room again
    final bool tx_full()
        => bundle_kept() || !control_room();

    // a bundle the transport refused waits, closed, for the room that re-invites the producer
    final bool bundle_kept() const pure
        => (_peer_flags & PeerFlags.bundle_closed) != 0;

    final bool produce_tx(BaseInterface)
    {
        _peer_flags |= PeerFlags.tx_producing;
        scope (exit) _peer_flags &= ~PeerFlags.tx_producing;
        if (!pump_fragments() || flush_bundle() < 0)
            return tx_full();
        bool console_waiting = produce_console();
        bool more = get_module!SyncModule.produce(this);
        flush_bundle();
        return more || console_waiting;
    }

    // Value and log messages of one queue share a frame of up to a page, which goes before any other frame. One the
    // transport refuses is kept, closed, and messages offered behind it are refused, so their producers keep them.
    final int bundle(const(ubyte)[] message, TxQueue queue)
    {
        immutable bool json = _encoder == SyncEncoderKind.json;
        // room for a JSON separator and close
        size_t limit = (send_limit < max_tx_page ? send_limit : max_tx_page) - 2;
        if (_bundle.length && ((_peer_flags & PeerFlags.bundle_closed) || queue != _bundle_queue || _bundle.length + message.length > limit) && flush_bundle() < 0)
            return -1;
        if (message.length > limit)
            return transmit_unbundled(message, json, queue);
        if (json)
            _bundle ~= cast(ubyte)(_bundle.length ? ',' : '[');
        else if (_bundle.length)
            message = message[1 .. $];   // a binary val or log runs its records on behind the first one's verb
        _bundle ~= message;
        _bundle_queue = queue;
        return 0;
    }

    // ahead of control, the bundle takes control's admission, as it must go first
    final int flush_bundle(bool ahead_of_control = false)
    {
        if (!_bundle.length)
            return 0;
        immutable bool json = _encoder == SyncEncoderKind.json;
        if (json && !(_peer_flags & PeerFlags.bundle_closed))
            _bundle ~= cast(ubyte)']';
        _peer_flags |= PeerFlags.bundle_closed;
        int r = transmit_unbundled(_bundle[], json, ahead_of_control ? TxQueue.control : _bundle_queue);
        if (r == 0)
        {
            _bundle.clear();
            _peer_flags &= ~PeerFlags.bundle_closed;
        }
        return r;
    }

    // remote consoles and commands drain while the plane has room, and hold the producer while the transport is full
    final bool produce_console()
    {
        bool waiting;
        if (SyncConsoleStream stream = _console_session ? dyn_cast!SyncConsoleStream(_console_session.stream) : null)
            waiting = drain_console(stream);
        foreach (cmd; _commands)
            waiting |= drain_console(cmd.stream);
        return waiting;
    }

    private final bool drain_console(SyncConsoleStream stream)
    {
        stream.room_returned();
        return stream.tx_queued() && tx_full();
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
        if (!uses_rdp)
            _transport.wait_tx(_tx_waiter);
        else if (control_room())
            _tx_waiter.handler(null);
    }

    // burst protocol: begin_burst, send, check send_ok after every send; refusal or teardown ends it
    final uint begin_burst()
    {
        // a failure stays until its session restarts; startup clears it once, so every send it makes counts
        if (_state == State.running)
            _send_failed = false;
        return _session_gen;
    }

    final bool send_ok(uint gen) const pure
        => !_send_failed && _session_gen == gen;

    uint             _intro_table;
    uint             _intro_slot;
    uint             _bind_table;
    uint             _bind_slot;
    uint             _unbind_cursor;    // bound objects below it are yet to be checked against the subscriptions
    bool             _introducing;
    bool             _binding;          // a subscription's binds are still being walked
    Array!(Array!ubyte) _pre_start;      // frames held until the session can process them
    uint             _pre_start_bytes;
    bool             _pre_start_overflow;
    enum pre_start_max = 64;
    enum pre_start_max_bytes = 64 * 1024;
    bool             _send_failed;
    uint             _session_gen;       // bumped by detach_peer; a burst spanning it is dead

    enum uint min_segment = 32;   // below hello's size, so a peer that can handshake clears it

    ubyte            _remote_caps;       // hello negotiation; 0 = no hello received
    Array!ubyte      _bundle;            // messages of one queue collected for one frame
    TxQueue          _bundle_queue;
    uint             _remote_max_message; // 0 until hello
    uint             _remote_segment;    // 0 until hello
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
    Map!(ulong, LiveNode) _live_nodes;   // EID.raw of armed nodes -> next unsent record index
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
    Array!(InboundCmd*) _commands;

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

    enum uint reassembly_budget = is_tiny ? 8 * 1024 : ushort.max;
    enum ubyte fragment_first = 1 << 0;
    enum ubyte fragment_more = 1 << 1;
    enum frag_hold_max = 16;
    enum frag_hold_max_bytes = 4096;
    // control and values share a lane, so a val never overtakes its add; logs stand aside on a bulk lane
    enum model_lane = PCP.ca;
    enum log_lane = PCP.bk;

    @bitfield enum PeerFlags : ubyte
    {
        none                 = 0,
        transport_subscribed = 1 << 0,
        uses_rdp             = 1 << 1,
        owns_rdp             = 1 << 2,
        tx_producing         = 1 << 3,
        claims               = 1 << 4,
        in_session           = 1 << 5,
        bundle_closed        = 1 << 6,
    }

    union
    {
        ObjectRef!BaseInterface _transport;
        static if (has_rdp)
            RDPEndpoint* _rdp;
    }
    TxWaiter                _tx_waiter;
    InetAddress             _remote;
    Array!ubyte             _frag_tx;        // the pending fragmented message, behind two spare bytes
    Array!ubyte             _frag_rx;        // the message being reassembled
    Array!(Array!ubyte)     _frag_hold;      // control frames offered while the train is pending, in order
    ubyte[16]               _local_nonce;
    uint                    _frag_tx_sent;   // bytes of it submitted
    PeerFlags               _peer_flags;

    int raw_tx(const(ubyte)[] bytes, bool is_text, TxQueue queue)
    {
        StackPacket p;
        ref hdr = p.init!RawFrame(bytes);
        static if (has_rdp)
        {
            if (uses_rdp)
            {
                p.pcp = queue == TxQueue.log ? log_lane : model_lane;
                return _rdp.send(&p.packet, _remote) < 0 ? -1 : 0;
            }
        }
        hdr.is_text = is_text;
        return _transport.forward(&p.packet);
    }

    void clear_log_sink()
    {
        if (!_log_active)
            return;
        get_module!LogModule.unregister_consumer(_log_consumer);
        _log_consumer = LogConsumerHandle.init;
        _log_active = false;
    }

    // control has no gap semantics, so a refusal invalidates the session; a refused value or log is backpressure,
    // held in the bundle or by its producer
    int refused(bool control)
    {
        if (!control)
            return -1;
        _send_failed = true;
        if (_state == State.running)
        {
            log.warning("peer '", name[], "' control frame refused; restarting session");
            restart();
        }
        return -1;
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
            int sent = raw_tx(frame, false, TxQueue.control);
            if (sent < 0)
                refused(true);
            _frag_tx_sent += cast(uint)slice;
            if (sent < 0 || slice == remaining)
                _frag_tx.clear();   // done, or the session is restarting
            if (sent < 0)
                _frag_hold.clear();
        }
        // what waited behind the train goes in order; one that starts a train holds the rest again
        while (!_frag_hold.empty && !_frag_tx.length)
        {
            Array!ubyte held = _frag_hold[0].move;
            _frag_hold.remove(0);
            if (transmit_unbundled(held[], false, TxQueue.control) < 0)
            {
                refused(true);
                return true;
            }
        }
        return !_frag_tx.length;
    }

    void detach_transport()
    {
        _tx_waiter.cancel();
        // the endpoint shares the transport's storage
        if (uses_rdp)
            return;
        BaseInterface transport = _transport;
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
    {
        static if (has_rdp)
            if (uses_rdp)
                return _rdp && _rdp.established(_remote);
        return _transport && _transport.link_up;
    }

    static if (has_rdp)
    {
        bool open_rdp()
        {
            _rdp = rdp_open(null, &_remote, &on_rdp_message, &on_rdp_event);
            return _rdp !is null;
        }
    }

    void close_rdp()
    {
        static if (has_rdp)
        {
            if (uses_rdp && _rdp)
            {
                if (owns_rdp)
                    _rdp.close();
                _rdp = null;
            }
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
        encoder_for(_encoder).decode_and_dispatch(this, frame);
    }

    final package void clear_fragments()
    {
        _frag_tx.clear();
        _frag_rx.clear();
        _frag_hold.clear();
        _frag_tx_sent = 0;
    }

    void on_transport_packet(const(Packet)* p, BaseInterface, PacketDirection, void*) nothrow @nogc
    {
        if (p.type != PacketType.raw && p.type != PacketType.udp)
            return;
        deliver_frame(cast(const(ubyte)[])p.data);
    }

    // a recreated transport is a new object, so a destroyed one takes the subscriptions with it
    void on_transport_state(ActiveObject, StateSignal sig) nothrow @nogc
    {
        if (sig == StateSignal.destroyed)
            _peer_flags &= ~PeerFlags.transport_subscribed;
        else if ((sig == StateSignal.offline || sig == StateSignal.link_down) && running)
            restart();
    }

    bool uses_rdp() const pure
        => (_peer_flags & PeerFlags.uses_rdp) != 0;

    bool owns_rdp() const pure
        => (_peer_flags & PeerFlags.owns_rdp) != 0;

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
    p.arm(element, eid, 0);
    p._pending_vals ~= eid;
    assert(element.sync_peers == 1);
    p.attach_model_element(device, element, Access.read);
    assert(!p._live_nodes.exists(eid.raw) && p._pending_vals.empty && element.sync_peers == 0);
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
        override ubyte tx_floor() const
            => pending < cap ? 0 : tx_full;
        override int transmit(Packet* packet, MessageCallback, const(QueuePolicy)*)
        {
            scope (exit) packet_free(packet);
            if (refuse)
                return -1;
            pending += packet.length;
            if (pending > peak)
                peak = pending;
            if (packet.length > largest)
                largest = packet.length;
            ++frames;
            count(cast(const(ubyte)[])packet.data);
            return 0;
        }
        void count(const(ubyte)[] f)
        {
            if (!f.length || f[0] != Verb.val)
                return;
            for (f = f[1 .. $]; f.length; )
            {
                take_varint(f);
                take_varint(f);
                lost += take_varint(f);
                ulong n = take_varint(f);
                delivered += n;
                foreach (_; 0 .. n)
                {
                    take_varint(f);
                    // value tags on the wire: 3 and 4 a varint, 5 an f64, 6 a string; the test writes no others
                    ubyte tag = f[0];
                    f = f[1 .. $];
                    if (tag == 3 || tag == 4)
                        take_varint(f);
                    else if (tag == 5)
                        f = f[8 .. $];
                    else if (tag == 6)
                        f = f[cast(size_t)take_varint(f) .. $];
                }
            }
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
        bool refuse;
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

    // A range spans multiple transport windows, each pass resuming where the last stopped.
    import manager.sync.binary_encoder : BinaryEncoder;
    SyncEncoder enc = alloc!BinaryEncoder(null);
    scope(exit) free(enc);
    uint gen = peer.begin_burst();
    SyncHandle handle = peer.handle_of(power.ensure_eid());
    ulong position;
    bool range(SysTime to = SysTime(ulong.max))
    {
        bool told_gap;
        bool done = SyncModule.send_records(peer, enc, power, handle, position, told_gap, to, 1, gen);
        peer.flush_bundle();
        return done;
    }
    bool live_events()
    {
        bool done = SyncModule.send_live(peer, enc, power, handle, gen);
        peer.flush_bundle();
        return done;
    }
    uint passes;
    ulong last = 0;
    while (!range())
    {
        assert(peer.send_ok(gen) && position > last);
        last = position;
        link.pending = 0;
        ++passes;
    }
    assert(passes > 1 && position == records && peer.send_ok(gen));
    assert(link.frames == (records + 255) / 256 && link.delivered == records && link.lost == 0);

    // A feed armed from a time streams from the record holding then, through every later write, once.
    peer.arm(power, power.ensure_eid(), power.index_for_time(from_unix_time_ns(1000 * 1_000_000_000L)));
    SyncPeer.LiveNode* live = power.ensure_eid().raw in peer._live_nodes;
    assert(live.position == 999);
    float[1] late = [float(records)];
    SysTime[1] late_time = [from_unix_time_ns((records + 1) * 1_000_000_000L)];
    power.write_samples(late[], late_time[]);
    link.delivered = 0;
    while (!live_events())
        link.pending = 0;
    assert(link.delivered == records + 1 - 999 && live.position == records + 1);
    live_events();
    assert(link.delivered == records + 1 - 999);

    // A held element streams every change: armed without a store it sends its register first, and its first
    // change creates a sync store holding the register as record 0, so the stream continues from record 1.
    Element* level;
    {
        DeviceBuilder builder = devices.create("tank");
        level = builder.element(builder.component("meter"), "level", register_value_format!float());
        builder.commit();
    }
    EID level_node = level.ensure_eid();
    level.write_sample(1.0f, from_unix_time_ns(1_000_000_000L));
    peer.introduce(level_node);
    SyncHandle level_handle = peer.handle_of(level_node);
    peer.arm(level, level_node, SyncModule.live_start(level));
    SyncPeer.LiveNode* level_live = level_node.raw in peer._live_nodes;
    assert(!level.has_history && level_live.position == 0);
    SyncModule.mark_pending_val(peer, level_node);
    SyncModule.mark_pending_val(peer, level_node);
    assert(level_live.pending && peer._pending_vals.length == 1 && peer._pending_vals[0] == level_node);
    peer._pending_vals.clear();
    level_live.pending = false;
    link.pending = 0;
    link.delivered = 0;
    assert(SyncModule.send_register(peer, enc, level, level_handle));
    peer.flush_bundle();
    assert(link.delivered == 1 && level_live.position == 1);
    level.write_sample(2.0f, from_unix_time_ns(2_000_000_000L));
    level.write_sample(3.0f, from_unix_time_ns(3_000_000_000L));
    assert(level.has_history && level.record_count == 3);
    assert(SyncModule.send_live(peer, enc, level, level_handle, gen));
    peer.flush_bundle();
    assert(link.delivered == 3 && level_live.position == 3);

    // an invalidation reaches the peer once, as a null at its time, and the next value follows it
    level.invalidate(from_unix_time_ns(4_000_000_000L));
    assert(SyncModule.send_live(peer, enc, level, level_handle, gen));
    peer.flush_bundle();
    assert(link.delivered == 4 && level_live.told_gap && level_live.position == 3);
    assert(SyncModule.send_live(peer, enc, level, level_handle, gen));
    peer.flush_bundle();
    assert(link.delivered == 4);
    level.write_sample(6.0f, from_unix_time_ns(5_000_000_000L));
    assert(SyncModule.send_live(peer, enc, level, level_handle, gen));
    peer.flush_bundle();
    assert(link.delivered == 5 && !level_live.told_gap && level_live.position == 4);
    peer.disarm(level, level_node);
    assert(level.sync_peers == 0);

    Element* make_meter(const(char)[] device)
    {
        DeviceBuilder builder = devices.create(device);
        Element* m = builder.element(builder.component("meter"), "flow", register_value_format!float());
        builder.commit();
        return m;
    }

    // armed with no store: after its register was sent, an invalidation gives the element a store holding
    // that value as record 0, ended there, so the null follows it and the next value is record 1
    Element* flow = make_meter("pipe");
    EID flow_node = flow.ensure_eid();
    flow.write_sample(1.0f, from_unix_time_ns(1_000_000_000L));
    peer.introduce(flow_node);
    SyncHandle flow_handle = peer.handle_of(flow_node);
    peer.arm(flow, flow_node, SyncModule.live_start(flow));
    SyncPeer.LiveNode* flow_live = flow_node.raw in peer._live_nodes;
    link.delivered = 0;
    assert(SyncModule.send_register(peer, enc, flow, flow_handle));
    peer.flush_bundle();
    assert(link.delivered == 1 && flow_live.position == 1);
    flow.invalidate(from_unix_time_ns(2_000_000_000L));
    assert(flow.has_history && flow.record_count == 1);
    assert(SyncModule.send_live(peer, enc, flow, flow_handle, gen));
    peer.flush_bundle();
    assert(link.delivered == 2 && flow_live.told_gap);
    flow.write_sample(2.0f, from_unix_time_ns(3_000_000_000L));
    assert(SyncModule.send_live(peer, enc, flow, flow_handle, gen));
    peer.flush_bundle();
    assert(link.delivered == 3 && flow_live.position == 2 && !flow_live.told_gap);
    peer.disarm(flow, flow_node);

    // already unknown when armed: the peer is told so without the position moving, and the first value is record 0
    Element* idle = make_meter("valve");
    EID idle_node = idle.ensure_eid();
    idle.write_sample(1.0f, from_unix_time_ns(1_000_000_000L));
    idle.invalidate(from_unix_time_ns(2_000_000_000L));
    peer.introduce(idle_node);
    SyncHandle idle_handle = peer.handle_of(idle_node);
    peer.arm(idle, idle_node, SyncModule.live_start(idle));
    SyncPeer.LiveNode* idle_live = idle_node.raw in peer._live_nodes;
    link.delivered = 0;
    assert(SyncModule.send_register(peer, enc, idle, idle_handle));
    peer.flush_bundle();
    assert(link.delivered == 1 && idle_live.position == 0 && idle_live.told_gap);
    idle.write_sample(3.0f, from_unix_time_ns(3_000_000_000L));
    assert(idle.record_count == 1);
    assert(SyncModule.send_live(peer, enc, idle, idle_handle, gen));
    peer.flush_bundle();
    assert(link.delivered == 2 && idle_live.position == 1 && !idle_live.told_gap);
    peer.disarm(idle, idle_node);

    // reads of introduced elements share a frame, each element's samples a group under the read's seq
    link.frames = 0;
    Element*[3] read = [level, flow, idle];
    foreach (e; read)
    {
        ulong at = 0;
        bool told_gap;
        assert(SyncModule.send_records(peer, enc, e, peer.handle_of(e.ensure_eid()), at, told_gap, SysTime(ulong.max), 7, gen));
    }
    peer.flush_bundle();
    assert(link.frames == 1);

    // a point read of an event series answers its latest retained event, where a live feed waits for the next
    Element* bell;
    {
        import manager.series : DataFormat, register_format, SeriesKind, ValueType;

        static immutable DataFormat press = DataFormat(ValueType.u8, SeriesKind.point);
        DeviceBuilder builder = devices.create("door");
        bell = builder.element(builder.component("button"), "press", register_format(press));
        builder.commit();
    }
    bell.retention(16);
    bell.write_sample(ubyte(1), from_unix_time_ns(1_000_000_000L));
    peer.introduce(bell.ensure_eid());
    ulong first = SyncModule.read_start(bell, 0);
    assert(first == 0 && SyncModule.live_start(bell) == 1);
    link.delivered = 0;
    bool bell_gap;
    assert(SyncModule.send_records(peer, enc, bell, peer.handle_of(bell.ensure_eid()), first, bell_gap, SysTime(ulong.max), 7, gen));
    peer.flush_bundle();
    assert(link.delivered == 1);

    // Over a narrow link each block holds what one segment carries, and the walk still delivers every record.
    assert(link.mtu(200) is null && peer.send_limit == 200);
    link.frames = 0;
    link.pending = 0;
    link.largest = 0;
    link.delivered = 0;
    link.cap = size_t.max;
    position = 0;
    assert(range() && position == records + 1);
    assert(link.largest <= 200 && link.frames > 4 * ((records + 1 + 255) / 256));
    assert(link.delivered == records + 1 && link.lost == 0);

    // A range ending mid-block stops at its last record, however the blocks were cut.
    position = 0;
    link.delivered = 0;
    assert(range(from_unix_time_ns(1000 * 1_000_000_000L)) && position == 1000);
    assert(link.delivered == 1000);

    // A record larger than any message the peer takes goes as an empty block declaring it lost, and the walk
    // and the live flush move past it instead of parking on it.
    assert(link.mtu(7) is null && peer.max_message(false) == 7);
    link.frames = 0;
    link.delivered = 0;
    position = 0;
    assert(range(from_unix_time_ns(1000 * 1_000_000_000L)) && position == 1000);
    assert(link.frames == 1000 && link.delivered == 0 && link.lost == 1000);
    live.position = 1000;
    assert(live_events() && live.position == records + 1);
    assert(link.lost == records + 1 && peer.send_ok(gen));
    assert(link.mtu(200) is null);
    link.cap = 4096;
    assert(link.mtu(ushort.max) is null);

    // a refused block parks the walk where it stood and leaves the session standing; the producer stays armed, and
    // the transport's room callback sends what was kept before the walk resumes
    link.refuse = true;
    link.delivered = 0;
    link.pending = 0;
    live.position = 0;
    assert(!live_events() && live.position < records + 1 && peer.send_ok(gen));
    link.refuse = false;
    while (!live_events())
        link.pending = 0;
    assert(link.delivered == records + 1 && live.position == records + 1 && peer.send_ok(gen));

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
        override ubyte tx_floor() const
            => frames.length < room ? 0 : tx_full;
        override int transmit(Packet* packet, MessageCallback, const(QueuePolicy)*)
        {
            scope (exit) packet_free(packet);
            if (refuse)
                return -1;
            Array!ubyte f;
            f ~= cast(const(ubyte)[])packet.data;
            frames ~= f.move;
            return 0;
        }
        Array!(Array!ubyte) frames;
        size_t room = size_t.max;
        bool refuse;
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
        uint held;
        // producing needs the sync module; a held turn is what the tests observe
        bool hold(BaseInterface)
        {
            ++held;
            return true;
        }
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
    peer._tx_waiter.handler = &peer.hold;
    link.reliable(true);
    assert(link.mtu(200) is null && peer.send_limit == 200);

    ubyte[1000] message;
    foreach (i, ref b; message)
        b = cast(ubyte)(i * 7);

    // values collect into one frame, which closes before the segment and before any other frame
    {
        peer._encoder = SyncEncoderKind.json;
        scope (exit) peer._encoder = SyncEncoderKind.binary;
        ubyte[40] msg = 'v';
        msg[0] = '{';
        msg[$ - 1] = '}';
        link.frames.clear();
        foreach (_; 0 .. 3)
            assert(peer.bundle(msg[], TxQueue.val) == 0);
        assert(link.frames.length == 0 && peer._bundle.length == 3 * 41);
        peer.flush_bundle();
        assert(link.frames.length == 1 && link.frames[0].length == 3 * 41 + 1);
        assert(link.frames[0][0] == '[' && link.frames[0][$ - 1] == ']');
        link.frames.clear();
        foreach (_; 0 .. 10)
            assert(peer.bundle(msg[], TxQueue.val) == 0);
        peer.flush_bundle();
        assert(link.frames.length == 3, "ten 40-byte values over a 200-byte segment take three frames");
        foreach (ref f; link.frames[])
            assert(f.length <= 200 && f[0] == '[' && f[$ - 1] == ']');
        link.frames.clear();

        // a refused frame is kept and goes first; a value offered behind it is refused, and nothing overtakes it
        foreach (_; 0 .. 2)
            assert(peer.bundle(msg[], TxQueue.val) == 0);
        link.refuse = true;
        uint burst = peer.begin_burst();
        assert(peer.flush_bundle() < 0 && peer._bundle.length == 2 * 41 + 1);
        assert(peer.bundle(msg[], TxQueue.val) < 0 && peer.bundle(msg[], TxQueue.log) < 0);
        assert(peer.send_ok(burst) && peer.tx_blocked() && peer.tx_full(), "backpressure holds the producer armed; the session stands");
        assert(peer.produce_tx(link) && peer.bundle_kept(), "the room callback retries the kept bundle first, and stays armed while it is refused");
        link.refuse = false;
        assert(peer.bundle(msg[], TxQueue.val) == 0 && link.frames.length == 1 && link.frames[0].length == 2 * 41 + 1);
        assert(peer.flush_bundle() == 0 && link.frames.length == 2 && !peer.tx_blocked());
        link.frames.clear();

        // binary records run on behind the first one's verb, and a message for the other queue closes the frame
        peer._encoder = SyncEncoderKind.binary;
        msg[0] = Verb.val;
        foreach (_; 0 .. 2)
            assert(peer.bundle(msg[], TxQueue.val) == 0);
        msg[0] = Verb.log;
        assert(peer.bundle(msg[], TxQueue.log) == 0 && link.frames.length == 1 && link.frames[0].length == 2 * 40 - 1);
        assert(link.frames[0][0] == Verb.val && link.frames[0][1 .. 40] == msg[1 .. $] && link.frames[0][40 .. $] == msg[1 .. $]);
        assert(peer.flush_bundle() == 0 && link.frames.length == 2 && link.frames[1][] == msg[]);
        link.frames.clear();
    }

    // a message over the segment goes as flagged fragments that reassemble to it
    peer._remote_max_message = 65535;
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

    // backpressure halfway pauses it; a control message waits behind the train in order, a value in its producer
    link.frames.clear();
    link.room = 2;
    assert(peer.transmit_frame(message[]) == 0 && link.frames.length == 2 && peer.tx_blocked());
    ubyte[4] small = [1, 2, 3, 4];
    assert(peer.transmit_frame(small[]) == 0 && link.frames.length == 2 && peer._frag_hold.length == 1);
    peer._remote_max_message = 600;
    ubyte[700] unsendable;
    assert(peer.transmit_frame(unsendable[]) < 0 && peer._frag_hold.length == 1, "the hold takes only what it can send");
    peer._remote_max_message = 65535;
    assert(peer.transmit_frame(small[], false, TxQueue.val) < 0 && link.frames.length == 2);
    link.room = size_t.max;
    assert(peer.pump_fragments() && !peer.tx_blocked() && peer._frag_hold.empty);
    joined.clear();
    foreach (ref f; link.frames[0 .. $ - 1])
        joined ~= f[2 .. $];
    assert(joined[] == message[] && link.frames[$ - 1][] == small[]);

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

    // a second peer, which reassembles what the first sends
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
    remote._tx_waiter.handler = &remote.hold;
    link_b.reliable(true);
    peer._remote_segment = 0;
    assert(link_b.mtu(200) is null && peer.send_limit == 200 && remote.send_limit == 200);
    peer.live(true);
    remote.live(true);
    peer._peer_flags |= SyncPeer.PeerFlags.in_session;
    remote._peer_flags |= SyncPeer.PeerFlags.in_session;

    ubyte[3000] long_message;
    foreach (i, ref b; long_message)
        b = cast(ubyte)(i * 13);
    enum slice = 200 - 2;

    // a session reset mid-message discards the partial message, and the next one starts clean
    link.frames.clear();
    assert(peer.transmit_frame(long_message[]) == 0);
    remote.deliver_frame(link.frames[0][]);
    assert(remote._frag_rx.length == slice);
    remote.clear_fragments();
    assert(remote._frag_rx.empty);
    remote.accept_fragment(SyncPeer.fragment_first | SyncPeer.fragment_more, long_message[0 .. slice]);
    assert(remote._frag_rx[] == long_message[0 .. slice] && remote.running);

    // framing errors reset the session: a second first fragment, a stray continuation, a nested fragment
    remote.accept_fragment(SyncPeer.fragment_first, long_message[0 .. 10]);
    assert(!remote.running);
    remote.live(true);
    remote._frag_rx.clear();
    remote.accept_fragment(0, long_message[0 .. 10]);
    assert(!remote.running);
    remote.live(true);
    ubyte[3] nested = [Verb.fragment, SyncPeer.fragment_first, 0];
    remote.accept_fragment(SyncPeer.fragment_first, nested[]);
    assert(!remote.running && remote._frag_rx.empty);

    // a remote console's output waits while the peer cannot take it, and follows the wake that frees it
    {
        import manager.console : Console;
        import manager.sync.console : SyncConsoleStream;
        import router.stream : Stream;

        SyncConsoleStream stream = Collection!SyncConsoleStream().create("relay-test");
        stream.peer(peer);
        stream.sequence(1);
        Collection!Stream().update_all();
        assert(stream.running);
        Console* console = alloc!Console(null, StringLit!"test.relay");
        Session session = alloc!Session(Collection!Session().allocate_id("relay-session"), ObjectFlags.none, *console);
        session.stream(stream);
        Collection!Session().add(session);
        peer._console_session = session;
        char[3000] text = 'a';

        // a full transport invites the peer back, and the peer keeps its turn until the console drains
        link.frames.clear();
        peer._tx_waiter.cancel();
        link.room = 0;
        assert(stream.send_bytes(text[]) && link.frames.length == 0);
        assert(peer._tx_waiter.waiting, "a full transport arms the peer");
        link.room = 4;
        assert(peer.produce_console() && link.frames.length == 4);
        link.room = size_t.max;
        assert(!peer.produce_console() && stream.tx_queued() == 0);

        // a code point cut between pages goes out whole, though the line is full when it completes
        char[2 + 3 * 100] euros = void;
        euros[0 .. 2] = "ab";
        foreach (i; 0 .. 100)
            euros[2 + 3 * i .. 5 + 3 * i] = "€";
        link.frames.clear();
        assert(stream.send_bytes(euros[0 .. 150]) && link.frames.length == 1);
        link.room = 1;
        assert(stream.send_bytes(euros[150 .. 152]) && link.frames.length == 1 && stream.tx_queued() == 2);
        link.room = size_t.max;
        assert(!peer.produce_console() && stream.tx_queued() == 0 && link.frames.length == 2);
        assert(stream.send_bytes(euros[152 .. $]) && stream.tx_queued() == 0);
        Array!char relayed;
        foreach (ref f; link.frames[])
        {
            size_t at = 3;
            size_t length = f[at] & 0x7F;
            if (f[at++] & 0x80)
                length |= size_t(f[at++]) << 7;
            const(char)[] data = cast(const(char)[])f[at .. $];
            assert(data.length == length && (data[0] & 0xC0) != 0x80, "each frame starts on a code point");
            relayed ~= data;
        }
        assert(link.frames.length == 3 && relayed[] == euros[]);

        peer._console_session = null;
        session.destroy();
        Collection!Session().update_all();
        stream.detach_peer();
    }

    // over RDP: sends wait for the session, one lane keeps add before val, bulk stops at its floor until room returns
    static if (has_rdp)
    {
        import router.iface.bridge : BridgeInterface;
        import router.iface.endpoint : UDPReceiveInfo;
        import router.iface.rdp : RDPEndpoint, RDPEvent, rdp_open;

        static struct Wire
        {
        nothrow @nogc:
            struct Datagram
            {
                RDPEndpoint* to;
                InetAddress from;
                Array!ubyte bytes;
            }
            RDPEndpoint* a;
            RDPEndpoint* b;
            InetAddress addr_a;
            InetAddress addr_b;
            Array!Datagram queue;

            void carry(RDPEndpoint* from, const(ubyte)[] frame, ref const InetAddress)
            {
                Datagram d;
                d.to = from is a ? b : a;
                d.from = from is a ? addr_a : addr_b;
                d.bytes ~= frame;
                queue ~= d.move;
            }

            void pump()
            {
                while (!queue.empty)
                {
                    Datagram d = queue.pop_front();
                    UDPReceiveInfo info;
                    info.source = d.from;
                    d.to.test_deliver(d.bytes[], info);
                }
            }
        }

        BridgeInterface station = Collection!BridgeInterface().create("sync-test-rdp");
        Live near = alloc!Live(CID(13));
        Live far = alloc!Live(CID(14));
        Wire wire;
        wire.addr_a = InetAddress(station.mac.b, 4001);
        wire.addr_b = InetAddress(station.mac.b, 4002);
        wire.a = rdp_open(&wire.addr_a, null, &near.on_rdp_message, &near.on_rdp_event, station);
        wire.b = rdp_open(&wire.addr_b, null, &far.on_rdp_message, &far.on_rdp_event, station);
        assert(wire.a && wire.b);
        scope (exit)
        {
            near.live(false);
            far.live(false);
            wire.a.close();
            wire.b.close();
            free(far);
            free(near);
            station.destroy();
            Collection!BridgeInterface().table.free_pending();
        }
        wire.a._test_wire = &wire.carry;
        wire.b._test_wire = &wire.carry;
        near.bind_rdp_session(wire.a, wire.addr_b);
        far.bind_rdp_session(wire.b, wire.addr_a);
        near._tx_waiter.handler = &near.hold;
        far._tx_waiter.handler = &far.hold;
        near.live(true);
        far.live(true);
        assert(!near.transport_ready && near.local_segment == rdp_max_message);

        ubyte[3] add = [1, 1, 1];
        ubyte[3] val = [2, 2, 2];
        ubyte[3] line = [3, 3, 3];
        assert(near.transmit_frame(add[]) < 0);
        StackPacket opener;
        opener.init!RawFrame(line[]);
        assert(wire.a.send(&opener.packet, wire.addr_b) >= 0);
        wire.pump();
        assert(near.transport_ready && far.transport_ready && near.local_segment == wire.a.message_limit(wire.addr_b));
        far._pre_start.clear();
        far._pre_start_bytes = 0;

        assert(near.transmit_frame(add[]) == 0);
        assert(near.transmit_frame(val[], false, TxQueue.val) == 0);
        assert(near.transmit_frame(line[], false, TxQueue.log) == 0);
        wire.pump();
        assert(far._pre_start.length == 3 && far._pre_start[0][] == add[] && far._pre_start[1][] == val[]);
        far._pre_start.clear();
        far._pre_start_bytes = 0;

        wire.a._test_blocked = true;
        while (near.control_room())
            assert(near.transmit_frame(val[], false, TxQueue.val) == 0);
        assert(near.transmit_frame(line[], false, TxQueue.log) < 0, "a log waits at bulk's floor");
        assert(near.tx_full() && near.transmit_frame(add[]) == 0, "control still finds room above bulk's floor");
        near.held = 0;
        wire.a._test_blocked = false;
        assert(near.transmit_frame(add[]) == 0);
        foreach (_; 0 .. 8)
            wire.pump();
        assert(near.held == 0, "the fall under a send is not announced inside it");
        wire.a.test_next_pass();
        assert(near.control_room() && near.held == 1, "the next pass re-invites the producer once");

        near.on_rdp_event(wire.a, wire.addr_b, RDPEvent.closed);
        assert(!near.running);
    }
}
