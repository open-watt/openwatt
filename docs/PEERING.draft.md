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
  surface that shows the name (beacons, the provisioning AP's SSID, BLE advertising);
  startup.conf or the adopting controller renames it.
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
- `secret=` sets the fleet key by hand. Normally nobody does: the key is minted by the
  authority at first adoption and handed over inside the claim (see *Adoption* below); the
  property remains for hand-wired fleets and key rotation.

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

## Links and reachability

The neighbour table is the fabric's L3 table: node-id is the address, beacons are the adjacency
protocol, and each node keeps its own view of who it heard and how. A beacon is link-local (never
forwarded), so an entry means "I personally heard you"; reachability *through* the fabric is a
future propagation mechanism, not a beacon concern.

A neighbour holds identity once (node-id, name, cluster, role, claim state) and a set of
**links**, one per `(interface, address)` pair a beacon arrived through. The pair is indivisible:
an address alone does not identify a path (a modbus address is meaningless without its bus, a MAC
is ambiguous across segments -- and since stations adopt their driver's address, a VLAN leg shares
its parent's MAC). The sync port rides per link, since it is announced per medium. A multi-homed
node (say, an ethernet leg and a wifi leg, plus an RS485 drop later) contributes one link each;
every fabric member populates the table symmetrically, so member-initiated traffic picks paths by
the same rules.

Link **eligibility** is freshness only: a link that stops beaconing is dead after the table's
max-age, individually, while its siblings live on. **Preference** among live links is currently
fastest-link-speed with recency as tie-break; the full order is intended to be: operator cost
override, then link class (ethernet > wifi > 15.4 > RS485), then link speed, then recency. A
working session is sticky: re-ranking never moves it. Failure (the session dying, a claim
refused or unanswered) demotes the link the attempt went through with doubling backoff, and the
next sweep rebuilds through the next preferable live link; success clears the demotion. There is
no proactive move off a live session.

Transports are built from both halves of the chosen link (`interface=` + address), so the send
path never consults the L2 fdb and never floods. Failover today means rebuilding the transport
from the next link -- the reliability sublayer sees a new session and rebuilds, which it already
tolerates. Seamless failover (a session that addresses the node-id and late-binds its path per
send) is the full L3 move, deferred alongside election.

RTT can be collected from any sync exchange that expects a response (control acks, the time-sync
pull), per link, Karn-filtered and smoothed. Its primary uses are the retransmit clock (a flat
250ms schedule is wrong for both a LAN and a 9600-baud drop) and demotion of a degrading active
link against its own baseline; cross-class preference stays with the static order. Standby links
have no traffic, hence no RTT: class + freshness is their prior until a solicited probe (the CFM
mac-ping already exists for ether) proves worth adding.

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
   spawn/sweep. [done: sweep every 5s over the neighbour table; per-candidate exponential
   backoff; members listen via a dynamic /sync/udp-server; a claimed member is still claimed
   by an authority with no session to it (the dual-authority seat doubles as restart
   recovery), and a member that reboots out from under a session the datagram link cannot
   pronounce dead is detected by its unbound beacon and re-claimed]
5. Claim auth (secret + HMAC challenge). [done: every hello carries a fresh 16-byte session
   nonce; claim auth = hex(HMAC-SHA256(secret, member_nonce || cluster)). The secret never
   travels, and a captured claim cannot replay into a new session. A member with a secret
   refuses unauthenticated claims; an authority with a secret waits for the member's hello
   before claiming]
6. Dual-authority: authority-authority session, election, membership exchange.
7. Later domains: UDP multicast for routed segments, modbus function-code discovery per the
   L2/L3 trajectory.

## Adoption

Nobody should type keys. The fleet forms Zigbee-join style, trust-on-first-use:

- **Factory state**: a member with no key accepts any claim. An authority adopting such a node
  mints the fleet key if it doesn't hold one yet (32 random bytes, persisted), and hands it
  over inside the claim -- the one TOFU moment where the channel is trusted.
- **Allegiance**: the member persists `{cluster, key}` in `conf/fleet.id` beside node.id.
  From then on it beacons `adopted`, refuses claims that cannot prove the key (HMAC over its
  per-session hello nonce -- the key itself never travels again), and holds that allegiance
  across reboots. One fleet key shared by the cluster's authorities keeps dual-authority
  hot-hot without waiting on the election channel.
- **Approval mode is authority policy, not protocol**: `claim=*` auto-adopts matching factory
  nodes; an empty filter leaves the sweep observing only, and the neighbour table -- which
  already lists unbound nodes -- is the "waiting for adoption" list a controller UI presents
  for the user to approve.
- **Factory reset**: `/sync/peering reset` clears the allegiance (file and runtime); the node
  beacons factory-fresh again, which also voids any authority's claim backoff so re-adoption
  is immediate. Reset before moving hardware between fleets. Embedded builds will want a
  hardware-button hook.
- The MITM window is the adoption instant itself, as with every pairing scheme; user-present
  approval mode narrows it.

## Out-of-box onboarding (design sketch)

Adoption assumes the device is already on the network; the layer beneath gets it there. A
factory device has no WiFi credentials, so first contact is a phone app against one of:

- **SoftAP provisioning**: the unconfigured device boots an AP named after its factory
  hostname (`openwatt-XXXX`) and serves the existing config surface (HTTP/API); the app joins,
  sets WiFi credentials (and optionally pre-seeds cluster/name), the device joins the LAN, and
  fleet adoption proceeds from beacons as above. Nearly free: AP mode and the HTTP server
  already exist.
- **BLE provisioning**: the device advertises its factory name and exposes a small GATT
  config service for the same credentials. Needs BLE peripheral mode, which the stack does not
  do yet (the Tesla work built the central role).

The chain end to end: factory -> provision (get on the network) -> discovered (beacons) ->
adopted (claim + key handover) -> configured (the authority pushes config; phase B).

## The claimed surface

A successful claim arms `device:**` on the session: the member's whole device tree, live. The
model plane is self-describing (type/add frames), so subscribing is the enumeration; elements
appearing later stream in through the same sub. The member takes its first claimant as its time
authority (clock discipline is part of subordination; the elected-active refinement comes with
the election). Scoping the surface (`sub=` on the authority) is deferred until a
bandwidth-constrained medium forces it.

## Open questions

- Matching global device ids merge and their schemas and access are unioned. Peer-local devices
  retain their owning peer namespace, and private devices never enter the sync surface. A future
  scope flag should distinguish read-only and read-write peer-local exports.

- Empty `cluster=` on a member: accept any claimant is convenient on the bench and spooky in the
  field. Current position: accept but log loudly; refuse whenever a secret is configured.
- ~~Optional persistence of claimed state~~ -- resolved by adoption: allegiance persists,
  sessions do not; a moved node keeps refusing foreign fleets until factory reset.
- Announce cadence config: per-domain property, probably; not decided.
- Whether the member should prefer its previous claimant on reconnect (affinity without
  persistence). Cheap to add later.
