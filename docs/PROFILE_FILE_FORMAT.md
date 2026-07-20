# Device Profile File Format

## Overview

Profiles describe protocol fields, their native types, and the component tree exposed as
an OpenWatt `Device`. The canonical catalogue is the `conf/profiles` Git submodule.
OpenWatt searches that tree recursively and resolves profiles by `.conf` basename.
Directories are organisational, so basenames must be globally unique.

The default search root is `conf/profiles`. It can be changed before profiles are loaded:

```text
/system/profile-path path=/path/to/profiles
openwatt --profile-path /path/to/profiles
```

A profile normally contains some combination of:

1. `parameters:` used by protocol strings;
2. named `enum:` or `bitfield:` declarations;
3. protocol root sections such as `requests:` or `mqtt-subscribe:`;
4. `elements:` or `registers:` containing protocol source descriptors;
5. one or more `device-template:` blocks that mount sources into components.

Indentation creates parent/child structure. Values are comma-separated unless quoted.
Comments start with `#`.

## Parameters

Declare names accepted as binding properties:

```conf
parameters: device_id, api_key
```

Protocol strings can reference them with `{name}`:

```conf
mqtt: {device_id}/voltage/get, f64:V        desc: voltage
```

A declaration is not globally required. An unset parameter produces a warning only when
an active binding expands a topic, subscription, request path, template, or expression
that uses it. Supplying a parameter not declared by the profile is an error.

## Enumerations and Bitfields

Enums map stable keys to wire values and optional display names:

```conf
enum: ChargeMode
    off: 0, "Off"
    normal: 1, "Normal"
    solar: 2, "Solar"
```

Use the declaration from a type spec with `enum<width>:Name`:

```conf
mqtt: {device_id}/Mode, enum8:ChargeMode    desc: mode
```

Bitfields use mask values. A shifted value is accepted where it makes the intent clearer:

```conf
bitfield: ErrorFlags
    communication: 1 << 0, "Communication failure"
    over_temperature: 1 << 2, "Over temperature"

registers:
    reg: 40001, bf16:ErrorFlags              desc: errors
```

Profiles register enum names as `profile_basename.EnumName`; references inside the same
profile may use the short name.

## Native Type Specifications

Every protocol section compiles the same value-spec grammar into a `SampleDesc`:

```text
<family><width>[_mods][@bit][:name][[N]]
```

Common families are:

- `bool`
- unsigned integers: `u8`, `u16`, `u32`, `u64`
- signed integers: `s8`, `s16`, `s32`, `s64`
- floating point: `f32`, `f64`
- enums and bitfields: `enum8:Name`, `enum16:Name`, `bf8:Name`, `bf16:Name`
- floating wire enums: `enumf32:Name`, `enumf64:Name`
- text: `str` for protocol-framed text, or `strN` for a fixed-width binary field
- date/time: `dt`, fixed-width `dtN`, or a named encoding such as
  `dt48:yymmddhhmmss`
- registered native types such as `mac`, `ipv4`, and `ipv6`
- fixed vectors with `[N]`, for example `u16[3]`
- bit selection with `@bit`, when supported by the protocol context

Scaling and units follow `:` for numeric families:

```conf
u16:100mA
f32:V
s16:0.01°C
```

The protocol supplies the normal byte and word order. State layout modifiers only when
the device differs from that context:

- `_bs`: swap bytes within each protocol word;
- `_wr`: swap word order;
- `_le` / `_be`: absolute scalar endianness in a byte-stream context;
- `_sp`: space-padded fixed text;
- `_be` on a registered aggregate: members are stored big-endian.

Legacy `i*`, glued `le`/`be`, and `_r` spellings remain parser aliases during the
catalogue migration, but new profiles should use the normalized forms above.

Access is a separate column after the type:

```conf
reg: 40020, u16, RW                       desc: address
mqtt: device/state, bool, R               desc: state
```

`R`, `W`, and `RW` are accepted. Omitted access means read unless a protocol section
derives read/write access from an explicit write mapping.

The definitive grammar and protocol layout rules live in
[`src/manager/sample/spec.d`](../src/manager/sample/spec.d).

## Source Sections

Protocol modules register their own element section names and own their descriptor
storage. The common parser does not need a new `ElementType` for each protocol.

Current registered sections include:

| Section | Protocol | Addressing before the type |
|---|---|---|
| `reg` / `mb` | Modbus | register address or mapped register |
| `can` | CAN | message identifier and byte offset |
| `aa55` | GoodWe | function and response offset |
| `ble` | BLE | service UUID and characteristic UUID/offset |
| `zb` | Zigbee | cluster, attribute, and optional manufacturer data |
| `mqtt` | MQTT | read topic; optional nested `write:` topic |
| `http` | HTTP | request name and response identifier |

See a nearby catalogue profile for the protocol-specific address fields. The type,
access, and `desc:` metadata are shared.

### MQTT

`mqtt-subscribe:` is a comma-separated root section. It can contain parameters:

```conf
parameters: device_id
mqtt-subscribe: "#"

elements:
    mqtt: {device_id}/state/get, bool, RW       desc: state
        write: {device_id}/state/set
```

Topics are expanded by an MQTT binding. Profiles containing MQTT and another protocol
are valid; each binding ignores descriptor kinds it does not own.

### HTTP

HTTP request definitions are named and then referenced by `http:` elements:

```conf
requests:
    request: status, GET, "/settings"
        root: data
        success: result == "OK"
    request: set_mode, POST, "/settings?{key}={value}"

elements:
    http: status, mode, enum8:ChargeMode        desc: mode
        write: set_mode, mode
```

Supported request directives include `format: json`, `format: form`, `parse: json`,
`parse: regex`, `parse: none`, `root:`, and `success:`. `{key}` / `{value}` create a
per-element request; `{keys}` / `{values}` create a batch request. Singular and plural
placeholders cannot be mixed in one request.

## Element Metadata

Each source definition names itself with `desc:`:

```conf
reg: 30000, f32:V    desc: voltage, V, realtime, "Line voltage"
```

The fields are:

```text
desc: source_id [, display_units] [, frequency] [, display_name] [, description]
```

Frequencies are:

- `realtime`: approximately 400 ms;
- `high`: approximately 1 second;
- `medium`: approximately 10 seconds;
- `low`: approximately 60 seconds;
- `const`: sample once;
- `config`: configuration value;
- `report`: event-driven;
- `ondemand`: never polled automatically.

The source ID is referenced from a device template as `@source_id`.

## Device Templates

A device template creates components and mounts source descriptors into standard element
names:

```conf
device-template:
    component:
        id: info
        template: DeviceInfo
        element: type, "energy-meter"
        element: name, "Example Meter"
    component:
        id: meter
        template: EnergyMeter
        element: type, "single-phase"
        element-map: voltage, @voltage
        element-map: current, @current
        element-map: power, @active_power
```

Supported entries are:

- `element:`: a static value or expression;
- `element-map:`: mount a protocol source;
- `element-alias:`: link to another element path;
- `element-sum:`: accumulate a source with a selected integration mode;
- nested `component:` blocks;
- `template:`: apply a standard component shape;
- `model:` at device-template level: select a template by model wildcard.

An `element-map` may add its own `desc:` metadata to override presentation or frequency.

## Complete Minimal Example

```conf
enum: RelayState
    off: 0, "Off"
    on: 1, "On"

registers:
    reg: 30000, f32:V                 desc: voltage
    reg: 30006, f32:A                 desc: current
    reg: 40010, enum16:RelayState, RW desc: relay

device-template:
    component:
        id: meter
        template: EnergyMeter
        element: type, "single-phase"
        element-map: voltage, @voltage
        element-map: current, @current
    component:
        id: control
        template: Switch
        element-map: switch, @relay
```

## Further References

- [Profile catalogue README](../conf/profiles/README.md)
- [Profile contribution guide](../conf/profiles/CONTRIBUTING.md)
- [Native descriptor compiler](../src/manager/sample/spec.d)
- [Component templates](COMPONENT_TEMPLATES.md)
