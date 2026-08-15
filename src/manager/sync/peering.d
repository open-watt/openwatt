module manager.sync.peering;

// The peering agent (docs/PEERING.draft.md): node-global auto-peering policy.
// role=member advertises this node as claimable and accepts claims over the
// sync channel; role=authority sweeps the neighbour table and claims unbound
// members matching the claim filter (transport factory: not built yet).
// A member accepts multiple claimants from one cluster - that is the
// dual-authority shape - and reverts to unbound when the last session dies.

import urt.array;
import urt.conv : format_uint;
import urt.log;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;

import manager;
import manager.console;
import manager.plugin;
import manager.sync.discovery;
import manager.sync.encoder : encoder_for;
import manager.sync.peer : SyncPeer;

nothrow @nogc:


alias log = Log!"peering";


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

    void peering_set(Session session, Nullable!bool enabled, Nullable!PeerRole role,
                     Nullable!(const(char)[]) cluster, Nullable!uint priority,
                     Nullable!(const(char)[]) claim, Nullable!(const(char)[]) secret)
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

        // config is intent; live claims that contradict it are released rather than
        // silently retained (which would admit claimants from two clusters at once)
        if (claimed && (cluster_conflict || !_enabled || _role != PeerRole.member))
        {
            session.write_line("note: released ", _claimants.length, " live claim(s)");
            log.warning("reconfigured while claimed; releasing ", _claimants.length, " claimant(s)");
            _claimants.clear();
            _adopted_cluster = String();
        }

        if (_role == PeerRole.member && _claim.length)
            session.write_line("note: claim filter is ignored for role=member");

        apply_announce_state();
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
        }
        if (_role == PeerRole.member)
        {
            session.write_line("state:    ", claimed ? "claimed" : "unbound");
            foreach (ref c; _claimants[])
            {
                char[16] id = void;
                format_uint(c.node_id, id[], 16, 16, '0');
                session.write_line("claimant: ", id[], " (", c.peer.name[], ") cluster=", bound_cluster[], " priority=", c.priority);
            }
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

        char[16] id = void;
        format_uint(from._remote_node_id, id[], 16, 16, '0');
        log.info("claimed by node ", id[], " ('", from.name[], "') cluster='", bound_cluster, "'");

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
                _claimants.remove(i);
                if (!claimed)
                {
                    _adopted_cluster = String();
                    log.info("last claimant detached; reverting to unbound");
                    apply_announce_state();
                }
                return;
            }
        }
    }

package:
    bool     _enabled;
    PeerRole _role;
    String   _cluster;
    uint     _priority = 100;
    String   _claim;
    String   _secret;

    struct Claimant
    {
        ulong node_id;
        SyncPeer peer;
        uint priority;
    }
    Array!Claimant _claimants;
    String _adopted_cluster;

    void apply_announce_state()
    {
        auto disco = get_module!SyncDiscoveryModule;
        disco.local_role = _enabled ? _role : PeerRole.none;
        disco.local_cluster = _cluster.length ? _cluster : _adopted_cluster;
        disco.local_claimed = claimed;
    }
}
