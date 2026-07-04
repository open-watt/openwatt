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

- **Unknown-SOC policy semantics**: with no car telemetry, `soc(N)` is never satisfied, so a
  floor-tier car policy runs mv=inf and pulls grid at full rate whenever plugged. Decide: treat
  unknown-SOC floor goals as satisfied (can't verify -> don't burn grid) while deadline-shaped
  tiers still drive? Revisit when Tesla BLE lands SOC.

- **Floor-tier ranking anomaly**: zephyr_reserve (floor, mv=inf in /why) is shadowed by
  zephyr_ready (essential, 0.8) in the allocator queue - suggests the planner's floor marginal
  value goes NaN in the allocator pass while the /why recompute shows inf. Harmless today (same
  setpoint either way) but the ordering is wrong; look in analyse_policy.

- **Allocator drives max flat-out**: no planner-informed modulation (existing TODO in
  allocator.d); should consult required_kwh/slack to pick a setpoint. Also nothing publishes
  min_dwell for the TWC control, so surplus tracking could churn the setpoint.

## Tesla TWC

- **Car-presence heuristic conflates scheduling with fact**: master.d treats heartbeat
  `Ready && current==0` as "car disconnected" and clears the VIN flags. That was a VIN-poll
  scheduling hint (5174d165); a plugged-but-sleeping car also sits at Ready+0, so presence flaps
  and the published `circuit` VIN flaps with it. Fix: latch presence on VIN evidence - on Ready+0
  re-poll VIN1; N consecutive zero-byte responses = real unplug (clear VIN); non-zero = still
  present (changed prefix = car swap, recollect).

- **Release semantics**: the allocator's release writes 0A, and the master then sends
  LimitCurrent 0 - below the TWC's 5A floor and not really expressible in the protocol; suspected
  car-error trigger. Decide what "stop" writes to a TWC (clamp to min? proper stop sequence?).

- **Recovery is harsh**: any iface link flap resets all chargers, replays the ~4s boot sequence,
  then waits silently for SlaveLinkReady - which the slave only broadcasts after its own
  master-loss timeout, so every hiccup costs minutes of masterless time and the car reports
  "no primary wall connector". Keep heartbeating / re-adopt without the full ceremony.

## Infrastructure

- **API response truncation**: /api/get responses truncate around 140KB (seen querying
  `energy.*`); clients get invalid JSON with no error.

- **TLS server-mode transport ownership**: shutdown destroys the handed-in listener stream;
  if a server-side TCP ever takes multiple ticks to shut down after going offline, the same
  double-destroy shape fixed for client mode (b4005c88) exists there. Same scrutiny needed.
