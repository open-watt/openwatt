# TODO

Design-level work items. Inline TODO/HACK comments track point fixes; this file tracks
cross-cutting issues that need a design decision or touch multiple systems.

## Energy

- **Topology publisher bind is O(paths x siblings)**: `TopologyPublisher.bind()` re-runs
  `find_or_create_element` for every field of every record (~3000 dotted-path lookups, each a
  linear sibling scan per segment, plus a tconcat/makeString per field) - ~106ms per rebuild on
  the Pi. Rebuilds are rare again so it's latency noise, but it should be microseconds: reuse
  cache entries whose ids didn't change and only resolve new/removed records (diff-based rebind),
  or give Component a keyed child/element lookup.

- **Session-delta SOC floor, remaining work**: v1 landed (session.d: incremental accumulation of
  the delivering EVSE's import counter, soc_floor = delivered * 0.88 / capacity, published on
  the vehicle and picked up as the soc(N) witness). Remaining: persist the session across
  OpenWatt restarts (currently re-seeds at 0 - conservative but loses progress); VIN-less cars
  with a STATIC pairing (mg_zs via car=mg_zs) can key sessions by appliance name instead of VIN
  (the binding asserts identity that VIN-discovery would have provided; needs a vehicle-store
  entry keyed by appliance name to carry soc_floor); truly unknown cars get EVSE-scoped policies
  only (surplus soak / duty goals - soc is meaningless without identity); real SOC via Tesla BLE
  supersedes the estimate when it lands; feed (delivered, soc-delta) samples into the capacity
  estimator once real SOC exists.

- **Integrated import/export counters (stateful meter completion)**: nodes without cumulative
  energy counters should get them by integrating active power. Unlike the existing stateless
  per-sample synthesis in `get_meter_data`, this needs persistent per-port accumulators and a
  MonoTime timebase, updated where port meter data is refreshed; results feed back in as
  total_import/export_active with a new `Provenance.integrated` and publish onto the node as
  elements (the "artificial energy meter"). Semantics: counters restart at 0 on boot (consumers
  must anchor-delta, never read absolute), skip integration across stale samples (gap
  threshold), keep them out of the recorder by default.

- **Surplus-tracking, remaining work**: v1 landed (opportunistic policies capped at
  draw + signed grid surplus at the path's source bus, consumed from a per-bus pool in rank
  order; setpoints step-quantized against meter jitter). Remaining: VERIFY the grid-port sign
  convention live (a flipped meter sign reads export as import and opportunistic never drives);
  floor/essential still drive flat-out - modulate from planner required_kwh/slack; hysteresis is
  only step-quantization + dwell guards, watch for churn under fast-moving clouds; the
  `pressure_modifier` gate on opportunistic marginal value is now redundant with the hard
  surplus cap - remove it.

- **Stale allocation reasons**: `record_decision` only runs for policies that made the queue, so
  a policy whose marginal value drops to 0 keeps displaying its last recorded reason forever
  (misleading during debugging). Record an explicit "satisfied"/"idle" reason for non-queued
  policies each tick, or expire the elements.

## Tesla TWC

- **Release semantics, remaining work**: landed - master floors delivered current at 5A
  (charge_current getter), binding publishes can_disable=false, allocator actuates a separate
  enable_e on drive/release (release: setpoint=min then enable=false). Remaining: the car-side
  BLE `charging` element that becomes enable_e via pick_enable_element - until it lands,
  "satisfied" trickles at 5A (~1.25kW), so satisfied night-time rules still draw grid.
  Appliance/master disable remains an explicit hard-off only (see recovery below).

- **Recovery reworked, verify on hardware**: link flaps no longer reset chargers - the master
  just resumes heartbeating with all latched state intact. First bring-up plays the ~4s announce
  ceremony once, then optimistically adopts all configured chargers (specified_max_current is
  the clamp until SlaveLinkReady refines device_max); a stalled slave re-arms its heartbeat
  counters and keeps being polled instead of de-adopting into the minutes-long LinkReady wait.
  UNVERIFIED protocol assumption: slaves answer master heartbeats without having seen our
  announce (believed true from TWCManager lore); if wrong, the failure mode is just unanswered
  heartbeats until the slave re-announces on its own timeout - same as the old behaviour.

## Zigbee latency and robustness

1. [ ] **Validation metrics**: expose queue wait by PCP, deadline promotions and expiries,
    queue rejection and DEI eviction counts, reserved-slot dispatches, user-command
    submission-to-completion latency, and reactive receive-to-dispatch latency.

## Automation

The as-built record lives in [docs/AUTOMATION.draft.md](docs/AUTOMATION.draft.md) (implementation
status block). Remaining legs, roughly in order:

1. [ ] **Execution policy**: `overrun=skip|queue|restart|coalesce`, `catch_up=skip|once|all`
   (+ grace window), `on_error=ignore|retry|disable`. Today concurrent runs simply stack in
   `_running_commands` (inherited accidental cron behaviour), and the only catch-up semantic is
   cron's hard-coded fire-once clamp on a missed deadline plus wall-clock re-anchoring - neither
   suppressible nor multipliable.

2. [ ] **Typed `$trigger.*` context**: only the flat `$value` exists. Decide flat locals ($prev,
   $topic, ...) vs a `$trigger` object local (expression getMember walk already supports it) when
   the first provider with rich payloads (mqtt) lands.

3. [ ] **More providers**: mqtt (filtered publish), zigbee (attribute report), sun
   (sunset/sunrise with offsets - needs an astronomical calc), http. Each is a module-registered
   ISignalProvider; the engine needs no changes.

4. [ ] **`on=` completer**: 5th `Prop!` param + `Property.completer` + the collection_commands
   hook; ISignalProvider gains a complete/suggest capability (scheme completed from the registry,
   body and param values by the provider). Deliberately last.

5. [ ] **Event-driven element attach**: a rule referencing a not-yet-created element parks in
   Starting re-running startup() each frame until subscribe succeeds - observable and correct,
   but true event attach means notify_element_created revisits signal subscriptions instead of
   frame polling.

6. [ ] **Re-entrancy / loop guard**: automations both subscribe to and write elements; only
   value-change damping breaks cycles today. The `who` cookie exists on `Element.value()` but no
   caller passes it and the OnChangeCallback subscriber list never filters by it (element.d has
   the TODO). Design doc wants writes tagged with the originating rule plus a bounded re-entrancy
   guard. Related: `/element/set` silently updates the local value of a read-only element - it
   should surface "target is not writable".

7. [ ] **`?deadband=` trigger param**: the automation surface of the element deadband design -
   see Data model below.

8. [ ] **Energy pivot**: the propose/dispose action surface - rules express intent to a
   `Control`'s request surface and the allocator arbitrates contended outputs; energy `Policy`
   goals then migrate onto automations while the allocator keeps ownership of contended
   setpoints.

## Data model

- **Commands / device logic in profiles (design 2026-07-16; the ancient "commands" TODO's
  answer)**: the missing write/control facet - how a state-element write becomes a transmitted/
  written protocol action, INCLUDING stateful logic (toggles: only fire if desired != current).
  Today this would live as per-device binding code. Proposal: **bring the automation/expression
  engine down into profiles** so device behaviour is data-driven. Invents almost nothing - reuses
  the expression evaluator (`@`-refs, arithmetic, funcs; expression.d), the automation `on/if/do`
  shape, and Element2 change events. Three layers:
  1. **Actions as generative expressions**, not static captures. An action computes its payload
     from managed state:
     `action light = ook(addr=df258, button=7, counter=$seq, check=$seq ^ 7 ^ 7)`
     `action speed = ook(addr=df258, button=$b, counter=$seq, check=$seq ^ $b ^ 7)`
     where `$seq` is a per-device managed counter the binding advances each emit (protocol-
     specific rolling counter), and the checksum is deterministic. Captures the whole protocol
     once; every transmission generated fresh (not replay).
  2. **Elements in the component template** = the state model (fan.speed, light.on, ...).
  3. **Element-change scripts carry the logic** - the automation `if/do` scoped to a device:
     `on fan.speed : play(speed[$value])`                         # absolute
     `on light.on  : if $value != @light.on then play(light)`     # toggle: fire only to change
     Solves the toggle problem (know current state before commanding a toggle) in two profile
     lines, no binding code.
  GENERALISES past RF: "on element change, invoke a named action with logic" is protocol-
  agnostic - the action is an OOK expression for RF, a topic-write for MQTT, a register-write for
  Modbus. So `action`/`play` IS the general commands primitive the write-binding/sink model lacks;
  profiles become where device control is authored regardless of transport. SYMMETRIC for RX:
  `on rx(button=7): @light.on = !@light.on` expresses decode->state (physical-remote-follows-us
  sync) in the profile too. Scope: profile parser grows an expression/script layer; define a
  DEVICE-SCRIPT EXECUTION CONTEXT (access to `@`-elements, the `play(action)` primitive, per-device
  managed state like `$seq`). Less "new subsystem" than "point the automation engine at the device
  layer". First customer: the RF433 fan (drafts conf/rf_profiles/brilliant_22034.conf +
  src/protocol/rf433/package.d; Brilliant 22034 protocol fully reverse-engineered - see
  memory/pi_433_wiring). Ties to: profile FUNCTIONS facet in the data-model redesign, automation
  Phase 3 ($trigger context / typed action surface), and the GpioBinding signal-generator (TX).

- **Data model / observation fabric redesign (settled 2026-07-15; full design in
  [docs/DATA_MODEL.draft.md](docs/DATA_MODEL.draft.md), identity in
  [src/manager/id.d](src/manager/id.d) header)**: typed element series (buckets, observers +
  cursors, retention tiers, clock domains), series contract module shared by elements and
  taps, operators absorbing Map/Sum/Alias (fixes accumulator integrating blind across gaps),
  property projection (every Prop! semantically an element, physically lazy), Event! and
  profile FUNCTIONS as the missing facets, Device-as-BaseObject via composition (kills
  is_device trap), mesh trajectory (config authority is the new subsystem). Build order in the
  doc; ID migration steps 0-2 LANDED 2026-07-17 (see Infrastructure entry below). Series
  contract module EXTRACTED 2026-07-17: manager/series.d holds the host-agnostic vocabulary
  (DataFormat/ValueType/Semantics, Constraint, ClockDomain, Scalar, RecordBlock, SeriesEvent,
  Bucket/SeriesStore), organised for all three facets (Event! payloads and device-function
  params/results will use the same DataFormat vocabulary); element2.d keeps the mount-point
  machinery (Element2, Observer/Subscription, Cursor, dirty list). Both build systems updated.
  Mount step LANDED 2026-07-17: Element embeds Element2 - the mount keeps identity/metadata
  (id/name/desc/display_unit/access/sampling_mode/parent) plus the boxed Variant mirror
  (latest/prev/recent/subscribers); a null or indirect format means legacy (bit-identical
  behaviour for every existing consumer), a scalar format makes the mount native: boxed
  writes unbox into the core (series.unbox_scalar), native observe!T/observe_block/mark_gap
  on Element feed the series then mirror the tail into the boxed path (legacy subscribers,
  prev pair, recent ring see the same timeline). Boxing edge implemented in series.d
  (box_record/unbox_scalar, RecordBlock.box, Element2.value; ints/floats wrap format.unit as
  Quantity). GpioBinding mounts its series on the device element (element= prop, default
  "state"; materialise() hangs it, shutdown marks a gap) - first native producer through the
  tree; binding still owns the DataFormat+ClockDomain (mount outlives binding destruction -
  formats need a durable home, noted inline). 92/92 unit tests (native-mount coverage added)
  + boot smoke. First protocol LANDED 2026-07-17 (CAN): Profile.series_format(ValueDesc)
  mints shared per-shape DataFormats (held semantics, profile-owned/borrowed like enum_info;
  numerics and bool only - enums/bitfields/strings/dates wait on the type registry) and CAN's
  add_handler assigns them, so CAN elements store natively via the boxed-setter unbox path.
  Variant-free decode (sample_record straight to observe, skipping the box) is the follow-up
  optimisation once more protocols carry formats. NEXT: remaining producers per-protocol
  (Modbus last), consumers then leave the boxed mirror; recorder-as-cursor waits for
  retention tiers (build order step 3); the prev pair dies when operators absorb the
  accumulator (step 4).

- **Element deadband (settled design, build when needed)**: per-point change-event conditioning,
  standard SCADA/OPC report-by-exception. ONE mechanism, three surfaces: the filter itself lives in
  the element's subscription machinery - each subscriber record carries an effective band plus an
  anchor (last value DELIVERED to that subscriber); deliver when the move from the anchor meets the
  band, then re-anchor. Non-numeric values ignore the band. `Element.latest` always stores truth
  (live reads/`@path`/API stay exact); only event delivery is gated. Band selection: (1) element
  metadata (profile field `deadband: 5W`) is the DEFAULT, the "signal modelling plan" = noise floor;
  (2) any subscription may override - coarser, finer, or 0 for raw realtime; (3) the automation
  surface is just a trigger URI param (`on="@motor.power?deadband=100W"`) that the element provider
  passes through as the subscription override - no rule-side reimplementation, works on unmodeled
  elements. Default-following subscribers resolve the element default at DELIVERY time, so
  retrofitting a band onto a raw element immediately benefits them; explicit overriders are pinned.
  Composition rule for docs: element default = measurement noise floor, overrides = consumer intent
  (don't crank the element band "for the recorder"; that's the recorder's own override). Caveats:
  the recorder may capture inline rather than subscribe - it needs to consult the same band (ties
  into the record-flag follow-up); percent deadband (OPC-style) is a later variant, absolute first.
  KNOWN DEADBAND PATHOLOGY (Manu, 2026-07-12) + required companion: crossing-triggered delivery is
  selection-biased toward extremes - (1) a transient trips delivery at its peak and the anchor
  latches that extreme while the signal settles to nominal INSIDE the band (delivered value wrong
  by up to the band, indefinitely, always toward the extreme); (2) warble marginally wider than the
  band delivers ONLY alternating boundary crossings, never a central sample, so the delivered
  stream sits farther from the rolling mean than raw would. Fix (1) and bound staleness with the
  standard historian companion knob, a max-report interval (`refresh=<dur>`, cf. PI exception-max-
  time / OPC keep-alive): after a quiet refresh period, deliver the current CLOCK-sampled value and
  re-anchor (clock samples are excursion-uncorrelated, so the anchor migrates to nominal). Deadband
  without refresh is half a mechanism - ship them together. Fully killing (2) needs the band
  decision made on a cheap EMA of the signal (decide on smoothed, deliver raw-current so consumers
  never see synthetic values) - optional third param, adds a time-constant knob; swinging-door
  compression is the heavyweight endpoint we don't need. Damage is consumer-dependent: `latest` is
  truth, so use-time re-readers (live `@path`, encode-time sync reads) suffer only timing bias;
  delivered-sample ingesters (recorder, `$value`) latch extremes and are who `refresh=` is for.
  Motivation: makes analog debounce coherent (motor inrush exceeds band and re-arms the automation's
  settle window, steady-state ripple is quiet -> `on="@motor.power?deadband=100W" debounce=5s` fires
  once when the motor stabilises) and cuts sync/record traffic from jittery samples at the source.

## Infrastructure

- **ID strategy migration (settled 2026-07-15; full design in the header of
  [src/manager/id.d](src/manager/id.d))**: replace hash-derived EIDs/CIDs with permanent
  monotonic handles bound to objects, with names as the parking/rebind fallback. Ids are
  two-level: EID = (container id, element index) - the container level is ONE id space with
  per-type tables (CID type bits); Devices register as a type WITHOUT becoming BaseObjects
  (g_app.devices Map dissolves into it), the data plane shards per container, device rename is
  O(1) with no full-path interning, and property projections compute their EID as
  (obj CID, Prop! index) with no lookup or cache. Kills ALL rekey
  machinery: `rehash()`, `ElementTable.rekey`, `CollectionTable.rekey`, `do_rekey`,
  `broadcast_rekey`, `rekey_field` all delete - rename-following becomes intrinsic (ids don't
  move when objects rename) instead of repaired by reflection broadcast. Gains: forward
  references and recreation-rebind via a parked-id claim state machine in insert(); O(1) rename/
  death/claim regardless of ref count; no hash-collision concept; EID and CID unify on identical
  semantics (ObjectRef and element refs share one follow-forwards + self-heal deref helper).
  Rules that must hold system-wide: ids never persisted, never on the wire (sync exchanges names
  once per session, binds varint session handles), no blind `hash_id` of a name to fabricate an
  id. Prerequisite for the Element2/series work (element2.d draft holds `Element2*` in Cursor -
  becomes an EID under this scheme). STARTED 2026-07-17; execution order (full steps 0-5 in the
  id.d header): (0) ids off the wire FIRST - sync today ships raw CIDs and leans on cross-peer
  hash agreement (json_encoder rekey verbs + the rehash-divergence patch in sync/package.d), so
  session name/handle binding lands before ids change shape, making the cutover a pure internal
  refactor; (1) the park/claim/forward machine standalone + unit-tested (dense per-type slot
  arrays, next_slot++ allocator, separate name map holding parked ids); (2) container cutover
  (CollectionTable, delete ALL rekey machinery, then Devices as a container type); (3) element
  index tables + Cursor->EID; (4) unified EID ref type; (5) holder audit.
  Step 2 LANDED 2026-07-17 (both halves): (2a) CollectionTable reimplemented over
  IdMachine!BaseObject - CID = type bits + dense slot, name setter calls table.rename (the id
  never moves, held refs follow intrinsically), and ALL rekey machinery deleted (hash_id/rehash
  chains, the intern StringTable, broadcast_rekey/rekey_field/has_cid, the rekey virtual, the
  RekeyHandler mixin + its ~30 sites; net -240 lines). (2b) Devices register as a container
  type: g_app.devices Map dissolved into DeviceTable (device.d) over IdMachine!Device with a
  map-flavoured surface (in/insert/values/keys), CollectionType.device carries the type bits.
  Verified: 92/92 unit tests + runtime smoke via --config script (duplicate-name rejection,
  rename, old-name reuse, rename-onto-live rejection) + full dev-conf boot clean.
  Step 3 core LANDED 2026-07-17: IndexTable(T) in manager.id (the nameless element-level
  machine - same tagged-word encoding as IdMachine, no name map: relative paths resolve
  through the component tree, indices park positionally on release and rebind at the same
  mount); Device carries cid (stamped by DeviceTable.insert via make_cid, now
  package(manager)) + IndexTable!(Element*) element_ids; Element.ensure_eid() mints lazily on first
  demand (walk to device ancestor; unmounted elements have no identity);
  DeviceTable.resolve(EID) + resolve_element() free function; ElementCursor {EID, position,
  bit} in element.d is the durable cursor (resolves per call, delegates to the storage-level
  element2.Cursor, goes quiet on dead elements); Element.open_cursor returns it. Unit-tested
  (IndexTable cycle, lazy mint/resolve, stray-element refusal). Step 3 remainder rides later
  work: deterministic indices (profile template index / Prop! index) land with per-protocol
  producer migration; destruction-parks wiring lands when anything actually destroys
  elements. NEXT: step 4 (unified EID ref type) + step 5 (holder audit).
  Step 1 LANDED 2026-07-17: IdMachine(T) in manager.id - dense tagged slots (0 = dormant,
  bit0=0 = bound, bit0=1 = write-once forward), reserve/claim/rename/release/deref with
  self-healing forward chains, separate String-keyed name map; unit-tested through the full
  park/claim/rename-merge/resurrect cycle. En route: urt map.d heterogeneous remove was broken
  (search compare reinterpreted the search key as K - segfault on remove-by-slice from a
  String-keyed map); fixed in urt with a regression test.
  Step 0 LANDED 2026-07-17 (compiles, unit-green; sync end-to-end smoke test remains an open
  gap it already had): add_name = {handle, name, type} introducer, SyncPeer carries the
  session handle tables (_introduced objects / _adopted local CIDs; wire handle low bit =
  allocated-by-sender, flips crossing the wire; slots never rebind, object death voids them
  via the destroyed lifecycle hook), every other verb cites handles, translation confined to
  the encoder seam (package.d handlers still speak local CIDs). Deleted: the rekey verb both
  directions, the fan_out_rekey/on_object_rekeyed stubs, and #/$ raw-CID subscription
  patterns. Rename propagation (never wired) is now one {handle, new_name} verb + a global
  renamed hook, deliberately deferred.

- **Async I/O end-state: the main loop's wait primitive IS the reactor** (decided 2026-07-12;
  supersedes the earlier "fold the workers onto one shared worker-thread reactor" plan).
  Today there are three standing I/O thread backends: `SerialReader` (`router/stream/serial.d`,
  linux poll+eventfd / windows IOCP with one parked overlapped read per port), `SocketWorker` /
  `IOCPWorker` (`protocol/ip/package.d`), and the `fdwatch` readiness waiter
  (`driver/linux/fdwatch.d`). All of them exist for ONE reason: the main loop sleeps on
  `_wake_event` (futex / win32 event), which cannot be waited on together with I/O handles - so
  each subsystem runs a thread whose whole job is converting I/O readiness into a wake. The
  destination is to delete that layer entirely: make the main loop's sleep the I/O wait itself.
  - linux: `wait_for_wake` becomes `epoll_wait` (the wake is an eventfd in the set; `post_event`
    writes it, gated by an already-signaled atomic so it costs one syscall per sleep cycle).
    epoll, NOT poll: poll() re-does O(n) waitqueue setup/teardown on every call - fine for a
    parked worker, wrong for a loop waking at 20Hz+ - while epoll registration is persistent
    (`epoll_ctl` once per fd lifecycle = config-time churn) and `epoll_wait` is O(ready) with
    zero per-fd work on re-entry. Level-triggered, drain on main, same semantics as fdwatch's
    service hooks. (At our fd counts poll would actually survive - ~10us per wake for 50 fds -
    but epoll makes the concern structurally impossible; don't relitigate.)
  - windows: `wait_for_wake` becomes `GetQueuedCompletionStatus[Ex]` with the timer deadline as
    the timeout; the wake is `PostQueuedCompletionStatus`. IOCP registration is persistent by
    construction. Completions (serial reads, socket ops) are handled inline on main.
  - The single-threaded dataplane then needs NO SPSC rings, NO backpressure semaphores, NO
    generation/ABA tags, NO worker-owned closes - all of that machinery exists only because I/O
    currently happens off-main. Everything deletes rather than merges.
  - Public API stays completion-shaped ("here are your bytes" via `g_app.watch_io(key, handle,
    &on_data, &on_error)`), never readiness-shaped: readiness is unimplementable on IOCP, and a
    completion contract lets an io_uring backend slot in later without touching clients.
  - io_uring: considered and REJECTED for now - needs recent kernels, is commonly blocked by
    container seccomp defaults (Docker denies it; the RouterOS container target is directly at
    risk), would still require the epoll fallback, and its wins only appear at op rates far
    above ours. Revisit only if a workload demands it; the API above is already shaped for it.
  - Migration passes, each independently shippable:
    1. DONE (2026-07-12): wake-primitive swap - `manager/reactor.d` `Reactor` replaces the
       Application's `_wake_event` Event with the same latch semantics (set/reset/wait) on an
       eventfd (linux) / an IO completion port (windows); one kernel signal per latch cycle via
       an atomic gate. Embedded/other keep the Event arm. Unit-tested both platforms.
    2. DONE (2026-07-13): `g_app.watch_io(file, &on_data, &on_error)` - registration is
       `epoll_ctl` / `CreateIoCompletionPort` association; delivery happens inline on the main
       thread from inside `wait_for_wake` (`Reactor.wait` sweeps ready I/O before and after the
       sleep so it never starves behind a latched wake, and a busy loop still sweeps via a
       zero-timeout wait). Serial folded on; the whole `SerialReader` block is DELETED - no
       rings, no backpressure, no generation tags, owner closes its own handle after
       unwatch_io. Windows: one overlapped read parked per watch with an entry-embedded buffer
       (MAXDWORD/MAXDWORD/1000ms COMMTIMEOUTS = complete-on-first-bytes + 1s idle tick),
       cancelled reads reaped via entry retention until their completion drains;
       ERROR_OPERATION_ABORTED (a flush purge) re-arms quietly; serial's purge-before-close and
       low-bit-tagged write-event suppression carry over unchanged (see notes below). linux:
       level-triggered epoll, reads on main into a stack buffer; errored/hup'd fds are DEL'd
       from the set immediately so they can't spin the loop while the owner's restart works
       through the state machine.
    3. DONE (2026-07-13): OS sockets folded onto the reactor's layer-1 primitive and
       `SocketWorker` + `IOCPWorker` DELETED (~1140 lines out of `protocol/ip/package.d`). The
       layer under `watch_io` (see `manager/reactor.d`): linux exposes `watch_fd(fd, want_write,
       &on_ready)` / `modify_fd` (raw level-triggered readiness; the endpoint does its own
       recv/accept/send on the main thread and unwatches on error); windows exposes
       `associate(handle)` + a public `IoOp` struct (OVERLAPPED + an on_complete delegate) that
       callers park themselves (`WSARecv`/`WSASend`/`ConnectEx`/`AcceptEx`/`WSARecvFrom`), with
       completions delivered on the main thread from `Reactor.wait`. TCPConnection/TCPListener/
       UDPEndpoint each carry their own embedded ops; endpoints are freed by `pump_ip_endpoints`
       once `reclaimable` (windows: all cancelled overlapped ops drained; else immediately).
       Connect readiness = EPOLLOUT (linux) / ConnectEx completion (windows); accept re-arms
       itself. No SPSC rings, no wake socket, no `post_event` marshalling, no `EntryKind`/`Ev`/
       `Req` vocabulary. Verified: win 88/88 + linux 89/89 UT, full builds both platforms, and a
       live loopback that drove all four IOCP op types (ConnectEx outbound -> AcceptEx inbound ->
       WSASend banner -> WSARecv) plus rapid accept/close cycles with no leak.
    4. DONE (2026-07-13): fdwatch's waiter thread DELETED - the LAST standing I/O thread on linux.
       `driver/linux/fdwatch.d` is now a thread-free adapter: its watchers (BLE + 3 wifi) keep the
       collect/service API unchanged, and it registers their fds as a "pool" in the reactor's epoll
       set sharing ONE coalesced drain (`Reactor.set_pool_drain`/`set_pool_fds`, linux). All pool
       fds carry a single epoll data sentinel (`&_pool_tag`) - membership is reconciled by fd number
       (ADD/DEL/MOD diff), no per-fd allocation. When any pool fd is ready, dispatch() sets
       `_pool_pending` and runs the drain (= every watcher's service() + a re-collect) ONCE after
       the batch, at most once per wait() cycle - exactly the old "any readiness -> service all,
       then rebuild" semantics, minus the thread/semaphore/wake-eventfd. Adversarially reviewed
       (0 confirmed defects); unit-tested (coalesced multi-fd drain, drain-to-empty, mid-flight
       set shrink) + full builds both platforms. The whole 4-pass migration is COMPLETE: no
       standing I/O threads remain (SerialReader, SocketWorker, IOCPWorker, fdwatch waiter all
       deleted); the main loop's epoll (linux) / IOCP (windows) wait IS the reactor.
       Known contract (see reactor.d dispatch pool branch): a pool fd stuck in persistent
       EPOLLERR/EPOLLHUP that its watcher keeps collecting would keep the loop from idling (the
       shared sentinel gives the reactor no fd to DEL). Not a regression - the old poll() waiter
       burned a core on the same case - and the drain still runs so the watcher can react. The
       real gap is client-side: wifi `pump_raw_frames`/`pump_monitor` (`driver/linux/wifi.d`)
       `break` on a genuine (non-transient) `poll_ll` error WITHOUT clearing `_raw.fd` or
       restarting, so `collect_fds` keeps re-including the dead fd. Harden those to drop the fd /
       restart on persistent error (pre-existing; only made loop-visible by the single-thread fold).
  - Embedded is the same contract: UART rx-IRQ fills a ring and wakes the main loop (wire the
    already-declared-but-dropped `UartRxCallback`/`buf_size` through `uart_open` -> uart_hw).
    This design makes desktop/server behave like embedded, not the other way around.
  - Known refinements INSIDE the model, only when a real device makes them hurt: async serial
    writes (EPOLLOUT armed on demand / write completions through the port) to remove the bounded
    ~100-200ms main-thread stall a flow-control-blocked write can cause; and storage I/O, which
    epoll cannot async (regular files are always "ready") - recorder flushes to a stalled SD
    card remain the one legitimate helper-thread (or future io_uring) candidate.
  Until pass 2 lands: serial rx is event-driven on linux+windows via `SerialReader`;
  other-Posix/Embedded still drain in `update()` -> `incoming()` (kept so `rx_handler` works
  everywhere).
  Windows note: comm WRITE timeouts on the overlapped path complete with ERROR_SEM_TIMEOUT and a
  short count (the old sync path returned TRUE + short count); `write()` maps it back to the
  partial-write contract - don't "simplify" that check away.
  Note: the serial pass was data-path-only, so the genuine timers left in `update()` are
  intentional - ASH retransmit (250ms) + RST retry (`ashv2.d`), EZSP request timeout (200ms,
  `client.d`), and the Zigbee NCP counter poll (`iface.d`); moving those onto
  `g_app.schedule`/the 1s heartbeat is a separate cleanup.

- **GPIO sampler backend upgrades** (baseline landed 2026-07-15: urt gpio sampler API +
  posix cdev v2 backend + /binding/gpio (GpioBinding) populating an Element2 series):
  (1) pigpiod runtime detection on linux, preferred over cdev when present (decided: cdev
  stays the portable default; pigpio = DMA sample-clock timestamps + the only honest TX;
  no Pi 5 support, so detect, never assume) - same GpioSampler surface, mode tag inside;
  (2) map cdev `line_seqno` gaps to `mark_gap()` on the series so kernel event-buffer
  overflow marks the loss at the drop site; (3) bucket eviction is now LIVE-urgent: an open
  squelch on a 433 receiver grows the series unboundedly (~16 B/edge at hundreds-thousands
  edges/sec); (4) TX (waveform generator API) when 433 transmit lands - forces the pigpio
  backend.

- **Port discovery completeness and eventing**: /port is meant to be the unified hardware
  inventory, but discovery is still uneven. Ethernet and WiFi publish ports today; serial
  discovery needs to be event-driven instead of periodically rescanning; CAN devices are not
  published yet. Linux CAN should be discovered from SocketCAN netdevs via
  /sys/class/net/*/type (ARPHRD_CAN = 280) and reported as PortKind.can, while
  ethernet/wifi scans should only accept real ethernet netdevs (ARPHRD_ETHER = 1).
  Replace polling with OS events: route netlink for netdev classes, and kobject uevents
  or inotify-backed rescans for tty/serial devices.

- **HTTP client binding request-state wedge**: the SmartEVSE binding polled once at boot then
  froze (every device-sourced element stuck at timestamp 0) while binding and client both report
  Running and the device answers in <30ms. Suspected mechanism: request/response correlation is
  FIFO-by-assumption on both sides - the client times out requests at 5s and fires the handler
  with an empty message, so a late response then matches the wrong queued request; and
  `submit_request` silently drops when the binding's 16-deep in-flight queue is full while
  `rs.in_flight` stays true forever, permanently killing that request state. The constant
  `feed_currents` write traffic from the se_meter element links alongside the 400ms status poll
  gives plenty of opportunity to hit either. Verify with `version = DebugHTTPClientBinding`,
  then replace the FIFO assumption with a real request handle (existing TODO in binding.d:
  "HTTPClient NEEDS TO RETURN A HANDLE") and make in_flight self-recover.

- **API response truncation**: /api/get responses truncate around 140KB (seen querying
  `energy.*`); clients get invalid JSON with no error.

- **/device/print over /api/cli/execute CRASHES the instance** (found 2026-07-15, pre-existing):
  every invocation resets the connection (http 000 at ~1.4s), the child dies (defunct under the
  supervisor) and respawns. The same command over a piped --interactive console session prints
  NOTHING but survives. Suspect: DeviceTreeView (and live views generally) assume a terminal
  channel the API/pipe sessions don't have. Severity: any web/API user typing it restarts prod.
  Reproduce locally with the piped-console for the silent case; the crash case needs an API
  session against a populated tree. See console-session skill when investigating.

- **TLS server-mode transport ownership**: shutdown destroys the handed-in listener stream;
  if a server-side TCP ever takes multiple ticks to shut down after going offline, the same
  double-destroy shape fixed for client mode (b4005c88) exists there. Same scrutiny needed.

- **Profiles must never be freed** - things borrow into the profile's string caches, so if
  profile freeing is ever reintroduced, un-borrow these first:
  - accumulator `comp.source` path strings, pre-bind (device.d)
  - element name/desc/display_units metadata (served by /api/list)
  - conf-defined enum templates (profile.d)
  - per-binding retained `ElementDesc` refs from add_handler (aa55 copies by value; audit others)
  - Expressions used to, but now copy their strings at parse (expression.d) - immune.
