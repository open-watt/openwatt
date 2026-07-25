# High-frequency tracking: dispatching fast devices against power fluctuation

Status: DESIGN SPEC, not implemented. Branch `ow/energy-hf-tracking` carries the
Control-side metadata this needs; the merge branch does not (see APP-12e in
ENERGY_APP_REVIEW.md). Written so an agent with no prior context can implement it.

## 1. Goal

Site net power moves faster than the policy/allocator loop reasons about. Cloud
edges swing PV by kilowatts in seconds; a kettle, a compressor start or an oven
element steps load instantly. The planner/allocator decide *what should run* on a
horizon of minutes to hours. Nothing today decides *which device absorbs the
jitter in between*.

The aim is to keep a chosen quantity near a setpoint at short timescales, the
usual one being grid exchange near zero (consume your own generation, avoid
export clipping and import spikes), by continuously trimming whichever connected
devices can actually respond that fast.

This is a distinct control loop from allocation:

- **Allocation** (existing): tier-ranked, goal-driven, slow, decides who runs.
- **Tracking** (this): error-driven, fast, decides how a *already-running*
  device's setpoint is trimmed around its allocated operating point.

Tracking must never override allocation's decisions; it modulates within the
headroom allocation has already granted.

## 2. Device candidacy

Not every controllable device can chase fluctuation. A resistive water heater on
a relay cannot; a modulating EV charger or a battery inverter can. Candidacy is
decided from the response-characteristic metadata a profile declares on its
control component:

| element              | meaning                                            | use in candidacy |
|----------------------|----------------------------------------------------|------------------|
| `ramp_rate`          | how fast the device can slew its output (unit/s)    | bounds how much error it can absorb per tick |
| `command_latency`    | delay from command accepted to output changing      | dead time; large values make a device unstable in a fast loop |
| `measured`           | the value the device is actually delivering         | closes the loop: confirms tracking rather than assuming it |
| `autonomous_mode`    | `track_meter` / `schedule` / `weather` / `unknown`   | the device can do this itself |
| `autonomous_reference` | the reference the device tracks in autonomous mode | what we hand it when delegating |

Continuous controls only: a discrete on/off surface has no trim range, and its
`min_on_time` / `min_off_time` / `max_cycles_per_hour` limits exist precisely to
stop it being cycled fast. Staged controls are marginal (quantised steps) and
should be excluded until there is a reason not to.

A candidate is roughly: `kind == continuous`, a `setpoint` that can be commanded,
a `measured` element to verify with, `command_latency` short relative to the loop
period, and `ramp_rate` large enough that a meaningful fraction of the expected
error can be taken in one interval.

## 3. Delegate before you drive

`autonomous_mode` is the important shortcut and should be preferred wherever it
exists. A hybrid inverter in `track_meter` mode regulates against its own CT
clamp at hundreds of hertz. No control loop running on this device, over Modbus,
at 20 Hz, will beat that, and trying to drive it manually is strictly worse.

So the design is two-tier:

1. **Delegate** to any device reporting an `autonomous_mode` that matches the
   objective. Write `autonomous_reference` (e.g. the grid setpoint to hold) and
   otherwise leave it alone. Our job reduces to setting the reference and
   monitoring.
2. **Drive** the remaining candidates directly, from our own error signal, only
   for the residual the delegated devices do not cover.

An implementation that only does step 1 is still useful, and is the safer thing
to land first.

## 4. Control loop sketch (for the driven case)

Per tick:

- Read the tracked error (e.g. `account.grid.power` minus its target).
- Subtract what delegated devices are expected to be absorbing already.
- Distribute the residual across driven candidates, respecting for each:
  - allocation's granted operating point and the policy tier that granted it
  - `min` / `max`, and the circuit headroom the allocator already computes
  - `ramp_rate` as a per-tick delta clamp
  - existing dwell / min-on / min-off / max-cycles constraints
- Compare `measured` against the last command to detect devices that are not
  actually following; demote or drop them from the candidate set.

Stability matters more than optimality here. Prefer proportional trimming with a
deliberately conservative gain, deadband around zero error so the site does not
hunt, and back off when `measured` disagrees with the command.

## 5. Interaction with existing machinery

- **Allocator**: tracking sits after allocation in the tick and may only move a
  control within the band allocation permits. `setpoint_change_block_reason`
  still applies; do not bypass the rate limiter.
- **Accounts**: the error signal comes from the island accounts, so it inherits
  their sign conventions. Note the boundary-injection work in
  SOURCE_SURVEY.draft.md, which changes how those are computed.
- **BMS limits** (`ow/energy-bms-limits`): a battery's charge/discharge limits
  bound how much a battery candidate can absorb. If both land, tracking must
  intersect with them.
- **Loop rate**: the app runs ~20 Hz but protocol round-trips (Modbus, BLE) are
  far slower. Effective tracking rate is per-device and bounded by
  `command_latency`, not by the app tick.

## 6. Open questions

- What is the tracked objective, exactly: grid power to zero, or a configurable
  per-island target? Probably a property on the island, not a global.
- How does this express in config? Likely a policy tier or an explicit
  `/apps/energy/tracking` object rather than overloading Policy.
- Do we need anti-windup / integral action, or is proportional-with-deadband
  sufficient given devices have their own inner loops?
- How is a device that repeatedly fails the `measured` cross-check reported to
  the operator, versus silently dropped?
