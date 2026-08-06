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

Stream collections additionally report status and traffic counters such as
`link-status`, `tx-bytes`, `rx-bytes`, and current and maximum transfer rates.

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
| `/stream/serial/lines <name>` | all platforms | Prints the current modem-line state for an open serial stream, including RTS, CTS, DTR, DSR, DCD, and RI where supported. |
| `/stream/serial/devices` | POSIX hosts | Lists detected serial devices. |

### `/stream/usb-serial`

This stream exposes the native USB programming port on supported ESP targets.
It uses USB Serial/JTAG on C3, C5, C6, H2, P4, and S3, and USB CDC on S2. It has
no transport properties.

```text
/stream/usb-serial/add name=console
/console/session/add name=default stream=console profile=vt100 initial-command="/log/print --stream"
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
without the IP stack carry these peers only.

The interface self-configures its L2MTU from the peer's datagram payload MTU
(assuming a 1500-byte link MTU: 1472 for IPv4, 1452 for IPv6, 1474 for ether);
`l2mtu` may be lowered by the user.

| Property | Values | Default | Description |
| --- | --- | --- | --- |
| `local-host` | host or address | wildcard | Local address to bind. |
| `local-port` | `0` to `65535` | `0` | Local port; zero requests an ephemeral port. |
| `remote-host` | host, address or MAC | none | Default datagram destination. |
| `remote-port` | `1` to `65535` | with remote-host | Default destination port. |
