# Data Model and Observation Fabric (DRAFT)

Status: settled design, implementation begun. Supersedes STREAM_MODEL.draft.md (whose "signal
stream" concept dissolved into the element model during review, 2026-07-14/15). Identity
scheme is canonical in the header of [src/manager/id.d](../src/manager/id.d); this doc covers
everything else.

Implementation status (2026-07-15): [src/manager/element2.d](../src/manager/element2.d) lives
beside Element in both build systems, unit-tested (held dedup, gap-forced bucket boundaries,
cursor backfill+tail across buckets, irregular block append, regular time derivation). First
real producer: the urt GPIO realtime sampler API (gpio-cdev v2 backend; pigpiod detected at
runtime and preferred when present - decided, not yet built) feeding an irregular held bool
series through /binding/gpio (GpioBinding : ProtocolBinding; instance models the sampled
equipment via device=; series is binding-owned until Element2 mounts under Components, then
materialise() hangs it on the device). Hardware sampler APIs live in the urt
driver layer behind capability flags (has_gpio_sampler); bindings stay platform-blind.

## 1. Planes: three transport disciplines, one observation discipline

OpenWatt moves data under three deliberately DIFFERENT delivery contracts. They are not
unifiable because each plane's defining guarantee is a non-goal of the others:

- **Byte plane** (Stream): lossless, ordered, flow-controlled, single destructive reader, no
  timebase. A gap is corruption. Conveyance.
- **Packet plane** (BaseInterface): addressed, routed, prioritized-and-droppable (queue policy
  is traffic engineering), multi-consumer by filter. Transit; a packet is FOR someone.
- **Series plane** (Element): timestamped, replayable, multi-subscriber, lossy-honest (gaps are
  first-class truth), and deliberately WITHOUT upstream flow control (a slow consumer must
  never backpressure a producer). Record; a record is FROM something.

The unification is one level up: **no plane IS a series, but every plane is OBSERVABLE AS
one.** A tap observes a byte stream as records (`set_log_file`); pcap observes packet transit;
a waveform tap observes a capture; property projection observes object state. The series
contract (DataFormat, RecordBlock, timeline events, owsig codec) factors into a shared
module with multiple hosts. Observation demands nothing of its subject; the data model is the
universal witness, not the universal substrate.

Chains may span planes: 433 OOK is waveform -> packets -> elements. The seams are owned:
interface crosses waveform/bytes -> packets; binding crosses packets -> elements.

## 2. Element series

Every element carries a **series**: typed, timestamped records. Variant survives only as
boxing at the edges (console, SNMP, expressions); storage and delivery are native-typed.

**Format descriptor (`DataFormat`)**: `{ ValueType, Semantics, unit (ScaledUnit), rate, clock }`.
The runtime typed-data descriptor that replaces Variant across the plane (named DataFormat, not
SeriesFormat: properties and latest-only elements use it too). One shared immutable instance
per declared shape - a Prop! declaration, a profile template, a collector's static format -
and elements point at it, never own one. `ValueType.variant` is the boxed escape hatch for
exotic values (fixed-stride inline Variant records).

**Validation rides the descriptor**: `DataFormat.constraint` (nullable, shared immutable like
the format itself, so it costs nothing per element). Declarative typed min/max/step is the
preferred form - machine-readable, so the UI clamps before submit and the API exports schema -
with a function pointer as the escape hatch for rules data can't express (code validators
supplied against Prop!s). Constraints gate WRITES (setpoints, config, sink elements, /element
set, mesh writes); observations are NEVER validated or clamped - a measurement is truth even
when out of spec. Enforcement wires into the write/sink path when it lands.
- Semantics: **held** (value changes; dedup; RLE of state), **sampled** (observations of a
  continuous quantity; every observation delivers), **point** (occurrences; no between; never
  deduped).
- rate: 0 = irregular (explicit timestamps), else regular (time = index/rate; no time storage).
- clock: orthogonal to rate. null = wall-native. Regular capture series are INDEX-NATIVE in a
  ClockDomain (never stamp wall time into data at write: bakes in IRQ jitter and NTP steps);
  collectors record ClockAnchor (index, observed SysTime) pairs; conversion is query-time.
  Exact cross-series alignment iff same domain; correlated quantities (V/I) go in ONE
  multi-channel series. Irregular series may also be domain-clocked (edge captures: pulse
  widths must survive NTP steps).

**Storage**: buckets. A bucket is a dense sample buffer (+ parallel timestamp array iff
irregular). Gap forces a bucket boundary (`follows_gap`), so within a bucket the timeline is
continuous and regular series store zero bytes of time. The bucket directory carries
first/last time AND first index: time-seek and index-seek are binary searches over one array.
Strings/structured values: variable-stride behind a format flag; the numeric 95% never pays.

**RecordBlock is storage AND delivery**: the block an observer receives, the block a cursor
returns, and the bucket's memory layout are one shape ({format*, data*, times*|null, t0,
first_index, count}). Readback is slicing, never copying; times==null doubles as the
regular/irregular discriminator; blocks never span buckets.

**Element2 layout: the retention plan is the struct's shape.** The core is <= 48 bytes
(static-asserted): `{ const(DataFormat)* format, Scalar latest, SysTime last_update,
Subscription* subs, SeriesStore* history, dirty/flags }`. Identity lives outside the struct
(the component tree names device elements; projections compute theirs), the format is shared,
subscriptions are an intrusive list paid for by the subscriber at subscribe time (and are
where per-subscriber deadband state will live), and ALL retention cost - buckets, head,
cursor registry, budgets - sits behind the nullable `history` pointer (`ensure_history()`
opts in). retention=none is the dominant case once properties project, and it costs exactly
the core; the cost gradient matches the consumption gradient at every tier.

**Delivery**: two styles over one storage.
- Synchronous observers: in-order call sequence (records / gap / format-change / offline) with
  `who` echo-break. The call order IS the timeline; no side-channel, no skew.
- Polled cursors: (position, dirty bit). Backfill+tail splice is inherent (open a cursor at
  any index, drain to head, dirty bit signals more). Dirty propagation: element enqueues
  itself on a global list on first dirtying; sweepers (recorder, sync) drain at their cadence.

**Retention tiers** (per element, profile-defaulted): none (latest+observers only; embedded
default), ring (bounded recent), history (buckets under budget, recorder tailing). Eviction:
budgets win; a cursor lapped by eviction takes a records_lost gap (the drop site marks the
loss). Bucket capacity scales with rate (target time-span, not record count).

**Recorder**: a cursor consumer serializing series to owsig containers (one per series, keyed
by NAME; ids never persist). Element history and waveform capture share the container format.
Record counters, not rates: counter deltas are gap-proof, rates derive at query time; restart
resets are timeline events (RRD-style).

**Known work in the draft**: eviction, NOW LIVE-URGENT (an open-squelch 433 receiver at
hundreds-thousands edges/sec grows ~16 B/edge unbounded, tens of MB/hour); clock-orthogonality
in Bucket.times (the GPIO backend sidesteps it for now by requesting CLOCK_REALTIME kernel
stamps); cdev line_seqno gaps must call mark_gap() (drop site marks the loss);
reactor-thread producers defer dispatch to main loop; Cursor holds Element2* pending EID
resolution (the two-part EID TYPE now exists at target shape in manager.id; the tables are
the migration); RAM buckets + on-disk container need one time-keyed, decimation-aware read
stack (index is process-local, TIME is the archival axis). Done since first draft: irregular
block append (observe_block); compact core layout (identity out, format shared, history
behind a pointer, intrusive subscriptions); legacy hash-EID + ElementTable deleted from
element.d (they were unused - a slice of migration step 1 done by removal).

## 3. Identity

Canonical: [src/manager/id.d](../src/manager/id.d) header. Summary: names are the only durable
identity; ids are permanent monotonic process-local handles, two-part
(container id, element part), issued by tables, bound to things, parked on names, forwarded on
merges, self-healed by holders. No rekey machinery of any kind. Ids never persist, never wire:
peers exchange names once per session and bind varint handles (introducer allocates, parity
bit per direction, never reused). Device rename is O(1); full element paths are never
stored/interned. Property projections COMPUTE their EID as (obj CID, Prop! index).

## 4. Vocabulary

- **element**: named point in the device tree (name "Element" kept; it means mount point, not
  "field equipment").
- **series**: the element's typed record stream.
- **binding**: produces into (read) or consumes from (write/sink) elements, and is
  DEVICE-SHAPED: the class is generic protocol/hardware machinery, the INSTANCE models a
  particular piece of equipment - naming that equipment (device=) is what makes it a binding.
  Samplers/collectors are bindings under exactly this rule: a GPIO edge-capture instance
  bound to a 433 radio models an RF sensor precisely as a weather station is a sensor
  (GpioBinding); the AFE publishing waveforms under a metering device likewise. Write-bindings
  are the sink story; pacing/jitter buffers live in the sink; drops surface as gaps; no
  upstream flow control. (The packet-decode deployment of the same radio - an OOK interface
  demuxing remote transmitters into their own devices - is the separate gateway door; both
  may coexist.)
- **alias**: format-strict dumb wire between elements. Wires don't compute; mismatched formats
  are a validation error. Rated series demand an exclusive producer; held tolerate last-wins.
- **operator**: series transform node (the DSP slot). Founding members: today's
  Map/Sum/Alias Computations (alias = wire, expression = stateless map, accumulator =
  integrator). Gap events fix the accumulator's blind integration across outages (it currently
  manufactures energy across comms loss). Node state taxonomy: stateless / transient /
  integrating (persist!). Multi-input at sample rate deferred (needs clock alignment).
- **recorder / container (owsig)**: at-rest form of any series.
- **trigger**: automation keeps the word "signal"; no rename forced.

## 5. Decision rules (minted during review; keep these sharp)

1. Addressed datagrams from independent talkers -> packet plane (an interface + per-device
   event bindings). Continuous measurement -> series. 433 RX is an INTERFACE (codes are
   addresses, remotes are the Devices, station table = learning); the AFE is a binding.
2. Hardware that carries other things' data = port + interface, never a Device. Things that
   ARE data get Devices. One physical object may hold both roles through separate doors.
3. The device tree is a CURATED representation of the site. Object runtime state stays in
   BaseObject properties. Infrastructure captures (raw waveforms, byte logs, pcap) are TAPS:
   direct to container or live session, never elements.
4. Named vs anonymous: if any generic consumer (recorder, sync, scope, automation) will touch
   it, it gets a name in the tree; if only its owner touches it, it is not an Element at all.
5. A series mounts under the device whose observation it is.
6. Element vs function: if reading it back is meaningful, it is an element (setpoints); if it
   is an occurrence you cause, it is a function (reset, identify, start).
7. Events are control-rate occurrences; data-rate content belongs to its plane.
8. Tunnel frames, not edges: timing-sensitive layers (RTU inter-frame gaps, ASH, BLE) run near
   the hardware; packets and elements tunnel.

## 6. The three-facet surface grid

Every published surface decomposes into **attributes / commands / events** (the
Matter/OPC-UA/HA convergence), at two schema layers:

| | attributes | commands | events |
|---|---|---|---|
| runtime objects (compile-time schema) | `Prop!` | console commands | `Event!` (to build) |
| devices (load-time schema = profiles) | elements | functions (to build) | point series |

`Prop!` is a hard-coded profile: both are schemas declaring an observable surface over a
substrate, differing only in binding time. Consequences: Prop! should grow optional unit/desc
fields; profiles' ElementDesc and Prop! reflection should converge on one schema
representation (the todo_rpc_dedupe endpoint).

**Property projection** (settled): every Prop! is SEMANTICALLY an element - subscribe, record,
trigger - but PHYSICALLY lazy: materialized on first name resolve, under the object's
collection path (not /device). mark_set stays the producer signal (hot-path safe); the frame
flush samples dirty projected getters -> observe!T. Coalesced-by-construction, Semantics.held,
native-typed end to end (viable BECAUSE Element2 dropped Variant). Unwatched properties cost
one dirty bit. Non-Prop members remain hard data; composition wiring (delegates between
collaborating objects) remains hard API - the declaration line IS the classification.

**Event! (to design)**: compile-time payload schema, sibling of Prop!; published as trigger
provider sources with typed payloads ($trigger.* is the reserved slot); mesh-shippable behind
schema fingerprints. Undeclared callbacks do not exist outside the process.

**Device functions (to design)**: profiles gain function declarations
(name, ValueDesc params, result, protocol mapping); the binding is the executor (register
recipes, ZCL commands, HTTP requests - mappings stay declarative; logic stays in binding
code). Async via CommandState (progress/cancel). Functions take element parts in the id scheme
(kind bit), so they are name-addressed, reservable, automation-callable from do={}, and
mesh-invocable. Actuation needs provenance (who), stricter access, and arbitration (the energy
propose/dispose pivot is the arbitration story; functions are its addressable target).

## 7. Structural direction: Device becomes a BaseObject (composition)

Not yet committed, but recommended: Device : BaseObject that OWNS its root Component
(HAS-A, not IS-A; the extern(C++)/extern(D) barrier forbids inheritance anyway). Kills the
is_device()/cast-always-succeeds trap (exists only because Device IS-A Component without
dynamic cast). Devices get: ObjectRef, rename via set name=, dynamic|temporary lifetime
(binding-spawned devices = the Tesla-session pattern), Prop! metadata, and StateSignal
offline as the home of device availability (emission point for element gaps). Container level
of the id scheme then simplifies to collection types only. Until committed: devices register
as a non-BaseObject type in the container id space (g_app.devices Map dissolves into it).

## 8. Distributed trajectory (mesh)

Goal: child nodes' devices and capabilities present and operable at aggregators (eventually
peer mesh; aggregator/child is a policy overlay on symmetric machinery).

**Pre-solved by this design**: ids never wire, so there is no cross-node id coherence problem.
Reservation + claim = remote presence (proxies claim node-scoped names; consumers pre-wire and
light up). Prop!-as-schema makes proxies synthesizable; projection's mark_set feed is the
proxy update stream. Series gaps + cursors + time-keyed backfill = partition-tolerant
collection with reconciliation on reconnect (child records through the outage; aggregator
splices). Byte plane tunnels as streams; packet plane tunnels via OW encapsulation (operating
a child's modbus interface = submitting packets to it; the interface serializes all
requesters, so there is one bus master).

**Replicate clients, proxy singletons**: protocol clients rarely need remoting - tunnel the
plane below and instantiate locally. Session-stateful singletons (zigbee coordinator, BLE
sessions) are proxied via the three facets: synced props + RPC verbs + subscribed events.

**The genuinely new subsystem: config authority.** Desired state at the owner, actual state at
the executor, a convergence loop (CAPsMAN/k8s shape). Pushed-down config persists at the
executor with provenance (must survive reboot during partition), owner reasserts on reconnect,
deletions need desired-state tombstones, conflicts resolve by authority tag. Write arbitration
generalizes `who` to node-scoped provenance; split-horizon prevents mirror echo.

**Barriers**: Prop!/Event! schema version skew across mixed-version meshes (fingerprints per
type; operate on the intersection or refuse); node-scoped name syntax must become first-class;
config-plane authn/authz; placement is manual-first (run-at=), automatic placement is a later
optimizer over declared timing constraints.

## 9. Build order (sketch)

(A slice of step 2 was deliberately pulled forward of step 1: Element2 + the GPIO sampler
binding exist as a scaffold to harden the storage/delivery design against a real producer.
The scaffold is binding-owned and touches no identity machinery, so the order below stands.)

1. ID migration (id.d header steps 1-6) - prerequisite for everything.
2. Series contract module (DataFormat/RecordBlock/events/owsig) + Element2 replaces Element.
3. Retention tiers + recorder-as-cursor + container read stack.
4. Operators absorb Map/Sum/Alias (gap-aware accumulator).
5. Property projection; Prop! unit/desc fields.
6. Event! + device functions (profiles grow the third facet).
7. Mesh: session name/handle binding, proxies, config authority.
