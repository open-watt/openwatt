# TODO

Cross-cutting work that needs a design decision or changes more than one module. Point fixes
belong beside the code. When an item lands, delete it or reduce it to the work that remains;
the commit history and linked design documents carry the implementation record.

## Energy

- **Speed up topology publisher binding**: `TopologyPublisher.bind()` repeats
  `find_or_create_element` for every field of every record. A rebuild performs roughly 3000
  dotted-path lookups and takes about 106 ms on the Pi. Reuse bindings whose IDs did not
  change, or give `Component` keyed child and element lookup. The same storm dominates the
  233 ms first energy update after boot, where each creation also allocates a fresh String and
  fans notifications out to sync, websocket and api subscribers; a bulk-bind mode that
  suppresses per-element notification until the batch completes addresses both.

- **Cut the remaining energy update cost**: profile with the existing `log_slow_phase` and
  `log_slow_topology_publish` subdivisions before optimizing. Beyond the publisher storm above:
  debounce topology rebuilds until configuration settles, so early boot stops rebuilding the
  graph every frame; retain production strings per rebuild rather than per sample
  (`rebuild_productions` and `retain_production_string` heap-copy owner/group/port/circuit for
  every contribution, every sample); and intern the name comparisons that still scan strings
  (the `buses` map key, production owner/group/circuit compares, `circuit_in_island`,
  `attribution.terminal_index`, and `is_first_owner_port`, which is quadratic in ports). The
  solver's one-unknown-per-pass rescan is fine at current scale; the work-queue formulation
  removes the quadratic if large sites appear.

- **Upgrade the provenance representation**: the solver carries a flat provenance enum. Replace
  it with a dependency set of seed meters (a small fixed bitset) per solved value, so a value
  inferred from another inferred point stays distinguishable from a direct measurement,
  mismatch and outage reports can name the meters a value stands on, and outage-bridged values
  are distinguishable from never-metered ones. The precedence rule is unchanged: measured
  outranks inferred, boundary-most is authoritative among equals, disagreement beyond the noise
  floor keeps the winner and reports a mismatch, never silently average.

- **Report faults and underdetermined components**: publish, per connected constraint component,
  its closure residual and the identities of its still-free variables. Severity falls out of
  that: a normally-measured boundary degraded to inferred keeps accounting and alerts on the
  transition; multiple dark boundaries in one component lose category detail but keep net flow
  and name the culprits; a residual on a fully-determined circuit is a fault; sink absorption is
  a normal account. Today residuals only publish through the per-bus rogue/coverage fields.
  Never allocate a multi-unknown residual per port.

- **Seed zero through open switchgear**: appliance ports carry contact state (`read_port_closed`),
  but `ports_connected` treats appliances as unconditional junctions and group inference ignores
  per-port state, so an open contactor still exchanges inferred energy. An open port is a known
  zero, not an unknown. Land it with a review of the coverage semantics, since it moves buses
  from dark/bounded to measured and that is account-visible. Latent until something in-tree
  publishes `closed=false` on an appliance port.

- **Supply link loss**: every link/switchgear constraint carries a loss term defaulting to zero,
  so single-unknown group inference manufactures a zero-loss value for conversion appliances.
  Add providers keyed by declared link identity so learned state survives topology rebuilds:
  a configured bound (watts or percent) or resistance, and a learned fit where meters exist at
  both ends (`deltaV * I` is far better conditioned than subtracting two large powers; the
  fitted slope is the run's resistance, the intercept self-calibrates the voltmeter pair, and
  drift in fitted R is a corroding-joint diagnostic). Correct the propagated value and mark
  provenance as standing on a learned parameter.

- **Build transfer switch support**: `PortGroupKind.transfer` exists and asserts TODO. It needs a
  declaration surface (two input ports, one output, A/B/off position from contact feedback or a
  live element), connectivity per position, and acceptance tests. Do not infer position from
  instantaneous power.

- **Tighten underdetermined reporting**: on underdetermined components, use supply/consume-only
  flow domains to publish directional bounds, never a per-port allocation. Per-meter noise
  floors can stay a single constant (50 W / 2 percent of flow scale) until a meter accuracy
  class justifies refining them.

- **Complete session-derived SOC**:

  - persist the active session across OpenWatt restarts;
  - key statically paired VIN-less vehicles by appliance name;
  - keep truly unidentified cars on EVSE-scoped policies, where SOC has no useful identity;
    and
  - feed delivered-energy and SOC-delta samples into the capacity estimator.

- **Synthesize import/export counters for meters without them**: integrate active power into
  persistent per-port accumulators using a monotonic timebase. Publish
  `total_import_active`/`total_export_active` with `Provenance.integrated`, skip stale gaps,
  restart at zero on boot, and exclude these synthetic counters from recording by default.

- **Finish surplus-tracking behavior**:

  - verify the live grid-port sign convention;
  - modulate floor and essential policies from required energy and slack;
  - check cloud-edge churn and add hysteresis beyond quantization/dwell if required; and
  - remove the redundant `pressure_modifier` gate from opportunistic marginal value.

- **Expire stale allocation reasons**: policies omitted from the allocation queue retain their
  last displayed reason. Record an explicit idle/satisfied result each tick, or expire the
  reason elements.

## Tesla TWC

- **Allow satisfied charging to turn fully off**: the vehicle model now carries
  `charging.enabled` (`src/apps/energy/vehicle.d`), but `pick_enable_element`
  (`src/apps/energy/control.d:427`) searches the control component and does not find it. Wire
  the two together. Until then, release bottoms out at 5 A instead of disabling charging.

- **Verify recovery on hardware**: confirm that a slave answers master heartbeats without a
  fresh announce after a link flap. If it does not, explicitly restart the announce ceremony
  when repeated heartbeats go unanswered.

## Tesla vehicle BLE

- **Honor addr_type in Windows BLE connect**: `ble_hw_connect` in urt's Windows driver drops
  its `addr_type` argument; `FromBluetoothAddressAsync` assumes a public address, so connecting
  to the (random-address) vehicle likely only works while Windows has it in its scan cache.
  Switch to `IBluetoothLEDeviceStatics2.FromBluetoothAddressWithBluetoothAddressTypeAsync`.
  Blocked on testing against the car.

## Zigbee latency and robustness

- **Expose scheduling validation metrics**: queue wait by PCP, deadline promotions and
  expiries, queue rejection and DEI eviction counts, reserved-slot dispatches,
  user-command submission-to-completion latency, and reactive receive-to-dispatch latency.

## Automation

The current implementation and remaining phases are described in
[docs/AUTOMATION.md](docs/AUTOMATION.md).

1. **Execution policy**: implement `overrun=skip|queue|restart|coalesce`,
   `catch_up=skip|once|all` with a grace window, and `on_error=ignore|retry|disable`.

2. **Typed trigger context**: replace the lone flat `$value` with a coherent context for
   provider data such as previous value, topic, payload, and timestamp. Decide whether this is
   a `$trigger` object or a set of flat locals before adding the first rich provider.

3. **More signal providers**: add MQTT filtered publishes, Zigbee attribute reports,
   sunrise/sunset with offsets, and HTTP events.

4. **`on=` completion**: add a property completer hook and let each `ISignalProvider` suggest
   bodies and parameter values. Complete the URI scheme from the provider registry.

5. **Event-driven element attachment**: revisit subscriptions when an element is created
   instead of polling `startup()` every frame for a previously missing element.

6. **Re-entrancy and loop protection**: tag automation writes, bound recursive activation,
   and make `/element/set` reject read-only targets instead of silently updating local state.

7. **Deadband trigger parameter**: pass `?deadband=` and its refresh policy through to the
   element subscription described below.

8. **Energy intent surface**: let automations propose and dispose requests on `Control`; keep
   arbitration and ownership of contended outputs in the allocator.

## Data model

- **Complete the unit model**:

  - represent logarithmic reference-relative units such as dBm with explicit conversion and
    arithmetic semantics;
  - distinguish arbitrary counters so unrelated dimensionless counts cannot combine; and
  - settle bit/byte identity and decimal versus binary prefixes (`kB` versus `KiB`).

- **Retire profile compatibility grammar**: normalize the external profile catalogue, then
  remove the two-column unit/enum fallback, access suffixes (`/R`, `/W`, `/RW`), `i*`, glued
  endian spellings, `_r`, and Modbus high/low-byte aliases. Keep
  [docs/PROFILE_FILE_FORMAT.md](docs/PROFILE_FILE_FORMAT.md) and parser tests limited to the
  canonical grammar. Fixed vectors also need codec support when the first wire producer uses
  them; `sample_record()` currently rejects `DataFormat.count != 1`.

- **Settle bitfield profile declarations**: choose whether plain values in `bitfield:` are bit
  indices or masks. If indices win, convert them to masks in the parser, migrate the
  `pace_bms` and `smartevse` declarations after auditing expression/key users, retain
  `1 << n` as an explicit mask form, and warn when a `bf` field references a non-bitfield
  enum.

- **Support multi-protocol device profiles**:

  1. Add an enum remap codec with an invertible write mapping; treat combinable bitfields
     separately.
  2. Add protocol/source filters to templates and elements so one semantic tree can carry
     multiple source descriptions without materialising the wrong protocol's descriptors.
  3. Track source provenance, health, read preference, failover freshness, and write authority
     explicitly. SmartEVSE should prefer MQTT while retaining REST as a fallback.

- **Decide Home Assistant discovery's long-term binding model**: either keep the bespoke
  discovered-element binding or synthesize a runtime profile and use an ordinary MQTT
  binding once MQTT descriptors can carry value and command transforms. A migration must
  preserve the faithful HA element tree, stable hash-keyed enums, explicit-profile topic
  claims, and per-device collision behavior.

- **Give profiles control over retention and recording**: settle element tokens for RAM floors
  and ceilings by record count and age, a no-history option, and a separate disk-recording
  flag. Add inherited component/profile defaults and byte budgets. The recorder should select
  elements by recording intent, not infer disk policy from RAM retention.

- **Finish converging the value path**: `src/manager/sample/` is now the single wire-desc to
  native-record path, but the per-protocol survivors named in the original audit are still
  standing: zigbee's `get_zcl_value`, and HTTP/MQTT's `apply_value` and `format_value`. Audit
  each against the shared descriptor language and either justify it or dissolve it into the
  one module, keeping the encode/decode inverse in a single place. Batching and timing policy
  belong in the same sweep, not just decode.

- **Finish the series operator model**: move expression maps, accumulators, and aliases out of
  `Device.Computation`/`ElementLink` into explicit operator objects beside the sample layer.
  Operators must consume batches against a committed frame, handle gap events, and own any
  transient or integrating state. Move accumulator timing out of `Device.update()`. Once the
  customers are objects, replace the two-pointer `Subscriber` delegate with a one-pointer
  subscriber interface and audit subscription lifetime.

- **Finish series storage and recording**: finish sealed-bucket packing, reuse the packed stripe
  on disk, unify RAM/disk time queries, and add the decimation ladder described in
  [docs/DATA_MODEL.md](docs/DATA_MODEL.md).

- **Bound recorder container growth**: `.ows` files grow without limit. Add a size or age budget
  per series or per recorder, and give the retention classes distinct policies: the short class
  (planner budget, allocation decisions, coverage and mismatch flags) wants days, while island
  `account.*` powers, today counters, per-boundary flow views and battery SOC want months. Today
  the classes are separated by recorder but every recorder retains alike. This is the last thing
  between the current state and leaving recording on indefinitely.

- **Make the container complete**: `ows` v0 cannot flush user types or enum identity (both need
  name binding in the block header) or domain-clocked series (need anchor blocks for the clock), so
  those series stop at RAM. Adoption under live cursors is unresolved (`src/manager/ows.d` header):
  `open_()` rebases the store's buckets and pins behind adopted history, but a `Cursor` holds its
  position by value and cannot be reached, so one opened in the sub-second gap before the recorder
  attaches re-reads adopted history as new, and a pinned sync cursor would re-ship it. Either a
  store-held rebase epoch the cursor applies lazily, or cursors holding store-side positions only.
  The columnar codec planes (time-plane delta varint, value-plane bit-pack, zigzag-delta and XOR,
  per-plane codec byte with raw fallback) are designed against the existing `SeriesCodec` registry
  and not written.

- **Defer reactor-thread producers to the main loop**: a producer writing from a reactor thread
  must not dispatch observers or mark dirty inline (`src/manager/element.d:1261`); queue the
  dispatch and drain it on the main loop.

- **Make recorder shutdown lossless**:

  - `/system/reboot` must seal every active bucket and wait for every `HistoryBlock` to become
    durable. Never abandon unwritten history on a deadline; keep the watchdog active, report
    worker progress, and cancel the reboot or keep retrying if storage cannot complete.
  - route SIGTERM and SIGINT through the same main-thread shutdown using an
    async-signal-safe wake;
  - add a preallocated fatal-crash path that sends each non-durable bucket's committed prefix
    to the I/O worker without allocations, locks, or callback maps, waits with a bounded
    worker-liveness check, then resumes normal crash handling; and
  - define the disk durability boundary and batch `fsync` in the I/O owner. `pwrite`
    completion alone does not cover power loss.

- **Finish the other device facets**: add lazy property projection, typed events, and device
  functions using `DataFormat`; replace the `Device`/`BaseObject` type trap with composition.
  Keep identity, values, events, and functions addressable without turning the data model into
  a transport.

- **Add device logic to profiles**: define named actions whose payloads are evaluated from
  current device state, plus device-scoped `on`/`if`/`do` scripts for writes, toggles, rolling
  counters, and receive-to-state updates. Reuse the expression and automation machinery, but
  define a bounded device execution context and protocol-owned action primitives. The first
  customer is the RF433 fan profile and waveform transmitter.

- **Implement element deadband with a maximum refresh interval**: deadband belongs to each
  subscription, with its own last-delivered anchor. Element metadata supplies the default and
  subscribers may override it; `Element.latest` always remains exact. Deliver current truth
  when the absolute movement crosses the band or `refresh=<duration>` expires, then re-anchor.
  Non-numeric values ignore the band. Recorder and automation subscriptions must use the same
  mechanism. A later optional EMA decision signal may reduce alternating boundary bias without
  replacing the delivered value.

- **Recorder durable-holder cutover**: `RecordStream` (`src/manager/record.d`) keys its intake off
  a raw `Element*` plus a transient pinned `Cursor`, so a destroyed-and-recreated element leaves the
  stream dangling. Move it onto the durable `EID` (deref-and-heal). This already landed on the
  `sample-transactions` line, where the recorder reads via `eid.deref`; it rides in when that work
  rebases on top. Fold the remaining `ElementCursor` decision into that cutover:

  - `ElementCursor.next()` (`src/manager/element.d`) reuses a cursor bit claimed on the *previous*
    element after an EID heal, so it null-derefs a fresh series or corrupts another cursor's pin.
    Either make it re-register on the resolved element, or delete it in favour of the bare-EID
    approach the recorder already took.
  - `open_series_cursor` aborts with `assert(false, "out of cursors")` on the 17th concurrent
    cursor; return an invalid cursor instead of aborting in release.

- **Element.value() drops unconvertible values silently**: `value()` discards
  `update_typed_series`'s failure, so a value that cannot unbox to the element's format (wrong
  dimension, overflow, non-string to a text element) vanishes with no log and no caller feedback.
  Decide whether to return the status, warn (rate-limited; this is on every write), or keep it
  silent by design. As written it hides bring-up bugs.

## Sync and peering

The built surface is documented in [docs/SYNC.md](docs/SYNC.md) and [docs/PEERING.md](docs/PEERING.md);
this is what remains.

- **Elect an active authority**: two authorities of one cluster already share a member (each holds
  its own session), but nothing elects between them. Build the authority-to-authority session
  carrying membership view, epoch and liveness, elect by `priority` then node-id, and have members
  follow the elected-active for time discipline and routine control instead of the first claimant
  (`src/manager/sync/peering.d:410`). That session carries coordination only, never fleet state, so
  the A-B-member triangle never becomes a sync loop. `/sync/peering print` should show the
  membership delta under partition.

- **Rank links properly and fail over without a restart**: `discovery.d:137` still prefers by link
  speed then recency. The intended order is operator cost override, then link class (ethernet,
  wifi, 15.4, RS485), then speed, then recency. Collect RTT per link from any acked exchange
  (Karn-filtered) to drive the retransmit clock and to demote a degrading active link against its
  own baseline. Seamless failover, where a session addresses the node-id and late-binds its path
  per send, is the full L3 move and lands with the election. Beacons stay link-local; reachability
  through the fabric is a separate propagation mechanism.

- **Make backpressure a channel property**: `#557` paces one producer and every send reports
  pass/fail, but that is detection, not backpressure. Every other control emitter still bursts into
  the 64-frame window (`model_sub`/`sub` fan-out, lifecycle fan-out, `result`, `history`) and a
  refused send aborts a burst with work left. Producers must be able to ask for room and
  suspend/resume; oversize control frames must be refused at encode time against `hello.max_frame`
  rather than dropped in the interface; `val_block` chunking must honour `max_frame` instead of a
  fixed 256 records; and control frames should ride PCP >= ca with DEI=0 on the underlying packets.

- **Harden clock discipline**: gate member sampling, recording and shipping on wall time (an ESP32
  ships 1970-stamped samples until its first pull), carry a synced flag in `hello`, add a
  minimum-delta threshold so steady-state polls do not step, and make `adjust_utc_time` step the OS
  clock on Posix (today it rewrites the current time, so a chained authority drops pushes and
  forwards them). NTP versus peer discipline needs an owner.

- **Make the full mirror a claim policy**: a claim today arms the log tap and time discipline, not
  the member's device tree. Landing `device:**` as claim policy needs node-scoped naming for remote
  devices (flat `g_app.devices` collides on `energy`/`system`; a colliding `add_name` adopts onto
  the local CID), offline/gone on detach (remote devices persist forever with stale values), a paced
  `model_sub` burst, one quiet skip per unknown type per session, and write routing to the authority;
  until that lands a console `set` on a proxy diverges it silently.

- **Finish the model plane**: `model_sub` takes patterns, `once` and a `from`/`to` window, nothing
  else. Still to build: `meta`/`depth` structure browsing, `rate`/`deadband`/`mode` (tightest wins
  when patterns overlap), `move` and `gone`, `call` with the signature form of `type` (lands with
  the first callable node; `cancel` reserved), constraint min/max/step on the format block together
  with element-write enforcement, echo suppression for `set` writers via `SampleUpdate.who`,
  pinned-cursor paced backfill (backfill serves synchronously inside the burst today), and an
  element lifecycle hook that carries the element. Formats failing `ows.container_serialisable` are
  skipped with a log rather than answered `err`, because per-node errors inside a glob burst are
  unresolved. Confirm `device` is registered as a namespace in `g_app.types`.

- **Converge the object mirror into the model plane**: `add_name`/`bind`/`unbind` become
  `add`/`sub`/`unsub` on object subtrees, property `set` becomes `set` on projected elements,
  `reset` becomes `set {reset:true}`, `state` a built-in event node, `create`/`destroy` a `call` on
  collection methods, `enum_req` the push-only `type` form. Gated on property projection in
  `id.d`. Keep the sibling transport class buildable on the way: handles are already `ulong`, but
  `IdAllocator` and `g_formats` allocate through `defaultAllocator`, so shared-memory residency
  needs a writer/reader ownership rule before the BL808 M0/D0 ring exists.

- **Build the remaining transports**: the shared-memory ring for BL808 M0/D0 (sibling class,
  length-prefixed SPSC rings, ring-full is queue-and-wait), a `CPCEndpoint` transport for UART/SPI
  point links (I2C deferred until a data-ready GPIO exists), the RS485 multi-drop envelope (valid
  Modbus RTU frames with a user-space function code, token is the poll, one scheduler shared with
  the Modbus master, per-slave baud as addressing metadata from day one), and one-way multicast
  feeds (publisher-owned handle namespace, gap detection by datagram seq, unicast backfill, never
  acks on the group). `stream=` on `/sync/peer` materialising the CPC stack, and `remote=` URI
  schemes beyond UDP, arrive with those. RS485 slave-to-slave goes through the master first;
  multicast groups are configured before derived.

- **Take the fleet to micros and to the box**: `conf/fleet.id` and `conf/node.id` need an NVS
  backing where there is no filesystem (`peering.d:595`). Out-of-box onboarding is unbuilt: SoftAP
  provisioning serving the existing HTTP config surface is nearly free, BLE provisioning needs the
  peripheral role the stack does not have. An approval mode where the neighbour table is the
  "waiting for adoption" list is authority policy, not protocol. A member preferring its previous
  claimant on reconnect is cheap and undecided.

- **Build config authority**: the mesh's genuinely new subsystem. Desired state at the owner,
  actual state at the executor, and a convergence loop between them: pushed-down config persists
  at the executor with provenance so it survives a reboot during partition, the owner reasserts on
  reconnect, deletions need desired-state tombstones, and conflicts resolve by authority tag. Write
  arbitration generalises `who` to node-scoped provenance. Barriers to clear first: `Prop!`/`Event!`
  schema fingerprints across mixed-version fleets, first-class node-scoped name syntax, and
  config-plane authn/authz.

- **Log sync residue**: render origin hostname and producer timestamp in the text sink, and cap the
  severity a remote can raise on ingress (both left from `#582`). Parked with owners elsewhere: a
  module-level sync test harness (the reliable sublayer and decoder are unit-testable in isolation),
  an allocation-flag placement API for `Array`/`MutableString`, and pool-backed packet buffers
  (`#518`).

## Infrastructure

- **Harden bindings against malformed remote input**: the `ow/dm` review found protocol
  bindings that abort or deref on data an attacker controls, and these survive. ESPHome still
  carries `assert(false, "what here?")` on `proto_deserialise` length mismatch
  (`src/protocol/esphome/client.d`), which is a remote abort on a malformed frame. MQTT's
  `desc_by_index(mqtt.desc)` (`src/protocol/mqtt/binding.d:216`) has no `desc == ushort.max`
  check. `ows.load` still reads `first_index`/`last_index`/`stride` off disk unvalidated
  (`src/manager/ows.d:59`), so a corrupt or hostile container is trusted. External state
  rejects, it does not assert.

- **Close the descriptor grammar gaps**: `strN` widths parse but are ignored entirely, so any
  `N` compiles unvalidated while the span comes from the register map
  (`src/manager/sample/spec.d`). Integer text records no longer accept exponent notation
  (`"1e3"` parsed on the old `Quantity!long` path and now fails), which is a silent behaviour
  regression for profiles that used it. `sample_record`'s integer case asserts `pre_scale == 1`
  while the encode side accepts it (`src/manager/sample/package.d:154`), breaking the
  encode/decode symmetry. Confirm each is intended before closing.

- **Settle the remaining binding asymmetries**: Tesla's `materialise` fires
  `notify_element_created` per element but never `tree_changed` or `online`
  (`src/protocol/tesla/binding.d:291`), where SunSpec does (`sunspec.d:1160`); consumers that
  rebuild on `tree_changed` miss Tesla devices. MQTT accepts `ip6addr` and other non-scalar
  user types it cannot then sample (`src/protocol/mqtt/package.d:112`), and reverse-projects a
  `SysTime` into `MonoTime` by cast. `held_repeat` sets `_last_update` unconditionally on an
  out-of-order equal sample (`src/manager/element.d:974`), regressing record time. Expression
  format inference runs `Type.call` intrinsics against exemplar values
  (`src/manager/expression.d`), which executes code to infer a type.

- **Finish identity follow-ups**:

  - assign deterministic element indices from profile/template and property positions
    (`src/manager/id.d:382` still allocates sequentially from `_slots.length`);
  - run an end-to-end sync identity smoke test; and
  - add ID reclamation and high-watermark telemetry only if distinct-name churn justifies it.

- **Harden reactor clients**:

  - make Linux WiFi raw/monitor paths drop or restart persistently errored pooled FDs so epoll
    cannot spin;
  - pass the embedded UART RX callback and buffer size through `uart_open` to the hardware
    drivers and wake the main loop from RX IRQ/DMA;
  - move serial writes to on-demand async completion if flow control causes material
    main-thread stalls; and
  - move recorder storage I/O to a helper or future async backend if slow media blocks the
    reactor.
  The remaining ASH, EZSP, and Zigbee timers should move to scheduled callbacks separately;
  they are not I/O readiness work.

- **Complete the GPIO sampler backends**:

  - turn cdev `line_seqno` gaps into series gap events (`urt/driver/posix/gpio.d:289`);
  - enforce live retention ceilings for open-squelch edge streams; and
  - add the waveform generator API needed by RF433 transmit.

- **Complete `/port` discovery and eventing**: publish serial and CAN devices, classify Linux
  netdevs by ARPHRD type, and replace polling with route netlink for netdevs plus uevents or
  inotify-backed rescans for tty devices.

- **Fix the HTTP binding request-state wedge**: reproduce with request tracing, then replace
  FIFO response correlation with request handles. A rejected or timed-out submission must
  clear `in_flight`; late responses must not complete a different request.

- **Fix API response truncation**: `/api/get` responses around 140 KB currently produce
  incomplete JSON without an error.

- **Fix `/device/print` on non-terminal sessions**: `/api/cli/execute` crashes the process and
  a piped interactive session prints nothing. Audit `DeviceTreeView` and other live views for
  terminal-channel assumptions.

- **Clarify TLS server transport ownership**: ensure shutdown cannot destroy a listener twice
  when a server-side TCP stream takes multiple ticks to stop.

- **Make profile lifetime explicit**: either keep profiles process-lifetime and enforce that
  contract, or give borrowers ownership before allowing reload/free. Borrowers include
  accumulator source paths, element metadata, profile enums, protocol element descriptors,
  and other slices into profile string/section storage.

## Dated entries

Deferred work lands here as dated sections; remove a section once it is absorbed.

### 2026-08-26: profiles should express derived values instead of inventing attribute ids

An IAS Zone device reports its whole state as bits of one attribute, `0x0002` (ZoneStatus,
a `map16`). The profile has no way to say "this element is bit 3 of that attribute", so it
invents an address per bit instead:

```
zb: 0x500, 0xFC01, bool    desc: alarm2
zb: 0x500, 0xFC03, bool    desc: low_battery
```

Nothing on the device answers to `0xFC01`. Priming duly asked for those ids and the reads
came back unsupported, so a contact sensor's state could not be fetched at all; the
controller carries `apply_zone_status` to decode the real attribute by hand, priming carries
a special case for cluster `0x0500`, and both are guarded by treating `>= 0xFC00` as a
never-readable range by convention.

The shared value-spec grammar already covers this, and the mapping wants to become:

```
zb: 0x500, 0x0002, bool@0    desc: alarm1
zb: 0x500, 0x0002, bool@3    desc: low_battery
```

reading the attribute the value really lives in, with the generic decode extracting the bit.
Doing it deletes `apply_zone_status` (three callers), the priming special case and the
`0xFC00` guard, and generalises well beyond zigbee: Modbus status/alarm registers, CAN
signals (which are only ever bit offset plus width), ZCL `map8`/`map16` attributes, Tuya
bitmap datapoints and SunSpec bitfields all pack many values into one wire value.

#### Blocker: the element index holds one element per attribute

`_sample_elements` is keyed by `(eui, endpoint, cluster, attribute, manufacturer)` and
asserts one element per key:

```d
assert(key !in _sample_elements, "TODO: support element duplicates?");
```

so seven elements cannot share attribute `0x0002`. **The synthetic ids exist only to
manufacture unique keys** - that is the whole reason for them. The index has to hold a list
per key, and every write path becomes "update all matching" rather than "update the one":
`find_sample_element` and `find_sample_element_tuya` and each of their call sites in the
report, tuya-datapoint, read-response and priming paths.

#### Gotchas

- **The notification is a command, not an attribute report.** Zone Status Change
  Notification is cluster-specific command `0x00`, carrying ZoneStatus, ExtendedStatus,
  ZoneID and Delay. The generic attribute path never sees it, so the command handler must
  keep parsing the payload and writing `0x0002`'s value; only the decode downstream becomes
  generic. `apply_zone_status` today is a pure mapper of already-decoded values, called from
  the live notification, the priming read and the replay path.
- **Bit offsets are relative to the context word, and zigbee's context is not worded.**
  `container = sliced ? (ctx.worded ? ctx.word_bytes : 0) : 0`. Modbus is
  `LayoutContext(2, true, ...)`, so `bool@3` yields `container_bytes == 2`. Zigbee compiles
  against `stream_le_context` / `stream_be_context`, which are `word_bytes = 1` and not
  worded, so container is 0. IAS needs bit 9 (`battery_defect`, mask `0x200`) of a `map16`,
  i.e. a bit offset that crosses a byte. **Verify cross-byte bit offsets decode correctly in
  a byte-stream context before trusting this** - see next point.
- **No profile uses `@bit` at all.** It is implemented and unit-tested, but the unittest
  only exercises `modbus_context` (worded, 2-byte). It has never run end-to-end, and never
  in a non-worded context. First real user should expect to shake something out.
- **`0x0002` is only readable after IAS enrolment.** Proven on hardware: before enrolment
  the read was delivered and silently ignored; ~150ms after the CIE address write landed,
  the same read was answered in 123ms. So anything that reads ZoneStatus depends on
  enrolment having run first. The device never sent an `ias_zone_enroll_request`, so it
  enrols silently and the enroll request cannot be used as proof enrolment took.
- **`zone_id` and `delay` do not fit the model.** `zone_id` has a real attribute (`0x0011`)
  it could map to. `delay` exists only in the command payload with no attribute behind it at
  all, so it stays synthetic or goes.
- **`conf/profiles` is a submodule.** A profile change ships separately from the binary and
  has to be deployed to a target in its own right, so a binary that expects the new mapping
  can meet an old profile and vice versa.
