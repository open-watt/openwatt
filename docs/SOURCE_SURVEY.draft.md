# Boundary survey: remaining work

Status: the boundary-edge accounting model is IMPLEMENTED (branch
`ow/source-survey`, commits b31f317..a4aef43). The model itself is documented
in [ENERGY.draft.md](ENERGY.draft.md): boundary edges as the single accounting
authority, port groups with conservation constraints, geometry-declared sinks,
closed-world circuits, one account reduction with metadata classification.

This document now tracks only the deferred follow-ups, roughly in the order
they are worth doing.

## 1. Provenance representation upgrade

The solver carries the flat provenance enum. The upgrade is a richer tag per
solved value, combined through a single funnel so the representation is a
value-type swap rather than a solver restructure:

- **Requirement**: a value inferred from another inferred point stays
  distinguishable from a direct measurement, and a later measured
  contradiction becomes a reconciliation mismatch instead of silently
  replacing history.
- **Recommended form**: a dependency set of seed meters (small fixed bitset),
  so mismatch and outage reports can name the meters a value stands on, and
  outage-bridged values are distinguishable from never-metered ones.
- The written precedence rule (measured outranks inferred; boundary-most
  authoritative among equals; disagreement beyond the noise floor keeps the
  winner and reports a mismatch; never silently average) holds regardless of
  representation.

## 2. Fault and underdetermined reporting

The solver should report, per connected constraint component, its closure
residual and the identities of its still-free variables. Severity falls out:

1. Normally-measured boundary degraded to inferred: accounting continues;
   alert on the provenance transition or the device's own offline state.
2. Multiple dark boundaries in one component: category detail lost, net flow
   still accounted, culprits named ("solar and battery on dc bus
   unmeasurable; combined net flow X W").
3. Residual on a fully-determined circuit: fault (meter error, wiring or sign
   mismatch, undeclared equipment).
4. Sink absorption: expected diffuse flow, a normal account.

Today residuals still publish through the per-bus rogue/coverage fields; the
component-level report with named free variables is not built. Never allocate
a multi-unknown residual per port.

## 3. Contact-state zero seeding

Review sharpened the scope: appliance ports carry contact state too
(read_port_closed), but ports_connected treats appliances as unconditional
junctions and group inference ignores per-port state, so an open contactor
would still exchange inferred energy. An open port is a known zero, not an
unknown; seed it as such here. Latent today: nothing in-tree publishes
closed=false on an appliance port.

Open switchgear should seed explicit zero through-flow on its ports instead
of leaving them dark. Deferred because it changes bus coverage classification
(dark/bounded becomes measured), which is account-visible; land it together
with a review of the coverage semantics.

## 4. Attribution seeding from boundaries (SHIPPED)

`attribution.seed_source_mix` now consumes the solved boundary flows: a
grid-kind in-flow seeds grid supply, every other in-flow seeds local
(diffuse/unclassified supply is local by nature; battery discharge is local
regardless of what charged it), and residuals never seed (error is not
energy). The load-shortfall heuristic survives only as a fallback for a grid
bus no grid boundary reported on. The network-flow projection downstream of
the seeds is unchanged.

## 5. Boundary publishing is the UX enumeration surface (SHIPPED, complete)

Implemented: `boundary.<name>.*` (kind, owner, origin, port, circuit, island,
directional power, provenance, counters, soc on batteries, mismatch on owned
solar) and `appliance.<name>.*`; the demotions in section 9 are executed.
Per-group loss is published too: `appliance.<name>.loss_power`
(self-consumption/conversion loss for multi-port appliances) and
`topology.link.<id>.loss_power`/`.mismatch` (two-sides-disagree alarm on
switchgear and sinks). Nothing remains from this section. Original intent
follows.

Publish the boundary list as a flat, stable, enumerable namespace; it IS the
user-facing entity list, and the UX must not have to walk the topology debug
trees to build one. Per boundary, keyed by a stable name (owner appliance
name, or the link name for sinks/handovers):

- `kind` (solar/generator/battery/grid/load/unclassified), `owner`, `island`,
  `circuit`;
- live directional power (into/out of the site) and provenance
  (measured/inferred);
- corrected energy-counter values where a meter backs the boundary.

UX filters this one list for every presentation view: kind load with an
owner = appliances; kind load from a sink = per-circuit general load; solar
and generator = generation sources; battery; grid. Aggregation at any level
(island, kind, owner) is summation over the same list, guaranteed consistent
with the island accounts because both are reductions of the same flows.

Alongside it, a small appliance index for presentation entities that have no
boundary yet (intent anchors, unplugged cars): name, kind, connected
boundary reference when present, control availability. This replaces
`topology.appliance_index` as the supported surface; the `topology.*` and
`circuit.*` trees then demote to debug per section 9.

Also publish per-group loss/self-consumption (`PortGroup.loss_power`,
`mismatch`) for device-loss and wiring-alarm views. All values are computed
each sample; only the publishers are missing.

## 6. Link loss providers

Until a provider supplies loss, single-unknown group inference manufactures
a zero-loss value for conversion appliances; the error is bounded by device
loss and the value is marked inferred, but accounts built on it inherit the
approximation.

Every link/switchgear constraint already carries a loss term, default zero.
Providers may later supply it, keyed by declared link identity so learned
state survives topology rebuilds:

- configured bound (watts or percent) or configured resistance;
- a learned fit: with meters at both ends, `deltaV * I` is a well-conditioned
  loss estimator (far better than subtracting two large powers), the fitted
  slope is the run's resistance, the intercept self-calibrates the voltmeter
  pair, and drift in fitted R is a corroding-joint diagnostic.

Correct the propagated value by the loss estimate; provenance marks values
standing on a learned parameter.

## 7. Transfer switches

`PortGroupKind.transfer` exists and asserts TODO. Needs a declaration surface
(two input ports, one output, A/B/off position from contact feedback or a
live element), connectivity per position, and the §acceptance transfer tests.
Do not infer position from instantaneous power.

## 8. Smaller items

- **Flow-domain bound tightening**: on underdetermined components, use
  supply/consume-only domains to publish directional bounds (never a per-port
  allocation).
- **Diffuse daily energy**: sinks have no counters; integrating inferred
  power would fabricate energy data, so it stays out unless demanded, and
  then explicitly marked as derived.
- **Per-meter noise floors**: a single constant floor (50 W / 2 percent of
  flow scale) suffices; refine per meter accuracy class later.
- **Production layer: RESOLVED, retained internally.** Its element surface
  and topology-survey role are deleted; what remains is the documented
  aggregate-vs-member reconciliation policy itself, feeding solar daily
  counters (a meterless inferred pv boundary is counted by its interior
  mppt meters, aggregate authoritative) and the boundary mismatch flag.
  Rewriting that boundary-side would relocate the same policy without
  deleting coverage; not worth it.
- **Energy counters do not bridge outages** (documented behavior): power
  rides through by inference; daily counters stall and self-heal when the
  meter returns, and energy transferred while a meter was both silent and
  reset is lost to the daily account.

## 9. History recording and element-footprint audit

Status: recording is enabled and CURATED. Recording is opt-in by
construction: a `Recorder` with no `filter=` records nothing, and each
conf recorder names the class it captures. The filter is a comma list of
path patterns where a leading `!` excludes, so the device archive is
`filter="*,!energy.*,!config.*"` (raw data-source samples) and the runtime
state classes are named explicitly. The reference site went from ~2090
captured series to ~400.

Delivery is already built: the sync/websocket protocol carries
`history_req` / `history` frames (`inbound_history_req` in
[../src/manager/sync/package.d](../src/manager/sync/package.d)), answered
synchronously from RAM buckets plus the `.ows` container. Console
`/record/query` and `/record/graph` serve from the same local path.

Remaining:

- **Container retention/rotation**: `.ows` files grow without bound.
  Needs a size/age budget per series or per recorder. This is now the only
  thing between the current state and leaving recording on indefinitely.
- **Class-specific retention**: the short class (budget, allocations) wants
  days, not months; today every recorder retains alike, so the classes are
  separated by recorder but not yet by policy.

The retention classes as arbitrated:

- **Long history (UX graphing)**: island `account.*` powers and today
  counters (grid import/export, per-battery charge/discharge, per-source
  solar, rogue), the per-boundary flow views, battery SOC.
- **Short history (local reasoning)**: planner budget, allocation decisions,
  coverage/mismatch flags; enough to answer "what just happened", days not
  months.
- **No history, audit before demoting**: parts of the wide `topology.*` and
  `circuit.*` trees are transient reasoning state wearing element costumes,
  but the UX renders the site graph in meaningful detail, so demotion is an
  itemised decision with the frontend, not a sweep. Elements exist for what
  a user edits, a 3rd party samples, or the UX presents; whatever fails all
  three moves to D structs and console views, which is also the same fix as
  the first-publish element storm below.

  Arbitrated so far:

  - `circuit.bus.*` KEEP: the flow-coloring data (local_fraction is the
    per-node green/red ratio). The mix treatment is defined by the seeding
    rules in section 4 (unclassified/diffuse is local; fault residuals are
    excluded).
  - `circuit.terminal.*` DEMOTE: a bus is one electrical node, so
    everything drawn from it shares the bus's mix; per-port local/grid is
    derivable (port draw times bus ratio) and need not be published. Move
    battery `soc` onto battery-kind boundary entries first (from the store
    reconciliation, which already merges multi-view SOC; one bar per
    battery, on the boundary marker, not per observing terminal).
  - `circuit.branch.*` and `topology.link.*` MERGE into one edge namespace:
    endpoints, closed, capacity, live current/power, utilisation (the UX
    renders CB load-vs-capacity meters). No per-edge blend: a bus mixes
    perfectly, so the blend on an edge is exactly the source-side bus's
    local_fraction, fully determined by the edge's flow sign plus data
    already published; the painting rule is documented for the frontend
    instead of duplicated as elements. Retire the other tree.
  - `circuit.production.*` RETIRE after the boundary entries gain an
    aggregate-vs-member `mismatch` flag; `production_contribution.<index>`
    (unstable array-position keys) demotes to the console circuit table.
  - `topology.appliance.*` DELETE (triple-published meter mirror; identity
    superseded by `appliance.*`/`boundary.*`); `topology.port.*` keeps the
    surviving meter mirror, slimmed. `topology.appliance_index` deletes
    after UX migrates.

Related: the daily counters in accounts.d are hand-rolled reset-banking
around live meter totals; once recording lands they become
`value_at(source, midnight)` queries against the store (existing
TODO(0.6, db.Stream)). Unmetered categories (rogue, sink diffuse) have no
counter to record; daily energy for them requires the explicit
integrate-with-derived-provenance decision (section 8).

## 10. Performance work

The first energy update after boot logged 233ms, which is far beyond what
this graph size justifies. Profile before optimizing; the existing
`log_slow_phase` / `log_slow_topology_publish` subdivisions (layout,
cache_bind, values) localize it. Known suspects and strategies, roughly in
expected-payoff order:

- **Element-creation storm on first publish**: hundreds of
  `find_or_create_element` calls, each tconcat-ing a full dot path and
  walking the component tree with a linear child search per level, each
  `set_element` allocating a fresh String, each creation fanning out
  notifications to sync/ws/api subscribers. Strategies: per-component child
  index, a bulk-bind mode that suppresses per-element notification until the
  batch completes, reuse of the path buffer, set-if-changed for strings.
- **Boot rebuild storm**: every link/appliance startup requests a topology
  rebuild and every shape element change marks dirty; early boot can rebuild
  the graph (and re-bind publishers) many times in consecutive frames.
  Debounce rebuilds until configuration settles.
- **Per-sample allocation churn**: `rebuild_productions` runs every sample
  and `retain_production_string` heap-copies owner/group/port/circuit for
  every contribution each time; battery-store contribution collection is
  similar. Retain strings per topology rebuild, not per sample. The island
  members string in the account publisher also rebuilds per sample.
- **String identity -> IDs**: name comparisons should be interned indices or
  pointers, not string scans. Sites: the `buses` map keyed by string,
  production owner/group/circuit compares, `circuit_in_island` for
  production contributions, `attribution.terminal_index` (linear over
  ports), `is_first_owner_port` (O(ports^2) in the publisher). Island
  membership for boundary accounts already compares `Bus*` directly; extend
  the same treatment outward.
- **Solver rescan**: the fixed point deliberately solves one unknown per
  pass and rescans all buses and groups each pass, O(unknowns x graph).
  Fine at current scale; the work-queue formulation (seed, solve, enqueue
  adjacent constraints) removes the quadratic if large sites appear.

## Out of scope (unchanged)

- A general nonlinear power-flow solver.
- Fabricating per-port values when several unknowns leave the system
  underdetermined.
- Replacing battery store identity/SOC reconciliation.
- Replacing `DailySnapshot` with database-backed historical queries.
