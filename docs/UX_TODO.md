# UX client task accumulator

Client-visible changes land here as dated task sections; UX clients (sync consumers) work
through them and remove sections as they are absorbed.

## 2026-08-07: interfaces expose a `caps` property

- All `/interface` collections gain a read-only `caps` bitfield property naming the
  interface's transport promises: `ethernet`, `reliable` (acknowledged/retransmitted
  delivery), `ordered` (in-order delivery). Clients rendering interface detail views may
  surface it; absence of a flag means no promise, not a fault.

## 2026-08-07: UDP moved from stream to packet interface

- `/stream/udp` collection is removed. UDP is not a byte stream; it is now modelled as a
  raw-packet interface.
- New collection `/interface/udp` (type `udp`): properties `local-host`, `local-port`,
  `remote-host`, `remote-port`, plus the standard interface MTU/status/traffic properties.
  Clients enumerating interface types should expect the new type; anything offering
  `/stream/udp` in pickers/forms must drop it.
- Log sinks can no longer be given a UDP transport (syslog over UDP is unavailable) until
  sinks can bind a packet interface.

## 2026-08-10: ethernet stations gain `cfm-level`; mac ping/discover CLI split

- All ethernet-station interface collections (platform ethernet, bridge, vlan, wifi, udp)
  gain a `cfm-level` property (0-7, default 7): the 802.1ag maintenance level the station
  answers loopback at. Clients rendering interface detail/edit views may surface it.
- `/interface/ethernet/ping` no longer accepts `identify=` and rejects multicast/broadcast
  addresses; it is now a unicast 802.1ag loopback (works against third-party CFM gear).
- New command `/interface/ethernet/discover`: broadcast sweep listing OW stations on the
  segment with their system name and universal addresses. Anything that offered broadcast
  ping as a discovery affordance should move to it.

## 2026-08-10: constant-valued elements no longer carry a one-record history

- An element that has never been given a retention policy now keeps its latest value
  directly and has no series behind it. This is the normal case for `constant`/`config`
  elements, notably the whole `info.*` subtree (manufacturer, model, serial, firmware).
- Consequence for clients: a history/backfill request for such an element returns an empty
  range rather than the single synthetic record it used to report. The element's current
  value, timestamp and metadata are unaffected, so anything rendering the value needs no
  change; only views that plot or tabulate history should treat "no history" as normal for
  these rather than as an error or a gap.
- Elements that do have retention (everything the default policy covers, plus event/point
  elements) are unchanged.

## 2026-08-11: static file mounts gain writes and opt-in CORS

- `/protocol/http/static` mounts accept `PUT` (store a file, `201` created / `200`
  replaced) and `DELETE` (`200`, or `404` when absent) beneath the mount's URI, plus
  `OPTIONS` preflight. The config file editor should target these directly.
- New property `allowed-origin` (empty | `*` | one origin): CORS policy for the mount.
  The default (empty) sends no CORS headers, so a web client served from a different
  origin than the backend must have the mount configured with its origin (or `*`) before
  cross-origin reads or writes work. Error statuses carry the CORS headers too, so a
  cross-origin client sees real 404/403 codes.
- Uploads stream to disk: `PUT` bodies are no longer capped by the server's 64KB
  `max-request-body`, and an interrupted upload leaves the previous file intact. Requests
  the mount refuses (403, 405, 409, 500) still drain the body and answer with the real
  status, so large uploads never die as opaque network errors.
- Downloads above 64KB stream from disk with a known `Content-Length` and are NOT
  content-encoded, where the previous buffered path gzipped them. Large text pays for this
  on the wire: the 132KB `goodwe_ems.conf` gzips ~4.9x, so it now transfers at full size.
  Compressing a streamed body needs `Transfer-Encoding: chunked` (the compressed length
  isn't known up front) plus an incremental compressor, and urt.zip's is whole-buffer
  only, so this is deferred. Clients should not assume large files arrive compressed.
- `.conf` and `.log` serve as `text/plain`, `.yaml`/`.yml` as `text/yaml`, so they display
  in a browser tab instead of downloading as `application/octet-stream`.
- There is no ETag/If-Match yet: two editors saving the same file last-writer-wins.

## 2026-08-12: link speed is populated on every interface, and on streams

- `tx-link-speed` / `rx-link-speed` (bits per second) previously only ever had a value on
  platform ethernet interfaces. Every interface type now reports one where it can: modbus,
  can, tesla-twc, zigbee, ble, i2c, ash, cpc (trunk and endpoints), websocket, ppp, vlan,
  bridge and udp. Views that hid the field, special-cased ethernet, or assumed it meant
  "ethernet only" should now render it for any interface.
- `0` still means unknown and must be rendered as such, not as "0 bit/s" or as a down link.
  It is a genuine outcome: a modbus interface reached over a TCP bridge with no configured
  or estimated baud honestly does not know its bus rate. `link-status` remains the only
  thing that says whether the link is up.
- The fields are now cleared when an interface goes offline and restamped when it comes
  back, so a client holding a cached value across a link bounce sees it go to 0 and back.
- Streams gain the same two read-only properties, so `/stream/print` and stream detail
  views can show the rate of a serial port, or of whatever a tunnel rides on.
- WLAN interfaces report the negotiated PHY rate where the platform exposes it, and the
  theoretical maximum for the negotiated mode where it does not, so the number moves with
  link quality on some platforms and is a fixed ceiling on others. Clients should not
  present it as a measured throughput; `tx-rate`/`rx-rate` remain the measured counters.

## 2026-08-13: WLAN interfaces report the negotiated PHY as `phy-mode`

- New read-only property `phy-mode` on `/interface/wlan`, a display string such as `VHT80
  2SS`: the 802.11 mode name with the channel width folded in the way the standard names
  them, the spatial stream count, and `SGI` when a short guard interval is in use.
- It is a label, not something to parse or compute with. The number that goes with it is
  already `tx-link-speed`/`rx-link-speed`. Render it as-is.
- Empty means not associated, or that the platform could not name the PHY at all. Parts are
  omitted rather than guessed, so the string is not a fixed shape: Windows reports only the
  family (`VHT`) because the association carries no width or stream count, and `11a`/`11b`/`11g`
  never carry a width. Don't assume three space-separated fields.
- It sits with `bssid`/`rssi`/`signal-quality` because it describes the association, not the
  radio.

## 2026-08-13: radios report `phy-capability`, APs report their operating `phy-mode`

- `phy-mode` is now on `/interface/ap` as well as `/interface/wlan`, same format and same
  rules. On an AP it is what the BSS operates at, which is the ceiling for every client on
  it, not any one client's negotiated rate. Per-client PHY is not reported: there is no
  client object to attach it to.
- New read-only `phy-capability` on `/interface/wifi` (the radio), same format again: the
  hardware's own ceiling, e.g. `HE160 2SS`. A bound WLAN's `phy-mode` is at or below it.
  A concrete `band` reports that band's ceiling; `band=any` reports the best supported band.
  Useful as the denominator when showing how good a link is relative to the hardware.
- Expect these to be partly filled, and don't infer "broken" from a short string. Linux and
  ESP32 report all three parts; Windows reports no capability at all, as it exposes no API
  for it.
- Worth surfacing in UI: on Linux an AP currently reads legacy `11g` on 2.4 GHz or `11a` on
  5/6 GHz, because both AP backends run the BSS non-HT, so clients are capped at 54 Mbit/s
  no matter what the radio can do. That is real, not a reporting artifact.
