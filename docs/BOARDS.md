# Board build profiles

`PLATFORM` selects a chip family, architecture, toolchain, and peripheral
capabilities. `BOARD` selects populated hardware and product policy.

When `BOARD` is omitted, each embedded platform uses a reference development
configuration. This makes `make PLATFORM=...` useful for development
without pretending that every product using the same chip has the reference
board's flash or external RAM.

When `BOARD` is present, its `board.mk` supplies the default platform. A
command-line `PLATFORM` still wins:

```text
make BOARD=smartevse-v30
make BOARD=smartevse-v30 PLATFORM=esp32
```

## Board directory

A board lives at `platforms/<family>/boards/<name>/` and contains:

- `board.mk`, required. It declares `BOARD_PLATFORM`, `BOARD_FLASH_SIZE`, and
  `BOARD_PSRAM_SIZE`. Product defaults such as `FEATURES`, `HEADLESS`, `TINY`,
  and `VERSIONS` also belong here. Use `?=` for values users may override.
- `system.conf`, required. It replaces the platform's baked-in startup script.
- `sdkconfig.defaults`, required for Espressif boards. ESP-IDF applies it after
  the platform defaults, so board values override the reference development
  board.
- `partitions.csv`, optional. If present, the board's `sdkconfig.defaults`
  selects it with a project-relative path such as
  `boards/example/partitions.csv`.

`BOARD_FLASH_SIZE` and `BOARD_PSRAM_SIZE` are the canonical hardware limits
visible to the Make build. The vendor configuration must express the same
limits. For ESP-IDF this means the flash-size and PSRAM settings in the board
`sdkconfig.defaults`, plus a partition table which does not exceed the fitted
flash.

ESP-IDF output and generated `sdkconfig` files live below the board-specific
OpenWatt object directory. Building two boards therefore cannot reuse one
another's generated configuration.

## ESP core-dump builds

`COREDUMP=1` is an opt-in diagnostic feature for ESP32-S3, S31, C5 and C6. It selects
the platform's coredump partition table, reserving 512 KiB of flash, and places
the result in a separate `*_coredump` build directory:

```bash
make esp-idf-build PLATFORM=esp32-s3 CONFIG=debug COREDUMP=1
```

Use this only for a board compatible with that partition layout, and flash the
partition table together with the coredump-enabled image. The normal
`COREDUMP=0` build keeps the full storage partition.

## Supported boards

Board profiles in the tree. Build with `make esp-idf-build BOARD=<name> CONFIG=release`; the
output lands in `bin/<platform>_<board>_<config>/`. Each board's `system.conf` wires its
peripherals and its `default.conf` brings up the HTTP API, sync, OTA and file server, so a fresh
unit is reachable before it has any credentials. Boards with a radio also open a setup access
point; a board without one is reachable over its console until a `startup.conf` gives it a
network.

| Board | `BOARD=` | Platform | Flash | PSRAM |
| --- | --- | --- | ---: | ---: |
| SmartEVSE v3.0 | `smartevse-v30` | `esp32` | 4 MB | none |
| Waveshare ESP32-S3-RS485-CAN | `waveshare-esp32-s3-rs485-can` | `esp32-s3` | 16 MB | 8 MB |
| ESP32-S31-Function-CoreBoard-1 | `esp32-s31-function-coreboard-1` | `esp32-s31` | 16 MB | 16 MB |
| Wireless-Tag WT99P4C5-S1 | `wt99p4c5-s1` | `esp32-p4` | 16 MB | 32 MB |

**ESP32-S31-Function-CoreBoard-1** enables the fitted 16 MB octal PSRAM at 200 MHz.
Its setup AP is at `192.168.1.1`. The board's Ethernet port remains unsupported.
Espressif documents its fitted memory on the [S31 board page](https://esp32-s31.espressif.com/en).

**SmartEVSE v3.0** replaces the stock SmartEVSE firmware in place. The build is `switch-http`,
headless and tiny, with Modbus, the HTTP client and the file server compiled out, and the
`SmartEVSE` version set selects the EVSE hardware driver (`/driver/boards/smartevse`), its
binding, the front panel, and RS485 on UART1. The image is app-only: it retains the stock partition
table, NVS and SPIFFS, is uploaded through the stock web interface's `/update` page, and the open
`OpenWatt-SmartEVSE` access point accepts a stock `firmware.bin` back through `/ota` to return the
unit. The full procedure is in
[platforms/esp32/boards/smartevse-v30/MIGRATION.md](../platforms/esp32/boards/smartevse-v30/MIGRATION.md).

**Waveshare ESP32-S3-RS485-CAN** is the reference industrial gateway board: RS485 on UART1, CAN
through the TWAI controller, a PCF85063 RTC on I2C that seeds system time at boot (`startup.conf`
waits on `object:rtc?state=online` before proceeding), the USB-serial console, LittleFS storage,
and WiFi running access point and station concurrently alongside BLE scanning. Its setup access
point is WPA2 (`OpenWatt-Waveshare`, password `openwatt-setup`) and it also opens a telnet
console.

**Wireless-Tag WT99P4C5-S1** is a WT0132P4-A1 module (ESP32-P4 N16R32, 16 MB flash and 32 MB HEX
PSRAM) on a carrier with a 10/100 Ethernet port, an ESP32-C5-WROOM-1 for Wi-Fi 6, BLE and
802.15.4, RS485, an SD slot and MIPI DSI/CSI connectors. `BOARD=` matters more than usual here:
it selects `esp32-p4`, and an `esp32-p4x` image will not boot this one. The console is
UART0 out of the USB-C marked USB_UART. **Neither the EMAC (IP101GRI on the RJ45) nor the C5 has a
driver yet**, so the board has no network; both pin maps are recorded in `system.conf`.

## Espressif reference profiles

| Platform | Reference development board | Flash | PSRAM |
| --- | --- | ---: | ---: |
| `esp32` | ESP32-DevKitC V4 with ESP32-WROOM-32E | 4 MB | none |
| `esp32-s2` | ESP32-S2-DevKitC-1-N8R2 | 8 MB | 2 MB |
| `esp32-s3` | ESP32-S3-DevKitC-1-N16R8 | 16 MB | 8 MB |
| `esp32-s31` | Generic S31 development configuration | 16 MB | none |
| `esp32-c2` | ESP8684-DevKitC-02, 4 MB variant | 4 MB | none |
| `esp32-c3` | ESP32-C3-DevKitM-1 | 4 MB | none |
| `esp32-c5` | ESP32-C5-DevKitC-1 with N8R8 module | 8 MB | 8 MB |
| `esp32-c6` | ESP32-C6-DevKitC-1 with 16 MB flash | 16 MB | none |
| `esp32-h2` | ESP32-H2-DevKitM-1-N4 | 4 MB | none |
| `esp32-p4` | WT0132P4-A1 module | 16 MB | 32 MB |
| `esp32-p4x` | ESP32-P4X-Function-EV-Board | 16 MB | 32 MB |

The ESP32-P4 needs two platforms because it is two parts. Revisions below v3.0 and
from v3.0 up have different register maps and different ISA extensions, and ESP-IDF
makes supporting them mutually exclusive. Espressif sells the v3.x part as the ESP32-P4X, so
`esp32-p4` is the original silicon and `esp32-p4x` the v3.x one. Neither image boots the other's silicon, and the
bootloader's minimum-revision field refuses it at flash time rather than at boot.
Read the revision off the part with `esptool chip-id` before choosing.

These are development defaults, not chip capabilities. A production board
must declare its fitted memory even when it happens to match the reference
profile.

The generic S31 configuration assumes 16 MB external flash and no PSRAM. Both
the platform and Function-CoreBoard-1 profiles create the chip's `wifi1` and
`wpan1` radios; set `wpan1`'s channel before using the 802.15.4 radio.

The H2 profile creates the chip's `wpan1` radio the same way; it has no WiFi.

The C5 and C6 layouts use two 3.5 MiB OTA slots, and the H2 two 1.8125 MiB slots with a
256 KiB LittleFS partition at the top of its 4 MB. When migrating from the old
layouts, back up filesystem contents and flash the new partition table and
application together; an app-only OTA cannot update the table. Reformat and
restore the moved filesystem. The NVS, PHY and OTA metadata offsets are unchanged.
