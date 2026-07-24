# Automation

Status: partially implemented. This document is the full design vision; the section below records
what is actually built so the rest reads as intent, not fact.

## Implementation status (2026-07-12)

**Built + runtime-verified** (incl. a live Zigbee door->light on the production Pi):
- The general **signal** framework in [src/manager/signal.d](../src/manager/signal.d): `ISignalProvider`
  (validate / subscribe / unsubscribe / next_run), the opaque `SignalSub` handle (with a `provider()`
  method), `SignalEvent` (`.source` + `.value`), `SignalSink` (carries a `MonoTime`), `SignalUri` +
  `parse_signal_uri`. Errors are `StringResult`. **The registry lives on the `Application`**
  (`g_app.register_signal_provider` / `find_signal_provider`), so any subsystem can provide or consume
  signals.
- Providers: **cron** ([src/manager/cron.d](../src/manager/cron.d)) is the time provider (`every:` /
  `at:` / `when:`); the **`Application` itself** is the `element:` provider (`@` sentinel).
- The `Automation` object ([src/apps/automation/automation.d](../src/apps/automation/automation.d)):
  `on=<uri>,<uri>` (comma-separated signal URIs), `if=<expr>` (a quoted boolean gate), `do={...}`,
  and the write-only time sugar `schedule=` / `at=` / `when=`. Observability: `last_run`, `next_run`
  (min across triggers, including a pending debounce settle), `run_count`.
- **Three-outcome arming**: a bad URI is rejected at the CLI (provider `validate()`); a reference to a
  not-yet-created element parks the rule in Starting, re-trying each frame with the reason shown in
  `status_message` ("element not found: ..."), and arms the moment the element appears. No backoff, no
  log spam. (True event-driven attach, subscribing on element creation, remains future work.)
- **Trigger context**: the element provider snapshots the changed value into `SignalEvent.value`, and
  the action sees it as `$value` (owned copy at change time; null for value-less triggers like time).
- **Condition leg complete**: `edge=level|rising|falling` and `for=<dur>`, operating on the
  *resolutions* of `if=` (both require it; validated). Each settled trigger evaluates the condition
  once; `edge=` fires on the chosen transition between consecutive observations, `for=` requires the
  qualifying polarity (truth, or falseness for `edge=falling`) to hold for the window -- armed when it
  begins, cancelled the moment an observation finds it dropped, **one run per qualifying episode**,
  with a final live re-evaluation at the deadline so silent drops can't slip through. Seeding: on arm
  the tracker is primed so an already-true condition is not an edge; a `level` `for=` arms from state
  at boot ("open for 5m" spans a restart) while rising/falling arm only from an observed transition.
  Both hot-apply; a pending `for=` deadline folds into `next_run`. Caveat: the condition is observed
  at trigger times (plus the deadline check), not continuously monitored.
- **Temporal shaping**, all three knobs, hot-applied on a running rule (setters do not restart):
  - `debounce=<dur>`: trailing edge; each trigger (re)starts the settle window, holding an owned
    snapshot of the latest event; the action runs once on settle, so `$value` is the settled datum.
  - `throttle=<dur>`: leading edge; act, then lock out for the window.
  - `rate=<per-time>` + `burst=<n>`: token bucket; capacity `burst` (default 1), refill `rate`.
  - Ordering is **peek early, commit late**: throttle/rate drop bursts before the `if=` condition is
    evaluated (cheap), but the lockout stamp / token spend commits only when the action actually runs,
    so a false condition never consumes the budget. All shaping timing is `MonoTime`.
- **Cutover done**: `CronJob` and the `/system/cron` collection are deleted; cron collapsed to the
  single-file time provider; OTA's one-shot uses `AutomationModule.schedule_oneshot`.

**Naming**: this doc drafted the interface as `TriggerProvider` / `TriggerSub` / `TriggerSink` /
`TriggerEvent` with a `trigger_types` registry. As built these are **`ISignalProvider` / `SignalSub`
/ `SignalSink` / `SignalEvent`**, and the registry is `signal_providers` on the `Application`. Read
"trigger" below as "signal".

**Not yet built** (design only, below): execution policy (`overrun`/`catch_up`/`on_error`); the
per-property `on` completer; the wider typed `$trigger.*` context (only the flat `$value` exists
today); providers beyond element+time (mqtt/zigbee/sun/http); event-driven element attach (see the
arming note above); and the element `?deadband=` subscription param (settled design in
[TODO.md](../TODO.md) "Data model" - pass-through to the element subscription, see the `on=` URI
section).

**Syntax reality** vs earlier drafts in this doc: the condition keyword is `if=` (not `condition=`);
triggers are `on=` URIs of form `[provider:|@]body[?k=v&k=v]` (not the `mqtt(...)` call form) and must
be **quoted** at the CLI when they contain `?` `=` `@`; `days=`/`repeat=` are not sugar (use the URI
`?days=`/`?repeat=false`); `/element/set` takes named args `element=` / `value=`. Shaping deltas from
the design below: the doc's `rate=<n>/<dur>` is split into `rate=` (a per-time quantity: `12/h`,
`4/min`, `0.2/s` all convert to canonical `/s` at the property boundary) plus `burst=<n>` (bucket
capacity, default 1) because canonicalisation discards the as-written numerator. Numeric denominators
(`3/1h`) are not a unit spelling; use `0.05/min` or pick a unit. `/m` is per-METRE (SI), per-minute is
`/min`. `Hz` is rejected: as defined it is `Cycle/Second`, an angular frequency (1 Hz normalises to
2*pi rad/s), dimensionally distinct from plain per-time.

## Summary

OpenWatt has a `Cron` subsystem that runs a `do={...}` console script on a schedule.
That is a narrow special case of a much more useful thing: a rule that runs an action
when *something happens*, where "the clock reached T" is only one of the things that can
happen. This document proposes folding `Cron` into a general, IFTTT-style **Automation**
engine.

An automation is a `Collection`-managed `ActiveObject`. You create one with an id like any
other object, it lives in the automation pool, and it is configured entirely through the
console (no config files, same as everything else):

```
/automation/add name=door-light on="@door.open" \
    do={ /element/set element=hall.light value=@door.open }
```

The model has four legs:

```
triggers  ->  condition  ->  temporal shaping  ->  execution policy  ->  action
(wake it)     (proceed?)     (smooth the stream)   (how runs relate)     (do={...})
```

Cron is the degenerate rule: one time trigger, no condition, no shaping, a script.
Everything below preserves existing cron behaviour as the defaults of the general model.

## The object

```d
class Automation : ActiveObject
{
    // properties reflected to the console (add/set/get/print) as usual
    enum type_name = "automation";
    enum path = "/automation";
    enum collection_id = CollectionType.automation;
    ...
}
```

- Registered as `Collection!Automation` from an `AutomationModule` (the renamed
  `CronModule`), living under `src/apps/automation/`.
- Lifecycle mirrors [CronJob](../src/manager/cron/job.d):
  - `validate()` - at least one trigger and an action are present.
  - `startup()` - compile the condition and action once, arm time triggers via
    `g_app.schedule()`, subscribe to element triggers. Subscribe at the *end* of startup,
    track with a `_subscribed` flag (per the ObjectRef discipline in AGENTS.md).
  - `shutdown()` - cancel scheduled wakes, unsubscribe, and `request_cancel()` any
    in-flight action commands, then drain them.
  - Property setters tear down subscriptions and `restart()` on change.
- Running actions are async (`CommandState`) and tracked in a `_running_commands` array
  exactly as cron does today.

## The rule model

### 1. Triggers - what wakes the rule

Triggers are the only thing that causes evaluation. Two families:

**Time triggers** (preserved verbatim from cron, wall-clock based):

| Property | Meaning |
|---|---|
| `schedule=<dur>` | every N (e.g. `5m`) |
| `at=<HH:MM>` `days=mon,wed,fri` | daily / weekly time-of-day |
| `when=<datetime>` | absolute one-shot |
| `repeat=false` | make any kind one-shot |

**Element triggers** (new, event/subscription based):

| Property | Meaning |
|---|---|
| `on=@path[,@path...]` | fire when any listed element's value changes |

Element paths use the expression element sigil `@device.component.element`
(see [expression.d](../src/manager/expression.d)); a leading dot forces a global path.
Elements only signal on an *actual* value change, so there are no spurious re-fires.

Target model: triggers are **additive** (a rule may wake on `at=07:00` *and* `on=@door.open`).
See Phasing for why v1 likely keeps cron's single mutually-exclusive discriminant first.

### 2. Condition - whether to proceed

An optional gate evaluated when a trigger fires. It reuses the expression engine that the
energy policy layer already runs on.

| Property | Meaning |
|---|---|
| `condition=<expr>` | boolean gate, e.g. `"@power > 2000W && @battery.soc < 80%"` |
| `edge=level\|rising\|falling` | how the condition's truthiness maps to firing |
| `for=<dur>` | condition must hold continuously for this long before firing (cancellable) |

`edge` folds edge-detection into the model without a separate trigger kind:

- `level` (default): fire whenever a trigger fires and the condition is currently true.
- `rising`: fire only on the false->true transition of the condition.
- `falling`: fire only on the true->false transition.

For a *boolean* element, `level` already behaves like a rising edge, because the value only
ever transitions to/from true and the gate passes on the true transition. `edge=rising`
earns its keep for predicates over continuous values: `condition="@power > 2000W"` with
`edge=level` fires on every sample above the threshold; with `edge=rising` it fires *once*
as power crosses it.

`for=` is the "door open **for** 5 minutes" qualifier. It is a cancellable timer on the
condition, not the action: if the condition drops before the window elapses, nothing fires.

### 3. Temporal shaping - smoothing the trigger stream

These shape *how often the rule may fire*, independent of the condition. They are distinct
primitives, not one knob (they differ on leading/trailing edge, drop-vs-coalesce, and
whether the window is measured from the last trigger or the last action):

| Property | Behaviour | For |
|---|---|---|
| `debounce=<dur>` | trailing: wait for quiet (window resets on each trigger), then act once on the settled state | flappy contact, bouncing switch |
| `throttle=<dur>` | leading: act now, then lock out for the window | chatty sensor you do not want to spam on |
| `rate=<n>/<dur>` | at most N firings per interval (token bucket); excess dropped | hard ceiling (generalises the allocator's TODO `max_cycles_per_hour`) |

All shaping durations are **elapsed time and therefore use `MonoTime`**, immune to
wall-clock sync jumps. Only the *time triggers* above use wall-clock. This is the clock
domain discipline the allocator already follows; mixing the two compiles silently, so it is
called out deliberately.

Shaping is off (`0`) by default. A hidden global debounce would mask flapping, which is
usually a real signal (a sensor bouncing 10x/second is a bug worth seeing). Opt in per rule.

Note: rule-level shaping protects against *this rule* spamming, not the *device*. If many
rules command one actuator, or an automation drives an energy `Control`, the device-level
anti-chatter is the allocator's `min_dwell`/`min_on_time` at the control layer. Do not
double-shape the same command in two places.

### 4. Execution policy - how runs relate to each other

Because actions are async and can span ticks, triggers can arrive while a run is in flight,
or be missed while the box was down. Cron today has *accidental* behaviour here (a slow
async body lets runs overlap and stack in `_running_commands`, which nobody chose). The
policy leg makes this explicit:

| Property | Question | Options | Default |
|---|---|---|---|
| `overrun=` | trigger fires while the last action still runs | `skip` / `queue` / `restart` / `coalesce` | `coalesce` |
| `catch_up=` | a scheduled time passed while we were down / late | `skip` / `once` / `all` (+ grace `catch_up=30m`) | `skip` |
| `on_error=` | the action script fails | `ignore` / `retry` / `disable` | `ignore` (log) |

- **overrun**: `coalesce` runs once more for a burst with the latest data (right for "set the
  light to the door's state" - you want the final state, not five stacked runs). `queue`
  runs once per trigger in order (right for counting/logging where every event matters).
  `restart` cancels the in-flight action via `request_cancel()` and starts fresh with the
  newest inputs. `skip` never stacks. This is the "run for each vs run once" fork, per-rule.
- **catch_up**: anacron-style. `skip` is safest ("morning lights" firing at noon because you
  booted late is wrong). `once` runs a single catch-up; `all` fires every missed occurrence
  (usually wrong). An optional grace window runs the missed occurrence only if less than N
  late.
- **on_error** is per-*run* outcome, distinct from `BaseObject`'s exponential backoff, which
  is per-*object* lifecycle failure.

### The action

`do={ ... }` is the same script machinery cron uses: parsed to a `Script`, executed through
`Console.execute` on an internal `Session`. It can run any console command, branch with
`:if`, set locals with `:set`, and return with `:return`.

Setting an element value is a normal console command:

```
/element/set hall.light 1
```

**Snapshot vs live.** When a run is delayed (queued, debounced, or `for=`), the action can
see values two ways, and it needs both:

- `@door.open` re-reads the element **live** at execution time (the "act on current reality"
  default).
- `$trigger.value` / `$trigger.prev` / `$trigger.element` are **captured** from the change
  that woke the rule (the exact edge, for logging or arithmetic on the crossing value).

"Set light = current door state" wants live; "log the value that crossed 2000W" wants the
snapshot.

## The pipeline

```
   time trigger ----+
                    |
   element change --+--> [ shaping ]  --> [ condition ] --> [ overrun ] --> action
   (on=@x)               debounce         condition/edge     skip/queue      do={...}
                         throttle/rate    for=<dur>          restart/coal
```

Each stage is orthogonal and composable. Shaping acts on the *trigger stream*; overrun acts
on *action-in-flight*. They are different problems and are not one setting.

## Config surface (summary)

```
/automation/add name=<id>
    # triggers (>= 1)
    [ schedule=<dur> | at=<HH:MM> days=<...> | when=<datetime> | on=@path[,...] ]
    [ repeat=<bool> ]
    # condition
    [ condition=<expr> ] [ edge=level|rising|falling ] [ for=<dur> ]
    # shaping
    [ debounce=<dur> ] [ throttle=<dur> ] [ rate=<n>/<dur> ]
    # policy
    [ overrun=skip|queue|restart|coalesce ] [ catch_up=skip|once|all ] [ on_error=ignore|retry|disable ]
    # action
    do={ <script> }
    [ enabled=<bool> ]
```

## Worked examples

Door drives a light (single rule, branching action):

```
/automation/add name=door-light on="@door.open" \
    do={ /element/set element=hall.light value=@door.open }
```

Door drives a light (two declarative rules):

```
/automation/add name=door-on  on=@door.open condition=@door.open   do={ /element/set hall.light 1 }
/automation/add name=door-off on=@door.open condition=!@door.open  do={ /element/set hall.light 0 }
```

Alert only if the door is left open:

```
/automation/add name=door-ajar on=@door.open condition=@door.open for=5m \
    do={ /notify "front door open 5 min" }
```

Fire once as load crosses a threshold, not on every sample above it:

```
/automation/add name=peak on=@site.power condition="@site.power > 2000W" edge=rising \
    do={ /notify "peak load" }
```

Flappy sensor, act on the settled state at most once per burst:

```
/automation/add name=motion on=@pir.motion debounce=500ms \
    do={ /element/set porch.light @pir.motion }
```

Time trigger (unchanged cron behaviour):

```
/automation/add name=nightly at=02:00 do={ /device/print }
```

## Semantics that need care

**Commanding real hardware.** `/element/set` calls `element.value()`, which updates the
local value and notifies subscribers. It commands a device only when the target element is
writable and its binding subscribed it: bindings subscribe to elements with `Access.write`
(for example [modbus binding](../src/protocol/modbus/binding.d)) and push the change out.
Setting a read-only sensor element just updates the local value. The implementation should
surface "target is not writable" rather than silently no-op.

**Re-entrancy / loops.** Automations both subscribe to and write elements, so they can form
feedback loops (a rule on A writes B, a rule on B writes A). The element system already
carries a `who` cookie for cycle-breaking; actions pass `who=this` so a rule does not
re-trigger itself, and the engine bounds re-entrancy (a per-tick "already fired" guard /
depth limit).

**Startup seeding.** On `startup()`, seed condition state (the `edge`/`for` bookkeeping) by
evaluating once *without firing*, so a rule does not fire on boot merely because its
condition is already true. A boot may optionally count as a missed occurrence for time
triggers (see `catch_up`).

## What this reuses

Almost all of the machinery exists; the automation object is mostly wiring.

| Automation needs | Exists as | Where |
|---|---|---|
| condition / expression language, compile-once eval-many, unit-aware | `expression.d` (live in the energy policy layer) | [expression.d](../src/manager/expression.d), [policy.d](../src/apps/energy/policy.d) |
| discover which elements a condition references (to subscribe) | `Expression.gather_elements()` | [expression.d](../src/manager/expression.d) |
| react to committed samples | `Element.subscribe(Subscriber)` | [element.d](../src/manager/element.d) |
| action script parse + execute | `make_script` + `Console.execute` (cron's `do={}`) | [expression.d](../src/manager/expression.d), [cron/job.d](../src/manager/cron/job.d) |
| set an element | `/element/set` | [manager/package.d](../src/manager/package.d) |
| command hardware on set | binding write-back on `Access.write` elements | [modbus/binding.d](../src/protocol/modbus/binding.d) |
| scheduled wakes | `g_app.schedule()` / `schedule_oneshot` | [cron/job.d](../src/manager/cron/job.d) |
| CRUD, lifecycle, backoff, async command tracking | `Collection` + `ActiveObject` | [collection.d](../src/manager/collection.d), [base.d](../src/manager/base.d) |

## Extensible triggers

Trigger kinds must be open-ended and feature-gated. A protocol or custom application module
should be able to register a new trigger type: the MQTT module contributes a "filtered
publish" trigger, the Zigbee module an "attribute report" trigger, and so on. If MQTT is not
compiled into the binary, that trigger type simply does not exist, and neither the console nor
the UI offers it. The trigger description language is therefore **open-vocabulary**.

This is the established OpenWatt idiom (modules register capabilities in `init()`), so triggers
become a registry that is a direct peer of the expression engine's `intrinsic_functions`
([manager/package.d](../src/manager/package.d): `register_intrinsic` /
`Map!(String, IntrinsicFunction)`). Same shape, one level up.

### The registry

`Application` gains a `Map!(String, TriggerType*) trigger_types` and a
`register_trigger_type(...)`, called from module `init()`:

- The core `AutomationModule` registers the built-ins: `element` and `time` (`schedule`/`at`/
  `when`). Built-ins go through the same registry - **the engine hardcodes no trigger kind**.
- `MqttModule` registers `mqtt`; `ZigbeeModule` registers `zigbee`; etc. Only when compiled.

The contract has two roles. The **provider** is the service that owns the event source (the
MQTT module, the core element/time machinery). The **consumer** is the automation engine. A
provider registers a descriptor that gives the engine two capabilities:

1. **Describe the event** so the engine can express it - in the config language, in validation,
   and in the UI. This is a name, a typed parameter schema, and the set of context fields the
   event delivers. The engine and UI need nothing type-specific beyond this.
2. **Subscribe to the event** with supplied config, and receive callbacks when it fires. The
   engine calls `subscribe(config, sink)`; the provider starts delivering and returns an opaque
   handle; the engine calls `unsubscribe(handle)` to stop.

Sketch:

```d
struct TriggerProvider              // registered once per event type in a module's init()
{
    String name;                    // "mqtt" - keyword and UI label
    const(ParamDesc)[] params;      // typed config schema: drives console parse AND UI form
    const(char)[][] context;        // the $trigger.* fields this event delivers

    // engine -> provider: start delivering; returns an opaque, provider-owned handle
    TriggerSub* delegate(ref Map!(String, Variant) config, TriggerSink sink) subscribe;
    void        delegate(TriggerSub* handle) unsubscribe;

    // optional: predict the next fire time. time/sun/scheduled providers implement it;
    // event-driven providers (mqtt/element/zigbee) leave it null (they cannot foresee an edge).
    Nullable!SysTime delegate(TriggerSub* handle) next_run;
}

alias TriggerSink = void delegate(ref const TriggerEvent ev) nothrow @nogc;   // provider -> engine
```

The engine parses the trigger's config against `params` into a `Map!(String, Variant)` (so the
console and the UI both get generic parsing and rendering for free), hands it to `subscribe`,
and holds the returned handle for the automation's lifetime. When the event fires the provider
builds a `TriggerEvent` whose fields become the action's `$trigger.*` locals (`mqtt`:
topic/payload; `element`: element/value/prev; `time`: the scheduled instant).

Decoupling that matters:

- The engine holds an **opaque handle** and knows nothing protocol-specific. All MQTT/Zigbee/etc.
  knowledge stays in the provider.
- The **provider owns source liveness**. The MQTT provider already manages its client and
  reconnects; it keeps the subscription alive across a reconnect so the engine's handle stays
  valid. Source churn (an `ObjectRef` going offline/online, per AGENTS.md) is the provider's
  concern, not the engine's. The engine only subscribes at automation `startup()` and
  unsubscribes at `shutdown()`.
- Config parsing is **schema-driven** by default (free console parse + free UI form). A provider
  with an exotic parameter (a complex topic-filter grammar) can mark that param raw and parse it
  itself inside `subscribe`.

The engine-side per-automation object is then a thin wrapper: provider name, parsed config, and
the live handle, routing the sink callback into `automation.fire()`. The built-in `element` and
`time` triggers are just providers registered by the core module, so the engine special-cases
nothing.

### `on=` is a URI, and the provider owns its DSL

A trigger is not a predicate and is never evaluated or polled: it is an *addressable event
source*. The surface reflects that: `on=` is a URI with the grammar

```
[provider: | @] id [?param=value[&param=value[&...]]]
```

the scheme is the provider, `id` is the provider's opaque body, and the optional `&`-joined
query carries named params. `@` is a sentinel for the element provider, so `@door.open` is
sugar for `element:door.open` (the common case stays a bare sigil).

```
on=@door.open                 # element - the @ sigil is the element scheme, no prefix needed
on=at:18:00     on=every:5m   # built-in time providers
on=mqtt:/wow/+/#?qos=1         # provider:body?params
on=zigbee:0x1234/onoff/state
on=sun:sunset?offset=-15m
on=@motor.power?deadband=100W  # element param: value-domain filter on this subscription
```

The `?deadband=` param above is the automation surface of the element deadband design (settled,
parked in [TODO.md](../TODO.md) "Data model"): the filter itself is per-subscription state in the
element's subscriber machinery, with element metadata supplying the default band; the automation
never implements it - the element provider just passes the param through as the override on the
subscription the rule was already creating. This is what makes debounce meaningful on analog
signals: sub-band ripple generates no events, so `on="@motor.power?deadband=100W" debounce=5s`
fires once when the motor settles after its inrush.

The `on=` argument is **raw-captured** (grabbed as source text, never expression-parsed), which
is what lets the body use `: / + # ? =` freely without quotes - they are bytes the provider
reads, not expression tokens. The only forbidden character is a space, and URIs are space-free
by nature. Contrast `if=`, which genuinely is an expression to evaluate and so uses the
expression grammar with parens to hold spaces: `if=(@power > 2000W)`. Both are captured
unevaluated at the CLI; they differ only in sub-language (URI vs expression). Boolean and
threshold logic lives exclusively in `if=`; `on=` is only ever a set of concrete edge sources
(repeat `on=` for "any of").

### Complete - the third provider capability

The provider interface is a triad: **describe** (param schema + context fields),
**subscribe/unsubscribe** (the event plumbing above), and **complete** (autocomplete its DSL).
Completion layers between framework and provider:

| Part of the `on=` URI | Completed by | Source |
|---|---|---|
| scheme (before `:`) | framework | the `trigger_types` registry (provider names) |
| body (`:` to `?`) | provider | live / domain data |
| `?` `&` `=` structure | framework | URI grammar |
| param name (after `?`/`&`) | framework | the provider's `param_schema` |
| param value (after `=`) | schema for enums/types, else provider | schema, or live enumeration |

The framework parses the URI skeleton; the provider fills only the slots that need domain
knowledge. The body is where live data enters: `mqtt:` completes topics seen on the broker,
`zigbee:` completes joined device IDs then clusters then attributes, `@` completes the element
tree (reusing the device-tree walk that already powers the device tab). This plugs into the
console's existing per-command `complete()` / `suggest()` hooks
([console.d](../src/manager/console/console.d)), and the same `provider.suggest(section, partial)`
serves both console tab-completion and the web UI's trigger builder through the API - one
implementation, two front-ends, always correct for the running binary because absent providers
contribute nothing.

### Feature-gating falls out for free

Because a trigger type exists only if its module registered it, the available set is correct
per build with **zero `version()` checks in the engine**. It reads the registry. This is the
same mechanism that makes `energy.apparent` or the `mqtt` binding present-or-absent by
compilation, and it is exactly the graceful-degradation model already used for `has_tls`.

### A registry per leg

Triggers are the one leg missing an extension registry. Conditions and actions already have
theirs, so modules can extend all four legs uniformly:

| Leg | Extension mechanism | Status |
|---|---|---|
| trigger | `trigger_types` registry | new (this section) |
| condition | `intrinsic_functions` - functions callable in a condition expression, e.g. `sun.is_down()` | exists ([package.d](../src/manager/package.d)) |
| action | the console command tree - any module's commands are callable inside `do={}` | exists |
| shaping / policy | fixed, generic | n/a |

So one MQTT module could contribute a trigger (`mqtt(...)`), a condition function, and action
commands, each through the matching registry, each gated by whether MQTT is compiled in. The UI
discovers all of this dynamically: it enumerates `trigger_types` (and their `param_schema`) to
build the trigger picker, `intrinsic_functions` for condition autocomplete, and the command
tree for the action builder. An API endpoint lists what the running binary actually offers.

## Config language and UX

Expressing all of the above cleanly is the hard part. Two observations make it tractable.

**Only the trigger leg is structurally hard.** The condition is a single expression string
(already solved by `expression.d`), the action is a single script block (already solved by
cron's `do={}`), and shaping/policy are scalars that flat `key=value` handles fine. The one
heterogeneous, *repeatable* thing is the trigger set. So the config-language problem reduces
to "how do we express a set of triggers" plus "keep the other three legs flat."

Settled: the trigger set is expressed by **repeating `on=`**, each value a URI (see
[on= is a URI](#on-is-a-uri-and-the-provider-owns-its-dsl) above). Per-trigger options are
deliberately *not* supported - a trigger that needs its own condition or shaping is just
another automation. That keeps `on=` a flat, repeatable list of dumb edge sources and pushes
all the middle-leg logic (`if=`, shaping, policy) to the rule level where it is shared. Trigger
sub-objects were considered and rejected as over-structured for what a trigger actually is.

Recommendation: flat single-trigger for v1 (ships now, consistent with cron), sub-objects as
the target for additive/rich rules. Sub-objects also round-trip for the UI, which matters:

**Structured vs scripted, and why it couples to the UI.** A rule could be defined as one
script blob (maximally expressive) or as structured per-leg fields (form-friendly). A visual
editor *requires* structured fields, because it must introspect an existing rule back into
its trigger/condition/shaping/action parts to render and edit them; an opaque script only
supports a raw text editor. So keep the four legs as distinct fields, and use the
script/expression escape hatch *within* a leg (the action is a script, the condition is an
expression) rather than making the whole rule a script. This is the Home Assistant model: a
visual editor over a structured model, with a code view for the parts the visual editor
cannot represent. Nothing the UI produces should be inexpressible in the console, and nothing
the console produces should be unrenderable in the UI - both are views over one structured
model.

**Observability is half the UX.** A rule engine's UI lives or dies on "did it fire, and if
not, why." The object should expose read-only fields the API surfaces:

- `enabled`, `state` (armed / waiting-for / cooling-down / running / disabled)
- `last_fired`, `next_run` (time triggers), `fire_count`, `last_error`
- ideally a short per-rule trace: "trigger fired -> condition false -> skipped",
  "debounced until T", "throttled, cooldown until T", "for= timer armed, 3m remaining".

This is what turns an automation from a black box into something debuggable.

**UI shape.** A builder that mirrors the four legs: a trigger repeater (add/remove, each a
type plus its options), a condition builder (element picker + operator + value that generates
the expression, with a raw-expression fallback), a shaping/policy panel (selects and
durations), and an action builder (a guided command picker for the common "set element" case,
a code editor for scripts). The management view is the list plus the observability fields
above.

## Migration from Cron (done)

The strategy was: build `src/apps/automation/` from scratch (lifting cron's machinery), prove it
alongside cron, then cut cron over. All of that is complete:

- `Automation` / `AutomationModule` live under `src/apps/automation/`, scope `/automation`, with
  `CollectionType.automation`.
- Cron is no longer a collection: `CronJob` and `src/manager/cron/job.d` are **deleted**, and
  `src/manager/cron/package.d` collapsed to the single file [manager/cron.d](../src/manager/cron.d),
  which is now purely the time `ISignalProvider` (`every:`/`at:`/`when:`) plus `Weekday`/`parse_days`.
- The one internal consumer moved: OTA calls `AutomationModule.schedule_oneshot` (which builds
  `on="every:<delay>?repeat=false"`) instead of the old cron one.
- `CollectionType.cron_job` was removed (verified safe - the ordinal is never persisted; records key
  on element paths, sync transmits `type_index` as data inside the CID, and the collection tables are
  rebuilt each boot).
- `/system/cron` is gone rather than aliased. No repo `.conf` used it; the Pi's `startup.conf` was
  updated in place when the automation rule was deployed.

**Build tier note.** `apps/automation/` is under `static if (has_all)`, so `FEATURES=switch` / minimal
builds don't include Automation - but the time provider (cron) is core, so the scheduling engine
itself is still reachable if a lean build ever needs it.

## Design for the Energy pivot

The energy application should eventually stop reimplementing triggering, expression
evaluation, and temporal shaping, and express its rules as automations. This is a first-class
goal of the design, not an afterthought: the energy `Policy` layer *already* runs on the
shared expression engine, and the allocator *already* speaks the shaping vocabulary.

What maps cleanly onto automations:

- **Policy goals become rules.** A goal like "if SOC < 20% enable charging" is exactly a
  `condition -> action` automation. The `Expression*` a policy already compiles is the same
  object an automation's `condition=` compiles.
- **min_on_time / min_off_time / min_dwell / max_cycles_per_hour** are the temporal-shaping
  and `for=` layer, one level up. `min_dwell` is `throttle`; `min_on_time`/`min_off_time` are
  directional dwell; `max_cycles_per_hour` is `rate=`.
- **Reads and setpoint writes** are element reads and `/element/set`, which automations do
  natively.

What does **not** cleanly become independent rules:

- **Scarcity arbitration.** The allocator's real job is resolving competing demands for a
  shared, limited resource (electrical headroom), ranked by priority, under safety
  constraints. Independent rules that each write a setpoint do not solve contention; two
  rules commanding the same headroom would fight. This arbiter has to remain as a
  coordinator that *owns* contended setpoints.

Implication for the design: automations should be able to **propose** to a coordinator, not
only **command** an element directly. For uncontended outputs (a light, a notification) an
action writes the element. For a contended energy output, the action expresses intent to the
allocator, which disposes (respecting priority and dwell) and owns the final write. Concretely
that likely means an action verb that targets a `Control`'s request surface rather than the
raw setpoint element. The automation engine provides trigger/condition/shaping/action; the
allocator remains the thing that arbitrates who wins. Keeping that boundary is what lets the
energy app adopt automations without the allocator and the rules stepping on each other.

## Phasing

1. **Rename + move**, behaviour identical. Cron jobs keep working; `/system/cron` aliases
   `/automation`. Single mutually-exclusive trigger discriminant preserved.
2. **Element triggers + condition.** Add `on=`, `condition=`, `edge=`, and the
   subscribe/gather-elements wiring. This alone delivers the door/light use case.
3. **Temporal shaping + policy.** Add `debounce`/`throttle`/`rate`, `overrun`, `catch_up`,
   `on_error`. Defaults chosen so existing time jobs behave exactly as before.
4. **Additive triggers.** Allow a rule to hold several triggers at once ("every morning *and*
   when I get home"). This is the one piece that breaks cron's mutually-exclusive-property
   pattern and needs the trigger-arming refactor, hence last.
5. **Energy adoption.** Introduce the propose/dispose action surface and migrate energy
   `Policy` onto automations, leaving the allocator as the arbiter.
6. **UI.** A visual builder and management view over the structured per-leg model, plus the
   observability fields. Depends on the legs being structured fields (see Config language and
   UX), so that constraint is honoured from phase 1.

## Open decisions

1. **Single-trigger vs additive-trigger for v1.** Ship single (cron's tidy last-wins
   discriminant, "OR" = two rules) and design toward additive, vs build additive up front.
   Leaning: ship single, design for additive.
2. **Default `overrun`.** `coalesce` (latest wins, my pick) vs `skip` (never stack, simplest).
3. **`for=` in v1 or deferred.** It is the most-wanted of the time-relationship knobs but
   needs a cancellable timer. Leaning: include it in phase 2/3.
4. **Scope path / home.** `/automation` (user-facing, my pick) vs `/system/automation` (cron
   sibling), and `src/apps/automation/` vs keeping the scheduler engine in `manager/` core.
5. **Trigger set encoding.** Compound-value mini-DSL (flat, reuses the value parser) vs
   trigger sub-objects (native collection idiom, additive, round-trips for the UI). Leaning:
   flat single-trigger v1, sub-objects as the target. Needs the console sub-collection
   feasibility check.
6. **Structured fields vs script blob.** Confirm the four legs stay distinct structured
   fields (form-editable, UI round-trips) with script/expression escape hatches per leg,
   rather than one opaque rule script. Leaning: structured, non-negotiable if the UI is a
   goal.
