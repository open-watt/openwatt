# Component Template Reference

Quick reference for standard component templates and their expected elements.

## Template Summary

| Template | Purpose | Required Elements |
|----------|---------|-------------------|
| `DeviceInfo` | Device identification | `type`, `name` |
| `RealtimeEnergyMeter` | Real-time electrical measurements | `type` |
| `CumulativeEnergyMeter` | Accumulated energy totals | `type` |
| `DemandEnergyMeter` | Demand measurements | `type` |
| `Battery` | Battery (recursive) | `soc` |
| `BatteryConfig` | Battery specifications | - |
| `Solar` | Solar PV array (recursive) | - |
| `SolarConfig` | Solar PV specifications | - |
| `Inverter` | Solar/battery/hybrid inverter | - |
| `EVSE` | EV charger | `state` |
| `Vehicle` | Connected vehicle | - |
| `ChargeControl` | Charge controller | `target_current` |
| `HVAC` | Climate control system | - |
| `Switch` | On/off control | `switch` |
| `Shutter` | Window/door shutter control | `position` |
| `ContactSensor` | Contact/door sensor | `open` or `alarm` |
| `Network` | Network connectivity | - |
| `Configuration` | Device settings | varies |

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

### modbus: Modbus
- `status: enum/string` - Connection status

### ethernet: Ethernet
- `status: enum/string` - Connection status
- `ip_address: string` - IPv4 address
- `gateway: string` - Default gateway
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

## RealtimeEnergyMeter

Real-time electrical measurements.

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

---

## CumulativeEnergyMeter

Accumulated energy totals.

### Required
- `type: string` - "single-phase", "three-phase", or "dc"

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
- `import_reactive: kvarh` - Total import
- `import_reactive1-3: kvarh` - Per-phase import
- `export_reactive: kvarh` - Total export
- `export_reactive1-3: kvarh` - Per-phase export
- `net_reactive: kvarh` - Total (net)
- `net_reactive1-3: kvarh` - Per-phase total
- `absolute_reactive: kvarh` - Gross (absolute)
- `absolute_reactive1-3: kvarh` - Per-phase gross

### Apparent Energy
- `apparent: kVAh` - Total apparent
- `apparent1-3: kVAh` - Per-phase apparent

### DC
- `import: kWh` - Total import (or charge)
- `export: kWh` - Total export (or discharge)
- `net: kWh` - Total (net)
- `absolute: kWh` - Gross (absolute)

---

## DemandEnergyMeter

Demand measurements (averaged over demand period).

### Elements
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

## Battery

Battery (recursive - can represent whole system, individual pack, or sub-pack).

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
- `realtime: RealtimeEnergyMeter` (type: "dc") - DC measurements at this level
- `cumulative: CumulativeEnergyMeter` (type: "dc") - Energy totals at this level
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

### Optional
- `state: enum` - PV state: not_connected, no_power, producing
- `mode: enum` - Operating mode: mppt, constant_voltage, off, fault
- `temp: °C` - Panel/module temperature
- `efficiency: %` - MPPT/conversion efficiency

### Sub-components
- `panel1, panel2, ...panelN: Solar` - Individual panels/modules (for optimizer/microinverter systems)
- `string1, string2, ...stringN: Solar` - Individual strings (for multi-string systems)
- `realtime: RealtimeEnergyMeter` - PV measurements (type: "dc" for string/optimizer, "single-phase" for microinverter)
- `cumulative: CumulativeEnergyMeter` - Total PV energy production
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

### Optional
- `state: enum` - Inverter state: standby, grid_tied, off_grid, fault, etc.
- `mode: enum` - Operating mode: on_grid, off_grid, hybrid, eco, backup
- `temp: °C` - Inverter temperature
- `rated_power: W` - Rated output power
- `efficiency: %` - Current conversion efficiency
- `bus_voltage: V` - DC bus voltage

### Sub-components
- `solar: Solar` - Solar PV input(s)
- `battery: Battery` - Connected battery system
- `charge_control: ChargeControl` - Battery charge controller (for managing battery charging)
- `load: RealtimeEnergyMeter` / `load_cumulative: CumulativeEnergyMeter` - Inverter load
- `backup: RealtimeEnergyMeter` / `backup_cumulative: CumulativeEnergyMeter` - Backup/EPS output
- `export_meter: RealtimeEnergyMeter` / `meter_cumulative: CumulativeEnergyMeter` - External energy meter for self-consumption reference
- `evse: EVSE` - Integrated EV charger (for inverters with built-in EVSE)
- `config: Configuration` - Inverter configuration

---

## EVSE

Electric Vehicle Supply Equipment (EV charger).

### Optional
- `temp: °C` - EVSE temperature
- `session_energy: Wh` - Energy delivered in current charging session
- `lifetime_energy: Wh` - Energy delivered in the lifetime of the charger
- `state: enum` - J1772 pilot state: A (standby), B (vehicle detected), C (ready/charging), D (ventilation required), etc.
- `error: bitfield/enum` - Error flags
- `connected: boolean` - Vehicle connected

### Sub-components
- `charge_control: ChargeControl` - Charge control sub-component (for controllable chargers)
- `vehicle: Vehicle` - Connected vehicle information (if EVSE can communicate with vehicle)
- `realtime: RealtimeEnergyMeter` - Real-time charging measurements (type: "single-phase" or "three-phase")
- `cumulative: CumulativeEnergyMeter` - Total energy delivered
- `config: Configuration` - EVSE configuration (mode, limits, etc.)

---

## Vehicle

Vehicle information (typically EV connected to charger).

### Optional
- `vin: string` - Vehicle identification number
- `soc: %` - State of charge (0-100%)
- `range: km` - Remaining range
- `battery_capacity: kWh` - Battery capacity

---

## ChargeControl

Charge controller for managing charging current/power.

### Required
- `target_current: A` - Target/commanded current (writable)

### Optional
- `max_current: A` - Maximum charging current/limit
- `min_current: A` - Minimum charging current
- `actual_current: A` - Actual charging current
- `max_power: W` - Maximum charging power
- `target_power: W` - Target/commanded power (writable)
- `actual_power: W` - Actual charging power

---

## HVAC

Heating, ventilation, and air conditioning systems.

### Required

### Optional
- `temperature: °C/°F` - Current ambient temperature
- `state: enum` - Current active state - off, heating, cooling, etc
- `target_temperature: °C/°F` - Target/commanded temperature (writable)
- `humidity: %` - Current relative humidity
- `target_humidity: %` - Target/commanded humidity (writable)
- `mode: enum` - Operating mode (off, heat, cool, auto, fan_only, dry)
- `fan_speed: enum/%` - Fan speed (low, medium, high, auto, or 0-100%)

---

## Switch

On/off control devices.

### Required
- `switch: boolean/enum` - Switch state (on/off, 0/1)

### Optional
- `type: enum` - Switch type - light, power, outlet (power outlet), fan, etc
- `mode: enum` - Switch mode
- `timer: s` - Timer value

### Sub-components
- `meter: RealtimeEnergyMeter` / `meter_cumulative: CumulativeEnergyMeter` - Switched circuit energy meter

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
        id: realtime
        template: RealtimeEnergyMeter
        element: type, "single-phase"
        element-map: voltage, @voltage
        element-map: current, @current
        element-map: power, @activePower
        element-map: apparent, @apparentPower
        element-map: reactive, @reactivePower
        element-map: pf, @powerFactor
        element-map: frequency, @frequency
    component:
        id: cumulative
        template: CumulativeEnergyMeter
        element: type, "single-phase"
        element-map: import, @importActiveEnergy
        element-map: export, @exportActiveEnergy
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
        template: Battery
        element-map: soc, @soc
        element-map: soh, @soh
        element-map: mode, @battery_mode
        element-map: temp, @temp_avg
        element-map: remain_capacity, @capacity_ah
        element-map: cycle_count, @cycles
        component:
            id: realtime
            template: RealtimeEnergyMeter
            element: type, "dc"
            element-map: voltage, @voltage
            element-map: current, @current
            element-map: power, @power
        component:
            id: cumulative
            template: CumulativeEnergyMeter
            element: type, "dc"
            element-map: import, @total_charge
            element-map: export, @total_discharge
```

### Hybrid Solar Inverter
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "inverter"
        element: name, "Hybrid Inverter"
    component:
        id: inverter
        template: Inverter
        element-map: state, @inv_state
        element-map: temp, @inv_temp
        element-map: bus_voltage, @dc_bus_voltage
        component:
            id: pv
            template: Solar
            element-map: state, @pv_state
            component:
                id: realtime
                template: RealtimeEnergyMeter
                element: type, "dc"
                element-map: voltage, @pv_voltage
                element-map: current, @pv_current
                element-map: power, @pv_power
        component:
            id: battery
            template: Battery
            element-map: soc, @bat_soc
            element-map: mode, @bat_mode
            component:
                id: realtime
                template: RealtimeEnergyMeter
                element: type, "dc"
                element-map: voltage, @bat_voltage
                element-map: current, @bat_current
                element-map: power, @bat_power
        component:
            id: grid
            template: RealtimeEnergyMeter
            element: type, "single-phase"
            element-map: voltage, @grid_voltage
            element-map: current, @grid_current
            element-map: power, @grid_power
            element-map: frequency, @grid_frequency
        component:
            id: load
            template: RealtimeEnergyMeter
            element: type, "single-phase"
            element-map: voltage, @load_voltage
            element-map: current, @load_current
            element-map: power, @load_power
```

### EV Charger (EVSE)
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "evse"
        element: name, "SmartEVSE v3"
        element-map: serial_number, @serial
        element-map: temp, @temperature
    component:
        id: evse
        template: EVSE
        element-map: state, @pilot_state
        element-map: error, @error_code
        element-map: connected, @vehicle_connected
        component:
            id: charge_control
            template: ChargeControl
            element-map: max_current, @max_current
            element-map: target_current, @set_current
        component:
            id: realtime
            template: RealtimeEnergyMeter
            element: type, "three-phase"
            element-map: voltage1, @voltage_l1
            element-map: voltage2, @voltage_l2
            element-map: voltage3, @voltage_l3
            element-map: current, @current_total
            element-map: power, @power_total
        component:
            id: cumulative
            template: CumulativeEnergyMeter
            element: type, "three-phase"
            element-map: import, @energy_total
        component:
            id: config
            template: Configuration
            element-map: mode, @charge_mode
```

### Smart Switch (Multi-Gang)
```
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "light-switch"
        element: name, "3-Gang Switch"
    component:
        id: gang1
        template: Switch
        element-map: switch, @1:onoff
    component:
        id: gang2
        template: Switch
        element-map: switch, @2:onoff
    component:
        id: gang3
        template: Switch
        element-map: switch, @3:onoff
```

---

## Notes

- **Required vs Optional**: Required elements must be present for the template to be valid. Optional elements can be omitted.
- **Element Types**: Type suffixes (`:` units) are shown for documentation - actual element names don't include units.
- **Variations**: Some templates support variations (single/three-phase, DC) specified by the `type` element.
- **Nested Components**: Templates can contain sub-components for logical grouping.
- **Custom Elements**: Devices may expose additional elements beyond those listed here.

## See Also

- [Profile File Format](PROFILE_FILE_FORMAT.md) - Profile file syntax and structure
