# Energy Element Data Spec

This document describes the element data published by the energy app for web
visualisation and other subscribers. The frontend should render the circuit
graph from normal element subscriptions, not from a bespoke topology endpoint.

Status: draft contract for `energy.circuit.schema_version = 1`.

## Source Device

The energy app publishes runtime state on the synthetic device:

```text
energy
```

All paths below are relative to that device. A client should subscribe to
subtrees on `energy` and process element deltas like any other device data.

Missing numeric values are published as `NaN`. Treat `NaN` as unknown, not zero.

## Recommended Subscriptions

For the circuit graph:

```text
energy.circuit
```

For source-detail debugging:

```text
energy.topology.port
energy.topology.link
energy.topology.bus
```

For planner/control overlays:

```text
energy.control_path
energy.policy
energy.allocation
energy.islands
```

`energy.circuit.*` is the primary contract. `energy.topology.*` is a source
projection of the runtime graph and is useful for debugging profile/config
binding, but new renderers should not build their main graph from it.

The `/apps/energy/circuit` console command is only a human-readable projection
of the same runtime state.

## Generations And Stale Records

The publisher currently has no tombstone/delete protocol for element subtrees.
Clients must use generation fields to ignore stale records:

1. Read `circuit.generation`.
2. Process only `circuit.*.*.<id>.generation == circuit.generation`.
3. If using topology debug records, also match `topology.generation`.

When the generation changes, clients should rebuild their local graph from the
matching records. Live meter deltas with the same generation can update nodes in
place.

## Meter Field Shape

Whenever a circuit bus balance, terminal, topology bus balance, topology port,
topology link, production aggregate, or production contribution publishes
meter-shaped data, it uses these fields:

| Field | Type | Unit | Meaning |
| --- | --- | --- | --- |
| `power` | number | W | Signed active power. For terminals, positive means the connected circuit is feeding the appliance terminal; negative means the appliance terminal is supplying the circuit. For buses this is a synthetic balance, not a physical meter. |
| `current` | number | A | Current. |
| `voltage` | number | V | Voltage. |
| `import` | number | kWh | Cumulative active import in the same convention as `power`. For terminals, this is energy from the connected circuit into the appliance terminal. |
| `export` | number | kWh | Cumulative active export in the same convention as `power`. For terminals, this is energy supplied by the appliance terminal to the connected circuit. |
| `apparent` | number | VA | Apparent power. |
| `reactive` | number | var | Reactive power. |
| `pf` | number | 1 | Power factor. |
| `frequency` | number | Hz | Frequency. |
| `<field>_source` | string | - | Provenance for each meter field. |

Provenance values:

```text
missing
measured
synthesized
quadrant-derived
inferred-sum
inferred-subtraction
rogue
```

## Circuit Envelope

Path:

```text
circuit.<field>
```

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | number | Current schema version. This document describes version `1`. |
| `generation` | number | Monotonic topology/circuit rebuild counter. |
| `buses` | number | Count of circuit buses. |
| `terminals` | number | Count of circuit terminals. |
| `branches` | number | Count of circuit branches. |
| `islands` | number | Count of electrically connected islands. |
| `grid_island` | number | Island index containing `grid`, or `-1` if absent. |
| `battery_stores` | number | Count of reconciled battery-store circuits. |
| `battery_store_contributions` | number | Count of battery-store source records. |
| `productions` | number | Count of reconciled production groups. |
| `production_contributions` | number | Count of production source records. |

## Circuit Buses

Path:

```text
circuit.bus.<circuit_id>.<field>
```

A bus is an electrical circuit space between terminals. It is the stable unit
for layout lanes, island membership, and residual/unaccounted load display.

The meter-shaped fields on a bus are a calculated bus balance from the terminal
meters at its edges. They do not mean the bus owns a physical meter. A bus can
have zero, one, or many terminal meters contributing to that balance.

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `generation` | number | Circuit generation this record belongs to. |
| `id` | string | Circuit id. Same as `<circuit_id>`. |
| `coverage` | string | `unknown`, `bounded`, `rogue-value`, `measured`, or `estimated`. |
| `accounted_power` | number W | Signed balance from known/inferred terminals before residual classification. |
| `residual_power` | number W | Noise-gated signed residual. |
| `unaccounted_load_power` | number W | Positive residual exposed as unknown load. |
| `unaccounted_source_power` | number W | Negative residual exposed as unknown source/generation. |
| `dark_power_bound` | number W | Conservative bound when one or more terminals are dark. |
| `source_power` | number W | Instantaneous source pool visible at this circuit, `local_source_power + grid_source_power`. |
| `local_source_power` | number W | Portion of the current source pool attributed to local generation/storage flow. |
| `grid_source_power` | number W | Portion of the current source pool attributed to utility-grid import. |
| `load_power` | number W | Sum of known positive terminal consumption on this circuit. |
| `local_fraction` | number 0..1 | Local share of the current source pool. Use for green/yellow/orange flow coloring. |
| `terminal_count` | number | Terminals attached to this circuit. |
| `metered_count` | number | Terminals with power data after inference. |
| `dark_count` | number | Terminals still missing power data. |
| `anomaly` | bool | Backend detected a suspicious balance condition. |
| `contains_grid` | bool | This bus is the implicit `grid` circuit. |
| `explicit_root` | bool | This circuit was marked as an explicit source/root anchor. |
| `island` | number | Connected island index. |
| `depth` | number | BFS depth from `grid` or the first explicit root, or `-1` when disconnected from that render tree. |
| `parent` | number | Parent bus index in the backend spanning tree, or `-1`. |
| meter fields | mixed | Synthetic balance fields calculated for this bus. |

Render a synthetic `?` row when `unaccounted_load_power > 0` or
`unaccounted_source_power > 0`. Use `residual_power` only when a signed display
is useful.

## Circuit Terminals

Path:

```text
circuit.terminal.<terminal_id>.<field>
```

A terminal is a Port projected into the role-blind circuit kernel. Terminals are
the electrical connection points that carry owner, port role, flow domain, meter
data, and explicit root/source hints.

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `generation` | number | Circuit generation this record belongs to. |
| `id` | string | Stable terminal id. Usually `<appliance>.<port_path>` or `<link>.<side>`. |
| `owner` | string | Owning appliance id, or empty string for configured physical links. |
| `owner_kind` | string | Appliance kind, normally inferred from `device.info.type`, or empty string. |
| `owner_device` | string | Configured appliance device/component reference, or empty string. |
| `port` | string | Port path/name, for example `grid`, `backup`, `battery`, `solar`, or `solar.mppt1`. |
| `label` | string | Human/config label, or empty string. |
| `circuit` | string | Circuit bus this terminal is connected to. |
| `role` | string | Port role, for example `grid`, `backup`, `battery`, `pv`, `car`, `outlet`. |
| `domain` | string | Flow domain: `sink`, `source`, `bidirectional`, or `unknown`. This describes expected capability, not meter sign. |
| `consumed_power` | number W | Positive terminal load from the connected circuit into the appliance terminal. `0` for supplying terminals. |
| `supplied_power` | number W | Positive terminal supply from the appliance terminal into the connected circuit. `0` for consuming terminals. |
| `local_power` | number W | Portion of this terminal's current flow attributed to local energy. For supplying terminals, this is the supplied local power. |
| `grid_power` | number W | Portion of this terminal's current consuming flow attributed to utility-grid energy. Supplying terminals publish `0`. |
| `local_fraction` | number 0..1 | Local share for this terminal's flow. Use this directly to color terminal/edge flow. |
| `root` | bool | This terminal is an explicit render/source root. |
| meter fields | mixed | Meter data for this terminal. May be measured or inferred. |

Role and domain are descriptive. They do not imply sign by themselves. Effective
terminal power has already been normalized to the port convention.

`local_fraction` is instantaneous attribution metadata, not a billing/accounting
counter. Render `0` as grid/red-or-orange, `1` as local/green, and intermediate
values as a blend. Prefer terminal `local_fraction` for edge coloring; use bus
`local_fraction` for node/background coloring.

## Circuit Branches

Path:

```text
circuit.branch.<branch_id>.<field>
```

A branch is a conducting element between two circuit buses: breaker, inline
meter, appliance bridge, transfer leg, or another link-like element.

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `generation` | number | Circuit generation this record belongs to. |
| `id` | string | Stable branch id. Configured links use their configured name. |
| `owner` | string | Owning appliance id for appliance-internal branches, otherwise empty string. |
| `label` | string | Human/config label, or empty string. |
| `kind` | string | `breaker`, `meter`, `appliance`, `link`, etc. |
| `parent` | string | Upstream/source-side circuit id as declared by config/runtime topology. |
| `child` | string | Downstream/load-side circuit id as declared by config/runtime topology. |
| `capacity` | number A | Current limit, or `0` if unknown/not applicable. |
| `conducting` | bool | Whether the branch currently conducts. |
| `parent_terminal` | number | Index into circuit terminal collection, or `-1`. |
| `child_terminal` | number | Index into circuit terminal collection, or `-1`. |

For ordinary circuit trees, physical configured branches usually have
`owner == ""`. Branches with an owner are appliance fan-out/conversion details.

## Battery Stores

Path:

```text
circuit.battery_store.<circuit_id>.<field>
```

A battery store is the reconciled battery state for a battery circuit. A
standalone BMS and an inverter's internal battery view can contribute to the
same store. Authoritative battery appliances are `member` contributions; inverter
or charger views are `view` contributions.

Fields:

| Field | Type | Unit | Meaning |
| --- | --- | --- | --- |
| `generation` | number | - | Circuit generation this record belongs to. |
| `circuit` | string | - | Battery circuit id. |
| `soc` | number | percent | Reconciled state of charge. |
| `soh` | number | percent | Reconciled state of health. |
| `remain_capacity` | number | Ah | Remaining capacity when available. |
| `full_capacity` | number | Ah | Full capacity when available. |
| `max_charge_current` | number | A | Charge current limit. |
| `max_discharge_current` | number | A | Discharge current limit. |
| `max_charge_power` | number | W | Charge power limit. |
| `max_discharge_power` | number | W | Discharge power limit. |
| `member_count` | number | - | Authoritative member count. |
| `view_count` | number | - | Corroborating view count. |
| `soc_anomaly` | bool | - | Member/view SOC disagreement exceeded backend tolerance. |

Contribution path:

```text
circuit.battery_store_contribution.<index>.<field>
```

Fields: `generation`, `circuit`, `owner`, `port`, `kind`, `component`.
`kind` is `member` or `view`.

## Production Groups

Path:

```text
circuit.production.<owner>.<group>.<field>
```

A production group is the reconciled generation aggregate for a source group,
currently PV/solar. A single PV input may be the top-level `solar` port.
Multiple MPPT ports such as `solar.mppt1` and `solar.mppt2` group under
`solar`. If an aggregate Solar meter exists it is published directly; otherwise
the aggregate is calculated from member ports.

Fields:

| Field | Type | Unit | Meaning |
| --- | --- | --- | --- |
| `generation` | number | - | Circuit generation this record belongs to. |
| `owner` | string | - | Appliance id. |
| `group` | string | - | Group path, for example `solar`. |
| `aggregate_power` | number | W | Explicit aggregate meter power, when present. |
| `member_power` | number | W | Sum of member port powers. |
| `aggregate_count` | number | - | Count of aggregate sources. |
| `member_count` | number | - | Count of member ports. |
| `calculated` | bool | - | True when aggregate data was calculated from members. |
| `mismatch` | bool | - | Aggregate/member mismatch exceeded backend tolerance. |
| meter fields | mixed | - | Reconciled production meter data. |

Contribution path:

```text
circuit.production_contribution.<index>.<field>
```

Fields: `generation`, `owner`, `group`, `port`, `circuit`, `kind`,
`component`, plus meter fields. `kind` is `member` or `aggregate`.

## Topology Debug Projection

`topology.*` mirrors the lower-level runtime graph. It remains useful when
debugging profile bindings and explaining why a circuit record exists.

Envelope:

```text
topology.schema_version
topology.generation
```

Collections:

```text
topology.bus.<bus_id>.*
topology.link.<link_id>.*
topology.port.<port_id>.*
topology.appliance_index.<appliance_id>.*
topology.appliance.<appliance_id>.<port_path>.*
```

Prefer `circuit.bus` over `topology.bus`, `circuit.branch` over
`topology.link`, and `circuit.terminal` over `topology.port` for the main
renderer.

Topology port and appliance-port debug records include `meter_sign`, with value
`normal` or `inverted`, showing the profile/config transform applied before the
port meter was projected into the circuit model. Renderers should use the
published normalized meter fields, not reapply this sign.

## Control Paths

Path:

```text
control_path.<appliance_id>.<field>
```

Control paths are graph-derived upstream routes from an appliance's anchor port
back toward `grid` or another explicit root. They are published for appliances
that have topology ports, not only appliances that are currently controllable.

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `generation` | number | Topology/circuit generation this path belongs to. |
| `target` | string | Appliance id. |
| `target_bus` | string | Circuit where the appliance's anchor port is attached. |
| `source_bus` | string | Furthest upstream circuit reached by the path walk. |
| `complete` | bool | Path reached `grid` or an explicit root. |
| `links` | number | Count of physical links in the route. |
| `route` | string | Comma-separated physical branch/link ids from target upstream. |
| `headroom_amps` | number A | Minimum spare current among rated, measured links in the route. |
| `headroom_watts` | number W | `headroom_amps * voltage` when both are known. |
| `voltage` | number V | Voltage used to derive watt headroom. |
| `limiting_link` | string | Link/branch id that currently provides headroom, or empty string. |
| `limiting_kind` | string | Kind for the limiting link, e.g. `breaker` or `meter`. |
| `limiting_capacity_amps` | number A | Capacity of the limiting link, or `0` when unknown. |
| `limiting_current_amps` | number A | Current observed/derived on the limiting link. |

The allocator uses this path model when clamping amp- and watt-based controls.
Boolean controls with a known nameplate are blocked when their nameplate would
exceed known path headroom.

## Islands And Accounts

Path:

```text
islands.<island_id>.<field>
```

Important fields:

| Field | Type | Unit | Meaning |
| --- | --- | --- | --- |
| `mode` | string | - | `on_grid`, `off_grid`, or `unknown`. |
| `members` | string | - | Comma-separated circuit ids in the island. |
| `account.solar.power` | number | W | Solar generation aggregate. |
| `account.battery.power` | number | W | Positive = discharging. |
| `account.grid.power` | number | W | Positive = importing. |
| `account.generation.power` | number | W | Derived source aggregate. |
| `account.load.total.power` | number | W | Derived load aggregate. |
| `account.solar.today.energy` | number | kWh | Since local midnight snapshot. |
| `account.battery.today.charge` | number | kWh | Since local midnight snapshot. |
| `account.battery.today.discharge` | number | kWh | Since local midnight snapshot. |
| `account.grid.today.import` | number | kWh | Since local midnight snapshot. |
| `account.grid.today.export` | number | kWh | Since local midnight snapshot. |

Planner budget fields live under:

```text
islands.<island_id>.budget.<field>
```

Current budget fields:

```text
battery_available_kwh
battery_capacity_kwh
demand_floor_kwh
demand_essential_kwh
demand_important_kwh
demand_opportunistic_kwh
reserve_kwh
pressure
forecast_supply_kwh
forecast_demand_kwh
forecast_net_kwh
```

## Policies And Allocation

Policy path:

```text
policy.<policy_id>.<field>
```

Fields include:

```text
target
tier
goal
goal_value
current_value
satisfied
marginal_value
planner.marginal_value
planner.required_kwh
planner.max_rate_kw
planner.slack_hours
planner.time_to_deadline_hours
planner.time_to_satisfy_hours
```

Allocation path:

```text
allocation.<policy_id>.<field>
```

Fields include:

```text
target
reason
commanded
target_bus
source_bus
path_complete
path_headroom_amps
path_headroom_watts
available_headroom_amps
available_headroom_watts
committed_amps
committed_watts
path_voltage
limiting_link
```

`path_headroom_*` is measured/derived headroom before this allocation pass.
`available_headroom_*` subtracts higher-priority commands already accepted in
the same allocator tick. `committed_*` is the estimated capacity reserved by an
accepted command.

Common `reason` values:

```text
on
off
drive
drive (headroom-clamped)
expression
no control
no setpoint element
no max/nameplate
no path headroom
shadowed by higher-tier policy
min dwell
min on time
min off time
```

## Reconstructing The Circuit Graph

1. Read `circuit.generation`.
2. Load matching `circuit.bus.*`, `circuit.branch.*`, and
   `circuit.terminal.*` records.
3. Build branch adjacency from `branch.parent -> branch.child` where
   `conducting == true`.
4. Choose render roots:
   - Prefer the bus with `id == "grid"`.
   - Otherwise use buses where `explicit_root == true`.
   - Otherwise use buses with no incoming conducting branch.
   - Multiple roots are valid.
5. Lay out circuit buses as vertical lanes. Branches connect lanes.
6. Attach appliance nodes from terminals where `owner != ""`.
7. For each appliance, choose an anchor terminal:
   - Prefer the terminal on the circuit closest to a render root.
   - Prefer roles `grid`, `connection`, or `parent` when distances tie.
8. Render non-anchor terminals as appliance fan-out lanes to their own circuits
   only when the downstream circuit has visible contents or useful meter data.
9. Use `terminal.owner_kind`, `terminal.label`, and `branch.label` for display
   metadata.
10. Render synthetic unaccounted rows from bus residual fields.

## Current Backend Limitations

- There is no deletion/tombstone protocol for element data. Use generations.
- Circuit branch endpoint direction trusts configured `parent -> child` topology.
  The backend does not compensate for bad meter polarity.
- Per-phase graph inference is not part of this contract yet. Use aggregate
  phase 0 values for graph visualisation.
- `members` and `route` are comma-separated strings, not arrays.
