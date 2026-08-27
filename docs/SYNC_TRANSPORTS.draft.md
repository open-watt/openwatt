# Sync Transports

Status: design. Companion to [SYNC_PROTOCOL.draft.md](SYNC_PROTOCOL.draft.md), which defines the
verb set and the foreign/sibling transport classes. This document covers the layer below: the
physical links the binary sync channel rides, what each link must provide, and the adapter
designs. The binary encoder ([binary_encoder.d](../src/manager/sync/binary_encoder.d)) is built;
this is the plan for putting it on wires.

**Where the substrate stands** (2026-08-10, after the ether/endpoint work landed):
[`/interface/udp`](../src/router/iface/udp.d) exists and is better than what this document
originally planned -- it is a router-layer interface (so ip-less tiers get it), does unicast and
multi-drop, carries per-frame peer addresses in a `UDPFrame` header, and reaches ether peers
(`[mac]:port`) with no IP configured. [`InterfaceCaps`](../src/router/iface/package.d#L59) now
expresses `reliable` and `ordered` as advertised link properties, which is exactly contract
items 2-3 below, in code. A unicast remote now genuinely filters rx to its peer on every
platform, so "connected" means the same thing everywhere.

**What blocks sync-over-UDP** is that the interface dispatches `UDPFrame` while `SyncPeer`
subscribes `PacketFilter(PacketType.raw)`, so a peer on a UDP transport transmits and receives
nothing. The peer is what changes -- see *Framing* below.

## The link contract

`SyncPeer.transport` is any `BaseInterface` delivering `RawFrame` packets. The encoder calls
`transmit_frame` and never sees the link. What the sync channel requires of a link adapter:

1. **Frame delimiting.** One protocol frame per packet. Datagram links get this free; byte
   streams need framing.
2. **Integrity.** Corrupt frames are dropped at the link, never delivered. CRC everywhere except
   memory-coherent links.
3. **Ordered delivery for the control plane.** The protocol assumes type-before-cite,
   add_name-before-bind, add-before-val. Any reliability scheme must preserve per-peer order for
   control verbs.

4. **Best-effort is acceptable for the data plane.** `val`/`val_block`, `log`, `time_push` are
   latest-value or cursor-recoverable. Lost vals self-heal: latest-value elements on the next
   update, point series by backfill from the series cursor (residency-unified series reach full
   history, so recovery is always possible). Retransmitting stale telemetry is worse than
   re-reading it.
5. **MTU.** Advertised via `hello.max_frame`, already negotiated. The encoder must learn to cap
   `val_block` chunking to the peer's max_frame (currently fixed 256-record blocks); oversized
   control frames (bind with many props) are a real hazard on small-MTU links. TODO on the
   encoder side.
6. **Channels (where shared).** Links carrying more than sync (console, OTA, log tap as separate
   streams) need a mux id. Datagram links can instead use distinct ports; point streams use CPC
   endpoints; RS485 uses an envelope channel byte.

Items 2-3 are advertised by the link as `InterfaceCaps.reliable` / `.ordered`, so a peer can read
its transport's caps and decide whether it must supply the missing guarantee itself (shmem and CPC
advertise both; UDP advertises neither). That check is the natural home for the control-plane
reliability layer below -- it arms only where the link doesn't already promise it.

**Backpressure contract (cross-cutting fix, phase 1b):** `transmit_frame < 0` currently drops
event-driven control frames with no retry, on every transport. The contract should become
"accepted = enqueued": link adapters own a bounded queue (`PriorityPacketQueue` fits), and
control verbs are only droppable when the peer is genuinely dead (queue overflow after patience,
peer offline). Data-plane frames stay droppable (DEI=1); control frames ride PCP >= ca with
DEI=0. Until this lands, reliable links mask the problem and lossy links occasionally lose a
`state` or `result` frame.

## Configuration language

The most important design surface. The links differ in role shape -- symmetric peers (UDP),
client/server (WS, TCP), master/slave (RS485), fixed pairing (shmem) -- but the user should
only ever describe the **channel**; the sync module chooses and owns the transport adapter
stack above it. Nobody hand-wires stream -> framing interface -> peer.

**Principle: name the channel, get the stack.** Datagram links are already interface-shaped
(one datagram, one frame), so their interface IS the channel object and carries the endpoint
config directly -- no stream underneath. Byte streams are the ones needing an adapter stack.
`SyncPeer` accepts, in increasing sugar:

- `transport=<iface>` -- a raw-frame interface: `UDPInterface`, a WebSocket, later a
  `CPCEndpoint` or the RS485/shmem adapters. How ws-server wires accepted sockets today.
- `stream=<stream>` (future, lands with CPC) -- for byte streams only (serial, RS232 bridge,
  TCP): the peer materialises the CPC stack above the stream and owns it (dynamic object,
  destroyed with the peer). Mutually exclusive with `transport`, later set wins.
- `remote=<address>` -- creates and owns a temporary UDP interface. Address syntax is
  `ip:port`, `[ipv6]:port`, or `[mac]:port`; the port is required. Future URI schemes can
  extend this to WebSocket, serial, RS485 and shared memory.

**Outbound/symmetric** links are one command:

```
/sync/peer add name=pi remote=192.168.0.8:4826 encoder=binary
```

**Inbound/server** roles are listeners that spawn dynamic peers on accept, one collection per
scheme, precedent set by `/sync/ws-server`: a future `/sync/udp-server` (accept datagrams from
unknown sources, spawn a peer per source), `/sync/serial-server` (CPC secondary answering a
primary). Spawned peers are `dynamic`, named after the listener, destroyed when the transport
dies.

**Master/slave (RS485)** maps onto the same two shapes: the master configures one peer per
slave (`remote=rs485://bus1/12` -- bus interface plus slave address; the bus's single
scheduler owns arbitration), the slave side is a listener (`/sync/rs485-server bus=...`
responding when polled). **Shmem** is a fixed pairing: `remote=shm://ring0` on both cores.

The encoder choice stays orthogonal (`encoder=json|binary`) but transports may default it:
shmem and RS485 default binary; ws stays json for browsers.

## Transport matrix

| link | framing | integrity | reliability | mux | class |
|---|---|---|---|---|---|
| UDP unicast | datagram | UDP checksum | control: seq/ack layer; data: best-effort + cursor recovery | ports | foreign |
| UDP multicast | datagram | UDP checksum | none on group; gap-detect + unicast backfill | ports | foreign, one-way |
| shmem ring (BL808 M0/D0) | length prefix | memory | inherent; backpressure = ring full | channel byte | sibling |
| UART / RS232 / SPI point link | CPC | CPC CRC | CPC retransmit | CPC endpoints | foreign |
| I2C point link | (deferred) | - | - | - | needs data-ready GPIO or polling; prefer SPI/UART |
| RS485 multi-drop | Modbus RTU envelope | CRC16 | poll/response retransmit | envelope channel byte | foreign |

## UDP (phase 1)

### UDP endpoints -- built upstream

[`router/iface/endpoint.d`](../src/router/iface/endpoint.d) provides the direct datagram API.
An explicitly configured peer owns a connected endpoint. A UDP server owns unconnected listener
endpoints and its spawned peers borrow the receiving endpoint plus the remote source address.
This lets several peers share one socket without creating peer sub-interfaces or routing packets
through `BaseInterface`.

UDP is neither ordered nor reliable while ASH, CPC and shmem are both, so direct UDP peers arm
the control-plane reliability layer unconditionally. Interface-backed peers still use
`InterfaceCaps.reliable` and `InterfaceCaps.ordered`.

```
/sync/peer add name=pi remote=192.168.0.8:4826 encoder=binary
```

The `/sync/udp-server` listener creates a peer only for an initial hello from an unknown source
and routes subsequent datagrams by `(local endpoint, remote address)`.

### Reliability split (phase 2) -- BUILT

Not one scheme, two planes:

- **Control plane** (registry, bind/create/destroy, set/reset, cmd/result, sub, type/add,
  model_set, res/err, claim, time_push): small, rare, must arrive in order and in good time.
  time_push rides here because a lost delta corrupts every timestamp the subordinate collects
  until the next push or the 17-minute poll repairs it.
- **Data plane** (val/val_block, log): reliable but lazy. No retransmit timer and no urgency,
  but nothing is willingly lost: unacked data refolds into the next frame as catch-up, so a
  dropped val simply arrives as `{ts+val, ts+val}` alongside its successor. Peers agree on
  history; `sub {from}` backfill is demoted to deep-history repair (rejoin after an outage
  longer than the catch-up backlog).

As built: the layer lives on the peer (the placement question resolved itself: reliability
state is per remote, and on a shared multi-drop transport only the peer knows its remote).
It arms when the transport doesn't advertise `reliable+ordered` -- both ends decide from
their own link, so arming is symmetric by construction; websocket, CPC and shmem skip it.
Armed, every frame carries `[src_session:4][dst_session:4][kind:1]` (fixed bytes; all windows
are tiny, so seq/ack/id fields are wrapping single bytes). Control frames add `[seq][ack]`,
are retransmitted on timeout (250ms doubling, 8 tries, then the session restarts) until the
piggybacked cumulative ack covers them, and deliver strictly in order through a small reorder
hold. Data frames carry `[epoch][ack_epoch][ack]` plus `[id][len:2][payload]` records: each
queue (val, log) has its own id space and backlog, every data frame refolds the entire
unacked backlog, and the receiver's per-queue watermark dedups replays while keeping
application in order. A record the receiver can't apply yet -- a val racing its add through
the control plane -- is left unacked, so the refold resupplies it until the add lands.
Handles are announced in ascending order over the in-order control plane, so the receiver
can tell that race from a poison: a handle below the announced high-water mark had its add
delivered (adds announce their handle even when the node fails to materialise), so a val
citing it that still doesn't resolve is dead and skipped as declared loss rather than
stalling the queue; only handles above the high-water hold, and that hold is bounded by the
control plane's own repair horizon. A bare ack carrying all watermarks goes out on the next
tick when no reverse traffic piggybacks them.

Bounded retention means eviction (cap overflow, or the ttl -- derived from the control
retransmit schedule so it outlasts any legitimate repair) is possible, and eviction breaks
the catch-up promise, so it is declared, not silent: the queue's epoch bumps once per
repair cycle, and the receiver re-bases its watermark under a newer epoch's refold. That
keeps the single-byte ids sound (within an epoch, watermark-to-newest distance is bounded
by the backlog cap), and acks are epoch-qualified, so a pre-bump ack can never release
post-bump frames through wrap ambiguity. A bump is durable: with nothing left to refold an
empty frame keeps announcing it, and only an ack carrying the new epoch closes the repair
cycle -- so however long a partition lasts, the epoch stays within one of the receiver and
can never wrap out of its own comparison window. The gap itself is repaired above the
sublayer once the cycle closes: a val-queue bump re-pushes the latest value of every armed
live node (idempotent, so the mirror is correct again and only intermediate history is
missing -- backfill's job), and a log-queue bump emits a lost-lines marker.

Session ids echo rather than "new id wins": a frame is honored only when its `dst` matches
the receiver's live tx session (`dst 0` passes only for a stream-opening hello, or while
`src` is already the adopted session), so stragglers from a dead session can neither deliver
nor ack. Adopting a genuinely new `src` restarts the peer -- the remote rebooted and the whole
session space (handles, interning, subs) must rebuild -- and the freshly-restarted side
re-adopts from zero without restarting again, so mutual restart cannot ping-pong.

Classification is by verb at encode time, carried as a queue tag on `transmit_frame`; the
four data-plane emitters in each encoder are the only call sites that tag it. Control
transmit is accepted-means-enqueued (the backpressure contract above): a control frame is
only lost if the peer is genuinely dead, at which point the session restarts and re-syncs
from hello. PCP/DEI marking of the underlying packets remains a TODO.

### Multicast (phase 5)

For one-publisher many-subscriber val feeds. Structural change: multicast needs a
**publisher-owned handle and ft namespace** -- receivers adopt only, nobody allocates handles
back, because only the publisher transmits on the group. This is a third session shape next to
foreign and sibling: foreign-one-way.

- Join: newcomer unicasts `hello` + `sub`; publisher unicasts current `type`/`add` schema and a
  snapshot, then the receiver follows the group feed. A per-publisher datagram seq marks the
  switchover point, gap-free against the snapshot cursor.
- Loss: receivers detect gaps by datagram seq; recover by unicast `sub {from}` backfill. Never
  per-receiver acks on the group (ack implosion).
- Scope: publisher-enabled optimization, per group. Wired ethernet with IGMP snooping is the
  win case. WiFi multicast (base-rate, no retries, DTIM buffering) usually loses to two or
  three unicasts -- do not default it on.

## Shared memory: BL808 M0/D0 (phase 3)

Two SPSC rings, one per direction, length-prefixed frames. No CRC, no retransmit. This is the
**sibling** class from SYNC_PROTOCOL: same-build cores, shared id/format tables, introduction
and interning degenerate to identity. Notes:

- Cache coherence: D0 is cached; rings live in an uncached window or get explicit maintenance.
  Same class of lesson as the WRAM/PSRAM wifi work.
- Backpressure: ring-full must surface as "queue and wait", not frame loss -- which is exactly
  the transmit-is-enqueue contract above. Size rings so control bursts (startup registry fan-out)
  fit.
- M0 is `FEATURES=switch HEADLESS=1`: validate what actually syncs (interface state, counters,
  console, logs) before sizing anything.

## CPC over byte streams: UART, RS232, SPI (phase 4)

Point-to-point board links (C6<->P4 and kin) are **not** assumed accurate: UART overruns are
routine, SPI slaves desync and have no flow control, I2C acks bytes but not payloads. CPC
(in tree, [protocol/cpc/](../src/protocol/cpc/)) already provides exactly the needed layer over
UART and SPI-with-handshake-GPIO: HDLC-ish framing, CRC, retransmit, and multiplexed endpoints
(sync on one endpoint, console/OTA on others). The adapter is: sync peer's transport = a
`CPCEndpoint`. CPC's primary/secondary asymmetry is a config choice on a point link.

I2C is deferred: the slave cannot initiate, so it needs a data-ready GPIO or master polling
underneath CPC. Between our own boards, prefer SPI or UART.

## RS485 multi-drop (phase 4, design settled here)

Requirements: multiple OW sync nodes on one bus, coexisting with non-OW Modbus devices, master
arbitrated.

**Envelope: real Modbus RTU frames.** Not "looks like" -- actually valid:
`[addr][fc=OW_SYNC][chan][seq|flags][sync frames...][crc16]`, with `fc` from the user-defined
function code space (0x41-0x48 / 0x64-0x6E). Coexistence is then by construction, not
probability: non-OW slaves ignore by address, bus analyzers see legal Modbus, and arbitration is
Modbus discipline -- only the addressed node transmits, inside a bounded response window.

**Token = poll.** The master's token grant is a request frame to one slave; the slave's transmit
opportunity is its response window. Response carries queued sync frames plus a "more pending"
flag; the master re-polls while more is set. Reliability falls out of the request/response
shape: master times out and re-polls with the same seq; slave answers a repeated seq from its
last-response cache. No free-running timers on the bus.

**Mux without CPC.** One channel byte + one seq/flags byte in the envelope. Literal CPC is
wrong here: its retransmit timers assume it owns a duplex link; polled half-duplex fights it.

**One bus, one scheduler.** The sync adapter must live under the same scheduler as the Modbus
master on that port -- sync grants interleave with ordinary Modbus polls through the existing
priority queue. Two independent owners of one RS485 port cannot coexist. This slots into the
Modbus L2/L3 trajectory (interfaces as switch ports).

**Per-slave baud.** Electrically feasible (switch while idle between frames), but wrong-baud
frames degrade the coexistence guarantee from "provably ignored" to "almost certainly ignored"
(byte soup with a 1/65536 CRC accident), and silence timing shifts with baud. Design: baud is
per-slave addressing metadata from day one; implementation deferred until a real fixed-baud
legacy device forces it; default is a uniform bus.

## Build order

0. ~~Direct UDP endpoints~~ -- done upstream ([router/iface/endpoint.d](../src/router/iface/endpoint.d)).
1. ~~Sync over direct UDP endpoints~~ -- done: explicit peers own connected endpoints;
   `/sync/udp-server` owns listener endpoints and routes datagrams to borrowing peers by source.
2. **Backpressure contract**: transmit-is-enqueue, PCP/DEI classification of control vs data.
   Reads `InterfaceCaps` to know what the link already promises.
3. **Shmem ring** (with the BL808 work): sibling class, binary encoder's original target.
4. **CPC endpoint transport** + **RS485 envelope**: RS485 benefits from the mux/seq conventions
   the others settle.
5. ~~UDP reliability layer~~ -- done (see Reliability split above). Remaining: **multicast**.

Order of 2 vs 5a is flexible: the UDP control-plane layer may *be* the backpressure contract's
first implementation.

## Open questions

- `max_frame`-driven chunking in the encoders: needed before small-MTU links (CPC payload,
  RS485 response windows) carry model bursts.
- RS485 slave-to-slave traffic: hub through the master (star, matches current sync topology) or
  scheduled slave-to-slave windows? Star first.
- Multicast group addressing: per-publisher group derived from node id vs configured. Configured
  first, derivation later.
