# UX client task accumulator

Client-visible changes land here as dated task sections; UX clients (sync consumers) work
through them and remove sections as they are absorbed.

## 2026-09-20: ESP filesystem default changes to LittleFS

- The uRT update defaults ESP storage to LittleFS; SmartEVSE explicitly retains SPIFFS.
  Existing SPIFFS volumes require backup, explicit LittleFS formatting, and restoration of
  configuration and identity or re-adoption. Do not present re-adoption alone as a storage fix.
  Account for changed node identity and fleet membership when identity files are not restored,
  and verify persistence after reboot before treating migration as complete.

## 2026-09-17: `add` frames carry component templates

- The model-plane `add` frame gains an optional `tmpl`: the authority's component template for
  every node the path crosses, the device's own first, each followed by `/`
  (`Vehicle/Port/EnergyMeter/`). Split on `/` and drop the final empty piece; the segments then
  align one to one with the device and each component on the path.
- A chain that is present is authoritative: a segment sets that node's template, and an empty
  segment clears it (`Vehicle//EnergyMeter/` unclassifies the middle node, `/` unclassifies the
  device). A chain that is absent says nothing; never treat a missing `tmpl` as a clear.
- Devices owned by a peer previously arrived with no component templates at all, because the
  mirror builds components from element paths alone. Any client that classified components by
  template saw peer-owned devices as untyped and silently skipped them; that now resolves, so
  expect fleet devices to start appearing in template-driven views.
- A template can change after a device is already on screen (a fleet node upgrading, a binding
  that classifies its tree late, a template being cleared). Those arrive as
  `add {path, class:"component", tmpl}`: no `h`, no value, and `tmpl` always present; apply the
  chain to the named component and its ancestors. They are only sent to a session whose `hello`
  lists the `templates` capability; without it the new shape only appears on the next full
  introduction, i.e. after a reconnect.

## 2026-09-17: vehicle terminal moves under a `charge` port

- A `Vehicle` device now exposes `charge: Port` (`role=connection`, `flow=consume`) and the
  charge terminal lives under it. Element paths move: `meter.*` -> `charge.meter.*` and
  `control.*` -> `charge.control.*`. Nothing else in the vehicle tree moves; `battery`,
  `charging`, `hvac` and the rest stay at the device root.
- `charge.circuit` publishes the VIN. A car and an EVSE that publishes the same VIN on its
  `car` port now share a circuit and join with no configuration, so expect vehicles to start
  appearing attached to their charger in the energy flow graph instead of on an island of their
  own.
- A `/apps/energy/appliance` with `vin=` and no `device=` resolves the VIN-rooted
  vehicle device without changing the configured `device` property. Changing or clearing `vin`
  updates this fallback; an explicit `device` takes precedence. Its port carries the vehicle's
  own meter and charge control.

## 2026-09-16: JSON quantity scaling (uRT #297, adopted by #711)

- Consume each quantity's `q` and `u` together. An unspellable source scale now
  selects a spellable engineering prefix: `2.95` at `10^5 W` arrives as
  `{"q":2.95e2,"u":"kW"}`, while named units such as `bar` stay unchanged.
  Do not assume the value-frame unit always matches the element's declared unit.
- Accept exponent notation in all JSON numbers and plain numbers for bare scales
  without a unit spelling (`23302` at `10^-1` becomes `23302e-1`). Add regression
  coverage for pressure, scaled dimensionless sensors, and negative SI exponents.

## 2026-09-16: power regulator drops `window`

- `/driver/power/regulator` no longer has a `window` property; remove it from any regulator
  configuration view. Stored configuration carrying `window=` is now rejected as an unknown
  property, so migrate saved regulator configs before upgrading.
- Burst-fire duty now follows `level` directly at q16 resolution instead of quantising to
  `1/window` steps. Commanded level and delivered power previously diverged: at the default
  `window=50`, a commanded 25% delivered 26%, 99% saturated to 100%, and anything below about
  1.5% delivered nothing at all, while `applied-level` reported the commanded figure throughout.
  A client that worked around the dead bottom or saturated top of the range should drop those
  workarounds; the full 0-100 range is now linear in power.

## 2026-09-15: DHCPv4 lease quarantine (PR #705)

- `/protocol/dhcp/lease` gains a read-only `declined` boolean. A lease whose client sent
  DECLINE stays in the collection for ten minutes with `declined=true`, owning its address so
  it is not re-offered; show it as quarantined rather than as an active binding, and expect it
  to disappear when the quarantine lapses.
- Dynamic leases now expire and vanish on their own, and `expires` is a display value derived
  from the lease's monotonic deadline; a wall-clock correction no longer moves the real expiry.

## 2026-09-14: WebSocket sync sessions drop under sustained client backpressure

- A sync WebSocket now holds at most 128 KB of unsent frames (previously 4 MB). When a client
  stops reading and that fills, the server closes the socket. Keep the socket drained (do not
  pause reads while rendering), and reconnect with backoff on an unexpected close, resubscribing
  from scratch.

## 2026-09-11: device liveness and `status.online` (PR #663)

- Every device now carries a `status.online` boolean element holding one central reachability
  verdict, aggregated across every binding that can reach the device. Render a device's
  online/offline state from this element instead of per-protocol heuristics or the absence of
  value updates.
- The verdict has three states, and the element is written only once some source has voted.
  Treat a device with no `status.online` value as *unknown*, not offline, and show it as such;
  a device is offline only when the element reads false. Once published, losing every source
  (its last binding stopped, restarted, removed or disabled) reads offline, never back to unknown.
- A device stays online while any one source can still reach it, so a partially failing device
  reports online with some of its elements stale. Element-level staleness is still the client's
  own call; `status.online` does not answer it.
- `ComponentEvent.online` / `offline` now mean "backing source reachable / unreachable". The old
  tree-is-ready meaning moved to the new `ComponentEvent.materialised`. Anything that used
  `online` as the go-ahead to render a device's tree must switch to `materialised`.
- Bindings gain an `offline-timeout` duration property (see the `/binding` common properties in
  [CLI.md](../CLI.md)) that marks a device offline after a quiet period even while its transport
  stays up. Surface it wherever binding configuration is edited: default `0` (disabled), `30s`
  for CAN.
- Devices bound through OBD or Home Assistant availability/LWT do not vote yet
  and will stay unknown. A dropped peer link does not yet mark that peer's mirrored devices
  offline.

## 2026-09-09: Tesla vehicle write authority (PR #683)

- Use the vehicle's `control.min` value for charging sliders; Tesla VIN registration now
  publishes 5 A. Do not hardcode the generic 6 A vehicle default.
- Verify charging and HVAC controls against a ready Tesla session. Binding authority now
  permits writes; access changes after a mirror's introduction still need the sync-plane
  follow-up recorded in TODO.md. Check both existing and newly connected mirrors.

## 2026-09-09: IPv6 pools and retained parent allocations

- `/protocol/ip/pool6.prefix` is now an IPv6 network (`address/length`), with
  type `ipv6nwk`. Remove `prefix-length` controls and combine existing values
  into this single property. Valid configured lengths are 1..64; `::/0` is unset.
- Add the `pool` parent selector. Create a child with `pool=<parent>` and
  `prefix=::/56`. A nonzero prefix address written to the authority selects static
  mode and clears the parent; `::/length` changes the requested width while
  keeping the parent. Clearing `pool` retains the current network as static.
- Display the authoritative `prefix` received in sync snapshots and updates,
  including acquisitions and renumbering. Applying a prefix echo to a proxy
  must preserve its parent selection; do not interpret that echo as a user edit.
- Pool6 now exposes ActiveObject `running` and `status`. Parent loss does not
  imply child loss: the child retains its prefix and reservations, and stays
  online if exact reclamation succeeds after parent recovery or recreation.
  Failed reclamation takes the child and descendant pools offline to reacquire;
  clear dependent address views on their own lifecycle events.
- Continue keeping DHCPv6 client/server/lease controls unavailable. This change
  provides the allocator, not operational DHCPv6 roles.

## 2026-09-09: IPv6 zone in address text (PR #674 prerequisite)

- `inetaddr` values now render an IPv6 zone inside the brackets: `[fe80::1%eth0]:5353`. The zone
  is an interface NAME when it is an OpenWatt interface and a bare number when it is a host-stack
  interface OpenWatt does not manage. Parsers must accept `%zone` before `]`; unscoped addresses
  are unchanged. Property values such as sync `bind` lists may carry it. `/ping address=` accepts
  `fe80::1%<iface>` as an alternative to `iface=`.

## 2026-09-08: retrospective merge reconciliation

- Appliance `device`, `meter`, and `state` paths may be accepted before the
  target exists. Preserve configured paths in editors, display an unresolved
  target separately from an empty property, and tolerate late device discovery
  and late children. The backend now resolves both automatically while the energy
  app is started; destruction/recreation remains separate lifecycle work.
- Log viewers must accept Tiny's default of 64 entries and cap of 256 (normal
  builds: 256/1024). A streaming follow retains no rolling view history after
  emitting the initial history; clients needing scrollback must retain it.
- Tesla sessions can restart after repeated authentication failures and retain
  a fault status while reconnecting. Surface that status, and treat vehicle
  categories as independently refreshed samples. Correlated session faults now
  trigger a fresh handshake while retaining the affected operation's timed back-off;
  show that delay even after the handshake succeeds. A Ready session also expires after 45 seconds
  without an authenticated reply. Ordinary command rejections do not imply a broken
  session. Do not automatically replay controls after a reconnect or infer
  command success solely from Running; use observed vehicle state.
  Refused polls retain their category and cadence starts on accepted submission;
  do not assume a fixed refresh timestamp while the command queue is full.
  Show category back-off and latch reasons from session `status`; one failed
  telemetry category does not disable the others. Add scanner/VIN `backoff` and
  `reset-backoff` actions under `/protocol/tesla/vehicle-scanner`, including when
  the session is absent. Explain that reconnects preserve latches; explicit reset,
  key change, VIN/scanner removal or process restart clears them. Permission
  changes in the vehicle require an explicit reset. Reset never replays controls.
- Beken `/system/sysinfo` reports SRAM and, on BK7231N, DTCM pools. Render pool
  names and counts dynamically; BK7231T has no DTCM pool.
- Keep DHCPv6 client/server/lease controls unavailable: only the codec exists.
- Remove `/protocol/tesla/crypto-test` from diagnostic actions; the command was removed.
- Migrate `/protocol/ip/ping6` and `/interface/ethernet/ping` callers to
  `/ping address=<IPv4|IPv6|MAC> [count=] [iface=]`. Address family selects the
  protocol; both old command paths are removed. IP ping requires the internal
  IP stack. Consoles must handle cancellation when the selected interface goes
  offline or is removed; scoped replies are matched on that interface.
  Multicast requests can produce multiple replies (up to 64 distinct sources
  per request), so reply counts can exceed request counts.
  Handle correlated ICMP/ICMPv6 error lines, including MTU and parameter pointers;
  errors do not increase reply counts. Multicast requests remain open after an
  error and can report up to 64 distinct error sources per request.

## 2026-08-07: interfaces expose a `caps` property

- All `/interface` collections gain a read-only `caps` bitfield property naming the
  interface's transport promises: `ethernet`, `reliable` (acknowledged/retransmitted
  delivery), `ordered` (in-order delivery). Clients rendering interface detail views may
  surface it; absence of a flag means no promise, not a fault.

## 2026-08-07: UDP moved from stream to packet interface

- `/stream/udp` collection is removed. UDP is not a byte stream; it is now modelled as a
  raw-packet interface.
- New collection `/interface/udp` (type `udp`): properties `local-host`, `local-port`,
  `remote-host`, `remote-port`, plus the standard interface MTU/status/traffic properties.
  Clients enumerating interface types should expect the new type; anything offering
  `/stream/udp` in pickers/forms must drop it.
- Log sinks can no longer be given a UDP transport (syslog over UDP is unavailable) until
  sinks can bind a packet interface.

## 2026-08-10: ethernet stations gain `cfm-level`; mac ping/discover CLI split

- All ethernet-station interface collections (platform ethernet, bridge, vlan, wifi, udp)
  gain a `cfm-level` property (0-7, default 7): the 802.1ag maintenance level the station
  answers loopback at. Clients rendering interface detail/edit views may surface it.
- MAC `/ping` no longer accepts `identify=` and rejects multicast/broadcast
  addresses; it is now a unicast 802.1ag loopback (works against third-party CFM gear).
- New command `/interface/ethernet/discover`: broadcast sweep listing OW stations on the
  segment with their system name and universal addresses. Anything that offered broadcast
  ping as a discovery affordance should move to it.

## 2026-08-10: constant-valued elements no longer carry a one-record history

- An element that has never been given a retention policy now keeps its latest value
  directly and has no series behind it. This is the normal case for `constant`/`config`
  elements, notably the whole `info.*` subtree (manufacturer, model, serial, firmware).
- Consequence for clients: a history/backfill request for such an element returns an empty
  range rather than the single synthetic record it used to report. The element's current
  value, timestamp and metadata are unaffected, so anything rendering the value needs no
  change; only views that plot or tabulate history should treat "no history" as normal for
  these rather than as an error or a gap.
- Elements that do have retention (everything the default policy covers, plus event/point
  elements) are unchanged.

## 2026-08-11: static file mounts gain writes and opt-in CORS

- `/protocol/http/static` mounts accept `PUT` (store a file, `201` created / `200`
  replaced) and `DELETE` (`200`, or `404` when absent) beneath the mount's URI, plus
  `OPTIONS` preflight. The config file editor should target these directly.
- New property `allowed-origin` (empty | `*` | one origin): CORS policy for the mount.
  The default (empty) sends no CORS headers, so a web client served from a different
  origin than the backend must have the mount configured with its origin (or `*`) before
  cross-origin reads or writes work. Error statuses carry the CORS headers too, so a
  cross-origin client sees real 404/403 codes.
- Uploads stream to disk: `PUT` bodies are no longer capped by the server's 64KB
  `max-request-body`, and an interrupted upload leaves the previous file intact. Requests
  the mount refuses (403, 405, 409, 500) still drain the body and answer with the real
  status, so large uploads never die as opaque network errors.
- Downloads above 64KB stream from disk with a known `Content-Length` and are NOT
  content-encoded, where the previous buffered path gzipped them. Large text pays for this
  on the wire: the 132KB `goodwe_ems.conf` gzips ~4.9x, so it now transfers at full size.
  Compressing a streamed body needs `Transfer-Encoding: chunked` (the compressed length
  isn't known up front) plus an incremental compressor, and urt.zip's is whole-buffer
  only, so this is deferred. Clients should not assume large files arrive compressed.
- `.conf` and `.log` serve as `text/plain`, `.yaml`/`.yml` as `text/yaml`, so they display
  in a browser tab instead of downloading as `application/octet-stream`.
- There is no ETag/If-Match yet: two editors saving the same file last-writer-wins.

## 2026-08-12: link speed is populated on every interface, and on streams

- `tx-link-speed` / `rx-link-speed` (bits per second) previously only ever had a value on
  platform ethernet interfaces. Every interface type now reports one where it can: modbus,
  can, tesla-twc, zigbee, ble, i2c, ash, cpc (trunk and endpoints), websocket, ppp, vlan,
  bridge and udp. Views that hid the field, special-cased ethernet, or assumed it meant
  "ethernet only" should now render it for any interface.
- `0` still means unknown and must be rendered as such, not as "0 bit/s" or as a down link.
  It is a genuine outcome: a modbus interface reached over a TCP bridge with no configured
  or estimated baud honestly does not know its bus rate. `link-status` remains the only
  thing that says whether the link is up.
- The fields are now cleared when an interface goes offline and restamped when it comes
  back, so a client holding a cached value across a link bounce sees it go to 0 and back.
- Streams gain the same two read-only properties, so `/stream/print` and stream detail
  views can show the rate of a serial port, or of whatever a tunnel rides on.
- WLAN interfaces report the negotiated PHY rate where the platform exposes it, and the
  theoretical maximum for the negotiated mode where it does not, so the number moves with
  link quality on some platforms and is a fixed ceiling on others. Clients should not
  present it as a measured throughput; `tx-rate`/`rx-rate` remain the measured counters.

## 2026-08-13: WLAN interfaces report the negotiated PHY as `phy-mode`

- New read-only property `phy-mode` on `/interface/wlan`, a display string such as `VHT80
  2SS`: the 802.11 mode name with the channel width folded in the way the standard names
  them, the spatial stream count, and `SGI` when a short guard interval is in use.
- It is a label, not something to parse or compute with. The number that goes with it is
  already `tx-link-speed`/`rx-link-speed`. Render it as-is.
- Empty means not associated, or that the platform could not name the PHY at all. Parts are
  omitted rather than guessed, so the string is not a fixed shape: Windows reports only the
  family (`VHT`) because the association carries no width or stream count, and `11a`/`11b`/`11g`
  never carry a width. Don't assume three space-separated fields.
- It sits with `bssid`/`rssi`/`signal-quality` because it describes the association, not the
  radio.

## 2026-08-13: radios report `phy-capability`, APs report their operating `phy-mode`

- `phy-mode` is now on `/interface/ap` as well as `/interface/wlan`, same format and same
  rules. On an AP it is what the BSS operates at, which is the ceiling for every client on
  it, not any one client's negotiated rate. Per-client PHY is not reported: there is no
  client object to attach it to.
- New read-only `phy-capability` on `/interface/wifi` (the radio), same format again: the
  hardware's own ceiling, e.g. `HE160 2SS`. A bound WLAN's `phy-mode` is at or below it.
  A concrete `band` reports that band's ceiling; `band=any` reports the best supported band.
  Useful as the denominator when showing how good a link is relative to the hardware.
- Expect these to be partly filled, and don't infer "broken" from a short string. Linux and
  ESP32 report all three parts; Windows reports no capability at all, as it exposes no API
  for it.
- Worth surfacing in UI: on Linux an AP currently reads legacy `11g` on 2.4 GHz or `11a` on
  5/6 GHz, because both AP backends run the BSS non-HT, so clients are capped at 54 Mbit/s
  no matter what the radio can do. That is real, not a reporting artifact.

## 2026-09-10: TWC discovery and charge controls

- Replace the old TWC free commands with the `/protocol/tesla/twc` collection.
  Configure `stream` or `interface`; discovered bindings and devices use `twc_<hex-id>`.
  Migrate appliance device references and add `master` to manually configured TWC bindings.
- Configure the shared fleet budget on `TeslaTWCMaster.max-current` (32A default).
  Remove `max-current` from binding forms; binding properties only identify master,
  slave id, and Device. Do not migrate several per-charger ceilings by summing them:
  the master property must match the actual shared installation limit.
- `grid.control.max` is the read-only discovered hardware maximum. Move user/policy
  ceilings to writable `grid.control.cap` (zero means uncapped; nonzero minimum 5A).
  Keep writable `setpoint` as requested demand. Display read-only `allocated` for
  the last commanded allocation and `accepted` for the charger's reported limit;
  neither value should overwrite the request or cap. All values and `step` carry amps.
- TWC `setpoint` and `cap` access now follows the master's bus agency: read/write
  only while active, read-only while observing. Live access-change propagation is
  still TODO; clients must eventually update controls without reconnecting.
- A circuit-budget reduction waits for charger acknowledgements before reallocating
  current. Budgets below 5A per eligible charger remain unsupported pending stop/admission policy.

## 2026-09-01: `Wh` is an energy unit, not a duration

- An element carrying watt-hours (a TWC's `status.lifetime_energy`, a meter's `import`)
  arrives over sync as `"unit":"Wh"` in its type frame, and each value as
  `{"q":394167000,"u":"Wh"}`. Both were verified against the encoders and the unit parser
  round-trips `Wh` back to watt-hours exactly, so a client showing this as a time is
  reading the unit wrong on its own side.
- The likely trap is tokenising the suffix and finding `h` for hours. Units are whole
  symbols: match `Wh`, `kWh`, `MWh`, `varh`, `VAh` before any single-letter fallback.
- Rendering a quantity from `u` alone is enough; there is no need to reduce to base units.
  `Wh` is joules scaled by 3600, so a client that normalises will get joules, never
  seconds.
## 2026-09-02: saved config and a config-dirty flag for a Save button

- `/system/config/save` publishes a numbered config revision, keeps five completed revisions,
  and reports its filename. `file=` supplies a revision base, not an exact output filename.
  Boot selects the newest valid saved revision in place of startup.conf. `.tmp` files are ignored;
  corrupt/unparseable revisions are retired as `.bad` with logged rollback. Exhausted revisions
  do not trigger factory defaults. Surface rollback messages and retain access to recovery logs.
- Revision publication does not confirm management reachability. A confirmation-window protocol
  is still outstanding; do not present save success as proof a remote update is safe.
- Consume secret `services`, DNS `protocols`, and certificate lists as arrays rather than
  comma-joined strings. TCP-client `remote` now reports the live hostname or typed address;
  do not assume it is always a hostname string. Telnet servers are managed collection objects
  with add/remove/get/set/reset/print operations and a `port` property.
- `/system/sysinfo config-dirty` returns `true`/`false`: whether config has been modified since boot
  or the last save. The human `sysinfo` output shows it as `Config: modified|saved`.
- Suggested UX: poll it alongside the existing sysinfo health poll and show a Save button (invoking
  `/system/config/save`) whenever it reads `true`. It clears on a successful save to the default path.
- Dirtiness is event-based, not a diff: setting a property back to its old value still reads dirty
  until saved. Save success confirms a file write, not a complete future restore: #665
  exports create-disabled, configure, and enable phases. Clients consuming exports must
  accept `set` commands as well as `add`. References to excluded objects and reconciliation
  with boot-created objects remain incomplete. Do not describe the saved state as verified
  to survive reboot; see `TODO.md`.

## 2026-09-08: energy element tree slimming, itemised with the frontend

Parts of the wide `topology.*` and `circuit.*` trees are transient reasoning state wearing
element costumes, but the UX renders the site graph in meaningful detail, so this is an
itemised decision with the frontend rather than a sweep. The rule: elements exist for what a
user edits, a third party samples, or the UX presents. Whatever fails all three moves to D
structs and console views. Nothing below has happened yet; each needs a client answer first.

- `circuit.bus.*` KEEP. This is the flow-colouring data; `local_fraction` is the per-node
  green/red ratio.
- `circuit.terminal.*` DEMOTE. A bus is one electrical node, so everything drawn from it
  shares the bus's mix and per-port local/grid is derivable (port draw times bus ratio).
  Battery `soc` moves onto battery-kind boundary entries first, one bar per battery on the
  boundary marker rather than per observing terminal.
- `circuit.branch.*` and `topology.link.*` MERGE into one edge namespace: endpoints, closed,
  capacity, live current and power, utilisation (the UX renders CB load-vs-capacity meters).
  No per-edge blend is published: a bus mixes perfectly, so an edge's blend is exactly the
  source-side bus's `local_fraction`, determined by the edge's flow sign plus data already
  published. The painting rule is documented for the frontend instead of duplicated as
  elements. The other tree retires.
- `circuit.production.*` RETIRE once boundary entries gain an aggregate-vs-member `mismatch`
  flag. `production_contribution.<index>` uses unstable array-position keys and demotes to the
  console circuit table.
- `topology.appliance.*` DELETE: a triple-published meter mirror whose identity is superseded
  by `appliance.*` and `boundary.*`. `topology.port.*` keeps the surviving meter mirror,
  slimmed. `topology.appliance_index` deletes after the UX migrates off it.

Two behaviours worth knowing while planning views: energy counters do not bridge outages
(power rides through by inference, daily counters stall and self-heal when the meter returns,
and energy moved while a meter was both silent and reset is lost to the daily account), and
diffuse sink energy is deliberately not integrated, because sinks have no counters and
integrating inferred power would fabricate data.
