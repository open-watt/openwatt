# Overview

OpenWatt is an industrial and IoT communications router with a programmable logic layer on top.
At the highest level it implements a network router for a broad range of industrial protocols and
common network standards, and combines that with a hierarchical data model, recording, a rule
engine, and the ability to assemble several nodes into one fleet. It has applications in energy
management, industrial environments, home automation and network monitoring.

Everything is configured at runtime through the [console](CLI.md); there are no configuration
files, only a startup script of console commands.

## Project structure

- **`src/manager`**: the core runtime: application loop, console, collections and the object
  lifecycle, the data model ([DATA_MODEL.md](DATA_MODEL.md)), profiles, recording, and the sync
  channel ([SYNC.md](SYNC.md)) with its peering layer ([PEERING.md](PEERING.md)).
- **`src/router`**: the packet fabric: interfaces, streams and ports.
- **`src/protocol`**: protocol implementations, each contributing some of a packet interface, a
  client or server, and a binding into the data model.
- **`src/apps`**: high-level application logic: energy management ([ENERGY.draft.md](ENERGY.draft.md))
  and the automation engine ([AUTOMATION.md](AUTOMATION.md)).

## Terminology

### Runtime

- **Module**: a unit of functionality registered at build time. Each module registers its
  collections and console commands in `init()`; a module that is not compiled in contributes
  nothing, which is how features gate themselves.
- **Console**: the runtime interface. It provides the [command-line interface](CLI.md) through
  which every object is created, configured and inspected.
- **Session**: one connection to the console, local, over telnet, or over the sync channel.
- **Command**: one operation executable through the console.
- **Collection**: a typed container of runtime objects of one kind (interfaces, streams, bindings,
  peers). A collection automatically gains `add`, `remove`, `set`, `get` and `print` commands.

### Router

- **Stream**: a byte source or sink with no framing of its own: a serial port, a TCP socket, a file.
- **Interface**: a packet interface, whether a hardware port (Ethernet, CAN) or a virtual one that
  frames packets out of a stream (Modbus over serial).
- **Protocol**: an implementation of a communication standard (Modbus, MQTT, HTTP, Zigbee). A
  protocol decodes and encodes what travels over an interface or a stream.

### Data model

- **Device**: the root of everything known about one piece of equipment (an inverter, a battery, a
  sensor). Devices are created from profiles.
- **Component**: a grouping of elements within a device, following the vocabulary in
  [COMPONENT_TEMPLATES.md](COMPONENT_TEMPLATES.md); components nest.
- **Element**: the smallest unit of data, one value with a typed, timestamped series behind it.
- **Profile**: a file describing how a kind of device is read and how its data maps onto the
  standard component templates ([PROFILE_FILE_FORMAT.md](PROFILE_FILE_FORMAT.md)).
- **Binding**: the bridge between a protocol and the data model. A binding instance names the
  device it models and either polls it or reacts to its traffic, writing into elements and
  writing element changes back to the device.
- **Subscriber**: anything notified when an element changes: the recorder, a sync peer, an
  automation, an expression.

### Fleet

- **Sync**: the channel between two nodes carrying objects, the data model, a console, logs and
  clock discipline ([SYNC.md](SYNC.md)).
- **Peering**: how nodes discover each other and assemble into a fleet with an authority and
  members, without being hand-wired ([PEERING.md](PEERING.md)).
- **Automation**: a rule that runs a console script when a signal fires
  ([AUTOMATION.md](AUTOMATION.md)).

## Where to read next

- [CLI.md](CLI.md): the console, startup configuration, and the reference for every command.
- [FEATURES.md](FEATURES.md): current and planned features at a glance.
- [BOARDS.md](BOARDS.md): platform and board build profiles for embedded targets.
- The specifications above, and the design drafts they defer to:
  [SERIES_RESIDENCY.draft.md](SERIES_RESIDENCY.draft.md),
  [PROP_ELEMENTS.draft.md](PROP_ELEMENTS.draft.md),
  [TAPS_AND_TUNNELS.draft.md](TAPS_AND_TUNNELS.draft.md).
- [wip/](wip/) holds per-project working documents, and [TODO.md](../TODO.md) is the single
  accumulator of outstanding work.
