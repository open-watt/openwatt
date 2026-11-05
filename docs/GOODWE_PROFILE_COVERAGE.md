# GoodWe profile implementation and confidence

Audited against SolarGo 7.2.2/build1521 and the GW5048D-ES DSP23/ARM14.
The [208-entry menu survey](GOODWE_SOLARGO_MENU_SURVEY.md) is the UI reference.
The [coverage index](GOODWE_PROFILE_COVERAGE.json) accounts for every entry and
its runtime path, decoder confidence and write implementation. A surveyed menu
is not necessarily a working setter.

| Surface | Runtime implementation | Confidence / limit |
| --- | --- | --- |
| Basic grid code / working mode | Readback plus staged mode activation | Native Self-use/Peak and observed ESU General/Off-grid/Backup/TOU workflows; grid-code selection remains separate |
| Battery catalogue | Readbacks plus scoped native low745 staged selection | Fourteen-field/seven-write transaction; legacy and other catalogue branches remain separate |
| TOU | Four ES and seven native physical-slot six-register editors | Stage fields, then apply; native fresh-bank checks enforce four TOU groups; format validation, ACK and full readback tested against emulator |
| Advanced operating settings | Backup, shadow scan and software export-enable are RW | Unchanged native AA55 ACK/readback verified; physical changed-state trials remain separate |
| Battery Function | On/off-grid minimum SOC RW; physical configured currents in A | 20–100% reserve range for selected lithium battery; current/voltage writes disabled as in app |
| Safety | All 108 app schema fields assigned nested paths | Confirmed voltage/frequency/time and 17 signed curve-point decoders; cycles and uncertain coefficients explicitly raw; eighty bounded scalar setters emulator-tested; shared/nonlinear workflows remain |
| BMS version | Native 0780 read | A failed read remains unavailable; the app's delayed 00 is not firmware proof |
| Solar status | Measured PV voltage/current/power | Contradictory mode-0 enum removed from visible ports; raw code retained |
| SPN configuration | Native profile supported by the GoodWe client/binding; nested app categories | Live menu survey, native scalar writers and modern TOU emulator tests; physical write/persistence audit remains |
| Dispatch strategy | Writable autonomous/continuous enum | Unsupported enum states rejected; independent physical enable/stop255 |
| Hybrid solar + battery targets | Addressing infrastructure only | Compensated ES translator and generation curtailment remain unproven |
| Proxy writes | Optional upstream client | Correlated AA55/RTU/module-v1 forwarding with exception propagation, bounded queue and peer isolation; other formats and target app validation remain |

Scalar writes read the current block, preserve unrelated bytes, require an ACK,
and compare a fresh readback. Inspect `status.config_write.{pending,address,result}`.
Only `verified` reports matching register readback; it does not prove persistence
or physical execution. [Probe evidence](GOODWE_PROFILE_PROBE_20261030.json) retains
all bytes from the latest bounded unchanged-value trial. The on-grid SOC reassertion
timed out in that trial; earlier writes succeeded. This result is not hidden.

Reserved FFFF physical readings are invalidated. Raw fields intentionally retain
all bits, including unsupported PQ values. Trip cycles require the nominal country
frequency, and some firmware uses the B253 extended-time bank. Do not apply the
enum table's gain hints as universal decoders. Q(U), cosφ(P) and P(U) response times now use the source-traced nonlinear
coefficient codec. Invalid coefficients remain unavailable; the original raw
fields remain available for diagnosis.

## Historical checkpoint, 2026-11-06

Both inverter families now use the GoodWe binding transaction machinery. A native
client starts with `identity=modbus` and can load `goodwe_ems` directly. Holding
and input registers map to FC03/04; native RW fields receive the same bounded
fresh-read/write/ACK/readback handling as mixed AA55 fields. The existing generic
Modbus binding remains available. Native mode changes are never part of startup.

The SPN TOU record uses flags6/249, signed power in tenths of a percent and a
12-bit month mask. Its `apply` counter commits one complete six-register block.
The native tests cover identity, safety writes, module-independent app switches,
minimum-SOC and protection controls, whole-record schedule writes and rejected
invalid values. Configuration and proxy runtime results are recorded below as the implementation grows.
These results establish emulator behavior, not physical acceptance or persistence.

The house survey records live screens in GOODWE_SPN_MENU_SURVEY.json and distinct
requests in GOODWE_SPN_OBSERVED_REQUESTS.json. All native configuration writes in
this pass were withheld. Simulated ACKs are explicitly logged to reveal conditional
editors. Reads came from the real inverter. Module credential values remain private.

The native Battery Function setters confirm that on/off-grid values at45356/45358
are minimum SOC. SolarGo subtracts each DoD input from100. SOC protection47500 is
inverted:0 enabled,1 disabled. Backup SOC holding47602 uses0/1. The separate upper
SOC value is47760; its coupled lower-bound check remains required before exposing
a writer. The current battery model limits the UI's DoD range; a0–100 protocol
range does not imply that every value is accepted by that battery/inverter.

At that checkpoint, gaps included coupled application/mode activation, battery selection,
smart charging, peak shaving, generator/load records, network/password commits,
actions, shared/nonlinear safety encodings, proxy write-through and physical
persistence/dispatch/failover behavior. The strict native proxy also requires all
bytes of a requested block to be represented by valid Device fields; sparse
native profile coverage is not complete SolarGo block emulation. The identity,
runtime, meter and BMS banks now have hidden byte snapshots, with full-block
proxy tests and a separate proxy identity. This preserves unknown bytes without
claiming they have been decoded.

## Historical completion audit, 2026-11-05

The protocol knowledge and configuration profiles remain incomplete. The legacy
survey covers the selected ES target. A separate exhaustive house SPN menu/write
audit is still required. Its reported identity is GW6000ES20, serial
00000SPN00000001, despite the GW5000-SBP-20 appliance label.

The legacy profile currently declares 104 bulk AA55 fields, one AA55 register
field and 155 RTU fields. Five scalar write declarations exist. There are no
`goodwe-module` field declarations, although the client supports 5A5A transport.
The house profile contains 615 native register declarations and 68 mapped
Device elements. Register catalogue size does not establish target validity,
writable configuration coverage or current deployment capability.

The 29 rows labelled workflow-not-implemented undercount the remaining setter
work. Mapped read-only working-mode, battery-selection, schedule and safety rows
also lack complete write transactions. The 208-entry total measures survey
accounting. It does not measure successfully implemented configuration items.

The mixed ES endpoint uses AA55 vendor commands, AA55 register operations,
raw Modbus RTU requests, AA55-prefixed RTU responses and 5A5A module messages.
AA55-prefixed RTU replies retain Modbus CRC semantics. Module settings require
separate payload schemas and commit/reload sequences. The house serial EMS
path uses native Modbus registers. Its WiFi module is a separate communication
surface whose complete configuration remains unaudited.

The house recovery also disproved the assumption that automatic-mode and
manufacturer-code readback established autonomous release. Restoring 47505=10
and requesting mode1 still stopped after30 seconds until a full controller
restart with FC06 45221=361. Native self-use then passed an eight-minute
read-only soak and a two-minute communication blackout. External dispatch
failover remains unverified. [Recovery evidence](GOODWE_NATIVE_RECOVERY_20261105.json)

Historical slot206 validation below does not establish the current runtime.
During recovery the Pi was on slot213 and lacked the experimental
`goodwe-control` binding. Source code, parsed profiles, deployed binding support
and physical behaviour require separate checks.

Completion requires model-specific configuration transactions, module binding,
remaining actions and conditional fields, validated safety decoders, persistent
reserve behaviour, characterized dispatch semantics and correlated proxy
write-through. Each setting needs independent evidence for decoding, encoding,
ACK/readback, persistence and physical effect where applicable.

## Workflows still lacking runtime transactions

These entries are traced in the app source, but the profile does not claim them
as implemented controls. Some are local/cloud actions or conditional module
features rather than inverter settings.

| Survey entry | Menu / item | Existing app operation |
| --- | --- | --- |
| item-020 | Communication / WLAN/LAN / Router hotspot list | Selection fills editor; Set commits |
| item-022 | Communication / WLAN Detection / Router credentials / encryption | Read-only Diagnosis / Re-diagnose |
| item-023 | Communication / WLAN Detection / Assigned network parameters | Read-only Diagnosis / Re-diagnose |
| item-031 | Basic / Grid Code / Export | Local image export only |
| item-101 | Device Information / Update Record / Firmware name / time / type / version / result | none |
| item-185 | Advanced / Safety / Other / LVRT / HVRT Extended Functions (shared register) | f706b1bb + big-endian encoded value + CRC |

Outstanding implementation and hardware validation is tracked in [TODO](../TODO.md).
No safety, battery chemistry, credential or network changes were made by this audit.

Cos-phi points are dimensionless: the default SI display may use90% for ratio0.90. Respect the advertised unit and convert once.

The connection ramp values `grid_connect_power_rate` and
`grid_connect_power_rate_under_fault` are seconds, despite their names:
`JointParamFragment.java:212–226` appends `s` to the unsigned words unchanged.
Frequency response slopes `of_power_slope`, `uf_power_slope` and
`recovery_power_slope` are unsigned per mille
(`CurveSettingFragment.java:551–553`, `ArrayUtils.java:133–138`); the profile
scales them to percent. These five fields reject FFFF. Frequency-response
parameters and Q(U)/P(U) coefficients are grouped under `safety.curves`, matching
the app submenu. Coefficients still marked `_raw` do not claim decoded units.


## Deployed validation

Initial Pi slot204 committed with no probation failure. Both real ES reserves accepted
21%, then20%, with raw AA55 ACK06 and matching readback captured. They were left
at20% (80% DoD), initially confirming autonomous strategy, enabled, native mode1.
The [live evidence](GOODWE_PROFILE_VALIDATION_20261030.json) distinguishes this
changed-value proof from the earlier unchanged reassertion and timeout.

The daylight runner completed all seven phases on slot205 after the initial
telemetry starvation fix. Steady2.64kW PV accompanied0/484/981W battery charging
for0/500/1000W requests, and498W discharging for a−500W request. The independent
cabin feeder meter moved in corresponding directions. See
[daylight evidence](GOODWE_DAYLIGHT_20261030.json); exact AC compensation and
generation curtailment remain unproven. Native reserves reverted80/0 earlier
and were restored20/20; cause remains unresolved. Client trace is persistently
enabled and raw packets remain private. Reserve polling now requests both fields
every10s rather than60s, with no automatic rewrite masking a reversion.


## Implementation checkpoint, 2026-11-05

The integrated client now lives at `/protocol/goodwe/client`. The binding is
`/binding/goodwe` and the Device-backed server is `/protocol/goodwe/server`.
AA55 remains the vendor codec. The client multiplexes AA55, raw/prefixed RTU and
5A5A messages through one request queue. Bespoke CLI requests support all three
wire families. See the current CLI reference for the renamed command paths.

The legacy profile adds six 5A5A firmware/network fields using functions01/03.
The binding supports whole-payload, CSV and byte-length-prefixed text fields.
The server reconstructs those module payloads from its shared Device. WLAN/LAN
readbacks appear under both module status and the configuration submenu.
Credential and network commit transactions remain outstanding.

Five additional scalar writers cover DRED, hardware power limit, output active
power, immediate charging and charge cutoff SOC. Each uses the source-traced
RTU setter, validates bounds and checks ACK/fresh readback. The configuration
emulator test passed all five. These are implemented writers with physical
changed-value validation pending. They are distinct from the five earlier
hardware-verified scalar writers. The read/write inventory records both levels.

The house profile accepts its reported GW6000ES20 identity and adds the native
application-mode enum and raw battery protocol under basic configuration.
Application mode, EMS mode and physical grid state remain separate elements.

PowerControl exposes a common Watchdog child. Its feed counter renews the
controller lease independently of changes in the requested power. The energy
allocator feeds each selected, driven surface. The binding translates renewal
into its native mode/power command cadence during continuous control and requests
automatic mode on lease expiry. It observes native state in autonomous mode
without periodic EMS writes. The experimental automatic47505 rewrite has been
removed. No native device failover action is asserted.

These branch changes have not been deployed. The complete configuration surface
and dependable hardware communication-loss fallback remain open work.

The continued survey implements four atomic TOU slot editors. Their fields stage
until the slot's apply counter changes. Apply snapshots unchanged fields as well
as edited fields, validates the complete slot and verifies one six-register
FC16 write. Mode-selection side effects are a separate pending transaction.
Parameterized 5A5A functions04/05 now populate both server states and channel,
sent and received packet counters. Alternate numeric/text status replies retain
their native meaning. These additions passed emulator configuration tests.

The SPN live app survey now follows its separate 745 route. Its Advanced Settings
page exposes backup N–PE relay, remote shutdown/RCR/EnWG14a, power limits, AFCI and
five safety categories. Battery Function uses separate parameter, protection and
immediate-charge pages. The growing screen inventory is in
GOODWE_SPN_MENU_SURVEY.json. A native profile error was corrected by using
47509/47510 for this unit's software limit rather than 42003/42004. The latter
register block remains separately named. SPD, N–PE relay, CT ratio and AFCI
readbacks now use the app's exact addresses.

Both profiles include the108 installed-app safety fields. Eighty fields with
established linear encoding or raw grid-cycle representation now have bounded
scalar setters. Common profile range compilation is shared by GoodWe and Modbus.
Remaining nonlinear filter coefficients, shared mode switches and coupled
activation paths require their explicit app transactions. New safety setters
have not been changed on physical inverters.
The native profile now separates Basic/Backup, Battery Function/Parameters,
Battery Function/Limit Protection and Port Connection/Generator/Load. Generator
rated power, run time, preheat delay, dry contact and charge fraction have bounded
scalar writers. Two prohibited-time editors commit complete three-register
records. Load mode is an enum with disabled, dry-contact, time and SOC states.
The load contact and off-SOC threshold, backup enable/detection/holding, reserve
and protection setters pass emulator tests. Coupled generator threshold pairs
remain read-only until their cross-field validation is implemented.

A write-blocked native live check decoded model identity and both20% minimum-SOC
readbacks. Batching reduced the waiting configuration surface compared with
per-register polling. The private baseline contains162 reads/7 timeouts and the
batched check102 reads/4 timeouts/1 exception in the bounded run. The exception
was conditional load-on SOC47897, which is now on-demand. This is read-path
evidence only. A separate proxy test verifies FC03 and FC04 at the same register
address and catches frame-length parsing regressions. Latest proxy runtime
passed94.483s. Native control-loss fallback remains unverified.

Native action counters now cover AFCI self-test(45271=05AA), AFCI clear(45272=050A),
overload clear(45260=1), cold start(45248=4) and cancel cold start(45248=1). The ES
overload action sends03/5E with payload0F and expects03/DE plus ACK06. Commands
execute only after a counter change. They neither read a command register first
nor claim a matching state readback. Emulator tests verify exact payloads and
that startup sends no action. Configuration runtime passed93.034s. The isolated
GoodWe message codec unit module also passes under DMD's standalone unit runner;
this does not remove the unrelated full-application Windows unit-suite failure.

The native reported identity GW6000ES20 now selects the battery component, which
previously matched only SBP-labelled models. Its SOC mapping is covered by the
native profile test. Native WiFi profiles also include the same11 non-credential
module fields as the mixed ES profile. Serial Modbus bindings leave these WiFi
module fields unavailable rather than inventing values.

### Latest source reconciliation

Native AFCI self-test/alarm-clear, backup cold-start/cancel and overload-clear
are request counters. The ES overload-clear action uses03/5E with payload0F
and requires03/DE with ACK06. Actions report `acknowledged`, never `verified`: a
command ACK is not proof of its physical effect.

The native Voltage Ride Through screen reads45920/count14 in addition to45505/count5
and45499. UV1–5 are visible for Australia-A; UV6–7 are conditional on Sri Lanka.
The profile exposes voltages and explicitly named raw grid-cycle times. Seconds
require the configured country's nominal frequency, not measured line frequency.
Register45499 uses bit0 for LVRT and bit1 for HVRT. Its toggle writers compute
the new word from the pre-click state and update that state only after an ACK.
The native profile exposes both as read/modify/write booleans; changing one
preserves the other and any reserved bits.

The bounded read-only live native check after bulk-block support completed120
reads, two timeouts, zero Modbus exceptions and zero attempted configuration
writes. It does not establish setter acceptance or persistence.

Native Self-use now maps backup/grid-charge/TOU and Smart Charge switches,
monthly mask, peak sales fraction, PV priority and paired start time. Immediate
charging stages cutoff SOC, power% and enable, then verifies each in that order;
a rejected step cancels the rest. TOU and generator-period delete counters use
the source-traced5500 marker at their distinct word offsets. The full native
menu and transaction reference is GOODWE_SPN_CONFIGURATION.md. These changes
remain undeployed and physical setter validation remains outstanding.

Earlier checked runtime: configuration116.884s passed; proxy94.256s passed.
That source-survey checkpoint recorded73 distinct screen states. Its signed
frequency-response slopes use the actual native activity's signed decoder,
independently of the older ES fragment.

Optional server upstream proxying now passes emulator checks for FC03/04/06/16,
upstream exceptions, vendor AA55 and5A5A module messages, separate app peers,
proxy identity, upstream client recreation and cancellation during server removal.
An earlier guarded real-native proxy check completed123 reads with five timeouts,
zero Modbus exceptions and zero physical write attempts. Known Device-backed
serving remains the default; proxy ACKs do not optimistically alter Device state.


### Tagged schedules and module password route

The native snapshot includes47547/count48. Typed fields require the actual
schedule tag; inactive values are unavailable and do not overwrite opaque proxy
bytes. Smart Charge edits preserve the full six-word record; TOU deletes first
verify the record type. The shared bank's logical four-TOU/four-load allocation
still needs automatic free-slot selection. Seven native physical-slot editors
now cover the TOU candidate set and enforce the four-group limit.

That native survey checkpoint recorded74 screen states and127 distinct requests.
Its password editor emits5A5A family2/01, then family1/0C. Both writes were
intercepted and acknowledged synthetically; the app displayed success. The
codec/client/proxy now retain both families and reject cross-family replies.
This is not a physical credential-change test. Configuration runtime passed
120.625s; standalone message units and nine capture tests pass. Full application
Windows unit-suite limitations remain recorded separately.

The native reserve_pair editor stages both minimum-SOC values and preserves the
intervening off-grid voltage in one three-word FC16. Catalogue selection now has
a source-traced ordered transaction table, including both reserve words and the
forced-charge thresholds. The scoped low745 form now implements this transaction;
it is not a reset diagnosis or evidence for other catalogue branches.


The isolated app fixture now records the native catalogue transaction and the
peak editor's five-word boundary. config.basic.peak_shaving stages the period,
purchase limit and reserve, rejects other occupied record types, and leaves47594
untouched. A separate staged native mode form now implements Self-use/Peak
activation with per-step verification and abort on failure.
New inventory entries distinguish the loopback-only fixture from physical reads.

Latest configuration integration passed124.104s with the native peak editor.

Native TOU editors now cover physical slots1–7. A fresh42-word bank preflight
checks the four-group limit before creating a record. Emulator tests reject a
fifth group, then permit slot5 after another group is deleted, preserving the
other records. The integration test passed131.535s. Guarded native checks returned
valid48-word and42-word bank replies; latest totals150 reads/one timeout/no
exceptions/no write attempts. These are not physical setter/persistence tests.

The native reactive-selection form now stages cosφ(P), Q(U), fixed PF and fixed
Q together. Its writer rejects inconsistent combinations, verifies neutral
settings before activation and aborts after a failed step. Signed PF uses the
native disjoint hundredth-step encoding. Edits during an active staged command
remain pending for the next apply. Configuration integration passed146.669s,
including reactive transitions, invalid values, failure abort and the immutable
active snapshot. Physical reactive-power effect is not verified.

The password reminder's app policy, module classification and per-serial
dismissal preference are source-traced in GOODWE_SPN_CONFIGURATION.md. It is
not evidence of an unset-password response from the inverter; the independent
WLAN connection warning remains unresolved.

The preceding90-screen/141-request checkpoint used fully offline reactive-mode
interactions with synthetic ACKs and mutable readbacks. Its proxy integration
passed94.239s.

### November7 implementation update

The native inventory now records102 distinct screen states and150 distinct
requests. Screen states include dialogs and editor states; these counts are not
a percentage of app coverage. New write captures use the isolated loopback fixture.

Implemented staged transactions now include native Self-use/Peak activation,
eight physical standard/intelligent load editors with a combined four-group limit,
and the observed GW6000ES20 low745 single-battery catalogue selection. Intelligent
load apply verifies the export-limiter prelude before writing the period. The
catalogue form validates all fourteen fields before its seven ordered writes;
`tools/goodwe_battery_catalogue.py` emits commands from an explicitly supplied
catalogue. Busbar, dual-battery, EOA and other catalogue branches remain separate.

The observed ESU DSP23/ARM14 firmware now has General/Off-grid/Backup/TOU activation
transactions with explicit source-traced AA55 payloads and reply codes. Both profiles have staged
UDP module network/router and WLAN-password forms, with ACK/reload distinguished
from successful reconnect/readback. Ordinary UDP APN apply/clear has its own
50-byte transaction; the cloud/BLE150-byte branch is separate. Native RS485 writes
enforce the address range and discrete745 baud options.

Device-backed proxy reads exclude staged and write-only fields. Read-only wire
snapshots preserve legacy identity/runtime/settings/TOU blocks and native coupled
battery/reactive/schedule blocks. Upstream forwarding remains a distinct path;
standalone Device-backed register writes still require completion/error mapping.
No physical configuration writes or deployment accompany these changes. Hardware
acceptance, persistence, dispatch and communication-loss behavior remain unproven.

Configuration regression passed254.252s and proxy regression94.348s on the final
Windows debug build. Two standalone protocol unit modules and fifteen Python
capture/catalogue/inventory tests passed. The full application unit-suite's
previously recorded uRT temporary-file assertion remains a separate limitation.


ES First Cold Start now exposes explicit enable/cancel request counters under
`config.advanced.cold_start`. SolarGo's checked switch sets the store selector0,
which buildPackage47 encodes as04; unchecked sets selector3, encoded01. Both
expect03/A6 with ACK06. The counters report acknowledgement, not physical state.
Backup supply is a prerequisite; no physical cold start or continuity trial ran.


ES `config.meter_ct_detection` now exposes status/result words from the app's
AA55 register059C/count2 read. Status0 is idle,1 checking,2 waiting; result0 is
untested,1 correct,2 reversed,3 incorrect on the surveyed ES branch. The EMJ/IJL
two-CT nibble format is different. Raw codes remain visible and require status
context; the profile does not infer completion from an ACK or start a physical test.

The configuration regression now asserts actual repeated traffic from both
extra realtime load fields and rejects profile-parser warnings. Its earlier
load fixture used unsupported top-level element maps; that fixture is corrected.
The ES mode encoder uses the client's normal response-function OR80 correlation;
there is no separate response-code table for these steps. See
[the selector trace](GOODWE_LEGACY_MODE_ENCODINGS.json).


Meter/CT detection now also has explicit start/stop request counters. Their
source-traced payloads are059C010001 and059C010000 under AA55 control02/function39,
with response02/B9 ACK06. No test runs at startup. Emulator tests cover both
requests and rejection; status/result remain independent from the ACK. Physical
prerequisites, power-limit interaction, completion and cancellation are unverified.

The profile loader now respects protocol parser rejection for fields and root
sections. It frees the failed parse and returns failure rather than retaining a
partially parsed descriptor. The runtime regression deliberately supplies an
invalid one-word schedule commit, observes the rejected-field diagnostic and
proves no writable element is materialised. Both complete GoodWe profiles then
load and execute their valid transactions under the same stricter loader.

The full Windows unit target builds, but its run still stops in
`manager.console.command:626` at `get_temp_filename`, as in the earlier saved
run. New profile field/root-rejection unit cases compile but are not reached by
that run. The Linux test compiler is not installed; the two standalone protocol
unit modules and the focused runtime tests are separate passing evidence.


Native alarm history now has count/cursor/window fetching and eight raw records,
verified cursor publication and Unix timestamps. SolarGo7.2.2 rendered distinct
fixture timestamps, fault labels and operating states in newest-first order.
This is offline app evidence, not a hardware acceptance or persistence trial.
The updated inventories contain102 screen states and150 distinct requests.
Final runtime checks passed: configuration254.252s and proxy94.348s. The full
Windows unit target compiles but retains its earlier temporary-file assertion.
The alarm `present` expression exposed a global parser defect: `!=` had parsed
as equality. It now selects inequality, covered by numeric console cases and
compiled numeric/string unit cases (the Windows full-suite limitation still applies).
