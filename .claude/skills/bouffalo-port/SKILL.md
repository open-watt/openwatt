---
name: bouffalo-port
description: Bouffalo Labs (BL808/BL618) platform port -- build, flash, debug, bare-metal D runtime, dual-core IPC, and known pitfalls. Use when working on any Bouffalo variant, fixing bare-metal issues, or debugging the RISC-V startup/memory/interrupt stack.
---

# Bouffalo Labs Platform Skill

You are working on Bouffalo Labs RISC-V platform support for OpenWatt. All Bouffalo targets run bare-metal (no RTOS), using LDC to cross-compile D to RISC-V. Two chips are supported:

- **BL808** -- Dual-core: T-Head C906 (RV64GC, "D0") + T-Head E907 (RV32IMAFC, "M0"). OpenWatt runs as two clustered instances connected via XRAM bridge.
- **BL618** -- Single-core: T-Head E907 (RV32IMAFC). Single OpenWatt instance.

The current dev boards are the Sipeed M1s Dock (BL808) and Sipeed M0P Dock (BL618). UARTs are USB CDC via a BL702 bridge chip on both boards (baud rate setting is irrelevant).

## Build

### Build commands

```bash
# BL808 D0 core (C906 RV64GC) -- default
make PLATFORM=bl808 CONFIG=release
make PLATFORM=bl808 CONFIG=unittest

# BL808 M0 core (E907 RV32)
make PLATFORM=bl808 PROCESSOR=e907 CONFIG=release

# BL618 (E907 RV32, single-core)
make PLATFORM=bl618 CONFIG=release
```

**Important:** Always use `timeout 90` when building for BL808 to guard against an LLVM riscv-isel hang triggered by `+unaligned-scalar-mem`. If the build hangs, a new code pattern is triggering the bug -- investigate with binary search on source files.

```bash
timeout 90 make PLATFORM=bl808 CONFIG=release
```

### Build output

| Platform | Output file | Location |
|----------|------------|----------|
| BL808 D0 | `d0fw.bin` | `bin/bl808-d0_release/` |
| BL808 M0 | `m0fw.bin` | `bin/bl808-m0_release/` |
| BL618 | `fw.bin` | `bin/bl618_release/` |

### D version flags

The Makefile sets these version identifiers for conditional compilation:

- `Bouffalo` -- all Bouffalo targets
- `BL808` -- BL808 D0 core
- `BL808_M0` -- BL808 M0 core
- `BL618` -- BL618
- `CRuntime_Picolibc` -- newlib fork compatibility

### Processor/ISA mapping

```makefile
PLATFORM=bl808              # PROCESSOR=c906 (default), ISA: rv64gc
PLATFORM=bl808 PROCESSOR=e907  # ISA: rv32imafc
PLATFORM=bl618              # PROCESSOR=e907 (fixed), ISA: rv32imafc
```

## Platform Files

### Per-variant directories

Each variant has a platform directory under `platforms/`:

- `platforms/bl808/ld/openwatt.ld` -- D0 linker script (PSRAM execution)
- `platforms/bl808/system.conf` -- UART3 console at 2Mbps (MM domain)
- `platforms/bl808/partition.toml` -- Flash partition table
- `platforms/bl808/firmware/firmware_20230227.bin` -- M0 firmware blob (pre-built)
- `platforms/bl808_m0/ld/openwatt.ld` -- M0 linker script (Flash XIP)
- `platforms/bl808_m0/system.conf` -- UART0 console at 2Mbps
- `platforms/bl618/ld/openwatt.ld` -- BL618 linker script (Flash XIP)
- `platforms/bl618/system.conf` -- UART0 console at 2Mbps

### Vendor startup code (BL808 M0 only)

`platforms/bl808/vendor/startup/` contains the M0 boot chain:
- `startup.S` -- M0 reset handler
- `system_bl808.c` -- Clock, BOR, cache initialization
- `start_load.c` -- Memory section copy/init
- `interrupt.c` -- Exception handlers, IRQ dispatch
- `vectors.S` -- Exception/interrupt vector table
- `riscv_fpu.S` -- FP register save/restore

### URT platform packages

D-side system support lives in `third_party/urt/src/sys/`:

**BL808 D0** (`sys/bl808/`): Full driver set -- UART (4 ports, interrupt-driven), GPIO, I2C, SPI, IRQ, timer, XRAM IPC, WiFi, crash handler. 14 files total.

**BL618** (`sys/bl618/`): Minimal -- UART (stub, needs implementation), IRQ, timer, syscalls, start.S. 6 files total. Shared with BL808 M0 builds.

### Source selection in Makefile

```
BL808 D0: third_party/urt/src/sys/bl808/*.d
BL808 M0: third_party/urt/src/sys/bl618/*.d  (shared E907 peripherals)
BL618:    third_party/urt/src/sys/bl618/*.d
```

## Memory Layout

### BL808 D0 (C906 RV64GC)

**Critical: D0 executes from PSRAM, NOT Flash XIP.** M0 copies D0 firmware from Flash (0x580F0000) to PSRAM (0x50100000) before starting D0.

```
Region      Address       Size   Usage
CODE (rx)   0x50100000    2MB    .text, .rodata, .eh_frame (PSRAM, copied by M0)
DATA (rwx)  0x50300000    61MB   .data, .bss, heap (PSRAM writable)
SRAM (rwx)  0x3EFF8000    64KB   .got, .tdata/.tbss, stack (fast on-chip)
HBNRAM (rw) 0x20010000    4KB    Hibernate-persistent storage

Stack: top of SRAM (0x3F008000, grows down)
Heap: end of .bss -> top of DATA region
GOT: SRAM (LMA in CODE, copied by start.S)
TLS: SRAM (LMA in CODE, copied by start.S)
```

### BL808 M0 (E907 RV32IMAFC)

```
Region      Address       Size   Usage
FLASH (rx)  0x58000000    2MB    .text, .rodata (XIP)
DTCM (rwx)  0x20000000    64KB   .got, .tdata/.tbss, stack (tightly-coupled)
RAM (rwx)   0x22020000    64KB   .data, .bss, heap (OCRAM)

Stack: top of DTCM
Heap: end of .bss -> top of RAM
```

### BL618 (E907 RV32IMAFC)

```
Region      Address       Size   Usage
FLASH (rx)  0xA0000000    8MB    .text, .rodata (XIP)
DTCM (rwx)  0x20000000    64KB   .got, .tdata/.tbss, stack (tightly-coupled)
RAM (rwx)   0x22020000    480KB  .data, .bss, heap (OCRAM cached)

Stack: top of DTCM
Heap: end of .bss -> top of RAM
```

## Boot Sequence

### BL808 D0 Boot (start.S in third_party/urt/src/sys/bl808/)

1. Spin ~1M cycles (~80ms at 24MHz) -- wait for M0 to init clocks/PSRAM
2. Disable IRQ (clear MIE, SIE in mstatus)
3. Enable T-Head extensions (THEADISAEE, MM in mxstatus)
4. Enable FPU (double-precision) and RV-V vector
5. Set mtvec (vectored interrupt table)
6. Set gp, tp (thread pointer -> _tdata_start), sp (-> stack top in SRAM)
7. Release TZC security (set bit 16 of 0x20005380) -- M0 doesn't do this for us
8. Clear PLIC enables/pending
9. Copy .got (CODE LMA -> SRAM), .tdata (CODE LMA -> SRAM), zero .tbss
10. Copy .data (CODE LMA -> DATA PSRAM), zero .bss
11. Enable I-cache and D-cache, set MHINT prefetch hints
12. Enable PLIC, set MEIE in mie, set MIE in mstatus
13. Call `sys_init()` (UART, timer, IPC)
14. Run `.init_array` (D module constructors)
15. Call `main()`

**Boot progress markers on UART0:** `@` first instruction, `+` M0 wait done, `S` stack, `G` GOT copied, `T` TZC released, `P` PSRAM data OK, `B` BSS zeroed, `D` .data copied, `C` caches, `I` IRQ table.

### BL618 Boot (start.S in third_party/urt/src/sys/bl618/)

Simpler (no M0 handshake, no PSRAM, no D-cache):

1. Disable IRQ
2. Enable T-Head extensions (THEADISAEE, MM)
3. Enable FPU (single-precision only on E907)
4. Set mtvec vectored, set gp/tp/sp
5. Copy .got, .tdata, zero .tbss (4-byte ops for RV32)
6. Copy .data, zero .bss
7. Enable I-cache only (no D-cache on E907)
8. Setup PLIC, enable global IRQ
9. Call `sys_init()`, `.init_array`, `main()`

## Dual-Core Architecture (BL808)

OpenWatt runs as **two clustered instances** on BL808, not as "app + custom firmware":

- **M0 instance (data plane):** OpenWatt compiled for RV32. Owns WiFi, EMAC, radio hardware. Handles bridging and packet switching. Minimal module set (router layer + interface drivers only).
- **D0 instance (control plane):** OpenWatt on RV64 with PSRAM. Handles protocol decode, samplers, energy management, console, apps. Full module set.
- **IPC:** XRAM ring buffers (16KB shared at 0x22020000) mapped as a Bridge interface on both sides. Same packet format, same BaseInterface abstraction.

### XRAM Ring Buffers

Ring IDs:
- 0 = LOG_C906 (D0 log output)
- 1 = LOG_E902 (LP core log)
- 2 = NET (Ethernet/WiFi frames -- the main bridge)
- 3 = PERIPHERAL (GPIO/SPI/PWM/Flash commands)
- 4 = RPC (Remote procedure calls)

Each ring has volatile 16-bit head/tail cursors. Net ring frames have a header with magic, length, type (command/frame/sniffer), and CRC16.

### Module gating

`version(DataPlane)` / `version(ControlPlane)` gates module loading in `plugin.d`. M0 builds strip everything except router + interfaces + bridge to fit in tight memory.

## UART Driver

### BL808 D0 (full implementation in sys/bl808/uart.d)

4 UART peripherals:
- UART0/1/2: MCU domain (0x2000_A000/A100/AA00) -- polled only (no D0 IRQs)
- UART3: MM domain (0x3000_2000) -- interrupt-driven, PLIC IRQ 20

Features: 512-byte RX/TX ring buffers, configurable baud/parity/stop-bits, FIFO thresholds (RX=16, TX=8 of 32-byte FIFO), RX timeout at 80 bit periods.

API: `uart_open/close/read/write/poll/check_errors/rx_pending/flush`

Early-boot debug: `uart0_puts()`, `uart3_puts()` for direct register writes before ring buffers are initialized.

### BL618 (stub in sys/bl618/uart.d)

Type definitions present but functions are stubbed. Full implementation still needed.

### Serial stream integration

`src/router/stream/serial.d` selects the correct UART driver:
```d
version (Bouffalo) {
    version (BL808) import sys.bl808.uart;
    else            import sys.bl618.uart;
}
```

## Bare-Metal D Runtime Fixes

These fixes are needed for D on bare-metal RISC-V and apply to all Bouffalo targets:

1. **TLS init in start.S** -- D module-level variables are TLS by default. `tp` must be set, `.tdata` copied, `.tbss` zeroed before any D code runs. Without this, fiber's `co_active_handle` etc. are garbage.

2. **`.eh_frame` registration** -- DWARF unwinder needs `__register_frame_info(&__eh_frame_start, &object)` called at init. Use `_info` variant, NOT `__register_frame` (which calls `malloc` too early). Pre-allocate a 48-byte object in BSS.

3. **LLVM riscv-isel hang** -- `+unaligned-scalar-mem` triggers infinite loop in instruction selection when LLVM sees store->memcmp pattern (slice equality on stack buffers). Workaround: `pragma(inline, false)` helper for string comparisons in unittests.

4. **co_swap single asm block** -- RV64 and RV32 `co_swap` must use a SINGLE `asm` block. `@naked` + multiple asm blocks is UB in LLVM (registers clobbered between blocks).

5. **FreeStanding unittest guards** -- Some tests need `version(FreeStanding)` guards to skip platform-specific functionality.

## Key Addresses

| Component | BL808 D0 | BL808 M0 | BL618 |
|-----------|----------|----------|-------|
| Code origin | 0x50100000 (PSRAM) | 0x58000000 (Flash) | 0xA0000000 (Flash) |
| Data RAM | 0x50300000 (PSRAM) | 0x22020000 (OCRAM) | 0x22020000 (OCRAM) |
| Fast RAM | 0x3EFF8000 (SRAM) | 0x20000000 (DTCM) | 0x20000000 (DTCM) |
| UART console | 0x3000_2000 (UART3) | 0x2000_A000 (UART0) | 0x2000_A000 (UART0) |
| PLIC | 0xE000_0000 | -- | -- |
| CLINT/mtime | 0xE400_0000 | -- | -- |
| TZC release | 0x20005380 | -- | -- |
| XRAM shared | 0x2202_0000 (16KB) | 0x2202_0000 (16KB) | N/A |
| HBN RAM | 0x20010000 (4KB) | -- | -- |

## Common Pitfalls

- **D0 executes from PSRAM, not Flash** -- the linker script CODE origin must be 0x50100000. Using Flash XIP addresses (0x58000000) makes all PC-relative references wrong by 0x07FF0000.
- **M0 doesn't release TZC for D0** -- D0 start.S must clear TZC bit 16 at 0x20005380 or PSRAM data writes fault silently.
- **M0 switches D0 clock AFTER starting D0** -- the spin delay at boot start is required to avoid pipeline glitches during the XTAL-to-PLL transition.
- **`lw` on RV64 sign-extends** -- use `lwu` for unsigned 32-bit loads when comparing to values with bit 31 set.
- **LLVM build hangs** -- always build with `timeout 90` for BL808 targets. If it hangs, a new code pattern triggered the riscv-isel bug.
- **BL618 UART driver is incomplete** -- only type definitions and stubs exist. Full register-level implementation still needed.
- **M1s Dock / M0P Dock UARTs are USB CDC via BL702** -- baud rate setting in system.conf has no effect on actual transmission speed.
- **GCC-compiled C objects linked by LLD** end up at END of .text -- use section attributes to place early if needed.
- **No D-cache on E907** -- BL618 and BL808 M0 enable I-cache only. Don't rely on cache coherency patterns from D0 code.
