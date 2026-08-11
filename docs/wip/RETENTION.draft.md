# Element Retention and Recording (proposal)

Status: partially implemented. The model (a declared recording intent per element,
[manager/device.d](../../src/manager/device.d)) and byte-budget accounting
([manager/element.d](../../src/manager/element.d), `evict_over_budget`) have landed. The
profile grammar of section 4 and the CLI surface of section 6 have not; the former is tracked
as "Give profiles control over retention and recording" in [TODO.md](../../TODO.md). Delete
this file once those two land.

This proposal unifies element history (RAM) and the recorder (disk) under one declared
*recording intent* per element, with byte-budget accounting, inheritance from profiles,
runtime override, and an observable CLI surface. It replaces the current situation where
RAM policy and disk policy are two unrelated mechanisms that interact accidentally through
`ensure_history()`.

## 1. Problem

Mechanically the series layer is in good shape: `SeriesStore` has a sound floor/ceiling/pin
retention model, buckets seal and shrink, cursors report loss when lapped. The problems are
all in *policy* - who decides what an element retains, and how anyone finds out:

- Retention defaults are three `enum`s buried in `apply_default_retention()` (256 records,
  16384 records, 1h). Not per-profile, not per-element, not visible, not settable.
- Only profile-materialised devices get those defaults. Elements created through
  `find_or_create_element` (Zigbee interview, HA discovery, Tesla, ESPHome) get no history,
  and if anything opens a cursor on them they get *limit-free* history: all four retention
  knobs zero means `evict_over_budget()` returns immediately and the buffer grows forever.
- Opening a cursor silently allocates history. The recorder's `filter=*` therefore hands
  unbounded buffers to exactly the elements the defaults deliberately skipped (constants,
  config values) and to every non-profile element.
- Disk policy is a path glob on the Recorder. There is no way to say "keep this in RAM
  generously but never write it to disk", or "this element must reach disk". RAM and disk
  policy share no vocabulary.
- Budgets are counts and ages; there is no byte budget per element, no global accounting,
  and no way to ask the running system how much RAM history is using.
- Non-serialisable formats (text, user types, device-clock domains) are silently skipped by
  the recorder but keep their pinned cursor, degrading to forced eviction and silent loss.
- On-disk growth is uncontrolled: nothing prunes or decimates `.ows` containers.
- The legacy `db` module is vestigial (nothing pushes samples any more) but still costs one
  fd per stream and still serves stale `.owr` fallback queries.

## 2. The model: one intent, three tiers

Every element resolves to exactly one *recording intent*:

| intent   | meaning                                                              |
|----------|----------------------------------------------------------------------|
| `latest` | no history: 8-byte latest + timestamp only (today's null `_history`) |
| `memory` | RAM series with a retention policy (window / records / bytes)        |
| `disk`   | `memory` plus the recorder persists it; disk has its own retention   |

`disk` implies `memory`: the RAM series is the intake buffer the recorder drains, exactly
as `RecordStream.flush()` works today. The tiers are strictly ordered so a single token
names the whole story.

A retention *policy* is attached to the `memory` and `disk` tiers:

    retain = { min_records, max_records, min_age, max_age, max_bytes }

`max_bytes` is new (records * stride + offsets, accounted per bucket). The existing
floor/ceiling/pin semantics are unchanged; bytes join records and age as a third ceiling
axis. Eviction stays whole-bucket.

Rules the mechanism must start enforcing:

- History never exists without a policy. `ensure_history()` grows a policy parameter;
  a cursor opened against a `latest` element does not allocate history - it reads the
  empty store and reports nothing. Consumers that need history must raise the element's
  intent (explicitly, observably), not conjure a buffer as a side effect.
- Every element gets an intent, including non-profile elements. The resolution chain
  (section 3) bottoms out in platform defaults, so Zigbee/HA/discovered elements land on
  the same policy surface as profile elements.

## 3. Policy resolution

Most specific wins; each level only needs to state what it overrides:

1. Runtime override (CLI, section 6) - per element or wildcard pattern.
2. Profile element token (section 4).
3. Profile component / profile-header defaults (section 4).
4. Binding/device property (`/binding/... retain=...`) for whole-device adjustment.
5. Platform defaults, scaled by tier: full desktop/Pi builds default sampled elements to
   `memory` with today's numbers (promoted from enums to configurable state); TINY targets
   default to `latest` for everything, opt-in per element.

Sampling mode keeps its current role as an input to the *default* (constants and config
values default to `latest`), but any level may override it - a config value can be recorded
if someone asks.

Resolution happens at element creation and re-runs when a level changes (a runtime override
or a profile reload walks the affected subtree, same shape as `apply_default_retention`
today). The resolved policy is stored on the element; resolution is not a per-write lookup.

## 4. Profile grammar

Two additions to the profile format.

**Element token.** The descriptor line grows an optional retention token after the
sample frequency:

    reg: 30000, f32, V,   desc: voltage, V, realtime, retain=24h, "Voltage"
    reg: 31000, u32, Wh,  desc: energy,  Wh, high,    retain=disk, "Lifetime energy"
    reg: 40020, f32/RW,   desc: address, ,  config,   retain=none, "Modbus address"

Token forms: `retain=none` (latest only), `retain=<age>` (memory, window), `retain=disk`
or `retain=disk:<age>` (disk tier; the age bounds the *disk* series, RAM intake stays at
the memory default). Count/byte bounds are policy-level detail and live in defaults blocks,
not on individual lines.

**Defaults block.** Profile- or component-scope:

    retention:
        default: 1h
        battery.*: 24h, disk
        *.serial: none

Patterns match element paths relative to the scope. This is where per-class byte budgets
can be stated when needed (`battery.*: 24h, 64K`).

**Accounting hints.** Profiles already declare sample frequency, which is an expected data
rate: `realtime` = 400ms, `high` = 1s, etc. The accountant (section 5) uses
`window / period * stride` to *estimate* each element's steady-state footprint at profile
load, so a device's declared cost is known before a single sample arrives. Profiles do not
declare bytes directly; they declare rate (already) and window (new), and the system does
the arithmetic. Event-driven elements (`report`) have no declared rate, so they estimate
from observed rate and are the reason byte ceilings exist at all.

## 5. Memory accounting

A single global accountant, not a hard allocator:

- Each `SeriesStore` reports its allocated bytes on bucket alloc/free (cheap counters, no
  scanning). Rollups aggregate per element -> component -> device -> total.
- A configurable global budget (`/system/history/set budget=512M`; default scaled by
  platform tier, e.g. 1-2G on desktop, tens of MB on Pi-class, ~0 on TINY). The budget is
  soft: when total allocation crosses it, the accountant applies pressure by tightening
  effective `max_age`/`max_bytes` ceilings proportionally across elements that are over
  their *estimated* footprint, largest overshoot first. Pinned-but-stalled consumers get
  lapped exactly as the existing ceiling semantics prescribe.
- Estimates vs actuals are both reported, so a profile whose declared rates are wrong is
  visible ("estimated 2M, holding 40M").

This deliberately keeps per-element policy primary and the global budget as a backstop;
we do not build a cache with global LRU across elements.

## 6. CLI surface

Observability first - none of this exists today:

    /system/history/print                    # total bytes, budget, element count per intent
    /system/history/print device=inverter    # rollup per component/element:
                                             #   records, buckets, bytes, window, intent,
                                             #   cursors (and who holds them), estimate vs actual

Policy:

    /system/history/set budget=512M
    /system/history/retain add match="inverter.battery.*" window=24h intent=disk
    /system/history/retain add match="*.debug.*" intent=none
    /system/history/retain print

Runtime overrides are a small ordered Collection of match rules (level 1 of the resolution
chain), so they survive as console commands in startup.conf like everything else, and
`remove` restores the underlying default.

Recorder simplifies: it stops being the policy and becomes the disk sink:

    /record/add name=rec dir=records disk-budget=8G

`filter` is deleted (or retained as an additional *restriction* for split-storage setups,
e.g. two recorders on two disks). A recorder serves every element whose resolved intent is
`disk`; if no recorder exists, `disk` elements run as `memory` and report themselves as
unserviced in `/system/history/print`. Disk retention (prune/decimate old blocks toward
`disk-budget` and per-element disk windows) is the recorder's job; the decimation ladder
from the data-model design lands behind this same property.

## 7. Code surface

- `Element.retention(...)` overloads collapse into `Element.set_policy(ref const RetentionPolicy)`,
  applied by the resolver only. Direct calls from protocol code (gpio's
  `ensure_history()` scaffold) are replaced by intent declarations at element creation:
  `find_or_create_element(name, format, RecordIntent.memory)` or a resolver hook, so the
  policy chain always has the last word.
- `ensure_history(policy)` asserts a policy is present; a debug assert fires on any path
  that would create an unbounded store.
- Cursor open stops allocating history (section 2). `open_series_cursor` on a `latest`
  element returns an always-empty cursor; the 16-slot limit gets a graceful failure
  (return invalid cursor + log) instead of `assert(false)`.
- Non-serialisable formats: the recorder refuses the *attach* (element reports
  "disk intent unserviceable: no codec" in history/print) instead of silently pinning.
  When text/user codecs land, the refusal path simply stops triggering.
- The legacy db series handle is removed from `RecordStream`; `.owr` query fallback goes
  with it (one release note; existing `.owr` archives are dead weight).

## 8. Open questions

- Pressure policy detail: proportional tightening is stated above, but "who loses first"
  deserves one more pass once real workloads exist (age-weighted? intent-weighted so
  `disk` intake never loses to `memory` browsing?).
- Should runtime overrides persist per element after rename/re-profile, or stay
  pattern-based only (current proposal: pattern-based only, simpler and startup.conf-native)?
- Disk decimation ladder specifics (bucket packing, stripe reuse) are already tracked in
  TODO.md "Finish series storage and recording" and stay out of scope here beyond the
  `disk-budget` property they serve.
- Whether `/system/history` is the right home vs a top-level `/history` scope; it wants to
  sit beside `/record` in discoverability.
- Sync consumers: should a consumer peer be able to *request* elevated retention (a lease:
  "keep 24h of these while I'm attached")? Leases fit the pin model naturally but need an
  expiry story. Client-visible either way: UX_TODO entry required when this lands.
