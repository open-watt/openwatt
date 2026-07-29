module manager.sync.peer;

import urt.array;
import urt.log;
import urt.mem.allocator;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.log;
import manager.syslog;
import manager.sync;
import manager.sync.encoder;

import router.iface;
import router.iface.packet;

nothrow @nogc:


alias log = Log!"sync";


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

    // Session name/handle binding. Local ids never travel: each side announces its
    // objects by name (add_name) and allocates the session handle for the objects it
    // introduces. A wire handle's low bit says who allocated it relative to the frame
    // it appears in: 0 = the frame's sender, 1 = the receiver, so the same handle value
    // flips its low bit crossing the wire. Handles are never reused; a slot whose
    // object dies resolves invalid forever, and a session (attach..detach) resets the
    // whole space.

    enum uint invalid_handle = uint.max;

    uint introduce(BaseObject obj)
    {
        foreach (i, o; _introduced[])
            if (o is obj)
                return cast(uint)i << 1;
        uint idx = cast(uint)_introduced.length;
        _introduced ~= obj;
        return idx << 1;
    }

    void adopt(uint handle, CID local)
    {
        if (handle & 1)
        {
            log.warning("peer '", name[], "' announced a receiver-side handle ", handle);
            return;
        }
        uint idx = handle >> 1;
        while (_adopted.length <= idx)
            _adopted ~= CID.invalid;
        if (_adopted[idx] && _adopted[idx] != local)
        {
            log.warning("peer '", name[], "' re-announced handle ", handle, " for a different name");
            return;
        }
        _adopted[][idx] = local;
    }

    uint handle_of(BaseObject obj)
    {
        foreach (i, o; _introduced[])
            if (o is obj)
                return cast(uint)i << 1;
        foreach (i, c; _adopted[])
            if (c == obj.id)
                return (cast(uint)i << 1) | 1;
        return invalid_handle;
    }

    uint handle_of(CID cid)
    {
        foreach (i, c; _adopted[])
            if (c == cid)
                return (cast(uint)i << 1) | 1;
        foreach (i, o; _introduced[])
            if (o && o.id == cid)
                return cast(uint)i << 1;
        return invalid_handle;
    }

    CID cid_of(uint handle)
    {
        uint idx = handle >> 1;
        if (handle & 1)
            return idx < _introduced.length && _introduced[idx] ? _introduced[idx].id : CID.invalid;
        return idx < _adopted.length ? _adopted[idx] : CID.invalid;
    }

    void forget(BaseObject obj)
    {
        foreach (ref o; _introduced[])
            if (o is obj)
            {
                o = null;
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
        return CompletionStatus.complete;
    }

package:
    Array!String     _subscriptions;
    Array!BaseObject _bound;             // objects we've sent bind{...} to this peer
    Array!BaseObject _authoritative;     // proxies we hold on this peer's behalf
    Array!BaseObject _introduced;        // handle table: objects we announced (slot = handle >> 1)
    Array!CID        _adopted;           // handle table: local ids for names the peer announced
    SyncEncoderKind  _encoder;

    bool     _time_authority;
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
    ObjectRef!BaseInterface _transport;
    bool                    _transport_subscribed;

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
