# TODO

Outstanding work and follow-ups, including point fixes and work awaiting a design decision.
When an item lands, delete it or reduce it to the work that remains;
the commit history and linked design documents carry the implementation record.

## Retrospective merge reconciliation (2026-09-08)

- **[#669, deferred until removal is needed] Define device/subtree removal lifetime**:
  DeviceTable currently has no removal API and production code never emits
  `ComponentEvent.destroyed`; the earlier P1 classification overstated a
  demonstrated runtime failure. Before introducing removal/recreation, define
  ownership and invalidate appliance/link references, topology watches and
  control caches before freeing Components or Elements. Include other raw
  model-pointer consumers and coverage for removing/recreating a bound subtree.
  Keep the process-lifetime model for now. If the code structure requires an
  unsupported removal path, it may assert; do not introduce a removal lifecycle
  until the feature is needed.

- **[#667] Validate Tesla recovery on a vehicle**: exercise category back-off,
  busy responses, session counter/epoch/clock faults, BLE loss, bounded key
  approval, and latch reset with a vehicle. Host regressions do not replace
  hardware acceptance. Legacy firmware predating encrypted responses remains
  unsupported; development requires access to an old offline car.

- **[#655, SDK acceptance] Select and pin a supported SDK revision**:
  Compare clean and incremental full N/T SDK builds with the selected revision.
  Full firmware and mode-retry cancellation/rebind still need hardware acceptance.
  Candidate evidence: SDK archives built against OpenBK7231T_App `fd131f3c`
  (N SDK `244bdfe8`, T SDK `12c68122`), with repeat builds preserving timestamps.
  The corrected N firmware links and packs successfully; T links but has the
  packed-size follow-up below. Neither result establishes boot acceptance.

- **[uRT Variant, deferred policy] Define erased-class downcasts**:
  Variant's current ancestry checks describe the stored type. Add a policy handoff
  if dynamic downcasts from its erased base type are needed.

- **[uRT no-RTTI build follow-up] Reconcile remaining consumers**:
  The full no-RTTI unit build fails in `urt.internal.traits`' associative-array
  enum test. Resolve that dependency before claiming full no-RTTI host/test
  support. Class-to-interface dynamic casts still use an unsupported runtime
  assertion; define their contract or reject them at compile time separately.

- **[Beken STA, hardware acceptance] Validate the merged integration**:
  Validate cold boot, association/recovery after lost confirmations, GTK rotation,
  mode changes, allocation failures, RX/TX pressure and shutdown on a pinned SDK.
  Exercise general-DMA TX copies with source offsets 0..3 and partial-word tails;
  source inspection establishes synchronous copying, not the hardware alignment contract.
  Measure service fairness outside the deferred-work budget and audit vendor
  interrupt-context logging. Keep synthetic L-SIG input disabled pending explicit
  buffer-length/metadata handling.

- **[Beken T, separate-session follow-up] Investigate packed firmware size**:
  T is provisional: no hardware is available, and T-specific differences remain
  unimplemented. N is the required Beken target. The maintainer authorizes
  dropping T from CI if it fails; its current uRT cross job passes. The local
  T packaging failure is separate from N support. The tested T firmware links, but `pack_ram_image.py` rejects the image as 2,006 bytes too large
  (about 2 KB, not 2 MB). Both N and T builds used `CONFIG=release`, `TINY=1`,
  `FEATURES=switch`, `HEADLESS=1`, `-Oz`, no RTTI, exceptions, IP or TLS.
  BK7231N now packs successfully at 1,079,206 bytes after the minimal-state audit. Evidence uses LDC 1.43,
  arm-none-eabi GCC 15 and the SDK revisions above. Rebuilding the SDK with
  `-Oz` instead of `-Os` produces the same overflow; that experiment was not
  adopted. Preserve the partition boundary and required behavior when reducing
  size. N is the target for this session and passes; investigate T separately.
  No comparable earlier size/map has yet established when growth occurred or
  whether a previously excluded blob was retained. Bisect in a new session if
  that difference is not immediately apparent. The failed build's `fw.bin` is
  an unpacked intermediate, not flashable.
  Logs: `.tmp/urt258-evidence/final-openwatt-t-link.log` and `t-size-link.log`.

- **WPA pairwise rekey**: the shared supplicant handles initial PTK installation
  and GTK rotation, but does not yet renegotiate a PTK on an established link.
  Add authenticated rekey transitions and retransmission tests without resetting
  receive counters when already installed key material is repeated.

- **[uRT build, in passing] Respect the compiler's Tiny version flag**:
  `platforms.mk` hard-codes `-d-version=Tiny`, so `TINY=1 COMPILER=dmd` fails
  before compilation. Use the existing compiler-specific `VERSION_FLAG`.

- **[Host build, local work] Reconcile the unfinished power regulator**:
  The untracked `src/driver/power/regulator.d` references `ComponentEvent.materialised`,
  `set_device_online` and `note_activity`, which are absent from the current model.
  It is discovered by the full source build; reconcile it with the intended model
  work before expecting this working checkout's host build to pass.

- **[Windows toolchain] Retire the default beta DMD and isolate LDC COMDAT failure**:
  PATH selects DMD 2.112.0-beta.1, whose unittest build fails copy-constructor
  detection at `urt.internal.traits:376`; installed stable DMD 2.113 passes the
  isolated OpenWatt suite. LDC 1.43 aborts the full Windows unittest build with
  an associative COMDAT error for `BLESession.find_char`; isolate that compiler
  failure separately. Evidence: `.tmp/urt258-evidence/adoption-host-build.log`,
  `adoption-isolated-build.log`, and `adoption-dmd-stable-run.log`.

- **[uRT host test] Investigate Windows x86 stack unwinding**:
  DMD fails twice at the unchanged `urt.internal.exception:453` stack-trace test.
  An isolated LDC 1.43 pbuf-only suite also reaches that failure after its pbuf
  tests pass. The larger LDC WPA/driver suites pass 76/76 and 77/77. Reproduce
  and isolate the cause; image-layout sensitivity is only a hypothesis.
  Evidence: `.tmp/urt258-evidence/final-host-run.log`, `final-host-rerun.log`,
  and the isolated series pbuf logs.

- **[uRT alignment, other ports] Audit opaque unwinder storage**:
  Beken now explicitly aligns `__eh_frame_object`. STM32, RP2350 and BL common
  still declare byte storage without an alignment contract; check their selected
  unwinder ABI and align or remove the unused registration path as appropriate.

- **[#657, transport follow-up] Complete IPv6 transport error delivery**:
  connect incoming ICMPv6 errors to TCP/UDP when their IPv6 delivery paths are
  implemented. Add per-destination path-MTU state and propagate local oversize
  output failures through a transport completion API; `output_v6()` currently
  returns void. Handle quoted fragments alongside IPv6 fragmentation/reassembly.
  Incoming errors currently reach pending echo diagnostics only. Add host-OS
  ICMP backends for `/ping`; IP echo currently requires the internal stack.

- **[P2, IPv6 UDP] Validate the native zone paths on hardware**: the zone contract in
  docs/wip/NETWORKING.draft.md is implemented for UDP on the internal stack, Linux and Windows, but only the
  internal stack has regression coverage. Still owed: a two-interface Linux run of the pktinfo
  receive path, connected link-local replies and `IPV6_MULTICAST_IF`; a Windows IOCP run of the
  IPv6 `IN6_PKTINFO` path (`kernel_ifindex6`); an ESP32 run of the internal stack over wifi
  (link-local replies, `ff02::` joins via MLD). The Ether family's `scope_id` stays 0
  (`UDPBindEndpoint` carries the station separately). urt's WinSock `IPV6_RECVPKTINFO` /
  `IPV6_PKTINFO` constants are the Linux values (49/50), not Windows' 19; the IOCP path defines
  its own, but `urt.socket.recvfrom` with packet-info is wrong on Windows.
- **[P3, build] The lwIP socket backend is unbuilt and unsupported**: ESP builds default to
  the internal stack and do not link lwIP; `USE_INTERNAL_IP_STACK=0` on ESP32 fails to compile
  (`IoReady` is Linux-only in manager/reactor.d, `Array!DNSQuestion` fails to emplace under the
  embedded toolchain). No driver records a lwIP netif index, so IPv6 zones would not translate
  there either. Either grow the FreeRTOS reactor and finish that backend, or delete the opt-in.
- **[P2, IPv6 UDP] IPv6 multicast without a zone on the internal stack joins every link**:
  `c_set_option(multicast6)` with `scope_id == 0` joins the group on each interface holding an
  IPv6 address (the DNS server's mDNS/LLMNR listeners rely on this), where a native stack picks
  one default interface. Decide whether a routed default is wanted instead, and whether the DNS
  server should join per link explicitly. `SocketOption.multicast` (IPv4) now also joins on the
  internal stack; before this it was a silent no-op.
- **[P3, IPv6 UDP] TCPv6 on the internal stack**: `c_create` refuses IPv6 stream sockets
  (`// TODO: TCPv6` in protocol/ip/socket.d); the v6 input path drops TCP segments. Windows IOCP
  TCP is IPv4-only too.
- **[P3, IPv6 SLAAC] Source selection is first-fit, not RFC 6724**: `preferred_source_v6` honours
  only rule 3 (skip deprecated addresses); no longest-matching-prefix, scope or ULA-versus-global
  ordering, and `source_for_target` in nd.d ignores deprecation. Renumbering (a `preferred=0` RA
  deprecating the old prefix under the two-hour valid floor) has only been reasoned through, not
  exercised against a real router.
- **[P3, IPv6 RA] Router-side gaps**: the SLAAC host still solicits routers on a link this node
  advertises (RFC 4861 6.3.7 says a router does not); no RA consistency checking against other
  routers on the link (6.2.7); no per-service DHCPv6 tie-in behind `managed`/`other-config`. The
  service has not been exercised against a real host beyond compilation.

- **[P3, style-audit deferrals] Preserve outstanding design work**: validate
  appliance port names against a profile-authoritative or explicit namespace
  instead of accepting every unknown string property as a circuit binding.
  Add borrowed protobuf byte fields so vehicle decoding can avoid one owned
  allocation per bytes field. These existing deferrals were moved out of long
  source comments during reconciliation.

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

- **[#661] Validate fleet transfers on hardware**: exercise cap changes, circuit-budget
  reductions, dropped replies, restart/takeover, and measured-current ramp-down.
  Verify no current is reassigned until the lower limit is acknowledged and measured.
- **[#661] Establish a verified TWC stop/start operation**: the existing driver has a
  5A floor and cannot safely revoke an admitted charger's grant. The below-minimum
  fleet-budget case is deliberately deferred from this PR: decide admission/stop
  policy, zero grants, and live circuit-budget reductions below the fleet minimum.
  For now no new allocations are issued in that case; existing grants remain reserved.

- **[#661] Exercise arbitration on a two-master bench**: cover simultaneous startup,
  takeover after silence, duplicate bus ids, and ids sharing the same low nibble
  (the current jitter has only 16 slots). Also verify standby discovery from an
  already-running master's heartbeat replies without a fresh slave announcement.

- **Allow satisfied charging to turn fully off**: the vehicle model now carries
  `charging.enabled` (`src/apps/energy/vehicle.d`), but `pick_enable_element`
  (`src/apps/energy/control.d:427`) searches the control component and does not find it. Wire
  the two together. Until then, release bottoms out at 5 A instead of disabling charging.

- **Verify recovery on hardware**: confirm that a slave answers master heartbeats without a
  fresh announce after a link flap. If it does not, explicitly restart the announce ceremony
  when repeated heartbeats go unanswered.

## Tesla vehicle BLE

- **[#683] Validate vehicle write-back on hardware**: from the web UI, exercise charging
  enable, current setpoint (including 5 A), HVAC power and target temperature on the S3.
  Repeat after disconnect/reconnect and VIN removal; check existing and fresh sync mirrors.

- **[#526] Validate the whitelist refusal decode on the car**: the reason strings come from
  Tesla's `vcsec.proto` enum, never from an observed refusal. Provoke one (enrol a key while
  the vehicle sits at the touchscreen prompt and decline it, expecting information 24) and
  confirm the frame reaches `handle_enrolment_status` rather than being dropped as unaddressed.

- **[#526] Fail fast on terminal whitelist refusals**: `WHITELIST_FULL`, `NO_PERMISSION_TO_ADD`
  and `INVALID_PUBLIC_KEY` cannot succeed by retrying, but the session still burns its whole
  60-second approval window before backing off. Ending the phase early needs on-car evidence of
  which codes are genuinely terminal; a code misclassified as terminal aborts enrolments that
  would have worked.

- **[#526] Offer ROLE_CHARGING_MANAGER when enrolling**: `Keys.Role` 6 is the least-privilege
  role for what OpenWatt actually does, and would drop the owner-level authority the enrolled
  key currently holds. Held back only because AddKey has never been tried with it: a role the
  vehicle refuses costs an approval window to discover.

- **Document the rest of `/protocol/tesla/session`**: `get-charge`, `get-climate`,
  `charge-start`, `charge-stop`, `set-amps`, `climate`, `set-temperature` and
  `schedule-charging` have never been listed in [docs/CLI.md](docs/CLI.md); only `enrol` is.

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

- **Device construction API, remaining pieces** (the builder landed: `DeviceBuilder`,
  `DeviceLifecycleEvent.created`, private tree arrays, energy off the table scan):
  - no removal path: `Component` has no remove, `DeviceTable` has no remove, elements are never
    destroyed and `DeviceLifecycleEvent.destroyed` / `ComponentEvent.destroyed` are never emitted.
    Route removal through the builder when the first producer needs it.
  - `online`/`offline` are still ad hoc: six emitters of `online`, one of `offline` (smartevse).
    Mirrored and MQTT-discovered devices never go offline.
  - MQTT discovery and sync mirrors publish an empty device and grow it one edit per frame; that is
    the intended burst granularity, but a discovery that knows its entity set up front could build
    once.
  - `PublishSlot` binds lazily on first write, so structure is still created on first touch. Bind
    the allocator, policy and planner slots when the Policy or Island is created, and drop the path
    argument from the per-tick write.
  - Nesting a builder asserts, in release too, by choice: find misuse early. Revisit once the
    esphome, goodwe, zigbee, SunSpec, MQTT discovery and SmartEVSE paths have run under it; none of
    them were exercised on the bench.
  - The esphome and goodwe `status.network.ip.address` elements are written once at connect and
    never refreshed; they should follow the client's connection.
  - `open_commit()` (element.d) has no callers: every multi-element write still delivers per
    element, so a subscriber can run between two fields of one frame and the topology watch can
    rebuild mid-frame. Wrap each frame boundary in a `CommitScope`: the TWC push, the Modbus,
    SunSpec, GoodWe and Zigbee response handlers, the MQTT publish path, the tesla vehicle
    publish functions, the energy publishers, and the sync inbound value path.
  - `components` / `elements` return writable slices, so a caller can still overwrite a slot without
    the builder; closing it needs a slot-immutable view type.
  - Element name and access edits on a live element are not announced anywhere: sync announces on
    creation only, so a rediscovered MQTT entity whose access changed is stale on peers. That is
    sync's to re-announce, not shape; a format change is a series event on the same element.
  - Helpers that build part of a tree thread `ref DeviceBuilder` through every call (about ninety
    sites in the TWC and SmartEVSE bindings, eight SunSpec helpers). A component-scoped handle
    would remove the argument; not obvious it is worth its own type.

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

## DHCPv6 features

The codec from `67e83fb4` has no operational client, server or relay. The reserved
client/lease/server collection IDs have no implementations or commands. These
are feature follow-ups, outside the retrospective merge fixes; choose the first
role from a concrete deployment need before implementing or advertising it.

- **Client**: decide whether the deployment needs address assignment, prefix
  delegation or both, then implement the client lifecycle and configuration.
- **Server and leases**: define address/prefix allocation and lease policy,
  then implement the server and lease collections.
- **Relay**: define the required relay deployment and supported message forms,
  then implement request/reply forwarding.
- **Temporary addresses (IA_TA)**: decide whether support is needed. If so,
  add its separate four-byte header and codec coverage; the existing twelve-byte
  IA helpers explicitly accept only IA_NA/IA_PD.

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

- **Highly desirable expansion: rank paths and fail over without a restart**:
  Defer this architectural work from the reconciliation point fix. `discovery.d:137` prefers by link
  speed then recency. One logical peer owns a set of discovered/configured paths; claims,
  subscriptions, mirrored state, sequence/ACK state and queued work must survive path changes.
  The user's provisional default order is MAC > IPv6 > IPv4 > high-bandwidth serial > radio >
  low-bandwidth serial. Settle how that order combines physical-medium cost with encapsulation,
  operator overrides, health and recovery hysteresis. IPv6 discovery is not implemented today.
  Collect RTT per link from acknowledged exchanges (Karn-filtered) to drive the retransmit clock
  and demote degraded paths. Bind additional paths to the same established remote/session before
  transferring traffic, and distinguish link failure from a remote reboot/session epoch change.
  Beacons stay link-local; reachability through the fabric is a separate propagation mechanism.

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

- **Finish claimed device mirroring**: acknowledged claims already subscribe to `device:**`.
  The remaining model work needs node-scoped naming for remote
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

- **Re-announce an element whose access changes**: `access` is emitted once, at model-add time
  (`src/manager/sync/json_encoder.d:551`). A provider that becomes writable later - a Tesla vehicle
  session reaching `Phase.ready`, or a TWC master taking over or standing down - leaves
  already-introduced mirrors holding stale access, so
  their UIs may hide available controls or offer controls without agency. Emit an access change on the
  control plane, and make the mirror re-evaluate its peer binding.

## Infrastructure

- **Make clock-sensitive unittests hermetic**: tests that leave a `MonoTime` member at
  `MonoTime.init` and then compare it against a real `getTime()` only pass once the monotonic
  clock exceeds the interval under test, so they fail on a freshly booted CI runner. The tesla
  poll test is fixed; `protocol.obd`'s asleep-probe case still sets `_sent_time = MonoTime.init`
  and needs the clock past `probe_interval` (`src/protocol/obd/package.d:1034`). The structural
  answer is to stop reading the real clock in these tests: `handle_protocol_fault` and
  `issue_requests` call `getTime()` internally, so the time source has to be injectable before
  the tests can anchor on a synthetic base the way `protocol.tesla.vehicle_session`'s first
  unittest already does.

- **Repair the runtime test harness**: `test/test_harness.py` pipes stdin into
  `--interactive`, but startup requires a terminal and the Windows console
  stream reads console events. Use a terminal or supported session transport.
  Drain stderr during execution and terminate before waiting for EOF; the
  current shutdown reads stderr before stopping the process and can hang.

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

- **Complete the Linux kernel mirror** (`src/protocol/ip/linux_mirror.d`): a netlink transport
  failure stalls the main loop on the writer's 1s `SO_RCVTIMEO` backstop; move the ACK wait onto
  the reactor. A netdev that appears after its addresses exist (hot-plugged NIC) is only
  re-pushed by a property edit or the bridge offload's refresh; hook netdev appearance from the
  route-netlink watch above. The startup sweep of stale `RTPROT_OPENWATT` entries relies on
  `IFA_PROTO` for addresses, which kernels before 5.18 ignore; on those only routes are swept.

- **Neighbour table as a collection** (agreed 2026-09-09, next PR after #681): make
  `/protocol/ip/neighbour` and `neighbour6` collections (`address`, `mac`, `interface`, read-only
  `state`) on every build. Learned entries are dynamic objects, D-flagged like SLAAC addresses:
  on kernel-mirror builds created, updated and destroyed from `RTNLGRP_NEIGH` events on the
  shared listener in `driver/linux/netlink.d` (seeded by one `RTM_GETNEIGH` dump), on the
  internal stack from the existing cache. Static entries sync back: the mirror tracks them like
  addresses and routes and pushes `NUD_PERMANENT | NTF_EXT_LEARNED`, the flag doubling as the
  ownership marker for the startup sweep since neighbours carry no protocol tag; the internal
  stack installs them as permanent cache entries. The function-style neighbour prints go away.
  While there, move the listener off its per-tick non-blocking recv onto the reactor via
  `fdwatch`.

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
