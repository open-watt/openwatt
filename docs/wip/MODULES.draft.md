# Build modules

Status: design only, nothing built. **Required, not speculative**: the OTA arithmetic below shows that
per-unit size work cannot reach the ceiling on its own, so whole-subsystem exclusion has to happen. Build
the reduced form described under "What the evidence attacks" -- no dependency solver, no availability
language -- not the full design as first drafted. This supersedes the tiered `FEATURES` model in
[features.mk](../../features.mk) and the negative version flags in
[src/manager/features.d](../../src/manager/features.d).

## The problem

Tight micros need to be picky at a granularity we cannot currently express. If a target has no I2C we
want neither `router/iface/i2c.d` nor urt's i2c driver in the image; likewise SPI, IP, TLS, HTTP, the
exotic interfaces and samplers, and the choice between the binary `/sync` channel and the JSON/websocket
one. Today:

- **Selection is tiered, not composable.** `FEATURES=switch|switch-ip|full` picks a source-dir list and
  emits a handful of negative flags (`NoAll`, `NoIP`, `NoTLS`, `NoHTTP`) that
  [features.d](../../src/manager/features.d) inverts into `has_*` enums. There is no way to say "switch,
  plus modbus and i2c and binary sync, no SPI, no JSON".
- **urt has no granularity at all.** [platforms.mk](../../third_party/urt/platforms.mk) compiles every
  `urt/**.d` unconditionally and picks `driver/<platform>/` by platform only. `i2c.d`, `can.d`,
  `gpio.d`, `zip.d` and the crypto tree ride along everywhere. `--gc-sections` reclaims some of it, but
  anything reachable from a registration root survives.
- **Negative flags do not scale.** Past a few axes you want positive selection, with everything-on as
  the fallback for builds that bypass make (Visual Studio, ad-hoc tooling). That fallback is the one
  invariant of the current design worth keeping.
- **The registration root is the real size lever.** `register_modules()` in
  [src/manager/plugin.d](../../src/manager/plugin.d) is what drags subsystems into the link. Gating there
  is already the pattern; it is just far too coarse, with `has_all` covering some twenty protocols.

## Vocabulary

**Module** -- one canonical lowercase-snake name, simultaneously a make word, a D string literal, and a
C macro fragment: `i2c`, `spi`, `can`, `ip`, `dhcp`, `tls`, `http`, `mqtt`, `modbus`, `zigbee`,
`sync_bin`, `sync_json`, `energy`.

urt owns the inner names (hardware and runtime capabilities); openwatt reuses **the same name** for the
frontend material that extends it. Selecting `i2c` enables urt's i2c driver layer *and*
[src/router/iface/i2c.d](../../src/router/iface/i2c.d) and its console surface. One name, two layers, one
decision.

**Selectable vs derived.** Not every compiled-out unit should be user-nameable. There will be many
units and few real choices, so they split:

- **Selectable** -- things a real target would plausibly want off while a sibling target wants them on:
  `i2c`, `zigbee`, `http`, `tls`, `energy`, `sync_json`. Dozens at most. Documented, appear in bundles
  and board defaults, and are the only names anyone ever types.
- **Derived** -- finer internal splits implied by what is selected and never named by hand: urt's
  individual crypto primitives pulled in by `tls`, a protocol's codec-vs-client split, per-driver
  sub-pieces. They are still compiled out, and still appear in the manifest so `static if` can see them,
  but they are not part of the vocabulary.

The test for which one something is: **would two real targets in the fleet ever disagree about it?** If
not, derive it. Naming it only adds surface area someone has to understand.

**Bundle** -- a module with dependencies and no sources of its own. `full`, `switch`, `switch_ip` are
bundles, and so are the convenience groupings: `http` hard-depends on `ip`, a `webui` bundle pulls
`http ws sync_json`.

**Profile** -- a saved, named selection line for a real target (`shed-coproc`, `pi-full`).

## The selection language

```
MODULES = switch modbus i2c sync_bin            # positive selection, replaces the baseline
make MODULES_ADD="mqtt tls" MODULES_DEL=zigbee  # adjust whatever baseline won
make PROFILE=shed-coproc                        # a saved MODULES line
```

Declaration table, in `modules.mk` on the urt side and a sibling on the openwatt side:

```make
deps_http     := ip tcp
deps_dhcp     := ip
deps_tls      := crypto
deps_sync_ws  := http ws sync
dirs_http     := protocol/http
srcs_i2c      := urt/driver/i2c.d
```

An unknown name in any of `MODULES`, `MODULES_ADD` or `MODULES_DEL` is a **make-time error with a
near-match suggestion**. This is the typo check that protects a person: `MODULES=htpp` must not quietly
produce a build with no web server. (ESP-IDF's Kconfig silently ignores unknown keys in
`sdkconfig.defaults`, which is why it needed a whole `sdkconfig.rename` mechanism to cope with renamed
options. Error loudly from day one instead.)

## Resolution order

Lowest to highest, each layer able to override the one below:

1. **Built-in bundle default** -- `full` on hosts.
2. **Platform default** -- chip-level, in urt's platform blocks. What suits any board on this SoC.
3. **BOARD default** -- `platforms/<plat>/boards/<board>/board.mk` declaring
   `BOARD_MODULES := switch modbus i2c sync_bin`, tailored to the machine.
4. **User baseline** -- `make MODULES="..."` replaces the lot. Make's command-line-beats-file precedence
   does this natively, no machinery required.
5. **User adjustment** -- `MODULES_ADD` / `MODULES_DEL` applied on top of whichever baseline won. This is
   the common case: keep the board's curated set and poke one thing in or out.

Then, in order: **closure** (pull dependencies in transitively) -> **subtraction** (apply `MODULES_DEL`,
hard-erroring if something in the remaining set still depends on the removed module, printing the chain)
-> **availability intersection**.

Closure only. There is deliberately no Kconfig-style `select` that forces a module on while bypassing its
own dependencies; that is the classic source of unbuildable kernel configurations.

## Availability and the board contract

urt's platform blocks declare what the silicon has, because that is where the hardware knowledge lives:

```make
avail_bl618 := uart i2c spi gpio wifi ble
```

Selecting a module the chip does not have is an **error**, so tight-micro configurations stay honest.

A board may only ever narrow that, and may add its own peripherals:

- `BOARD_AVAIL_DEL := spi` -- the silicon has SPI but this board does not route the pins, so asking for
  `spi` here fails honestly instead of driving unconnected pads.
- `BOARD_MODULES += rtc_pcf85063` -- an on-board peripheral becomes a module addition. This is exactly
  the cleanup [plugin.d](../../src/manager/plugin.d) needs, where that RTC driver is currently registered
  unconditionally for every `has_all` build.

Consequence: `BOARD` stops being an esp32-s3 oddity and becomes a first-class axis on every platform
(the M1s Dock, the Pi deployments, the bk7231 devices are all really boards). Output directories key on
`$(BUILDNAME)_$(BOARD)_$(CONFIG)` uniformly, which the s3 path already does.

## Ownership: urt owns the mechanism

urt must work standalone, and openwatt already compiles urt's sources into the *same* compiler
invocation ([Makefile](../../Makefile), the response file holds both). So:

- **urt owns** the closure engine (`third_party/urt/modules.mk`, sitting beside `platforms.mk` in the
  same shared-with-consumers pattern), the manifest writer, the platform availability sets, the inner
  module table, and `urt.features`.
- **openwatt owns** its own table entries, merged into the engine before the closure pass, and the
  named aliases in `manager.features`.

One merged table, one closure pass, one manifest, consumed by both trees. urt-standalone builds run the
same engine over urt's table alone and get granular builds for free.

## The manifest

`$(OBJDIR)/modules.conf`, generated, **exhaustive** (every known module as `name=0` or `name=1`), and
**never committed**. It is machine-facing: regenerated on every parse, read only by the CTFE scanner.
Being exhaustive is what makes an unknown name in `has!()` a compile error rather than a silent `false`,
which would quietly delete a subsystem from the build.

Each line carries a provenance comment recording *why* the value is what it is -- bundle, board, or
explicit flag -- so "why is zigbee in this build?" is one line of reading rather than archaeology. A
`make explain-modules` target prints the same thing. (Borrowed from ESP-IDF's generated `sdkconfig`,
which annotates every line with `# default:`.)

Do **not** commit an exhaustive fallback copy. It would have to duplicate urt's whole table into
openwatt's repo, and since urt is a submodule, every module added on the urt side would force a matching
openwatt commit or a CI failure.

The string import happens exactly once, in one module, and every check reuses that one symbol:

```d
module urt.features;

private enum manifest = import("modules.conf");   // the only import() in the tree

template has(string mod)
{
    private enum idx = entry_index(manifest, mod);
    static assert(idx >= 0, "unknown module '" ~ mod ~ "'");
    enum has = manifest[idx] == '1';
}
```

`manager.features` becomes `public import urt.features : has;` plus the openwatt-side named aliases
(`enum has_ip = has!"ip";`). Template instantiations are memoised, so each distinct `has!"x"` scans once
per compilation however many call sites use it.

Two compiler behaviours this rests on, both **verified on DMD and LDC**:

- `-J` roots are searched in the order given, first match wins.
- `__traits(compiles, import("missing.conf"))` evaluates to `false`; it is not a hard error.

So the fallback for builds that bypass make is `static if (__traits(compiles, import("modules.conf")))`,
else everything on. The resulting asymmetry -- make builds validate module names, Visual Studio and
ad-hoc builds do not -- is tolerable because the failure direction is safe (an unvalidated typo leaves
code compiled *in*, never silently dropped) and any make build, CI included, catches it.

The C rendering is `$(OBJDIR)/ow_modules.h` (`#define OW_MOD_I2C 1`), pulled into `BAREMETAL_CFLAGS` with
`-include` for the C shims and vendor glue.

## The rebuild contract

The manifest must not go dirty on every run, and must trigger a rebuild when it genuinely changes.

Content is a pure function of the resolved module set, so write-if-changed makes the mtime move only
when the set actually moves. Generate at make **parse time**, not in a recipe, so the mtime is settled
before make evaluates any prerequisite (no `FORCE`-target interactions):

```make
MODULE_MANIFEST := $(OBJDIR)/modules.conf
MANIFEST_BODY := $(foreach m,$(MODULES_ALL),$(m)=$(if $(filter $(m),$(MODULES_ON)),1,0))

ifeq ($(filter clean,$(MAKECMDGOALS)),)
$(shell mkdir -p $(OBJDIR); printf '%s\n' $(MANIFEST_BODY) > $(MODULE_MANIFEST).tmp; \
        cmp -s $(MODULE_MANIFEST).tmp $(MODULE_MANIFEST) \
          && rm -f $(MODULE_MANIFEST).tmp || mv -f $(MODULE_MANIFEST).tmp $(MODULE_MANIFEST))
endif
```

Identical rebuilds leave the mtime untouched, and recursive invocations (the RouterOS container path
re-enters `$(MAKE)`) rewrite the same bytes and also leave it untouched.

It then genuinely triggers when dirty by being a real prerequisite of `$(TARGET)`. That is exact rather
than approximate because the build is whole-program single-invocation, so there is no partial-rebuild
granularity to get wrong. `ow_modules.h` gets the same treatment and must additionally be a prerequisite
of `$(BAREMETAL_OBJS)`, which compile under their own rules.

**A second file fixes an existing hole.** The manifest only covers the module set. Changing `TINY`,
`HEADLESS`, `BOARD` or a compiler flag moves no file's mtime, and *shrinking* the source list moves none
either, since `$(SOURCES)` as a prerequisite catches added and modified files but never removed ones.
This is the wart AGENTS.md currently documents as "make clean between FEATURES changes". So emit
`$(OBJDIR)/build.sig` the same write-if-changed way, holding the fully resolved `DFLAGS` plus the sorted
source list, and list it as a prerequisite too. The compiler never reads it; it exists so that any
build-affecting change moves exactly one mtime. That subsumes the module-set case, the removed-source
case and the `FEATURES` wart in a single mechanism.

## How modules actually remove code

Two levers, doing different jobs, both kept:

1. **Source selection** -- an unenabled module's sources never reach the compiler. This is the honesty
   lever: if `protocol/zigbee` is not in the source list, nothing can quietly depend on it, and a stray
   reference is a link error, which is the signal to fix the layering. On the urt side this replaces the
   blanket glob: for each enabled hardware module the generic `urt/driver/<m>.d` plus the platform
   implementation, with a filename convention (`urt/driver/<plat>/i2c*.d` belongs to module `i2c`) so the
   mapping stays declarative instead of a per-platform-per-module table. Files matching no module name
   (`start.S` glue, clock init, `platform.d`) are the platform's unconditional core.
2. **`static if (has!"x")` at reference points** -- the registration roots and interior touch points in
   always-compiled code. These are the roots that currently defeat `--gc-sections`.

Where a touch point is really a layering violation, invert it into a registry the provider populates
from its own `init()` rather than adding a guard.

## Migration

Sequenced so the mechanical, provable work comes first and the open-ended refactors are deferred until
the machinery can prove each cut. Steps 1 and 2 span two repos; urt lands first, and its commits are
PR-grade.

**1. Engine, with no behaviour change.** Build `modules.mk` (table syntax, closure, availability,
manifest and header emission, write-if-changed, `explain-modules`, unknown-name errors), `urt.features`,
the `-J $(OBJDIR)` root, the new prerequisites and `build.sig`. Define *only* the three existing tiers as
bundles, and keep `has_all` / `has_ip` / `has_tls` / `has_http` / `has_switch` as aliases over `has!()`
so no call site changes. Verify: same targets build byte-identically, a repeated `make` does nothing, and
a `MODULES` change rebuilds exactly once.

**2. urt granularity.** urt's module table (hardware: `uart`, `i2c`, `spi`, `can`, `gpio`, `wifi`, `ble`,
`rtc`; runtime: `crypto`, `zip`, ...), the per-platform availability sets, and the computed source sets
replacing the globs. First real size win; measure it on bl808-m0 and esp32-c2.

**3. openwatt protocol granularity.** Each `protocol/<x>` and `apps/<x>` becomes selectable, `sync_bin`
splits from `sync_json`/`ws`, and `register_modules()` splits into per-module blocks. This is where the
Phase 2 entanglements listed at the bottom of [features.mk](../../features.mk) bite, and each gets fixed as
its seam is cut, in the order the cuts demand:

- `manager/console/session.d` -> telnet registers itself as a transport; the console core should not know
  it exists. Prerequisite for telnet being optional.
- `manager/sync/ws_server.d` -> move out of `manager/sync/`. Prerequisite for separating `sync_json`.
- `manager/profile.d` -> the modbus / goodwe / http decoders register themselves with profile.
  Prerequisite for those protocols being optional.
- `router/pcap.d` -> the zigbee-aware encoding moves behind a registry. Prerequisite for optional zigbee.
- `manager/certificate.d` -> move to `protocol/tls/` or `apps/`.

**4. Hardware interface modules and BOARD.** Gate the `i2c` / `spi` / `can` frontends, formalise the
`board.mk` contract across all platforms, key output dirs on BOARD, and move the pcf85063 registration to
a board-declared module.

**5. Profiles for the real targets.** bl808-m0 coproc, esp32-c2 tiny node, Pi full, routeros. Record
per-profile binary sizes as the regression baseline.

## Challenges and alternatives

### Why this is required: the OTA arithmetic

The ESP32 partition tables put an app slot at `0x1C0000` = **1,835,008 bytes**, and there are two of them
because OTA needs two. The current `bin/esp32-s3_release/openwatt.bin` is **3,134,656 bytes**. That is
1,299,648 bytes over, so **41.5% of the image has to go** for an OTA-capable build. The repo already
records the failure: the esp32-c2 and esp32-c3 partition tables carry the comment "single app -- binary
too large for OTA", having given up the second slot rather than shrink.

Per-unit size work cannot close that gap alone. [SIZE_REVIEW.md](SIZE_REVIEW.md) totals **~522 KB across
all of Tier 2** measured on target, which still leaves roughly 780 KB to find. And the single largest item
on target, S15 unwind tables at 363,084 bytes (10.3%), is marked `[-] BLOCKED`: partial suppression was
already attempted and does not work, because it needs complete removal of exception support end to end.
Do not re-propose it as a quick win -- though note that "end to end, across urt and the app" is precisely
the shape of thing a build axis carries and an ad-hoc flag cannot.

So whole-subsystem exclusion is not an optimisation to weigh against the per-unit work. It is the only
remaining source of a megabyte, and both workstreams have to land.

### RAM needs its own measurement

SIZE_REVIEW is a flash tracker and does not answer the RAM question, which for the tightest targets is the
harder constraint. C1 (buffers embedded in classes) already closed the big RAM item -- init blobs are down
to 396 symbols totalling 41,600 bytes -- so the next step is a `.bss`/`.data`/`.sram_data` inventory on the
actual target rather than an assumption. Module exclusion helps here directly and for free: an excluded
module takes its static state with it.

### What the evidence defends

Source-level exclusion earns its place, and the attractive simple alternative does not work here.
"Compile everything, gate only the registration roots, let `--gc-sections` reclaim the rest" fails on
SIZE_REVIEW verified mechanic 3: **`ClassInfo.m_init` pins the blob and survives `--gc-sections` even when
the class is never constructed.** In a codebase where every Collection object is a class, an unregistered
protocol still leaves its init blobs in the image. Tracker item S4, whether the RISC-V-direct path even
emits per-symbol sections, is still `UNVERIFIED`, so the linker's granularity is itself an open question.

### What the evidence attacks

The dependency closure engine is the weakest part of this design and should probably be cut. It is a
hand-maintained duplicate of something the linker already computes exactly, from real references rather
than a declared table that will drift: `MODULES=http` without `ip` produces undefined symbols naming
precisely what is missing. Similarly, availability is a filesystem fact (`urt/driver/bl618/i2c.d` existing
*is* "bl618 has i2c"), and module membership is one too (`protocol/zigbee/` *is* the zigbee module).

Deriving all three from the tree instead of declaring them removes the fixpoint solver, the availability
language, and the ongoing table maintenance, while keeping the parts that carry the weight: sources
excluded from the compile, `static if` at the registration roots, and the manifest and rebuild plumbing
(which the rebuild-correctness argument requires independently). Bundles survive as dumb sugar, a name
expanding to a list, rather than as a solver.

### Directions not taken

- **Use Kconfig rather than inventing a language.** kconfiglib is a single Python file, and ESP-IDF is
  already in this project's toolchain for the esp targets. It brings `depends on`, defaults, `menuconfig`,
  header generation and defconfigs, all battle-tested and already familiar to embedded developers, leaving
  only a small emitter for the D-side manifest to write. The costs are a Python dependency on the bl808,
  bk7231 and host paths that do not have one today, and Kconfig's `select` footgun. This is the strongest
  "stop designing and adopt something" option and deserves a day's evaluation before committing to
  anything bespoke.
- **Explicit per-profile source lists, with no selection language at all.** `profiles/<name>.mk` literally
  lists the directories. Five or six real targets means five or six lists, zero engine, and maximum
  honesty since you read the file and know what is in the build. It is `FEATURE_DIRS_*` taken to its
  logical end, with duplication as the cost and list-includes-list as the mitigation. If the measurement
  above comes in modest, this is very likely the right answer.
- **Config-driven selection.** [main.d](../../src/main.d) already does
  `static immutable system_conf = import("system.conf")`, so embedded targets already string-import their
  configuration at compile time. Extending that to CTFE-parse `startup.conf` and map console command paths
  onto modules (`/interface/modbus/add` implies modbus) would make a device's configuration *be* its module
  selection, with no new vocabulary at all. It is the most native idea to OpenWatt's central premise, and
  the objection is fatal to it as a mechanism: it destroys runtime reconfiguration, which is the project's
  stated differentiator. As a *generator* that emits a starting `MODULES` line for a human to edit, it
  remains a genuinely nice tool.

## Deferred

- `minimal` (below `switch`) still needs the manager/router decoupling listed under the deeper refactors
  in [features.mk](../../features.mk): `manager/value.d` router-type Variant support, `manager/console/argument.d`
  router-type conversions, `manager/sync/peer.d` packet forwarding.
- The protocol-internal fabric/control splits (modbus iface+message vs client/sampler/binding/sunspec;
  zigbee iface+aps+coordinator vs zcl/zdo; ble LL/HCI vs GATT and the Tesla session logic) are derived
  splits, not selectable ones, and can wait until step 3 has proved the seams.
