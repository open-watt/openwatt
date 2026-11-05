# GoodWe AA55 server

The reconciled protocol, register maps, command directories and validation limits
are documented in [GOODWE_REFERENCE.md](GOODWE_REFERENCE.md). This page describes
the current server and experiment CLI; capture/reply capabilities do not imply
that every referenced operation is implemented.

`/protocol/goodwe/server` exposes a Device to AA55 clients, including a
SolarGo discovery/capture experiment. It is a profile binding with a UDP listener:

```text
real inverter -> GoodWeClient -> GoodWeBinding -> Device -> GoodWeServer -> native app
```

The ongoing request inventory, field confidence and reverse-engineering evidence
are maintained in [GOODWE_PROTOCOL.md](GOODWE_PROTOCOL.md).

By default the server reads the current Element values for every request. Its `aa55:` profile
descriptors supply function codes, offsets, field sizes, scales and encodings.
The client and server can use the same profile and Device. A different producer,
or console assignments, can populate the Device instead.

The AA55 client starts with a direct `01/02` identity read to address `7F`,
matching the captured SolarGo flow. It does not query registration or allocate
an inverter address. Responses are matched by configured UDP endpoint, local
destination address, control and function, with checksum validation; the source
bus address may already have been assigned by another client. The server still
supports registration for other clients that choose to use it.

## Optional upstream proxy

Set `upstream=inverter-link` to use a configured GoodWe client for actual app
requests and responses. Requests retain their originating peer; the client
serializes all three supported wire families with its other work. This includes
writes: it is an explicit real-inverter proxy mode, not simulated acceptance.
Default Device-backed serving remains available with upstream unset.

Discovery, registration, explicit raw/vendor response rules and the synthetic
module-network override stay local. Identity reads retain the proxy serial while
the physical Device identity is unchanged. Native exceptions propagate, and
queue/target failures do not generate success ACKs. Pending duplicate requests
from one peer are coalesced. The bounded queue and dependency subscriptions are
cancelled on shutdown or replacement. The Device's producer binding continues
sampling independently; a forwarded ACK is not optimistic Device state.

Only validated vendor AA55, bare RTU FC03/04/06/16 and module-family1/2 requests
use this path. Unknown formats remain captured/logged for explicit experiments;
this does not establish support for every module or firmware-transfer format.

## Expose an existing inverter Device

Substitute the real inverter address and the OpenWatt host's LAN address:

```text
/protocol/goodwe/client/add name=inverter-link remote=192.0.2.21:8899
/binding/goodwe/add name=inverter-reader client=inverter-link device=inverter profile=gwxx48es model=GW5048D-ES
/protocol/goodwe/server/add name=solargo device=inverter profile=gwxx48es model=GW5048D-ES advertise-address=192.0.2.22
```

To distinguish the proxy from the real inverter in the native app, give the server
its own serial and matching discovery name:

```text
/protocol/goodwe/server/set solargo serial-number=00000ESU99000008 discovery-id="020000000101,Solar-WiFi99000008"
```

The override changes the identity served on the wire and used in address
registration. The shared Device retains the real inverter's serial.

The server participates in the binding collection and shares its name namespace.
It does not create an online-status source for the Device: serving a cached value
does not imply that the real inverter is online.

AA55 listens on UDP 8899; discovery listens on UDP 48899. The default bind address
is `0.0.0.0`, which permits LAN broadcast discovery. Set `advertise-address` to the
host address reachable by the phone. When it is unset, the server uses
`bind-address`; it never advertises the wildcard address. Host firewall rules and
Wi-Fi client isolation must allow the phone to reach those ports.

The discovery probe is `WIFIKIT-214028-READ`. The response is
`<advertised IPv4>,<discovery-id>`, with a default discovery ID of
`020000000001,Solar-WiFiOpenWatt`. Set `discovery-id` to the MAC/name fields observed
for the dongle being emulated if the app requires a different identity. Discovery
does not create a Wi-Fi access point. The phone and OpenWatt must already share a
reachable network.

The separate CRC-protected `5A5A` WLAN-module protocol supports the verified
empty-payload function `03` network-configuration read. Configure the emulated
module with the host's actual DHCP network details:

```text
/protocol/goodwe/server/set solargo module-network-config="DHCP,192.0.2.2318,255.255.255.0,192.0.2.23,192.0.2.23"
```

The value is descriptive: it does not change Linux networking. The default is
empty, which leaves that read unanswered. Malformed lengths/CRCs and response
frames are rejected; other module functions remain logged and unanswered.
Password changes and network writes are not implemented. The recurring SolarGo
password reminder alone is not evidence of an unset password; see the protocol
notebook for the documented app behaviour and outstanding connection failure.

This implements the legacy discovery exchange used by the
[GoodWe Python client](https://github.com/marcelblijleven/goodwe/blob/master/goodwe/__init__.py).
Actual appearance and navigation in SolarGo still require a phone test. Newer
Modbus, Bluetooth and encrypted dongle transports are outside this AA55 endpoint.

## Capture configuration requests

### Interactive protocol investigation

Use the existing upstream client so experiments share its socket. Enable manual
mode, wait for pending requests to drain, and resume sampling when finished:

Use `/log/print tag=aa55 --stream` to watch the combined client/server log. Captured
request IDs are also printed with incoming traffic when the server trace is on.

```text
/protocol/goodwe/client/set cabin_solar manual=true trace=true
/protocol/goodwe/client/request client=cabin_solar control=1 fn=9
/protocol/goodwe/client/received client=cabin_solar
/protocol/goodwe/server/requests server=solargo
/protocol/goodwe/server/relay server=solargo id=42 client=cabin_solar
/protocol/goodwe/client/received client=cabin_solar
/protocol/goodwe/server/answer server=solargo id=42 data=0,42 repeat=true
/protocol/goodwe/client/set cabin_solar manual=false
```

Replace 42 with a current capture ID. The answer payload above is an experimental
marker, not a real device value. `answer` adds AA55 framing/checksum; `repeat=true`
matches the complete captured request and bypasses Device encoding. Without repeat
it sends once to that captured peer. `raw-reply` and `respond` accept complete wire
datagrams for Modbus RTU or other protocols. `send` on the client sends complete
wire bytes; `request` builds an AA55 frame. Byte arguments are comma-separated
decimal or `0x`-prefixed bytes, not a space-separated hex dump.

Relay is explicit and may execute a configuration write on the real inverter.
It never automatically relays the upstream reply back to the app. `received`
shows only the latest datagram, not a correlated success indication: inspect its
addressing/function/length/checksum, and use logs when multiple responses arrive.
Normal Device values stay cached while the client is manual. Restore
`manual=false` to resume sampling. Captures retain the last 32 datagrams, IDs
expire, and experimental raw rules are capped at 32 and persist only in memory
unless their console commands are saved. `clear-replies` removes both kinds of
rule, including installed baseline reads.

Capture the upstream side as well:

```text
/stream/file/add name=aa55-upstream tx-file=/home/manu/ow/goodwe-upstream.log tx-mode=append
/log/sink/add name=aa55-upstream stream=aa55-upstream format=syslog tag=aa55 max-severity=info
```

This tag prefix includes both client and server logs. For each experiment record
the app action, request bytes, real response, one changed field and its recognizable
value, and the resulting app display. Only confirmed semantics should become
named client operations and bidirectional profile mappings.

The CLI build was deployed by OTA as Pi slot 195 (`good=195`, `fail=0`). The
runtime integration test covers raw relay, inspecting the response, one-off raw
response, exact-request matching, automatic AA55 checksum framing, and resuming
live values. On the Pi, a read-only identity request and a captured settings read
were sent through `cabin_solar`; the settings reply was inspected and returned
byte-for-byte to the captured test peer. Manual mode was then disabled. The
`aa55-upstream` file stream and log sink were added to startup.conf, with backup
`startup.conf.before-solargo-cli-20261028`. Experiment replies added during tests
were confined to the isolated host test; no synthetic rules were left on the Pi.

`trace=true` is the default. The `aa55-server` log tag records received and sent
datagrams in hex with the peer address. Unknown valid requests also report their
control code, function and payload; malformed datagrams are recorded before
validation. Record a persistent capture with the existing log sink:

```text
/stream/file/add name=aa55-capture tx-file=goodwe-capture.log tx-mode=append
/log/sink/add name=aa55-capture stream=aa55-capture format=syslog tag=aa55-server max-severity=info
```

Change one setting at a time in the app and note the setting name and before/after
values. The syslog file preserves timestamps for correlation. No configuration
write is acknowledged or applied automatically: these commands are the subject
of the experiment, and a success reply does not establish their semantics.

An explicit experimental reply can unblock a dialog once the expected response
has been observed. Supply payload bytes only, without the AA55 header/checksum:

```text
/protocol/goodwe/server/reply name=solargo control=2 fn=57 data=1
/protocol/goodwe/server/clear-replies name=solargo
```

That example is a **synthetic** `02:B9` response with payload `01`, not a verified
configuration acknowledgement. Rules match control/function, regardless of request
payload, and reply with the function's response bit set. They do not change the
Device or forward anything to the inverter. For an ordinary read without a request
payload, a rule supplies baseline bytes and length, then mapped Device values are
encoded over it. This preserves observed reserved fields while keeping mapped
values live. Missing mapped values still prevent a read reply.

Rules survive server restart but are in-memory only. Put the `reply` commands after
the server's `add` in a startup script if they should survive process restart.

## Standalone simulated Device

The test profile provides a small lab inverter with identity and grid voltage.
For a separate lab instance, start with an empty startup script and
`--profile-path test/profiles`, then run:

```text
/protocol/goodwe/server/add name=lab device=lab profile=aa55_server_test advertise-address=192.0.2.22
/element/set element=lab.info.firmware value="2323G"
/element/set element=lab.info.model_id value="GW5048D-ES"
/element/set element=lab.info.serial_number value="00000ESU00000001"
/element/set element=lab.info.nominal value="3600"
/element/set element=lab.info.software value="TEST-0001"
/element/set element=lab.grid.voltage value=230.5V
```

These are simulated values. The server supports address discovery/assignment/removal
and direct reads. Identity must be populated before registration succeeds.

## Current coverage

Only profile descriptors attached by `element-map` become server fields. An AA55
descriptor merely declared under `elements:` does not expose a value. The existing
`gwxx48es` template maps much of function 6, but only model and serial in function 2;
its other identity fields and setting/status groups need mappings for fidelity.
Bytes without mappings are zero unless an explicit reply baseline supplies them.
Known response structures have minimum lengths for functions 1, 2, 3 and 6; other
functions use the greatest mapped field end or the supplied baseline length.

Unset or unencodable mapped fields suppress that read response. The server serves
the last stored Device values, including when its source is offline. It does not
refresh the real inverter on demand, translate configuration writes into Element
updates, or implement client write-back. Those require captured command semantics.
The negotiated bus address belongs to the emulated inverter and is shared by its
clients, just as the identity is.

## Verification

```text
python test/test_goodwe_server.py --binary bin/x86_64_windows_debug/openwatt.exe
```

The test uses the repository runtime harness with an isolated temporary startup
script, a loopback console and dynamically allocated UDP ports. It verifies
discovery, identity, invalid frames, experimental replies, the complete
client -> Device -> server path, a changed measurement and listener restart.
Codec and reverse-encoding unit tests live alongside the implementation.

## Pi capture deployment (2026-10-28)

The Pi (management address `192.0.2.20`) runs the server as `solargo`, bound to the existing
`cabin_solar` Device. Its existing client reads `192.0.2.28:8899`. Discovery
advertises `192.0.2.2318,020000000101,Solar-WiFi99000008`; the wire serial is
`00000ESU99000008`. AA55 and discovery use UDP 8899 and 48899 respectively.

Linux NetworkManager connection `solargo-vlan3` creates VLAN 3 as `solargo3` on
`eth0`, with MAC `02:00:00:00:01:01` and DHCP address `192.0.2.2318`. It adds no
default route or DNS. This is required because the Linux build uses host UDP
sockets; OpenWatt's internal `ether1.3` address (`192.0.2.2322`) does not expose
those listeners. VLAN 3 broadcast discovery and identity replies were checked
from a socket bound to `192.0.2.2318`; the address also responds across the LAN
router. The advertised address is currently explicit and must follow any DHCP
lease change. The original `.0.8` advertisement was corrected in startup.conf,
with another backup at `startup.conf.before-solargo-vlan3-20261028`.

The ARM64 release uses October master `371d7dc2e` plus the server changes, with
its pinned uRT. OTA committed slot 194 (`good=194`, `fail=0`). Both the original
branch and production-baseline builds passed the loopback client/Device/server
test. LAN unicast and broadcast discovery, identity, functions 1/2/3/6 and
malformed-packet logging were verified against the deployed instance.

The capture sink appends timestamped full RX/TX hex to
`/home/manu/ow/goodwe-solargo.log`, including unknown and malformed messages.
Its syslog records are concatenated (the current sink omits newlines for syslog);
split at the `<PRI>1 ` record headers when reading the file. Configuration is in
`/home/manu/ow/conf/startup.conf`, backed up as
`startup.conf.before-solargo-20261028` before adding the capture block.

Read baselines for functions 1/2/3/6 were captured from the real inverter. Mapped
fields are overwritten from the live Device on every response; unmapped fields,
including the function 1/status and function 3/settings baselines, remain captured
snapshots. No write reply rules are installed. SolarGo discovery, primary screens
and alarm-history display have now been exercised; see the current field/evidence
status in [GOODWE_PROTOCOL.md](GOODWE_PROTOCOL.md).

### First SolarGo connection

SolarGo traffic from `192.0.2.2334` confirmed discovery and successful identity
and function 6 reads. The user reported an immediate WLAN-password reminder;
the capture alone does not establish what triggers that dialog. GoodWe's
[SolarGo manual, page 6](https://www.goodwe.com.au/Ftp/EN/Downloads/ZUO/GW_SBP-G2_SolarGo-User-Manual-AU-C.pdf)
documents the matching reminder on each WLAN connection from app version 5.6.2,
with Skip and Never Show Again options. It is not evidence that a response from
our server reported an unset password. No password-specific response has been
implemented.

New requests observed (control/function in hex):

- `03/02`, payload `1A 0A 1C 01 2A 02`: consistent with a clock write of
  2026-10-28 01:42:02, matching capture time; interpretation remains inferred.
- `01/09`, empty payload: unanswered.
- `01/1D`, source `B0`, empty payload: unanswered, retried three times.
- `01/1A`, source `B0`, payload `05 9C 02`: unanswered, retried three times.
- `F7 03 75 06 00 01 6A 91`: valid Modbus RTU CRC, unit 247, function 3,
  register `0x7506`, count 1, transported on the same UDP port. Captured by the
  AA55 listener but rejected as non-AA55; register meaning is not established.

The app repeats these probes alongside successful identity and telemetry reads.
No captured write was applied or forwarded to the real inverter.

The user also reported the Alarms screen spinning indefinitely. Additional
CRC-valid Modbus RTU reads were captured on UDP 8899 during screen exploration:
unit `F7`, register `D6D8`, count 67; unit `FA`, register `2329`, count 1;
unit `F7`, register `90C4`, count 16; unit `F7`, register `0780`, count 1.
Initially these received no response because the listener only decoded AA55.
Subsequent explicit real-device reads and an exact-request reply rule for D6D8
allowed Alarms to render history. A user screenshot confirms the 16-byte record
layout and three entries' IDs, times, codes, types, statuses and temperatures;
the notebook records remaining header/pagination uncertainties. These are valid
non-AA55 packets, despite the generic `invalid AA55 datagram` diagnostic.

### Settings-screen comparison

The user reported correct SOC, consumption and grid import but different battery
model, working mode, backup enablement and power-limit indicators. A subsequent
read-only probe of the real inverter obtained the missing `01/09` settings block
(86 bytes). It was installed as an explicit read baseline and verified byte for
byte at the emulator, then persisted in startup.conf. The original reply is saved
on the Pi as `solargo-capture/settings-baseline-20261028.hex`. This is still a
settings snapshot, not a live Device mapping; the phone must confirm which labels
it corrects. `01/1D` also returned a 16-byte payload and `01/1A` at `0x059C`, count
2, returned four zero bytes from the real inverter. These replies, the Modbus
`0x7506` value 1 and the alarm-history block were later installed as volatile
exact-request read snapshots. An initial Modbus probe reported a timeout because
it expected an unprefixed reply; raw CLI inspection exposed the GoodWe `AA55`
Modbus prefix and CRC. No guessed labels or write acknowledgements were added.

After the first session, `solargo-pcap.service` was started as a transient systemd
unit for wider capture. `tcpdump` listens on Linux `solargo3`, preserving full
packets on all ports for phone `192.0.2.2334`, plus all UDP 48899 discovery.
Files are `/home/manu/ow/solargo-capture/solargo.pcap0` through `solargo.pcap7`,
rotating at 20 MB each. This captures traffic visible at the Pi, not the phone's
unrelated Internet traffic. It does not retrospectively cover other ports in the
first session, and the transient service must be restarted after a Pi reboot.
Check status with `systemctl status solargo-pcap`; stop with
`sudo systemctl stop solargo-pcap`. The persistent application log remains at
`/home/manu/ow/goodwe-solargo.log` and includes raw RX before parsing, raw TX, and
explicit unhandled/malformed diagnostics.

Module families1 and2 retain their family byte through forwarding and response
correlation. A family1 reply cannot satisfy a family2 request. Device-backed
module fields and synthetic network overrides apply only to family1. The WLAN
password route is captured and its ACK/reload chain is simulated, not physically
validated.
