# Feature Set

This section lists the current and planned features of the OpenWatt platform.

| Feature                        | Status  | Notes                                                              |
| ------------------------------ | ------- | ------------------------------------------------------------------ |
| **Core**                       |         |                                                                    |
| Modular Component Architecture | Working | The system is built on a flexible and extensible component model.  |
| Plugin Support                 | TODO    | Allow for runtime extension of the system is TODO.                 |
| Data/Network Routing Engine    | Working | A network routing engine for various communications.               |
| Console Interface              | Working | Provides a command-line interface for system management.           |
| Web Interface                  | Planned | Needs a web interface for device configuration.                    |
| App Interface                  | Planned | Phone app for monitoring/managing instances.                       |
| Data Logging                   | Planned | Recording of signal/data streams.                                  |
| **Protocols**                  |         |                                                                    |
| CAN bus                        | Working | Packet interface and routing.                                      |
| DNS                            | Alpha   | mDNS working, DNS is TODO.                                         |
| HTTP                           | Working | Client and server.                                                 |
| HTTPS                          | Planned | Needs TLS stream.                                                  |
| Modbus                         | Working | Packet interface, routing, and protocol decoding/sampling.         |
| MQTT                           | WIP     | Client and broker. Needs polish + testing.                         |
| SNMP                           | Planned |                                                                    |
| Telnet                         | Working | Telnet console sessions working, telnet data streams TODO.         |
| Tesla TWC                      | Working | Tesla Wall Connector 2 packet interface and master implementation. |
| Wireshark/PCAP                 | Working | PCAP logging working, rpcapd is TODO. (remote wireshark)           |
| Zigbee                         | WIP     | EZSP driver comms working, runtime management WIP.                 |
| **Applications**               |         |                                                                    |
| Energy Management              | Alpha   | Core application for monitoring and managing energy systems.       |
| Automation Engine              | Planned | Runtime events to bind automation rules.                           |
| **Device Support**             |         |                                                                    |
| GoodWe inverters               | Working |                                                                    |
| Energy meters                  | Various | Numerous energy meters are supported.                              |
| Pylon BMS                      | Working | Monitor/control Pylon BMS.                                         |
| SmartEVSE                      | WIP     | Control SmartEVSE device. (modbus TODO, HTTP TODO)                 |
| Tesla TWC2                     | Working | Control Tesla EVSE.                                                |
| ...                            |         | etc... and lots more to come!                                      |
