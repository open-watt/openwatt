# AGENTS.md

This file provides guidance to coding agents (Codex, Claude Code, etc.) when working with code in this repository.

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
make                                   # Debug build with DMD (default)
make COMPILER=ldc CONFIG=release       # Release build with LDC (recommended for production)
make clean                             # Clean build artifacts

# Special platform builds
make PLATFORM=routeros CONFIG=release  # MikroTik RouterOS (ARM64 + container)
make PLATFORM=esp32                    # ESP32 embedded target
make PLATFORM=k210                     # K210 RISC-V microcontroller

# Cross-architecture builds (set ARCH directly)
make ARCH=arm64 OS=linux               # Generic ARM64 Linux build
make ARCH=riscv64                      # Generic RISC-V 64-bit build

# Feature-tier builds
make FEATURES=switch                   # L2 packet-fabric only, no IP/protocols/apps
make FEATURES=full                     # Default: full standalone instance
make HEADLESS=1                        # Embedded role: no human shell/web; gates CLI help, prompts, banners
make PLATFORM=bl808 PROCESSOR=e907     # BL808 M0 coprocessor (auto-defaults to switch + headless)

# Testing
make CONFIG=unittest                    # Build with unit tests enabled
./bin/x86_64_unittest/openwatt_test    # Run unit tests (adjust platform as needed)
```

**Build variables:**
- `COMPILER`: `dmd` (default, fast compilation), `ldc` (best optimization), `gdc` - auto-selects LDC for cross-compilation
- `CONFIG`: `debug` (default), `release`, `unittest`
- `PLATFORM`: Auto-detected from host if unspecified. Values: `windows`, `linux`, `routeros`, embedded targets (`esp32`, `k210`, `cortex-a7`, etc.)
- `ARCH`: Target architecture (`x86_64`, `arm64`, `riscv64`, etc.) - auto-detected or set by PLATFORM
- `OS`: Target OS (`windows`, `linux`, `freertos`) - usually auto-detected
- `FEATURES`: `switch` (L2 fabric only) or `full` (default; protocols+apps+devices+tools). `minimal` is deferred. See [features.mk](features.mk).
- `HEADLESS`: `0` (default) or `1`. Orthogonal to FEATURES; strips human-facing CLI affordances. Auto-set with BL808 e907.
- `TINY`: `0`/`1`, set by [third_party/urt/platforms.mk](third_party/urt/platforms.mk) for <~350KB-RAM / <2MB-flash targets. Forces `-Oz` under LDC, strips verbose strings, drops heavy helpers.

**Output directories:**
- Special platforms: `bin/$(PLATFORM)_$(CONFIG)/` (e.g., `bin/routeros_release/`)
- Generic platforms: `bin/$(ARCH)_$(OS)_$(CONFIG)/` (e.g., `bin/arm64_linux_release/`)

Note: output paths don't include `$(FEATURES)`, so switching presets in the same tree currently won't trigger a rebuild — `make clean` between FEATURES changes.

**Special platform: `routeros`**
- Builds statically-linked ARM64 binary for MikroTik RouterOS
- Automatically packages binary into minimal Alpine-based container
- Provides additional targets: `routeros-container`, `routeros-tar`, `routeros-clean`
- Requires Docker or Podman for container builds
- See [docs/MIKROTIK_DEPLOYMENT.md](docs/MIKROTIK_DEPLOYMENT.md) for deployment guide

Windows users can alternatively use Visual Studio or MSBuild with `openwatt.sln`.

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
- [src/manager/console/argument.d](src/manager/console/argument.d) - Argument type conversion for CLI

**Example:** When you register a `Collection!ModbusInterface`, the console automatically creates:
- `/interface/modbus/add` - Create new interface
- `/interface/modbus/remove` - Remove interface
- `/interface/modbus/get` - Get property value
- `/interface/modbus/set` - Set property value
- `/interface/modbus/print` - List all interfaces

**Property type support:** The property system automatically converts CLI arguments to typed properties via `convertVariant()` functions in [src/manager/console/argument.d](src/manager/console/argument.d). Supported types include:
- Primitives: `bool`, integers, floats, strings
- Time types: `Duration` (with unit parsing: "5m", "30s"), `SysTime` (Unix timestamps)
- Complex types: enums, arrays, Collection references (BaseObject, Device, Component, Stream, Interface)
- Custom types can be added by implementing `convertVariant()` function

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

##### ObjectRef and Dependency Management

When a BaseObject holds a reference to another BaseObject (e.g., an interface referencing its stream, or a binding referencing its client), use `ObjectRef!Type` instead of a raw pointer.

`ObjectRef!T` stores a single `CID` — a hash of the target's `(name, type_index)`. Every dereference looks up the CID in the global `CollectionTable`, so the ref tracks the underlying entry rather than caching a pointer:

- **Destruction tombstones the entry**: The CID slot stays, its `value` is nulled. `_ref.get` returns null, `_ref !is null` is false (via `alias get this`).
- **Recreation auto-rebinds**: A new object with the same name and type hashes to the same CID, populating the same slot. The ref points at the new object — no explicit reattach call.

**Offline detection via state subscriptions**: Don't poll `!dependency.running` in `update()` — this misses offline→online bounces between update cycles. Subscribe to `StateSignal.offline` on the dependency and call `restart()` from the handler.

**Subscription lifecycle rule**: Subscribe at the end of `startup()`, unsubscribe in `shutdown()`. Track with an explicit `_subscribed` flag (placed in struct padding). The flag ensures visibly symmetrical bookkeeping — every subscribe has a matching unsubscribe, no no-ops. Property setters unsubscribe and clear the flag when `_subscribed` is true, then store the new reference and `restart()` — startup will re-subscribe. This prevents use-after-free: destruction cycles through shutdown, which unsubscribes before the object is freed.

```d
// Property setter — tear down subscription, swap reference, restart
final void iface(CANInterface value)
{
    if (_iface.get is value)
        return;
    if (_subscribed)
    {
        _iface.unsubscribe(&iface_state_change);
        _iface.unsubscribe(&packet_handler);
        _subscribed = false;
    }
    _iface = value;
    restart();
}

// startup() — subscribe when the dependency is up
override CompletionStatus startup()
{
    CANInterface i = _iface.get;
    if (!i || !i.running)
        return CompletionStatus.continue_;

    i.subscribe(&packet_handler, PacketFilter(...));
    i.subscribe(&iface_state_change);
    _subscribed = true;
    return CompletionStatus.complete;
}

// shutdown() — unsubscribe if subscribed
override CompletionStatus shutdown()
{
    if (_subscribed)
    {
        _iface.unsubscribe(&iface_state_change);
        _iface.unsubscribe(&packet_handler);
        _subscribed = false;
    }
    return super.shutdown();
}

// State-change handler — restart when dependency goes offline
void iface_state_change(ActiveObject, StateSignal signal)
{
    if (signal == StateSignal.offline)
        restart();
}
```

**Key details:**
- `ObjectRef` uses `alias get this`, so `_iface !is null` works naturally and covers both "never set" and "target destroyed/missing" cases — no separate `detached()` check needed at use sites.
- `destroy()` fires `StateSignal.offline` before `StateSignal.destroyed` for running objects, so handling `offline` alone is sufficient.
- `unsubscribe()` is idempotent — safe to call in `shutdown()` even if `startup()` never completed.

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

See [src/protocol/modbus/iface.d](src/protocol/modbus/iface.d) for comprehensive protocol interface example.

#### 7. Binding System: Protocol-to-Data-Model Bridge

Bindings are the bridge between a protocol client/interface and the Device/Component/Element data model. They are top-level `ActiveObject` instances managed by `Collection!ProtocolBinding` — created at runtime via console commands like `/binding/modbus/add` and updated by the manager each frame.

The base hierarchy (`src/manager/binding.d`):
- **`ProtocolBinding`** — abstract base, holds the bound `device` name, creates the Device in `g_app.devices` if missing.
- **`ProfileBinding`** — adds profile loading: `profile_name()` / `model_name()` are overridden by subclasses, `materialise()` resolves the profile basename recursively below the configured profile path and calls `create_device_from_profile()` with an `add_handler` delegate that the subclass uses to wire elements to its sampling/event logic.

Bindings support two operating modes per protocol:
- **Active polling** (Modbus, HTTP): `update()` drives requests; smart batching where applicable. Modbus groups adjacent registers (max 128-register span, max 16-register gap) and assigns PCP priority based on sample frequency.
- **Event-driven** (CAN, MQTT, Zigbee, BLE): subscribe to data source in `startup()`, react to incoming packets / publishes / GATT notifications.

Other features:
- **Adaptive sampling**: Frequencies: Realtime (400ms), High (1s), Medium (10s), Low (60s), Constant (once), OnDemand (never)
- **Type-aware decoding**: protocol profile sections compile the shared descriptor language in [src/manager/sample/spec.d](src/manager/sample/spec.d) into `SampleDesc`; [src/manager/sample/package.d](src/manager/sample/package.d) applies those descriptors to binary and textual records.
- **Bidirectional**: Bindings that implement `Subscriber` (HTTP, MQTT) get notified of element changes for write-back

**Data flow (active polling):**
1. Binding's `update()` checks per-element timing, builds batched read requests
2. Protocol client submits to interface with callback handler
3. Interface transmits packet, correlates response by sequence number
4. Response invokes callback with data
5. Binding decodes via `sample_value()` and calls `element.value()`
6. Elements notify subscribers of value changes

See [src/protocol/modbus/binding.d](src/protocol/modbus/binding.d) for the most thorough implementation.

### Layer Details

#### Manager Layer (src/manager/)

Core runtime providing:
- **Application**: Main loop running at configurable Hz (default 20Hz)
- **Console**: Command-line interface with hierarchical scopes
- **Collection**: Type-safe runtime object management
- **Device/Component/Element**: Hierarchical data model
- **Plugin/Module**: Extensibility mechanism
- **Cron**: Scheduled task execution system

**Entry point:** [src/main.d](src/main.d) - Creates Application, loads `conf/startup.conf`, runs main loop

##### Automation System

An automation runs a `do={...}` action when a signal fires. It is a `Collection` object under `/automation`. Triggers are `on=<uri>,<uri>` signal URIs of the form `[provider:|@]body[?k=v&k=v]` -- e.g. `on="@door.open"` (element change; `@` is the element sentinel), `on="every:5m"`, `on="at:18:00?days=mon,fri"`, `on="when:2027-01-01T00:00:00"`, `on="mqtt:/topic?qos=1"`. URIs containing `?` `=` `@` must be quoted at the CLI (the parser reserves them). An optional `if=<expr>` (a quoted boolean expression) gates the action; a falsey result skips it. The time shorthands `schedule=`/`at=`/`when=` are thin write-only sugar that translate to `every:`/`at:`/`when:` URIs (finer detail like `?days=`/`?repeat=false` lives in the URI, not as sugar). Signals come from `ISignalProvider`s registered on the `Application` (general capability, [src/manager/signal.d](src/manager/signal.d)); the built-ins are the Application itself (the `element:` provider) and cron ([src/manager/cron.d](src/manager/cron.d), the `every:`/`at:`/`when:` time provider -- the former `/system/cron` collection is gone). Example: `/automation/add name=poll schedule=5m do={ /device/print }`. See [src/apps/automation/automation.d](src/apps/automation/automation.d). Not yet built (design in [docs/AUTOMATION.draft.md](docs/AUTOMATION.draft.md)): shaping (debounce/throttle), execution policy, and typed `$trigger.*` context.

#### Router Layer (src/router/)

Network routing infrastructure:
- **Interfaces** (`router/iface/`): Generic L2 packet infrastructure (Ethernet, WiFi, Bridge, VLAN) and shared utilities (Packet, MAC, PriorityQueue, AddressTable). Protocol-specific interfaces (Modbus, CAN, Tesla, Zigbee, BLE) live in `protocol/<name>/iface.d`.
- **Streams** (`router/stream/`): Byte streams (Serial, Bridge, Console, Duplex, File, Memory). IP-dependent streams (TCP, UDP) live in `protocol/ip/`; TLS lives in `protocol/tls/`; WebSocket lives in `protocol/http/`.
- **Ports** (`router/port/`): Low-level hardware (serial ports)

#### Protocol Layer (src/protocol/)

Protocol implementations. Several protocols carry their own packet interface (`iface.d`); these plug into the router fabric the same way the generic L2 interfaces in `router/iface/` do.

**Industrial bus / fieldbus:**
- **Modbus** (`protocol/modbus/`): RTU, TCP and ASCII framing. `iface.d` is the packet interface (CRC, sequence correlation, address translation via [[modbus_server_map_is_arp]]); `client.d` issues requests; `binding.d` bridges to the data model with register batching and adaptive polling; `sunspec.d` decodes SunSpec models; `node.d` / `message.d` are the shared data types. Future direction: [[modbus_l2_l3_split_trajectory]].
- **CAN** (`protocol/can/`): CAN bus packet interface plus event-driven binding.
- **Tesla** (`protocol/tesla/`): TWC (Tesla Wall Connector) master/slave. `iface.d` framing, `master.d` heartbeat round-robin, `binding.d` direct value push, `twc.d` device model. (Tesla *vehicle* BLE lives under `protocol/ble/` — see [[tesla_ble_architecture]].)
- **GoodWe** (`protocol/goodwe/`): AA55 vendor protocol decoder + binding.

**Wireless / radio:**
- **Zigbee** (`protocol/zigbee/`): full stack — `iface.d` packet interface, `aps.d` APS layer, `coordinator.d` network formation / security / join handling, `router.d` ZDO base, `controller.d` async node-interview loop, `client.d` runtime Node/Endpoint objects, `zcl.d` / `zdo.d` cluster and discovery handling.
- **EZSP** (`protocol/ezsp/`): EmberZNet Serial Protocol driver — `client.d` command queue, `ashv2.d` ASHv2 framing over serial (BaseInterface), `commands.d` command definitions. Consumed by Zigbee, not used standalone.
- **BLE** (`protocol/ble/`): Bluetooth LE link layer as a packet interface, advert dispatch, client/device objects. Tesla vehicle session logic also lives here (see [[tesla_ble_architecture]]).

**IP stack and transports:**
- **IP** (`protocol/ip/`): in-tree IPv4/IPv6 stack — `stack.d`, `address.d`, `route.d`, `arp.d`, `neighbour.d`, `icmp.d`, `firewall.d`, `pool.d`, `socket.d`. `tcp.d` / `udp.d` are the transports; `tcp_stream.d` / `udp_stream.d` expose them as router Streams. `client.d` is the `IPClient` helper used by protocols that need a TCP (or, when TLS is built, TLS-over-TCP) outbound connection.
- **TLS** (`protocol/tls/`): `certificate.d` for cert management, `stream.d` wraps any byte stream as a TLSStream. Fully gated by the `has_tls` feature flag — protocols that opt-in (HTTP, IPClient) gracefully degrade when TLS is compiled out.
- **DHCP** (`protocol/dhcp/`): client + server, lease store, option codec, message decoder.
- **DNS** (`protocol/dns/`): server (mDNS-capable) + message codec.
- **PPP** (`protocol/ppp/`): client and server.

**Application protocols:**
- **HTTP** (`protocol/http/`): client and server (`server.d` self-adapts to HTTPS when `has_tls`), HTTP message codec, WebSocket (`websocket.d`), and an HTTP-polling `binding.d`.
- **MQTT** (`protocol/mqtt/`): client, full broker (`broker.d` + `session.d` + `topic.d`), wire codec, connection state machine, `binding.d` for topic-driven Element bindings.
- **Telnet** (`protocol/telnet/`): client, server (spawns console sessions), and a `stream.d` wrapper that handles IAC sequences and terminal channel negotiation.
- **SNMP** (`protocol/snmp/`): agent + MIB tree; exposes Device/Component/Element values as OIDs and accepts SET writes on managed properties.
- **ESPHome** (`protocol/esphome/`): native API client (proto file + binding) for ESPHome devices.

Each protocol typically provides some subset of:
- Packet interface (`iface.d`) for protocols that route packets
- Client and/or Server objects (BaseObject-managed, Collection-registered)
- A Binding (`binding.d`) that bridges the protocol to the Device/Component/Element data model
- Codec / message types shared between client and server

#### Apps Layer (src/apps/)

High-level application logic:
- **Energy management** (`apps/energy/`): Circuits, meters, appliances
- Future: Automation engine with event bindings

## Development Practices

### Debugging & Root Cause Analysis

**Never apply speculative fixes.** When investigating a bug:
- Understand the FULL causal chain before writing any code. If the root cause isn't clear, say so — discuss the structural issues and what evidence is still needed rather than guessing.
- Symptoms like invalid states, assertion failures, or unexpected values are signals to trace deeper, not to patch over. Ask: "why is this value wrong?" not "how can I handle this value?"
- If you're not confident in a fix, explicitly state your uncertainty and present it as a hypothesis for discussion, not as a code change.
- A fix that doesn't address the root cause is worse than no fix — it hides the real bug and creates false confidence.
- Never take the easy path. When a structural issue is identified, address it directly — don't work around it with guards, special cases, or compatibility shims. Early structural fixes prevent compounding debt.

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
- Increment operators: Prefer prefix (`++i`) over postfix (`i++`) where semantically equivalent
- Comments: Avoid self-explanatory comments. *Only* add comments that explain WHY or provide context the code doesn't make obvious. Remove grouping comments like "// Schedule configuration" or "// Update counters" where the code is clear. You don't need function headers unless there's something surprising about the calling environment or the arguments/results. No need to narrate code (the code should do that itself!), function named and argument names should be obvious wherever possible.
- Code is always ascii; only unicode inside string literals or where unicode is to be expected.
- NO EM-DASH EVER.

**Import order:**
- uRT imports first (e.g., `import urt.string;`, `import urt.time;`)
- Manager imports second (e.g., `import manager.base;`)
- Other imports follow

**Code organization:**
- Header is `module ...;`\n [imports]\n `version = DebugXXX;`\n `nothrow @nogc:`\n\n [public module stuff]...
- Public API (properties, overrides) at top of class/module
- `protected:` section at middle (of classes)
- `package:` between protected/private, ONLY if it's absolutely needed, this should be rare!
- `unittest { ... }` - place module-scale tests at the bottom of the file so they do not interrupt the implementation's reading flow. Inline tests are only for small tests of a specific function and may sit directly below that function. Prefer one module-scale test block over several scattered blocks.
- `private:` section at bottom of class/module for private members and helper methods
- DO ALWAYS move code around and keep the file in good logical flow order while refactoring. Once flow degrades, it's impossible to know where to add new code anymore, so it's important to maintain!

**Platform/version conditionals:**
- Keep one definition of each function and struct. Put `version` blocks *inside* at the exact point of divergence -- never duplicate the entire function or struct across version blocks.
- When a version flag is needed in multiple places within a function, compute it once as an `enum` at the top (e.g. `version (X) enum hw = true; else enum hw = false;`) and branch with `static if`.
- Declare local `version` identifiers (e.g. `version = Foo;`) at the top of a `version` block to create derived flags that simplify downstream conditionals.

**Property patterns:**
- **Mutually exclusive properties**: Later-set properties overwrite state of earlier ones. Don't validate mutual exclusion; instead, have each property setter update internal state to indicate which option is active.
  ```d
  // Example: schedule property overwrites previous schedule type
  void schedule(Duration value)
  {
      _schedule = value;
      _schedule_type = ScheduleType.Duration;  // Track which type is set
      restart();
  }
  ```
- **Property validation**: Check configuration validity in `validate()`, not in setters (allows partial configuration during construction)

**Command lifecycle patterns:**
- **Latent commands**: Commands may return `CommandState` for async operations. Track these and call `update()` to poll progress.
- **Command cancellation**: Use `command.request_cancel()` to request cancellation (safe to call repeatedly - only transitions from `InProgress` state). During `shutdown()`, request cancellation for all commands, then return `CompletionStatus.Continue` to wait for them to finish. The state machine calls `shutdown()` repeatedly while in `State.Stopping`, NOT `update()`.
  ```d
  override CompletionStatus shutdown()
  {
      foreach (ref cmd; _running_commands)
          cmd.command.request_cancel();

      update_running_commands();  // Clean up finished commands

      if (_running_commands.length > 0)
          return CompletionStatus.Continue;

      return CompletionStatus.Complete;
  }
  ```

### Third-Party Dependencies

**uRT (Micro Runtime):** Located in `third_party/urt/`, this is a custom D runtime providing:
- `@nogc` containers: Array, Map, String, MutableString
- Lots of string and array utilities
- I/O abstractions and drivers (streams, files)
- Async primitives
- Time/system utilities
- Memory allocators

uRT replaces the D standard library to enable embedded targets without OS dependencies.


### Important Files & Directories

**Critical files to understand:**
- [src/main.d](src/main.d) - Entry point, main loop
- [src/manager/package.d](src/manager/package.d) - Application class
- [src/manager/base.d](src/manager/base.d) - BaseObject state machine (740 lines)
- [src/manager/collection.d](src/manager/collection.d) - Collection system
- [src/manager/plugin.d](src/manager/plugin.d) - Module registration
- [src/manager/console/console.d](src/manager/console/console.d) - Console dispatcher

**Example implementations:**
- [src/protocol/modbus/iface.d](src/protocol/modbus/iface.d) - Protocol interface
- [src/protocol/modbus/binding.d](src/protocol/modbus/binding.d) - Binding implementation
- [src/protocol/modbus/client.d](src/protocol/modbus/client.d) - Protocol client

**Documentation:**
- [docs/OVERVIEW.md](docs/OVERVIEW.md) - Detailed system overview
- [docs/CLI.md](docs/CLI.md) - Console command structure
- [docs/FEATURES.md](docs/FEATURES.md) - Feature roadmap

### Testing

OpenWatt has two types of tests:

**1. Unit Tests (D `unittest` blocks)** - For testing individual functions and data structures
```bash
rm -rf obj bin && make CONFIG=unittest && ./bin/x86_64_unittest/openwatt_test 2>&1 | grep "passed"
```

**2. Runtime Tests (Python test harness in `test/`)** - For testing the full application

The test harness provides **3 core capabilities**:

1. **Quick Test** - Fast one-off commands
   ```bash
   # Default: /system/sysinfo (always works, environment-independent)
   python test/test_runner.py

   # Custom commands
   python test/test_runner.py "/device/print"
   ```

2. **JSON Test Suite** - Sequential commands with assertions
   ```bash
   python test/test_harness.py --suite test_suite.json
   ```

3. **Persistent REPL** - Interactive investigation (recommended for Claude)
   ```bash
   # Start background REPL with named pipe (cross-platform)
   # Binary: bin/x86_64_debug/openwatt (Linux) or openwatt.exe (Windows)
   BINARY="bin/x86_64_debug/openwatt$([ "$(uname -s | grep -i mingw)" ] && echo .exe)"
   mkfifo /tmp/ow_stdin
   tail -f /tmp/ow_stdin | $BINARY --interactive > /tmp/ow_stdout.txt 2> /tmp/ow_stderr.txt &

   # Send commands and analyze responses
   echo "/system/sysinfo" > /tmp/ow_stdin
   tail -10 /tmp/ow_stdout.txt

   echo "/device/print" > /tmp/ow_stdin
   tail -50 /tmp/ow_stdout.txt

   # Check logs separately
   tail -20 /tmp/ow_stderr.txt | grep -i error
   ```

The REPL method enables true interactive investigation: send a command, analyze the output, think about next steps, send another command to the SAME persistent OpenWatt session.

**See:** [test/README.md](test/README.md) for complete documentation

## Common Development Tasks

### Adding a New Protocol

1. Create module in `src/protocol/yourprotocol/`
2. Implement client/server classes inheriting from appropriate base
3. Create Module class with `DeclareModule!("yourprotocol")`
4. Register collections in `init()`
5. Add to [src/manager/plugin.d](src/manager/plugin.d) module registration
6. If needed, create corresponding interface in `src/router/iface/`

### Adding a New Device Type

1. Create a profile in the `conf/profiles` submodule's appropriate directory (e.g. `modbus_profiles/`, `rest_profiles/`)
2. If the protocol doesn't yet have a Binding, implement one (subclass `ProfileBinding` or `ProtocolBinding`)
3. Register the binding's Collection in the protocol's Module `init()`
4. The user creates an instance at runtime: `/binding/<proto>/add name=... device=... profile=... ...`

### Debugging Tips

- Use `writeDebug()`, `writeInfo()`, `writeWarning()` from `urt.log`
- Enable state machine debugging in [src/manager/base.d:21](src/manager/base.d#L21) by uncommenting `version = DebugStateFlow;`
- Set `enum DebugType = "type_name"` to debug specific type
- Console commands execute synchronously - use `/device/print` to inspect runtime state
- PCAP logging available for packet capture/analysis

## Remember...

And remember,
- NO GRATUITOUS COMMENTING! (see above)
- NO EM-DASH EVER!
- No unicode in source files unless it's string data that's meant to contain unicode.
- Line-breaks at col 120 is fine, no need to break at 80! Use good taste, avoid gratuitous line breaking!
