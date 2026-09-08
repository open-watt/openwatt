# Automation

An automation is a rule that runs a console script when something happens. "The clock reached T"
is one of the things that can happen; an element changing value, or an object coming online, are
others. This document is the design of that rule engine as built: the four-leg model, the signal
providers that wake a rule, and the rules that keep the surface flat enough for a console and
structured enough for a visual editor. The command reference is the `/automation` section of
[CLI.md](CLI.md); what is designed but not built is listed under *Direction* and tracked in
[TODO.md](../TODO.md) under *Automation*.

## The rule

```
triggers  ->  shaping  ->  condition  ->  action
(wake it)     (smooth)     (proceed?)      do={...}
```

An automation is a `Collection` object under `/automation`, created and configured through the
console like everything else:

```
/automation/add name=door-light on="@door.open" do={ /element/set element=hall.light value=$value }
```

It reads as a sentence: **on** X, **if** Y, **do** Z. A scheduled job is the degenerate rule, one
time trigger and a script, which is why the old `/system/cron` collection is gone: cron collapsed
into the time signal provider, and every former cron job is an automation with a time trigger.

Each leg is orthogonal. Shaping acts on the trigger stream; the condition decides whether a
settled trigger proceeds; the action is a script. A trigger that needs its own condition or
shaping is simply another automation: there are no per-trigger options, which is what keeps `on=`
a flat, repeatable list of edge sources and all the middle-leg logic at the rule level where it
is shared.

## Triggers

A trigger is not a predicate and is never evaluated or polled. It is an addressable event source,
and `on=` names one or more of them as **signal URIs**:

```
[provider: | @] body [?param=value[&param=value...]]
```

The scheme is the provider, the body is the provider's opaque address, and the query carries named
parameters. `@` is sugar for the `element:` scheme, so `@door.open` is the common case with no
prefix. The value is captured as source text and never expression-parsed, so `: / + # ? =` are
bytes the provider reads, not tokens; a URI containing `?`, `=` or `@` must still be quoted at the
CLI, because the console's argument parser reserves those. Several triggers are comma-separated;
any of them wakes the rule.

| provider | URI | fires when |
| --- | --- | --- |
| element | `@device.component.element` | the element's value actually changes; `$value` is the new value |
| every | `every:<duration>[?repeat=false]` | each interval, or once |
| at | `at:<hh:mm>[?days=mon,wed,fri]` | that time of day, optionally on the named weekdays |
| when | `when:<datetime>` | an absolute instant, once |
| object | `object:<name>?state=online\|offline\|destroyed` | an `ActiveObject` makes that transition; `online` also fires immediately if it is already running |

`schedule=<duration>`, `at=<hh:mm>` and `when=<datetime>` are write-only shorthands for the three
time URIs and share one slot with `on=`; a rule mixing time and events writes everything through
`on=`. Finer detail, `?days=` and `?repeat=false`, lives in the URI and has no sugar.

**Arming has three outcomes.** A malformed URI is rejected at the CLI by the provider's
`validate`. A URI naming an element that does not exist yet parks the rule in `Starting` with a
status of `element not found: <path>`, retried each frame with no backoff and no log spam, and the
rule arms the moment the element appears, which is the normal case for a Zigbee device before its
scan completes. A valid, resolvable URI subscribes.

**Trigger context** is the flat `$value`: the datum that fired, snapshotted at the moment of
change, and null for value-less triggers such as time. Prefer it to re-reading `@path` in the
action: a live re-read can race a later change, `$value` cannot.

### Providers

Signals come from `ISignalProvider`s registered on the `Application`
([src/manager/signal.d](../src/manager/signal.d)); any subsystem can provide or consume them. The
contract is `validate`, `subscribe`/`unsubscribe` returning an opaque `SignalSub`, and an optional
`next_run` that time-shaped providers implement and event-driven ones leave null. A provider owns
its source's liveness: reconnects and object churn are its concern, and the engine only subscribes
at `startup()` and unsubscribes at `shutdown()`. The registry is read, never special-cased, so the
available provider set is correct per build with no `version()` checks in the engine: a provider
exists only if its module registered it, and an absent module contributes nothing to the console
or the UI. Built-in providers are the `Application` itself (`element:`), cron
([src/manager/cron.d](../src/manager/cron.d), `every:`/`at:`/`when:`) and the object-signal module
(`object:`).

## Condition

`if=<expr>` is an optional gate, a quoted expression on the same engine the energy policy layer
runs on: it reads any element by `@path`, compares with units (`@site.power > 2000W`), and a falsey
result skips the action. Two qualifiers operate on its resolutions, and both require it:

- `edge=level|rising|falling` (default `level`) picks which transitions fire. `level` fires on
  every trigger that finds the condition true. For a boolean element that already behaves like a
  rising edge; `edge=rising` earns its keep over continuous values, where `@power > 2000W` with
  `level` fires on every sample above the threshold and with `rising` fires once as power crosses
  it. `falling` fires on true-to-false.
- `for=<duration>` requires the qualifying state (truth, or falseness under `edge=falling`) to
  hold for the window: armed when it begins, cancelled the moment an observation finds it
  dropped, one run per qualifying episode, with a final live re-evaluation at the deadline so a
  silent drop cannot slip through.

On arm the tracker is seeded so an already-true condition is not an edge. A `level` `for=`
qualifies from state, so "open for 5m" spans a restart; `rising` and `falling` qualify only from an
observed transition. Both hot-apply; a pending `for=` deadline folds into `next_run`. The condition
is observed at trigger times plus the deadline check, not continuously monitored.

## Temporal shaping

Shaping decides how often the rule may fire, independent of the condition. The three knobs are
distinct primitives, not one setting: they differ on leading versus trailing edge, drop versus
coalesce, and whether the window is measured from the last trigger or the last action.

| property | behaviour | for |
| --- | --- | --- |
| `debounce=<duration>` | trailing edge: each trigger restarts the settle window; the action runs once on settle and `$value` is the settled datum | a flappy contact, a bouncing switch |
| `throttle=<duration>` | leading edge: act now, then lock out for the window | a chatty sensor you do not want to spam on |
| `rate=<per-time>` with `burst=<n>` | token bucket: capacity `burst` (default 1), refill `rate` | a hard ceiling on cycles per hour |

Ordering is peek early, commit late: throttle and rate drop bursts before the condition is
evaluated, which is cheap, but the lockout stamp or the token spend commits only when the action
actually runs, so a false condition never consumes the budget. All shaping timing is `MonoTime`,
immune to wall-clock steps; only the time triggers use the wall clock. All three hot-apply on a
running rule.

Shaping is off by default. A hidden global debounce would mask flapping, which is usually a real
signal worth seeing. Rule-level shaping also protects against *this rule* spamming, not the device:
when many rules command one actuator, or an automation drives an energy `Control`, the anti-chatter
belongs to the allocator's `min_dwell`/`min_on_time` at the control layer, not to a second copy
here.

`rate=` takes any per-time quantity (`12/h`, `4/min`, `0.2/s`) and canonicalises to `/s`. Per
minute is `/min` (`/m` is per metre); numeric denominators like `3/1h` are not a unit spelling;
`Hz` is rejected because it is angular (cycles per second), dimensionally distinct from plain
per-time.

## The action

`do={ ... }` is a console script: it runs any console command through an internal session, branches
with `:if`, sets locals with `:set`, returns with `:return`. `/element/set element=<path>
value=<val>` is the ordinary way to write an element, and `@path` inside the script reads another
element's live value at run time.

Setting an element commands a device only when the target is writable and its binding subscribed
it for write-back; setting a read-only sensor element just updates the local value. Actions are
async `CommandState`s tracked per rule, and `shutdown()` requests cancellation of every in-flight
run before the object goes down.

## Observability

`run_count`, `last_run` and `next_run` are read-only. `next_run` is the minimum across every time
trigger, a pending debounce settle and a pending `for=` deadline, so it answers "when will this
fire" whatever is holding it. While a rule cannot arm, the object's status carries the reason.

## Design rules

- **The provider owns its DSL.** The engine knows the URI skeleton and nothing protocol-specific;
  the body is bytes the provider interprets. Boolean and threshold logic lives exclusively in
  `if=`; `on=` is only ever a set of concrete edge sources.
- **Only the trigger leg is repeatable.** The condition is one expression, the action one script,
  shaping a few scalars, so the whole config surface stays flat `key=value` and the trigger set is
  repeating `on=`.
- **Structured legs, not a script blob.** A visual editor must introspect a rule back into its
  legs to render and edit it, so the legs stay distinct fields with the script and expression
  escape hatches *within* a leg. Nothing the UI produces is inexpressible in the console, and
  nothing the console produces is unrenderable in the UI.
- **A registry per leg.** Triggers extend through the signal-provider registry, conditions through
  the expression engine's intrinsic functions, actions through the console command tree. One
  module can contribute to all three, each gated by whether it is compiled in.
- **Automations propose; the allocator disposes.** For an uncontended output (a light, a
  notification) the action writes the element. Electrical headroom is contended, and independent
  rules writing setpoints would fight, so the allocator remains the arbiter that owns those
  writes; the automation's job there is to express intent to it. This is what lets the energy
  policy layer, which already shares the expression engine and the shaping vocabulary, move onto
  automations without the two stepping on each other.

## Direction

Designed and not built, tracked in [TODO.md](../TODO.md) under *Automation*:

- **Execution policy**, the fourth leg. Actions are async, so triggers can arrive mid-run or be
  missed while the box was down, and today's behaviour is accidental (runs stack). `overrun=`
  `skip|queue|restart|coalesce` (default `coalesce`: one more run with the latest data, right for
  "set the light to the door's state"; `queue` for counting where every event matters; `restart`
  cancels the in-flight run). `catch_up=skip|once|all` with a grace window, anacron-style,
  default `skip` because morning lights firing at noon after a late boot is wrong. `on_error=`
  `ignore|retry|disable`, per run, distinct from the object's lifecycle backoff.
- **Typed trigger context.** A `$trigger.*` object (value, previous value, source, and per-provider
  fields such as topic and payload) replacing the lone `$value`, decided before the first rich
  provider lands.
- **More providers.** MQTT filtered publishes, Zigbee attribute reports, sunrise and sunset with
  offsets, HTTP events.
- **Completion**, the third provider capability beside describe and subscribe. The framework
  completes the scheme (from the registry), the URI structure and parameter names (from the
  provider's schema); the provider completes the body from live data (topics seen on the broker,
  joined Zigbee devices, the element tree). One implementation serves console tab completion and
  the web UI's trigger builder.
- **Event-driven attach.** Subscribe on element creation instead of retrying `startup()` each
  frame for a missing element.
- **Re-entrancy.** Rules subscribe to and write elements, so they can form loops. Actions should
  pass `who=this` so a rule never re-triggers itself, recursion should be bounded, and
  `/element/set` should refuse a read-only target instead of silently updating local state.
- **`?deadband=`** on an element trigger, passed through to the element subscription the rule
  already creates; the band is per-subscription state in the element, with metadata supplying the
  default. That is what makes debounce meaningful on an analogue signal: sub-band ripple generates
  no events, so `on="@motor.power?deadband=100W" debounce=5s` fires once when the motor settles.
- **The energy intent surface**: an action verb that targets a `Control`'s request surface rather
  than the raw setpoint element.
- **The UI**: a builder mirroring the legs (trigger repeater, condition builder, shaping panel,
  action picker with a code fallback) and a management view over the observability fields, plus a
  short per-rule trace ("trigger fired, condition false, skipped"; "debounced until T").
