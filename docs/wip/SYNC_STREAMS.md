# Lossless, untorn sync streams

Status: phase A (#852), B1a (#855) and the series corrections B1b needed (#862) landed; B1b (#857) and B2a in review. Delete this file when phase C lands; reconcile what remains
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
- Configuring retention or attaching a container takes it over: the configured policy replaces the
  sync ceiling and the open bucket keeps growing to the configured size. Nothing else changes.
- Releasing a sync store, and demoting a configured store back to one when its policy is removed,
  need to know which stores exist only for sync; that marker arrives with B3, which uses it.
- Reads never promote: opening a cursor must not create or claim a store.
- Any store created on an element that holds a value starts with that value as record 0, for every
  format (text and wide already do; scalars join in B1b), so "one record before the latest" exists
  for every element.

Because the open bucket can now move, a `RecordBlock` is valid only until the next write to its
element (the open text heap already reallocates under the same rule). A producer that resumes
across pulls keeps its cursor position and reads again; it never holds a block.

### Who is subscribed

`Element._sync_peers`, in the padding byte after `_status`, counts the peers that have the node
armed. It changes by one wherever a node enters or leaves a peer's `_live_nodes` (`track_live`,
`rebuild_live_nodes`, peer detach, per-node removal), so disarm never scans other peers, and the
number of sessions holding live patterns is capped at admission. The write path tests
`!_history && _sync_peers`.

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
only. Values travel in exactly two ways, both as `val`: increments to subscribers, and replies to
reads, where a point read is the latest record and a held window starts with the record holding at
`from`. A `val` group's `seq` names the read or the increment it belongs to.

- An increment is a fixed slice: records (position, head at T_k] for every touched element,
  however many frames it spans. Its `val`s carry the increment id in `seq`, and `res {seq}`
  closes it. One increment is in flight per peer; the next opens from where it ended.
- Sync rides `/interface/rdp` (#869), so every transport is reliable and ordered and a lost
  frame is the layer's to repair. The shared pin advances when the layer reports the increment's
  closing `res` delivered, never when a frame is merely accepted for sending. Moving sync onto the
  layer retires the reliability sublayer whole: the `DataQueue` backlog, refold, epochs and the
  repush rewind.
- The receiver stages an increment's records in each element's store past a published head, which
  every reader (cursors, walks, `index_for_time`, the register, the dirty sweep) treats as the end.
  Staged writes neither notify nor enlist in the dirty sweep, so a relay never forwards a partial
  increment and a reader never sees one torn across elements. The closing `res` publishes: the head
  advances over the staged records, the elements enlist, and one batch `SampleUpdate` per touched
  element, carrying the increment's records, is delivered inside `open_commit()`. `previous` is the
  record before the slice. A mirror element without a store gets a sync store to stage into.
- A session that dies mid-increment truncates the staged records; the new session's first
  increment carries the current state.
- Clients without stores (web, droid) buffer an increment's samples and apply them on its `res`.

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
| B1b | Held elements stream through cursors like point series; subscribing arms one record before the latest and marks the element touched, and `add` carries no value for an armed node. sync stores on first change with the sync ceiling; every new store over a held value starts with it as record 0; the shared pin; gaps sent as a null at their start; eviction below every pin when there are no floors. `encode_val` stays for a store-less element's register, and the val-queue repair rewinds held positions to their latest record (B2 deletes it). | `_pending_vals` coalescing, the value in armed `add`s, the re-push of every armed node |
| B1c | Counters for sync stores (live, peak, created, freed, grown, bytes) on the `system` device once #849 lands; `lost` on `/sync/peer`. | |
| B2a | One value path: a `once` sub answers each match with `val`s carrying the request's `seq`, bundled on the control plane, from one sample-frame encoder per encoding; a point read is the latest record, `from`/`to` a range from the record holding at `from`, `points` its span means. An armed sub's `from` seeds its position. `index_for_time` is exact. Protocol version 3. | `history_req`/`history` and the `history` capability, the value in `add`, `send_backfill` and the parked live cursor, the unarmed value retry, `SampleAggregator` |
| B2b | Increments, after sync moves onto `/interface/rdp`: the increment id in `seq` closed by `res`, the store's published head and staging, held delivery on receivers and clients, the pin advancing on delivery. | the repush rewind (the move itself retires the `DataQueue` backlog, refold and epochs) |
| B3 | Sync store release, the freelist and demotion, if B1c's counters justify the first two. | |
| C | Logs as a text series, `LogSink` on a cursor, merged reads. | `log.d` retention and consumers, log sub verbs, `DataQueue` |

## Candidates waiting on measurement

- Sparse positions: when a flush keeps up, every armed element's position equals its head, so a
  peer's entry need only exist while the element has unsent records; caught-up peers do not
  constrain the pin. The per-peer map then holds the backlog, not every armed element (the energy
  device alone is ~5,400 entries per peer on the Pi). Wait for B1c's counters and the map size
  with an energy visualisation open.
- Component arms: a pattern naming a whole component arms the component, and an element is armed
  if it or an ancestor is. Saves the subscribe walk and per-node counts, at the cost of a second
  arming path and an ancestor walk on writes; only if measurements show the walk or the counts.

## Open

- A local write to a mirrored element while an increment is staged appends after the staged
  records and publishes with them, until a mirror forwards local writes to its authority instead
  (the TODO at `merge_remote_value`).
- Whether `res` for `model_set` keeps carrying the applied value, or only the outcome and the
  record's position, leaving the value to the feed.
- The sync lag ceiling per platform.
- Attaching a container adopts disk history beneath the RAM buckets and shifts indices; positions
  held by value (peer positions) need the store-held rebase offset from TODO.md, "Make the
  container complete". B1 makes this likely rather than a boot-time race.

## Obligations

- [SYNC.md](../SYNC.md) changes in B1 and B2. The web client is a receiver and must hold
  notification per increment: a migration action in [UX_TODO.md](UX_TODO.md) with B2, clients
  ship first.
- STREAMING.md (#805), "Atomic source views", points here; TODO.md's "Sync produces on demand"
  loses its copy-on-write sentence to this model.
