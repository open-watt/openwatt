# OpenWatt

OpenWatt is a comprehensive energy management and home/industrial automation platform. It provides a powerful and flexible router for industrial and IoT communications, coupled with an adaptable logic layer for monitoring, recording, and managing data from a wide range of devices.

## Features

- **Industrial/IoT Communications Router:** A versatile router that supports a broad range of protocols to connect to different equipment, such as inverters, batteries, sensors, and controls.
- **Data Monitoring and Recording:** A robust data logging and monitoring system that provides real-time insights into your energy consumption and production.
- **Automation and Management:** A powerful logic layer that allows you to create custom rules and automation to optimize your energy usage and manage your devices.
- **Extensible and Modular:** Designed to be extensible, allowing you to add support for new devices and protocols.

## Documentation

For a detailed overview of the project structure, terminology, and module layout, please see our [System Overview](docs/OVERVIEW.md).

A quick reference for the project's feature set is available in the [Feature Set](docs/FEATURES.md) document.

For details on the command-line interface and startup configuration, see the [CLI Documentation](docs/CLI.md).

## Getting Started

### Prerequisites

Before you can build OpenWatt, you need a working D compiler. You can find installation instructions on the official D language website:

- [D Language Installation Guide](https://dlang.org/install.html)

### Building

1.  Clone the repository:
    ```bash
    git clone https://github.com/open-watt/openwatt.git
    cd openwatt
    ```

2.  Build the project using the Makefile:
    ```bash
    make
    ```
    This will create a debug build using the DMD compiler by default. For more advanced build options (e.g., building with LDC/GDC or creating a release build), please see the [Contribution Guide](CONTRIBUTING.md#build-process).

    Windows users can also use the Visual Studio solution file (`openwatt.sln`) to build and run the project.

## Licensing

This project is dual-licensed.

- **Non-Commercial and Educational Use:** For non-commercial and educational use, this project is licensed under the Mozilla Public License, version 2.0. The full text of this license can be found in the [LICENSE-MPL-2.0.md](LICENSE-MPL-2.0.md) file.
- **Commercial Use:** For commercial use, a separate licensing agreement is required. Please see the [LICENSE.md](LICENSE.md) file for more information.

## Contributing

Contributions are welcome! We have a dedicated [Contribution Guide](CONTRIBUTING.md) with detailed instructions on how to set up your development environment, build the project, and submit pull requests.

## Contact

For commercial licensing inquiries or other questions, please contact the project owner.
