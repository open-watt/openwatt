# Modular build: epic scope

Management record for issue #919. Never merges. Builds on [MODULES.draft.md](MODULES.draft.md) and
overrides it where Manu has since decided:

- modules are **nominated and their dependencies inferred** (the draft argued for cutting the closure);
- every module is **version-boxed** (`version (HasX):` at module scope) and the build enables boxes
  selectively (the draft used a string-imported manifest and `has!"x"`);
- **platforms and boards declare default sets; the command line adds and removes** with plain make
  variables.

## 0. State today (measured from the tree)

- Selection is five tiers (`FEATURES=switch|switch-ip|switch-http|switch-https|full`), nine 0/1 axes
  (`MODBUS`, `HTTP_CLIENT`, `HTTP_FILESERVER`, `IPV6`, `GATEWAY`, `RDP`, `SFP`, `HEADLESS`, `TINY`) and raw
  `BOARD_VERSIONS` (`NoECSecret`). Nothing lies between `switch-https` and `full`: `full` switches on about 25
  protocol and app packages at once (`has_all`).
- Dependencies are encoded by hand in three places that already disagree: tier dir lists in `features.mk`,
  `No*`/`Has*` inversions in `src/manager/features.d`, and the `static if` tree in `register_modules()`.
  `has_aes_gcm` ("Windows or MbedTLS") is computed in `features.d` and derived again in `features.mk` to drop
  `protocol/tesla/vehicle_*.d`. `has_file_io` repeats urt's backend list.
- `openwatt.vcxproj` lists 503 files by hand and passes no feature flags, so VS builds are "full" by accident.
- `TINY` conflates four unrelated things: `-Oz`; RAM budgets (`log.d`, `element.d`, sync peers and
  reassembly, `ip/pool.d` trie depth); feature cuts (WebDAV, the MQTT broker message cache, Tesla vehicle
  commands); and role defaults (`GATEWAY=0`, `RDP=0`). SmartEVSE (520 KB RAM) sets `TINY=1` only to save
  flash.
- `HEADLESS=1` sets `is_headless`, and **nothing in `src/` reads it**.
- `GATEWAY=0` also drops the DHCP server, and TINY forces `GATEWAY=0`. Yet the SmartEVSE and BL808 M0
  `default.conf` files both start a DHCP server on their setup AP. This looks broken on both boards (not run
  on hardware).
- SmartEVSE carries IPv6, because `IPV6` defaults to 1 and nothing turns it off.
- `FEATURES=switch` (BK7231N, STM32F4) has no IP at all, yet it carries all of `protocol/modbus`, because
  `router/iface/bridge.d` imports `ServerMap`. BK7231N is at 99% of its slot like that, so a light switch
  that needs IP, MQTT and OTA does not fit.
- Cross-module imports that block optionality (import scan):
  `manager/console/session.d -> protocol.telnet`, `manager/sync/ws_server.d -> protocol.http`,
  `manager/sync/{discovery,udp_bind}.d -> protocol.ip`, `manager/profile.d -> modbus, goodwe, http`,
  `router/iface/{package,endpoint}.d -> protocol.ip`, `router/pcap*.d -> protocol.ip.tcp_stream`,
  `router/iface/bridge.d -> protocol.modbus`, `protocol/tesla -> apps.energy`, `apps/ota -> apps.automation`,
  `protocol/tls -> protocol.http`, `protocol/zigbee -> protocol.ezsp` (unconditional, which blocks Zigbee
  on the native radio).

## 1. Taxonomy

There are three kinds of name in one namespace. The make word is lowercase snake; the D flag is
`Has<Pascal>`, which matches the existing `HasSFP`, `HasRDP`, `HasAPI` and `HasOTA`.

- **Capability**: something the platform or board provides. The urt platform block declares it and
  `board.mk` may narrow it. It is never selected, only required. Platform facts stay plain `version (X)`.
- **Module**: a selectable version box that owns its sources, its registration and its console surface.
- **Bundle**: a name that expands to a list (`full`, `switch`, `webui`). It has no box of its own.

Granularity test: make something its own module only when two real products disagree about it. Library
pieces (protobuf, expression, codecs) ride inside the module that needs them, or form a derived module that
nobody types.

### Capabilities (urt)

| cap | provided by |
| --- | --- |
| `uart` `gpio` `adc` `pwm` `i2c` `spi` | the SoC's driver exists (`urt/driver/<plat>/<cap>*.d`) |
| `can` | TWAI (esp32), bxCAN/FDCAN (stm32), socketcan (linux) |
| `eth` | EMAC+PHY (p4, s31, mt7621, stm32h7), linux, windows |
| `wifi_sta` `wifi_ap` | esp32*, bk7231, bl808 m0, bl618, linux nl80211, windows |
| `ble` | an HCI controller: esp32 (only s3 enabled today), bk7231n, bl618, linux, windows |
| `ieee802154` | esp32-c5/c6/h2 |
| `xram` | bl808 inter-core link |
| `usb_serial` | esp32 c3/c5/c6/h2/p4/s2/s3/s31 |
| `fs` | spiffs, littlefs, posix, windows |
| `threads` | freertos, posix, windows |
| `aes_gcm` `ecdsa` `tls_backend` | mbedtls (linux, esp, bouffalo) or windows bcrypt/schannel |
| `ota_slots` | two app slots plus the boot guard |
| `ip_backend` | `internal` or `lwip`; the platform chooses, not the product |

### Modules

`core` is always in. It is `manager/` minus the seams cut below (collections, console engine, element
model, log, cron, config, object_signal, record, panel), plus the `router/` base (stream, iface, packet,
bridge, vlan, queue). `minimal`, a core without `router/`, stays deferred.

| module | requires | optional (activates if also selected) | notes |
| --- | --- | --- | --- |
| `shell` | | | help, prompts, banners, completion; replaces `HEADLESS` |
| `sync` | | | binary peer protocol; a module, not core (BK7231 needs it out) |
| `sync_ws` | `sync` `websocket` | | out of `manager/sync` |
| `sync_udp` | `sync` `ip` | | transport and discovery |
| `sync_xram` | `sync` cap `xram` | | |
| `telnet` | `ip` | | registers itself as a session transport |
| `pcap` | | `ip` (server) | the zigbee encoding registers itself |
| `wifi` | cap `wifi_sta` | cap `wifi_ap` | |
| `wpan` | cap `ieee802154` | | |
| `ethernet` | cap `eth` | | |
| `i2c` `spi` | the matching cap | | |
| `sfp` | `i2c` | | |
| `ip` | cap `ip_backend` | | v4, arp, icmp, udp, tcp |
| `ipv6` | `ip` | | |
| `dhcp_client` | `ip` | `ipv6` | |
| `dhcp_server` | `ip` | | server, leases, pool; split from `gateway` |
| `gateway` | `ip` | `ipv6` | transit forwarding, firewall, RA |
| `dns` `ntp` `rdp` `snmp` | `ip` | | |
| `ppp` | `ip` cap `uart` | | |
| `tls` | cap `tls_backend` | | `manager/certificate.d` moves here |
| `http_server` | `ip` | `tls` | |
| `http_client` | `ip` | `tls` | includes the http binding |
| `websocket` | `http_server` | | |
| `http_files` | `http_server` cap `fs` | | |
| `webdav` | `http_files` | | was `!Tiny` |
| `api` | `http_server` | | |
| `ota` | `http_server` cap `ota_slots` | | the `automation` edge is cut |
| `mqtt` | `ip` | `tls` | client and binding |
| `mqtt_broker` | `mqtt` | | |
| `ha_discovery` | `mqtt` | | side-quest branch |
| `profile` | | | loader and sampler; protocol decoders register into it |
| `modbus` | cap `uart` `profile` | `ip` (tcp framing) | ServerMap out of `bridge.d` |
| `sunspec` | `modbus` | | |
| `goodwe` | cap `uart` `profile` | `ip` | |
| `can` | cap `can` | | |
| `obd` | `can` | | |
| `ezsp` `cpc` `spinel` | cap `uart` | | |
| `zigbee` | one of `ezsp` `spinel` `wpan` | | needs the ezsp edge cut |
| `ble` | cap `ble` | | |
| `tesla_twc` | cap `uart` | | |
| `tesla_vehicle` | `ble` cap `aes_gcm` | | the `apps.energy` edge is cut |
| `esphome` | `ip` | | |
| `gpio` | cap `gpio` | | relay, button, light bindings |
| `automation` | | | |
| `energy` | `profile` | | 10k lines; the largest app |
| `db` | | cap `threads` | |
| `board_smartevse` `rtc_pcf85063` `power_regulator` `meter_hlw8012` | their caps | | named only by a `board.mk` |

## 2. Mechanism: version boxes, registry, inference

### The box

Every source file of module `mqtt` starts like this:

```d
module protocol.mqtt.client;
version (HasMQTT):

import urt.string;
...
```

The box comes before the imports, so a module that is not selected imports nothing and emits nothing: no
code, no `ClassInfo`, no init blob. That removes the draft's `--gc-sections`/`m_init` objection without
any source-list surgery. Optional edges nest inside the box: `version (HasTLS) { ... }`. A `has_*` enum
survives only where a value has to feed an expression, and then only as the generated mirror described
below, never as a hand-maintained list.

### File inclusion follows the flags

The compile always takes the whole of `src/`. The boxes do the excluding, so `FEATURE_DIRS`,
`FEATURE_EXCLUDES` and the tier dir lists go away, and VS compiles the same file set as make. The cost is
parse time for the empty files, which is small next to a whole-program LDC build (to be measured in PR 2).
urt C shims and vendor blobs are the exception: make still selects those per cap, using the same resolved
list.

### Registration follows the flags

`register_modules()` imports and registers every module unconditionally. In a module that is boxed out,
`Modules!mod` is empty and registers nothing (its "no Module" warning becomes silent). The hand-maintained
`static if` tree in plugin.d disappears. Order constraints, where they exist, live in the registry.

### The registry, the only place dependencies are written

`modules.mk` lives at the repo root, beside a urt sibling `third_party/urt/modules.mk` for caps and urt
modules. Each module has one line:

```make
$(call module, mqtt,          MQTT,         ip,             tls)
$(call module, tesla_vehicle, TeslaVehicle, ble cap_aes_gcm, )
$(call bundle, switch,        wifi wpan ethernet sync shell)
```

The fields are name, D flag, requires and optional. Caps are declared by the urt platform block in one
place, for example `CAPS += $(if $(filter 1,$(USE_MBEDTLS))$(filter windows,$(OS)),aes_gcm tls_backend)`.
That one line replaces both copies of "Windows or MbedTLS".

### Inference

The final set is computed as a closure over requires (a small fixpoint in make over about 50 names). It is
then checked against `CAPS`, and `optional` edges switch on only when both ends are already in the set.
The output is `$(addprefix -version=Has,...)` over the resolved flags. `make explain-modules` prints each
module and why it is in (platform, board, WITH, or "required by X").

### Drift guard

`tools/modlint.d` is a host tool built like `binstats`. It fails in two cases. First, when a file under a
module's directory does not open with that module's box. Second, when a top-level import inside box A
names module B while B is in neither A's requires nor A's optional list, or when an optional import is not
nested in `version (HasB)`. This answers the draft's objection that a declared table drifts: the table is
checked against the code on every make. A third check compares the vcxproj file list with `src/`.

### Generated outputs (write-if-changed, at parse time; the draft's rebuild contract)

| output | for |
| --- | --- |
| `-version=Has*` in DFLAGS | D |
| `$(OBJDIR)/build.sig` | rebuild on any DFLAGS change (fixes "make clean between FEATURES") |
| `$(OBJDIR)/ow_modules.h` | C shims |
| `$(OBJDIR)/modules_list.d` | the `has_*` mirror plus the module list, for console `/system/modules` |
| `build/windows.props` | VS `VersionIdentifiers` for the windows default set; committed, and modlint checks it |

## 3. Selection: platform, then board, then command line

Plain make. A command-line assignment overrides the makefile's own value of that variable, so users never
assign the default variables. Two variables are reserved for the command line and are never assigned in
any makefile (none of these names is in use today):

| variable | set by | meaning |
| --- | --- | --- |
| `PLATFORM_MODULES` | urt platform block | the chip default (`full` on hosts) |
| `BOARD_MODULES` | `board.mk`, with `:=` | replaces the platform default; may name bundles and reference `$(PLATFORM_MODULES)` |
| `MODULES` | command line only | replaces the whole default set outright |
| `WITH` | command line only | added on top of whichever default won |
| `WITHOUT` | command line only | removed after closure |

```
make BOARD=smartevse-v30 WITH="ocpp" WITHOUT="shell"
make PLATFORM=esp32-c6 WITH=zigbee
make PLATFORM=linux MODULES="switch sync_udp"
```

Resolution:

1. Take `MODULES` if it was given, else `BOARD_MODULES` if a board is set, else `PLATFORM_MODULES`.
2. Expand bundles, then add `WITH`.
3. Close over requires.
4. Remove `WITHOUT`. If anything still in the set requires a removed module, that is an **error that prints
   the chain** (`WITHOUT=ip: required by mqtt (board default) <- ha_discovery (WITH)`). Nothing is silently
   added back.
5. Check against caps. A missing cap is an error that names the board and the cap.
6. Unknown names are an error with a near-match suggestion.

A board's default set therefore lives in exactly one line of its `board.mk`.

### Retirement of the old variables

They stay for one release as shims that map onto `WITH`/`WITHOUT` and print a warning, then they are deleted.

| old | new |
| --- | --- |
| `FEATURES=switch` and the other tiers | bundles: `MODULES=switch` |
| `HEADLESS=1` | `WITHOUT=shell` |
| `MODBUS=0`, `HTTP_CLIENT=0`, `HTTP_FILESERVER=0`, `IPV6=0`, `RDP=0` | `WITHOUT=modbus` and so on |
| `GATEWAY=0` | `WITHOUT=gateway` (the DHCP server stays) |
| `SFP=1` | `WITH=sfp`, or in `BOARD_MODULES` |
| `BOARD_VERSIONS=NoECSecret` | `WITHOUT=ec_secret` |
| `TINY` | section 4 |

## 4. What replaces TINY

There are three independent knobs, and none of them selects features:

| knob | values | drives | default from |
| --- | --- | --- | --- |
| `OPT` | `size` `speed` | `-Oz` vs `-O2`/`-O3` | the board's slot size |
| `TERSE` | 0/1 | verbose error strings, enum display names, long help text (help itself is `shell`) | the board's slot size |
| `MEM_CLASS` | `tiny` `small` `large` | every RAM budget constant, via `urt.features.mem_class` | `BOARD_RAM_SIZE` + PSRAM |

What happens to each `version (Tiny)` site today:

- The budgets in `log.d`, `element.d`, `sync/package.d`, `sync/peer.d`, `ip/pool.d` and `mqtt/broker.d` move
  to `mem_class`.
- WebDAV becomes the `webdav` module.
- The Tesla vehicle command gate is deleted: a product that cannot afford those commands does not select
  `tesla_vehicle`.
- `GATEWAY=0` and `RDP=0` as defaults become "not in the board set".
- urt's `exception.d` Tiny gate moves to `TERSE`.

The memory classes are three discrete values rather than a continuous budget, so each class is a tested
configuration.

## 5. Product profiles

Two x86-64 LDC release builds of master were attributed by D symbol prefix. The table below gives the
selectable modules' cost, scaled to Thumb/RV32 at 0.42 to 0.6x. The low end comes from RP2350 `full` at
1.66 MB against x86-64 at about 3.96 MB without `driver.linux`; the high end allows for ESP builds. These
are lower bounds, because template instances often mangle under the template's module.

| module (x86-64 KB) | | | | | |
| --- | --- | --- | --- | --- | --- |
| sync 275 | energy 237 | router.iface 144 | ip (in-tree) 142 | http 126 | zigbee 124 |
| mqtt 122 | console 109 | tesla 96 | tls 90 (+ backend) | modbus 83 | dhcp 56 |
| profile 45 | ble 44 | obd 33 | api 29 | esphome 27 | ezsp 22 |
| cpc 21 | can 18 | gpio 18 | telnet 18 | goodwe 17 | automation 14 |

Anchors with a *ledger* note come from [BINARY_SIZE.md](../BINARY_SIZE.md). Everything else is the
nearest anchor plus or minus module deltas at about 0.5x. Expect +-25%.

| product | modules (beyond `core`) | must not carry | estimate vs limit |
| --- | --- | --- | --- |
| **Pi gateway** (arm64 linux) | `full` + `ethernet` `wifi` `ble` `can` `sfp` | - | 5.83 MB *ledger*; no limit |
| **SmartEVSE v3** (esp32, 4 MB, no PSRAM) | `board_smartevse` `wifi` `ip` `dhcp_client` `dhcp_server` `http_server` `websocket` `tls` `api` `ota` `sync_ws` `sync_udp` `modbus` (meter) + a future `ocpp` | `ipv6` `gateway` `shell` `http_files` `mqtt_broker` `energy` `pcap` | today 1.68 / 1.77 MB *ledger*; + modbus 40 + ocpp ~50, - ipv6 ~30 - shell/TERSE ~30 -> ~1.71 MB. Fits only if those cuts land first |
| **Inverter dongle** (esp32-c3 class, 4 MB, OTA) | `wifi` `ip` `dhcp_client` `dns` `ntp` `modbus` `sunspec` `goodwe` `profile` `mqtt` `tls` `http_server` `api` `ota` `sync_udp` | `gateway` `dhcp_server` (except a setup AP) `ipv6` `zigbee` `ble` `tesla_*` `can` `energy` `mqtt_broker` `webdav` `shell` | SmartEVSE anchor - board + modbus/sunspec/goodwe ~55 + mqtt ~60 -> ~1.80 MB against a 1.9 MB slot (the c3 table gives up OTA for `full` today) |
| **BK7231N plug / light switch** (2 MB, 256 KB RAM) | `wifi` `ip` `dhcp_client` `mqtt` `ha_discovery` `gpio` `http_server` `ota`; plug adds `meter_hlw8012` | `modbus` (in `switch` today) `sync` `shell` `pcap` `sfp` `i2c` `rdp` `tls` `ipv6` `api` | today `switch` (no IP) 1,078 / 1,083 KB *ledger*. + ip/dhcp ~100, mqtt ~60, http/ota ~70; - modbus ~40, sync ~140, shell/TERSE ~40 -> roughly break-even. **Fits only if `sync` is optional** |
| **BL808 M0 as L2 coprocessor** | `wifi` `wpan`? `sync` `sync_xram`, `WITHOUT=shell` | `ip` and everything above it | today's M0 (network node) ~1.64 MB *ledger*; L2-only estimated 0.7-0.9 MB |
| **ESP32-C6 Zigbee + WiFi** (802.15.4 native) | `wpan` `zigbee` `wifi` `ip` `dhcp_client` `http_server` `websocket` `api` `ota` `sync_ws` `mqtt` | `ezsp` `energy` `tesla_*` `ble` `can` `modbus` | C5 `full` 3.20 / 3.5 MB *ledger* - energy ~120 - tesla/ble/obd/can ~95 -> ~2.95 MB |
| **ESP32-H2 RCP** (802.15.4 only) | `wpan` `spinel` (server side, not yet written) `sync`, `WITHOUT=shell` | `ip` and everything above it | H2 `switch` 1.03 / 1.90 MB *ledger*; should drop with `shell` and `TERSE` |

Two readings:

- On tight targets the levers that matter are `sync`, `shell`/`TERSE`, `ipv6` and the `switch`-carried
  `modbus`, not the exotic protocols, which those products never had.
- The ESP-IDF base (WiFi blob, lwIP, mbedtls) is a fixed ~1 MB on ESP targets that no module selection can
  touch.

## 6. Migration (each PR lands alone, in order)

1. **`build.sig`**: rebuild on any change to DFLAGS or the source set. Independent, and it removes a wart now.
2. **Registry, closure, `WITH`/`WITHOUT`, caps**: with no behaviour change. Today's tiers and axes become
   bundles and shims that emit exactly today's flags (byte-identical images); "Windows or MbedTLS" and the
   fs backends are declared once as caps. Measure parse-time cost of compiling all of `src/`.
3. **`modlint`** in make and CI.
4. **Box the already-clean modules** (those with no inbound edges from core): energy, zigbee+ezsp, tesla,
   esphome, obd, can, cpc, spinel, snmp, goodwe, gpio, ppp, ntp, dns. In the same PR, plugin.d registers
   everything unconditionally and the `has_all` tree goes.
5. **TINY split** into `OPT`, `TERSE` and `MEM_CLASS`.
6. **`shell`** replaces `HEADLESS` and actually gates something.
7. **`dhcp_server` split from `gateway`**, fixing the SmartEVSE and M0 setup AP.
8. Seam cuts, one PR each. Each makes one module boxable, and each records a ledger row:
   - telnet as a session transport;
   - `sync_ws` and `sync_udp` out of `manager/sync`, then `sync` itself boxable;
   - a profile decoder registry (modbus, goodwe and http out of `profile.d`);
   - `ServerMap` out of `bridge.d`;
   - a pcap encoder registry;
   - `certificate.d` into `tls`;
   - cut `tesla -> energy`, `ota -> automation`, `zigbee -> ezsp` and `router/iface -> protocol.ip`.
9. **Board modules and `BOARD_MODULES` on every board**: rtc, regulator and smartevse named by `board.mk`;
   the `FEATURES` shims deleted; ledger sections rekeyed by board.
10. **urt granularity** (a paired urt PR): driver sources selected per cap instead of globbed.

PRs 1-3 build the platform. PRs 4-7 are cheap wins. PR 8 is the long tail and can run in parallel.

## 7. Open questions for Manu

1. Flag spelling: `HasMQTT` (matching `HasSFP`/`HasRDP`), or a prefix that cannot collide with platform
   versions, such as `Mod_mqtt`?
2. Compile all of `src/` and let the boxes exclude, or keep make-side file selection as a compile-time
   optimisation? This decides whether VS and make see the same file set.
3. Is `sync` optional? BK7231N does not fit otherwise.
4. Where does the registry live: one root `modules.mk`, or a `module.mk` per directory?
5. BL808 M0's role: today it is the network node (AP, IP, HTTP, API, OTA, telnet, pcap) with D0 as a sync
   member. The brief calls it an L2-only headless coprocessor. Which is the target?
6. `ip` as one module, or a separate `tcp` for UDP-only sync nodes?
7. `MEM_CLASS` as three classes, or numeric budgets from `BOARD_RAM_SIZE`?
8. Was losing the DHCP server on TINY targets intended?
