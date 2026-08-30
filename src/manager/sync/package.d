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
import urt.mem;
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
import manager.element : Access, add_feed_listener, Cursor, Element, ElementLifecycleEvent,
                         register_element_lifecycle_handler, remove_feed_listener, sweep_dirty;
import manager.id : EID;
import manager.path : Address, match_path, pattern_matches, walk_elements, walk_elements_until;
import manager.series : Constraint, DataFormat, format_info, FormatId, RecordBlock, register_format, Scalar,
                        SeriesKind, unbox_scalar, valid, value_compatible, ValueType;
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
    SyncPeer    dest;         // authoritative peer the request was forwarded to
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

        g_json_encoder = alloc!JsonEncoder(this);
        g_encoders[SyncEncoderKind.json] = g_json_encoder;
        g_binary_encoder = alloc!BinaryEncoder(this);
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

        each_running_peer((SyncPeer p) { tick_peer(p); });

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
            each_running_peer((SyncPeer p) { flush_pending_vals(p); });
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
            free(req.command);
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

        p._intro_table = 0;
        p._intro_slot = 1;
        p._introducing = true;
        pump_introductions(p);
    }

    // removal-safe walk for transmitting bodies: a refused send may detach the peer under it
    void each_running_peer(scope void delegate(SyncPeer p) nothrow @nogc fn)
    {
        for (size_t i = 0; i < peers.length; )
        {
            SyncPeer p = peers[i];
            if (p.running)
                fn(p);
            if (i < peers.length && peers[i] is p)
                ++i;
        }
    }

    void tick_peer(SyncPeer p)
    {
        if (p._introducing)
        {
            pump_introductions(p);
            return;
        }
        pump_model_intro(p);
        encoder_for(p._encoder).tick_dirty(p);
        p.flush_logs();
    }

    void flush_pending_vals(SyncPeer p)
    {
        if (p._pending_vals.empty)
            return;
        SyncEncoder enc = encoder_for(p._encoder);
        uint gen = p.begin_burst();
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
                ulong committed = *next;
                auto c = e.open_series_cursor(committed);
                for (;;)
                {
                    RecordBlock blk = c.next(256);
                    if (!blk.count)
                        break;
                    enc.encode_val_block(p, h, blk);
                    if (!p.send_ok(gen))
                        break;
                    committed = c.position;
                }
                // position commits only past accepted sends, and the send may have torn the
                // session down and freed the map entry, so look it up again
                if (ulong* live = node.raw in p._live_nodes)
                    *live = committed;
                e.close_series_cursor(c);
            }
            else
                enc.encode_val(p, h, e);
            if (!p.send_ok(gen))
                return;   // the session went down under the burst; its pending set went with it
        }
        p._pending_vals.clear();
    }

    void pump_introductions(SyncPeer p)
    {
        if (!p._introducing)
            return;

        SyncEncoder enc = encoder_for(p._encoder);
        uint gen = p.begin_burst();
        while (p.control_window_free() > SyncPeer.control_reserve)
        {
            BaseObject obj = next_object(p._intro_table, p._intro_slot);
            if (!obj)
            {
                p._introducing = false;
                return;
            }
            if (!obj._typeInfo.syncable || obj._is_remote)
                continue;
            if (p.handle_of(obj) != SyncPeer.invalid_handle)
                continue;   // the lifecycle hook announced it while the walk was paused
            enc.encode_add_name(p, obj);
            if (!p.send_ok(gen))
                return;
        }
    }

    void pump_model_intro(SyncPeer p)
    {
        pump_live_rescan(p);
        if (p._pending_subs.empty && p._pending_live.empty)
            return;
        SyncEncoder enc = encoder_for(p._encoder);
        uint gen = p.begin_burst();

        while (!p._pending_live.empty)
        {
            if (p.control_window_free() <= SyncPeer.control_reserve)
                return;
            EID node = p._pending_live[0];
            p._pending_live.remove(0);
            if (Element* e = resolve_element(node))
            {
                if (authored_by(p, e))
                    continue;
                char[256] buf = void;
                ptrdiff_t len = e.full_path(buf);
                if (len > 0 && len <= buf.length)
                    introduce_element(p, enc, e, buf[0 .. len], gen, true, 0, 0);
            }
            if (!p.send_ok(gen))
                return;
        }

        while (!p._pending_subs.empty)
        {
            ref sub = p._pending_subs[0];
            bool starved = false;

            uint device_index = 0;
            foreach (dev; g_app.devices.values)
            {
                if (device_index < sub.device_cursor)
                {
                    ++device_index;
                    continue;
                }
                if (!dev.cid || dev.private_)
                {
                    ++device_index;
                    ++sub.device_cursor;
                    continue;
                }

                if (!sub.device_sent)
                {
                    if (p.control_window_free() <= SyncPeer.control_reserve)
                    {
                        starved = true;
                        break;
                    }
                    if (match_path(sub.pattern[], dev.id[]))
                        introduce_device(p, enc, dev);
                    if (!p.send_ok(gen))
                        return;
                    sub.device_sent = true;
                }

                uint match_index = 0;
                bool complete = walk_elements_until(dev, sub.pattern[], (Element* e, const(char)[] path)
                {
                    if (match_index++ < sub.element_cursor)
                        return true;
                    if (authored_by(p, e))
                    {
                        ++sub.element_cursor;
                        return true;
                    }
                    if (p.control_window_free() <= SyncPeer.control_reserve)
                        return false;
                    if (sub.arm)
                        track_live(p, e);
                    introduce_element(p, enc, e, path, gen, sub.arm, sub.from_ms, sub.to_ms);
                    ++sub.element_cursor;
                    return p.send_ok(gen);
                });
                if (!p.send_ok(gen))
                    return;
                if (!complete)
                {
                    starved = true;
                    break;
                }

                ++device_index;
                ++sub.device_cursor;
                sub.element_cursor = 0;
                sub.device_sent = false;
            }

            if (starved)
                return;

            if (sub.res_seq)
            {
                if (p.control_window_free() <= SyncPeer.control_reserve)
                    return;
                enc.encode_res(p, sub.res_seq);
                if (!p.send_ok(gen))
                    return;
            }
            p._pending_subs.remove(0);
        }
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
        ++p._session_gen;   // any burst spanning this teardown is dead, even if its sends succeeded
        p._send_failed = true;   // condemned until the replacement session's startup
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
        p._warned_name_count = 0;
        p._remote_caps = 0;
        p.reset_sublayer();           // seq spaces are session state
        p._remote_nonce_set = false;
        p._local_nonce_set = false;   // a reconnect is a new session; fresh nonce
        p._ft_sent.clear();
        p._next_ft = 0;
        p._enums_sent.clear();
        p._ft_recv.clear();
        p.detach_model_bindings();
        foreach (ref pat; p._model_subs[])
            remove_feed_listener();
        p._model_subs.clear();
        p._live_nodes.clear();
        p._pending_vals.clear();
        p._pending_subs.clear();
        p._pending_live.clear();
        p._live_rescan = false;
        p._rescan_cursor = 0;

        // forwards die with either endpoint; a dead destination answers the origin with err
        Array!uint doomed;
        Array!PendingForward stranded;
        foreach (kvp; pending_forwards[])
        {
            if (kvp.value.origin is p || kvp.value.dest is p)
            {
                doomed ~= kvp.key;
                if (kvp.value.origin !is p)
                    stranded ~= kvp.value;
            }
        }
        foreach (k; doomed[])
            pending_forwards.remove(k);
        foreach (ref f; stranded[])
        {
            if (f.origin.running)
                encoder_for(f.origin._encoder).encode_error(f.origin, f.origin_seq, "authority detached");
        }

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
        if (!from.adoptable(handle))
        {
            log.warning("add_name from '", from.name[], "' with unusable handle ", handle);
            return;
        }
        // an accepted handle always advances the table, even when the name can't be
        // reserved, or every handle behind it reads as sparse
        EID local = EID.invalid;
        auto rt = type in g_app.types;
        if (!rt)
        {
            if (from.first_sighting(type))
                log.warning("add_name from '", from.name[], "' with unknown type '", type, "'");
        }
        else if (rt.type_info.is_abstract)
            log.warning("add_name from '", from.name[], "' for abstract type '", type, "'");
        else
        {
            ubyte type_idx = cast(ubyte)rt.type_info.collection_id;
            local = EID(item_table(type_idx).reserve(name, type_idx));
        }
        from.adopt(handle, local);
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
                if (from.first_sighting(type))
                    log.warning("bind from '", from.name[], "' for unknown type '", type, "' - cannot materialize proxy for CID ", target.raw);
                return;
            }
            const(CollectionTypeInfo)* ti = rt.type_info;
            if (ti.is_abstract)
            {
                log.warning("bind from '", from.name[], "' for abstract type '", type, "'");
                return;
            }

            const(char)[] name = get_id(target)[];
            if (name.length == 0)
            {
                log.warning("bind from '", from.name[], "' for CID ", target.raw, " with no prior add_name");
                return;
            }

            BaseCollection coll = BaseCollection(ti);
            proxy = coll.alloc(name, ObjectFlags.remote);
            if (!proxy)
            {
                log.warning("bind from '", from.name[], "' - alloc failed for '", name, "' (", type, ")");
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
                log.warning("bind re-announce for '", proxy.name[], "' from a different peer than current authority");
        }
        else
        {
            // Bind targeting a local authoritative object - protocol violation.
            log.warning("bind from '", from.name[], "' targeting our local '", proxy.name[], "' - ignoring");
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
        each_running_peer((SyncPeer p) {
            if (p is from)
                return;
            encoder_for(p._encoder).encode_add_name(p, proxy);
            foreach (ref pat; p._subscriptions[])
            {
                if (pattern_matches(pat[], proxy))
                {
                    bind_to_peer(p, proxy);
                    break;
                }
            }
        });
    }

    void inbound_unbind(SyncPeer from, CID target, uint seq)
    {
        BaseObject proxy = get_item(target);
        if (!proxy)
        {
            log.warning("unbind from '", from.name[], "' for unknown CID ", target.raw);
            return;
        }
        auto pp = target in authority;
        if (!pp || *pp !is from)
        {
            log.warning("unbind from '", from.name[], "' for '", proxy.name[], "' which they don't own");
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
            pending_forwards[local_seq] = PendingForward(from, seq, PendingKind.destroy, auth);
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
            log.warning("state from '", from.name[], "' for unknown CID ", target.raw);
            return;
        }

        if (auto ao = dyn_cast!ActiveObject(proxy))
            ao.set_remote_state(sig);

        // Fan out to our bound peers (hub-of-hubs).
        each_running_peer((SyncPeer p) {
            if (p is from)
                return;
            foreach (bound; p._bound[])
            {
                if (bound is proxy)
                {
                    encoder_for(p._encoder).encode_state(p, target, sig);
                    break;
                }
            }
        });
    }

    // Inbound: property sync

    void inbound_set(SyncPeer from, CID target, const(char)[] prop,
                     ref const Variant value, uint seq)
    {
        BaseObject obj = get_item(target);
        if (!obj)
        {
            log.warning("set from '", from.name[], "' for unknown CID ", target.raw);
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
                log.warning("proxy set failed for '", obj.name[], ".", prop, "': ", r.message);
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
            pending_forwards[local_seq] = PendingForward(from, seq, PendingKind.set, auth);
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
            log.warning("reset from '", from.name[], "' for unknown CID ", target.raw);
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
            pending_forwards[local_seq] = PendingForward(from, seq, PendingKind.reset, auth);
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
            log.warning("malformed log frame from '", from.name[], "'");
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
            log.warning("result from '", from.name[], "' for unknown seq=", seq);
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
            log.warning("error from '", from.name[], "' for unknown seq=", seq, ": ", text);
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
        bool dead = false;
        foreach_object((BaseObject obj) nothrow @nogc {
            if (dead || !obj._typeInfo.syncable)
                return;
            if (obj._is_remote)
                return;
            if (!pattern_matches(pat, obj))
                return;
            if (!bind_to_peer(peer, obj))
                dead = true;
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
            from._remote_cluster = cluster.make_string();
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

        // a node's newest session supersedes any older one it re-dialled away from
        if (node_id)
        {
            Array!SyncPeer superseded;
            collect_superseded(peers[], from, node_id, superseded);
            foreach (p; superseded[])
            {
                if (p.flags & ObjectFlags.dynamic)
                {
                    // disable, not destroy: teardown runs from the state machine next tick,
                    // and destruction stays with the object's owner (listener sweep, operator)
                    log.info("session '", p.name[], "' superseded by '", from.name[], "' for node ", nid[]);
                    p.disabled(true);
                }
                else
                    log.warning("peer '", p.name[], "' also carries node ", nid[], "; configured peers are not superseded");
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

        Array!(const(char)[]) to_arm;
        Array!(SyncPeer.PendingSub) staged;
        foreach (pat; patterns)
        {
            Address a = Address.parse(pat);
            if (!a.valid)
            {
                enc.encode_err(from, seq, "bad_value", "bad pattern");
                return;
            }

            if (!once)
            {
                bool armed = false;
                foreach (ref p; from._model_subs[])
                {
                    if (p[] == pat)
                    {
                        armed = true;
                        break;
                    }
                }
                foreach (ref p; to_arm[])
                {
                    if (p[] == pat)
                    {
                        armed = true;
                        break;
                    }
                }
                if (!armed)
                    to_arm ~= pat;
            }

            if (!wildcard_match(a.ns, "device"))
                continue;   // only the device namespace is served so far
            SyncPeer.PendingSub req;
            req.pattern = a.subject.make_string();
            req.from_ms = from_ms;
            req.to_ms = to_ms;
            req.arm = !once;
            staged ~= req.move;
        }

        if (from._pending_subs.length + staged.length > SyncPeer.max_pending_subs)
        {
            enc.encode_err(from, seq, "busy", "too many model subs in flight");
            return;
        }

        foreach (pat; to_arm[])
        {
            from._model_subs ~= pat.make_string();
            add_feed_listener();
        }

        if (staged.empty)
        {
            enc.encode_res(from, seq);
            return;
        }
        staged[staged.length - 1].res_seq = seq;
        foreach (ref req; staged[])
            from._pending_subs ~= req.move;
        pump_model_intro(from);
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
        {
            from._rescan_cursor = 0;
            rebuild_live_nodes(from);
        }
    }

    void inbound_type_format(SyncPeer from, uint ft, ref const WireFormat wf)
    {
        import urt.si.unit : ScaledUnit;
        import manager.sample : find_enum_info;

        if (ft in from._ft_recv)
        {
            log.warning("peer '", from.name[], "' re-interned ft ", ft);
            return;
        }

        // Every seen ft is interned or tombstoned before dependent adds arrive.
        FormatId reg = FormatId.invalid;
        scope(exit) from._ft_recv.insert(ft, reg);

        ValueType vt;
        const(char)[] user_name;
        if (!value_type_from_wire(wf.type, vt, user_name))
        {
            log.warning("type frame with unknown value type '", wf.type, "'");
            return;
        }
        const(SeriesKind)* kind = enum_from_key!SeriesKind(wf.series);
        if (!kind)
        {
            log.warning("type frame with unknown series kind '", wf.series, "'");
            return;
        }

        DataFormat f;
        if (vt == ValueType.user)
        {
            import urt.typereg : find_type_by_name, TypeDetails;

            if (wf.enum_name.length || wf.unit.length)
            {
                log.warning("user type frame carrying a unit or enum - malformed");
                return;
            }
            immutable(TypeDetails)* td = find_type_by_name(user_name);
            if (!td)
            {
                if (from.first_sighting(user_name))
                    log.warning("format cites user type '", user_name, "', which this node lacks");
                return;
            }
            if (td.variant is null || !td.text_round_trip)
            {
                if (from.first_sighting(user_name))
                    log.warning("format cites user type '", user_name, "', which cannot cross a text wire");
                return;
            }
            f = DataFormat(vt, *kind, td);
        }
        else if (wf.enum_name.length)
        {
            const(VoidEnumInfo)* ei = find_enum_info(wf.enum_name);
            if (!ei)
            {
                log.warning("format cites unknown enum '", wf.enum_name, "'");
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
                log.warning("format with unparsable unit '", wf.unit, "'");
                return;
            }
            f = DataFormat(vt, *kind, su);
        }
        else
            f = DataFormat(vt, *kind);
        f.count = wf.count;
        f.rate = wf.rate;
        if (!f.stride_fits)
        {
            log.warning("format record stride exceeds 255 bytes");
            return;
        }
        if (vt == ValueType.user && !f.is_scalar)
        {
            if (from.first_sighting(user_name))
                log.warning("format cites a wide or vector user type, which has no decode path");
            return;
        }

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
                    log.warning("format constraint value out of range for its own type");
            }
            take(wf.min, c.min, Constraint.Has.min);
            take(wf.max, c.max, Constraint.Has.max);
            take(wf.step, c.step, Constraint.Has.step);
            if (c.has)
                f.constraint = register_constraint(c);
        }

        reg = register_format(f);
    }

    void inbound_type_enum(SyncPeer from, const(char)[] name, ref Variant members)
    {
        import manager.sample : register_enum_info;

        if (!members.isObject)
        {
            log.warning("enum type frame without members");
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

    void inbound_model_add(SyncPeer from, SyncHandle handle, const(char)[] path, const(char)[] node_class, uint ft, const(char)[] access, Variant* v, ulong t_ms, ulong peer_id)
    {
        if (!from.adoptable(handle))
        {
            log.warning("add from '", from.name[], "' with unusable handle ", handle);
            return;
        }
        // Failed materialisation must still advance the announced handle high-water.
        from.adopt(handle, materialise_add(from, path, node_class, ft, access, v, t_ms, peer_id));
    }

    EID materialise_add(SyncPeer from, const(char)[] path, const(char)[] node_class, uint ft, const(char)[] access, Variant* v, ulong t_ms, ulong peer_id)
    {
        Address a = Address.parse(path);
        if (!a.valid || a.ns[] != "device")
        {
            log.warning("add with unsupported path '", path, "'");
            return EID.invalid;
        }
        const(char)[] rest = a.subject;
        const(char)[] dev_id = rest.split!'.';

        Device dev = find_or_create_device(dev_id, peer_id);
        if (!dev)
            return EID.invalid;

        if (node_class[] == "device")
            return EID(dev.cid);
        if (node_class[] != "element" || rest.empty)
        {
            log.warning("add with unsupported class '", node_class, "' at '", path, "'");
            return EID.invalid;
        }
        FormatId* pf = ft in from._ft_recv;
        if (!pf)
        {
            log.warning("add cites unknown ft ", ft);
            return EID.invalid;
        }
        if (!(*pf).valid)
        {
            log.debug_("add for declined ft ", ft, " at '", path, "'");
            return EID.invalid;
        }
        Element* e = dev.find_element(rest);
        if (e && e.format.valid)
        {
            if (e.format != *pf && !value_compatible(*format_info(*pf), *e.data_format))
            {
                log.warning("add for '", path, "' conflicts with the existing element's format - skipped");
                return EID.invalid;
            }
        }
        else
        {
            e = dev.find_or_create_element(rest, *pf);
            if (!e)
                return EID.invalid;
            if (e.data_format.kind == SeriesKind.point && !e.has_history)
            {
                // a mirror event log retains the same window the authority's default gives
                e.retention(256, 16_384);
                e.retention(3600.seconds);
            }
        }
        Access remote_access = Access.read;
        if (access.length)
        {
            if (const(Access)* acc = enum_from_key!Access(access))
                remote_access = *acc;
        }
        if (v && !v.isNull)
            merge_remote_value(e, *v, t_ms);
        EID eid = e.ensure_eid();
        from.attach_model_element(dev, e, remote_access);
        return eid;
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

        if (!has_local_writer(e))
        {
            enc.encode_err(from, seq, "not_authoritative", "no writable local provider");
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
        EID node = from.node_of(handle);
        Element* e = resolve_element(node);
        if (!e)
        {
            if (!from.handle_announced(handle))
                return false;
            log.debug_("val for dead handle ", handle);
            return true;
        }
        merge_remote_value(e, value, t_ms);
        return true;
    }

    void inbound_res(SyncPeer from, uint seq)
    {
        if (get_module!SyncPeeringModule.claim_response(from, seq, true, null, null))
            return;
        log.info("model burst complete from '", from.name[], "' seq=", seq);
    }

    void inbound_err(SyncPeer from, uint seq, const(char)[] code, const(char)[] text)
    {
        if (get_module!SyncPeeringModule.claim_response(from, seq, false, code, text))
            return;
        log.warning("err from '", from.name[], "' seq=", seq, " code=", code, ": ", text);
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
        log.info("inbound enum '", type_name, "' from '", from.name[], "' seq=", seq);
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
            log.warning("time_resp from non-authority '", from.name[], "'");
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
        log.info("clock synced from authority '", from.name[], "'");
    }

    void inbound_time_push(SyncPeer from, uint ver, long delta_ns)
    {
        if (!from._time_authority)
        {
            log.warning("time_push from non-authority '", from.name[], "'");
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
        each_running_peer((SyncPeer p) {
            if (!p._time_subordinate || p is _applying_push)
                return;
            encoder_for(p._encoder).encode_time_push(p, _timebase_version, delta_ns);
        });
    }

    void poll_time_authorities()
    {
        MonoTime now = getTime();
        each_running_peer((SyncPeer p) {
            if (!p._time_authority)
                return;
            if (p._time_seq != 0)
            {
                if (now - p._time_t1 > time_response_timeout)
                {
                    p._time_seq = 0;
                    p._next_time_poll = now + time_retry_interval;
                }
                return;
            }
            if (now >= p._next_time_poll)
                send_time_req(p);
        });
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
        each_running_peer((SyncPeer p) { encoder_for(p._encoder).encode_add_name(p, obj); });
    }

    void fan_out_state(BaseObject obj, StateSignal sig)
    {
        // Only online/offline go on the wire. destroyed is communicated via
        // unbind (see fan_out_unbind) - the binding ending is what a subscriber
        // cares about, regardless of whether the upstream destroyed the object
        // or the peer just stopped tracking it.
        assert(sig != StateSignal.destroyed, "fan_out_state: destroyed is not sent on the wire");
        each_running_peer((SyncPeer p) {
            foreach (bound; p._bound[])
            {
                if (bound is obj)
                {
                    encoder_for(p._encoder).encode_state(p, obj.id, sig);
                    break;
                }
            }
        });
    }

    // Emits unbind to every peer that has `obj` bound. `correlate` + `corr_seq`
    // let the originator of a destroy request receive the correlation ack on
    // their same unbind frame; all other peers get seq=0. `exclude` skips a
    // peer entirely - used when the authority already told us, so we don't
    // echo unbind back to them.
    void fan_out_unbind(BaseObject obj, SyncPeer correlate = null, uint corr_seq = 0, SyncPeer exclude = null)
    {
        each_running_peer((SyncPeer p) {
            if (p is exclude)
                return;
            bool has = false;
            foreach (bound; p._bound[])
                if (bound is obj) { has = true; break; }
            if (!has)
                return;
            uint s = (p is correlate) ? corr_seq : 0;
            unbind_from_peer(p, obj, s);
        });
    }

    // Fan a reset echo to every bound peer. Same correlate/exclude semantics
    // as echo_set.
    void echo_reset(BaseObject obj, size_t prop_index, const(char)[] prop_name, SyncPeer correlate, uint correlate_seq, SyncPeer exclude = null)
    {
        ulong mask = ulong(1) << prop_index;
        debug assert_reset_matches_init(obj, *obj.properties()[prop_index]);
        each_running_peer((SyncPeer p) {
            if (p is exclude)
                return;
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
        });
    }

    // Fan a set echo to every bound peer. `correlate` + `correlate_seq` go
    // to one peer for correlation; everyone else gets seq=0. `exclude` skips
    // a peer entirely - used on the hub-of-hubs path when the authority has
    // already told us and we must not echo back to them.
    void echo_set(BaseObject obj, size_t prop_index, SyncPeer correlate, uint correlate_seq, SyncPeer exclude = null)
    {
        ulong mask = ulong(1) << prop_index;
        each_running_peer((SyncPeer p) {
            if (p is exclude)
                return;
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
        });
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
        each_running_peer((SyncPeer p) {
            foreach (ref pat; p._subscriptions[])
            {
                if (pattern_matches(pat[], obj))
                {
                    bind_to_peer(p, obj);
                    break;
                }
            }
        });
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

    bool bind_to_peer(SyncPeer peer, BaseObject obj, uint seq = 0)
    {
        uint gen = peer.begin_burst();
        if (!peer.send_ok(gen))
            return false;   // condemned session; no bookkeeping may survive into its replacement

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
        {
            SyncEncoder enc = encoder_for(peer._encoder);
            // a sub can arrive before attach_peer's registry walk (ws clients speak at accept
            // time), so the first cite introduces; the walk skips handles that already exist
            if (peer.handle_of(obj) == SyncPeer.invalid_handle)
            {
                enc.encode_add_name(peer, obj);
                if (!peer.send_ok(gen))
                    return false;
            }
            enc.encode_bind(peer, obj, seq);
        }
        return peer.send_ok(gen);
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
        enc.encode_add(to, h, tconcat("device:", dev.id[]), "device", 0, null, dev.peer_id);
    }

    void send_element(SyncPeer to, SyncEncoder enc, Element* e, const(char)[] path, uint gen, bool include_value = true)
    {
        import urt.mem.temp : tconcat;
        import manager.sample : enum_info_name;

        if (!e.format.valid)
            return;
        const(DataFormat)* fmt = e.data_format;
        if (!wire_serialisable(*fmt))
        {
            log.debug_("skipping unserialisable element ", path);
            return;
        }
        EID node = e.ensure_eid();
        if (!node)
            return;
        Device device = g_app.devices.container(node.container);
        if (!device)
            return;
        SyncHandle h = to.handle_of(node);
        if (h != SyncPeer.invalid_handle)
        {
            if (include_value)
                enc.encode_val(to, h, e);
            return;
        }
        if (fmt.desc == DataFormat.Desc.enum_)
        {
            const(char)[] ename = enum_info_name(fmt.enum_info);
            if (!ename)
            {
                log.warning("element ", path, " cites an unregistered enum - skipped");
                return;
            }
            if (!to.enum_seen(fmt.enum_info))
            {
                enc.encode_type_enum(to, ename, fmt.enum_info);
                if (!to.send_ok(gen))
                    return;
            }
        }
        bool first;
        uint ft = to.ft_of(e.format, first);
        if (first)
        {
            enc.encode_type_format(to, ft, *fmt);
            if (!to.send_ok(gen))
                return;
        }
        h = to.introduce(node);
        enc.encode_add(to, h, tconcat("device:", path), "element", ft, e, device.peer_id, include_value);
    }

    void send_backfill(SyncPeer to, SyncEncoder enc, Element* e, ulong from_ms, ulong to_ms, uint gen)
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
        Cursor cursor = e.open_series_cursor(idx);
        scope (exit) e.close_series_cursor(cursor);
        SysTime to_t = to_ms ? from_unix_time_ns(to_ms * 1_000_000) : SysTime();
        for (;;)
        {
            RecordBlock blk = cursor.next(256);
            if (!blk.count)
                break;
            if (to_ms)
            {
                uint full = blk.count;
                while (blk.count && blk.time(blk.count - 1) > to_t)
                    --blk.count;
                if (blk.count)
                    enc.encode_val_block(to, h, blk);
                if (!to.send_ok(gen))
                    return;
                commit_backfill(to, e, blk);
                if (blk.count < full)
                    break;
            }
            else
            {
                enc.encode_val_block(to, h, blk);
                if (!to.send_ok(gen))
                    return;
                commit_backfill(to, e, blk);
            }
        }
    }

    void commit_backfill(SyncPeer to, Element* e, ref const RecordBlock blk)
    {
        if (ulong* live = e.ensure_eid().raw in to._live_nodes)
            *live = blk.first_index + blk.count;
    }

    void introduce_element(SyncPeer p, SyncEncoder enc, Element* e, const(char)[] path, uint gen, bool arm, ulong from_ms, ulong to_ms)
    {
        bool backfill = from_ms && e.has_history;
        send_element(p, enc, e, path, gen, !backfill);
        if (backfill && p.send_ok(gen))
            send_backfill(p, enc, e, from_ms, to_ms, gen);
        if (backfill && e.data_format.kind != SeriesKind.point && p.send_ok(gen))
        {
            SyncHandle h = p.handle_of(e.ensure_eid());
            if (h != SyncPeer.invalid_handle)
                enc.encode_val(p, h, e);
        }
        if (arm && e.data_format.kind == SeriesKind.point && p.send_ok(gen))
            mark_pending_val(p, e);
    }

    void mark_pending_val(SyncPeer p, Element* e)
    {
        EID node = e.ensure_eid();
        if (!node)
            return;
        foreach (n; p._pending_vals[])
            if (n == node)
                return;
        p._pending_vals ~= node;
    }

    void queue_live_intro(SyncPeer p, EID node)
    {
        if (p._pending_live.length >= SyncPeer.max_pending_live)
        {
            p._live_rescan = true;
            p._rescan_cursor = 0;
            return;
        }
        foreach (n; p._pending_live[])
            if (n == node)
                return;
        p._pending_live ~= node;
    }

    void pump_live_rescan(SyncPeer p)
    {
        if (!p._live_rescan || !p._pending_live.empty)
            return;
        while (p._rescan_cursor < p._model_subs.length)
        {
            if (p._pending_subs.length >= SyncPeer.max_pending_subs)
                return;
            Address a = Address.parse(p._model_subs[p._rescan_cursor][]);
            ++p._rescan_cursor;
            if (!a.valid || !wildcard_match(a.ns, "device"))
                continue;
            bool queued = false;
            foreach (ref req; p._pending_subs[])
            {
                if (req.pattern[] == a.subject)
                {
                    queued = true;
                    break;
                }
            }
            if (queued)
                continue;
            SyncPeer.PendingSub req;
            req.pattern = a.subject.make_string();
            req.arm = true;
            p._pending_subs ~= req.move;
        }
        p._rescan_cursor = 0;
        p._live_rescan = false;
    }

    bool authored_by(SyncPeer peer, Element* element)
    {
        EID eid = element.ensure_eid();
        Device device = g_app.devices.container(eid.container);
        if (!device)
            return false;
        foreach (entry; element.binding_entries)
        {
            if (entry == Element.binding_end)
                break;
            if (entry < Element.binding_destroyed)
            {
                ubyte index = Element.binding_index(entry);
                assert(index < device.bindings.length);
                if (device.binding_is_peer(index) && device.bindings[index] is peer)
                    return true;
            }
        }
        return false;
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
                if (!dev.cid || dev.private_)
                    continue;
                walk_elements(dev, a.subject, (Element* e, const(char)[] path) {
                    if (authored_by(from, e))
                        return;
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
        if (!dev.cid || dev.private_)
            return;

        char[256] buf = void;
        ptrdiff_t len = e.full_path(buf);
        if (len <= 0 || len > buf.length)
            return;
        const(char)[] path = buf[0 .. len];

        each_running_peer((SyncPeer p) {
            if (authored_by(p, e))
                return;
            foreach (ref pat; p._model_subs[])
            {
                Address a = Address.parse(pat[]);
                if (!a.valid || !wildcard_match(a.ns, "device") || !match_path(a.subject, path))
                    continue;
                track_live(p, e);
                if (EID node = e.ensure_eid())
                    queue_live_intro(p, node);
                break;
            }
        });
    }

    bool has_local_writer(Element* e)
    {
        EID eid = e.ensure_eid();
        Device device = g_app.devices.container(eid.container);
        if (!device)
            return false;
        foreach (entry; e.binding_entries)
        {
            if (entry == Element.binding_end)
                break;
            if (entry < Element.binding_destroyed)
            {
                ubyte index = Element.binding_index(entry);
                assert(index < device.bindings.length);
                if (!device.binding_is_peer(index) && (Element.binding_access(entry) & Access.write))
                    return true;
            }
        }
        return false;
    }

    void merge_remote_value(Element* e, ref Variant value, ulong t_ms)
    {
        import urt.time : from_unix_time_ns;

        if (t_ms > max_model_time_ms)
            return;
        SysTime timestamp = t_ms ? from_unix_time_ns(t_ms * 1_000_000) : getSysTime();
        SysTime current = e.record_update();
        if (!model_value_is_newer(current, t_ms, timestamp))
            return;

        e.value(value, timestamp);
    }

    Device find_or_create_device(const(char)[] id, ulong peer_id)
    {
        if (Device device = g_app.devices.find(id, peer_id))
            return device;
        Device dev = alloc!Device(id.make_string(), peer_id);
        g_app.devices.insert(dev);
        return dev;
    }

    uint alloc_seq()
    {
        uint s = ++next_seq;
        if (s == 0)
            s = ++next_seq;
        return s;
    }
}


package void collect_superseded(SyncPeer[] peers, SyncPeer from, ulong node_id, ref Array!SyncPeer superseded)
{
    foreach (p; peers)
        if (p !is from && p._remote_node_id == node_id && !p.disabled)
            superseded ~= p;
}


private:

enum max_model_time_ms = ulong.max / 1_000_000;

bool model_value_is_newer(SysTime current, ulong t_ms, SysTime timestamp) pure
{
    import urt.time : unix_time_ns;

    return current == SysTime() || (t_ms ? t_ms > unix_time_ns(current) / 1_000_000 : timestamp > current);
}

void sync_model_sub(Session session, SyncPeer peer, const(char)[] pattern, Nullable!bool once)
{
    SyncModule mod = get_module!SyncModule;
    const(char)[][1] patterns = [pattern];
    encoder_for(peer._encoder).encode_model_sub(peer, mod.alloc_seq(), patterns[], !once || once.value);
}

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


unittest
{
    import urt.mem;

    SyncPeer a = alloc!SyncPeer(CID(1));
    scope(exit) free(a);
    SyncPeer b = alloc!SyncPeer(CID(2));
    scope(exit) free(b);
    SyncPeer c = alloc!SyncPeer(CID(3));
    scope(exit) free(c);

    a._remote_node_id = 0xF993;
    b._remote_node_id = 0xF993;
    c._remote_node_id = 0;          // no hello identity (a browser): never reconciled

    SyncPeer[3] peers = [a, b, c];
    Array!SyncPeer superseded;

    // the announcing session is kept; its namesake goes
    collect_superseded(peers[], b, 0xF993, superseded);
    assert(superseded.length == 1 && superseded[0] is a);

    // a session already going down is not superseded again
    a.disabled(true);
    superseded.clear();
    collect_superseded(peers[], b, 0xF993, superseded);
    assert(superseded.length == 0);

    // an identity-less peer matches nothing, and node 0 supersedes nothing
    superseded.clear();
    collect_superseded(peers[], c, c._remote_node_id, superseded);
    assert(superseded.length == 0);

    SysTime current = from_unix_time_ns(1_999_999);
    assert(!model_value_is_newer(current, 1, from_unix_time_ns(1_000_000)));
    assert(model_value_is_newer(current, 2, from_unix_time_ns(2_000_000)));
    assert(!model_value_is_newer(current, 0, current));
    assert(model_value_is_newer(current, 0, current + nsecs(1_000)));
}
