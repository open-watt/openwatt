---
name: esp32-port
description: Espressif (ESP32) platform port -- build, flash, debug, WiFi shim, lwIP quirks, sdkconfig, and known pitfalls. Use when working on any ESP32 variant, fixing embedded issues, or debugging the WiFi/networking stack on Espressif hardware.
---

# Espressif Platform Skill

You are working on Espressif ESP32 platform support for OpenWatt. All ESP32 variants run FreeRTOS with ESP-IDF v6.0, using LDC to cross-compile D. Xtensa variants (ESP32, ESP32-S2, ESP32-S3) require a two-stage bitcode build via Espressif's llc fork due to upstream LLVM bugs. RISC-V variants (ESP32-C3, C6, H2) compile directly with LDC.

The current dev board is an ESP32-S3 with 8MB octal PSRAM and 16MB flash, connected via native USB Serial/JTAG (no UART bridge chip).

## Build & Flash

### Build process

The D code compiles to an object file, then ESP-IDF links it with the C runtime. On Xtensa targets, LDC emits LLVM bitcode which Espressif's llc compiles to native code (see `platforms/esp32s3/LLVM_BUG_*.md` for why). RISC-V targets compile directly.

```bash
# 1. Compile only D code (from WSL)
make PLATFORM=esp32-s3 CONFIG=release    # or CONFIG=unittest

# 2. Compile and link with ESP-IDF (from WSL, needs IDF environment)
source /home/[user]/.espressif/release-v6.0/esp-idf/export.sh
make esp-idf-build PLATFORM=esp32-s3 CONFIG=release

# Full clean rebuild (needed when sdkconfig.defaults changes)
rm -rf platforms/esp32s3/build platforms/esp32s3/sdkconfig
make esp-idf-build PLATFORM=esp32-s3 CONFIG=release
```

### Flash from Windows PowerShell

The dev board connects via USB Serial/JTAG to Windows. Flash addresses must match the partition table.

```powershell
python -m esptool --chip esp32s3 -p COM5 -b 460800 write_flash 0x0 bin\esp32-s3_release\bootloader.bin 0x8000 bin\esp32-s3_release\partition-table.bin 0x10000 bin\esp32-s3_release\ota_data_initial.bin 0x20000 bin\esp32-s3_release\openwatt.bin
```

### Serial monitor

```powershell
python -m serial.tools.miniterm COM5 115200
```

On boards with native USB Serial/JTAG, the COM port drops on reset (USB re-enumerates). Bootloader output is lost unless you reconnect fast. The unit test build calls `abort()` after tests to create a crash/reboot loop so output is visible.

## Platform Files

Each ESP32 variant has a platform directory under `platforms/`:

- `platforms/esp32s3/sdkconfig.defaults` -- ESP-IDF configuration
- `platforms/esp32s3/partitions.csv` -- flash partition layout
- `platforms/esp32s3/system.conf` -- string-imported system config (baked into binary)
- `platforms/esp32s3/main/CMakeLists.txt` -- component registration, links D object

Shared C code for all Espressif targets:

- `third_party/urt/src/sys/esp32/main.c` -- C entry point, NVS init, watchdog task
- `third_party/urt/src/sys/esp32/ow_shim.c` -- C shim for UART, WiFi, TWAI, lwIP wrappers

## sdkconfig.defaults

Key settings for the ESP32-S3 board (other variants may differ):

- `CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y` -- boards with native USB need this or all output is invisible. Boards with a UART bridge use `CONFIG_ESP_CONSOLE_UART_DEFAULT=y` instead.
- `CONFIG_LOG_DEFAULT_LEVEL_NONE=y` -- OpenWatt has its own log system.
- `CONFIG_COMPILER_CXX_EXCEPTIONS=y` -- required for D exception unwinding.
- `CONFIG_FREERTOS_UNICORE=y` -- single-core mode (ESP32-S3 specific; single-core chips don't need this).
- `CONFIG_SPIRAM=y` -- external PSRAM (board-specific).
- `CONFIG_ESP_TASK_WDT_INIT=n` -- we run our own watchdog.
- `CONFIG_PARTITION_TABLE_CUSTOM=y` -- custom OTA-capable partition table.

## Architecture: app_main and D main

ESP-IDF calls `app_main()` after FreeRTOS starts. Our `app_main` in `main.c`:

1. Initializes NVS (required by WiFi for calibration data)
2. Initializes lwIP (`esp_netif_init`) and event loop (`esp_event_loop_create_default`)
3. Starts the software watchdog task
4. Calls D `main()` which never returns (runs the OpenWatt main loop)

The D main loop calls `ow_watchdog_feed()` each frame. If the feed stops for 5 seconds, the watchdog aborts (crash + reboot).

## lwIP Socket Quirks

These apply to all Espressif targets (all use lwIP):

### Non-blocking sockets: use ioctlsocket, not fcntl

lwIP's `fcntl(F_SETFL)` rejects the call if any bits besides `O_NONBLOCK` are set. The standard POSIX pattern (`fcntl(F_GETFL)` then `F_SETFL` with OR'd flags) fails because `F_GETFL` returns access mode bits that lwIP doesn't accept back. Fix: use `ioctlsocket(FIONBIO)` on lwIP instead. See `urt/socket.d` around the `SocketOption.non_blocking` handling.

## WiFi Shim (ow_shim.c)

The C shim wraps ESP-IDF WiFi APIs for the D code. These apply to all WiFi-capable Espressif chips.

- `ow_wifi_init/deinit` -- ref-counted. First init calls `esp_wifi_init`, registers event handlers, creates netifs. Netifs are created eagerly in init (not lazily in sta_config/ap_config) so `esp_netif_receive` always has valid targets.
- `ow_wifi_start/stop` -- wraps `esp_wifi_start/stop`.
- `ow_wifi_set_mode` -- wraps `esp_wifi_set_mode`. Safe to call while running; dynamically adds/removes STA/AP interfaces without full restart.
- `ow_wifi_sta_config/ap_config` -- configures STA/AP parameters.
- `ow_wifi_sta_connect/disconnect` -- async; fires events when complete.
- `ow_wifi_set_sta_callback/ap_callback` -- set D-side event handlers.
- `ow_wifi_set_rx_callback` -- registers raw Ethernet frame RX handlers via `esp_wifi_internal_reg_rxcb`.
- `ow_wifi_tx` -- transmits raw Ethernet frames via `esp_wifi_internal_tx`.

### WiFi Event Flow

Events flow: ESP event task -> `ow_wifi_event_handler` (C) -> `ow_wifi_sta_cb`/`ow_wifi_ap_cb` function pointers -> D callback functions (`esp_sta_event`/`esp_ap_event` in wifi.d) which set global flags -> main loop polls flags in `startup()`.

Key events: `WIFI_EVENT_STA_CONNECTED` (4), `WIFI_EVENT_STA_DISCONNECTED` (5), `WIFI_EVENT_AP_START` (12), `WIFI_EVENT_AP_STOP` (13).

## WiFi D-side Architecture (wifi.d)

### WiFiInterface (radio)

Manages the ESP WiFi driver lifecycle. Goes to Running after `ow_wifi_init` + `ow_wifi_start`. Tracks `_esp_started` flag so `bind_wlan` can call `update_esp_mode()` even before the radio reaches Running state. Also calls `update_esp_mode()` at end of startup to set mode based on already-bound interfaces.

### WLANBaseInterface (shared STA/AP base)

Binds to radio BEFORE checking `radio.running` (avoids chicken-and-egg with mode setting). The `radio_state_change` handler only calls `restart()` when `running` -- during `starting`, the startup loop naturally stalls on `!radio.running`.

### WLANInterface (STA client)

Async startup: calls `ow_wifi_sta_connect()` then returns `continue_`. Polls `esp_sta_connected` / `esp_sta_disconnected` flags on subsequent startup calls. Goes to Running only on `STA_CONNECTED`. Has `update()` override that restarts on disconnect while running.

### APInterface (access point)

Async startup: calls `ow_wifi_ap_config()` then returns `continue_`. Polls `esp_ap_started` / `esp_ap_stopped` flags. Goes to Running only on `AP_START`.

### Status Messages

All WiFi objects override `status_message()` for user-facing diagnostics:
- "Waiting for radio" -- STA/AP starting, radio not yet online
- "Connecting" -- STA connect initiated, waiting for association
- "Starting AP" -- AP config sent, waiting for AP_START
- "Association failed" / "Disconnected" -- STA failure states
- "AP failed to start" -- AP startup failure
- "STA/AP config rejected by driver" -- ESP-IDF rejected the configuration

## Unit Tests on Embedded

`version (FreeStanding)` calls `abort()` after unit tests complete. This creates a crash/reboot loop so test output is visible (on USB Serial/JTAG boards, the port drops on clean exit making output invisible).

## Session Output on Embedded

When a console Session has no stream attached (embedded boot with no interactive console), `write_output` falls back to `writeInfo("session: ", text)`. This surfaces command errors in the log instead of silently dropping them.

## Common Pitfalls

- **Always full-clean rebuild** when changing `sdkconfig.defaults` -- the bootloader and partition table must be rebuilt too.
- **Flash addresses must match the partition table** -- check `partitions.csv` for correct offsets.
- **esp_wifi_set_mode() is non-destructive** -- changing mode (e.g. STA -> APSTA) starts/stops individual interfaces without resetting the whole driver. Downstream interfaces don't need to restart on mode changes.
