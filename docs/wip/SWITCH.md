# Switch chips behind an Ethernet MAC

Design for SoCs whose CPU MAC is wired to an integrated or external managed switch. First target:
MT7621 GE1 to the MT7530 CPU port (MikroTik hEX S: ether1..ether5 are MT7530 ports 0..4; sfp1 is
GE2 through the PHY at MDIO 7 and is not a switch port). Delete this file when the work lands.

## Layering

To the CPU a switch is one Ethernet link carrying per-frame metadata, plus a configuration
side-channel. That is what urt exposes; the tag format and the chip's register map never leave urt.

### urt (`urt.driver.ethernet` and the platform driver)

- MACs are named in the vendor's space by the platform driver (`ge1`, `ge2` on MT7621); OpenWatt
  matches on the name.
- `eth_switch_ports(port)`: number of front ports behind a MAC, 0 for a plain MAC, with per-port
  facts (has a PHY).
- RX: `EthRxInfo` carries the source front port; urt strips the tag.
- TX: `eth_hw_tx` takes a destination front-port mask; urt builds the tag.
- Link events carry the front-port index.
- Configuration is declarative: OpenWatt hands over the complete desired state per front port
  (forwarding group or standalone, learning, VLAN mode/PVID/membership, forwarding state, enabled).
  urt diffs it against the chip, programs what changed, flushes learned addresses on ports whose
  group changed, and reports what it could not express.

### OpenWatt

- One class, `/interface/ethernet`, with identity properties:
  - `device`: the MAC, in vendor naming (`ge1`).
  - `switch-port`: the front port, in the chip's numbering. Unset means the interface is the MAC.
- `validate()` rejects: `switch-port` on a MAC that fronts no switch, or naming a non-front port;
  a switch-fronting `device` without `switch-port` (the conduit is not a usable interface); two
  interfaces claiming the same (device, switch-port).
- Unclaimed front ports are off: isolated, PHY powered down.
- `wire_send` passes `1 << switch-port` as the destination mask; RX and link events route by
  (device, port).
- Each logical port has its own MAC; the board supplies the source (hEX S: hard_config base + index,
  ether1..5 = +0..+4, sfp1 = +5), defaulting to base + switch-port.
- Out-of-the-box connectivity is the board's default config declaring every port and bridging the
  LAN ports; there is no implicit catch-all.

## Bridge offload

Not before OpenWatt runs standalone on the target. Until then the chip does no switching at all:
every claimed port is isolated and CPU-only, and bridges forward in software.

- The switch-front driver hooks the bridge's `ports_changed`, works out per bridge which members are
  its ports, and whether the chip can reproduce the bridge's semantics for them. If so they form a
  hardware group; otherwise they stay standalone and the software bridge forwards (always correct).
- Decline offload when the bridge uses VLAN filtering the chip cannot mirror, or a member has
  software-only per-port processing (filters, capture) that hardware-forwarded frames would skip.
- Grouped ports still deliver broadcast, unknown-unicast and CPU-bound frames to the CPU, tagged with
  their source port. The bridge gains one rule: a frame received on a member in hardware domain D is
  not forwarded in software to other members of D (switchdev's offload forward mark). The existing
  kernel-bridge CPU-port seam stays as it is for Linux.

## Phases

Status 2026-09-26 on the hEX S: phase 0 runs except GE2; phase 1 runs
except the netconsole's move to a UDP log sink. The MT7621 entry in TODO.md lists what the first cut left open.

0. MIPS GIC interrupt driver and timer tick; a real frame-engine driver (QDMA TX, interrupt-driven
   PDMA RX, both GMACs) replacing the bring-up netconsole; hard_config read through the memory-mapped NOR.
1. urt switch-front API and MT7530 driver; standalone ports; per-port link from the port status
   registers (heartbeat until the switch interrupt is wired); netconsole becomes a UDP log sink.
2. sfp1 on GE2: the SerDes PHY at MDIO 7, the SFP cage object (I2C EEPROM and DDM, presence, LOS,
   TX-disable GPIOs) and the per-port media description shared with copper ports (see the MT7621
   entry in TODO.md).
3. Bridge offload through hardware domains; per-bridge-port `hw` flag, default on.
4. VLAN-filtering bridge offload through the MT7530 VLAN table.
5. Own switch and PHY init, independent of RouterBOOT's state; MIB counters as interface stats.
