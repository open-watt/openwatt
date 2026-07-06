# Automation - command reference

`/automation/add` examples. The first section is what **works today** (built + runtime-verified,
incl. a live Zigbee door->light on the production Pi). The second is the **planned** surface from
[AUTOMATION.draft.md](AUTOMATION.draft.md) - shaping, policy, richer conditions, more providers -
not yet implemented; those commands would be rejected today.

## The shape (today)

```
/automation/add name=<id>
    on=<uri>[,<uri>...]       # trigger signal(s); or use the schedule/at/when sugar below
    [ if=<expr> ]             # optional gate: run only if the (quoted) expression is truthy
    do={ <script> }           # the action
```

Reads like a sentence: **on** X, **if** Y, **do** Z.

**Triggers are signal URIs**: `[provider:|@]body[?k=v&k=v]`. `@x` is sugar for `element:x`. Built-in
providers are `element` (via `@`) and the time schemes `every`/`at`/`when` (cron). Multiple triggers
are comma-separated. **Quote any URI containing `?`, `=`, or `@`** - the CLI parser reserves those
characters, so bare `on=@x` or `on=every:5m?repeat=false` will not parse; `on="@x"` does.

**Time sugar**: `schedule=<dur>` / `at=<hh:mm>` / `when=<datetime>` are write-only shorthands that
translate to `on="every:..."` / `on="at:..."` / `on="when:..."`. Setting `on=` clears the sugar and
vice-versa (they share one slot), so a rule mixing time + events uses `on=` for all of it.

## 1. Working today

```
# THE LIVE ONE: front door contact drives a light switch (running on the prod Pi).
# $value is the value that fired the trigger, so the switch follows the door contact.
/automation/add name=door-light on="@zb_71057949f238c1a4.contact.open" \
    do={ /element/set element=zb_6e88a9348538c1a4.gang1.switch value=$value }

# Element change (short paths).
/automation/add name=hall-light on="@door.open" \
    do={ /element/set element=hall.light value=$value }

# Time: every N (sugar), or the URI form.
/automation/add name=poll    schedule=5m       do={ /device/print }
/automation/add name=poll2   on="every:5m"     do={ /device/print }

# Time of day (sugar), optionally restricted to weekdays via the URI form.
/automation/add name=nightly at=2:00           do={ /device/print }
/automation/add name=weekday on="at:18:00?days=mon,wed,fri" do={ /notify "evening" }

# Absolute one-shot.
/automation/add name=once when=2027-01-01T00:00:00 do={ /notify "happy new year" }
/automation/add name=once2 on="every:30m?repeat=false" do={ /notify "runs once, in 30 min" }

# Condition gate: same trigger, different if= (quote the expression).
/automation/add name=cond on="@site.power" if="@site.power > 2000W" do={ /notify "over 2kW" }
/automation/add name=dark on="@pir.motion"  if="@sun.down"          do={ /element/set element=porch.light value=1 }

# edge/for operate on the if= resolutions (both require if=).
# edge=rising fires once as the condition becomes true, not on every sample above the threshold.
/automation/add name=peak on="@site.power" if="@site.power > 2000W" edge=rising do={ /notify "crossed 2kW" }
# for=: the condition must hold for the window; one run per qualifying episode, cancelled if it drops.
/automation/add name=ajar on="@door.open" if="@door.open" for=5m do={ /notify "door left open 5 min" }
# edge=falling + for= holds the FALSE state: "closed for an hour".
/automation/add name=shut on="@door.open" if="@door.open" edge=falling for=1h do={ /notify "long closed" }

# Multiple triggers (comma-separated, each quoted if it has special chars).
/automation/add name=multi on="@door.open","every:1h" do={ /device/print }

# Temporal shaping. All three hot-apply to a running rule (no restart).
# debounce: act once the trigger stream settles; $value is the settled datum.
/automation/add name=motion on="@pir.motion" debounce=500ms do={ /element/set element=porch.light value=$value }
# throttle: act now, then lock out for the window.
/automation/add name=chatty on="@noisy.sensor" throttle=10s do={ /notify "event" }
# rate + burst: token bucket; sustained ceiling with a burst allowance.
# rate takes any per-time quantity (12/h, 4/min, 0.2/s); it is canonicalised to /s.
/automation/add name=cycles on="@hws.demand" rate=12/h burst=3 do={ /element/set element=hws.enable value=1 }
```

Notes on what's live:
- `on=` values are signal URIs; `@` -> element, `every:`/`at:`/`when:` -> cron time provider. A
  malformed trigger (bad scheme body, unknown provider) is rejected right at the CLI.
- If the referenced element does not exist yet (e.g. a Zigbee device before its scan completes), the
  automation waits in `Starting` with a status of `element not found: <path>` and arms the instant the
  element appears -- no error spam, no backoff.
- `$value` is the datum that fired the trigger, snapshotted at the moment of change. Prefer it to
  re-reading `@path` in the action: a live re-read can race a later change, `$value` cannot. It is
  null for value-less triggers (time).
- `/element/set` takes named args: `element=<path> value=<val>`; `@path` still reads an element's live
  value at run time when you want the current value of some *other* element.
- The `if=` expression is evaluated on every fire; a falsey result skips the action. It can read any
  element by `@path` and use comparisons/operators (`>`, `<`, `&&`, `||`, units like `2000W`).
- Shaping order is peek-early / commit-late: throttle/rate drop bursts before `if=` is evaluated, but
  the lockout / token spend only commits when the action actually runs, so a false condition costs
  nothing. Unit spelling notes: per-minute is `/min` (`/m` is per-metre), numeric denominators like
  `3/1h` are not a thing (pick a unit), and `Hz` is angular (Cycle/Second) so it is rejected here.

## 2. Managing them

```
/automation/print                      # list all
/automation/set name=door-light if="@door.open"   # change a property
/automation/remove name=poll
```

## 3. Planned (NOT yet built)

These are the design targets from [AUTOMATION.draft.md](AUTOMATION.draft.md). The syntax below is
illustrative and would be rejected today.

```
# More providers (mqtt/zigbee/sun/http) - only element + time exist today.
/automation/add name=wow  on="mqtt:/wow/+/#?qos=1"        do={ /log $trigger.payload }
/automation/add name=dusk on="sun:sunset?offset=-15m"     do={ /element/set element=garden.lights value=1 }

# Execution policy - none implemented.
/automation/add name=setpoint on="@target.power" overrun=coalesce catch_up=skip on_error=disable \
    do={ /element/set element=inverter.limit value=@target.power }

# Typed trigger payload ($trigger.*) - SignalEvent carries only .source today.
/automation/add name=echo on="mqtt:/sensors/#" do={ /log "got " .. $trigger.topic .. " = " .. $trigger.payload }
```

Planned building blocks, in order (see the design doc's Phasing): execution policy
(`overrun`/`catch_up`/`on_error`), the `on` completer, typed `$trigger.*` context, and more
providers (mqtt/zigbee/sun/http).
