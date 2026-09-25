# System IO: buttons, lights and the system device

Status: design only, nothing built. The work items are tracked under "System IO" in
[TODO.md](../../TODO.md). Delete this file once they land, and move whatever is left into
TODO.md.

A node has no physical controls today. No button can reboot, recover or factory-reset it, no
light shows what state it is in, and there is no factory reset at all, from the console or
otherwise. The hardware has no model either. The SmartEVSE binding invents a `Buttons` component
of three bools, lights are modelled as `Switch` with `type=light`, and nothing drives a board LED.
This plan models buttons, relays and lights as ordinary components. It gives the `system` device
fixed slots that the node's own behaviour keys on, and builds recovery and status indication on
those slots.

The target products are Tuya-module plugs and wall switches on BK7231 (a button, a relay and an
LED on bare GPIO), ESP devkits (a BOOT button and a WS2812), the SmartEVSE (three front-panel
buttons and an RGB LED), and later smart bulbs.

## Principles

- Hardware is modelled with the same templates any other equipment would use. What the system
  does with it is declared on the system side, by aliasing, never by flags on the hardware.
- Recovery must not depend on configuration, the automation engine or the network. It lives in
  `manager` and works in every `FEATURES` tier.
- A factory reset is a deliberate act, as in the boot guard (#747). It takes either a long hold
  with visible stages or an explicit command.
- Board wiring belongs in `system.conf`, which states what the board is and runs under every
  configuration rung.

## Templates

Two new entries go into `g_well_known_elements`
([src/manager/profile.d](../../src/manager/profile.d)) and
[COMPONENT_TEMPLATES.md](../COMPONENT_TEMPLATES.md).

### Button

`Button` models a physical input. It is not `Switch` with a mode, because `Switch` is an
actuator: its `switch` element is the control. The energy app's `find_actuator_in`
([src/apps/energy/control.d](../../src/apps/energy/control.d)) takes an appliance's first
`PowerControl`, or failing that its first `Switch`, as the control it drives. An input filed under
`Switch` would be adopted as a load the allocator can switch. The toggle-versus-trigger
distinction is real, but it describes the input. Matter's Generic Switch (with its latching and
momentary features) and Shelly's Input (`button` or `switch`) both put it there.

| Element | Format | Access | Meaning |
| --- | --- | --- | --- |
| `mode` | enum `momentary`, `latching` | constant | what is wired: a pushbutton, or a rocker or toggle |
| `state` | bool, held | read | pressed, or the switch position |
| `event` | enum, point series | read | momentary only: `click`, `double`, `triple`, `hold` |

`event` is the gesture stream for automations. `hold` fires once per press, when the hold time
passes. The timings are binding properties.

### Light

`Light` models an illumination output, from an indicator LED to a colour bulb. It follows the
Zigbee and Matter ladder (on/off, dimmable, colour temperature, extended colour), so the ZCL
On/Off (0x0006), Level Control (0x0008), Color Control (0x0300) and Identify (0x0003) clusters map
straight across. A light's capabilities are simply which optional elements it has.

| Element | Format | Access | Meaning |
| --- | --- | --- | --- |
| `on` | bool | read/write | required |
| `level` | % | read/write | dimmable outputs |
| `cct` | K | read/write | tunable white, with `min_cct` and `max_cct` constants; the binding converts ZCL mireds |
| `colour` | colour | read/write | colour outputs; the representation is an open decision |
| `effect` | enum `none`, `blink`, `fast_blink`, `breathe`, `flash` | read/write | the owner's steady appearance |
| `indicate` | same enum | read/write | an override: while it is not `none` it replaces the output, and clearing it restores whatever the owner last set |
| `indicate_colour` | colour | read/write | colour outputs only |

`indicate` is what lets two users share a light. A Tuya plug has one LED, which shows the relay
state and is also the status light. The system writes only `indicate`, so the owner's `on` and
`colour` survive every indication. The same element serves "find this bulb" from a UI, which is
the job ZCL's Identify cluster does.

### Switch

`Switch` is unchanged, except that `type=light` should be retired in favour of `Light`, so there
is only one way to say it. Six components in
[zigbee.conf](../../conf/profiles/zigbee_profiles/zigbee.conf) use it: the TS0013 and Moes gangs.
The rule is that the template names what the output is for, not how it is switched. A relay
feeding a light fitting is a `Light` with only `on`. A relay feeding an outlet or a water heater is
a `Switch` under its `Port`, which is where the energy app looks for it.

`Switch.mode` is documented but was never implemented: its entry in `g_Switch_elements` is
commented out. The likely reading is the device's input coupling, Tuya's `switch_type`, which
this plan calls `input_mode`. See Composition.

### Composition

- An output is a `Light` or a `Switch`, by purpose.
- A physical input nests under the output it drives. A detached input, such as a scene button,
  sits at device level.
- How the input drives the output is a property of the output. `toggle` flips it on each
  actuation, `follow` makes it track a latching input, and `detached` means the input only
  reports. For a Zigbee device this is the device's own setting, mapped as an optional
  `input_mode` element on the output. For local hardware it is the output binding's `input-mode`
  property.

```
hall                     device
  light        Light     on
    input      Button    mode=latching, state

plug                     device, topology from a naked device profile
  outlet       Port
    switch     Switch    switch
  button       Button    mode=momentary, state, event
  led          Light     on, indicate
```

## Bindings and drivers

There are three local-hardware bindings. They live in `src/driver/`, so every `FEATURES` tier
compiles them, including `switch`, the BK7231 default, which has no automation engine. As with
every binding, `device=` names the equipment and `component=` gives the path within it.

| Binding | Hardware | Properties (proposed defaults in brackets) |
| --- | --- | --- |
| `/binding/button` | a GPIO input | `gpio`, `active=low\|high`, `pull`, `mode`, `debounce` (30ms), `click-gap` (300ms), `hold` (1s) |
| `/binding/switch` | a GPIO output | `gpio`, `active`, `input`, `input-mode` |
| `/binding/light` | a GPIO output, or an LED driver | `gpio` and `active`, or `output` and `index`; `input`, `input-mode` |

- **Light sources.** `gpio=` is the shorthand for plain on/off. Anything richer goes through
  `output=<driver>`, plus `index=` for one pixel of a strip. The driver owns the peripheral and
  reports its capabilities, and the binding creates only the elements that output supports. The
  binding renders effects and `indicate` from a scheduled timer, so a plain GPIO LED can blink as
  well as a WS2812 can. This is the same split as the SmartEVSE: a driver object owns the
  hardware, and a binding references it.
- **LED drivers.** `/driver/led/pwm` takes one to five channels: one for level, two for warm and
  cool white, three for RGB, four for RGBW, five for RGBCW. `/driver/led/ws2812` takes `gpio`,
  `count` and the colour order. The two-wire LED driver chips in Tuya bulbs (SM2135, BP5758D) come
  later.
- **Input coupling.** `input=` references a button binding, and the output binding acts on it
  directly. That keeps a wall switch working when the network or the configuration is broken, and
  on builds with no automation engine. Momentary coupling acts on the press edge, not on `click`,
  so it has no multi-click delay.
- **Sampling.** GPIO interrupts exist only on ESP32, with two ports. A button therefore samples on
  a scheduled timer everywhere, and may wake from an interrupt where a port is free.
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
and `cpu`. This plan adds:

- `info` (`DeviceInfo`): hostname, firmware version and board;
- `state`, the configuration rung and the reset class, under `status` (`DeviceStatus`, which
  every device already has, for `status.online`);
- `panel`, which holds the slots.

| Slot | Template | Behaviour |
| --- | --- | --- |
| `panel.reset` | `Button` | the hold ladder |
| `panel.status` | `Light` | system indication |
| `panel.network` (later) | `Light` | link state |

A slot is filled either by an alias or by a binding writing there directly. The policy lives in
`manager`. It attaches to a filled slot whose template matches, warns on a mismatch, and does
nothing for an empty slot. One light may fill several slots, the way OpenWrt aliases a single LED
as `led-boot`, `led-failsafe`, `led-running` and `led-upgrade`; the precedence order under "The
status slot" resolves them.

### The reset slot

The action happens on release. While the button is held, the status light shows which stage is
armed.

| Held for | On release | Status light while held |
| --- | --- | --- |
| under 5 s | nothing | unchanged |
| 5 s | reboot | slow blink |
| 10 s | recovery: `default.conf` once, erase nothing | fast blink |
| 20 s | factory reset | steady (red on a colour light) |
| 30 s | cancelled | unchanged |

Leaving everything under 5 s alone is what lets a Tuya plug's single button toggle the relay and
also be the reset button.

A button held through power-on cannot be read, because the boot guard picks a rung before
`system.conf` creates the button. The guard's crash ladder and its power-cycle gesture already
cover a unit that never reaches runtime.

### The status slot

The policy writes `indicate`, and `indicate_colour` on a colour light, for the first state in this
list that applies:

1. hold feedback (the table above);
2. identify, from `/system/identify`;
3. updating, while an OTA transfer runs or an image is on trial;
4. recovery: running below the top rung, whether the guard stepped down or the operator asked
   (this is the LED indication #747 defers);
5. booting, until the startup script finishes;
6. unconfigured: running `default.conf` because no other configuration exists;
7. running: `indicate=none`, which hands the light back to its owner.

The winning state is also published as `system.status.state` for UIs. Network state, which users
most want from a status light, has no source yet. It will come when the wifi mirror in
[#749](https://github.com/open-watt/openwatt/pull/749) moves from the SmartEVSE binding into
`system.status.network`.

## Actions

- **Reboot.** `/system/reboot` already exists, and the reset slot calls it.
- **Recovery.** This is the same one-shot defaults boot as #747's power-cycle gesture
  (`BootDecision.one_shot`). The boot store needs a way for a running system to request it before
  rebooting.
- **Factory reset.** A new `/system/factory-reset`, which takes a confirming argument and shares
  its code with the 20 s stage. The recommendation is to erase everything OpenWatt persisted
  (format the configuration filesystem and clear the boot store) but never the firmware or the
  chip's identity. The SmartEVSE needs care, because it keeps the stock NVS and SPIFFS partitions
  so a unit can migrate back.
- **Identify.** DATA_MODEL rule 6 names identify as a device function. Until device functions
  exist, `/system/identify [duration]` sets `panel.status.indicate` and clears it when the
  duration ends.
- **Wifi on and off.** This already works with `/interface/wifi/set wifi1 disabled=true`. It is
  not a built-in gesture, because turning wifi off strands a wifi-only unit. Instead it is an
  automation on a button's `event`, and that has two gaps. `if=` cannot read `$value` today (see
  Automation in TODO.md), and the `switch` tier has no automation engine.

## Hardware support today

- **GPIO:** backends exist for ESP32, Bouffalo, BK7231 and Linux. RP2350 and STM32 have none.
- **GPIO interrupts:** ESP32 only, with two ports (`num_gpio_interrupts`).
- **PWM:** ESP32 only, with four LEDC ports. The SmartEVSE control pilot takes one, which leaves
  exactly three for its RGB LED.
- **WS2812:** the only driver is
  [urt/driver/bl808/led.d](../../third_party/urt/src/urt/driver/bl808/led.d). It is bit-banged,
  with loop counts calibrated for the D0 core at 480 MHz, on the M1s Dock's pin. ESP32 needs RMT
  transmit, which urt does not drive yet. RP2350 needs PIO, and a GPIO backend before that.
  Encoding the bit stream over SPI would work anywhere urt has SPI, which today means ESP32 and
  BL808.

## Examples

A Tuya plug (pins vary by product):

```
/device/add id=plug profile=tuya-plug
/binding/button add name=button device=plug component=button gpio=3 active=low
/binding/switch add name=relay device=plug component=outlet.switch gpio=12 input=button input-mode=toggle
/binding/light add name=led device=plug component=led gpio=5 active=low
/element/alias add source=plug.button target=system.panel.reset
/element/alias add source=plug.led target=system.panel.status
```

An ESP32-C3-DevKitM-1. Its BOOT button and WS2812 belong to nothing but the node, so the bindings
fill the slots directly:

```
/driver/led/ws2812 add name=pixel gpio=8 count=1
/binding/button add name=boot device=system component=panel.reset gpio=9 active=low pull=up
/binding/light add name=status device=system component=panel.status output=pixel
```

## Order of work

1. Land #532. It conflicts with master and depends on urt#232.
2. Add the `Button` and `Light` templates. Migrate the six `Switch{type=light}` gangs and the
   SmartEVSE's `Buttons`, with UX_TODO actions.
3. Build the three GPIO bindings, with input coupling, and write their CLI.md sections.
4. Build the component alias.
5. Build the system slots: the hold ladder, the status indication, `system.status.state`,
   `/system/factory-reset` and `/system/identify`. The recovery stage needs #747.
6. Add `/driver/led/pwm` for the SmartEVSE, then `/driver/led/ws2812` for each chip family.
7. Let `if=` read `$value`.
8. Add network indication, once the #749 mirror moves to `system`.

## Open decisions

1. Should `Switch{type=light}` be retired in favour of `Light`, across the profiles and the
   frontend?
2. Should `colour` be stored as sRGB, which is what LEDs and colour pickers use, or as CIE xy,
   which Zigbee and Matter use natively? The lean is sRGB, converted in the bindings.
3. What does a factory reset erase: everything, including vehicle keys such as `tesla.pem` and
   the recordings, or configuration only?
4. Are the hold timings right, and does reboot deserve a stage of its own?
5. What should a dedicated status light show while running: nothing, a steady light, or a
   heartbeat flash?
6. Is `Button` the right name for a latching rocker, or would a more neutral `Input` be better?
7. Should the alias be `/element/alias`, or a flag on `/element/link`?
8. Should `input_mode` replace the unimplemented `Switch.mode`?

## Related

- #532 and urt#232: the system device.
- #747: the boot guard, which defers its LED indication and button gesture to this plan.
- #749: the SmartEVSE front panel and the wifi status mirror.
- TODO.md, RP2350 bring-up: the undriven on-board RGB LED.
- The parity list at the top of
  [src/driver/boards/smartevse/package.d](../../src/driver/boards/smartevse/package.d): the RGB
  status LED, the buttons and the external switch modes.
