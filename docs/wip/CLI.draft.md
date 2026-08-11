# CLI Reference

OpenWatt is configured and operated through a command-line interface. The CLI is not a secondary interface bolted onto a config file system — it *is* the configuration system. Every runtime object is created, modified, and inspected through console commands.

## Accessing the Console

There are three ways to interact with the console:

**Interactive mode** — Local console at startup:
```bash
./bin/x86_64_debug/openwatt --interactive
```

**Telnet** — Remote console session:
```bash
telnet 192.168.1.100 23
```
Requires a Telnet server: `/protocol/telnet/server add name=console port=23`

**Startup script** — `conf/startup.conf` is a sequence of console commands executed at boot. It's the same commands you'd type interactively — there is no separate config file format.

## Command Structure

Commands use hierarchical paths separated by forward slashes:

```
/interface/modbus/add name=inv stream=tcp1 protocol=rtu
```

Breaking this down:
- `/interface/modbus` — the scope (where the command lives)
- `add` — the command
- `name=inv stream=tcp1 protocol=rtu` — named arguments

### Scopes

The console is organized into a tree of scopes. Top-level scopes:

| Scope | Purpose |
|-------|---------|
| `/system` | System settings, logging, cron, sysinfo |
| `/secret` | Authentication credentials |
| `/certificate` | TLS certificate management |
| `/stream` | Byte transports (TCP, serial, UDP, WebSocket) |
| `/interface` | Packet interfaces (Modbus, CAN, Zigbee, bridge) |
| `/protocol` | Protocol clients, servers, brokers, device bindings |
| `/apps` | Application logic (energy management) |
| `/device` | Device data model (read-only — populated by protocols) |
| `/tools` | PCAP capture, diagnostics |

You can navigate into a scope and issue commands relative to it:

```
> /interface/modbus
/interface/modbus> add name=inv stream=tcp1 protocol=rtu
/interface/modbus> add name=meter stream=tcp2 protocol=rtu master=true
/interface/modbus> print
```

Or use absolute paths from anywhere:

```
> /interface/modbus/add name=inv stream=tcp1 protocol=rtu
```

Both forms are equivalent. The startup script typically uses absolute paths for clarity.

### Tab Completion

The console supports tab completion for:
- Scope paths (`/inter<TAB>` → `/interface/`)
- Commands (`/interface/modbus/pr<TAB>` → `/interface/modbus/print`)
- Property names (`name=<TAB>` shows available names)
- Object references (`stream=<TAB>` lists available streams)

### Command History

Standard up/down arrow navigation through previous commands. History persists within a session.

## Auto-Generated Commands

Every Collection (type-safe object container) automatically generates a standard set of commands. When you see a scope like `/interface/modbus` or `/stream/tcp-client`, these commands are available:

### `add`

Create a new managed object:

```
/interface/modbus/add name=inverter stream=tcp1 protocol=rtu
```

The `name` argument is required for most objects and must be unique within the Collection.

### `remove`

Destroy a managed object:

```
/interface/modbus/remove inverter
```

This triggers the object's shutdown lifecycle — resources are released cleanly.

### `get`

Read a single property:

```
> /interface/modbus/get inverter protocol
rtu
```

### `set`

Modify a property at runtime:

```
/interface/modbus/set inverter master=true
```

Some properties trigger a restart of the object (e.g., changing a stream reference). Others take effect immediately.

### `print`

List all objects in the Collection with their current state:

```
> /stream/tcp-client/print
NAME             REMOTE              STATE
meterbox.1       192.168.3.7:8001    running
meterbox.2       192.168.3.7:8002    running
cabin_switch     192.168.1.7:8899    connecting (backoff: 4s)
```

## Property Types

Properties are typed. The console automatically converts string arguments to the appropriate type:

| Type | Syntax | Examples |
|------|--------|---------|
| Boolean | `true`/`false`, `yes`/`no` | `master=true` |
| Integer | Decimal or hex | `address=2`, `id=0x6914` |
| String | Unquoted or quoted | `name=inv`, `name="my inverter"` |
| Duration | Number + unit | `interval=5m`, `timeout=500ms`, `schedule=1h` |
| Enum | Enum member name | `protocol=rtu`, `type=single_phase` |
| Object reference | Object name | `stream=tcp1`, `interface=modbus1` |
| Array | Comma-separated | `certificates=acme,selfsigned` |

Duration units: `ms` (milliseconds), `s` (seconds), `m` (minutes), `h` (hours).

## Common Patterns

### Create a protocol stack

The typical pattern: stream -> interface -> remote device -> protocol node/client -> binding.

```
# Byte transport
/stream/tcp-client add name=tcp1 remote=192.168.3.7:8001

# Protocol framing
/interface/modbus add name=inv stream=tcp1 protocol=rtu

# Known device on the bus
/interface/modbus/remote-server add name=meter interface=inv address=2 profile=sdm120

# Protocol node for request/response handling, then a device binding
/protocol/modbus/node add name=mb interface=inv
/binding/modbus add name=meter device=meter node=mb slave=meter
```

### Bridge two interfaces

```
/interface/bridge add name=br1
/interface/bridge/port add bridge=br1 interface=modbus1
/interface/bridge/port add bridge=br1 interface=modbus2
```

All traffic between the two Modbus interfaces is relayed transparently.

### Scope shorthand in startup.conf

When adding multiple objects to the same collection, enter the scope once:

```
/stream/tcp-client
add name=link1 remote=192.168.3.7:8001
add name=link2 remote=192.168.3.7:8002
add name=link3 remote=192.168.3.7:8003
```

This is equivalent to three separate `/stream/tcp-client/add` commands.

### Inspect runtime state

```
# System info
/system/sysinfo

# All devices and their current values
/device/print

# Specific interface state
/interface/modbus/print

# Stream connection status
/stream/tcp-client/print
```

### Comments

Lines starting with `#` are comments. Used extensively in `startup.conf`:

```
# Configure the meter bus
/stream/tcp-client add name=meter remote=192.168.3.7:8002
```

## Startup Script

`conf/startup.conf` is executed line-by-line at boot. It's imperative — order matters. A stream must exist before an interface can reference it; an interface must exist before a client can use it.

A typical startup script follows this order:

1. System settings (`/system/log-level`, `/system/update-rate`)
2. Authentication (`/secret/add`)
3. Streams (`/stream/tcp-client`, `/stream/serial`)
4. Interfaces (`/interface/modbus`, `/interface/can`, `/interface/zigbee`)
5. Bridges (`/interface/bridge`, `/interface/bridge/port`)
6. Protocol clients/nodes and bindings (`/protocol/modbus/node`, `/binding/modbus`, `/binding/http/client`)
7. Application configuration (`/apps/energy/circuit`, `/apps/energy/appliance`)
8. Servers (`/protocol/http/server`, `/protocol/telnet/server`, `/apps/api`, `/sync/ws-server`)

See `conf/startup.conf` in the repository for a complete real-world example.

## Further Reading

- [Overview](../OVERVIEW.md) — How the console, collections, and reflection system work
- [Device Profiles](../PROFILE_FILE_FORMAT.md) — Profile file format for adding device support
