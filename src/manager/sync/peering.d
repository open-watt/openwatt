module manager.sync.peering;

// The peering agent (docs/PEERING.draft.md): node-global auto-peering policy.
//
// The leaf dials. role=member sweeps the neighbour table for authorities of its fleet
// and opens a session to each (a connected UDP endpoint toward the neighbour's medium
// address and announced sync port, owned by a dynamic SyncPeer), then accepts the
// claims that arrive on those sessions. A member accepts multiple claimants from one
// cluster - that is the dual-authority shape - and reverts to unbound when the last
// session dies. Failed dials back off per link.
//
// role=authority listens on the sync port (a dynamic /sync/udp-server on the ether
// wildcard) and claims the members that reach it and match the claim filter. It keeps
// no dial state: a member that cannot be reached is the member's problem to retry, and
// a node with no inbound surface - behind a NAT, or simply not listening - still joins.
// Policy direction and transport direction are separate: the authority still decides
// who joins its fleet, it just answers rather than dials.

import urt.array;
import urt.conv : format_uint;
import urt.inet;
import urt.log;
import urt.map;
import urt.mem;
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

import router.iface.endpoint : UDPEndpoint, udp_open;
import router.iface.ethernet : EthernetStation;
import router.iface.mac : MACAddress;

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
        g_app.console.register_command!(peering_set, "set")("/sync/peering", this);
        g_app.console.register_command!(peering_print, "print")("/sync/peering", this);
        g_app.console.register_command!(peering_reset, "reset")("/sync/peering", this);
        load_allegiance();
    }

    override void update()
    {
        if (!_enabled)
            return;

        MonoTime now = getTime();

        // The leaf dials. A member with no inbound surface - behind a NAT, or simply not
        // listening - still reaches its fleet, and the authority keeps no per-candidate
        // dial state for nodes that may never answer.
        if (_role == PeerRole.member)
        {
            foreach (kvp; _attempts[])
            {
                ref a = kvp.value;
                if (a.dead)
                {
                    log.info("session to node ", hex_id(kvp.key)[], " died");
                    fail_attempt(kvp.key, a);
                    continue;
                }
                if (a.peer && !a.claimed && a.peer.running)
                {
                    a.claimed = true;   // session established; a claim, if any, arrives on it
                    a.claimed_at = now;
                    if (NeighborLink* l = attempt_link(kvp.key, a))
                    {
                        l.failures = 0;
                        l.retry_at = MonoTime();
                    }
                }
                if (a.expired(now))
                {
                    log.warning("session to authority ", hex_id(kvp.key)[], " stalled in setup");
                    fail_attempt(kvp.key, a);
                }
            }

            if (now < _next_sweep)
                return;
            _next_sweep = now + sweep_interval;
            sweep_authorities(now);
            return;
        }

        if (_role != PeerRole.authority)
            return;

        // claims ride the sessions members open to us; nothing to dial, nothing to back off
        prune_issued();
        if (now < _next_sweep)
            return;
        _next_sweep = now + sweep_interval;
        claim_inbound(now);
    }

    // Every authority this node can see and is allowed to join. An adopted member talks
    // only to its own fleet; a factory node talks to whoever answers, and the authority
    // decides whether to keep it.
    void sweep_authorities(MonoTime now)
    {
        foreach (kvp; get_module!SyncDiscoveryModule.neighbors[])
        {
            ref n = kvp.value;
            if (n.role != PeerRole.authority)
                continue;

            const(char)[] mine = bound_cluster[];
            if (mine.length && n.cluster.length && n.cluster[] != mine)
                continue;

            if (ClaimAttempt* a = kvp.key in _attempts)
                if (a.peer)
                    continue;

            NeighborLink* link = n.best_link(now);
            if (!link)
                continue;
            start_session(kvp.key, n, *link);
        }
    }

    // Claim the members that have opened a session to us and pass the filter. The beacon
    // carries the adoption state that decides key handover, so a node we have not heard
    // from yet waits for a later pass rather than being guessed at.
    void claim_inbound(MonoTime now)
    {
        get_module!SyncModule.each_running_peer((SyncPeer p) { claim_over(p, now); });
    }

    // Log delegation is claim policy: the tap is (re)armed each time a member is claimed, so it
    // survives the member reconnecting under a fresh session rather than dying with the old peer.
    void arm_logs(SyncPeer p)
    {
        if (_collect_logs)
            p.request_logs(_log_severity, false, null);
        else
            p.request_logs(_log_severity, true, null);
    }

    void arm_claimed_logs()
    {
        foreach (kvp; _issued[])
            if (kvp.value.acked && kvp.value.peer)
                arm_logs(kvp.value.peer);
    }

    void claim_over(SyncPeer p, MonoTime now)
    {
        if (!p.running || p._remote_role != PeerRole.member)
            return;
        ulong node_id = p._remote_node_id;
        if (!node_id || node_id in _issued)
            return;

        Neighbor* n = node_id in get_module!SyncDiscoveryModule.neighbors;
        if (!n)
            return;
        if (!wildcard_match(_claim.length ? _claim[] : "*", n.name[]))
            return;
        if (n.cluster.length && _cluster.length && n.cluster[] != _cluster[])
            return;

        bool handover = !n.adopted;
        if (handover && !_secret.length)
            mint_fleet_key();

        char[64] auth = void;
        bool have_auth = false;
        if (_secret.length)
        {
            if (!p._remote_nonce_set)
                return;   // the claim proves the key against their hello nonce
            have_auth = claim_auth(p._remote_nonce[], _cluster[], auth);
        }

        IssuedClaim* c = _issued.insert(node_id, IssuedClaim());
        c.peer = p;
        c.seq = get_module!SyncModule.alloc_seq();
        c.sent_at = now;
        encoder_for(p._encoder).encode_claim(p, c.seq, _cluster[], _priority, have_auth ? auth[] : null, handover ? _secret[] : null);
        log.info("claiming node ", hex_id(node_id)[], " ('", n.name, "') over its session", handover ? " (adoption)" : "");
    }

    // An inbound session is the member's to keep alive; when it goes, so does the claim.
    void prune_issued()
    {
        Array!ulong ended;
        foreach (kvp; _issued[])
            if (!kvp.value.peer || !kvp.value.peer.running)
                ended ~= kvp.key;
        foreach (id; ended[])
        {
            log.info("session from node ", hex_id(id)[], " ended");
            _issued.remove(id);
        }
    }

    void peering_set(Session session, Nullable!bool enabled, Nullable!PeerRole role, Nullable!(const(char)[]) cluster, Nullable!uint priority, Nullable!(const(char)[]) claim, Nullable!(const(char)[]) secret, Nullable!ushort port, Nullable!bool collect_logs, Nullable!Severity log_severity)
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
            _cluster = cluster.value.make_string();
        if (priority)
            _priority = priority.value;
        if (claim)
            _claim = claim.value.make_string();
        if (secret)
            _secret = secret.value.make_string();
        if (port)
            _port = port.value;
        if (collect_logs || log_severity)
        {
            if (collect_logs)
                _collect_logs = collect_logs.value;
            if (log_severity)
                _log_severity = log_severity.value;
            arm_claimed_logs();   // apply the change to members already claimed
        }

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
            session.write_line("logs:     ", _collect_logs ? severity_names[_log_severity] : "off");
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
            _secret = key.make_string();
            _allegiance_cluster = cluster.make_string();
            save_allegiance();
            log.notice("adopted into fleet '", cluster, "' by node ", hex_id(from._remote_node_id)[], "; allegiance persisted (/sync/peering reset returns to factory)");
        }
        else if (!bound_cluster.length && !claimed)
        {
            _adopted_cluster = cluster.make_string();
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
        foreach (kvp; _issued[])
        {
            if (kvp.value.peer is p)
            {
                log.info("session from node ", hex_id(kvp.key)[], " ended");
                _issued.remove(kvp.key);
                break;
            }
        }
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
        foreach (kvp; _issued[])
        {
            ref c = kvp.value;
            if (c.peer !is from || c.seq != seq || c.acked)
                continue;
            if (ok)
            {
                c.acked = true;
                log.info("claimed node ", hex_id(kvp.key)[], " ('", from.name[], "')");
                arm_logs(from);
            }
            else
            {
                log.warning("claim of node ", hex_id(kvp.key)[], " refused: ", code, " (", text, ")");
                _issued.remove(kvp.key);
            }
            return true;
        }
        return false;
    }

package:
    bool     _enabled;
    PeerRole _role;
    bool     _collect_logs = true;      // an authority taps its claimed members' logs by default
    Severity _log_severity = Severity.info;
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
        ObjectRef!EthernetStation link_station;  // the link this attempt went through; demoted on failure
        MACAddress link_mac;
        uint seq;
        bool sent;
        bool claimed;
        bool dead;
        bool handover;   // target beacons un-adopted: the claim carries the fleet key
        MonoTime deadline;
        MonoTime claimed_at;

        bool expired(MonoTime now) const pure nothrow @nogc
            => peer !is null && !claimed && now >= deadline;
    }
    Map!(ulong, ClaimAttempt) _attempts;   // sessions this node dials (member -> authority)

    // A claim this authority sent over a session a member opened to it.
    struct IssuedClaim
    {
        SyncPeer peer;
        uint seq;
        bool acked;
        MonoTime sent_at;
    }
    Map!(ulong, IssuedClaim) _issued;
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
        _secret = hex[].make_string();
        save_allegiance();
        log.notice("minted the fleet key for cluster '", _cluster, "'");
    }

    void load_allegiance()
    {
        import urt.file : load_file;

        char[] stored = cast(char[])load_file(fleet_id_path);
        if (!stored)
            return;
        scope(exit) free(stored);

        const(char)[] s = stored;
        const(char)[] cluster = s.split!'\n';
        const(char)[] key = s.split!'\n';
        if (!key.length)
            return;
        _secret = key.make_string();
        _allegiance_cluster = cluster.make_string();
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

        // the authority listens; members dial it, so the leaf needs no inbound surface
        bool want_listener = _enabled && _role == PeerRole.authority;
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
                _listener.local_host(StringLit!"00:00:00:00:00:00");
                _listener.port(_port);
            }
            else
                log.error("failed to create peering sync listener");
        }

        if (!_enabled || _role != PeerRole.member)
        {
            foreach (kvp; _attempts[])
                teardown_attempt(kvp.value);
            _attempts.clear();
        }
        if (!_enabled || _role != PeerRole.authority)
            _issued.clear();
    }

    void apply_announce_state()
    {
        auto disco = get_module!SyncDiscoveryModule;
        disco.local_role = _enabled ? _role : PeerRole.none;
        disco.local_cluster = _cluster.length ? _cluster : _allegiance_cluster.length ? _allegiance_cluster : _adopted_cluster;
        disco.local_claimed = claimed;
        disco.local_adopted = _secret.length != 0;
        disco.local_sync_port = (_enabled && _role == PeerRole.authority) ? _port : 0;
    }

    // Dial an authority: connected ether-UDP toward its beaconed mac:port, and a peer
    // that introduces us. The claim, if it comes, arrives back over this session.
    void start_session(ulong node_id, ref const Neighbor n, ref NeighborLink link)
    {
        char[16] id = hex_id(node_id);

        SyncPeer peer = Collection!SyncPeer().create(n.name[], ObjectFlags.dynamic);
        if (!peer)
            peer = Collection!SyncPeer().create(tconcat("auth-", id[]), ObjectFlags.dynamic);
        if (!peer)
        {
            log.warning("failed to create session peer for authority ", id[]);
            return;
        }
        InetAddress remote = InetAddress(link.mac.b, link.sync_port);
        EthernetStation station = link.station.get;
        UDPEndpoint* endpoint;
        if (station)
            endpoint = udp_open(null, &remote, &peer.on_udp_receive, station);
        if (!endpoint)
        {
            log.warning("failed to create session transport for authority ", id[]);
            peer.destroy();
            return;
        }
        peer.adopt_udp_endpoint(endpoint);
        peer.encoder(SyncEncoderKind.binary);
        peer.subscribe(&claim_peer_state);

        ClaimAttempt* a = node_id in _attempts;
        if (!a)
            a = _attempts.insert(node_id, ClaimAttempt());
        a.peer = peer;
        a.link_station = link.station;
        a.link_mac = link.mac;
        a.sent = false;
        a.claimed = false;
        a.handover = false;
        // the setup window: transport up and hellos exchanged; expiry demotes the link
        a.deadline = getTime() + claim_timeout;

        log.info("opening session to authority ", id[], " ('", n.name, "') at ", link.mac, ":", link.sync_port, " via ", link.station.name[]);
    }

    void claim_peer_state(ActiveObject obj, StateSignal sig)
    {
        if (sig == StateSignal.destroyed)
        {
            // Signal callbacks cannot destroy their source; update() reaps the attempt.
            foreach (kvp; _attempts[])
            {
                ref a = kvp.value;
                if (a.peer is obj)
                {
                    a.peer = null;
                    a.dead = true;
                    return;
                }
            }
            return;
        }
        if (sig != StateSignal.offline)
            return;
        foreach (kvp; _attempts[])
        {
            ref a = kvp.value;
            if (a.peer is obj && a.claimed)
            {
                // the decision is terminal: deregister now so no further signals arrive,
                // and leave the teardown to update()
                a.peer.unsubscribe(&claim_peer_state);
                a.dead = true;
                return;
            }
        }
    }

    void teardown_attempt(ref ClaimAttempt a)
    {
        if (a.peer && !a.dead)
            a.peer.unsubscribe(&claim_peer_state);
        if (a.peer)
        {
            a.peer.destroy();
            a.peer = null;
        }
        a.sent = false;
        a.claimed = false;
        a.dead = false;
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
    import urt.mem;

    // the setup deadline expires attempts that never sent, not just unanswered claims
    SyncPeeringModule.ClaimAttempt a;
    MonoTime t0 = MonoTime() + 100.seconds;
    a.deadline = t0 + 10.seconds;
    assert(!a.expired(t0 + 11.seconds));    // no peer: nothing to expire

    a.peer = alloc!SyncPeer(CID(1));
    scope(exit) free(a.peer);
    assert(!a.expired(t0));
    assert(a.expired(t0 + 11.seconds));     // unsent and stale: a dead link during setup fails over

    a.sent = true;
    assert(a.expired(t0 + 11.seconds));     // sent and unanswered: same path

    a.claimed = true;
    assert(!a.expired(t0 + 11.seconds));    // a live claim never expires here
}

unittest
{
    import urt.mem;

    SyncPeeringModule m = alloc!SyncPeeringModule(null);
    scope(exit) free(m);
    SyncPeer p1 = alloc!SyncPeer(CID(1));
    scope(exit) free(p1);
    SyncPeer p2 = alloc!SyncPeer(CID(2));
    scope(exit) free(p2);

    m._issued.insert(0xA, SyncPeeringModule.IssuedClaim(p1, 1));
    m._issued.insert(0xB, SyncPeeringModule.IssuedClaim(p2, 2));

    // a detaching peer takes its issued claim with it, and only its own
    m.peer_detached(p1);
    assert((0xA in m._issued) is null);
    assert((0xB in m._issued) && (0xB in m._issued).peer is p2);

    m.peer_detached(p1);
    assert(m._issued.length == 1);
}

unittest
{
    import urt.mem;

    SyncPeeringModule m = alloc!SyncPeeringModule(null);
    scope(exit) free(m);
    SyncPeer p = alloc!SyncPeer(CID(1));
    scope(exit) free(p);

    SyncPeeringModule.ClaimAttempt* a = m._attempts.insert(0xA, SyncPeeringModule.ClaimAttempt());
    a.peer = p;
    a.claimed = true;
    p.subscribe(&m.claim_peer_state);

    // offline records the death and deregisters; nothing is torn down inside the signal
    m.claim_peer_state(p, StateSignal.offline);
    assert(a.dead && a.peer is p);
    p.subscribe(&m.claim_peer_state);   // asserts if the handler had not removed itself
    p.unsubscribe(&m.claim_peer_state);

    // destruction by the peer's owner drops the ref and leaves the reap to update()
    a.dead = false;
    m.claim_peer_state(p, StateSignal.destroyed);
    assert(a.dead && a.peer is null);

    // signals for a peer no attempt holds are no-ops
    m.claim_peer_state(p, StateSignal.destroyed);
    assert(m._attempts.length == 1);
}
