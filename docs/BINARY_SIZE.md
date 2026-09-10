# Binary Size Ledger

A loose record of deployed-image size over time, per build configuration. It exists to make
bloat visible before a target stops fitting, not to be precise. Update it opportunistically:
whenever a release build is made for any reason, append a row for that configuration. Never
run a build just to update this file.

Only release builds as they would be deployed belong here. Debug and unittest builds are
never recorded.

## How to measure

Every build prints its footprint from [tools/binstats.d](../tools/binstats.d), a host tool
the Makefile builds with the same compiler, after the link (or after `idf.py` for ESP
targets). A release build also prints a `ledger` line, which
is the row to paste here:

```
=== bin/bk7231n_release/openwatt ===
  text      952,804
  rodata    122,139
  data       10,344
  bss        61,420
  init       10,312 -> 3,408 packed (deflate), 6,904 saved
  image   1,078,400  fw.bin
  flash   1,078,400  of 1,083,040 (99%), 4,640 free
  ram        71,764
  ledger | 2026-09-09 | 62a6417e | ldc 1.43.0 | 1,078,400 | 71,764 | 1,083,040 | |
```

The tool reads the ELF or PE section table directly, so the numbers are the loaded image,
never the file on disk. `flash` is the packaged image when one exists (`fw.bin`,
`openwatt.bin`) and text+rodata+data otherwise; `ram` is data+bss. The limit comes from the
linker's `_image_limit` symbol on urt bare-metal targets and from the smallest app partition
on ESP targets. To measure an existing binary by hand:

```
bin/host/binstats bin/<outdir>/openwatt [--image bin/<outdir>/fw.bin]
```

## Row format

Each configuration has its own table, keyed by the exact make invocation. Columns:

| column | meaning |
| --- | --- |
| date | ISO date of the build |
| commit | short hash the build was made from |
| compiler | compiler and version, e.g. `ldc 1.42.0` |
| flash | packaged image size in bytes, or text+rodata+data when there is no package |
| ram | static RAM (data + bss) in bytes |
| limit | hard flash limit for the target, or `-` when there is none |
| note | one clause on what moved, if anything notable |

Platforms with a hard limit carry it in every row so the headroom is readable from the last
row alone. Sizes stay in bytes; round in the note if that reads better.

## Configurations

### x86_64 linux, `make COMPILER=ldc CONFIG=release`

| date | commit | compiler | flash | ram | limit | note |
| --- | --- | --- | --- | --- | --- | --- |

### arm64 linux (Raspberry Pi), `make ARCH=arm64 OS=linux CONFIG=release`

| date | commit | compiler | flash | ram | limit | note |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-10 | #687 | ldc 1.43.0 | 5,622,160 | 494,512 | | first row; DeviceBuilder as the only tree writer, deployed to the Pi as slot 152 |

### Waveshare ESP32-S3-RS485-CAN, `make esp-idf-build BOARD=waveshare-esp32-s3-rs485-can CONFIG=release`

Limit is the 4 MB `ota_0` partition. `ram` is internal DRAM only; PSRAM is heap.

| date | commit | compiler | flash | ram | limit | note |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-08 | 6b95c1e1 | ldc 1.42.0 | 3,190,272 | 150,049 | 4,194,304 | first row; LDC 1.43 bitcode is rejected by esp-clang 21, build with 1.42 |
| 2026-09-09 | a8c75cbf | ldc 1.42.0 | 2,831,712 | 129,561 | 4,194,304 | uRT now defaults to no exceptions, removing RTTI and exception metadata |

### SmartEVSE v3.0, `make esp-idf-build BOARD=smartevse-v30 CONFIG=release`

Limit is the stock 0x1b0000 `ota_0` partition, which the in-place migration must not change.

| date | commit | compiler | flash | ram | limit | note |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-09 | a8c75cbf | ldc 1.42.0 | 1,612,576 | 91,223 | 1,769,472 | first row; 91% of the stock partition |

### BK7231N, `make PLATFORM=bk7231n CONFIG=release`

Limit is `_image_limit` from the linker script: the packed image must fit the app slot with
the RAM-image workspace excluded.

| date | commit | compiler | flash | ram | limit | note |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-09 | 62a6417e | ldc 1.43.0 | 1,078,400 | 71,764 | 1,083,040 | first row; 99% full, 4,640 bytes of headroom |

### bl808 e907, `make PLATFORM=bl808 PROCESSOR=e907 CONFIG=release`

| date | commit | compiler | flash | ram | limit | note |
| --- | --- | --- | --- | --- | --- | --- |

Add a section for any other configuration the first time it is deployed. Keep the make
invocation in the heading exact, including FEATURES, HEADLESS, IPV6 and GATEWAY when they
differ from the defaults; a different invocation is a different table.
