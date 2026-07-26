# Energy Management

OpenWatt's energy manager models your site as a graph of circuits, links, and appliances — matching how it's actually wired, because how it's wired determines what's physically possible and what's economically optimal.

Most energy management systems model a flat list of devices with a single global power limit. That works until your site has structure — sub-panels, narrow links between buildings, separate inverters serving different areas, DC buses behind hybrid inverters. A 32A EVSE behind a 20A link to an outbuilding can only draw from the grid what the link allows, even if the main panel has 40A of headroom. But it can charge at full rate when the local battery and solar can supply the difference. A flat model can't express this. The circuit graph can.

The energy manager does three things:

- **Accounting** — reconcile every meter on the site into per-island solar/battery/grid/load figures, with unexplained power surfaced rather than smeared
- **Protection** — never trip a breaker: every commanded watt is clamped against measured headroom along its physical route
- **Optimisation** — service declared intent (policies) from the cheapest source: surplus solar first, battery second, grid only when a policy's tier permits it

All three emerge from the same topology awareness. Knowing where the constraints are is the same as knowing where the opportunities are.

## The Circuit Graph

A **circuit** is an electrical space where things connect: a breaker's downstream wiring, a sub-panel, the DC bus inside a battery system. Circuits are not declared — they exist by being named. Referencing `house.gpo` from a link or an appliance port binding brings it into existence.

**Links** are the installed infrastructure connecting circuits: breakers, inline meters, contactors, transfer legs. They carry the current limits and (optionally) the meters:

```
/apps/energy/link add name=main kind=breaker parent=grid child=main meter=se_meter.meter capacity=63A meter-phase=1
/apps/energy/link add name=house kind=breaker parent=sub_main child=house meter=vue2.mains_a capacity=50A
/apps/energy/link add name=house_gpo kind=breaker parent=house.backup child=house.gpo meter=vue2.circuit_7 capacity=20A
/apps/energy/link add name=cabin kind=breaker parent=sub_main child=cabin meter=cabin_solar.inverter.export_meter meter-sign=inverted capacity=20A
/apps/energy/link add name=house_gpo_outlets parent=house.gpo
```

Link properties:

| Property | Meaning |
|----------|---------|
| `parent`, `child` | The circuits this link connects, in feed direction. A link with only `parent` set dangles toward unenumerated equipment and becomes a diffuse-load sink (see Metering and Accounting). A link with only `circuit` set is a point connection, not a bridge. |
| `kind` | `breaker`, `meter`, etc. Inferred when omitted: `capacity` implies breaker, `meter` implies meter. |
| `capacity` | Current limit as an ampere quantity (`capacity=20A`; a bare number reads as amps). This is what protection enforces. |
| `meter`, `meter-phase`, `meter-sign` | Dot-path to any EnergyMeter component, which phase to read, and polarity correction. |
| `closed` | Whether the link conducts (contactors, transfer switches). |
| `role` | Declares what lives on the child circuit when it isn't otherwise modelled: `role=pv` on a breaker feeding microinverters books its backfeed as solar. See Metering and Accounting. |

The meter can come from any protocol — a Modbus meter, an inverter's built-in CT, CT clamps on an ESPHome device, a Zigbee plug. The energy manager consumes Component trees and doesn't care who populated them.

The grid is the implicit root circuit named `grid`. Everything reachable from it forms the on-grid island; disconnected groups (an unplugged car, an off-grid shed) form their own islands and are accounted independently.

## Appliances

Appliances are the things that consume, produce, or store energy. An appliance is a flat, named entity; its electrical shape comes from its device profile's **Port** components, and each port is bound to a circuit with a `<port>=<circuit>` property:

```
/apps/energy/appliance add name=goodwe grid=house backup=house.backup_feed battery=dc_bus device=goodwe_ems
/apps/energy/appliance add name=house_battery connection=dc_bus device=house_bms
/apps/energy/appliance add name=cabin_solar grid=cabin backup=cabin.backup_feed battery=cabin.dc solar.mppt1=cabin.pv1 solar.mppt2=cabin.pv2 device=cabin_solar
/apps/energy/appliance add name=shed_evse grid=shed device=shed_twc
/apps/energy/appliance add name=house_ac connection=house meter=vue2.circuit_4 kind=hvac
/apps/energy/appliance add name=cabin_hot_water connection=cabin.laundry kind=water-heater
```

The goodwe line reads: this inverter's grid port is on the `house` circuit, its backup output feeds `house.backup_feed`, and its battery port faces the `dc_bus` circuit. The BMS is a separate appliance on that same `dc_bus` — that co-location is what lets the system reconcile the inverter's view against the battery's own.

Appliance properties:

| Property | Meaning |
|----------|---------|
| `<port>=<circuit>` | Bind a device Port (by path, e.g. `solar.mppt1`) to a circuit. Ports not bound explicitly may name their circuit in the device profile. |
| `device` | Dot-path to the protocol device (or sub-component) carrying the appliance's data and control surface. |
| `kind` | Appliance class: `inverter`, `battery`, `evse`, `car`, `hvac`, `water-heater`, `pv`, ... Normally inferred from `device.info.type`; set explicitly for anchors without devices. |
| `meter` | Explicit consumption meter when it isn't on the device itself. |
| `meter-sign` | Polarity correction for the meter. |
| `state` | Explicit state component (SOC, temperature) when state lives on a different device than control — e.g. a car's BLE provides SOC while the wall connector provides the control. |
| `vin` | Vehicle identity; see Cars. |
| `capacity` | Usable battery kWh; fallback for SOC/energy estimation when the device can't report it. |
| `root` | Marks this appliance as an explicit source root for otherwise-unrooted islands (generators, off-grid inverters). |

Appliances with no device and no meter are valid: they are intent anchors. `cabin_hot_water` above has no control surface yet, but policies can already target it; `/apps/energy/why` reports "no control" until hardware arrives.

### Cars

Cars are appliances that move. A car with a `vin` attaches to a circuit named by its VIN. An EVSE that can identify the plugged-in car (e.g. Tesla Wall Connector) reports the same VIN as its `car` port's circuit — so the pairing is an ordinary circuit join, and it reshapes automatically on plug/unplug:

```
/apps/energy/appliance add name=evie kind=car vin=LRW3F7EKXMC392131
/apps/energy/appliance add name=zephyr kind=car vin=5YJ3F7EC8LF488644
/apps/energy/appliance add name=mg_zs kind=car connection=mg_zs    # EVSE can't read this VIN; bound manually
```

Policies target the car, not the charger. When the car is plugged in, the allocator drives it through the paired EVSE's control surface (`via` in the `/why` output). Unplugged cars report "not connected" — status, not error.

## Metering and Accounting

Power enters and leaves the modeled graph at **boundary edges**, and accounting happens exactly there. A port is a boundary when the equipment behind it is not modeled:

- the single port of a one-port appliance (the dishwasher itself isn't modeled, its connection is);
- a dangling port with no circuit (a hybrid inverter's MPPT input, the far end of a parent-only link);
- a handover on the `grid` circuit, which stands for the unmodeled utility.

Every other port is **interior**. Interior meters never source an account — they are constraints: they anchor inference, cross-check redundant observations, and expose wiring, polarity, and calibration errors. Modelling more equipment moves the boundary outward and automatically demotes the meters it passes to verification duty; a meter always means "the flow at this exact point" and is never re-described by configuration elsewhere.

Classification is metadata, not sign. A boundary's account — solar, battery, grid, load — comes from its declared role or its owner's kind, never from which way power happens to flow at the moment. An untagged generator books as unclassified generation instead of disappearing.

An inverter is the instructive case: it looks like an appliance, but electrically it's a coupling between circuits — a lossy transformer with a port on each bus. Its battery port reading is the *net* DC bus flow. If the DC bus holds only a battery, that net equals the battery; but put a DC-coupled charge controller on the same bus and the inverter can no longer see the panels' generation or the battery's true charge rate — only their sum. Modelling the DC bus as a circuit with its occupants as appliances recovers what the inverter cannot report — and the inverter's own battery-port meter stays useful as the cross-check on the new equipment's story.

### Diffuse-load sinks

Circuits with sockets carry loads nobody will ever enumerate. Declare that with a parent-only link — its dangling end is a boundary that absorbs the circuit's unexplained flow as a named account:

```
/apps/energy/link add name=house_gpo_outlets parent=house.gpo
```

The link's name is the account: `house_gpo_outlets` reports the plug loads on that circuit, per circuit, instead of leaving them pooled in island-wide rogue load. When another declared port on the same circuit is also unmetered, the two are indistinguishable and the solver defers rather than guessing a split. A sink absorbs meter error along with plug loads, so declare them only where sockets really exist and keep fully-enumerated circuits sink-free for full fault sensitivity.

### Implicit terminals

Declaring a port's role (`battery`, `pv`) states what lives on the circuit it faces. When nothing of that class is actually modelled there, the topology synthesizes an **implicit terminal** in its place and infers its flow from the circuit balance. The bank behind a bare hybrid inverter becomes an accountable battery without any extra configuration; when you later add the real BMS device, it displaces the implicit terminal automatically, and any leftover residual (DC cabling loss, meter disagreement) shows up honestly as rogue load on that circuit.

The same declaration works on ordinary breakers. Microinverters plugged in behind a GPO circuit are invisible equipment backfeeding a boundary meter — declare the circuit's link with `role=pv` and the net backfeed books as solar:

```
/apps/energy/link add name=patio_gpo parent=house child=house.patio role=pv capacity=20A
```

Without the declaration, backfeed on a circuit is left as **rogue generation**: real, but unattributed.

### Reconciliation and health

Each circuit's balance is the signed sum of its port meters. The residual — what the meters can't explain — is classified per circuit:

- **Unaccounted load** (the common case): unmetered GPO loads, cabling loss between bracketing meters. Normal life, reported, not alarming — and claimable per circuit by a sink.
- **Unaccounted source**: power appearing from nowhere. Genuinely suspicious — flagged as an anomaly unless a declared role explains it.
- Where a circuit has exactly one dark (unmetered) port that could physically carry the residual, inference assigns it — so one missing meter doesn't blind a circuit.
- Groups conserve: a multi-port appliance's port flows sum to its conversion loss, a closed breaker's two ports mirror. A group with exactly one unknown port is solved from its siblings — this is what carries a circuit residual out through a sink's dangling end, and what closes a hybrid inverter's last port. Fully-measured appliances publish their self-consumption; fully-measured breakers flag disagreement beyond meter noise as a mismatch.

Coverage per circuit is published as `measured` (balanced), `bounded` (dark terminals with a power bound), `rogue-value` (unexplained residual), or `unknown`.

### Accounts

Each island's accounts are projections of one reduction over its solved boundary edges — every boundary contributes exactly once, to the account its classification picks, oriented by its shape:

- **SOLAR** — net flow of solar-classified boundaries (daily energy reconciled per source: an aggregate meter is authoritative over per-string/per-panel members)
- **BATTERY** — net flow of battery-classified boundaries (positive = discharging)
- **GRID** — net flow of the grid handover boundaries (positive = importing)
- **ROGUE GENERATION / ROGUE LOAD** — unclassified boundary flows plus unattributed circuit residuals, summed island-wide
- **GENERATION** — net on-site supply: solar + battery (signed) + rogue generation. Grid is not included; it has its own account. The identity `LOAD = GENERATION + GRID` holds exactly, and `GENERATION - BATTERY` is pure production (solar + rogue).
- **LOAD** — `GENERATION + GRID`, clamped at zero

Battery and solar terminals are DC-side meters, so inverter conversion losses land in LOAD — in both directions. Charging books the AC drawn at full value while only the smaller DC-side charge power is subtracted; discharging books the DC supply while the AC side delivers less. LOAD is therefore "household consumption plus conversion overhead": it will read slightly above the sum of your AC circuit meters, with the difference being real energy your energy system consumed. Conversion loss is just another rogue load.

Daily energy tallies (`today.charge`, `today.import`, ...) accumulate from the source meters' energy counters since local midnight.

## Policies: Declaring Intent

Policies are layered intent that the allocator services every tick. Each policy names a target appliance, a tier, and a goal:

```
/apps/energy/policy
add name=evie_reserve    target=evie   tier=floor         goal="soc(20)"
add name=evie_ready      target=evie   tier=important     goal="soc(40)" deadline=11:00 shape=window
add name=evie_topup      target=evie   tier=opportunistic goal="soc(90)"
add name=cabin_ev_surplus target=cabin_evse tier=opportunistic goal="soc(100)"
```

**Tiers**, highest priority first:

| Tier | Contract |
|------|----------|
| `floor` | Must always hold. Infinite priority; may buy from the grid. |
| `essential` | Must reach the goal by its deadline. High priority, decays toward urgent as slack runs out. |
| `important` | Try to reach the goal. Yields to floor/essential; solar and battery only — no grid buy. |
| `opportunistic` | Consume surplus only; gated on battery/solar pressure. |

**Goals**: `on`, `off`, `soc(N)`, `temp(N)`, `duty(...)`, or an expression. `deadline=HH:MM` feeds the slack boost on essential/important tiers. `shape=window` marks charge-window intent (parsed and published; ranking integration pending).

A target usually carries several policies at different tiers — read each block top-to-bottom as intent: "never below 20%, be at 40% by 11am, fill to 90% on surplus."

Autonomous equipment needs no policy: a hybrid inverter that manages its own battery reserve (PowerControl kind `autonomous`) takes no setpoint. Policies drive *commandable* controls.

## Planning and Allocation

Each tick, per island:

1. **Budget** — the planner totals battery energy available/reserved, forecast supply and demand, and per-tier demand (`islands.<id>.budget.*`).
2. **Ranking** — each policy gets a marginal value from its tier, goal distance, and deadline slack.
3. **Allocation** — in rank order, each policy's command is routed to a control surface (the target's own, or its paired EVSE's) and clamped against the physical route.
4. **Actuation** — accepted commands are written through the protocol layer; the reason for every decision is published (`allocation.<policy>.reason`).

**Control paths** make protection structural: for every controllable appliance the graph computes the route from its connection back toward the grid or a source root, and the minimum spare capacity along that route (`headroom`). A command can never exceed the headroom of its narrowest link, minus capacity already committed to higher-ranked policies in the same tick. Boolean loads with a known nameplate are refused when switching on would exceed the route's headroom.

This is also where topology becomes opportunity: an EVSE behind a 20A inter-building link can still charge hard when the local inverter and battery supply the difference — the path headroom constrains *grid-side* draw, and local sources sit downstream of the constraint.

## Inspection

Everything the energy manager believes and decides is published as elements on the synthetic `energy` device (see [ENERGY_ELEMENT_DATA_SPEC.md](ENERGY_ELEMENT_DATA_SPEC.md) — the contract the web frontend renders from). The console offers projections of the same state:

| Command | Shows |
|---------|-------|
| `/apps/energy/live` | Live island accounts: solar, battery, grid, rogue, generation, load. |
| `/apps/energy/topology [-w]` | The raw graph: buses, links, ports, coverage, residuals. |
| `/apps/energy/circuit [-w]` | The reconciled circuit view (kernel projection). |
| `/apps/energy/control print` | Every discovered control surface: kind, direction, unit, range, setpoint, nameplate. |
| `/apps/energy/why` | Per-policy decisions: goal, satisfaction, marginal value, and the reason for the current command. |

`why` is the first stop when the system does something surprising: every policy row states what it wanted, what it was allowed, and why.

## How It Fits Together

The energy manager sits at the top of the OpenWatt stack. It reads from the device model and writes control commands back through the protocol layer:

```
Energy Manager
  reads from: Device -> Component -> Element (Port, EnergyMeter, Battery, PowerControl, ...)
  writes to:  control setpoints on the same tree
    |
Protocol Layer
  translates element writes into protocol operations
  (Modbus write register, MQTT publish, TWC current command, BLE, ...)
```

This separation is what makes it protocol-agnostic:

- Adding a new meter or inverter requires a device profile — the energy manager doesn't change
- Any mix of protocols can feed a single site's energy management
- The energy manager can be tested without hardware — mock the Elements

By the time the energy app runs, protocol devices already exist with their Component trees populated:

```
# GoodWe hybrid inverter via proprietary protocol
/protocol/goodwe/aa55/add name=cabin_solar remote=192.168.3.5 profile=gwxx48es
/binding/goodwe/add name=cabin_solar device=cabin_solar client=cabin_solar profile=gwxx48es

# Tesla Wall Connector via TWC protocol
/interface/tesla-twc add name=shed_twc stream=shed
/binding/tesla/twc/add name=shed_twc device=shed_twc slave_id=0x6820

# ESPHome energy monitor (CT clamps)
/protocol/esphome/client add name=vue2 remote=192.168.3.20
/binding/esphome add name=vue2 device=vue2 client=vue2 profile=emporia
```

## Further Reading

- [Element Data Spec](ENERGY_ELEMENT_DATA_SPEC.md) — The published element contract (frontend renders from this)
- [Overview](OVERVIEW.md) — How the OpenWatt layers fit together
- [Device Profiles](PROFILE_FILE_FORMAT.md) — Writing profiles for new meters and inverters
- [Component Templates](COMPONENT_TEMPLATES.md) — Standard templates (EnergyMeter, Battery, Port, PowerControl, ...)
- [CLI Reference](CLI.md) — Console command syntax
