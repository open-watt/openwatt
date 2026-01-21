# Device Profile File Format

## Overview

Device profiles define how to read data from hardware devices and map it to standardized component templates. Each profile file contains:

1. **Enumerations** - Named value mappings for enum and bitfield types
2. **Data Source Definitions** - Protocol-specific element definitions
3. **Device Templates** - Component structures that map source data to standardized elements

## Protocol Types

### Modbus (RTU/TCP)

**File Location**: `conf/modbus_profiles/*.conf`

**Source Section**: `registers:`

**Element Syntax**:
```
reg: address, type[/access], units, desc: id, display_units, sample_frequency, "description"
    [valueid: name1, name2, ...]      # For enums/bitfields
    [valuedesc: "Display 1", "Display 2", ...]
```

**Examples**:
```conf
reg: 30000, f32, V,         desc: voltage, V, realtime, "Voltage"
reg: 40020, f32/RW,         desc: address, , config, "Modbus address"
reg: 41000, f32le/RW, kWh,  desc: EnergySum, kWh, medium, "Total net energy"
```

### REST/HTTP

**File Location**: `conf/rest_profiles/*.conf`

**Source Sections**:
```
requests:
    req: id, method, path, format
```

**Element Syntax** (in device template):
```
element-sampler: name, scale, json_path[, write_path]
```

**Examples**:
```conf
requests:
    req: settings, GET, "/settings", json
    req: settings_set, POST, "/settings", query

device-template:
    component:
        id: info
        template: DeviceInfo
        element-sampler: serialNumber, , settings@serialnr
        element-sampler: batteryCurrent, -100mA, settings@home_battery.current, currents_set@battery_current
```

### GoodWe AA55 Protocol

**File Location**: `conf/goodwe_profiles/*.conf`

**Source Section**: `elements:`

**Element Syntax**:
```
aa55: function, offset, type, units, desc: id, display_units, sample_frequency, "description"
```

**Examples**:
```conf
aa55: 1,  0, u16be, 0.1V,  desc: info_v_pv1, V, realtime, "PV1 voltage"
aa55: 6, 26, u8, %,        desc: data_soc, , high, "State of Charge"
```

### Zigbee

**File Location**: `conf/zigbee_profiles/*.conf`

**Source Section**: `elements:`

**Element Syntax**:
```
zb: cluster, attribute, type[/access], [units,] desc: id, display_units, sample_frequency, "description"
```

**Examples**:
```conf
zb: 0, 0x0004, str/R,       desc: mfg_name, , const, "Manufacturer"
zb: 6, 0x0000, u8/R,        desc: onoff, , report, "On/Off"
zb: 1, 0x0021, u8/R, 0.5%,  desc: batt_percentage_remaining, %, low, "Battery Remaining"
```

**Note**: Zigbee elements in device templates use endpoint prefix:
```
element-map: switch, @1:onoff      # Endpoint 1, attribute onoff
element-map: manufacturer, @1:mfg_name
```

## Data Types

### Numeric Types
- **Unsigned integers**: `u8`, `u16`, `u32`, `u64`
- **Signed integers**: `i8`, `i16`, `i32`, `i64`
- **Floating point**: `f32`, `f64` (IEEE 754)
- **Enumerations**: `enum8`, `enum16`, `enumf32`
- **Bit fields**: `bf16`, `bf32`
- **Strings**: `str`, `str5`, `str10`, `str16`
- **Date/Time**: `dt48` (6-byte datetime)

### Endianness Modifiers
- `be` - Big-endian (e.g., `u16be`, `f32be`)
- `le` - Little-endian (e.g., `u32le`, `f32le`)
- Default - Host byte order or protocol default

### Access Modifiers
- `/R` - Read-only
- `/W` - Write-only
- `/RW` - Read/write
- Default - Read-only

## Units and Scaling

Units specify how raw values should be interpreted:

- **Simple units**: `V`, `A`, `W`, `Hz`, `°C`, `%`
- **Scaled units**: `0.1V`, `10mA`, `0.01Hz`

### Common Units
- **Voltage**: `V`, `mV`, `0.1V`, `10mV`, `100mV`
- **Current**: `A`, `mA`, `0.1A`, `10mA`
- **Power**: `W`, `kW`, `VA`, `var`, `kvarh`, `kWh`
- **Frequency**: `Hz`, `0.01Hz`
- **Temperature**: `°C`, `0.1°C`, `°K`
- **Time**: `s`, `min`, `hrs`, `ms`, `us`, `0.1s`, `0.02s`, `25us`
- **Percentage**: `%`, `0.1%`, `0.01%`
- **Energy**: `kWh`, `Wh`, `0.1kWh`, `10Wh`, `kvarh`, `kVAh`
- **Capacity**: `Ah`, `mAh`, `10mAh`
- **Angle**: `deg`, `0.01deg`, `0.001deg`

## Sample Frequencies

Indicates how often elements should be sampled:

- **`realtime`** - Sub-second to seconds (high-speed measurements)
- **`high`** - Seconds to minutes (frequently changing values)
- **`medium`** - Minutes to tens of minutes (slowly changing values)
- **`low`** - Hours (rarely changing values)
- **`report`** - Event-driven or on-change
- **`ondemand`** - Only when explicitly requested
- **`config`** - Configuration parameters
- **`const`** - Constants/identification data (read once)

## Enumerations

Define before data source definitions:

```
enum: EnumName
    symbolic_name1: numeric_value, "Display String 1"
    symbolic_name2: numeric_value, "Display String 2"
```

**Example**:
```conf
enum: WorkMode
    wait: 0, "Wait"
    normal: 1, "Normal"
    error: 2, "Error"
    check: 3, "Check"

registers:
    reg: 40028, enum16, desc: workMode, , high, "Work Mode"
```

## Value Descriptors

For enum and bitfield elements, specify value mappings inline:

```
reg: address, enum16, desc: element_id, , frequency, "Description"
    valueid: name1, name2, name3
    valuedesc: "Display 1", "Display 2", "Display 3"
```

**Enum Example**:
```conf
reg: 40003, enum16/RW, desc: modeNoSave, , high, "EVSE mode"
    valueid: normal, smart, solar
    valuedesc: "Normal", "Smart", "Solar"
```

**Bitfield Example**:
```conf
reg: 40001, bf16/RW, desc: error, , high, "Error flags"
    valueid: LESS_6A, NO_COMM, TEMP_HIGH, , RCD, NO_SUN
    valuedesc: "Less than 6A", "No Communication", "Temperature High", , "RCD", "No Sun"
```
*Empty positions represent unused bits*

## Device Template Structure

### Basic Syntax

```
device-template:
    [model: model_identifier]  # Optional: for model-specific templates
    component:
        id: component_id
        template: TemplateName
        [element: name, value]                    # Static element
        [element-map: element_name, @source_id]   # Map from source
        [element-sampler: name, scale, path]      # REST/JSON mapping
        [component: ...]                          # Nested sub-component
```

### Element Mapping Types

**1. Static Elements** - Fixed values:
```
element: type, "energy-meter"
element: brand_name, "Moes"
```

**2. Source Mapping** - Reference source elements:
```
element-map: voltage, @VoltAvgLN
element-map: serialNumber, @SerialNumber
element-map: temp, @data_c_inverter_temp
```

**3. Zigbee Endpoint Mapping**:
```
element-map: switch, @1:onoff           # Endpoint 1
element-map: manufacturer, @1:mfg_name
element-map: switch2, @2:onoff          # Endpoint 2
```

**4. Sampler Mapping** (REST/JSON):
```
element-sampler: name, scale, read_path[, write_path]
```
- `name` - Element name
- `scale` - Optional scaling (e.g., `100mA`, `-100mA`)
- `read_path` - JSON path (e.g., `settings@serialnr`, `settings.mode`)
- `write_path` - Optional write endpoint (e.g., `settings_set@mode`)

Examples:
```
element-sampler: serialNumber, , settings@serialnr
element-sampler: batteryCurrent, -100mA, settings@home_battery.current, currents_set@battery_current
element-sampler: mode, "", settings.mode
```

### Component Hierarchy

Nest components for logical grouping:

```
component:
    id: grid
    component:
        id: realtime
        template: RealtimeEnergyMeter
        element: type, "single-phase"
        element-map: voltage, @gridVoltage
    component:
        id: cumulative
        template: CumulativeEnergyMeter
        element: type, "single-phase"
        element-map: totalImportActiveEnergy, @importEnergy
```

### Model-Specific Templates

Define multiple templates for different device models:

```
device-template:
    model: "_TZ3000_qewo8dlz:TS0013:1.80"
    component:
        id: info
        template: DeviceInfo
        element: name, "3-Gang Switch"
        ...

device-template:
    model: "_TZ3000_6zvw8ham:TS0203:1.70"
    component:
        id: info
        template: DeviceInfo
        element: name, "Door Sensor"
        ...
```

## Complete Example

```conf
# Eastron SDM120 Single-Phase Energy Meter
# http://support.innon.com/PowerMeters/SDM120-MOD-MID/Manual/SDM120_PROTOCOL.pdf

enum: BaudRate
    _2400: 0, "2400"
    _4800: 1, "4800"
    _9600: 2, "9600"
    _19200: 3, "19200"
    _38400: 4, "38400"

registers:
    # Measurements
    reg: 30000, f32, V,     desc: voltage, V, realtime, "Voltage"
    reg: 30006, f32, A,     desc: current, A, realtime, "Current"
    reg: 30012, f32, W,     desc: activePower, W, realtime, "Active power"
    reg: 30072, f32, kWh,   desc: importActiveEnergy, kWh, high, "Import active energy"

    # Configuration
    reg: 40020, f32/RW,     desc: address, , config, "Modbus address"
    reg: 40028, enumf32/RW, desc: baudRate, , config, "Baud rate"

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
    component:
        id: cumulative
        template: CumulativeEnergyMeter
        element: type, "single-phase"
        element-map: totalImportActiveEnergy, @importActiveEnergy
    component:
        id: config
        template: Configuration
        element-map: modbusAddress, @address
        element-map: networkBaudRate, @baudRate
```

## Validation Rules

1. **Profile Structure**:
   - Must define one of: `registers:`, `elements:`, or `requests:`
   - All source element IDs must be unique
   - Enums must be defined before use

2. **Device Templates**:
   - Must include at least one component
   - Component IDs must be unique within template
   - All `element-map` references must exist in source definitions
   - Template names must match standard templates (see COMPONENT_TEMPLATES.md)

3. **Element Definitions**:
   - Sample frequencies must use standard keywords
   - Units must follow recognized patterns
   - Data types must be valid

## Best Practices

### Naming Conventions
- **Component IDs**: `snake_case` (e.g., `realtime`, `grid_meter`)
- **Element IDs**: `camelCase` (e.g., `voltage`, `activePower`)
- **Template names**: `PascalCase` (e.g., `DeviceInfo`, `RealtimeEnergyMeter`)

### Organization
- Define enums at top of file
- Group related source elements together
- Add comments with protocol documentation links
- Use `info` component for device metadata
- Separate measurements from configuration

### Documentation
- Include device model numbers in comments
- Reference protocol documentation URLs
- Document special behaviors or limitations
- Note any device-specific quirks

### Reusability
- Use standard templates whenever possible
- Define reusable enums for common values
- Consider variants (single/three-phase) in template design
- Support multiple models in one profile where appropriate

## See Also

- [Component Templates Reference](COMPONENT_TEMPLATES.md) - Standard template specifications
