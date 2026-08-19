# Peering adoption spins the authority's main loop until the watchdog kills it

Status: diagnosed to a code region, root cause not yet identified. Reproducible on demand.
Severity: high. Every adoption attempt takes the node down for ~10s; with the config persisted in
`startup.conf` it becomes a boot loop.

## Symptom

An authority that finds a claimable member enters the claim path and never returns to the main
loop. The supervisor's 5s heartbeat deadline expires, the app is killed and relaunched. The member
is never adopted, and each attempt leaves an orphaned dynamic `/sync/peer` on it (datagram links
carry no death signal, so they linger until the 5m idle sweep).

Observed 3 times on the prod Pi, always within ~10s of a claimable member appearing.

## Reproduction

Two nodes on one L2 segment (they may be bridged across a wifi hop; discovery works over it).

Authority (Pi, `192.168.0.8`, node `B1562EBC8E0223EF`):

```
/sync/discover/ether add name=lan interface=ether1
/sync/peering set role=authority cluster=home claim=*
```

Member (ESP32-S3, `192.168.0.56`, node `709889988161F993`, factory-fresh, never adopted):

```
/sync/discover/ether add name=lan interface=wlan1
/sync/peering set role=member
```

Everything up to the claim works: beacons flow both ways, both neighbour tables populate, the
authority evaluates the candidate, mints the fleet key and builds the transport. Then it spins.

## Evidence

### 1. It dies immediately after registering the claim

```
[Notice] sync.peering: minted the fleet key for cluster 'home'
[Info]   udp 'openwatt-F993-udp': destroyed
[Info]   sync.peering: claiming node 709889988161F993 ('openwatt-F993') at 28:84:85:54:FB:08:7000 (adoption)
2026-08-19T09:35:13 [ota-supervisor] no heartbeat for 5000ms; killing app
```

That log line is the last statement of `begin_claim()` ([peering.d:603](../src/manager/sync/peering.d#L603)),
so the spin is in what runs after it returns: the dynamic peer's startup, the ether-UDP transport,
or the first session frames.

### 2. Where it spins (gdb, two samples 3s apart, identical region)

```
#0  __syscall_cancel_arch ()
#3  driver.linux.ethernet.LinuxRawEthernet.wire_send(const(ubyte)[])
#4  router.iface.ethernet.EthernetInterface.medium_tx(ref Packet)
#5  router.iface.ethernet.EthernetStation.transmit(...)
#7  router.iface.vlan.VLANInterface.medium_tx(ref Packet)        <- one sample only
#11 router.iface.endpoint.EtherEndpoint.sendto(EUI!48, ushort, scope const(void)[]).__lambda_L232_C31(EthernetStation)
```

Frame 11 is the fallback flood in `EtherEndpoint.sendto`
([endpoint.d:228-235](../src/router/iface/endpoint.d#L228-L235)):

```d
if (EthernetStation i = ether_neighbour_lookup(dst))
    return emit(i, dst, frame) ? data.length : 0;
bool sent = false;
foreach_ether_station((EthernetStation s) {
    if (s.running && emit(s, dst, frame))
        sent = true;
});
```

The destination MAC missed in the ether neighbour table, so every frame floods all ethernet
stations. On this node that set includes a VLAN leg that re-forwards into `ether1` (visible in the
stack above) and a modbus bridge that fans into its member ports.

### 3. It is spinning, not blocked (`/proc/<pid>` sampled at ~100ms)

```
21:17:43.491 state=S cpu=15176 933  wchan=do_epoll_wait     <- idle, normal
21:17:43.586 state=R cpu=15178 934  wchan=0                 <- claim begins
21:17:44.011 state=R cpu=15190 964  wchan=0
21:17:45.949 state=R cpu=15262 1085 wchan=0
21:17:47.865 state=R cpu=15326 1213 wchan=0                 <- 4.3s later, still going
```

`state=R` throughout, `wchan=0` (not sleeping in any kernel call), utime +148 and stime +280 ticks
over 4.3s: ~100% of a core, roughly two thirds of it in the kernel. Consistent with a very large
number of real `sendto` syscalls, not with one that fails to return.

Blocking I/O is ruled out: the AF_PACKET socket is set `O_NONBLOCK` at open
([raw.d:166](../src/driver/linux/raw.d#L166)), so `send()` returns `EAGAIN` rather than parking.

## What is not yet known

What drives the loop. Three candidates, none confirmed:

1. **Why does `ether_neighbour_lookup(dst)` miss?** The authority is claiming a node whose beacon it
   just received, at a MAC and port learned from that beacon. A hit takes the single-station path
   and no flood happens at all. This may be the whole bug.
2. **Re-entrancy through the station topology.** The flood walks every station including a VLAN over
   `ether1` and a bridge with many members. If a flooded frame re-enters the flood (via the bridge's
   member set, or via own-frame reflection on the promiscuous raw socket - see the "own sendto
   frames reflected back" handling at [raw.d:229](../src/driver/linux/raw.d#L229)) it feeds itself.
3. **An unthrottled caller** above `sendto`, retrying with no rate limit.

## Caveat for whoever picks this up

Every observed occurrence was on a build carrying the two commits on branch
`agent/linux-station-mac` (on top of `github/master` 891738d4), which change station MAC assignment:
stations now adopt the **driver's** hardware address instead of a synthesised node-id-seeded one.
Two consequences worth checking against suspects 2 and 3:

- `ether1` and its VLAN `ether1.3` now carry the **same** MAC (a VLAN adopts its parent's), where
  previously every station had a distinct synthetic address.
- A station's MAC now equals the **kernel's** MAC on that netdev, so OpenWatt-sourced frames are no
  longer distinguishable from host-stack frames by source address.

Anything keyed on station MAC identity - own-frame suppression, loop detection, neighbour learning -
may behave differently as a result. The stall has **not** been observed on plain master, but plain
master was never exercised with a live claim either, so this is an open question, not an accusation.
Confirming or excluding it is the cheapest first move: run the same repro against a master build
(slot 104 on the Pi is exactly that).

## Reproducing off prod

The claim loop was previously validated end to end on a WSL veth pair (two Linux instances,
ether-family datagrams, binary encoder) without this stall. The difference here is the station
topology - a VLAN leg and a modbus bridge with many members - so a veth repro should add those
before expecting the stall to appear.

## Environment

- **Authority**: Raspberry Pi 3B, aarch64 Debian 13, `openwatt-pi`, `192.168.0.8`. Runs
  `openwatt --supervise` under systemd as root, WorkingDirectory `/home/manu/ow`. KernelMirror
  build: the kernel owns IP, OpenWatt holds no in-stack addresses, `ether1` is an AF_PACKET tap on
  eth0. Supervisor policy: commit 30s, watchdog 5s, max-fail 3. gdb is installed; `perf` is not.
- **Member**: Waveshare ESP32-S3-RS485-CAN, `openwatt-F993`, `192.168.0.56`. Firmware predates the
  MAC commits, includes peering, factory-fresh (no `conf/fleet.id`). Reachable on telnet 23 and
  HTTP 80, `/apps/ota` running.
- Peering config on the Pi is **not** persisted: the lines are present but commented out in
  `~/ow/conf/startup.conf`, deliberately, so a reboot cannot enter a claim loop. Re-enable by hand
  for a repro.

## Related defects found while investigating (separate issues)

- `/device/print --json` over the sync channel heap-corrupts and aborts the process
  (`free(): corrupted unsorted chunks`, then `double free or corruption` on a later attempt).
  Remote-triggerable over `/sync` with no auth; the socket simply closes, so a client sees it as
  "server not responding".
- `ash 'zbdongle': retransmit seq 7 (attempt 1..3 of 3)` immediately precedes several other
  `no heartbeat` kills that have nothing to do with peering: an unresponsive Zigbee NCP appears to
  stall the main loop past the same 5s deadline.
- `/apps/ota`'s `watchdog` property is effectively write-only at runtime. `ota_push_policy()` is
  only called from `startup()` ([ota/package.d:137](../src/apps/ota/package.d#L137)), so setting the
  property stores the new value while the supervisor keeps enforcing the old one. This blocks the
  otherwise obvious "widen the watchdog and let the claim run to completion" experiment.
