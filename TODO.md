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

## Infrastructure

- **Serial rx reader -> shared fd reactor**: SerialStream rx is now event-driven. On linux a
  bespoke `SerialReader` poll() thread in `router/stream/serial.d` owns the tty fds + an eventfd
  wake, reads them, and marshals each read to the main thread via `g_app.post_event` ->
  `SerialStream.incoming()`. It is a near-copy of the `protocol.ip` `SocketWorker` (SPSC rings +
  backpressure semaphore + `post_event` coalescing). Fold both onto ONE shared main-thread fd
  reactor - the natural home is the manager layer (it already owns `schedule`/`post_event`/the
  event queue): expose something like `g_app.watch_fd(fd, &on_readable)` and register both serial
  tty fds and the IP sockets with it, so neither subsystem carries its own reader-thread plumbing.
  Until then: non-linux platforms (Windows/other-Posix/Embedded) still get rx via an interim
  drain-in-`update()` -> `incoming()` (a poll at the serial layer only, kept so `rx_handler`
  works everywhere); Windows/embedded true push (overlapped-IOCP / UART rx-IRQ) is the follow-up.
  Note: this pass was data-path-only, so the genuine timers left in `update()` are intentional -
  ASH retransmit (250ms) + RST retry (`ashv2.d`), EZSP request timeout (200ms, `client.d`), and
  the Zigbee NCP counter poll (`iface.d`); moving those onto `g_app.schedule`/the 1s heartbeat is
  a separate cleanup.

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
