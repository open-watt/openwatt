# TODO: element time semantics (parked work)

**This branch carries the arrival-order element-time rework that was backed out of
PR #439 (`ow/component-link`). The code here WORKS on 64-bit but its unit tests
exposed a pre-existing 32-bit urt time bug that fails x86 CI. Do not merge until
that is resolved. The rationale below is the state of the design discussion.**

## The problem thread

Element links (PR #439) needed a rule for delivering into linked elements without
creating write cycles or fighting computed elements. The first attempt used wall
timestamps as an ordering key: reject writes stamped older than the element's
record clock ("stale samples are not applied"). That was unsound for two reasons:

1. **Wall stamps come from more than one derivation.** Protocols stamp with
   `cast(SysTime)getTime()` (mono converted through the boot-time calibration
   offset); direct writes stamp with `getSysTime()`. Their relative error
   (calibration + NTP slew) can exceed the gap between consecutive writes, so a
   newer write can arrive looking older and get dropped. This flaked CI.
2. **`/sync` adjusts UTC at runtime by design.** After a backward adjustment,
   every new write is older-stamped than existing records; strict rejection
   would wedge every element until wall catches up. Wall time in OpenWatt is
   not monotonic and can never be an ordering key.

## The model on this branch

Ordering authority belongs to the clock that is actually monotonic:

- Writes always apply, in **arrival order**.
- `Element.last_update` follows the applied record, so value and timestamp
  always describe the same observation (they could previously diverge:
  an out-of-order write updated the record but not the stamp).
- A new `Element.last_arrival` (MonoTime) records write sequence and is the
  sequencing authority. Link initial-sync compares arrival, not wall.
- Link delivery propagates any update the destination does not already hold
  ((timestamp, value) identity). This converges in arrival order and still
  terminates cycles: a value that lapped a link mesh arrives identical.
- Genuine staleness/duplicate discrimination belongs to tick-domain series
  clocks (`ClockDomain`), where ordering is well defined.

## Related follow-ups (not on this branch)

- **Clock changes for tick series**: on a UTC adjustment, the series-local mono
  clock just continues and a new `ClockAnchor` is pinned at the adjustment
  moment. `ClockDomain.to_wall`/`from_wall` must then select the anchor
  contemporaneous with the record index (currently they always use
  `anchors[$-1]`, which would retroactively re-interpret pre-adjustment
  history). `adjust_utc_time` is the natural pin trigger.
- **Demote `last_update`**: after this branch it always equals `record_update`
  except for `force_update`, whose advancing exists only so accumulators get
  correct integration intervals. Move that bookkeeping into the accumulator
  `Computation` and `last_update` becomes a read-only property over
  `record_update`; the mutable wall field dies.

## Bugs discovered while working this (both pre-existing)

- **urt x86-32 time is broken (strong hypothesis, verify before trusting)**:
  `urt.internal.sys.posix` declares `time_t = long` (always 64-bit in D), but
  32-bit linux glibc's `clock_gettime` fills a timespec with 32-bit fields.
  The kernel writes 8 bytes into a 16-byte struct and `tv_sec` reads garbage,
  making `getTime()` non-monotonic on x86-32. This is what actually failed
  x86 CI on this branch (`assert(st.last_arrival >= first_arrival)`), and it
  most likely also caused the earlier x86 ha_discovery flake. Fix in urt
  (use `__clock_gettime64` / correct 32-bit timespec layout), then this
  branch's tests should pass.
- **Layout-sensitive segfault in `urt.internal.exception`'s unittest on
  Windows**: the dbghelp/stack-walk test crashes or passes depending purely on
  binary layout; any code-size change in `src/manager/package.d` can flip it.
  Suspect `_resolve_address`/dbghelp needing an SEH guard.
