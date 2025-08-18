# Contributing to OpenWatt

We welcome contributions from the community! Whether you're fixing a bug, adding a new feature, or improving documentation, your help is appreciated.

## Development Setup

OpenWatt uses [the D language](https://dlang.org). Before you can build OpenWatt, you need a working D compiler.

Most native programmers (particularly C++ programmers) will find this familiar and can generally learn by osmosis. D can link directly with C/C++ code if necessary to take advantage of existing libraries.

### D Compiler

This project supports the DMD, LDC, and GDC compilers. You can install from your package manager, or using the official `install.sh` script from dlang.org.

For detailed instructions, please follow the [official D language installation guide](https://dlang.org/install.html).

## Build Process

The project uses a `Makefile` for building. The build process can be configured with several options.

Windows/Visual Studio users may alternatively use MSBuild via the solution file (`openwatt.sln`) to build and run the project in Visual Studio.

### Basic Build

To build the project with default settings (debug build with DMD on x86_64), simply run:

```bash
make
```

### Build Configurations

You can customize the build by setting the following variables:

- `COMPILER`: The D compiler to use. Supported values are `dmd` (default), `ldc`, and `gdc`.
- `CONFIG`: The build configuration. Supported values are `debug` (default), `release`, and `unittest`.
- `PLATFORM`: The target architecture.
    - For `dmd`: `x86_64` (default), `x86`
    - For `ldc`: `x86_64` (default), `x86`, `arm64`, `arm`, `riscv64`

**Examples:**

- Build in release mode with LDC:
  ```bash
  make COMPILER=ldc CONFIG=release
  ```

- Build for ARM64 with LDC:
  ```bash
  make COMPILER=ldc PLATFORM=arm64
  ```

- Build and run the unit tests:
  ```bash
  make CONFIG=unittest
  ./bin/$(PLATFORM)_unittest/openwatt_test
  ```
  Replace `$(PLATFORM)` with your target platform (e.g., `x86_64`).

### Cleaning the Build

To remove all generated build files, run:

```bash
make clean
```

## Pull Request Process

1.  Fork the repository.
2.  Create a new branch for your feature or bug fix (`git checkout -b feature/your-feature-name`).
3.  Make your changes and commit them with a clear and descriptive message.
4.  Push your changes to your fork (`git push origin feature/your-feature-name`).
5.  Create a pull request to the main repository.

Please make sure that your code adheres to the project's coding standards and that you have added appropriate tests for any new functionality.

## Coding Style

To maintain consistency across the codebase, please follow these coding style guidelines.

### Naming Conventions

- **Types (`class`, `struct`, `union`, `enum`):** `PascalCase`
- **Variables, functions, enum members:** `snake_case`
- **Templates:**
    - Templates that resolve to a type: `PascalCase`
    - Templates that resolve to a value: `snake_case`
    - Macro-like templates: `SCREAMING_SNAKE`

### Bracing and Indentation

- **Bracing:** Use the Allman style, omitting braces for single line body.
  ```d
  if (condition)
  {
      // code
      // ...
  }

  if (another)
      do_one_thing();
  ```
- **Indentation:** 4 spaces.

### Memory Management and Function Attributes

The OpenWatt kernel is intended to be usable on tiny microcontrollers, so performance and memory awareness are essential.

- **Memory Allocation:** Allocation should be deliberate and infrequent to minimize memory fragmentation.
- **Function Attributes:** Functions should generally be marked `@nogc` and `nothrow` wherever possible.

Application-level features which make no sense on microcontrollers may deviate from these rules when useful.
