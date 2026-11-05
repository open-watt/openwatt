# SolarGo native SPN configuration survey

Target: the house inverter reporting GW6000ES20, DSP04048-11-S03 /
ARM02020-12-S01, Australia-A. App: SolarGo7.2.2/build1521. Updated2026-11-07.
The appliance's SBP label is not its protocol identity. This document supplements
the [legacy ES survey](GOODWE_SOLARGO_MENU_SURVEY.md); neither target's menu is a
substitute for the other's.

The [screen inventory](GOODWE_SPN_MENU_SURVEY.json) records actual visible controls.
The [request inventory](GOODWE_SPN_OBSERVED_REQUESTS.json) records distinct captured
requests. Native configuration writes during this survey are intercepted; some
receive simulated ACKs to reveal conditional menus. Generator mode reads may be
explicitly synthetic. Those observations prove app behavior, not physical write
acceptance. Public records omit credentials and substitute private identities.

## Connection and status

Discovery uses UDP48899; local requests use UDP8899. This target's inverter
register requests are native RTU, with AA55-prefixed RTU replies. Its communication
module independently uses5A5A. Optional legacy AA55 registration is unnecessary.
The native client's identity read is FC03 at35000/count33. The observed principal
banks are35100/count125,36000/count27 and37000/count22. Hidden Device byte-vector
snapshots preserve unknown/reserved bytes for full-block proxy responses. The
server's serial override does not modify the physical Device identity.

Home, Parameters/Data, alarms, DSP/ARM/BMS versions and module diagnostics are
separate reads. A delayed displayed00 is not evidence that a BMS firmware fetch
succeeded. An app password reminder is also distinct from inverter registration.
The privacy reminder is gated by app state in `OverviewFragment`: downloaded
`WIFI_STATUS_SEC` (default1), inverter/model eligibility, module classification
and the per-serial `_rak` dismissal preference. `WelcomeActivity` obtains the
security flag from `WIFI_TXT_URL`; it is not a register read. Discovery classifies
the RAK module by MAC substring `60C5A8`. The preference is set by Never Show
Again and by the successful password dialog's OK callback. A fresh proxy serial
therefore has a fresh dismissal preference. The reminder alone does not establish
that the module reported a default password. This does not resolve the separate
Cannot Connect to WLAN Module error; do not spoof module identity to hide it.

See the [protocol reference](GOODWE_REFERENCE.md) and
[network investigation](GOODWE_PROXY_NETWORK_DIAGNOSIS.md).

## Settings navigation and independent fields

All register addresses below are physical addresses, not profile40000-offset
notation. Profile access must distinguish a decoded field, a working writer and
verified physical behavior. An ACK or matching register readback alone proves
neither persistence nor the resulting power flow.

| Menu | Fields / transaction | Current implementation |
| --- | --- | --- |
| Basic → SPD |45293 | Bounded scalar writer |
| Basic → Backup |45252 enable;45254 detection:0 full wave,1 half wave,2 EPS | Bounded scalar writers |
| Backup → cold start/cancel |45248=4 /1 | Explicit action counters; ACK only |
| Backup → clear overload |45260=1 | Explicit action counter; ACK only |
| Advanced → Backup N-PE relay |45288 | Bounded scalar writer |
| Advanced → software power limit |47509 enable,47510 W | Bounded scalar writers; separate from active-output control |
| Advanced → DC AFCI |45270 enable;35226 status;45271=05AA self-test;45272=050A clear | Scalar enable and action counters |
| Battery Function → Parameter Settings |45353/45355 charge/discharge current;45378/45380 second battery | Readback; parallel/dual-battery coupling must be retained before enabling writers |
| Battery Function → Limit Protection |45356 on-grid minimum SOC;45358 off-grid minimum SOC | Bounded percentage writers; app DoD input maps to100−DoD |
| Limit Protection → SOC Protection |47500:0 enabled,1 disabled | Scalar writer; inverted boolean meaning |
| Limit Protection → SOC Upper Limit |47760 | Readback; coupled lower-bound validation remains |
| Limit Protection → Backup SOC Holding |47602 | Bounded scalar writer |
| Battery Function → Immediate Charging |47546 stop SOC,47603 power%,47545 enable | Ordered apply with read/ACK/readback per step; stop action writes47545=0 |
| Port Connection → Load |47595 mode:0 off,1 contact,2 time,3 SOC;47596 contact;47597 off SOC | Bounded scalar writers |
| Load → on SOC |47897 | Conditional/on-demand; physical read rejected on this installation |
| Port Connection → Generator |47745:0 auto start,1 switch control,2 absent,3 manual | Raw mode readback; complete activation workflow remains |
| Generator → power/run/preheat |47759 rated power×0.01kW;47758 run time×0.1h;45597 preheat seconds | Bounded scalar writers |
| Generator → dry contact/charging |47746 contact;47747 charging fraction×0.1% | Bounded scalar writers |
| Generator → start/stop threshold |47756/47757: SOC for lithium, voltage×0.1V for lead-acid | Raw readback; battery-dependent bounds remain |
| Generator → voltage/frequency |45593–45596, voltage×0.1V/frequency×0.01Hz | Readback; generator mode dependencies remain |
| Generator → prohibited periods |47749/count3 and47752/count3 | Staged whole-record apply; delete action writes5500 to the first word |
| Meter Function → CT ratio |47456 | Scalar configuration; binding/detection workflows are distinct |
| Communication Settings → WLAN module |5A5A01 firmware,03 network CSV,04 status selectors,05 counters | Eleven noncredential profile fields |
| Communication Settings → password/network/APN/RS485 | Versioned module schemas, commits/reload and inverter configuration | UDP router/password forms implemented; older HTTP/APN and model-specific serial branches remain |
| Device Information → upgrade | Local controller/module versions plus cloud firmware catalogue/download | Information readback; firmware upgrade is a separate multipart transaction |

## Quick Settings and Self-use

Quick Settings traverses country/grid code, battery connection, battery catalogue
and working-mode selection. Battery selection is not one protocol-number write:
it carries catalogue/model-specific electrical parameters and protocol/index data.
The catalogue may be refreshed from the network. Writing a model index without
those coupled parameters does not reproduce the app.

The actual native Self-use settings activity is `AdvancedSetActivity`. Its
backup, TOU and smart editors are independent expandable controls. The previous
screen inventory's collapsed smart state did not expose all of its parameters.

| Self-use item | Address / encoding | Implementation |
| --- | --- | --- |
| Backup mode enable |47605,0/1 | Scalar writer |
| Charging power from grid |47606, tenths of percent;0 disables | Bounded scalar writer |
| TOU mode enable |47612,0/1 | Scalar writer |
| TOU physical slots1–7 |47547–47583, step6; six words each | Staged whole-record editors; bank preflight limits TOU to four groups |
| Delete TOU group | Base+2, write5500 | Action counter; does not overwrite the start-time word |
| Smart Charge enable |47609,0/1 | Scalar writer; app can additionally reset PV priority |
| Monthly repeat |47594,12-bit month mask | Bounded scalar writer |
| Peak power sales limit |47592, tenths of percent | Bounded scalar writer; must be coordinated with export limit |
| PV priority |47613:0 prioritize battery,1 sell electricity | Scalar writer |
| Start charging time |47590, byte0 hour/byte1 minute | Staged paired-field apply preserving the complete word |

Native TOU enable flags are6/249; power is signed tenths of percent, the cutoff
is SOC%, weekdays are a bit mask and the last word is a12-bit month mask. These
records differ from the old ES12-byte format. The shared eight-record bank also
carries peak/backup/smart types: records5–8 must not be blindly decoded as TOU.

Selecting Self-use sends work mode5 at47000 and the app's clear-mode operation
writes47511/count2 with values1,0. Peak selection also manipulates the shared
record flags and mode4. These remain coupled mode transactions, not ordinary
aliases for a continuous battery setpoint. They do not establish that a previous
external-controller watchdog latch has been released.

## Safety menus

The actual root is `NewCustomSafetyActivity`. It opens Active Power Mode Settings,
Reactive Power Mode Settings, Protection Parameters, Connection Parameters and
Voltage Ride Through. Do not substitute similarly named unused activities with
different register families. The108-field
[app schema](GOODWE_APP_SAFETY_MAP.json) and
[implementation index](GOODWE_PROFILE_COVERAGE.json) cover the common bank.

Reactive mode selection changes several registers, not just a selector:

| Selection | Values to coordinate |
| --- | --- |
| cosφ(P) |45433=1,45456=0,45482=100,45483=0 |
| Q(U) |45456=1,45433=0,45482=100,45483=0 |
| Fixed PF |45456=0,45433=0,45483=0;45482 carries PF |
| Fixed Q |45456=0,45433=0,45482=100;45483 carries signed Q |

The native profile exposes these four fields under
`config.advanced.safety.reactive_selection`. Its `apply` counter snapshots the
staged values, rejects conflicting selections, and verifies neutral settings
before activating the selected curve, PF or Q. A rejected step aborts the
remaining transaction; it does not roll back already verified steps.

`enc16:goodwe-native-power-factor` maps raw80–100 to positive lagging0.80–1.00,
and raw1–20 to negative leading−0.99–−0.80, in0.01 steps. Other raw values are
unavailable; the app's fallback display is not evidence of a valid setting.
Register45483 is signed tenths of percent, bounded−60–60%, negative leading and
positive lagging. These semantics are source-traced and emulator-tested;
physical reactive-power effects have not been tested. Offline SolarGo captures
confirm PF0.93 under-excited→raw7, PF0.87 over-excited→raw87 and fixed Q0.375
under-excited→signed−375, plus both four-register curve-selection sequences.

Native frequency-response slopes45453/45454 use signed tenths of percent,
bounded−100–100%; recovery45455 permits−100–200%. The actual native
`ActiveModeSettingActivity` reads them through `NumberUtils.bytes2Int2V2`.
This differs from the old ES fragment's unsigned read path. The native profile
therefore has signed writers; the ES decoding is not silently changed.

Response-time coefficients at45468(Q/U),45510(cosφ/P) and45512(P/U) decode as
`seconds = 0.6 * (4096 / raw - 1)`. The inverse follows the app's two-decimal
formatting, float conversion and U16 truncation. Zero or a coefficient above4096
is unavailable. Profiles expose bounded0–60s writers and retain raw diagnostics.

The native Voltage Ride Through screen additionally reads45920/count14. It maps
UV1–7 to alternating voltage×0.1V and trip-cycle words. UV1–5 are visible here;
UV6–7 require Sri Lanka country60 and the corresponding capability. Their raw
cycle fields are explicit: conversion to seconds uses the configured country's
50/60Hz nominal frequency, never instantaneous measured frequency.

Register45499 has bit0 LVRT and bit1 HVRT. The app calculates toggle writes from
the pre-click state, then updates that state after the ACK. Native profile
booleans use read/modify/write so the other enable and reserved bits survive.
HVRT start/end voltage, times and trip threshold are45505–45509. UI ranges and
extended trip-time register banks must be checked separately from raw U16 limits.

## Proof and remaining parity work

Runtime emulator tests exercise the register encodings, field preservation,
whole-record scheduling, ordered immediate charging, abort on rejected writes,
action payloads and bulk proxy responses. Guarded live checks establish read
behavior only. No configuration writes or deployment were made to either real
inverter in this pass.

This is not yet full app parity. Remaining work includes catalogue-based battery
selection outside the observed path, other model-specific mode workflows, older HTTP and cloud/BLE APN branches,
firmware transfer, hardware validation of native alarm paging and
any remaining wire formats outside the implemented proxy transport families.
Persistence and control-loss behavior also remain independent hardware questions. These are accumulated in [TODO.md](../TODO.md).
The existence of a raw-request CLI is not evidence that those workflows are
implemented in profiles.

Optional server `upstream` now forwards validated inverter and module requests,
including app writes, through the serialized GoodWe client. Peer correlation,
exception propagation, queue bounds, proxy identity and dependency recreation
are explicit. This closes the need for manual relay/reply on those wire families;
it does not replace missing typed profile workflows or hardware validation.

`TimeManagementActivity` (the load time editor) shares the schedule bank. Standard flags are1/254 and
intelligent flags2/253; bytes6–7 are rated power in0.01kW, bytes8–9 minimum on-time
in minutes, bytes10–11 zero. Intelligent save first disables the export limiter.
Mode3.0 uses twelve slots:47547–47583 in steps of six, then47840–47864 in steps
of six; its delete word is base+2. Older layout selection uses the eight-slot
factory. The mode3.0 editor permits midnight crossing but rejects equal times;
the older editor requires start before end. These formats and slot allocation
must be modeled before treating every bank slot as a battery TOU group.

On this target, the app's mode3.0 capability read is FC03 at36212/count1 and
returns exception02 (`aa55f7830220c3`). `DataCollectUtil.getSupportMode30` sets the
capability only after a valid two-byte read; `SeriesActivity` initially clears it.
Consequently the observed app uses the eight-slot branch. The twelve-slot layout
above is a conditional source finding, not a capability claim for this hardware.

Typed schedule fields now require the record's actual type. Smart Charge type5
and battery TOU type6 are distinct from load and peak layouts. A scalar Smart
Charge edit reads/validates the full record and preserves all other bytes. TOU
creation requires a complete staged record; its delete action first verifies the
record type. The readable state enum distinguishes occupied and deleted slots.
Unavailable typed fields are omitted from proxy encoding so opaque bank bytes
survive unchanged instead of being overwritten by zeros.

## WLAN password transaction

The live native app takes the UDP branch of `ModifyWifiPasswordActivity` after
reading module firmware. Its change request is **5A5A family2/function01**,
not family1/function0A. The payload is ASCII
`AT+WAKEY=WPA2PSK,AES,<new-password>\r\n`; its byte length is the frame's U16
length field. The app then sends family1/function0C with an empty payload to
reload the module. Each helper retries up to three times. The app validator
checks CRC and returns nonempty data; a success dialog is not an independent
readback of the changed password.

A private emulator trial intercepted both writes, supplied CRC-valid synthetic
02/81 and01/8C responses and reached the success dialog. No request in this chain
was forwarded to the real module. Thus the request format and app sequence are
observed; the physical ACK shape, actual credential change and reconnection are
not verified. The protocol codec, queued client and optional upstream proxy now
preserve families1/2; staged UDP credential commits are now implemented below. The older
HTTP fallback remains a separate firmware-dependent workflow.

The shared schedule bank is eight physical records, not four fixed TOU slots.
The app selects records by their tag and permits up to four TOU and four load
entries. The seven native TOU editors address physical records, with a four-group bank
limit; automatic logical/free-slot selection remains an implementation gap. Opaque bank
preservation and record-type checks prevent pretending that an occupied load,
peak or Smart Charge record is one of those TOU editors.

The app captured four valid96-byte replies from47547/count48. An earlier guarded
smoke check timed out on that read while47589/count6 succeeded; timeout is retained
as evidence, rather than turning unknown bank values into zero.

Communication → RS485 actually opens `OtherSettingsActivity`: COM address is
45127/U16, UI range1–247; baud is45132/U32, written together with FC16/count2.
This native target displays115200; the745 branch offers9600/19200/38400/57600/115200,
whereas205 omits115200. Existing profile fields are under`config.modbus`. Optional
Modbus TCP is47017 (B7A9), shown only for qualifying205 firmware/security states;
matching resistor33964 (84AC),0/1530, is YueHai-specific. Neither conditional item
was visible on this target, so they are not advertised as applicable controls.

## Native low-voltage battery catalogue commit

The applicable quick-setup activity is`Select745BatteryLowVoltageActivity`.
Its selection handler calls`setBatteryVendorCode`, then`setBatteryParamNew`;
`DataCollectUtil.setETUBatteryParamNew` serializes the four middle requests.
All words below are big-endian. This is source-traced, not a physical selection
test; a catalogue index is meaningful only with its matching catalogue entry.

| Order | Request | Content |
| --- | --- | --- |
| Conditional prelude | FC06/47743=1 | ESG2 without busbar support: single-battery mode |
|1 | FC06/47514 | Catalogue protocol/vendor code |
|2 | FC06/45350 | Catalogue capacity |
|3 | FC16/45352,count7 | Charge voltage×10, charge current×10, discharge voltage×10, discharge current×10,100−on-grid DoD, discharge voltage×10 again,100−off-grid DoD |
|4 | FC16/47531,count2 | Forced-charge start SOC×10 and end SOC×10 |
|5 | FC06/47504 | Catalogue index |
|6 | FC06/47615 | Current coefficient×100; omitted for EOA |

The app proceeds after the mode-prelude callback even if that callback reports
failure. Its helper retries individual steps up to three times. The decompiled helper
appears to retain a previous success value after later retry exhaustion; that
requires bytecode or traffic confirmation. A new
implementation must verify every step and stop on failure, rather than duplicate
that apparent success handling. Catalogue current/voltage conversion truncates
after floating-point scaling. Missing/invalid reserve strings can become zero
DoD in the app's fallback, which then encodes100% minimum SOC. This identifies
one potential writer of reserve values, not the cause of the previously observed
uncommanded reversion; no such causal event has been captured.

The native profile now additionally offers
`config.battery_function.limit_protection.reserve_pair`: stage both minimum-SOC
percentages, then increment`apply`. It performs one FC16 across45356–45358 and
preserves45357 (off-grid discharge voltage).20% minimum SOC is80% DoD. The ordinary
single-field controls remain. This pair editor does not select a battery model,
change its catalogue parameters or claim to solve persistence. Battery-specific
limits and the separate upper SOC bound still constrain hardware acceptance.

The bundled low745 fallback has207 entries in20 manufacturer groups, version231.
Its hash/schema are recorded in GOODWE_BATTERY_CATALOGUE_SCHEMA.json. The app reads
internal`BATTERY_LIST_HIGH_NAME_V7.txt` first and falls back to that asset only
when absent. A bundled model name alone is not an authoritative protocol/index
pair for the installed firmware or the latest downloaded catalogue.

## Offline workflow confirmation

A loopback-only UDP replay fixture with no upstream socket now supports app
workflow trials. Its responses are snapshots or synthetic state; none of these
trials establish hardware acceptance. New screen/request inventory entries mark
this provenance separately. The battery-selection test reached the success
dialog and matched every request in the catalogue table above.

The native peak editor is `ElectricityDemandActivity`. Save emits FC16 at47589,
**five words**, with bytes: start HH/MM, end HH/MM, FC7F, purchase limit U16×10W,
and reserve SOC U16%. Its UI enforces start before end,0–500kW and0–100% SOC. An
offline trial displayed01:23–04:56,4.37kW and23%, then emitted
`F710 B9E5 0005 0A 0117 0438 FC7F 01B5 0017` plus CRC.47594 is not written.
The typed profile editor stages those values under`config.basic.peak_shaving`,
validates type3 and writes/verifies exactly five words. A Smart Charge record
cannot silently become a peak record through that editor.

Peak activation is distinct from Save. The observed app sequence is:
1. FC06/47612=0 (TOU disable, named`setEcoMode` by the app).
2. FC16/47511,count2:[1,0] (clear external mode/setpoint).
3. FC06/47591=FC7F (peak-enabled tag plus all weekdays).
4. FC06/47000=4 (application mode).
Both selecting the radio and completing the wizard can send this sequence.
Selecting Self-use instead sends47511:[1,0],47591:037F,47612:0,47000:5, in that
order. Opening its editor from the already-selected mode can take a shorter
clear/mode path. The profile's explicit activation reproduces the full selection
path; opening an editor does not activate a mode.

`config.basic.working_mode.requested_mode` stages `self_use` or `peak_shaving`.
Increment its `apply` counter to perform the matching four-step transaction,
verifying each complete word/block before the next step. Failure aborts without
rollback. The47591 operation replaces the whole peak tag/weekday word, matching
the app; it is not a preserving edit of a Smart Charge record. Mode activation
disables TOU and clears external mode/setpoint. It leaves47505 untouched and does
not claim to release a communication watchdog latch. The peak-period editor's
own apply still only edits its period.

The latest guarded physical readcheck (before switching the app fixture) read
47511:[1,0],47000:5 and47505:10. These are raw register observations, not proof of
power flow or watchdog release semantics;47505 is not modified by this work.

## Shared-bank allocation details

Source reconciliation narrows the allocation rules: `AdvancedSetActivity`
constructs TOU candidates from bytes0–83 only, i.e. the first **seven** records.
Its Add handler rejects four existing TOU groups. `TimeModeFragment` scans all
eight records for load kinds1/2. The eighth record is also the fixed Smart/peak
record. These editors therefore have overlapping but different candidate sets;
"eight shared records" does not mean eight TOU candidates.

The native profile now exposes TOU physical slots1–7. Each staged writer reads
47547/count42 before editing its selected six-word record. Creation in a free
slot is rejected when four TOU records already exist; an existing TOU can still
be edited, and another occupied record type cannot be overwritten. The apply
writes/verifies only the selected record. Frontends can choose an eligible slot
from its state; automatic logical-group/free-slot allocation is not implemented.

The latest guarded bank check returned valid47547/count48 and/count42 replies.
Across that run150 reads succeeded, one timed out, no Modbus exception occurred
and no write was attempted. The preflight span therefore has positive target
read evidence; its setters and persistence still require physical validation.


## Native load-period implementation

`config.port_connection.load.time1` through `time8` address the eight physical
records. Each stages start/end HH:MM, raw enable/type flag, weekday mask, rated
power and minimum run time. Standard tags are1/254, intelligent tags2/253;
disabled/enabled respectively. Whole-record apply permits conversion between
these two load kinds, but rejects other occupied kinds. A fresh47547/count48
preflight counts both load kinds toward the combined four-group limit. Creation
in a free/deleted record is allowed only below that limit; guarded delete writes
5500 at record base+2.

The observed target uses the older eight-slot branch, so start must precede end.
Standard records require zero power and minimum run time. Intelligent records
permit0–100kW in10W steps and0–1440 minutes; the app's explanatory label says
10 minutes while its save validator accepts0. Reserved bytes are zero. After
validation and record ownership checks, intelligent apply writes47509=0 and
verifies it before writing the schedule. A failed prelude prevents the record
write. The export-limit change is not rolled back if the later record fails.
The load-mode selector47595 remains separate from editing its schedules.

Offline SolarGo saved00:01–00:03 as standard with bytes
`00010003FE00000000000000`, then converted it to intelligent4.37kW/17min with
`00010003FD0001B500110000`. The latter capture contains47509=0 before the FC16
at47547/count6. These are fixture ACK/readback observations, not hardware effects.
The twelve-slot mode3.0 branch remains conditional and is not enabled on this
target, whose capability read rejects36212.


## Low745 selection form and module commits

The reported GW6000ES20 profile now has a staged
`config.basic.battery_model.selection` form for the captured ESG2 single-battery,
non-EOA path. Its fourteen fields are in transaction order: single-battery mode,
protocol, capacity, charge voltage/current, discharge voltage/current, on-grid
minimum SOC, repeated off-grid discharge voltage, off-grid minimum SOC,
forced-charge start/end SOC, catalogue index, current coefficient raw×100.
`apply` validates the full form before any write, including the two equal
discharge voltages, reserve ranges and ordered forced-charge thresholds. It then
executes the seven requests in the table above, verifying every block and aborting
remaining steps after failure. Already applied settings are not rolled back.
The single-battery prelude is intentional and this form is scoped to the observed
model; it is not advertised for busbar, dual-battery, high-voltage or EOA branches.

`tools/goodwe_battery_catalogue.py` lists entries from an explicitly supplied
low745 catalogue/cache JSON and emits the form's console commands for one index.
It does not contact or configure an inverter. Use a current applicable catalogue;
the bundled fallback is not silently substituted. `--apply` must differ from the
current counter. All207 entries in the supplied fallback passed encoding checks.
The captured PYLON index116 form writes capacity200Ah,53.2V/100A charging,
45V/100A discharging,20% minimum SOC in both domains,14/19% forced-charge
thresholds and coefficient raw100. Runtime tests compare the complete request
sequence, reject inconsistent forms before writes, and abort before index and
coefficient when the SOC-block write fails. Physical acceptance/persistence is
still unverified.

The native profile's `config.communication.wlan_lan.configure` stages eight text
fields: mode (`DHCP` or `static`), address, netmask, gateway, DNS, SSID, encryption
and router_password. The last two are write-only inputs. Static addresses are
validated before any mutation; DHCP ignores the staged address quartet. Apply
sends family1/0B with `DHCP` or `static,<IP>,<mask>,<gateway>,<DNS>`, then family1/0A
with byte-length-prefixed SSID/encryption/password, then family1/0C reload. The
5A5A frame carries the overall payload length; no duplicate inner U16 is added.
Router SSID is1–32 bytes, password8–64 bytes. No control characters are accepted.

The adjacent `password.new_password` form implements the observed module WLAN
password path:8–16 ASCII letters/digits/underscore, family2/01 AT+WAKEY payload,
then family1/0C reload. All fields are snapshotted on apply; sampling cannot
overwrite staged text. A transport failure prevents subsequent steps. Write-only
inputs are cleared after completion unless a newer edit is staged. Success is
reported as `acknowledged; reconnect and readback required`: an ACK/reload is not
proof of the new address, credentials or a successful reconnection. Neither
workflow silently changes the GoodWe client's remote address. Older HTTP and
other module-generation branches remain separate parity work.


## Native alarm-history paging

SolarGo 7.2.2's `AlarmNewFragment` and `AlarmHistoryNewFragment` use FC03/55316
for the page count, FC06/47016 for a zero-based cursor and FC03/55252,count65
for the selected window. The app starts at count minus one. This is a native
platform branch, separate from legacy ES history. The encoding is traced to the
APK and confirmed by SolarGo against the isolated loopback fixture on
2026-11-07. Eight distinct timestamps, mask-bit fault labels and operating states
displayed in newest-first order. Physical hardware acceptance remains unverified.

`status.alarms.page_count` is sampled normally. To fetch a page, write
`status.alarms.page.requested_index`, then increment `.apply`. The
`native-alarm-page` transaction reads the current count, checks the index, writes
the cursor, reads the 130-byte window and rereads the cursor before publishing
the records and `.index`. Empty history invalidates the cached window/index;
other failed fetches preserve the last verified page. Cursor interference fails
the fetch. This check cannot exclude another reader changing and restoring the
global cursor during the transaction; avoid concurrent history readers.

Each window contains eight 16-byte records followed by the page-count word.
`record1` starts at byte112 (newest), through `record8` at byte0. Record offsets:

| Offset | Field | Encoding |
| --- | --- | --- |
| 0 | timestamp | U32 big-endian Unix seconds |
| 4 | subcode_mask | U16 bit mask |
| 6 | detail_word | U16 secondary condition |
| 8 | source_address | U8 |
| 9 | operating_mode | U8, waiting/on-grid/off-grid/fault/flashing/checking |
| 10 | main_code | U16 fault-catalogue main code |
| 12 | tail_raw | Four opaque bytes |

`present` excludes main_code65535 and an empty subcode mask. The main code is a
fault-catalogue selector, not an inverter model id. SolarGo resolves labels from
its wSolar catalogue using the main code, each set mask bit and the secondary
condition. The profile exposes these inputs without inventing fault labels or
copying the app's catalogue. Loopback tests cover ordered fetch, timestamps,
empty history, invalid index, cursor-write rejection and cursor drift.

## APN and authoritative proxy reads

The ordinary UDP `ApnSettingHybridActivity` branch writes FC16/47041,count25.
Its50-byte block is a big-endian U16 name length, name bytes and zero padding;
clear writes50 zeros. Both profiles expose the staged write-only
`config.communication.apn.name` and apply counter. Names longer than48 bytes or
containing control characters fail before submission. The writer verifies all50
bytes and clears the form input. Carrier/region choices come from the app's APN
catalogue; they are not separate inverter registers.

The `setType=1` cloud/BLE branch instead uses unitFA,address1063,count75 and a
150-byte name image, without this two-byte prefix. It is not silently substituted
for the UDP form. `support4g` is a model-serial eligibility list, which includes
SPN; a visible menu alone does not prove a cellular communication module exists.
The ordinary write encoding is source-traced; physical APN acceptance/reconnection
is unverified.

The Device-backed proxy no longer encodes staged transaction fields or write-only
inputs as telemetry. Read-only native snapshots retain coupled battery blocks,
reactive selectors and shared schedules. The legacy profile now retains the
actual64-byte identity,140-byte runtime and86-byte settings images as well as
individual12-byte TOU images. These preserve opaque/reserved bytes and supply
authoritative read values independently of pending form edits. Cached values
still carry their sampling age; source freshness and model-backed server writes
remain separate work. Explicit upstream forwarding continues to use wire replies.
