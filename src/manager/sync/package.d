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
//   - Binary encoder not implemented (deferred to BL808 D0/M0 shmem work).
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
import urt.meta.enuminfo : VoidEnumInfo;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.variant;

import db;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.console.command : CommandState, CommandCompletionState;
import manager.console.session;
import manager.plugin;
import manager.features;
import manager.syslog;
import manager.system : hostname;
import manager.sync.encoder;
import manager.sync.json_encoder;
import manager.sync.peer;
static if (has_http)
    import manager.sync.ws_server;

nothrow @nogc:


// History responses must fit in one raw packet (64KB); JSON samples are ~25 bytes each.
enum uint max_history_points = 2000;

// Time-sync cadence for a remote pulling from its authority.
enum Duration time_poll_interval    = seconds(17 * 60);
enum Duration time_retry_interval   = seconds(30);
enum Duration time_response_timeout = seconds(4);


// Subscription pattern forms:
//   "[=]<type>:<name>"    - type/name match; both halves accept wildcards.
//                           Without '=' the type half matches any ancestor.
//     "modbus:goodwe_ems"  - any modbus (incl. subtypes) named goodwe_ems
//     "=modbus:goodwe_ems" - only objects whose concrete type is exactly "modbus"
//     "interface:*"        - everything derived from "interface"
//     "*:*"                - everything
bool pattern_matches(const(char)[] pattern, BaseObject obj) nothrow @nogc
{
    import urt.string : wildcard_match;

    if (pattern.length == 0)
        return false;

    bool strict = false;
    if (pattern[0] == '=')
    {
        strict = true;
        pattern = pattern[1 .. $];
    }

    ptrdiff_t colon = -1;
    foreach (i, c; pattern)
        if (c == ':')
        {
            colon = cast(ptrdiff_t)i;
            break;
        }
    if (colon < 0)
        return false;

    const(char)[] type_pat = pattern[0 .. colon];
    const(char)[] name_pat = pattern[colon + 1 .. $];

    if (!wildcard_match(name_pat, obj.name[]))
        return false;

    if (strict)
        return wildcard_match(type_pat, obj.type);

    for (const(CollectionTypeInfo)* ti = obj._typeInfo; ti !is null;
         ti = ti.get_super ? ti.get_super() : null)
    {
        if (wildcard_match(type_pat, ti.type[]))
            return true;
    }
    return false;
}


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

// Inbound history request awaiting the database's async answer.
struct PendingHistory
{
    SyncPeer     peer;
    uint         seq;
    String       path;
    uint         ticket;
    MonoTime     started;
    Array!Sample samples;
    bool         ready;

    this(this) @disable;
}


class SyncModule : Module
{
    mixin DeclareModule!"sync";
nothrow @nogc:

    Array!SyncPeer             peers;
    Map!(CID, SyncPeer)        authority;         // only remote auth; absence = local
    Map!(uint, PendingForward) pending_forwards;
    Array!PendingInboundCmd    pending_inbound_cmds;
    Array!PendingHistory       pending_history;
    uint                       next_seq;
    uint                       _timebase_version;  // our version as a clock authority
    SyncPeer                   _applying_push;     // peer whose delta push we're applying

    override void init()
    {
        g_app.register_enum!SyncEncoderKind();

        g_json_encoder = defaultAllocator.allocT!JsonEncoder(this);
        g_encoders[SyncEncoderKind.json] = g_json_encoder;

        g_app.console.register_collection!SyncPeer();
        static if (has_http)
            g_app.console.register_collection!WebSocketSyncServer();

        g_app.console.register_command!sync_log_sub("/sync", this, "log-sub");

        set_log_hostname(hostname[]);

        register_object_lifecycle_handler(&on_object_lifecycle);
        register_object_state_handler(&on_object_state);
        subscribe_clock_change(&on_clock_step);
    }

    override void deinit()
    {
        unsubscribe_clock_change(&on_clock_step);
    }

    override void update()
    {
        static if (has_http)
            Collection!WebSocketSyncServer().update_all();
        Collection!SyncPeer().update_all();

        foreach (p; peers[])
        {
            encoder_for(p._encoder).tick_dirty(p);
            p.flush_logs();
        }

        poll_time_authorities();

        // Drain completed inbound commands and emit their results back.
        for (size_t i = 0; i < pending_inbound_cmds.length; )
        {
            ref PendingInboundCmd req = pending_inbound_cmds[i];
            if (req.command.update() == CommandCompletionState.in_progress)
            {
                ++i;
                continue;
            }
            encoder_for(req.peer._encoder)
                .encode_result(req.peer, req.seq, req.command.result, req.session.takeOutput()[]);
            g_app.console.destroy_session(req.session);
            pending_inbound_cmds.remove(i);
        }

        // Drain completed inbound history requests answered by the database.
        import urt.time : getTime, seconds;
        for (size_t i = 0; i < pending_history.length; )
        {
            ref PendingHistory h = pending_history[i];

            bool alive = false;
            foreach (p; peers[])
                if (p is h.peer)
                {
                    alive = true;
                    break;
                }

            if (alive && !h.ready && getTime() - h.started <= 5.seconds)
            {
                ++i;
                continue;
            }
            if (alive && h.ready)
                encoder_for(h.peer._encoder).encode_history(h.peer, h.seq, h.path[], h.samples[]);
            else
                database().cancel(h.ticket); // peer gone or timed out: drop the query
            pending_history.remove(i);
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

    void detach_peer(SyncPeer p)
    {
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

        // Drop pending forwards where this peer was the origin; we can't route
        // a response back to a gone peer.
        Array!uint doomed;
        foreach (kvp; pending_forwards[])
            if (kvp.value.origin is p)
                doomed ~= kvp.key;
        foreach (k; doomed[])
            pending_forwards.remove(k);

        // Drop in-flight inbound commands from this peer - no one to reply to.
        for (size_t i = 0; i < pending_inbound_cmds.length; )
        {
            if (pending_inbound_cmds[i].peer is p)
            {
                g_app.console.destroy_session(pending_inbound_cmds[i].session);
                pending_inbound_cmds.remove(i);
            }
            else
                ++i;
        }

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

    void inbound_add_name(SyncPeer from, uint handle, const(char)[] name, const(char)[] type)
    {
        // Reserves local identity for the peer's announced name and binds their
        // session handle to it. No proxy yet - bind is what materialises one.
        auto rt = type in g_app.types;
        if (!rt)
        {
            log.warning("sync: add_name from '", from.name[], "' with unknown type '", type, "'");
            return;
        }
        ubyte type_idx = cast(ubyte)rt.type_info.collection_id;
        CID local = item_table(type_idx).reserve(name, type_idx);
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
                log.warning("sync: bind from '", from.name[], "' for unknown type '", type,
                            "' - cannot materialize proxy for CID ", target.raw);
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
                log.warning("sync: bind from '", from.name[], "' for CID ",
                            target.raw, " with no prior add_name");
                return;
            }

            BaseCollection coll = BaseCollection(ti);
            proxy = coll.alloc(name, ObjectFlags.remote);
            if (!proxy)
            {
                log.warning("sync: bind from '", from.name[], "' - alloc failed for '",
                            name, "' (", type, ")");
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
                log.warning("sync: bind re-announce for '", proxy.name[],
                            "' from a different peer than current authority");
        }
        else
        {
            // Bind targeting a local authoritative object - protocol violation.
            log.warning("sync: bind from '", from.name[], "' targeting our local '",
                        proxy.name[], "' - ignoring");
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
        // Re-inject into local logging. Split-horizon: mark the arrival peer so
        // the fan-out's tap back toward `from` skips it. Keying on `from` (not
        // msg.hostname) is what makes relays correct - msg.hostname is the
        // original emitter, possibly several hops upstream of `from`.
        g_log_reinject_source = from;
        write_log(msg);
        g_log_reinject_source = null;
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

        // typed series answer synchronously from RAM buckets + owsig container; the db
        // serves legacy ring-fed streams
        Array!Sample local;
        if (query_local(*rs, from_ms * 1_000_000, to_ms * 1_000_000, max_points, QueryMode.raw, local))
        {
            encoder_for(from._encoder).encode_history(from, seq, path, local[]);
            return;
        }

        uint ticket = database().query(rs.series, from_ms * 1_000_000, to_ms * 1_000_000, max_points, QueryMode.raw, &on_history_result);
        if (!ticket)
        {
            encoder_for(from._encoder).encode_error(from, seq, "history unavailable");
            return;
        }

        import urt.time : getTime;
        pending_history ~= PendingHistory(from, seq, path.makeString(defaultAllocator()), ticket, getTime());
    }

    void on_history_result(uint ticket, scope const(Sample)[] samples)
    {
        foreach (ref h; pending_history[])
        {
            if (h.ticket != ticket)
                continue;
            h.samples.clear();
            if (samples.length)
            {
                h.samples.resize(samples.length);
                h.samples[][] = samples[];
            }
            h.ready = true;
            break;
        }
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
    void fan_out_unbind(BaseObject obj, SyncPeer correlate = null, uint corr_seq = 0,
                        SyncPeer exclude = null)
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
    void echo_reset(BaseObject obj, size_t prop_index, const(char)[] prop_name,
                    SyncPeer correlate, uint correlate_seq,
                    SyncPeer exclude = null)
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
    void echo_set(BaseObject obj, size_t prop_index,
                  SyncPeer correlate, uint correlate_seq,
                  SyncPeer exclude = null)
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

    // Helpers

    uint alloc_seq()
    {
        uint s = ++next_seq;
        if (s == 0) s = ++next_seq;  // skip reserved zero on wrap
        return s;
    }
}


private:

package __gshared SyncPeer g_log_reinject_source;

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
