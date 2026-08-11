# Task: split mac-ping into standard CFM reachability + OW discovery

## Background

`EthernetStation` in OpenWatt currently has three overlapping mechanisms, and one
of them is doing two jobs badly.

1. **OW echo** (`OWControl.echo_req` / `echo_reply`, defined in
   `src/router/iface/packet.d`, handled in `EthernetStation.station_control` in
   `src/router/iface/ethernet.d`). Body is `[cookie:u32 BE][flags:u8][payload]`.
   `OWEchoFlag.identify` makes the responder return its hostname instead of
   echoing the payload. `EthernetStation.ping()` is the only producer, and its
   only caller is the CLI command below.

2. **802.1ag CFM responder** (`EthernetStation.cfm_ingress`, same file). It
   answers LBM (opcode 3) with LBR (opcode 2) by copying the PDU and flipping the
   opcode. It parses nothing else: no TLVs, no MD level filtering, no source
   checks.

3. **OW address discovery** (`OWControl.addr_query` / `addr_report`, handler in
   the same switch). Broadcast an `addr_query` carrying a `PacketType` filter
   (`unknown` = all) and every station unicasts back an `addr_report` listing its
   universal addresses as `u64` big-endian entries, capped at
   `max_report_entries`.

The CLI command `/interface/ethernet/ping address=<mac> [count=] [identify=]`
(registered in `EthernetInterfaceModule.post_init`, implemented as the
`MacPingState` latent command in `src/router/iface/package.d`) uses mechanism 1
for both purposes: unicast reachability testing *and*, when given a broadcast
address, discovery sweeps. Defaults are `count=4`, `identify=true`, `count=0`
collapses to 1, one request round per second, requests emitted from every running
station, replies printed as `reply from <mac>: time=<rtt>` with a
`<replies> replies for <sent> requests` summary.

## Goal

Separate the two jobs, and use the standard where one exists.

**Unicast reachability moves to 802.1ag CFM.** Retire `OWControl.echo_req`,
`echo_reply` and `OWEchoFlag` completely. Every field OW echo invented has a
native CFM home:

- cookie becomes the Loopback Transaction Identifier, the 4-byte field LBM/LBR
  already carry after the common header
- identity becomes a Sender ID TLV (type 1) in the LBR
- the `identify` request flag disappears; always include Sender ID in our LBRs

Do **not** wrap the existing OW payload inside a CFM TLV. Use the native fields.
The Organization-Specific TLV (type 31) is reserved for future discovery metadata
that has no standard field, and it needs a real OUI, which the project does not
currently have.

**Broadcast discovery moves to `addr_query` / `addr_report`**, which is already
the right shape and just needs extending:

- add the system name so it covers what `identify` did
- add a transaction id to the query, echoed in the report, so replies correlate
  to a sweep (today `addr_report` answers either `who_has` or `addr_query` with no
  correlation field, so there is no RTT and no way to discard stale replies)
- jitter replies over a small random window; every station currently answers a
  broadcast instantly, which is a synchronised storm on a populated segment

**Fix the CFM responder while you are in it.** It answers any LBM at any MD level
from any source, which makes every OpenWatt station a rogue MIP: on a network with
provisioned CFM it will answer loopback messages belonging to someone else's
maintenance domain and corrupt their diagnostics. Add a level filter, defaulting
to answering only at a level we claim.

**Split the CLI to match** (confirmed): `ping` (unicast, CFM, RTT, single target)
and a new `discover` (broadcast enumeration listing stations with identity and
addresses).

## Why not CFM for the broadcast half

Do not re-litigate this. LBM is a point-to-point reachability test. Third-party
CFM implementations answer LBM addressed to their own MAC or to the class-specific
CFM multicast at their configured level, so a broadcast LBM gains no responders
beyond our own stations. The standard's actual discovery answer is CCM, periodic
multicast heartbeats inside a provisioned maintenance association, which is far
heavier than an on-demand operator sweep needs. CFM earns its place for unicast
interop only.

## Decisions still open, ask before assuming

- Sender ID TLV chassis ID subtype: MAC address, interface name, or locally
  assigned.
- Which MD level(s) we answer at by default, and whether that is a per-interface
  property.
- Whether identity stays the hostname or becomes a real system name. There is an
  existing TODO in the echo handler saying the hostname is a placeholder.
- Whether discovery keeps broadcast or moves to a dedicated OW multicast group.
- Whether `addr_report` gaining a transaction id is acceptable as a wire change.

## Conventions

`AGENTS.md` at the repo root is authoritative; read it first. The ones most
relevant here:

- Comments only where the code genuinely surprises. Deletion is the default, not
  shortening. No function header docs, no narration.
- No em-dash, no unicode in source.
- `snake_case` for non-type identifiers, `PascalCase` for types, Allman braces,
  4 spaces, wrap around 120 columns.
- Any CLI command change ships with its `docs/CLI.md` entry in the same PR, not as
  a follow-up. The existing `### /interface/ethernet` section documents the
  combined command and will need rewriting for the split.
- Terse commit subjects. Fold fixes into the commit that introduced the problem
  rather than appending churn commits. Strip `Co-Authored-By` trailers.
- Adding new `.d` files means updating `openwatt.vcxproj` and
  `openwatt.vcxproj.filters` as well; the Makefile auto-discovers but Visual
  Studio does not.

## Verification

- `make CONFIG=unittest` then run `./bin/x86_64_unittest/openwatt_test`.
- `src/router/iface/ethernet.d` compiles on every target, including switch-tier
  and headless builds, so check a `FEATURES=switch` build too.
- CI runs a baremetal matrix; `baremetal (bl808)` is the only 64-bit target that
  compiles the internal IP stack, so it catches size_t narrowing bugs the desktop
  jobs cannot see.

## Note on line numbers

Symbols are referenced rather than line numbers, because PR #478 (comment cleanup
plus the `/interface/ethernet` CLI.md section) shifts them slightly. If that PR is
still open when this task starts, the CLI.md section to rewrite lives there rather
than on master.
