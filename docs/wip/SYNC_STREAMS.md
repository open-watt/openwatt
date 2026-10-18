# Lossless, untorn sync streams

Status: phase A landed (#852), B1a in progress. Delete this file when phase C lands; reconcile what remains
into [TODO.md](../../TODO.md).

## Problem

Sync produces value messages progressively, and a burst no longer fits one frame. Sources change
between frames, so a peer receives values from different moments: an energy meter's voltage,
current and power arrive torn. The receiver also applies each frame as it lands and notifies
subscribers per value, so even a burst that was coherent at the sender is torn by the time a
subscriber runs. Held values are coalesced to the latest, so a subscriber cannot render a
waveform either.

## Model

### A subscription is a lossless stream

Every record of every subscribed element is delivered, in order. The only loss is a stalled
peer lapped by the sync lag ceiling, reported as `lost` and rendered as a gap. There is one mode;
a coalescing mode waits for evidence that the lossless one costs too much.

### Retention comes from the series store

There is no second mechanism. Sync retains records through the element's `SeriesStore` and a pin:

- An element with configured retention (the `memory` or `disk` intent of
  [RETENTION.draft.md](RETENTION.draft.md)) keeps its policy. Sync pins into it.
- An element without history gets a *sync store*: created on the first real change while the
  element is subscribed (in `apply()`, after `held_repeat` has dropped repeats), never on
  subscription. Constant elements never allocate.

A sync store is marked in the element's sync byte (below), so the series layer stays unaware of
sync. It has no floors and no container; its ceiling is the per-platform sync lag ceiling.

- The first bucket is 32 bytes of records (4 records at stride 8) plus its offsets plane, and
  grows in place by doubling up to `bucket_capacity`. A sync store is normally one open bucket.
- It is released when every peer has reached head: the tail returns to the register for text and
  wide formats, peer positions rebase to 0, and the store returns to a freelist. The freelist keeps
  a store's bucket only when it is exactly the 32-byte minimum and was never packed.
- Configuring retention or attaching a container *promotes* it: the open bucket is reallocated to
  the configured size and the sync-store bit clears. Nothing else changes.
- Removing the policy while subscribed *demotes* it: the sync-store bit sets, and every sealed bucket
  wholly below the sync pin is dropped (borrowed ones on their last `release_ref`). Removing it
  while unsubscribed releases the store.
- Reads never promote: opening a cursor must not create or claim a store.
- Any store created on an element that holds a value starts with that value as record 0, for every
  format (text and wide already do; scalars join in B1b), so "one record before the latest" exists
  for every element.

Because the open bucket can now move, a `RecordBlock` is valid only until the next write to its
element (the open text heap already reallocates under the same rule). A producer that resumes
across pulls keeps its cursor position and reads again; it never holds a block.

### Who is subscribed

`Element._sync`, in the padding byte after `_status`, holds the number of peers that have the node
armed, shifted left one, and in bit 0 whether the store exists only for sync (set implies a store).
Arming adds 2 and disarming subtracts 2 wherever a node enters or leaves a peer's `_live_nodes`
(`track_live`, `rebuild_live_nodes`, peer detach, per-node removal), so disarm never scans other
peers; an element allows 127 peers. The write path tests `!_history && _sync >= 2`. Bit 0 clears
in `retention()` and at container attach (`ows.d` and `record.d` reach the store through
`ensure_history()`, so they call back into the element there).

Sync holds one pinned cursor per stored element, shared by every peer, at the lowest peer
position. It opens when a sync store is created (or when a subscribed element's configured store
exists) and closes when the peer count reaches zero.

### Increments

A peer's feed is a sequence of increments. Increment k covers, for each touched element, records
(position, head at T_k]. Opening one records the heads; the pins already hold the records, so
nothing is copied.

Subscribing is arming at a position and marking the element touched; the first increment carries
the current state. A held element arms one record before its latest (a store-less one at its
register, which becomes the store's first record if one is created before the increment), an event
series at head, and a subscription with backfill at `index_for_time(from)`. `add` carries schema
only. Values travel in exactly two ways: increments to subscribers, and replies to history range
requests from readers outside a subscription, where a point read is a range with `from == to` and
a held range starts with the record before `from`.

- Frames carry the increment id, a frame index and a final flag. The receiver acks frames; the
  sender rebuilds missing frames from the store. A retry keeps the increment's original end; only
  a completed increment advances to a new one. A timeout restarts from the same base.
- The shared pin advances when an increment completes, never when a frame is merely accepted for
  sending. The store is the retransmit buffer, which retires the val `DataQueue` backlog, refold
  and epochs.
- The receiver writes records into its elements as they arrive and holds notification. When the
  increment completes it delivers one batch `SampleUpdate` per touched element, carrying the
  increment's records, inside `open_commit()`. `previous` is the record before the slice. A
  receiver that needs the slice for delivery creates a sync store the same way.

Increments do not depend on on-demand production (TODO.md, "Sync produces on demand"); they work
with today's push encoder, and on-demand production later changes only what drives it.

### Logs become a text series

A log line is a text record `<severity digit> <tag> <object>: <message>`; the timestamp is the
record's, the host is the node. `LogSink` reads through a pinned cursor, so text files, syslog and
the console stay sinks with today's formatters. Peer logs arrive as each peer's own log element
and are merged when read, never inserted: the series stays append-only. This deletes the log
module's retention and consumers, the log sub verbs and the last `DataQueue` user.

## Phases

Each phase is one PR.

| Phase | Work | Deletes |
|---|---|---|
| B1a | `Element._sync_peers` counts the peers that have the element armed, kept by `SyncPeer.arm`/`disarm`; a write enlists in the dirty sweep only when its element is armed. | `add_feed_listener`, `remove_feed_listener`, `g_feed_listeners` |
| B1b | Held elements stream through cursors like point series; subscribing arms a position and marks the element touched. `_sync_peers` becomes `_sync` with the store bit, sync stores, the shared pin, promotion and demotion, eviction below every pin when there are no floors. Counters for stores, churn, grown buckets and bytes on the `system` device; `lost` on `/sync/peer`. | `_pending_vals` coalescing, `encode_val`, `take_val_repush`, the value in `add`, `send_backfill` as a separate path |
| B2 | Increments: wire fields, receiver held delivery, ack-driven pin, retransmit from the store. Protocol version bump. | the val `DataQueue` backlog, refold and epochs |
| B3 | Sync store release and freelist, if B1's counters justify it. | |
| C | Logs as a text series, `LogSink` on a cursor, merged reads. | `log.d` retention and consumers, log sub verbs, `DataQueue` |

## Open

- Receiver restart of an increment: truncate the store back to the delivery pin (a new
  `SeriesStore` operation) or skip duplicates. Truncation is preferred.
- A local write to an element whose notification is held: before or after the held increment.
- Whether `res` for `model_set` keeps carrying the applied value, or only the outcome and the
  record's position, leaving the value to the feed.
- The sync lag ceiling per platform, and the size of an increment on a lossy link.
- Attaching a container adopts disk history beneath the RAM buckets and shifts indices; positions
  held by value (peer positions) need the store-held rebase offset from TODO.md, "Make the
  container complete". B1 makes this likely rather than a boot-time race.

## Obligations

- [SYNC.md](../SYNC.md) changes in B1 and B2. The web client is a receiver and must hold
  notification per increment: a migration action in [UX_TODO.md](UX_TODO.md) with B2, clients
  ship first.
- STREAMING.md (#805), "Atomic source views", points here; TODO.md's "Sync produces on demand"
  loses its copy-on-write sentence to this model.
