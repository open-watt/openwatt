# SolarGo proxy warning investigation — 2026-10-29

Target: SolarGo 7.2.2/build1521, GW5048D-ES proxy serial 00000ESU99000008.
This investigation distinguishes app policy, protocol parsing and network delivery.

## Privacy reminder

In the extracted APK, `OverviewFragment.showPrivacySecurityDialog` (around lines
1598–1638) gates the legacy reminder on cloud policy `WIFI_STATUS_SEC`, inverter
classification, demo/RAK exclusions and the per-serial preference
`Constant.Inverter_sn + "_rak"`. The Never Show Again action sets that preference.
This path does not establish that a module password is unset. A different proxy
serial has a different reminder preference. Do not falsify module identity or
change the inverter password to suppress this policy reminder.

## Home failure and duplicate replies

`OverviewFragment.refreshNewData` shows the WLAN connection dialog after
`BroadcastFailCount` or `CollectorFailCount` reaches ten. The runtime collector
expects a valid 01/86 response to 01/06. `GoodUDP.writeInner` takes the next UDP
datagram without request/response correlation. An extra reply can therefore be
consumed by the next request, producing failures despite valid individual frames.

Simultaneous captures during the failing proxy session showed:

- The Pi sent an original reply with TTL64 and source MAC 02:00:00:00:01:01.
- The PC received duplicate IP IDs and UDP payloads with TTL63 and source MAC
  02:00:00:00:01:03. That malformed address overlaps the PC destination address
  and the original source address; it does not identify a physical device.
- Extra copies were absent from the observed Pi physical-interface capture.
- Isolated proxy request bursts did not reproduce duplicates consistently.

These observations locate a delivery problem on the tested VLAN3 path, but do
not identify the forwarding instance or prove the source-code defect causing it.
Radio monitor mode being off does not establish that a node cannot forward packets.

## Controlled alternate path

The emulator relay was retargeted from 192.0.2.2318 to 192.0.2.20, reaching the
same wildcard-bound proxy server with the same serial and protocol replies.
Home loaded without the WLAN error. Battery Function also loaded without its
retrieval error, displaying 56.0V, 50.0A charge/discharge limits and both DoD
fields at 80%. The privacy reminder remained, as its policy path predicts.

The clean Battery Function exchange includes B9B9/2 with response
`aa55f70304000000646dd7`, and AA55 01/1A address05A1/count1 with response
`aa550db0019a020014026d` (minimum SOC20 → DoD80%). No configuration writes were
forwarded in this control test. This result supports investigating delivery
before inventing additional Battery Function responses; it is not proof that
all phone/proxy paths have been repaired.

## Network inventory and evidence

The Pi sees subordinate members openwatt-4547 at .3.11 and openwatt-F993 at
.3.13. Both report monitor mode off. A third ESP32-S3, openwatt-F8C6 at .3.121
(02:00:00:00:01:02), has peering disabled and monitor mode off. Its physical
location is unconfirmed. The owner recalls an older cabin carport node and
possibly ESP32-C6/STM instances. None is identified as the duplicate source.

Private evidence under `.tmp/`: `solargo-warning-pc.pcapng`,
`solargo-warning-pc2.pcapng`, `solargo-warning-eth0-full.pcap`,
`solargo-warning-wire.pcap`, `solargo-warning-wire2.pcap`,
`solargo-proxy-warning-20261029.jsonl`, and
`solargo-proxy-ethernet-control.jsonl`. Raw captures can contain credentials.
Use the original pcaps: one PowerShell TSV export was truncated and must not be
used to infer missing packets. The relay log may continue growing while active.

Outstanding: identify the extra forwarding path, establish the exact cause,
repair it, and repeat the original VLAN3 phone/emulator test. Keep this separate
from hardware write acceptance, DoD persistence and measured EMS power response.
