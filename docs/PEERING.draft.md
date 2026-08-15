# Auto-Peering and Discovery

Status: design + first build. Companion to [SYNC_PROTOCOL.draft.md](SYNC_PROTOCOL.draft.md) and
[SYNC_TRANSPORTS.draft.md](SYNC_TRANSPORTS.draft.md). Those documents define the sync channel and
the wires it rides; this one covers how nodes find each other on those wires and assemble
themselves into a fleet without hand-wiring every peer.

## The shape of the problem

A fleet is a set of OpenWatt nodes that should behave as one system: an authority (or a pair)
holds the full control surface; members contribute their devices and accept control. Today every
peer relationship is two console commands on each end. That does not scale past a handful of
nodes and cannot survive address churn. The pieces that exist:

- OW control-plane echo (`echo_req`/`echo_reply` + identify) and broadcast sweeps -- a mac-layer
  ping that can already enumerate stations on a segment.
- `UDPInterface` with an ether backend -- a sync-capable datagram transport that rides a bare MAC
  address on IP-less builds, or ordinary UDP where IP exists.
- `SyncPeer` + the hub, transport-blind behind `BaseInterface`, with the ws-server precedent of a
  listener spawning `dynamic` peers and sweeping them when their transport dies.

Auto-peering is the layer that connects them: discovery finds candidates, a claim handshake forms
the relationship, and the peering agent owns the lifecycle.

## Identity

Peering cannot key on hostname (mutable, collides) or interface MAC (per-NIC, changes with
hardware). Every node carries:

- **name** -- the human name; the existing `/system` hostname. An out-of-box device names
  itself `openwatt-XXXX` from its node-id, so a box of fresh units is tellable-apart at every
  surface that shows the name; startup.conf (or, later, the adopting controller) renames it.
- **node-id** -- a 64-bit id. A chip-burned hardware identity wins where the platform has one
  (the eFuse factory MAC on ESP32; chip UIDs on other micros): it survives reflash and needs
  no storage, and on a micro the chip *is* the node. Computers carry a software identity
  instead -- random, generated on first boot, persisted in `conf/node.id` -- because a Pi's
  identity travels with its SD card, not the board.

Discovery, claims, and the dual-authority tiebreak key on node-id; names are display. The
mac-ping identify reply carries name + node-id (resolving the placeholder-hostname TODO).

## Configuration language

Three surfaces, all existing conventions:

**Discovery domains -- per-medium collections, the binding pattern.** Each protocol that can
discover neighbours registers a collection under `/sync/discover/<medium>`, as bindings live at
`/binding/<proto>`. Instances are the opt-in: no domain configured, no beacons, no responses.

```
/sync/discover/ether add name=lan interface=ether1
/sync/discover/udp   add name=site port=7001 multicast=...   # future: routed segments
/sync/discover/modbus add name=bus1 interface=mb1            # future: vendor fc discovery
```

Each is an ActiveObject holding its interface via ObjectRef, subscribing to state signals,
restarting when the medium bounces. The medium details (control frames, function codes) live
with the protocol; the sync module only sees the domain interface.

**The peering agent -- a singleton `/sync/peering`.** Role is node-global:

```
/sync/peering set enabled=yes role=member cluster=home           # claimable node
/sync/peering set role=authority cluster=home claim=* secret=...  # sweep + claim
/sync/peering set role=authority cluster=home priority=50 ...     # second authority = dual-master
```

- `role=member|authority`. "Authority" is already sync vocabulary; a member's *state*
  (unbound/claimed) is state, not config.
- `claim=` takes the sync path-glob grammar against node names, scoping what an authority adopts.
- `cluster=` names the fleet. Members accept claims only for their cluster (empty = accept any,
  for bench bring-up; refused when a secret is set). Two authorities declaring the same cluster
  is what creates the dual-authority relationship -- no dedicated pairing config.
- `secret=` gates claims (HMAC challenge inside the claim exchange). Claiming a node hands over
  the full control surface; the property exists day one even while the challenge detail lands
  later.

**Manual peers keep working.** `/sync/peer add transport=...` remains the hand-wired escape
hatch; auto-claimed peers are `dynamic` instances in the same collection, named after the remote
node (the per-VIN session precedent). One observability table: `/sync/neighbor print` -- identity,
domain, address, role, claim state, last-seen.

## Discovery mechanics

Two modes per domain, both cheap:

- **Announce (steady state):** unbound members and authorities beacon periodically
  (`OWControl.announce`, TLV body: node-id, name, role, cluster, claim state, sync reach). Slow
  cadence (default 30s), faster for a minute after a state change. Authorities passively populate
  the neighbour table; a state change (claimed, released) propagates within a beacon.
- **Probe (on demand):** the broadcast identify sweep, for active scans and for an authority that
  just started and does not want to wait a beacon interval.

Discovery yields a *medium address*; the peer needs a *transport*. Each domain owns a
`make_transport(candidate)` factory: the ether domain spins up a dynamic `UDPInterface` on the
ether backend targeting the neighbour's MAC and the well-known sync port; an RS485 domain would
yield the RTU-envelope adapter. The peering agent stays transport-blind, same seam as
`SyncPeer.transport`.

## Claim lifecycle

Discovery is unauthenticated and lossy; the claim rides the sync channel:

1. Authority sees an unbound neighbour passing `claim=`, builds the transport, creates a dynamic
   `SyncPeer`, sends `hello` extended with identity (node-id, name, role, cluster) plus
   `claim {cluster, priority, auth}`.
2. Member verifies cluster + secret. Accept: marks itself claimed (cluster + claimant node-ids),
   answers `res`; its announces now say claimed, so other clusters' authorities skip it.
   Reject: `err {code:"claimed"}` or `access_denied`.
3. Transport death tears down the dynamic peer (ws-server sweep pattern); the member reverts to
   announcing claimed-but-disconnected; the authority's neighbour entry ages back to a candidate
   with per-candidate backoff.

Claims are runtime state, not persisted: on reboot a member comes up unbound-within-cluster and
is re-claimed within a beacon interval. startup.conf declares role and domains; the mesh
reassembles itself.

## Dual-authority

The shape that avoids fighting the hub's star-only loop defense: **members hold a session to each
authority; the authority-authority link carries coordination only, never fleet state.**

- A member claimed by cluster `home` accepts sessions from both of home's authorities -- hot-hot,
  both build the full fleet surface directly from the source. No state transfer on failover; the
  survivor already has everything.
- The authorities discover each other (announces carry role + cluster), form one peer session,
  and exchange membership view, epoch, liveness, and the active/standby election: `priority=`
  then node-id tiebreak, VRRP-style. This link deliberately does not fan out mirrored devices,
  so the A-B-member triangle never becomes a sync loop; each member still sees a star.
- Write discipline: both can write, only the elected active does routine control; standby takes
  over on liveness loss. Policy in the peering agent, not new protocol -- `set`/`call` already
  route to the authority.
- Partition honesty: a member reachable by only one authority shows in the membership exchange
  (`/sync/peering print` shows the delta). Relaying fleet state through the partner is out of
  scope for v1; it is the thing that would need origin-tagged loop defense.

## Build order

1. `/system` name + persistent node-id; point echo identify at it. [done]
2. Neighbour table on the sync hub + ether discovery domain (announce TLV + sweep reuse),
   `/sync/neighbor print`. [done]
3. `/sync/peering` singleton, member side: announce unbound, accept claim, mark claimed. [done:
   hello carries identity (node-id, role, cluster); claim rides the channel, answered res/err;
   multiple claimants from one cluster accepted (the dual-authority seat); last-detach reverts
   to unbound]
4. Authority side: claim filter, transport factory via UDPInterface-over-ether, dynamic peer
   spawn/sweep.
5. Claim auth (secret + HMAC challenge). The `secret=` property exists; setting it refuses all
   claims until the challenge lands.
6. Dual-authority: authority-authority session, election, membership exchange.
7. Later domains: UDP multicast for routed segments, modbus function-code discovery per the
   L2/L3 trajectory.

## Open questions

- Empty `cluster=` on a member: accept any claimant is convenient on the bench and spooky in the
  field. Current position: accept but log loudly; refuse whenever a secret is configured.
- Optional persistence of claimed state, so a moved node does not silently join a neighbour's
  cluster. Deferred until it bites.
- Announce cadence config: per-domain property, probably; not decided.
- Whether the member should prefer its previous claimant on reconnect (affinity without
  persistence). Cheap to add later.
