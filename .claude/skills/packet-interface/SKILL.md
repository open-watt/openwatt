---
name: packet-interface
description: Packet routing architecture — BaseInterface, Packet model, VLAN PCP/DEI priority, PriorityPacketQueue, interface layering. Use when working on interfaces, bridges, or packet scheduling.
---

# Packet Interface Architecture

Architecture for OpenWatt's packet routing layer. Documents interface abstraction, async message lifecycle, priority scheduling, and layering.

## File Map

| File | Role |
|------|------|
| `src/router/iface/package.d` | **BaseInterface** — abstract packet interface, subscribers, dispatch/forward/transmit, MessageState/MessageCallback |
| `src/router/iface/packet.d` | **Packet** struct — 24-byte embedded header + data pointer, PacketType enum |
| `src/router/iface/priority_queue.d` | **PriorityPacketQueue** — standalone priority scheduling utility |
| `src/router/iface/bridge.d` | **BridgeInterface** — L2 bridge, VLAN filtering, PCP preservation |
| `src/router/iface/vlan.d` | **VLANInterface** — 802.1Q VLAN sub-interfaces |
| `src/router/iface/mac.d` | MACAddress type |
| `src/router/status.d` | Interface status/counters |

## Packet Model

```d
struct Packet
{
    SysTime creation_time;
    union {
        Ethernet eth;   // 14 bytes (dst + src + ether_type + ow_sub_type)
        void[24] embed; // protocol headers live here (APSFrame, ModbusHeader, etc.)
    }
    PacketType type;    // discriminator for the embed union
    ushort vlan;        // 802.1Q TCI: [PCP:3][DEI:1][VID:12]
    // package: _flags, _offset, _length, _ptr
}
```

Key properties:
- `embed[24]` — protocol-specific headers overlay this union. Each header type declares `enum Type = PacketType.xxx;`
- `type` — discriminator; use `packet.hdr!APSFrame()` to access typed header (asserts correct type)
- `vlan` — full 802.1Q Tag Control Information, used for both L2 routing AND priority scheduling
- `data()` — returns payload slice via `_ptr[_offset.._length]`
- `init!T(payload)` — initialize packet with typed header and payload data
- `clone(allocator)` — deep copy (header + payload)

### Supported PacketTypes

```d
enum PacketType : ushort
{
    unknown, ethernet, wpan, _6lowpan, zigbee_nwk, zigbee_aps,
    modbus, can, tesla_twc, ash   // ash = ASHv2 serial framing
}
```

## 802.1Q VLAN TCI — PCP/DEI/VID

```
Bits:  [15:13] PCP    [12] DEI    [11:0] VID
       3-bit priority  drop-elig   12-bit VLAN ID
```

### PCP Priority Ordering (802.1p)

Standard ordering from lowest to highest priority:

| PCP | Acronym | Traffic Class | OpenWatt Use |
|-----|---------|--------------|--------------|
| 1   | BK      | Background | Housekeeping (counter polls, diagnostics) |
| 0   | BE      | Best Effort | Default — normal messages |
| 2   | EE      | Excellent Effort | Interview/discovery traffic |
| 3   | CA      | Critical Apps | Protocol responses, time-sensitive |
| 4   | VI      | Video | (reserved) |
| 5   | VO      | Voice | User commands (light on/off) — low latency |
| 6   | IC      | Internetwork Control | (reserved) |
| 7   | NC      | Network Control | Network management (reserved) |

**Key insight:** PCP=0 (Best Effort) is NOT the lowest priority. PCP=1 (Background) is lower. This is the standard ordering.

### DEI (Drop Eligible Indicator)

When `DEI=1`, the frame is eligible for discard under congestion. Used for non-critical housekeeping (counter polls, keep-alive pings) that can be safely dropped without affecting functionality.

### PCP/DEI/VID Accessors (Packet members in `src/router/iface/packet.d`)

```d
// enum PCP : ubyte { be=0, bk=1, ee=2, ca=3, vi=4, vo=5, ic=6, nc=7 }
PCP pcp() const;       void pcp(PCP value);
bool dei() const;      void dei(bool value);
ushort vid() const;
```

### Bridge PCP Interaction

Bridges already preserve PCP bits during VLAN tag operations:
```d
// bridge.d — on egress, strip VID but keep PCP+DEI
packet.vlan &= 0xF000;
// on ingress, adopt PVID while keeping PCP+DEI
src_vlan = (src_vlan & 0xF000) | port.pvid;
```

Every interface has a `_pvid` (Port VLAN ID) for internal L2 routing. PCP rides alongside the VID through bridges, even for non-Ethernet interfaces. This makes priority a universal concept across all interface types.

## BaseInterface Architecture

### Core API

```d
class BaseInterface : BaseObject
{
    // Packet flow (public API) — returns int tags
    int forward(ref Packet packet, MessageCallback callback = null);  // outgoing: subscribers -> transmit()
    void dispatch(ref Packet packet);   // incoming: update stats -> notify subscribers

    // Subclass override
    abstract int transmit(ref const Packet packet, MessageCallback callback = null);

    // Async message lifecycle (virtual — override for async interfaces)
    void abort(int msg_handle, MessageState reason = MessageState.aborted) {}
    MessageState msg_state(int msg_handle) const { return MessageState.complete; }

    // Subscriber system
    void subscribe(PacketHandler, ref PacketFilter, void* user_data);
    void unsubscribe(PacketHandler);

    // State
    protected Status _status;   // counters: send/recv bytes/packets/dropped
    protected ushort _pvid;     // port VLAN ID for internal routing
}
```

### Return Value Semantics

`forward()` and `transmit()` return `int`:
- **`< 0`** — Error (not running, queue full, send failure). Message was NOT sent.
- **`0`** — Synchronous success. Message fully sent, nothing to cancel.
- **`> 0`** — Async tag. Message is queued or in-flight. Use `abort(tag)` to cancel, `msg_state(tag)` to query status.

### MessageState and MessageCallback

Defined at module scope in `src/router/iface/package.d`:

```d
enum MessageState
{
    queued,      // in queue, not yet sent
    in_flight,   // sent to transport, awaiting confirmation
    complete,    // successfully delivered
    failed,      // transport error
    aborted,     // cancelled by caller
    timeout,     // transport safety-net timeout (in-flight too long)
    expired,     // queue patience timeout (stale before dispatch)
    dropped,     // discarded due to congestion (DEI-based)
}

alias MessageCallback = void delegate(int msg_handle, MessageState state) nothrow @nogc;
```

### forward() Callback Contract

`forward()` handles callback invocation for sync results:
- If `transmit()` returns `<= 0`, `forward()` fires the callback immediately with `complete` (for 0) or `failed` (for < 0).
- If `transmit()` returns `> 0` (async tag), `forward()` does **NOT** fire the callback — the interface is responsible for calling it later via `on_frame_complete()` or similar.

### Packet Flow

**Outgoing:** `forward(packet, callback)` -> notify outgoing subscribers -> `transmit(packet, callback)` (abstract)

**Incoming:** `dispatch(packet)` -> update recv counters -> learn MAC -> notify incoming subscribers (or route to master if slave interface)

### Subscribers

Up to 4 subscribers per interface. Each subscriber has a `PacketFilter` (type, direction, MAC, ethertype, VLAN) and a callback. Subscribers see packets in both directions (incoming via dispatch, outgoing via forward).

### Lifecycle

BaseInterface extends BaseObject -> full state machine: Validate -> Starting -> Running -> Stopping. Interfaces are managed via Collections and configured through console commands. `update()` called each frame while Running.

## PriorityPacketQueue — Standalone Utility

A reusable queue utility for interfaces that need priority-aware scheduling with async tag tracking. Used via composition — interfaces create an instance and delegate scheduling to it.

### API

```d
struct PriorityPacketQueue
{
    void configure(ubyte max_in_flight,
                   ubyte reserved_slots = 0, PCP reserved_min_pcp = PCP.vo,
                   Status* status = null);
    void set_queue_timeout(Duration timeout);      // queue patience (stale data expiry)
    void set_transport_timeout(Duration timeout);   // transport safety net

    // Producer: enqueue packet (reads PCP/DEI from packet.vlan)
    // Returns tag (>= 0) on success, -1 on drop.
    int enqueue(ref Packet packet, MessageCallback callback = null);

    // Consumer: dequeue highest-priority pending frame (null if empty or at capacity)
    // Respects reserved slots: low-priority capped at (max_in_flight - reserved_slots)
    QueuedFrame* dequeue();

    // Lifecycle: mark in-flight frame as complete
    void complete(ubyte tag, MessageState state = MessageState.complete);

    // Maintenance: expire stale queued frames + safety-net evict in-flight frames
    void expire_stale(MonoTime now);

    // Bulk operations
    void cancel_all();             // cancel all queued + in-flight (fires aborted callbacks)
    void fail_all_in_flight();     // fail in-flight only (leaves queued untouched)
    bool cancel(ubyte tag);        // cancel a specific frame by tag

    // Status
    bool has_pending() const;
    bool has_capacity(PCP pcp = PCP.nc) const;
    size_t in_flight_count() const;
    size_t queue_depth(PCP pcp) const;
    bool has_queued(ubyte tag) const;   // check queued buckets (not in-flight)
}
```

### Tags

Tags are `ubyte` (1–255), assigned sequentially by the queue. Tag 0 is skipped on wraparound so it can serve as a "no tag" sentinel. Tags are unique within the queue's lifetime (wrap after 255).

### Priority Ordering

Dequeue order follows 802.1p: PCP 7 first, then 6, 5, 4, 3, 2, 0, 1 last. Within same PCP level, FIFO.

### Reserved Slots

High-priority traffic (PCP >= `reserved_min_pcp`) can use all `max_in_flight` slots. Lower-priority traffic is capped at `max_in_flight - reserved_slots`. This prevents low-priority floods from starving time-sensitive messages.

### DEI-Aware Overflow

When queue is full (32 frames) and a new frame arrives:
1. If new frame has DEI=0 and queue has DEI=1 frames -> drop lowest-priority DEI=1 frame
2. If new frame has DEI=1 and queue is full -> drop the new frame

### In-Flight Tracking

Frames transition from "queued" to "in-flight" when dequeued. In-flight frames are tracked with a tag and timestamps (enqueue_time, dispatch_time). `complete(tag, state)` fires the frame's callback and frees the slot. `expire_stale(now)` handles two distinct concerns:
1. **Queue patience** — drops queued (not yet dispatched) frames older than `_queue_timeout` from `enqueue_time`, firing `MessageState.expired`. This is a user-facing knob: "don't bother sending stale data."
2. **Transport safety net** — evicts in-flight frames older than `_transport_timeout` from `dispatch_time`, firing `MessageState.timeout`. This is an internal invariant: "the transport is broken if it hasn't reported back." Should be generous; zero = disabled.

### EWMA Timing Stats

When a `Status*` is provided, the queue tracks exponentially-weighted moving averages:
- `avg_wait_us` — time from enqueue to dispatch (queue latency)
- `avg_service_us` — time from dispatch to completion (transport latency)
- `max_service_us` — peak transport latency

### Where It's Used

| Interface | max_in_flight | timeout | Notes |
|-----------|---------------|---------|-------|
| ASHInterface | 3 | 2s | ASH sliding window (serial to Zigbee NCP) |
| ZigbeeInterface | 3 | 4s | APS message queue (over EZSP) |
| ModbusInterface | 1 (RTU) / 8 (TCP) | combined queue+request timeout | RTU: gap-time gated dequeue |

## Async Interface Pattern: Queue + Pending Map

Both ZigbeeInterface and ModbusInterface follow the same composition pattern for async message handling. This is the standard way to add async support to a BaseInterface.

### Structure

```d
class AsyncInterface : BaseInterface
{
    PriorityPacketQueue _queue;           // owns packets, handles priority/scheduling
    Map!(ubyte, PendingMetadata) _pending; // tag -> caller metadata (callback, correlation IDs)
}
```

The queue owns the packet lifecycle (clone, priority, timeout). The pending map stores caller-provided metadata needed to route completions back.

### Transmit Flow

```d
override int transmit(ref const Packet packet, MessageCallback callback)
{
    // 1. Validate, extract protocol-specific info
    // 2. Enqueue (queue clones the packet)
    Packet p = packet;  // mutable copy (enqueue takes ref Packet)
    int tag = _queue.enqueue(p, &on_frame_complete);
    if (tag < 0) return -1;

    // 3. Store caller metadata keyed by tag
    _pending[cast(ubyte)tag] = PendingMetadata(..., callback);

    // 4. Try to send immediately
    send_queued_messages();
    return tag;
}
```

### send_queued_messages()

Dequeue loop with transport-specific gating (e.g., gap-time for RTU, EZSP readiness for Zigbee):

```d
void send_queued_messages()
{
    // transport-specific gate (e.g., gap time, EZSP online check)
    if (!ready_to_send()) return;

    for (auto frame = _queue.dequeue(); frame !is null; frame = _queue.dequeue())
    {
        auto pm = frame.tag in _pending;
        if (!pm) { _queue.complete(frame.tag, MessageState.failed); continue; }

        // frame and send on wire...
        if (send_failed) { _queue.complete(frame.tag, MessageState.failed); continue; }

        // notify caller: now in-flight
        if (pm.callback) pm.callback(frame.tag, MessageState.in_flight);
    }
}
```

### Completion Flow

```d
// Callback registered with the queue — bridges to caller's callback
void on_frame_complete(int tag, MessageState state)
{
    ubyte t = cast(ubyte)tag;
    if (auto pm = t in _pending)
    {
        if (pm.callback) pm.callback(tag, state);
        _pending.remove(t);
    }
}
```

### Response Matching

When a response arrives (`incoming_packet` or similar):
1. Find the matching `_pending` entry (by address, sequence number, etc.)
2. Dispatch the response packet to upper layers
3. `_queue.complete(tag, MessageState.complete)` — fires `on_frame_complete` → caller callback
4. `send_queued_messages()` — try to fill the freed slot

### abort() and msg_state() Overrides

```d
override void abort(int msg_handle, MessageState reason = MessageState.aborted)
{
    ubyte t = cast(ubyte)msg_handle;
    if (auto pm = t in _pending) {
        if (pm.callback) pm.callback(msg_handle, reason);
        _pending.remove(t);
    }
    _queue.cancel(t);
}

override MessageState msg_state(int msg_handle) const
{
    if (cast(ubyte)msg_handle in _pending)
        return MessageState.in_flight;
    if (_queue.has_queued(cast(ubyte)msg_handle))
        return MessageState.queued;
    return MessageState.complete;
}
```

### Shutdown

```d
// Fire aborted callbacks for pending entries, then clear queue
foreach (kvp; _pending[])
    if (kvp.value.callback) kvp.value.callback(kvp.key, MessageState.aborted);
_pending.clear();
_queue.cancel_all();
```

### Update

```d
_queue.expire_stale(getTime());
send_queued_messages();
```

## Interface Layering

Interfaces are packet-level abstractions. They transmit and receive packets, handle framing and low-level transport constraints, but do NOT perform request/response correlation. Protocol clients sit **above** interfaces as consumers.

Interfaces can be **layered** — a client of one interface may itself be an interface (or own one), forming a protocol stack. Each layer adds framing, reliability, or abstraction.

### Zigbee Stack (layered interfaces)

```
ZigbeeClient (protocol/zigbee/client.d)
    ZigbeeController, ZigbeeCoordinator
    — node interview, ZDO/ZCL exchanges, network formation
    |  forward(packet, callback, pcp)
    v
ZigbeeInterface (BaseInterface) — async, uses PriorityPacketQueue
    — APS message queuing, PCP-based priority scheduling
    — delivery callbacks via MessageCallback
    — abort()/msg_state() for tag lifecycle
    |  internally uses EZSPClient to serialise APS → EZSP
    v
EZSPClient (BaseObject, owns ASHInterface)
    — EZSP command serialization, seq number correlation
    — version negotiation, command queue
    |  _ash.send(ezsp_frame)
    v
ASHInterface (BaseInterface)
    — ASH framing, CRC, byte-stuffing
    — sliding window (maxInFlight=3), retransmit/NAK
    |  stream read/write
    v
Serial Stream
```

### Modbus Stack (flat — single interface, uses queue)

```
ModbusClient (protocol/modbus/client.d)
    — request/response correlation by transaction ID
    — sampler integration, register decoding
    |  forward(packet)
    v
ModbusInterface (BaseInterface) — async, uses PriorityPacketQueue
    — RTU/TCP/ASCII framing, CRC
    — master: queue + pending map, gap-time gated dequeue
    — slave: synchronous response (no queue)
    — abort()/msg_state() for tag lifecycle
    |  stream read/write
    v
Serial or TCP Stream
```

### Ethernet (flat — synchronous)

```
BridgeInterface, VLAN consumers, protocol handlers
    |  forward(packet), subscribe()
    v
EthernetInterface (BaseInterface) — sync, returns 0
    — raw Ethernet frames
    |
    v
NIC / tap device
```

### Design Principles

**Interfaces handle delivery, clients handle meaning.** An interface knows about framing, queuing, priority, and transport constraints (e.g. a Modbus slave can't initiate, a master has one request in flight). But correlating which response answers which request is the client's job.

**Protocol binding is an implementation detail.** ZigbeeInterface happens to use EZSP today, but could alternatively drive a raw 802.15.4 radio. ModbusInterface handles RTU/TCP/ASCII framing without knowing what the registers mean.

**Layering is composition, not inheritance.** ZigbeeInterface doesn't extend ASHInterface — it owns an EZSPClient which owns an ASHInterface. Each layer has its own lifecycle, queue, and error handling.

### Interface Communication Patterns

**Subscribe pattern:** Protocol clients subscribe to interfaces for incoming packets via `PacketFilter`. Example: EZSPClient subscribes to ASHInterface for incoming EZSP response frames.

**Forward pattern:** Protocol clients call `interface.forward(packet, callback)` to send outgoing packets. The interface queues, frames, and transmits. Returns a tag for async tracking.

**Callback pattern:** Async interfaces support `MessageCallback` for delivery status. Called when the frame transitions state (queued → in_flight → complete/failed/timeout). This is delivery status, not application-level response correlation.

**Cancel pattern:** Callers can `abort(tag)` to cancel a queued or in-flight message. `msg_state(tag)` queries current status. Default implementations (sync interfaces) treat all messages as immediately complete.

## Bridge Queue-Aware Message Tracking

BridgeInterface transparently tracks message lifecycle through port interfaces so that upstream callers (e.g., ModbusClient) get meaningful tags, callbacks, and abort support even when routed through a bridge.

### Design

**Fast path (no callback):** `transmit()` has one `if (callback)` check. Without a callback, the existing `send()` path runs with zero overhead — this is the common case for Ethernet traffic.

**Slow path (with callback):** `send_tracked()` handles both unicast (known destination) and broadcast (unknown/multicast) with full lifecycle tracking.

### TagTracking

```d
struct TagTracking
{
    TagTracking* next;          // intrusive free-list OR active-list link
    MessageCallback upstream_cb;
    Array!PortTag port_tags;    // (iface, tag) pairs for ports that returned async tags
    ubyte bridge_tag;           // synthesized tag returned to caller
    ubyte n_pending;            // ports that haven't reported back
    bool any_succeeded;
}
```

**Free-list:** Intrusive linked list via `next` pointer. Batch-allocated in groups of 4 from `defaultAllocator()`. Never destroyed during operation — `Array!PortTag` capacity survives across recycles via `.clear()`. Destructor finds batches by scanning for contiguous pointers.

**Active list:** Same `next` pointer (entry is in one list or the other, never both). Used by `abort()` and `msg_state()` to find entries by bridge_tag.

### Callback suppression

`on_port_callback` checks `port_tag <= 0` to filter synchronous fires. When `BaseInterface.forward()` returns <= 0, it fires the callback with `msg_handle = 0` (or < 0). These are handled directly by `send_tracked()` via return values, not via the callback.

During `abort()`, `upstream_cb` is saved and nulled before iterating port aborts, preventing double-fire from synchronous port abort callbacks.

### Broadcast aggregation

For unknown-destination or multicast sends, `send_tracked()` iterates all ports. Each port's `forward()` result:
- `> 0` (async): store PortTag, increment `n_pending`
- `== 0` (sync success): set `any_succeeded = true`
- `< 0` (failure): count as failure

When `n_pending` reaches 0 in `on_port_callback`, upstream fires with `complete` if `any_succeeded`, else `failed`.

### Bridge tags

Uses shared `TagAllocator` (same as PriorityPacketQueue). Tags 1-255, ubyte. Allocated when async tracking is needed, freed on recycle.

### Shutdown

`shutdown()` drains the active list — aborts all port tags, fires upstream callbacks with `MessageState.aborted`, recycles entries.

### Known limitations

- `BridgePort.iface` is a raw pointer (ObjectRef deferred until Array move semantics are implemented)
- `remove_member()` is unimplemented (MAC table reindex, subscriber fixup, tracking cleanup all TODO)

## Collection Integration

All interfaces are registered in a global `Collection!BaseInterface` via `InterfaceModule`. Console commands are auto-generated:
- `/interface/print` — list all interfaces with status
- `/interface/zigbee/add name=...` — create interface
- `/interface/zigbee/set ... property=value` — configure

Interfaces also appear in a unified `/interface` collection for cross-type operations.
