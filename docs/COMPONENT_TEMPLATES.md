# Component Template Reference

Quick reference for standard component templates and their expected elements.

## Template Summary

| Template | Purpose | Required Elements |
|----------|---------|-------------------|
| `DeviceInfo` | Device identification | `type`, `name` |
| `EnergyMeter` | Electrical and energy measurements | `type` |
| `Battery` | Battery (recursive) | `soc` |
| `BatteryConfig` | Battery specifications | - |
| `Solar` | Solar PV array (recursive) | - |
| `SolarConfig` | Solar PV specifications | - |
| `Inverter` | Solar/battery/hybrid inverter | - |
| `EVSE` | EV charger | `state` |
| `Vehicle` | Connected vehicle | - |
| `Port` | Energy topology connection point | `role`, `flow` |
| `HVAC` | Climate control system | - |
| `WaterHeater` | Hot water tank | `temperature` |
| `Switch` | On/off control | `switch` |
| `Shutter` | Window/door shutter control | `position` |
| `ContactSensor` | Contact/door sensor | `open` or `alarm` |
| `Network` | Network connectivity | - |
| `Configuration` | Device settings | varies |
| **Capability primitive (energy app contract)** |||
| `PowerControl` | Unified actuator surface | `kind`, `setpoint` |

---

## Energy Topology Contract

The energy app builds circuit topology from [`Port`](#port) components only.
Capability templates such as `EVSE`, `Inverter`, `Battery`, `Solar`, `HVAC`,
`WaterHeater`, and `Switch` describe behaviour, state, controls, and domain
metadata; they do not create topology by themselves.

Any profile intended to become an `/apps/energy/appliance` must expose at least
one `Port`. A one-terminal appliance usually has a `connection` port. Inline or
distribution devices expose one port per externally meaningful terminal:
`supply` plus `outlet1..N` for a smart power strip, `grid` plus `car` for an
EVSE, `grid`/`backup`/`battery`/`pv` for a hybrid inverter, and so on.

The `Port` component path is the site wiring key. Top-level ports use their id
directly (`grid=house`). Nested subsystem ports use dotted paths
(`solar.mppt1=pv.east`). A port may also publish its own live
`circuit` element when the device knows the circuit identity at runtime, such
as a VIN-derived vehicle circuit.

Meters, controls, switches, and state components should live at the smallest
scope that is true. If a meter measures a terminal, put it under that `Port`. If
a meter measures an aggregate subsystem, put it under the subsystem component.
If a relay controls one outlet terminal, put the `Switch` under that outlet
`Port`.

State components nested under a `Port` describe things present at the circuit
that port is bound to. For example, `battery.store` is the battery reservoir
visible on the `battery` port's circuit. It is not a second topology node. The
energy app classifies that store state by the owning appliance: a battery/BMS
appliance contributes an authoritative store member, while an inverter or
charger contributes a view of the store on that bus.

---

## DeviceInfo

Device identification and metadata.

### Required
- `type: string` - Device category: "energy-meter", "inverter", "battery", "evse", "smart-switch", "contact-sensor"
- `name: string` - Device display name

### Optional
- `manufacturer_name: string` - Manufacturer display name
- `manufacturer_id: string` - Manufacturer identifier code
- `brand_name: string` - Brand display name (where it may differ from manufacturer; ie, non-OEM products)
- `brand_id: string` - Brand identifier code
- `model_name: string` - Model display name
- `model_id: string` - Model identifier code
- `serial_number: string` - Serial number
- `firmware_version: string` / `software_version: string` - Firmware version
- `hardware_version: string` - Hardware version
- `app_ver: string` - Application version (Zigbee)
- `zcl_ver: string` - ZCL version (Zigbee)

---

## DeviceStatus

Device runtime and operating status.

### Required

### Optional
- `time: systime` - Current device time
- `up_time: s` - Uptime since power-on
- `running_time: s/min/hr` - Total running time (from installation)
- `running_time_with_load: s/min/hr` - Running time under load
- `network: Network` - Network connectivity status (sub-component)

---

## Network

Network connectivity information (read-only status).

### Optional
- `mode: enum/string` - Active network mode/type: modbus, ethernet, wifi, cellular, zigbee

### Sub-components
Can be nested for grouped parameters. Standard network sub-components:

### ip: IP
- `address: string` - IPv4 address (or hostname)
- `gateway: string` - Default gateway

### ip6: IP6
- `address: string` - IPv6 address (or hostname)
- `gateway: string` - Default gateway

### modbus: Modbus
- `status: enum/string` - Connection status
- `variant: enum/string` - Protocol variant: rtu, tcp, or ascii
- `address: u8` - Modbus slave/unit address

### ethernet: Ethernet
- `status: enum/string` - Connection status
- `mac_address: string` - MAC address
- `link_speed: Mbps` - Link speed

### wifi: Wifi
- `status: enum/string` - Connection status
- `ssid: string` - Connected network SSID
- `rssi: dBm` - Signal strength
- `bssid: string` - Connected AP MAC address
- `channel: integer` - Wi-Fi channel
- `mac_address: string` - MAC address
- `ip_address: string` - IPv4 address

### bluetooth: Bluetooth
- `status: enum/string` - Connection status
- `mac_address: string` - MAC address

### cellular: Cellular
- `status: enum/string` - Connection status
- `signal_strength: dBm/%` - Signal strength
- `operator: string` - Network operator
- `imei: string` - Device IMEI
- `iccid: string` - SIM ICCID
- `ip_address: string` - Assigned IP address

### zigbee: Zigbee
- `status: enum/string` - Connection status
- `eui: EUI64` - MAC address
- `address: u16` - Network address
- `lqi: int` - Link quality index
- `rssi: dBm` - Received Signal Power

---

## EnergyMeter

Electrical and energy measurements.

An `EnergyMeter` measures electrical quantities at a point. It does not, by
itself, say where that point is connected. Connectivity is described by
[`Port`](#port) components and energy links.

For energy appliance profiles, put the meter under the `Port` it measures:
`grid.meter`, `backup.meter`, `battery.meter`, `outlet1.meter`, etc. A
standalone meter profile may expose a `Port` when the meter is itself modelled
as an energy appliance. A meter profile used only as an explicit
`/apps/energy/link meter=...` source may expose plain `EnergyMeter` components;
the link object supplies the topology in that case. A meter that measures a
remote reference point, such as an
export-limiting CT at the property gateway, belongs on a named reference
component such as `inverter.export_meter` and should not be treated as one of
the device's own port flows.

Reusable profiles should make each `EnergyMeter` internally sign-consistent.
For a meter, `import` means energy accumulated while its own `power` field is
positive, and `export` means energy accumulated while its own `power` field is
negative. This may deliberately differ from the appliance or vendor register
language: for example, an inverter battery-port meter whose positive power means
battery discharge into the inverter should map that discharge energy to
`import`, because it is import into the inverter-side terminal.

Port-level topology normalization belongs on the containing `Port`, not inside
the meter. The energy app interprets effective port power as positive when
power flows from the connected circuit into the appliance terminal. When a port
uses `meter_sign="inverted"`, instantaneous signed fields are flipped,
directional cumulative fields such as `import`/`export` are swapped, and gross
totals remain gross. Use profile expressions for vendor-specific semantic
counters such as explicit battery charge/discharge totals; reserve
`meter_sign` for whole-meter polarity reversal, such as a reversed CT or a
vendor meter whose signed fields and directional counters share the same
opposite convention.

### Required
- `type: string` - "single-phase", "three-phase", or "dc"

### Single-Phase AC
- `voltage: V` - Voltage
- `current: A` - Current
- `power: W` - Active power
- `apparent: VA` - Apparent power
- `reactive: var` - Reactive power
- `pf: 1` - Power factor (-1 to 1)
- `frequency: Hz` - Line frequency
- `phase: deg` - Phase angle
- `nature: enum` - Load nature: resistive, inductive, capacitive, nonload

### Three-Phase AC
All single-phase elements plus:
- `voltage1: V`, `voltage2: V`, `voltage3: V` - Per-phase voltage
- `current1: A`, `current2: A`, `current3: A` - Per-phase current
- `power1: W`, `power2: W`, `power3: W` - Per-phase active power
- `apparent1: VA`, `apparent2: VA`, `apparent3: VA` - Per-phase apparent power
- `reactive1: var`, `reactive2: var`, `reactive3: var` - Per-phase reactive power
- `pf1`, `pf2`, `pf3` - Per-phase power factor
- `ipv: V` - Inter-phase voltage average
- `ipv1: V`, `ipv2: V`, `ipv3: V` - Line-to-line voltages (AB, BC, CA)

### DC
- `voltage: V` - DC voltage
- `current: A` - DC current
- `power: W` - DC power

### Active Energy
- `import: kWh` - Total import
- `import1-3: kWh` - Per-phase import
- `export: kWh` - Total export
- `export1-3: kWh` - Per-phase export
- `net: kWh` - Total (net)
- `net1-3: kWh` - Per-phase total
- `absolute: kWh` - Gross (absolute)
- `absolute1-3: kWh` - Per-phase gross

### Reactive Energy
- `q1: kvarh` - Quadrant 1 (active import, inductive)
- `q2: kvarh` - Quadrant 2 (active export, inductive)
- `q3: kvarh` - Quadrant 3 (active export, capacitive)
- `q4: kvarh` - Quadrant 4 (active import, capacitive)
- `inductive: kvarh` - Inductive total (= q1 + q2); split by Q sign
- `inductive1-3: kvarh` - Per-phase inductive
- `capacitive: kvarh` - Capacitive total (= q3 + q4); split by Q sign
- `capacitive1-3: kvarh` - Per-phase capacitive
- `reactive_import: kvarh` - Reactive accumulated while active was imported (= q1 + q4); split by P sign
- `reactive_import1-3: kvarh` - Per-phase
- `reactive_export: kvarh` - Reactive accumulated while active was exported (= q2 + q3); split by P sign
- `reactive_export1-3: kvarh` - Per-phase
- `net_reactive: kvarh` - Net (= inductive - capacitive); used when device doesn't split
- `net_reactive1-3: kvarh` - Per-phase net
- `absolute_reactive: kvarh` - Gross (= inductive + capacitive)
- `absolute_reactive1-3: kvarh` - Per-phase absolute

### Apparent Energy
- `apparent: kVAh` - Total apparent (= apparent_import + apparent_export; populated directly by meters that don't split)
- `apparent1-3: kVAh` - Per-phase total
- `apparent_import: kVAh` - Apparent energy accumulated while importing active power
- `apparent_import1-3: kVAh` - Per-phase
- `apparent_export: kVAh` - Apparent energy accumulated while exporting active power
- `apparent_export1-3: kVAh` - Per-phase

### DC Energy
- `import: kWh` - Total import (or charge)
- `export: kWh` - Total export (or discharge)
- `net: kWh` - Total (net)
- `absolute: kWh` - Gross (absolute)

### Demand
- `demand: W` - Current demand (active power)
- `reactive_demand: var` - Current reactive demand
- `apparent_demand: VA` - Current apparent demand
- `current_demand: A` - Current demand
- `import_demand: W` - Import demand
- `export_demand: W` - Export demand
- `max_demand: W` - Maximum demand
- `max_reactive_demand: var` - Maximum reactive
- `max_apparent_demand: VA` - Maximum apparent
- `max_current_demand: A` - Maximum current
- `max_import_demand: W` - Maximum import
- `max_export_demand: W` - Maximum export
- `min_demand: W` - Minimum demand

---

## Port

Electrical connection point exposed by a device profile.

The energy graph is built from **circuits** and **ports**:

- A **circuit** is a named electrical region outside a port, such as `house`,
  `house.backup`, `dc_bus`, `pv1`, `carport`, or `grid`. Circuits are not
  declared separately; they exist because ports and links name them. The runtime
  graph calls these nodes buses internally.
- A **port** is one electrical terminal of a device-backed appliance. A port
  has a stable component path, a role, a flow domain, optional meter/control
  surfaces, and a runtime circuit binding.
- A **link** is installed inline infrastructure configured directly in the
  energy app (`/apps/energy/link`): breakers, grid links, contactors, inline
  meters, sub-board feeds. Links connect two circuits with `parent=` and
  `child=`.
- A **topology root** is a source-side entry point for rendering. The only
  non-appliance root is a configured grid ingress link (`parent=grid`). Other
  source roots, such as generators, are appliance ports marked with
  `root=yes`. Root status affects presentation and source-side graph walking;
  it does not imply grid connectivity.
- An **appliance** is a user-level participant (`/apps/energy/appliance`): loads,
  sources, stores, EVSEs, inverters, and other device-backed things. For
  one-port appliances, config usually binds `connection=<name>`. For multi-port
  appliances, config binds each profile `Port` component path to a circuit.

Profiles define **what terminals a device has**. Site config defines **where
those terminals are wired**. A reusable profile must not contain installation
circuit names like `house` or `dc_bus`; those belong in
`/apps/energy/appliance`.

Topology discovery is deliberately simple: the energy app walks the appliance's
device tree recursively and reads every `Port` component. `EVSE`, `Inverter`,
`Switch`, `Solar`, `Battery`, and similar templates add runtime meaning; they do
not define topology by themselves. A port with a live `circuit` element can name
its own circuit (for example a VIN-derived car circuit). Otherwise, site config
binds circuits using the port component path.

Example site bindings:

```
/apps/energy/link add name=main_feed kind=breaker parent=grid child=house capacity=63
/apps/energy/link add name=backup_feed kind=contactor parent=house child=house.backup capacity=50
/apps/energy/link add name=sub_main_meter kind=meter parent=house child=sub_main meter=main_meter.meter

/apps/energy/appliance add name=fridge device=fridge_plug connection=house.gpo kind=load
/apps/energy/appliance add name=generator device=generator_meter connection=generator kind=generator root=yes
/apps/energy/appliance add name=goodwe device=goodwe_ems grid=house backup=house.backup battery=dc_bus solar=pv_bus
/apps/energy/appliance add name=hybrid device=hybrid_ems solar.mppt1=pv.east solar.mppt2=pv.west battery=dc_bus grid=house
/apps/energy/appliance add name=bms device=pylon_bms battery=dc_bus
```

The last two lines intentionally share `battery=dc_bus`: the inverter's battery
terminal and the BMS's battery terminal land on the same DC circuit. The energy
app can then reconcile inverter-side battery flow with BMS/store state without
inventing a private pairing rule.

For a standalone battery/BMS appliance, positive battery-port power means
charging because the DC circuit feeds the battery appliance. For an inverter's
battery port, positive battery-port power means battery discharge because the DC
circuit feeds the inverter appliance. Both are the same port convention viewed
from different appliances.

Transfer switches are not plain two-terminal links. Model the sources and load
as separate circuits (`grid`, `generator`, `main`) and model the transfer switch
as a device-backed appliance with source/load ports and a dynamic selected path.
The runtime should then expose only the currently closed source-to-load edge, so
the graph cannot accidentally parallel `grid` and `generator`.

Console views serve different jobs: `/apps/energy/topology` is the raw
flat bus/link/port audit, while `/apps/energy/circuit` collapses appliance
ports into appliance rows so user-visible devices are the primary objects.

### Required
- `role: enum` - Stable terminal role. Common roles are:
  - `connection` - Generic one-port load/source/store connection.
  - `grid` - AC grid/site-side terminal of an inverter, charger, or converter.
  - `backup` - Backup/EPS/load output of an inverter.
  - `battery` - DC battery terminal.
  - `pv` - PV input terminal. Multiple PV inputs are distinct component paths
    such as `solar.mppt1` and `solar.mppt2`; they still use
    role `pv`.
  - `car` - Vehicle-side EVSE terminal; usually VIN-derived.
  - `outlet` - Downstream switched outlet/load terminal on a smart GPO or power
    strip.
  - `parent` / `child` - Directional terminals for EVSEs or inline devices
    where source-ward/load-ward naming is meaningful.
- `flow: enum` - Flow domain at this terminal, from the connected circuit's
  perspective:
  - `consume` - Draws from the connected circuit; unmetered/dark flow is
    conservatively treated as load.
  - `supply` - Supplies into the connected circuit.
  - `bidirectional` - Can consume or supply relative to the connected circuit.

### Optional
- `circuit: string` - Live or static circuit name for this port. Site config
  usually supplies this by binding the port path (`grid=house`,
  `solar.mppt1=pv.east`). Profiles/drivers may expose it directly when
  the device knows the circuit identity at runtime, such as a VIN-derived EVSE
  car circuit.
- `capacity: A` - Port or conversion/link current limit.
- `closed: bool` - Whether this port/link is electrically closed. Missing means
  closed.
- `phase: int` - Per-phase meter slot to project into this port when a shared
  meter is multi-phase.
- `meter_sign: enum` - `normal` or `inverted`. Applied to the nested terminal
  meter when the energy app projects it onto this port. Use this when the
  profile's raw meter sign is opposite to the port convention: positive port
  power means connected circuit to appliance terminal, negative means appliance
  terminal to connected circuit. Site/runtime appliance and link bindings may
  override this for reversed CTs or installation quirks. `flow` remains a
  capability/default-inference hint; it is not a sign transform.

### Sub-components
- `meter: EnergyMeter` - Flow at this exact terminal. This is the preferred
  location for multi-port devices.
- `control: PowerControl` - Actuator for this terminal, if the terminal is
  directly controllable.
- `store: Battery` - Battery/store data visible through this terminal. Under an
  inverter battery port this is the inverter's view of the store on that
  circuit. Under a BMS or standalone battery appliance port it is authoritative
  store state. In both cases it is not a separate topology node; member vs view
  semantics come from the owning appliance.
- `solar: Solar` - PV/string data visible through this terminal.
- `vehicle: Vehicle` - Vehicle data visible through an EVSE car port.

### Multi-Port Devices

A hybrid inverter is a converter with several ports. The public electrical
terminals are usually top-level `Port` components; none is "the device's
circuit". For example:

```
component:
    id: grid
    template: Port
    element: role, "grid"
    element: flow, "bidirectional"
    component:
        id: meter
        template: EnergyMeter
        element: type, "single-phase"
        element-map: voltage, @grid_voltage
        element-map: current, @grid_current
        element-map: power, @grid_power

component:
    id: backup
    template: Port
    element: role, "backup"
    element: flow, "bidirectional"
    element: meter_sign, "inverted"
    component:
        id: meter
        template: EnergyMeter
        element: type, "single-phase"
        element-map: voltage, @backup_voltage
        element-map: current, @backup_current
        element-map: power, @backup_power

component:
    id: battery
    template: Port
    element: role, "battery"
    element: flow, "bidirectional"
    component:
        id: meter
        template: EnergyMeter
        element: type, "dc"
        element-map: voltage, @bat_voltage
        element-map: current, @bat_current
        element-map: power, @bat_power
    component:
        id: store
        template: Battery
        element-map: soc, @bat_soc
        element-map: soh, @bat_soh

component:
    id: solar
    template: Solar
    component:
        id: meter
        template: EnergyMeter
        element: type, "dc"
        element-map: power, @pv_power_total
    component:
        id: pv
        template: Port
        element: role, "pv"
        element: flow, "supply"
        component:
            id: meter
            template: EnergyMeter
            element: type, "dc"
            element-map: voltage, @pv_voltage
            element-map: current, @pv_current
            element-map: power, @pv_power

component:
    id: inverter
    template: Inverter
    element-map: state, @state
```

This backup example assumes `@backup_power` is a vendor load/output reading:
positive when the inverter is feeding the backup circuit. That is opposite to
the port convention, so the port carries `meter_sign="inverted"`. If a device
already reports backup power positive when the backup circuit feeds the
inverter terminal, omit the inversion.

And the site config wires those terminals:

```
/apps/energy/appliance add name=goodwe device=goodwe_ems grid=house backup=house.backup battery=dc_bus solar=pv_bus
```

This means:

- `grid=house` connects the inverter's grid-side AC terminal to the house bus.
- `backup=house.backup` connects the backup/EPS output to a different AC bus.
- `battery=dc_bus` breaks the DC battery terminal out as its own bus. A BMS or
  second inverter can bind its own `battery`/`dc` port to the same `dc_bus`.
- `solar=pv_bus` names the PV side separately, so PV generation
  is not collapsed into the grid or battery terminal.

If the inverter exposes battery SOC internally, put that `Battery` component
under the inverter's `battery` port as a **view** of the store on `dc_bus`. If a
separate BMS is also configured as an appliance on `dc_bus`, the BMS is the store
member and the inverter battery view corroborates it. If no separate BMS exists,
the inverter's battery view can define the store.

---

## Battery

Battery (recursive - can represent whole system, individual pack, or sub-pack).

`Battery` is store metadata, not a topology terminal. A BMS, inverter battery
view, or standalone battery appliance must expose a `Port` for the electrical
terminal, usually `battery: Port` or `connection: Port` with `role="battery"`
and `flow="bidirectional"`. Put the `Battery` component under that port,
usually as `store: Battery`, when it is the state of the store visible at that
terminal. The nested `Battery` describes the store on the port's connected
circuit/bus; it is a member when the owning appliance is a battery/BMS, and a
view when the owning appliance is an inverter/charger observing its battery
terminal. Pack-level `Battery` sub-components may remain nested inside the store
component.

### Canonical Port Layout

Use the same one-member vs many-member shape as solar:

```text
# One battery terminal
battery: Port
battery.meter: EnergyMeter       # terminal flow meter
battery.store: Battery           # store state visible at this terminal

# N independently bindable battery terminals
battery: Battery                 # aggregate battery/store container
battery.meter: EnergyMeter       # aggregate meter if available, otherwise sum members
battery.store: Battery           # aggregate store state if available/calculable
battery.pack1: Port
battery.pack1.meter: EnergyMeter # pack1 meter if available
battery.pack1.store: Battery
battery.packN: Port
battery.packN.meter: EnergyMeter # packN meter if available
battery.packN.store: Battery
```

Do not create a single-child aggregate container. If only one battery terminal
exists, `battery` is the `Port`.

### Required
- `soc: %` - State of Charge (0-100%)

### Status
- `soh: %` - State of Health (0-100%)
- `mode: enum` - Battery mode: standby, charging, discharging
- `temp: °C` - Average/representative temperature
- `low_battery: boolean` - Low battery warning

### Capacity
- `remain_capacity: Ah` - Remaining capacity
- `full_capacity: Ah` - Full capacity
- `cycle_count: count` - Charge cycles

### Energy-management setpoints (optional, writable)
- `target_state: %` - SOC target the BMS/inverter should aim for; the energy app
  may shift this throughout the day (high during solar surplus, lower as overnight
  reserve adjusts)
- `min_state: %` - SOC floor below which the BMS must not discharge regardless of
  load demand; protects overnight reserve

### Limits
- `max_charge_current: A` - Maximum charge current
- `max_discharge_current: A` - Maximum discharge current
- `max_charge_power: W` - Maximum charge power
- `max_discharge_power: W` - Maximum discharge power

### Cell Data (typically at pack level)
- `cell_voltage1-16: V` - Individual cell voltages
- `cell_temp1-4: °C` - Individual cell temperatures

### Temperature (typically at pack level)
- `mosfet_temp: °C` - MOSFET temperature
- `env_temp: °C` - Environment temperature

### Status Flags (typically at pack level)
- `warning_flag: bitfield` - Warning flags
- `protection_flag: bitfield` - Protection flags
- `status_fault_flag: bitfield` - Status/fault flags
- `balance_status: bitfield` - Cell balance status

### Sub-components
- `pack1, pack2, ...packN: Battery` - Sub-batteries (for multi-pack systems)
- `meter: EnergyMeter` (type: "dc") - DC measurements at this state level when
  the meter is internal to the pack/store. Terminal flow meters belong under
  the enclosing `Port`.
- `config: BatteryConfig` - Static configuration (cell count, topology, limits)

---

## BatteryConfig

Static battery configuration and specifications.

### Topology
- `topology: string` - Arrangement description (e.g., "4S2P" for packs or cells)

### Pack Arrangement (system level)
- `pack_count: count` - Number of battery packs/modules
- `packs_series: count` - Number of packs in series
- `packs_parallel: count` - Number of packs in parallel

### Cell Configuration (pack level)
- `cell_count: count` - Total number of cells in this pack
- `cells_series: count` - Number of cells in series
- `cells_parallel: count` - Number of cells in parallel
- `cell_chemistry: string` - Cell chemistry (e.g., "LiFePO4", "NMC", "LTO")

### Voltage Limits
- `voltage_min: V` - Minimum pack voltage
- `voltage_max: V` - Maximum pack voltage
- `cell_voltage_min: V` - Minimum cell voltage
- `cell_voltage_max: V` - Maximum cell voltage

### Capacity Specs
- `design_capacity: Ah` - Design/nominal capacity
- `rated_energy: Wh` - Rated energy capacity

### Current/Power Limits
- `max_charge_current: A` - Maximum continuous charge current
- `max_discharge_current: A` - Maximum continuous discharge current
- `peak_charge_current: A` - Peak charge current (short duration)
- `peak_discharge_current: A` - Peak discharge current (short duration)
- `max_charge_power: W` - Maximum charge power
- `max_discharge_power: W` - Maximum discharge power

### Temperature Limits
- `temp_min_charge: °C` - Minimum charging temperature
- `temp_max_charge: °C` - Maximum charging temperature
- `temp_min_discharge: °C` - Minimum discharging temperature
- `temp_max_discharge: °C` - Maximum discharging temperature

---

## Solar

Solar PV array/input (recursive - can represent whole array, string, or individual panel).

`Solar` describes PV subsystem state and configuration; topology still comes
from `Port`s. A standalone/simple PV device or single-input inverter should
expose a top-level `solar: Port` containing a DC meter. A multi-input inverter
uses a top-level `solar: Solar` grouping component with aggregate meters/config
and nested ports such as `mppt1: Port` and `mppt2: Port`. Site config then binds
`solar.mppt1=pv.east`, `solar.mppt2=pv.west`, etc.

### Canonical Port Layout

```text
# One MPPT/PV input
solar: Port
solar.meter: EnergyMeter         # the solar terminal meter

# N independently bindable MPPT/PV inputs
solar: Solar                     # aggregate solar container
solar.meter: EnergyMeter         # aggregate meter if available, otherwise sum MPPT meters
solar.mppt1: Port
solar.mppt1.meter: EnergyMeter   # mppt1 meter if available
solar.mpptN: Port
solar.mpptN.meter: EnergyMeter   # mpptN meter if available
```

Do not create a single-child aggregate container. If only one MPPT/PV input
exists, `solar` is the `Port`. If multiple MPPT/PV inputs exist, `solar` is the
aggregate `Solar` component and each independently bindable input is a child
`Port`.

### Optional
- `state: enum` - PV state: not_connected, no_power, producing
- `mode: enum` - Operating mode: mppt, constant_voltage, off, fault
- `temp: °C` - Panel/module temperature
- `efficiency: %` - MPPT/conversion efficiency

### Sub-components
- `panel1, panel2, ...panelN: Solar` - Individual panels/modules (for optimizer/microinverter systems)
- `string1, string2, ...stringN: Solar` - Individual strings (for multi-string systems)
- `mppt1, mppt2, ...mpptN: Port` - Electrical PV inputs when the subsystem has
  independently bindable strings/MPPTs.
- `meter: EnergyMeter` - Aggregate PV measurements (type: "dc" for
  string/optimizer, "single-phase" for microinverter). Terminal-specific meters
  belong under the relevant `Port`.
- `config: SolarConfig` - Static configuration (panel specs, array topology)

---

## SolarConfig

Static solar PV configuration and specifications.

### Array Arrangement (system level)
- `panel_count: count` - Total number of panels
- `string_count: count` - Number of strings
- `topology: string` - Array arrangement description (e.g., "10P+6P" for 2 strings of 10 panels and 6 panels)

### Panel Specifications (panel/string level)
- `rated_power: W` - Panel rated power (Wp)
- `voltage_mpp: V` - Voltage at maximum power point
- `current_mpp: A` - Current at maximum power point
- `voltage_oc: V` - Open circuit voltage
- `current_sc: A` - Short circuit current
- `temp_coeff_power: %/°C` - Temperature coefficient of power
- `temp_coeff_voltage: V/°C` - Temperature coefficient of voltage

---

## Inverter

Solar/battery/hybrid inverter with optional grid, battery, renewable inputs, and load connections.

`Inverter` describes converter state and capability. It does not define the
electrical terminals by itself. Inverter profiles must expose one `Port` per
externally bindable terminal. Those ports are usually top-level siblings of the
`Inverter` metadata component (`grid`, `backup`, `battery`, `pv`). Grouped PV
inputs should live under a top-level `solar: Solar` subsystem, not under the
operational `inverter: Inverter` metadata component.

### Optional
- `state: enum` - Operating state
- `events: bitfield` - Active fault/event flags
- `mode: enum` - Operating mode: on_grid, off_grid, hybrid, eco, backup
- `temp: °C` - Inverter temperature (representative; use specific temps below when available)
- `heatsink_temp: °C` - Heatsink temperature (closest to die; most useful for thermal monitoring)
- `cabinet_temp: °C` - Cabinet/ambient temperature inside the enclosure
- `transformer_temp: °C` - Transformer temperature (transformer-based inverters)
- `rated_power: W` - Rated output power
- `efficiency: %` - Current conversion efficiency
- `bus_voltage: V` - DC bus voltage

Do not model a hybrid inverter as one root meter plus a bag of unrelated
sub-meters when the device reports distinct terminals. Put each terminal's
meter/control/state under the relevant `Port`, and keep remote reference meters
as named non-port components.

### Topology and Related Components
- `grid: Port` - Grid/site AC terminal, usually `flow="bidirectional"`.
- `backup: Port` - Backup/EPS/load AC terminal, usually
  `flow="bidirectional"`.
- `battery: Port` - DC battery terminal, usually `flow="bidirectional"`; may
  contain a `Battery` view and a DC `meter`.
- `pv: Port` - Single PV/DC source terminal, usually `flow="supply"`; may
  contain `Solar` detail and DC meters.
- `solar: Solar` - Optional top-level PV subsystem grouping; may contain
  aggregate meter plus nested `mpptN: Port` components.
- `control: PowerControl` (optional) - Energy-app actuator; for hybrid inverters, typically `kind=continuous`, `direction=bidirectional` for charge/discharge, or `kind=autonomous` when the inverter runs its own self-consumption policy
- `export_meter: EnergyMeter` - Export-limiting / self-consumption reference
  meter at the property gateway (point of common coupling); measures the
  whole-site grid interface, not the inverter's own output. Put this under the
  `inverter: Inverter` metadata component as operational/reference data, not as
  a top-level terminal.
- `evse: EVSE` - Integrated EV charger (for inverters with built-in EVSE)
- `config: InverterConfig` - Static inverter ratings and capabilities

---

## InverterConfig

Static inverter configuration and ratings (analogous to BatteryConfig / SolarConfig).

### Power Ratings
- `rated_power: W` - Rated active power output
- `rated_apparent: VA` - Rated apparent power output
- `rated_current: A` - Rated AC current
- `rated_reactive_inject: var` - Maximum reactive output when injecting (over-excited / leading)
- `rated_reactive_absorb: var` - Maximum reactive output when absorbing (under-excited / lagging)
- `pf_over_excited: 1` - Minimum power factor when over-excited (leading)
- `pf_under_excited: 1` - Minimum power factor when under-excited (lagging)

### Grid Limits
- `voltage_nominal: V` - Nominal AC line voltage
- `voltage_min: V` / `voltage_max: V` - Operational voltage range

### Capability
- `intentional_islanding: bitfield` - Supported intentional islanding categories

---

## EVSE

Electric Vehicle Supply Equipment (EV charger).

An EVSE profile must expose at least two ports:

- `grid: Port` (or `supply: Port`) - site-side electrical supply,
  `flow="consume"` for a unidirectional charger.
- `car: Port` - vehicle-side terminal, `flow="supply"` for a unidirectional
  charger and `flow="bidirectional"` for V2G/V2H.

`EVSE` itself is runtime/task metadata. Put the charge-current control and
site-side meter under `grid`. Put `Vehicle` state under `car`. If the EVSE knows
the connected VIN, expose it as the `car` port's live `circuit` element; site
config can otherwise bind `car=<vehicle-circuit>`.

### Optional
- `temp: °C` - EVSE temperature
- `session_energy: Wh` - Energy delivered in current charging session
- `lifetime_energy: Wh` - Energy delivered in the lifetime of the charger
- `state: enum` - J1772 pilot state: A (standby), B (vehicle detected), C (ready/charging), D (ventilation required), etc.
- `error: bitfield/enum` - Error flags
- `connected: boolean` - Vehicle connected

### Topology and Related Components
- `grid: Port` / `supply: Port` - Site-side supply terminal.
- `car: Port` - Vehicle-side terminal.
- `control: PowerControl` - Energy-app actuator when the control is EVSE-wide;
  prefer nesting under the controlled `Port` when the controlled terminal is
  clear.
- `vehicle: Vehicle` - Connected vehicle information; prefer nesting under
  `car`.
- `config: Configuration` - EVSE configuration (mode, limits, etc.)

---

## Vehicle

Vehicle information (typically EV connected to charger).

`Vehicle` is state metadata, not topology. For an EVSE, place `Vehicle` under
the EVSE's `car: Port`. For a separately modelled car appliance, expose a
`battery` or `connection` port for the vehicle/storage circuit and put
`Vehicle` state under that port or beside it as metadata.

### Optional
- `vin: string` - Vehicle identification number
- `soc: %` - State of charge (0-100%)
- `range: km` - Remaining range
- `battery_capacity: kWh` - Battery capacity

---

## HVAC

Heating, ventilation, and air conditioning systems.

`HVAC` is thermal comfort metadata. An HVAC energy appliance still needs a
`connection: Port` (or a more specific stable port id) with `flow="consume"`.
Put the consumption meter and controllable surface under that port when they
measure/control the electrical connection.

### Required

### Optional
- `temperature: °C/°F` - Current ambient temperature
- `state: enum` - Current active state - off, heating, cooling, etc
- `target_temperature: °C/°F` (writable) - Target/commanded temperature
- `min_temperature: °C/°F` (writable) - Comfort floor; the energy app must add heat (or stop cooling) below this even at the cost of grid import
- `super_temperature: °C/°F` (writable) - Opportunistic ceiling for pre-cooling/pre-heating when surplus energy is available
- `humidity: %` - Current relative humidity
- `target_humidity: %` (writable) - Target/commanded humidity
- `mode: enum` - Operating mode (off, heat, cool, auto, fan_only, dry)
- `fan_speed: enum/%` - Fan speed (low, medium, high, auto, or 0-100%)

### Topology and Related Components
- `connection: Port` - Electrical supply/load terminal.
- `control: PowerControl` (optional) - Energy-app actuator; typically `kind=discrete` for single-stage units, `kind=staged` for multi-stage

---

## WaterHeater

Hot water tank with thermostat-controlled heating element. Tracked as thermal
storage by the energy app, which can opportunistically super-heat when surplus
energy is available and let the tank coast down to a comfort floor otherwise.

`WaterHeater` is thermal storage metadata. A water-heater energy appliance must
expose a `connection: Port` with `flow="consume"` for the electrical heating
load. Put element meters and relays under that port, or expose multiple element
ports (`element1`, `element2`) when the elements are independently wired or
controlled.

### Required
- `temperature: °C/°F` - Current water temperature

### Optional
- `state: enum` - Heating/idle/error
- `target_temperature: °C/°F` (writable) - Normal heating setpoint
- `min_temperature: °C/°F` (writable) - Comfort floor for hot water availability; below this the energy app must add heat regardless of pressure
- `super_temperature: °C/°F` (writable) - Opportunistic ceiling for super-heating when surplus energy is available
- `mode: enum` - Operating mode (e.g. normal, vacation, boost)
- `volume: L` - Tank capacity (informational; helps planner estimate stored thermal energy)

### Topology and Related Components
- `connection: Port` - Electrical heating load terminal.
- `meter: EnergyMeter` - Thermal or internal element energy metadata. Terminal
  consumption meters belong under the relevant `Port`.
- `control: PowerControl` (optional) - Energy-app actuator; typically `kind=discrete` for relay-controlled elements

---

## Switch

On/off control devices.

`Switch` is itself a control surface: the `switch` element is both the
observable state and the actuator. When a `Switch` is associated with a
[`Port`](#port), the energy app can use it as a discrete control component
(implicit `kind=discrete`, `setpoint=switch`). There is no need to nest a
`PowerControl` under a Switch; instead, optional control-metadata elements (the
subset that makes sense for a binary actuator) can be added directly on the
Switch. See [PowerControl](#powercontrol) for the full set; the subset
applicable to a discrete switch is listed below.

`Switch` does not define topology. Smart plugs, GPOs, relays, and power strips
must expose `Port`s for the electrical terminals they switch or measure. A
smart plug/power strip usually has `supply: Port` with `flow="consume"` and one
or more outlet ports with `flow="supply"`. Put the `Switch` under the outlet
port it controls. Fixed, opaque switch-load devices may expose a single
`connection: Port`.

### Required
- `switch: boolean/enum` - Switch state (on/off, 0/1). Also the setpoint.

### Optional (device-level)
- `type: enum` - Switch type - light, power, outlet (power outlet), fan, etc
- `mode: enum` - Switch mode
- `timer: s` - Timer value

### Optional (energy-app control metadata)
- `direction: enum` - `consume` (default) / `produce` / `bidirectional`
- `nameplate_power: W` - Known nominal load when on (for fixed-power appliances)
- `min_on_time: s` - Minimum duration the switch must remain on after being turned on
- `min_off_time: s` - Minimum duration it must remain off after being turned off
- `min_dwell: s` - Minimum time between any two transitions
- `max_cycles_per_hour: count` - Cap on on-off cycles per hour (relay-protection)
- `command_latency: s` - Typical command-to-effect lag (informational)
- `can_disable: bool` - `false` for switches that accept commands but cannot be cleanly turned off (rare; default `true`)

### Topology and Related Components
- `supply: Port` - Upstream supply terminal for inline/distribution switches.
- `outlet1, outlet2, ...outletN: Port` - Downstream switched terminals for
  smart GPOs/power strips.
- `connection: Port` - Single opaque electrical terminal for fixed switch-load
  devices.
- `meter: EnergyMeter` - Switch-internal metadata. Terminal energy meters belong
  under the relevant `Port`.

---

## Shutter

Window/door shutter control devices.

### Required
- `position: %` - Shutter position (0-100%)

### Optional
- `type: enum` - Shutter type - window, blind, garage, etc
- `state: enum` - Shutter state (open, closed, opening, closing)
- `tilt: %` - Shutter tilt angle (0-100%)
- `target_position: %` - Target/commanded position (writable)
- `target_tilt: %` - Target/commanded tilt (writable)

---

## ContactSensor

Door/window sensors.

### Required
- `open: boolean` - Open/closed state, OR

### Optional
- `alarm: boolean` - Alarm status
- `tamper: boolean` - Tamper detection

---

## Configuration

Device configuration parameters. Elements vary by device type.

### Common
- `demand_period: min` - Demand averaging period
- `slide_time: min` - Demand slide time
- `password: string` - Device password
- `reset_energy_data: trigger` - Reset energy counters
- `reset_demand_data: trigger` - Reset demand data

### Sub-components
Can be nested for grouped parameters. Standard sub-components:

#### `modbus: ModbusConfig`
Modbus/RS485 network configuration (writable settings).
- `address: integer` - Modbus slave address (1-247)
- `baud_rate: enum` - Serial baud rate (1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200)
- `parity: enum` - Serial parity (none, even, odd)
- `stop_bits: enum` - Stop bits (1, 2)

#### `ethernet: EthernetConfig`
Ethernet network configuration (writable settings).
- `dhcp_enabled: boolean` - DHCP enable/disable
- `ip_address: string` - Static IPv4 address (when DHCP disabled)
- `gateway: string` - Default gateway
- `dns_primary: string` - Primary DNS server
- `dns_secondary: string` - Secondary DNS server
- `hostname: string` - Device hostname

#### `wifi: WifiConfig`
Wi-Fi network configuration (writable settings).
- `ssid: string` - Target network SSID
- `password: string` - Wi-Fi password/key
- `security: enum` - Security mode (open, wep, wpa, wpa2, wpa3)
- `dhcp_enabled: boolean` - DHCP enable/disable
- `ip_address: string` - Static IPv4 address (when DHCP disabled)
- `gateway: string` - Default gateway

#### `cellular: CellularConfig`
Cellular/LTE network configuration (writable settings).
- `apn: string` - Access point name
- `username: string` - APN username
- `password: string` - APN password
- `pin: string` - SIM PIN

#### `zigbee: ZigbeeConfig`
Zigbee network configuration (writable settings).
- ...

---

## PowerControl

Unified actuator surface for any device whose energy consumption (or
production) can be observed and optionally directed by an external controller.
One device may expose multiple `PowerControl` components (e.g. a hybrid inverter
publishes separate charge and discharge surfaces).

When a [`Switch`](#switch) is associated with a `Port`, the energy app can use
that switch as an implicit discrete control surface (`kind=discrete`,
`setpoint=switch`). A subset of the elements documented below - the ones that
make sense for a binary actuator - can be added directly on the Switch instead
of nesting a separate `PowerControl` sub-component. The `Switch` does not
replace the `Port`; it only describes control.

### Required
- `kind: enum` - Control type:
  - `autonomous` - device runs its own policy; no setpoint accepted
  - `discrete` - on/off (relay, contactor, smart plug)
  - `continuous` - smoothly adjustable within `[min, max]` at `step` resolution
  - `staged` - finite ordered set of setpoint values (e.g. multi-tap heater)
- `setpoint: writable` - The actuator. For `discrete`, a boolean or 0/1 enum.
  For `continuous`/`staged`, a number in the unit specified by `unit`. Absent
  on `kind=autonomous`.

### Optional
- `direction: enum` - `consume` (load), `produce` (source), `bidirectional`. Default: `consume`.
- `unit: enum` - Setpoint and limit unit:
  - `A` - amperes (typical for EVSE)
  - `W` - watts
  - `percent` - 0-100% of an external reference
  - `nameplate_fraction` - 0-1 of `max`
- `min: num` - Minimum non-zero setpoint (in `unit`). Below this the device is effectively off.
- `max: num` - Maximum allowable setpoint (in `unit`).
- `step: num` - Resolution of setpoint changes (in `unit`); e.g. 1 A for an EVSE.
- `measured: alias` - Reference (`@path`) to the element carrying actual current
  consumption or production, typically a neighbouring `EnergyMeter`'s `power`.
  Lets the energy app close the loop without per-device knowledge.

### State-change constraints (optional)
- `min_on_time: s` - Minimum duration the device must remain on after being turned on.
- `min_off_time: s` - Minimum duration it must remain off after being turned off.
- `min_dwell: s` - Minimum time between any two setpoint changes.
- `max_cycles_per_hour: count` - Cap on on-off transitions per hour.
- `ramp_rate: W/s` or `A/s` - Maximum rate of setpoint change.
- `command_latency: s` - Typical command-to-effect lag (informational).
- `can_disable: bool` - `false` for devices that accept setpoint changes but
  cannot be cleanly turned off (some industrial inverters, always-on
  controllers). Default: `true`.

### Autonomous control declaration (when `kind=autonomous`)
- `autonomous_mode: enum` - Identifies the device's autonomous behaviour:
  - `track_meter` - tracks a referenced energy meter (e.g. meter-watching battery inverter)
  - `schedule` - runs an internal schedule
  - `weather` - follows ambient temperature, solar irradiance, etc.
  - `unknown` - device declares itself autonomous but the policy is opaque
- `autonomous_reference: alias` - For `track_meter`: the meter element this
  device watches. Used by the energy app to detect conflicts (two autonomous
  devices watching the same reference will fight).

### Mapping common cases

| Case | Configuration |
|------|---------------|
| Smart plug, no power info | `kind=discrete`, no `max` |
| Smart plug with nameplate | `kind=discrete`, `unit=W`, `max=<nameplate>` |
| EVSE, 6-32 A in 1 A steps | `kind=continuous`, `unit=A`, `min=6`, `max=32`, `step=1` |
| Inverter, % of rated power | `kind=continuous`, `unit=percent`, `min=0`, `max=100`, `step=1` |
| Hybrid inverter, charge or discharge | two `PowerControl`s, `direction=bidirectional` or split |
| Meter-watching battery inverter | `kind=autonomous`, `autonomous_mode=track_meter`, `autonomous_reference=@<grid_meter>` |
| Heat-pump compressor | `kind=discrete`, `min_on_time=600`, `min_off_time=300` |

---

## Usage Examples

### Energy Meter (Single-Phase)
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "energy-meter"
        element: name, "Eastron SDM120"
    component:
        id: connection
        template: Port
        element: role, "connection"
        element: flow, "bidirectional"
        component:
            id: meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: voltage, @voltage
            element-map: current, @current
            element-map: power, @activePower
            element-map: apparent, @apparentPower
            element-map: reactive, @reactivePower
            element-map: pf, @powerFactor
            element-map: frequency, @frequency
            element-map: import, @importActiveEnergy
            element-map: export, @exportActiveEnergy
```

Site wiring:

```
/apps/energy/appliance add name=main_meter device=sdm120 connection=house
```

### Battery System with BMS
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "battery"
        element: name, "LiFePO4 Battery"
    component:
        id: battery
        template: Port
        element: role, "battery"
        element: flow, "bidirectional"
        component:
            id: store
            template: Battery
            element-map: soc, @soc
            element-map: soh, @soh
            element-map: mode, @battery_mode
            element-map: temp, @temp_avg
            element-map: remain_capacity, @capacity_ah
            element-map: cycle_count, @cycles
        component:
            id: meter
            template: EnergyMeter
            element: type, "dc"
            element-map: voltage, @voltage
            element-map: current, @current
            element-map: power, @power
            element-map: import, @total_charge
            element-map: export, @total_discharge
```

Site wiring:

```
/apps/energy/appliance add name=house_bms device=house_bms battery=dc_bus
```

The `battery` port lands on `dc_bus`. The nested `store` is the BMS's knowledge
of the reservoir on that bus.

### Hybrid Solar Inverter
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "inverter"
        element: name, "Hybrid Inverter"
    component:
        id: grid
        template: Port
        element: role, "grid"
        element: flow, "bidirectional"
        element: meter_sign, "inverted"
        component:
            id: meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: voltage, @inv_ac_voltage
            element-map: current, @inv_ac_current
            element-map: power, @inv_ac_power
            element-map: frequency, @inv_ac_frequency
    component:
        id: backup
        template: Port
        element: role, "backup"
        element: flow, "bidirectional"
        element: meter_sign, "inverted"
        component:
            id: meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: voltage, @backup_voltage
            element-map: current, @backup_current
            element-map: power, @backup_power
    component:
        id: solar
        template: Solar
        element-map: state, @pv_state
        component:
            id: meter
            template: EnergyMeter
            element: type, "dc"
            element-map: power, @pv_power_total
        component:
            id: mppt1
            template: Port
            element: role, "pv"
            element: flow, "supply"
            component:
                id: meter
                template: EnergyMeter
                element: type, "dc"
                element-map: voltage, @pv1_voltage
                element-map: current, @pv1_current
                element-map: power, @pv1_power
        component:
            id: mppt2
            template: Port
            element: role, "pv"
            element: flow, "supply"
            component:
                id: meter
                template: EnergyMeter
                element: type, "dc"
                element-map: voltage, @pv2_voltage
                element-map: current, @pv2_current
                element-map: power, @pv2_power
    component:
        id: battery
        template: Port
        element: role, "battery"
        element: flow, "bidirectional"
        component:
            id: store
            template: Battery
            element-map: soc, @bat_soc
            element-map: mode, @bat_mode
        component:
            id: meter
            template: EnergyMeter
            element: type, "dc"
            element-map: voltage, @bat_voltage
            element-map: current, @bat_current
            element-map: power, @bat_power
    component:
        id: inverter
        template: Inverter
        element-map: state, @inv_state
        element-map: temp, @inv_temp
        element-map: bus_voltage, @dc_bus_voltage
        component:
            id: export_meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: voltage, @grid_voltage
            element-map: current, @grid_current
            element-map: power, @grid_power
            element-map: frequency, @grid_frequency
```

Site wiring:

```
/apps/energy/appliance add name=goodwe device=goodwe_ems grid=house backup=house.backup solar.mppt1=pv.east solar.mppt2=pv.west battery=dc_bus
```

Here `house`, `house.backup`, `pv.east`, `pv.west`, and `dc_bus` are different
circuits. The inverter bridges them as a converter; they are not child
components of one another. A separate BMS can also bind `battery=dc_bus`, which
makes both devices describe the same DC reservoir from different perspectives.

The `inverter.export_meter` is not a port. It is a remote reference meter at
the property gateway, useful for autonomous inverter behaviour and export
limiting.

### EV Charger (EVSE)
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "evse"
        element: name, "SmartEVSE v3"
        element-map: serial_number, @serial
    component:
        id: grid
        template: Port
        element: role, "parent"
        element: flow, "consume"
        component:
            id: meter
            template: EnergyMeter
            element: type, "three-phase"
            element-map: voltage1, @voltage_l1
            element-map: voltage2, @voltage_l2
            element-map: voltage3, @voltage_l3
            element-map: current, @current_total
            element-map: power, @power_total
            element-map: import, @energy_total
        component:
            id: control
            template: PowerControl
            element: kind, "continuous"
            element: direction, "consume"
            element: unit, "A"
            element: min, 6
            element: step, 1
            element-map: max, @max_current
            element-map: setpoint, @set_current
    component:
        id: car
        template: Port
        element: role, "car"
        element: flow, "supply"
        element-map: circuit, @vin
        component:
            id: vehicle
            template: Vehicle
            element-map: vin, @vin
    component:
        id: evse
        template: EVSE
        element-map: temp, @temperature
        element-map: state, @pilot_state
        element-map: error, @error_code
        element-map: connected, @vehicle_connected
    component:
        id: config
        template: Configuration
        element-map: mode, @charge_mode
```

Site wiring:

```
/apps/energy/appliance add name=garage_evse device=garage_evse grid=garage.gpo
```

When an EVSE can report a VIN, the vehicle-side port can publish that VIN as
its live `circuit` value. When it cannot, bind `car=<static-car-circuit>` or
leave the vehicle side dark until another signal can identify the car.

### HVAC
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "hvac"
        element: name, "Split System"
    component:
        id: connection
        template: Port
        element: role, "connection"
        element: flow, "consume"
        component:
            id: meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: power, @power
        component:
            id: control
            template: PowerControl
            element: kind, "staged"
            element: direction, "consume"
            element-map: setpoint, @mode_setpoint
    component:
        id: hvac
        template: HVAC
        element-map: temperature, @room_temp
        element-map: target_temperature, @target_temp
        element-map: state, @state
        element-map: mode, @mode
```

Site wiring:

```
/apps/energy/appliance add name=lounge_ac device=lounge_ac connection=house.lounge
```

### Water Heater
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "water-heater"
        element: name, "Hot Water Tank"
    component:
        id: connection
        template: Port
        element: role, "connection"
        element: flow, "consume"
        component:
            id: meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: power, @element_power
        component:
            id: relay
            template: Switch
            element-map: switch, @relay
    component:
        id: tank
        template: WaterHeater
        element-map: temperature, @tank_temp
        element-map: target_temperature, @target_temp
        element-map: min_temperature, @min_temp
        element-map: super_temperature, @super_temp
        element-map: volume, @tank_volume
```

Site wiring:

```
/apps/energy/appliance add name=hot_water device=hot_water connection=house.laundry
```

### Smart GPO / Power Strip
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "smart-gpo"
        element: name, "3-Outlet Smart GPO"
    component:
        id: supply
        template: Port
        element: role, "parent"
        element: flow, "consume"
        component:
            id: meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: voltage, @supply_voltage
            element-map: power, @supply_power
    component:
        id: outlet1
        template: Port
        element: role, "child"
        element: flow, "supply"
        component:
            id: switch
            template: Switch
            element-map: switch, @1:onoff
        component:
            id: meter
            template: EnergyMeter
            element: type, "single-phase"
            element-map: power, @1:power
    component:
        id: outlet2
        template: Port
        element: role, "child"
        element: flow, "supply"
        component:
            id: switch
            template: Switch
            element-map: switch, @2:onoff
    component:
        id: outlet3
        template: Port
        element: role, "child"
        element: flow, "supply"
        component:
            id: switch
            template: Switch
            element-map: switch, @3:onoff
```

Site wiring:

```
/apps/energy/appliance add name=bench_gpo device=bench_gpo supply=garage.gpo outlet1=bench.left outlet2=bench.right outlet3=bench.spare
/apps/energy/appliance add name=toaster connection=bench.left kind=load
```

The GPO defines the outlet circuits. A user-visible appliance such as
`toaster` can then bind to one of those circuits and inherit/estimate energy
from the outlet meter.

---

## Notes

- **Required vs Optional**: Required elements must be present for the template to be valid. Optional elements can be omitted.
- **Element Types**: Type suffixes (`:` units) are shown for documentation - actual element names don't include units.
- **Variations**: Some templates support variations (single/three-phase, DC) specified by the `type` element.
- **Nested Components**: Templates can contain sub-components for logical grouping.
- **Custom Elements**: Devices may expose additional elements beyond those listed here.

## See Also

- [Profile File Format](PROFILE_FILE_FORMAT.md) - Profile syntax and native descriptors
- [Profile catalogue](../conf/profiles/README.md) - Catalogue policy and contribution guidance
