# GoodWe native-app protocol notebook

Current consolidated reference: [GOODWE_REFERENCE.md](GOODWE_REFERENCE.md).
This file preserves dated investigation notes. Later captures and app-source
analysis supersede some early hypotheses, particularly current scaling, module
framing, alarm pagination and legacy EMS support; use the consolidated reference
and its evidence tables for the reconciled account.

Living reverse-engineering record, started 2026-10-28 (Australia/Brisbane).
Experimental setup and CLI: [GOODWE_SERVER.md](GOODWE_SERVER.md).
Machine-readable real-device evidence: [GOODWE_OBSERVATIONS.json](GOODWE_OBSERVATIONS.json).
The broader system/version model is in [GOODWE_ECOSYSTEM.md](GOODWE_ECOSYSTEM.md).
The user identifies the app used for these experiments as **SolarGo 7.2.2**.

## Evidence and confidence

### Native LAN capture, 23:43–23:53 AEST

The earlier Linux `solargo3` capture was filtered to phone IPv4 `.3.134` or
UDP 48899. It did not establish complete app traffic coverage. The physical
OpenWatt `ether1` capture is substantially broader: VLAN-tagged frames, IPv6,
ARP and multiple LAN destinations are visible. OpenWatt's existing RPCAP server
on `.0.8:2002` streams this interface directly to workstation `dumpcap` without
protocol/address filtering or additional Pi capture-file writes.

Ten one-minute files are retained under
`.tmp/solargo-lan-rpcap-followup_00001_20261028234330.pcapng` through `_00010_...`.
They contain 188,821 frames. Phone MAC `02:00:00:00:01:04` identifies 14,214
frames in the interval: UDP/8899 to the proxy, UDP/48899 discovery broadcasts,
ARP, three ICMP port-unreachable messages and one SSDP/1900 broadcast. No phone
TCP or IPv6 flow was found in these captured reproductions. This does not rule
out a path absent from the interface or cellular traffic. RPCAP's reported drop
statistics use global interface RX/drop counters, not capture-specific loss
accounting; do not interpret them as a completeness guarantee.
Capture file sizes/hashes and phone-flow counts are saved in
[GOODWE_NATIVE_LAN_CAPTURE_01.json](GOODWE_NATIVE_LAN_CAPTURE_01.json).
A cross-check over the approximate 23:43:30–23:53:31 interval found 14,153
phone UDP/8899 frames in RPCAP and 14,186 in the independent server log. The
RPCAP data channel started after the nominal interval boundary; exact time
alignment and the 33-packet difference remain to be reconciled. Zero-loss
coverage is not established by this comparison.

The user reproduced both warnings twice during this capture. UDP/8899 included
valid AA55, CRC-valid Modbus and CRC-valid 5A5A frames; no malformed frame was
established among the unique app requests. Function 02 was sent three times at
23:44:22 alongside function 03, while FA/2329 was requested three times just
before that. Secondary framing on the same port is confirmed; an additional
app transport endpoint has not yet been identified.

Explicit replay of empty module function 02 against `.3.5:8899` at 23:49
returned `5A5A01820025`, 37 payload bytes, valid length and CRC. The payload is
three consecutive byte-length-prefixed fields, lengths 11, 12 and 11; the third
is `WPA2PSK,AES`. The first two appear to be station SSID/password. Actual values
are retained privately on the Pi and excluded from repository evidence. See
[redacted structure](GOODWE_MODULE02_STRUCTURE.json). A replay of the previously
captured empty function 0E returned no datagram within the two-second wait;
this does not prove it is unsupported.

A volatile exact-request module-02 trial was installed at 23:52:13: synthetic
SSID `OpenWatt-Proxy`, synthetic password `proxy-capture-only`, and the verified
security descriptor. Framing/CRC and the exact returned datagram were verified.
This only supplies emulator metadata; it changes no host/inverter Wi-Fi setting.
SolarGo WLAN/LAN field acceptance and warning behaviour were initially pending UI
confirmation. On Oct 29 the user reported no visible change. At 00:00:33 AEST,
server logs confirm two module-02 requests and trial replies, followed by
module-03 request/reply. Thus the trial was exercised at the server; UI acceptance
was not demonstrated. A second, bounded full-interface RPCAP capture began at 23:53:52,
with prefix `.tmp/solargo-module02-trial-lan`, 30-minute duration and 12x10 MB
ring. The original Linux capture and raw server log remain active.

- **Wire verified**: bytes were captured, framing/checksum validated, and an
  explicit real-inverter read returned the recorded response.
- **Mapped**: a field has an existing profile/codec or a cited reference. This
  does not prove which SolarGo widget uses it.
- **UI verified**: an isolated reply change produced an observed app change.
- **Hypothesis**: plausible interpretation awaiting a controlled comparison.

Batch 01 UI marker results are recorded below. Other app screen
associations remain provisional unless explicitly marked otherwise. A missing
reply is an observation within a stated wait, not proof of unsupported hardware.

## Setup and capture coverage

### WLAN session hardening, 10:41–10:49 AEST

At 12:15–12:16 AEST, three fresh proxy connections again produced both reported
complaints. All six Home read families received replies; the only unhandled
request was clock write 03/02, followed each time by about three seconds before
the first runtime read. No registration (control 00) or 5A5A request was seen.
The optional AA55 registration dance is address allocation, not password
authentication; SolarGo skips it in these captures.

A volatile proxy-only trial at 12:18 returned candidate `03/82` payload `01`
for clock writes. The exact success payload was unverified; the user reported
the WLAN error still appeared. The trial was removed with the saved restore
script. It is a negative experiment, not an implemented clock-write operation.
No clock write reached the real inverter.

The trial connection's first runtime read arrived about 47 ms after its clock
request, versus roughly three seconds without the ACK. The later WLAN error
still appeared according to the user: removing this wait did not resolve it.

At about 12:25 the user left Device Information open on the proxy and reported
BMS 0 after waiting. In that session the only newly observed reads were 90C4
and 0780; no additional BMS-specific fetch was identified. Crucially, later
wire validation found all 17 saved raw-reply rules absent after the 12:19
restore helper had reported success. M7506 and R1A had stopped being answered;
the BMS 0 result may therefore be a timeout fallback. Do not promote it to
version-decoding evidence. Explicit reinstall followed by a second complete
wire check restored 17/17 rules. Subsequent supervisor-log inspection establishes
the reset boundary: a five-second heartbeat timeout killed the good-slot app at
12:21:48, and it relaunched slot 196 at 12:21:54, clearing volatile rules. This
was not a failed restore. Another watchdog interrupted OTA at 12:29:31 and
relaunched 196 at 12:29:35; no new slot had been staged. The continuously
regenerated derived inventory was paused during retry; raw capture continued.
The cause of the heartbeat stalls is still unverified.

Fresh replay at 12:19–12:20 of all six Home reads against the real inverter is
saved in [GOODWE_HOME_COMPARE_04.json](GOODWE_HOME_COMPARE_04.json). R1D, R1A and
M7506 replies match the proxy byte for byte. M7506 still returns raw 0001 despite
the real-app UI report of 00. Identity differs only in source bus address,
intentional serial override and checksum; settings differ only in source bus
address and checksum. Runtime has additional changing values and baseline
fields. These comparisons do not establish which difference triggers the app.

The OpenWatt client now starts directly with identity read 01/02 to 7F, matching
SolarGo and avoiding address allocation. Reply correlation uses the configured
UDP endpoint, local destination, control/function and checksum, accepting source
bus addresses that may have been assigned by another client. The server still
supports optional registration for external clients. This change is independent
of the unresolved SolarGo WLAN-session error.

The direct-start client deployed to slot 197 (`good=197`, `fail=0`) around
12:31 AEST after the retry. A traced reconnect sent identity read
`AA55C07F0102000241`, received the real module's 77-byte identity response from
source 0D, and resumed runtime sampling. No control-00 registration TX appeared
in the reconnect trace. Native runtime coverage verifies direct startup, 7F and
previously assigned 0D reply sources, an extended identity payload and resumed
Device sampling. The expanded integration test also drains stderr: without it,
the native diagnostic pipe filled at about 4 KiB and blocked the test process.
All 17 research replies were explicitly restored and wire-verified after OTA;
they remain volatile. Raw capture and server/client logs continue while the
derived inventory refresh is paused.

Subsequent direct-device UI comparison: the user first reported BMS Information
`--.--`, then corrected this after waiting: it changed to **00**. Record this as
an initial placeholder followed by 00, not permanent unavailability. The proxy's
01 and batch marker 42 do not establish parity with the real device. The saved
M7506 response is raw 0001; a fresh equivalent real-app read and its timing are
needed to distinguish changed state, another source or formatting/validity rules.

The Home screenshot at 10:41 shows a WLAN-module connection failure over
previously populated marker values. Pi service/listener/VLAN remained up;
captured phone UDP requests and corresponding replies continued. A representative
00:41:28–00:44:03 UTC flow had 10,401 requests and 10,397 responses: the unmatched
requests were clock write 03/02 and the previously unanswered Modbus reads
90C4 (twice) and 0780. No 5A5A request appears in this failure window. Thus the
Home failure is unresolved; neither a populated row nor a sent UDP reply proves
SolarGo accepted fresh data. Marker overrides were restored to live Device
encoding at about 10:47 AEST, retaining the verified read extensions.

At 10:49 AEST an explicit read of the real module at `.3.5:8899` confirmed
`5A5A01030000A510` -> function `83`, length 54, ASCII
`DHCP,192.0.2.28,255.255.255.0,192.0.2.23,192.0.2.23`, CRC `5099` on wire.
Evidence: [GOODWE_MODULE_NETWORK_READ.json](GOODWE_MODULE_NETWORK_READ.json).
This agrees with the independent first-hand
[WLAN-protocol capture](https://smlx.dev/posts/goodwe-sems-protocol-teardown/).
The server now validates the 5A5A version, length and full-frame CRC, and supports
this read using explicit host metadata. Other module functions, including
02 and 0E, remain unimplemented. A successful network read is not evidence that
the Home session-health failure is fixed.

Pi DHCP options confirm `.3.118/24`, router/DNS `.3.1`; its emulated network
configuration uses those values rather than the real inverter's `.3.5` address.
The recurring password reminder is documented app behaviour; password-status,
change and recovery exchanges have not yet been identified. No password-change
or unknown clock/control request was forwarded to the real inverter.

Deployment at about 11:00 AEST committed Pi slot 196 (`good=196`, `fail=0`),
build `371d7dc2e-aa55-module`. A wire query to `.3.118:8899` returned the expected
56-byte DHCP payload with valid CRC `859B` on wire. BMS Information is restored
to 1 and the live runtime SOC was 19, replacing the frozen marker 67. Verified
read snapshots were replayed after OTA; the module metadata property is saved
in startup.conf. Capture and inventory services remained active. Native runtime
integration (including malformed/unsupported module traffic) and all seven
capture-decoder tests passed. SolarGo acceptance and the Home failure still
require a fresh phone connection; no UI success is claimed from the wire test.

The retained failure evidence was archived before deployment at
`.tmp/solargo-wlan-evidence-20261028-005609Z.tar.gz` (also `/tmp/` on the Pi):
13 files, 10,715,171 bytes, SHA256
`8b82c5968eb6fbde7e48f50a4d6aeee7542d54409988df0ac8492e63f0cbadb5`.
The archive includes server/client logs, retained packet files and current
research JSON, with file sizes/timing in `SNAPSHOT.json`. Capture continued;
append-only snapshots may end in a partial final record. The earlier 03:33
archive remains separate.

The real ES inverter is `192.0.2.28:8899`; OpenWatt's `cabin_solar` client and
binding feed the shared Device. The emulated inverter is `192.0.2.2318:8899`,
serial `00000ESU99000008`, name `Solar-WiFi99000008`. Phone observed at
`192.0.2.2334`. The Pi's internal VLAN address `.3.122` is distinct from its
Linux socket address `.3.118`.

Evidence on the Pi:

| File | Contents |
| --- | --- |
| `~/ow/goodwe-solargo.log` | Server raw RX/TX, capture IDs and unhandled/malformed diagnostics |
| `~/ow/goodwe-upstream.log` | Client experimental raw RX/TX and server messages (tag prefix `aa55`) |
| `~/ow/solargo-capture/solargo.pcap*` | Full packets visible on Linux VLAN 3 for the phone, plus discovery, across all ports; rotating 8 × 20 MB |
| `~/ow/solargo-capture/probe-20261028-02.json` | Explicit read probes and raw real-device responses |
| `~/ow/solargo-capture/installed-20261028-02.json` | Temporary exact-request snapshots installed to unblock app exploration |
| `~/ow/solargo-capture/inventory.json` | Automatically refreshed classified events and deduplicated request/response inventory |

The pcap started after the first app connection and its transient systemd unit
does not survive a Pi reboot. Server log records are concatenated syslog; split
at `<PRI>1 ` headers. `tools/goodwe_capture.py` reads these records, validates wire
formats and emits JSON events plus a deduplicated inventory. Example:

```text
python tools/goodwe_capture.py capture.log --peer 192.0.2.2334 --output inventory.json
```

The Pi's transient `solargo-inventory.service` runs the same tool with `--watch 5`,
refreshing its JSON atomically whenever the server log changes. Like pcap, this
service must be restarted after a Pi reboot. It classifies wire formats; semantic
interpretations and controlled UI results belong in this notebook.

Logs use UTC; convert to Brisbane by adding 10 hours when associating app actions.

### Collected evidence archive

On 2026-10-28 around 03:33 Brisbane, all retained server/upstream logs, probe
files, installed-rule list and current inventory were archived with a complete-
packet pcap snapshot. Local archive:
`.tmp/solargo-evidence-20261028-0333.tar.gz`; Pi copy:
`/tmp/solargo-evidence-20261028-0333.tar.gz`.
SHA-256: `d20053184a41350f985f96ab4dea15888b886f2e533221a49af48d6fcb11dfcf`.
The archive and six individual file hashes were verified after transfer. The
pcap snapshot contains 88,921 complete packets; the capture continues separately.
At 03:32:53, tcpdump reported 88,916 captured/received packets and zero kernel
drops, no service restarts since 01:47:44, and no rotated file had been discarded.
This supports capture completeness within the stated interface/filter/time
coverage, not every communication the phone might make elsewhere.

## Wire formats

**AA55 vendor frame:** `AA 55 SRC DST CONTROL FUNCTION LEN PAYLOAD SUM16_BE`.
The sum covers header and payload. Responses normally set function bit 7.
Length must equal `9 + LEN`. Requests use source `C0` or `B0`, destination `7F`.
The real inverter responds from `0D` for identity/register reads, but `7F` for
`01/1D`. Do not impose one source address across all response types.

**Modbus RTU request over UDP:** `UNIT FUNCTION ADDRESS_BE COUNT_BE CRC16_LE`.
Captured reads use function 03 and unit F7 (247) or FA (250).

**GoodWe Modbus response:** `AA 55 UNIT FUNCTION BYTE_COUNT PAYLOAD CRC16_LE`.
The CRC covers bytes after the `AA55` prefix, including unit and function.
These packets are not AA55 vendor frames. This distinction explained why an
earlier probe that expected an unprefixed Modbus response reported a timeout.
The manual client now preserves these raw replies before the normal decoder.
See the [reference validator](https://github.com/marcelblijleven/goodwe/blob/master/goodwe/modbus.py).

## Request inventory

Hex request bytes below include checksums. Main-screen traffic repeats the
identity/runtime/settings reads and capability probes. Retries are evidence of
waiting, not independent protocol commands.

| ID | Exact request | Interpretation and evidence | Emulator status |
| --- | --- | --- | --- |
| D01 | ASCII `WIFIKIT-214028-READ`, UDP 48899 | Discovery; app receives IP, MAC-like ID and Solar-WiFi name | Implemented |
| R02 | `AA55C07F0102000241` | Identity; model/serial/firmware returned by real inverter | Live mapped identity plus real baseline and proxy serial override |
| R06 | `AA55C07F0106000245` | Running data, 140-byte payload; SOC, home consumption and grid import look right to user | Live mapped values over captured baseline |
| R09 | `AA55C07F0109000248` | Settings, 86-byte payload; real response verified | Captured baseline; named settings not yet Device-mapped |
| R1D | `AA55B07F011D00024C` | Real response `01/9D`, 16-byte payload `00010000000000000000000000000000`; field meanings unknown | Temporary exact-request real-response rule |
| R1A | `AA55B07F011A03059C0202EF` | Read 2 registers starting at 059C, real `01/9A` payload `00000000` | Temporary exact-request real-response rule |
| M7506 | `F703750600016A91` | BMS Information, unit 247, register 29958; 1 -> 42 marker displayed as decimal 42 | UI verified; batch 01 marker active |
| MD6D8 | `F703D6D80043A8DE` | Read unit 247, register 55000, count 67; 134 data bytes; screenshot confirms alarm history records | Temporary exact-request real-response rule; record fields partially UI verified |
| M2329 | `FA03232900014BCD` | Read unit 250, register 9001, count 1 | No response captured in one 1.6-second probe; no rule |
| M90C4 | `F70390C400103C6D` | Read unit 247, register 37060, count 16 | No response captured in one 1.6-second probe; no rule |
| M0780 | `F703078000019000` | Read unit 247, register 1920, count 1 | No response captured in one 1.6-second probe; no rule |
| W0302 | `AA55C07F0302061A0A1C012A0202B6` | Payload decodes as 2026-10-28 01:42:02 and aligns with connection time; likely clock set | Captured once, unanswered, not replayed upstream |

R1A is a register read, distinct from W0302. The reference
[`Aa55ReadCommand`](https://github.com/marcelblijleven/goodwe/blob/master/goodwe/protocol.py)
constructs `01 1A 03 REGISTER_BE COUNT`. That source also implements register
writes with `02/39` and response `02/B9`; these write commands have not yet been
observed from this app session. Actual app captures and completion semantics
must be established before implementing named control operations.

## Known fields and app observations

The 20-image batch from 03:08–03:11 is transcribed by attachment order in
[GOODWE_SCREENSHOTS.json](GOODWE_SCREENSHOTS.json). Phone clocks provide only
minute-level timing. Screenshots are conversation attachments; the evidence
archive contains wire logs and this repository contains their structured
transcription, not copies of the image binaries. Installer credentials are
intentionally omitted from the transcription.

Offsets are zero-based within the vendor response payload, not the full frame.

| Response | Offset / encoding | Meaning / evidence | Remaining question |
| --- | --- | --- | --- |
| R02 | 0..4, 5 ASCII bytes | `2323E`: DSP 23/23, ARM base-36 E = 14; user sees DSP 23 and ARM 14 | BMS Information 00 is not explained by this field |
| R02 | 5..14 / 31..46 | Model / 16-byte serial | Confirm native app's model-dependent feature selection |
| R06 | 26, u8 | Battery SOC; profile and user display agree | No UI marker experiment needed for current decoding |
| R06 | 34, u16 × 0.1 V | Grid voltage | Existing mapping |
| R06 | 38 / 80 | Grid power / direction selector | User sees plausible grid import; verify sign transitions |
| R06 | 43, u16 × 0.1 V | Backup voltage | Voltage being present is separate from configured backup enablement |
| R06 | 42 / 51 / 52 / 77, u8 | Grid/load/energy/effective modes per current profile | Which field SolarGo labels Working Mode remains unverified |
| R09 | 12, u16 | Backup supply; real value 1 | User initially saw OFF while R09 was unanswered; recheck after baseline |
| R09 | 18, u16 | Export limit enabled; real value 1 | Do not equate this automatically with both software/hardware power-limit labels |
| R09 | 40, u16 | BMS protocol setting per existing profile; real value 0 | Does not establish Battery Model or BMS firmware display semantics |
| R09 | 66, u16 | Configured work mode; real value 0 | Map enum and verify widget; N/A may be fallback from previously missing R09 |
| MD6D8 | first u16 = 0040 | Candidate history count/header | Meaning unconfirmed |
| MD6D8 | bytes 4..7 = 6A96A6B2 | Unix-seconds interpretation renders 2026-09-01 10:19:30, exactly as the screenshot | UI verified for three records; timezone interpretation remains separate |

The MD6D8 block has eight plausible Unix timestamps at offsets `4 + 16*i`,
for i=0..7, in chronological order: 2026-09-01 10:19:30 and 10:29:07 UTC;
2026-09-02 03:13:09, 03:13:18, 03:15:07, 03:17:19, 08:43:17 and 10:25:46 UTC.
The subsequent screenshot confirms a repeated 16-byte history-record layout
starting at payload offset 2; details below. Header and trailing fields remain
unknown.

### MD6D8 alarm records: screenshot correlation

The user-provided screenshot (phone clock 3:20, proxy serial `00000ESU99000008`)
contains these three fully readable entries, each matching the saved response:

| ID | Displayed date/time | Code | Type | Status | Temperature | Displayed message |
| --- | --- | --- | --- | --- | --- | --- |
| 512 | 2026-09-01 10:19:30 | 192 | BMS Warning | On-grid | 43 | Battery under SOC,Battery under total voltage |
| 515 | 2026-09-02 03:13:18 | 256 | BMS Alarm | Waiting | 12 | Battery communication failure |
| 517 | 2026-09-02 03:17:19 | 256 | BMS Alarm | Waiting | 11 | Battery communication failure |

Another partly clipped card shows code 256, BMS Alarm, Waiting, temperature 6;
its ID/date are not visible, so it cannot distinguish records 518 and 519.
Visible full cards are in descending time/ID order.

For each 16-byte record at `payload[2 + 16*i]`:

| Record-relative offset | Interpretation | Confidence / limit |
| --- | --- | --- |
| 0..1 | Unknown prefix, preserve raw | Unknown |
| 2..5 | u32 big-endian timestamp in seconds | Three timestamps exactly match the app when rendered as UTC, with no +10h conversion; does not establish inverter timezone semantics |
| 6..9 | Code, decoded as u32 big-endian | 192 and 256 match; all observed high words are zero, so full field width remains unproven |
| 10 | Type: 3 = BMS Alarm, 4 = BMS Warning | UI verified; other enum values unknown |
| 11 | Status: 0 = Waiting, 1 = On-grid | UI verified; other enum values unknown |
| 12 | Unknown byte, FF in this snapshot | Do not merge into a signed temperature without further evidence |
| 13 | Temperature byte: 0C = 12, 0B = 11, 2B = 43 | UI verified for positive values; unit/signedness beyond these values unconfirmed |
| 14..15 | u16 big-endian ID: 0200 = 512, 0203 = 515, 0205 = 517 | UI verified |

Payload consists of header `0040`, eight such records, then trailing `03B6002A`.
That does not yet explain whether header 0040 is a count, flags or metadata.
Records 513/514/516 are absent from the visible portion; 513 and 516 have zero
codes in the response, suggesting cleared-event filtering, but scrolling and
other filters have not been controlled. The screenshot establishes the named
labels only for type/code pairs (4,192) and (3,256), not a universal code table.
Per-record raw bytes, decoded values and screenshot evidence are stored in
`GOODWE_OBSERVATIONS.json` under the MD6D8 observation.

Profile mappings are in `conf/profiles/goodwe_profiles/gwxx48es.conf`.
The upstream [ES decoder](https://github.com/marcelblijleven/goodwe/blob/master/goodwe/es.py)
provides an independent implementation for running/settings offsets. Exact
SolarGo widget associations require observation rather than inference from names.

## App behaviours already observed

- The user sees broadly correct measurements, but initially saw Battery Model
  Self Define, Working Mode N/A, Backup OFF and questionable power-limit flags.
  R09 was unanswered at that time; it now has a verified real baseline. Battery
  model and each flag still need individual confirmation.
- Alarms initially spun indefinitely. Returning the verified MD6D8 snapshot
  stopped the spinner and rendered alarm history. The screenshot confirms three
  record IDs, dates, codes, types, statuses, temperatures and messages above.
- The WLAN-password reminder is documented for each WLAN connection in SolarGo
  5.6.2 onward; it is not evidence of an unset password response. See
  [GoodWe's manual, page 6](https://www.goodwe.com.au/Ftp/EN/Downloads/ZUO/GW_SBP-G2_SolarGo-User-Manual-AU-C.pdf).

## Experiment record and next observations

### Read probe 03: filling Advanced/Battery/Safety reads on the same inverter

The proposed second-inverter comparison was cancelled before any probe was sent
to it. All reads here used the existing `cabin_solar` client to the original
`192.0.2.28:8899`. Evidence: [GOODWE_READ_PROBE_03.json](GOODWE_READ_PROBE_03.json).
Normal sampling was paused only during the explicit probes and restored in a
finally block. No configuration or execute command was forwarded.

At 04:16–04:17 Brisbane, 18 requests were tested. Thirteen produced checksum-
validated, full-length register replies. Those 13 exact request/response pairs
were installed on the emulator and queried again, matching byte-for-byte.
They extend the prior read snapshots; batch 01's three marker overrides remain
active. The app can now receive real data for these formerly unanswered reads:

| Read address / count | Observed data / candidate purpose |
| --- | --- |
| F7 B158 / 17 | Protection bank; first words 2650, 75. Local EMS profile comments identify B158 as GridVoltHighS1, but units/widget mapping need app confirmation |
| F7 B169 / 10 and / 16 | Connection bank; first words 2540, 1960, 5015, 4750, 60. Candidate connection voltage/frequency/time settings from local profile comments |
| F7 B16D / 12 | Overlapping connection/adjacent bank, first word 60 |
| F7 B183 / 67 and B179 / 66 | Larger overlapping protection/curve/settings banks |
| F7 B253 / 33 and / 1 | All FFFF words; preserve the real response, do not interpret as configured numbers without sentinel semantics |
| F7 B7BC / 1 | Value 0, purpose unresolved |
| F7 B1AC / 1 | Value 1000; local comments call this fixed active power in per-mille. Candidate 100%, requires UI verification |
| F7 B9B9 / 2 | Values 0 and 100. Reference names are fast-charge enable and target SOC; candidate Immediate Charging source |
| F7 B1C8 / 1 | Value 0; local comments call this P(U) time constant, still needs UI confirmation |
| AA55 01/1A, 05A1 / 1 | Value 20; candidate off-grid remaining-SOC reserve (possible DoD 80%), requires UI confirmation |

Counts after the slash are decimal, addresses hexadecimal. The native Modbus
responses cover **147 distinct register words**. Overlapping ranges contain no
conflicting values in this probe. Local naming evidence is in comments in
`conf/profiles/modbus_profiles/goodwe_ems.conf`; that profile covers other firmware
families too, so names alone do not establish this inverter's semantics.

Unit FA register 0BC3/count 83 had no response within this probe's 1.6-second
post-send wait. Paired tests of F7 native Modbus registers 0500 and 050E also
had no captured reply. Their AA55-wrapped equivalents returned a checksum-valid
**one-byte payload 15**, whereas a one-register value would require two bytes.
Treat those as short possible rejection replies, not PV voltage or SOC. This
does not establish equivalence of the two register spaces.

Installed rules are recorded on the Pi in
`~/ow/solargo-capture/installed-read-probe-03.json`. Original probe data is
`read-probe-20261028-03.json` in the same directory. The marker restore script
was extended to retain these 13 real-response rules after restoring live R06
and normal R09/M7506; its former version is saved as
`marker-batch-01/restore.before-read-probe03.conf`. These new replies are volatile
snapshots, not yet live Device bindings. The next UI pass should distinguish
which retrieval failures disappear and which settings now populate.

#### Follow-up at 04:25: unchanged Battery Function values

The user reports the page still shows values identical to the 03:57–03:58
marker screenshots. The capture proves a fresh visit: at 04:25:05,
04:25:16 and 04:25:41 the phone requested B9B9/2 and 05A1/1 and received the
new verified replies each time. B9B9 payload was `00000064`; 05A1 payload was
`0014`. These reads were not left unanswered by the emulator. Delivery does not
prove the app accepted or used them. Shared R09 marker values were intentionally
unchanged, and no fresh R09 read appears in this page-specific sequence, so
identical charging voltage/DoD alone does not establish stale or cross-device
data. The user has been asked whether the failure toast still appeared and
off-grid DoD stayed blank. Do not infer a fully successful page or promote the
current-scaling hypothesis.

A separate `AA55C07F031D00025E` appeared at 03:59:54 and 04:25:33. The local
enum calls execute 03/1D `disconnect_reconnect_grid`; exact app-action association
and response semantics remain unverified. It was logged and left unanswered,
never relayed to the real inverter. This is distinct from read 01/1D.

### Restored marker batch 01: 22 numeric fields

The user authorized simultaneous, distinct markers to reduce UI turnarounds.
Manifest with original/modified raw frames and every byte offset:
[GOODWE_MARKER_BATCH_01.json](GOODWE_MARKER_BATCH_01.json).
It was active on the emulator through three exact-request rules:
R06 runtime, R09 settings and M7506. All three response datagrams were queried
and verified byte-for-byte after installation. The source Device and real
inverter were not modified, and the client remains in normal sampling mode.
These deliberately synthetic replies were removed at about 10:47 AEST on
2026-10-28 to eliminate frozen telemetry and BMS-version 42 as confounding
factors in the connection-failure investigation. The restore file also retains
the 13 validated read extensions from probe 03.

| Screen / area | Distinct markers to look for |
| --- | --- |
| Home / Data | SOC 67%; SOH 94%; battery 51.2 V, 2.3 A, 31.7°C; BMS charge/discharge limits 11 A / 17 A |
| System Data | Grid 234.5 V, frequency 49.87 Hz (may round), import 678 W (about 0.68 kW); backup 221.6 V, 1.3 A, 456 W (about 0.46 kW) |
| Advanced Settings | Power limit 4321; power factor 0.93 |
| Battery Function | Capacity 123 Ah if exposed; charging voltage 54.3 V; current-setting raw values 37 and 43 (observe integer amps versus 3.7/4.3 A); discharge voltage 47.6 V; remaining-SOC raw 25, candidate DoD 75% |
| Device Information | M7506 changed from 1 to 42: look for BMS Information 42 decimal or 2A hexadecimal |

Flags, enums, identity, capability blocks and alarm history were preserved for
this batch. Home power-flow values may be derived from several numeric fields;
use directly named Data rows to establish individual mappings first. Fields
that remain at old/default values despite the marker identify another data
source, cached UI, or missing reads; they do not disprove a mapping by themselves.

The batch is volatile and is not written into startup.conf. Pre-batch normal
reply commands and the four prior exact real-read rules are saved on the Pi at
`~/ow/solargo-capture/marker-batch-01/restore.conf`. Restore with
`sudo python3 /tmp/apply_solargo_markers.py restore`, which clears experimental
rules and reinstalls those saved baseline commands and raw replies. This
restores Device-backed encoding for R06 rather than freezing its saved frame.
Archive the observation screenshots before restoration. After UI comparison,
record each changed/unchanged row and advance confidence only where the unique
marker is actually seen.

#### Batch 01 results: 03:57–03:58 screenshots

Fifteen of the 22 markers are directly confirmed, two current-setting fields
show transformed values, and five markers were not visible in the submitted
images. Per-field results are recorded in the batch JSON.

- R06 confirms battery voltage at 10 (0.1 V), temperature at 16 (0.1°C), current
  at 18 (0.1 A), charge/discharge limits at 20/22 (integer A), SOC/SOH at 26/29
  (integer %), grid voltage at 34 (0.1 V), import-power magnitude at 38 (W, with
  existing import direction), frequency at 40 (0.01 Hz, rendered to one decimal),
  backup voltage at 43 (0.1 V) and backup power at 81 (W).
- R09 confirms charge voltage at 24 (0.1 V) and on-grid DoD as `100 - u16(32)`.
- Changing M7506 from 1 to 42 made BMS Information show **42**, explicitly
  reported by the user. R1D was not changed. This links the field to that read,
  but does not establish its complete validity/formatting rules.
- Battery power is 0.12 kW, consistent with `51.2 V * 2.3 A = 117.76 W`; Home
  consumption is 0.80 kW, consistent with `678 + 117.76 = 795.76 W` with PV zero.
  These derived relationships need sign/mode variation before generalization.
- Runtime status and No Battery/Battery Disconnected remain unchanged despite
  nonzero synthetic voltage/current. Those widgets use separate status fields.
- Home's Hardware Power Limit now says OFF (previously ON). No flag was directly
  changed in this batch; its data source or dependency remains unresolved.

Current-setting scaling requires a focused follow-up: R09 raw 37 at offset 26
shows 13.9 A; raw 43 at offset 28 shows 33.6 A. Together with earlier baseline
133 -> 50.0 A and 64 -> 50.0 A, the results are numerically consistent with
factors 0.375 and 0.78125 respectively after rounding. This is a hypothesis,
not a decoded scale: capacity, BMS version and other numeric fields also changed
in the batch, and the page still reports Failed To Retrieve Data. Hold all
other values fixed and obtain another point before changing the profile's
current descriptors or implementing writes.

### Screenshot batch: app navigation and additional requests

The screenshots establish this UI tree:

```text
Home: power flow, status, grid code, working mode, battery, backup, limits
Parameters
  Data: Information -> System Data -> BAT System
  Alarm: alarm-history cards (empty in an earlier 03:09 image)
Settings
  Communications -> WLAN/LAN
  Device Information -> Update Record
  Installer login -> Advanced Settings
    Limits / DRED / Shadow Scan / Backup / Detection Mode / Battery Activated
    Power Factor / Clear Overload History / Output Active Power
    Battery Function
      Charging/discharge limits / SOC protection / DoD / Immediate Charging
    Safety Parameter Settings
      Protection Parameters / Connection Parameters / Curve Settings / Other
```

**Verified UI outcomes after read baselines:** Home now displays General Mode,
PYLONTECH US2000B-TB*2, Backup ON and Meter/CT Normal. Device Information displays
DSP 23, ARM 14, **BMS 01** on the proxy rather than the earlier 00. The later batch 01 marker
confirmed M7506 as its source: 42 displayed as decimal 42 while R1D was unchanged. These screenshots
confirm the display values, not an independently controlled real configuration.

The R09 snapshot and screenshots support these candidate field associations:

| R09 payload offset | Raw value | Visible setting | Status |
| --- | --- | --- | --- |
| 12 | 1 | Backup ON | Consistent with existing profile and UI |
| 16 | 1 | Shadow Scan ON | Consistent with existing profile and UI |
| 18 | 1 | Software Power Limit ON | Candidate association with existing export-limit field |
| 20 | 10 | PYLONTECH US2000B-TB*2 | New battery-selector candidate; full enumeration unknown |
| 24 | 560 | Charging Voltage 56.0 V | Consistent at scale 0.1 V |
| 32 | 20 | On-grid DoD 80% | Consistent with `100 - value` |
| 42 | 90 | Power Factor 0.90 | Consistent at scale 0.01 |
| 52 | 5000 | Power Limit Value 5000 | Consistent with existing export-limit field |
| 66 | 0 | General Mode | Candidate configured-mode enum mapping |

Important discrepancies remain:

- Home shows Hardware Power Limit ON, while Advanced Settings shows it OFF.
- Battery Function shows charging and discharge currents of 50.0 A, but the
  R09 snapshot contains raw 133 and 64 at offsets 26/28. Neither an assumed
  integer-amp nor 0.1-amp interpretation explains both displays. Do not treat
  these controls as decoded current settings yet.
- SOC Protection is ON in the screenshot while the existing profile's R09
  protection field at offset 56 is zero. Its actual widget source is unresolved.
- Battery Function displays `Failed To Retrieve Data`, and off-grid DoD is empty,
  despite other controls containing values. Such values may be cached/defaulted.
- WLAN/LAN shows empty network/encryption fields, all-zero IP/mask/gateway/DNS,
  DHCP OFF, and a communication-instability toast. These are not evidence of the
  real dongle's network configuration.
- Safety pages display values including 0.1 Hz thresholds and unusual voltage
  thresholds while their reads are unanswered. Record them as UI observations,
  not verified protection settings. No such setting was written to the inverter.

The archived wire log contains **17 additional request variants** in 03:09–03:11,
stored under `screenshot_interval_requests` in `GOODWE_OBSERVATIONS.json`:

| First local time | Request(s) | Screen correlation |
| --- | --- | --- |
| 03:09:15.827 / 15.857 | `5A5A01020000F4D0`, `5A5A01030000A510` | WLAN/LAN minute; module-protocol candidate |
| 03:09:30.213 | `5A5A010E000034D3` | Same communications interval; purpose unknown |
| 03:09:41.086 | Unit FA, register 0BC3 (3011), count 83 | Device/communications/update-record interval; exact screen unresolved |
| 03:10:29.086–29.111 | Unit F7: B169/10, B16D/12, B253/33, B158/17, B183/67 | Advanced-settings interval; several ranges prefetched together |
| 03:10:36.831 | F7: B253/1 | Advanced-settings interval |
| 03:10:49.832–49.864 | F7: B7BC/1, B1AC/1 | Advanced-settings interval |
| 03:11:03.509 | F7: B9B9 (47545)/2; AA55 01/1A register 05A1 (1441)/1 | Battery Function minute; precise widget association unresolved |
| 03:11:21.854 | F7: B169/16 | Safety-settings minute |
| 03:11:32.139–32.140 | F7: B179/66, B1C8/1 | Safety-settings minute |

All listed F7/FA requests are CRC-valid Modbus function 03 reads. Counts after
the slash are decimal register counts, while register addresses are hexadecimal.
No real-device replay was performed during the initial screenshot transcription;
read probe 03 below subsequently obtained and installed 13 full responses.

**New wire family:** the eight-byte `5A5A` messages have a valid Modbus-style
CRC16 covering the preceding six bytes, stored little-endian. This does **not**
make them ordinary Modbus requests: interpreting the prefix as unit/function
would produce unit 90, function 90. Their common observed body is
`01 COMMAND 00 00`, with commands 02, 03 and 0E. Message meaning, length-field
interpretation, response layout and read/write semantics are unverified.
The inventory now classifies them separately as `goodwe-5a5a`; they remain
capture-only, with no synthetic replies or upstream relays.

The Update Record screenshot says No Data. The login image followed by Advanced
Settings establishes navigation only; no independent authentication request or
successful device-side authentication has been identified from those images.

### Initial connection, 2026-10-28 03:04–03:05 Brisbane

The user explicitly announced opening the app and connecting, then reported the
WLAN-password reminder again. Existing real-response snapshot rules remained
unchanged during this observation. Phone address stayed `.3.134`; source UDP
ports changed between discovery and sessions.

| Local time | Captured action |
| --- | --- |
| 03:04:13.965 onward | Discovery requests and valid discovery replies |
| 03:04:46.986 | Identity R02 request/reply |
| 03:04:47.020 | W0302, payload `1A0A1C03042E` = 2026-10-28 03:04:46; unanswered |
| 03:04:50.036 | Runtime R06, then identity/settings and R1D/R1A/M7506 probes, all answered |
| 03:05:09.144 | Another identity request on a new source port |
| 03:05:09.191 | W0302, payload `1A0A1C030508` = 2026-10-28 03:05:08; unanswered |

The roughly 3-second gap after the first W0302 is consistent with an ACK timeout;
that cause is not yet proven. Two time-shaped payloads matching connection time
strengthen the clock-setting interpretation. Neither command was forwarded.

The capture through 03:05:37 contains 16,236 RX/TX events since 03:04:00.
Requests include discovery 27 times, R02 972 times, R06 977, R09 969, R1D 1,476,
R1A 1,066 and M7506 2,630, plus the two W0302 frames. The app issues rapid batches,
sometimes three identical M7506 reads within milliseconds, rather than only a
slow telemetry refresh. Do not mistake each retry/batch for a new command.
The reason for this cadence is unresolved. No new request family was observed
in that window, and no dedicated password-status request was identified.

The reminder recurred while R1D, R1A and M7506 were answered with verified real
replies. That is consistent with the documented recurring WLAN reminder; it does
not establish that any particular returned flag indicates an unset password.

### Home/Parameters switching and Alarms, 03:05–03:08 Brisbane

The user switched Home ↔ Parameters several times and explicitly announced
another visit to Parameters around 03:07. The capture through 03:07:22 showed
the same six read families R06/R02/R09/R1D/R1A/M7506, with rapid repeated batches;
no distinct Parameters-only request was established. That may reflect shared
background data rather than a separate screen-fetch operation.

At **03:07:54.964**, immediately after the user announced opening **Alarms**,
the app sent MD6D8 (`F703D6D80043A8DE`) three times within a millisecond and
received the verified real-device snapshot each time. This is a strong direct
screen-to-request association for MD6D8. The user initially reported that the
spinner stopped and the list was empty, then clarified that **there is content**
and reported sharing a screenshot. Content display after the verified response
is user-confirmed. Subsequent image inspection matched three records exactly;
the field layout and explicit enum/message pairs above are now UI verified.
Date filtering, active/history selection, count/header semantics and remaining
record fields still need investigation.
Later traffic still consists of the shared six-read background sequence; the
recent tail contains no new alarm-detail or pagination request. The user has
been asked about any visible date or Active/History filtering before changing
the alarm payload.

On 2026-10-28 around 02:20 Brisbane, the real client was put into manual mode,
the seven R1D/R1A/Modbus requests were explicitly sent, replies saved, and normal
sampling restored. Four replies validated. Their exact-response rules were
installed only on the emulator and are volatile; no real configuration write
was made. These snapshots preserve real data but are not ongoing sampling.

For each new screen/action, record local time and screen name, new request bytes,
capture ID/peer, real response or bounded timeout, changed payload byte(s),
synthetic value, observed app label/value, and a confidence update. Distinct
numeric markers may be batched as authorized; isolate ambiguous enums, flags
and interdependent fields in later passes. Record and restore each prior rule. A successful synthetic ACK
does not demonstrate that the real inverter applied a write.

Next priorities: map alarm header/pagination and remaining record fields; associate Battery Model,
BMS Information, Working Mode and separate power-limit flags with their reads;
capture actual configuration actions and their result/error responses; identify
pagination and selective alarm-detail reads. Keep outstanding implementation work
in [TODO.md](../TODO.md).
