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
