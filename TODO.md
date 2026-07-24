# TODO

Cross-cutting work that needs a design decision or changes more than one module. Point fixes
belong beside the code. When an item lands, delete it or reduce it to the work that remains;
the commit history and linked design documents carry the implementation record.

## Energy

- **Speed up topology publisher binding**: `TopologyPublisher.bind()` repeats
  `find_or_create_element` for every field of every record. A rebuild performs roughly 3000
  dotted-path lookups and takes about 106 ms on the Pi. Reuse bindings whose IDs did not
  change, or give `Component` keyed child and element lookup.

- **Complete session-derived SOC**:

  - persist the active session across OpenWatt restarts;
  - key statically paired VIN-less vehicles by appliance name;
  - keep truly unidentified cars on EVSE-scoped policies, where SOC has no useful identity;
  - prefer real vehicle SOC when available; and
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

- **Allow satisfied charging to turn fully off**: expose the car-side BLE `charging` element
  used by `pick_enable_element`. Until then, release bottoms out at 5 A instead of disabling
  charging.

- **Verify recovery on hardware**: confirm that a slave answers master heartbeats without a
  fresh announce after a link flap. If it does not, explicitly restart the announce ceremony
  when repeated heartbeats go unanswered.

## Zigbee latency and robustness

- **Expose scheduling validation metrics**: queue wait by PCP, deadline promotions and
  expiries, queue rejection and DEI eviction counts, reserved-slot dispatches,
  user-command submission-to-completion latency, and reactive receive-to-dispatch latency.

## Automation

The current implementation and remaining phases are described in
[docs/AUTOMATION.draft.md](docs/AUTOMATION.draft.md).

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

- **Finish the series operator model**: move expression maps, accumulators, and aliases out of
  `Device.Computation`/`ElementLink` into explicit operator objects beside the sample layer.
  Operators must consume batches against a committed frame, handle gap events, and own any
  transient or integrating state. Move accumulator timing out of `Device.update()`. Once the
  customers are objects, replace the two-pointer `Subscriber` delegate with a one-pointer
  subscriber interface and audit subscription lifetime.

- **Converge live history and recording**: make durable recorder holders use `ElementCursor`
  rather than raw `Element*` plus storage `Cursor`; remove the legacy database `SeriesId`
  path once graph/sync queries read the typed history and owsig container exclusively. Then
  finish sealed-bucket packing, reuse the packed stripe on disk, unify RAM/disk time queries,
  and add the decimation ladder described in
  [docs/DATA_MODEL.draft.md](docs/DATA_MODEL.draft.md).

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

## Infrastructure

- **Finish identity follow-ups**:

  - assign deterministic element indices from profile/template and property positions;
  - reserve and rebind element indices when elements are actually destroyed;
  - propagate locally authoritative renames through sync using the existing session handle;
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

  - detect pigpiod at runtime on Linux and prefer it when available;
  - turn cdev `line_seqno` gaps into series gap events;
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
