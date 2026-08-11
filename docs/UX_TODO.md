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
- There is no ETag/If-Match yet: two editors saving the same file last-writer-wins.
