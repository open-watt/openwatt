---
name: zigbee-work
description: Deep architectural knowledge for the Zigbee subsystem (EZSP, coordinator, node storage, ZCL/ZDO). Use when modifying or debugging Zigbee code.
---

# Zigbee Implementation Skill

You are working on the Zigbee subsystem of OpenWatt. This skill provides deep architectural knowledge to avoid lengthy re-exploration of the codebase.

## File Map

| File | Role |
|------|------|
| `src/router/iface/zigbee.d` | **ZigbeeInterface** — packet interface, message queues, EZSP callbacks |
| `src/protocol/zigbee/package.d` | **ZigbeeProtocolModule** + **NodeMap** struct — node storage and lookup |
| `src/protocol/zigbee/coordinator.d` | **ZigbeeCoordinator** — network formation, security, join handling |
| `src/protocol/zigbee/router.d` | **ZigbeeRouter** — base class for coordinator, ZDO frame handling, NetworkParams |
| `src/protocol/zigbee/controller.d` | **ZigbeeController** — async node interview loop |
| `src/protocol/zigbee/client.d` | **ZigbeeNode**, **ZigbeeEndpoint** — runtime node/endpoint objects |
| `src/protocol/ezsp/client.d` | **EZSPClient** — EZSP command serialization, owns ASHInterface |
| `src/protocol/ezsp/commands.d` | EZSP command definitions (EmberZNet protocol) |
| `src/protocol/ezsp/ashv2.d` | **ASHInterface** (BaseInterface) — ASHv2 framing over serial, sliding window |
| `src/router/iface/priority_queue.d` | **PriorityPacketQueue** — standalone priority scheduling utility |
| `src/router/iface/packet.d` | **Packet** struct + PCP/DEI/VID helpers |
| `conf/zigbee_profiles/` | Zigbee device profiles (ZCL cluster/attribute mappings) |

## Component Relationships

```
ZigbeeInterface (router/iface/zigbee.d)
    ├── owns _ezsp_client: EZSPClient (serial transport)
    ├── owns _coordinator: ZigbeeCoordinator (network mgmt)
    ├── _send_queues[8] (PCP-ranked buckets), _in_flight[] (message queues)
    ├── _network_status: EmberStatus (NETWORK_UP/DOWN)
    ├── counter polling: 10s interval (was 10ms)
    └── status_handler() ← EZSP_StackStatusHandler callback

EZSPClient (protocol/ezsp/client.d)
    ├── owns _ash: ASHInterface (created on stream set)
    ├── EZSP command queue (_queued_requests)
    └── version negotiation on startup

ASHInterface (protocol/ezsp/ashv2.d) extends BaseInterface
    ├── _stream: Stream (serial port)
    ├── ASH framing, CRC, byte-stuffing
    ├── sliding window: _maxInFlight=3 (was 1)
    └── auto-registers in InterfaceModule.interfaces

ZigbeeCoordinator (protocol/zigbee/coordinator.d) extends ZigbeeRouter
    ├── _network_params: NetworkParams (extended_pan_id, pan_id, channel, tx_power)
    ├── _init_promise: async fibre for init()/init_network()
    ├── _network_key, _channel, _pan_eui, _pan_id (configured values)
    └── join_handler() ← EZSP_TrustCenterJoinHandler callback

ZigbeeProtocolModule (protocol/zigbee/package.d)
    ├── nodes_by_eui: Map!(EUI64, NodeMap) — primary node storage
    ├── nodes_by_pan: Map!(uint, NodeMap*) — secondary index (pan_id<<16|node_id)
    ├── unknown_nodes: Array!UnknownNode
    └── Collections: nodes, routers, coordinators, endpoints, controllers

ZigbeeController (protocol/zigbee/controller.d)
    └── update() iterates nodes_by_eui, launches async interview fibres
```

## Priority / QoS System

### Layer Stack
```
ZigbeeInterface (BaseInterface) — APS message queue, PCP-based priority
  → EZSPClient (BaseObject) — EZSP command serialization, owns ASHInterface
    → ASHInterface (BaseInterface) — ASH framing, sliding window (maxInFlight=3)
      → Stream (serial port)
```

### PCP Usage in Zigbee
All send methods accept `PCP pcp = PCP.be` parameter. PCP is set on `Packet.vlan` via `p.pcp = pcp` in client.d's `send_message`, then flows through `forward_async` → `transmit_async` → `PriorityPacketQueue`.

| PCP | Class | Rank | Use |
|-----|-------|------|-----|
| VO (5) | Voice | 5 | User commands (on/off, Tuya set_value), join handler |
| CA (3) | Critical Apps | 3 | Protocol responses, IAS CIE write |
| BE (0) | Best Effort | 1 | Default messages |
| BK (1) | Background | 0 | Interview traffic (discovery, attribute reads) |

- `PriorityPacketQueue` uses 8 rank-indexed buckets; `pcp_priority_map[]` converts PCP → rank
- Dequeue order: highest rank first (7→0)
- Reserved slots: high-priority PCP (≥ `reserved_min_pcp`) can use all in-flight slots

### ASH Sliding Window
- `_maxInFlight=3` (was 1, causing stop-and-wait bottleneck)
- Supports up to 7 in-flight frames (ASH protocol limit)
- ACK-based: frames freed when ACK received, retransmit on NAK/timeout

### Counter Polling
- Interval: 10 seconds (was 10ms — major latency bottleneck)
- Uses `EZSP_ReadAndClearCounters` for MAC-level statistics
- Fires in ZigbeeInterface.update(), occupies EZSP command slot

### Key Files for QoS
- `src/router/iface/packet.d` — `vlan_pcp()`, `vlan_set_pcp()`, `pcp_to_rank[]` helpers
- `src/router/iface/priority_queue.d` — `PriorityPacketQueue` (standalone utility, not yet used by Zigbee)
- `.claude/skills/packet-interface/SKILL.md` — full architecture doc for PCP/DEI/priority system

## EZSP Client — Two Command Modes

The EZSPClient (`protocol/ezsp/client.d`) owns an `ASHInterface _ash` (created on first stream set). Two ways to send commands:

1. **`request!CMD()`** — Fibre-based synchronous. Yields fibre until response arrives. **Must be called from fibre context** (asserts on `isInFibre()`). Used by coordinator's `init()` which runs as `async(&init)`.

2. **`send_command!CMD(callback, args...)`** — Async callback-based. Works from any context (nothrow). Pass `null` callback for fire-and-forget. Returns `bool` (false if `!running`). Used by the interface for message sending and shutdown.

**ASH lifecycle:** EZSPClient has mutually exclusive `ash_stream` (Stream) and `ash_interface` (ASHInterface) properties. In `startup()`, if `ash_stream` is set, it creates a dynamic ASHInterface via `Collection.create()` (owned, destroyed in shutdown). If `ash_interface` is set, it uses that external ASH (not owned). ASH is managed by `EZSPProtocolModule.ash_connections` collection — EZSPClient subscribes to ASH state signals for offline detection, does NOT poll or drive ASH updates.

## Node Storage System

### NodeMap (package.d:77-258)

The core data structure for Zigbee device knowledge:

**Identity fields:**
- `EUI64 eui` — permanent IEEE address (never changes)
- `ushort pan_id` — 0xFFFF = not joined (sentinel)
- `ushort id` — 0xFFFE = not online (sentinel)
- `bool discovered` — indicates whether a node was added explicitly or via discovery **IMPORTANT: never set to true** (see Known Issues below)
- `BaseInterface via` — set inconsistently (see below)
- `bool available() => pan_id != 0xFFFF && id != 0xFFFE`

**Interview data (expensive to rebuild — requires OTA ZDO/ZCL exchanges):**
- `ubyte initialised` — bit flags: 0x01=node_desc, 0x02=power_desc, 0x04=endpoints, 0x08=clusters, 0x10=attributes, 0x40=basic_attempt, 0x80=basic_done, 0xFF=complete
- `NodeDescriptor desc` — type, manufacturer_code, capabilities
- `PowerDescriptor power` — power mode, battery level
- `BasicInfo basic_info` — mfg_name, model_name, sw_build_id
- `Map!(ubyte, Endpoint) endpoints` — each with clusters (Map of Cluster) and attributes (Map of Attribute)
- `Map!(ubyte, Variant) tuya_datapoints`

**Volatile state:**
- `scan_in_progress`, `device_created`, `lqi`, `rssi`, `last_seen`

### Dual-Index Storage

```d
Map!(EUI64, NodeMap) nodes_by_eui;      // primary — owns the NodeMap data
Map!(uint, NodeMap*) nodes_by_pan;      // secondary — key is (pan_id << 16 | node_id), value points into nodes_by_eui
```

### Key Methods (package.d:308-393)

- **`attach_node(EUI64, pan_id, id)`** — Create or update. Looks up by EUI first; creates if missing (discovered=false). Handles address reassignment (detaches old PAN entry if ID changed). Updates both maps.
- **`detach_node(pan_id, id)`** — Clears PAN association (sets pan_id=0xFFFF, id=0xFFFE), removes from nodes_by_pan. Node stays in nodes_by_eui with interview data preserved.
- **`remove_node(EUI64)`** — Full removal: detach then delete from nodes_by_eui.
- **`find_node(EUI64)`** — Lookup in nodes_by_eui.
- **`find_node(pan_id, id)`** — Lookup in nodes_by_pan via composite key.
- **`add_node(EUI64, via)`** — DEAD CODE: never called anywhere.
- **`remove_all_nodes(iface)`** — See Known Issues.

### Where `via` Is Set

| Location | Set? | Context |
|----------|------|---------|
| coordinator.d:503 (own node) | **No** (commented out) | Coordinator's own entry |
| coordinator.d:544 (child table) | **Yes** `= _interface` | EZSP pre-population |
| coordinator.d:560 (address table) | **No** | EZSP pre-population |
| coordinator.d:605 (join handler) | **No** (commented out) | Device joining |
| zigbee.d:777 (incoming msg, known EUI) | **Yes** `= this` | Message reception |
| zigbee.d:810 (incoming msg, EUI lookup) | **Yes** `= this` | Message reception |
| controller.d:225 (probe response) | **Yes** `= unk.via` | Unknown node discovery |

## Coordinator Startup Flow

### init() (coordinator.d:307-346) — runs as async fibre

Checks `EZSP_NetworkState()`:
- **JOINED_NETWORK** → returns `true` immediately. **Does NOT call init_network().** Network params NOT fetched. Node pre-population NOT run.
- **NO_NETWORK** → calls `init_network(ezsp)` for full setup.
- **JOINING/LEAVING** → sleeps and retries.

### init_network() (coordinator.d:348-565) — full setup

1. Configure EZSP stack (policies, security, MAC passthrough)
2. Get coordinator EUI via `EZSP_GetEui64`
3. `EZSP_NetworkInit()` — try to rejoin existing network
4. If `NOT_JOINED`: generate random extended PAN ID + network key, `EZSP_FormNetwork()`
5. Wait for `NETWORK_UP` via status_handler
6. **`EZSP_GetNetworkParameters()`** → populates `_network_params` (line 480-484)
7. Get node ID (should be 0x0000 for coordinator)
8. Create coordinator's own node entry (errors if already exists — line 493-498)
9. `EZSP_PermitJoining(0xFF)`
10. Pre-populate nodes from EZSP child table and address table (lines 528-563)

### Coordinator shutdown (coordinator.d:215-244)

1. Abort init_promise
2. Unsubscribe from interface
3. `_network_params = NetworkParams()` — **clears extended_pan_id**
4. `_ready = false`

### do_destroy_network() (coordinator.d:567-582)

Full nuclear option (used by explicit destroy command, NOT normal shutdown):
`EZSP_LeaveNetwork` → `EZSP_ClearKeyTable` → `EZSP_ClearTransientLinkKeys` → `EZSP_TokenFactoryReset` → `EZSP_ResetNode`

## Interface Lifecycle

### Startup (zigbee.d:183-217)
1. Wait for `_ezsp_client.running`
2. If coordinator: wait for `_coordinator.ready`
3. Return `complete`

### Shutdown (zigbee.d:219-277)
1. If network UP + EZSP running: send `EZSP_LeaveNetwork(null)` via send_command, return `continue_`
2. Wait for `status_handler` to confirm `NETWORK_DOWN`
3. If EZSP not running: force `_network_status = NETWORK_DOWN`
4. `remove_all_nodes(this)` — currently a no-op (see Known Issues)
5. Unsubscribe coordinator, set `_coordinator = null`
6. Abort all queued/in-flight messages
7. Clear sequence_number, last_ping
8. Return `complete`

### Update (zigbee.d:268+)
- If EZSP client not running → `restart()`
- Send queued messages (PCP priority order: highest rank first)
- Counter poll every 10s (EZSP_ReadAndClearCounters)

### Incoming Message Flow (zigbee.d:689-814)
1. Look up sender in `nodes_by_pan`
2. If not found: check `_sender_eui` (set by `EZSP_IncomingSenderEui64Handler`)
3. If EUI available: `attach_node(eui, pan_id, sender)`, set `via = this`
4. If no EUI: `send_command!EZSP_LookupEui64ByNodeId` → callback does `attach_node`
5. Update `last_seen`, `lqi`, `rssi`

## Controller Interview (controller.d)

### Update Loop (lines 170-185)
```d
foreach (ref NodeMap nm; zb.nodes_by_eui.values)
{
    if (nm.initialised < 0xFF && !nm.scan_in_progress && _promises.length < MaxFibers)
    {
        nm.scan_in_progress = true;
        _promises.pushBack(async(&do_node_interview, &nm));
    }
    if (_auto_create_devices && !nm.device_created && (nm.initialised & 0x80))
    {
        nm.device_created = true;
        if (nm.desc.type != NodeType.coordinator)
            create_device(nm);
    }
}
```

**No availability guard** — will try to interview detached nodes with invalid addresses.

### Interview Stages (do_node_interview, lines ~885-1199)
Each stage checks/sets a bit in `initialised`:
- 0x01: Node descriptor (ZDO node_desc_req)
- 0x02: Power descriptor (ZDO power_desc_req)
- 0x04: Active endpoints (ZDO active_ep_req)
- 0x08: Simple descriptors per endpoint (ZDO simple_desc_req)
- 0x10: Attribute discovery per cluster
- 0x40: Basic cluster read in progress
- 0x80: Basic cluster read done (mfg_name, model_name, etc.) — triggers device auto-creation
- 0xFF: Fully initialized

## Restart Scenarios

### EZSP Glitch (client goes offline momentarily)
1. `_ezsp_client.running` → false → interface `restart()`
2. `shutdown()`: EZSP not running → can't send LeaveNetwork → force NETWORK_DOWN
3. NCP still has network in flash
4. `startup()`: wait for EZSP client + coordinator
5. Coordinator `init()`: NCP says JOINED_NETWORK → returns true (no init_network)
6. Nodes still in nodes_by_eui (remove_all_nodes was no-op)

### Deliberate LeaveNetwork
1. `shutdown()`: sends EZSP_LeaveNetwork, waits for NETWORK_DOWN
2. NCP leaves and clears network from flash
3. `startup()`: coordinator init() → NO_NETWORK → init_network() forms new network
4. New random PAN ID, new extended PAN ID
5. Pre-populates from (empty) EZSP tables

## NetworkParams (defined in router.d:66-76)
```d
struct NetworkParams {
    EUI64 extended_pan_id;
    ushort pan_id = 0xFFFF;
    ubyte radio_tx_power;
    ubyte radio_channel;
}
```

Property accessor: `ushort pan_id() => _network_params.pan_id == 0xFFFF ? _pan_id : _network_params.pan_id;`

## EZSP Commands Quick Reference

| Command | Code | Notes |
|---------|------|-------|
| EZSP_NetworkState | 0x0018 | Returns EmberNetworkStatus |
| EZSP_NetworkInit | 0x0017 | Initialize/rejoin from NCP flash |
| EZSP_FormNetwork | 0x001E | Form new network (coordinator) |
| EZSP_LeaveNetwork | 0x0020 | Leave network (triggers StackStatusHandler NETWORK_DOWN) |
| EZSP_PermitJoining | 0x0022 | Allow device joins (0xFF = indefinite) |
| EZSP_GetNetworkParameters | 0x0028 | Returns panId, extendedPanId, channel, txPower |
| EZSP_GetEui64 | 0x0026 | Device's IEEE address |
| EZSP_GetNodeId | 0x0027 | Short network address |
| EZSP_GetChildData | | Enumerate child devices |
| EZSP_GetAddressTableRemoteNodeId/Eui64 | | Enumerate address table |
| EZSP_ClearKeyTable | 0x00B1 | Clear network keys |
| EZSP_ResetNode | 0x0104 | Hard reset NCP |

**EmberStatus (network):** NETWORK_UP (0x90), NETWORK_DOWN (0x91), NETWORK_OPENED, NETWORK_CLOSED
**EmberNetworkStatus:** NO_NETWORK, JOINING_NETWORK, JOINED_NETWORK, JOINED_NETWORK_NO_PARENT, LEAVING_NETWORK

## Known Issues

1. **`discovered` flag is dead:** `add_node()` (the only way to set `discovered=true`) is never called. All nodes created via `attach_node()` have `discovered=false`. This means `remove_all_nodes()` which filters on `discovered && via is iface` is effectively a **no-op**.

2. **`remove_all_nodes` doesn't clean `nodes_by_pan`:** Even if it removed nodes, it doesn't call `detach_node()` first — would leave dangling pointers in the secondary index.

3. **`via` inconsistently set:** Coordinator's own node, join handler nodes, and address table pre-populated nodes don't set `via`. Only child table nodes, incoming message nodes, and controller-discovered nodes do.

4. **`JOINED_NETWORK` path skips init_network:** When NCP already has the network, `init()` returns immediately without fetching network params or pre-populating nodes. `_network_params` stays empty after being cleared in shutdown.

5. **Controller has no availability guard:** Will attempt to interview detached nodes (pan_id=0xFFFF, id=0xFFFE) with invalid addresses.

6. **Coordinator's own node on restart:** `init_network()` line 493-498 errors if the coordinator's node already exists in `nodes_by_pan`. This can happen if nodes persist across restarts.

7. **No persistent storage:** Node interview data only lives in memory. No disk save/load.
