---
name: bouffalo-port
description: Bouffalo Labs (BL808/BL618) platform port -- build, flash, debug, bare-metal D runtime, dual-core IPC, vendor blob integration, and known pitfalls. Use when working on any Bouffalo variant, fixing bare-metal issues, or debugging the RISC-V startup/memory/interrupt stack.
---

# Bouffalo Labs Platform Skill

OpenWatt on Bouffalo RISC-V, bare-metal. LDC cross-compiles D for two chips:

- **BL808** -- Dual-core: T-Head C906 (RV64GC, "D0", 480MHz) + T-Head E907 (RV32IMAFC, "M0", 400MHz). OpenWatt runs as two clustered instances bridged through XRAM IPC.
- **BL618** -- Single-core: T-Head E907 (RV32IMAFC, 320MHz). Single OpenWatt instance.

Dev boards: Sipeed M1s Dock (BL808), Sipeed M0P Dock (BL618). USB-CDC is via a separate **BL702 bridge chip** on both -- M0/BL618 only drives UART, baud rate setting is irrelevant (BL702 fakes it).

## Product Roles

### BL808 (dual-core)

Two clustered OpenWatt instances on the same chip, talking over XRAM rings:

**D0 -- control plane.** Has PSRAM (59MB+ data). Runs all protocol decoders/bindings (Modbus, MQTT, Zigbee, CAN, HTTP, TLS, ESPHome, SNMP, BLE, Tesla, GoodWe), the Device/Component/Element data model, apps (energy, automation, OTA), console/Telnet/Web. Owns UART3 (MM domain, IRQ-driven). No direct access to radios.

**M0 -- data plane.** Tight memory (~1MB PSRAM slice). Owns WiFi (vendor `libwifi.a`+`libbl606p_phyrf.a` link into the M0 binary), EMAC, MM-domain hardware. Bridges packets to D0 via XRAM. Performs all chip-wide bring-up before D0 starts (MM domain power, PLLs, PSRAM init, L2 SRAM, TZC), then loads D0 firmware from flash to PSRAM and releases D0. Strips most modules via `version(DataPlane)`. Owns UART0 (MCU domain, polled).

The split is hardware-driven: PSRAM is on the MM domain (powered by M0), radios are wired to M0's bus.

### BL618 (single-core)

Cheaper single-chip variant for cost-sensitive deployments. Same codebase, smaller targets: 480KB OCRAM (no PSRAM), 4-8MB flash, lower CPU. Uses `Tiny` builds with optional protocols compiled out.

## Build

```bash
# BL808 D0 (default)                   ARCH: rv64gc
make PLATFORM=bl808 CONFIG=release

# BL808 M0                             ARCH: rv32imafc
make PLATFORM=bl808 PROCESSOR=e907 CONFIG=release

# BL618                                ARCH: rv32imafc
make PLATFORM=bl618 CONFIG=release
```

**Always use `timeout 90` for BL808 D0 builds** -- LDC riscv-isel hangs on certain patterns with `+unaligned-scalar-mem`. If it hangs, bisect on source files to find the trigger.

Outputs:

| Platform | Output | Path |
|----------|--------|------|
| BL808 D0 | `d0fw.bin` + `d0fw.bin.gz` (M0 auto-detects gzip magic at flash offset 0) | `bin/bl808-d0_release/` |
| BL808 M0 | `m0fw.bin` | `bin/bl808-m0_release/` |
| BL618 | `fw.bin` | `bin/bl618_release/` |

D versions set: `Bouffalo`, `BL808` (also for M0), `BL808_M0` (M0 only), `BL618`, `CRuntime_Picolibc`, `BareMetal`, `Embedded`. `Tiny` is auto-set for M0 and BL618.

## File Layout

```
platforms/bl808/              D0 build inputs: ld/, system.conf, partition.toml, include/
platforms/bl808/firmware/     firmware_20230227.bin -- vendor M0 blob (still used in prod)
platforms/bl808_m0/           M0 build inputs: system.conf
platforms/bl808_m0/vendor/    Vendor C linked into M0:
    wifi/{src,include,lib}/   WiFi driver C + libwifi.a + libbl606p_phyrf.a
    psram/{src,include}/      Vendor PSRAM init: bl_psram.c, bl808_psram_uhs.c, bl808_glb_pll.c
    tlsf/                     TLSF allocator (mspace_* backing for M0 multi-pool heap)
platforms/bl618/              BL618 build inputs

third_party/urt/platforms/bl808/bl808_d0.ld   D0 linker script
third_party/urt/platforms/bl808/bl808_m0.ld   M0 linker script (multi-pool heap)
third_party/urt/platforms/bl618/bl618.ld      BL618 linker script

third_party/urt/src/urt/driver/bl808/         D0 drivers: UART (4-port, IRQ), GPIO, I2C, SPI, IRQ, timer,
                                                 xram (IPC), wifi, alloc, crash, exception, ipc, start.S
third_party/urt/src/urt/driver/bl808_m0/      M0-specific forks/extras: start.S + start.d (chip bring-up + D0 launch),
                                                 alloc.d (multi-pool TLSF), wifi.d, bl_ops.d
third_party/urt/src/urt/driver/bl618/         Shared E907 driver pool (used by BL618 AND BL808 M0):
                                                 UART, IRQ, timer, syscalls, alloc, gpio
```

Source selection in `platforms.mk`:
- D0: `urt/driver/bl808/*.d`
- M0: `urt/driver/bl618/*.d` + `urt/driver/bl808_m0/*.d` + `urt/driver/bl808/{wifi,bl_ops,hbn}.d`
- BL618: `urt/driver/bl618/*.d`

### Driver organization: shared vs forked

`urt/driver/bl618/` is the **shared E907 driver pool** -- the same files serve BL618 standalone AND the BL808 M0 core (both pull them in via platforms.mk). Two gating patterns coexist:

**1. Shared file with inline divergence (~90% identical, e.g. UART, GPIO, IRQ, timer):**
Unguarded code = shared truth for both chips. Carve-outs gate the minority case:

```d
version (BL808_M0) enum console_tx_pin = 22;  // M0 on M1s Dock
else                enum console_tx_pin = 14; // BL618 default

version (BL808_M0) { ... M0-specific extra register write ... }
```

Compose `enum` at the top of a function, then `static if` on it -- per CLAUDE.md *"Keep one definition of each function and struct. Put `version` blocks inside at the exact point of divergence."*

**2. Forked file (shape meaningfully differs, e.g. `alloc.d`):**
M0 gets its own `bl808_m0/<name>.d` with a different module name. The **`bl618/<name>.d` is gated with `version (BL618):` at the top** so it compiles to nothing on M0 builds. Both files still appear in the M0 source list, but only one contributes symbols. Examples already forked this way:
- `alloc.d` -- M0 has three-pool TLSF (DTCM+OCRAM+PSRAM), BL618 has single-pool OCRAM
- `start.S`/`start.d` -- M0 has chip bring-up + D0 launch, BL618 has none

Fork only when the implementation *shape* differs (different memory model, lifecycle, programming model). Don't fork because a constant or a single branch differs -- that's pattern (1).

### Vendor C build flags

- WiFi: `-DCFG_CHIP_BL808 -DCFG_TXDESC=4 -DCFG_STA_MAX=5 -fcommon`
- PSRAM: `-DBL808 -DARCH_RISCV -fcommon` (`-DARCH_RISCV` is required so `bl808.h` picks the RISC-V CSI include branch -- otherwise `__NOP` is undefined)

One vendor patch: `vendor/psram/include/bl808_glb.h` has `GLB_AHB_CLOCK_IP_UART4` added to an enum -- vendor's own `bl808_glb_pll.c` references it but the matching header omits it. Commented inline.

## Memory Layout

### BL808 D0 (C906 RV64GC)

```
CODE   (rx)   0x50100000   4MB    .text, .rodata, .eh_frame  (PSRAM, M0-loaded)
DATA   (rwx)  0x50500000   59MB   .data, .bss, heap
SRAM   (rwx)  0x3EFF8000   64KB   .got, .tdata/.tbss, stack  (fast on-chip)
HBNRAM (rw)   0x20010000   4KB    Hibernate-persistent
```

D0 executes from PSRAM, not Flash XIP. M0 copies the image from flash partition (XIP 0x58100000) to PSRAM 0x50100000 before releasing D0.

CODE region size (4 MB) must stay in sync across three files: `bl808_d0.ld` MEMORY block, `partition.toml` D0FW `size0`, and `bl808_m0/start.d` `D0_PSRAM_LOAD_SIZE`/`D0_IMAGE_FLASH_SIZE`. Touch one, touch all four.

### BL808 M0 (E907 RV32IMAFC) -- multi-pool heap

```
FLASH         0x58000000   2MB    XIP: .text, .rodata, .eh_frame, .init_array
ITCM          0x62028000   28KB   @critical (.ramfunc), copied at boot
DTCM          0x6202F000   4KB    fastest heap (uncached, single-cycle, no DMA)
XRAM          0x40000000   16KB   EMI shared with D0/LP -- IPC (reserved, no sections)
OCRAM         0x22020000   64KB   .got + @fast_data + fast/DMA heap + stack
WIFIRAM       0x22030000   96KB   vendor .wifibss + WiFi @fast_data tail (base is HW-fixed)
PSRAM         0x50000000   1MB    .data/.bss/.tdata/.tbss + @bulk_data + slow heap
```

Allocator routes by `MemFlags`: `fastest` -> DTCM, `fast`/`dma` -> OCRAM, default/`slow`/`large` -> PSRAM. Backed by TLSF (vendor `tlsf.c`).

D0's PSRAM slice starts at 0x50100000 -- M0's slice ends just below at 0x50100000.

### BL616 / BL618 (E907 RV32IMAFC) -- Sipeed M0P Dock

Authoritative map: BL616/BL618 datasheet + vendor `bouffalo_sdk` bl616dk
linker template. **No TCM** -- the vendor MEMORY{} has none; `.tcm_*` fold
into RAM. Cacheability is address-based: bit 30 set = cached (`0x62..`/`0x63..`),
clear = non-cache (`0x22..`/`0x23..`) -- same physical RAM, two windows. Code
and data run cached; only DMA uses the non-cache alias.

```
FLASH    0xA0000000   8M     XIP, I-cached: .text/.rodata
OCRAM    0x62FC0000   320K   cached; top 64K aliased non-cache (0x23000000) for DMA
WRAM     0x23010000   160K   reserved (non-cache) for WiFi DMA
PSRAM    0xA8000000   4M     M0P pseudo-SRAM; needs bl_psram_init before use
HBN      0x20010000   4K     @persist
```

Allocator: `fast`/`fastest`/`slow` -> cached OCRAM; `dma` -> non-cache OCRAM
alias. PSRAM is reserved but not yet a pool (no boot-time init wired).

`0x20000000` is **GLB peripheral register space, NOT DTCM**. Earlier docs and
the old `bl618.ld` carried a fabricated "DTCM @ 0x20000000 64K" (copied from a
bad assumption, never on hardware) -- there is no TCM on this part.

## Boot Sequence

### BL808 cold boot: BootROM -> Boot2 -> M0

Mask ROM reads the bootheader at flash 0, loads vendor "Boot2" (stage-2 loader at flash 0x00000) which reads the partition table at 0xE000/0xF000 (two copies) and loads FW partition (M0 firmware at 0x10000-0x100000) into memory.

Boot2 and FW partitions have **vendor 4KB boot headers** (magic `"BFNP"`/`"BFAP"`, flash config, PLL config, image hash). Vendor flash tools (DevCube / `bflb_iot_tool`) read `platforms/bl808/partition.toml` and prepend these automatically.

**D0FW partition has `header = 0`** -- M0 loads D0 directly without parsing a vendor header. D0 image is flashed raw to flash offset 0x100000.

OpenWatt build produces raw `.bin` via `objcopy -O binary`. Headers (if any) come from the flash tool, not the build.

### M0 boot (`urt/driver/bl808_m0/start.S` + `start.d`)

`start.S` (asm):

1. Disable IRQ, enable T-Head ext (THEADISAEE + MM in mxstatus), FPU
2. **HBN/PDS retention bit clear** -- zero stale sleep-state bits at `0x2000F034`, `0x2000E020`, `0x2000E028`
3. Set `mtvec` + `mtvt` to `__vectors`
4. gp/tp/sp; copy .got -> OCRAM, .tdata -> PSRAM, zero .tbss; copy .data -> PSRAM, zero .bss
5. Enable I-cache (MHCR); MEIE + MIE
6. **Call `m0_bringup()`** (start.d) -> `sys_init` -> `.init_array` -> `main`

`start.d` `m0_bringup()` (D, runs before `sys_init`):

1. MM domain power-on (`PDS_CTL2` @ 0x2000E010 -- clear bits 1, 5, 17, 13, 9 with 45us delay after step 1)
2. MM clock config (`MM_CLK_CTRL_CPU` @ 0x30007000 -- 6 bitfields: XCLK=XTAL, BCLK=160M, CPU root=PLL, CPU=400M, UART/I2C=XCLK)
3. UART signal mux (`GLB_PARM_CFG0` @ 0x20000510 -- bits 3+5)
4. `bl_psram_init()` (vendor C: `GLB_Config_UHS_PLL` + `Psram_UHS_x16_Init(2000)`)
5. L2 SRAM/VRAM partition (`MM_MISC_VRAM_CTRL` @ 0x30000050 -- 64KB L2 / 0KB VRAM)
6. TZC for D0: set D0 master group=1 (`TZC_MM_BMX_TZMID` @ 0x20005300), enable PSRAMA/B region-0 for group 1 (`TZC_PSRAMA_TZSRG_CTRL` @ 0x20005380, PSRAMB @ 0x200053A0)
7. **Launch D0** (chained `launch_d0()`):
   - Read D0 image from flash 0x58100000; sniff gzip magic at offset 0 -> `gzip_uncompress` into PSRAM, else raw memcpy. D-cache off around the write.
   - D0 mtimer divider (`MM_MISC_CPU_RTC` @ 0x30000018 -- DIV=39 for 10MHz from 400MHz)
   - Halt D0 (`MM_GLB_SW_SYS_RESET` @ 0x30007040 bit 8 set) -> set boot address (`MM_MISC_CPU0_BOOT` @ 0x30000000) -> release (clear bit 8)

D0 runs from this point in parallel; M0 returns and continues with `sys_init` and `main`.

### D0 boot (`urt/driver/bl808/start.S`)

1. Spin ~1M cycles (~80ms at 24MHz, ~5ms at 400MHz) -- waits for M0 clock setup. **Do not shorten** -- M0 switches D0's clock XTAL->PLL after release; the wait avoids pipeline glitches.
2. Disable IRQ; THEAD ext; FPU (FS=Initial) + RV-V vector
3. `mtvec` = `__vectors | 1` (vectored)
4. gp/tp/sp (sp -> SRAM at 0x3F008000)
5. Clear PLIC enables/pending (PLIC base 0xE0000000, enables 0xE0002000, pending 0xE0001000, claim 0xE0200004)
6. Copy .got -> SRAM, .tdata -> SRAM, zero .tbss; copy .data -> PSRAM, zero .bss
7. Enable I+D cache (MHCR) and prefetch hints (MHINT)
8. MEIE + MIE; `sys_init` -> `.init_array` -> `main`

Trap vectored table (`__vectors`) routes M-mode exception to `_trap_exception` (saves 32 GPRs, redirects mtvec to spin to avoid double-fault recursion, calls D-side `_crash_handler`), M-timer to `_trap_mtimer`, M-external to `_trap_mext` (PLIC claim -> `_irq_dispatch` -> complete). Current PLIC user: UART3 IRQ 20.

### BL618 boot (`urt/driver/bl618/start.S`)

No MM domain, no PSRAM, no D-cache, no D0 launch. Just disable IRQ, enable T-Head ext + FPU, set mtvec, gp/tp/sp, copy/zero sections, enable I-cache, MEIE+MIE, `sys_init` -> `.init_array` -> `main`.

## Dual-Core IPC (BL808)

16KB at `0x22020000` is partitioned into rings. Each ring has volatile 16-bit head/tail cursors with a payload region. Both cores see the same physical memory; neither has cache coherency with the other -- `fence rw, rw` after writes.

| ID | Name | Direction | Purpose |
|----|------|-----------|---------|
| 0 | LOG_C906 | D0 -> M0 | D0 log out (M0 forwards to UART0) |
| 1 | LOG_E907 | M0 -> D0 | M0 log out |
| 2 | NET | bidirectional | Frame bridge (mapped as `BaseInterface` on both sides) |
| 3 | PERIPHERAL | D0 -> M0 req, M0 -> D0 resp | RPC for hardware M0 owns |
| 4 | RPC | bidirectional | Generic control/status RPC |

Net ring frames: 16-bit magic, 16-bit length, type, CRC16. Other rings: length-prefixed.

M0 zeros all rings during bring-up before releasing D0. After release, both cores update head/tail concurrently -- no locks (single-producer/single-consumer per direction).

Module gating: `version(DataPlane)` on M0, `version(ControlPlane)` on D0, picked in `plugin.d`.

## UART

**D0 (`urt/driver/bl808/uart.d`, full):** 4 peripherals -- UART0/1/2 at `0x2000_A000`/`A100`/`AA00` (MCU domain, polled only), UART3 at `0x3000_2000` (MM domain, IRQ-driven, PLIC IRQ 20). 512-byte rings, configurable baud/parity, RX timeout at 80 bit-periods. Early-boot helpers `uart0_puts()`/`uart3_puts()` for pre-ring-buffer output.

**M0 / BL618 (`urt/driver/bl618/uart.d`, full polled):** 2 peripherals -- UART0/1 at `0x2000_A000`/`A100`. Polled-only (CLIC IRQ dispatch not yet wired). Same register layout as D0, ported with `size_t` casts for RV32. 512-byte rings. Early-boot helpers:
- `uart0_early_init(tx_pin, rx_pin, baud)` -- pad mux + signal routing + reg init, callable from `m0_bringup()` before `sys_init`
- `uart0_putc` / `uart0_hw_puts` / `uart0_hex` -- blocking polled output for boot markers

The early-init does GPIO mux inline (raw MMIO to `GLB_GPIO_CFG{n}` and `GLB_UART_CFG1/2`) rather than going through `bl618/gpio.d` -- two pads at boot isn't worth a driver call. The full `uart_hw_open()` re-applies the same setup harmlessly.

`m0_bringup()` issues single-byte progress markers (`A`-`E`) between each step after UART comes up -- if boot hangs, the last byte on the wire tells you which step died.

Pin assignments (M1s Dock): UART0 TX=GPIO22, RX=GPIO21, 2Mbaud (BL702 fakes baud anyway). BL618 pins TBD when that board comes up -- gate with `version (BL808_M0)` per the driver-organization rules.

`src/router/stream/serial.d` picks via `version(BL808)` vs else (-> `urt.driver.bl618.uart`). M0 builds set both `BL808` and `BL808_M0` but the source list (not the version) is what selects the bl618 uart module.

## Key Addresses

| | D0 | M0 | BL618 |
|--|------|------|------|
| Flash XIP | 0x58000000 | 0x58000000 | 0xA0000000 |
| Code origin | 0x50100000 (PSRAM) | 0x58000000 (XIP) | 0xA0000000 (XIP) |
| Data RAM | 0x50500000 PSRAM 59MB | 0x50000000 PSRAM 1MB | 0x62FC0000 OCRAM 320K (+0xA8000000 PSRAM 4M) |
| Fast RAM | 0x3EFF8000 SRAM 64KB | 0x6202F000 DTCM 4KB | 0x62FC0000 OCRAM cached (no TCM) |
| OCRAM | -- | 0x22020000 64K (+WIFIRAM 0x22030000 96K) | 0x62FC0000 320K |
| UART console | UART3 @ 0x3000_2000 | UART0 @ 0x2000_A000 | UART0 @ 0x2000_A000 |
| IRQ controller | PLIC @ 0xE0000000 | CLIC | CLIC |
| XRAM (IPC) | 0x2202_0000 16KB | 0x4000_0000 16KB | -- |
| TZC PSRAMA/B | M0 owns | 0x2000_5380 / 0x2000_53A0 | -- |
| MM domain regs | -- | PDS_CTL2 0x2000_E010, MM_CLK 0x3000_7000, MM_RST 0x3000_7040, CPU0_BOOT 0x3000_0000, CPU_RTC 0x3000_0018 | -- |

## Pitfalls (recurring)

- **LLVM riscv-isel hang** on `+unaligned-scalar-mem`: always wrap BL808 builds in `timeout 90`. If it hangs, bisect to find the trigger pattern (typically store->memcmp slice equality).
- **`lw` sign-extends on RV64.** Use `lwu` for unsigned 32-bit loads when comparing against values with bit 31 set (e.g. flash addresses `0x58xxxxxx`).
- **DTCM on M0 has no DMA path.** Allocator routes `MemFlags.dma` to OCRAM only.
- **No D-cache on E907** (M0, BL618). I-cache only. Don't extrapolate cache patterns from D0.
- **M0 OCRAM heap starts at `0x22030000`, not `0x22024000`.** The lower 48KB is libwifi.a's private working RAM.
- **`0x20000000` is peripheral register space on BL808, RAM on BL618.** Same chip family, different memory maps. Don't extrapolate.
- **M0 switches D0's clock AFTER releasing D0 from reset.** D0 start.S's ~80ms spin loop is required; don't shorten.
- **Vendor PSRAM C requires `-DARCH_RISCV`** so `bl808.h` picks the RISC-V CSI include branch instead of Cortex-M.
- **M1s/M0P Dock UART is USB CDC via BL702** -- baud rate setting is cosmetic, BL702 fakes it.
- **`gzip_uncompress` byte-tracking** relies on `urt.zip.uncompress`'s `getbits` doing minimal-pull byte reads. If anyone rewrites getbits to bulk-load 32 bits, gzip CRC validation breaks. Comment is in zip.d.
