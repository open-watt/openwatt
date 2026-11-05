# GoodWe operational discovery — GW5048D-ES

Consolidated reference and full directories:
[GOODWE_REFERENCE.md](GOODWE_REFERENCE.md). This file records the operational
experiments; the reference also reconciles app safety descriptors and ESU current
scales discovered afterward.

Evidence date: 2026-10-29, Brisbane. Target: cabin_solar at 192.0.2.28,
DSP 23/23, ARM 14, module V1.1.3.14, SolarGo 7.2.2/build 1521.
Discovery is incomplete. The static command index is wider than the verified
wire surface; neither is a claim of implemented configuration support.

## External power control

The desired operation is to replace automatic battery dispatch with an explicit
battery charge/discharge power target. An inverter stop command, generation
ceiling, grid exchange target and battery power target have different effects.

The [manufacturer's third-party EMS protocol](https://en.goodwe.com/Ftp/EN/Downloads/GW_Third-Party-EMS-Protocol_MODBUS-EN.pdf)
V1.1.1, pp. 17–27, documents:

| Operation | Mode | Setpoint |
| --- | --- | --- |
| Automatic self consumption | 1 | Not applicable |
| Battery standby | 8 | Not applicable |
| Battery charge power | 11 | Positive watts |
| Battery discharge power | 12 | Positive watts |
| Grid import/export control | 4/5 or 9/10 | Model-specific grid target semantics |
| Inverter stopped | 255 | Not applicable |

Its two register blocks are 42000/U16 + 42001/U32 and 47511/U16 + 47512/U16.
Applicability differs by block and model; the legacy ES is not listed. The
document specifies a 1-second write cadence. Its fallback register 47505 has
model-dependent behavior after 30 seconds: 2 stops, 3 returns to self use on a
restricted model list, and 10 retains the last mode. This is not a verified
fallback contract for our ES. The older ARM745 map calls 47505 a manufacturer
code rather than a fallback mode. Do not merge these versions into one profile.

SolarGo's `EmsModeActivity` independently reads three words from 42000, decodes
U16 mode + U32 power, writes mode with `GoodUtil.writeSingle(42000, ...)`, and
writes two power words with `writeMultiple(42001, 2, ...)`. Display is kW with
write gain 1000. Its menu visibility depends on model/safety flags. Presence in
the APK does not establish availability for this ES.

**Newer-map target probe:** individual reads of 42000 and 42001/2 returned Modbus exception
02; individual reads of 47511 and 47512 returned exception 04. Earlier combined
reads returned 04. AA55-wrapped reads of these blocks returned a one-byte `15`
instead of register data. No newer-map register was written. Those failures do
not rule out the older control map below. The owner confirms this GW5048D-ES has
no accessible EMS port: the communications dongle is its communication path.

### Working legacy control map

The [legacy manufacturer V1.3 map, pp. 10 and 18](https://downloads.vodnici.net/uploads/wpforo/attachments/483/4349-1GoodweModbusPROTOCOLHybrid-ENV1-3EMseries.pdf)
identifies **0x056E (1390), WgPowerMode** and **0x056F (1391), WgPowerSet**.
Both are U16; power is watts. Table 8-16 also gives AA55 execute **03/3A**,
one-byte mode followed by two-byte power. Automatic mode is 1, charge 2,
discharge 3, import 4, export 5, conserve 6, off-grid 7 and stopped 255.
Charge power is the maximum grid contribution, with PV preferred; discharge
power is a maximum. These are not the newer 11/12 exact battery-power modes.

Both raw Modbus F7/03 and AA55 01/1A read this pair on the real inverter.
The baseline was mode1/power0. **Modbus function 10 writes and AA55 03/3A
execute both accepted a reassertion of that baseline.** The AA55 response was
03/BA with payload `06`; Modbus returned an exact function-10 echo.

A bounded follow-up wrote mode2/power123W, then mode3/power137W. Each returned
the exact function-10 ACK and the requested pair on read-back. A finally block
restored mode1/power0, verified the original read-back, and resumed normal
sampling. This establishes writable control settings through the dongle.
It does **not** establish measured battery power, transient behavior, zero-power
semantics, restart persistence or communication-loss fallback.

Evidence:
[legacy reads](GOODWE_LEGACY_EMS_PROBE_20261029.json),
[Modbus baseline ACK](GOODWE_LEGACY_EMS_REASSERT_20261029.json),
[AA55 baseline ACK](GOODWE_LEGACY_AA55_EMS_REASSERT_20261029.json),
[charge/discharge trial and restoration](GOODWE_LEGACY_EMS_CONTROL_TRIAL_20261029.json).

The read request `f703056e0002b18c` returned
`aa55f70304000100003dfc`. The AA55 automatic-mode request
`aa55b07f033a03010000026f` returned `aa550db003ba01060280`.
These addresses are literal wire addresses, without a Modbus 40000 prefix.

The older ES **Eco path is accessible**. AA55 read 0x0701/16 returned its four
schedule groups; raw Modbus reads of 47547/6, 47553/6, 47559/6 and 47565/6 returned
data. These are schedule records, not EMS power registers. The pinned ES client
implements forced charge/discharge by replacing group 1, disabling groups 2–4
and selecting Eco mode. This is a candidate workaround with persistent schedule
effects, not a proven replacement for an instantaneous watt setpoint. The legacy
056E/056F path should now be investigated first. Snapshot,
ACK/read-back, power semantics and restoration still require validation.

The legacy AA55 `03/1E` generation adjustment must not be advertised as battery
power control. Likewise, “automatic battery management” in older maps may concern
battery settings rather than dispatch; its name is insufficient evidence.

## Reserve SOC and Battery Function

| Field | Evidence / representation | Status |
| --- | --- | --- |
| On-grid reserve | Raw Modbus 0x0560 = 20; bulk AA55 01/09 offset 32/U16 | Read verified; means minimum SOC20 / DoD80 |
| Off-grid reserve | AA55 01/1A payload `03 05A1 01`, raw Modbus 0x05A1 = 20 | Read verified; minimum SOC20 / DoD80 |
| App off-grid setter | AA55 02/39 payload `05A1 01 0015` for DoD79 | Changed20/21% reserve ACK/readback verified2026-10-30 |
| App on-grid setter | Selected 105-platform editor uses AA55 02/39,0560,count1; older03/52 path also carries voltage/current | Selected scalar path changed20/21% ACK/readback verified; coupled legacy path not exercised |
| Immediate charge | F7/03 B9B9/2, switch + target SOC | Real response `0000 0064`; UI loaded |
| BMS protocol info | AA55 01/25 → 01/A5, four bytes `0001 000C` | Read verified; not the delayed BMS version display |

The exact captured off-grid DoD79 request is
`aa55b07f02390505a1010015032a`. It was retried three times and withheld each time.
No physical reserve setting changed during this experiment.

SolarGo's bundled low-voltage battery entry 123, PYLONTECH US2000B-TB*2, declares
an 80% DoD ceiling. The current 105-platform/ARM14 validation uses that profile
ceiling for off-grid input. Entering 95 displays `Range[0,80]` and sends no packet.
This establishes an app restriction, not the inverter's acceptance range.
Do not interpret blank off-grid input as zero or cached numbers as fresh reads.

The reversion fault is now captured in the retained client trace: both reserves
changed20/20 to80/0 without a corresponding write from our client. First bad
readbacks follow a return-to-auto command, which is correlation rather than proof
of a trigger. Other LAN/cloud writers remain possible. See
`GOODWE_DAYLIGHT_20261030.json`. Monitoring must record raw values, timestamps,
work mode, battery selection/protocol, charge/discharge limits and diagnostics
across a reset, another writer or any actual reversion before proposing a fix.

## Other new wire findings

- Module version: `5a5a0101000004d0` returns
  `5a5a0181000956312e312e332e3134a199`, UTF-8 V1.1.3.14. This agrees with HTTP.
- Real WLAN/LAN reads populate the network configuration. Module 02 includes
  credentials; raw replies stay in private artifacts.
- Alarm history is stateful: write Modbus B7A8 with page number, receive a
  GoodWe-prefixed 06 echo, then read D6D8/67. SolarGo requested pages 45 then 44
  and displayed records. These cursor writes were forwarded; configuration writes
  were withheld. Our earlier blank result in this pass followed a blocked cursor.
- Real Home loaded without the proxy's WLAN error. The privacy reminder appeared
  on the real inverter too. Its static policy path is documented separately.
- Module diagnostic functions 0D and 04 with payloads 01/02 were captured but
  withheld; their effects and actual responses remain unknown.

## Reproducible coverage

[GOODWE_FULL_READ_PROBE_20261029.json](GOODWE_FULL_READ_PROBE_20261029.json)
records 30 isolated read probes: 17 data-bearing valid frames, four short AA55
`15` replies, four Modbus exceptions and five bounded timeouts. A timeout is not
an unsupported-operation finding. Manual mode was restored to false and checked.

[GOODWE_SOLARGO_FACTORY_INDEX.json](GOODWE_SOLARGO_FACTORY_INDEX.json) now indexes
1083 command-factory cases plus 1138 direct register call sites, including other
models. It preserves source locations/hashes and unresolved expressions; it
does not export executable commands or assert those operations apply here.
One method named `build105ReadingPackage` contains a restart command: classify
the assembled frame, never the Java method name, before sending anything.

The emulator pass recorded 267 app requests / 33 distinct datagrams. Its full
WiFi checkpoint contains 508 UDP/8899 frames. The emulator's Ethernet tcpdump
alone missed its WiFi traffic; WiFiPacketStream/netsimd capture was necessary.
[Capture manifest](GOODWE_EMULATOR_CAPTURE_20261029.json) records private artifact
hashes, counts and limitations. No claim covers every historical phone packet.

Generate the static index and private interaction report with:

```text
python tools/goodwe_apk_inventory.py <jadx-sources> --output <index.json>
python tools/goodwe_interactions.py <relay.jsonl> --actions <actions.jsonl> --output <private-report.json>
```

Remaining work is accumulated in [TODO.md](../TODO.md): physical ES dispatch validation,
verified write workflows, continuous reserve monitoring, module parity and shared
client/server binding implementation. Capturing or naming an operation does not
complete its implementation.
