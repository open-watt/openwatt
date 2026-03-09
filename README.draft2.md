# OpenWatt

The space between "expensive German proprietary gateway" and "bodge it together with Node-RED and hope" is enormous. Thousands of sites — solar farms, commercial buildings, agricultural operations, small manufacturing — need to integrate a handful of protocols and can't justify a six-figure SCADA deployment. They either overpay for vendor lock-in or underpay for something fragile.

OpenWatt sits in that gap. It's three things:

**[A protocol router](#protocol-router)** that does for industrial and IoT communications what a managed switch does for Ethernet. Modbus, Zigbee, CAN, MQTT — routable, bridgeable, with VLANs, QoS, and packet capture. Not a protocol translator. An actual router.

**[An energy manager](#energy-management)** that models your site as a tree of circuits and appliances — matching how it's actually wired, so it can optimise energy use within the limits of what's physically safe. Breaker ratings, narrow links between buildings, sub-panels — optimisation and protection enforced at every circuit boundary. Works with any hardware that speaks a supported protocol.

**[An embedded platform](#embedded-platform)** that compiles to x86, ARM64, ESP32, STM32, and RISC-V from the same codebase. A full peer node — CLI, web server, protocol routing — on a $5 board. No coordinator required; nodes mesh on their own.

Each layer stands alone. The protocol router doesn't need the energy manager. The energy manager doesn't care which protocols feed it. The embedded platform runs any combination of the above. But they're designed to compose.

It is not a collection of loosely-coupled integrations held together by configuration files and a prayer. The protocols share a common packet abstraction, a common data model, and a common management interface. When something goes wrong, you can see the actual packets on the wire — not an entity that's "unavailable" for reasons it declines to share.

You configure OpenWatt through a live command-line interface — the same operational model used by MikroTik RouterOS and Cisco IOS. Shell in, inspect state, reconfigure at runtime, realtime packet capture off the wire. The system is designed to be operated, not just installed and hoped for the best. If you've ever configured a VLAN on a MikroTik, you already know how to use this. If you haven't, it's the kind of CLI that makes you wonder why everything else uses YAML.

---

## Protocol Router

Most IoT gateways treat each protocol as an isolated adapter — a Modbus plugin here, a Zigbee plugin there, connected by internal glue. OpenWatt treats industrial protocols as routable traffic. Every protocol gets a packet interface that participates in L2 switching: VLAN tagging, 802.1p priority scheduling, MAC learning, bridging.

A Modbus serial link is a switch port. A CAN bus is a switch port. A Zigbee radio is a switch port. They have PVIDs. They participate in VLANs. Bridge a Modbus interface and a CAN interface, and packets route between them. Add an Ethernet interface to the bridge, and non-Ethernet protocols wrap in custom L2 frames and distribute across the broadcast domain.

This isn't a feature anyone would think to ask for. But once you have it, it solves a class of industrial networking problems that people usually solve with expensive proprietary gateways or don't solve at all.

### What this looks like

A `startup.conf` that bridges a solar inverter's Modbus link to a distant energy meter, and snooping the traffic to passively sampling data without disrupting the appliances natural communications:

```
# Connect to an RS485/Ethernet bridge
/stream/tcp-client
add name=inverter_link remote=192.168.3.10:8000
add name=meter_link remote=192.168.3.20:8001

# Create Modbus packet interfaces from the serial streams
/interface/modbus
add name=inverter stream=inverter_link protocol=rtu
add name=meter stream=meter_link protocol=rtu master=true

# Bridge the two interfaces — relay traffic transparently
/interface/bridge add name=modbus_bridge
/interface/bridge/port
add bridge=modbus_bridge interface=inverter
add bridge=modbus_bridge interface=meter

# Register the existence of a device on the meter bus, with a protocol profile for sampling its data
/interface/modbus/remote-server
add name=grid_meter interface=meter address=2 profile=sdm120

# Create a modbus protocol client and configure it to snoop the inverter's commucations with the meter
/protocol/modbus/client add name=mb interface=inverter snoop=true

# Finally, create a 'device' bound to grid_meter, which will sample data informed by its profile
/protocol/modbus/device add id=grid_meter client=mb slave=grid_meter
```

This creates a transparent Modbus bridge between 2 distant nodes where no physical modbus link was in place, while simultaneously sampling energy data from the appliances existing communications — solving the common problem where a single-master bus can't serve multiple readers, and crucially, not interfering with the apliances natural operation, which may introduce unreliability into the system. If you've dealt with problems like this before, you know. If you haven't, count yourself lucky.

A Zigbee setup follows the same shape — create a bitstream to the radio hardware, create an interface to turn that bitstream into a routable packet natwork, add a coordinator to the zigbee network, devices are discovered and interviewed automatically. CAN, Tesla TWC, ESPHome — same patterns, different protocol.

### Why it matters

**You can see the wire.** Capture packets off any interface, stream them to Wireshark in real time. When a Modbus device stops responding, you don't stare at a log that says "timeout" — you see whether the request went out, whether the CRC was valid, whether the response came back malformed. This is how network engineers debug problems. It's how industrial protocol problems should be debugged too.

**QoS across all protocols.** When a user toggles a light switch, that Zigbee command gets Voice priority and jumps the queue ahead of background Modbus register polls to assure responsiveness remains snappy. 802.1p priority classes (PCP/DEI) apply to every protocol, not just Ethernet. This is automatic — user commands, discovery traffic, and housekeeping polls are classified at the interface level.

**Declarative device profiles.** Add support for a new device by writing a profile config — no code changes. A Modbus profile defines register maps; a Zigbee profile maps ZCL clusters; a REST profile describes JSON endpoints. Same format, same tooling, regardless of protocol.

**New protocols are cheap to add.** The packet abstraction and interface model mean a new protocol implementation is a contained piece of work, not a full-stack integration. The Tesla Wall Connector protocol, for instance, was community reverse-engineered and proprietary — but once implemented, it's a first-class participant: routable, bridgeable, with QoS and packet capture. No second-class citizens. Adding it didn't require changes to the router, the bridge, the device model, or the UI. Just the protocol framing and a device profile.

[Architecture deep-dive →](docs/ARCHITECTURE.md) · [CLI Reference →](docs/CLI.md) · [Supported Protocols →](#supported-protocols)

---

## Energy Management

The energy manager models your site as a tree of circuits and appliances — matching how it's actually wired, because how it's wired determines what's physically possible.

Consider a property with a 20A link to an outbuilding. That link powers lights, GPOs, and an EVSE. The EVSE alone can draw 32A — more than the link can carry. It can only charge at full rate when the local battery is charged or the sun is shining, because the grid path is the bottleneck. A flat list of "entities" with a global power limit can't express this constraint. The circuit tree can: the 20A link is a node in the hierarchy, and everything downstream is bound by it. The system won't allow the EVSE to pull power that would trip the breaker on that link — even if the main panel has plenty of headroom.

This is the difference between energy management that knows your site and energy management that knows your devices. Devices don't trip breakers. Circuits do.

### What this looks like

```
main (63A, single-phase, metered by grid CT)
├── house (50A)
│   ├── house.backup (50A, metered by inverter)
│   │   ├── GPOs (20A)
│   │   └── Lights (10A)
│   └── shed (50A)
│       └── EVSE — priority 5
├── carport (32A)
│   └── EVSE — priority 5
└── cabin (20A, metered by second inverter)  ← narrow link
    ├── cabin.backup (20A)
    ├── cabin.laundry (20A)
    │   └── Hot water — priority 6
    └── cabin.carport (50A)
        └── EVSE — priority 5  ← can't exceed 20A from grid
```

Limits are enforced independently at every node in the tree. The cabin's EVSE can charge at full rate from the local inverter and battery, but the grid contribution through that 20A link is capped — automatically, based on real-time metering at the circuit boundary. When the main breaker approaches 63A, the water heater (priority 6) sheds before the EVSEs (priority 5), and the EVSEs shed before the house.

### Why it matters

**Safety.** The circuit tree models physical electrical topology — breaker ratings, sub-panel hierarchies, narrow links between buildings. Every sub-circuit enforces its own limit independently. The system won't allow a downstream appliance to overdraw a constrained link, even if the main panel has headroom. This is protection logic, not just scheduling.

**Value.** The same topology awareness that prevents overloads also finds opportunities. An EVSE behind a narrow grid link can still charge at full rate when the local battery and solar can supply it — the system knows the difference between grid power and local generation at each circuit boundary. Use what you're producing before you buy from the grid.

**Reliability.** Works with any hardware that speaks a supported protocol. The meter feeding a circuit can be a Modbus energy meter, an inverter's built-in CT, a Zigbee smart plug, or CT clamps on an ESPHome device. The energy manager doesn't care where the data comes from — it cares what the data means. No single vendor dependency. Add a new meter type with a device profile; it works immediately.

**Cars move.** Cars are appliances with a VIN and a priority. When a car plugs into an EVSE, the system identifies which car it is and applies per-car charging priorities. Two EVSEs, three cars, different priorities — the system handles it.

[Energy management guide →](docs/ENERGY.md) · [Getting started →](docs/GETTING_STARTED.md)

---

## Embedded Platform

The same codebase compiles for x86_64 Linux/Windows, ARM64, router containers, ESP32, STM32, and RISC-V. It carries its own runtime — less an application than a small operating system, self-contained enough to run bare-metal on the kind of hardware currently running Tasmota or ESPHome. Except instead of a sensor node that needs a controller, you get a full OpenWatt peer with its own CLI, web server, and protocol routing. No coordinator required; nodes can mesh on their own.

### Why it matters

**Deploy where the hardware is.** Put a full peer node on a $5 board next to the equipment it manages. Not one fat gateway in a rack — twenty small nodes, each local to its hardware, meshing into a coherent system. Scalable, cheap to deploy incrementally.

**No single point of failure.** The site doesn't go dark because one box died or one cable got cut. Every node is a self-contained peer — if one goes down, others can take over. If a communication link fails, nodes with alternative paths keep operating. One central instance, a handful of distributed nodes, or a fully redundant mesh — the architecture isn't opinionated. The site designer has the agency to build what fits their constraints and improve it over time.

**Define once, use everywhere.** A property defined in D code automatically appears in CLI commands, REST API schemas, web UI editors, and the Android app. The frontends are thin clients — the web UI is static files (vanilla JS, no framework, no build step, no node_modules the size of a small country) that talk directly to OpenWatt instances over their REST API. There is no app server. There is no cloud. (We'd say "serverless" but that word has been ruined.)

The compile-time reflection that makes this work also means no duplicate schemas to maintain. Add a field to a struct, recompile, and it appears in every interface — console, API, web, mobile. Remove it, and it disappears. This is what makes it practical to support dozens of device types without drowning in boilerplate, and it's what makes the thin-client model possible — the frontends don't embed knowledge of every property; they generate UI from metadata at runtime.

[Architecture deep-dive →](docs/ARCHITECTURE.md) · [MikroTik deployment →](docs/MIKROTIK_DEPLOYMENT.md)

---

## Supported Protocols

| Protocol | Status | Capabilities |
|----------|--------|------|
| **Modbus** (RTU/TCP/ASCII) | Stable | Interface, bridge, client, sampler, device profiles |
| **Zigbee** (EZSP) | Beta | Coordinator, node interview, ZCL/ZDO, device profiles |
| **MQTT** | Beta | Client and broker |
| **HTTP/WebSocket** | Stable | Client and server, REST API, ACME certificates |
| **CAN bus** | Stable | Interface, routing, device profiles |
| **Tesla TWC** | Stable | Wall Connector interface and master controller |
| **ESPHome** | Beta | Native API client, device auto-discovery |
| **Telnet** | Stable | Console access |
| **DNS/mDNS** | Alpha | mDNS responder |
| **PCAP** | Stable | Packet capture, remote Wireshark (rpcapd) |

## Quick Start

### Prerequisites

A D compiler — [installation guide](https://dlang.org/install.html). DMD for fast builds, LDC for optimized release builds.

### Build and Run

```bash
git clone https://github.com/open-watt/openwatt.git
cd openwatt
make                    # Debug build with DMD
./bin/x86_64_debug/openwatt --interactive
```

You'll get a live console. Try `/system/sysinfo` or `/device/print`.

For production:

```bash
make COMPILER=ldc CONFIG=release
```

### Deploy to MikroTik RouterOS

```bash
make PLATFORM=routeros CONFIG=release    # ARM64 binary + container
make routeros-tar                        # Export container image
scp openwatt.tar admin@192.168.88.1:/    # Upload to router
```

See [MikroTik Deployment Guide](docs/MIKROTIK_DEPLOYMENT.md) for complete setup.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/ARCHITECTURE.md) | System design, layer model, data flow |
| [Energy Management](docs/ENERGY.md) | Circuit hierarchy, load shedding, appliance configuration |
| [Getting Started](docs/GETTING_STARTED.md) | First setup walkthrough |
| [CLI Reference](docs/CLI.md) | Command structure and examples |
| [Device Profiles](docs/PROFILE_FILE_FORMAT.md) | Profile file format for adding devices |
| [Component Templates](docs/COMPONENT_TEMPLATES.md) | Standard data model templates |
| [MikroTik Deployment](docs/MIKROTIK_DEPLOYMENT.md) | RouterOS container deployment |
| [Contributing](CONTRIBUTING.md) | Development setup and coding style |

## Licensing

This project is dual-licensed:

- **Non-commercial / educational use:** [Mozilla Public License 2.0](LICENSE-MPL-2.0.md)
- **Commercial use:** Separate license required — see [LICENSE.md](LICENSE.md)

## Contributing

Contributions welcome — see the [Contributing Guide](CONTRIBUTING.md) for setup, build options, and coding conventions.

Written in [D](https://dlang.org) — if C++ and Python had a pragmatic child that inherited the good parts of both. Most systems programmers will find it familiar; the compile-time metaprogramming is what makes the reflection system possible without runtime cost.
