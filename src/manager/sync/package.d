module manager.sync;

// SyncModule - the singleton hub.
//
// Holds cross-peer state: the peer list, the authority map (CID → SyncPeer for
// proxies only), pending-forwards for correlation of routed requests, and the
// next-seq counter. Drives the per-tick property flush. Hooks into global
// object lifecycle to emit registry deltas and state signals.
//
// All state lives on the Module instance. Encoders call the inbound_* methods
// after decoding a frame. Local machinery calls the on_object_* hooks on
// object lifecycle events. Nothing below ever constructs a SyncMessage.
//
// Known gaps (not smoke-tested end-to-end yet):
//
//   - Rename propagation: nothing broadcasts a locally-authoritative rename.
//     Session handles are rename-stable (bound to the object, not the name),
//     so this is one "rename" verb {handle, new_name} plus a global renamed
//     hook (analogous to register_object_lifecycle_handler) when needed.
//   - inbound_enum doesn't correlate pending enum_req forwards - currently
//     latent (no outbound enum_req emitter exists yet).
//
// Soft / wasteful but correct:
//
//   - Create to a `from` that also matches a subscription pattern sends three
//     frames: add_name (redundant - `from` initiated), bind(seq=0) from the
//     auto-bind path, bind(seq=correlation) from inbound_create. Receivers
//     should dedup on CID. Fixing properly means stashing the correlation
//     seq before coll.create fires its signal.
//   - Hub-of-hubs re-fan in inbound_bind emits add_name to all peers except
//     `from`, including peers that already know the CID. Idempotent waste.
//
// Structural concerns worth eyeballing under real traffic:
//
//   - Pending-forward leaks on peer disconnect: detach_peer cleans entries
//     where the *origin* is gone, but not entries routed *to* a departing
//     authority. No TTL either - an unresponsive authority leaves entries
//     forever.
//   - No loop defense for multi-hop rings. inbound_bind skips `from` in its
//     re-fan (kills A↔B echoes), but a longer cycle (A→B→C→A) isn't defended.
//     Star topologies are fine; arbitrary graphs aren't.
//   - inbound_set authority-sync path: obj.set marks dirty, then echo_set
//     clears the bit after emit. If tick_dirty interleaves we could in
//     principle double-emit - think it's fine because echo_set clears under
//     the same sync slot, but worth watching.

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.meta.enuminfo : enum_from_key, make_enum_info, VoidEnumInfo;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.variant;


import manager;
import manager.base;
import manager.collection;
import manager.component : Component;
import manager.device : Device;
import manager.element : Access, add_feed_listener, Element, ElementLifecycleEvent,
                         register_element_lifecycle_handler, remove_feed_listener, SamplingMode, sweep_dirty;
import manager.id : EID;
import manager.path : Address, match_path, pattern_matches, walk_elements;
import manager.series : Constraint, DataFormat, FormatId, RecordBlock, register_format, Scalar, SeriesKind,
                        unbox_scalar, valid, ValueType;
import manager.console;
import manager.console.command : CommandState, CommandCompletionState;
import manager.console.session;
import manager.plugin;
import manager.features;
import manager.log;
import manager.syslog;
import manager.system : hostname;
import manager.sync.binary_encoder;
import manager.sync.discovery : PeerRole;
import manager.sync.encoder;
import manager.sync.json_encoder;
import manager.sync.peering : SyncPeeringModule;
import manager.sync.peer;
import manager.sync.udp_server;
static if (has_http)
    import manager.sync.ws_server;

nothrow @nogc:


// History responses must fit in one raw packet (64KB); JSON samples are ~25 bytes each.
enum uint max_history_points = 2000;

// Time-sync cadence for a remote pulling from its authority.
enum Duration time_poll_interval    = seconds(17 * 60);
enum Duration time_retry_interval   = seconds(30);
enum Duration time_response_timeout = seconds(4);


enum PendingKind : ubyte
{
    cmd,
    create,
    destroy,
    enum_req,
    set,
    reset,
}

struct PendingForward
{
    SyncPeer    origin;       // peer that originated the request
    uint        origin_seq;   // seq assigned by origin peer
    PendingKind kind;
}

// Inbound command running locally on behalf of a peer. When execute() returns
// a non-null CommandState (async completion), we hold onto it until its
// update() transitions out of in_progress, then emit encode_result.
struct PendingInboundCmd
{
    SyncPeer      peer;
    uint          seq;
    StringSession session;
    CommandState  command;
}

class SyncModule : Module
{
    mixin DeclareModule!"sync";
nothrow @nogc:

    Array!SyncPeer             peers;
    Map!(CID, SyncPeer)        authority;         // only remote auth; absence = local
    Map!(uint, PendingForward) pending_forwards;
    Array!PendingInboundCmd    pending_inbound_cmds;
    uint                       next_seq;
    uint                       _timebase_version;  // our version as a clock authority
    SyncPeer                   _applying_push;     // peer whose delta push we're applying

    override void init()
    {
        g_app.register_enum!SyncEncoderKind();

        g_json_encoder = defaultAllocator.allocT!JsonEncoder(this);
        g_encoders[SyncEncoderKind.json] = g_json_encoder;
        g_binary_encoder = defaultAllocator.allocT!BinaryEncoder(this);
        g_encoders[SyncEncoderKind.binary] = g_binary_encoder;

        g_app.console.register_collection!SyncPeer();
        g_app.console.register_collection!UDPSyncServer();
        static if (has_http)
            g_app.console.register_collection!WebSocketSyncServer();

        g_app.console.register_command!(sync_log_sub, "log-sub")("/sync", this);
        g_app.console.register_command!(sync_model_sub, "model-sub")("/sync", this);

        set_log_hostname(hostname[]);

        register_object_lifecycle_handler(&on_object_lifecycle);
        register_object_state_handler(&on_object_state);
        register_element_lifecycle_handler(&on_element_lifecycle);
        subscribe_clock_change(&on_clock_step);
    }

    override void deinit()
    {
        unsubscribe_clock_change(&on_clock_step);
    }

    override void update()
    {
        Collection!UDPSyncServer().update_all();
        static if (has_http)
            Collection!WebSocketSyncServer().update_all();
        Collection!SyncPeer().update_all();

        foreach (p; peers[])
        {
            encoder_for(p._encoder).tick_dirty(p);
            p.flush_logs();
        }

        // Live model feeds: drain the per-tick dirty sweep into per-peer pending
        // sets, then flush coalesced latest values.
        bool feeds = false;
        foreach (p; peers[])
        {
            if (!p._model_subs.empty)
            {
                feeds = true;
                break;
            }
        }
        if (feeds)
        {
            // a val-queue eviction broke the catch-up promise; re-push the latest
            // value of every armed node (idempotent) so only history stays lost
            foreach (p; peers[])
            {
                if (!p.take_val_repush())
                    continue;
                foreach (raw; p._live_nodes.keys)
                {
                    EID node;
                    node.raw = raw;
                    bool queued = false;
                    foreach (pe; p._pending_vals[])
                    {
                        if (pe == node)
                        {
                            queued = true;
                            break;
                        }
                    }
                    if (!queued)
                        p._pending_vals ~= node;
                }
            }

            sweep_dirty((ref Element e) {
                EID node = e.ensure_eid();
                if (!node)
                    return;
                foreach (p; peers[])
                {
                    if (p._model_subs.empty || (node.raw in p._live_nodes) is null)
                        continue;
                    bool queued = false;
                    foreach (pe; p._pending_vals[])
                    {
                        if (pe == node)
                        {
                            queued = true;
                            break;
                        }
                    }
                    if (!queued)
                        p._pending_vals ~= node;
                }
            });
            foreach (p; peers[])
            {
                if (p._pending_vals.empty)
                    continue;
                SyncEncoder enc = encoder_for(p._encoder);
                foreach (node; p._pending_vals[])
                {
                    Element* e = resolve_element(node);
                    SyncHandle h = p.handle_of(node);
                    if (!e || h == SyncPeer.invalid_handle)
                        continue;
                    if (e.data_format.kind == SeriesKind.point)
                    {
                        // events deliver every occurrence (mode `all`); the cursor clamps
                        // past eviction and reports lost
                        ulong* next = node.raw in p._live_nodes;
                        if (!next || !e.has_history)
                            continue;
                        auto c = e.open_series_cursor(*next);
                        for (;;)
                        {
                            RecordBlock blk = c.next(256);
                            if (!blk.count)
                                break;
                            enc.encode_val_block(p, h, blk);
                        }
                        *next = c.position;
                        e.close_series_cursor(c);
                    }
                    else
                        enc.encode_val(p, h, e);
                }
                p._pending_vals.clear();
            }
        }

        poll_time_authorities();

        // Drain completed inbound commands and emit their results back.
        for (size_t i = 0; i < pending_inbound_cmds.length; )
        {
            ref PendingInboundCmd req = pending_inbound_cmds[i];
            if (req.command.update() < CommandCompletionState.finished)
            {
                ++i;
                continue;
            }
            encoder_for(req.peer._encoder)
                .encode_result(req.peer, req.seq, req.command.result, req.session.takeOutput()[]);
            req.session.allocator.freeT(req.command);
            g_app.console.destroy_session(req.session);
            pending_inbound_cmds.remove(i);
        }
    }

    void attach_peer(SyncPeer p)
    {
        foreach (existing; peers[])
            if (existing is p)
                return;
        peers ~= p;

        // Eager registry: announce every local authoritative syncable object
        // to the newly-attached peer.
        SyncEncoder enc = encoder_for(p._encoder);
        foreach_object((BaseObject obj) nothrow @nogc {
            if (!obj._typeInfo.syncable)
                return;
            if (obj._is_remote)
                return;
            enc.encode_add_name(p, obj);
        });
    }

    // Peer teardown: request cancellation of the peer's in-flight inbound commands;
    // the update() drain reaps them (delivering results while the transport lasts).
    // True while any remain, so the peer's shutdown() can wait on it.
    bool cancel_inbound_cmds(SyncPeer p)
    {
        bool waiting = false;
        foreach (ref cmd; pending_inbound_cmds)
        {
            if (cmd.peer is p)
            {
                cmd.command.request_cancel();
                waiting = true;
            }
        }
        return waiting;
    }

    void detach_peer(SyncPeer p)
    {
        get_module!SyncPeeringModule.peer_detached(p);

        // Destroy proxies we held on this peer's behalf.
        foreach (obj; p._authoritative[])
        {
            authority.remove(obj.id);
            obj.destroy();
        }
        p._authoritative.clear();
        p._bound.clear();
        p._subscriptions.clear();
        p._introduced.clear();
        p._adopted.clear();
        p._remote_caps = 0;
        p.reset_sublayer();           // seq spaces are session state
        p._remote_nonce_set = false;
        p._local_nonce_set = false;   // a reconnect is a new session; fresh nonce
        p._ft_sent.clear();
        p._next_ft = 0;
        p._enums_sent.clear();
        p._ft_recv.clear();
        foreach (ref pat; p._model_subs[])
            remove_feed_listener();
        p._model_subs.clear();
        p._live_nodes.clear();
        p._pending_vals.clear();

        // Drop pending forwards where this peer was the origin; we can't route
        // a response back to a gone peer.
        Array!uint doomed;
        foreach (kvp; pending_forwards[])
            if (kvp.value.origin is p)
                doomed ~= kvp.key;
        foreach (k; doomed[])
            pending_forwards.remove(k);

        debug foreach (ref cmd; pending_inbound_cmds)
            assert(cmd.peer !is p, "detach with in-flight inbound commands; shutdown must drain them first");

        foreach (i, existing; peers[])
        {
            if (existing is p)
            {
                peers.remove(i);
                break;
            }
        }
    }

    // Inbound: registry

    void inbound_add_name(SyncPeer from, SyncHandle handle, const(char)[] name, const(char)[] type)
    {
        // Reserves local identity for the peer's announced name and binds their
        // session handle to it. No proxy yet - bind is what materialises one.
        auto rt = type in g_app.types;
        if (!rt)
        {
            log.warning("sync: add_name from '", from.name[], "' with unknown type '", type, "'");
            return;
        }
        if (rt.type_info.is_abstract)
        {
            log.warning("sync: add_name from '", from.name[], "' for abstract type '", type, "'");
            return;
        }
        ubyte type_idx = cast(ubyte)rt.type_info.collection_id;
        CID local = item_table(type_idx).reserve(name, type_idx);
        from.adopt(handle, EID(local));
    }

    // Inbound: mirror lifecycle

    void inbound_bind(SyncPeer from, CID target, const(char)[] type, uint seq)
    {
        BaseObject proxy = get_item(target);

        // First-time bind: materialize proxy. add_name already reserved the
        // CID (value=null); alloc+add will plug the proxy object into that
        // slot and fire signal_object_created (which our handler ignores for
        // remote objects).
        if (!proxy)
        {
            auto rt = type in g_app.types;
            if (!rt)
            {
                log.warning("sync: bind from '", from.name[], "' for unknown type '", type, "' - cannot materialize proxy for CID ", target.raw);
                return;
            }
            const(CollectionTypeInfo)* ti = rt.type_info;
            if (ti.is_abstract)
            {
                log.warning("sync: bind from '", from.name[], "' for abstract type '", type, "'");
                return;
            }

            const(char)[] name = get_id(target)[];
            if (name.length == 0)
            {
                log.warning("sync: bind from '", from.name[], "' for CID ", target.raw, " with no prior add_name");
                return;
            }

            BaseCollection coll = BaseCollection(ti);
            proxy = coll.alloc(name, ObjectFlags.remote);
            if (!proxy)
            {
                log.warning("sync: bind from '", from.name[], "' - alloc failed for '", name, "' (", type, ")");
                return;
            }
            coll.add(proxy);

            authority[target] = from;
            from._authoritative ~= proxy;
        }
        else if (proxy._is_remote)
        {
            // Re-bind of an existing proxy (e.g. authority reset state).
            // Authority should still be `from`; warn if it's drifted.
            auto pp = target in authority;
            if (!pp || *pp !is from)
                log.warning("sync: bind re-announce for '", proxy.name[], "' from a different peer than current authority");
        }
        else
        {
            // Bind targeting a local authoritative object - protocol violation.
            log.warning("sync: bind from '", from.name[], "' targeting our local '", proxy.name[], "' - ignoring");
            return;
        }

        // Correlation: if this bind answers a create we forwarded, resolve it
        // so the origin peer learns their request succeeded.
        if (seq)
        {
            auto pf = seq in pending_forwards;
            if (pf && pf.kind == PendingKind.create)
            {
                SyncPeer origin = pf.origin;
                uint origin_seq = pf.origin_seq;
                pending_forwards.remove(seq);
                // Origin likely doesn't yet know this object - introduce it first.
                encoder_for(origin._encoder).encode_add_name(origin, proxy);
                bind_to_peer(origin, proxy, origin_seq);
            }
        }

        // Hub-of-hubs: tell our other subscribers about this newly-materialized
        // proxy. add_name first (they may not know it), then bind to any
        // whose subscription patterns match.
        foreach (p; peers[])
        {
            if (p is from)
                continue;
            encoder_for(p._encoder).encode_add_name(p, proxy);
            foreach (ref pat; p._subscriptions[])
            {
                if (pattern_matches(pat[], proxy))
                {
                    bind_to_peer(p, proxy);
                    break;
                }
            }
        }
    }

    void inbound_unbind(SyncPeer from, CID target, uint seq)
    {
        BaseObject proxy = get_item(target);
        if (!proxy)
        {
            log.warning("sync: unbind from '", from.name[], "' for unknown CID ", target.raw);
            return;
        }
        auto pp = target in authority;
        if (!pp || *pp !is from)
        {
            log.warning("sync: unbind from '", from.name[], "' for '", proxy.name[], "' which they don't own");
            return;
        }

        // Resolve a pending destroy forward: the origin peer gets the
        // correlated unbind so their request returns an ack.
        if (seq)
        {
            auto pf = seq in pending_forwards;
            if (pf && pf.kind == PendingKind.destroy)
            {
                SyncPeer origin = pf.origin;
                uint origin_seq = pf.origin_seq;
                pending_forwards.remove(seq);
                // Origin may or may not have had this proxy bound. If bound,
                // unbind_from_peer handles bookkeeping + emits unbind with
                // correlation. Otherwise emit a bare unbind frame.
                bool origin_bound = false;
                foreach (bound; origin._bound[])
                    if (bound is proxy) { origin_bound = true; break; }
                if (origin_bound)
                    unbind_from_peer(origin, proxy, origin_seq);
                else
                    encoder_for(origin._encoder).encode_unbind(origin, target, origin_seq);
            }
        }

        // Fan unbind to our other bound peers (hub-of-hubs): they observed
        // this proxy via us and now must drop it. Do this BEFORE destroying
        // the proxy locally, otherwise on_object_state(destroyed) would
        // race us with fan_out_unbind(seq=0).
        fan_out_unbind(proxy, null, 0, from);

        foreach (i, obj; from._authoritative[])
        {
            if (obj is proxy)
            {
                from._authoritative.remove(i);
                break;
            }
        }
        authority.remove(target);
        proxy.destroy();
    }

    void inbound_create(SyncPeer from, const(char)[] type, NamedArgument[] props, uint seq)
    {
        auto rt = type in g_app.types;
        if (!rt)
        {
            encoder_for(from._encoder).encode_error(from, seq, "unknown type");
            return;
        }
        const(CollectionTypeInfo)* ti = rt.type_info;
        if (ti.is_abstract)
        {
            encoder_for(from._encoder).encode_error(from, seq, "abstract type");
            return;
        }

        // Extract "name" from props; the remaining args drive property setters.
        // BaseCollection.create asserts that named_args doesn't contain "name".
        const(char)[] name;
        Array!NamedArgument other_args;
        foreach (ref arg; props)
        {
            if (arg.name[] == "name")
                name = arg.value.asString();
            else
                other_args ~= arg;
        }
        if (name.length == 0)
        {
            encoder_for(from._encoder).encode_error(from, seq, "missing name");
            return;
        }

        // Atomic construct-and-validate: if any setter fails, coll.create frees
        // the object before add() - nothing ever observes a broken instance.
        BaseCollection coll = BaseCollection(ti);
        BaseObject obj = coll.create(name, ObjectFlags.none, other_args[]);
        if (!obj)
        {
            encoder_for(from._encoder).encode_error(from, seq, "create failed");
            return;
        }

        // Bind the requester with correlation seq. If on_object_created's
        // subscription match already bound them, bind_to_peer(seq != 0) still
        // emits the correlation frame without double-inserting into _bound.
        bind_to_peer(from, obj, seq);
    }

    void inbound_destroy(SyncPeer from, CID target, uint seq)
    {
        BaseObject obj = get_item(target);
        if (!obj)
        {
            if (seq)
                encoder_for(from._encoder).encode_error(from, seq, "unknown target");
            return;
        }

        auto pp = target in authority;
        if (pp)
        {
            // Proxy: forward to the authoritative peer. The unbind arriving
            // back (correlated by local_seq) resolves the correlation and
            // drives our proxy teardown.
            SyncPeer auth = *pp;
            uint local_seq = alloc_seq();
            pending_forwards[local_seq] = PendingForward(from, seq, PendingKind.destroy);
            encoder_for(auth._encoder).encode_destroy(auth, target, local_seq);
            return;
        }

        // Authoritative: fan out unbind to bound peers first - requester gets
        // `seq` for correlation, others get seq=0. Then destroy locally.
        // on_object_state(destroyed) will still fire fan_out_unbind, but
        // _bound is already drained so it's a no-op.
        fan_out_unbind(obj, from, seq);
        obj.destroy();
    }

    void inbound_state(SyncPeer from, CID target, StateSignal sig)
    {
        // Only online/offline travel on the wire; destroyed is communicated
        // via unbind (see inbound_unbind).
        assert(sig != StateSignal.destroyed, "inbound_state: destroyed is never sent on the wire");

        BaseObject proxy = get_item(target);
        if (!proxy)
        {
            log.warning("sync: state from '", from.name[], "' for unknown CID ", target.raw);
            return;
        }

        if (auto ao = cast(ActiveObject)proxy)
            ao.set_remote_state(sig);

        // Fan out to our bound peers (hub-of-hubs).
        foreach (p; peers[])
        {
            if (p is from)
                continue;
            foreach (bound; p._bound[])
            {
                if (bound is proxy)
                {
                    encoder_for(p._encoder).encode_state(p, target, sig);
                    break;
                }
            }
        }
    }

    // Inbound: property sync

    void inbound_set(SyncPeer from, CID target, const(char)[] prop,
                     ref const Variant value, uint seq)
    {
        BaseObject obj = get_item(target);
        if (!obj)
        {
            log.warning("sync: set from '", from.name[], "' for unknown CID ", target.raw);
            if (seq)
                encoder_for(from._encoder).encode_error(from, seq, "unknown target");
            return;
        }

        auto pp = target in authority;
        if (pp && *pp is from)
        {
            // Authority is pushing state to us (our proxy). Apply locally,
            // resolve any pending forward correlation, then fan out to our
            // other bound peers (hub-of-hubs).
            Variant v = value;
            auto r = obj.set(prop, v);
            if (r.failed)
            {
                log.warning("sync: proxy set failed for '", obj.name[], ".", prop, "': ", r.message);
                return;
            }

            size_t prop_idx = size_t.max;
            foreach (i, p; obj.properties())
                if (p.name[] == prop) { prop_idx = i; break; }
            if (prop_idx == size_t.max)
                return;

            SyncPeer correlate = null;
            uint corr_seq = 0;
            if (seq)
            {
                auto pf = seq in pending_forwards;
                if (pf && pf.kind == PendingKind.set)
                {
                    correlate = pf.origin;
                    corr_seq = pf.origin_seq;
                    pending_forwards.remove(seq);
                }
            }
            echo_set(obj, prop_idx, correlate, corr_seq, from);
            return;
        }

        if (pp)
        {
            // Proxy owned by a different peer - forward to the authority.
            SyncPeer auth = *pp;
            uint local_seq = alloc_seq();
            pending_forwards[local_seq] = PendingForward(from, seq, PendingKind.set);
            encoder_for(auth._encoder).encode_set(auth, target, prop, value, local_seq);
            return;
        }

        // Authoritative: apply, then echo to all bound peers.
        Variant v = value;
        auto r = obj.set(prop, v);
        if (r.failed)
        {
            if (seq)
                encoder_for(from._encoder).encode_error(from, seq, r.message);
            return;
        }

        size_t prop_idx = size_t.max;
        foreach (i, p; obj.properties())
            if (p.name[] == prop) { prop_idx = i; break; }
        if (prop_idx == size_t.max)
            return;
        echo_set(obj, prop_idx, from, seq);
    }

    void inbound_reset(SyncPeer from, CID target, const(char)[] prop, uint seq)
    {
        BaseObject obj = get_item(target);
        if (!obj)
        {
            log.warning("sync: reset from '", from.name[], "' for unknown CID ", target.raw);
            if (seq)
                encoder_for(from._encoder).encode_error(from, seq, "unknown target");
            return;
        }

        auto pp = target in authority;
        if (pp && *pp is from)
        {
            // Authority pushing a reset. Apply, resolve pending correlation,
            // fan out to our other bound peers.
            obj.reset(prop);

            size_t prop_idx = size_t.max;
            foreach (i, p; obj.properties())
                if (p.name[] == prop) { prop_idx = i; break; }
            if (prop_idx == size_t.max)
                return;

            SyncPeer correlate = null;
            uint corr_seq = 0;
            if (seq)
            {
                auto pf = seq in pending_forwards;
                if (pf && pf.kind == PendingKind.reset)
                {
                    correlate = pf.origin;
                    corr_seq = pf.origin_seq;
                    pending_forwards.remove(seq);
                }
            }
            echo_reset(obj, prop_idx, prop, correlate, corr_seq, from);
            return;
        }

        if (pp)
        {
            // Proxy of another peer - forward to authority.
            SyncPeer auth = *pp;
            uint local_seq = alloc_seq();
            pending_forwards[local_seq] = PendingForward(from, seq, PendingKind.reset);
            encoder_for(auth._encoder).encode_reset(auth, target, prop, local_seq);
            return;
        }

        // Authoritative: reset, then fan out reset to all bound peers.
        obj.reset(prop);

        size_t prop_idx = size_t.max;
        foreach (i, p; obj.properties())
            if (p.name[] == prop) { prop_idx = i; break; }
        if (prop_idx == size_t.max)
            return;

        echo_reset(obj, prop_idx, prop, from, seq);
    }

    // Inbound: log streaming

    void inbound_log_sub(SyncPeer from, Severity max_severity, bool off, const(char)[] tag)
    {
        from.set_log_sub(max_severity, off, tag);
    }

    void inbound_log(SyncPeer from, const(char)[] line)
    {
        LogMessage msg;
        if (!parse_syslog(line, msg))
        {
            log.warning("sync: malformed log frame from '", from.name[], "'");
            return;
        }
        // Arrival identity, not hostname, prevents a relayed record echoing to
        // the peer it came from.
        get_module!LogModule.source(cast(void*)from);
        write_log(msg);
        get_module!LogModule.source(null);
    }

    // Inbound: commands, errors, enums, subscriptions

    void inbound_cmd(SyncPeer from, uint seq, const(char)[] text)
    {
        StringSession session = g_app.console.createSession!StringSession();
        Variant result;
        CommandState cmd = g_app.console.execute(session, text, result);
        if (cmd is null)
        {
            // Completed synchronously (or failed to parse).
            encoder_for(from._encoder).encode_result(from, seq, result, session.takeOutput()[]);
            g_app.console.destroy_session(session);
            return;
        }
        pending_inbound_cmds ~= PendingInboundCmd(from, seq, session, cmd);
    }

    void inbound_suggest(SyncPeer from, uint seq, const(char)[] text)
    {
        Array!String suggestions = g_app.console.suggest(text, g_app.console.root);
        MutableString!0 completed = g_app.console.complete(text, g_app.console.root);
        encoder_for(from._encoder).encode_suggestions(from, seq, suggestions[], completed[]);
    }

    void inbound_result(SyncPeer from, uint seq, ref const Variant v, const(char)[] out_text)
    {
        auto pf = seq in pending_forwards;
        if (!pf)
        {
            log.warning("sync: result from '", from.name[], "' for unknown seq=", seq);
            return;
        }
        encoder_for(pf.origin._encoder).encode_result(pf.origin, pf.origin_seq, v, out_text);
        pending_forwards.remove(seq);
    }

    void inbound_error(SyncPeer from, uint seq, const(char)[] text)
    {
        auto pf = seq in pending_forwards;
        if (!pf)
        {
            log.warning("sync: error from '", from.name[], "' for unknown seq=", seq, ": ", text);
            return;
        }
        encoder_for(pf.origin._encoder).encode_error(pf.origin, pf.origin_seq, text);
        pending_forwards.remove(seq);
    }

    void inbound_sub(SyncPeer from, String pattern)
    {
        foreach (ref p; from._subscriptions[])
            if (p[] == pattern[])
                return;   // dedup
        from._subscriptions ~= pattern.move;
        const(char)[] pat = from._subscriptions[$ - 1][];

        // Walk local authoritative syncable objects; bind any that match.
        SyncPeer peer = from;
        foreach_object((BaseObject obj) nothrow @nogc {
            if (!obj._typeInfo.syncable)
                return;
            if (obj._is_remote)
                return;
            if (!pattern_matches(pat, obj))
                return;
            bind_to_peer(peer, obj);
        });
    }

    void inbound_unsub(SyncPeer from, const(char)[] pattern)
    {
        bool removed = false;
        foreach (i, ref p; from._subscriptions[])
        {
            if (p[] == pattern)
            {
                from._subscriptions.remove(i);
                removed = true;
                break;
            }
        }
        if (!removed)
            return;

        // Any bound object that no longer matches any pattern → unbind.
        for (ptrdiff_t i = cast(ptrdiff_t)from._bound.length - 1; i >= 0; --i)
        {
            BaseObject obj = from._bound[i];
            bool still_matches = false;
            foreach (ref p; from._subscriptions[])
            {
                if (pattern_matches(p[], obj))
                {
                    still_matches = true;
                    break;
                }
            }
            if (!still_matches)
                unbind_from_peer(from, obj);
        }
    }

    // Inbound: model plane

    void inbound_hello(SyncPeer from, uint ver, const(char)[] host, ubyte caps, uint max_frame, ulong node_id = 0, PeerRole role = PeerRole.none, const(char)[] cluster = null, const(ubyte)[] nonce = null)
    {
        import urt.conv : format_uint;

        from._remote_caps = caps;
        from._remote_node_id = node_id;
        from._remote_role = role;
        if (from._remote_cluster[] != cluster)
            from._remote_cluster = cluster.makeString(defaultAllocator);
        if (nonce.length == from._remote_nonce.length)
        {
            from._remote_nonce[] = nonce[];
            from._remote_nonce_set = true;
        }

        char[16] nid = void;
        if (node_id)
            format_uint(node_id, nid[], 16, 16, '0');
        log.info("hello from '", from.name[], "' host='", host, "' ver=", ver, " caps=", caps,
                 node_id ? " node=" : "", node_id ? nid[] : "");

        // One session per node. A listener spawns a peer per source address, so a node that
        // re-dialled - new ephemeral source, new spawned peer - would otherwise accumulate a
        // session per attempt, and the old ones keep transmitting: the far end receives frames
        // from several sessions over one link, restarts, and re-dials again.
        if (node_id)
        {
            Array!SyncPeer superseded;
            foreach (p; peers[])
                if (p !is from && p._remote_node_id == node_id)
                    superseded ~= p;
            foreach (p; superseded[])
            {
                log.info("session '", p.name[], "' superseded by '", from.name[], "' for node ", nid[]);
                p.destroy();
            }
        }
    }

    void inbound_claim(SyncPeer from, uint seq, const(char)[] cluster, uint priority, const(char)[] auth, const(char)[] key)
    {
        get_module!SyncPeeringModule.handle_claim(from, seq, cluster, priority, auth, key);
    }

    void inbound_model_sub(SyncPeer from, uint seq, const(char[])[] patterns, bool once, ulong from_ms = 0, ulong to_ms = 0)
    {
        SyncEncoder enc = encoder_for(from._encoder);
        foreach (pat; patterns)
        {
            Address a = Address.parse(pat);
            if (!a.valid)
            {
                enc.encode_err(from, seq, "bad_value", "bad pattern");
                return;
            }

            // arm the pattern for the live feed; a re-sub of an armed pattern just re-serves
            bool arm = !once;
            if (arm)
            {
                foreach (ref p; from._model_subs[])
                {
                    if (p[] == pat)
                    {
                        arm = false;
                        break;
                    }
                }
                if (arm)
                {
                    from._model_subs ~= pat.makeString(defaultAllocator);
                    add_feed_listener();
                }
            }

            if (!wildcard_match(a.ns, "device"))
                continue;   // only the device namespace is served so far
            foreach (dev; g_app.devices.values)
            {
                if (!dev.cid || authored_by(from, dev))
                    continue;
                if (match_path(a.subject, dev.id[]))
                    introduce_device(from, enc, dev);
                walk_elements(dev, a.subject, (Element* e, const(char)[] path) {
                    if (arm)
                        track_live(from, e);
                    send_element(from, enc, e, path);
                    if (from_ms)
                        send_backfill(from, enc, e, from_ms, to_ms);
                });
            }
        }
        enc.encode_res(from, seq);
    }

    void inbound_model_unsub(SyncPeer from, const(char[])[] patterns)
    {
        bool removed = false;
        foreach (pat; patterns)
        {
            foreach (i, ref p; from._model_subs[])
            {
                if (p[] == pat)
                {
                    from._model_subs.remove(i);
                    remove_feed_listener();
                    removed = true;
                    break;
                }
            }
        }
        if (removed)
            rebuild_live_nodes(from);
    }

    void inbound_type_format(SyncPeer from, uint ft, ref const WireFormat wf)
    {
        import urt.si.unit : ScaledUnit;
        import manager.sample : find_enum_info;

        if (ft in from._ft_recv)
        {
            log.warning("sync: peer '", from.name[], "' re-interned ft ", ft);
            return;
        }
        ValueType vt;
        if (!value_type_from_name(wf.type, vt))
        {
            log.warning("sync: type frame with unknown value type '", wf.type, "'");
            return;
        }
        const(SeriesKind)* kind = enum_from_key!SeriesKind(wf.series);
        if (!kind)
        {
            log.warning("sync: type frame with unknown series kind '", wf.series, "'");
            return;
        }

        DataFormat f;
        if (wf.enum_name.length)
        {
            const(VoidEnumInfo)* ei = find_enum_info(wf.enum_name);
            if (!ei)
            {
                log.warning("sync: format cites unknown enum '", wf.enum_name, "'");
                return;
            }
            f = DataFormat(vt, *kind, ei);
        }
        else if (wf.unit.length)
        {
            ScaledUnit su;
            float pre_scale;
            if (su.parse_unit(wf.unit, pre_scale) <= 0)
            {
                log.warning("sync: format with unparsable unit '", wf.unit, "'");
                return;
            }
            f = DataFormat(vt, *kind, su);
        }
        else
            f = DataFormat(vt, *kind);
        f.count = wf.count;
        f.rate = wf.rate;

        if (f.is_scalar && (!wf.min.isNull || !wf.max.isNull || !wf.step.isNull))
        {
            import manager.sample : register_constraint;

            Constraint c;
            void take(ref const Variant v, ref Scalar slot, Constraint.Has bit)
            {
                if (v.isNull)
                    return;
                Scalar s;
                if (unbox_scalar(v, f, s))
                {
                    slot = s;
                    c.has |= bit;
                }
                else
                    log.warning("sync: format constraint value out of range for its own type");
            }
            take(wf.min, c.min, Constraint.Has.min);
            take(wf.max, c.max, Constraint.Has.max);
            take(wf.step, c.step, Constraint.Has.step);
            if (c.has)
                f.constraint = register_constraint(c);
        }

        from._ft_recv.insert(ft, register_format(f));
    }

    void inbound_type_enum(SyncPeer from, const(char)[] name, ref Variant members)
    {
        import manager.sample : register_enum_info;

        if (!members.isObject)
        {
            log.warning("sync: enum type frame without members");
            return;
        }
        Array!(const(char)[]) keys;
        Array!long values;
        foreach (k, ref v; members)
        {
            keys ~= k;
            values ~= v.asLong();
        }
        register_enum_info(name, make_enum_info(name, keys[], values[]));
    }

    void inbound_model_add(SyncPeer from, SyncHandle handle, const(char)[] path, const(char)[] node_class, uint ft, const(char)[] access, const(char)[] mode, Variant* v, ulong t_ms)
    {
        // the handle is announced even when the node fails to materialise: it must
        // advance the announced high-water regardless, or vals citing it read as
        // still-in-flight and stall the data queue behind a node that never comes
        from.adopt(handle, materialise_add(from, path, node_class, ft, access, mode, v, t_ms));
    }

    EID materialise_add(SyncPeer from, const(char)[] path, const(char)[] node_class, uint ft, const(char)[] access, const(char)[] mode, Variant* v, ulong t_ms)
    {
        import urt.time : from_unix_time_ns;

        Address a = Address.parse(path);
        if (!a.valid || a.ns[] != "device")
        {
            log.warning("sync: add with unsupported path '", path, "'");
            return EID.invalid;
        }
        const(char)[] rest = a.subject;
        const(char)[] dev_id = rest.split!'.';

        Device dev = find_or_create_remote_device(dev_id);
        if (!dev)
            return EID.invalid;

        if (node_class[] == "device")
            return EID(dev.cid);
        if (node_class[] != "element" || rest.empty)
        {
            log.warning("sync: add with unsupported class '", node_class, "' at '", path, "'");
            return EID.invalid;
        }
        FormatId* pf = ft in from._ft_recv;
        if (!pf)
        {
            log.warning("sync: add cites unknown ft ", ft);
            return EID.invalid;
        }
        Element* e = dev.find_or_create_element(rest, *pf);
        if (!e)
            return EID.invalid;
        if (e.data_format.kind == SeriesKind.point && !e.has_history)
        {
            // a mirror event log retains the same window the authority's default gives
            e.retention(256, 16_384);
            e.retention(3600.seconds);
        }
        if (access.length)
        {
            if (const(Access)* acc = enum_from_key!Access(access))
                e.access = *acc;
        }
        if (mode.length)
        {
            if (const(SamplingMode)* m = enum_from_key!SamplingMode(mode))
                e.sampling_mode = *m;
        }
        if (v && !v.isNull)
            e.value(*v, t_ms ? from_unix_time_ns(t_ms * 1_000_000) : getSysTime());
        return e.ensure_eid();
    }

    // Element write. `res {seq, value}` carries the applied value; any further
    // consequence flows back through the ordinary feed.
    void inbound_model_set(SyncPeer from, uint seq, SyncHandle handle, const(char)[] path, Variant* value, bool reset)
    {
        SyncEncoder enc = encoder_for(from._encoder);
        Element* e;
        if (path.length)
        {
            Address a = Address.parse(path);
            if (!a.valid || a.ns[] != "device")
            {
                enc.encode_err(from, seq, "unknown_path", path);
                return;
            }
            e = g_app.find_element(a.subject);
        }
        else
            e = resolve_element(from.node_of(handle));
        if (!e)
        {
            enc.encode_err(from, seq, path.length ? "unknown_path" : "unknown_handle", path);
            return;
        }
        if (reset)
        {
            enc.encode_err(from, seq, "unsupported", "elements have no reset");
            return;
        }

        Component c = e.parent;
        while (c && !c.is_device)
            c = c.parent;
        Device dev = cast(Device)cast(void*)c;    // extern(C++) has no dynamic cast; is_device checked above
        if (dev && dev.remote)
        {
            // routing a mirror write to its authority is not built yet
            enc.encode_err(from, seq, "not_authoritative", "element belongs to a remote device");
            return;
        }
        if (!(e.access & Access.write))
        {
            enc.encode_err(from, seq, "access_denied", "read-only element");
            return;
        }
        if (!value || value.isNull)
        {
            enc.encode_err(from, seq, "bad_value", "set requires a value");
            return;
        }
        if (const(char)[] error = e.try_set(*value))
        {
            enc.encode_err(from, seq, "bad_value", error);
            return;
        }
        Variant applied = e.value;
        enc.encode_res(from, seq, applied);
    }

    // false = the handle's add is still in flight on the ordered control plane; the
    // sublayer withholds the ack so the sender's catch-up retries it. An announced
    // handle that doesn't resolve is dead (its node failed to materialise or is
    // gone) - those samples are skipped, never held, so a poison val can't stall
    // the queue behind it.
    bool inbound_val(SyncPeer from, SyncHandle handle, ref Variant value, ulong t_ms)
    {
        import urt.time : from_unix_time_ns;

        EID node = from.node_of(handle);
        Element* e = resolve_element(node);
        if (!e)
        {
            if (!from.handle_announced(handle))
                return false;
            log.debug_("sync: val for dead handle ", handle);
            return true;
        }
        e.value(value, t_ms ? from_unix_time_ns(t_ms * 1_000_000) : getSysTime());
        return true;
    }

    void inbound_res(SyncPeer from, uint seq)
    {
        if (get_module!SyncPeeringModule.claim_response(from, seq, true, null, null))
            return;
        log.info("sync: model burst complete from '", from.name[], "' seq=", seq);
    }

    void inbound_err(SyncPeer from, uint seq, const(char)[] code, const(char)[] text)
    {
        if (get_module!SyncPeeringModule.claim_response(from, seq, false, code, text))
            return;
        log.warning("sync: err from '", from.name[], "' seq=", seq, " code=", code, ": ", text);
    }

    void inbound_history_req(SyncPeer from, const(char)[] path, ulong from_ms, ulong to_ms, uint max_points, uint seq)
    {
        import urt.time : getSysTime, unixTimeNs;
        import manager.record;

        RecordStream* rs = get_module!RecordModule.find_stream(path);
        if (!rs)
        {
            encoder_for(from._encoder).encode_error(from, seq, "no record stream");
            return;
        }

        ulong now_ms = unixTimeNs(getSysTime()) / 1_000_000;
        if (to_ms == 0 || to_ms > now_ms)
            to_ms = now_ms;
        if (max_points == 0)
            max_points = 500;
        else if (max_points > max_history_points)
            max_points = max_history_points;

        Array!Sample local;
        query_local(*rs, from_ms * 1_000_000, to_ms * 1_000_000, max_points, QueryMode.raw, local);
        encoder_for(from._encoder).encode_history(from, seq, path, local[]);
    }

    void inbound_enum_req(SyncPeer from, const(char)[] type_name, uint seq)
    {
        import manager.sample : find_enum_info;
        const(VoidEnumInfo)* e = find_enum_info(type_name);
        if (!e)
        {
            encoder_for(from._encoder).encode_error(from, seq, "unknown enum");
            return;
        }

        Variant members;
        foreach (i; 0 .. e.count)
        {
            const(char)[] key = e.key_by_decl_index(i);
            members.insert(key, e.value_for(key));
        }
        encoder_for(from._encoder).encode_enum(from, type_name, members, seq);
    }

    void inbound_enum(SyncPeer from, const(char)[] type_name, ref const Variant members, uint seq)
    {
        // TODO: resolve pending_forwards[seq] for PendingKind.enum_req (outbound
        // enum requests aren't yet wired - no callback mechanism on this side).
        log.info("sync: inbound enum '", type_name, "' from '", from.name[], "' seq=", seq);
    }

    // Inbound: time sync

    void inbound_time_req(SyncPeer from, uint seq)
    {
        if (!wall_time_set())
            return; // no authoritative time to serve yet; the remote will retry

        from._time_subordinate = true; // pulled from us -> wants our delta pushes
        ulong recv_ns = unixTimeNs(getSysTime());
        ulong xmit_ns = unixTimeNs(getSysTime());
        encoder_for(from._encoder).encode_time_resp(from, seq, recv_ns, xmit_ns, _timebase_version);
    }

    void inbound_time_resp(SyncPeer from, uint seq, ulong recv_ns, ulong xmit_ns, uint ver)
    {
        if (!from._time_authority)
        {
            log.warning("sync: time_resp from non-authority '", from.name[], "'");
            return;
        }
        if (from._time_seq == 0 || seq != from._time_seq)
            return; // unsolicited or stale

        MonoTime t4 = getTime();

        // Subtract the authority's processing (xmit - recv) from the round trip,
        // halve for one-way, anchor to its transmit timestamp (xmit).
        long t2 = cast(long)recv_ns, t3 = cast(long)xmit_ns;
        long rtt = (t4 - from._time_t1).as!"nsecs";
        long corrected = t3 + (rtt - (t3 - t2)) / 2;
        from._time_seq = 0;
        from._last_authority_version = ver;
        from._next_time_poll = t4 + time_poll_interval;

        set_utc_time(cast(ulong)corrected); // on_clock_step fans the resulting step to our subordinates
        log.info("sync: clock synced from authority '", from.name[], "'");
    }

    void inbound_time_push(SyncPeer from, uint ver, long delta_ns)
    {
        if (!from._time_authority)
        {
            log.warning("sync: time_push from non-authority '", from.name[], "'");
            return;
        }
        if (!wall_time_set() || ver > from._last_authority_version + 1)
        {
            // Never established, or we missed a correction: re-establish by pull.
            send_time_req(from);
            return;
        }
        if (ver <= from._last_authority_version)
            return; // already accounted for (e.g. via a pull)

        from._last_authority_version = ver;
        _applying_push = from;
        adjust_utc_time(delta_ns); // on_clock_step chains it to our own subordinates
        _applying_push = null;
    }

    void on_clock_step(long delta_ns)
    {
        if (delta_ns == 0)
            return;
        ++_timebase_version;
        foreach (p; peers[])
        {
            if (!p._time_subordinate || p is _applying_push)
                continue;
            encoder_for(p._encoder).encode_time_push(p, _timebase_version, delta_ns);
        }
    }

    void poll_time_authorities()
    {
        MonoTime now = getTime();
        foreach (p; peers[])
        {
            if (!p._time_authority)
                continue;
            if (p._time_seq != 0)
            {
                if (now - p._time_t1 > time_response_timeout)
                {
                    p._time_seq = 0;
                    p._next_time_poll = now + time_retry_interval;
                }
                continue;
            }
            if (now >= p._next_time_poll)
                send_time_req(p);
        }
    }

    void send_time_req(SyncPeer p)
    {
        p._time_seq = alloc_seq();
        p._time_t1 = getTime();
        encoder_for(p._encoder).encode_time_req(p, p._time_seq);
    }

    // Fan-out helpers (internal)

    void fan_out_add_name(BaseObject obj)
    {
        foreach (p; peers[])
            encoder_for(p._encoder).encode_add_name(p, obj);
    }

    void fan_out_state(BaseObject obj, StateSignal sig)
    {
        // Only online/offline go on the wire. destroyed is communicated via
        // unbind (see fan_out_unbind) - the binding ending is what a subscriber
        // cares about, regardless of whether the upstream destroyed the object
        // or the peer just stopped tracking it.
        assert(sig != StateSignal.destroyed, "fan_out_state: destroyed is not sent on the wire");
        foreach (p; peers[])
        {
            foreach (bound; p._bound[])
            {
                if (bound is obj)
                {
                    encoder_for(p._encoder).encode_state(p, obj.id, sig);
                    break;
                }
            }
        }
    }

    // Emits unbind to every peer that has `obj` bound. `correlate` + `corr_seq`
    // let the originator of a destroy request receive the correlation ack on
    // their same unbind frame; all other peers get seq=0. `exclude` skips a
    // peer entirely - used when the authority already told us, so we don't
    // echo unbind back to them.
    void fan_out_unbind(BaseObject obj, SyncPeer correlate = null, uint corr_seq = 0, SyncPeer exclude = null)
    {
        foreach (p; peers[])
        {
            if (p is exclude)
                continue;
            bool has = false;
            foreach (bound; p._bound[])
                if (bound is obj) { has = true; break; }
            if (!has)
                continue;
            uint s = (p is correlate) ? corr_seq : 0;
            unbind_from_peer(p, obj, s);
        }
    }

    // Fan a reset echo to every bound peer. Same correlate/exclude semantics
    // as echo_set.
    void echo_reset(BaseObject obj, size_t prop_index, const(char)[] prop_name, SyncPeer correlate, uint correlate_seq, SyncPeer exclude = null)
    {
        ulong mask = ulong(1) << prop_index;
        debug assert_reset_matches_init(obj, *obj.properties()[prop_index]);
        foreach (p; peers[])
        {
            if (p is exclude)
                continue;
            foreach (bound; p._bound[])
            {
                if (bound is obj)
                {
                    uint s = (p is correlate) ? correlate_seq : 0;
                    encoder_for(p._encoder).encode_reset(p, obj.id, prop_name, s);

                    ushort slot = find_sync_slot(obj, p);
                    if (slot != sync_slot_none)
                        sync_state(slot).props_dirty &= ~mask;
                    break;
                }
            }
        }
    }

    // Fan a set echo to every bound peer. `correlate` + `correlate_seq` go
    // to one peer for correlation; everyone else gets seq=0. `exclude` skips
    // a peer entirely - used on the hub-of-hubs path when the authority has
    // already told us and we must not echo back to them.
    void echo_set(BaseObject obj, size_t prop_index, SyncPeer correlate, uint correlate_seq, SyncPeer exclude = null)
    {
        ulong mask = ulong(1) << prop_index;
        foreach (p; peers[])
        {
            if (p is exclude)
                continue;
            foreach (bound; p._bound[])
            {
                if (bound is obj)
                {
                    uint s = (p is correlate) ? correlate_seq : 0;
                    encoder_for(p._encoder).encode_set(p, obj, prop_index, s);

                    // We just emitted to this peer - clear its dirty bit so
                    // tick_dirty doesn't re-emit.
                    ushort slot = find_sync_slot(obj, p);
                    if (slot != sync_slot_none)
                        sync_state(slot).props_dirty &= ~mask;
                    break;
                }
            }
        }
    }

    // Local object lifecycle hooks (registered in init)

    void on_object_lifecycle(BaseObject obj, ObjectLifecycleEvent event)
    {
        // Destruction fan-out (unbind) is handled via the state hook
        // (on_object_state) so the correlation seq can be threaded through;
        // here we only retire the dead object's session handles - the slots
        // must stop resolving, and they never rebind.
        if (event == ObjectLifecycleEvent.destroyed)
        {
            foreach (p; peers[])
                p.forget(obj);
            return;
        }
        if (event != ObjectLifecycleEvent.created)
            return;

        if (!obj._typeInfo.syncable)
            return;
        if (obj._is_remote)
            return;   // proxy creation is driven by inbound_add_name; don't re-broadcast.

        fan_out_add_name(obj);

        // Auto-bind to any peer whose active subscription patterns match.
        foreach (p; peers[])
        {
            foreach (ref pat; p._subscriptions[])
            {
                if (pattern_matches(pat[], obj))
                {
                    bind_to_peer(p, obj);
                    break;
                }
            }
        }
    }

    void on_object_state(ActiveObject obj, StateSignal sig)
    {
        if (!obj._typeInfo.syncable || obj._is_remote)
            return;

        if (sig == StateSignal.destroyed)
        {
            // Fan out unbind to bound peers. If inbound_destroy preempted this
            // fan-out (to pass a correlation seq to the requester), _bound is
            // already empty for this obj on each peer and fan_out_unbind is a
            // no-op.
            fan_out_unbind(obj);
        }
        else
            fan_out_state(obj, sig);
    }

    // Bind / unbind bookkeeping
    //
    // A peer "binding" to an object means: we've sent bind{} to the peer and
    // will echo future property changes. Backed by a per-peer sync_state slot
    // chained onto obj._sync_slot; encoders read that slot in tick_dirty.

    void bind_to_peer(SyncPeer peer, BaseObject obj, uint seq = 0)
    {
        bool already_bound = false;
        foreach (bound; peer._bound[])
            if (bound is obj) { already_bound = true; break; }

        if (!already_bound)
        {
            ushort slot = sync_state_alloc(peer);
            sync_state(slot).next = obj._sync_slot;
            obj._sync_slot = slot;
            peer._bound ~= obj;
        }

        // Emit if this is a fresh bind, or if `seq` carries a correlation ack
        // the requester is expecting. Already-bound + seq=0 collapses to a
        // no-op - used by the subscription auto-bind path which is idempotent.
        if (!already_bound || seq != 0)
            encoder_for(peer._encoder).encode_bind(peer, obj, seq);
    }

    void unbind_from_peer(SyncPeer peer, BaseObject obj, uint seq = 0)
    {
        foreach (i, bound; peer._bound[])
        {
            if (bound is obj)
            {
                peer._bound.remove(i);
                break;
            }
        }

        // Unlink this peer's slot from obj's _sync_slot chain.
        ushort target = sync_slot_none;
        if (obj._sync_slot != sync_slot_none &&
            sync_state(obj._sync_slot).channel is peer)
        {
            target = obj._sync_slot;
            obj._sync_slot = sync_state(target).next;
        }
        else
        {
            ushort prev = obj._sync_slot;
            while (prev != sync_slot_none)
            {
                ref prev_ss = sync_state(prev);
                if (prev_ss.next != sync_slot_none &&
                    sync_state(prev_ss.next).channel is peer)
                {
                    target = prev_ss.next;
                    prev_ss.next = sync_state(target).next;
                    break;
                }
                prev = prev_ss.next;
            }
        }
        if (target != sync_slot_none)
            sync_state_free(target);

        encoder_for(peer._encoder).encode_unbind(peer, obj.id, seq);
    }

    // Walk obj's _sync_slot chain and return the slot owned by `peer`, or
    // sync_slot_none if not bound. O(peers_on_obj) - typically 1.
    ushort find_sync_slot(BaseObject obj, SyncPeer peer)
    {
        for (ushort slot = obj._sync_slot; slot != sync_slot_none; )
        {
            ref ss = sync_state(slot);
            if (ss.channel is peer)
                return slot;
            slot = ss.next;
        }
        return sync_slot_none;
    }

    // Global name lookup. Names are unique across collections, so exactly one
    // object matches (or none). O(all objects) - cold path (rekey / rare).
    BaseObject find_by_name(const(char)[] name)
    {
        BaseObject result = null;
        foreach_object((BaseObject obj) nothrow @nogc {
            if (result !is null)
                return;
            if (obj.name[] == name)
                result = obj;
        });
        return result;
    }

    // Model-plane introduction: schema pushed before first cite, node bound to a
    // session handle, current value riding the add frame.

    void introduce_device(SyncPeer to, SyncEncoder enc, Device dev)
    {
        import urt.mem.temp : tconcat;

        EID node = EID(dev.cid);
        if (to.handle_of(node) != SyncPeer.invalid_handle)
            return;
        SyncHandle h = to.introduce(node);
        enc.encode_add(to, h, tconcat("device:", dev.id[]), "device", 0, null);
    }

    void send_element(SyncPeer to, SyncEncoder enc, Element* e, const(char)[] path)
    {
        import urt.mem.temp : tconcat;
        import manager.sample : enum_info_name;

        if (!e.format.valid)
            return;
        const(DataFormat)* fmt = e.data_format;
        if (!wire_serialisable(*fmt))
        {
            log.debug_("sync: skipping unserialisable element ", path);
            return;
        }
        EID node = e.ensure_eid();
        if (!node)
            return;
        SyncHandle h = to.handle_of(node);
        if (h != SyncPeer.invalid_handle)
        {
            enc.encode_val(to, h, e);
            return;
        }
        if (fmt.desc == DataFormat.Desc.enum_)
        {
            const(char)[] ename = enum_info_name(fmt.enum_info);
            if (!ename)
            {
                log.warning("sync: element ", path, " cites an unregistered enum - skipped");
                return;
            }
            if (!to.enum_seen(fmt.enum_info))
                enc.encode_type_enum(to, ename, fmt.enum_info);
        }
        bool first;
        uint ft = to.ft_of(e.format, first);
        if (first)
            enc.encode_type_format(to, ft, *fmt);
        h = to.introduce(node);
        enc.encode_add(to, h, tconcat("device:", path), "element", ft, e);
    }

    // Backfill behind the add: the add already carried the latest value, history streams
    // as val blocks after it so a UI paints instantly and fills the chart. Served
    // synchronously within the burst; nothing can interleave, so a live sub's feed takes
    // over gap-free where the backfill ends. The series spans its full recorded history
    // (disk-evicted buckets reconstitute through the store), so from_ms is honoured as
    // far as history exists.
    void send_backfill(SyncPeer to, SyncEncoder enc, Element* e, ulong from_ms, ulong to_ms)
    {
        import urt.time : from_unix_time_ns;

        if (!e.has_history)
            return;
        SyncHandle h = to.handle_of(e.ensure_eid());
        if (h == SyncPeer.invalid_handle)
            return;
        ulong idx = e.index_for_time(from_unix_time_ns(from_ms * 1_000_000));
        if (idx == ulong.max)
            return;
        SysTime to_t = to_ms ? from_unix_time_ns(to_ms * 1_000_000) : SysTime();
        for (;;)
        {
            RecordBlock blk = e.read_records(idx, 256);
            if (!blk.count)
                break;
            if (to_ms)
            {
                uint full = blk.count;
                while (blk.count && blk.time(blk.count - 1) > to_t)
                    --blk.count;
                if (blk.count)
                    enc.encode_val_block(to, h, blk);
                if (blk.count < full)
                    break;
            }
            else
                enc.encode_val_block(to, h, blk);
            idx = blk.first_index + blk.count;
        }
    }

    // true when this peer announced the device; its mirror is never served back to it,
    // but is served to other peers (hub fan-out)
    bool authored_by(SyncPeer p, Device dev)
    {
        SyncHandle h = p.handle_of(EID(dev.cid));
        return h != SyncPeer.invalid_handle && (h & 1);
    }

    // arms a node for the live feed; several patterns may match one node, within one sub or
    // across successive ones, and re-arming must not rewind the cursor or records arriving
    // between the two arms would never be sent
    void track_live(SyncPeer to, Element* e)
    {
        EID node = e.ensure_eid();
        if (!node)
            return;
        if ((node.raw in to._live_nodes) is null)
            to._live_nodes.insert(node.raw, e.record_count);
    }

    // Recomputes the armed set from the surviving patterns, so a node stays armed while any
    // pattern still matches it and no arm count has to be maintained. Survivors keep their
    // cursor: re-seeding record_count would skip everything recorded but not yet sent.
    void rebuild_live_nodes(SyncPeer from)
    {
        Map!(ulong, bool) matched;
        foreach (ref pat; from._model_subs[])
        {
            Address a = Address.parse(pat[]);
            if (!a.valid || !wildcard_match(a.ns, "device"))
                continue;
            foreach (dev; g_app.devices.values)
            {
                if (!dev.cid || authored_by(from, dev))
                    continue;
                walk_elements(dev, a.subject, (Element* e, const(char)[] path) {
                    EID node = e.ensure_eid();
                    if (!node)
                        return;
                    matched.insert(node.raw, true);
                    if ((node.raw in from._live_nodes) is null)
                        from._live_nodes.insert(node.raw, e.record_count);
                });
            }
        }

        Array!ulong doomed;
        foreach (k; from._live_nodes.keys)
        {
            if (!matched.exists(k))
                doomed ~= k;
        }
        foreach (k; doomed[])
            from._live_nodes.remove(k);
    }

    // Creation notification: a node appearing later that matches an armed pattern
    // receives its add when it appears - no dedicated verb.
    void on_element_lifecycle(Element* e, ElementLifecycleEvent event)
    {
        if (event != ElementLifecycleEvent.created)
            return;

        Component c = e.parent;
        while (c && !c.is_device)
            c = c.parent;
        if (!c)
            return;
        Device dev = cast(Device)cast(void*)c;    // extern(C++) has no dynamic cast; is_device checked above
        if (!dev.cid)
            return;

        char[256] buf = void;
        ptrdiff_t len = e.full_path(buf);
        if (len <= 0 || len > buf.length)
            return;
        const(char)[] path = buf[0 .. len];

        foreach (p; peers[])
        {
            if (authored_by(p, dev))
                continue;
            foreach (ref pat; p._model_subs[])
            {
                Address a = Address.parse(pat[]);
                if (!a.valid || !wildcard_match(a.ns, "device") || !match_path(a.subject, path))
                    continue;
                track_live(p, e);
                send_element(p, encoder_for(p._encoder), e, path);
                break;
            }
        }
    }

    Device find_or_create_remote_device(const(char)[] id)
    {
        if (Device* d = id in g_app.devices)
        {
            if (!(*d).remote)
            {
                log.warning("sync: remote device '", id, "' collides with a local device - ignored");
                return null;
            }
            return *d;
        }
        Device dev = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
        dev.remote = true;
        g_app.devices.insert(dev.id[], dev);
        return dev;
    }

    // Helpers

    uint alloc_seq()
    {
        uint s = ++next_seq;
        if (s == 0) s = ++next_seq;  // skip reserved zero on wrap
        return s;
    }
}


private:

// /sync/model-sub peer=<peer> pattern=<address> [once=no] - model read; once=no arms a live feed
void sync_model_sub(Session session, SyncPeer peer, const(char)[] pattern, Nullable!bool once)
{
    SyncModule mod = get_module!SyncModule;
    const(char)[][1] patterns = [pattern];
    encoder_for(peer._encoder).encode_model_sub(peer, mod.alloc_seq(), patterns[], !once || once.value);
}

// /sync/log-sub peer=<name> [severity=<sev>] [tag=<prefix>]
CommandState sync_log_sub(Session session, const(char)[] peer, Nullable!Severity severity, Nullable!(const(char)[]) tag)
{
    SyncModule mod = get_module!SyncModule;
    SyncPeer target;
    foreach (p; mod.peers[])
    {
        if (p.name[] == peer)
        {
            target = p;
            break;
        }
    }
    if (!target)
    {
        session.write_line("no such sync peer: ", peer);
        return null;
    }

    bool off = !severity;
    target.request_logs(off ? Severity.info : severity.value, off, tag ? tag.value : null);
    return null;
}
