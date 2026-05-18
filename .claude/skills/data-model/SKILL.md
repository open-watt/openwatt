---
name: data-model
description: Device/Component/Element data model, profile system, and protocol bindings. Use when working on devices, elements, profiles, bindings, or adding a new protocol integration.
---

# Data Model & Protocol Bindings

You are working on OpenWatt's runtime data model. This skill covers the full chain: how profile configuration files define device structure, how Device/Component/Element hierarchies are built at runtime, and how protocol-specific bindings populate elements with live data.

## Part 1: Device / Component / Element Hierarchy

### Overview

OpenWatt represents all equipment and sensor data in a three-level hierarchy:

```
Device (e.g., "inverter")          <- extends Component
  +- Component (e.g., "info")      <- logical grouping
  |    +- Element ("type" = "solar-inverter")
  |    +- Element ("serial_number" = "SN12345")
  +- Component (e.g., "meter")
  |    +- Element ("voltage" = 230.5 V)
  |    +- Element ("current" = 15.2 A)
  |    +- Element ("power" = 3502.6 W)   <- expression: voltage * current
  |    +- Element ("import" = 42.1 kWh)  <- sum: trapezoid integral of power
  +- Component (e.g., "battery")
       +- Element ("soc" = 85 %)
       +- Component (nested)
            +- Element (...)
```

Devices live in `g_app.devices` (Map keyed by name) and are populated by **bindings** — top-level `ActiveObject`s in `Collection!ProtocolBinding` that look up or create a Device by name and materialise its component tree from a profile.

### Component

```d
// src/manager/component.d
extern(C++) class Component {
    String id;
    String name;
    String template_;              // e.g. "EnergyMeter", "Battery", "DeviceInfo"
    Component parent;
    Array!Component components;    // child components
    Array!(Element*) elements;     // direct elements
}
```

**Key methods:**
- `find_component("battery.meter")` -- dot-separated hierarchical lookup
- `find_element("voltage")` -- recursive element search
- `find_or_create_element("path")` -- creates missing components/element
- `full_path(buf)` -- builds path string like `"inverter.meter.voltage"`

### Device

```d
// src/manager/device.d
class Device : Component {
    Profile* profile;
    Array!Computation computations;   // expression / accumulator / alias bindings
    Array!(Element*) sample_elements; // elements that need force-updates (sum/integration)
}
```

Devices are pure data — they do **not** own bindings. The binding registry (`Collection!ProtocolBinding`) is the owner; each binding holds a String `device` name and resolves it through `g_app.devices`.

**Runtime lifecycle:** `device.update()` runs each frame and force-updates accumulator sources (Riemann integrals) that need fresh samples. The binding's own `update()` is driven independently by the binding collection.

### Element

```d
// src/manager/element.d
struct Element {
    Variant latest;              // current value (any type via Variant)
    Variant prev;                // previous value
    SysTime last_update;         // timestamp of current value
    SysTime prev_update;         // timestamp of previous value
    String id, name, desc;
    String display_unit;
    Access access;               // none/read/write/read_write
    SamplingMode sampling_mode;  // poll/report/constant/on_demand/config/manual/dependent
    Component parent;            // owning component
    Array!Subscriber subscribers;
    Array!OnChangeCallback subscribers_2;
}
```

**Value update:**
```d
element.value(newVal, timestamp, who);
// if newVal != latest:
//   prev = latest, latest = newVal
//   signal() -> notify all Subscribers except `who`
```

**Subscriber interface:**
```d
interface Subscriber {
    void on_change(Element* e, ref const Variant val, SysTime timestamp, Subscriber who);
}
```

Bindings that support write-back (HTTP, MQTT) implement `Subscriber` so they can react to element changes and push the new value out over their protocol.

### Element Types in Device Template

| Syntax | Type | Description |
|--------|------|-------------|
| `element: prop, "literal"` | Static | Constant string/value, never sampled |
| `element-map: prop, @reg_id` | Mapped | Bound to a protocol register/element, sampled |
| `element-alias: prop, @path` | Alias | References another element (no duplication) |
| `element: prop, @a * @b` | Expression | Computed from other elements, auto-updates |
| `element-sum: prop, trapezoid, @source` | Sum | Time-integrated (Riemann sum of source element) |

### Enums

```d
enum Access : ubyte { none=0, read=1, write=2, read_write=3 }

enum SamplingMode : ubyte {
    manual, constant, dependent, poll, report, on_demand, config
}

enum Frequency : ubyte {
    realtime=0, high, medium, low, constant, on_demand, report, configuration
}

enum ElementType : ubyte { modbus, can, zigbee, http, aa55, mqtt }

enum SumType : ubyte { sum, right, trapezoid, positive_trapezoid, negative_trapezoid }
```

**Frequency -> SamplingMode** (`freq_to_element_mode()`):
- realtime/high/medium/low -> `poll`
- constant -> `constant`, on_demand -> `on_demand`, report -> `report`, configuration -> `config`

---

## Part 2: Profile System

Profiles are text configuration files that define both the protocol-specific data points (registers, topics, attributes) and the device template (component/element hierarchy). They live in `conf/<protocol>_profiles/`.

### Profile File Structure

```
[1. Enum definitions]
[2. Register/element definitions]
[3. HTTP request definitions -- HTTP only]
[4. Device template]
[5. Parameters and MQTT subscriptions]
```

### 2.1 Enum Definitions

```
enum: EnumName
    value_name: numeric_value, "Display String"
    flag_name: 1 << bit, "Display String"    # for bitfields
```

### 2.2 Register/Element Definitions

Each protocol has its own syntax. The section header `elements:` (Zigbee, MQTT, HTTP) (`registers:` is valid but deprecated).

**Modbus:**
```
reg: address, type[/access] [, units|enum],  desc: id [, display_units, frequency, "description"]
```
```
reg: 30000, f32, V,           desc: voltage
reg: 40018, enumf32/RW, BaudRate,  desc: baudRate
reg: 40001, bf16/RW, ErrorFlags,   desc: error
```

**CAN:**
```
can: message_id, byte_offset, type [, units|enum],  desc: id [, ...]
```
```
can: 0x351, 0, u16, 0.1V     desc: chargeVoltage
can: 0x356, 2, i16, 0.1A     desc: systemTotalCurrent
can: 0x359, 0, bf16, Protection  desc: protection
```

**Zigbee:**
```
zb: cluster, attribute, type[/access] [, scale|enum],  desc: id [, display_units, frequency, "description"]
```
```
zb: 0, 0x0005, str/R         desc: model_id, , const, "Model"
zb: 6, 0x0000, u8/RW         desc: onoff, , report, "On/Off"
zb: 1, 0x0021, u8/R, 0.5%    desc: batt_percentage_remaining, %, low, "Battery Remaining"
zb: 0xEF00, 24, bool8/RW     desc: state_l1, , report, "L1 State"  # Tuya datapoint
```

**MQTT:**
```
mqtt: topic_path, type [, units],  desc: id [, display_units, frequency, "description"]
    [write: write_topic, type]
```
```
parameters: device_id
mqtt-subscribe: "#"

mqtt: {device_id}/voltage/get, num, V    desc: voltage
mqtt: {device_id}/1/onoff, bool          desc: 1_onoff
    write: {device_id}/1/onoff/set, bool
```

**HTTP** (see also detailed HTTP section below):
```
http: request_name, identifier, type [, enum_name] [, unit],  desc: id [, display_units, frequency]
    [write: write_request [, write_key]]
    [response: alt_response_path]
```
```
requests:
    request: status, GET, "/settings"
    request: set_mode, POST, "/settings?{key}={value}"
        success: $result == "OK"

http: status, evse.state_id, enum, EvseState,   desc: state, , high
    write: set_mode, mode
http: status, ev_meter.import_active_power, num, W,  desc: ev_power, W, realtime
```

**Profile parameters** (shared by HTTP and MQTT):
```
parameters: param1, param2
```
Defines named placeholders (`{param1}`, `{param2}`) that are substituted into URL paths, request bodies, topic strings, etc. at device materialisation. Values come from named arguments set on the binding (e.g. `host=192.168.1.5 device_id=plug42` on the `add` command). `mqtt-variables:` is an alias for `parameters:`.

### 2.3 Data Types

| Type | Size | Description |
|------|------|-------------|
| `u8`/`i8` | 1 byte | unsigned/signed 8-bit |
| `u16`/`i16` | 2 bytes | unsigned/signed 16-bit |
| `u32`/`i32` | 4 bytes | unsigned/signed 32-bit |
| `u64`/`i64` | 8 bytes | unsigned/signed 64-bit |
| `f32`/`f64` | 4/8 bytes | IEEE float |
| `bf8`/`bf16` | 1/2 bytes | bitfield (used with enum) |
| `enum8`/`enum16`/`enumf32` | varies | enumeration |
| `str`/`str8` | varies | string |
| `bool`/`bool8` | 1 byte | boolean |
| `num` | (text) | text numeric parsing (MQTT/HTTP) |
| `dt` | (text) | datetime text |
| `ipaddr`/`ip6addr`/`inetaddr` | (text) | address types |

**Access:** `/R` (default), `/RW`, `/W`

**Units:** Direct SI (`V`, `A`, `W`, `Wh`, `kWh`, `Hz`, `deg-C`, `%`, `dBm`) with optional scaling (`0.1V`, `100mA`, `0.01Hz`).

**Frequency codes:** `realtime` (as fast as possible), `high` (1s), `medium` (10s, default), `low` (60s), `const` (once), `config`, `report` (event-driven), `on_demand`.

### 2.4 Device Template

```
device-template:
    [model: "fingerprint"]              # optional model matching
    component:
        id: component_id
        template: TemplateType          # see docs/COMPONENT_TEMPLATES.md for valid templates
        element: prop, "literal"        # static value
        element-map: prop, @reg_id      # maps to defined register
        element-map: prop, @reg_id,  desc: units, frequency, "Name", "Description"
        element-alias: prop, @path      # reference another element
        element: prop, @a * @b          # expression
        element-sum: prop, positive_trapezoid, @source  # integration
        component:                      # nesting
            id: sub
            ...
```

**Model variants:** Multiple `model:` lines or `component: [*pattern*]` for model-specific components.

**Element references:**
- `@element_id` -- direct reference to a defined register by its `desc: id`
- `@component.element` -- hierarchical path within device template
- `@endpoint$element` -- Zigbee endpoint + element (e.g., `@1$onoff`)

### 2.5 Profile Descriptor Structs

```d
// src/manager/profile.d
struct ElementDesc {
    CacheString display_units;
    Access access;
    Frequency update_frequency;
    ElementType type();      // bits 13-15 of _element_index
    size_t element();        // bits 0-12 -- index into protocol-specific array
}

struct ElementDesc_Modbus  { ushort reg; RegisterType reg_type; ValueDesc value_desc; }
struct ElementDesc_CAN     { uint message_id; ubyte offset; ValueDesc value_desc; }
struct ElementDesc_Zigbee  { ushort cluster_id; ushort attribute_id; ushort manufacturer_code; ValueDesc value_desc; }
struct ElementDesc_MQTT    { ushort read_topic; ushort write_topic; TextValueDesc value_desc; }
struct ElementDesc_HTTP    { ushort request_index; ushort write_request_index; bool identifier_quoted; TextValueDesc value_desc; }
struct ElementDesc_AA55    { ubyte function_code; ubyte offset; ValueDesc value_desc; }
```

### 2.6 Profile Locations

```
conf/modbus_profiles/     # Eastron meters, SolarEdge, SmartEVSE, Pace BMS, GoodWe, etc.
conf/can_profiles/        # Pylon BMS
conf/zigbee_profiles/     # Generic Zigbee (multi-model with fingerprints)
conf/mqtt_profiles/       # OpenBeken smart plugs
conf/rest_profiles/       # SmartEVSE REST API
conf/goodwe_profiles/     # GoodWe AA55 protocol
conf/ha_profiles/         # ESPHome/Home Assistant
```

---

## Part 3: Device Creation Flow

Devices are created on demand by **bindings**. A binding is a top-level Collection-managed object configured at runtime, e.g.:

```
/binding/modbus/add name=inv1 node=n1 device=inverter profile=goodwe_es model=GW10K-ES
```

This creates a `ModbusBinding`, sets `device="inverter"` (auto-creating the Device in `g_app.devices` if it doesn't exist), and triggers `restart()` which moves the binding through the state machine into `startup()`.

The binding's lifecycle does the work:

```d
// src/manager/binding.d (abridged)
abstract class ProfileBinding : ProtocolBinding {
nothrow @nogc:
    abstract const(char)[] profile_dir() const pure;     // e.g. "conf/modbus_profiles/"
    abstract const(char)[] profile_name() const pure;
    abstract const(char)[] model_name() const pure;
    abstract void add_handler(Device device, Element* e,
                              ref const ElementDesc desc, ubyte index);

    bool materialise()
    {
        // 1. Load and parse profile file
        void[] file = load_file(tconcat(profile_dir(), profile_name(), ".conf"), g_app.allocator);
        _profile_data = parse_profile(cast(char[])file, g_app.allocator);

        // 2. Validate required parameters were set on the binding
        // (parameters declared in the profile come in as Property setters via
        //  set_unknown_property; stored in _params Map and substituted into
        //  templated identifiers/topics/paths)

        // 3. Build device hierarchy from profile template;
        //    add_handler is called for each element-map
        Device device = create_device_from_profile(
            *_profile_data, model_name(), _device[], null, &add_handler);
        return device !is null;
    }
}
```

The subclass's `add_handler` is the wiring hook — for each `element-map` in the profile, it pulls the protocol-specific descriptor (register / topic / handle / CAN ID + offset), initialises the element value, and registers the element with the binding's internal element table so subsequent samples can find it. For example, in ModbusBinding:

```d
override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte index)
{
    ref const ElementDesc_Modbus mb = _profile_data.get_modbus(desc.element);
    // initialise element value
    ubyte[256] tmp = void;
    tmp[0 .. mb.value_desc.data_length] = 0;
    e.value = sample_value(tmp.ptr, mb.value_desc);
    // append to internal SampleElement array
    _elements ~= SampleElement(/* register, regKind, desc, ... */);
}
```

`create_device_from_profile()` handles: component hierarchy construction, static elements, expression elements, sum elements, aliases, model variant filtering, and calls the delegate for each `element-map`.

**Properties as profile parameters:** Profiles declare `parameters: host`, `device_id`, etc. The binding's `set_unknown_property` (`manager.binding`) accepts any unknown property name and stuffs it into the binding's `_params` Map, which is later substituted into URL paths, MQTT topics, etc. This means console syntax like `host=192.168.1.5 device_id=plug42` Just Works without each binding subclass having to declare those properties.

---

## Part 4: Value Descriptors

Two descriptor types handle the conversion from raw protocol data to typed `Variant` values.

### ValueDesc -- Binary data (Modbus, CAN, Zigbee, GoodWe)

```d
struct ValueDesc {
    DataType _type;      // encodes byte count, signedness, endianness, data kind
    union {
        struct { ScaledUnit _unit; float _pre_scale; }
        DateFormat _date_format;
        const(VoidEnumInfo)* _enum_info;
        CustomSample _custom_sample;
    }
}
```

**DataType flags** (uint):
- Bits 0-2: byte count minus 1 (0=1byte, 1=2bytes, 3=4bytes, 7=8bytes)
- Bit 3: `signed` (on `string_`: encodes space-padding)
- Bit 4: `word_reverse` (swap 16-bit words)
- Bit 5: `little_endian`
- Bit 6: `big_endian`
- Bit 7: `enumeration`
- Bit 8: `array`
- Bits 12-15: DataKind (`integer`, `bitfield`, `date_time`, `floating`, `low_byte`, `high_byte`, `string_`)

**Decoding:** `Variant sample_value(const void* data, ref const ValueDesc desc)`

### TextValueDesc -- Text data (MQTT, HTTP)

```d
struct TextValueDesc {
    TextType type;   // bool_, num, str, enum_, bf, dt, inetaddr, ipaddr, ip6addr
    ScaledUnit unit;
    float pre_scale = 1;
    const(VoidEnumInfo)* enum_info;
}
```

**Decoding:** `Variant sample_value(const(char)[] data, ref const TextValueDesc desc)`
**Formatting:** `const(char)[] format_value(ref const Variant val, ref const TextValueDesc desc)` -- inverse (Variant to string for write-back)
**Applying:** `void apply_value(Element*, ref Variant, ref const TextValueDesc, SysTime)` -- type-aware assignment with unit handling (HTTP binding)

---

## Part 5: Protocol Bindings

### Base Classes

```d
// src/manager/binding.d
abstract class ProtocolBinding : ActiveObject {
    // device name (String) — Device is created in g_app.devices if absent
    final ref const(String) device() const pure;
    final void device(String value);
protected:
    String _device;
    bool materialise() { return true; }  // override to build the device tree
}

abstract class ProfileBinding : ProtocolBinding {
    // load profile, create_device_from_profile(), iterate element-map entries
    // through add_handler()
    abstract const(char)[] profile_dir() const pure;
    abstract const(char)[] profile_name() const pure;
    abstract const(char)[] model_name() const pure;
    abstract void add_handler(Device device, Element* e,
                              ref const ElementDesc desc, ubyte index);
}
```

All bindings are `nothrow @nogc`. They are registered as collections (e.g. `g_app.console.register_collection!ModbusBinding()`) and updated by `Collection!ProtocolBinding().update_all()` in `manager.package.update()`.

Helpers like `ValueDesc`, `TextValueDesc`, `sample_value()`, `format_value()`, and `apply_value()` live in `src/manager/sampler.d`. That module holds the shared descriptor/codec utilities; the binding class hierarchy is in `src/manager/binding.d`.

### Binding Taxonomy

| Protocol | Class | Base | Model | Descriptor | Write | Profile Dir |
|----------|-------|------|-------|------------|-------|-------------|
| **Modbus** | `ModbusBinding` | `ProfileBinding` | Active polling | `ValueDesc` | Server mode | `modbus_profiles/` |
| **SunSpec** | `SunspecBinding` | `ProfileBinding` | Active polling | `ValueDesc` | No | `modbus_profiles/` |
| **CAN** | `CANBinding` | `ProfileBinding` | Event-driven | `ValueDesc` | No | `can_profiles/` |
| **Zigbee** | (`ZigbeeController`) | `ActiveObject + Subscriber` | Event-driven | `ValueDesc` | Yes | `zigbee_profiles/` |
| **BLE** | `BLEClientBinding` | `ProfileBinding` | Hybrid (notify + poll) | `ValueDesc` | Characteristic write | `ble_profiles/` |
| **HTTP** | `HTTPClientBinding` | `ProfileBinding` | Active polling | `TextValueDesc` | Yes | `rest_profiles/` |
| **MQTT** | `MQTTBinding` | `ProfileBinding` | Event-driven | `TextValueDesc` | Yes | `mqtt_profiles/` |
| **ESPHome** | `ESPHomeBinding` | `ProfileBinding` | Event-driven | Direct (typed proto) | Yes | `ha_profiles/` |
| **GoodWe** | `GoodWeBinding` | `ProfileBinding` | Active polling | `ValueDesc` | No | `goodwe_profiles/` |
| **TWC** | `TeslaTWCBinding` | `ProtocolBinding` | Active push | Direct | Yes | (hardcoded) |

Zigbee is the one exception that doesn't subclass `ProtocolBinding` — it uses `ZigbeeController` directly because device discovery is event-driven (devices join and identify themselves), and the controller creates devices via `create_device_from_profile()` inline when nodes are interviewed.

### File Map

| File | Role |
|------|------|
| `src/manager/binding.d` | **ProtocolBinding** + **ProfileBinding** base classes |
| `src/manager/sampler.d` | **ValueDesc**, **TextValueDesc**, `sample_value()`, `format_value()`, `apply_value()` -- descriptor/codec utilities |
| `src/protocol/modbus/binding.d` | **ModbusBinding**, **SunspecBinding** -- register batching, active polling |
| `src/protocol/modbus/client.d` | **ModbusClient** -- request/response via interface |
| `src/protocol/can/binding.d` | **CANBinding** -- event-driven packet handler |
| `src/protocol/zigbee/controller.d` | **ZigbeeController** -- attribute report handler, inline device materialisation |
| `src/protocol/ble/binding.d` | **BLEClientBinding** -- GATT notify + read, characteristic write |
| `src/protocol/http/binding.d` | **HTTPClientBinding** -- request/response, JSON/regex parsing |
| `src/protocol/mqtt/binding.d` | **MQTTBinding** -- topic subscription, bidirectional |
| `src/protocol/esphome/binding.d` | **ESPHomeBinding** -- native ESPHome API |
| `src/protocol/goodwe/binding.d` | **GoodWeBinding** -- AA55 vendor protocol |
| `src/protocol/tesla/binding.d` | **TeslaTWCBinding** -- direct value push from master |
| `src/protocol/tesla/master.d` | **TeslaTWCMaster** -- heartbeat round-robin controller |

---

### Modbus Binding -- Active Polling with Register Batching

**Key concept:** Groups contiguous registers into efficient batch reads.

**SampleElement:**
```d
struct SampleElement {
    SysTime lastUpdate;
    ushort register;         // register address
    ubyte regKind;           // coil(0), discrete_input(1), input_register(3), holding_register(4)
    ubyte flags;             // bit 0: in-flight, bit 1: constant-sampled
    ushort sampleTimeMs;     // timing gate
    PCP pcp; bool dei;       // packet priority
    Element* element;
    ValueDesc desc;
}
```

**Frequency mapping:**
```
realtime -> 1ms,     PCP=bk, DEI=true
high     -> 1000ms,  PCP=bk, DEI=false
medium   -> 10000ms, PCP=be, DEI=false
low      -> 60000ms, PCP=ee, DEI=false
constant -> 0ms,     PCP=ca (sample once)
on_demand-> ushort.max (never)
```

**Batching algorithm** (in `update()`):
1. Sort elements by `regKind` then `register` (once, when `needsSort`)
2. Scan elements, skip: in-flight, constant-done, not-yet-due
3. Start batch at first ready element, expand forward until:
   - register type changes
   - span exceeds **MaxRegs=128**
   - gap exceeds **MaxGapSize=16**
4. Promote batch PCP to highest element PCP; clear DEI if any non-droppable
5. Mark batch elements in-flight, send via `client.sendRequest()`
6. Response handler: decode with `sample_value()`, call `element.value()`
7. Error handler: clear in-flight flags

**Snoop mode:** if client is snooping, passively processes observed traffic without sending requests.

---

### CAN Binding -- Event-Driven Packet Handler

**SampleElement:**
```d
struct SampleElement {
    SysTime last_update;
    uint id;            // CAN message ID
    ubyte offset;       // byte offset in CAN data (0-7)
    Element* element;
    ValueDesc desc;
}
```

**How it works:**
- Constructor subscribes: `iface.subscribe(&packet_handler, PacketFilter(type: PacketType.unknown, direction: incoming))`
- `packet_handler`: for each incoming CAN packet, iterates elements matching `can.id`, then: `e.element.value(sample_value(data + offset, desc), creation_time)`
- No `update()` override, no frequency gating -- every matching message updates immediately

---

### Zigbee -- Attribute Report Handler

Zigbee doesn't use a `ProtocolBinding` subclass. `ZigbeeController` handles sampling directly because device discovery is event-driven (devices announce themselves via join/interview) — the controller creates devices on the fly via `create_device_from_profile()`.

**SampleElement:**
```d
struct SampleElement {
    Element* element;  ValueDesc desc;
    EUI64 eui;  ubyte endpoint;  ushort cluster;  ushort attribute;  ushort manufacturer;
}
```

Stored in `Map!(ulong[2], SampleElement)` keyed by `make_sample_key(eui, endpoint, cluster, attribute, manufacturer)`.

**Data flow:**
1. Device sends `ZCLCommand.report_attributes` (0x0a) -- unsolicited
2. `handle_aps_frame()` parses: `[u16 attr_id][u8 data_type][value...]`
3. Looks up SampleElement by composite key
4. Decodes via `get_zcl_value()`, adjusts with `adjust_value()` per ValueDesc
5. `e.element.value(v, timestamp, this)`

**Also handles:** Tuya datapoints (cluster 0xEF00), IAS zone status (cluster 0x0500 synthetic attributes).

**No polling** -- relies entirely on device-initiated attribute reports.

---

### HTTP Binding -- Request/Response with JSON Parsing

The HTTP binding is the most feature-rich. It supports multiple request/response patterns, body formatting, JSON path navigation, regex parsing, success validation, and bidirectional element binding.

#### Profile: Request Definitions

```
requests:
    request: name, METHOD, "/path/with/{param}"
        [format: json, {"body": {key}: {value}}]
        [format: form, {key}={value}]
        [parse: json]
        [parse: json, template.{key}.path]
        [parse: regex]
        [parse: none]
        [root: data.response]
        [success: $status == "ok"]
```

**Request fields:**
- **name** -- identifier referenced by element definitions
- **METHOD** -- HTTP method: GET, POST, PUT, DELETE, HEAD, PATCH
- **path** -- URL path, may contain placeholders (see below)

**Sub-directives (all optional):**

| Directive | Purpose |
|-----------|---------|
| `format: json, template` | Send JSON body; template expanded per-element and deep-merged |
| `format: form, template` | Send `application/x-www-form-urlencoded` body |
| `parse: json` | Parse response as JSON, walk element identifiers as paths (default) |
| `parse: json, {key}.subpath` | Parse JSON with `{key}` template -- element identifier substituted into parse path |
| `parse: regex` | Element identifier is a regex pattern; first capture group (or full match) extracted |
| `parse: none` | Discard response body |
| `root: path.to.data` | Navigate to this JSON path before extracting elements |
| `success: expr` | Expression evaluated on JSON root; request fails if false |

#### Profile: Element Definitions

```
http: request, identifier, type [, enum_name] [, unit],  desc: id [, display_units, frequency]
    [write: write_request [, write_key]]
    [response: alt_path]
```

- **request** -- name of the request definition to use for reading
- **identifier** -- JSON path or literal key for extracting value from response
  - Unquoted (`evse.temp`): dot-walk path through JSON objects
  - Quoted (`"temperature_c"`): literal object key lookup (no dot-walk)
- **write: request [, key]** -- bind element writes to a different request; optional `key` overrides the identifier used as `{key}` in the write request
- **response: path** -- override the response extraction path (use this instead of `identifier` when reading)

#### URL/Body Placeholders

Three kinds of placeholders, never mixed:

**Profile parameters** (`{param_name}`):
- Defined via `parameters:` section; substituted once at device creation
- Used for base URLs, device IPs, API keys

**Per-element singular** (`{key}`, `{value}`):
- One HTTP request sent per element per frame
- `{key}` = element identifier (or write_key override), `{value}` = formatted element value
- Path example: `/{key}?value={value}` with element mode=2 -> `/mode?value=2`

**Batch plural** (`{keys}`, `{values}`):
- All matching elements collected into one HTTP request
- Comma-separated in paths: `/currents?{keys}={values}` -> `/currents?L1=5.0,L2=4.5,L3=5.2`
- In JSON bodies: each element expands the template, results deep-merged
- In form bodies: each element appends `&key=value`

**Cannot mix** `{key}`/`{value}` with `{keys}`/`{values}` in same request.

#### Body Formatting

**`format: json, template`**
- Template expanded per element: `{key}` becomes quoted JSON string, `{value}` becomes JSON-formatted value
- Multiple elements `{keys}`/`{values}`: each expansion parsed as JSON, then **deep-merged**:
  - Object keys: recursive merge (later overwrites)
  - Arrays: append elements across expansions
  - Scalars: later overwrites earlier
- Example: template `{"paths": [{keys}]}` with elements voltage, current -> `{"paths": ["voltage", "current"]}`

**`format: form, template`**
- Template expanded per element, joined with `&`
- Example: `{keys}={values}` with L1=5.0, L2=4.5 -> `L1=5.0&L2=4.5`

**No format** -- path-only request (GET with query params, or no body)

#### Response Parsing

**`parse: json` (default):**
1. Parse response body as JSON
2. Evaluate `success:` expression if defined (see below)
3. Navigate to `root:` path if defined
4. For each element bound to this request:
   - Use `response:` override path, or element identifier
   - If `parse:` template has `{key}`: expand `{key}` with identifier, walk resulting path
   - Else if identifier is quoted: flat object key lookup
   - Else: dot-walk path (supports `a.b.c` and `arr[0]`)
5. Convert JSON value to Element value via `apply_value()`

**`parse: regex`:**
1. For each element bound to this request:
   - Element identifier is the regex pattern
   - `regex_match(response_content, pattern)`
   - Extract first capture group, or full match if no captures
   - Parse with `sample_value(text, TextValueDesc)`

**`parse: none`:**
- Response discarded, no element updates

#### Success Expressions

Expression evaluated on JSON root object. JSON members are available as `$name` variables.

```
success: $result == "OK"           # string equality
success: $count > 0                # numeric comparison
success: $status == 200 && $ok     # compound expression
```

Variables use `$` prefix (e.g., `$result` looks up JSON key `"result"`). Supports `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`.

If expression evaluates to false, all element updates for that response are skipped.

#### JSON Path Walking

`walk_json_path()` supports:
- Dot notation: `a.b.c` -- nested object navigation
- Array indexing: `arr[0]`, `data.items[1].id`
- Mixed: `data.items[2].nested.value`

`resolve_parse_template()` for `{key}` in parse templates:
- Template `items.{key}.value` with identifier `temp` -> walks `items`, then `temp`, then `value`
- Respects quoted vs unquoted identifiers for the `{key}` step

#### Write-Back Flow

1. Element value changes (from outside the HTTP binding)
2. `on_change()`: finds element's `write_request_index`, marks that `RequestState.write_dirty = true`
3. Next `update()`: sends write request before checking read timing
4. For singular requests: one request per changed element
5. For batch requests: all dirty elements collected into one request

#### Internal State

```d
struct HTTPSampleElement {
    Element* element;
    ushort http_index;        // index into profile.http_elements[]
    ushort sample_time_ms;    // 400/1000/10000/60000/0/ushort.max
    MonoTime last_sample;
    bool sampled;             // for constant: true after first sample
}

struct RequestState {
    String resolved_path, resolved_body_template;
    Expression* success_expr;
    String resolved_root_path, resolved_parse_template;
    ushort request_index, min_sample_ms;
    MonoTime last_request;
    bool in_flight, write_dirty, is_batch, has_substitutions;
    ushort[4] sub_offsets;    // byte offsets: [path_key, body_key, path_val, body_val]
}
```

**Frequency mapping:** realtime->400ms, high->1000ms, medium->10000ms, low->60000ms, constant->0 (once), on_demand->ushort.max.

**In-flight tracking:** Circular queue `_in_flight_queue[16]` of request indices, max 16 concurrent requests.

#### Complete Example

```
parameters: host

requests:
    request: status, GET, "http://{host}/api/status"
        root: data
        success: $status == "ok"

    request: set_mode, POST, "http://{host}/api/settings?{key}={value}"
        success: $result == "OK"

    request: feed_currents, POST, "http://{host}/api/currents"
        format: json, {"currents": {"{key}": {value}}}

elements:
    http: status, mode, enum, ChargeMode,   desc: charge_mode, , high
        write: set_mode, mode

    http: status, temp, num, deg-C,         desc: temperature, deg-C, medium

    http: feed_currents, , num, A,          desc: l1_current, A
        write: feed_currents, L1
    http: feed_currents, , num, A,          desc: l2_current, A
        write: feed_currents, L2
```

**Read flow:** GET `http://192.168.1.1/api/status` -> `{"data": {"mode": 1, "temp": 45.2}, "status": "ok"}` -> success check passes -> root navigates to `data` -> `mode`=1 (enum lookup), `temp`=45.2 deg-C

**Write flow (singular):** User sets charge_mode to solar (2) -> POST `http://192.168.1.1/api/settings?mode=2` -> `{"result": "OK"}` -> success check passes

**Write flow (batch JSON):** User sets L1=5.0A, L2=4.5A -> POST `http://192.168.1.1/api/currents` with body `{"currents": {"L1": 5.0, "L2": 4.5}}` (deep-merged from two template expansions)

---

### MQTT Binding -- Topic Subscription, Bidirectional

**SampleElement:**
```d
struct SampleElement {
    MonoTime last_update;
    Element* element;
    TextValueDesc desc;
    String read_topic;
    String write_topic;
}
```

**How it works:**
- Constructor subscribes topics: `broker.subscribe(topic, &on_publish)` for each subscription in profile
- `on_publish(sender, topic, payload, timestamp)`: matches topic to `read_topic` -> `sample_value(payload_str, desc)` -> `element.value(value, timestamp, this)`
- Write-back: `on_change()` -> `format_value(val, desc)` -> `broker.publish(write_topic, text)`
- Purely reactive -- no `update()` override
- Topic wildcards: `+` (single-level), `#` (multi-level)
- Parameters: `{device_id}` in topics substituted at device creation from named arguments (defined via `parameters:` section in profile)

---

### Tesla TWC Binding -- Direct Value Push

`TeslaTWCBinding` subclasses `ProtocolBinding` (not `ProfileBinding`) — no profile, no descriptors. Device template is built inline in the binding's `materialise()`. Values are read directly from the master controller struct.

**How it works:**
- `TeslaTWCMaster` handles protocol: 400ms heartbeat round-robin, request cycling (heartbeat -> charge info -> serial -> VIN)
- `TeslaTWCBinding.update()`: lazy-binds to master by `charger_id` or `mac`, then pushes charger fields to elements by `element.id` string match:
  ```
  "state"         -> charger.charger_state()
  "voltage1"      -> Volts(charger.voltage1)
  "current"       -> CentiAmps(charger.current)      (only if flags & 2)
  "power"         -> Watts(charger.total_power)
  "import"        -> WattHours(lifetime_energy * 1000)
  "serial_number" -> charger.serial_number[]          (only if flags & 4)
  "vin"           -> charger.vin[]                    (only if flags & 0xF0 == 0xF0)
  ```
- Conditional reporting: values only set when `charger.flags` indicate data received
- Write: only `target_current`, directly sets `charger.target_current`
- Device template hardcoded in `materialise()` (components: info, charge_control, meter)

---

## Part 6: Implementing a New Binding

### 1. Choose Sampling Model
- **Active polling** (Modbus, HTTP): override `update()`, manage per-element timing, submit requests
- **Event-driven** (CAN, MQTT, BLE): subscribe to the data source in `startup()`, react in callbacks
- **Direct push** (TWC): read state from a protocol controller in `update()`

### 2. Choose Value Descriptor
- **Binary data** (raw bytes): use `ValueDesc` + `sample_value(void*, ValueDesc)`
- **Text data** (JSON, strings): use `TextValueDesc` + `sample_value(char[], TextValueDesc)`
- **Direct values** (already typed): set `element.value()` with unit-typed Variants

### 3. Create SampleElement Struct
```d
struct SampleElement {
    Element* element;          // always needed
    // + protocol-specific identifier (register, topic, handle, message_id, ...)
    // + value descriptor (ValueDesc or TextValueDesc)
    // + timing/state fields (last_update, flags, sample_time_ms, ...)
}
```

### 4. Implement Binding Class

For a profile-driven binding, subclass `ProfileBinding`:

```d
class MyBinding : ProfileBinding {
    alias Properties = AliasSeq!(Prop!("client", client),
                                 Prop!("profile", profile),
                                 Prop!("model", model));
nothrow @nogc:
    enum type_name = "my-binding";
    enum path = "/binding/my";

    this(CID id, ObjectFlags flags = ObjectFlags.none) {
        super(collection_type_info!MyBinding, id, flags);
    }

    final override bool validate() const pure {
        return _client.get !is null && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup() {
        if (!materialise()) return CompletionStatus.error;
        // subscribe to data source, etc.
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown() {
        // unsubscribe, clear state
        return CompletionStatus.complete;
    }

    override void update() {
        // active polling: check timing, submit requests
    }

    final override const(char)[] profile_dir() const pure => "conf/my_profiles/";
    final override const(char)[] profile_name() const pure => _profile_name[];
    final override const(char)[] model_name()   const pure => _model_name[];

    final override void add_handler(Device device, Element* e,
                                    ref const ElementDesc desc, ubyte index) {
        ref const ElementDesc_MyProto p = _profile_data.get_my(desc.element);
        // initialise element value to typed zero
        ubyte[256] tmp = void;
        tmp[0 .. p.value_desc.data_length] = 0;
        e.value = sample_value(tmp.ptr, p.value_desc);
        // push SampleElement with protocol-specific info
        _elements ~= SampleElement(/* ... */);
        // optional: element.add_subscriber(this) for write-back
    }

    // Write-back (if Subscriber implemented):
    override void on_change(Element* e, ref const Variant val,
                            SysTime ts, Subscriber who) {
        if (who is this) return;  // don't echo own changes
        // format and send via protocol
    }

private:
    ObjectRef!MyClient _client;
    String _profile_name, _model_name;
    Array!SampleElement _elements;
}
```

If no profile is needed (the TWC case), subclass `ProtocolBinding` directly and build the device tree inline by overriding `materialise()`.

### 5. Add Profile Support (skip for direct-push bindings)
- Add `ElementDesc_MyProto` struct to `src/manager/profile.d`
- Add `ElementType.myproto` to the enum
- Add a parsing case in `parse_profile()`
- Add `myproto_elements[]` to `Profile` struct
- Create `conf/myproto_profiles/`

### 6. Register the Collection
In your protocol module's `init()`:
```d
g_app.console.register_collection!MyBinding();
```

That gives you `/binding/my/add`, `/binding/my/set`, `/binding/my/print`, etc. for free.

### 7. Register Module
Add to `src/manager/plugin.d` module list.

---

## Part 7: BLE Bindings

### What Exists
- `BLEInterface` -- GATT session management, WinRT backend, packet routing
- `BLEClient` -- connection initiator, `read_characteristic(handle)`
- `BLEClientBinding` (`src/protocol/ble/binding.d`) -- the `ProfileBinding` subclass that wires GATT characteristics to elements
- GATT discovery: services -> characteristics with handles, UUIDs, properties
- Notifications auto-subscribed for notify/indicate characteristics
- WinRT: `submit_read()`, `submit_write()`, `poll_gatt()` functional

### Operating Model
Hybrid: **react** to notifications/indications (like CAN) + **poll** read-only characteristics that don't notify. Profiles in `conf/ble_profiles/` map `service_uuid + char_uuid` to elements with `ValueDesc` for decoding raw bytes. UUIDs are 128-bit but many BLE profiles use 16-bit short UUIDs (0x2A19 = battery level).

### BLE Characteristic Model
```d
struct GattCharacteristic {
    ushort handle;                           // ATT attribute handle
    GUID service_uuid;
    GUID char_uuid;
    GattCharacteristicProperties properties; // read/write/notify/indicate/...
}
```

### Tesla Vehicle BLE
The Tesla vehicle BLE flow (separate from TWC charging) is implemented as a session model in `protocol/ble/` — see [[tesla_ble_architecture]] in memory. It doesn't go through `BLEClientBinding` because vehicle sessions are server-spawned, ephemeral, and identified by VIN rather than configured by a binding.
