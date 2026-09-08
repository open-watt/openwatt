# Energy element contract: boundary-model transition

Audience: the web frontend / UX team. The energy app's accounting was rebuilt
around boundary edges (branch `ow/source-survey`). Most of the element
contract is unchanged; this document lists exactly what moved, what it now
means, and what is coming next so views can be planned rather than patched.

## 1. The model shift in one paragraph

Accounting now happens only at **boundary edges**: the points where power
crosses out of the modeled graph (a one-port appliance's connection, a
dangling port such as an inverter's MPPT input, the grid handover). Every
boundary contributes to exactly one account, classified by metadata (declared
role or equipment kind), never by which way power happens to flow. Interior
meters no longer source accounts; they verify. Consequence for UX: numbers
are attributable to a specific named edge, and "unexplained" power is an
explicit, shrinking category rather than a smear.

## 2. Semantic changes to existing elements

### 2.1 `islands.<id>.account.rogue.*` composition changed

- Previously: unattributed circuit residuals only.
- Now: residuals PLUS measured-but-unclassified boundary flows. Equipment
  with no role/kind tag used to vanish from accounts entirely; it now lands
  here. Expect rogue generation to be nonzero on sites with untagged
  generators.
- Declaring a diffuse-load sink on a circuit (a parent-only link) REMOVES
  that circuit's plug-load residual from rogue: it becomes a solved,
  load-classified boundary. Total load is unchanged; rogue shrinks. The
  per-sink figure is its `boundary.<link_name>.*` entry (section 4).
- Copy suggestion: this account increasingly means "unclassified", not
  "suspicious"; consider renaming in the UI when section 4 lands.

### 2.2 `account.solar.power` and nighttime standby

Solar is the net flow of solar-classified boundaries. A hybrid inverter's
MPPT boundary reads ~0 at night (panels draw nothing); its standby power
arrives through the interior grid port and lands in the appliance's
self-consumption (the sum of all its port powers, published with the
group-loss view). Only a one-port solar appliance (a net-metered
microinverter drawing standby through its only connection) can take the
solar account slightly negative at night; show it and tooltip it as standby
draw rather than clamping.

### 2.3 `account.battery.today.charge` / `.discharge` both accumulate

The old implicit-terminal path misattributed one direction on some
configurations. Both counters now accrue correctly from the battery
boundary's meters. Dashboards comparing across the upgrade will see a step
change; this is a correction, not noise.

### 2.4 Grid daily counters

Same elements (`account.grid.today.import/export`), now sourced from the
grid handover boundary's meters instead of a special-cased root-bus scan.
Values are identical on conventional configurations.

## 3. Shape and type changes

- **`circuit.schema_version` and `topology.schema_version` are now 2.**
  Version 1 is the pre-boundary contract; a consumer built against v1
  should treat v2 as this document. Gate on the version rather than
  probing for the removed namespaces.

- **New ports appear** in `topology.port.*`:
  dangling ports (retained MPPT/battery inputs) and sink endpoints
  (`<link>.connection`, `<link>.child`). They publish `bus=""` and may have
  `owner=""`. Tolerate the empty strings; do not render dangling ports as
  wiring errors -- they are boundary edges, arguably the most interesting
  ports on the site.
- **Ports with a battery behind them publish `soc`**:
  `topology.port.<id>.soc` is the device's own gauge at that port (an
  inverter's battery port, a BMS connection). The field exists only where
  the device reports one; the reconciled multi-view value remains on the
  battery boundary entry. Render appliance-card bands from the port value,
  site-level battery state from the boundary.
- **Appliance cards are built from ports**: select `topology.port.*` where
  `owner` equals the appliance name -- one band per port, labeled by
  `port`/`port_role`, full meter block plus `soc` where present. The old
  `topology.appliance.*` mirror is gone; `topology.link.*` entries with
  `kind=appliance` are the appliance's internal legs, not circuit edges --
  do not draw them as breakers.
- **Float capacities**: `topology.link.<id>.capacity` and
  `control_path.<name>.limiting_capacity_amps` changed int ->
  float (fractional amps are legal; config accepts `capacity=20A`).
- **Production contributions**: `circuit` may be empty for dangling members;
  member power is now always generation-positive (no frame mixing).

## 4. The enumeration surface (available now) and what follows

**Published now** -- the supported entity list for all presentation views:

- `boundary.<name>.*`: one entry per accountable edge, keyed by its declared
  name (`house_gpo_outlets`, `dishwasher`, `main`, `cabin_solar.solar.mppt1`).
  Fields: `kind` (solar/generator/battery/grid/load/unclassified), `owner`,
  `origin` (appliance/switchgear/handover/sink -- what declared it), `port`
  (the exact topology port id, i.e. the pin in the site graph this boundary
  hangs from), `circuit`, `island`, `power_in`/`power_out` (watts into/out
  of the site), `provenance` (measured / inferred-* / missing),
  `energy_in`/`energy_out`
  (corrected counters where a meter backs the boundary). Filter by kind to
  build every list: appliances (load with owner), per-circuit general load
  (sinks), generation, batteries, grid. Sum any subset for aggregates; the
  island accounts are the same reduction.

  A boundary carries accounting semantics ONLY; physical data (capacity,
  contact state, meters) lives on the topology entity its `port` points at.
  The earlier `edge_kind`/`capacity`/`closed` duplication on switchgear
  boundaries is REMOVED: parent-only links (sinks, terminal breakers) now
  publish as first-class `topology.link.<id>.*` entries -- endpoints
  (`child` is empty for a dangling end), kind, capacity, closed, live
  current/utilisation, loss/mismatch -- so the network graph is
  topology-first and boundaries are lightweight references onto it.
- `appliance.<name>.*`: `kind`, `circuit`, `boundary` (key into the list
  above, empty when none), `connected` -- covers presentation entities that
  have no boundary (intent anchors, unplugged cars). Multi-port appliances
  also publish `loss_power`: live self-consumption / conversion loss (the sum
  of all port powers when every port is solved; empty otherwise).
- `topology.link.<id>.loss_power` / `.mismatch`: for breakers and sinks the
  same port sum is a cross-check, and `mismatch=true` means the two sides
  disagree beyond meter noise (max of 50 W and 2 percent of flow) -- a
  wiring/calibration alarm worth a distinct visual treatment.

### Labeling: mapping boundary keys to user-facing names

The boundary key is the configuration name of the thing that declared it,
so it is already human-chosen; the association strategy for display labels:

1. **`owner` non-empty**: the boundary belongs to that appliance. Label it
   with your appliance display name; `appliance.<owner>.boundary` gives the
   reverse mapping. When one appliance has several boundaries the key is
   `<owner>.<port path>` (`cabin_solar.solar.mppt1`); the path suffix is the
   sub-label ("MPPT 1").
2. **`origin=sink`**: a declared diffuse-load catchall. Label from the
   circuit: "General load on <circuit>" / "Outlets"; the key itself
   (`house_gpo_outlets`) is the installer's own chosen name and works as a
   default.
3. **`kind=grid`**: the utility connection; label "Grid".
4. **`origin=handover`, `owner` empty**: role-declared unmodeled equipment
   (an implicit stand-in). Label from kind + circuit: "Solar on <circuit>",
   "Battery on <circuit>". These disappear automatically when the real
   equipment is modeled, replaced by an owned boundary.

`origin` publishes the declaring group's kind:
appliance / switchgear / transfer / handover / sink.

### Site header stats

The top-level dashboard figures, all per island (the on-grid island is the
one whose `mode` is `on_grid`):

| Stat | Source |
|------|--------|
| Local/grid mix | `account.local_fraction`: fraction of consumption served locally (1 while exporting; battery discharge counts as local regardless of what charged it) |
| Overall production | `account.generation.power - account.battery.power` (pure production: solar + generators + unclassified generation, battery movement excluded) |
| Overall consumption | `account.load.total.power`; today's energy is the counter identity `grid.today.import + solar.today.energy + battery.today.discharge - grid.today.export - battery.today.charge` |
| Battery | `account.battery.power` (positive = discharging), `today.charge`/`today.discharge`, `budget.battery_available/battery_capacity/reserve_kwh`, SOC on battery-kind boundary entries |
| Export meter | the boundary entry with `kind=grid` (`power_in` = importing, `power_out` = exporting, `energy_in`/`energy_out` = the meter's corrected counters, `provenance` = meter health) |
| Ruleset "why" | `allocation.<policy>.*` (command, reason) alongside `policy.*` definitions; render adjacent to the export meter since grid exchange is where their effect lands |

### Flow coloring

`circuit.bus.<id>.local_fraction` is the per-node green/red ratio (1 = all
local energy, 0 = all grid). Buses mix perfectly, so every flow leaving a
bus carries that bus's ratio; the edge painting rule is: color each flow
line with the local_fraction of the bus the flow is drawn from this sample
(the edge's flow sign says which side that is). No per-edge blend is
published because it is exactly this derivation.

**Coming next** (paths tentative until `ENERGY_ELEMENT_DATA_SPEC.md` is
updated):
- **Fault and outage reports**: three severities that want distinct visual
  treatment: (1) a normally-measured boundary currently running on inference
  (meter offline; accounting continues -- info, not alarm); (2) several dark
  boundaries confounded (category detail lost, net still accounted, culprit
  list provided); (3) residual on a fully-measured circuit (genuine
  meter/wiring fault).

## 5. Deprecations: do not build against these

Arbitrated for removal or replacement; migrate off them (or never adopt):

| Namespace | Fate | Replacement |
|-----------|------|-------------|
| `topology.appliance.*` | delete (triple-published meter mirror) | identity: `appliance.*` / `boundary.*`; meters: `topology.port.*` |
| `topology.appliance_index.*` | delete | `appliance.*` |
| `circuit.terminal.*` | demote (per-port mix is derivable: port draw x bus ratio) | bus ratio at `circuit.bus.*`; `soc` moves to battery-kind boundary entries |
| `circuit.branch.*` / `topology.link.*` | merge into ONE edge namespace: endpoints, closed, capacity, live current/power, utilisation | final name announced in the element spec |
| `circuit.production.*`, `circuit.production_contribution.*` | retire | solar boundary entries, which will gain an aggregate-vs-member `mismatch` flag |

`soc` is available on battery-kind boundary entries (`boundary.<name>.soc`,
the reconciled store value); read it there, not from `circuit.terminal`.

**Graphing is available now.** The presentation set records to disk (island
accounts including the today counters, every `boundary.*` power/energy/soc,
appliance loss), and the sync websocket already answers history requests:
send a `history_req` frame with `path` (the full element path, e.g.
`energy.islands.grid.account.grid.power`), `from`/`to` in epoch
milliseconds, and `max_points` (default 500, hard cap 2000); you get back a
`history` frame with `samples` as `[time_ms, value]` pairs. An unrecorded
path answers with an error frame, which is the signal that the element is
live-only by design -- ask for it to be added to the recorder rather than
polling it into your own store.

Recording is opt-in per element class, so what you can graph is exactly the
supported presentation surface. Debug trees (`circuit.bus.*`,
`topology.port.*`) are deliberately not recorded.

## 6. Unchanged guarantees

- All `islands.<id>.account.*` element paths and units.
- The identities, which hold exactly and are assertable client-side:
  `generation = solar + battery + rogue.generation` (plus generator kinds),
  `load = generation + grid` clamped at zero.
- Coverage vocabulary (`measured` / `bounded` / `rogue-value` / `unknown`).
- Production/production-contribution element shapes.
- Daily counters bank across meter resets as before. Note: energy counters
  do not bridge meter outages -- live power rides through by inference, but
  daily totals stall while a meter is silent and catch up when it returns.

## 7. Frontend migration checklist

1. Accept `bus=""` / `owner=""` on ports; group dangling ports as
   "boundaries" rather than under a circuit.
2. Parse capacities as floats.
3. Expect solar ~0 at night on this site; small negative solar only
   appears for one-port solar appliances (standby draw), tooltip it.
4. Expect rogue to differ from the previous build (larger where untagged
   equipment exists, smaller where sinks are declared).
5. Treat battery daily-counter steps at upgrade time as a correction.
6. Build entity lists and site header stats from `boundary.*` /
   `appliance.*` / `islands.<id>.account.*` only; treat section 5's
   namespaces as already gone.
7. Adopt `appliance.<name>.loss_power` and `topology.link.<id>.mismatch`
   (available now), and build charts against the sync `history_req` frame
   (section 5); reserve UI space for the three-severity fault reporting
   (section 4).
