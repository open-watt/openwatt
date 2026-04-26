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
//   - Rename propagation: on_object_rekeyed and fan_out_rekey are stubs. Need
//     a global register_object_rekeyed_handler (analogous to _created_handler)
//     before locally-authoritative renames can broadcast.
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
import urt.string;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.console.command : CommandState, CommandCompletionState;
import manager.console.session;
import manager.plugin;
import manager.sync.encoder;
import manager.sync.json_encoder;
import manager.sync.peer;
import manager.sync.ws_server;


nothrow @nogc:


alias log = Log!"sync";


// Subscription pattern forms:
//   "#<decimal>"          - exact CID match (decimal uint)
//   "$<hex>"              - exact CID match (hex uint, case-insensitive)
//   "[=]<type>:<name>"    - type/name match; both halves accept wildcards.
//                           Without '=' the type half matches any ancestor.
//     "modbus:goodwe_ems"  - any modbus (incl. subtypes) named goodwe_ems
//     "=modbus:goodwe_ems" - only objects whose concrete type is exactly "modbus"
//     "interface:*"        - everything derived from "interface"
//     "*:*"                - everything
bool pattern_matches(const(char)[] pattern, BaseObject obj) nothrow @nogc
{
    import urt.conv : parse_uint;
    import urt.string : wildcard_match;

    if (pattern.length == 0)
        return false;

    if (pattern[0] == '#' || pattern[0] == '$')
    {
        uint base = pattern[0] == '#' ? 10 : 16;
        const(char)[] digits = pattern[1 .. $];
        if (digits.length == 0)
            return false;
        size_t taken;
        ulong val = parse_uint(digits, &taken, base);
        if (taken != digits.length || val > uint.max)
            return false;
        return obj.id.raw == cast(uint)val;
    }

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


class SyncModule : Module
{
    mixin DeclareModule!"sync";
nothrow @nogc:

    Array!SyncPeer             peers;
    Map!(CID, SyncPeer)        authority;         // only remote auth; absence = local
    Map!(uint, PendingForward) pending_forwards;
    Array!PendingInboundCmd    pending_inbound_cmds;
    uint                       next_seq;

    override void init()
    {
        g_app.register_enum!SyncEncoderKind();

        g_json_encoder = defaultAllocator.allocT!JsonEncoder(this);
        g_encoders[SyncEncoderKind.json] = g_json_encoder;

        g_app.console.register_collection!SyncPeer();
        g_app.console.register_collection!WebSocketSyncServer();

        register_object_created_handler(&on_object_created);
        register_object_state_handler(&on_object_state);
    }

    override void update()
    {
        Collection!WebSocketSyncServer().update_all();
        Collection!SyncPeer().update_all();

        foreach (p; peers[])
            encoder_for(p._encoder).tick_dirty(p);

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
            enc.encode_add_name(p, obj.id, obj.name[]);
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

    void inbound_add_name(SyncPeer from, CID cid, const(char)[] name)
    {
        // Purely extends our id-table / cid→name resolution. No proxy yet -
        // the concrete type is only known when bind arrives, which is also
        // what materialises the proxy.
        uint type_idx = cid.type_index;
        CID local = item_table(type_idx).insert(name, cast(ubyte)type_idx, null);

        // If the receiver's rehash-on-collision landed on a different CID
        // than the sender, the two id-tables have diverged. Log for now;
        // a per-peer CID translation slot will handle it later.
        if (local != cid)
            log.warning("sync: add_name CID mismatch for '", name, "' - peer=",
                        cid.raw, " local=", local.raw);
    }

    void inbound_rekey(SyncPeer from, CID old_cid, CID new_cid)
    {
        BaseObject obj = get_item(old_cid);
        if (!obj)
        {
            log.warning("sync: rekey from '", from.name[], "' for unknown CID ", old_cid.raw);
            return;
        }
        if (!obj._is_remote)
        {
            log.warning("sync: rekey from '", from.name[], "' targeting our local authoritative '",
                        obj.name[], "' - ignoring");
            return;
        }

        const(char)[] new_name = get_id(new_cid)[];
        if (new_name.length == 0)
        {
            log.warning("sync: rekey to unknown CID ", new_cid.raw);
            return;
        }

        const(char)[] err = obj.name = new_name;
        if (err.length)
        {
            log.warning("sync: rekey CID ", old_cid.raw, " -> ", new_cid.raw, " failed: ", err);
            return;
        }

        // Follow the rename in the authority map. broadcast_rekey already fired
        // via the name setter so local ObjectRefs have been updated.
        authority.remove(old_cid);
        authority[obj.id] = from;
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
                // Origin likely doesn't yet know this CID - make sure they do.
                encoder_for(origin._encoder).encode_add_name(origin, target, proxy.name[]);
                bind_to_peer(origin, proxy, origin_seq);
            }
        }

        // Hub-of-hubs: tell our other subscribers about this newly-materialized
        // proxy. add_name first (they may not know the CID), then bind to any
        // whose subscription patterns match.
        foreach (p; peers[])
        {
            if (p is from)
                continue;
            encoder_for(p._encoder).encode_add_name(p, target, proxy.name[]);
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

    void inbound_enum_req(SyncPeer from, const(char)[] type_name, uint seq)
    {
        auto pe = type_name in g_app.enum_templates;
        if (!pe)
        {
            encoder_for(from._encoder).encode_error(from, seq, "unknown enum");
            return;
        }

        Variant members;
        const(VoidEnumInfo)* e = *pe;
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

    // Fan-out helpers (internal)

    void fan_out_add_name(BaseObject obj)
    {
        foreach (p; peers[])
            encoder_for(p._encoder).encode_add_name(p, obj.id, obj.name[]);
    }

    void fan_out_rekey(CID old_cid, CID new_cid)
    {
        // TODO: iterate peers bound to old_cid / new_cid and emit encode_rekey.
        // Deferred until rename propagation wires up (needs a global rekey hook).
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

    void on_object_created(BaseObject obj)
    {
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

    void on_object_rekeyed(BaseObject obj, CID old_cid, CID new_cid)
    {
        // TODO: if local authoritative rename, fan_out_rekey(old, new).
        // If proxy rename, update authority map keyed on the new CID.
        // Blocked on adding a global register_object_rekeyed_handler hook
        // (analogous to register_object_created_handler).
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
