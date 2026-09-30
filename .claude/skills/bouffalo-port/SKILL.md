---
name: bouffalo-port
description: Bouffalo Labs (BL808/BL618) platform port -- build, flash, debug, bare-metal D runtime, the BL808 single image and inter-core XRAM link, vendor blob integration, and known pitfalls. Use when working on any Bouffalo variant, fixing bare-metal issues, or debugging the RISC-V startup/memory/interrupt stack.
---

# Bouffalo Labs Platform Skill

OpenWatt on Bouffalo RISC-V, bare-metal. LDC cross-compiles D for two chips:

- **BL808** -- Dual-core: T-Head C906 (RV64GC, "D0", 480 MHz) + T-Head E907 (RV32IMAFC, "M0", 320 MHz). Two OpenWatt instances, peered over XRAM.
- **BL618** -- Single-core: T-Head E907 (RV32IMAFC, 320MHz). Single OpenWatt instance.

Dev boards: Sipeed M1s Dock (BL808), Sipeed M0P Dock (BL618). USB-CDC is via a separate **BL702 bridge chip** on both; baud rate settings are cosmetic (the BL702 fakes them).

## Product Roles

### BL808 (dual-core)

**M0 -- the network node.** Owns the radios (vendor `libwifi.a` + `libbl606p_phyrf.a`), EMAC, flash and the MCU-domain peripherals, and all chip-wide bring-up: MM domain power, PLLs, PSRAM, L2 SRAM, then inflates D0 into PSRAM and releases it. Full build with its console (not Tiny, not headless); runs the provisioning AP and services from `platforms/bl808_m0/default.conf`, and the board panel from its `system.conf`. Owns UART0 (MCU domain, polled).

**D0 -- the compute assistant.** Runs from PSRAM (60 MB), full feature set, no network path of its own. Owns the MM domain (camera, display, NPU) and the MM UART (UART3, IRQ-driven).

M0 claims D0 over XRAM (`/sync/peer ... claim=yes`, in both `system.conf`s) and mirrors D0's devices, so D0 never appears on the network; M0 stays a peering `member` toward its fleet.

### BL618 (single-core)

Cheaper single-chip variant: 480KB OCRAM (no PSRAM in use yet), 4-8MB flash. `Tiny` builds.

## Build

Build in WSL; the Windows shell has no `riscv64-unknown-elf-gcc`/picolibc.

```bash
# BL808 single image: builds D0 (sub-make, PROCESSOR=c906) and appends it to M0
wsl -e bash -lc "cd /mnt/d/<tree> && make PLATFORM=bl808 PROCESSOR=e907 CONFIG=release -j8"

# BL808 D0 alone                          ARCH: rv64gc
make PLATFORM=bl808 CONFIG=release

# BL618                                   ARCH: rv32imafc
make PLATFORM=bl618 CONFIG=release
```

**Wrap BL808 D0 builds in `timeout`** -- LDC riscv-isel has hung on some patterns with `+unaligned-scalar-mem`. If it hangs, bisect on source files.

Outputs:

| Platform | Output | Path |
|----------|--------|------|
| BL808 | `fw.bin` = `m0fw.bin` + D0 payload (flash this) | `bin/bl808-m0_release/` |
| BL808 D0 | `d0fw.bin` (input to the payload) | `bin/bl808-d0_release/` |
| BL618 | `fw.bin` | `bin/bl618_release/` |

`third_party/urt/tools/bl808_image.py append` packs D0's ELF load segments into a run table (entry, count, then `(dest, size)` pairs) followed by one raw-deflate stream per run, and appends it after M0's last flash-resident byte (`_d0_image`). The build prints `M0 x + D0 y = z of <bank>`.

D versions: `Bouffalo`, `BL808` (both cores), `BL808_M0` (M0 only), `BL618`, `CRuntime_Picolibc`, `BareMetal`, `Embedded`. `Tiny` is auto-set for the BL618.

## Flash and console

```bash
cd /d/dev/BouffaloLabDevCube-v1.9.0 && ./bflb_iot_tool.exe --chipname=bl808 --port=COM11 --baudrate=1200000 \
  --pt=<tree>/platforms/bl808/partition.toml \
  --boot2=chips/bl808/builtin_imgs/boot2_isp_bl808_v6.6.2/boot2_isp_release.bin \
  --dts=chips/bl808/device_tree/bl_factory_params_IoTKitA_auto.dts \
  --firmware=<tree>/bin/bl808-m0_release/fw.bin
```

The tool is meant to reset the board into the ROM and back, but since 2026-09-30 its reset often fails (`shake hand fail`, `RESET CPU FAIL`): then put the chip in the downloader from D0 with `/system/reboot bootloader=1` on COM12 and flash with `--baudrate=500000` (that entry leaves the chip on RC32M, which cannot hold 1.2 Mbaud), and press RST afterwards. Never retry in a loop: it wedges the BL702 until a USB replug. On the M1s Dock the BL702 exposes M0's UART0 as COM11 and D0's MM UART as COM12, both 2 Mbaud. Wait ~15 s after reset before talking to D0: M0 inflates D0 first (6-9 s).

M0's console RX is polled: send commands in chunks of 16 bytes or fewer with a short gap, or the 32-byte FIFO overruns. From Git Bash, set `MSYS_NO_PATHCONV=1` or `/stream/...` arguments get rewritten into Windows paths.

`/system/reboot` resets both cores (POR); `bootloader=1` sets the boot ROM's hand-off in HBN_RSV2 first.

## Flash layout (`platforms/bl808/partition.toml`)

| Region | Offset | Size | Notes |
|---|---|---|---|
| Boot2 | 0x0 | 0xE000 | vendor stage 2, header added by the tool |
| partition table | 0xE000/0xF000 | 4K x2 | |
| FW bank A / B | 0x10000 / 0x410000 | 4 MB each | M0 image + D0 payload; boot2 maps the active bank at 0x58000000 |
| kv | 0x810000 | 64K | reserved for NVS |
| media | 0x820000 | 0x6E0000 | littlefs (M0 mounts it; `/system/fs format`) |
| factory | 0xF00000 | | written by the flash tool from the dts; never by firmware |

## File Layout

```
platforms/bl808/                         partition.toml, system.conf (D0)
platforms/bl808_m0/                      system.conf, default.conf (M0)
third_party/urt/vendor.mk                vendor C rules and flags
third_party/urt/platforms/bl808_m0/vendor/wifi/   WiFi driver C + libwifi.a + libbl606p_phyrf.a
third_party/urt/platforms/bl808_m0/vendor/psram/  PSRAM init plus the SF flash driver (sflash, sf_ctrl, xip_sflash, sf_cfg)
third_party/urt/platforms/bl808/         bl808_d0.ld, bl808_m0.ld
third_party/urt/src/urt/driver/bl808/    D0: start.S, UART (4-port, IRQ), I2C, SPI, IRQ (PLIC), timer
third_party/urt/src/urt/driver/bl808_m0/ M0: start.S + start.d (chip bring-up, D0 inflate and launch), flash.d, WiFi
third_party/urt/src/urt/driver/bl618/    shared E907 pool (BL618 and M0): UART, IRQ (CLIC), timer, syscalls
third_party/urt/src/urt/driver/bl_common/ both chips: heap, xram, reset, gpio, pwm, ws2812, clock, hbn, identity, trng, exception
src/router/stream/xram.d                 /stream/xram
src/router/iface/framed.d                /interface/framed
```

Source selection is in `platforms.mk`. Shared files diverge inline with `version (BL808_M0)` at the exact point of divergence; fork into `bl808_m0/` only when the shape differs.

### Vendor C build flags

- WiFi: `-DCFG_CHIP_BL808 -DCFG_TXDESC=4 -DCFG_STA_MAX=5 -fcommon`
- PSRAM: `-DBL808 -DARCH_RISCV -fcommon` (`-DARCH_RISCV` picks the RISC-V CSI branch of `bl808.h`)
- Flash driver (runs from RAM): `-fno-jump-tables -fno-tree-switch-conversion`, or its switches load tables from flash while flash is busy.

`vendor/psram/include/bl808_glb.h` carries one patch: `GLB_AHB_CLOCK_IP_UART4` added to an enum the vendor's own `bl808_glb_pll.c` references.

## Memory Layout

### BL808 D0 (C906)

```
PSRAM  (rwx)  0x50100000   60M    code, data, heap (M0 inflates the load runs here)
SRAM   (rwx)  0x3EFF8000   64K    .got, TLS, stack, fast heap
HBNRAM (rw)   0x20010000   4K     survives reset
```

### BL808 M0 (E907) -- no TCM

```
FLASH   0x58000000   ~4M    XIP: .text, .rodata; D0 payload after _d0_image
ITCM    0x6202E000   8K     @critical / .ramfunc (the flash driver, arch_delay_us), copied at boot
OCRAM   0x22020000   64K    .got, fast data, fast/DMA heap, stack (below ITCM's alias)
WIFIRAM 0x22030000   96K    vendor .wifibss; base is fixed by the PHY DMA routing
XRAM    0x40000000   16K    inter-core rings; no sections
PSRAM   0x50000000   1M     .data/.bss/TLS, slow heap; D0 starts at 0x50100000
```

"ITCM" and "DTCM" are OCRAM through its cached alias at 0x62020000, not tightly coupled memory. Code cannot execute below 0x62028000 in that alias; 0x6202E000 works.

Heap pools route by `MemFlags` (`bl_common/heap.d`): `fast`/`dma` to OCRAM, default/`slow` to PSRAM. Heap regions start 8-aligned in the linker script; TLSF rejects a misaligned pool.

## Boot

### M0 (`bl808_m0/start.S`, `start.d`)

Boot2 hands over with the E907 D-cache **on and write-back** (MHCR 0x103F) and a SYSMAP making everything from 0x40000000 up cacheable. `m0_bringup()` (before `sys_init`):

1. `mtime_config` on M0's own timer (160 MHz; see Timebase)
2. `xram_uncached`: extend SYSMAP region 0 (strongly ordered) to 0x40004000 so XRAM bypasses M0's cache
3. MM domain power (`PDS_CTL2`), CPU PLL to 480 MHz (`bl_cpupll_480m`), MM clocks (D0 on the CPU PLL, MM UART clock from XCLK), bus threshold, UART signal mux, UART0 early init (GPIO14 TX / GPIO15 RX)
4. WiFi EM carve-out, PSRAM init (vendor `bl_psram_init`), L2 SRAM partition
5. `launch_d0`: inflate each payload run to its address, set D0's console pads (GPIO16/17, MM UART function 21), D0 timer divider (160 MHz from 480 MHz), halt D0 (clock gate + reset), set boot address, `xram_reset`, clean the D-cache (`th.dcache.call; th.sync.s`, emitted as `.word`), release D0, zero both timers together (`mtime_zero`)

No TrustZone setup: assigning D0 a TZC group or enabling a PSRAM region without a range locks D0 out of its own code.

### D0 (`bl808/start.S`)

Spins ~80ms (M0 finishes D0's clocks after release), sets up traps (vectored; PLIC at 0xE0000000), gp/tp/sp, zeroes .bss/.tbss (the image is already in place), enables caches, then `sys_init` -> `.init_array` -> `main`. D0 caches XRAM.

## Inter-core link

`bl_common/xram.d`: per channel, one SPSC ring per direction, 4K each: producer counter at +0x00, consumer counter at +0x40 (own cache lines), data from +0x80 (3968 bytes). Counters run free. A write rings the peer's IPC doorbell with the channel's data bit, a read with its space bit. IPC blocks: M0 0x2000A800 (CLIC 16+3), D0 0x30005000 (PLIC 16+38); words: 0 set, 9 status, 10 clear, 11 unmask, 12 mask. D0 cleans/invalidates around each access; M0 relies on the uncached SYSMAP.

The link has no carrier: bytes written before the far end opens are lost. Sync copes through its reliability sublayer, which `/interface/framed` (COBS, no reliability caps) arms.

```text
# D0 (COM12)
/stream/xram add name=m0 channel=0
/interface/framed add name=m0link stream=m0
/sync/peering set role=member
/sync/peer add name=m0 transport=m0link

# M0 (COM11)
/stream/xram add name=d0 channel=0
/interface/framed add name=d0link stream=d0
/sync/peer add name=d0 transport=d0link claim=yes
```

D0's `/sync/peering print` then reads `state: claimed`, and M0's `/device/print` shows D0's devices.

## Timebase

Each core's `mtime` divides its own core clock (`MCU_E907_RTC` 0x20009014 for M0, `MM_MISC_CPU_RTC` 0x30000018 for D0: DIV [9:0], bit 30 holds the counter at zero, bit 31 enables). There is no shared timer, but both clocks come from the one 40 MHz crystal, so equal rates never drift. `bl_common/clock.d` sets both to 160 MHz (M0 320/2, D0 480/3) and M0 zeroes the two counters together right after releasing D0, whose counter does not run while it is halted. The cores read one timebase, measured within 125 ns over XRAM.

## GPIO, PWM and the M1s Dock panel

`GPIO_CFG` n at 0x200008C4 + 4n: input enable 0, schmitt 1, pull-up 4, pull-down 5, output enable 6, function 12:8 (11 = SWGPIO, 16/17 = PWM0/1), output 24, input 28, mode 31:30 (2 = the transmit FIFO). Older urt code used a layout neither chip has.

PWM (`bl_common/pwm.d`): two blocks at 0x2000A440 and 0x2000A480, four channels each with positive and negative outputs, XCLK through a whole divider, per-output active level. Pin n reaches output n % 8 of either block (channel (n % 8) / 2, negative on odd pins); only GPIO8 has been checked. The block's clock gate is `GLB_CGEN_CFG1` bit 20. Software PWM covers pins no channel reaches.

WS2812 (`bl_common/ws2812.d`): the GPIO transmit FIFO, `GPIO_CFG142`-`144`, XCLK counts per code; untested on a real WS2812.

M1s Dock: a plain active-low LED on GPIO8 (not a WS2812, despite old code), S1 on GPIO22 and S2 on GPIO23 (active low, pull-up). RST is the hardware reset line; BOOT is not readable from the BL808 (pressing it makes the BL702 toggle GPIO20/21).

## Key Addresses

| | D0 | M0 | BL618 |
|--|------|------|------|
| Flash XIP | 0x58000000 | 0x58000000 | 0xA0000000 |
| Code | 0x50100000 (PSRAM) | 0x58000000 (XIP) | 0xA0000000 (XIP) |
| Fast RAM | 0x3EFF8000 SRAM 64K | 0x22020000 OCRAM 64K | 0x62FC0000 OCRAM |
| Console | MM UART @ 0x3000_2000 | UART0 @ 0x2000_A000 | UART0 @ 0x2000_A000 |
| IRQ controller | PLIC @ 0xE0000000 | CLIC | CLIC |
| XRAM | 0x4000_0000 16K | 0x4000_0000 16K | -- |
| IPC doorbell | 0x3000_5000 | 0x2000_A800 | -- |

M0-side MM registers: PDS_CTL2 0x2000E010, MM_CLK_CTRL_CPU 0x30007000, MM_CLK_CTRL_PERI 0x30007010, MM_GLB_SW_SYS_RESET 0x30007040, MM_MISC_CPU0_BOOT 0x30000000, MM_MISC_CPU_RTC 0x30000018, SYSMAP 0xEFFFF000.

### BL616 / BL618 (M0P Dock)

No TCM. Cacheability is address-based: bit 30 set = cached (`0x62..`), clear = non-cache (`0x22..`/`0x23..`), same RAM. OCRAM 0x62FC0000 320K cached (top 64K aliased non-cache at 0x23000000 for DMA), WRAM 0x23010000 160K reserved for WiFi, PSRAM 0xA8000000 4M (not yet a pool), HBN 0x20010000 4K. `0x20000000` is GLB register space on these parts, not RAM.

## Pitfalls

- **The E907 on M0 has a write-back D-cache, on from boot2.** Anything another master reads (D0 reading the image, XRAM) needs a clean or an uncached mapping.
- **The boot ROM API table has unimplemented entries** (`0xdeedbeef`). Flash operations use the vendored SF driver in RAM, with the flash config derived from the JEDEC id.
- **Code that runs while flash is busy must be entirely in RAM**, including helpers like `arch_delay_us` (`@critical`) and switch tables (the no-jump-table flags).
- **The CPU PLL's "400M" name is nominal.** Boot2 programs it with the vendor's 380 MHz table; M0 reprograms it to 480 MHz. Measure a core's real rate against the host clock (sample `/system/sysinfo` time over serial ~40 s apart), never against its own cycle counter.
- **Anything counting mtime ticks as microseconds is wrong on the BL808**: scale by `mtime_freq_hz`.
- **`lw` sign-extends on RV64.** Use `lwu` in D0 asm for addresses with bit 31 set.
- **M0's LLVM target has no T-Head cache instructions**: emit them as `.word`. D0's target takes the `th.*` mnemonics.
- **WIFIRAM base must stay 0x22030000**; the PHY DMA is routed to that bank.
- **Vendor PSRAM C requires `-DARCH_RISCV`.**
- **A register that reads and writes may still be unclocked.** Peripherals behind a clock gate (PWM: `GLB_CGEN_CFG1` bit 20) accept writes but never change status, so a wait on a status bit spins forever. Bound such waits.
- **M0 has a hardware watchdog** (`bl_common/watchdog.d`, MCU timer block): a main loop stalled for 5 s resets the chip and boots as `crash (watchdog)`. Resolve a crash report's addresses with `riscv64-unknown-elf-addr2line -e bin/bl808-m0_release/openwatt`.
