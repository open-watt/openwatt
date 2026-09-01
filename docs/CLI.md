# Command Line Interface (CLI)

The application is configured and controlled through a command-line interface (CLI). The CLI provides a powerful way to interact with the system, manage devices, and configure applications.

## Startup Configuration

The primary configuration file for the system is `conf/startup.conf`. This file is not a simple configuration file, but rather a script that is executed line-by-line at startup. This allows for a flexible and powerful configuration process.

Each line in the `conf/startup.conf` file is a command that is executed by the CLI. This means that you can configure the system by adding, removing, or modifying commands in this file.

## CLI Syntax

The CLI uses a hierarchical command structure. Commands are organized into a tree-like structure, with each level separated by a forward slash (`/`).

For example, the command `/system/log-level level=debug` sets the log level of the system. In this command:
- `system` is the top-level command group.
- `log-level` is a command within the `system` group.
- `level=debug` is an argument to the `log-level` command.

### Command Hierarchy

The CLI is organized into a few top-level categories, each managing a different aspect of the system:

-   `/system`: General system-level commands, such as logging.
-   `/stream`: Manages data streams, which are typically network connections (TCP, WebSocket), serial ports, etc.
-   `/interface`: Configures hardware or logical interfaces, like Modbus, CAN, network bridges, etc.
-   `/protocol`: Manages protocol-specific configuration, such as Modbus clients, MQTT brokers, HTTP servers, etc.
-   `/apps`: High-level application functionality, like the energy management system.

Each of these top-level commands has its own set of sub-commands for more specific configuration.

### Saved Configuration

The running configuration can be saved and restored:

- `/system/config/export`: Prints the running configuration as a script of `add` commands, one per
  explicitly-configured object. Only properties that were explicitly set are emitted; dynamic, temporary,
  and remote (synced) objects are skipped.
- `/system/config/save [file=<path>]`: Writes the same script to a file, `conf/config.conf` by default.

At startup, if `conf/config.conf` exists it is loaded INSTEAD of `conf/startup.conf` (the platform's
`system.conf` and `user.conf` layers still apply). An explicit `--config` on the command line takes
precedence over the saved configuration. Delete `conf/config.conf` to fall back to the startup script.

Secrets are never written in plaintext when hashed: a hashed `/secret` exports its password as a
`hash:<algo>:<salt>:<hash>` literal which reloads directly into the same salt and hash.

Config mutations after boot (any collection `add`/`remove`/`set`/`reset`) mark the running configuration
dirty. `/system/sysinfo` shows this as `Config: modified` or `Config: saved`, and `/system/sysinfo
config-dirty` returns the bare boolean for UX clients polling health; saving to the default path clears it.

### Common Commands

Here are some of the common commands used in the `conf/startup.conf` file:

- `/system/log-level`: Sets the system's log level.
- `/system/profile-path`: Sets the root directory searched recursively for device profiles.
- `/stream/tcp-client`: Configures TCP client streams for connecting to remote devices.
- `/interface/modbus`: Creates and configures Modbus interfaces.
- `/interface/bridge`: Creates bridges between interfaces.
- `/protocol/modbus/client`: Configures Modbus clients for communicating with devices.
- `/apps/energy/appliance`: Configures appliances within the energy management system.
- etc...

## Example Configuration

The following is a hypothetical `startup.conf` file, where we configure ourself as a man-in-the-middle on a typical solar inverter's modbus link to its energy meter, so that we may also sample data from the energy meter directly.

```
# Configure TCP client streams for an RS485/ethernet bridge device with 2 ports
/stream/tcp-client
add name=meterbox.1 remote=192.168.3.7:8001  # to the inverter
add name=meterbox.2 remote=192.168.3.7:8002  # to the energy meter

# Create modbus interfaces on the tcp streams
/interface/modbus
add name=goodwe_inverter stream=meterbox.1 protocol=rtu
add name=goodwe_meter stream=meterbox.2 protocol=rtu master=true

# create a modbus bridge interface to relay traffic between the inverter and its energy meter
/interface/bridge add name=modbus_bridge
# add the 2 modbus interfaces to the bridge
/interface/bridge/port
add bridge=modbus_bridge interface=goodwe_inverter
add bridge=modbus_bridge interface=goodwe_meter

# populate the meter bus interface with a remote device, making the meter known to the application
/interface/modbus/remote-server
add name=gw_meter interface=goodwe_meter address=2 profile=gm1000
```

Configuring the remote server will populate the runtime with a `Device` representing the data sampled from the meter, which can be used by local program logic. This bridge configuration solves the problem where a modbus appliance (the meter) on a single hardware bus can not receive requests from multiple masters.

## CLI Command Reference

This section is the growing, command-by-command reference for the CLI. The
scopes listed here are documented completely. Additional scopes will be added
as the reference expands.

### `/log`

Log calls submit severity, timestamp, hostname, tag, object name, and message as
separate fields. The log router retains each submitted record in a 128-record
delivery queue until every matching registered consumer acknowledges it. The
last acknowledgement makes the record deletable; the history policy may retain
that same structured record beyond delivery.

| Command | Syntax | Description |
| --- | --- | --- |
| `emergency` | `/log/emergency <message>` | Emits an emergency message with the `console` tag. |
| `alert` | `/log/alert <message>` | Emits an alert message with the `console` tag. |
| `critical` | `/log/critical <message>` | Emits a critical message with the `console` tag. |
| `error` | `/log/error <message>` | Emits an error message with the `console` tag. |
| `warning` | `/log/warning <message>` | Emits a warning message with the `console` tag. |
| `notice` | `/log/notice <message>` | Emits a notice message with the `console` tag. |
| `info` | `/log/info <message>` | Emits an informational message with the `console` tag. |
| `debug` | `/log/debug <message>` | Emits a debug message with the `console` tag. |
| `trace` | `/log/trace <message>` | Emits a trace message with the `console` tag. |
| `print` | `/log/print [--stream] [level=<severity>] [tag=<prefix>] [match=<text>] [max=<count>]` | Opens a live log consumer. Defaults to `level=trace` and `max=256`; `max` is capped at 1024. |

`/log/print` is a temporary log consumer. When history is enabled it first
copies matching retained records into its private view, then follows new
records. With history disabled it starts empty and accumulates records from the
moment the command begins. Its bounded records are released when the command
finishes. Formatting happens only while rendering for the attached terminal,
so retained data never contains terminal escape sequences or preformatted
text.

By default the command presents a scrollable live view. `--stream` instead
prints each matching record once as it arrives. It emits no cursor movement,
screen clearing, or status footer, making it suitable as the initial command
for a serial console session. Press `q` or Ctrl+C to stop either mode and return
to the console.

### `/log/history`

In-memory history is the log router's structured retention policy. Matching
records are marked for history retention at ingress; history is not a consumer,
does not require acknowledgement, and never holds delivery open. Eviction or
expiry removes the history retention mark. The record is then deleted if all
deliveries are complete, or after its last outstanding delivery otherwise.

| Command | Syntax | Description |
| --- | --- | --- |
| `get` | `/log/history/get` | Prints the retention policy, retained count, and immediate delivery-queue statistics. |
| `set` | `/log/history/set [max-messages=<count>] [max-age=<duration>] [max-severity=<severity>] [tag=<prefix>]` | Changes only the supplied policy fields. `max-messages` is capped at 1024; zero disables and clears history. `max-age=0s` removes the age limit. |
| `clear` | `/log/history/clear` | Drops retained history without changing its policy. |

The default policy is `max-messages=1024`, no age limit,
`max-severity=info`, and no tag restriction. Tightening the severity, tag, age,
or count policy immediately evicts records that no longer match.

### Collection commands

The scopes in this section are managed collections. They all expose the same
seven commands:

| Command | Syntax | Effect |
| --- | --- | --- |
| `add` | `<scope>/add [name=<name>] [<property>=<value> ...]` | Creates an item and applies the supplied properties. The name is generated when omitted. |
| `get` | `<scope>/get <name> <property>` | Returns one property from one item. |
| `list` | `<scope>/list` | Returns an array containing every item name. |
| `print` | `<scope>/print [--watch\|-w] [--json]` | Prints all items as a table, opens a live view, or returns structured output. |
| `remove` | `<scope>/remove <name>` | Destroys an item. |
| `reset` | `<scope>/reset [<name>] [<property> ...]` | Restores properties to defaults. With no item name, it applies across the collection. |
| `set` | `<scope>/set <name> <property>=<value> [<property>=<value> ...]` | Changes one or more properties on an existing item. |

The item name for `get`, `remove`, `reset`, and `set` is positional. For
example, use `/log/sink/set serial disabled=true`, not
`/log/sink/set name=serial disabled=true`.

All managed items also have these common properties:

| Property | Access | Description |
| --- | --- | --- |
| `name` | read/write | Name within the collection. It can be changed if the new name is unused. |
| `type` | read-only | Runtime object type. |
| `disabled` | read/write | Stops the object while retaining its configuration. |
| `comment` | read/write | Operator-supplied annotation. |
| `flags` | read-only | Compact runtime flags shown by collection output. |
| `running` | read-only | Whether an active object is online. |
| `status` | read-only | Lifecycle status such as `Running`, `Starting`, `Disabled`, or `Failed`. |

### `/log/sink`

A log sink subscribes to application log messages and writes them to a Stream.
It only subscribes while that stream is running and acknowledges each record
after the stream accepts the complete formatted message. An offline or disabled
sink unregisters from delivery, so it neither holds the immediate queue open
nor replays stale log lines when it returns.

The process-created primary sink is always named `default`. This name describes
its role rather than its destination, so configuration can address it
consistently:

```text
/log/sink/set default max-severity=debug
```

On desktop platforms it targets stderr and defaults to `max-severity=info`.
The object remains present but disabled when stderr shares an interactive
console terminal, preventing asynchronous log lines from corrupting the CLI.

Configuration properties:

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `stream` | Stream name | required | Destination stream. |
| `format` | `text`, `syslog` | `text` | Plain OpenWatt text or RFC 5424 syslog framing. |
| `line-ending` | `lf`, `crlf` | `lf` | Terminator for `text`. Syslog messages have no appended line ending. |
| `max-severity` | `emergency`, `alert`, `critical`, `error`, `warning`, `notice`, `info`, `debug`, `trace` | `info` | Includes messages at this severity and all more severe levels. |
| `tag` | tag prefix | empty | Restricts the sink to matching log tags. |

Examples:

```text
# Logs on stderr
/stream/console/add name=stderr input=none output=stderr
/log/sink/add name=default stream=stderr format=text max-severity=info

# Logs on a serial stream
/stream/serial/add name=console device=uart0 baud-rate=115200
/log/sink/add name=console stream=console format=text line-ending=crlf max-severity=trace
```

### `/console/session`

This collection creates the normal CLI `Session` directly and binds it to any
Stream. There is no separate configured-session wrapper and no login phase:
once the stream and session are running, incoming bytes go directly to the
command-line editor.

The platform-created primary local session is always named `default`,
regardless of whether its backing stream is desktop stdio, an embedded
programming console, or a UART:

```text
/console/session/set default disabled=true
```

Desktop process defaults create this session disabled before `system.conf`,
`startup.conf`, and `user.conf` run, so those layers can change its stream,
profile, history, or initial command by name. An interactive launch enables it
after those configuration layers complete.

Configuration properties:

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `stream` | Stream name | required | Bidirectional byte stream used by the session. |
| `profile` | `dumb`, `nvt`, `vt100`, `ansi`, `xterm`, `windows` | required | Terminal capability standard used for line endings, editing, cursor control, text attributes, colour, and related features. |
| `history` | file path | empty | Optional persistent command-history file. |
| `initial-command` | CLI command | empty | Command started whenever the session is created. Ctrl+C uses the command's normal cancellation path and returns to the CLI. |

The configured profile supplies terminal capabilities even when the selected
stream has no terminal side-channel, as with raw serial and duplex streams.
When a side-channel is present, it may still supply dynamic information such as
terminal dimensions, but it does not replace the configured profile.

Profile summary:

| Profile | Intended client |
| --- | --- |
| `dumb` | Plain terminal with CRLF line endings and no escape sequences. |
| `nvt` | Basic Network Virtual Terminal behavior. |
| `vt100` | VT100 cursor movement, erasing, attributes, and graphics. |
| `ansi` | ANSI editing and basic colour with UTF-8 text. |
| `xterm` | ANSI plus full colour, graphics, resizing, and mouse capability. |
| `windows` | Native Windows console capability set. |

Examples:

```text
# Direct serial CLI
/console/session/add name=serial stream=console profile=ansi history=.serial_history

# Show plain logs until Ctrl+C, then expose a conservative serial CLI
/console/session/add name=default stream=console profile=vt100 initial-command="/log/print --stream"
```

The embedded platform defaults use the second form on their programming
console. `/log/print --stream` shows the retained startup log and appends each
new record once without cursor movement, screen clearing, or a status footer.
Ctrl+C returns to the prompt. The session can be disabled or removed if the
underlying port is needed for another role.

ESP targets model the actual programming transport. C3, C5, C6, H2, P4, and S3
use `/stream/usb-serial` for their native USB Serial/JTAG peripheral; S2 uses
the same stream scope with its native USB CDC backend. The original ESP32 and
C2 use `/stream/serial` on UART0 because their programming USB connection is an
external UART bridge.

Creating two consumers for one stream is currently permitted. Reader ownership
and exclusivity are intentionally not specified yet; configuration should avoid
assigning two active readers to the same stream.

### `/stream/*`

All stream collections expose these properties in addition to the common
managed-item properties above:

| Property | Access | Description |
| --- | --- | --- |
| `last-status-change-time` | read-only | Time of the most recent link-status change. |
| `link-status` | read-only | Operational state: `unknown`, `down`, or `up`. |
| `link-downs` | read-only | Number of link-down transitions. |
| `tx-link-speed` | read-only | Underlying transmit signalling rate in bits per second; `0` when unknown. |
| `rx-link-speed` | read-only | Underlying receive signalling rate in bits per second; `0` when unknown. |
| `tx-bytes` | read-only | Bytes transmitted. |
| `rx-bytes` | read-only | Bytes received. |
| `tx-rate` | read-only | Current transmit rate in bytes per second. |
| `rx-rate` | read-only | Current receive rate in bytes per second. |
| `tx-rate-max` | read-only | Maximum observed transmit rate in bytes per second. |
| `rx-rate-max` | read-only | Maximum observed receive rate in bytes per second. |

### `/stream/ble-serial`

A ble-serial stream carries a byte stream over a BLE GATT serial bridge: bytes
written to the stream are written to one characteristic, and notifications from
another are delivered as received bytes. This covers the common vendor serial
services (Nordic UART, Microchip Transparent UART, HM-10 and ELM327 clones),
which all share this shape and differ only in UUIDs.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `client` | BLE client name | required | Connected `/protocol/ble/client` providing the GATT session. |
| `service` | UUID | required | Service containing the serial characteristics. 16-bit shorthand is accepted. |
| `write` | UUID | required | Characteristic bytes are written to. |
| `notify` | UUID | `write` | Characteristic bytes are received from. Omit for single-characteristic devices. |
| `write-mode` | `auto`, `command`, `request` | `auto` | `command` uses unacknowledged writes, `request` acknowledged writes. `auto` prefers `command` when the characteristic supports it. |

Writes are chunked to the negotiated ATT MTU. `tx-backlog` pressure is visible
to producers; acknowledged mode paces transmission on the peer's responses.

```text
/protocol/ble/client/add name=obd interface=ble1 peer=A1:B2:C3:D4:E5:F6
/stream/ble-serial/add name=obd0 client=obd service=FFF0 write=FFF2 notify=FFF1
```

### `/stream/console`

This desktop stream exposes the process console handles. It is also useful as a
write-only stdout or stderr destination. Embedded transports use their concrete
serial or USB stream instead.

Configuration properties:

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `input` | `none`, `stdin` | `stdin` | Reads standard terminal input or makes the stream write-only. |
| `output` | `stdout`, `stderr` | `stdout` | Selects the process output handle. |

`input=stdin` enables local terminal setup and a TerminalChannel. `input=none`
does not alter terminal input state and exposes no terminal side-channel.

### `/stream/duplex`

A duplex stream combines independent transmit and receive streams into one
Stream. It is useful when a terminal or protocol reads and writes through
different underlying transports.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `tx` | Stream name | empty | Stream used for writes. |
| `rx` | Stream name | empty | Stream used for reads and input flushing. |

At least one of `tx` and `rx` is required.

```text
/stream/duplex/add name=split-terminal tx=terminal-out rx=terminal-in
/console/session/add name=split stream=split-terminal profile=xterm
```

### `/stream/serial`

A serial stream opens a host serial device or an embedded UART.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `device` | device path, COM name, or `uartN` | required | Serial device to open. |
| `baud-rate` | positive integer | `9600` | Symbol rate. |
| `data-bits` | `5` to `8`; some embedded UARTs allow `9` | `8` | Data bits per character. |
| `parity` | `none`, `even`, `odd`, `mark`, `space` | `none` | Parity mode. Embedded UARTs currently support `none`, `even`, and `odd`. |
| `stop-bits` | `one`, `one_point_five`, `two` | `one` | Stop-bit mode. |
| `flow-control` | `none`, `hardware`, `software`, `dsr_dtr` | `none` | Flow control. `rts_cts` aliases `hardware`; `xon_xoff` aliases `software`. |
| `tx-gpio` | GPIO number | platform default | Embedded-only transmit pin override. |
| `rx-gpio` | GPIO number | platform default | Embedded-only receive pin override. |
| `rts-gpio` | GPIO number | platform default | Embedded-only RTS pin override. |
| `cts-gpio` | GPIO number | platform default | Embedded-only CTS pin override. |
| `de-gpio` | GPIO number | platform default | Embedded-only driver-enable pin override. |

Additional commands:

| Command | Availability | Description |
| --- | --- | --- |
| `/stream/serial/devices` | POSIX hosts | Lists detected serial devices. |
| `/stream/serial/lines <name>` | all platforms | Prints the current modem-line state for an open serial stream, including RTS, CTS, DTR, DSR, DCD, and RI where supported. |

### `/stream/usb-serial`

This stream exposes the native USB programming port on supported ESP targets.
It uses USB Serial/JTAG on C3, C5, C6, H2, P4, and S3, and USB CDC on S2. It has
no transport properties.

```text
/stream/usb-serial/add name=console
/console/session/add name=default stream=console profile=vt100 initial-command="/log/print --stream"
```

### `/interface/*`

All interface collections expose these properties in addition to the common
managed-item properties above:

| Property | Access | Description |
| --- | --- | --- |
| `caps` | read-only | Interface capability flags. |
| `actual-mtu` | read-only | Effective MTU after resolving an automatic `mtu`. |
| `mtu` | read/write | Configured MTU; `0` uses `l2mtu`. |
| `l2mtu` | read/write | Link-layer MTU in bytes. |
| `max-l2mtu` | read-only | Maximum link-layer MTU reported by the driver; `0` when unknown. |
| `pcap` | write-only | Attaches the interface to a named packet capture. |
| `last-status-change-time` | read-only | Time of the most recent link-status change. |
| `connected` | read-only | Connection state: `unknown`, `disconnected`, or `connected`. |
| `link-status` | read-only | Operational state: `unknown`, `down`, or `up`. |
| `link-downs` | read-only | Number of link-down transitions. |
| `tx-link-speed` | read-only | Underlying transmit signalling rate in bits per second; `0` when unknown. |
| `rx-link-speed` | read-only | Underlying receive signalling rate in bits per second; `0` when unknown. |
| `tx-bytes` | read-only | Bytes transmitted. |
| `rx-bytes` | read-only | Bytes received. |
| `tx-packets` | read-only | Packets transmitted. |
| `rx-packets` | read-only | Packets received. |
| `tx-dropped` | read-only | Transmit packets dropped. |
| `rx-dropped` | read-only | Receive packets dropped. |
| `tx-rate` | read-only | Current transmit rate in bytes per second. |
| `rx-rate` | read-only | Current receive rate in bytes per second. |
| `tx-rate-max` | read-only | Maximum observed transmit rate in bytes per second. |
| `rx-rate-max` | read-only | Maximum observed receive rate in bytes per second. |
| `avg-queue-time` | read-only | Average transmit queue time in milliseconds. |
| `avg-service-time` | read-only | Average packet service time in milliseconds. |
| `max-service-time` | read-only | Maximum packet service time in milliseconds. |

### Ethernet station properties

Ethernet-class interfaces (`ethernet`, `wlan`, `ap`, `bridge`, and `vlan`)
expose these properties in addition to the common interface properties above:

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `cfm-level` | read/write | `0` to `7` | `7` | 802.1ag maintenance level used for CFM loopback. |
| `mac` | read/write; VLAN read-only | MAC address | driver, parent, or generated address | Address used by the station on its Ethernet segment. |

A driver-backed station adopts the driver's address so its source address
matches the address accepted by the medium. A supported `mac` assignment is
accepted only after the driver has reprogrammed that address, which drops that
interface's link while it is applied. An ESP32 `wlan` and `ap` use independent
addresses, and only the assigned interface restarts. In APSTA mode, the station's
reconnection scan can still disrupt clients of the running AP. A bridge generates
an address from the node id, while a VLAN follows its parent interface's address
and cannot be assigned independently.

### `/interface/ap`

An AP interface is one BSS served by a WiFi radio.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `radio` | read/write | WiFi interface name | required | Radio serving the BSS. |
| `ssid` | read/write | SSID | required | Network name advertised by the BSS. |
| `secret` | read/write | Secret name | empty | Credentials authorized for the `wifi` service. |
| `phy-mode` | read-only | PHY label | empty | BSS operating PHY and client ceiling; not a per-client value. |
| `auth` | read/write | `open`, `wpa2`, `wpa3`, `wpa2_wpa3`, `wpa2_enterprise`, `wpa3_enterprise` | `open` | Authentication mode. |
| `client-isolation` | read/write | boolean | `false` | Prevents clients on the BSS from communicating directly. |
| `max-clients` | read/write | `0` to `255` | `0` | Client limit; `0` selects the platform default. |
| `hidden` | read/write | boolean | `false` | Suppresses SSID broadcast. |
| `installation` | read/write | `any`, `indoor`, `outdoor` | `any` | Declared installation environment. |

### `/interface/ble`

A BLE interface is one Bluetooth LE radio. It scans continuously while running,
feeding discovered advertisements to `/protocol/ble/device/print`, and carries
connections opened by `/protocol/ble/client` entries.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `port` | read/write | `0` to radio count | `0` | Platform radio index. |
| `max-in-flight` | read/write | `1` to `255` | `4` | Concurrent unacknowledged frames; must be non-zero. |

### `/interface/ethernet`

Ethernet interfaces are a managed collection, and additionally carry the
mac-ping and discovery commands. Reachability testing uses 802.1ag loopback,
so standard L2 OAM equipment both answers `ping` and can ping an OpenWatt
station itself. Enumerating the segment is a separate command, because
loopback is a point-to-point test that gains no third-party responders when
broadcast.

| Command | Syntax | Description |
| --- | --- | --- |
| `discover` | `/interface/ethernet/discover` | Sweeps every segment for OpenWatt stations, listing each with its name and addresses. |
| `ping` | `/interface/ethernet/ping address=<mac> [count=<count>]` | Times 802.1ag loopback round trips to `address`, one request per second. |

| Argument | Values | Default | Description |
| --- | --- | --- | --- |
| `address` | mac address | required | Unicast destination. Multicast and broadcast are rejected; use `discover`. |
| `count` | request count | `4` | Number of requests to send; `0` is treated as `1`. |

Requests go out every running ethernet station, so whichever segment hosts the
target answers. Each reply prints as `reply from <mac>: time=<rtt>`, with the
responder's name appended when its LBR carried a Sender ID TLV. A summary of
`<replies> replies for <sent> requests` closes the command, and Ctrl+C cancels
it early.

`discover` broadcasts an OW address query from every running station and
collects the reports, printing each responder's mac address and name followed
by its universal addresses, one per line, indented and prefixed with the packet
type. Responders jitter their replies over a short window, so the sweep runs
for two seconds before closing with `<count> stations found`. Round-trip times
are not reported: the jitter makes them meaningless. Only OpenWatt stations
answer.

Stations answer loopback only at the maintenance level they claim, set per
interface by the `cfm-level` property (`0`-`7`, default `7`). Loopback messages
at other levels belong to another maintenance domain and are ignored, so an
OpenWatt station never corrupts diagnostics on a network with provisioned CFM.

```text
/interface/ethernet/ping address=02:13:37:aa:bb:64 count=10
/interface/ethernet/discover
/interface/ethernet/set eth0 cfm-level=5
```

### `/interface/obd`

An OBD interface speaks OBD-II diagnostics to a vehicle: requests and responses
are carried as packets holding a complete service message (mode + pid + data),
with ISO-TP segmentation handled below. Two data sources are supported and the
properties are mutually exclusive; the one set last wins.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | CAN interface name | none | Speaks ISO-TP directly on the nominated CAN bus. |
| `stream` | Stream name | none | Speaks to an ELM327 adapter over any byte stream: serial, `tcp-client` (WiFi adapters), or `ble-serial` (BLE dongles). |
| `vehicle` | `unknown`, `awake`, `asleep` | `unknown` | Read-only. Whether the vehicle is answering. |

The ELM327 backend initialises the adapter (echo off, headers on, automatic
protocol) and runs one command at a time against its prompt. 29-bit addressing
is not yet supported over ELM327.

A parked vehicle stops answering without anything failing, so this is reported
rather than treated as an error: the interface stays running and `status` reads
`Asleep`. `awake` is a fact, since something answered. `asleep` is a heuristic
inferred from a run of requests that drew no reply, so a vehicle that answers
slower than the interface waits looks the same. Bindings read this rather than
each inferring it independently.

```text
/stream/ble-serial/add name=obd0 client=car service=FFF0 write=FFF2 notify=FFF1
/interface/obd/add name=car-obd stream=obd0
```

### `/interface/udp`

A UDP interface is a raw-packet interface over UDP datagrams: one datagram is
one packet, in both directions.

A unicast `remote-host` gives a point-to-point link (reception is filtered to
that peer). A broadcast or multicast remote, or no remote at all, gives a
multi-drop segment: datagrams are accepted from any peer, each received packet
carries its source address, and transmitted packets may address a peer
per-frame (falling back to the configured remote).

A peer may be a MAC address (`02:13:37:AA:BB:64`), in which case datagrams ride raw
ethernet over the OpenWatt ethertype and no IP configuration is required; builds
without the IP stack carry these peers only. An ether peer may additionally be
bound to a station with `interface=`: datagrams then egress that station only,
where an unbound endpoint selects egress by learned neighbour (flooding on a
miss). A station name binds unambiguously where a MAC cannot: a VLAN
sub-interface shares its parent's address. A bound station is a dependency: the
interface waits for it to come up, restarts when it goes offline, and holds
rather than falling back to a wildcard endpoint if it disappears.

The interface self-configures its L2MTU from the peer's datagram payload MTU
(assuming a 1500-byte link MTU: 1472 for IPv4, 1452 for IPv6, 1474 for ether);
`l2mtu` may be lowered by the user.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | ethernet station name | none | Egress binding for an ether peer; datagrams ride this station only. |
| `local-host` | host or address | wildcard | Local address to bind. |
| `local-port` | `0` to `65535` | `0` | Local port; zero requests an ephemeral port. |
| `remote-host` | host, address or MAC | none | Default datagram destination. |
| `remote-port` | `1` to `65535` | with remote-host | Default destination port. |

### `/interface/wifi`

This collection represents physical radios; WLAN and AP interfaces bind to them.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `mode` | read-only | `monitor`, `sta`, `ap`, `apsta` | derived | Active role from the bound interfaces. |
| `band` | read/write | `any`, `2_4ghz`, `5ghz`, `6ghz`; or a frequency such as `2.4GHz` | `any` | Selected operating band. Enum keys are lowercase; units are case-sensitive. |
| `channel` | read/write | `0` to `233` | `0` | Requested channel; `0` selects automatically. |
| `active-channel` | read-only | `0` to `233` | `0` | Current channel; `0` means unavailable. |
| `tx-power` | read/write | dBm | `0` | Requested transmit power; `0` selects the platform default. |
| `country` | read/write | ISO 3166-1 alpha-2 | empty | Regulatory country; empty selects the platform default. |
| `monitor` | read/write | boolean | `false` | Enables monitor capture alongside configured WLAN/AP roles. |
| `phy-capability` | read-only | PHY label | empty | Radio ceiling, for example `HE160 2SS`; a concrete `band` reports that band and `any` reports the best supported band. |
| `wiphy` | read/write | Linux phy or netdev name | required on Linux | Physical Linux radio to manage. |
| `netdev` | read-only | Linux netdev name | empty | Primary Linux virtual interface adopted or created for the radio. |
| `adapter` | read/write | Windows adapter name | required on Windows | Physical Windows WiFi adapter to manage. |

### `/interface/wlan`

A WLAN interface is one station association bound to a WiFi radio.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `radio` | read/write | WiFi interface name | required | Radio used for the association. |
| `ssid` | read/write | SSID | required | Network to associate with. |
| `secret` | read/write | Secret name | empty | Credentials authorized for the `wifi` service. |
| `phy-mode` | read-only | PHY label | empty | Negotiated PHY, for example `VHT80 2SS`; unavailable parts are omitted. |
| `bssid-filter` | read/write | MAC address | none | Restricts association to one AP. |
| `bssid` | read-only | MAC address | empty | Currently associated AP. |
| `rssi` | read-only | dBm | `0` | Received signal strength; `0` means unavailable. |
| `signal-quality` | read-only | `0` to `100` | `0` | Normalized signal quality. |

### `/binding/obd`

An OBD binding polls a vehicle through an OBD interface and materialises the
results into a Device from a profile's `obd:` element map. Polling batches up
to six mode-01 pids per request, queries the supported-pid bitmasks at startup
so pids the vehicle does not implement are never polled, and treats a silent
vehicle as parked rather than failed: it follows the interface's `vehicle` state,
dropping to a quiet probe every ten seconds while that reads `asleep` and
resuming its normal cadence when the vehicle answers again.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | OBD interface name | required | Interface used to reach the vehicle. |
| `device` | device name | required | Device to create or populate. |
| `profile` | profile basename | required | Profile holding the `obd:` element map. |
| `model` | model name | empty | Model selector within the profile. |

Profile `obd:` lines are `mode, pid, offset, type` with an optional units
column and an optional `ecu=<id>` field addressing a specific ECU (the default
is the functional broadcast). Mode `0x22` pids are 16-bit UDS data identifiers.

```text
/interface/obd/add name=car-obd stream=obd0
/binding/obd/add name=car device=mg profile=j1979
```

### `/protocol/ble/device`

| Command | Syntax | Description |
| --- | --- | --- |
| `print` | `/protocol/ble/device/print` | Lists devices heard advertising, with RSSI, name, and advertised service and manufacturer identifiers. |

Entries expire twenty seconds after the last advertisement. A connected device
stops advertising, so it leaves this list while a client holds it.

### `/protocol/ble/client`

A BLE client is one GATT connection to a peer device. It connects on startup and
completes service and characteristic discovery before reporting `Running`, so a
running client always has a populated attribute table.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `interface` | read/write | BLE interface name | required | Radio carrying the connection. |
| `peer` | read/write | MAC address | required | Device address to connect to. |

| Command | Syntax | Description |
| --- | --- | --- |
| `gatt` | `/protocol/ble/client/gatt <client>` | Prints the discovered attribute table grouped by service. |
| `read` | `/protocol/ble/client/read <client> <handle>` | Submits an ATT read; the value is written to the log. |

`gatt` reports the negotiated ATT MTU, then each service with its handle range
and characteristics. `PROPS` is a fixed eight-column mask, one letter per ATT
property bit, `-` where the bit is clear:

| Letter | Property |
| --- | --- |
| `B` | Broadcast |
| `R` | Read |
| `C` | Write without response (write command) |
| `W` | Write with response (write request) |
| `N` | Notify |
| `I` | Indicate |
| `A` | Authenticated signed writes |
| `E` | Extended properties |

Reads and writes are refused locally against these bits, so a characteristic
without `R` reports `read_not_permitted` without transmitting.

```
/protocol/ble/client/add name=obd interface=ble1 peer=00:10:CC:4F:36:03
/protocol/ble/client/gatt obd
```

```
mtu=247, 3 services, 4 characteristics

service 00001800-0000-1000-8000-00805F9B34FB  handles 0x0001-0x0003
  VALUE   DECL    CCCD    PROPS     UUID
  0x0003  0x0002  -       -R------  00002A00-0000-1000-8000-00805F9B34FB

service 00001801-0000-1000-8000-00805F9B34FB  handles 0x0004-0x0007
  VALUE   DECL    CCCD    PROPS     UUID
  0x0006  0x0005  0x0007  -----I--  00002A05-0000-1000-8000-00805F9B34FB

service 0000FFF0-0000-1000-8000-00805F9B34FB  handles 0x0008-0xFFFF
  VALUE   DECL    CCCD    PROPS     UUID
  0x000A  0x0009  0x000B  --CWN---  0000FFF1-0000-1000-8000-00805F9B34FB
  0x000D  0x000C  -       --CW----  0000FFF2-0000-1000-8000-00805F9B34FB
```

### `/protocol/http/server`

An HTTP server provides the listener and shared policy for its registered
handlers.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `port` | `0` to `65535` | `0` | Plain HTTP listen port; zero disables it. |
| `tls-port` | `0` to `65535` | `0` | HTTPS listen port; available when TLS is built. |
| `certificates` | certificate names | empty | Certificates used by HTTPS. |
| `https-redirect` | `yes`/`no` | `no` | Redirect plain HTTP requests to HTTPS. |
| `max-request-body` | bytes | `65536` | Maximum body buffered by the HTTP parser. Streaming handlers are not limited by it. |
| `allowed-origin` | empty, `*`, or an origin | empty | Default cross-origin policy for handlers on this server. Empty disables cross-origin access, `*` allows any origin, and another value allows that exact `scheme://host[:port]`. |

### `/protocol/http/fileserver`

A file mount serves a filesystem directory beneath a URI prefix on an HTTP
server. `GET <uri>/a/b.css` reads `<root>/a/b.css`. A directory named without
its trailing slash redirects (`301`) to it, so a path that names a directory
is always distinguishable from a file. A directory request serves
`index.html` or `index.htm`, and otherwise falls back to a JSON listing
(`{"entries":[{name, dir, size, mtime}]}`, `mtime` in unix seconds) served as
`application/vnd.openwatt.dir+json` - parseable as plain JSON, but never
mistakable for a `.json` file. Requesting with `Accept: application/json`
returns the listing even where an index exists; this is how the web file
browser enumerates, at every access level. `HEAD` answers with the headers
alone. Responses larger than 64KB stream from disk instead of buffering,
paced by the connection.

Path mapping URL-decodes the request, rejects `..` traversal, and refuses
path separators inside a segment, for reads and writes alike.

The `access` property sets how far the mount goes beyond reading:

- `read`: `GET`/`HEAD` only (the default).
- `write`: adds `PUT` (store a file) and `DELETE` (remove one). Uploads
  stream to a temporary as the body arrives, so they are not limited by the
  server's `max-request-body`, and the target is only replaced once the
  upload completes: an interrupted transfer leaves the previous file
  untouched.
- `webdav`: upgrades the mount to a WebDAV server, so filesystem clients
  (davfs2, rclone, Windows Explorer, macOS Finder) can mount it. Adds
  `PROPFIND` (Depth 0 and 1; infinity is refused, clients walk), `MKCOL`,
  `COPY`, `MOVE` and recursive collection `DELETE`, plus `LOCK`/`UNLOCK`
  grants that are never enforced: they exist because Windows and macOS
  refuse to mount read-write without a lock to hold, not to arbitrate
  writers. The mount root itself cannot be deleted, moved, or overwritten.
  WebDAV is compiled out of `TINY` builds; such a mount serves read-write.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `http-server` | HTTP server name | required | Server the mount registers its URI handlers on. |
| `uri` | URI prefix | required | Prefix the mount answers under; `/` serves the whole tree. |
| `root` | directory path | empty | Directory served; empty is the filesystem origin (the working directory on hosts). |
| `access` | `read`, `write`, `webdav` | `read` | Access level; see above. |
| `auth-required` | `yes`/`no` | `no` | Require HTTP Basic credentials; see below. |
| `allowed-origin` | empty, `*`, or an origin | inherited | Cross-origin access policy; see below. |

With `auth-required=yes` every request except `OPTIONS` (preflights carry no
credentials) must present Basic credentials naming a `/secret` that validates
and is allowed the `http` service (or `any`); anything else is a `401` with a
`WWW-Authenticate` challenge. Basic credentials travel in cleartext, so an
authenticated mount belongs on an HTTPS server.

```text
/secret add name=admin password=hunter2 services=http
```

When `allowed-origin` is not specified, the mount inherits its HTTP server's
policy. An explicitly assigned value overrides the server: empty disables
cross-origin access, `*` allows any origin, and another value allows that exact
`scheme://host[:port]`. Resetting the property restores inheritance. `OPTIONS`
preflights and normal responses use the effective policy.

```text
/protocol/http/server add name=webserver port=80
/protocol/http/fileserver add name=files http-server=webserver uri=/files root="conf" access=webdav allowed-origin=http://192.168.0.5:8080
```

### `/sync/udp-server`

A datagram sync listener: it owns a wildcard multi-drop `/interface/udp` on
the configured port and spawns a dynamic `/sync/peer` for the first datagram
from each unknown source. The server routes received frames to its peers by
source address, and each spawned peer transmits addressed back to its source.
Datagram links carry no death signal, so a peer whose source goes quiet is
swept after the idle timeout; a re-appearing source simply spawns afresh.
It listens on UDP port `4712` unless `port` is set.

The peering agent creates one of these (named `peering`) for `role=member`;
explicit instances serve hand-wired datagram sync.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `port` | `1` to `65535` | `4712` | Port the listener binds. |
| `local-host` | host, address or MAC | empty | Bind address, selecting the family: empty is the IP wildcard; the zero MAC (`00:00:00:00:00:00`) is ether's any-station, hearing OpenWatt-ethertype datagrams. |
| `encoder` | `json`, `binary` | `binary` | Encoding for spawned peers. |
| `timeout` | duration | `5m` | Idle time after which a silent peer is swept. |

### `/sync/peer`

`transport` binds a peer to an existing interface. Alternatively, `remote`
creates a dynamic, temporary UDP interface owned by the peer; it is destroyed
with the peer. The last of `transport` and `remote` set wins.

| Property | Values | Description |
| --- | --- | --- |
| `remote` | `address:port`, `[ipv6]:port`, `[mac]:port` | Remote UDP peer. The address and port are both required. |

### `/sync/discover/ether`

An ether discovery domain beacons this node's peering identity (node-id, name,
role, cluster, claim state) over the OpenWatt ethertype on one ethernet
station, and feeds received beacons into the neighbour table. Domains are the
per-medium opt-in: no domain configured, no beacons sent or consumed on that
medium.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | ethernet station name | required | Segment to beacon on. |
| `interval` | duration | `30s` | Beacon cadence. |

### `/sync/neighbor`

`print` lists every node heard through any discovery domain: node-id, name,
role, cluster, claim state, and the age of its last beacon, followed by one
line per link: the station a beacon arrived on, the source address, and the
sync port announced for that medium. A multi-homed node shows one link per
(station, address) pair it beacons through; the peering agent claims via the
most preferable live link. Nodes and links age out after 10 minutes of
silence.

```text
/sync/discover/ether add name=lan interface=ether1
/sync/neighbor print
```

### `/sync/peering`

The peering agent (see [PEERING.draft.md](PEERING.draft.md)) is the node-global
auto-peering policy: it does not exist as a collection, just `set`/`print` on a
singleton. Setting `role=` is the opt-in (it implies `enabled=yes`).

A `member` advertises itself as claimable through the configured discovery
domains and accepts claims arriving on the sync channel. A member accepts any
number of claimants from a single cluster (two claimants is the dual-authority
shape); a claim naming a second cluster is refused. Claims are runtime state:
when the last claimant's session dies the member reverts to unbound and is
re-claimed within a beacon interval.

An `authority` listens for members' sessions on the sync port: a dynamic
`/sync/udp-server` named `peering`, bound to the ether wildcard, created and
destroyed with the role. Its port rides the discovery beacons, so a member
learns where to connect without configuration.

A `member` sweeps the neighbour table every few seconds and opens a session to
each authority of its fleet: it builds a dynamic connected `/interface/udp`
from that authority's most preferable live link (bound to the station the
beacon arrived on, toward its address and beaconed port) and spawns a dynamic
`/sync/peer` named after the remote node. The leaf dials because it is the end
that can: a member behind a NAT, or with no inbound surface at all, still joins
its fleet. The authority claims the members that reach it and match the
`claim` filter, so it still decides who joins - it just answers rather than
dials.
A dial that never establishes tears the pair down and backs off per link (30s
doubling to 10m), so a member seeing an authority on two segments settles on
the one that works. A member holds a session to every authority of its fleet,
which is what gives a second authority its dual-authority seat, and a restarted
authority is rejoined by its members rather than having to rediscover them. A
member that reboots simply dials again on the way up, without waiting for a
sweep.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `yes`/`no` | `no` | Participate in peering; implied by setting `role`. |
| `role` | `member`, `authority` | none | This node's peering role. |
| `cluster` | name | empty | Fleet this node belongs to. A member with no cluster accepts (and adopts) any claimant's cluster, logging loudly; set one to pin the node. |
| `priority` | number | `100` | Authority election precedence; lower wins, node-id breaks ties. |
| `claim` | path glob | `*` | Authority only: which member names to adopt. |
| `secret` | string | empty | The fleet key, set by hand. Normally unset: the authority mints one at first adoption and hands it to each factory member inside the claim; thereafter claims prove it with an HMAC over the member's per-session hello nonce, so the key never travels again and a captured claim cannot replay. |
| `port` | `1` to `65535` | `7000` | Authority only: sync port the session listener binds; advertised in discovery beacons so members know where to dial. |

A factory member (no key) is adopted by the first claiming authority: the claim hands the
fleet key over (the one trust-on-first-use moment), and the member persists its allegiance
(`{cluster, key}` in `conf/fleet.id`) across reboots, beaconing `adopted` and refusing any
claim that cannot prove the key. `reset` is the factory reset: it clears the allegiance and
the node is adoptable again immediately.

```text
/sync/peering set role=member                      # factory: adopted by whoever claims first
/sync/peering set role=authority cluster=home claim=*
/sync/peering print
/sync/peering reset                                # factory reset: leave the fleet
```

