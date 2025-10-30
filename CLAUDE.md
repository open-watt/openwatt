# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenWatt is an industrial/IoT communications router and automation platform written in D. It functions as a programmable gateway that bridges diverse industrial protocols (Modbus, MQTT, Zigbee, CAN, HTTP, etc.) with a runtime console for configuration, monitoring, and automation.

**Key differentiators:**
- Runtime configuration via console commands (not config files)
- Targets both desktop and embedded microcontrollers (ESP32, STM32, RISC-V)
- Uses custom `@nogc nothrow` runtime (uRT) instead of D standard library
- Protocol-agnostic packet routing with unified interface abstraction
- Hierarchical data model (Device → Component → Element) for runtime state

## Build System

Makefile-based build supporting multiple D compilers and cross-compilation to various platforms.

### Common Commands

```bash
# Basic builds
make                                    # Debug build with DMD (default)
make COMPILER=ldc CONFIG=release       # Release build with LDC (recommended for production)
make COMPILER=dmd CONFIG=debug         # Debug build with DMD
make clean                             # Clean build artifacts

# Cross-platform builds (requires LDC)
make COMPILER=ldc PLATFORM=arm64       # ARM64 build
make COMPILER=ldc PLATFORM=riscv64     # RISC-V 64-bit
make COMPILER=ldc PLATFORM=x86         # 32-bit x86

# Testing
make CONFIG=unittest                    # Build with unit tests enabled
./bin/x86_64_unittest/openwatt_test    # Run unit tests (adjust platform as needed)
```

**Build variables:**
- `COMPILER`: `dmd` (default, fast compilation), `ldc` (best optimization), `gdc`
- `CONFIG`: `debug` (default), `release`, `unittest`
- `PLATFORM`: `x86_64` (default), `x86`, `arm64`, `arm`, `riscv64`, `riscv`, plus embedded targets (esp32, stm32, etc.)

Binaries output to `bin/$(PLATFORM)_$(CONFIG)/openwatt`. Windows users can alternatively use Visual Studio or MSBuild with `openwatt.sln`.

## Architecture: The Big Picture

### Layered System Design

OpenWatt is organized into four layers, each with distinct responsibilities:

```
┌─────────────────────────────────────────┐
│  Apps Layer (src/apps/)                 │  High-level business logic
│  - Energy management, automation        │
├─────────────────────────────────────────┤
│  Protocol Layer (src/protocol/)         │  Protocol implementations
│  - Modbus, MQTT, Zigbee, HTTP, etc.     │
├─────────────────────────────────────────┤
│  Router Layer (src/router/)             │  Packet routing infrastructure
│  - Interfaces, Streams, Ports           │
├─────────────────────────────────────────┤
│  Manager Layer (src/manager/)           │  Core runtime system
│  - Console, Collections, Device model   │
└─────────────────────────────────────────┘
```

### Key Architectural Concepts

#### 1. Runtime Console Configuration

**Critical distinction:** OpenWatt is NOT configured via static config files. Instead, `conf/startup.conf` contains a script of **console commands** that are executed line-by-line at startup.

Commands use hierarchical paths like `/interface/modbus/add name=inv stream=tcp1`. The console provides:
- Command registration via scopes (`/system`, `/interface`, `/protocol`, etc.)
- Automatic command generation for Collections (`add`, `remove`, `get`, `set`, `print`)
- Tab completion and command history
- Remote access via Telnet

**Example workflow:** To add a Modbus interface, you'd execute:
```
/stream/tcp-client add name=tcp1 remote=192.168.1.100:502
/interface/modbus add name=inv stream=tcp1 protocol=rtu
```

These commands create runtime objects managed by the Collection system.

#### 2. Collection System: Type-Safe Object Management

Collections are the backbone of runtime object management. Key features:

- **Type-safe containers**: `Collection!Type` wraps `Map!(String, BaseObject)`
- **Automatic CLI generation**: Collections auto-generate `/add`, `/remove`, `/get`, `/set`, `/print` commands
- **Property synthesis**: Compile-time reflection extracts getters/setters into a property system
- **Lifecycle management**: Objects flow through state machine (Validate → Starting → Running → Stopping)
- **Observable pattern**: State changes propagate to subscribers

**Code locations:**
- [src/manager/collection.d](src/manager/collection.d) - Collection implementation
- [src/manager/base.d](src/manager/base.d) - BaseObject state machine
- [src/manager/console/collection_commands.d](src/manager/console/collection_commands.d) - Auto-generated commands

**Example:** When you register a `Collection!ModbusInterface`, the console automatically creates:
- `/interface/modbus/add` - Create new interface
- `/interface/modbus/remove` - Remove interface
- `/interface/modbus/get` - Get property value
- `/interface/modbus/set` - Set property value
- `/interface/modbus/print` - List all interfaces

#### 3. BaseObject State Machine

All managed objects inherit from `BaseObject` and follow a lifecycle state machine with exponential backoff on failure:

```
Validate → Starting → Running
              ↓          ↓
          InitFailed   Failure
              ↓          ↓
           (backoff)  Stopping → Disabled/Destroyed
```

**States:**
- `Validate`: Check if configuration is valid
- `Starting`: Execute `startup()` (may be async, return `Continue`)
- `Running`: Normal operation, `update()` called each frame
- `Failure`: Shutdown and retry with exponential backoff (100ms → 60s)
- `Stopping`: Execute `shutdown()` before transitioning to Disabled/Destroyed

**Key methods to override:**
- `validate()`: Return true if config is valid
- `startup()`: Initialize resources (return `Complete`, `Continue`, or `Error`)
- `shutdown()`: Clean up resources (must not fail)
- `update()`: Per-frame processing when Running

See [src/manager/base.d:325-495](src/manager/base.d#L325-L495) for state machine implementation.

#### 4. Module System

Modules are the top-level organizational unit. Each module registers Collections and provides lifecycle hooks:

- `init()`: One-time initialization, register Collections with console
- `pre_update()`: Called before all modules' `update()`
- `update()`: Per-frame processing
- `post_update()`: Called after all modules' `update()`

**Module registration:** Modules are manually registered in [src/manager/plugin.d:59-94](src/manager/plugin.d#L59-L94). Each protocol/router layer is a module.

#### 5. Hierarchical Data Model: Device → Component → Element

OpenWatt represents equipment data in a three-level hierarchy:

```
Device (e.g., "inverter")
  ├─ Component (e.g., "battery")
  │    ├─ Element (e.g., "voltage" = 52.3V)
  │    ├─ Element (e.g., "current" = 15.2A)
  │    └─ Component (nested)
  └─ Component (e.g., "meter")
       └─ Element (...)
```

- **Device**: Top-level equipment object, extends Component
- **Component**: Logical grouping of data, supports nesting
- **Element**: Leaf data point with `Variant latest` value and timestamp

**Navigation:** Dot-notation lookup: `device.find_component("battery.voltage")` traverses the hierarchy.

**Subscribers:** Elements notify subscribers on value changes, enabling event-driven logic.

**Code locations:**
- [src/manager/device.d](src/manager/device.d) - Device class
- [src/manager/component.d](src/manager/component.d) - Component hierarchy
- [src/manager/element.d](src/manager/element.d) - Element data points

#### 6. Protocol-Agnostic Packet Routing

The router layer abstracts all protocols into a unified packet format for routing:

```
[Ethernet Header] [OpenWatt Header] [Protocol Data]
```

**BaseInterface** is the unified abstraction. All protocols (Modbus RTU/TCP, CAN, Ethernet, Tesla TWC) implement this interface.

**Key patterns:**
- **Packet normalization**: Protocols convert frames to common format
- **Sequence correlation**: Requests tagged with sequence numbers to match responses
- **Bridge interfaces**: Transparently relay packets between interfaces (e.g., Modbus bridge between two serial links)
- **Address translation**: Interfaces map local addresses to universal addressing

**Example:** ModbusInterface handles RTU/TCP/ASCII framing, validates CRC, correlates requests/responses by sequence number, and translates between local Modbus addresses and universal addressing.

See [src/router/iface/modbus.d](src/router/iface/modbus.d) (1143 lines) for comprehensive protocol interface example.

#### 7. Sampler System: Smart Data Collection

Samplers periodically read data from devices and update Elements. Key features:

- **Smart batching**: Groups adjacent registers, respects protocol limits (e.g., Modbus 128-register max)
- **Gap threshold**: Skips gaps >16 registers to optimize requests
- **Adaptive sampling**: Frequencies: Realtime (400ms), High (1s), Medium (10s), Low (60s), Constant (once)
- **Type-aware decoding**: Supports U8/S8/U16/S16/U32/F32/U64/F64 with 4 endian combinations
- **Closed-loop**: Samplers implement Subscriber pattern, get notified of element changes

**Data flow:**
1. Sampler sends batched read request to protocol client
2. Protocol client submits to interface with callback handler
3. Interface transmits packet, correlates response by sequence number
4. Response invokes callback with data
5. Sampler decodes registers and updates Elements
6. Elements notify subscribers of value changes

See [src/protocol/modbus/sampler.d](src/protocol/modbus/sampler.d) (557 lines) for implementation.

### Layer Details

#### Manager Layer (src/manager/)

Core runtime providing:
- **Application**: Main loop running at configurable Hz (default 20Hz)
- **Console**: Command-line interface with hierarchical scopes
- **Collection**: Type-safe runtime object management
- **Device/Component/Element**: Hierarchical data model
- **Plugin/Module**: Extensibility mechanism

**Entry point:** [src/main.d](src/main.d) - Creates Application, loads `conf/startup.conf`, runs main loop

#### Router Layer (src/router/)

Network routing infrastructure:
- **Interfaces** (`router/iface/`): Packet interfaces (Ethernet, CAN, Modbus, Tesla, Bridge)
- **Streams** (`router/stream/`): Byte streams (TCP, UDP, Serial, Bridge, WebSocket)
- **Ports** (`router/port/`): Low-level hardware (serial ports)

#### Protocol Layer (src/protocol/)

Protocol implementations:
- **Modbus** (RTU/TCP/ASCII): Client, sampler, profile-based device discovery
- **MQTT**: Client and broker
- **HTTP/WebSocket**: Client and server (HTTPS WIP, needs TLS)
- **Zigbee**: EZSP driver, coordinator, ZCL/ZDO/APS layers
- **Others**: DNS/mDNS, Telnet, PPP, Tesla TWC, SNMP (planned)

Each protocol typically provides:
- Client/Server implementations
- Integration with interface layer
- Samplers for data collection

#### Apps Layer (src/apps/)

High-level application logic:
- **Energy management** (`apps/energy/`): Circuits, meters, appliances
- Future: Automation engine with event bindings

## Development Practices

### Language & Tooling

**Language:** D programming language (dlang.org)
- Modern systems language with C/C++ interop
- Compile-time metaprogramming for zero-cost abstractions
- Supports DMD (fast compilation), LDC (best optimization), GDC

**Embedded focus:** Code must work on microcontrollers, so:
- Use `@nogc nothrow` attributes wherever possible
- Minimize allocations (allocations should be deliberate and infrequent)
- Avoid D standard library (Phobos) - use uRT runtime instead

### Coding Style

Follow these conventions (from [CONTRIBUTING.md](CONTRIBUTING.md)):

**Naming:**
- Types (class, struct, enum): `PascalCase`
- Functions, variables, enum members: `snake_case`
- Template types: `PascalCase`
- Template values: `snake_case`

**Formatting:**
- Indentation: 4 spaces
- Braces: Allman style, omit for single-line bodies
  ```d
  if (condition)
  {
      // code
  }

  if (simple)
      do_one_thing();
  ```

### Third-Party Dependencies

**uRT (Micro Runtime):** Located in `third_party/urt/`, this is a custom D runtime providing:
- `@nogc` containers: Array, Map
- String utilities with deduplication
- I/O abstractions (streams, files)
- Async primitives
- Time/system utilities
- Memory allocators

uRT replaces the D standard library to enable embedded targets without OS dependencies.

### Configuration Files

- **Runtime config**: `conf/startup.conf` - Console command script executed at startup
- **Modbus profiles**: `conf/modbus_profiles/` (referenced in README but may use different paths)
- **No static config format**: Everything is console commands

### Testing

Unit tests are embedded in source files using D's `unittest` blocks. Build with `CONFIG=unittest` and run the test binary.

### Important Files & Directories

**Critical files to understand:**
- [src/main.d](src/main.d) - Entry point, main loop
- [src/manager/package.d](src/manager/package.d) - Application class
- [src/manager/base.d](src/manager/base.d) - BaseObject state machine (740 lines)
- [src/manager/collection.d](src/manager/collection.d) - Collection system
- [src/manager/plugin.d](src/manager/plugin.d) - Module registration
- [src/manager/console/console.d](src/manager/console/console.d) - Console dispatcher

**Example implementations:**
- [src/router/iface/modbus.d](src/router/iface/modbus.d) - Protocol interface (1143 lines)
- [src/protocol/modbus/sampler.d](src/protocol/modbus/sampler.d) - Sampler implementation (557 lines)
- [src/protocol/modbus/client.d](src/protocol/modbus/client.d) - Protocol client

**Documentation:**
- [docs/OVERVIEW.md](docs/OVERVIEW.md) - Detailed system overview
- [docs/CLI.md](docs/CLI.md) - Console command structure
- [docs/FEATURES.md](docs/FEATURES.md) - Feature roadmap

## Common Development Tasks

### Adding a New Protocol

1. Create module in `src/protocol/yourprotocol/`
2. Implement client/server classes inheriting from appropriate base
3. Create Module class with `DeclareModule!("yourprotocol")`
4. Register collections in `init()`
5. Add to [src/manager/plugin.d](src/manager/plugin.d) module registration
6. If needed, create corresponding interface in `src/router/iface/`

### Adding a New Device Type

1. Create modbus profile in appropriate location (or use other protocol)
2. Implement Sampler for the protocol if needed
3. Register device type in energy app or create new app module
4. Add console commands to create device instances

### Debugging Tips

- Use `writeDebug()`, `writeInfo()`, `writeWarning()` from `urt.log`
- Enable state machine debugging in [src/manager/base.d:21](src/manager/base.d#L21) by uncommenting `version = DebugStateFlow;`
- Set `enum DebugType = "type_name"` to debug specific type
- Console commands execute synchronously - use `/device/print` to inspect runtime state
- PCAP logging available for packet capture/analysis

## Recent Development

Current branch: `zigbee`
- Implementing ZigbeeController for managing Zigbee device networks
- EZSP driver communication working
- Recent additions: WebSocket support, TLS stream (for HTTPS)
