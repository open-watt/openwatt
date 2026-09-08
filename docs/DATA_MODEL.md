# Data model

OpenWatt represents a site as a curated tree of devices, components and elements, and every
element carries a typed, timestamped series. This document is the shape of that model and the
rules that keep it sharp: the three delivery planes and why only one of them is a series, the
series contract, identity, vocabulary, the decision rules that place a thing in the model or keep
it out, and the surface grid every published thing decomposes into. Detail lives beside it:
identity is canonical in the header of [src/manager/id.d](../src/manager/id.d), the series contract
in [src/manager/series.d](../src/manager/series.d), block residency in
[SERIES_RESIDENCY.draft.md](SERIES_RESIDENCY.draft.md), property projection in
[PROP_ELEMENTS.draft.md](PROP_ELEMENTS.draft.md), recording intent in
[wip/RETENTION.draft.md](wip/RETENTION.draft.md), taps in
[TAPS_AND_TUNNELS.draft.md](TAPS_AND_TUNNELS.draft.md), the wire in [SYNC.md](SYNC.md), the
component vocabulary in [COMPONENT_TEMPLATES.md](COMPONENT_TEMPLATES.md) and the profile grammar in
[PROFILE_FILE_FORMAT.md](PROFILE_FILE_FORMAT.md).

## Planes

OpenWatt moves data under three deliberately different delivery contracts. They are not
unifiable, because each plane's defining guarantee is a non-goal of the others:

- **Byte plane** (`Stream`): lossless, ordered, flow-controlled, one destructive reader, no
  timebase. A gap is corruption. Conveyance.
- **Packet plane** (`BaseInterface`): addressed, routed, prioritised and droppable (queue policy
  is traffic engineering), multi-consumer by filter. Transit; a packet is *for* someone.
- **Series plane** (`Element`): timestamped, replayable, multi-subscriber, lossy-honest (a gap is
  first-class truth), and deliberately without upstream flow control: a slow consumer never
  backpressures a producer. Record; a record is *from* something.

The unification is one level up. No plane *is* a series, but every plane is *observable as* one:
a tap observes a byte stream as records, pcap observes packet transit, a waveform tap observes a
capture, property projection observes object state. The series contract lives in one module with
many hosts; Element is the first, and the recorder's containers and the taps host the same formats
without becoming elements. Observation demands nothing of its subject: the data model is the
universal witness, not the universal substrate.

Chains span planes: 433 MHz OOK is waveform to packets to elements. The seams are owned: an
interface crosses waveform or bytes to packets; a binding crosses packets to elements.

## The element series

Every element carries a series of typed, timestamped records. `Variant` survives only as boxing at
the edges (console, SNMP, expressions); storage and delivery are typed end to end.

### Format

`DataFormat` holds what every record in a series shares: value type, count, unit, names, clock,
rate and an optional constraint. One shared immutable instance exists per declared format (a
`Prop!` declaration, a profile template, a collector's static format) and elements point at it,
never own one. `box_record` combines record bytes with their format to make a self-describing
`Variant` at the edge.

A value is an **atom times an extent**. Atoms are the machine scalars (`bool`, `u8` to `s64`,
`f32`, `f64`), `char`, and `user`: a type registered in `urt.typereg`, identified through the
format's descriptor slot, which is the same slot that carries an enum or bitfield dictionary. The
extent is `count`: one for a scalar, N for a fixed vector, zero for a dynamic record. A string is
dynamic `char`; a blob is dynamic `u8` with opaque display. Registered types are what make an IP
address in Modbus registers, or any other structured value, a first-class element value: one
definition site buys text parsing, register decoding, storage, printing, JSON and the container.
Overlay metadata (unit, dictionary, type details) rides the format, never the record.

`Constraint` (min, max, step) rides the format too, nullable and shared, and gates the write path
only. Observations are never validated or clamped: a measurement is truth even when out of spec.

**Series kind** says what a record means. `held`: the value changed, equal repeats are deduplicated,
the series is a run-length encoding of state. `sampled`: an observation of a continuous quantity,
every observation delivers. `point`: an occurrence, nothing in between, never deduplicated.

**Rate and clock** are orthogonal. Rate zero is irregular, with a timestamp per record; otherwise
time is index over rate and the series stores no time at all. Clock null means wall-clock
timestamps. A regular capture series instead counts ticks in a `ClockDomain`, because stamping wall
time at write bakes in IRQ jitter and NTP steps; the collector records `ClockAnchor` pairs (tick,
observed wall time) and conversion happens at read. Series align exactly across each other only
within one domain, so correlated quantities such as voltage and current belong in one
multi-channel series. Irregular series may also be domain-clocked: an edge capture's pulse widths
must survive an NTP step.

### Storage

Records live in **buckets**: a dense sample buffer, a parallel timestamp array only when the series
is irregular, and a byte heap for dynamic records, where a record is a `u16` offset to a
length-prefixed value, 2-aligned and deduplicated within the bucket. The record plane stays
fixed-stride and the image is context-free, so a bucket in RAM and a block on disk are byte
identical. A gap forces a bucket boundary, so within a bucket the timeline is continuous and a
regular series stores zero bytes of time. The bucket directory carries first and last time and
first index, so time-seek and index-seek are both binary searches over one array.

`RecordBlock` is storage and delivery in one shape: the block an observer receives, the block a
cursor returns and the bucket's memory layout are the same `{format, data, times|null, t0,
first_index, count}`. Readback is slicing, never copying; blocks never span buckets; a null
`times` is the regular/irregular discriminator.

A bucket is append-only and only the tail is written, so its life is a state machine: **open**
(the tail, writable), **sealed** (immutable, shrunk to fit), **packed** (encoded through a
registered `SeriesCodec`, which fires when the last reader of a sealed bucket releases it), and
**flushed** or **evicted** (in the container, or dropped). A late cursor reaching a packed bucket
reconstitutes a shared raw side and drops it again when done, so the hot path never decodes.
Residency is the axis retention works along: RAM and disk are two residencies of one block chain,
not two tiers of a series (see [SERIES_RESIDENCY.draft.md](SERIES_RESIDENCY.draft.md)).

The **container** (`.ows`) is a raw-image block list: each block carries next and prev offsets and
its index and time span, the first block of a format run carries the format header, and a flush
appends one sealed bucket's image as one block, a straight write. Opening a container adopts every
block into the store as a fully evicted bucket, headers only, so a cursor opened at index zero
walks all recorded history through the same reconstitute path that serves a packed block. The
container is one file per series, keyed by name; ids never persist. Record counters, not rates:
counter deltas are gap-proof, rates derive at query time, and a restart reset is a timeline event.

### Delivery

Two styles over one storage. **Subscribers** receive `SampleUpdate` callbacks per update, a record
batch or a boxed value, with timeline events riding the same shape and `who` for echo-break. A
commit scope (`begin_commit`/`end_commit`, or the RAII `open_commit`) defers delivery only: writes
apply immediately and deliver when the outermost scope closes, so a subscriber always runs against
a fully applied frame; dependent expressions re-evaluate idempotently and held dedup absorbs the
repeats. **Cursors** are polled readers with a position and a dirty bit, and backfill-then-tail is
inherent: open a cursor at any index, drain to head, and the dirty bit says there is more. An
element enqueues itself on a global dirty list on first dirtying, and sweepers (the recorder, sync)
drain it at their own cadence.

### Retention

Retention is per element and profile-defaulted. `none` keeps the latest value and the subscribers
and nothing else; it is the dominant case once properties project, and costs exactly the element
core. Otherwise buckets are held under record-count and age floors and ceilings and a byte budget,
and budgets win: a cursor lapped by eviction takes a `records_lost` gap, marked at the drop site,
so the reader knows where it is wrong rather than being wrong silently. Which elements record to
disk, and under what intent, is the subject of [wip/RETENTION.draft.md](wip/RETENTION.draft.md).

## Identity

Names are the only durable identity. Ids are permanent, monotonic, process-local handles, two-level
(container id, element index), issued by tables, bound to things, reserved for names, forwarded on
merges and updated to the terminal slot during dereference. There is no rekey machinery. Ids never
persist and never travel: the container and the wire carry names, and a session binds handles once
(see [SYNC.md](SYNC.md)). A device rename is O(1); full element paths are never stored. Property
projections compute their EID as (object CID, `Prop!` index). The full scheme is the header of
[src/manager/id.d](../src/manager/id.d).

## Vocabulary

- **element**: a named point in the device tree, not field equipment.
- **series**: the element's typed record stream.
- **binding**: produces into (read) or consumes from (write, sink) elements, and is
  device-shaped: the class is generic protocol or hardware machinery, the instance models one
  piece of equipment, and naming that equipment (`device=`) is what makes it a binding. Samplers
  and collectors are bindings under exactly this rule: a GPIO edge-capture instance bound to a
  433 MHz radio models an RF sensor precisely as a weather station is a sensor. Write bindings are
  the sink story; pacing and jitter buffers live in the sink, drops surface as gaps, and there is
  no upstream flow control.
- **alias**: a format-strict dumb wire between elements. Wires do not compute; mismatched formats
  are a validation error. Rated series demand an exclusive producer; held series tolerate
  last-wins.
- **operator**: a series transform node, the DSP slot. Today's `Map`, `Sum` and `Alias`
  computations are its founding members (alias is a wire, expression a stateless map, accumulator
  an integrator). Node state is stateless, transient or integrating, and integrating state
  persists.
- **recorder**, **container**: the at-rest form of any series.
- **tap**: an infrastructure capture (raw waveform, byte log, pcap), direct to a container or a
  live session, never an element.
- **trigger**: automation keeps the word signal; nothing is renamed.

## Decision rules

1. Addressed datagrams from independent talkers are the packet plane: an interface plus
   per-device event bindings. Continuous measurement is a series. A 433 MHz receiver is an
   interface (codes are addresses, remotes are the devices, the station table is learning); the
   analogue front end is a binding.
2. Hardware that carries other things' data is a port plus an interface, never a device. Things
   that *are* data get devices. One physical object may hold both roles through separate doors.
3. The device tree is a curated representation of the site. Object runtime state stays in
   `BaseObject` properties. Infrastructure captures are taps.
4. Named versus anonymous: if any generic consumer (recorder, sync, scope, automation) will touch
   it, it gets a name in the tree; if only its owner touches it, it is not an element at all.
5. A series belongs to the device whose observation it is.
6. Element versus function: if reading it back is meaningful it is an element (a setpoint); if it
   is an occurrence you cause it is a function (reset, identify, start).
7. Events are control-rate occurrences; data-rate content belongs to its plane.
8. Tunnel frames, not edges: timing-sensitive layers (RTU inter-frame gaps, ASH, BLE) run near
   the hardware, and packets and elements tunnel.

## The surface grid

Every published surface decomposes into attributes, commands and events, at two schema layers:

| | attributes | commands | events |
| --- | --- | --- | --- |
| runtime objects (compile-time schema) | `Prop!` | console commands | `Event!` (direction) |
| devices (load-time schema, profiles) | elements | functions (direction) | point series |

`Prop!` is a hard-coded profile: both are schemas declaring an observable surface over a
substrate, differing only in binding time. Every `Prop!` is therefore semantically an element
(subscribe, record, trigger) and physically lazy, materialised on first name resolve under the
object's collection path; `mark_set` stays the producer signal and the frame flush samples dirty
projected getters. Projection is partially built; [PROP_ELEMENTS.draft.md](PROP_ELEMENTS.draft.md)
carries what exists and what remains.

The type registry is the one table behind `DataFormat`, the samplers and `Variant`: a registered
type carries its canonical name (the hash is a process-local accelerator, never on wire or disk),
its size and its hooks, and both the binary and the text profile descriptors resolve against it.
The two description languages stay two; the runtime targets converge on one.

## Direction

Settled design that is not built, tracked in [TODO.md](../TODO.md) under *Data model*:

- **The decimation ladder.** Wall-aligned bucket boundaries make cheap decimation possible: a
  stripe whose span coincides with an aggregation window closes that window at seal, from hot
  data, with no carry state. A level is another series with a compound record (sum and count, not
  mean, because mean does not compose; time-weighted for held numerics with a coverage honesty
  signal; duty and transitions for held bools; count for points) on a fixed rung ladder
  (1s/10s/1min/10min/1h/1d), epoch-aligned so every element's minute level shares one grid. The
  read stack picks the coarsest level with enough points, else reduces raw on the fly; the ladder
  is an accelerator, never a correctness dependency. Realtime and capture series opt out by
  construction.
- **Codec planes.** Columnar compression in the packed stripe: delta or delta-of-delta zigzag
  varint on the time plane, bit-packing, zigzag-delta and XOR-with-previous by value type, with a
  per-plane codec byte and a mandatory raw fallback. The registry and the pack-at-seal lifecycle
  exist; the codecs do not.
- **Container serialisability.** User types and enum identity need name binding in the container
  header, and domain-clocked series need anchor blocks, before they can be flushed.
- **Operators.** Expression maps, accumulators and aliases move out of `Device.Computation` into
  explicit operator objects that consume committed batches and handle gap events, which is what
  stops the accumulator manufacturing energy across an outage.
- **`Event!` and device functions.** The third and fourth cells of the grid: a compile-time payload
  schema published as a trigger source, and profile-declared functions (name, params, result,
  protocol mapping) executed by the binding, async through `CommandState`, name-addressed and
  automation-callable, with provenance and arbitration because actuation needs both.
- **Device as a `BaseObject`.** A device that owns its root component by composition rather than
  inheriting from it. It ends the cast-always-succeeds trap that exists only because `Device` is a
  `Component` across the `extern(C++)` barrier, and gives devices `ObjectRef`, rename, dynamic
  lifetime and `StateSignal.offline` as the home of availability.
- **The mesh.** Ids never travel, so there is no cross-node id coherence problem; reservation plus
  claim is remote presence; series gaps and time-keyed backfill are partition-tolerant collection.
  [SYNC.md](SYNC.md) and [PEERING.md](PEERING.md) are the built part. What remains is config
  authority: desired state at the owner, actual state at the executor, a convergence loop with
  provenance that survives a reboot during partition.
