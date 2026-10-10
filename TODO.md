# TODO

- **CI is held off release compilers by dlang/dmd#23605**: on 32-bit x86, a D-declared subclass of
  an `extern(C++)` root gets its generated `__aggrDtor` with D linkage while the virtual call uses
  the C++ convention, so the destructor receives the vtbl pointer as `this` (fixed by #23606 in
  2.114). Host CI builds DMD with `dmd-master` and excludes LDC x86, since LDC is still on the 2.113
  frontend. Restore the release DMD and the LDC x86 jobs once both releases carry the fix.

## URGENT: undo at the next compiler update

These work around compiler bugs. Undo each as soon as the minimum DMD **and** LDC carry the fix;
left in place they are dead weight whose reason is invisible in the code.

- **Delete every `~this() {}` in `src`** (179: every class in the `BaseObject`, `CommandState` and
  `Component` hierarchies; `grep -rn '~this() {}' src` finds exactly these) once the minimum
  frontend is 2.114. Before dlang/dmd#22931, a C++ destructor below a class that does not declare
  one is not virtual. Delete uRT's `cpp_dtor_chain_declared` check in `urt/mem/alloc.d` in the same
  change; it switches itself off at `__VERSION__ >= 2114` and would stop enforcing anything.
- **Move `BaseObject.alias Properties` back above `flags()`** in `manager/base.d` once the minimum
  DMD carries dlang/dmd#23946. On Windows targets, an overload inserted in front of the reserved
  C++ destructor slot does not move it, and the destructor overwrites the shifted function. Until
  then, an `extern(C++)` root must lay out `~this()` before its other virtuals: declare it first,
  and name no virtuals in a class-scope alias above it.

- uRT's class `free` passes the static type's instance size, so freeing a derived object through
  a base reference (every collection free) under-reports it to `MemoryThreats` accounting on targets
  whose allocator does not report usable size (Windows, Linux, ESP); the accounted total drifts up.
  Bare-metal heaps use `_memsize` and are exact. Needs the dynamic size at free.
- Each executed console script appears to leak about 80 bytes (two 40-byte blocks); suspected
  `Expression` nodes from parsing, see the expression ownership rework. Measured with the
  `ALLOC_TRACKING=1` console-restart probe after the destructor fixes; unconfirmed, because the
  tracker cannot attribute it on Windows (next entry).
- `urt.mem.profile.record` call-site names are garbled on Windows DMD debug builds (file names
  overwrite each other and every site resolves to one unrelated function), which makes
  `/system/alloc/leaks` unusable for attribution there.

- Validate boot-guard OTA handoff on ESP32 hardware with NVS write/commit failures
  and power loss before/after image acceptance and rollback slot selection. Also
  exercise record loss/corruption and the power-on gesture on embedded targets.
  Host fault-injection tests and cross-compilation do not substitute for these checks.

- Give `ObjectRef` an `opCast(bool)` that tests for a stored identity, preserving
  `detached()` as the unresolved-target check and `alias get this` for object access.
  Audit existing boolean uses (including negation, logical operators and ternaries)
  and replace live-target checks with `!ref.detached` before changing conversion
  semantics. Replace the bridge master's `name.length` identity check with the bool
  conversion. Cover empty, resolved, destroyed and recreated targets in tests;
  leave null comparisons unchanged (`is` cannot be overloaded in D).
- Export passive `BaseObject` configuration as fully configured creations after
  active object identities exist, without an enable phase. Preserve passive
  dependency ordering (for example DHCP leases reference IP pools) and replay of
  existing boot-created objects.
- Let PPP/PPPoE servers target a bridge and create membership rows for accepted
  session interfaces. Use the shared bridge-port collection and dynamic endpoint
  cleanup rather than a separate membership path.
- Fix the Windows empty-directory `get_temp_filename` contract in uRT; the native
  console unit test fails creating its script file (command.d:590), including
  outside the sandbox. WSL unit tests pass.
- Complete bridge VLAN membership tables beyond per-port PVID configuration;
  non-PVID ingress with filtering and non-PVID egress currently drop.
- Decide uRT's memory-flags contract for allocations that must remain accessible
  while the flash cache is disabled. The power regulator's `FireEngine` uses
  `MemFlags.fast`, which prefers internal SRAM but may fall back to PSRAM under
  exhaustion or fragmentation, allowing the ISR cache-access crash to recur.
  Deferred from #745: provide guaranteed internal placement with clean allocation
  failure, and test the exhausted-internal-heap path.

- Verify `/system/reboot bootloader=1` on classic ESP32 hardware; the downloader
  path has compiled, but its RTC GPIO0 hold and subsequent flashing cycle remain untested.
- **SocketCAN hardware validation (#503)**: exercise a physical controller's bitrate
  changes, rejected timing restoration, bus-off recovery and capability failures.
  Validate Linux USB WiFi/BLE removal on real adapters.

- Separate Element's unseen state from a valid zero timestamp; held-value dedup
  currently treats SysTime.init as unseen on clocks whose epoch starts at zero.
- Make Tesla BLE startup report unsupported AES-GCM/ECDH backends directly on
  embedded targets instead of discovering the missing backend during a session.
- Support or explicitly reject Linux builds without mbedTLS: uRT KeyPair currently
  fails a static assertion before the backend-independent unit tests can run.
- Endian codegen follow-up: investigate LLVM array-return lowering for ARM native
  double stores and Beken/Xtensa swapped stores; direct pointer-output comparisons
  are shorter, but returning the same byte array recreates the existing sequence.
  Check remaining strict swapped-16 masking and Xtensa bytewise lowering despite
  unaligned capability. Keep any DMD improvement simple; no compiler-specific
  FP path is justified by the current results.
- Verify ESP-IDF RV32 emulated TLS with two tasks: distinct temp arenas, contents
  preserved across preemption, and allocations reclaimed after task deletion. uRT
  #303 is merged; flag checks and C5/BL618 cross-builds passed, but this hardware
  isolation/cleanup test remains outstanding.
- Firmware-test the uRT P4 RV32IMAFC/ilp32f correction (removes unsupported standard
  D/V extensions). O2/Oz scalar fragments pass; no board execution yet.
- Retest packed-member access after LDC #4236 is fixed before removing the byte-copy
  workaround: https://github.com/ldc-developers/ldc/issues/4236.
- Verify the width-aware uRT endian paths on RP2350 hardware using the DHCPv6 IA_PREFIX
  reproducer before retiring the global strict-alignment proposal in uRT #306. Optimized
  Cortex-M33 IR/assembly and host suites pass; the target test image has only been built.
- Before deploying the LittleFS-default uRT update to existing SPIFFS devices, back up persistent
  files, explicitly format LittleFS, restore configuration/identity or re-adopt, and verify
  persistence after reboot. Mount failure does not auto-format; re-adoption alone is insufficient.

Outstanding work and follow-ups, including point fixes and work awaiting a design decision.
When an item lands, delete it or reduce it to the work that remains;
the commit history and linked design documents carry the implementation record.

## HIGH PRIORITY: a target with no crypto backend fails in the field, not at build

`aes_gcm_encrypt`/`decrypt` and the ECDH helpers are dispatchers to mbedtls or Windows CNG;
bare metal has no third branch and returns `unsupported` at runtime. SHA-256 and HMAC do
have software implementations, and the CSPRNG has hardware backends on Beken and RP2350,
so randomness is real on those two and absent on every other bare-metal target. An image
still builds cleanly and then cannot do TLS or a Tesla vehicle session, and nothing says so
until it is running on a device.

The Tesla and TLS unit tests are gated on `has_crypto` to keep the suite moving. That is a
holding action, not an answer. Options, cheapest first:

- let `has_crypto` gate the features themselves, so an image that cannot do AES-GCM fails
  to build rather than failing on a customer's device;
- add a software AES-GCM to urt, which serves every bare-metal target;
- bring a trimmed mbedtls to bare metal if ECDH is genuinely needed there.

## HIGH PRIORITY: saved configuration can lose state on reboot (#665)

- **KNOWN RESTORE LIMITATIONS, explicitly deferred for #665: boot-created objects and omitted dependencies.**
  Phased export creates objects disabled, applies saved properties, then enables only
  those originally enabled. Forward references and cycles between exported objects
  are handled. References to excluded dynamic, temporary, remote or missing objects
  still require those identities to exist when properties are applied.
  Existing names from process defaults, discovery and `system.conf` reject the create
  command; later sets apply explicit properties, but cannot undo earlier startup or
  restore omitted defaults/removals. An already-enabled boot object saved as disabled
  is not disabled by the rejected create. Keep `system.conf` for early hardware
  sequencing; design reconciliation across firmware changes and the later `user.conf`
  layer. Save success is not proof of complete restoration or remote reachability.
- **HIGH PRIORITY HARDENING, explicitly deferred for #665: secret-store scope and access.** Every hashed password, including
  verification-only admin credentials, is persisted as reversible hex plaintext.
  Restrict recoverable storage to explicit outbound requirements and create it with
  owner-only permissions; the current POSIX save path requests mode 0666. Define
  deletion/rotation cleanup so superseded plaintext does not accumulate indefinitely.
- **HIGH PRIORITY: confirmed remote configuration changes.** A config can parse and
  stay alive while disabling management connectivity. Add a confirmation deadline,
  explicit remote acceptance and automatic return to a protected known-good revision;
  uptime alone is not proof of reachability. Current rollback detects integrity/syntax
  errors and NVS-counted failed boots, not command errors or management disconnection.
- Exercise revision publication and rollback under actual power interruption on each
  embedded filesystem (SPIFFS/littlefs), including NVS boot-failure recovery. Host
  fault-injection tests do not establish the storage driver's power-loss guarantees.
- Bound cleanup of crash-left `.tmp` and rejected `.bad` revision files without losing
  useful recovery evidence; successful-save retention currently prunes completed files.
- Complete the config-dirty mutation coverage (`set-hostname` currently bypasses it).
- **Retained reset/clock validation after uRT #322/#327**: the pin includes the
  merged watchdog-clock and reset-barrier fixes plus RTC restore. Verify Beken
  reset with its watchdog initially disabled, RP2350 mark/reset and wall-time
  restore, and cold power cycles without sync. Add regression coverage for
  invalid/warm records, repeated take/caller ordering, scratch preservation,
  and RTC offset restoration. Reconcile the RTC stop/reset contract with the
  ESP32 no-op and RP2350 stop-only implementations.
- **Boot guard follow-ups**:
  - **BK7231 and BL618 arm no hardware watchdog.** `driver.baremetal.watchdog` drives one only on
    the BL808 M0, MT7621, RP2350 and STM32, so a hang elsewhere never resets and never counts. Arm
    each part's watchdog from `watchdog_init`; the record already classifies the resulting
    reset (`running` left in place reads as a watchdog). Bouffalo also has no `system_reset()`:
    its reset needs the vendor's clock-switch sequence from TCM (`GLB_SW_System_Reset`), so its
    fault paths still halt and the crash only ends with a power cycle, which erases the record.
  - **BK7231 and Bouffalo classification is unverified on hardware**: both build with the
    record in place (BK7231N `.persist` after `.bss`; Bouffalo at the top of HBN RAM, one slot
    per BL808 core), but no board was attached. Check that the Beken bootloader and the
    Bouffalo boot ROM leave those bytes alone across a reset.
  - **No bare-metal part has a filesystem** (RP2350, BK7231, Bouffalo): LittleFS exists only
    for ESP (`urt/driver/esp32/littlefs_port.c` over `esp_partition_*`, enabled for `esp%` in
    `platforms.mk`). Without one these parts have no `startup.conf`, no saved revisions and no
    boot store, so the bring-up defaults are their only rung and the gesture counter never
    survives a power loss. Each needs a LittleFS block device over its own flash, a region
    carved out of the linker `FLASH` region, and `USE_LITTLEFS` on by default. RP2350: the
    bootrom's `flash_range_erase`/`flash_range_program`, called from RAM with XIP exited and
    interrupts off, then the QMI XIP configuration restored, as pico-sdk's `flash.c` does.
    The library itself is already in urt (`third_party/littlefs`, v2.11.3); only the block
    devices are missing.
  - The Linux supervisor's own slot probation (30 s soak, three failures) still runs beside the
    app's ladder and should defer to it.
  - A fixed recovery image, built once and never updated over the air, as the final rung on
    parts with no A/B slot.
  - **A recovery boot as the last rung** (the automatic half of #776; the manual
    `/system/reboot bootloader=1` landed). When the bring-up defaults crash out with no previous
    image, a platform whose recovery boot comes back on its own when nobody answers (RouterBOOT's
    try-Ethernet-once; not RP2350 BOOTSEL or the ESP32 ROM, which wait forever) could reboot into
    it unattended: the boot guard decides when, a `has_recovery_boot` /
    `system_reboot_to_recovery()` pair decides how. It needs, in order:
    - boot-state persistence on MT7621, its only candidate, which today keeps no boot-guard state
      across a reset at all (see the MT7621 entry below), so `checkpoint()` never commits a rung;
    - a failure contract: arming reports failure, and the boot guard keeps the transition pending
      and retries instead of clearing it;
    - recovery once per crash episode, recorded in the boot state and cleared by a healthy boot,
      since arming RouterBOOT erases its settings sector and RouterBOOT rewrites it to disarm, so
      re-arming every three crashes in an unattended loop wears that sector;
    - a defined state after the recovery boot (MT7621 classifies a software reset as `unknown`,
      and the deliberate-reset branch does not reset the rung);
    - an end-to-end test of crash, checkpoint, recovery and fallback on the board.
    An ESP32 factory app partition is the natural second implementation.
  - **A stepped-down unit stays down until someone reboots it**, even after the fault clears; on
    the bring-up defaults it is off the site network. Decide whether a healthy lower rung
    schedules its own retry of the top, with backoff (10 min, 1 h, 6 h, ...).
  - The reset gesture on a BOOT button; safe-state indication in the beacon and on an LED.
  - Wire up retained wall time on BK7231, BL618 and STM32; verify counter registers and
    reset/power-loss behavior on hardware.
- **The BK7231N `switch-ip` build no longer fits**: `make PLATFORM=bk7231n CONFIG=release
  FEATURES=switch-ip HEADLESS=1 MODBUS=0` links but the packed image is 157,830 bytes over
  `_image_limit` on master (2026-09-22); the last ledger row (2026-09-09) had 4,640 bytes spare.

## Driver audit (2026-09-30): STM32, RP2350, serial, panel

What an adversarial review of the STM32 and RP2350 drivers, the serial event path, the boot guard
and the panel left outstanding.

- **The RP2350 warm-boot console stall was never explained.** After a core-only (AIRCR) reset the
  IRQ UART once left the console silent. `system_reset()` now resets the whole chip, and the UART
  resets itself on open; with AIRCR forced back in, six core-only resets came up live, and without
  the open-time reset only the first input was lost. A debugger's SYSRESETREQ is still core-only:
  if a silent console follows one, the cause is open.

- **DMA** for UART RX and TX on every family (**F4 and F7 take an interrupt per byte**, see the
  STM32 section), for WS2812 frames, and for PIO in general.
- **F4 has no receiver timeout**: its gap is the one-character IDLE line, not 3.5 characters.
- **The RP2350's gap is the PL011's fixed 32 bit times** (3.2 characters at 8N1).
- STM32 UART: 7-bit framing (parity always forces M), 1.5 stop bits, OVER8 for high baud on F4,
  the error callback with `rx_avail == 0`, H7 kernel-clock selection.
- STM32 PWM, per family: TIM9-14 on F4/F7 (TIM9-11 AF3, TIM12-14 AF9), TIM12-17 on H7, LPTIM and
  the H7 HRTIM, each with its own alternate functions and clock; TIM1/TIM8 complementary outputs
  (CHxN), dead time and break inputs; PB3/PB4 are SWO/NJTRST at reset and should not be taken
  silently; the achieved frequency is not reported; `apb1_timer_hz` hard-codes x2 (TIMPRE
  unhandled).
- STM32 IWDG: WWDG and its early-wakeup interrupt (which could stamp the reset record with the hung
  PC) unused; the timeout rides the uncalibrated LSI (F4: 3.4-9.4 s for 5 s);
  LPWR/CPU/D1/D2 reset flags unreported.
- STM32 EXTI: edge direction thrown away on `gpio_change`; no autonomous tier (TIM capture to DMA
  to BSRR, H7 DMAMUX); lines 16+ (PVD, RTC, COMP) unused; no arbitration with a future GPIO
  interrupt API.
- RP2350: POWMAN reset flags unread; the reset record
  still overlaps SCRATCH2-3, which ROM `reboot()` writes, so a ROM reboot reads as an update; PWM
  phase-correct mode, input capture and in-phase start unused; the PWM CC update is not ISR-safe;
  WS2812 frames block the main loop and the line floats after close; **PIO allocation**: the
  WS2812 driver hard-claims PIO0 and its state machines 0-3, and never sets PIO `GPIOBASE`, so the
  RP2350B's pins 32-47 are out of reach (a PIO block addresses 32 pins, 0-31 or 16-47, shared by
  its four state machines): PIO blocks, state machines and instruction memory want an allocator;
  RP2350 hardware PWM has never run on hardware (the Y23A's only light is the WS2812); RP2350-E9 (the pull-down latch) is undocumented for inputs.
- GpioBinding: no GPIO ownership arbitration (two bindings on a pin, or a binding on a UART pin,
  work until one releases); `led=` writes a synced peer's light (no ownership check, unlike the
  panel).

## Bouffalo drivers (2026-10-02)

- **The BL808 cannot name its resets.** HBN_RESET_EVENT and PDS_RESET_EVENT read the same after
  power-on, the reset pin, a software reset and a watchdog bite, and the watchdog's WTS flag dies
  with the reset it causes, so `reset_cause()` is `unknown` and an unrecorded reset reads as the
  watchdog. A pre-bite latch (a timer compare just short of the watchdog, whose ISR stamps the
  record) would name hangs that keep interrupts enabled.
- **D0 reads a chip reset M0 starts as a crash**: its own record still says running. D0 should
  take the chip's classification from M0, or both cores read one chip-level record.
- **Flashing through the M1s Dock's BL702 at 1.2 Mbaud loses bulk data** from the chip since
  2026-10-02, whatever image runs (handshake and short commands pass; a 4 KB read stalls);
  500 kbaud works. It flashed and read 16 MB at 1.2 Mbaud on 2026-09-30. Also unexplained: from
  2026-09-30 07:48 the tool's own entry never got a handshake through the bridge, and from 10:32
  neither did `bootloader=1`, until the board was restored from a backup through a USB-UART on
  GPIO14/15; it has not recurred since.
- **The BL808 PWM pin map is inferred** (pin n reaches output n % 8) from the vendor dev kit's
  wiring, and confirmed only for GPIO8 on block 0.
- **The WS2812 FIFO driver has never met a WS2812**: the M1s Dock's LED is a plain one.
- **GPIO interrupts and event links are M0's only.** D0's PLIC has no GPIO line, so its edges must
  come from M0; the BL618 has its own CLIC line and wants the M0 backend.
- **The BL618 has no watchdog**: give it the MCU timer watchdog the BL808 M0 uses.
- **M0 SRAM runs near full**: 20 of 21 KB with two telnet sessions, 768 B to spare.
- **M0 resets by watchdog without a known cause**: once during a night idle on the full image, and
  two or three times in the first minute of a `D0=0` image on the bring-up defaults rung, after which
  it ran clean. Log the stalled main-loop work before the bite, then reproduce.
- **D0's heartbeat rides the 1 s application heartbeat**: its 500 ms is a minimum interval, not
  a cadence. Schedule it if 500 ms is meant.
- **M0 takes 6-9 s to inflate D0 at boot.** Inflate runs from XIP flash into PSRAM; measure where
  it goes (flash reads, PSRAM writes, the inflater) before choosing between placing the inflater in
  RAM, raising the clocks first, or letting D0 inflate its own image.

## UART follow-ups (2026-10-02)

- **RS485 in the driver on BK7231, Bouffalo, RP2350, MT7621 and the STM32F4**: software DE needs
  the moment the shifter empties. STM32F4 has a transmit-complete interrupt and ESP32 already
  times DE in the IDF's half-duplex mode; BK7231's `TX_STOP_END` is unverified, Bouffalo's TX-end
  interrupt belongs to its transfer-length mode, and RP2350 and MT7621 raise nothing, so they need a
  driver-owned timer alarm or a spin in the ISR of up to a character (a millisecond at 9600).
  `turnaround_us` is refused everywhere yet.
- **Line activity callback**: report when the RX line goes active (the first edge after idle) and
  idle again, once per transition, with the edge interrupt armed only while idle. A receiver sees
  activity, not drive: an idle biased bus and a driven 1 read the same, unless the board drives DE
  from inverted TX with DI low, which makes the bus wired-AND and lets readback arbitrate. Capture
  per part: EXTI on STM32's RX pin, a GPIO edge on RP2350, ESP32 and Bouffalo (to confirm), likely
  unsupported on MT7621; report unsupported from the call.
- **UART DMA**: STM32 (the F4 most, with no FIFO), RP2350, Bouffalo and ESP32's UHCI can move the
  lent pages and the RX ring by DMA behind the same API.
- **RX pages when consumers keep buffers**: the driver fills pages, but SerialStream copies each
  burst into `incoming`; once packets can be views onto refcounted pages, hand the pages up.
- **Hosts report no RX gap**: a USB adapter delivers in blocks on its own timer (a CP2102 256 bytes
  every 22 ms on Linux, 512 every 44 ms on Windows), so the quiet that ends a frame never reaches
  the host, and serial bursts come up open; a gap-framed protocol on a host (Modbus RTU) frames by
  length and CRC. A board's own UART may do better: the 8250 and PL011 drivers push on their
  receive timeout, so a Pi's ttyAMA/ttyS might deliver promptly enough to time gaps from reads.
  Explore it when there is a rig (TODO at `uart_reports_rx_gap` in urt's posix backend).
- **Windows serial ports carry no USB identity**, find only COM names, and leave FTDI adapters at
  their 16 ms latency timer; SetupAPI, a name table and the driver's registry setting, each a
  TODO inline in urt's `driver/windows/uart.d`.
- **Main-thread latency is not measured.** ISR-posted events dispatch with age 0, and the worst
  handler, event age and loop iteration are logged only past 50 ms. Stamp ISR posts and keep
  running maxima as stats, so `rx-latency` and buffer sizes can be set from measurement.
- **A console session loses input around Ctrl-C.** Ctrl-C on a configured session's initial
  `/log/print --stream` restarts the session, and bytes that arrive meanwhile are dropped or fed to
  the restarted stream; a long line pasted soon after loses its head. The UART delivers every byte
  (counted at the stream on both BL808 cores at 2 Mbaud).
- **Console output lost chunks on the BL808 at 2 Mbaud**: the console session's update spent
  51 ms in each UART write, and the stream took a short write as sent, so long output (the echo of
  a 500-character line, `/log/print`) arrived with holes on both cores. The stream now queues what
  the line has not taken and a UART write never waits; retest on both cores, and find what held
  TX for 50 ms if the stall remains.
- **Console output past a serial stream's TX bound is lost until S4**: `Session` writes with
  `write()` and ignores a short write, and `SerialStream.write()` refuses once 2 KB waits in the
  driver, which drains asynchronously. Replies that outrun the line lose everything past the bound:
  40 queued `/system/sysinfo` over a pty with a slow reader gave 29 replies. Master hid it on Linux
  behind the kernel's tty buffer and spun up to 50 ms per ring-full on embedded parts. Pull-driven
  print (S4, #817/#803) retires it.
- **Type-ahead is echoed again after every command**: the session redraws all pending input with
  each prompt, so n queued commands echo n(n+1)/2 times (40 queued: 755 copies, 13 KB). Echo
  pending input once.
- **ESP32 UART close leaves the module clock on**: the port is set up through IDF's public calls
  (`uart_param_config`, `uart_set_pin`), and IDF marks the module enabled in its driver's state;
  only `uart_driver_delete` on an installed driver turns it off, so turning it off ourselves would
  leave the next open with a dead UART. Pins are released on close. A trimmed copy of the IDF
  driver's setup would own the clock too, at the cost of tracking IDF's private internals.
- **The ESP32 UART interrupt is not IRAM-resident**: IDF holds it off while flash is written, so
  a long littlefs write at a high baud can overrun the RX FIFO. Allocate it with
  `ESP_INTR_FLAG_IRAM`, with the ISR path and the core it calls placed in IRAM.
- **Live reconfigure is unrun on embedded hardware**: every backend re-initialises its UART in
  place under a critical section, which the register models pass. An earlier live RXFTCFG change
  on the DevEBox H7 (a pending threshold applied from the TX complete interrupt) hung the board
  twice, so change baud and `rx-latency` on a running H7 and BL808 before relying on it; LPUART1
  is untested either way.
- **SerialStream has no tests of its own**: urt's pseudo-terminal test and register models cover
  the driver, and the hosts ran on a CP2102, but the stream's restart on a lost device, its
  reconfigure fallback and its burst delivery are untested at the stream.
- **The panel's reset gestures have no test**, including a reset binding stopped or replaced mid-gesture
  (a review probe confirmed it disarms): a module test would build its own Application, and an
  Application cannot be created twice in one process, since its destructor releases neither the page
  pool nor the event queues, intrinsics and signal providers its constructor registers.
- **`Duration` properties print as raw nanoseconds** (`get` shows `3e+10ns` for `30s`): the value
  reaches the console as a quantity rather than through `Duration`'s own formatting.

## Driver contracts (2026-10-04)

urt's driver contract suite (`test/driver/`, CI only) runs the UART and event-link cases
against every bare-metal backend over register models. What it does not reach, or what the
backends still cannot do:

- **ESP32 is outside the suite**: its UART ISR is D on the shared core, over a C shim of HAL calls in
  `ow_shim.c`, and its GPIO logic is C. A fake of those shim calls would put the UART in the suite;
  the new ISR has not run on hardware. The watchdog adapter ignores the requested timeout and stop.
- **BK7231 refills TX from Timer2**: its `TX_FIFO_NEED_WRITE` never fired at bring-up, so Timer2
  refills the FIFO every half FIFO's worth of line time while a port has pages queued. If the
  interrupt is edge-triggered on the FIFO falling below its threshold, enabling it only after a fill
  above the threshold would make it work and retire Timer2: try it on hardware. `TX_STOP_END` may be
  the transmit-complete event RS485 needs. Nothing shows the shifter, so a flush waits a character
  time after the FIFO empties rather than for a status. It reports no RX gap.
- **MT7621's UART interrupts are unverified on hardware**: it moved onto its 16550 interrupts (GIC
  26-28) and runs only in the model, since no board here exposes its UART. Its I2C is synchronous,
  and the netconsole copies the console UART until OpenWatt carries a UDP log sink.
- **Bouffalo delivers bytes that failed parity**: the FIFO keeps them, so the error is reported
  but the byte is not dropped.
- **The suite covers UART and links only**: PWM, WS2812, watchdog and reset, I2C and SPI want the
  same treatment.
- **The parity rework is unrun on hardware**: the BK7231 and MT7621 UART changes, MT7621 edge
  ownership and the ESP32 pin claims are built and model-tested only.
- **Bouffalo's vendor printf** (picolibc stdout) still writes the console directly; hook it into
  urt.log as BK7231 does with `ow_log_vendor`.

## Flow-control duplication (2026-10-08)

Windows, retransmit, backoff and rate machinery is reimplemented per protocol. Each cluster wants
one primitive (most belong in urt) and its copies deleted:

- **Wraparound sequence compare**: `seq_lt/le/gt/ge` in `protocol/ip/tcp.d`, inline
  `cast(ubyte)(ack - x) < 128` in `manager/sync/peer.d` (`release_control`, `release_data`),
  hand-rolled mod-8 in `protocol/ezsp/ashv2.d` and `protocol/cpc/package.d`, and
  `cast(int)(l - r) < 0` in urt's `driver/esp32/ble.d`. One serial-number template over the bit
  width (3, 8, 32).
- **Capped exponential backoff**: `min(base << n, cap)` in `manager/base.d` (restart), sync
  `peering.d`, `tesla/vehicle_retry.d`, `zigbee/controller.d`, `dhcp/client.d` and `client6.d`,
  `tls/certificate.d`, `ip/linux_mirror.d`; retransmit timers in tcp.d (RTO), ashv2.d, cpc and
  sync `peer.d` (bounded only by `max_retries`, so its last interval is 64 s). One `Backoff`
  (base, cap, attempt, `next`, `reset`).
- **Bitrate sampler**: `router/stream/package.d` and `router/iface/package.d` heartbeat samplers
  are line-for-line copies, as are their status structs in `router/status.d`. One `RateMeter`.
- **Debounce and pacers**: automation and `protocol/gpio` each schedule their own debounce;
  automation also holds the only throttle and token bucket. Share them as general pacers.
- **Window with reserve** (limit, in flight, headroom): TCP's free window, sync `max_unacked` with
  `control_reserve`, `PriorityPacketQueue` `_max_in_flight` with `_reserved_slots`, and the
  in-flight caps in BLE GATT, `driver/baremetal/ble.d`, `tesla/vehicle_session.d`. Sync channel
  credit is the next instance.
- **Go-back-N ARQ**: ASHv2, CPC (near copy of ASH) and the sync control plane each keep an
  in-flight list, cumulative ack and doubling ack timeout. One engine built on the three above;
  ASH and CPC need a dongle smoke before it lands.
- **Bounded tx byte queues**: Stream `tx_queue_limit` (repeated in `router/stream/serial.d`),
  websocket page queue with low water, BLE stream `max_tx_backlog`, ASH `max_tx_queue`, and
  the console session's pending page. These converge on page chains
  under the stream contract (docs/wip/STREAMING.md), not a new abstraction.

## Retrospective merge reconciliation (2026-09-08)

- **[#669, deferred until removal is needed] Define device/subtree removal lifetime**:
  DeviceTable currently has no removal API and production code never emits
  `ComponentEvent.destroyed`; the earlier P1 classification overstated a
  demonstrated runtime failure. Before introducing removal/recreation, define
  ownership and invalidate appliance/link references, topology watches and
  control caches before freeing Components or Elements. Include other raw
  model-pointer consumers and coverage for removing/recreating a bound subtree.
  Keep the process-lifetime model for now. If the code structure requires an
  unsupported removal path, it may assert; do not introduce a removal lifecycle
  until the feature is needed.

- **[#667] Validate Tesla recovery on a vehicle**: exercise category back-off,
  busy responses, session counter/epoch/clock faults, BLE loss, bounded key
  approval, and latch reset with a vehicle. Host regressions do not replace
  hardware acceptance. Legacy firmware predating encrypted responses remains
  unsupported; development requires access to an old offline car.

- **[#655, SDK acceptance] Select and pin a supported SDK revision**:
  Compare clean and incremental full N/T SDK builds with the selected revision.
  Full firmware and mode-retry cancellation/rebind still need hardware acceptance.
  Candidate evidence: SDK archives built against OpenBK7231T_App `fd131f3c`
  (N SDK `244bdfe8`, T SDK `12c68122`), with repeat builds preserving timestamps.
  The corrected N firmware links and packs successfully; T links but has the
  packed-size follow-up below. Neither result establishes boot acceptance.

- **[uRT Variant, deferred policy] Define erased-class downcasts**:
  Variant's current ancestry checks describe the stored type. Add a policy handoff
  if dynamic downcasts from its erased base type are needed.

- **[uRT no-RTTI build follow-up] Reconcile remaining consumers**:
  The full no-RTTI unit build fails in `urt.internal.traits`' associative-array
  enum test. Resolve that dependency before claiming full no-RTTI host/test
  support. Class-to-interface dynamic casts still use an unsupported runtime
  assertion; define their contract or reject them at compile time separately.

- **[Beken STA, hardware acceptance] Validate the merged integration**:
  Validate cold boot, association/recovery after lost confirmations, GTK rotation,
  mode changes, allocation failures, RX/TX pressure and shutdown on a pinned SDK.
  Exercise general-DMA TX copies with source offsets 0..3 and partial-word tails;
  source inspection establishes synchronous copying, not the hardware alignment contract.
  Measure service fairness outside the deferred-work budget and audit vendor
  interrupt-context logging. Keep synthetic L-SIG input disabled pending explicit
  buffer-length/metadata handling.

- **[Beken T, separate-session follow-up] Investigate packed firmware size**:
  T is provisional: no hardware is available, and T-specific differences remain
  unimplemented. N is the required Beken target. The maintainer authorizes
  dropping T from CI if it fails; its current uRT cross job passes. The local
  T packaging failure is separate from N support. The tested T firmware links, but `pack_ram_image.py` rejects the image as 2,006 bytes too large
  (about 2 KB, not 2 MB). Both N and T builds used `CONFIG=release`, `TINY=1`,
  `FEATURES=switch`, `HEADLESS=1`, `-Oz`, no RTTI, exceptions, IP or TLS.
  BK7231N now packs successfully at 1,079,206 bytes after the minimal-state audit. Evidence uses LDC 1.43,
  arm-none-eabi GCC 15 and the SDK revisions above. Rebuilding the SDK with
  `-Oz` instead of `-Os` produces the same overflow; that experiment was not
  adopted. Preserve the partition boundary and required behavior when reducing
  size. N is the target for this session and passes; investigate T separately.
  No comparable earlier size/map has yet established when growth occurred or
  whether a previously excluded blob was retained. Bisect in a new session if
  that difference is not immediately apparent. The failed build's `fw.bin` is
  an unpacked intermediate, not flashable.
  Logs: `.tmp/urt258-evidence/final-openwatt-t-link.log` and `t-size-link.log`.

- **WPA pairwise rekey**: the shared supplicant handles initial PTK installation
  and GTK rotation, but does not yet renegotiate a PTK on an established link.
  Add authenticated rekey transitions and retransmission tests without resetting
  receive counters when already installed key material is repeated.

- **[uRT build, in passing] Respect the compiler's Tiny version flag**:
  `platforms.mk` hard-codes `-d-version=Tiny`, so `TINY=1 COMPILER=dmd` fails
  before compilation. Use the existing compiler-specific `VERSION_FLAG`.

- **[Host build, local work] Reconcile the unfinished power regulator**:
  The untracked `src/driver/power/regulator.d` references `ComponentEvent.materialised`,
  `set_device_online` and `note_activity`, which are absent from the current model.
  It is discovered by the full source build; reconcile it with the intended model
  work before expecting this working checkout's host build to pass.

- **[Windows toolchain] Retire the default beta DMD and isolate LDC COMDAT failure**:
  PATH selects DMD 2.112.0-beta.1, whose unittest build fails copy-constructor
  detection at `urt.internal.traits:376`; installed stable DMD 2.113 passes the
  isolated OpenWatt suite. LDC 1.43 aborts the full Windows unittest build with
  an associative COMDAT error for `BLESession.find_char`; isolate that compiler
  failure separately. Evidence: `.tmp/urt258-evidence/adoption-host-build.log`,
  `adoption-isolated-build.log`, and `adoption-dmd-stable-run.log`.

- **[uRT host test] Investigate Windows x86 stack unwinding**:
  DMD fails twice at the unchanged `urt.internal.exception:453` stack-trace test.
  An isolated LDC 1.43 pbuf-only suite also reaches that failure after its pbuf
  tests pass. The larger LDC WPA/driver suites pass 76/76 and 77/77. Reproduce
  and isolate the cause; image-layout sensitivity is only a hypothesis.
  Evidence: `.tmp/urt258-evidence/final-host-run.log`, `final-host-rerun.log`,
  and the isolated series pbuf logs.

- **[uRT alignment, other ports] Audit opaque unwinder storage**:
  Beken now explicitly aligns `__eh_frame_object`. STM32, RP2350 and BL common
  still declare byte storage without an alignment contract; check their selected
  unwinder ABI and align or remove the unused registration path as appropriate.

- **[#657, transport follow-up] Complete IPv6 transport error delivery**:
  connect incoming ICMPv6 errors to TCP/UDP when their IPv6 delivery paths are
  implemented. Add per-destination path-MTU state and propagate local oversize
  output failures through a transport completion API; `output_v6()` currently
  returns void. Handle quoted fragments alongside IPv6 fragmentation/reassembly.
  Incoming errors currently reach pending echo diagnostics only. Add host-OS
  ICMP backends for `/ping`; IP echo currently requires the internal stack.

- **[P2, IPv6 UDP] Validate the native zone paths on hardware**: the zone contract in
  docs/wip/NETWORKING.draft.md is implemented for UDP on the internal stack, Linux and Windows, but only the
  internal stack has regression coverage. Still owed: a two-interface Linux run of the pktinfo
  receive path, connected link-local replies and `IPV6_MULTICAST_IF`; a Windows IOCP run of the
  IPv6 `IN6_PKTINFO` path (`kernel_ifindex6`); an ESP32 run of the internal stack over wifi
  (link-local replies, `ff02::` joins via MLD). The Ether family's `scope_id` stays 0
  (`UDPBindEndpoint` carries the station separately). urt's WinSock `IPV6_RECVPKTINFO` /
  `IPV6_PKTINFO` constants are the Linux values (49/50), not Windows' 19; the IOCP path defines
  its own, but `urt.socket.recvfrom` with packet-info is wrong on Windows.
- **[P3, build] The lwIP socket backend is unbuilt and unsupported**: ESP builds default to
  the internal stack and do not link lwIP; `USE_INTERNAL_IP_STACK=0` on ESP32 fails to compile
  (`IoReady` is Linux-only in manager/reactor.d, `Array!DNSQuestion` fails to emplace under the
  embedded toolchain). No driver records a lwIP netif index, so IPv6 zones would not translate
  there either. Either grow the FreeRTOS reactor and finish that backend, or delete the opt-in.
- **[P2, IPv6 UDP] IPv6 multicast without a zone on the internal stack joins every link**:
  `c_set_option(multicast6)` with `scope_id == 0` joins the group on each interface holding an
  IPv6 address (the DNS server's mDNS/LLMNR listeners rely on this), where a native stack picks
  one default interface. Decide whether a routed default is wanted instead, and whether the DNS
  server should join per link explicitly. `SocketOption.multicast` (IPv4) now also joins on the
  internal stack; before this it was a silent no-op.
- **[P3, IPv6 UDP] TCPv6 on the internal stack**: `c_create` refuses IPv6 stream sockets
  (`// TODO: TCPv6` in protocol/ip/socket.d); the v6 input path drops TCP segments. Windows IOCP
  TCP is IPv4-only too.
- **[P3, IPv6 SLAAC] Source selection is first-fit, not RFC 6724**: `preferred_source_v6` honours
  only rule 3 (skip deprecated addresses); no longest-matching-prefix, scope or ULA-versus-global
  ordering, and `source_for_target` in nd.d ignores deprecation. Renumbering (a `preferred=0` RA
  deprecating the old prefix under the two-hour valid floor) has only been reasoned through, not
  exercised against a real router.
- **[P3, IPv6 RA] Router-side gaps**: the SLAAC host still solicits routers on a link this node
  advertises (RFC 4861 6.3.7 says a router does not); no RA consistency checking against other
  routers on the link (6.2.7); no per-service DHCPv6 tie-in behind `managed`/`other-config`. The
  service has not been exercised against a real host beyond compilation.

- **[P3, style-audit deferrals] Preserve outstanding design work**: validate
  appliance port names against a profile-authoritative or explicit namespace
  instead of accepting every unknown string property as a circuit binding.
  Add borrowed protobuf byte fields so vehicle decoding can avoid one owned
  allocation per bytes field. These existing deferrals were moved out of long
  source comments during reconciliation.

## Energy

- **The topology publisher dominates the synced model**: measured on the prod Pi 2026-09-16,
  the `energy` device is 5298 of the node's 6613 tree nodes, 80% of everything sync carries.
  Every bus and every port emits all nine meter fields plus a `_source` provenance element each,
  whether or not the field is present, so a fully `missing`/`nan` bus still costs 18 elements.
  This is what pushed the model snapshot to roughly 1.1 MB. Gate the provenance elements behind
  `hidden`, or omit absent fields entirely and publish provenance only where it differs from the
  bus default.

- **Speed up topology publisher binding**: `TopologyPublisher.bind()` repeats
  `find_or_create_element` for every field of every record. A rebuild performs roughly 3000
  dotted-path lookups and takes about 106 ms on the Pi. Reuse bindings whose IDs did not
  change, or give `Component` keyed child and element lookup. The same storm dominates the
  233 ms first energy update after boot, where each creation also allocates a fresh String and
  fans notifications out to sync, websocket and api subscribers; a bulk-bind mode that
  suppresses per-element notification until the batch completes addresses both.

- **Cut the remaining energy update cost**: profile with the existing `log_slow_phase` and
  `log_slow_topology_publish` subdivisions before optimizing. Beyond the publisher storm above:
  debounce topology rebuilds until configuration settles, so early boot stops rebuilding the
  graph every frame; retain production strings per rebuild rather than per sample
  (`rebuild_productions` and `retain_production_string` heap-copy owner/group/port/circuit for
  every contribution, every sample); and intern the name comparisons that still scan strings
  (the `buses` map key, production owner/group/circuit compares, `circuit_in_island`,
  `attribution.terminal_index`, and `is_first_owner_port`, which is quadratic in ports). The
  solver's one-unknown-per-pass rescan is fine at current scale; the work-queue formulation
  removes the quadratic if large sites appear.

- **Upgrade the provenance representation**: the solver carries a flat provenance enum. Replace
  it with a dependency set of seed meters (a small fixed bitset) per solved value, so a value
  inferred from another inferred point stays distinguishable from a direct measurement,
  mismatch and outage reports can name the meters a value stands on, and outage-bridged values
  are distinguishable from never-metered ones. The precedence rule is unchanged: measured
  outranks inferred, boundary-most is authoritative among equals, disagreement beyond the noise
  floor keeps the winner and reports a mismatch, never silently average.

- **Report faults and underdetermined components**: publish, per connected constraint component,
  its closure residual and the identities of its still-free variables. Severity falls out of
  that: a normally-measured boundary degraded to inferred keeps accounting and alerts on the
  transition; multiple dark boundaries in one component lose category detail but keep net flow
  and name the culprits; a residual on a fully-determined circuit is a fault; sink absorption is
  a normal account. Today residuals only publish through the per-bus rogue/coverage fields.
  Never allocate a multi-unknown residual per port.

- **Seed zero through open switchgear**: appliance ports carry contact state (`read_port_closed`),
  but `ports_connected` treats appliances as unconditional junctions and group inference ignores
  per-port state, so an open contactor still exchanges inferred energy. An open port is a known
  zero, not an unknown. Land it with a review of the coverage semantics, since it moves buses
  from dark/bounded to measured and that is account-visible. Latent until something in-tree
  publishes `closed=false` on an appliance port.

- **Supply link loss**: every link/switchgear constraint carries a loss term defaulting to zero,
  so single-unknown group inference manufactures a zero-loss value for conversion appliances.
  Add providers keyed by declared link identity so learned state survives topology rebuilds:
  a configured bound (watts or percent) or resistance, and a learned fit where meters exist at
  both ends (`deltaV * I` is far better conditioned than subtracting two large powers; the
  fitted slope is the run's resistance, the intercept self-calibrates the voltmeter pair, and
  drift in fitted R is a corroding-joint diagnostic). Correct the propagated value and mark
  provenance as standing on a learned parameter.

- **Build transfer switch support**: `PortGroupKind.transfer` exists and asserts TODO. It needs a
  declaration surface (two input ports, one output, A/B/off position from contact feedback or a
  live element), connectivity per position, and acceptance tests. Do not infer position from
  instantaneous power.

- **Tighten underdetermined reporting**: on underdetermined components, use supply/consume-only
  flow domains to publish directional bounds, never a per-port allocation. Per-meter noise
  floors can stay a single constant (50 W / 2 percent of flow scale) until a meter accuracy
  class justifies refining them.

- **Complete session-derived SOC**:

  - persist the active session across OpenWatt restarts;
  - key statically paired VIN-less vehicles by appliance name;
  - keep truly unidentified cars on EVSE-scoped policies, where SOC has no useful identity;
    and
  - feed delivered-energy and SOC-delta samples into the capacity estimator.

- **Synthesize import/export counters for meters without them**: integrate active power into
  persistent per-port accumulators using a monotonic timebase. Publish
  `total_import_active`/`total_export_active` with `Provenance.integrated`, skip stale gaps,
  restart at zero on boot, and exclude these synthetic counters from recording by default.

- **Finish surplus-tracking behavior**:

  - verify the live grid-port sign convention;
  - modulate floor and essential policies from required energy and slack;
  - check cloud-edge churn and add hysteresis beyond quantization/dwell if required; and
  - remove the redundant `pressure_modifier` gate from opportunistic marginal value.

- **Expire stale allocation reasons**: policies omitted from the allocation queue retain their
  last displayed reason. Record an explicit idle/satisfied result each tick, or expire the
  reason elements.

- **A dead device reads as a measured zero, not as missing** (found 2026-09-17 on the prod Pi).
  `ModbusBinding.add_handler` seeds every scalar element with a zero record at materialise, before
  a register has been read (`src/protocol/modbus/binding.d:379`). `get_meter_data` accepts any
  non-NaN reading as `Provenance.measured` and never consults `Device.online_status`, so an
  inverter that has never answered presents authoritative 0 W port meters. On the Pi, `goodwe_ems`
  (TX 10 KB, RX 0, `status.online=false`) made `house.backup` and `dc_bus` rogue-value anomalies,
  double-counted the house battery's discharge into `generation` (once as `account.battery.power`,
  again as the dc_bus residual), and forced the house-bus residual onto the only unmetered link,
  fabricating hundreds of watts of `shed_evse` draw. Drop the seed, make
  `Element.normalised_value`/`scaled_value` return NaN for an unsampled element (`Variant.asQuantity`
  launders Null to 0), and treat meters on an offline device as missing. Peer-mirrored devices go
  stale silently too: `pt100`/`tac1100` read `online false` with 11-hour-old values while
  `cabin_hot_water` still consumed them as current.

- **The grid bus is flagged as an anomaly whenever the site imports**: `classify_bus_coverage`
  (`src/apps/energy/topology.d:1701`) runs on the island root like any other bus, so the grid bus,
  which has one metered port and no dark port to absorb the flow, goes `rogue-value` (and `anomaly`
  when importing) above the 50 W noise floor. The accounts are unaffected because `add_island_rogue`
  skips `island.root`, but the published bus state lies.

## Tesla TWC

- Mark sampled series gaps when a binding loses observation. TWC master outages
  currently mark the Device offline and detach providers without calling `mark_gap()`
  on sampled elements, so resumed history can bridge the outage. Define this in the
  shared binding/provider lifecycle, accounting for other live providers and preserving
  control setpoints; cover both shutdown and the silence watchdog, plus accumulator
  integration across gaps.

- **[#661] Validate fleet transfers on hardware**: exercise cap changes, circuit-budget
  reductions, dropped replies, restart/takeover, and measured-current ramp-down.
  Verify no current is reassigned until the lower limit is acknowledged and measured.
- **[#661] Establish a verified TWC stop/start operation**: the existing driver has a
  5A floor and cannot safely revoke an admitted charger's grant. The below-minimum
  fleet-budget case is deliberately deferred from this PR: decide admission/stop
  policy, zero grants, and live circuit-budget reductions below the fleet minimum.
  For now no new allocations are issued in that case; existing grants remain reserved.

- **[#661] Exercise arbitration on a two-master bench**: cover simultaneous startup,
  takeover after silence, duplicate bus ids, and ids sharing the same low nibble
  (the current jitter has only 16 slots). Also verify standby discovery from an
  already-running master's heartbeat replies without a fresh slave announcement.

- **Allow satisfied charging to turn fully off**: the vehicle model now carries
  `charging.enabled` (`src/apps/energy/vehicle.d`), but `pick_enable_element`
  (`src/apps/energy/control.d:427`) searches the control component and does not find it. Wire
  the two together. Until then, release bottoms out at 5 A instead of disabling charging.

- **Verify recovery on hardware**: confirm that a slave answers master heartbeats without a
  fresh announce after a link flap. If it does not, explicitly restart the announce ceremony
  when repeated heartbeats go unanswered.

- **Evict chargers that leave the bus**: `_chargers` only ever grows. A charger removed from
  the bus keeps its stale state flag and reservation until the next master restart, withholding
  its share of the budget; after the restart its flag is never set again, and because
  `next_offer` holds every offer while any known charger lacks fresh state, no charger can be
  offered more current than it already has. Its binding is also respawned on every master
  start. Needs a presence timeout that evicts the record and its dynamic binding.

## Tesla vehicle BLE

- **[#683] Validate vehicle write-back on hardware**: from the web UI, exercise charging
  enable, current setpoint (including 5 A), HVAC power and target temperature on the S3.
  Repeat after disconnect/reconnect and VIN removal; check existing and fresh sync mirrors.

- **Honor addr_type in Windows BLE connect**: `ble_hw_connect` in urt's Windows driver drops
  its `addr_type` argument; `FromBluetoothAddressAsync` assumes a public address, so connecting
  to the (random-address) vehicle likely only works while Windows has it in its scan cache.
  Switch to `IBluetoothLEDeviceStatics2.FromBluetoothAddressWithBluetoothAddressTypeAsync`.
  Blocked on testing against the car.

## 802.15.4 radio (WpanInterface)

- Create `wpan1` in the C5 and C6 system profiles, as on S31; both currently require
  manually adding the built-in radio.
- **Receive is validated on hardware; transmit is not.** On an ESP32-C5 DevKitC-1,
  `/interface/wpan/add name=wpan1 channel=15 promiscuous=yes` comes up Running with
  link-status up and counts real traffic off the air: 54 packets and 1,568 bytes in the first
  minute, about 51 B/s, with zero rx-dropped. That exercises the driver opening the radio, the
  ISR handing frames to the shim, the 16-slot ring, the MHR parser and the interface counters.
  Still unproven: transmit with and without CCA, the tx-completion callback, and the ring under
  burst load heavy enough to drop.
- **Our extended-address display disagrees with the chip's EUI-64 in the middle two bytes.**
  `esptool` reports the C5's 802.15.4 address as `10:bd:a3:ff:fe:c0:b0:ac`, the canonical
  EUI-48-to-EUI-64 mapping that inserts `ff:fe`; `/interface/wpan/get wpan1 extended-address`
  reads back `10:BD:A3:FE:FF:C0:B0:AC`. The driver round-trips its own bytes faithfully, so the
  disagreement is in what `esp_read_mac(ESP_MAC_IEEE802154)` hands back: IDF composes it from
  `ESP_MAC_EFUSE_EXT` plus the base MAC and orders that pair the other way. Settle which order
  is on-air correct against the standard before changing anything, since the address we display
  is also the one we hand the radio.
- **The H2 needs the soft-float processor entry the C5 and C6 got** and does not have it: it is
  still on `e906`, which has no atomic extension, so every `__atomic_*` libcall is undefined at
  link. IDF builds it `rv32imac` like the others. The H2 also cannot fit the full tier at all,
  at 2.69 MB against the 1.75 MB OTA slots of its 4 MB flash.

- **WiFi coexistence on C5/C6**: the 802.15.4 radio shares the RF path with WiFi;
  `CONFIG_ESP_COEX_SW_COEXIST_ENABLE=y` is required when both run and is not yet set.
- **Multipurpose, fragment and extended frames are refused.** They carry their own header
  formats, which `WpanFrame.parse` does not implement, so they count as rx-dropped and never
  reach a capture. Zigbee, Thread and 6LoWPAN use none of them; add each format with a consumer
  or when a capture needs it. 802.15.4-2015 IE lists are likewise left to the consumer.
- **An elided PAN is reported as `wpan_broadcast_pan`, not resolved.** 802.15.4-2015 lets a
  frame drop the PAN when it is the receiver's own, which Thread does routinely, so the same
  node is learned under `0xFFFF` from those frames and under its real PAN from explicit ones.
  The interface knows its `pan-id` and could substitute it on receive; decide that with the
  first consumer that keys on the universal address.
- **EUI-64 does not fit the 48-bit universal address**: extended addresses keep their low 48
  bits, so two radios sharing an OUI alias in an address table. Decide the universal address
  shape for 64-bit link layers before a bridge learns wpan addresses.
- **Radio features the stack layers will need**: hardware auto-ack and frame-pending table,
  coordinator mode, energy detect and channel scan, `receive_at`/`transmit_at`, MAC security
  offload. Add each with its consumer (Zigbee NWK over wpan, Thread), not speculatively.
- A rejected ISR event post (reactor ISR queue full) is retried by the next radio event or the
  1s heartbeat; a quiet radio holds frames for up to a second after such a burst.
- Linux backend over an nl802154/AF_IEEE802154 socket so a host can drive a USB dongle.

## Zigbee latency and robustness

- **Expose scheduling validation metrics**: queue wait by PCP, deadline promotions and
  expiries, queue rejection and DEI eviction counts, reserved-slot dispatches,
  user-command submission-to-completion latency, and reactive receive-to-dispatch latency.

## Automation

The current implementation and remaining phases are described in
[docs/AUTOMATION.md](docs/AUTOMATION.md).

1. **Execution policy**: implement `overrun=skip|queue|restart|coalesce`,
   `catch_up=skip|once|all` with a grace window, and `on_error=ignore|retry|disable`.

2. **Typed trigger context**: replace the lone flat `$value` with a coherent context for
   provider data such as previous value, topic, payload, and timestamp. Decide whether this is
   a `$trigger` object or a set of flat locals before adding the first rich provider.

3. **More signal providers**: add MQTT filtered publishes, Zigbee attribute reports,
   sunrise/sunset with offsets, and HTTP events.

4. **`on=` completion**: add a property completer hook and let each `ISignalProvider` suggest
   bodies and parameter values. Complete the URI scheme from the provider registry.

5. **Event-driven element attachment**: revisit subscriptions when an element is created
   instead of polling `startup()` every frame for a previously missing element.

6. **Re-entrancy and loop protection**: tag automation writes, bound recursive activation,
   and make `/element/set` reject read-only targets instead of silently updating local state.

7. **Deadband trigger parameter**: pass `?deadband=` and its refresh policy through to the
   element subscription described below.

8. **Energy intent surface**: let automations propose and dispose requests on `Control`; keep
   arbitration and ownership of contended outputs in the allocator.

9. **`if=` cannot read `$value`**: `condition_holds()` evaluates the condition with an empty
   `EvalContext`, so `$value` exists only inside `do={}`. Dispatching on an enum element, such as
   a button's `event`, needs the trigger value in the condition's context; a `for=` deadline can
   use the snapshot it already keeps.

10. **Enums and bools do not compare with their names**: `(@system.panel.reset.event == "hold")`
    and `(@x.switch == false)` are false on a matching value, so an action cannot branch on a
    button's `event`. `Type.eq` compares the two Variants raw; an enum operand should compare by
    key against a string, and `true`/`false` should be literals.

## System IO

Buttons, relays and lights as data-model components, the `system` device as the node's own
surface, and the recovery and status behaviour built on them. The design, examples and open
decisions are in [docs/wip/SYSTEM_IO.draft.md](docs/wip/SYSTEM_IO.draft.md). The `Button` and
`Light` templates exist; nothing drives them yet.

1. **`/binding/gpio` coupling and tier**: a `switch` or `light` should couple the `input` and
   `indicator` components nested under its own. The binding registers only in the `full` tier;
   move it to `src/driver/` so the `switch` tier (BK7231) has it. Latching buttons need a way to
   say so (`mode` is always `momentary`).

2. **`/binding/gpio` multi-line types**: `bistable-switch`, `encoder`, `shutter`,
   with role-prefixed line properties (`set-gpio`, `reset-gpio`, `a-gpio`, `b-gpio`).

3. **SmartEVSE button gestures**: its three `Button`s report `state` only; `event` needs the
   gesture timing `/binding/gpio` has, factored out where the board binding can use it.

4. **MT7621 GPIO misconfiguration asserts**: a line in a pin group urt reserves, or a pull on a
   part with no pad pulls, asserts in the driver instead of failing the binding; urt should
   offer a query `validate()` can use.

5. **Component alias**: `/element/alias` creates a mirror of a component and registers itself as
   the writer, so sync accepts remote writes. `/element/link` has no CLI.md section; document it
   alongside.

6. **System slots**: gestures for recovery, unconfigured and an image on trial;
   `system.status.state`; `/system/factory-reset` sharing the reset slot's code; a recovery
   reset stage on #747's one-shot defaults boot; and a hold-only reset for a button shared with
   an output (see the open decisions in the plan).

7. **LED drivers**: `drive=ws2812` runs on the RP2350's PIO and the BL808 D0 bit-bang. ESP32
   wants RMT; SPI encoding would serve any chip with SPI; and a bit-bang timed from the cycle
   counter, with interrupts off per frame, would cover small chains elsewhere. The driver is sized
   for status LEDs: every pixel change sends the chain at once and blocks for the frame and latch.
   A strip wants writes batched behind a flush, one send per chain per frame, completion without
   blocking, and DMA feeding the PIO or SPI. The BL808 backend
   has not run since it moved behind the driver. urt's PWM allocator puts a
   channel on a PWM block where one is free and in software otherwise, moving flexible channels
   to software to make room for `hardware_required` ones. Software channels need the timer
   layer's periodic interrupt: ESP32 has none in urt yet (a gptimer backend), and Bouffalo's
   system tick holds the single periodic slot, so the slot needs multiplexing. urt drives PWM
   blocks on ESP32, RP2350 and STM32 (TIM1-4 and TIM8); Bouffalo and BK7231 have them too, with
   fixed pin routing that `pwm_hw_reaches` must describe. Demotion has not run on hardware.

8. **Multi-die lights**: `drive=pwm` should take `red-`, `green-`, `blue-`, `white-`, `warm-` and
   `cool-gpio`, report a read-only `channels` such as `RB` or `RGBW`, and gain `colour` and
   `indicate_colour` (or `cct` for warm and cool) from its dies, as `drive=ws2812` does.

9. **Network indication**: once #749's wifi mirror moves from the SmartEVSE binding into
   `system.status.network`.

10. **A light's `level` prints as `1e+2%`**: `/device/print` shows the `Quantity!(ubyte, Percent)`
    at 100 in exponent form. Find where an integral quantity is formatted as a float.

11. **Changing a binding's `kind` leaves the old kind's elements**: a `light` made a `button`
    keeps `effect`, `indicate`, `pulse`, `level` and `switch` beside `mode`, `state` and `event`,
    stale under a component now templated `Button`. Elements outlive a restart by design; a kind
    change should drop the ones the new kind does not bind.

## Data model

- **`system_reboot()` loses the last log lines on bare metal**: log sinks flush from the main
  loop and the reset is immediate, so the reset button's "factory reset" notice never reaches the
  netconsole, and neither does anything `/system/reboot` or the boot guard's revert logs last.
  Drain the sinks before resetting.

- **`/element/set` swallows rejected values**: `element_set` calls `Element.value(Variant)`, which
  drops the error `update_typed_series` returns, so `value=1` on a bool element does nothing and
  says nothing (`value=true` works). Report the error, and decide whether 0 and 1 should convert
  to bool.

- **The console prints quantities badly**: `/device/print` shows an integer 1310 nm as
  `1.31e+3nm` and a float supply of 3.2616 V as `3.2616000175476074V`. The stored values are
  right; the tree view's quantity formatting wants integers printed as integers and floats to a
  precision that matches their resolution.

- **`system` device memory is the allocator's own accounting**: on desktop that counts uRT
  allocations only, not the process's working set, which stays in `/system/sysinfo`. On ESP32
  the counters move when urt allocates or frees, so transient IDF-only allocations are missed;
  add allocator hooks if exact extrema are required. Concurrent interval sampling has
  approximate boundaries; serialize it with updates if exact windows become necessary.

- **Fragmentation is not published**: `largest_free` walks the heap under its lock, so it left
  the per-second `system` device and is reported only by `/system/sysinfo`. A periodic figure
  needs a bounded or incremental walk.

- **Byte counts carry no unit**: urt's unit encoding has no free unit type for information, so
  `system.mem` values are plain integers of bytes. A unit for bytes means widening that encoding.

- **A numeric-to-text format change with history crashes the next text read**: `text_value`
  reads the tail bucket without checking that bucket's format, so after `format` switches a
  numeric element with recorded history to text, it takes the scalar bucket's samples as `ushort`
  heap offsets into a heap that is null. `tail_record` likewise hands back the previous format's
  record. Either the readers ignore a tail whose format is not the element's, or the setter
  retires the tail.

- **One more `realloc` result stored unchecked**: `router/iface/mac.d:407`
  (`mem = realloc(mem, ...)`) assigns straight into the owning field, so an allocation failure
  installs null over a live pointer. It wants the shape the series bucket lifecycle now has: grow
  into a temporary, keep the old block when the grow fails, and let the caller refuse the
  operation.

- **`bucket_capacity`/`text_bucket_capacity` do not scale with the target**: `text_heap_limit`
  now does (8k under `Tiny`, 64k otherwise), but the record-count caps declared beside it are
  still 256 and 64 on every part, so a bucket on a 320KB device costs what one on a Pi costs.
  Fold all three into the same per-target sizing rather than leaving one scaled and two fixed.

- **Audit dynamic-object ownership across the tree**: `ObjectFlags.dynamic` means the object
  was created by something other than the user, is excluded from saved config, and is managed
  by its creator - so its creator must destroy it. Most spawners comply (sync `ws_server` and
  `peering`, the Tesla vehicle scanner, the Linux enumeration drivers, and now the TWC master),
  but `vehicle_appliance_for` (`src/apps/energy/vehicle.d`) allocs a dynamic `Appliance` from a
  free function with no owning object at all. Decide who owns a VIN-keyed appliance (the
  observer that saw the VIN, or durable like the Device it wraps) and sweep the remaining
  `ObjectFlags.dynamic` sites for the same question.

- **Modbus `report` registers: accept unsolicited responses and never poll them**: some devices
  push a value on their own schedule instead of answering reads. The bench PT100 transmitter does
  exactly this, and today the only way to consume it is snoop mode, which disables polling for the
  whole binding. Add a sample frequency (or profile attribute) meaning "reported": exclude the
  register from the poll scheduler and the batch grouping entirely, and match an unsolicited
  response to it by address with no preceding request outstanding. Zigbee and MQTT already model
  reporting this way; Modbus needs the same so one binding can poll most registers and accept
  reports for a few.

- **Modbus profile quirk to force write-multiple for single-register writes**: `createMessage_Write`
  (`src/protocol/modbus/message.d:186`) collapses a one-element array to fn 06 / fn 05. The bench
  TAC1100 rejects fn 06 on its config registers and accepts only fn 16, so a single-register write
  has to be spelled `values=2,3` to avoid the collapse. Add a per-profile (or per-remote-server)
  quirk that pins writes to fn 16 / fn 15 regardless of count.

- **`slave=` accepts only a named remote-server, and a raw unit address silently polls nothing**:
  `/binding/modbus` leaves `_slave_server` null unless `slave=` names an
  `/interface/modbus/remote-server` entry, and the poll path early-outs on
  `if (_snooping || !_slave_server) return;` (`src/protocol/modbus/binding.d:238`). A binding
  configured with a bare unit address therefore reaches Running and transmits nothing, with no
  diagnostic. Either resolve a numeric `slave=` to an implicit server or refuse the config in
  `validate()`. A `/interface/modbus` bus scan command would also have found the TAC1100's address
  in seconds instead of by hand.


- **Device construction API, remaining pieces** (the builder landed: `DeviceBuilder`,
  `DeviceLifecycleEvent.created`, private tree arrays, energy off the table scan):
  - no removal path: `Component` has no remove, `DeviceTable` has no remove, elements are never
    destroyed and `DeviceLifecycleEvent.destroyed` / `ComponentEvent.destroyed` are never emitted.
    Route removal through the builder when the first producer needs it.
  - liveness is centralised (`Device.set_online`, the `status.online` element), but not every
    source votes yet, so those devices sit at `unknown` forever:
    - a peer link dropping should mark that peer's mirrored devices offline; the sync layer has
      no override today, and mirrored devices therefore never go offline.
  - MQTT discovery and sync mirrors publish an empty device and grow it one edit per frame; that is
    the intended burst granularity, but a discovery that knows its entity set up front could build
    once.
  - `PublishSlot` binds lazily on first write, so structure is still created on first touch. Bind
    the allocator, policy and planner slots when the Policy or Island is created, and drop the path
    argument from the per-tick write.
  - Nesting a builder asserts, in release too, by choice: find misuse early. Revisit once the
    esphome, goodwe, zigbee, SunSpec, MQTT discovery and SmartEVSE paths have run under it; none of
    them were exercised on the bench.
  - The esphome and goodwe `status.network.ip.address` elements are written once at connect and
    never refreshed; they should follow the client's connection.
  - `open_commit()` (element.d) has no callers: every multi-element write still delivers per
    element, so a subscriber can run between two fields of one frame and the topology watch can
    rebuild mid-frame. Wrap each frame boundary in a `CommitScope`: the TWC push, the Modbus,
    SunSpec, GoodWe and Zigbee response handlers, the MQTT publish path, the tesla vehicle
    publish functions, the energy publishers, and the sync inbound value path.
  - `components` / `elements` return writable slices, so a caller can still overwrite a slot without
    the builder; closing it needs a slot-immutable view type.
  - Element name and access edits on a live element are not announced anywhere: sync announces on
    creation only, so a rediscovered MQTT entity whose access changed is stale on peers. That is
    sync's to re-announce, not shape; a format change is a series event on the same element.
  - Helpers that build part of a tree thread `ref DeviceBuilder` through every call (about ninety
    sites in the TWC and SmartEVSE bindings, eight SunSpec helpers). A component-scoped handle
    would remove the argument; not obvious it is worth its own type.

- **Complete the unit model**:

  - represent logarithmic reference-relative units such as dBm with explicit conversion and
    arithmetic semantics;
  - distinguish arbitrary counters so unrelated dimensionless counts cannot combine; and
  - settle bit/byte identity and decimal versus binary prefixes (`kB` versus `KiB`).

- **Retire profile compatibility grammar**: normalize the external profile catalogue, then
  remove the two-column unit/enum fallback, access suffixes (`/R`, `/W`, `/RW`), `i*`, glued
  endian spellings, `_r`, and Modbus high/low-byte aliases. Keep
  [docs/PROFILE_FILE_FORMAT.md](docs/PROFILE_FILE_FORMAT.md) and parser tests limited to the
  canonical grammar. Fixed vectors also need codec support when the first wire producer uses
  them; `sample_record()` currently rejects `DataFormat.count != 1`.

- **Settle bitfield profile declarations**: choose whether plain values in `bitfield:` are bit
  indices or masks. If indices win, convert them to masks in the parser, migrate the
  `pace_bms` and `smartevse` declarations after auditing expression/key users, retain
  `1 << n` as an explicit mask form, and warn when a `bf` field references a non-bitfield
  enum.

- **Support multi-protocol device profiles**:

  1. Add an enum remap codec with an invertible write mapping; treat combinable bitfields
     separately.
  2. Add protocol/source filters to templates and elements so one semantic tree can carry
     multiple source descriptions without materialising the wrong protocol's descriptors.
  3. Track source provenance, health, read preference, failover freshness, and write authority
     explicitly. SmartEVSE should prefer MQTT while retaining REST as a fallback.

- **Decide Home Assistant discovery's long-term binding model**: either keep the bespoke
  discovered-element binding or synthesize a runtime profile and use an ordinary MQTT
  binding once MQTT descriptors can carry value and command transforms. A migration must
  preserve the faithful HA element tree, stable hash-keyed enums, explicit-profile topic
  claims, and per-device collision behavior.

- **Give profiles control over retention and recording**: settle element tokens for RAM floors
  and ceilings by record count and age, a no-history option, and a separate disk-recording
  flag. Add inherited component/profile defaults and byte budgets. The recorder should select
  elements by recording intent, not infer disk policy from RAM retention.

- **Finish converging the value path**: `src/manager/sample/` is now the single wire-desc to
  native-record path, but the per-protocol survivors named in the original audit are still
  standing: zigbee's `get_zcl_value`, and HTTP/MQTT's `apply_value` and `format_value`. Audit
  each against the shared descriptor language and either justify it or dissolve it into the
  one module, keeping the encode/decode inverse in a single place. Batching and timing policy
  belong in the same sweep, not just decode.

- **Finish the series operator model**: move expression maps, accumulators, and aliases out of
  `Device.Computation`/`ElementLink` into explicit operator objects beside the sample layer.
  Operators must consume batches against a committed frame, handle gap events, and own any
  transient or integrating state. Move accumulator timing out of `Device.update()`. Once the
  customers are objects, replace the two-pointer `Subscriber` delegate with a one-pointer
  subscriber interface and audit subscription lifetime.

- **Finish series storage and recording**: finish sealed-bucket packing, reuse the packed stripe
  on disk, unify RAM/disk time queries, and add the decimation ladder described in
  [docs/DATA_MODEL.md](docs/DATA_MODEL.md).

- **Bound recorder container growth**: `.ows` files grow without limit. Add a size or age budget
  per series or per recorder, and give the retention classes distinct policies: the short class
  (planner budget, allocation decisions, coverage and mismatch flags) wants days, while island
  `account.*` powers, today counters, per-boundary flow views and battery SOC want months. Today
  the classes are separated by recorder but every recorder retains alike. This is the last thing
  between the current state and leaving recording on indefinitely.

- **Make the container complete**: `ows` v0 cannot flush user types or enum identity (both need
  name binding in the block header) or domain-clocked series (need anchor blocks for the clock), so
  those series stop at RAM. Adoption under live cursors is unresolved (`src/manager/ows.d` header):
  `open_()` rebases the store's buckets and pins behind adopted history, but a `Cursor` holds its
  position by value and cannot be reached, so one opened in the sub-second gap before the recorder
  attaches re-reads adopted history as new, and a pinned sync cursor would re-ship it. Either a
  store-held rebase epoch the cursor applies lazily, or cursors holding store-side positions only.
  The columnar codec planes (time-plane delta varint, value-plane bit-pack, zigzag-delta and XOR,
  per-plane codec byte with raw fallback) are designed against the existing `SeriesCodec` registry
  and not written.

- **Defer reactor-thread producers to the main loop**: a producer writing from a reactor thread
  must not dispatch observers or mark dirty inline (`src/manager/element.d:1261`); queue the
  dispatch and drain it on the main loop.

- **Make recorder shutdown lossless**:

  - `/system/reboot` must seal every active bucket and wait for every `HistoryBlock` to become
    durable. Never abandon unwritten history on a deadline; keep the watchdog active, report
    worker progress, and cancel the reboot or keep retrying if storage cannot complete.
  - route SIGTERM and SIGINT through the same main-thread shutdown using an
    async-signal-safe wake;
  - add a preallocated fatal-crash path that sends each non-durable bucket's committed prefix
    to the I/O worker without allocations, locks, or callback maps, waits with a bounded
    worker-liveness check, then resumes normal crash handling; and
  - define the disk durability boundary and batch `fsync` in the I/O owner. `pwrite`
    completion alone does not cover power loss.

- **Finish the other device facets**: add lazy property projection, typed events, and device
  functions using `DataFormat`; replace the `Device`/`BaseObject` type trap with composition.
  Keep identity, values, events, and functions addressable without turning the data model into
  a transport.

- **Add device logic to profiles**: define named actions whose payloads are evaluated from
  current device state, plus device-scoped `on`/`if`/`do` scripts for writes, toggles, rolling
  counters, and receive-to-state updates. Reuse the expression and automation machinery, but
  define a bounded device execution context and protocol-owned action primitives. The first
  customer is the RF433 fan profile and waveform transmitter.

- **Implement element deadband with a maximum refresh interval**: deadband belongs to each
  subscription, with its own last-delivered anchor. Element metadata supplies the default and
  subscribers may override it; `Element.latest` always remains exact. Deliver current truth
  when the absolute movement crosses the band or `refresh=<duration>` expires, then re-anchor.
  Non-numeric values ignore the band. Recorder and automation subscriptions must use the same
  mechanism. A later optional EMA decision signal may reduce alternating boundary bias without
  replacing the delivered value.

- **Recorder durable-holder cutover**: `RecordStream` (`src/manager/record.d`) keys its intake off
  a raw `Element*` plus a transient pinned `Cursor`, so a destroyed-and-recreated element leaves the
  stream dangling. Move it onto the durable `EID` (deref-and-heal). This already landed on the
  `sample-transactions` line, where the recorder reads via `eid.deref`; it rides in when that work
  rebases on top. Fold the remaining `ElementCursor` decision into that cutover:

  - `ElementCursor.next()` (`src/manager/element.d`) reuses a cursor bit claimed on the *previous*
    element after an EID heal, so it null-derefs a fresh series or corrupts another cursor's pin.
    Either make it re-register on the resolved element, or delete it in favour of the bare-EID
    approach the recorder already took.
  - `open_series_cursor` aborts with `assert(false, "out of cursors")` on the 17th concurrent
    cursor; return an invalid cursor instead of aborting in release.

- **Element.value() drops unconvertible values silently**: `value()` discards
  `update_typed_series`'s failure, so a value that cannot unbox to the element's format (wrong
  dimension, overflow, non-string to a text element) vanishes with no log and no caller feedback.
  Decide whether to return the status, warn (rate-limited; this is on every write), or keep it
  silent by design. As written it hides bring-up bugs.

## DHCPv4 audit

Static audit of `8b17d83f` (client, server, lease, option and message modules). These
are code findings, not an attribution of the reported S3 Wi-Fi incident. No runtime
reproduction or packet capture was performed. The P1 findings (NAK recovery, exchange
scoping, configuration reconciliation, DISCOVER shortening committed leases, lease
ownership, option-buffer overrun), the INIT-REBOOT silence rule and monotonic lease
expiry landed: a lease arms its own expiry and returns its own reservation to the pool
that made it, so no server reaps. What follows is still open.

- **P2: receive validation bypasses transport checks** (both `incoming_packet`
  methods): raw interface subscriptions do not check IPv4 checksum, fragmentation,
  or nonzero UDP checksum. UDP length is bounded by the frame rather than IPv4
  total length. Share a validated DHCP datagram decoder and reject malformed packets
  before changing lease state; preserve legal IPv4 zero UDP checksums.
- **P2: pool edits discard live reservations** (`ip/pool.d`, `start`, `end`):
  changing either endpoint clears the allocation bitmap without reconciling active
  leases; the running DHCP server can then allocate an already leased address.
  Rebuild reservations from their owners when changing pool geometry.
- **Remaining protocol/lifecycle work**: honour client identifiers instead of
  keying solely by MAC; implement or explicitly delimit relay and DHCPINFORM
  support; validate infinite lease values; implement conflict detection; consume requested
  DNS configuration; replace the client's 1s hostname poll with a `manager.system`
  change signal; ARP-resolve the server for unicast RENEW/RELEASE instead of
  broadcasting at L2. Audit subscription-capacity failure handling as part of
  bring-up.
- **Diagnostics and verification**: packet-level DHCP logs require a compile-time
  flag. Add a deterministic client/server packet harness covering acquisition, loss,
  duplicates, NAK recovery, renewal changes, multiple scopes, DECLINE followed by
  DISCOVER and by quarantine expiry, and a clock jump followed by a duplicate DISCOVER;
  only the option
  builder's fit boundaries and the client's T1/T2 derivation are unit-tested today,
  because NAK recovery, ACK reconciliation and pool ownership all run through the
  collection and scheduler and need that harness.

## DHCPv6 features

The codec from `67e83fb4` has no operational client, server or relay. The reserved
client/lease/server collection IDs have no implementations or commands. These
are feature follow-ups, outside the retrospective merge fixes; choose the first
role from a concrete deployment need before implementing or advertising it.

- **Client** (`/protocol/dhcp/client6`, IA_NA + IA_PD): landed. Remaining gaps: during a
  prefix renumbering overlap only the freshest delegated prefix reaches the pool, so the
  downstream `ra` withdraws the old /64 outright instead of advertising it deprecated
  alongside the new one; a NoBinding reply
  restarts from Solicit rather than sending a fresh Request; DNS servers from the ORO are
  ignored; replies are not checked against the interface's own link-local destination.
- **Server and leases**: define address/prefix allocation and lease policy,
  then implement the server and lease collections.
- **Relay**: define the required relay deployment and supported message forms,
  then implement request/reply forwarding.
- **Temporary addresses (IA_TA)**: decide whether support is needed. If so,
  add its separate four-byte header and codec coverage; the existing twelve-byte
  IA helpers explicitly accept only IA_NA/IA_PD.

## Sync and peering

The built surface is documented in [docs/SYNC.md](docs/SYNC.md) and [docs/PEERING.md](docs/PEERING.md);
this is what remains.

- **Devices mirrored from a `claim=` sibling need a naming rule.** The claimant files them under
  the sibling's peer id, so one named like a local device is ambiguous to anything addressing by
  name, and how the network sees a claimed sibling's devices is undecided.
- **A `claim=` sibling warns on every boot that it was claimed with no cluster.** The pair has no
  fleet of its own; decide whether the sibling inherits the claimant's cluster or the warning
  skips sibling claims.
- **The `claim=` session lifecycle has no unittest**: issuing a claim needs the sync modules, so an
  application, and one test binary cannot host two (collections outlive an application). It is
  verified on the BL808 only.
- **`/element/set` cannot reach a device keyed by a peer id**, such as the energy app's device,
  which `create_energy_device` keys by the local node id.
- **`/device/print` renders negative ages as `-209.-6s`** when a remote timestamp is ahead of the
  local clock.

- **A cleared template can survive a reconnect on a wholly unclassified path**: an introduction
  omits `tmpl` when nothing on the path carries a template, and an absent chain is silence, so a
  mirror that missed a clear while its session was down keeps the stale label if every node on
  that path, the device included, ended up unclassified. Live clears always travel (refresh
  frames state unclassified nodes explicitly), and any template left anywhere on the path makes
  the introduction's chain present and therefore corrective. Closing it means stating `/`-only
  chains on every introduction, which is most of the bytes of a large unclassified device; nothing
  clears a template today, so the trade stays as it is until something does.

- **Two nodes race to author a mirror's `status.online`**: every node fabricates `status.online` when
  it creates a device, mirrors included, so a downstream session may announce its own copy to a relay
  before the relay introduces the authority's. The relay then sees that session as the node's author
  and, by the usual rule, never introduces it back, so neither an introduction nor a template refresh
  ever carries `status`'s shape to it. Seen on the four-node rig: `status` arrived typed or bare
  depending on which side won. Decide who authors a mirror's liveness element.

- **Refresh filtering scans handles linearly**: `pump_refresh` asks `SyncPeer.handle_of` for each
  element under each templated component, and `handle_of` is a linear scan of the session's
  handle tables. A reclassification of a large device on a session holding thousands of handles is
  O(elements x handles), once per event. Fine at fleet scale and only at configuration time; a
  keyed handle lookup fixes it if a device ever churns templates.

- **The sync capability byte is full**: `templates` took bit 7 of `SyncCaps`, which is a `ubyte`
  on the wire (binary `hello`) and in `SyncPeer._remote_caps`. The next capability needs the field
  widened first; JSON names capabilities as strings and has no such limit.

- **Intern the `add` frame's template chain**: `tmpl` repeats the same short chain on every
  element of a component, so a full intro pays for it once per element rather than once per
  component. Formats and enum dictionaries already intern per session (`to.ft_of`,
  `to.enum_seen`); give the chain the same treatment if intro size becomes the binding
  constraint. It is a few percent of a burst that is already paced, so it is not urgent.

- **Elect an active authority**: two authorities of one cluster already share a member (each holds
  its own session), but nothing elects between them. Build the authority-to-authority session
  carrying membership view, epoch and liveness, elect by `priority` then node-id, and have members
  follow the elected-active for time discipline and routine control instead of the first claimant
  (`src/manager/sync/peering.d:410`). That session carries coordination only, never fleet state, so
  the A-B-member triangle never becomes a sync loop. `/sync/peering print` should show the
  membership delta under partition.

- **Highly desirable expansion: rank paths and fail over without a restart**:
  Defer this architectural work from the reconciliation point fix. `discovery.d:137` prefers by link
  speed then recency. One logical peer owns a set of discovered/configured paths; claims,
  subscriptions, mirrored state, sequence/ACK state and queued work must survive path changes.
  The user's provisional default order is MAC > IPv6 > IPv4 > high-bandwidth serial > radio >
  low-bandwidth serial. Settle how that order combines physical-medium cost with encapsulation,
  operator overrides, health and recovery hysteresis. IPv6 discovery is not implemented today.
  Collect RTT per link from acknowledged exchanges (Karn-filtered) to drive the retransmit clock
  and demote degraded paths. Bind additional paths to the same established remote/session before
  transferring traffic, and distinguish link failure from a remote reboot/session epoch change.
  Beacons stay link-local; reachability through the fabric is a separate propagation mechanism.

- **The Pi trips the 5s supervisor watchdog on first boot after an OTA**: observed 2026-09-16,
  two `no heartbeat for 5000ms; killing app` kills in 40s on the first two launches of a new slot,
  then the third launch soaked and committed and has been clean since. Slot 156 shows the same kill
  on 2026-09-15 three times, so this predates the sync tx-feed work and is not caused by it, but
  first-boot is clearly the worst case: every binding starts, the whole device tree is built and
  every peer introduces at once. Find what runs long enough to starve the heartbeat at boot (the
  `log_slow_phase` subdivisions and `collection.update.*` warnings are the handles) rather than
  raising the deadline. Related: `collection.update.interface.sync1-ws<n>` sits at a steady 70ms
  per frame against a 50ms budget, also pre-existing, with occasional 500-600ms spikes.

- **Make backpressure a channel property**: the bulk walks (registry and model introduction,
  live re-arm, history backfill, template refresh) now run as the transport's `tx_handler` and ask
  `tx_ready` before every frame, so a model larger than the websocket's 128 KB bound mirrors
  instead of restarting the session, and a paced queue holds 16 KB plus one frame.
  Every other emitter still pushes: the `val` and `log` queues (`flush_pending_vals` drains an
  armed event series until the val backlog is full, then retries from the next tick), `tick_dirty`,
  the `model_sub`/`sub` fan-out, lifecycle fan-out, `result` and `history`, and on a reliable
  transport a refused push is dropped with no retry path. Move them onto the same feed, and let
  control frames ride PCP >= ca with DEI=0 on the underlying packets. `BaseInterface`'s
  handler slot is single-owner like `Stream`'s, which suits the one-peer websocket; a shared
  bounded interface would need per-peer arbitration.
- **Viewing a peer's console loses output the local stream cannot drain**: `PeerConsoleCommand`
  writes received output with `Session.write_raw`, which drops what its stream does not take, and
  sync's acks report receipt, not consumption. Over a 115200 serial console an S3 viewing the Pi
  dropped about 60% of a large print. The remote session needs pacing from the viewer's drain:
  console-level credit returned from a `feed_output` producer, or a console session carried by an
  end-to-end transport rather than sync verbs.

- **Harden clock discipline**: gate member sampling, recording and shipping on wall time (an ESP32
  ships 1970-stamped samples until its first pull), carry a synced flag in `hello`, add a
  minimum-delta threshold so steady-state polls do not step, and make `adjust_utc_time` step the OS
  clock on Posix (today it rewrites the current time, so a chained authority drops pushes and
  forwards them). NTP versus peer discipline needs an owner.

- **Finish claimed device mirroring**: acknowledged claims already subscribe to `device:**`.
  The remaining model work needs node-scoped naming for remote
  devices (flat `g_app.devices` collides on `energy`/`system`; a colliding `add_name` adopts onto
  the local CID), offline/gone on detach (remote devices persist forever with stale values), a paced
  `model_sub` burst, one quiet skip per unknown type per session, and write routing to the authority;
  until that lands a console `set` on a proxy diverges it silently.

- **Finish the model plane**: `model_sub` takes patterns, `once` and a `from`/`to` window, nothing
  else. Still to build: `meta`/`depth` structure browsing, `rate`/`deadband`/`mode` (tightest wins
  when patterns overlap), `move` and `gone`, `call` with the signature form of `type` (lands with
  the first callable node; `cancel` reserved), constraint min/max/step on the format block together
  with element-write enforcement, echo suppression for `set` writers via `SampleUpdate.who`,
  pinned-cursor paced backfill (backfill serves synchronously inside the burst today), and an
  element lifecycle hook that carries the element. Formats failing `ows.container_serialisable` are
  skipped with a log rather than answered `err`, because per-node errors inside a glob burst are
  unresolved. Confirm `device` is registered as a namespace in `g_app.types`.

- **Converge the object mirror into the model plane**: `add_name`/`bind`/`unbind` become
  `add`/`sub`/`unsub` on object subtrees, property `set` becomes `set` on projected elements,
  `reset` becomes `set {reset:true}`, `state` a built-in event node, `create`/`destroy` a `call` on
  collection methods, `enum_req` the push-only `type` form. Gated on property projection in
  `id.d`. Keep the sibling transport class buildable on the way: handles are already `ulong`, but
  `IdAllocator` and `g_formats` allocate through `defaultAllocator`, so shared-memory residency
  needs a writer/reader ownership rule before a sibling transport shares them across the BL808
  cores.

- **Build the remaining transports**: the sibling class for BL808 M0/D0 (raw EIDs as handles; the
  cores peer today over `/interface/xram`), a `CPCEndpoint` transport for UART/SPI
  point links (I2C deferred until a data-ready GPIO exists), the RS485 multi-drop envelope (valid
  Modbus RTU frames with a user-space function code, token is the poll, one scheduler shared with
  the Modbus master, per-slave baud as addressing metadata from day one), and one-way multicast
  feeds (publisher-owned handle namespace, gap detection by datagram seq, unicast backfill, never
  acks on the group). `stream=` on `/sync/peer` materialising the CPC stack, and `remote=` URI
  schemes beyond UDP, arrive with those. RS485 slave-to-slave goes through the master first;
  multicast groups are configured before derived.

- **Take the fleet to micros and to the box**: `conf/fleet.id` and `conf/node.id` need an NVS
  backing where there is no filesystem (`peering.d:595`). Out-of-box onboarding is unbuilt: SoftAP
  provisioning serving the existing HTTP config surface is nearly free, BLE provisioning needs the
  peripheral role the stack does not have. An approval mode where the neighbour table is the
  "waiting for adoption" list is authority policy, not protocol. A member preferring its previous
  claimant on reconnect is cheap and undecided.

- **Build config authority**: the mesh's genuinely new subsystem. Desired state at the owner,
  actual state at the executor, and a convergence loop between them: pushed-down config persists
  at the executor with provenance so it survives a reboot during partition, the owner reasserts on
  reconnect, deletions need desired-state tombstones, and conflicts resolve by authority tag. Write
  arbitration generalises `who` to node-scoped provenance. Barriers to clear first: `Prop!`/`Event!`
  schema fingerprints across mixed-version fleets, first-class node-scoped name syntax, and
  config-plane authn/authz.

- **Log sync residue**: render origin hostname and producer timestamp in the text sink, and cap the
  severity a remote can raise on ingress (both left from `#582`). Parked with owners elsewhere: a
  module-level sync test harness (the reliable sublayer and decoder are unit-testable in isolation),
  an allocation-flag placement API for `Array`/`MutableString`, and pool-backed packet buffers
  (`#518`).

- **Re-announce an element whose access changes**: `access` is emitted once, at model-add time
  (`src/manager/sync/json_encoder.d:551`). A provider that becomes writable later - a Tesla vehicle
  session reaching `Phase.ready`, or a TWC master taking over or standing down - leaves
  already-introduced mirrors holding stale access, so
  their UIs may hide available controls or offer controls without agency. Emit an access change on the
  control plane, and make the mirror re-evaluate its peer binding.

## Infrastructure

- **Receive still polled after the stream migration** (2026-10-06): streams push, but a few
  consumers still learn of progress from a tick. TLS advances its handshake from `startup()`,
  which the state machine re-drives each frame, rather than from the bytes' arrival; the DNS
  server polls its UDP sockets with `recvfrom` each frame; `Session` polls terminal events.
  Sources with no receive event (Windows console input, a shared-memory FIFO, the IDF USB drivers,
  a replayed file) poll themselves through
  `poll_rx()`; each wants an event where its platform offers one (a reactor `watch_io` for stdin
  on Linux, the IDF drivers' callbacks).

- **`BridgeStream.write` spins on a member that is not running**: it loops until each member has
  taken all the data, and a stopped member takes nothing.

- **Push-receive review follow-ups** (2026-10-06, #814):
  - A connection paused by `recv_handler(null)` does not see the peer's FIN or a reset until it
    reads again; epoll drops read interest and IOCP holds the one receive it has.
  - Telnet subnegotiation is not clamped, so a peer that never sends `IAC SE` grows the buffer.
  - A consumer that calls `restart()` from inside its delivery leaves the source's loop to finish
    the chunk against a stopping object; such consumers should call `restart_deferred()`, and the
    delivery loops want to stop on `!running`.
  - An ISR whose event post is refused leaves serial RX to a retry flag `SerialStream.update()`
    takes, and ethernet drops the wake. Give ISR posters an intrusive overflow node the reactor
    wake drains, so a refused post is retried without a tick.
  - A second `Application` in one process re-runs every module's registrations against globals the
    first left behind, and crashes; so unit tests cannot drive `g_app.schedule`.

- **Sync producer sizing follow-ups** (2026-10-06, review of #813):
  - An event series with no val room stays pending and retries from the tick; the ack's `arm_tx`
    never reaches `flush_pending_vals`. Drive it from the room event.
  - A partial val frame re-reads a 256-record block after `seek`, about 25 times the reads on a
    200-byte segment. Advance within the block already read.
  - An eviction that moves the backlog head without changing the last id that fits sends nothing,
    so the new epoch waits for the 300 ms flush. Send when the head or epoch changed.
  - A bounded backfill whose range holds no record no longer commits the live cursor to the first
    block; decide whether records between `to` and arm time should stream.
  - The parked-on-`val_room` path is not exercised over an armed sublayer, and no test decodes a
    two-byte val count or the JSON paths.
  - The console relay still cuts output at 8 KB and sends each part at once, so output past one
    fragmented message is refused while the first is pending, and a burst can overrun the control
    window. Size it to the segment once session output is pulled (S4): the console stream then
    grants by window room and resumes on the ack, with a bounded buffer that splits on code points.

- **A Windows UDP socket that sends to a closed port stops receiving** (2026-10-06): two instances
  peering over `/interface/udp` on loopback, the one whose hello went out before the other bound
  its port never hears the other again. The ICMP port-unreachable surfaces as `WSAECONNRESET` on
  the next `recvfrom`; urt's `recvfrom` swallows it as success with 0 bytes, and the reception path
  appears to stop draining there. Disable `SIO_UDP_CONNRESET` on UDP sockets, or keep reading past
  the reset.

- **Interface sizes the MTU work left open** (2026-10-06): `l2mtu` should be writable on Ethernet,
  where jumbo frames make it meaningful, and read-only elsewhere, with `max-l2mtu` (the largest
  jumbo the hardware takes) present only there; the property system cannot yet let a derived class
  add a setter to an inherited read-only property (it would redeclare the name and replace the entry
  at its index). Jumbo frames also need the Ethernet `medium_tx` frame buffer (1522 bytes) sized
  from the hardware. Setting `mtu` back to its default on Linux never restores the OS value.
  Zigbee's 90-byte APS frame assumes the minimum NWK header; source routing or a longer APS header
  leaves less. Tesla TWC transmits its checksum byte unescaped, so a checksum of `0xC0` or `0xDB`
  corrupts the frame.

- **urt's platforms.mk drops MbedTLS when a caller sets `VERSIONS`**: it appends `MbedTLS` to
  `VERSIONS` with a plain assignment, which a command-line `VERSIONS` overrides, so
  `VERSIONS=Foo` on an mbedTLS platform builds without `version (MbedTLS)`. Add it to `DFLAGS`
  directly, as OpenWatt's `BOARD_VERSIONS` does.

- **Link follow-ups**: interfaces signal `link_up`/`link_down`, but every Ethernet driver except
  the SFP port still links with its lifecycle, waiting in Starting for carrier and restarting when
  it drops. Move them onto the SFP port's model (run from attach, signal the carrier through
  `carrier()`/`set_link()`) once the link consumers are proven on SFP. IPv6 does not redo DAD when
  a link comes back, as RFC 4862 wants, and the automation `object:` provider cannot trigger on
  link transitions, since the manager cannot read an interface's link.

- **A bare ESP32-H2 release build does not fit**: `FEATURES` defaults to `full`, which links at
  about 2.7 MB against the 1.8125 MB OTA slot, so `make esp-idf-build PLATFORM=esp32-h2
  CONFIG=release` fails the partition check. The IP tiers buy nothing on a part with no IP
  interface, so the choice is `switch`, which fits with room to spare but drops the BLE and
  Zigbee stacks, or `full` in a single-app layout, which gives up OTA. Set it in `features.mk`.

- **`/stream/serial device=uart0` produces nothing on the ESP32-H2**: `device=uart1` with
  `tx-gpio=24 rx-gpio=23` (UART0's IO_MUX pins, per IDF `soc/esp32h2/uart_pins.h`) drives the
  DevKitM-1's CH343 bridge and gives a fully interactive console, so the stream and the shim are
  fine; uart0 stays silent whether IDF's console is on it, on USB-JTAG, or disabled. Something
  about UART0 after the ROM leaves it is not being re-initialised. Until that is understood the
  H2's console stays on `usb-serial`.

- **The H2's `usb-serial` console wedges the host USB link**: the firmware logs
  `usb-serial 'console': online`, but the CDC device drops into Windows error 31 within seconds
  and only a physical replug clears it; the board never resets meanwhile. Suspect the endpoint
  being written continuously with nothing draining it. The C3/C6/S3 use the same config without
  trouble.

- **`/system/fs/format` did not take on the H2**: the command returns no output and littlefs
  still reports `Corrupted dir pair at {0x0, 0x1}` on the next boot, so `manager.ows` cannot pass
  on hardware. The format runs as a latent `CommandState` on its own task, and nothing reports
  whether it failed or never ran.

- **Nothing formats a fresh filesystem**: a failed `lfs_mount` latches `mount_state = -1` and only
  an explicit `/system/fs/format` clears it. A unittest image has no console, so `manager.ows`
  can never pass on a board whose storage partition has not been formatted by hand first.

- **A full-tier unittest image leaves the ESP32-H2 29.6 KB of heap**: it fits the fused 3.625 MB
  test partition but `manager.element` cannot allocate its own assertion buffers. Switch tier
  leaves 57.6 KB and is the realistic configuration. Either size the heavier element cases
  against available heap, or state that embedded test runs are switch-tier only.

- **Reduce embedded unittest metadata's internal-RAM cost.** The C5 run for #728
  retained 29,072 bytes of `TypeInfo_Class` and 15,368 of `ModuleInfo`, leaving about
  6 KB of DMA-capable heap; the priority-queue depth test failed at its 23rd packet.
  The runner needs ModuleInfo to discover tests. Investigate flash placement or a
  smaller test index while preserving required relocation and startup writes.

- **Run remaining embedded tests after an assertion failure.** Without exceptions,
  `urt.package.run_test` aborts at the first failed assertion. Add test selection or
  isolated recovery so finding the next failure does not require changing and
  reflashing the image. Any recovery must handle skipped destructors and dirty
  shared state; an assertion-handler `longjmp` alone is not sufficient.

- **Application recreation leaves the global page pool initialized**: `Application.~this` does not
  deinitialize the pool, so a second `create_application()` in the same process asserts in
  `page_pool_init`. Define ownership and teardown for shared pool users before adding more
  application-backed integration unittests (found reviewing #718).

- **The low-level `/element/set` command ignores element access**: `Application.element_set`
  calls `Element.value` without checking `Access.write`, allowing CLI writes to reported
  read-only identities such as a port's `circuit`. Define whether this command is an explicit
  diagnostic override or should enforce the same write contract as clients (found in #718).

- **`FEATURES=switch` does not link.** `driver/linux/bridge.d` and `driver/linux/wifi.d` import
  `protocol.ip.linux_mirror.mirror_refresh_interface` unconditionally, but the switch tier drops
  `protocol.ip`, so the symbol is undefined at link. Found while testing another branch on
  2026-09-20; `IPV6=0 GATEWAY=0` builds clean, so it is this tier specifically. Gate the import
  and its call sites on `has_ip`.

- **`EUILit` is unusable under LDC.** Building an EUI-64 from a string literal at compile time
  makes LDC 1.42 emit `ICE: overlapping initializers for struct literal`, from `EUI`'s union of a
  `ulong` and a `ubyte[8]`. DMD accepts it, and every ESP build uses LDC, so the template cannot
  be used in anything that targets hardware; use the `EUI64(0x01, ...)` constructor instead.
  Nothing had ever instantiated it, which is also why its own length check was wrong until now.
  The C-style `EUI64 x = { b: [...] }` initialiser is not an escape: D refuses brace initialisers
  on a struct that declares a constructor, and `EUI` declares one.

- Fix `urt.conv.parse_uint` overflow: reject values outside `ulong` range using the existing zero-consumption error contract. Revision filenames use checked `parse_int_fast`.

- **Unsubscribe during packet dispatch walks a stale slice**: `BaseInterface.fire_subscribers`
  and `send` iterate `_subscribers[0 .. _num_subscribers]` captured before the loop, and
  `unsubscribe` swap-removes into that range. A handler that calls `restart()` (the dhcp6
  client's declined-reply path, any offline handler) unsubscribes and re-subscribes inside the
  walk, so the moved-in and re-added entries can receive the same packet again. Snapshot the
  subscriber set or defer removals until the walk ends.

- **Make clock-sensitive unittests hermetic**: tests that leave a `MonoTime` member at
  `MonoTime.init` and then compare it against a real `getTime()` only pass once the monotonic
  clock exceeds the interval under test, so they fail on a freshly booted CI runner. The tesla
  poll test is fixed; `protocol.obd`'s asleep-probe case still sets `_sent_time = MonoTime.init`
  and needs the clock past `probe_interval` (`src/protocol/obd/package.d:1034`). The structural
  answer is to stop reading the real clock in these tests: `handle_protocol_fault` and
  `issue_requests` call `getTime()` internally, so the time source has to be injectable before
  the tests can anchor on a synthetic base the way `protocol.tesla.vehicle_session`'s first
  unittest already does.

- **`/system/fs/read` silently truncates to nothing**: the command formats the length, a
  literal and the whole file body through `tconcat` (`src/manager/system.d:285`), whose arena is
  4 KB (`TempMemSize`). When the concat does not fit, nothing is produced and the command prints
  an empty line: no error, and an empty file is indistinguishable from a failed read. The arena
  is a per-frame bump allocator, so a file near the limit is a coin flip -- reading a 2,145-byte
  config off a live ESP32-S3 failed three times and succeeded on the fourth, while a 2,174-byte
  file beside it read first time. Anything past ~4 KB can never be read. The single-argument
  `write_line` overload bypasses `tconcat`, so writing the prefix and the body separately fixes
  the common case; a file read should stream rather than materialise. The HTTP fileserver mount
  (`access=write`, GET and PUT) is the reliable transport in the meantime.

- **Repair the runtime test harness**: `test/test_harness.py` pipes stdin into
  `--interactive`, but startup requires a terminal and the Windows console
  stream reads console events. Use a terminal or supported session transport.
  Drain stderr during execution and terminate before waiting for EOF; the
  current shutdown reads stderr before stopping the process and can hang.
  `test/test_runner.py` also looks for `bin/x86_64_debug/openwatt` while the makefile emits
  `bin/x86_64_linux_debug/`, so it finds no Linux build at all.

- **`assert(classref)` still segfaults LDC debug builds**: under `--fno-rtti`, `assert(o)` on a
  class reference runs the invariant, and urt's `_d_invariant_impl` walks `typeid(o)`, which is
  gone. #710 moved the two `device.d` sites to `!is null`, but others remain: `debug assert(s)`
  in `ModbusInterface.startup` (`src/protocol/modbus/iface.d`) kills any debug instance whose
  startup script creates a Modbus interface. Sweeping every site is whack-a-mole; having
  `_d_invariant_impl` skip the ClassInfo walk when RTTI is compiled out fixes them all at once.

- **Move Xtensa to LDC 1.43 when esp-clang reaches LLVM 22**: LDC 1.43 emits LLVM 22 bitcode,
  which no esp-clang yet reads (the latest, esp-21.1.3, is LLVM 21), so Xtensa firmware is
  pinned to LDC 1.42 and the makefile refuses a newer one. Espressif has shipped a major every
  six months or so; re-check when the next esp-clang lands.

- **Harden bindings against malformed remote input**: the `ow/dm` review found protocol
  bindings that abort or deref on data an attacker controls, and these survive. ESPHome still
  carries `assert(false, "what here?")` on `proto_deserialise` length mismatch
  (`src/protocol/esphome/client.d`), which is a remote abort on a malformed frame. MQTT's
  `desc_by_index(mqtt.desc)` (`src/protocol/mqtt/binding.d:216`) has no `desc == ushort.max`
  check. `ows.load` still reads `first_index`/`last_index`/`stride` off disk unvalidated
  (`src/manager/ows.d:59`), so a corrupt or hostile container is trusted. External state
  rejects, it does not assert.

- **Close the descriptor grammar gaps**: `strN` widths parse but are ignored entirely, so any
  `N` compiles unvalidated while the span comes from the register map
  (`src/manager/sample/spec.d`). Integer text records no longer accept exponent notation
  (`"1e3"` parsed on the old `Quantity!long` path and now fails), which is a silent behaviour
  regression for profiles that used it. `sample_record`'s integer case asserts `pre_scale == 1`
  while the encode side accepts it (`src/manager/sample/package.d:154`), breaking the
  encode/decode symmetry. Confirm each is intended before closing.

- **Settle the remaining binding asymmetries**: Tesla's `materialise` fires
  `notify_element_created` per element but never `tree_changed` or `online`
  (`src/protocol/tesla/binding.d:291`), where SunSpec does (`sunspec.d:1160`); consumers that
  rebuild on `tree_changed` miss Tesla devices. MQTT accepts `ip6addr` and other non-scalar
  user types it cannot then sample (`src/protocol/mqtt/package.d:112`), and reverse-projects a
  `SysTime` into `MonoTime` by cast. `held_repeat` sets `_last_update` unconditionally on an
  out-of-order equal sample (`src/manager/element.d:974`), regressing record time. Expression
  format inference runs `Type.call` intrinsics against exemplar values
  (`src/manager/expression.d`), which executes code to infer a type.

- **Finish identity follow-ups**:

  - assign deterministic element indices from profile/template and property positions
    (`src/manager/id.d:382` still allocates sequentially from `_slots.length`);
  - run an end-to-end sync identity smoke test; and
  - add ID reclamation and high-watermark telemetry only if distinct-name churn justifies it.

- **Harden reactor clients**:

  - make Linux WiFi raw/monitor paths drop or restart persistently errored pooled FDs so epoll
    cannot spin;
  - pass the embedded UART RX callback and buffer size through `uart_open` to the hardware
    drivers and wake the main loop from RX IRQ/DMA;
  - move serial writes to on-demand async completion if flow control causes material
    main-thread stalls; and
  - move recorder storage I/O to a helper or future async backend if slow media blocks the
    reactor.
  The remaining ASH, EZSP, and Zigbee timers should move to scheduled callbacks separately;
  they are not I/O readiness work.

- **Complete the GPIO sampler backends**:

  - turn cdev `line_seqno` gaps into series gap events (`urt/driver/posix/gpio.d:289`);
  - enforce live retention ceilings for open-squelch edge streams; and
  - add the waveform generator API needed by RF433 transmit.

- **Complete `/port` eventing**: replace tty discovery polling with uevents or
  inotify-backed rescans.

- **Complete the Linux kernel mirror** (`src/protocol/ip/linux_mirror.d`): a netlink transport
  failure stalls the main loop on the writer's 1s `SO_RCVTIMEO` backstop; move the ACK wait onto
  the reactor. A netdev that appears after its addresses exist (hot-plugged NIC) is only
  re-pushed by a property edit or the bridge offload's refresh; hook netdev appearance from the
  route-netlink watch above. The startup sweep of stale `RTPROT_OPENWATT` entries relies on
  `IFA_PROTO` for addresses, which kernels before 5.18 ignore; on those only routes are swept.

- **Neighbour table as a collection** (agreed 2026-09-09, next PR after #681): make
  `/protocol/ip/neighbour` and `neighbour6` collections (`address`, `mac`, `interface`, read-only
  `state`) on every build. Learned entries are dynamic objects, D-flagged like SLAAC addresses:
  on kernel-mirror builds created, updated and destroyed from `RTNLGRP_NEIGH` events on the
  shared listener in `driver/linux/netlink.d` (seeded by one `RTM_GETNEIGH` dump), on the
  internal stack from the existing cache. Static entries sync back: the mirror tracks them like
  addresses and routes and pushes `NUD_PERMANENT | NTF_EXT_LEARNED`, the flag doubling as the
  ownership marker for the startup sweep since neighbours carry no protocol tag; the internal
  stack installs them as permanent cache entries. The function-style neighbour prints go away.
  While there, move the listener off its per-tick non-blocking recv onto the reactor via
  `fdwatch`.

- **Fix the HTTP binding request-state wedge**: reproduce with request tracing, then replace
  FIFO response correlation with request handles. A rejected or timed-out submission must
  clear `in_flight`; late responses must not complete a different request.

- **Bound the TCP push backlog once its writers can take a partial write**: `TCPConnection.send()`
  queues pages without limit because MQTT packet emission (`src/protocol/mqtt/connection.d`),
  HTTP `write_message`/`format_message` responses, the `/api` JSON dumps (`/api/get` responses
  around 140 KB already truncate) and console session output push a whole message in one
  `write()` and ignore the return; a cap would truncate their protocol streams. Migrate each to a
  `tx_handler` producer (the fileserver and the API schema endpoint are the pattern), or have it
  check `tx_backlog` before committing a message, then enforce a backlog bound in `send()`.

- **The websocket's 128 KB hard bound is sized for the desktop, not for a micro**: pulled
  producers stop at 16 KB, but every pushed emitter can still drive the page queue to the hard
  bound against a stalled reader. The bound exists only to exceed the largest committed frame
  (sync: 64 KB), so it falls with `hello.max_frame`: once pushed emitters are on the feed and
  `max_frame` is negotiated per platform, derive the bound from it. The queue is pool pages now,
  so a no-PSRAM ESP32 serving two stalled browsers needs 256 KB of pages, not of contiguous heap;
  measure the pool headroom on each target that serves `/sync` over a websocket.

- **WebSocket TX copies every frame into its pages**: once encoders write into pages (STREAMING.md
  B.2), a frame should be the producer's page with its header in headroom, queued as it stands,
  and a stream producer should be framed by a `ws_frame` filter that sets FIN on `end`.

- **Take the caller's `MemFlags` through the page-pool jumbo path**: `pagepool.d` hard-codes
  `MemFlags.dma` for any request above the largest slab category, which on ESP32 confines a
  large page to internal SRAM while PSRAM sits idle. Only a page that reaches a NIC ring needs
  DMA; ESP32 WiFi copies on `esp_wifi_internal_tx`, and TCP TX pages are copied into the pcb
  send buffer. Nothing in tree hands a pool jumbo to hardware, so the default should be the
  caller's flags with no DMA bit. Alongside that, surface `page_pool_stats()` and the ESP
  `heap_caps` per-capability free/largest figures through a release-safe console command; the
  pool collects per-category and jumbo histograms, counts and high-water marks and nothing
  reads them.

- **Diagnose the ESP32-S3 DHCP client's cold-boot DISCOVER loop**: `openwatt-4547` (WiFi
  station, node `2BF1FA7C63674547`) broadcasts DISCOVER every 4 to 30 s from a cold boot and never
  sends REQUEST. On its LAN two servers share one L2: `192.168.0.1` and `192.168.3.1` (the same
  MikroTik). Only the `.3.1` OFFER (`192.168.3.11`, 600 s) is ever seen on the wire and the client
  ignores it, while the `.0.1` server that leased it `192.168.0.88` for 396 renewals no longer
  answers. No ARP probe, DECLINE or REQUEST leaves the node. The node's own log is needed; it
  ships over sync only once peered, and the Pi is not ingesting the node's AF_ETHERNET beacon
  either (`/sync/neighbor print` is empty while the `0x88b5` beacon lands on `eth0` every 30 s,
  although the same beacon produced `appeared via ether2` earlier).

- **A stalled sync log subscriber blinds local logging**: the log router holds each record in its
  128-record delivery queue until every consumer acks, and a `log_sub` peer whose transport has
  stopped draining never acks, so new records are dropped at ingress for every sink, including
  stderr and history. Verified on Windows with a stalled WebSocket subscriber: the transport's own
  `tx overflow` warning never reached the log. Evict or bypass a consumer that holds the queue past
  a bound rather than dropping for everyone.

- **Symbolised traces are garbage on DMD/Windows**: `_resolve_batch` resolves every frame to
  `RtlUserThreadStart` with vctools file names, in crash traces and in `capture_trace` callers
  alike, so a trace from a debug build on Windows identifies nothing.

- **The phase-angle delay LUT interpolates a cube root linearly at both extremes**:
  `phase_delay_frac` indexes a 33-entry table by `level_q16 >> 11` and interpolates linearly
  across each 3.125%-wide interval, but a(P) approaches a cube root at both ends, so the chord
  departs badly from the curve there. Mid-way through the bottom interval a commanded 1.56%
  delivers about 0.39%, a 4x error exactly where a diversion controller wants fine trickle
  control; the top interval errs about 1.2 points the other way. Breakpoints are exact, and
  mid-range is fine. Fix with non-uniform breakpoints clustered at the extremes, or more
  entries; burst-fire is unaffected.

- **Verify phase-angle linearity against a trusted instrument**: the regulator now locks and
  fires on an ESP32-S3 (bench Waveshare, BTA16 + CT3021 gate opto + PC817 detector, 50 Hz lock,
  100 clean edges/s). Burst-fire tracks the commanded level, but phase-angle measured low at
  50%: a bench meter read 165.1 V where the 25% point's 124.3 V implies 175.8 V, about 44% power
  for a commanded 50%. That meter is average-responding on a chopped waveform and is the prime
  suspect; a constant zero-cross timing offset was ruled out arithmetically, since a late offset
  raises the ratio rather than lowering it and an early offset large enough to fit implies an
  impossible 211 V mains. Re-measure with a true-RMS or power meter before touching the phase
  LUT, and add the signed `zc-offset` property from the design note only if a real lead time
  shows up.

- **Port the last two classic-only ESP32 primitives**: counters, GPIO interrupts, link slots and
  the ADC (oneshot reads, calibration by the IDF's own scheme macro) are available
  across the family. Two remain gated to classic ESP32 in
  `urt/driver/esp32`: the reflex (NMI-tier link) synthesises Xtensa `xt_nmi` code against classic
  pin ranges, and the ISR-side raw ADC read drives the classic SAR registers directly
  (`adc_hw_can_read_critical` is false elsewhere). Each needs its own port and hardware check:
  S2/S3 for the reflex NMI vector and GPIO register layout, and a per-part ISR-safe SAR path or
  an honest "not in ISR" contract for the ADC.

- **Stream TX queue follow-ups** (2026-10-06, #815):
  - A stream whose `transmit()` is the default `write()` still lets a direct `write()` reach the
    line ahead of pages already queued. Retire `write()` as a line path: subclasses implement
    `transmit()`, and `write()` becomes `queue_copy()` everywhere, as `SerialStream` does now.
  - `SerialStream.write()` never blocks until the line has taken the bytes, so Modbus RTU's
    transport timeout starts while its frame is still on the wire. The timeout's margin of two
    frame times absorbs one queued frame; timing from the line's completion would not need it.
  - No test drives a pump's continuation: `pump_tx` yielding into `continue_tx`, `invite_tx`
    standing back while one is scheduled, and `offline()` cancelling it; nor `TCPConnection`'s, where
    a second invitation while one is pending must not schedule another (the #816 review's probe:
    an open connection, a producer that yields at its deadline, `tx_handler` twice, one continuation,
    then `drop_tx_handler` cancels it). Both need a scheduler: an `Application` in the test, which
    waits on an Application that can be created twice in one process. (#816)

- **`router.iface`'s unittest failed once on Windows** (2026-10-07, at the `set_l2mtu(1514)` mtu
  assertion, package.d:1872) and passed on three reruns of the same binary. A value assertion right
  after a setter should not be flaky; look for state another test leaves behind.

- **`/log/print` without `--stream` redraws its pager every tick**: on the RP2350 it held the CPU
  at 64% and logged an 80 ms `console-session` update each frame while idle. The live view should
  redraw on a new entry or a key, not per tick.

- **Console session restarts leak and slow down each time**, on the H7 and the RP2350 alike.
  Each Ctrl-C restart of a UART session logged a longer `console.session.update` tick on the H7
  (245, 285, 340 ms over three restarts, 820 ms later), and a restart often swallows the command
  sent right after it. The H7's AXI heap grew from 38 KB to 418 KB over a few dozen restarts
  until a 10,248-byte allocation failed, and the RP2350 grew about 5 KB per port open while idle
  time added nothing. Opening the port over a CP210x seems to restart the session by itself on
  alternate opens. Find what a restart keeps.

- **Stream `/api/cli/execute` output**: the handler collects output in a `StringSession`, whose
  `MutableString` asserts past 32 KB, so `/device/print` with ~20 devices kills the process.
  Give the request a session whose `feed_output` pulls into a chunked JSON response (as the
  schema transfer does) instead of a whole-output buffer. Windows also drops `--interactive`
  on a piped stdin, which is why a piped session prints nothing. Audit `DeviceTreeView` and the
  other live views for terminal-channel assumptions on such sessions.

- **Move the remaining prints onto the model design, not onto `TablePrint`**: a node and leaf
  model (collections, objects and devices as nodes; properties and elements as leaves; bespoke
  tables such as the MQTT broker's maps behind the same interface), encoders (table, tree, JSON,
  CSV) and pacers (print, live view), read through point cursors (copy-on-write snapshots) or span
  cursors (series ranges). It replaces `Table`'s cell store, `TablePrint`'s walk and resume, the
  duplicate print and view walkers, and the API's whole-buffer JSON; a design note goes in
  `docs/wip/` first. Interim: every former `Table.render` site, `/protocol/ble/device` and
  `/element/link` build their table whole and hand it to `print_table`, whose `BuiltPrint` paces
  the rows; when the sites move to the model, delete `print_table` and `BuiltPrint`. Still
  written whole: `/sync/neighbor`, `/sync/peering`, `/port`, `/system/linux`, `/record query`
  (one line per sample, the largest) and `/protocol/ble/client` GATT; `--json` prints still build
  one `Variant`. `CollectionPrint` resumes by iteration index, so an add or remove
  mid-print can skip or repeat one item; `DevicePrint` resumes by device slot, and inside a
  device by row count, so an element or component added between chunks repeats or loses a row
  and can leave the tree glyphs disagreeing.

- **Pulled print follow-ups** (2026-10-06, #817):
  - The session renders a fixed 1,600-byte chunk before it applies the grant, so a grant smaller than the
    chunk (TLS takes its record framing out of a page) is still split and copied by `take_tx_page`. Make the
    chunk follow the grant, within what a row needs (#832 review).
  - Cancelling a print drops the untaken tail of a page the stream has started, so the line
    ends mid-row, possibly mid-glyph or mid escape sequence, and the prompt lands on it. Keep
    the rest of a started page and drop only output not yet begun.
  - `TablePrint`'s destructor does nothing, so a path that frees one before `update()` finishes
    leaves the session holding `&produce`. Every path today finishes first.
  - `walk` and `emit` (a 512-byte row plus the recursion in `DevicePrint.emit_node`) now run
    inside the stream and TCP pumps; measure the stack headroom on the embedded targets.
  - A pull is not strictly bounded (the #817 review): measuring stops only between top-level
    blocks, so one device is measured whole; `DevicePrint`'s filter rescans each subtree from
    every ancestor, twice per component; and a resume re-walks the current device from its first
    row, skipping what was sent. Cheap for real devices, and the model design replaces it.
  - A print streams across many pulls and packets, so its rows show values from different moments
    and its widths were measured at another; a point cursor holding T fixes values and membership.
  - The live views (`CollectionWatchState`, `TreeViewState`) format and measure every row on every
    tick and render only the visible slice; they should format and fit only the slice.

- **Document `/device` in CLI.md**: `add`, `print` (`filter=`, `--watch`, `--expand`) and
  `/element/set` have no reference entry. A bare `print m1*` does not bind `filter`; it lands
  in the variadic `args` and prints everything.

- **Document `/protocol/mqtt/broker` in CLI.md**: the broker, its `discover` prefixes and the Home
  Assistant discovery it drives (entity mapping, writers, availability aggregated into
  `status.online`) have no CLI.md section at all.

- **Clarify TLS server transport ownership**: ensure shutdown cannot destroy a listener twice
  when a server-side TCP stream takes multiple ticks to stop.

- **Make profile lifetime explicit**: either keep profiles process-lifetime and enforce that
  contract, or give borrowers ownership before allowing reload/free. Borrowers include
  accumulator source paths, element metadata, profile enums, protocol element descriptors,
  and other slices into profile string/section storage.

- **Stack high-water marks beyond the main stack**: `sysinfo` reports only the main stack.
  Fibre stacks (16 KB embedded, 64 KB hosted; used by zigbee and ezsp) could be painted in
  `co_create` and reported per fibre, which is where an undersized stack would hide. BK7231's
  `bk_init_mode_stacks` colours its IRQ, FIQ and SYS stacks, but they live in `.bss.stacks`,
  which the reset path's bss zero wipes straight after; paint them after the zero and the IRQ
  and FIQ marks are a scan away.

### STM32 bring-up follow-ups (2026-09-26)

The DevEBox H7 boots and runs OpenWatt with a console, per-bank TLSF pools and DFU recovery.

- **!!! F4 AND F7 SERIAL RECEIVE IS ONE INTERRUPT PER BYTE. DO NOT PUT A FAST LINK ON ONE UNTIL
  THIS IS DONE. !!!** Neither family has a U(S)ART FIFO, so urt's STM32 UART takes an interrupt
  for every received and every transmitted byte: 100,000 a second each way at 1 Mbaud, with any
  interrupt or critical section longer than one character time overrunning RX. The H7 runs its
  16-byte FIFOs and is fine. Receive on F4/F7 wants circular DMA into the RX ring, with the IDLE
  line (F4) or the receiver timeout at 3.5 characters (F7) and the half/full transfer interrupts
  raising the RX event; transmit wants DMA from the TX ring. Neither family has run on hardware.

- **The JZ-F407VET6 image is ~70 KB over its 512 KB flash** (`BOARD=jz-f407vet6`, `switch`,
  TINY). Candidates: CLI helpers (~76 KB), the element catalogue (15.5 KB), libm trig (~15 KB),
  the two sync encoders; `HEADLESS=1` gates almost nothing. The APM32's ROM DFU reports a 1 MB
  sector layout, so read the factory flash-size register before trimming: the part may be a VG.
- **F4 and F7 have never run on hardware.** The APM32F407 board is the first F4 candidate.
- **No stack guard.** The stack sits at the top of core RAM with statics below it; an overflow
  silently corrupts them. An MPU no-access region under `_stack_low`, or a PSP/MSP split.
- **Queued console output is lost on a deliberate reset.** `system_reset` does not drain the
  UART's queued pages; only the fault path writes through the blocking `uart0_hw_puts`. MT7621's fault report
  flushes its netconsole before resetting; one console flush inside urt's `system_reset` would
  serve every part and every reset path.
- **No reflex/event backend.** EXTI, and on H7 EXTI to DMAMUX to DMA to BSRR, would give STM32
  what the ESP32 event links do.
- **Check whether the page pool's DMA pages belong in the H7's uncached SRAM1-3.** It takes 9 KB
  there at boot.

Bare-metal follow-ups from the same series:

- **The shared TLSF heap core has not run on Bouffalo, BK7231N/T or MT7621 hardware.** urt's
  `driver/baremetal/heap` now serves every bare-metal platform; only the STM32H7 and RP2350 have
  run it. Run the unit-test images on a BL618, a BL808, a BK7231N and the MT7621.
- **The MT7621 fault report prints no backtrace.** `urt.exception.write_backtrace` is shared by
  every bare-metal part and MIPS already unwinds in `capture_trace`; walking from the faulting
  frame needs the unwind seeded from the trapped epc, ra and sp rather than the handler's own.
- **A bare-metal assert spins forever**, so no boot guard counts it. It should record a crash
  and reset, as the Cortex-M fault report does.
- **The bare-metal assert backtrace skip is a fixed count**, and the number of frames the
  capture wrappers leave differs between builds: the skip is right in the RP2350 unittest image
  (per the #341 review) but the fault frames on an STM32H7 release image imply one frame more.
  The Cortex-M fault path anchors on EXC_RETURN instead; the assert path wants a similar anchor,
  such as starting after the last return address inside `urt_assert`.
- **Check the RP2350 console for truncated output.** Its UART write fills the 32-byte FIFO and
  returns short, and the console treats a short write as sent; the STM32 console lost output the
  same way until its UART went interrupt driven.

### BL808 follow-ups (2026-09-30)

M0 is the BL808's network node: it boots one image carrying D0, brings up the provisioning AP and
the standard services, drives the M1s Dock's panel, its LED on hardware PWM, and claims D0 over XRAM
so D0's devices appear on M0 only.

- **`d0fw.bin` is a side effect of linking D0's ELF**: changing the packer, or deleting only
  `d0fw.bin`, does not rebuild it. Make it an explicit output of the ELF and the packer.
- **The M0/D0 link has no permanent tests**: a link answer before and after Running, interface
  disable and re-enable, a transport destroyed and recreated, frames over the MTU, and load across
  both cores. The review's probes over a mocked platform are a start.
- **M0's PSRAM slice is 1 MB**, leaving the full build about 800 KB of heap, of which a full log
  history takes about 110 KB. Widen the slice at D0's expense (both linker scripts).
- **A D0 that never beats is not watched.** M0 stands for D0 only once D0's heartbeat has moved, so
  a missing image or a D0 that dies before its first beat leaves the chip up without it; that
  needs a boot deadline that cannot loop the chip on a bad D0 image.
- **M0's clock is whatever the boot header chose** (`mcu_clk`, the WiFi PLL's 320 MHz), and
  `bl_common/clock.d` trusts it for the shared 160 MHz timebase. Read M0's clock mux at boot, or set
  it, so a different boot header cannot silently skew the timers.
- **M0's new subsystems have no host tests**: the mailbox (wrap, full, space signal, count rollover),
  the partition table (both copies, bad CRCs, a newer backup), flash command failures, the image
  packer and loader, and the shared littlefs glue over each block device. Each needs a host seam.
- **`flash_program` reads its source after XIP is taken away**: fine for littlefs's RAM cache, its
  only caller, but a source in flash faults. Bounce through RAM, or make RAM-only the contract.
- **The D0 loader trusts its payload**: destinations, entry and segment ranges are bounded only by
  the bank. Validate them before OTA or recovery produce payloads.
- **A valid partition table's geometry is not bounded by the flash**: the media partition is checked
  for alignment only. Bound it by the flash size before littlefs erases and programs there.
- **Packets between the cores ride sync**: D0 reaches the network through M0 by a sync frame kind
  carrying packets, on the one raw XRAM channel, as `/interface/tunnel` in
  [TAPS_AND_TUNNELS.draft.md](docs/TAPS_AND_TUNNELS.draft.md); no Ethernet channel over XRAM.
- **Sync copies each frame into XRAM**: `/interface/xram` offers `tx_reserve`/`tx_commit`, so the
  sync encoders could build a frame where D0 or M0 reads it. Worth it once the M0/D0 link carries
  bulk traffic.
- **A doorbell event the full event queue refuses waits for the next heartbeat**, up to a second.
- **The heap core keeps a pool it failed to add**: reject it so its bytes are not counted as free.
- **The BL618 has no `system_reset`/`por_reset`**; only the BL808 cores do.
- **M0's provisioning AP is open**, where the Waveshare board's defaults run a WPA2 AP on a known
  setup secret with non-anonymous pcap. Bring M0's `default.conf` into line once a WPA2 AP and the
  secret's effect on the web config's API access are checked on the BL808.

### RP2350 bring-up follow-ups (2026-09-20)

Boots and runs on a WeAct RP2350B Core, with an interactive console on UART1 (GPIO8 TX,
GPIO21 RX): commands echo and execute, and the heartbeat ticks idle. `xosc_hz` is confirmed
at 12MHz by clean UART framing. Outstanding:

- **A light does not retry a failed WS2812 frame**: `ws2812_set` now fails when the PIO stalls
  and resends the whole chain on the next set, but the GPIO binding ignores the result, so a
  steady light keeps a lost frame until its output next changes. Retry from the binding.
- **The status WS2812 once held solid orange** with `colour` at `#00ff00`, from a flash until the
  next; not reproduced since. A light re-sends only on a change, so one garbled frame would
  persist; look at what reaches the chain before the first frame if it recurs.
- **`UartConfig.tx_gpio`/`rx_gpio` are ignored.** The driver routes a fixed default pair per
  port, so a stream cannot pick its own pins. Picking them needs a funcsel per pin, not per
  port: most UART pins are funcsel 2, but the alternates (GPIO6, 10, 14, 18, 22, 23) are 0x0b.
- **The `FLASH` region caps at 4MB.** The Core carries 16MB and there is no partition table,
  so the ceiling is the linker script's alone.
- **Unit tests stop at the first failure on hardware.** All 180 modules pass now, and
  reflashing no longer needs the button, so a regression costs a build cycle rather than a
  trip to the bench. `NOEXCEPTIONS=0`, which would let `run_test` catch and carry on, still
  does not build on baremetal: `dwarfeh.d` casts `Throwable` to `Error` and urt's no-RTTI
  `_d_cast` wants a `dyn_cast!Error` contract that `Throwable` does not declare.
- **The app is silent after the unit tests finish.** The runner prints `Process restarting...`
  and nothing follows. A release image boots to a working console, so this is specific to the
  `CONFIG=unittest` image, not to app startup.
- **More of the boot ROM is worth taking.** `urt/driver/rp2350/bootrom.d` has the table
  lookup, so each addition is a signature and a code. Still unused:
  `CONNECT_INTERNAL_FLASH`, `FLASH_EXIT_XIP`, `FLASH_RANGE_ERASE`, `FLASH_RANGE_PROGRAM`,
  `FLASH_FLUSH_CACHE` and `FLASH_ENTER_CMD_XIP` are the whole erase/program sequence, so
  littlefs and config persistence need no QMI driver; `OTP_ACCESS` reaches the OTP where a
  durable identity or MAC would live; and `LOAD_PARTITION_TABLE`/`PICK_AB_PARTITION`/
  `CHAIN_IMAGE`/`EXPLICIT_BUY` are an A/B OTA framework already in silicon, `EXPLICIT_BUY`
  being the commit step that gives rollback. No crypto is exported, so none of this touches
  the AES-GCM gap.

  Note `RESET_USB_BOOT` is RP2040 only. RP2350 reboots through `REBOOT` with
  `BOOT_TYPE_BOOTSEL`, and the lookup pointer sits at `0x16`, not the RP2040 `0x18`; the
  wrong one reads a bogus pointer and hard faults inside ROM.

- **Drive the RP2350 SHA256 block.** `SHA256_BASE 0x400F8000` (`CSR`, `WDATA`, `SUM0..7`)
  is still unused. It is an optimisation rather than a gap, since urt already has software
  SHA-256. The TRNG beside it is driven.
- **Measure the TRNG sample interval.** `trng.d` leaves `SAMPLE_CNT1` at its `0xFFFF` reset
  value, the slowest the block offers, because a conservative interval is the safe default
  for entropy and nothing had measured the alternative. That is roughly 12.6M cycles per
  192-bit collection before the von Neumann decorrelator discards anything, so a key or a
  nonce costs real time. The rate against entropy quality wants measuring before it is
  tuned.
- **Generate register definitions instead of hand-writing them.** Three constants in the
  RP2350 driver were wrong (`PLL_SYS_BASE`, `RESET_IO_BANK0`, and pad ISO never cleared)
  because nothing checked them against a primary source. A small generator emitting
  `regs.d` from the pico-sdk headers would be authoritative and re-runnable; pico-sdk is
  BSD-3-Clause against urt's MIT, so the attribution question needs deciding first.
- **No USB device stack.** `router/stream/usb_serial.d` is ESP32-only and rides that part's
  hardware USB-Serial-JTAG block. RP2350 needs a real CDC-ACM driver (controller bring-up,
  EP0, enumeration, bulk endpoints); until then the board does not enumerate at all once
  our image is running, and the UART is the only console.
- **The board is a Y23A-RP2350B**, not the WeAct whose pico-sdk header bring-up used; its WS2812
  on GP20 is `system.panel.status`. Its other pins, and any user key, are unverified.

### BL808 on the M1s Dock (2026-09-29)

- **M0 runs out of DMA memory at boot** on this branch: `heap.alloc: OOM! size=344 flags=4` right
  after `BL808 M0: ready`, and D0 never prints. Nothing had been flashed since May, so whether
  master does the same is unknown; start there.
- **The WS2812 on GPIO8 has not lit**, because D0 has not run; the D0 bit-bang backend moved
  behind `urt.driver.ws2812` untested.

### MT7621 bring-up follow-ups (2026-09-26)

`make BOARD=rb760igs` builds an image that RouterBOOT netboots on the MikroTik hEX S (RB760iGS): an
ELF linked at `0x80001000`, running from RAM. The unittest image passes on the hardware, and a
4-minute soak answers every ping and HTTP request. The hEX S has no serial header, so the platform
also broadcasts console output as UDP. Outstanding:

- **The netconsole is a bring-up probe.** Broadcasting console output from a fixed IP is a board
  hack inside the chip driver; it becomes a UDP log sink.
- **Only a watchdog reset is identifiable.** `RSTSTAT` latches the watchdog and software-reset
  causes (write-1-to-clear), but a deliberate `/system/reboot` and a fault's reset are both
  software resets, so every other boot classifies as `unknown` and counts a boot-guard strike. A
  retained reset record needs RAM that survives RouterBOOT, which is untested; until NVS exists the
  boot guard keeps no state across resets anyway.
- **Ethernet and the MT7530 switch.** Standalone ports take the platform's MAC offset by front
  port (etherN = base + N-1, as RouterOS assigns them); design and remaining phases in
  `docs/wip/SWITCH.md`.
  Every claimed port is isolated and CPU-only, and bridges forward in software. Open items in the
  driver:
  - Three consecutive runs on 2026-09-25 took a lease but never answered the PC's ARP or ping;
    every run since answered all of them. Unexplained; the interrupt path has since stopped acking
    after its last ring check, which could lose a wakeup. If it recurs, capture with `DebugARP` on,
    which shows whether the request arrives and the reply is sent.
  - Unclaimed ports stay powered and merely isolated; power their PHYs down once the netconsole is gone.
  - Receive trusts the frame engine's special-tag untag (`rxd2` VTAG, port in `rxd3`). 802.1Q frames on a
    front port pass inline both ways (ether1.3 takes a DHCP lease); 802.1ad is untested.
  - DMA buffers are uncached and transmit waits for each release; move to cached buffers with MIPS L1/L2
    cache maintenance and reclaim from the release ring.
- **sfp1 has never linked over fibre.** GE2 and the AR8033 behind the cage are driven (urt#347)
  and a UF-INSTANT GPON stick links and passes traffic, but the bench's BiDi BX10 module needs a
  BX-U partner, so an optical link on sfp1 is untested. The AR8033's cage side speaks
  1000BASE-X only, so a copper SFP links at 1000BASE-T alone and only after the cage sets the
  module's own PHY to 1000BASE-X over I2C (MDIO at 0x56, as Linux's sfp.c does): not written.
  A host with an SGMII SerDes would instead want a media hook driven from the module's EEPROM.
  The query is per interface and shared with copper ports: one port-media description (media
  kind; supported, advertised and partner link modes; identity from the PHY ID or the module
  EEPROM; diagnostics from PHY cable test/temperature or SFP DDM), assembled from the PHY via the
  ethernet driver or switch side-channel plus the bound cage, with absent fields creating no
  Element.
- **Check whether BL618, BL808 M0 and BK7231N corrupt their TLSF heaps.** `vendor.mk` forces
  `TLSF_ALIGN_SIZE_LOG2=3` on them (urt 51f84f0) so 8-byte requests skip memalign's gap, but on
  32-bit TLSF's 4-byte size field then makes blocks alternate between 8- and 4-aligned and its size
  arithmetic stops matching the physical layout: the MT7621 corrupted its heap within the first
  unittest module, and builds without the define. Getting the no-gap intent back needs TLSF
  patched to an 8-byte header overhead on 32-bit.
- **Only the timer compare, the frame engine and GPIO take interrupts.** Shared lines route to CPU
  pin 0 of VPE 0 and dispatch through `_irq_dispatch`; the switch and I2C are still polled. The
  periodic and one-shot compare share one register, as on BL618.
- **The CPU clock is derived, not measured.** `cpu_rate()` follows Linux's clk-mt7621 and the
  timing looks right, but nothing has checked it against a reference.
- **RAM size is a board fact.** `board.mk` passes the hEX S's 256MB. Detect it at runtime as
  Linux's mt7621 memory probe does (write a marker, find where it aliases) and size the heap from
  that. RouterBOOT's resident footprint is also unverified: the heap takes everything above the
  image; nothing has broken, but nothing has proven it either.
- **Flash and persistence.** 16MB SPI NOR: RouterBOOT occupies `0x0-0x40000` (hard_config
  holds the base MAC, soft_config the boot settings), and `0x40000-0x1000000` is a YAFFS2-like
  "minor" filesystem holding `kernel`. Flash boot needs that written; config persistence needs
  somewhere that is not RouterBOOT's. The NOR has a PIO driver private to the platform
  (`urt.driver.mt7621.spi_nor`), used only to arm netboot; it is not a `urt.driver.spi` backend.
- **The recovery rung wears the soft_config sector.** A firmware that crashes on its defaults
  arms netboot every fourth boot, and RouterBOOT disarms it again: two erases of one 4K sector
  per cycle, about 70 days of a one-minute crash loop to the NOR's 100k-cycle endurance. Back off
  (only every Nth descent) if a crash loop that long is plausible.
- **Check the model against the build.** hard_config carries the board code (`RB760iGS`) and the
  RAM size (tag 0x0D); warn when an image runs on a board it was not built for, and take the RAM
  size from there instead of `board.mk`.
- **No wall clock.** Neither the SoC nor the board has an RTC; the default config needs an NTP
  client. There is no TRNG driver either, so `crypto_random_bytes` is unsupported.
- **Audit the `align(1)` structs.** LDC loads `align(1)` fields at their natural alignment, so a
  misaligned one traps on MIPS and silently rotates on ARMv5 (BK7231). `urt.uuid.GUID` now stores
  bytes; the DHCP message, TCP header, GoodWe AA55 and Linux mgmt structs are unaudited. Worth an
  upstream LDC report: `DtoAlignment(VarDeclaration*)` knows the field alignment but member loads
  ignore it.
- **UART2/UART3 are pinmuxed to GPIO on the hEX S** (per the OpenWrt DTS), and the UART driver
  does not touch GPIOMODE.
- **Only one VPE of one core runs.** The 1004Kc pair has four VPEs. A second VPE running only reflex
  tasks, with the GIC routing their sources to it, is also how this chip would reach the event
  layer's unmaskable tier: the NMI vectors into RouterBOOT's flash, and there is no trigger matrix.
- **TLS is emulated.** `-emulated-tls` with urt's own single-threaded `__emutls_get_address`,
  since the UserLocal register is optional in MIPS32r2. Native TLS would be cheaper if the
  1004Kc has Config3.ULRI.
- **The sysroot is hand-built.** picolibc and compiler-rt builtins are built locally per
  `third_party/urt/platforms/mt7621/README.txt`; CI has no MIPS job.
- **RP2350 and STM32 still run picolibc's malloc behind a stash-header wrapper**
  (`urt/driver/{rp2350,stm32}/alloc.d`, identical copies). MT7621 moved to the vendored TLSF with
  its own C entry points, so no libc allocator links; the same would suit them. RP2350's `_sbrk`
  is dead code: picolibc's malloc calls its own weak `sbrk` over the same linker symbols.

### Template instantiation is 32% of the BK7231N image (2026-09-12)

Measured on the BK7231N release image (953,924 B of text): symbols from template
instantiations are 304,584 B, 31.9% of it. 1,425 of those symbols, 152,244 B (16.0% of text),
have exactly one caller and are never address-taken, so they exist only because an
instantiation gets its own out-of-line symbol. Three machines dominate, and each needs its own
fix; inlining is not the universal answer, and was measured to be the wrong one for Array.

- **`Array!T`: 64,968 B over 536 symbols and 88 element types.** The shared cores already exist
  (`array_grow_trivial`, `array_reserve_trivial`, `array_allocate`, `array_free`) and take the
  element size at runtime, so `Array!ubyte.grow`, `Array!uint.grow` and
  `Array!InetAddress.grow` are the same 22 instructions differing only in three immediate
  constants. The wrapper is 86 B because the core takes eight arguments and four of them spill
  to the stack. Shrink the ABI instead of inlining: the core can derive `alloc_count` from the
  array prefix and `has_allocation` from the pointer, and (size, alignment, prefix) pack into
  one word, leaving four register arguments and a wrapper of a few moves. Measured dead end:
  `pragma(inline, true)` on grow/reserve/resize/remove/removeSwapLast/clear/~this removes 203
  symbols and 5,740 B of Array code but costs 704 B of text overall, because the callers absorb
  more than the wrappers held.
- **Console property thunks: 31,512 B over 468 symbols.** `mark_set` is 9,592 B over 114
  symbols, 106 of them single-caller, and is a constant mask OR'd into a flags word followed by
  a shared notify path: pass the mask, keep one function. `SynthGetter`/`SynthSetter`/
  `SynthDefault` are 21,920 B over 354 symbols, all address-taken because they are the function
  pointers in the property descriptor, so they cannot be inlined away and must instead become
  fewer: one adapter per property *type* plus a member pointer in the descriptor, rather than
  one per property.
- **`from_variant!T` / `to_variant!T`: 14,184 B over 74 symbols, `from_variant` averaging 211 B.**
  41 of them are single-caller. Per-type parsing is real work, but the integer and enum families
  should share one body parameterised by width and signedness.

Not a lever: `--linkonce-templates` changes nothing here (one object file already), and LTO is
unusable on this target (see the strict-alignment entry).

### Strict alignment follow-ups (2026-09-11)

From the PR #563 audit; the call-site rule is in AGENTS.md (pointer form only on proven memory).

- ESP heap cost of the 8-byte untyped default: IDF TLSF has `ALIGN_SIZE = 4`, so every untyped
  `alloc` now takes `tlsf_memalign_offs` with a front gap; measure heap free and fragmentation on
  the S3 and C6 after urt#287 and decide whether to accept or special-case the ESP backend.
- LDC emits `alloca [N x i8], align 1` for `ubyte[N]` locals; GCC raises local arrays to the
  target preferred alignment. Propose upstream that LDC match (the ARM datalayout already declares
  32-bit preferred aggregate alignment); until then every wide-viewed local needs `align()`.
- Measure `pragma(inline, false)` on the 4- and 8-byte slice-form endian helpers for strict-align
  targets only; force-inlining everything cost 96 B on BK7231N, the narrow set was byte-identical.
- Pin the Ethernet frame base: Linux raw RX is now `align(4)`; Windows pcap and the wifi radio
  RX hand over foreign buffers, so the OW transport header padding (frame+20 4-aligned) is
  unasserted there. Assert at `incoming_ethernet_frame` once every driver states its alignment.
- Sealed bucket images place the record plane at `base + count*4`; round to 8 before 8-byte
  records are ever loaded wide from a sealed bucket (series.d image layout).
- Sweep the remaining `align(size_t.sizeof)` buffers to a literal alignment matching the widest
  view taken of them.
- ARMv5TE `ldrd` needs 8-byte alignment; a `cast(ulong*)` on 4-aligned memory is unsafe there
  even though the same code is fine on v7. Any 64-bit pointer-form access must prove 8, not 4.
- Frame pointers cost 26 KB of BK7231N text (`-frame-pointer=all`, 2.8%); `non-leaf` recovers 9.6 KB
  but the crash walker then needs the exception frame's `lr` as the first edge, since a leaf has no
  frame record. Worth doing once the walker handles it.
- LTO on ARMv5TE is not usable as is: the single-thread atomic lowering does not reach lld's LTO
  codegen (`__atomic_*` libcalls go undefined) and the size optimisation is lost there too (full LTO
  produced a 1.22 MB text, +275 KB). Needs `minsize` propagated into the LTO backend before it can
  fix the remaining single-caller forwarders the -Oz inliner leaves out of line.
- **Take the mbedtls shim's EC key import and export off the private members**: urt#299 sets
  `MBEDTLS_ALLOW_PRIVATE_ACCESS` so the shim compiles against mbedtls 4.x, which also leaves
  `urt_pk_import_ec_p256_key` and `urt_pk_export_privkey_d` reading `grp`, `d` and `Q` directly.
  Those are private from 3.x on, so upstream may rearrange them in a minor release. Switching to
  the classic accessors does not settle it: 4.2.0 moved `mbedtls_ecp_read_key`,
  `mbedtls_ecp_set_public_key` and `mbedtls_ecp_export` into `mbedtls/private/ecp.h` behind the
  same guard, so only PSA is sanctioned there. The shim already runs its RNG, key attributes and
  ECDH through PSA on 4.x, so these two would follow that path; the cost is that PSA hands back a
  `psa_key_id_t` rather than an `mbedtls_pk_context`, so the TLS callers move with it. 3.x can use
  its public accessors and 2.28.1, which the Bouffalo targets vendor, keeps the direct members.
  Worth doing when the 4.x path next needs touching, not as a build fix.

### ESP RISC-V bring-up (2026-09-20)

The pinned uRT includes the single-core RISC-V critical-section and ESP task-creation
fixes. The remaining build integration below still needs to land; in particular, the
D-side BLE driver must agree with the ESP-IDF Bluetooth configuration. Earlier C5 hardware
validation used additional local patches and does not validate the committed tree.

- **The C5 boot-loops, cause unknown.** The image links and the bootloader hands over, then the
  app takes a `SW_CPU` reset through `esp_restart_noos_inner` and repeats. The panic text goes to
  the USB-serial-JTAG console, not the CP210x UART, so it was never captured; a diagnostic image
  with the console on UART0 builds but overflows the 3 MB slot by 31 KB with IDF logging on. The
  NimBLE init and LittleFS mounting a SPIFFS-formatted partition
  are all candidates. Get the backtrace before changing anything.

- **Enable Bluetooth in the C5/C6/H2 IDF targets.** These are Bluetooth-enabled builds, but
  their defaults set `CONFIG_BT_ENABLED=n` and their component dependencies omit `bt`.
  Enable BT and NimBLE and include `bt`, matching the S3 target. The C5 firmware link fails
  on NimBLE symbols with ESP-IDF v6.1 and uRT `a8fe623`; the critical-section symbols resolve.
  This target configuration predates #732 and is a separate build fix.

- Choose an H2 feature set that fits its 1.75 MiB OTA slots; the reported 2.69 MB
  full image cannot fit a dual-OTA layout on its 4 MB flash.
- Reduce SmartEVSE image size within its stock partition layout; the 2026-09-19
  build used 94% of its slot, and stock-firmware compatibility prevents resizing it.

- **A LittleFS default needs a C6 migration.** SPIFFS is still the `esp%` default, and the C5
  cannot use it (its sdkconfig disables the VFS syscalls the SPIFFS backend rides on, so
  `ftruncate` goes undefined). Switching the default costs the deployed SPIFFS C6s their
  `conf/node.id` and fleet allegiance on first boot, so that release needs a re-adoption note,
  and ideally the NVS identity fallback already noted at `src/manager/sync/peering.d`. The
  SmartEVSE must stay on SPIFFS either way: it keeps the stock partition table for
  stock-firmware compatibility.

- **The C5 reference profile describes the wrong module.** It claims the N4 (4 MB, no PSRAM);
  the devkit in hand is an N8R8, 8 MB flash and 8 MB PSRAM, and a full image does not fit 4 MB
  dual-OTA at all. The branch moves the profile to 8 MB with the C6's partition layout. Note the
  profile sets `CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y` without `CONFIG_SPIRAM=y`, so the PSRAM
  is unused whichever module is fitted.

- **C5 and C6 text is ~395 KB larger than the S3's, unexplained.** Across the 10,166 functions
  present in both images RISC-V is only 4.8% bigger, and it wins on functions under 32 bytes and
  over 512; soft-float accounts for 536 bytes of helpers, and 802.15.4 is not built into either.
  So the bulk is code the S3 image simply does not contain. Worth identifying before deciding how
  to win back the C6's headroom.

### Keep FreeRTOS out of the primitives (2026-09-20)

Every port, bare-metal or ESP, runs the same single reactor loop in `src/main.d`, with no reactor
I/O and idle in `Event.wait`. The bare-metal ports realise the primitives on IRQ masking, atomics,
WFI and an mtime oneshot; the ESP port instead adopted the kernel's objects, and that is what
broke the RISC-V parts above. The D-side kernel surface is 18 symbols
(`urt/internal/sys/freertos/package.d`).

One dependency has to stay: the main loop is an IDF task, and IDF's own tasks (WiFi, lwIP, the
NimBLE host, the task WDT) only run if we block cooperatively, so the reactor wake stays a task
notification. The C shim's worker tasks stay C-side too; that is IDF's boundary, not ours.

- Audit whether any D code on ESP blocks on `Mutex`/`Semaphore`/`Event` outside the reactor. The
  architecture says no. Record anything found before changing the arms.
- Point the sync primitives at their `Embedded` arms instead of the `FreeRTOS` ones, shrinking
  the binding to the notify and task-handle calls.
- Route fibres through `co_swap` instead of one FreeRTOS task per fibre
  (`urt/driver/freertos/fibre.d`). This is the largest single win, since every `async` call
  currently costs a task, and the riskiest item: the Xtensa arm must spill register windows
  before switching and has never run. Verify on hardware, RISC-V first.

### ESP second core (2026-09-20)

The runtime is single-core on every part, including the dual-core S3 and S31, which both set
`CONFIG_FREERTOS_UNICORE=y` in their `sdkconfig.defaults`. Prerequisites, each small
once the primitives work is done:

- `cpu_id()` for ESP (Xtensa `PRID`, RISC-V `mhartid`) and `has_smp = true`. This compiles the
  SMP arm of `Critical` for the first time; it has never built on any port, and no port defines
  `cpu_id()` today.
- Per-core arenas in `urt/mem/temp.d`; the single `__gshared` arena is the known hazard, and the
  file says so.
- Real atomics, which openwatt#720 provides on Xtensa; RISC-V already has the A extension.

The open decision is the model, and it is a design question rather than a checkbox:

- **AMP**, as on the BL808: core 1 runs a second instance bridged by IPC, IDF stays unicore on
  core 0. Fits "FreeRTOS does not schedule our work" and reuses the BL808 shape, but needs an
  APP_CPU release path outside IDF, which leaves it stalled under `UNICORE`.
- **SMP** under IDF's kernel: `UNICORE=n` and pinned tasks. Less work, more FreeRTOS.

### ESP32-S31 bring-up (2026-09-21)

`PLATFORM=esp32-s31` builds, links, boots and runs: the console is interactive over
USB-serial-JTAG, `wap1` beacons, and `ble1` receives adverts. The part is an ESP32-S31 rev v0.0
on a board silkscreened
"ESP32-S31 Function-Core Board V1.0", with 16 MB flash: dual-core RV32IMAFC plus an LP core at
300 MHz, Wi-Fi 6 on 2.4 GHz only, BT 5.4 LE, IEEE 802.15.4, and a gigabit EMAC.

- **It needs ESP-IDF v6.1**, where `esp32s31` is still a preview target; v6.0.1 has no
  `components/soc/esp32s31` at all. Only `idf.py set-target` enforces `--preview`, and the build
  passes `-DIDF_TARGET`, so nothing had to change. `~/.espressif` now resolves to v6.1 for every
  ESP target and no other target has been rebuilt against it.

- **Hard-float ABI, shared with P4.** S31 uses `ilp32f` through the `e907` processor
  entry; P4 uses `ilp32f` through `esp32p4`. The C2, C3, C5, C6 and H2 use `ilp32`.
  The D object and ESP-IDF must use the same ABI.

- **The ADC has no calibration scheme.** `ow_shim.c` gated on
  `ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED` and treated the `#else` as curve fitting; the S31
  supports neither, so those types do not exist, exactly as on the H4. Now a three-way gate, and
  the part reads raw counts until IDF ships a scheme for it.

- **Verify PSRAM initialization on hardware.** Espressif specifies 16 MB PSRAM for the
  Function-CoreBoard-1. Its BOARD profile enables octal PSRAM at the IDF default 200 MHz;
  confirm the detected size, boot memory test and external heap on the bench board.

- **802.15.4 receives; transmit is unproven, as on the C5.** With the WpanInterface of #732,
  `wpan1` on channel 15 comes up Running and counts real frames off the air while BLE and the AP
  run, so `num_wpan = 1` is right. Nothing has driven the transmit path on any part.

- **The heap's preferred pool is empty during startup.** Every object created between the
  console and the first interface logs `heap.alloc: preferred pool full, fail to default` with
  `free=0 largest=0` at `flags=2`, twice per object. Each falls back to the default pool and the
  unit runs, and the messages stop once startup settles, but a pool that is empty from boot is
  not doing its job on this part. It has not been compared against a C5 or an S3 boot.

- **LittleFS never formats the virgin storage partition.** `Corrupted dir pair at {0x0, 0x1}`
  at error level, then the unit falls back to the built-in `default.conf`, and the next boot
  logs it again identically: nothing formats the partition, so a fresh board has nowhere to keep
  a `startup.conf` or a `node.id` while `/system/sysinfo` still reports `Config: saved`. The
  partition is subtype `spiffs`, as the C5 and C6 tables also declare, while the build mounts it
  with `USE_LITTLEFS=1`. Not S31-specific: a first boot on an ESP32-P4 fails
  identically, and it fails every filesystem unit test; formatting by hand first took the P4 run
  from ~20 modules to 115. `ow_lfs_ready()` in `littlefs_port.c` latches `mount_state = -1` on
  any mount failure. Formatting on mount failure is not the fix, since that destroys a filesystem
  after a transient corruption, or a partition still holding SPIFFS. Test the medium instead:
  format only when the whole partition reads `0xFF`, log that it happened, and keep any other
  failure latched. Check where the format runs; inline during startup risks the watchdog.

### ESP32-P4 bring-up (2026-09-21)

`PLATFORM=esp32-p4` **boots and runs on a WT99P4C5-S1**: the console is interactive over the
USB_UART port, `/system/sysinfo` reports 32 MB of PSRAM in the heap, and the main loop idles at 0%
load. It built and linked against ESP-IDF v6.1 with no source change at all; the profile had been
scaffolded but never built. Release is 2,371,264 bytes, 75% of the 3 MB `ota_0` slot.

- **The P4 is two parts, and needs two platforms.** Revisions below v3.0 and from v3.0 up have
  different register maps (`soc/esp32p4/register/hw_ver1` against `hw_ver3`) and different ISA
  extensions (v3 adds `_zcb_zcmp_zcmt`; Espressif's PIE is `xespv2p1` against `xespv`), and IDF
  makes the two mutually exclusive. Espressif sells v3.x as the P4X, so `esp32-p4` is the original
  part and `esp32-p4x` the v3.x one.
  Nothing in the D half cares: it targets the base rv32imafc/ilp32f and reaches hardware through
  IDF, so one object serves both and only the sdkconfig differs. **The `esp32-p4x` platform has never
  been built against real silicon** -- no v3 part is in hand, and its profile is IDF's default.

- **The minimum-revision field catches the mismatch at flash time.** esptool refuses a v3.1 image
  on a v1.0 part before writing anything, which is how the split was found. No risk of a wrong
  image reaching a board silently.

- **The console is UART0, not USB-serial-JTAG.** The board brings the console out of a USB-C
  socket marked USB_UART through a CP2102N; the part's own USB-serial-JTAG is on GPIO24/25 and is
  not wired out. `/stream/usb-serial` still builds for the part.

- **The v3 bootloader has almost no headroom**: 0x5f40 of the 0x6000 between its offset and the
  partition table, against 0x5c30 on v1. Neither varies with `CONFIG`, since
  `BOOTLOADER_COMPILER_OPTIMIZATION` is its own Kconfig choice defaulting to size. If a v3
  bootloader feature is ever needed, the escape is `CONFIG_PARTITION_TABLE_OFFSET=0x10000`, which
  the vendor's own configuration takes.

- **The C5, when it is wired.** An ESP-HOSTED SDIO slave: CMD GPIO19, CLK GPIO18, D0-D3 GPIO14-17,
  slave reset GPIO54. The open question is whether `esp_wifi_remote` proxies
  `esp_wifi_internal_reg_rxcb` and `esp_wifi_internal_tx`; those are the only path the in-tree IP
  stack takes, so without them a hosted radio cannot feed the fabric at all.

- **Unit tests on hardware: 115 modules pass, then `urt.async` fails.** The task-create assert
  that stopped the run there is fixed (urt#315); what follows it is a D assert and a store fault,
  probably the per-fibre task stack, and everything after `urt.async` is still unreached. The
  unittest image needs the fused-slot `partitions.unittest.csv`, which takes effect with #728.


### ESP Ethernet follow-ups (2026-09-21)

`/interface/ethernet` now has an Espressif backend (`driver/baremetal/ethernet.d` over
`urt/driver/ethernet.d`), built only where a board sets `USE_ETHERNET := 1`: an EMAC is a port
only where a PHY is wired to it, so no platform turns it on and no image pays for it otherwise.
Run on a WT99P4C5-S1 (P4 v1.0, IP101GRI) up to MAC and PHY install, factory address, link-down
status and live reinstall. **No frame has crossed a wire on any part**, for want of a cable. Also open:

- **The classic ESP32 and the S31 are built, not run.** The shim assembles
  `eth_esp32_emac_config_t` per target (fixed RMII pads and APLL clock output on the ESP32,
  IO_MUX pin selection on the P4, RGMII and gigabit on the S31), and only the P4 arm has run. `BOARD=esp32-s31-function-coreboard-1` (YT8531 on RGMII, reset GPIO7, `phy=yt8531`)
  is the first gigabit and RGMII run waiting to happen, and the first of the `yt8531` setup, whose register sequence is copied from the ESP-IDF Ethernet
  example rather than derived from a datasheet.

- **No CI job compiles the driver.** `USE_ETHERNET` is off in every CI build, and the ESP jobs stop
  before the C shim links, so urt#318 passed CI with two ownership bugs a mocked-SDK probe found
  at once. Wants a board build that links the shim, and the probe kept as a host test of the
  backend: close from inside the RX callback, calls through an unopened handle, close and reopen.

- **RGMII pins are reachable from urt but not from the console.** `EthernetConfig.data_gpio`
  carries all twelve, but `/interface/ethernet` only exposes the six RMII pads as properties;
  there is no array-valued property precedent and no RGMII board to test one against. The S31
  therefore runs on the reference wiring of the part until that is added.

- **Hardware timestamps reach the packet, and nothing reads them yet.** With `hw-timestamp=true`
  the interface gains `InterfaceCaps.hw_timestamp`, `Packet.creation_time` becomes the instant the
  MAC saw the frame (the stamp projected onto `MonoTime` from one paired clock sample per service
  pass; both run off the same crystal), and the raw stamp rides in `eth.hw_time` behind
  `Packet.has_hw_timestamp`, in spare bytes of the embed union so `Packet` did not grow. The raw
  value matters once a servo steers the MAC clock away from `MonoTime`: PTP arithmetic is in the
  MAC domain. `eth_get_time`, `eth_set_time` and `eth_adjust_frequency` discipline the clock. The
  1588 unit starts on P4 v1.0 silicon; **no stamped frame has been seen**, for want of a cable.
  Using any of it needs the PTP protocol itself
  (announce/sync/follow_up/delay_req/delay_resp, BMCA, a servo) and a grandmaster; check whether
  the Pi NIC timestamps in hardware before assuming it can be one. Transmit timestamps, which
  PTP also needs, go through `esp_eth_transmit_ctrl_vargs` and are not wired. IDF marks the
  whole surface Experimental. Note the clock-domain split: PTP would discipline wall time while
  `MonoTime` free-runs, so it improves records without tightening timer scheduling unless
  `esp_eth_mac_set_target_time` is used directly, which is the interesting half: several nodes
  sampling at the same instant rather than approximately together.

- **Only ethernet headers can carry a hardware stamp.** `hw_time` lives in `Ethernet`, so a radio
  that stamps in hardware (802.15.4 does) has nowhere to put one without its own header field.

- **Only the Espressif backend reports `duplex`.** The read-only property and `router.status.Duplex`
  exist so every backend can; Linux has it in `/sys/class/net/<if>/duplex` and Windows in the adapter
  info, and neither feeds it.

- **Link detection is a 2s poll inside ESP-IDF.** Nothing of ours waits or polls, but esp_eth finds
  the link by reading the PHY status over MDIO on its own timer (`check_link_period_ms`), so a cable
  event can be 2s late. A PHY interrupt pin would make it a real edge: GPIO interrupt, then one MDIO
  read through `ETH_CMD_READ_PHY_REG`. IDF uses that pin on no PHY, so it would be ours to build,
  per board that wires it.

- **A cable pull reinstalls the MAC.** Link-down restarts the interface, as the Linux backend
  does, and shutdown closes the driver, so every replug pays a full `esp_eth_driver_install`.
  Staying installed across link loss needs offline/online without shutdown.

- **Checksum offload is built and its hardware half is unproven.** The stack leaves TCP and UDP
  checksums pending (`Packet.checksum_pending`) and whatever frames the packet completes them
  (`encode_ethernet_frame`), unless the interface declares `InterfaceCaps.tx_checksum`. Received
  frames carry `Packet.checksum_verified` where the driver says the MAC checked that frame, and the
  transports then skip the arithmetic but not the validity rules. Both directions decide per frame
  from the engine's layout coverage (urt `engine_checksums`), since esp_eth never hands over the
  descriptor's own checksum status. Still to prove on a wire:
  - TX insertion exists only on the classic ESP32. It needs store-and-forward, so the whole frame
    in the transmit FIFO: 2 KB there, 256 bytes on the P4 and 1 KB on the S31 (datasheets), whose
    datasheets list no transmit insertion at all. No classic ESP32 board with a PHY is in hand, so
    `tx-checksum=true` has never run. Capture full-MTU UDP and TCP from one and check the sums.
  - RX trust rests on esp_eth dropping `ErrSummary` frames. Send the P4 board a datagram with a
    corrupt UDP checksum (scapy) and confirm it never reaches the socket.
  - ICMP and ICMPv6 stay in software on both paths; the engines cover them but the gain is nil.
  - A pcap tap sees locally originated TCP/UDP with a zero checksum, because taps sit above framing.
  - When v4 fragmentation lands (`stack.d`, "fragment (v4) or send PTB"), it must complete a
    pending checksum before it splits, and never mark a fragment pending.
  - Linux and Windows backends could report `checksum_verified` from the kernel's view
    (`PACKET_AUXDATA` `TP_STATUS_CSUM_VALID`); they do not.

- **MAC address filtering is unused.** The interface runs promiscuous because it may be bridged.
  Not a user setting: a port that is NOT a bridge member should program the perfect filters itself
  (8 slots, one is the station address) from its own addresses plus the stack's multicast
  memberships (IGMP/MLD groups, solicited-node, mDNS, the OW discovery group), and fall back to
  promiscuous on its own whenever the set outgrows the hardware or the port joins a bridge. Needs
  `ETH_CMD_ADD_MAC_FILTER`/`ETH_CMD_DEL_MAC_FILTER` through the facade, a filter-capacity figure
  per backend, and a membership-change signal from the stack to the interface.

- **PTP is the big one.** Everything under the protocol exists: stamped RX, clock get/set/slew.
  Missing: TX timestamps, the protocol (announce/sync/follow_up/delay_req/delay_resp, BMCA, a
  servo), and a grandmaster. With a disciplined clock the MAC's PPS output (an edge on a GPIO at
  each second boundary of the 1588 clock, other rates on the P4/S31) and target-time alarm become
  worth exposing: PPS pins on two nodes under a scope measure the real sync error, and the alarm
  gives several nodes one sampling instant.

## Dated entries

Deferred work lands here as dated sections; remove a section once it is absorbed.

### 2026-08-26: profiles should express derived values instead of inventing attribute ids

An IAS Zone device reports its whole state as bits of one attribute, `0x0002` (ZoneStatus,
a `map16`). The profile has no way to say "this element is bit 3 of that attribute", so it
invents an address per bit instead:

```
zb: 0x500, 0xFC01, bool    desc: alarm2
zb: 0x500, 0xFC03, bool    desc: low_battery
```

Nothing on the device answers to `0xFC01`. Priming duly asked for those ids and the reads
came back unsupported, so a contact sensor's state could not be fetched at all; the
controller carries `apply_zone_status` to decode the real attribute by hand, priming carries
a special case for cluster `0x0500`, and both are guarded by treating `>= 0xFC00` as a
never-readable range by convention.

The shared value-spec grammar already covers this, and the mapping wants to become:

```
zb: 0x500, 0x0002, bool@0    desc: alarm1
zb: 0x500, 0x0002, bool@3    desc: low_battery
```

reading the attribute the value really lives in, with the generic decode extracting the bit.
Doing it deletes `apply_zone_status` (three callers), the priming special case and the
`0xFC00` guard, and generalises well beyond zigbee: Modbus status/alarm registers, CAN
signals (which are only ever bit offset plus width), ZCL `map8`/`map16` attributes, Tuya
bitmap datapoints and SunSpec bitfields all pack many values into one wire value.

#### Blocker: the element index holds one element per attribute

`_sample_elements` is keyed by `(eui, endpoint, cluster, attribute, manufacturer)` and
asserts one element per key:

```d
assert(key !in _sample_elements, "TODO: support element duplicates?");
```

so seven elements cannot share attribute `0x0002`. **The synthetic ids exist only to
manufacture unique keys** - that is the whole reason for them. The index has to hold a list
per key, and every write path becomes "update all matching" rather than "update the one":
`find_sample_element` and `find_sample_element_tuya` and each of their call sites in the
report, tuya-datapoint, read-response and priming paths.

#### Gotchas

- **The notification is a command, not an attribute report.** Zone Status Change
  Notification is cluster-specific command `0x00`, carrying ZoneStatus, ExtendedStatus,
  ZoneID and Delay. The generic attribute path never sees it, so the command handler must
  keep parsing the payload and writing `0x0002`'s value; only the decode downstream becomes
  generic. `apply_zone_status` today is a pure mapper of already-decoded values, called from
  the live notification, the priming read and the replay path.
- **Bit offsets are relative to the context word, and zigbee's context is not worded.**
  `container = sliced ? (ctx.worded ? ctx.word_bytes : 0) : 0`. Modbus is
  `LayoutContext(2, true, ...)`, so `bool@3` yields `container_bytes == 2`. Zigbee compiles
  against `stream_le_context` / `stream_be_context`, which are `word_bytes = 1` and not
  worded, so container is 0. IAS needs bit 9 (`battery_defect`, mask `0x200`) of a `map16`,
  i.e. a bit offset that crosses a byte. **Verify cross-byte bit offsets decode correctly in
  a byte-stream context before trusting this** - see next point.
- **No profile uses `@bit` at all.** It is implemented and unit-tested, but the unittest
  only exercises `modbus_context` (worded, 2-byte). It has never run end-to-end, and never
  in a non-worded context. First real user should expect to shake something out.
- **`0x0002` is only readable after IAS enrolment.** Proven on hardware: before enrolment
  the read was delivered and silently ignored; ~150ms after the CIE address write landed,
  the same read was answered in 123ms. So anything that reads ZoneStatus depends on
  enrolment having run first. The device never sent an `ias_zone_enroll_request`, so it
  enrols silently and the enroll request cannot be used as proof enrolment took.
- **`zone_id` and `delay` do not fit the model.** `zone_id` has a real attribute (`0x0011`)
  it could map to. `delay` exists only in the command payload with no attribute behind it at
  all, so it stays synthetic or goes.
- **`conf/profiles` is a submodule.** A profile change ships separately from the binary and
  has to be deployed to a target in its own right, so a binary that expects the new mapping
  can meet an old profile and vice versa.
