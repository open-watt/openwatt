# Modular build: epic scope

Management record for issue #919. Never merges. Builds on [MODULES.draft.md](MODULES.draft.md) and
overrides it where Manu has since decided:

- modules are **nominated and their dependencies inferred** (the draft argued for cutting the closure);
- every module is **version-boxed** (`version (mqtt):` at module scope) and the build enables boxes
  selectively (the draft used a string-imported manifest);
- **platforms and boards declare default sets; the command line adds and removes** with plain make
  variables.

## 0. State today (measured from the tree)

- Selection is five tiers (`FEATURES=switch|switch-ip|switch-http|switch-https|full`), nine 0/1 axes
  (`MODBUS`, `HTTP_CLIENT`, `HTTP_FILESERVER`, `IPV6`, `GATEWAY`, `RDP`, `SFP`, `HEADLESS`, `TINY`) and raw
  `BOARD_VERSIONS` (`NoECSecret`, `SmartEVSE`). Nothing lies between `switch-https` and `full`: `full`
  switches on about 25 protocol and app packages at once (`has_all`).
- Dependencies are encoded by hand in three places that already disagree: tier dir lists in `features.mk`,
  `No*`/`Has*` inversions in `src/manager/features.d`, and the `static if` tree in `register_modules()`.
  "Windows or MbedTLS" is written twice (`features.d`, `features.mk`). The fs backend list is written four
  times: `has_file_io` (`features.d`), `has_boot_store` (`bootguard.d`), and `HasFilesystem` in both
  `manager/package.d` and `manager/system.d`.
- `openwatt.vcxproj` lists 503 files by hand and passes no feature flags, so VS builds are "full" by accident.
- `TINY` conflates four unrelated things: `-Oz`; RAM budgets (`log.d`, `element.d`, sync peers and
  reassembly, `ip/pool.d` trie depth); feature cuts (WebDAV, the MQTT broker message cache, Tesla vehicle
  commands); and role defaults (`GATEWAY=0`, `RDP=0`). SmartEVSE (520 KB RAM) sets `TINY=1` only to save
  flash.
- `HEADLESS=1` sets `is_headless`, and **nothing in `src/` reads it**. `ExcludeHelpText` and
  `ExcludeAutocomplete` are commented out in `command.d` and set by nothing. `NoSwitch` is set by no build.
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
  `router/iface/package.d -> protocol.ip, router.iface.{udp,vlan,endpoint}, router.pcap`,
  `router/iface/endpoint.d -> protocol.ip`, `router/pcap*.d -> protocol.ip.tcp_stream`,
  `router/iface/bridge.d -> protocol.modbus`, `protocol/tesla -> apps.energy`, `apps/ota -> apps.automation`,
  `protocol/tls -> protocol.http`, `protocol/zigbee -> protocol.ezsp` (unconditional, which blocks Zigbee
  on the native radio).

## 1. Taxonomy

- **Capability**: something the platform or board provides. Never selected, only required.
- **Module**: a selectable key with requires. Most also own files, behind their version box, with their
  registration and console surface. A module that owns no files and is only its requires is an
  **umbrella**: `dhcp` is `dhcp_client dhcp_server`, `ip` is `inet udp tcp`. There is no separate bundle
  concept; `full` and `l2` are umbrellas too.

Granularity test: make something its own module only when two real products disagree about it. Library
pieces (protobuf, expression, codecs) ride inside the module that needs them.

A module either owns files or is an umbrella. A name that only gates scattered branches inside other
modules is neither: it becomes an umbrella over real modules, or the branches are consolidated into a file
that the name then owns. The review named four names that fail this test.

### `router`, `console`, `switch`, `gateway`

**`router` is not a module.** `router/` is two things. Its base is core: `Stream`, `BaseInterface`,
`EthernetStation`, `Packet`, `mac`, `priority_queue`, `address_table`, `checksum`, `status`, `port`,
`group`, and the generic streams (`memory`, `duplex`, `bridge`, `console`, `file`). Every module above it
derives from those, and no product runs without them. Its concrete objects are modules, each owning its
files:

| module | owns | today |
| --- | --- | --- |
| `bridge` | `router/iface/bridge.d`, `driver/linux/bridge.d` | imports `protocol.modbus` for `ServerMap` |
| `vlan` | `router/iface/vlan.d` | registered by `router/iface/package.d` |
| `l2_udp` | `router/iface/udp.d`, `router/iface/endpoint.d` | registered by `router/iface/package.d`; needs `udp` |
| `rdp` | `router/iface/rdp.d` | `HasRDP` file excludes |
| `pcap` | `router/pcap.d`, `router/pcap_server.d` | `BaseInterface.pcap()` imports it |
| `serial` | `router/stream/serial.d`, `router/stream/usb_serial.d` | `stream/package.d` imports serial |
| `wifi` `wpan` `ethernet` `i2c` `sfp` | `router/iface/<x>.d`, `driver/<x>.d` | registered from the `has_switch` block |

The base has four seams to cut: `InterfaceModule.init()` registers `UDPInterface` and `VLANInterface`
(each module registers its own); `BaseInterface.pcap()` imports `router.pcap` (pcap registers an attach
hook); `ping` calls `IPModule.ping` (MAC ping stays core, `ip_stack` registers the IP path);
`stream/package.d` imports `serial` and public-imports every concrete stream.

**`console` is not a module.** The command engine (`console.d`, `command.d`, `collection_commands.d`,
`function_command.d`, `argument.d`, `builtin_commands.d`, `table.d`) is core: `startup.conf`, the sync
remote CLI and the API all execute through it. What products disagree about is the interactive human
surface, so that is the module:

| module | owns |
| --- | --- |
| `shell` | the terminal session: stream binding, line editor, history, completion, prompts and banners; `live_view.d`, `graph.d`, `tree_view.d`, `bitmap.d` |
| `telnet` | `protocol/telnet`; registers itself as a session transport, so `session.d` stops importing it |

`session.d` splits by class. Scripts already bypass the editor: `startup.conf`, automation actions, the API
and sync run through `Console.execute` on a session with no stream (`StringSession`, `ProducerSession`).
So core keeps a base `Session` (execute, command tracking, locals, scope, output queue and paging), and
`shell` adds `TerminalSession`, the `/console/session` objects bound to a stream, which take the editor
(`append_input`, ANSI handling, history, tab completion, prompt, `TerminalChannel`). About 700 of the
1,900 lines move. `energy`, `log`, `record` and `driver/linux/wifi`
import the live views today; those commands move inside `version (shell)`. `shell` replaces `HEADLESS`.

**`switch` is not a module.** It cannot be one under the naming rule below, since `switch` is a D keyword
(`version (switch)` does not parse). Today it means three things: the `FEATURES=switch` tier (core +
`router/` + `protocol/modbus`), `has_switch` (set by no build; it gates the registration of streams,
interfaces and sessions, which is core), and the switch chips of [SWITCH.md](SWITCH.md). The tier becomes
the umbrella `l2 = bridge vlan` plus the platform's link modules; `has_switch` is deleted; the switch-chip
meaning stays inside `ethernet`.

**`gateway` is not a module.** `has_gateway` gates five branches in four modules:

| branch | file | becomes |
| --- | --- | --- |
| transit forwarding, v4 and v6 | `protocol/ip/stack.d` (the `forward` arms) | `ip_forward`, owning a new `protocol/ip/forward.d` that the forward arms call |
| the router flag in neighbour adverts | `protocol/ip/nd.d` | `version (ip_forward)` |
| `RAService` and the RS -> RA hook | `protocol/ip/ra.d`, `protocol/ip/nd.d` | `ipv6_ra`, owning `ra.d`; requires `ip_forward ipv6` |
| DHCP server and leases | `protocol/dhcp/server.d`, `lease.d` | `dhcp_server`, owning both; requires `udp` `inet` |

`protocol/ip/pool.d` stays in `ip_stack`, since DHCPv6 prefix delegation on the client uses it. The firewall is
unconditional today and stays in `ip_stack`. `gateway` becomes the umbrella `ip_forward dhcp_server? ipv6_ra?`,
where `?` marks a weak require (section 3).

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

`core` is always in. `src/manager/` is core by default: collections, the console engine, element model,
log, config, record, panel, secrets, the expression engine and the signal plumbing (`signal.d`'s provider
registry, the `element:` provider, cron's `every:`/`at:`/`when:` provider, `object_signal`). Only four
things leave it, each optional by product: `sync`, `shell` and `profile`. Add the
`router/` base above. `minimal`, a core without `router/`, stays deferred.

| module | requires | optional (activates if also selected) | notes |
| --- | --- | --- | --- |
| `shell` | | | see above; replaces `HEADLESS` |
| `sync` | `websocket\|rdp\|cap xram` | `shell` (remote console) | binary peer protocol, all transports; each transport builds when its carrier is present |
| `telnet` | `tcp` | | |
| `pcap` | | `tcp` (server) | the zigbee encoding registers itself |
| `bridge` `vlan` | | | |
| `l2_udp` | `udp` | `rdp` | |
| `rdp` | `l2_udp` | | |
| `serial` | cap `uart` | cap `usb_serial` | |
| `wifi` | cap `wifi_sta` | cap `wifi_ap` | |
| `wpan` | cap `ieee802154` | | |
| `ethernet` | cap `eth` | | |
| `i2c` `spi` | the matching cap | | |
| `sfp` | `i2c` | | |
| `ip_stack` | cap `ip_backend` | | family-neutral: dispatch, sockets, firewall engine, pool; nobody names it |
| `inet` | `ip_stack` | | IPv4 base: v4 header path, arp, icmp, v4 routes and addresses |
| `inet6` | `ip_stack` | | IPv6 base: v6 header path, nd, icmp6, v6 routes and addresses |
| `udp` | `inet\|inet6` | | adapts to the families present |
| `tcp` | `inet\|inet6` | | `tcp.d`, `tcp_stream.d`, the TCP side of `client.d`; adapts |
| `ip_forward` | `inet\|inet6` | | forwards each family present |
| `ipv6_ra` | `ip_forward` `inet6` | | |
| `dhcp_client` | `udp` `inet\|inet6` | | DHCPv4 with `inet`, DHCPv6 with `inet6` |
| `dhcp_server` | `udp` `inet` | | v4 only; there is no DHCPv6 server |
| `dns` `ntp` `snmp` | `udp` | | family follows `udp` |
| `ppp` | `inet` cap `uart` | | IPCP is v4 |
| `tls` | cap `tls_backend` | | `manager/certificate.d` moves here |
| `http_server` | `tcp` | `tls` | |
| `http_client` | `tcp` | `tls` | |
| `http_binding` | `http_client` `profile` | | REST polling bindings |
| `websocket` | `http_server` | | |
| `http_files` | `http_server` cap `fs` | | |
| `webdav` | `http_files` | | was `!Tiny` |
| `api` | `http_server` | | |
| `ota` | `http_server` cap `ota_slots` | | its delayed reboot moves from `AutomationModule.schedule_oneshot` to `g_app.schedule` |
| `mqtt` | `tcp` `profile` | `tls` | client and binding |
| `mqtt_broker` | `mqtt` | | |
| `ha_discovery` | `mqtt` | | side-quest branch |
| `profile` | | | `ProfileBinding`, loader and sampler; never named, only required; protocol decoders register into it |
| `modbus` | cap `uart` `profile` | `tcp` (tcp framing) | `ServerMap` out of `bridge.d` |
| `sunspec` | `modbus` | | |
| `goodwe` | cap `uart` `profile` | `udp` | |
| `can` | cap `can` `profile` | | |
| `obd` | `can` | | |
| `ezsp` `cpc` `spinel` | cap `uart` | | |
| `zigbee` | `ezsp\|spinel\|wpan` `profile` | | needs the ezsp edge cut |
| `ble` | cap `ble` `profile` | | |
| `tesla_twc` | cap `uart` | | |
| `tesla_vehicle` | `ble` cap `aes_gcm` | | the `apps.energy` edge is cut |
| `esphome` | `tcp` `profile` | | |
| `gpio` | cap `gpio` | | relay, button, light bindings |
| `automation` | | | the `/automation` rules; core boots without them (the `switch` tiers do today) |
| `energy` | `profile` | | 10k lines; the largest app |
| `db` | | cap `threads` | |
| `board_smartevse` `rtc_pcf85063` `power_regulator` `meter_hlw8012` | their caps | | named only by a `board.mk` |

Umbrellas (they own no files):

| umbrella | requires |
| --- | --- |
| `ip` | `inet` `udp` `tcp` |
| `ipv6` | `inet6` `udp` `tcp` |
| `dhcp` | `dhcp_client` `dhcp_server` |
| `http` | `http_server` `http_client` |
| `gateway` | `ip_forward` `dhcp_server` `ipv6_ra?` |
| `l2` | `bridge` `vlan` |
| `full` | every module the host platforms can carry |

Code-owning modules require the part they use, never an umbrella: `mqtt` requires `tcp`, not `ip`, so a
UDP-only sync node takes `inet udp`. A dual-stack product names `ip ipv6`.

`a|b` in requires is an **any-of**: at least one alternative must be in the set, and the module adapts at
compile time with `has!`. It is for interchangeable carriers: the IP families, zigbee's radios, sync's
transports. An alternative may be a cap. A module above `udp` or `tcp` inherits its families from them.
A file that serves one alternative opens with both boxes (`version (sync): version (rdp):`).

## 2. How the code knows what was selected

### One version per module, spelled as the module key

For every resolved module, make passes `-version=<key>`, exactly the registry key: `-version=mqtt`,
`-version=http_files`, `-version=ip_forward`. Caps that the registry computes pass `-version=cap_<name>`:
`cap_aes_gcm`, `cap_fs`. The prefix is needed, because `can`, `ble`, `i2c`, `gpio` and `wifi` are both a cap
and a module. An umbrella emits its version like any module, but nothing reads it: code tests the
module it uses, and modlint rejects an umbrella key in a box or a `has!`.

Lowercase snake is therefore always a module or a cap; PascalCase stays for platform and board facts
(`ESP32_C6`, `BL808_M0`, `SmartEVSE_v30`), backend choices (`UseInternalIPStack`, `KernelMirror`), local
derived flags and `Debug*`. The two never collide.

A key may not be a D keyword (`switch`, `debug`, `version`) or a reserved version (`all`, `none`, `linux`,
`assert`, `unittest`, `D_*`; dmd refuses to set those). The registry rejects them with a clear error.

### Use sites

- A module's files open with `version (mqtt):` before their imports.
- An optional edge nests: `version (tls) { ... }`. Nesting is AND.
- Where a value has to feed an expression (OR, `!`, a constant), one template in `manager/features.d`:

```d
template has(string key) { mixin("version (" ~ key ~ ") enum has = true; else enum has = false;"); }

static if (has!"inet6" && !has!"ip_forward")
```

That template is the whole of `features.d`; every hand-written `has_*` mirror goes. D keeps versions and
symbols in separate namespaces (checked with dmd: `enum mqtt` and `version (mqtt)` coexist), so no enum has
to be renamed for the compiler. They are replaced because each restates the version under another name,
and some invert or rename it. A misspelt `has!"ipv7"` is silently false; modlint checks every `has!` key
against the registry.

### Renames

| today (version / enum) | becomes |
| --- | --- |
| `NoIP` / `has_ip` | `ip_stack` where the site means any IP, `inet` where it is v4 (polarity flips: present means in) |
| `NoIPv6` / `has_ipv6` | `inet6` |
| `NoTLS` / `has_tls` | `tls` |
| `NoHTTP` / `has_http` | `http_server` or `http_client` (`http` is an umbrella), by which side each site uses (`manager/sync`, `plugin.d`) |
| `NoHTTPClient` / `has_http_client` | `http_client` |
| `NoHTTPFileServer` / `has_http_file_server` | `http_files` |
| `NoModbus` / `has_modbus` | `modbus` |
| `NoGateway` / `has_gateway` | `ip_forward`, `ipv6_ra`, `dhcp_server` (section 1) |
| `NoECSecret` / `has_ec_secret` | `cap_ecdsa`: EC secrets are core and adapt to the cap |
| `HasAPI` `HasOTA` `HasRDP` `HasSFP` / `has_api` ... | `api` `ota` `rdp` `sfp` |
| `Headless` / `is_headless` | `shell` (inverted; nothing reads it today) |
| `WebDAV` (derived from `!Tiny` in `fileserver.d`) | `webdav` |
| `SmartEVSE` (`BOARD_VERSIONS`) | `board_smartevse`; `SmartEVSE_v30` stays a board fact |
| `NoSwitch` / `has_switch`, `NoAll` / `has_all` | deleted |
| `has_aes_gcm`, `has_tesla_vehicle` | `cap_aes_gcm`; `tesla_vehicle` requires it |
| `has_file_io`, `has_boot_store`, `HasFilesystem` (x2) | `cap_fs` |
| `Tiny` / `is_tiny` | stays, as the size hint only (section 5) |
| `ExcludeHelpText`, `ExcludeAutocomplete` | deleted; both become `Tiny` tightenings |

`FramingDiagnostics`, `Debug*` and the Linux backend flags (`KernelMirror`, `WifiStaKernel` and the rest)
are not modules and keep their names.

## 3. One source of truth

`modules.mk` at the repo root (urt carries a sibling for caps and urt modules) holds one line per module. Nothing else states a dependency.

```make
$(call module, mqtt,          tcp,                 tls)
$(call module, tesla_vehicle, ble cap_aes_gcm,     )
$(call module, ipv6_ra,       ip_forward inet6,     )
$(call module, tcp,           inet|inet6,          )
$(call module, ip,            inet udp tcp,        )
$(call module, ipv6,          inet6 udp tcp,       )
$(call module, dhcp,          dhcp_client dhcp_server, )
$(call module, gateway,       ip_forward dhcp_server? ipv6_ra?, )
```

The fields are key, requires and optional; the version is the key. An umbrella is a line with requires and
nothing else; modlint knows it owns no files because no file opens with its box. A trailing `?` marks a weak
require: it is taken only when its own requires are already in the set, so `gateway` adds `ipv6_ra` on an
IPv6 build and `dhcp_server` on an IPv4 one. A `|` token is an any-of (section 1); it never adds anything. Caps are declared by the urt platform
block in one place, for example
`CAPS += $(if $(filter 1,$(USE_MBEDTLS))$(filter windows,$(OS)),aes_gcm tls_backend)`.

Everything else derives from it:

| consumer | derived how |
| --- | --- |
| D | `-version=<key>` and `-version=cap_<name>` in DFLAGS, from the resolved set |
| file inclusion | none: the compile takes all of `src/`, the boxes exclude. `FEATURE_DIRS`, `FEATURE_EXCLUDES` and the tier lists go. urt C shims and vendor blobs are still picked by make from the same resolved set |
| module registration | `register_modules()` imports and registers every module, in registry order; a boxed-out module is empty and registers nothing. modlint checks the list against the registry |
| VS | `build/windows.props` (`VersionIdentifiers` for the windows default set), generated by make and committed; the vcxproj file list is all of `src/`. modlint checks both |
| rebuilds | the last good build's flags and source list in `build.stamp`, compared at parse time (PR 1) |
| C shims | `$(OBJDIR)/ow_modules.h` |
| humans | `make explain-modules` prints each module and why it is in (platform, board, `WITH`, "required by X"); `/system/modules` lists the compiled set at runtime via `has!` |

### Inference

The final set is a closure over requires (a small fixpoint in make over about 60 names), then checked
against `CAPS`. Optional edges switch on only when both ends are already in the set.

### Drift guard

`tools/modlint.d`, a host tool built like `binstats`, fails the build when:

- a file under a module's directory does not open with that module's box;
- a top-level import inside box A names module B while B is in neither A's requires nor A's optional list,
  or an optional import is not nested in `version (B)`;
- an any-of alternative is used outside `version (alt)` or `has!"alt"`, which would make the module depend
  on one alternative while declaring that any will do;
- a `has!` key is not in the registry;
- `register_modules()`, the vcxproj file list or `build/windows.props` disagree with the registry or `src/`.

## 4. Selection: platform, then board, then command line

Plain make. A command-line assignment overrides the makefile's own value of that variable, so users never
assign the default variables. Three variables are reserved for the command line and never assigned in any
makefile (none of these names is in use today):

| variable | set by | meaning |
| --- | --- | --- |
| `PLATFORM_MODULES` | urt platform block | the chip default (`full` on hosts) |
| `BOARD_MODULES` | `board.mk`, with `:=` | replaces the platform default; may name umbrellas and reference `$(PLATFORM_MODULES)` |
| `MODULES` | command line only | replaces the whole default set outright |
| `WITH` | command line only | added on top of whichever default won |
| `WITHOUT` | command line only | removed after closure |

```
make BOARD=smartevse-v30 WITH="ocpp" WITHOUT="shell"
make PLATFORM=esp32-c6 WITH=zigbee
make PLATFORM=linux MODULES="l2 inet udp rdp sync"
```

Resolution:

1. Take `MODULES` if it was given, else `BOARD_MODULES` if a board is set, else `PLATFORM_MODULES`.
2. Add `WITH`.
3. Close over requires, then take weak requires whose own requires are met.
4. Remove `WITHOUT`. An umbrella that required a removed module drops out with it (it owns no code), so
   `MODULES=ip WITHOUT=tcp` leaves `inet udp`. If a code-owning module still in the set requires a removed
   one, that is an **error that prints the chain** (`WITHOUT=tcp: required by mqtt (board default) <-
   ha_discovery (WITH)`). Nothing is silently added back.
5. Check any-of requires. Inference never picks an alternative: if none is in the set, that is an error
   naming the options and the chain (`tcp needs one of inet, inet6: required by mqtt (board default)`).
6. Check against caps. A missing cap is an error that names the board and the cap.
7. Unknown names are an error with a near-match suggestion.

### Retirement of the old variables

They stay for one release as shims that map onto `WITH`/`WITHOUT` and print a warning, then they are deleted.

| old | new |
| --- | --- |
| `FEATURES=switch` and the other tiers | umbrellas: `MODULES=l2` and so on |
| `HEADLESS=1` | `WITHOUT=shell` |
| `MODBUS=0`, `HTTP_CLIENT=0`, `HTTP_FILESERVER=0`, `IPV6=0`, `RDP=0` | `WITHOUT=modbus` and so on |
| `GATEWAY=0` | `WITHOUT="ip_forward ipv6_ra"` (the DHCP server stays) |
| `SFP=1` | `WITH=sfp`, or in `BOARD_MODULES` |
| `BOARD_VERSIONS=NoECSecret` | deleted; SmartEVSE carries EC secrets (its flash saving goes) |
| `TINY` | stays, as the size hint only (section 5) |

## 5. Tiny is a size hint, not a selection

`TINY` survives with one meaning: make this binary as small as possible. It never selects or removes a
module; that is the module set's job. A module that is selected tightens itself locally under `Tiny`:

- `-Oz` instead of `-O2`/`-O3`;
- terse error strings and enum display names;
- less detailed error parsing and handling;
- no help text and no local CLI suggestion machinery (today's dead `ExcludeHelpText` and `ExcludeAutocomplete`).
  The remote completion served over sync (`suggest`) is kept; it is a future candidate for `Tiny` to strip.

Each `version (Tiny)` site today:

- `command.d`, `expression.d` and urt's `exception.d` already tighten locally and stay.
- WebDAV becomes the `webdav` module; a board that cannot afford it leaves it out of its set.
- The Tesla vehicle command gate is deleted: a product that cannot afford those commands does not select
  `tesla_vehicle`.
- `GATEWAY=0` and `RDP=0` as TINY defaults go. The DHCP server stays wherever `dhcp_server` is selected.
- The RAM budgets in `log.d`, `element.d`, `sync/package.d`, `sync/peer.d`, `ip/pool.d` and `mqtt/broker.d`
  are not a size concern and need their own knob. `MEM_CLASS` (from `BOARD_RAM_SIZE` and PSRAM) is the
  candidate, but whether it is a few classes or numeric budgets needs investigation (PR 8). Until then
  they stay on `Tiny`.

## 6. Product profiles

Two x86-64 LDC release builds of master were attributed by D symbol prefix. The table gives the
selectable modules' cost, scaled to Thumb/RV32 at 0.42 to 0.6x. These are lower bounds, because template
instances often mangle under the template's module.

| module (x86-64 KB) | | | | | |
| --- | --- | --- | --- | --- | --- |
| sync 275 | energy 237 | router.iface 144 | ip (in-tree) 142 | http 126 | zigbee 124 |
| mqtt 122 | console 109 | tesla 96 | tls 90 (+ backend) | modbus 83 | dhcp 56 |
| profile 45 | ble 44 | obd 33 | api 29 | esphome 27 | ezsp 22 |
| cpc 21 | can 18 | gpio 18 | telnet 18 | goodwe 17 | automation 14 |

Anchors marked *ledger* come from [BINARY_SIZE.md](../BINARY_SIZE.md). Everything else is the nearest anchor
plus or minus module deltas at about 0.5x. Expect +-25%.

| product | modules (beyond `core`) | must not carry | estimate vs limit |
| --- | --- | --- | --- |
| **Pi gateway** (arm64 linux) | `full` + `ethernet` `wifi` `ble` `can` `sfp` | - | 5.83 MB *ledger*; no limit |
| **SmartEVSE v3** (esp32, 4 MB, no PSRAM) | `board_smartevse` `wifi` `ip` `dhcp_client` `dhcp_server` `http_server` `websocket` `tls` `api` `ota` `rdp` `sync` `modbus` (meter) + a future `ocpp` | `inet6` `ip_forward` `shell` `http_files` `mqtt_broker` `energy` `pcap` | today 1.68 / 1.77 MB *ledger*; + modbus 40 + ocpp ~50, - inet6 ~30 - shell ~30 -> ~1.71 MB. Fits only if those cuts land first |
| **Inverter dongle** (esp32-c3 class, 4 MB, OTA) | `wifi` `ip` `dhcp_client` `dns` `ntp` `modbus` `sunspec` `goodwe` `mqtt` `tls` `http_server` `api` `ota` `rdp` `sync` | `ip_forward` `inet6` `zigbee` `ble` `tesla_*` `can` `energy` `mqtt_broker` `webdav` `shell` | SmartEVSE anchor - board + modbus/sunspec/goodwe ~55 + mqtt ~60 -> ~1.80 MB against a 1.9 MB slot |
| **BK7231N plug / light switch** (2 MB, 256 KB RAM) | `wifi` `ip` `dhcp_client` `mqtt` `ha_discovery` `gpio` `http_server` `ota`; plug adds `meter_hlw8012` | `modbus` `bridge` `vlan` `sync` `shell` `pcap` `sfp` `i2c` `rdp` `tls` `inet6` `api` | today `switch` (no IP) 1,078 / 1,083 KB *ledger*. + ip/dhcp ~100, mqtt ~60, http/ota ~70; - modbus ~40, sync ~140, shell ~40 -> roughly break-even, with `sync` left out |
| **BL808 M0 network node** (D0 is a sync member) | `wifi` `ip` `dhcp_client` `dhcp_server` `http_server` `api` `ota` `telnet` `pcap` `sync` | `energy` `zigbee` `tesla_*` `can` `modbus` | ~1.64 MB *ledger*; not flash-pressured |
| **ESP32-C6 Zigbee + WiFi** (802.15.4 native) | `wpan` `zigbee` `wifi` `ip` `dhcp_client` `http_server` `websocket` `api` `ota` `sync` `mqtt` | `ezsp` `energy` `tesla_*` `ble` `can` `modbus` | C5 `full` 3.20 / 3.5 MB *ledger* - energy ~120 - tesla/ble/obd/can ~95 -> ~2.95 MB |
| **ESP32-H2 RCP** (802.15.4 only) | `wpan` `spinel` (server side, not yet written) `sync`, `WITHOUT=shell` | `inet` and everything above it | H2 `switch` 1.03 / 1.90 MB *ledger*; should drop without `shell` |

On tight targets the levers that matter are `sync`, `shell`, `inet6` and the `switch`-carried
`modbus`, not the exotic protocols. The ESP-IDF base (WiFi blob, lwIP, mbedtls) is a fixed ~1 MB on ESP
targets that no module selection can touch.

## 7. Migration

Each PR lands alone, in this order, and does one thing. The acceptance check runs the reference matrix:

| ref | build |
| --- | --- |
| `host` | x86_64 windows and linux release, and unittest (CI today) |
| `vs` | `openwatt.sln`, windows debug |
| `pi` | `make ARCH=arm64 OS=linux CONFIG=release` |
| `evse` | `make esp-idf-build BOARD=smartevse-v30 CONFIG=release` |
| `bk` | `make PLATFORM=bk7231n CONFIG=release` |
| `bl808` | `make PLATFORM=bl808 CONFIG=release` (M0 + D0) |
| `c6` | `make esp-idf-build PLATFORM=esp32-c6 CONFIG=release` |
| `h2` | `make esp-idf-build PLATFORM=esp32-h2 CONFIG=release FEATURES=switch` |
| `dongle` | `make esp-idf-build PLATFORM=esp32-c3 CONFIG=release`, until a dongle board exists |

"Identical" means a byte-identical image to master on every ref. Otherwise the PR states the expected
direction per ref, and its ledger rows go into BINARY_SIZE.md.

1. **Rebuild on a shrinking source set** (#986): a good build stamps its exact flags and source list; any
   difference forces the target.
   Accept: deleting a source rebuilds; identical.
2. **Registry and resolver**: `modules.mk`, closure, `MODULES`/`WITH`/`WITHOUT`, `explain-modules`. The legacy
   variables stay the default set's source; the resolved set projects onto the smallest tier and axes that
   compile it. Rows carry today's edges (`l2_udp` needs no `udp`, `inet6` needs `inet`, `zigbee` needs
   `ezsp`), tightened by the PRs that cut them. Caps, any-of and the optional column arrive with their first
   consumer (PR 3, 11 and 4); `PLATFORM_MODULES` and `BOARD_MODULES` with PR 12.
   Accept: identical; `explain-modules` output recorded per ref.
3. **Rename to module keys**: every row of the rename table, the `has!` template replacing the mirrors,
   "Windows or MbedTLS" and the fs list declared once as caps.
   Accept: identical.
4. **modlint** in make and CI, plus the generated `build/windows.props`.
   Accept: a planted violation of each rule fails CI; `vs` builds with the windows default set.
5. **Box the clean modules and compile all of `src/`**: energy, zigbee+ezsp, tesla, esphome, obd, can, cpc,
   spinel, snmp, goodwe, gpio, ppp, ntp, dns get their box; `FEATURE_DIRS`/`FEATURE_EXCLUDES` go;
   `register_modules()` registers everything in registry order and the `has_all` tree goes.
   Accept: `explain-modules` unchanged on every ref; images within 0.5%; parse-time cost measured on `host`.
6. **Dissolve `gateway`**: `forward.d`, `ip_forward`, `ipv6_ra`, `dhcp_server`, and the `gateway` umbrella.
   SmartEVSE and M0 regain their setup-AP DHCP server.
   Accept: `evse` and `bl808` grow by the DHCP server only, others identical; a client gets a lease from the
   SmartEVSE setup AP (hardware).
7. **Tiny becomes a size hint only**: role defaults and feature cuts come off it and into board sets
   (`webdav`, `tesla_vehicle`, `rdp`); help text and CLI suggestions become `Tiny` tightenings.
   Accept: `host` and `pi` identical; tiny refs differ only by the modules their board sets now name.
8. **RAM budgets (investigation)**: survey every budget now on `Tiny`, decide classes vs numeric budgets,
   then move them. Scope to be written once the survey is in.
   Accept: to be set by the survey; `host` and `pi` identical.
9. **`shell`**: `Session` splits into the core base and `TerminalSession`; the editor and live views move
   out of core; `HEADLESS` becomes `WITHOUT=shell`.
   Accept: `host` identical; `evse`, `bk`, `h2` shrink.
10. **Router seams**, one PR each, each making one module boxable:
   - `vlan` and `l2_udp` register themselves;
   - pcap attach hook (`pcap` boxable, zigbee encoding registers itself);
   - IP ping hook;
   - `ServerMap` out of `bridge.d` (`bridge` boxable; `l2` drops `modbus`);
   - `serial` out of `stream/package.d`.
   Accept: `host` identical; the ref that drops the module shrinks (`bk` for the `ServerMap` cut).
11. **Remaining seams**, one PR each: the IP family split (`ip_stack`, `inet`, `inet6`, `udp`, `tcp`; v4 becomes
    boxable for the first time, and `udp`, `tcp`, `dhcp_client` and `ip_forward` adapt by family); telnet as a session transport; sync's transports
    behind `has!`, then `sync` boxable; `profile` boxable (a decoder registry takes modbus, goodwe and http
    out of `profile.d`, and `ProfileBinding` and `create_device_from_profile` leave core); `certificate.d` into `tls`; cut `tesla -> energy`, `ota -> automation`, `zigbee -> ezsp`.
    Accept: as 10.
12. **`BOARD_MODULES` on every board**: board modules named by `board.mk`; the old variables and shims
    deleted; ledger sections rekeyed by board.
    Accept: every ref builds from its board or platform default alone; ledger rows for all.
13. **urt granularity** (a paired urt PR): driver sources selected per cap instead of globbed.
    Accept: identical on `host`; embedded refs shrink or hold.

PRs 1-4 build the platform. 5-9 are cheap wins. 10 and 11 are the long tail and can run in parallel.

## 8. Decisions

Decided (Manu, #920):

- `sync` is optional.
- BL808 M0 is a network node; it is not flash-pressured.
- Command execution and text rendering stay core: startup cannot run without them.
- `Tiny` is a size hint that never selects modules; losing the DHCP server on TINY targets was not intended.
- RAM budgets need investigation (PR 8).
- Names follow BSD. `inet` (IPv4 base) and `inet6` (IPv6 base) are separate modules; `ip` and `ipv6` are
  separate umbrellas, each on its own base. `udp`, `tcp` and `ip_forward` take any of the two and adapt.
- Remote CLI completion over sync survives `Tiny` for now.
- `src/manager/` is core by default. cron, the signal plumbing, the expression engine and secrets (EC keys
  included, adapting to `cap_ecdsa`) are core.
- `automation` is a module: core boots without it once `ota` uses `g_app.schedule`.
- `sync` is one module and adapts to its carriers (`websocket`, `rdp`, the xram cap); with none it is an error.
- `profile` is never named; the modules with profile bindings require it.
- `shell` is the terminal session; script execution stays core.
- `db` (`src/db`) is a module: a GPIO plug records nothing.

Approved by Manu on #920, 2026-11-25.
