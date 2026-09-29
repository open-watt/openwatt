# System IO: buttons, lights and the system device

Status: the `Button` and `Light` templates, `/binding/gpio`, interface `led=`, the gesture API
and the `panel.status` and `panel.reset` policies are built, and the hEX S uses all of them. The work items are
tracked under "System IO" in [TODO.md](../../TODO.md). Delete this file once they land, and move
whatever is left into TODO.md.

A node has no physical controls today. No button can reboot, recover or factory-reset it, no
light shows what state it is in, and there is no factory reset at all, from the console or
otherwise. This plan drives buttons, relays and lights from local hardware, gives the `system`
device fixed slots that the node's own behaviour keys on, and builds recovery and status
indication on those slots.

The target products are Tuya-module plugs and wall switches on BK7231 (a button, a relay and an
LED on bare GPIO), ESP devkits (a BOOT button and a WS2812), the SmartEVSE (three front-panel
buttons and an RGB LED), and later smart bulbs.

## Principles

- Hardware is modelled with the same templates any other equipment would use. What the system
  does with it is declared on the system side, by aliasing, never by flags on the hardware.
- Structure is declared; behaviour comes from ownership. Nesting never generates an automation.
- Recovery must not depend on configuration, the automation engine or the network. It lives in
  `manager` and works in every `FEATURES` tier.
- A factory reset is a deliberate act, as in the boot guard (#747). It takes either a long hold
  with visible stages or an explicit command.
- Board wiring belongs in `system.conf`, which states what the board is and runs under every
  configuration rung.

## The model

The element lists are in [COMPONENT_TEMPLATES.md](../COMPONENT_TEMPLATES.md). This section records
why they have the shape they do.

- **Three primitives, one per physical thing.** `Button` is an input, `Switch` is an actuator,
  `Light` is a light emitter. A `Button` is never an actuator, and is not a mode of `Switch`: the
  energy app adopts any `Switch` as a control it can drive, so an input filed there would become a
  load. Matter's Generic Switch and Shelly's Input also put momentary versus latching on the input.
- **`Light` extends `Switch`.** A light is an actuator too, and the energy app treats either as a
  discrete control. The template names what the device can do to the output, not what hangs off
  it: a bare contact on a lighting circuit is a `Switch` with the load hint `type=light`, and
  anything that can set `level`, `cct`, `colour`, `effect` or `indicate` is a `Light`, whether or
  not a relay sits behind `switch`. A light with `switch` alone is indistinguishable from
  `Switch{type=light}` to every consumer except the UI.
- **A component exists only if it is independently observable or controllable.** Most Zigbee
  lights and wall switches own their button and indicator in firmware, so they are a flat
  `Switch` or `Light`. An input or LED that we can read or drive ourselves is a component.
- **Nesting is association.** An input nests under the output it is wired to, as `input`; an
  indicator nests as `indicator`. Detached inputs and lights that belong to no output sit at
  device level.
- **Behaviour comes from ownership.** The profile looks identical whether the firmware couples an
  input to its output or nothing does, so nesting cannot imply behaviour. A local output binding
  that owns a `Switch` or `Light` couples its own `input` and `indicator` children: a momentary
  press toggles the output on the press edge, a latching input is followed, and the indicator
  mirrors the output. A profile-driven device has no such binding, so nothing is coupled twice.
- **`indicate` lets two users share a light.** A Tuya plug has one LED, which shows the relay
  state and is also the status light. The system writes only `indicate`, so the owner's state
  survives every indication. The same element serves "find this bulb" from a UI.

```
plug                            Tuya plug on local GPIO
  supply         Port
  outlet1        Port
    switch       Switch         switch, type=outlet
      input      Button         mode=momentary, state, event
      indicator  Light          switch, indicate

wallsw                          Zigbee 2-gang; firmware owns the buttons and LEDs
  gang1          Switch         switch, type=light
  gang2          Switch         switch, type=light

dimmer                          wall dimmer on local hardware
  light          Light          switch, level, cct
    input        Button         mode=momentary, state, event

remote                          scene remote
  button1..4     Button         state, event
```

## Bindings and drivers

Local hardware goes through one binding, `/binding/gpio`, whose `kind` says what the lines are
and so which component it builds; see [CLI.md](../CLI.md). `button`, `switch` and `light` exist
today. Kinds that combine lines follow the same shape, with role-prefixed properties as
`/interface/sfp` has (`set-gpio`, `reset-gpio`): `bistable-switch`, `encoder`,
`shutter`. As with every binding, `device=` names the equipment and `component=` gives the path
within it. The binding is registered only in the `full` tier today; it should move to
`src/driver/` so the `switch` tier, the BK7231 default, has it too.

- **Light sources.** `drive` says how a light reaches its line: `io` switches it, `pwm` dims it,
  and `ws2812` makes it one pixel (`index`) of a chain on the line. The binding creates only the
  elements its drive supports, and renders effects and `indicate` from scheduled timers for every
  drive. The two-wire LED driver chips in Tuya bulbs (SM2135, BP5758D) would be further drives,
  and several dies on several lines (`red-gpio` and the rest) a later form of `pwm`.
- **Coupling.** The output binding couples the `input` and `indicator` components nested under
  its own, whichever binding fills them. That keeps a wall switch working when the network or
  the configuration is broken, and on builds with no automation engine. Momentary coupling acts
  on the press edge, not on `click`, so it has no multi-click delay. `coupling=off` leaves the
  input to an automation and the indicator to its own writers.
- **Sampling.** Buttons take edges from an event link where the platform has them (ESP32 and
  MT7621) and sample their line every `debounce` elsewhere.
- **Topology.** A relay that should appear in the energy model needs its `Port`. A naked device
  profile declares it through the existing `/device/add id=plug profile=...`, and the bindings
  fill in the leaves.

## Component alias

The `system` device borrows components from the devices that own the hardware. Nothing can do
that today:

- `/element/link` wires two elements in both directions, binding each end when it appears. It
  never creates an element (`ElementLink` in [src/manager/package.d](../../src/manager/package.d)).
  Given two components, `ComponentLink` pairs up the relative paths found on either side and
  creates nothing, so a target that nothing populates never binds.
- A profile's `element-alias: id, .device.path` creates the local element, takes the source's
  format once the source resolves, and links the two
  ([src/manager/device.d](../../src/manager/device.d), `ComputationKind.alias_`). It works one
  element at a time, and only from a profile.

The alias combines them. `/element/alias add source=<path> target=<path>` creates the target
component with the source's template, creates one alias element per source element, and picks up
elements the source gains later. It is a mirror kept in sync by bidirectional links, as
`element-alias` is, not a symlink. A component has one parent and one path, and sync, the recorder
and the UI all address it by path. The facility is generic: the system device is its first user,
and a room or site device could collect lights the same way.

It must do two things that links do not:

- **Register as the writer.** Sync takes an element's writer from its binding entries
  (`remote_writer` in [src/manager/sync/package.d](../../src/manager/sync/package.d)). A mirrored
  element has none, so a remote write to it fails with `no writable provider`. The alias attaches
  itself with the source's access and forwards the write through the link. Local writes already
  propagate.
- **Show that it is an alias.** Sync carries no alias relationship, so a frontend would see
  `plug.led` and `system.panel.status` as two separate lights. That needs a flag on the wire and a
  [UX_TODO](UX_TODO.md) action when the alias lands.

`/element/link` has no section in [CLI.md](../CLI.md). Document it together with the alias.

## The system device

[#532](https://github.com/open-watt/openwatt/pull/532) creates `system` in the `Application`
constructor, before any startup script runs, so `system.conf` can populate it. It carries `mem`
and `cpu`, and `panel` holds the node's own controls:

| Slot | Template | Behaviour |
| --- | --- | --- |
| `panel.reset` | `Button` | click reboots; a hold arms a factory reset |
| `panel.status` | `Light` | lit while running; shows the system's gestures |
| `panel.network` (later) | `Light` | link state |

A slot is filled either by an alias or by a binding writing there directly.
[manager/panel.d](../../src/manager/panel.d) claims a slot when its elements appear, whatever
created them, and does nothing while a slot is empty. The hEX S fills all its slots from
`system.conf`.

Still to add: `info` (`DeviceInfo`: hostname, firmware version and board), and `state`, the
configuration rung and the reset class, under `status`.

### Gestures

Code that wants to show something asks for a gesture, not a light pattern:
`indicate(Gesture, duration)` returns a token, and `end_indication(token)` withdraws it; a
duration of `Duration.max` lasts until it is ended. The highest-precedence live gesture is
expressed, so a lower one resumes when a higher one ends. The expression is a table from gesture
to what the panel has: today an `indicate` effect on `panel.status`, later a colour or a sounder.

| Gesture | Raised by | Status light |
| --- | --- | --- |
| `reset_armed` | a reset hold | fast blink |
| `upgrading` | an OTA transfer | blink |
| `identify` | `/system/identify` | flash |
| `booting` | startup, until the scripts finish | breathe (a slow blink on a plain line) |

Still to add: recovery (running below the top rung, the indication #747 defers), unconfigured
(running `default.conf` because nothing else exists), an image on trial, and publishing the
winning gesture as `system.status.state` for UIs. Network state, which users most want from a
status light, has no source yet. It will come when the wifi mirror in
[#749](https://github.com/open-watt/openwatt/pull/749) moves from the SmartEVSE binding into
`system.status.network`.

### The reset slot

- A click reboots.
- A hold (the button's `hold`, 5 s on the hEX S) arms a factory reset and raises `reset_armed`
  for 15 s.
- Releasing while armed performs the factory reset and reboots. Holding past the window lets it
  lapse, and the release does nothing.

A factory reset deletes what OpenWatt writes: the saved configuration revisions, the secret store
and the fleet allegiance. It keeps the node identity, the firmware, the boot guard's state (which
carries any firmware trial) and files the user put there, such as certificates.

A button held through power-on cannot be read, because the boot guard picks a rung before
`system.conf` creates the button. The guard's crash ladder and its power-cycle gesture already
cover a unit that never reaches runtime.

## Actions

- **Reboot.** `system_reboot()`, as `/system/reboot` uses.
- **Factory reset.** Built for the reset slot. A console form, `/system/factory-reset` with a
  confirming argument, should share its code. The SmartEVSE needs care, because it keeps the stock
  NVS and SPIFFS partitions so a unit can migrate back.
- **Recovery.** A reset stage that boots `default.conf` once, erasing nothing, is the same one-shot
  defaults boot as #747's power-cycle gesture (`BootDecision.one_shot`). The boot store needs a way
  for a running system to request it before rebooting.
- **Identify.** `/system/identify [duration]` raises `identify`, 10 s by default. DATA_MODEL
  rule 6 names identify as a device function; this is the node's until device functions exist.
- **Locate.** `/interface/locate iface=<name> [duration]` blinks the interface's `led`.
- **Wifi on and off.** This already works with `/interface/wifi/set wifi1 disabled=true`. It is
  not a built-in gesture, because turning wifi off strands a wifi-only unit. Instead it is an
  automation on a button's `event`, which needs automation conditions to compare enums (see
  Automation in TODO.md), and the `switch` tier has no automation engine.

## Hardware support today

- **GPIO:** backends exist for ESP32, Bouffalo, BK7231, MT7621, RP2350, STM32 and Linux.
- **GPIO edges:** event links on ESP32 and MT7621; elsewhere a button samples its line.
- **PWM:** urt's allocator takes a PWM block where one reaches the line (ESP32's four LEDC ports,
  the RP2350's 24 slice channels) and otherwise one of eight software channels, density-modulated
  from a 4 kHz timer interrupt. Software channels need a timer compare, which Beken, ESP32 and
  Bouffalo lack. The SmartEVSE control pilot takes one LEDC port, which leaves exactly three for
  its RGB LED; the hEX S and the DevEBox H7 dim their LEDs in software.
- **WS2812:** `urt.driver.ws2812` owns the chains behind a small backend contract. The RP2350
  runs a chain on a PIO state machine; the BL808 D0 bit-bangs it with loop counts calibrated for
  480 MHz. ESP32 needs RMT transmit, which urt does not drive yet. Encoding the bit stream over
  SPI would work anywhere urt has SPI, which today means ESP32 only; the BL808 SPI driver is a
  stub.

## Examples

A Tuya plug (pins vary by product):

```
/device/add id=plug profile=tuya-plug
/binding/gpio add name=relay device=plug component=outlet1.switch kind=switch gpio=12
/binding/gpio add name=button device=plug component=outlet1.switch.input kind=button gpio=3 active=low
/binding/gpio add name=led device=plug component=outlet1.switch.indicator kind=light gpio=5 active=low
/element/alias add source=plug.outlet1.switch.input target=system.panel.reset
/element/alias add source=plug.outlet1.switch.indicator target=system.panel.status
```

An ESP32-C3-DevKitM-1. Its BOOT button and WS2812 belong to nothing but the node, so the bindings
fill the slots directly:

```
/binding/gpio add name=boot device=system component=panel.reset kind=button gpio=9 active=low pull=up
/binding/gpio add name=status device=system component=panel.status kind=light gpio=8 drive=ws2812
```

## Order of work

1. Land #532, which depends on urt#232.
2. Couple an output's nested `input` and `indicator` in `/binding/gpio`, and move the binding
   to the `switch` tier.
3. Build the component alias.
4. Finish the system slots: the remaining gestures, `system.status.state`,
   `/system/factory-reset`, and the recovery stage on #747's one-shot defaults boot.
5. WS2812 on more chips (ESP32 RMT, SPI encoding, a cycle-timed bit-bang), and multi-die lights.
6. Let `if=` read `$value`.
7. Add network indication, once the #749 mirror moves to `system`.

## Open decisions

1. A click reboots, which suits a dedicated reset button. A button shared with an output, like
   the Tuya plug's, toggles the relay on a click, so aliasing it to `panel.reset` as the example
   does would reboot the plug instead. Should a shared button reset on hold only, and who says
   which kind a slot has?
2. Should the alias be `/element/alias`, or a flag on `/element/link`?
3. May the energy app dim a `Light` that has `level`, as a continuous control? Lights are only
   adopted when configured as an appliance, so the question is whether that is ever wanted.

## Related

- #532 and urt#232: the system device.
- #747: the boot guard, which defers its LED indication and button gesture to this plan.
- #749: the SmartEVSE front panel and the wifi status mirror.
- TODO.md, RP2350 bring-up: the undriven on-board RGB LED.
- The parity list at the top of
  [src/driver/boards/smartevse/package.d](../../src/driver/boards/smartevse/package.d): the RGB
  status LED, the buttons and the external switch modes.
