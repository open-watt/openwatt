module manager.sync.peering;

// The peering agent (docs/PEERING.draft.md): node-global auto-peering policy.
//
// role=member advertises this node as claimable, listens on the sync port (a dynamic
// /sync/udp-server), and accepts claims arriving on the sync channel. A member accepts
// multiple claimants from one cluster - that is the dual-authority shape - and reverts
// to unbound when the last session dies.
//
// role=authority sweeps the neighbour table for unbound members matching the claim
// filter, builds a transport to each (a dynamic connected UDPInterface toward the
// neighbour's medium address and announced sync port), spawns a dynamic SyncPeer named
// after the remote node, and sends the claim once the session is up. Rejected or
// unanswered claims tear the pair down and back off per candidate.

import urt.array;
import urt.conv : format_uint;
import urt.inet;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.mem.temp : tconcat;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;
import manager.sync : SyncModule;
import manager.sync.discovery;
import manager.sync.encoder : encoder_for, SyncEncoderKind;
import manager.sync.peer : SyncPeer;
import manager.sync.udp_server : UDPSyncServer;

import router.iface.udp : UDPInterface;

nothrow @nogc:


alias log = Log!"peering";

enum ushort default_sync_port = 7000;


class SyncPeeringModule : Module
{
    mixin DeclareModule!"sync.peering";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!PeerRole();
        g_app.console.register_command!peering_set("/sync/peering", this, "set");
        g_app.console.register_command!peering_print("/sync/peering", this, "print");
    }

    override void update()
    {
        if (!_enabled || _role != PeerRole.authority)
            return;

        MonoTime now = getTime();
        foreach (kvp; _attempts[])
        {
            ref a = kvp.value;
            if (a.peer && a.sent && !a.claimed && now >= a.deadline)
            {
                log.warning("claim of node ", hex_id(kvp.key)[], " went unanswered");
                fail_attempt(a);
            }
        }

        if (now < _next_sweep)
            return;
        _next_sweep = now + sweep_interval;

        foreach (kvp; get_module!SyncDiscoveryModule.neighbors[])
        {
            ref const n = kvp.value;
            // a claimed member is NOT skipped: same-cluster members accept every authority's
            // session (the dual-authority seat), and a restarted authority re-claims through
            // the member's still-claimed announce; a foreign claim is refused at the member
            if (n.role != PeerRole.member || !n.sync_port)
                continue;
            if (n.cluster.length && n.cluster[] != _cluster[])
                continue;
            if (!wildcard_match(_claim.length ? _claim[] : "*", n.name[]))
                continue;

            ClaimAttempt* a = kvp.key in _attempts;
            if (a && a.peer)
            {
                // the member rebooted out from under a session the datagram link can't
                // pronounce dead: it beacons unbound after our claim settled. the grace
                // covers a pre-claim beacon still in flight.
                if (a.claimed && !n.claimed && n.last_seen > a.claimed_at + beacon_grace)
                    teardown_attempt(*a);
                else
                    continue;
            }
            if (a && now < a.retry_at)
                continue;

            start_claim(kvp.key, n);
        }
    }

    void peering_set(Session session, Nullable!bool enabled, Nullable!PeerRole role, Nullable!(const(char)[]) cluster, Nullable!uint priority, Nullable!(const(char)[]) claim, Nullable!(const(char)[]) secret, Nullable!ushort port)
    {
        bool cluster_conflict = claimed && cluster && cluster.value[] != bound_cluster[];

        if (enabled)
            _enabled = enabled.value;
        if (role)
        {
            _role = role.value;
            if (!enabled)
                _enabled = true;    // setting a role is the opt-in
        }
        if (cluster)
            _cluster = cluster.value.makeString(defaultAllocator());
        if (priority)
            _priority = priority.value;
        if (claim)
            _claim = claim.value.makeString(defaultAllocator());
        if (secret)
            _secret = secret.value.makeString(defaultAllocator());
        if (port)
            _port = port.value;

        // config is intent; live claims that contradict it are released rather than
        // silently retained (which would admit claimants from two clusters at once)
        if (claimed && (cluster_conflict || !_enabled || _role != PeerRole.member))
        {
            session.write_line("note: released ", _claimants.length, " live claim(s)");
            log.warning("reconfigured while claimed; releasing ", _claimants.length, " claimant(s)");
            release_claimants();
            _adopted_cluster = String();
        }

        if (_role == PeerRole.member && _claim.length)
            session.write_line("note: claim filter is ignored for role=member");

        apply_peering_state();
    }

    void peering_print(Session session)
    {
        session.write_line("enabled:  ", _enabled ? "yes" : "no");
        session.write_line("role:     ", role_name(_role));
        if (_cluster.length)
            session.write_line("cluster:  ", _cluster[]);
        if (_role == PeerRole.authority)
        {
            session.write_line("priority: ", _priority);
            session.write_line("claim:    ", _claim.length ? _claim[] : "*");
            foreach (kvp; _attempts[])
            {
                ref const a = kvp.value;
                if (a.peer)
                    session.write_line("claim:    ", hex_id(kvp.key)[], " (", a.peer.name[], ") ", a.claimed ? "claimed" : "pending");
            }
        }
        if (_role == PeerRole.member)
        {
            session.write_line("port:     ", _port);
            session.write_line("state:    ", claimed ? "claimed" : "unbound");
            foreach (ref c; _claimants[])
                session.write_line("claimant: ", hex_id(c.node_id)[], " (", c.peer.name[], ") cluster=", bound_cluster[], " priority=", c.priority);
        }

        if (!_enabled)
            return;

        size_t members, unbound, authorities;
        foreach (kvp; get_module!SyncDiscoveryModule.neighbors[])
        {
            ref n = kvp.value;
            if (n.role == PeerRole.authority)
                ++authorities;
            else if (n.role == PeerRole.member)
            {
                ++members;
                if (!n.claimed)
                    ++unbound;
            }
        }
        session.write_line("neighbours: ", members, " members (", unbound, " unbound), ", authorities, " authorities");
    }

    bool claimed() const pure
        => _claimants.length > 0;

    // The cluster this node is bound to: config wins, else adopted from the first claimant.
    const(char)[] bound_cluster() const pure
        => _cluster.length ? _cluster[] : _adopted_cluster[];

    // A claim arrived on the sync channel; accept binds this member to the
    // claimant's cluster. Multiple claimants from one cluster are the
    // dual-authority shape; a second cluster is refused.
    void handle_claim(SyncPeer from, uint seq, const(char)[] cluster, uint priority, const(char)[] auth)
    {
        auto enc = encoder_for(from._encoder);

        if (!_enabled || _role != PeerRole.member)
        {
            enc.encode_err(from, seq, "access_denied", "not a claimable member");
            return;
        }
        if (!from._remote_node_id)
        {
            log.warning("claim from '", from.name[], "' without hello identity; refused");
            enc.encode_err(from, seq, "access_denied", "no identity");
            return;
        }
        if (from._remote_role != PeerRole.authority)
        {
            log.warning("claim from '", from.name[], "' which did not announce as an authority; refused");
            enc.encode_err(from, seq, "access_denied", "not an authority");
            return;
        }
        if (_secret.length)
        {
            // HMAC challenge not built yet; a configured secret refuses all claims rather than admit unauthenticated ones
            log.warning("claim from '", from.name[], "' refused: secret is set and claim auth is not implemented");
            enc.encode_err(from, seq, "access_denied", "auth required");
            return;
        }
        if (_cluster.length && cluster[] != _cluster[])
        {
            enc.encode_err(from, seq, "access_denied", "wrong cluster");
            return;
        }
        if (claimed && cluster[] != bound_cluster[])
        {
            enc.encode_err(from, seq, "claimed", "bound to another cluster");
            return;
        }

        foreach (ref c; _claimants[])
        {
            if (c.peer is from)
            {
                c.priority = priority;  // re-claim on a live session refreshes the terms
                enc.encode_res(from, seq);
                return;
            }
        }

        if (!_cluster.length && !claimed)
        {
            _adopted_cluster = cluster.makeString(defaultAllocator());
            log.warning("claimed into cluster '", cluster, "' by '", from.name[],
                        "' with no local cluster configured; set cluster= to pin this node");
        }

        _claimants ~= Claimant(from._remote_node_id, from, priority);

        // subordination includes clock discipline: the first claimant becomes this node's
        // time authority. TODO: follow the elected-active authority once the election lands.
        if (_claimants.length == 1)
            from.grant_claim_time_authority();

        log.info("claimed by node ", hex_id(from._remote_node_id)[], " ('", from.name[], "') cluster='", bound_cluster, "'");

        apply_announce_state();
        enc.encode_res(from, seq);
    }

    // Sync module calls this as a peer detaches; the claim dies with the session.
    void peer_detached(SyncPeer p)
    {
        foreach (i, ref c; _claimants[])
        {
            if (c.peer is p)
            {
                p.revoke_claim_time_authority();
                _claimants.remove(i);
                if (!claimed)
                {
                    _adopted_cluster = String();
                    log.info("last claimant detached; reverting to unbound");
                    apply_announce_state();
                }
                else
                    _claimants[0].peer.grant_claim_time_authority();
                return;
            }
        }
    }

    // res/err routing from the sync module: true when the seq belonged to a claim we sent.
    bool claim_response(SyncPeer from, uint seq, bool ok, const(char)[] code, const(char)[] text)
    {
        foreach (kvp; _attempts[])
        {
            ref a = kvp.value;
            if (a.peer !is from || !a.sent || a.seq != seq || a.claimed)
                continue;
            if (ok)
            {
                a.claimed = true;
                a.claimed_at = getTime();
                a.failures = 0;
                log.info("claimed node ", hex_id(kvp.key)[], " ('", from.name[], "')");

                // build the fleet surface: the member's whole device tree, armed live.
                // the model plane is self-describing (type/add frames), so subscribing IS
                // the enumeration, and elements appearing later stream in via the same sub.
                const(char)[][1] patterns = ["device:**"];
                encoder_for(from._encoder).encode_model_sub(from, get_module!SyncModule.alloc_seq(), patterns[], false);
            }
            else
            {
                log.warning("claim of node ", hex_id(kvp.key)[], " refused: ", code, " (", text, ")");
                fail_attempt(a);
            }
            return true;
        }
        return false;
    }

package:
    bool     _enabled;
    PeerRole _role;
    String   _cluster;
    uint     _priority = 100;
    String   _claim;
    String   _secret;
    ushort   _port = default_sync_port;

    struct Claimant
    {
        ulong node_id;
        SyncPeer peer;
        uint priority;
    }
    Array!Claimant _claimants;
    String _adopted_cluster;

private:
    enum sweep_interval = 5.seconds;
    enum claim_timeout = 10.seconds;
    enum beacon_grace = 5.seconds;

    struct ClaimAttempt
    {
        SyncPeer peer;
        UDPInterface iface;
        uint seq;
        bool sent;
        bool claimed;
        ubyte failures;
        MonoTime deadline;
        MonoTime retry_at;
        MonoTime claimed_at;
    }
    Map!(ulong, ClaimAttempt) _attempts;
    UDPSyncServer _listener;
    MonoTime _next_sweep;

    void release_claimants()
    {
        foreach (ref c; _claimants[])
            c.peer.revoke_claim_time_authority();
        _claimants.clear();
    }

    static char[16] hex_id(ulong node_id)
    {
        char[16] id = void;
        format_uint(node_id, id[], 16, 16, '0');
        return id;
    }

    void apply_peering_state()
    {
        apply_announce_state();

        // members listen for the claimants' sessions; the listener dies with the role
        bool want_listener = _enabled && _role == PeerRole.member;
        if (_listener && (!want_listener || _listener.port != _port))
        {
            _listener.destroy();
            _listener = null;
        }
        if (want_listener && !_listener)
        {
            _listener = Collection!UDPSyncServer().create("peering", ObjectFlags.dynamic);
            if (_listener)
            {
                // ether any-station: claims arrive over the OW ethertype from the segment
                _listener.local_host("00:00:00:00:00:00".makeString(defaultAllocator()));
                _listener.port(_port);
            }
            else
                log.error("failed to create peering sync listener");
        }

        if (!_enabled || _role != PeerRole.authority)
        {
            foreach (kvp; _attempts[])
                teardown_attempt(kvp.value);
            _attempts.clear();
        }
    }

    void apply_announce_state()
    {
        auto disco = get_module!SyncDiscoveryModule;
        disco.local_role = _enabled ? _role : PeerRole.none;
        disco.local_cluster = _cluster.length ? _cluster : _adopted_cluster;
        disco.local_claimed = claimed;
        disco.local_sync_port = (_enabled && _role == PeerRole.member) ? _port : 0;
    }

    void start_claim(ulong node_id, ref const Neighbor n)
    {
        char[16] id = hex_id(node_id);

        UDPInterface iface = Collection!UDPInterface().create(tconcat("claim-", id[]), ObjectFlags.dynamic);
        if (!iface)
        {
            log.warning("failed to create claim transport for node ", id[]);
            return;
        }
        iface.remote_host(tconcat(n.mac).makeString(defaultAllocator()));
        iface.remote_port(n.sync_port);

        // the peer takes the remote node's name (the per-VIN session precedent); a collision
        // with an existing peer (manual, or a stale attempt) falls back to the node id
        SyncPeer peer = Collection!SyncPeer().create(n.name[], ObjectFlags.dynamic);
        if (!peer)
            peer = Collection!SyncPeer().create(tconcat("claim-", id[]), ObjectFlags.dynamic);
        if (!peer)
        {
            log.warning("failed to create claim peer for node ", id[]);
            iface.destroy();
            return;
        }
        peer.transport(iface);
        peer.encoder(SyncEncoderKind.binary);
        peer.subscribe(&claim_peer_state);

        ClaimAttempt* a = node_id in _attempts;
        if (!a)
            a = _attempts.insert(node_id, ClaimAttempt());
        a.peer = peer;
        a.iface = iface;
        a.sent = false;
        a.claimed = false;

        log.info("claiming node ", id[], " ('", n.name, "') at ", n.mac, ":", n.sync_port);
    }

    // claim once the session is up; hello (with our identity) precedes it on the wire
    void claim_peer_state(ActiveObject obj, StateSignal sig)
    {
        foreach (kvp; _attempts[])
        {
            ref a = kvp.value;
            if (a.peer !is obj)
                continue;
            if (sig == StateSignal.online && !a.sent)
            {
                a.seq = get_module!SyncModule.alloc_seq();
                a.sent = true;
                a.deadline = getTime() + claim_timeout;
                encoder_for(a.peer._encoder).encode_claim(a.peer, a.seq, _cluster[], _priority, null);
            }
            else if (sig == StateSignal.offline && a.claimed)
            {
                log.info("session to node ", hex_id(kvp.key)[], " died");
                fail_attempt(a);
            }
            return;
        }
    }

    void teardown_attempt(ref ClaimAttempt a)
    {
        // transport dies first (the ws-server precedent): its offline signal reaches a
        // still-live peer, which handles it with a restart; a destroyed peer would assert
        if (a.peer)
            a.peer.unsubscribe(&claim_peer_state);
        if (a.iface)
        {
            a.iface.destroy();
            a.iface = null;
        }
        if (a.peer)
        {
            a.peer.destroy();
            a.peer = null;
        }
        a.sent = false;
        a.claimed = false;
    }

    void fail_attempt(ref ClaimAttempt a)
    {
        import urt.util : min;

        teardown_attempt(a);
        if (a.failures < 8)
            ++a.failures;
        a.retry_at = getTime() + seconds(min(30 << (a.failures - 1), 600));
    }
}
