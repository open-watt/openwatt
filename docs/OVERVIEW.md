# Overview

This document provides a detailed overview of the project, structure, terminology, and module layout.

At the highest level, this project implements a network router for a broad range of industrial and IoT protocols and common network standards, and combines that functionality with comprehensive protocol analysis and command & control logic.

It combines functionality of an Industrial/IoT gateway with a conventional network router, and facilitates services for equipment or ecosystem management and automation.

It has applications in energy management, industrial environments, home automation, network monitoring/management, and many more.

## Project Structure

The project is organized into the following main directories:

- **`src/apps`**: Contains high-level application logic.
- **`src/manager`**: Contains the core components of the system.
- **`src/protocol`**: Implements various communication protocols.
- **`src/router`**: Implements the network router.

## Terminology

### Base System Concepts

- **Module**: A self-contained unit of functionality that can be dynamically loaded into the system. This is the primary mechanism for extending the platform.
- **Console**: The main interface for interacting with the system at runtime. It provides a [command-line interface](CLI.md) for inspecting and managing components.
- **Session**: Represents a single connection to the console, for example, through a telnet or a local terminal.
- **Command**: A specific operation that can be executed through the console.
- **Collection**: A container for managing a group of related runtime objects, such as interfaces or protocol instances.

### Network/Router Concepts

- **Interface**: A packet interface, ie; hardware ports (ethernet, CAN, etc), or virtual interfaces like parsing Modbus frames from a serial stream.
- **Stream**: A byte stream data source, ie; serial port, TCP socket, file, etc).
- **Protocol**: An implementation of a specific communication standard, such as Modbus, MQTT, or HTTP. Protocols are used to decode and encode data transmitted over an interface.

### Database and Management Concepts

- **Device**: A high-level component that represents a logical device, such as an inverter, a battery, or a sensor. It serves as the root for all data elements related to that device.
- **Component**: A container for organizing runtime data Elements into conceptual bundles.
- **Element**: The smallest unit of data in the system, representing a single value or piece of information, such as a temperature reading or a voltage measurement.
- **Sampler**: A component that is responsible for periodically reading data from a device and updating the corresponding elements in the system. Samplers interface Elements with Protocol implementations.
- **Subscriber**: A component that is subscribed to changes in element state, allowing for event-driven logic and automation.
