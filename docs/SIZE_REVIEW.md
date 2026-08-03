# Binary Size Review

**Opened:** 2026-08-03
**Scope:** whole-tree scan for flash/image bloat, with an eye to Tiny targets (BL808/BL618/ESP32).
**Baseline measured:** `bin/bl618_release/fw.bin` (3.5 MB, LDC 1.42 release) - the target profile.
Host builds were used for the early survey and are noted where a figure still comes from one.

**Status legend:** `[ ]` open - `[~]` needs a decision / verify first - `[x]` done - `[-]` closed, no action
**Evidence legend:** `MEASURED` (byte-level verification on a real artifact) -
`PROJECTED` (extrapolated from instantiation counts, not yet built) - `UNVERIFIED` (hypothesis)

> Tier 2 and C1 figures are from the bl618 target build. Tier 3/4 figures are still host-derived;
> re-measure before acting. Note `bl618` is **not** a `TINY` platform - `TINY=1` covers only
> `esp8266`, `bk7231n/t`, `esp32-c2/h2/s2` and `bl808`+`e907`
> ([platforms.mk:439](../third_party/urt/platforms.mk#L439)), so anything gated on `is_tiny`
> needs one of those to be exercised.

---

## Tracker

| ID | Item | Tier | Evidence | Size | Status |
|----|------|------|----------|-----:|--------|
| B0 | bl618 release baseline | 0 | MEASURED | - | `[x]` |
| **C1** | **Classes must not embed large buffers (sweep)** | **1** | **MEASURED** | **~300,000** | `[ ]` |
| C1.1 | DbModule SPSC rings out of the class | 1 | MEASURED | 113,728 + ~104K RAM | `[x]` |
| C1.2 | CPCInterface buffers to a heap struct | 1 | MEASURED | 4,136 | `[x]` |
| C1.3 | Application event queues out of the class | 1 | MEASURED | 9,232 | `[x]` |
| S3 | Zero-init non-zero defaults at module scope | 1 | MEASURED | 8,192 | `[ ]` |
| S4 | Verify per-symbol sections on RISC-V-direct path | 1 | UNVERIFIED | - | `[ ]` |
| S5 | CTFE-only guards on CTFE-only helpers | 1 | MEASURED | 616 | `[ ]` |
| S10 | `SynthGetter`/`SynthSetter`/`MaterialProperties` | 2 | MEASURED | 117,278 | `[ ]` |
| S9 | `function_command` to runtime signature descriptor | 2 | MEASURED | 105,288 | `[ ]` |
| S6 | `write_log!(T...)` to `LogArg[]` + one sink | 2 | MEASURED | 103,804 | `[ ]` |
| S7 | `Array!T` type erasure | 2 | MEASURED | 64,778 | `[ ]` |
| S8 | `proto_deserialise!T` to `FieldInfo[]` + walker | 2 | MEASURED | 53,632 | `[ ]` |
| S18 | `urt.map` / `AVLTree` instantiations | 2 | MEASURED | 18,686 | `[ ]` |
| S11 | String `switch` to `make_table` + `find_first` | 2 | MEASURED | 15,138 | `[ ]` |
| S15 | Drop unwind tables (`.eh_frame` + except table) | - | MEASURED | 363,084 | `[-]` |
| S12 | Wire `is_tiny` through the console render layer | 3 | MEASURED | 31,258 | `[ ]` |
| S13 | Gate `apps.energy` console tables | 3 | MEASURED | ~50,000 | `[~]` |
| S14 | Gate collection `get`/`print`/`set` formatting | 3 | MEASURED | 17,950 | `[~]` |
| S16 | Raw `string[]` tables to `make_table` | 4 | MEASURED | ~4,000 | `[ ]` |
| S17 | `LoadProtobuf!"path"` TypeInfo name shortening | 4 | MEASURED | 1,400 | `[ ]` |

Sizes are bytes recovered from the host build unless noted. Tier 2 totals ~522 KB.

**Dropped:** stripping release links (was S1, 1,737,732 bytes). Non-ALLOC sections never reach an
embedded image: `openwatt.bin` is 3,146,000 against a 16 MB ELF. Only ever helped the Pi OTA payload.

---

## Verified mechanics

Established by direct experiment against LDC. These rules drive every decision below, and several
of them contradict what looks obvious, so check here before proposing an init-related fix.

1. **A class is never zero-init.** The vptr and ClassInfo slot at offset 0 are always non-zero, so
   every class emits a full-size `__init` unconditionally. Identical fields, struct vs class:

   ```
   struct, all-zero fields  ->  .bss, 16,388 B, NO __initZ
   class,  all-zero fields  ->  __initZ 16,404 B in .data
   ```

2. **Init blobs are never truncated.** One non-zero member anywhere costs the whole aggregate, and
   field order makes no difference. A `double` (NaN) inside a 4096-entry array element pulls in
   98 KB, whether it sits first or last.

3. **`ClassInfo.m_init` pins the blob.** It survives `--gc-sections` even when the class is never
   constructed. Changing how `emplace` initialises is therefore irrelevant to size.

4. **`extern(C++)` does not help** - 16,396 vs 16,404 bytes, the monitor slot.

5. **`= void` is equivalent to zero-init** for placement and for `x = S.init` codegen. All three
   forms below are byte-identical in the first two cases:

   ```
   all-zero init   -> memset                     (no blob)
   buf = void      -> memset                     (no blob)
   non-zero member -> memcpy from __initZ        (full-size blob)
   ```

6. **Structs are the escape hatch.** A struct that is entirely zero-init (naturally, or via `= void`
   on don't-care storage) emits no `__init` and lands in `.bss`. This is why moving a buffer out of
   a class works and nothing else does.

7. **`assert(__ctfe, msg)` is a no-op under `-release`.** Use `if (!__ctfe) assert(false, msg);` -
   `assert(false)` is the one form D always retains, and it marks the body unreachable so it is
   dead-code-eliminated to a trap.

---

## Method

Reproducing the measurements:

```bash
# symbol inventory
nm --print-size --size-sort --radix=d bin/arm64_linux_release/openwatt > syms.txt

# aggregate by D package (first component of the mangled name)
awk '{sz=$2+0; s=$4; if (s ~ /^_D/) { r=substr(s,3);
      if (match(r,/^[0-9]+/)) { n=substr(r,RSTART,RLENGTH)+0; t[substr(r,RLENGTH+1,n)]+=sz } } }
     END { for (p in t) printf "%10d  %s\n", t[p], p }' syms.txt | sort -rn

# template matrix weight for a given template
awk -v t=make_arg_tuple 'index($4,t)>0 {s+=$2+0;n++} END {printf "%d syms %d bytes\n",n,s}' syms.txt

# section budget
size -A bin/arm64_linux_release/openwatt
```

Two throwaway scripts were used and are not committed: one classifies every initialised global
by fill pattern (all-zero / const-fill / repeating lane / varied) by mapping symbol addresses to
section file offsets and reading the bytes; the other splits name-string cost into ALLOC vs
non-ALLOC sections. Both are ~60 lines and easy to rewrite from the descriptions in S2/S3.

### Target baseline: bl618 release, FEATURES=full

`fw.bin` = 3,528,968 bytes.

```
.text             2,804,736     .eh_frame           342,900     .rodata      274,637
.gcc_except_table    20,184     .data                69,336     .sram_data    16,096
.bss                120,284  (free)
```

`.eh_frame` and `.gcc_except_table` share LOAD segment 01 with `.rodata`, so both are flashed:
**363,084 bytes, 10.3% of the image**, in a codebase that is `@nogc nothrow` throughout. That makes
S15 the single largest item on the real target.

Template matrices, on target. **Attribute by owner prefix** (`index($4, path) == 1`), never by
substring: a substring match counts every application function that merely takes the type as a
parameter. That error inflated `Array!T` from 68,764 to 169,910 on first measurement.

```
117,278  Synth* + MaterialProperties   769 syms
105,288  console.function_command      160 syms   (make_arg_tuple 70,160 / FunctionCommand 35,128)
103,804  urt.log write_log(f)          189 syms   (write_log 83,862 / write_logf 19,942)
 68,764  urt.array Array!T             250 syms
 53,632  tools.protobuf                 62 syms
 18,686  urt.map                       154 syms
 17,950  console.collection_commands    65 syms
 15,138  object.__switch                33 syms
```

Init blobs after C1: **396 symbols, 41,600 bytes total**, largest single 1,016
(`TeslaVehicleSession`). C1 is closed - there is nothing left worth chasing in that category.

### Host baseline section budget (early survey, superseded)

```
.text          4,130,388     .eh_frame        554,212     .rodata        524,016
.data.rel.ro     399,192     .data            128,640     .bss            45,856
.symtab          708,456     .strtab        1,029,276     (non-ALLOC)
```

### Object file anatomy (esp32-s3, 20,864,912 bytes)

```
section headers      5,218,440   (130,461 x 40B)
string+symbol tables 8,472,315
---- bookkeeping    13,690,755   = 66% of the object
actual content       7,174,157
```

Object size is a symptom, not a cause: `--function-sections --data-sections` names each section
after its full D mangled symbol, so 130,461 symbols is the driver. Every Tier 2 item shrinks it.

---

## Tier 1 - mechanical, verified, low risk

### C1. Classes must not embed large buffers `[ ]`

The general rule, and the largest single lever in the tree. Per mechanics (1) and (2): every class
emits a full-size `__init` blob unconditionally, and it is never truncated. So **any buffer embedded
in any class costs its own size in ROM, always** - even if the buffer is entirely zero, even if the
class is never instantiated, even with `extern(C++)`, and regardless of `--gc-sections`.

There is no way to make a class cheap. The only fix is to take the storage out of the class: a
module-scope `__gshared` global (when the owner is a singleton) or a heap allocation.

The 413 `__init` blobs total 300,294 bytes and are almost entirely this pattern. Ranked, host build:

```
113,905  db.DbModule                            <- C1.1 done
  9,840  manager.Application                    <- C1.3 done
  4,816  protocol.cpc.CPCInterface              <- C1.2 done
 21,904  driver.linux.wifi.LinuxAP               17,746  driver.linux.wifi.LinuxWlan             |
 17,055  driver.linux.wifi.LinuxWifiRadio        > host-only, not on embedded
 17,009  driver.linux.ethernet.LinuxRawEthernet  |
 16,440  driver.linux.bridge.LinuxBridgeOffload /
```

Numbers are from the current x86_64 release build. An earlier arm64 build listed `manager.log.LogModule`
at 16,424 and `manager.sync.peer.SyncPeer` at 4,349; both are 874 and 261 in the current tree, so they
had already been fixed independently. Re-measure before acting on any figure in this file.

`LogModule`, `Application`, `CPCInterface` and `SyncPeer` are on embedded; the Linux drivers are not.
Singletons take the `__gshared` route (C1.1); per-instance classes need heap storage (C1.2).

Tail-allocating the buffer alongside the class was considered and rejected: `allocT`/`freeT` both
hard-code `__traits(classInstanceSize, T)`
([allocator.d:67](../third_party/urt/src/urt/mem/allocator.d#L67),
[:98](../third_party/urt/src/urt/mem/allocator.d#L98)), so it needs a paired API, and it would have
to be plumbed through the deliberately type-agnostic Collection creation path. It also saves nothing
here: the init blob is sized by `classInstanceSize`, so any way of getting the buffer out saves the
same bytes. Its only edge is one allocation instead of two, which matters for high-count short-lived
objects (packets, sessions) - an allocation-churn concern to justify on its own numbers, not this.

### C1.1. DbModule SPSC rings `[x]`

First instance, and the largest. `db` is in the switch tier
([features.mk:70](../features.mk#L70)), so this is compiled into every embedded target.

[package.d:225-228](../src/db/package.d#L225-L228) embeds four rings in the class:

```d
SPSCRing!(IngestMsg, 4096) _ingest;    // 4096 x 24B = 98,304
SPSCRing!(QueryReq,   256) _requests;  //              8,192
SPSCRing!(QueryDone,  256) _done;      //              6,144
SPSCRing!(DbNotice,    64) _notices;   //              1,024
```

That is 113,905 bytes of `__init` in flash and ~104 KB of RAM, on targets with under 350 KB of RAM
total. Three changes:

- [spsc.d:154](../third_party/urt/src/urt/sync/spsc.d#L154): `T[N] _buf = void;`, cursors left
  zero-init, plus an `init()` that zeroes the three cursors.
- [package.d:41-44](../src/db/package.d#L41-L44): tier the capacities on `is_tiny`
  (4096/256/256/64 -> 64/8/8/8).
- Delete the four members; declare them in the bottom `private:` block beside `g_db` as
  `__gshared SPSCRing!(...) g_ingest = void;` and call `init()` from `DbModule.init()` ahead of
  `thread_spawn`. 16 reference renames.

Both halves are load-bearing and do different jobs: moving out of the class kills the unconditional
full-size class blob; `= void` keeps the now-global in `.bss` rather than `.data`, since `IngestMsg`
carries a NaN-defaulting `double`. `init()` is required because the `= void` declarations leave the
cursors genuinely undefined.

`adapter_watcher.d` also uses `SPSCRing` but as struct members, so it inherits zeroed cursors from
the struct's own init and needs nothing.

**Done.** `DbModule.__init` 113,905 -> 177 bytes; all four rings now in `.bss`
(98,320 + 8,208 + 6,160 + 1,040 = 113,728, exactly the delta). Landed as `_buf = void` in urt plus
`double value = 0` on `Sample` and `IngestMsg` - the NaN default was wrong on its own merits, and
the `= void` states the intent regardless of what the compiler does with it. Since the struct is
zero-init either way, the globals need no `= void` at the declaration and no `init()` call.
121/121 unittest modules pass.

### C1.2. CPCInterface rx/command buffers `[x]`

`ubyte[4096] _rx_buffer` plus `ubyte[16] _ucmd_buffer`, `char[16] _secondary_version` and
`char[32] _app_version`. The rx buffer is genuinely per-instance: `_rx_offset` accumulates partial
frames across `on_bytes` calls, so it cannot be shared.

Not a singleton, so the four moved into a `Buffers` struct heap-allocated in the constructor and
freed in `~this()`, with `validate()` gating on the allocation. Construction rather than `startup()`
because the state machine re-enters `shutdown()` on every restart-with-backoff cycle, and the
`const pure` version getters are callable while stopped.

The two `char[]` version fields were `0xFF`-initialised, which is wrong for strings on its own
merits; they are `= 0` now, and the two scratch byte buffers are `= void`, which leaves `Buffers`
zero-init so it emits no `__initZ` of its own.

**Done.** `CPCInterface.__init` 4,816 -> 680 bytes. 121/121 unittest modules pass.

### C1.3. Application event queues `[x]`

`MpscQueue!(PendingEvent, 32)` and `MpscQueue!(PendingEvent, 256)` - the same shape as C1.1, and the
whole of `Application`'s blob. `Application` is a singleton behind `g_app`, so both moved to
module-scope `__gshared` in the file's private section, with `PendingEvent` moved out of the class
alongside them (`EventHandler` was already module-scope, so nothing else had to move).

`MpscQueue` got the same `_slots = void` treatment as `SPSCRing`. Safe for the same reason and then
some: `init()` already primes every slot's sequence to [0, 1, ... N-1], and it was already being
called from the Application constructor, so no new lifecycle obligation.

**Done.** `Application.__init` 9,840 -> 608 bytes; both queues in `.bss` (8,200 + 1,032 = 9,232,
exactly the delta). 121/121 unittest modules pass, plus a runtime smoke test - the app starts,
modules come online, no asserts.

### S3. Zero-init non-zero defaults at module scope `[ ]`

What survives of the original S3 once C1 absorbs the class cases. D's defaults are not zero: `char`
is `0xFF`, `float`/`double` are NaN. At **module scope** this is a real and simple win, because a
zero-init global lands in `.bss`:

[system.d:176](../src/driver/linux/system.d#L176) and
[system.d:180](../src/driver/linux/system.d#L180), two `__gshared char[4096]` emitted as 8,192 bytes
of `0xFF` into `.data`.

A source scan found 121 non-zero-default declarations at module or aggregate scope. The aggregate
ones are only worth touching where the aggregate reaches a class layout or a large array, which is
C1's job; work the binary-side list rather than the source list. Any symbol classified const-fill or
mostly-zero in a PROGBITS section is a real hit.

Where a non-zero fill is genuinely wanted, broadcast it at startup rather than storing it.

### S4. Verify per-symbol sections on the RISC-V-direct path `[ ]`

`-L--gc-sections` is set only on the baremetal path
([platforms.mk:710](../third_party/urt/platforms.mk#L710)). The Xtensa path gets
`--function-sections --data-sections` from llc ([Makefile:380](../Makefile#L380)) and does have
per-symbol sections (130,461 in the object), so GC works there. The RISC-V path goes straight
from LDC and has not been checked. Without per-symbol sections `--gc-sections` can only drop
whole object files, and since the whole program compiles to one object, it drops nothing.

Check with `readelf -S openwatt.o | grep -c '\.text\.'` on a BL618 build.

### S5. CTFE-only guards `[ ]`

Use:

```d
if (!__ctfe) assert(false, "CTFE ONLY");
```

**Not** `assert(__ctfe, "CTFE ONLY")`. Measured with LDC on a function only ever called at CTFE:

| guard | `-O3 -release` | `-O3` |
|---|---:|---:|
| none | 356 B | 430 B |
| `assert(__ctfe, msg)` | 356 B | 36 B |
| `if (!__ctfe) assert(false, msg)` | **2 B** | 36 B |
| template `f()(args)` | 430 B | 430 B |

`-release` strips ordinary asserts, and embedded builds are release-only, so `assert(__ctfe, ...)`
buys nothing on the targets that matter. `assert(false)` is the one form D always retains; it
marks the rest unreachable and the body is dead-code-eliminated to a trap. CTFE still runs
correctly (the folded result materialises as a constant). The message goes to `.rodata.str1.1`
which is `SHF_MERGE|SHF_STRINGS`, so one shared text costs 10 bytes across the whole binary
(verified across two modules). Templating is counterproductive: larger, plus an extra section.

Confirmed recoverable today is only `parse_proto` (616 B). Most CTFE helpers already vanish -
`pack_strings`, `fill_table`, `make_table`, `trim_key`, `get_display_attr` are all 0 symbols -
but that is accidental, a consequence of being private or template-instantiated. The guard makes
it enforceable and fails loudly if something calls them at runtime. Apply to `parse_proto`,
`generate_enum`, `generate_message`, `pack_strings`, `fill_table` and the enuminfo CTFE helpers.

---

## Tier 2 - de-matrixing

Template instantiation matrices, measured on the host build:

| matrix | syms | bytes | keyed on |
|---|---:|---:|---|
| `Array!T` | 380 | 176,140 | 212 distinct element types |
| `urt.log.write_log!(T...)` | 212 | 128,613 | argument type tuple per call site |
| `console.function_command` | 163 | 124,640 | command signature |
| `SynthGetter` + `SynthSetter` | 668 | 124,952 | property |
| `proto_deserialise!T` | 33 | 54,288 | protobuf message type |
| `MaterialProperties!Type` | 91 | 27,000 | registered type |
| `AVLTree` | 160 | 22,968 | 44 distinct |
| `collection_commands` | 65 | 19,652 | |
| `object.__switch` | 36 | 18,328 | case-string list |

### S6. `write_log!(T...)` `[ ]`

[log.d:147](../third_party/urt/src/urt/log.d#L147) mints a fresh ~1.7 KB function for every
distinct argument type tuple at every call site. Marshal to a small `LogArg[]` via per-type
thunks and call one non-template sink; each site drops to roughly 16 bytes per argument of setup.
Best size-per-effort of the matrices, but it touches every module, so it wants its own branch
and a clean diff.

### S7. `Array!T` type erasure `[ ]`

Of 212 element types, 92 symbols (35,248 bytes) are `Array!(class)` or `Array!(pointer)` - all
pointer-sized and trivially copyable, so they can share one type-erased implementation behind a
thin typed facade. The 179 struct instantiations split by size and triviality rather than by
type, so a second tier keyed on `(size, hasElaborateCopy, hasElaborateDestructor)` would collapse
most of the remainder.

### S8. `proto_deserialise!T` `[ ]`

[package.d:122](../src/tools/protobuf/package.d#L122) unrolls a `static foreach` over
`msg.tupleof` into a `switch` per message type: 3,540 B for `DeviceInfoResponse`, 2,592 for
`ListEntitiesClimateResponse`, and so on across 33 instantiations.

The field metadata is already a UDA on each field and `FieldInfo{id, wire, ty}` already exists at
[package.d:36](../src/tools/protobuf/package.d#L36). Emit `immutable FieldInfo[]` plus member
offsets per message and write one runtime walker. This is the "only the struct declarations
remain" goal: the generated types themselves are cheap, the codec is what costs.

### S9. `function_command` / `make_arg_tuple` `[ ]`

[function_command.d:310](../src/manager/console/function_command.d#L310) instantiates per command
signature. Replace with a runtime signature descriptor (parameter type tags plus a conversion
table) and one dispatcher. Also produces the longest symbol names in the binary after
`object.__switch`, so it pays twice.

### S10. `SynthGetter` / `SynthSetter` / `MaterialProperties` `[ ]`

759 instantiations across [base.d:1140](../src/manager/base.d#L1140),
[base.d:1154](../src/manager/base.d#L1154) and [base.d:1062](../src/manager/base.d#L1062).
Same shape as S9: compile-time-per-property where a runtime descriptor would do. Largest single
group, and the most invasive, so probably last.

### S11. String `switch` to `make_table` `[ ]`

D's string-`switch` helper is templated on the entire case list **hex-encoded into the mangled
name**. The largest instance is 1,385 characters:

```
_D6object__T8__switchTxaVxAaa3_626167VxQna3_736574VxQBaa4_64617465VxQBqa4_696e7438...
                          ^bag        ^set        ^date           ^int8
```

That one is the `ZCLDataType` member names from [zcl.d:155](../src/protocol/zigbee/zcl.d#L155)
onward. Codebase-wide: 36 instantiations, 18,328 B of code and 9,056 B of symbol name, with the
case strings stored twice (once as data, once hex-encoded in the mangling).

The replacement already exists in-tree: `make_table` plus `find_first` from
[string.d:542](../third_party/urt/src/urt/string/string.d#L542). Densest sites:
[profile.d](../src/manager/profile.d) 32 cases, [ha_discovery.d](../src/protocol/mqtt/ha_discovery.d)
30, [staticfiles.d](../src/protocol/http/staticfiles.d) 26,
[json_encoder.d](../src/manager/sync/json_encoder.d) 22.

---

## Tier 3 - build out `version (Tiny)`

The flag exists and the build system sets it, but almost nothing responds. `is_tiny`
([features.d:20](../src/manager/features.d#L20)) has exactly one consumer in the whole tree,
[broker.d:31](../src/protocol/mqtt/broker.d#L31). `is_headless`
([features.d:19](../src/manager/features.d#L19)) has zero. The `version (Tiny)` clause itself
appears in three places, all in `urt/internal/exception.d`.

This is policy work more than mechanical work: someone has to decide what a Tiny build is allowed
not to do. Sequence it **after** Tier 2, because de-matrixing changes what is left to gate.

### S12. Console render layer `[ ]`

`manager.console` totals 245,025 bytes. The purely presentational part:

```
live_view 8,068   graph 8,660   tree_view 6,214   table 5,332   bitmap 2,984   = 31,258
```

### S13. `apps.energy` console tables `[~]`

`apps.energy` totals 361,451 bytes, heavily weighted to console table construction:
`publish_topology_layout` 16,332, `add_control_row` 7,452, `build_topology_table`/`add_bus_row`
7,112, `why` 6,744. Needs a decision on which of these are diagnostics versus load-bearing
(`publish_*` feed the sync/API path, not just the CLI) before anything is gated.

### S14. Collection `get`/`print`/`set` formatting `[~]`

19,652 bytes in [collection_commands.d](../src/manager/console/collection_commands.d), plus its
share of S9. The format metadata reachable via `get` is strictly non-essential on a headless
node. Interacts with S9, so decide the descriptor shape there first.

---

## Tier 4 - opportunistic

### S15. Unwind tables `[-]` BLOCKED

Confirmed the largest single item on target: `.eh_frame` 342,900 + `.gcc_except_table` 20,184 =
**363,084 bytes, 10.3% of the bl618 image**, and verified flashed (both share LOAD segment 01 with
`.rodata`).

**Not actionable as a build-flag change.** Already attempted; partial suppression does not work, it
needs complete removal of exception support end to end. Left recorded for size accounting only - do
not re-propose as a quick win.

### S16. Raw `string[]` tables `[ ]`

Each entry costs 16 bytes of pointer+length on 64-bit, 8 on 32-bit, before any string bytes.
`make_table` packs to one offset byte plus the characters. Sites:
[log.d:866](../src/manager/log.d#L866) `tag_colors` (16 ANSI escapes),
[message.d:122](../src/protocol/modbus/message.d#L122) and
[message.d:137](../src/protocol/modbus/message.d#L137),
[meter.d:445](../src/apps/energy/meter.d#L445),
[vehicle_session.d:811](../src/protocol/tesla/vehicle_session.d#L811),
[log.d:23](../third_party/urt/src/urt/log.d#L23),
[time.d:1203](../third_party/urt/src/urt/time.d#L1203).

Single-digit KB total, so opportunistic only. Note `enuminfo` already does this properly
(flat length-prefixed char array plus ubyte lookup tables) and is the reference implementation.

### S17. `LoadProtobuf!"path"` TypeInfo names `[ ]`

27 `TypeInfo_Enum` name strings in `.rodata` (2,035 bytes), each carrying the full template
argument:

```
protocol.esphome.LoadProtobuf!"protocol/esphome/api.proto".AlarmControlPanelStateCommand
```

About 1.4 KB of that is the repeated path literal. Shorten the template parameter or nest the
generated types inside one non-template aggregate.

---

## Closed findings

Recorded so they are not re-investigated.

### `[-]` LoadProtobuf CTFE material does not leak

Tested directly. The 77 KB `api.proto` text appears nowhere in the binary (zero hits for
`syntax = "proto3"`, `message HelloRequest`, and similar). The CTFE machinery does not reach the
symbol table either:

```
ProtoSpec 0 syms   generate_enum 0 syms   generate_message 0 syms   ProtoMessage 0 syms
parse_proto 1 sym, 616 bytes
```

So `enum text = import(name)` and `enum ProtoSpec spec = parse_proto(...)` at
[package.d:22-23](../src/tools/protobuf/package.d#L22-L23) evaporate correctly. The single
`parse_proto` leak is covered by S5, and the real remaining cost is the codec matrix in S8.

### `[-]` `assert(__ctfe, msg)` as a size guard

Does not work under `-release` (356 B with and without). Superseded by the
`if (!__ctfe) assert(false, msg)` form in S5.

### `[-]` Templating CTFE-only helpers

Makes them larger, not smaller: 430 B versus a 356 B baseline, plus an extra section.

### `[-]` `enuminfo` string packing

Already efficient. 392 symbols / 45,186 bytes, packing enum names into a flat length-prefixed
`char[]` with `ubyte[]` lookup tables. This is the pattern S16 wants applied elsewhere, not a
target itself.

### `[-]` `manager.spec.compile_spec` as a CTFE leak

False positive in the S5 survey. It is a genuine runtime function; profiles are parsed at runtime.
