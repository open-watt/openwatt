# Sync

Sync is the channel between OpenWatt nodes. One node mirrors another's objects and data model,
drives its console, taps its logs and disciplines its clock, over whatever link joins them. This
document is the specification of that channel as built: what a session is, what travels on it, and
what a link must provide to carry it. [PEERING.md](PEERING.md) describes how nodes find each other
and form sessions without being hand-wired; [CLI.md](CLI.md) is the console reference for every
command named here.

## Principles

1. **Identity is the name; ids never travel.** CIDs, EIDs, format ids and collection ordinals are
   process-local and build-sensitive. The wire carries names, paths and session handles.
2. **Knowledge is pushed, never requested.** A name binds to a handle once; a format or an enum
   dictionary is pushed before the first frame that cites it. There is no request verb for schema:
   if you hold a reference, you were already sent its definition.
3. **An introduction answers every question it provokes.** Path, schema reference, ownership and
   current value travel together, because each omission would stimulate the follow-up request
   principle 2 forbids.
4. **Every verb family is optional and negotiated.** Capability is a build-time property, so it is
   declared in `hello`, and an unsupported verb is answered `err {code:"unsupported"}`, never
   dropped.

## Peers and transports

A session is a `/sync/peer`. It binds to a link one of two ways, the last set winning:
`transport=<interface>` takes any interface delivering raw frames (a WebSocket, a UDP interface);
`remote=<address>:<port>` (`ip:port`, `[ipv6]:port` or `[mac]:port`, port required) opens a
connected UDP endpoint the peer owns. `encoder=json|binary` selects the wire encoding, and
`time-authority=yes` designates the remote as this node's clock source by hand.

Listeners spawn peers. `/sync/udp-server` owns one UDP endpoint per selected local endpoint and
spawns a dynamic peer for the first datagram from each unknown `(local endpoint, remote endpoint)`
pair; each spawned peer replies through the endpoint that received it, several peers share one
socket, and a source that goes quiet is swept after `timeout=` (default 5m) since datagrams carry
no death signal. `/sync/ws-server` binds a `uri=` on an HTTP server and spawns one peer per accepted
WebSocket, destroyed when the socket closes. Every discovery domain owns a dynamic, temporary UDP
server as its exclusive child, fed the session frames the domain demultiplexes from its own
sockets, so discovery and inbound sync share the exact endpoints. Spawned peers are `dynamic`
instances of `/sync/peer`, named after the remote node once its `hello` identifies it.

Two encoders share one verb space. JSON is the browser-facing form (`ws-server` defaults to it);
binary is the compact form (`/sync/peer` and `udp-server` default to it), packing many handles per
tick where JSON favours a frame per element.

## Sessions

`hello` is the first frame in each direction: protocol version, hostname, capability bits,
`max_frame`, and node-id, role, cluster and a fresh 16-byte nonce for peering. Capability names the
verb families this build serves: `objects` (the object mirror), `model` (the data-model plane),
`history`, `console`, `logs`, `time` and `console_session`. `max_frame` bounds every response;
history already caps at 2000 points to fit one 64 KB packet.

Session handles name everything addressable. The introducer allocates them, dense and ascending,
session-scoped and never reused; the low bit says who allocated the handle relative to the frame's
sender, so both directions share one space without a negotiation. A handle is an `EID` underneath,
`(container, element index)` with index 0 denoting the container itself, so devices, objects and
elements share the one handle space. Handle resolution is a peer responsibility, never an
encoder's: encoders ask the peer to map handle to node and back, which is the seam that keeps a
future shared-memory sibling transport possible (see *Direction*).

Formats are interned per session. The first frame that would cite an unseen `DataFormat` is
preceded by a `type` frame binding it to a session format id (`ft`); enum and bitfield
dictionaries are pushed the same way the first time a format cites them. Nothing is sent twice.
Frames arriving before the peer has started are buffered (up to 64 KiB) rather than processed
outside a session.

Every request carries a `seq`, omitted when zero; `res {seq, value?}` and `err {seq, code, text}`
answer it. Error codes: `unsupported`, `unknown_path`, `unknown_handle`, `access_denied`,
`bad_value`, `not_authoritative`, `too_large`, `unserialisable`, `busy`, `cancelled`, `claimed`.

Under peering, an authority answers a member's `hello` with `claim {seq, cluster, priority, auth?,
key?}`, and the member answers `res` or `err`. What the fields mean and prove is defined in
[PEERING.md](PEERING.md).

## The object mirror

The object mirror synchronises the `BaseObject` world: collections, their objects, properties and
lifecycle. A `sub` pattern of `[=]<type>:<name>` (with `*` globs; `=` means the exact type, no
descendants) arms it, and `unsub` disarms it.

| verb | carries |
| --- | --- |
| `add_name` | a syncable object's name and type, ahead of any reference to it |
| `bind` / `unbind` | a subscription binding a handle to a named object, with its properties |
| `create` / `destroy` | object lifecycle, as the console's `add`/`remove` would |
| `state` | a `StateSignal` transition |
| `set` / `reset` | a property write, or restore of its initial value |
| `enum_req` / `enum` | a property's enum dictionary, on request |

A `bind` introduces the object it cites, so a client can never bind something it was not told
about. Objects are announced in ascending handle order over the in-order control plane, which the
reliability sublayer relies on (below). Peer-contributed objects are served to peers other than
their contributor, so a hub fans out; the topology this defends is a star, not an arbitrary graph.

## The model plane

The data-model space is one tree. Only nodes with local identity are addressable; structure
without identity is carried by paths alone.

| node class | identity | schema |
| --- | --- | --- |
| device | `CID` | subtree prefix owner |
| element | `EID` | format |
| component | none | path structure only, never handle-bound |

Components are implied by paths: a client reconstructs the tree by splitting
`device:inv.battery.voltage`, and there are no container frames for components. This mirrors the
substrate exactly, since `Component` has no identity to bind while `Device` and `Element` do.

Addresses and patterns share one grammar:

```
address  := ns ':' name ( '.' segment )*
ns       := ident | '=' ident | '*'      ; '=' = exact type, no descendants
name     := ident | glob
segment  := ident | glob
glob     := '*' | '**' | ident-with-'*'
```

`*` matches one segment, `**` zero or more. The object mirror's `[=]<type>:<name>` is this grammar
with zero segments.

### Verbs

- **`model_sub {seq, patterns[], once?, from?, to?}`** is the read surface. It is list-valued and
  every read is a subscription: `once` closes it after the initial burst (a get), `from`/`to`
  bound a history window, and without `once` the patterns stay armed as a live feed. Reply order
  is `type` for unseen schema, `add` per match not yet bound, `val` payloads, then `res {seq}`
  closes the initial burst; under a `from` window the `add` binds without a value, chronological
  backfill follows, and the latest value closes the burst. A live pattern is the creation
  notification: a node created later that matches receives its `add` when it appears. Overlapping
  patterns arm a node once; a node carries one handle and one feed, and re-arming never rewinds its
  cursor.
- **`type`** has two forms, push-only and deduped per session: a format under an `ft` (type,
  count, series kind, unit, rate) and a named dictionary (enum or bitfield members). Formats with
  no wire representation, the same verdict `ows.container_serialisable` gives, are skipped from
  the surface with a log.
- **`add {h, path, class, ft, peer?, v?, t?}`** binds a handle to a path, announces existence,
  cites schema and carries the current value and timestamp, all in one frame. `class` is `device`
  or `element`; `peer` is the hexadecimal owner of a peer-local device and is omitted for the
  global namespace.
- **`val {h, s:[[t,v],...], lost?}`** is the feed, deliberately dumb: it is nearly all the bytes on
  a mature link and every field multiplies by sample count. `lost` reports overrun rather than
  hiding it, the difference between a mirror that is wrong and one that knows where. There is no
  staleness field: staleness is the absence of frames, and `t` plus a disciplined clock lets the
  receiver compute age itself. `val_block` carries a record block for history and backfill.
- **`model_set {seq, h|path, value}` or `{seq, h|path, reset:true}`** writes an element. The path
  form serves one-shot writers with no binding. `reset` carries no value, because null is a
  legitimate value here, and the receiver never infers the post-reset value: `res {seq, value}`
  carries the authority's applied value, and every other consequence flows back through the feed.

Feeds emit at the end of a commit scope, never per write, so a subscriber always sees a fully
applied frame. Peers ride the per-tick dirty sweep with a pending set drained each tick; pinned
element cursors are reserved for `from` subscriptions that need gap-free replay, since an element
holds at most sixteen pinned cursors.

A `model_set` arriving at a mirror is forwarded to the peer that advertised write access, and the
ack reflects that peer's applied value, not the mirror's optimistic one.

**`history_req {seq, path, from, to, max_points}`** is the one-shot history query, answered by
`history {seq, path, samples:[[t,v],...]}`. It predates the model plane and is the one verb that
still addresses an element by bare dotted path rather than by handle or pattern; `max_points` is
capped at 2000 so a reply fits one packet. A `model_sub` with a `from`/`to` window is the same query
through the handle-bound surface.

## Console, logs and time

The **console** plane runs a remote session: `cmd` carries a line, `result` and `error` its
outcome, `suggest {seq, text}` is answered by `suggestions {seq, complete, suggestions[]}` for
remote tab completion, and the `console_session` capability adds a `console` frame carrying
session events (open, input, output, terminal geometry, close) for a full interactive terminal
over the channel. `/sync console peer=` opens one from the local console.

The **log** plane is a tap: `log_sub` arms it and `log` frames carry lines (`/sync log-sub` from
the console). A peering claim arms log delegation on the authority side so a fleet's logs converge
on its authority, re-armed by each claim rather than by the session so it survives a member
rebooting under a fresh session. Reinjected lines are split-horizon by source so a tap never
echoes.

The **time** plane disciplines clocks. `time_req`/`time_resp` is the pull; `time_push` is a delta
from a node's time authority, and it rides the control plane because a lost delta corrupts every
timestamp the subordinate collects until the next push. The authority is either the peer marked
`time-authority=yes` or, under peering, the member's first claimant.

## Verb index

| capability | verbs |
| --- | --- |
| session | `hello`, `res`, `err`, `claim` |
| `objects` | `add_name`, `bind`, `unbind`, `create`, `destroy`, `state`, `set`, `reset`, `enum_req`, `enum`, `sub`, `unsub` |
| `model` | `model_sub`, `type`, `add`, `val`, `val_block`, `model_set` |
| `history` | `history_req`, `history` |
| `console` | `cmd`, `result`, `error`, `suggest`, `suggestions` |
| `console_session` | `console` |
| `logs` | `log_sub`, `log` |
| `time` | `time_req`, `time_resp`, `time_push` |

## The reliability sublayer

A session on a link that does not advertise both `reliable` and `ordered` (`InterfaceCaps`) arms a
sublayer on the peer. Both ends decide from their own link, so arming is symmetric by
construction; WebSocket, CPC and shared memory skip it, UDP always arms it. Reliability state is
per remote, which is why it lives on the peer and not the transport: on a shared multi-drop link
only the peer knows its remote.

Armed, every frame carries `[src_session:4][dst_session:4][kind:1]`. Two planes ride it:

- **Control** (registry, bind, create/destroy, set/reset, cmd/result, subscriptions, type/add,
  res/err, claim, time_push) adds `[seq][ack]`, is retransmitted on timeout (250ms doubling, 8
  tries, then the session restarts) until the piggybacked cumulative ack covers it, and delivers
  strictly in order through a small reorder hold. The window is 64 frames, with 16 held back from
  bulk walks so the session's other control frames always find room.
- **Data** (`val`, `log`) is reliable but lazy: no retransmit timer and no urgency, but nothing is
  willingly lost. Each queue has its own id space and a backlog (32 frames, 1 KiB), every data
  frame refolds the entire unacked backlog, and the receiver's per-queue watermark dedups replays
  while keeping application in order. A record the receiver cannot apply yet, a `val` racing its
  `add` through the control plane, is left unacked so the refold resupplies it until the `add`
  lands; because handles are announced ascending over the in-order control plane, a `val` citing
  a handle below the announced high-water mark that still does not resolve is dead and skipped as
  declared loss rather than stalling the queue. A bare ack carrying every watermark goes out on the
  next tick when no reverse traffic piggybacks it (300ms flush).

Bounded retention means eviction is possible, and eviction breaks the catch-up promise, so it is
declared, not silent: the queue's epoch bumps once per repair cycle, acks are epoch-qualified, and
the receiver re-bases its watermark under a newer epoch's refold. A bump is durable, announced by
an empty frame until acked, so however long a partition lasts the epoch stays within one of the
receiver. Once the cycle closes the gap is repaired above the sublayer: a `val` bump re-pushes the
latest value of every armed live node, and a `log` bump emits a lost-lines marker.

Session ids echo rather than "new id wins": a frame is honoured only when its `dst` matches the
receiver's live session, so stragglers from a dead session can neither deliver nor ack. Adopting a
genuinely new `src` restarts the peer, since the remote rebooted and the whole session space must
rebuild, and the freshly restarted side re-adopts from zero without restarting again, so mutual
restart cannot ping-pong. A member that re-dials is recognised by node-id at `hello`, and the older
dynamic peer is disabled rather than accumulating a session per source address.

Control transmit is accepted-means-enqueued: a control frame is only lost if the peer is genuinely
dead, at which point the session restarts and resyncs from `hello`.

## The link contract

`SyncPeer.transport` is any interface delivering raw frames; the encoder calls `transmit_frame` and
never sees the link. A link adapter provides:

1. **Frame delimiting.** One protocol frame per packet. Datagrams get this free; byte streams need
   framing.
2. **Integrity.** Corrupt frames are dropped at the link, never delivered.
3. **Ordered, reliable delivery for the control plane**, or an honest `InterfaceCaps` so the peer
   supplies it.
4. **Best effort is acceptable for the data plane.** Lost values self-heal: latest-value elements
   on the next update, history by backfill from the series cursor. Retransmitting stale telemetry
   is worse than re-reading it.
5. **MTU**, advertised via `hello.max_frame`.
6. **Channels**, where a link carries more than sync: datagram links use distinct ports; point
   streams will use CPC endpoints; RS485 will use an envelope channel byte.

| link | framing | integrity | reliability | status |
| --- | --- | --- | --- | --- |
| UDP unicast (IP or bare MAC) | datagram | UDP checksum | sublayer above | built |
| WebSocket | message | TCP | inherent | built |
| shared-memory ring (BL808 M0/D0) | length prefix | memory | inherent | designed |
| UART / RS232 / SPI point link | CPC | CPC CRC | CPC retransmit | designed |
| RS485 multi-drop | Modbus RTU envelope | CRC16 | poll/response | designed |
| UDP multicast feed | datagram | UDP checksum | gap-detect, unicast backfill | designed |

## Direction

Settled design that is not built, tracked in [TODO.md](../TODO.md) under *Sync and peering*:

- **The rest of the read surface.** `meta`/`depth` structure browsing so `sub {patterns:["*:"],
  once, meta, depth:0}` is namespace enumeration; `rate`, `deadband` and `mode` (`latest` coalesces
  per flush, `all` is forced for events), with tightest-wins when patterns overlap.
- **`move` and `gone`.** Rename or reparent with the handle surviving, because EIDs are
  rename-stable; a device `move` implies a subtree prefix rewrite in O(1). `gone` is terminal, and
  handles are never reused, so there is no ABA hazard.
- **Events and methods.** An event is an element whose series kind is `point`: no retained value,
  no coalescing, replay via `from` through the same store. A method occupies an element index with
  a signature as its schema and is invoked by `call {seq, h|path, args}`; latent commands answer
  late, `cancel` is reserved.
- **Convergence.** The object mirror dissolves into the model plane: `add_name`/`bind`/`unbind`
  become `add`/`sub`/`unsub` on object subtrees, property `set` becomes `set` on projected
  elements, `reset` becomes `set {reset:true}`, `state` a built-in event node on every object,
  `create`/`destroy` a `call` on collection methods, `enum_req` the push-only `type` form.
  Collections become container nodes whose methods mirror the console's auto-generated commands, so
  the CLI and the wire converge on the same signatures. Gated on property projection in
  `manager/id.d`; the mirror stays wire-compatible while `model` comes up beside it.
- **The sibling transport class.** Peers sharing physical memory (BL808 D0/M0) build from one tree,
  so if the id and format tables live in shared memory, EIDs and format ids are common currency
  and introduction is pure overhead. The design keeps it possible with five rules that cost nothing
  now: never bypass the peer's resolve methods, introduction is a peer policy, interning is a peer
  policy, handles are wide enough for raw EIDs (already `ulong`), and nothing downstream requires
  having seen a name.
- **Backpressure as a channel property.** Producers ask for room and suspend; oversize control
  frames are refused at encode time against `max_frame`; control rides PCP >= ca with DEI=0.
- **The designed transports** in the table above, and `stream=` on `/sync/peer` materialising the
  CPC stack over a byte stream. RS485 is settled: the envelope is a valid Modbus RTU frame with a
  user-space function code so coexistence with foreign slaves is by construction, the master's poll
  is the token, and the adapter lives under the same scheduler as the Modbus master on that port.
  Multicast needs a publisher-owned handle namespace, a third session shape beside foreign and
  sibling: receivers adopt only, gaps are detected by datagram seq and repaired by unicast backfill,
  never by acks on the group.
