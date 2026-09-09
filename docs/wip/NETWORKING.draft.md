# Networking

Contracts of the IP layer that hold on every backend: the in-tree stack, the Linux and Windows
host stacks.

## Interface scope ids

A link-scoped address (IPv6 `fe80::/10`, `ff01::/16`, `ff02::/16`) only means something together
with the link it lives on. `InetAddress.scope_id` names that link, and throughout OpenWatt it is
one identity regardless of IP backend:

- `0` is unscoped.
- `1 .. 2^26-1` is an OpenWatt interface: the object's collection slot (`BaseInterface.scope_id`,
  resolved by `interface_for_scope`). The slot is process-local, never reused for another name,
  resolves to null while the interface is destroyed, and resolves to the replacement once an
  interface of the same name is recreated. Bridges and VLAN sub-interfaces are interfaces in their
  own right, so the zone of a frame received through a bridge is the bridge, never the member port.
- `0x8000_0000 | n` is host-stack interface `n` that OpenWatt does not manage (a Windows adapter
  or Linux netdev with no OpenWatt object). It passes through the native boundary unchanged and
  never resolves to an interface.

The internal IP stack works in this space directly. Native backends translate at urt's socket
boundary through an `InetScopeProvider` the interface module registers: outbound (`bind`,
`connect`, `sendto`, `IPV6_MULTICAST_IF`, `IPV6_ADD_MEMBERSHIP`) maps a scope to the
interface's kernel index and fails with `invalid_parameter` when the zone has no live interface or
that interface has no native counterpart; inbound (`accept`, `getsockname`, `getpeername`,
`recvfrom` sender and packet-info) maps the kernel index back. Windows numbers IPv4 and IPv6
bindings separately, so the IPv6 index is what a scope translates to there. A specified zone is
never dropped or replaced by a default interface.

Text form is `addr%zone`: a zone name is an OpenWatt interface (`fe80::1%eth0`), a number is a
host-stack index (`fe80::1%3`). Persistent configuration and anything crossing to another node
carries names; the numeric ids are runtime handles only.

UDP endpoints keep the zone end to end. A bound or connected link-scoped address carries its
zone, so the same link-local on two links binds twice and each receiver sees only its own link;
received link-scoped source and destination addresses are stamped with the ingress interface.
Joining an IPv6 group pins the endpoint's outbound interface, and a link-scoped destination
without a zone is sent through that interface; an explicit zone that names another interface
is refused rather than rerouted.
