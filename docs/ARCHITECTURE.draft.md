# Architecture

OpenWatt is organized into four layers. Each layer depends only on the layers below it.

```
┌─────────────────────────────────────────────┐
│  Apps            Energy management,         │
│                  circuits, load shedding,   │
│                  automation                 │
├─────────────────────────────────────────────┤
│  Protocols       Modbus, MQTT, Zigbee,      │
│                  HTTP, Tesla TWC, CAN, ...  │
├─────────────────────────────────────────────┤
│  Router          Interfaces, Streams,       │
│                  Bridges, Packet scheduling │
├─────────────────────────────────────────────┤
│  Manager         Console, Collections,      │
│                  Device model, Reflection   │
└─────────────────────────────────────────────┘
```

The Manager layer provides the runtime foundation — object lifecycle, the console, the device data model, and the compile-time reflection that drives everything above it. The Router layer abstracts byte transports and packet interfaces. The Protocol layer implements specific protocols on top of those abstractions. The Apps layer consumes device data and adds domain logic.

This document walks through each layer bottom-up, then traces a complete data flow from physical wire to UI.

## Manager Layer

The Manager is the runtime kernel. It provides four things: a main loop, a console, a collection system for managing runtime objects, and a hierarchical data model for device state.

### Main Loop

The application runs at a configurable tick rate (default 20 Hz). Each tick:

1. `pre_update()` — Modules do preparatory work
2. `update()` — All modules and their managed objects update
3. `post_update()` — Cleanup, state propagation

Modules register themselves in `src/manager/plugin.d`. Each module owns one or more Collections and provides lifecycle hooks (`init`, `update`, `pre_update`, `post_update`).

### Console

The console is a live command-line interface, accessible interactively at startup or remotely via Telnet. It uses hierarchical paths:

```
/stream/tcp-client add name=tcp1 remote=192.168.1.100:502
/interface/modbus add name=inv stream=tcp1 protocol=rtu
```

`conf/startup.conf` is not a configuration file — it's a script of console commands executed line-by-line at boot. The same commands you'd type interactively.

The console provides:
- **Scopes**: Navigate with `/system`, `/interface`, `/protocol`, etc.
- **Auto-generated commands**: Every Collection gets `add`, `remove`, `get`, `set`, `print` for free
- **Tab completion and history**: Standard readline-style editing
- **Remote access**: Telnet sessions are full console sessions

See [CLI Reference](CLI.md) for command syntax and examples.

### Collections

Collections are type-safe containers that manage runtime objects. When you register a `Collection!ModbusInterface`, the system automatically generates:

- `/interface/modbus/add` — Create a new interface
- `/interface/modbus/remove` — Destroy an interface
- `/interface/modbus/get` — Read a property
- `/interface/modbus/set` — Modify a property
- `/interface/modbus/print` — List all interfaces with their state

This works because of compile-time reflection. The D compiler inspects the type's getters and setters at compile time and synthesizes a property table — types, names, defaults, validation. That same metadata feeds the REST API schema, the web UI's property editors, and the Android app's configuration screens. Define a property once in D; it appears everywhere.

Supported property types include primitives, durations (`"5m"`, `"30s"`), enums, arrays, and references to other managed objects (streams, interfaces, devices). Custom types can be added by implementing a `convertVariant()` function.

### Object Lifecycle

All managed objects inherit from `BaseObject` and follow a state machine:

```
Validate → Starting → Running
              ↓          ↓
          InitFailed   Failure
              ↓          ↓
           (backoff)  Stopping → Disabled/Destroyed
```

- **Validate**: Check configuration. If a dependency isn't ready yet, return and retry next tick.
- **Starting**: Acquire resources, open connections. May be async (return `Continue` to spread work across ticks).
- **Running**: Normal operation. `update()` called each tick.
- **Failure**: Something went wrong. Shut down, then retry with exponential backoff (100ms → 60s cap).
- **Stopping**: Release resources. Always runs before destruction.

Objects reference each other through `ObjectRef`, which safely detaches when the target is destroyed and reattaches when it reappears. Dependencies are tracked via state subscriptions — when a dependency goes offline, dependents restart automatically. This means the system self-heals: unplug a serial adapter, and everything on that bus cleanly shuts down. Plug it back in, and they restart in order.

### Device Data Model

Equipment state is represented as a three-level hierarchy:

```
Device "goodwe_ems"
  ├─ Component "info" (template: DeviceInfo)
  │    ├─ Element "type" = "inverter"
  │    ├─ Element "name" = "GoodWe ES series"
  │    └─ Element "serial_number" = "95000EMS230W1234"
  ├─ Component "status" (template: DeviceStatus)
  │    ├─ Element "up_time" = 1843200s
  │    └─ Component "network" (template: Network)
  │         ├─ Element "mode" = "modbus"
  │         └─ Element "address" = 247
  ├─ Component "inverter" (template: Inverter)
  │    ├─ Element "state" = grid_tied
  │    ├─ Element "temp" = 42.1°C
  │    ├─ Component "solar" (template: Solar)
  │    │    ├─ Element "voltage" = 380.2V
  │    │    └─ Element "power" = 3200W
  │    ├─ Component "backup" (template: EnergyMeter)
  │    │    ├─ Element "voltage" = 241.3V
  │    │    └─ Element "power" = 800W
  │    └─ Component "battery" (template: Battery)
  │         ├─ Element "soc" = 85%
  │         └─ Component "meter" (template: EnergyMeter, type: dc)
  │              ├─ Element "voltage" = 52.3V
  │              └─ Element "current" = 15.2A
  └─ Component "config" (template: Configuration)
       └─ ...
```

- **Device**: Top-level object.
- **Component**: Logical grouping. Supports arbitrary nesting. Templated — a Battery component has the same structure whether it came from Modbus, CAN, or Zigbee. Templates define expected elements and sub-components (see [Component Templates](COMPONENT_TEMPLATES.md)).
- **Element**: A single data point with a typed value and timestamp. Elements notify subscribers on change, enabling event-driven logic throughout the system.

Navigation uses dot-notation: `goodwe_ems.inverter.battery.meter.voltage` traverses the hierarchy. The energy manager, API, and frontends all consume this same tree — no protocol-specific data formats leak upward.

## Router Layer

The Router provides two abstractions: Streams for bytes, and Interfaces for packets.

### Streams

Streams are bidirectional byte transports. They carry raw data without knowing what protocol runs on top.

| Stream Type | Description |
|-------------|-------------|
| TCP Client | Connects to a remote TCP socket |
| TCP Server | Accepts incoming TCP connections |
| Serial | Hardware serial port (RS232/RS485) |
| UDP | Datagram transport |
| WebSocket | Upgraded HTTP connection |

Streams are managed objects — they participate in the lifecycle state machine, reconnect on failure with backoff, and can be created/destroyed at runtime via console commands.

### Interfaces

Interfaces parse protocol frames from streams. A Modbus interface handles RTU/TCP/ASCII framing and CRC validation. A CAN interface handles frame arbitration. A Zigbee interface bridges radio traffic into the packet routing system.

All interfaces share a common packet abstraction:

```
┌──────────────────────────────────────────────┐
│  Packet                                      │
│  ┌──────────┐ ┌──────┐ ┌──────────────────┐  │
│  │ 24-byte  │ │ VLAN │ │ Payload          │  │
│  │ header   │ │ TCI  │ │ (protocol data)  │  │
│  │ (union)  │ │      │ │                  │  │
│  └──────────┘ └──────┘ └──────────────────┘  │
└──────────────────────────────────────────────┘
```

The 24-byte header is a union — each protocol type overlays its own header struct (Modbus addresses, Zigbee APS frame, CAN arbitration ID, etc.). The `PacketType` discriminator identifies which header is active. This means all protocols fit the same packet structure without boxing or heap allocation.

Every packet carries 802.1p **Priority Code Point (PCP)** and **Drop Eligible Indicator (DEI)** fields, regardless of the underlying protocol. Interfaces classify traffic at ingress — user commands get high priority, background polls get low priority — and schedule transmission accordingly. This applies to all interfaces, irrespective of protocol. On a constrained serial link, a light switch command jumps the queue ahead of register polls without any explicit configuration.

### QoS: Priority Classes

The priority classes used across all interfaces:

| PCP | Class | OpenWatt Usage |
|-----|-------|----------------|
| 1 | Background | Housekeeping polls, diagnostics |
| 0 | Best Effort | Normal traffic (default) |
| 2 | Excellent Effort | Device discovery, interviews |
| 3 | Critical Apps | Protocol responses |
| 5 | Voice | User commands (low latency) |

The `PriorityPacketQueue` dispatches highest-priority-first, with DEI-marked frames eligible for discard under congestion. Note: PCP=0 (Best Effort) is *not* the lowest priority — PCP=1 (Background) is. This follows the 802.1p standard ordering.

### Bridges

Every interface has a **port VLAN ID (PVID)** for participation in 802.1Q switching when bridged.

Bridges relay packets between interfaces. A bridge with two Modbus interfaces transparently relays RTU frames between them. Add a CAN interface to the same bridge, and those packets route too.

Add an Ethernet interface, and non-Ethernet protocols are wrapped in custom L2 frames and distributed across the Ethernet broadcast domain. Serial Modbus in one building, CAN bus in another, both bridged onto an Ethernet backbone — any node on the segment can reach both.

Bridges support:
- **VLAN filtering**: Packets routed based on VLAN ID
- **MAC learning**: Standard L2 forwarding table
- **PCP preservation**: Priority bits survive VLAN tag operations

## Protocol Layer

Each protocol module implements one or more of: an Interface (packet framing), a Client (request/response correlation), a Sampler (periodic data collection), and device Profiles (register/cluster maps).

### Interfaces

Protocol interfaces sit between streams and the rest of the system. A Modbus interface, for example:

1. Reads bytes from its stream
2. Detects RTU/TCP/ASCII framing
3. Validates CRC/LRC
4. Extracts the Modbus PDU into a Packet with a typed header
5. Dispatches the packet to subscribers (bridges, clients)

On the transmit side, the reverse: wrap PDU in the configured framing, compute CRC, push bytes to the stream.

### Clients

Protocol clients handle request/response correlation. A Modbus client:

1. Accepts read/write requests from samplers or user commands
2. Tags each request with a sequence number
3. Submits the request to the interface
4. Matches incoming responses by sequence number
5. Invokes the caller's callback with the result

Clients also handle timeouts, retries, and — in snoop mode — passively decode traffic without sending any requests of their own.

### Samplers

Samplers periodically read data from devices and update the Element tree. Key features:

- **Smart batching**: Adjacent registers are grouped into single read requests, respecting protocol limits (e.g., Modbus 128-register max per request)
- **Gap optimization**: Gaps larger than 16 registers split into separate requests
- **Adaptive frequency**: Elements declare their desired sample rate — Realtime (400ms), High (1s), Medium (10s), Low (60s), or Constant (read once)
- **Type-aware decoding**: Registers are decoded according to their profile type (U16, S32, F32, etc.) and endianness

The data flow from wire to Element:

1. Sampler builds a batched read request
2. Protocol client submits it to the interface
3. Interface frames and transmits the packet
4. Response arrives, interface validates and dispatches
5. Client matches response to request, invokes callback
6. Sampler decodes register data and writes to Elements
7. Elements notify their subscribers of the new values

### Device Profiles

Profiles describe how to talk to a specific device model — no code changes required. A Modbus profile maps register addresses to Element names, types, and sample rates. A Zigbee profile maps ZCL cluster attributes. A REST profile describes JSON API endpoints.

```
# Excerpt from conf/modbus_profiles/eastron_sdm120.conf

registers:
	reg: 30000, f32, V,    desc: voltage
	reg: 30006, f32, A,    desc: current
	reg: 30012, f32, W,    desc: activePower
	reg: 30070, f32, Hz,   desc: frequency

device-template:
	component:
		id: meter
		template: EnergyMeter
		element-map: voltage, @voltage
		element-map: current, @current
		element-map: power, @activePower
		element-map: frequency, @frequency
```

When a remote server is added with `profile=sdm120`, the system loads this profile, creates the Component/Element hierarchy, and begins sampling automatically. See [Device Profiles](PROFILE_FILE_FORMAT.md) for the full format specification.

## Apps Layer

Apps sit at the top of the stack and consume device data to implement domain logic. They don't care which protocol delivered the data — they work with the Device/Component/Element tree.

### Energy Management

Models a site's electrical system as a hierarchical circuit tree. Breaker ratings, sub-panel hierarchies, narrow links between buildings — limits are enforced independently at every node.

The same topology awareness that prevents overloads also finds opportunities: an EVSE behind a constrained grid link can still charge at full rate when local solar and battery can supply it. Protection and optimisation from the same model. Protocol-agnostic — the meter feeding a circuit can be Modbus, Zigbee, ESPHome, or anything else that provides energy data.

See [Energy Management](ENERGY.md) for the full configuration reference.

### Cron

Scheduled command execution. Runs console commands at configurable intervals:

```
/system/cron/add name=poll schedule=5m command="/device/print"
```

Supports duration-based scheduling, repeat/one-shot modes, and concurrent execution of long-running commands.

### Future: Automation Engine

Planned support for event-driven automation — binding Element value changes to console commands or custom logic.

## Compile-Time Reflection: Define Once

This is the thread that ties everything together.

When you define a property in a D struct or class — say, a `max_current` field with a getter and setter — the compiler's reflection system extracts it at compile time. From that single definition:

1. The **Collection** generates `add`/`set`/`get` commands that accept `max-current=32` on the console
2. The **REST API** exposes it as a typed JSON field with schema metadata
3. The **Web UI** renders an appropriate editor (number input, dropdown, toggle — based on the type)
4. The **Android app** does the same, consuming the same schema

No serialization code, no API handlers, no UI components written per-property. Add a field to a struct, recompile, and it appears in every interface. Remove it, and it disappears.

This is what makes it practical to support dozens of device types and protocol configurations without drowning in boilerplate. It's also what makes the frontends possible as thin clients — they don't embed knowledge of every property; they generate UI from the metadata at runtime.

## Data Flow: Wire to UI

Here's a complete trace, from a physical meter reading to a number on someone's phone:

```
RS485 wire
  → TCP bridge (192.168.3.7:8002)
    → Stream (tcp-client "meter_link")
      → Interface (modbus "meter", protocol=rtu)
        → validates CRC, extracts PDU
          → Client (modbus "mb", matches response to request)
            → Sampler (decodes F32 register → 3247.5)
              → Element ("meter.active_power" = 3247.5W)
                → Subscriber (energy manager)
                  → Circuit tree update
                    → REST API (/api/apps/energy/circuits)
                      → Web UI / Android app
```

Every step is inspectable at runtime. You can capture packets at the interface level (`/tools/pcap`), print device state (`/device/print`), check element values, and reconfigure any layer — all through the same console.

## Source Layout

| Directory | Layer | Contents |
|-----------|-------|----------|
| `src/manager/` | Manager | Application, Console, Collection, Device model, Cron |
| `src/router/iface/` | Router | BaseInterface, Bridge, VLAN, Packet, PriorityQueue |
| `src/router/stream/` | Router | TCP, UDP, Serial, WebSocket streams |
| `src/router/port/` | Router | Hardware serial port abstraction |
| `src/protocol/modbus/` | Protocol | Modbus interface, client, sampler, profiles |
| `src/protocol/mqtt/` | Protocol | MQTT client and broker |
| `src/protocol/http/` | Protocol | HTTP/WebSocket client and server |
| `src/protocol/zigbee/` | Protocol | Zigbee EZSP, coordinator, ZCL/ZDO |
| `src/protocol/can/` | Protocol | CAN bus interface and profiles |
| `src/protocol/tesla/` | Protocol | Tesla TWC interface and master controller |
| `src/protocol/esphome/` | Protocol | ESPHome native API client |
| `src/apps/energy/` | Apps | Energy manager, circuits, appliances, meters |
| `src/main.d` | — | Entry point |

## Further Reading

- [CLI Reference](CLI.md) — Command syntax and scope navigation
- [Energy Management](ENERGY.md) — Circuit hierarchy, load shedding, appliance configuration
- [Device Profiles](PROFILE_FILE_FORMAT.md) — Profile file format for adding device support
- [Component Templates](COMPONENT_TEMPLATES.md) — Standard data model templates
- [Contributing](../CONTRIBUTING.md) — Build system, coding style, development setup
