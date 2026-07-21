module manager.sync.peer;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.syslog;
import manager.sync;
import manager.sync.encoder;
import manager.system : hostname;

import router.iface;
import router.iface.packet;

nothrow @nogc:


class SyncPeer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("transport",      transport),
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
        if (_transport is value)
            return;
        detach_transport();
        _transport = value;
        mark_set!(typeof(this), "transport")();
        restart();
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
        if (_time_authority == value)
            return;
        _time_authority = value;
        _next_time_poll = getTime(); // (re)establish promptly
        mark_set!(typeof(this), "time-authority")();
    }

    // API

    int transmit_frame(const(ubyte)[] frame, bool is_text = false)
    {
        if (!_transport || !_transport.running)
            return -1;
        Packet p;
        ref hdr = p.init!RawFrame(frame);
        hdr.is_text = is_text;
        return _transport.forward(p);
    }

    void request_logs(Severity max_severity, bool off, const(char)[] tag)
    {
        _want_logs = !off;
        _want_log_severity = max_severity;
        _want_log_tag = tag.makeString(defaultAllocator);
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

        _log_tag = tag.makeString(defaultAllocator);
        LogFilter filter;
        filter.max_severity = max_severity;
        filter.tag_prefix = _log_tag[];

        if (_log_active)
            set_sink_filter(_log_sink, filter);
        else
        {
            _log_sink = register_log_sink(&log_sink_out, cast(void*)this, filter);
            _log_active = _log_sink.valid;
            if (!_log_active)
                log.warning("no free log sink slot for peer '", name[], "'");
        }
    }

    void flush_logs()
    {
        if (!_log_count && !_log_dropped)
            return;

        SyncEncoder enc = encoder_for(_encoder);
        while (_log_count)
        {
            enc.encode_log(this, _log_ring[_log_head][]);
            _log_head = (_log_head + 1) % log_ring_size;
            --_log_count;
        }
        if (_log_dropped)
        {
            LogMessage drop;
            drop.severity = Severity.warning;
            drop.tag = "sync";
            drop.hostname = hostname[];
            drop.timestamp = get_sys_time();
            drop.message = tconcat(_log_dropped, " log messages dropped to peer")[];
            enc.encode_log(this, format_syslog(drop));
            _log_dropped = 0;
        }
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _transport !is null;

    // Idempotent; WS-spawned peers call this at accept time, because the client's
    // first frames can arrive before our first startup tick and unsubscribed
    // packets are dropped.
    package void subscribe_transport()
    {
        if (_transport_subscribed || !_transport)
            return;
        _transport.subscribe(&on_transport_packet, PacketFilter(PacketType.raw, PacketDirection.incoming));
        _transport.subscribe(&on_transport_state);
        _transport_subscribed = true;
    }

    override CompletionStatus startup()
    {
        if (!_transport || !_transport.running)
            return CompletionStatus.continue_;

        subscribe_transport();

        get_module!SyncModule.attach_peer(this);

        if (_want_logs)
            encoder_for(_encoder).encode_log_sub(this, _want_log_severity, false, _want_log_tag[]);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        get_module!SyncModule.detach_peer(this);
        detach_transport();

        // Peer-derived tap state dies with the stream; the desire to receive
        // (_want_*) persists so a reconnect re-subscribes.
        clear_log_sink();
        _log_head = 0;
        _log_count = 0;
        _log_dropped = 0;
        return CompletionStatus.complete;
    }

package:
    Array!String     _subscriptions;
    Array!BaseObject _bound;             // objects we've sent bind{...} to this peer
    Array!BaseObject _authoritative;     // proxies we hold on this peer's behalf
    SyncEncoderKind  _encoder;

    bool     _time_authority;
    bool     _time_subordinate;
    uint     _last_authority_version;
    uint     _time_seq;                  // 0 = no pull in flight
    MonoTime _time_t1;
    MonoTime _next_time_poll;

    // Outbound tap: the remote subscribed to our logs; our fan-out sink queues
    // matching lines here for flush_logs to drain each tick.
    enum uint log_ring_size = 256;
    LogSinkHandle _log_sink;
    bool          _log_active;
    String        _log_tag;              // owned; backs _log_sink's filter tag_prefix
    Array!(char, 0)[log_ring_size] _log_ring;
    uint _log_head;
    uint _log_count;
    uint _log_dropped;

    // Inbound tap: we subscribed to the remote's logs. Persists across reconnect.
    bool     _want_logs;
    Severity _want_log_severity;
    String   _want_log_tag;

private:
    ObjectRef!BaseInterface _transport;
    bool                    _transport_subscribed;

    static void log_sink_out(void* ctx, scope ref const LogMessage msg) nothrow @nogc
    {
        auto peer = cast(SyncPeer)ctx;
        // Split-horizon: don't echo a re-injected log back out the peer it
        // arrived on. msg.hostname is the original emitter (possibly upstream of
        // this peer in a relay chain), so the guard keys on arrival identity.
        if (peer is g_log_reinject_source)
            return;
        peer.enqueue_log(format_syslog(msg));
    }

    void enqueue_log(const(char)[] line)
    {
        if (_log_count >= log_ring_size)
        {
            ++_log_dropped;
            return;
        }
        uint slot = (_log_head + _log_count) % log_ring_size;
        _log_ring[slot].clear();
        _log_ring[slot] ~= line;
        ++_log_count;
    }

    void clear_log_sink()
    {
        if (!_log_active)
            return;
        unregister_log_sink(_log_sink);
        _log_sink = LogSinkHandle.init;
        _log_active = false;
    }

    void detach_transport()
    {
        if (!_transport_subscribed)
            return;
        _transport.unsubscribe(&on_transport_packet);
        _transport.unsubscribe(&on_transport_state);
        _transport_subscribed = false;
    }

    void on_transport_packet(ref const Packet p, BaseInterface, PacketDirection, void*) nothrow @nogc
    {
        encoder_for(_encoder).decode_and_dispatch(this, cast(const(ubyte)[])p.data);
    }

    void on_transport_state(ActiveObject, StateSignal sig) nothrow @nogc
    {
        if (sig == StateSignal.offline)
            restart();
    }
}
