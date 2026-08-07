# Board build profiles

`PLATFORM` selects a chip family, architecture, toolchain, and peripheral
capabilities. `BOARD` selects populated hardware and product policy.

When `BOARD` is omitted, each embedded platform uses a named reference
development board. This makes `make PLATFORM=...` useful for development
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

## Espressif reference profiles

| Platform | Reference development board | Flash | PSRAM |
| --- | --- | ---: | ---: |
| `esp32` | ESP32-DevKitC V4 with ESP32-WROOM-32E | 4 MB | none |
| `esp32-s2` | ESP32-S2-DevKitC-1-N8R2 | 8 MB | 2 MB |
| `esp32-s3` | ESP32-S3-DevKitC-1-N16R8 | 16 MB | 8 MB |
| `esp32-c2` | ESP8684-DevKitC-02, 4 MB variant | 4 MB | none |
| `esp32-c3` | ESP32-C3-DevKitM-1 | 4 MB | none |
| `esp32-c5` | ESP32-C5-DevKitC-1 with N4 module | 4 MB | none |
| `esp32-c6` | ESP32-C6-DevKitC-1 | 8 MB | none |
| `esp32-h2` | ESP32-H2-DevKitM-1-N4 | 4 MB | none |
| `esp32-p4` | ESP32-P4-Function-EV-Board | 16 MB | 32 MB |

These are development defaults, not chip capabilities. A production board
must declare its fitted memory even when it happens to match the reference
profile.
