# Peering

A fleet is a set of OpenWatt nodes that behave as one system: an authority holds the full control
surface, members contribute their devices and accept control. Peering is the layer that finds nodes
on the wires, forms those relationships, and keeps them alive across address churn and reboots
without every peer being hand-wired on both ends. It rides the sync channel described in
[SYNC.md](SYNC.md); this document covers everything above that channel. The console reference for
every command named here is in [CLI.md](CLI.md).

## Identity

Every node carries two identities. The **name** is the `/system` hostname and is display only: it
is mutable and can collide. The **node-id** is a 64-bit identity and is what discovery, claims and
the dual-authority tiebreak key on. Where the platform has a burned hardware identity (the factory
MAC on ESP32, a chip UID on other micros) that is the node-id: it survives reflash and needs no
storage, because on a micro the chip is the node. Elsewhere a random id is generated on first boot
and persisted in `conf/node.id`, so a Pi's identity travels with its SD card rather than the board.

An out-of-box device names itself `openwatt-XXXX` from the low 16 bits of its node-id, so a box of
fresh units is tellable-apart at every surface that shows the name; `startup.conf` or the adopting
authority renames it. Beacons, the `hello` frame and the neighbour table all carry both identities.

## Discovery

A discovery domain (`/sync/discover/udp`) beacons this node's peering identity from each local
endpoint it binds, feeds received beacons into the neighbour table, and owns one dynamic sync server
over the same endpoints. Domains are the opt-in: with no domain configured a segment carries no
beacons and accepts no inbound sync.

A domain binds a list of local endpoints. `bind=` takes exact endpoints (AF_ETHERNET or IPv4; an
omitted port takes the domain's `port=`, default 4826), `interface=` resolves to AF_ETHERNET and
every configured IPv4 endpoint on the named interfaces, and the station identity keeps a VLAN leg
distinct from its parent when both share a MAC. Ether beacons ride the ordinary OpenWatt Ethernet
UDP transport, so an IP-less build discovers and syncs on a bare MAC. IPv4 beacons use the
`239.255.79.87` multicast group by default (one wildcard socket per port, joined on every selected
local address, memberships announced with IGMPv2); `multicast=false` uses directed or limited
broadcast instead. Socket bind rules are the UDP stack's own: discovery does not enable address
reuse or paper over overlapping listeners.

The beacon is a small TLV body: node-id, name, role, cluster, and a flags byte carrying `claimed`
and `adopted`. Nodes beacon every `interval=` (default 30s) and faster for a while after a state
change, so a claim or a release propagates within one beacon. A domain also answers the identify
sweep, which is how a freshly started authority sees the segment without waiting an interval.

Only media that are not datagram-addressable get a medium-specific collection; a Modbus bus
discovers by function code rather than by socket, which is why it cannot be a `bind=` entry.

### The neighbour table

`/sync/neighbor print` is the fabric's own address table: node-id is the address, beacons are the
adjacency protocol, and each node keeps its own view of who it heard and how. A beacon is
link-local and never forwarded, so an entry means "I personally heard you".

A neighbour holds its identity once (node-id, name, cluster, role, claim state) and a set of
**links**, one per `(interface, address)` pair a beacon arrived through. The pair is indivisible:
an address alone does not identify a path (a MAC is ambiguous across segments, and a VLAN leg
shares its parent's MAC), so the interface travels with it. A multi-homed node contributes one link
per leg, and every node populates the table symmetrically, so member-initiated traffic picks paths
by the same rules an authority would.

A link is eligible while it is fresh: a link that stops beaconing dies after ten minutes,
individually, while its siblings live on. Among live links the most preferable is the one with
the highest link speed, recency breaking ties. A working session is sticky; re-ranking never moves
it. A failed attempt demotes the link it went through with doubling backoff, so the next sweep
rebuilds through the next preferable live link, and success clears the demotion.

## The peering agent

`/sync/peering` is a node-global singleton, not a collection: `set`, `print` and `reset`. Setting a
`role` is the opt-in.

- `role=member|authority`. Authority is already sync vocabulary. A member's state (unbound,
  claimed) is state, not configuration.
- `cluster=` names the fleet. A member accepts claims only for its cluster; with no cluster set it
  accepts and adopts the first claimant's cluster, logging loudly.
- `claim=` (authority only) is a path glob against member names, scoping what this authority
  adopts. Default `*`.
- `priority=` is the authority election precedence, lower wins, node-id breaking ties. Default 100.
- `secret=` is the fleet key set by hand. Normally nobody sets it; see *Adoption*.
- `collect-logs=` (default yes) and `log-severity=` (default info): an authority taps each claimed
  member's log stream, so a fleet's logs converge on its authority.

Manual peers keep working. `/sync/peer add` remains the hand-wired path, and auto-formed sessions
are `dynamic` instances in the same collection, named after the remote node.

## Session formation

The member dials. It is the end that can: a member behind NAT, or with no inbound surface at all,
still joins its fleet, and the authority still decides who joins by answering rather than by
calling. Every five seconds a member sweeps its neighbour table and, for each authority of its
fleet it has no session to, opens a connected UDP endpoint from that authority's most preferable
live link (bound to the address and station the beacon arrived on, toward the beacon's source
address and port) and spawns a dynamic `/sync/peer` named `auth-<node-id>`. A member that reboots
dials on the way up without waiting for a sweep.

The `hello` exchanged on that session carries identity (node-id, role, cluster) and a fresh
16-byte session nonce from each side. An authority that sees a member's hello pass its `claim`
filter answers with `claim {cluster, priority, auth, key}`. The member verifies cluster and, if it
holds a key, the proof (below); it marks itself claimed, records the claimant, answers `res`, and
its beacons now say claimed so other clusters' authorities skip it. A refused claim is
`err {code:"claimed"}` or `access_denied`.

If several configured sessions identify the same node, the authority keeps its pending or
acknowledged claim on the current session. Refusal, detach or an offline session releases that
claim; a later sweep can claim over another running session. This does not migrate session state.

The dial has ten seconds to establish and exchange hellos. Expiry, a refused claim, or the session
dying tears the pair down and demotes the link the attempt went through (30s, doubling to 10m), so
a member that sees an authority on two segments settles on the one that works.

Claims are runtime state. When the last claimant's session dies the member reverts to unbound and
is re-claimed within a beacon interval; `startup.conf` declares role and domains, and the fleet
reassembles itself. A restarted authority is rejoined by its members rather than having to
rediscover them, and a member that reboots out from under a session the datagram link cannot
pronounce dead is detected by its unbound beacon and re-claimed.

### What a claim confers

A successful claim makes the first claimant the member's time authority. After the member
acknowledges the claim, the authority arms its configured log tap and subscribes to `device:**`
on that session. A replacement session must acknowledge its own claim before either subscription
is armed. Device mirroring uses the model subscription described in [SYNC.md](SYNC.md).

## Dual-authority

A member accepts any number of claimants from a single cluster; a claim naming a second cluster is
refused. Two authorities declaring the same cluster is therefore the whole of dual-authority
configuration: each holds its own session to every member and builds the full fleet surface
directly from the source, hot-hot, with no state transfer on failover because the survivor already
has everything. A claimed member is still claimed by an authority that currently has no session to
it, which is what gives a restarting authority its seat back.

Election between the two is not built. Today both are live, the first claimant is the member's
time authority, and nothing distinguishes an active from a standby. See
[TODO.md](../TODO.md), *Sync and peering*.

## Adoption

Nobody types keys. The fleet forms Zigbee-join style, trust on first use:

- A **factory** member holds no key and accepts any claim. An authority adopting one mints the
  fleet key if it does not hold one yet (32 random bytes, persisted) and hands it over inside the
  claim. That is the one moment the channel is trusted.
- The member persists its **allegiance**, `{cluster, key}`, in `conf/fleet.id` beside `node.id`.
  From then on it beacons `adopted` and refuses any claim that cannot prove the key. Proof is
  `hex(HMAC-SHA256(key, member_nonce || cluster))` over the member's per-session hello nonce: the
  key never travels again, and a captured claim cannot replay into a new session. An authority
  with a key waits for the member's hello before claiming, since it needs the nonce.
- One fleet key shared by a cluster's authorities is what keeps dual-authority hot-hot without an
  election channel.
- Approval is authority policy, not protocol. `claim=*` auto-adopts every matching factory node; a
  narrower filter leaves the sweep observing, and the neighbour table, which already lists unbound
  nodes, is the "waiting for adoption" list.
- `/sync/peering reset` is the factory reset. It clears the allegiance, file and runtime, and the
  node beacons factory-fresh again, which also voids any authority's claim backoff so re-adoption
  is immediate. Reset before moving hardware between fleets.

The MITM window is the adoption instant itself, as with every pairing scheme.

## Tunables

| | |
| --- | --- |
| beacon interval | 30s, per domain (`interval=`) |
| neighbour and link max age | 10 minutes of silence |
| member sweep | 5s |
| dial deadline | 10s from open to hellos exchanged |
| dial backoff | 30s doubling to 10m, per link |
| service port | 4826, discovery and sync share the socket |
| IPv4 discovery group | `239.255.79.87` |

## Direction

The parts of the design that are settled but not built, tracked in [TODO.md](../TODO.md) under
*Sync and peering*:

- **Election.** The authorities form one peer session that carries membership view, epoch,
  liveness and the active/standby election (`priority` then node-id, VRRP-style). That link
  deliberately carries coordination only, never fleet state, so the authority-authority-member
  triangle never becomes a sync loop and each member still sees a star. Members then follow the
  elected-active for time discipline and routine control; both may write, standby takes over on
  liveness loss. A member reachable by only one authority shows as a delta in the membership
  exchange.
- **Link ranking and failover.** Operator cost override, then link class (ethernet, wifi, 15.4,
  RS485), then speed, then recency; per-link RTT from acked exchanges driving the retransmit clock
  and demoting a degrading link against its own baseline. Seamless failover, where a session
  addresses the node-id and late-binds its path per send, is the full L3 move and lands with the
  election. Reachability through the fabric is a separate propagation mechanism, not a beacon
  concern.
- **Onboarding.** A factory device with no network yet: SoftAP provisioning named after the
  factory hostname serving the existing HTTP config surface, or BLE provisioning once the stack has
  a peripheral role. The chain is factory, provision, discovered, adopted, configured.
- **Micros.** `node.id` and `fleet.id` need an NVS backing where there is no filesystem.
