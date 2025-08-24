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
add name=gw_meter interface=goodwe_meter address=2 profile=gm1000 # from conf/modbus_profiles/
```

Configuring the remote server will populate the runtime with a `Device` representing the data sampled from the meter, which can be used by local program logic. This bridge configuration solves the problem where a modbus appliance (the meter) on a single hardware bus can not receive requests from multiple masters.
