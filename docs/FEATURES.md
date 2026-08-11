# Feature Set

Current and planned features at a glance. Status vocabulary: **Working** (in production use),
**Beta** (complete, still hardening), **Alpha** (usable, incomplete), **WIP** (in active build, may
be on a branch), **Planned** (designed, not started). Design detail lives in the documents linked
from the [README](../README.md); outstanding work is in [TODO.md](../TODO.md).

## Core

| Feature | Status | Notes |
| --- | --- | --- |
| Runtime console configuration | Working | Everything is created and configured through console commands; `startup.conf` is a script, not a config file. Local, telnet, and over the sync channel. |
| Modular architecture | Working | Modules register collections and commands at build time; a module that is not compiled in contributes nothing, so features gate themselves. Build tiers `switch`, `switch-ip`, `switch-http`, `switch-https`, `full`, plus `HEADLESS` and `TINY` axes. |
| Custom runtime (uRT) | Working | `@nogc nothrow` throughout; no Phobos, no druntime, no exceptions. One tree builds desktop and microcontroller targets. |
| Event-driven core | Working | Reactor-driven I/O on every platform; no polling. Timers, completion callbacks and state signals drive all work. |
| Data model | Working | Device, component and element tree with a typed, timestamped series behind every element. See [DATA_MODEL.md](DATA_MODEL.md). |
| Device profiles | Working | Declarative profiles map a device's registers, topics, attributes or endpoints onto standard component templates. Profiles live in their own repository (`conf/profiles`). |
| Recording | Working | Opt-in per-element history in RAM and on disk (`.ows` containers), retention budgets, backfill and time-range queries. Retention and recording intent in profiles is Planned. |
| Logging | Working | Structured log with sinks (`/log/sink`), log history, and log delegation over sync so a fleet's logs converge on its authority. |
| Expression engine | Working | Unit-aware expressions over elements, shared by conditions, energy policy and computed elements. |
| Sync channel | Working | Object mirror, data-model plane, console, logs and clock discipline between nodes over UDP (IP or bare MAC) and WebSocket, JSON or binary. See [SYNC.md](SYNC.md). |
| Fleet peering | Working | Discovery, claims, trust-on-first-use adoption, dual-authority. Election between authorities is Planned. See [PEERING.md](PEERING.md). |
| OTA update | Working | Linux and ESP32 images over HTTP, with boot guard and factory-reset provisioning fallback on embedded targets. |
| Secret store | Working | Persistent secrets and keys (fleet key, TLS material, EC P-256). |
| PCAP / remote Wireshark | Working | Packet capture to file and an rpcapd-compatible server for live Wireshark. |
| Watchdog and crash reporting | Working | Main-loop watchdog on every platform; ESP32 core dumps; reset-reason reporting. |
| Runtime plugin loading | Planned | Modules are compiled in. Finer per-subsystem build modules are designed ([wip/MODULES.draft.md](wip/MODULES.draft.md)); runtime loading is not. |

## Interfaces

| Feature | Status | Notes |
| --- | --- | --- |
| Console (CLI) | Working | Tab completion, history, live views, scripting, remote sessions. See [CLI.md](CLI.md). |
| Web app | Beta | `openwatt-web`, a separate repository. A sync consumer over WebSocket: device tree, graphs, configuration. Client-visible changes are tracked in [wip/UX_TODO.md](wip/UX_TODO.md). |
| Android app | Beta | `openwatt-droid`, a separate repository. Same sync consumer model as the web app. |
| HTTP JSON API | Working | `/api` for get, set, list and console execution; used by the clients and by integrations. |
| Static file server | Working | Mounts with streamed GET and PUT, DELETE, opt-in CORS; serves the web app and edits config files in place. |
| SNMP agent | Working | Exposes the device tree as a MIB and accepts SET on managed properties. |
| Telnet | Working | Console sessions, client, and a raw stream with IAC handling. |

## Networking

| Feature | Status | Notes |
| --- | --- | --- |
| Ethernet | Working | Linux raw sockets, Windows (npcap), ESP32; OpenWatt ethertype encapsulation for exotic packets over ethernet. |
| WiFi | Working | Station and access point on Linux (nl80211), Windows (station), ESP32 (station and AP). Link speed and PHY mode reported. Beken BK7231 station is WIP. |
| Bridge, VLAN, interface groups | Working | L2 bridging with an address table, 802.1Q VLANs with priority flow, interface groups. |
| 802.1ag CFM | Working | Unicast loopback ping against third-party gear and a broadcast discovery sweep of OpenWatt stations. |
| UDP packet interface | Working | Unicast and multi-drop, over IP or a bare MAC (`[mac]:port`), so IP-less builds carry sync and discovery. |
| IP stack (IPv4 and IPv6) | Working | In-tree stack: addresses, routes, ARP and ND, ICMP and ICMPv6, IGMP and MLD membership, address pools, firewall, transit forwarding (`GATEWAY=1`), Linux mirroring. `IPV6=0` builds without the v6 half. |
| TCP and UDP streams | Working | Client and server endpoints on the in-tree stack. |
| DHCP | Working | IPv4 client and server with a lease store. DHCPv6 message codec is built; the v6 client and server are WIP. |
| DNS | Alpha | Listeners and message codec on master; the server, resolver, cache and DNS-over-HTTPS endpoint are built on the `ow/dns` branch, unmerged. |
| NTP | Working | Time sync client; peer clock discipline over sync for nodes without NTP. |
| TLS | Working | Windows/mbedTLS-backed streams, certificates, HTTPS server and client. |
| WebSocket | Working | Server, used by the sync channel and the web app. |
| PPP | Working | Client and server. |
| IGMP and DHCP snooping | WIP | Bridge snooping is built on a branch; host membership is on master. |

## Protocols and buses

| Feature | Status | Notes |
| --- | --- | --- |
| Modbus | Working | RTU, TCP and ASCII framing; packet interface with sequence correlation and address translation; transparent bridges between links; batched adaptive-rate binding; SunSpec model decoding. |
| CAN | Working | Packet interface and event-driven binding. |
| Zigbee | Working | Full coordinator over EZSP/ASHv2: network formation, security, joining, node interviews, ZCL and ZDO, sleepy-device wake, Tuya datapoints, device publication into the data model. |
| Thread / 802.15.4 | WIP | Spinel over CPC to an RCP; CPC transport over UART is Working, Spinel bring-up is in progress. |
| Bluetooth LE | Working | Central role on Linux, Windows and ESP32: scanning, GATT, adverts routed as packets, a serial stream over GATT, device bindings. Peripheral role is Planned. |
| Tesla vehicle (BLE) | Working | Vehicle session with key enrolment, signed commands, state and SOC live on a running fleet. |
| Tesla Wall Connector | Working | TWC2 RS485 packet interface, master with slave auto-discovery, charging control. |
| OBD-II | Working | Over an ELM327 BLE dongle; vehicle state binding. |
| MQTT | Working | Client, full broker with sessions and topic trees, Home Assistant discovery, topic-driven binding. |
| HTTP | Working | Client and server, streaming bodies, REST polling binding. |
| ESPHome | Working | Native API client and binding. |
| GoodWe | Working | AA55 vendor protocol decoder and binding. |
| GPIO and RF433 | Working | Realtime edge sampler (gpio-cdev, pigpiod when present) feeding held series; 433 MHz OOK capture profiles. Transmit is Planned. |
| I2C | Working | Bus interface for board peripherals. |
| USB serial | Working | Port registry with USB vendor, product and path metadata; stable by-path naming. |

## Applications

| Feature | Status | Notes |
| --- | --- | --- |
| Energy management | Beta | Site modelled as circuits, buses, links and appliances; boundary-edge accounting; priority allocator with dwell and surplus tracking; car charging control paired to vehicles; session-derived SOC. See [ENERGY.draft.md](ENERGY.draft.md). |
| Automation | Working | Rules with signal-URI triggers (element, time, object state), expression conditions with edge and hold, debounce, throttle and rate shaping, console-script actions. Execution policy, typed trigger context and more providers are Planned. See [AUTOMATION.md](AUTOMATION.md). |
| Fleet operation | Working | Nodes discover, adopt and mirror each other; a fleet's logs and clocks converge on its authority. |

## Platforms

| Target | Status | Notes |
| --- | --- | --- |
| Linux x86_64, x86, and ARM64 | Working | Raspberry Pi is the reference production host. |
| Windows | Working | npcap for ethernet; primary development host. |
| MikroTik RouterOS | Working | ARM64 container. |
| ESP32 family | Working | esp32, s2, s3, c2, c3, c5, c6, h2, p4 via ESP-IDF; board profiles (`BOARD=`); see [BOARDS.md](BOARDS.md). S3 and C6 are fleet members in production. |
| Waveshare ESP32-S3-RS485-CAN | Working | The reference industrial gateway board: RS485, CAN, RTC, USB console, AP+STA WiFi. `BOARD=waveshare-esp32-s3-rs485-can`; see [BOARDS.md](BOARDS.md). |
| SmartEVSE v3.0 | Beta | In-place replacement firmware for the SmartEVSE: EVSE driver, front panel, RS485, setup AP, stock-firmware return path over OTA. `BOARD=smartevse-v30`; see [BOARDS.md](BOARDS.md). |
| Bouffalo BL808 and BL618 | WIP | Bare-metal D runtime, dual-core IPC, WiFi on the M0 coprocessor. |
| Beken BK7231N/T | WIP | Switch tier; station associates. |
| RP2350, STM32, esp8266 | Alpha | Build targets present; bring-up in progress. |

## Device support

Device support is profile-driven and lives in the `conf/profiles` repository, so this list is
indicative rather than exhaustive.

| Family | Devices |
| --- | --- |
| Inverters and EMS | GoodWe GW-xx48-ES (AA55), GoodWe EMS (Modbus), SolarEdge meter (Modbus) |
| Batteries and BMS | Pylon (CAN), PACE BMS (Modbus) |
| Energy meters | Eastron SDM120, Emporia, GM1000, TAC1100, and generic SunSpec meters |
| EV charging | SmartEVSE (REST, Modbus, native OpenWatt build), Tesla Wall Connector 2, Tesla vehicles over BLE, OBD-II vehicles over ELM327 |
| Sensors | Xiaomi LYWSD03MMC (BLE), PT100 temperature (Modbus), any ZCL or Tuya Zigbee device, ESPHome nodes |
| Switching and lighting | Shelly (Modbus and HA discovery), OpenBeken (MQTT), any Home Assistant discovery device |
