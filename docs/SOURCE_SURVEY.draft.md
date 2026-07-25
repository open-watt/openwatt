# Source Survey: boundary-injection model for generation/storage accounting

Status: DESIGN SPEC, not yet implemented. Follow-up to the energy review merge
(ow/sq-energy). Resolves ENERGY_REVIEW.md MET-5 structurally; supersedes the
per-account sign handling described below. Written so that an agent with no
prior context can implement it.

## 1. Problem

The energy app computes island accounts (solar / battery / grid / rogue / load)
from meter readings collected at topology ports. Today three separate passes
each re-derive "which ports count, and with what sign", each differently:

- `accounts.add_island_battery` reads battery *class terminals* and negates
  (`t.battery_power += -p.meter_data.active[0]`) to get discharge-positive.
- `topology.rebuild_productions` collects `role == pv` ports RAW (no frame
  conversion) into `ProductionContribution.meter`; `accounts.d` then sums
  `production.data.active[0]` as-is into `account.solar.power`.
- `accounts.add_island_rogue` reads bus residuals.

This is MET-5: a real PV appliance terminal on a bus reads generation as
NEGATIVE (load convention: positive = power into the node), while an inverter's
dangling MPPT boundary port reads generation as POSITIVE (V*I of energy entering
the circuit). `rebuild_productions` mixes both frames unconverted, so there is
no configuration in which both a panel-terminal source and an MPPT source sum
correctly. Additionally, generation *detection* is gated on `role == pv` /
`owner.kind`, so an untagged stand-alone AC solar inverter (single grid-tie
port, supplying) is invisible as a generator.

## 2. Conceptual model

The circuit graph is conceptually bipartite:

- **Bus nodes** are explicit (`topology.Bus`).
- **Device nodes** are IMPLICIT: every `Appliance` is a junction node joining
  all ports that share that `owner`. A multi-port device (inverter, charger)
  has no bus aggregating its own ports; the device instance is the junction.
  Kirchhoff holds across a device node minus conversion loss and storage.

**Do NOT materialise a device-node struct.** The `Appliance` instance IS the
node; membership is the query `ports[].filter(p => p.owner is a)`; any balance
is computed transiently. A `Bus` is hard data only because nothing else backs
it. If per-device derived state is ever needed persistently, it goes on
`Appliance`, never in a parallel node table.

A **port** is always an edge between a device node and a bus node, or a device
node and nothing (a *dangling* edge to the unmodeled world, e.g. an inverter's
MPPT port whose PV strings are uncharted).

### 2.1 Boundary vs interior edges

- **Interior edge**: a port whose bus is modeled (`p.bus !is null`) AND whose
  owner has at least one other port on a modeled bus. Interior edges are
  balance/cross-check only. They NEVER source an account. (This is the
  structural replacement for "leaf-most" deduplication: an inverter's AC port
  is interior, so the energy entering at its MPPT is never counted twice.)
- **Boundary edge**: everything else. Two shapes:
  - *Dangling port*: `p.bus is null` (or the far side uncharted) but a meter
    exists. Energy crossing it enters/leaves the modeled circuit.
  - *Leaf device*: the only modeled port of a single-port appliance. The
    device's far side (the sun, the cell chemistry, the unmetered feeder) is
    intrinsically unmodeled, so this port is the modeled/unmodeled boundary.

Generation, storage flow, and grid exchange all occur ONLY at boundary edges:
energy cannot appear inside the modeled graph (it would violate node balance),
it can only cross a boundary.

### 2.2 Signed injection

Meter data is load convention after `get_port_meter_data` (extract_phase +
apply_meter_sign): **positive = power flowing INTO the port's node from the
bus**. Define one canonical derived quantity per boundary port:

```
injection(P) = -P.meter_data.active[0]   if P is on a modeled bus
             = +P.meter_data.active[0]   if P is dangling
```

`injection > 0` means the boundary net-supplies the modeled circuit; `< 0`
means it net-draws. The two branches are the same physical statement measured
from opposite sides of the boundary.

Worked cases (all follow from the one rule, no special-casing):

| case                                   | shape                    | raw active | injection |
|----------------------------------------|--------------------------|-----------:|----------:|
| DC panel string appliance on a DC bus  | leaf device, on-bus      | negative   | positive  |
| GoodWe MPPT (`gwxx48es.conf` solar.mppt1/2) | dangling port on inverter | +V*I  | positive  |
| AC microinverter appliance on AC bus   | leaf device, on-bus      | negative   | positive  |
| untagged stand-alone solar inverter    | leaf device, on-bus      | negative   | positive  |
| battery terminal, charging             | leaf device, on-bus      | positive   | negative  |
| battery terminal, discharging          | leaf device, on-bus      | negative   | positive  |
| plain load                             | leaf device, on-bus      | positive   | negative  |
| grid inlet                             | boundary on grid bus     | signed     | signed    |

NOTE for profile authors: a leaf device on a bus is expected to report load
convention (generating reads negative). A device whose firmware natively
reports generation-positive declares `meter_sign: inverted` on its port,
exactly as GoodWe's grid/backup ports already do (`gwxx48es.conf` grid port).
This must be documented in `docs/COMPONENT_TEMPLATES.md` when implemented.

### 2.3 Sign is data, not a filter

The survey collects boundary edges by CLASSIFICATION, never by instantaneous
sign. A battery boundary stays in the list while charging (injection < 0); a
panel at night contributes ~0. What separates "battery charging" from "a load"
is the kind stamp (metadata), not the sign of the moment.

## 3. Vocabulary

Add to `src/apps/energy/model.d` (alongside `BusType`/`MeterSign`):

```d
enum SourceKind : ubyte
{
    none,        // interior edge or unclassifiable
    grid,        // the utility boundary; excluded from the source survey
    solar,       // role == pv, or owner.kind in {pv, solar}
    battery,     // role == battery, or owner.kind == battery
    generation,  // boundary net-injecting, no classification (rogue source)
    load,        // boundary net-drawing, no classification (derived bucket)
}
```

Classification precedence (metadata first, geometry as fallback):
1. Port on the grid-ingress path (see 4.2) -> `grid`.
2. `p.role == PortRole.pv` OR `owner.kind` in {"pv","solar"} -> `solar`.
3. `p.role == PortRole.battery` OR `owner.kind == "battery"` -> `battery`.
4. Otherwise -> `none` at classification time; the ACCOUNTS bucket unclassified
   boundary flow by sign per tick: injecting -> `generation` (rogue),
   drawing -> `load`. (Rule 4 is what makes the untagged stand-alone solar
   inverter surface as generation with no role tag.)

## 4. The survey

One pass replaces `add_island_battery` + the collection side of
`rebuild_productions` + `add_island_rogue`'s source attribution.

### 4.1 Data

```d
struct TerminalFlow
{
    Port*      port;          // provenance: owner, port path (p.path), circuit (p.bus.id)
    SourceKind kind;
    float      injection;             // signed W, + = into the circuit
    float      energy_in_today_kwh;   // cumulative kWh INTO the circuit (see 4.3)
    float      energy_out_today_kwh;  // cumulative kWh OUT of the circuit
}
```

### 4.2 Algorithm

```
survey_sources(island, graph) -> Array!TerminalFlow:
  for each bus in island.members:
    for each port p on bus:
      if !is_boundary(p): continue            // interior edges excluded (2.1)
      if is_grid_inlet(p): continue           // grid keeps its own account
      t.port = p
      t.kind = classify_kind(p)               // section 3
      t.injection = signed_injection(p)       // section 2.2
      t.energy_* = boundary_energy(p)         // section 4.3
      result ~= t
  also: for each dangling metered port owned by an appliance anchored in this
        island (e.g. MPPT ports; p.bus is null so the bus loop misses them):
        same treatment, injection = +active.
```

`is_boundary(p)`: NOT interior per 2.1. Implement as:
`p.bus is null || !owner_has_other_modeled_port(p)`, where label-owned ports
(`p.owner is null`, declared breaker children) are boundaries of the charted
region and keep their existing net-metering clamp semantics (see 6.3).

`is_grid_inlet(p)`: p sits on the bus with `contains_grid` and is the port of
the grid-ingress link (the existing `island.root` grid loop identifies these).

Implicit terminals (`p.implicit`, synthesized by
`topology.synthesise_class_terminal`): they carry inferred residual meter_data
in load convention and ARE boundaries (they stand in for unmodeled equipment).
Include them with their stamped role's kind. This replaces the current
PV-implicit exclusion in `rebuild_productions` (`if (... || p.implicit)`); with
frame conversion in place the exclusion is no longer needed for correctness,
and including them makes "unmodeled panels on a charted DC bus" attributable.

`class_terminal()` in topology.d is DELETED once callers are migrated; its two
jobs split cleanly: terminal-vs-boundary becomes `is_boundary` (geometry), and
kind becomes `classify_kind` (metadata).

### 4.3 Energy counters

Daily kWh must cross the boundary in the same frame as power. From
`p.meter_data` (already sign/phase corrected, see MET-3 commit 76573ba):

- on-bus boundary: energy INTO circuit = `total_export_active[0]`,
  energy OUT = `total_import_active[0]`  (frame flip, matches injection)
- dangling boundary: energy INTO circuit = `total_import_active[0]`,
  energy OUT = `total_export_active[0]`

Feed these through `accounts.today_delta_value` keyed on the underlying element
exactly as today (MET-4 reset re-anchoring applies unchanged).

## 5. Rewiring the accounts

`compute_island_totals` becomes pure bucketing over the survey:

```d
foreach (t; survey[]) final switch (t.kind)
{
    case solar:      t_totals.solar_power   += t.injection; break;
    case battery:    t_totals.battery_power += t.injection; break;  // signed: + discharge
    case generation: t_totals.rogue_generation_power += max(t.injection, 0); break;
    case load:       /* derived; do not sum surveyed loads into LOAD */ break;
    case grid, none: break;
}
generation = solar + battery + rogue_generation;     // unchanged identity
load       = max(generation + grid, 0);              // still derived, not surveyed
```

Battery daily charge/discharge = energy_out/energy_in of battery-kind flows
(charge = energy leaving the circuit into the boundary). Solar today = sum of
energy_in of solar-kind flows, with the existing aggregate-vs-member preference
(6.2). No `-active`, no frame logic, no role filters remain in accounts.d.

Bus residual attribution (`add_island_rogue`) still runs for buses whose
imbalance is not soaked by an implicit terminal; unchanged.

## 6. Interactions preserved from the current code

6.1 **Terminal-first yield**: `rebuild_productions` currently skips a boundary
pv port when a real pv terminal exists on the same bus
(`bus_has_real_class_terminal`). Under the survey this rule survives as: a
dangling source port is EXCLUDED when the bus its owner anchors on has a real
same-kind leaf boundary... but note the shapes rarely overlap (MPPT dangles,
panels sit on a DC bus). Re-derive the rule during implementation: the goal is
never to double-count one energy flow measured at two boundaries of the same
unmodeled region. Where both measurements exist, prefer the more specific
(per-device) one and keep the other as cross-check, mirroring
`reconcile_productions` aggregate-vs-member logic.

6.2 **Production reconciliation/provenance**: `Production` /
`ProductionContribution` (production.d) and the published
`circuit.production.<owner>.<group>.*` / `circuit.production_contribution.<i>.*`
elements (state.d) remain the provenance layer; the survey feeds them
frame-normalized (generation-positive) contributions instead of raw meter_data.
`reconcile_productions`' aggregate-vs-member cross-check is unchanged. UI
stacking of distinct sources (house, cabin.s1, bathroom.micro) is a projection
of TerminalFlow provenance; no new model surface needed.

6.3 **Net-metered breaker-child clamp** (`rebuild_productions`: owner-null
member with negative power floored to 0): keep, expressed post-conversion as
"a label-owned generation boundary's visible injection floors at 0" (downstream
load behind the same breaker can exceed the micros).

6.4 **Grid account**: untouched. MET-2 (island.root anchored on the grid bus,
off-grid gating) and MET-3 (sign/phase-corrected daily counters) stay as-is.

## 7. Implementation order (each its own commit)

1. `SourceKind` in model.d + `is_boundary` / `classify_kind` /
   `signed_injection` helpers in topology.d (or a new terminal.d), with unit
   tests covering every row of the 2.2 table.
2. `survey_sources` + rewire `compute_island_totals` (accounts.d) onto it;
   delete `add_island_battery`; unit-test island totals for: hybrid inverter
   (dangling MPPT + battery terminal), leaf panel on DC bus, AC micro,
   untagged stand-alone solar inverter, battery charging tick.
3. Feed productions from the survey; delete `class_terminal` and the raw
   collection in `rebuild_productions`; keep reconciliation + publishing.
4. Document the leaf load-convention + `meter_sign` escape hatch in
   COMPONENT_TEMPLATES.md; note in PROFILE_FILE_FORMAT.md if needed.

Acceptance: all existing unit tests pass; new tests above; GoodWe
(`gwxx48es.conf`) island publishes identical account.solar.power to today
(its MPPTs are dangling boundaries -> +V*I, unchanged behaviour).

## 8. Out of scope

- Per-device conversion-loss tracking (device-node residual over time): later;
  would live as fields on Appliance per section 2.
- Load survey (loads remain derived as generation + grid).
- db.Stream-backed daily counters (replaces the DailySnapshot HACK; tracked
  separately).
