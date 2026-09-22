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

- `/system/config/export`: Prints the running configuration as a script of `add` and `set` commands.
  Only properties that were explicitly set are emitted; dynamic, temporary,
  and remote (synced) objects are skipped.
- `/system/config/save [file=<base>]`: Publishes a numbered revision, using `conf/config.conf`
  as the default base: `conf/config.conf.1`, `.2`, and so on. The command reports the actual
  filename. The latest five completed revisions are retained for each base, including custom
  `file=` exports. Only the default base is selected automatically at boot.

String values are always double-quoted in exports; quotes, backslashes and dollar signs
are backslash-escaped to preserve literal text.

Exports run in three phases: create every included object with `disabled=true`, set its
saved properties, then enable only objects that were originally enabled. All identities
exist before references are applied, including same-type dependencies and cycles.
Objects with no saved properties need no configuration `set` command.

**Known restore limitations (#665):** dependencies excluded from export must still exist.
Objects already created by `system.conf`, process defaults or discovery reject the `add`;
later `set` commands apply saved properties, but do not undo earlier startup, omitted
settings or removals. An already-enabled boot object saved as disabled also stays enabled
because its disabling `add` was rejected. A successful save does not guarantee a complete
restore. Reconciliation is tracked at the top of `TODO.md`.

Each revision is written to a separate `.tmp` file with an integrity checksum, flushed, then
renamed to its completed filename. Unfinished candidates are never selected at boot. A failed
write preserves previous completed revisions. On POSIX systems the containing directory is
also flushed after publication; Windows publication requests write-through. Embedded guarantees
still depend on the filesystem and storage driver.

Boot selects the newest revision with a valid checksum and parseable script. Corrupt or
unparseable revisions are renamed `.bad`, logged, and skipped in favour of older revisions.
The legacy `conf/config.conf` is still accepted as a fallback; new saves leave it intact.
The platform's `system.conf` and `user.conf` layers still apply. An explicit `--config` bypasses
automatic revision selection and can name an individual revision for recovery.

On targets with NVS boot-failure tracking, repeated failed boots retire the newest revision
and try the previous one. Exhausted saved revisions stop startup with an error; they do not
automatically run factory/startup defaults. With no saved configuration history, normal initial
provisioning still applies. Deliberately remove saved revisions (including `.bad` files) and
the legacy file to return to startup defaults; do not use repeated power cycling as a factory
reset. This recovery detects integrity, syntax and counted boot failures, not loss of remote
connectivity or individual command errors. A remote confirmation window is outstanding work.

A hashed `/secret` exports its password as `hash:<algo>:<salt>:<hash>`. Recoverable password
material is stored separately in numbered `conf/secret.store.<revision>` files, using the same
publication and retention mechanism. Each store snapshot includes all retained hash mappings,
so older config revisions can still recover their secrets. Unsaved changes to the store must
be persisted before a config revision can be published. The legacy `conf/secret.store` remains
readable. If material cannot be recovered, outbound use requires the password to be re-entered.

**Deferred security hardening (#665):** the side store contains reversible hex plaintext for
all hashed passwords, including verification-only credentials, and uses ordinary file creation
permissions. Restricting its scope, tightening access, and deleting obsolete material are tracked
prominently in `TODO.md`. Hashes in a config export do not protect a copied secret store.

Config mutations after boot (any collection `add`/`remove`/`set`/`reset`) mark the running configuration
dirty. `/system/sysinfo` shows this as `Config: modified` or `Config: saved`, and `/system/sysinfo
config-dirty` returns the bare boolean for UX clients polling health; saving to the default path clears it.

### Configuration property round trips

- `/protocol/telnet/server` is a managed collection with `add`, `remove`, `get`, `set`,
  `reset`, `list`, and `print`. Its `port` property is a nonzero unsigned 16-bit port;
  changing it restarts the listener. Example: `/protocol/telnet/server/add name=console port=23`.
- Secret `services` and DNS-server `protocols` getters return arrays. Their setters accept
  comma-separated values; setting DNS protocols replaces the previous selection.
- TCP-client `remote` returns the configured hostname or the live typed network address.
- HTTP-server, MQTT-broker and TLS `certificates` getters return arrays of certificate names.
  TLS `certificate` is a singular setter; exports use the canonical `certificates` property.

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

### `/system`

Node-wide state and lifecycle. The sub-scopes `/system/config`, `/system/fs` and
`/system/alloc` are not covered here yet.

`/system/hostname` prints the node's hostname; `/system/set-hostname <name>` sets it, and
also stamps the log HOSTNAME field.

`/system/sysinfo` prints hostname, node id, OS, CPU, memory pools, uptime, wall time and
whether the saved configuration is dirty, plus the reset reason where the platform has
one. Given property names instead, it prints only those values, one per line: `hostname`,
`node-id`, `os`, `processor`, `total`, `used`, `peak`, `largest`, `ext-total`, `ext-used`,
`ext-peak`, `ext-largest`, `uptime`, `time`, `config-dirty`, `reset-reason`.

`/system/uptime` prints time since start, and `/system/time` the current date and time.
`/system/sysinfo time` marks it `(unsynchronised)` until wall time is set.

`/system/log-level <severity>` sets the maximum severity that reaches the log sinks.

`/system/update-rate <rate>` sets the main loop frequency, a quantity in Hz, clamped to
1..1000.

`/system/profile-path <path>` sets the root searched recursively for device profiles. It
must be set before profiles load and cannot be empty; a command-line override wins and the
command says so.

`/system/sleep <duration>` pauses the session for the given duration. It is latent, so
Ctrl-C cancels it, which makes it useful for pacing a startup script.

`/system/reboot [bootloader=<n>]` restarts the node. Without arguments it performs a
normal restart.

`<n>` is an integer, and any non-zero value restarts into the chip's own ROM loader
instead, where the part exposes its factory firmware-update interface. `bootloader=1`
is the usual form; the value selects between loaders on a part offering more than one,
which none currently does. Only targets whose silicon provides such an entry point
implement this, and elsewhere the command reports that the platform has no bootloader
mode and does not reboot.

### `/ping`

`/ping address=<IPv4|IPv6|MAC> [count=<count>] [iface=<interface>]` selects
ICMP, ICMPv6 or 802.1ag loopback from the destination address. The default is
four requests, one per second; `count=0` sends one request. Use address literals
without ports. An IPv6 literal may carry a zone suffix naming an interface
(`fe80::1%eth0`); a numeric zone is a host-stack interface index and is not an
OpenWatt interface. IP ping requires the internal IP stack; MAC ping is also
available in builds using host networking.

`iface` selects an Ethernet station for MAC ping. Without it, MAC requests go
out through every running Ethernet station. MAC destinations must be unicast;
use `/interface/ethernet/discover` for discovery.

For IP ping, `iface` constrains the selected route and receiving interface.
It is required for IPv6 link-local/multicast and IPv4 multicast/broadcast
addresses; an IPv6 zone suffix selects the interface the same way, and the two
must agree when both are given. The command cancels if the selected interface goes offline or is
removed. Group requests accept up to 64 distinct unicast responders during
one second; duplicates count once per request. Reply counts can exceed request
counts when probing a group or sending MAC requests on several interfaces.

Correlated ICMP errors identify the reporting host/router and error code,
with MTU or parameter pointer where applicable. Errors do not count as replies.
Group requests remain open after an error and report at most 64 distinct error
sources per request.

```
/ping address=192.0.2.1 count=3
/ping address=2001:db8::1
/ping address=fe80::1 iface=eth0
/ping address=fe80::1%eth0
/ping address=02:13:37:aa:bb:64 iface=eth0
```

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
| `print` | `/log/print [--stream] [level=<severity>] [tag=<prefix>] [match=<text>] [max=<count>]` | Opens a live log consumer. Defaults to `level=trace` and `max=256` (64 on Tiny); `max` is capped at 1024 (256 on Tiny). |

`/log/print` is a temporary log consumer. The scrollable view first copies
matching history, when enabled, then accumulates new records up to `max`.
Its records are released when the command finishes. Formatting happens while
rendering, so retained data contains no terminal escape sequences or
preformatted text.

By default the command presents a scrollable live view. `--stream` instead
prints up to `max` matching history records, releases that private copy, then
prints new matching records without retaining them in the view. It emits no cursor movement,
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

Ethernet interfaces are a managed collection with a discovery command.
MAC reachability testing uses `/ping` and 802.1ag loopback,
so standard L2 OAM equipment both answers `ping` and can ping an OpenWatt
station itself. Enumerating the segment is a separate command, because
loopback is a point-to-point test that gains no third-party responders when
broadcast.

| Command | Syntax | Description |
| --- | --- | --- |
| `discover` | `/interface/ethernet/discover` | Sweeps every segment for OpenWatt stations, listing each with its name and addresses. |

Without `iface`, MAC ping requests go out every running Ethernet station.
Each reply prints as `reply from <mac>: time=<rtt>`, with the
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
/ping address=02:13:37:aa:bb:64 count=10
/interface/ethernet/discover
/interface/ethernet/set eth0 cfm-level=5
```

On an Espressif board built with `USE_ETHERNET=1` the interface drives the EMAC and its external
PHY directly, and the wiring is part of the interface. The board's `system.conf` creates it. Any pin left at `-1` takes the reference wiring of the part,
so a board that follows the reference design needs only its PHY address and reset line. Changing
a wiring property reinstalls the MAC.

| Property | Default | Description |
| --- | --- | --- |
| `phy` | `generic` | The PHY part. Every PHY is driven through its IEEE 802.3 registers; `yt8531` adds the setup that part needs beyond them (autonegotiation back on after reset, RGMII clock delays). |
| `phy-address` | `-1` | PHY address on the management bus; `-1` probes for it. |
| `mdc-gpio`, `mdio-gpio` | `-1` | Management bus pins. |
| `phy-reset-gpio` | `-1` | PHY hardware reset, active low; `-1` when it is not wired. |
| `clock-mode` | `platform_default` | Who sources the 50MHz RMII clock: `external` (PHY or oscillator) or `output` (the MAC, from an internal PLL). |
| `clock-gpio` | `-1` | The pin that clock enters or leaves by. |
| `promiscuous` | `true` | Receive every frame, which a bridged port needs. Applies immediately. |
| `flow-control` | `false` | Honour and send 802.3x pause frames. |
| `auto-negotiate` | `true` | Negotiate speed and duplex with the link partner. Setting it `true` hands a forced link back to detection. The link drops while the mode changes. |
| `speed` | `s100m` | Forces the link to `s10m`, `s100m`, or `s1000m` where the MAC is gigabit. Setting it turns `auto-negotiate` off. |
| `full-duplex` | `true` | Forces the duplex. Setting it turns `auto-negotiate` off. A forced end facing a negotiating partner leaves that partner at half duplex, so force both ends or neither. |
| `duplex` | read-only | What this end of the link is running: `full`, `half`, or `unknown` while it is down. |

The ESP32-P4 and ESP32-S31 route the data plane through IO_MUX and timestamp in the MAC, which
adds:

| Property | Default | Description |
| --- | --- | --- |
| `tx-en-gpio`, `txd0-gpio`, `txd1-gpio`, `crs-dv-gpio`, `rxd0-gpio`, `rxd1-gpio` | `-1` | RMII data pads. |
| `clock-loopback-gpio` | `-1` | With `clock-mode=output`, the pad the clock re-enters by; these MACs do not loop it back internally. |
| `hw-timestamp` | `false` | Start the IEEE 1588 clock of the MAC and stamp received frames with it. The interface then reports the `hw_timestamp` capability, and a received packet's time is when the MAC saw it rather than when software did. |

```text
/interface/ethernet/add name=eth1 phy-address=1 phy-reset-gpio=51
/interface/ethernet/add name=eth1 phy-address=0 clock-mode=output clock-gpio=17
/interface/ethernet/add name=eth1 phy=yt8531 phy-reset-gpio=7
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
| `remote-host` | host, address or MAC | none | Default datagram destination. An IPv6 multicast or link-local peer names its link with a zone (`ff02::1%eth0`). |
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

### `/interface/wpan`

The raw IEEE 802.15.4 radio, present on the ESP32-C5, C6, H2 and S31. On its own it delivers the beacon,
data, acknowledgement and command frames it hears as `wpan` packets and transmits frames handed to
it; Zigbee and Thread will layer on top. Multipurpose, fragment and extended frames are not parsed
and count as `rx-dropped`. With the default `pan-id` and `short-address` the radio has no network
identity, so only broadcast frames and `promiscuous` capture reach the interface.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `channel` | read/write | `11` to `26` | required | 2.4GHz O-QPSK channel. A value outside the range is stored and holds the interface out of Running. |
| `tx-power` | read/write | dBm | `0` | Requested transmit power; `0` selects the platform default. |
| `pan-id` | read/write | `0x0000` to `0xFFFF` | `0xFFFF` | PAN the radio filters on; `0xFFFF` is the broadcast PAN. |
| `short-address` | read/write | `0x0000` to `0xFFFF` | `0xFFFE` | 16-bit MAC address; `0xFFFE` means none assigned. |
| `extended-address` | read/write | EUI-64 | factory EUI-64 | 64-bit MAC address; reports the factory address until one is assigned. |
| `promiscuous` | read/write | boolean | `false` | Receives every frame regardless of address, with hardware acknowledgement off. |
| `cca` | read/write | boolean | `true` | Clear-channel assessment before each transmission. |

```text
/interface/wpan/add name=wpan1 channel=15 promiscuous=yes
```

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

### `/binding` common properties

Every binding tracks whether its device is reachable and mirrors the verdict
into the device's `status.online` element: polling bindings mark the device
offline once three consecutive polls have failed (timeouts, exceptions, and
malformed or error responses all count) and no poll has succeeded for thirty
seconds, and online again on the first successful sample. A partially failing
device stays online while any of its data still samples; the dead elements
simply stop updating. Event-driven bindings mark the device online on incoming
data and offline when their transport drops. Bindings that drive local hardware
(`/binding/gpio`, `/driver/power/regulator`) mark the device online once the
hardware is claimed and offline when it faults. A binding retracts its
verdict and cancels its watchdog during shutdown, including restarts. If no
other source remains online, the device becomes offline until fresh activity.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `device` | device name | required | Device to create or populate. |
| `offline-timeout` | duration | `0` (disabled; `30s` for CAN and Tesla TWC) | Marks the device offline when no data has arrived for this long, even while the transport stays up. |

### `/binding/obd`

An OBD binding polls a vehicle through an OBD interface and materialises the
results into a Device from a profile's `obd:` element map. Polling batches up
to six mode-01 pids per request, queries the supported-pid bitmasks at startup
so pids the vehicle does not implement are never polled, and treats a silent
vehicle as parked rather than failed: it follows the interface's `vehicle` state,
dropping to a quiet probe every ten seconds while that reads `asleep` and
resuming its normal cadence when the vehicle answers again. The device's
`status.online` verdict follows the interface, so it reads online while the
adapter answers whether or not the vehicle is awake.

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

### `/driver/power/regulator`

Drives an AC power controller module (triac/SSR stage with a PSM gate input
and a zero-cross detect output) from two GPIO pins, regulating a resistive
load between zero and full power. All firing decisions run in interrupt
context off the zero-cross edge, so regulation and the droop response ride
through a stalled main loop; a hardware-timer watchdog forces the gate off if
zero-cross edges stop. The regulator materialises a Device exposing writable
`control.level`, `control.mode`, and `control.enable` elements plus
`status.frequency` and `status.fault`; the device's `status.online` verdict
follows the zero-cross detector, so a lost mains reference reads offline.

`burst_fire` mode conducts whole mains cycles (never a DC-injecting half
cycle), distributing them evenly across the cycle stream; it is the right
mode behind an inverter, where phase-angle chop feeds the inverter harmonics
it handles poorly. `phase_angle` mode delays the gate within each half cycle
for continuous sub-cycle resolution and a steady per-cycle draw that meters
exactly; commanded level is linearised so 50% commands 50% power in both
modes. A droop curve, when configured, turns the regulator into a
frequency-following dump load for grid-forming inverters: output rises
linearly from zero at `droop-start` to `level` at `droop-full`, holds there
at higher frequency, and sheds below the start point, re-evaluated every
half cycle.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `device` | read/write | device name | required | Device to create or populate. |
| `psm-pin` | read/write | GPIO number | required | Gate drive output to the controller's PSM input. |
| `zc-pin` | read/write | GPIO number | required | Zero-cross detect input. |
| `psm-invert` | read/write | boolean | `false` | Drive the gate active-low. |
| `zc-edge` | read/write | `rising`, `falling`, `change` | `rising` | Zero-cross input edge; `change` suits square-wave polarity outputs. |
| `zc-pull` | read/write | `none`, `up`, `down` | `none` | Pull on the zero-cross input (open-collector detectors need `up`). |
| `mode` | read/write | `burst_fire`, `phase_angle` | `burst_fire` | Firing strategy; switchable at runtime. |
| `level` | read/write | `0` to `100` | `0` | Target power in percent; the ceiling when a droop curve is set. |
| `enable` | read/write | boolean | `true` | Master gate; disabled holds the output off without losing the level. |
| `droop-start` | read/write | hertz | `0` (disabled) | Frequency at and below which droop output is zero. |
| `droop-full` | read/write | hertz | `0` (disabled) | Frequency at which droop output reaches `level`. |
| `frequency` | read only | hertz | | Measured mains frequency from the zero-cross stream. |
| `applied-level` | read only | percent | | Level the engine is currently firing, after droop. |
| `zc-ok` | read only | boolean | | Zero-cross edges are arriving and frequency lock is held. |

```text
/driver/power/regulator/add name=dump device=dump-load psm-pin=25 zc-pin=26 level=100 droop-start=50.2 droop-full=52
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

### `/protocol/ip/*`

IP configuration for the in-tree network stack. On desktop hosts the kernel's
stack is used by default and these collections only take effect when built with
`USE_INTERNAL_IP_STACK=1`; embedded targets always use the in-tree stack.

IPv4 and IPv6 are configured through parallel collections: `address`/`address6`,
`route`/`route6`, `pool`/`pool6`. Every running Ethernet interface forms an
EUI-64 link-local address, verifies it with DAD, and publishes it as a dynamic
`address6` entry. Manual entries are only needed for global or ULA addressing.

IPv6 hosts autoconfigure by default (SLAAC, RFC 4862): each Ethernet interface
solicits routers on bring-up and consumes Router Advertisements. An advertised
prefix with the on-link flag becomes a dynamic `route6` for that prefix out the
interface; one with the autonomous flag becomes a dynamic `/128` `address6`
(prefix + EUI-64, duplicate-address-detected before use; the address itself
asserts no on-link prefix), marked `deprecated` once its
preferred lifetime lapses so new connections stop sourcing from it; a nonzero
router lifetime becomes a dynamic default `route6` via the advertising router.
These entries carry the `D` flag in `print` and expire on their advertised
lifetimes; no configuration is required to obtain a global address on a
network that advertises one.

`/protocol/ip/address` and `/protocol/ip/address6` properties:

| Property | Values | Description |
| --- | --- | --- |
| `address` | `addr/prefix` (e.g. `192.168.1.10/24`, `2001:db8::5/64`) | Address and on-link prefix to bind. |
| `interface` | interface name | Interface the address lives on. |
| `deprecated` | `yes`/`no` | `address6` only. Not chosen as a source for new connections while another address on the interface is available; set by SLAAC when the preferred lifetime lapses. |

`/protocol/ip/route` and `/protocol/ip/route6` properties:

| Property | Values | Description |
| --- | --- | --- |
| `destination` | `network/prefix` (`0.0.0.0/0`, `::/0` for default) | Destination network. |
| `gateway` | IP address | Next-hop; mutually exclusive with `blackhole`. A link-local IPv6 gateway also needs `out-interface`. |
| `out-interface` | interface name | Egress interface for directly-attached destinations. |
| `blackhole` | `yes`/`no` | Silently discard matching traffic. |
| `distance` | `0` to `255` | Route preference; lower wins. |

| Command | Description |
| --- | --- |
| `/protocol/ip/neighbour/print` | Show the IPv4 neighbour (ARP) cache: address, MAC, reachability state, retries, interface. |
| `/protocol/ip/neighbour6/print` | Show the IPv6 neighbour (ND) cache in the same shape. |

`/protocol/ip/pool6` allocates mixed-width sub-prefixes down to `/64` and
individual host addresses from `/64`s it reserves for itself. Best-fit
allocation packs around existing reservations. Static host reservations accept
any nonzero 64-bit interface ID; automatic issuance uses IDs 1..65535 per `/64`.
These allocator APIs are available for future DHCPv6 integration; the DHCPv6
client, server and lease collections are not implemented.

A pool's `prefix` is one IPv6 network, including its length. Configure a static
pool with `prefix=fd00:12:34::/48`, or request a `/56` from a parent with
`pool=upstream prefix=::/56`. Once acquired, `prefix` reports the actual network.
Setting a nonzero prefix address selects static mode and clears `pool`; setting
`pool` selects parent mode and retains the current prefix as a preferred range.
`prefix=::/60` changes the requested length while retaining the configured parent.

A running child keeps its prefix, host reservations and delegated ranges when
its parent goes offline or is removed. It continues serving its local allocation
space. When the parent returns, including recreation under the same name, it
first reserves the child's exact existing range. Success preserves the child's
running state and all reservations. Failure restarts the child and its descendant
pools, invalidates downstream consumers through their offline signals, and
attempts a new allocation. If no range is available, the child remains offline
and retries. Retaining local configuration does not establish upstream reachability.

| Property | Values | Description |
| --- | --- | --- |
| `prefix` | IPv6 network (`address/length`) | Static or acquired network. Valid lengths are 1..64; `::/length` requests a width from the configured parent. `::/0` clears the length and leaves the pool unconfigured. |
| `pool` | pool name | Parent pool to acquire from. Clearing it retains the current prefix as a static range. |
| `running`, `status` | read-only | Pool lifecycle state. A child can remain running while its parent is unavailable. |

```
/protocol/ip/address/add address=192.168.1.10/24 interface=eth0
/protocol/ip/address6/add address=2001:db8:1::10/64 interface=eth0
/protocol/ip/route6/add destination=::/0 gateway=fe80::1 out-interface=eth0
/protocol/ip/neighbour6/print
/ping address=fe80::1 iface=eth0
/protocol/ip/pool6/add name=upstream prefix=fd00:12:34::/48
/protocol/ip/pool6/add name=site pool=upstream prefix=::/56
```

### DHCPv4

#### `/protocol/dhcp/client`

Acquires an IPv4 lease on an ethernet interface. The bound address appears as a
dynamic `address`, the subnet as a dynamic connected `route`, and the offered
router as a dynamic default `route`; all three are updated in place when a
renewal changes them and destroyed when the lease is released. Replies are
accepted only for the exchange in flight and, outside REBINDING, only from the
selected server. A NAK or an expired lease restarts the client from DISCOVER.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | interface name | | Ethernet interface to acquire on. |
| `add-default-route` | `yes`/`no` | `yes` | Install the offered router as a default route. |

```
/protocol/dhcp/client/add name=wan interface=eth0
```

#### `/protocol/dhcp/server`

Answers DHCP on an ethernet interface from its own IPv4 address. Dynamic
addresses come from a `pool`; without one the server answers static leases
only. A server answers for the static leases in its subnet and for the dynamic
leases its pool allocated, and stays silent on an INIT-REBOOT or broadcast
REBINDING from a client it holds no lease for.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | interface name | | Interface to serve on; must carry an `address`. |
| `pool` | `pool` name | | Dynamic address range; must lie inside the interface subnet. |
| `lease-time` | duration | `1d` | Lease time granted on ACK. |
| `mac-limit` | count | `0` (unlimited) | Maximum leases per client MAC. |
| `add-default-gateway` | `yes`/`no` | `yes` | Advertise the server address as the router unless an option 3 is configured. |
| `options` | `option` names | | Extra options appended to every OFFER and ACK. |

```
/protocol/ip/pool/add name=lan start=192.168.1.100 end=192.168.1.199
/protocol/dhcp/server/add name=lan interface=eth1 pool=lan lease-time=12h
```

#### `/protocol/dhcp/lease`

One entry per bound address. A lease added here is static: it never expires
and is offered to its MAC whenever that client asks. Leases the server hands
out are dynamic, carry the pool that allocated them, and expire on their own,
returning the reservation to that pool; a DISCOVER holds a fresh offer for 30
seconds and an ACK extends the lease to the server's `lease-time`. A client
that DECLINEs its address leaves the lease quarantined for ten minutes, during
which the address is neither offered nor matched to any client.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `address` | IPv4 address | required | Leased address. |
| `mac` | MAC address | required | Client hardware address. |
| `hostname` | text | | Hostname the client sent. |
| `expires` | date-time | | Wall-clock expiry of a dynamic lease; the deadline itself runs on the monotonic clock. |
| `pool` | `pool` name | | Pool that allocated a dynamic lease. |
| `declined` | boolean | read only | The client declined this address; the lease is in quarantine. |

```
/protocol/dhcp/lease/add name=printer address=192.168.1.20 mac=00:11:22:33:44:55
```

#### `/protocol/dhcp/option`

A named option value the server appends to its replies, referenced from the
server's `options` list. The value is parsed according to `type`; `auto`
infers the type for well-known codes and falls back to raw hex bytes.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `code` | `1` to `254` | required | Option code. |
| `type` | `auto`, `bytes`, `ip`, `ip_list`, `u8`, `u16`, `u32`, `string`, `bool` | `auto` | How `value` is encoded. |
| `value` | text | | Value in the form the type expects; `ip_list` is comma-separated, `bytes` is hex. |

```
/protocol/dhcp/option/add name=dns code=6 value=192.168.1.1,1.1.1.1
/protocol/dhcp/server/set lan options=dns
```

### DHCPv6

The DHCPv6 message codec and client are present; there are no server or lease
commands yet. DHCPv6 address and prefix configuration coexists with Router
Advertisement discovery of default routers.

#### Client

`/protocol/dhcp/client6` requests host addresses (`IA_NA`) and/or delegated
prefixes (`IA_PD`). Each bound address appears as a dynamic `address6`. The
delegated prefix appears as one dynamic `pool6` named `pool-name`, a stable
identity for downstream consumers to draw from: the pool carries the freshest
delegated prefix and is renumbered in place when the server replaces it, and the
delegation's remaining lifetimes ride with it and cap whatever an `ra` service
drawing from it advertises. Bindings are tracked by identity, so a renumbering
Reply that deprecates the old address beside its replacement keeps both until the
old one lapses. Each IA is renewed at its own T1, rebound at T2 and each binding
dropped at its own valid lifetime; an address is marked deprecated once its
preferred lifetime passes. Only built with the in-tree IP stack; on desktop hosts the kernel's own
client owns the lease.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | interface name | | Interface to solicit on. |
| `request-address` | `yes`/`no` | `yes` | Request an `IA_NA` host address. |
| `request-prefix` | `yes`/`no` | `no` | Request an `IA_PD` delegated prefix. |
| `pool-name` | name | `<name>.pd` | Name of the dynamic pool carrying the delegated prefix. |

```
/protocol/dhcp/client6/add name=wan interface=eth0 request-prefix=true pool-name=site
```

### `/protocol/ip/ra`

The Router Advertisement service makes this node an IPv6 router for a link:
it advertises one /64 prefix for SLAAC, periodically and in answer to Router
Solicitations, and withdraws itself (zero router-lifetime) on shutdown or when
its interface, pool or prefix changes. The prefix comes from a `pool6` (one /64
held for the service's lifetime, released when the pool goes offline or is
renumbered, so a DHCPv6-PD delegation flows straight through) or is given
statically. The advertisement is applied to the advertising link exactly as a
received one would be: the prefix becomes a dynamic on-link `route6` and the
node's own prefix+EUI-64 becomes a dynamic `/128` `address6` after DAD, both
refreshed by every advertisement sent. Only built with the in-tree IP stack
and `GATEWAY=1`; on desktop hosts the kernel owns the router role.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `interface` | interface name | | Interface to advertise on. |
| `pool` | `pool6` name | | Pool to draw the /64 from; its own prefix must be shorter than /64. |
| `prefix` | `prefix/64` | | Static alternative to `pool`. |
| `interval` | `4s` to `1800s` | `600s` | Maximum unsolicited advertisement interval; each gap is random between a third of this and this (fixed at this below 9s), the first three capped at 16s. |
| `router-lifetime` | `0s`, or `interval` to `9000s` | `30m` | Default-router lifetime; `0s` advertises prefix only. |
| `valid-lifetime` | duration | `30d` | Prefix valid lifetime; capped to the remaining lifetime of a delegated pool prefix. |
| `preferred-lifetime` | duration <= `valid-lifetime` | `7d` | Prefix preferred lifetime; capped the same way. |
| `managed` | `yes`/`no` | `no` | M flag: clients should use DHCPv6 for addresses. |
| `other-config` | `yes`/`no` | `no` | O flag: clients should use DHCPv6 for other config. |
| `dns` | IPv6 addresses | empty | RDNSS servers advertised. |

Solicited advertisements are delayed by up to 500ms and never sent within 3s of
the previous one. Durations with a bare `m` suffix parse as metres (the SI unit
system owns unquoted suffixes); write minutes quoted (`"30m"`) or in another unit.

```
# advertise a /64 out of the site delegation, with DNS
/protocol/ip/pool6/add name=site prefix=2001:db8:40::/56
/protocol/ip/ra/add name=lan interface=eth1 pool=site dns="2001:db8:40::53"
```
### Linux kernel data plane (`/system/linux`, `/system/netlink`)

Linux builds without the in-tree IP stack let the kernel forward. OpenWatt mirrors its
`address`/`address6` and `route`/`route6` collections into the kernel over rtnetlink: `distance`
becomes the kernel metric (offset by one, so distance 0 is metric 1 rather than the IPv6 default of
1024), `blackhole=yes` installs a `blackhole` route, and every entry is
tagged `proto 80` so only OpenWatt's own entries are ever withdrawn; entries left behind by a
previous run are swept at startup. A write the kernel rejects is logged once and retried with
backoff until it is accepted. The kernel owns ARP and ND on
these builds; `/protocol/ip/neighbour/print` and `/protocol/ip/neighbour6/print` show the
kernel's tables (address, MAC, state, interface) in place of the internal cache.

| Command | Description |
| --- | --- |
| `/system/linux/print [format=ip\|interfaces]` | Dumps the live kernel network state, both IP families. `ip` (default) is an `ip -b`-runnable reproduction script; `interfaces` is `/etc/network/interfaces` form with an `inet6` stanza per interface that carries IPv6 state. The kernel's own loopback and IPv6 link-local addresses are omitted. |
| `/system/netlink/add-route destination=<address[/prefix]> gateway=<address>` | Installs a kernel route directly, bypassing the collections. Either family. |
| `/system/netlink/add-neighbour address=<ip> mac=<mac> iface=<netdev>` | Installs a permanent kernel neighbour entry. Either family. |
| `/system/netlink/del-neighbour address=<ip> iface=<netdev>` | Removes a kernel neighbour entry. |

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

### `/protocol/tesla/session`

Vehicle sessions report command rejection separately from session failure.
Session counter, signature, epoch, and clock faults trigger a fresh authenticated
handshake and timed back-off for the affected operation. A successful handshake
does not clear that operation's delay. A Ready session reconnects after 45 seconds without
an authenticated reply; unrelated or unauthenticated notifications do not extend that deadline.
Controls are not automatically replayed after reconnecting. Check observed
vehicle state before repeating a command whose outcome is unknown.

Failures back off per operation; drive, location, closures and tire-pressure polls
have independent records. Busy, timeout and unclassified action rejections delay
the next attempt by 5 seconds, doubling to a maximum of 5 minutes. A successful
reply clears that operation's timed back-off. Controls still require a new user
request after the delay; they are never queued for automatic retry.

Authenticated permanent rejections latch the affected operation. Key and access
failures affecting the whole session prevent validation. Session `status` shows
the affected operation, reason and whether the block is timed or latched.
Unsigned faults cause timed back-off only. Key enrollment allows a 60-second
approval window before backing off and trying again.

Records belong to the scanner/VIN and survive BLE reconnects, session recreation,
scanner restarts and unchanged VIN configuration. Latches clear on explicit
reset, a scanner secret change, detection of changed loaded public-key material,
VIN removal, scanner removal or OpenWatt process restart. A BLE address change,
ordinary reconnect or unrelated successful command does not clear a latch.
Changing vehicle permissions does not itself notify OpenWatt: correct the cause,
then explicitly reset. Reset restarts the session and discards pending controls.

### `/protocol/tesla/vehicle-scanner`

| Command | Arguments | Description |
| --- | --- | --- |
| `backoff` | `scanner=<name> vin=<VIN>` | Show retained failure reasons, including when no live vehicle session exists. |
| `reset-backoff` | `scanner=<name> vin=<VIN>` | Clear all failure records for this VIN and restart its session. Does not replay controls. |

Encrypted vehicle responses remain required. Legacy firmware support requires
development and acceptance testing with an old offline car.

### `/apps/energy/appliance`

With `vin=<VIN>` and no explicit `device`, the appliance uses the VIN-rooted
vehicle device and its `charge` port. `device` remains empty; changing or clearing
`vin` changes or removes that fallback. An explicit `device` takes precedence;
clearing it restores VIN lookup. Use `charge=<circuit>` to override the port's
VIN-derived circuit.

`device`, `meter`, and `state` accept component paths before their targets exist.
The configured path remains visible while unresolved. While the energy app is
started, paths resolve automatically when a device appears or its tree gains
children, including children received later over sync. Resolution occurs before
the next topology rebuild. Device/subtree removal and recreation remain separate
lifecycle work in `TODO.md`.

### `/automation`

A rule that runs a console script when a signal fires (see [AUTOMATION.md](AUTOMATION.md)).
Triggers are signal URIs, `[provider:|@]body[?k=v&k=v]`; `@x` is sugar for `element:x`. Quote any
URI containing `?`, `=` or `@`, since the argument parser reserves them.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `on` | URI list | none | Triggers, comma-separated. `@path` (element change), `every:<dur>[?repeat=false]`, `at:<hh:mm>[?days=mon,wed,fri]`, `when:<datetime>`, `object:<name>?state=online\|offline\|destroyed`. |
| `schedule` | duration | none | Write-only sugar for `on="every:<dur>"`. Shares the slot with `on`. |
| `at` | `hh:mm` | none | Write-only sugar for `on="at:<hh:mm>"`. |
| `when` | datetime | none | Write-only sugar for `on="when:<datetime>"`. |
| `if` | expression | none | Quoted boolean gate; a falsey result skips the action. Reads elements by `@path`, compares with units. |
| `edge` | `level`, `rising`, `falling` | `level` | Which transitions of `if` fire. Requires `if`. |
| `for` | duration | `0` | The qualifying state must hold this long before firing; one run per episode. Requires `if`. |
| `debounce` | duration | `0` | Trailing edge: act once the trigger stream settles; `$value` is the settled datum. |
| `throttle` | duration | `0` | Leading edge: act, then lock out for the window. |
| `rate` | per-time (`12/h`, `4/min`, `0.2/s`) | `0` | Token-bucket refill rate; canonicalised to `/s`. `Hz` is rejected (angular). |
| `burst` | count | `1` | Token-bucket capacity. |
| `do` | `{ script }` | none | The action. `$value` is the datum that fired the trigger (null for time). |
| `run_count`, `next_run`, `last_run` | read-only | | `next_run` folds in pending debounce settles and `for` deadlines. |

Shaping and `edge`/`for` hot-apply to a running rule. A trigger naming an element that does not
exist yet parks the rule in `Starting` (`element not found: <path>`) and arms when it appears.

```text
/automation/add name=door-light on="@door.open" do={ /element/set element=hall.light value=$value }
/automation/add name=poll schedule=5m do={ /device/print }
/automation/add name=weekday on="at:18:00?days=mon,wed,fri" do={ /notify "evening" }
/automation/add name=once on="every:30m?repeat=false" do={ /notify "runs once, in 30 min" }
/automation/add name=peak on="@site.power" if="@site.power > 2000W" edge=rising do={ /notify "crossed 2kW" }
/automation/add name=ajar on="@door.open" if="@door.open" for=5m do={ /notify "door left open 5 min" }
/automation/add name=shut on="@door.open" if="@door.open" edge=falling for=1h do={ /notify "long closed" }
/automation/add name=multi on="@door.open","every:1h" do={ /device/print }
/automation/add name=motion on="@pir.motion" debounce=500ms do={ /element/set element=porch.light value=$value }
/automation/add name=cycles on="@hws.demand" rate=12/h burst=3 do={ /element/set element=hws.enable value=1 }
/automation/add name=up on="object:inv?state=online" do={ /notify "inverter link up" }
/automation/set name=door-light if="@door.open"
/automation/print
```

### `/protocol/tesla/twc`

A TWC master runs the Tesla Wall Connector (Gen2) master role on an RS485 bus
reached through a `/interface/tesla-twc` interface. It announces itself, then
round-robins heartbeats and status requests across the chargers on the bus.
Slaves that answer the announcement with a link-ready message are discovered
automatically: each one gets a charger record, a dynamic `/binding/tesla/twc`
entry, and a Device, all named for the slave's 16-bit bus id (e.g. `twc_6820`).
Name collisions get a numeric suffix. Existing manually configured bindings
for the same master and slave are reused; a second binding cannot take over
an already-bound charger.
No slave addresses are configured on the master.

The bus allows one master. On startup the master listens for a few seconds
before claiming the bus, and stands by if another master is heard - snooping
the slaves' replies, discovering chargers from heartbeats as well as link-ready
announcements, so devices stay populated read-only - then takes over once
that master has been silent for ~15s. Hearing another master while active
stands down immediately. Our bus id is the low 16 bits of the node id; a master
frame carrying our own id while we are silent is an id collision with another
node, reported as a config error that fails the master. The status message
names the situation throughout.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `interface` | read/write | interface name | required | The `tesla-twc` interface carrying the bus. |
| `stream` | read/write | stream name | required | Byte stream carrying the bus; the master creates and owns a `tesla-twc` interface over it. |
| `max-current` | read/write | amps | 32A | Shared circuit budget for the entire fleet, not a per-charger limit. Minimum 5A. |

The master divides the circuit budget into equal shares, redistributing unused
shares when a charger's request, optional cap, or hardware maximum is lower.
Reductions retain their previous reservation until a heartbeat
confirms the new limit and measured current has fallen; missing replies never
release current for another charger. No new increases are granted while a known
charger lacks a fresh heartbeat. Lowering the circuit budget drains existing
allocations first and blocks increases during that transition. Budgets below
5A per eligible charger are not supported yet: no new allocations are issued,
existing grants are not revoked, and stop/admission policy remains TODO.

`interface` and `stream` are mutually exclusive: setting either replaces the
other, and the interface created for a `stream` is destroyed with the master.
Naming a stream is the short form, and is all that a bus of its own needs;
name an interface instead when it is shared, bridged, or captured.

```text
/protocol/tesla/twc add name=shed stream=shed_rs485

/interface/tesla-twc add name=shed_twc stream=shed_rs485
/protocol/tesla/twc add name=shed interface=shed_twc
```

### `/binding/tesla/twc`

Bridges one charger on a master's bus to its Device. Its properties identify the
association; charger capabilities, controls, and operating state are Device elements.
A manually configured binding pre-adopts its slave id. Allocation waits for a
hardware maximum and fresh heartbeat data.

| Property | Access | Values | Default | Description |
| --- | --- | --- | --- | --- |
| `device` | read/write | device name | required | Device to create or populate. |
| `master` | read/write | TWC master name | required | The `/protocol/tesla/twc` master owning the bus. |
| `slave_id` | read/write | 16-bit id | required | The charger's TWC bus id. |

The Device's `grid.control` elements carry amp quantities:

| Element | Access | Meaning |
| --- | --- | --- |
| `setpoint` | read/write | Requested current, initially the discovered hardware maximum. Allocation never overwrites it. |
| `cap` | read/write | Optional per-charger ceiling; zero means no secondary cap. Nonzero values must be at least 5A. |
| `max` | read | Discovered hardware maximum. |
| `allocated` | read | Most recent current limit commanded by the master, initially zero before admission. |
| `accepted` | read | Current limit reported by the charger in its heartbeat. |

`setpoint` and `cap` are writable only while the associated master is running
and active on the bus. Listening, standby, and offline transitions revoke this
binding's write permission; taking over restores it. Client notification of these
access changes remains TODO, so already-connected clients may show stale controls.

The existing `grid.meter.current` is measured consumption. `allocated` and
`accepted` may differ while a command is awaiting acknowledgement. Setpoints
below 5A retain the existing 5A floor for admitted chargers (`can_disable=false`).
Stopping a charger requires the vehicle-side control path.

```text
/protocol/tesla/twc add name=twc0 stream=shed_rs485 max-current=32A
/binding/tesla/twc add name=twc_6820 device=twc_6820 master=twc0 slave_id=0x6820
/element/set element=twc_6820.grid.control.cap value=20A
```

### `/sync/udp-server`

A datagram sync listener owns one UDP endpoint per selected local endpoint. It
spawns a dynamic `/sync/peer` for the first datagram from each unknown
`(local endpoint, remote endpoint)` pair, and each peer replies through the
endpoint that received it. Datagram links carry no death signal, so a peer whose
source goes quiet is swept after the idle timeout and a reappearing source
simply spawns afresh.

Every UDP discovery domain creates one dynamic, temporary server as its
exclusive child. That child uses the discovery domain's endpoints directly
and has no independent endpoint configuration. Instances added explicitly
serve hand-wired datagram sync and always own their sockets.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `bind` | endpoint list | empty | Exact local endpoints; an omitted port uses `port`. |
| `interface` | interface list | empty | Bind AF_ETHERNET and every configured IP endpoint on these interfaces. |
| `port` | `1` to `65535` | `4826` | Port used by named interfaces and bind entries that omit one. |
| `encoder` | `json`, `binary` | `binary` | Encoding for spawned peers. |
| `timeout` | duration | `5m` | Idle time after which a silent peer is swept. |

At least one of `bind` or `interface` is required for an explicit server. The
server is Running while at least one local endpoint is open; other configured
endpoints can appear or disappear independently.

### `/sync/peer`

`transport` binds a peer to an existing interface. Alternatively, `remote`
opens a connected UDP endpoint owned by the peer. The last of `transport` and
`remote` set wins.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `transport` | interface | none | An interface delivering raw frames (a WebSocket, a UDP interface). |
| `remote` | `address:port`, `[ipv6]:port`, `[mac]:port` | none | Remote UDP peer. The address and port are both required. |
| `encoder` | `json`, `binary` | `binary` | Wire encoding for this session. |
| `time-authority` | `yes`/`no` | `no` | Take this peer as the local clock source. A peering claim sets it on the member for its first claimant. |

### `/sync/ws-server`

Binds a URI on an HTTP server and spawns one dynamic `/sync/peer` per accepted
WebSocket connection; the peer is destroyed when the socket closes. This is the
transport browser clients use. Requires HTTP in the build.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `http-server` | HTTP server | none | The `/protocol/http/server` to bind on. |
| `uri` | path | none | URI the WebSocket upgrade is accepted at. |
| `encoder` | `json`, `binary` | `json` | Encoding for spawned peers. |

### `/sync` commands

Operate an existing peer session from the local console. Each takes `peer=`.

| Command | Arguments | Description |
| --- | --- | --- |
| `/sync console` | `peer=` | Open an interactive console session on the remote node over the sync channel. |
| `/sync log-sub` | `peer=`, `severity=`, `tag=` | Tap the remote node's log stream at the given severity, optionally filtered by tag. |
| `/sync model-sub` | `peer=`, `pattern=`, `once=` | Subscribe to the remote data model by path pattern; `once=yes` fetches and closes. |

See [SYNC.md](SYNC.md) for the channel these ride.

### `/sync/discover/udp`

A discovery domain beacons this node's peering identity (node-id, name, role,
cluster, claim state) from each address it binds, feeds received beacons into
the neighbour table, and creates one dynamic sync server over the same
endpoints. Domains are the opt-in: no domain configured, no beacons or inbound
sync accepted on that segment.

ESP provisioning defaults create a discovery domain on the setup AP and set
`/sync/peering/set role=member`. Loading a `startup.conf` replaces those defaults;
it must configure its own discovery domains and peering role.

`bind` takes one or more local endpoints and beacons from each. The domain's
`port` fills only entries whose `InetAddress.port` is zero; an explicit port in
an entry always wins. AF_ETHERNET and IPv4 entries are passed directly to
socket bind; other families are not discovery sources. Wildcard overlap,
duplicate listeners, and address availability therefore use the UDP stack's
normal bind rules, with address reuse disabled.

`interface` selects one or more named interfaces and listens on AF_ETHERNET and
every configured IPv4 endpoint. It also selects VLANs unambiguously when they
share their parent's MAC address. The domain is Running while at least one
resolved endpoint is Running; other configured endpoints can appear or
disappear independently.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `bind` | endpoint list | empty | Exact local endpoints; an omitted port uses `port`. |
| `interface` | interface list | empty | Bind AF_ETHERNET and every configured IPv4 endpoint on these interfaces. |
| `port` | `1` to `65535` | `4826` | Peer service port used by named interfaces and bind entries that omit one. Discovery and inbound sync share this socket. |
| `multicast` | `true` or `false` | `true` | Use `239.255.79.87` for IPv4 discovery. False uses directed or limited broadcast. |
| `interval` | duration | `30s` | Beacon cadence. |

At least one of `bind` or `interface` is required.

```text
/sync/discover/udp add name=fleet bind=00:00:00:00:00:00
/sync/discover/udp add name=iot bind=[28:84:85:54:FB:08]:7100
/sync/discover/udp add name=lan interface=ether1,vlan20 port=7100
/sync/discover/udp add name=site bind=0.0.0.0
/sync/discover/udp add name=multi bind=0.0.0.0,192.168.0.10:1234 port=6667
```

The last example binds `0.0.0.0:6667` and `192.168.0.10:1234`.

IPv4 uses multicast by default. The domain owns one wildcard socket per port and
joins the group on every selected local address, so multiple interfaces do not
require address reuse. `multicast=false` uses each exact bind's directed
broadcast when available; a wildcard bind uses `255.255.255.255`.

### `/sync/neighbor`

`print` lists every node heard through any discovery domain: node-id, name,
role, cluster, claim state, and the age of its last beacon, followed by one
line per link: the interface a beacon arrived on, the source endpoint, and its
age. A multi-homed node shows one link per (interface, address) pair it beacons
through; the peering agent claims via the most preferable live link. Nodes and
links age out after 10 minutes of silence.

```text
/sync/discover/udp add name=lan interface=ether1,vlan20
/sync/neighbor print
```

### `/sync/peering`

The peering agent (see [PEERING.md](PEERING.md)) is the node-global
auto-peering policy: it does not exist as a collection, just `set`/`print` on a
singleton. Setting `role=` is the opt-in (it implies `enabled=yes`).

A `member` advertises itself as claimable through the configured discovery
domains and accepts claims arriving on the sync channel. A member accepts any
number of claimants from a single cluster (two claimants is the dual-authority
shape); a claim naming a second cluster is refused. Claims are runtime state:
when the last claimant's session dies the member reverts to unbound and is
re-claimed within a beacon interval.

An `authority` listens for members' sessions through every active discovery
endpoint. Each discovery domain owns one dynamic sync server and demultiplexes
announcements from session frames before handing the latter to its child. The
child opens no sockets; the endpoint set follows the discovery interfaces and
addresses as they appear or disappear.

A `member` sweeps the neighbour table every few seconds and opens a session to
each authority of its fleet: it opens a connected UDP endpoint from that
authority's most preferable live link (bound to the address and station on
which the beacon arrived, toward its source address and port) and spawns a dynamic
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

On a successful claim the authority also taps the member's log stream (`collect-logs`,
default on), so a fleet's logs converge on its authority. The tap is re-armed by the claim
itself, so it follows a member across reboots even though the session peer is recreated each
time.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `yes`/`no` | `no` | Participate in peering; implied by setting `role`. |
| `role` | `member`, `authority` | none | This node's peering role. |
| `cluster` | name | empty | Fleet this node belongs to. A member with no cluster accepts (and adopts) any claimant's cluster, logging loudly; set one to pin the node. |
| `priority` | number | `100` | Authority election precedence; lower wins, node-id breaks ties. |
| `claim` | path glob | `*` | Authority only: which member names to adopt. |
| `secret` | string | empty | The fleet key, set by hand. Normally unset: the authority mints one at first adoption and hands it to each factory member inside the claim; thereafter claims prove it with an HMAC over the member's per-session hello nonce, so the key never travels again and a captured claim cannot replay. |
| `collect-logs` | `yes`/`no` | `yes` | Authority only: tap each claimed member's log stream. Re-armed on every claim, so it survives a member reconnecting under a fresh session. |
| `log-severity` | severity | `info` | Authority only: max severity requested from claimed members' logs (`emergency`..`trace`). Raising it raises the member's own ingress level. |

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

