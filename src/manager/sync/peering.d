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

import router.iface.ethernet : EthernetStation;
import router.iface.mac : MACAddress;
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
        g_app.console.register_command!peering_reset("/sync/peering", this, "reset");
        load_allegiance();
    }

    override void update()
    {
        if (!_enabled || _role != PeerRole.authority)
            return;

        MonoTime now = getTime();
        foreach (kvp; _attempts[])
        {
            ref a = kvp.value;
            if (a.peer && !a.sent && a.peer.running)
                try_send_claim(a, now);
            if (a.expired(now))
            {
                log.warning("claim of node ", hex_id(kvp.key)[], a.sent ? " went unanswered" : " stalled in setup");
                fail_attempt(kvp.key, a);
            }
        }

        if (now < _next_sweep)
            return;
        _next_sweep = now + sweep_interval;

        foreach (kvp; get_module!SyncDiscoveryModule.neighbors[])
        {
            ref n = kvp.value;
            // a claimed member is NOT skipped: same-cluster members accept every authority's
            // session (the dual-authority seat), and a restarted authority re-claims through
            // the member's still-claimed announce; a foreign claim is refused at the member
            if (n.role != PeerRole.member)
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
            // a factory-fresh beacon voids link demotion: the node was reset since we
            // failed to prove the key, and is adoptable right now
            if (a && !n.adopted && !a.handover)
                n.clear_link_demotion();

            NeighborLink* link = n.best_link(now);
            if (!link)
                continue;
            start_claim(kvp.key, n, *link);
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

        // config cannot walk a node out of a fleet: allegiance outlives it, so a contradicting
        // cluster= would leave every claim refused as "wrong fleet" with no visible cause
        if (cluster && _allegiance_cluster.length && cluster.value[] != _allegiance_cluster[])
            session.write_line("note: node is adopted into fleet '", _allegiance_cluster[], "'; claims from '", cluster.value, "' stay refused until /sync/peering reset");

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
            if (_allegiance_cluster.length)
                session.write_line("fleet:    ", _allegiance_cluster[], " (adopted; /sync/peering reset returns to factory)");
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

    // The cluster this node is bound to: config wins, then persisted fleet allegiance,
    // then a cluster adopted for this session by the first claimant.
    const(char)[] bound_cluster() const pure
        => _cluster.length ? _cluster[] : _allegiance_cluster.length ? _allegiance_cluster[] : _adopted_cluster[];

    // A claim arrived on the sync channel; accept binds this member to the
    // claimant's cluster. Multiple claimants from one cluster are the
    // dual-authority shape; a second cluster is refused.
    void handle_claim(SyncPeer from, uint seq, const(char)[] cluster, uint priority, const(char)[] auth, const(char)[] key)
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
            char[64] expected = void;
            if (!claim_auth(from.local_nonce(), cluster, expected) || !hmac_equal(auth, expected))
            {
                log.warning("claim from '", from.name[], "' refused: bad auth");
                enc.encode_err(from, seq, "access_denied", "bad auth");
                return;
            }
        }
        if (_cluster.length && cluster[] != _cluster[])
        {
            enc.encode_err(from, seq, "access_denied", "wrong cluster");
            return;
        }
        if (_allegiance_cluster.length && cluster[] != _allegiance_cluster[])
        {
            enc.encode_err(from, seq, "access_denied", "wrong fleet");
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

        if (!_secret.length && key.length)
        {
            // the TOFU handover: a factory node adopts the fleet that claims it, key and
            // all, and holds that allegiance across reboots until factory reset
            _secret = key.makeString(defaultAllocator());
            _allegiance_cluster = cluster.makeString(defaultAllocator());
            save_allegiance();
            log.notice("adopted into fleet '", cluster, "' by node ", hex_id(from._remote_node_id)[], "; allegiance persisted (/sync/peering reset returns to factory)");
        }
        else if (!bound_cluster.length && !claimed)
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

    // Factory reset of fleet state: allegiance, key, session claims. The node beacons
    // unbound-and-unadopted again, so a sweeping authority may immediately re-adopt it;
    // reset before moving the hardware, or disable its old authority's claim filter.
    void peering_reset(Session session)
    {
        import urt.file : delete_file;

        delete_file(fleet_id_path);
        _secret = String();
        _allegiance_cluster = String();
        _adopted_cluster = String();
        release_claimants();
        apply_announce_state();
        log.notice("fleet allegiance cleared; node is back to factory");
        session.write_line("fleet allegiance cleared; node is back to factory (unbound)");
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
                if (NeighborLink* l = attempt_link(kvp.key, a))
                {
                    l.failures = 0;
                    l.retry_at = MonoTime();
                }
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
                fail_attempt(kvp.key, a);
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
    String _adopted_cluster;      // session-adopted (bench, keyless); dies with the last claimant
    String _allegiance_cluster;   // persisted fleet allegiance; dies at factory reset

private:
    enum sweep_interval = 5.seconds;
    enum claim_timeout = 10.seconds;
    enum beacon_grace = 5.seconds;
    enum fleet_id_path = "conf/fleet.id";

    struct ClaimAttempt
    {
        SyncPeer peer;
        UDPInterface iface;
        ObjectRef!EthernetStation link_station;  // the link this attempt went through; demoted on failure
        MACAddress link_mac;
        uint seq;
        bool sent;
        bool claimed;
        bool handover;   // target beacons un-adopted: the claim carries the fleet key
        MonoTime deadline;
        MonoTime claimed_at;

        bool expired(MonoTime now) const pure nothrow @nogc
            => peer !is null && !claimed && now >= deadline;
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

    // claim auth: hex(HMAC-SHA256(secret, member_nonce || cluster)). the nonce is fresh per
    // session, so a captured claim cannot replay; the secret never travels.
    bool claim_auth(const(ubyte)[] nonce, const(char)[] cluster, ref char[64] hex_out)
    {
        import urt.digest.hmac : hmac_init, hmac_update, hmac_finalise, HMACContext;
        import urt.digest.sha : SHA256Context;
        import urt.encoding : hex_encode;

        if (nonce.length != 16)
            return false;
        HMACContext!SHA256Context h;
        hmac_init(h, cast(const(ubyte)[])_secret[]);
        hmac_update(h, nonce);
        hmac_update(h, cluster);
        ubyte[32] mac = hmac_finalise(h);
        hex_encode(mac[], hex_out[]);
        return true;
    }

    static bool hmac_equal(const(char)[] a, const(char)[] b)
    {
        if (a.length != b.length)
            return false;
        ubyte diff = 0;
        foreach (i; 0 .. a.length)
            diff |= a[i] ^ b[i];
        return diff == 0;
    }

    // Fleet allegiance: {cluster, key} in conf/fleet.id beside node.id -- the piece of
    // peering state that persists outside startup.conf. Members write it at adoption;
    // an authority writes it when it mints the fleet key at first adoption.
    // TODO: micros without a filesystem need an NVS backing for this and node.id.

    void mint_fleet_key()
    {
        import urt.crypto.random : crypto_random_bytes;
        import urt.encoding : hex_encode;

        ubyte[32] key = void;
        crypto_random_bytes(key);
        char[64] hex = void;
        hex_encode(key[], hex[]);
        _secret = hex[].makeString(defaultAllocator());
        save_allegiance();
        log.notice("minted the fleet key for cluster '", _cluster, "'");
    }

    void load_allegiance()
    {
        import urt.file : load_file;

        char[] stored = cast(char[])load_file(fleet_id_path);
        if (!stored)
            return;
        scope(exit) defaultAllocator().free(stored);

        const(char)[] s = stored;
        const(char)[] cluster = s.split!'\n';
        const(char)[] key = s.split!'\n';
        if (!key.length)
            return;
        _secret = key.makeString(defaultAllocator());
        _allegiance_cluster = cluster.makeString(defaultAllocator());
        apply_announce_state();
    }

    void save_allegiance()
    {
        import urt.file : save_file;

        const(char)[] cluster = _allegiance_cluster.length ? _allegiance_cluster[] : _cluster[];
        char[512] buf = void;
        size_t len = cluster.length + _secret.length + 2;
        if (len > buf.length)
            return;
        buf[0 .. cluster.length] = cluster[];
        buf[cluster.length] = '\n';
        buf[cluster.length + 1 .. len - 1] = _secret[];
        buf[len - 1] = '\n';
        if (save_file(fleet_id_path, buf[0 .. len]).failed)
            log.warning("couldn't persist fleet allegiance to ", fleet_id_path, "; adoption is ephemeral this boot");
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
        disco.local_cluster = _cluster.length ? _cluster : _allegiance_cluster.length ? _allegiance_cluster : _adopted_cluster;
        disco.local_claimed = claimed;
        disco.local_adopted = _secret.length != 0;
        disco.local_sync_port = (_enabled && _role == PeerRole.member) ? _port : 0;
    }

    void start_claim(ulong node_id, ref const Neighbor n, ref NeighborLink link)
    {
        char[16] id = hex_id(node_id);

        UDPInterface iface = Collection!UDPInterface().create(tconcat("claim-", id[]), ObjectFlags.dynamic);
        if (!iface)
        {
            log.warning("failed to create claim transport for node ", id[]);
            return;
        }
        iface.iface(link.station.get);
        iface.remote_host(tconcat(link.mac).makeString(defaultAllocator()));
        iface.remote_port(link.sync_port);

        // adopting a factory node hands the fleet key over inside the claim; mint one
        // the first time this fleet adopts anything
        bool handover = !n.adopted;
        if (handover && !_secret.length)
            mint_fleet_key();

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
        a.link_station = link.station;
        a.link_mac = link.mac;
        a.sent = false;
        a.claimed = false;
        a.handover = handover;
        // the setup window: transport up, hellos exchanged, claim away; expiry fails the link
        a.deadline = getTime() + claim_timeout;

        log.info("claiming node ", id[], " ('", n.name, "') at ", link.mac, ":", link.sync_port, " via ", link.station.name[], handover ? " (adoption)" : "");
    }

    // claim once the session is up; hello (with our identity) precedes it on the wire.
    // with a secret, the claim proves it against the member's hello nonce, so the send
    // also waits for the member's hello to arrive.
    void try_send_claim(ref ClaimAttempt a, MonoTime now)
    {
        char[64] auth = void;
        bool have_auth = false;
        if (_secret.length)
        {
            if (!a.peer._remote_nonce_set)
                return;
            have_auth = claim_auth(a.peer._remote_nonce[], _cluster[], auth);
        }
        a.seq = get_module!SyncModule.alloc_seq();
        a.sent = true;
        a.deadline = now + claim_timeout;
        encoder_for(a.peer._encoder).encode_claim(a.peer, a.seq, _cluster[], _priority, have_auth ? auth[] : null, a.handover ? _secret[] : null);
    }

    void claim_peer_state(ActiveObject obj, StateSignal sig)
    {
        if (sig != StateSignal.offline)
            return;
        foreach (kvp; _attempts[])
        {
            ref a = kvp.value;
            if (a.peer is obj && a.claimed)
            {
                log.info("session to node ", hex_id(kvp.key)[], " died");
                fail_attempt(kvp.key, a);
                return;
            }
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

    // the link the attempt went through, if the neighbour still lists it
    NeighborLink* attempt_link(ulong node_id, ref const ClaimAttempt a)
    {
        Neighbor* n = node_id in get_module!SyncDiscoveryModule.neighbors;
        if (!n)
            return null;
        foreach (ref l; n.links[])
        {
            if (l.is_link(a.link_station, a.link_mac))
                return &l;
        }
        return null;
    }

    void fail_attempt(ulong node_id, ref ClaimAttempt a)
    {
        import urt.util : min;

        teardown_attempt(a);
        if (NeighborLink* l = attempt_link(node_id, a))
        {
            if (l.failures < 8)
                ++l.failures;
            l.retry_at = getTime() + seconds(min(30 << (l.failures - 1), 600));
        }
    }
}


unittest
{
    import urt.mem.allocator : defaultAllocator;

    // the setup deadline expires attempts that never sent, not just unanswered claims
    SyncPeeringModule.ClaimAttempt a;
    MonoTime t0 = MonoTime() + 100.seconds;
    a.deadline = t0 + 10.seconds;
    assert(!a.expired(t0 + 11.seconds));    // no peer: nothing to expire

    a.peer = defaultAllocator().allocT!SyncPeer(CID(1));
    scope(exit) defaultAllocator().freeT(a.peer);
    assert(!a.expired(t0));
    assert(a.expired(t0 + 11.seconds));     // unsent and stale: a dead link during setup fails over

    a.sent = true;
    assert(a.expired(t0 + 11.seconds));     // sent and unanswered: same path

    a.claimed = true;
    assert(!a.expired(t0 + 11.seconds));    // a live claim never expires here
}
