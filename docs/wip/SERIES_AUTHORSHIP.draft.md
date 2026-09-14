# Series authorship, gaps and reconnection

Design note for the `ow/series-authorship` series. Settles who writes an element's series, what a
gap means, how a mirror behaves across a peer link loss, and how it reconciles on reconnect.
Prune as the patches land; delete when the series lands.

## Principles

1. **One author per element, fixed by residency.** The element lives on its device's node. Every
   other copy is a mirror. Sync is bi-directional only in that both nodes author some elements and
   mirror the rest; no element has two authors.

2. **Only the author's records enter a series.** A write on a mirror is a request forwarded to the
   author, never a record. While the author is unreachable the request is queued (latest wins per
   element) or refused; the mirror's series is untouched either way. The record is created when the
   author applies the change, with the apply time. "What was requested and when" is a different
   fact and, if recorded at all, lives in a command log or a mirror-authored element.

3. **A gap is "no claim over this interval", and the author raises its own.** Binding offline,
   restart, retention overrun: the author marks the gap in its series and it replicates as series
   structure. No peer logic is involved.

4. **A mirror raises a provisional gap on link loss** across everything it mirrors from that link,
   and propagates it downstream like any gap. A downstream consumer (UX client, second-tier mirror)
   is a mirror of a mirror and applies the same rules, so chains of any depth work.

5. **On reconnect the mirror recomputes gap state from the author's testimony.** The author resumes
   delivery from the mirror's position and states whether anything is missing before the first
   record. Nothing missing: clear the gap, adopt the backlog. Anything missing or position unknown:
   the gap stands. The author's own current gap state is then re-applied. No temporal inference:
   cadence is adaptive and report-mode elements have no cadence, so absence of records never
   clears a gap on its own.

6. **Testimony is a delivery cursor held by the author, per subscriber node, per series, advanced
   on ack.** Reconnect is "resume the cursor". `lost` from the series cursor is the exact count of
   records evicted below it and is already on the wire.

## Authorship

- The author is the element's single source entry: the binding attached with read access. Who
  created the element is irrelevant; creation is shape.
- No source entry: the local node is the author (console, automations, computations).
- A peer entry: the author is remote; the sync peer is its local representative. Residency already
  prevents a local source and a peer entry on the same element.
- Detaching the source gaps the element. HA discovery already does this on entity removal; it
  becomes the general behaviour of `Device.detach_binding`.
- A second source entry on one element is refused at attach; the binding fails validation.
- Frontends (SNMP agent, MQTT export, Modbus server) never attach. They subscribe and publish
  outward; an inbound write is a request through the write gate, whoever the author is.
- Two legitimate producers of one quantity (primary plus fallback, local plus remote) are two
  elements and a selecting computation, never two entries on one series.

## Cases

| Situation | Author's testimony | Mirror outcome |
| --- | --- | --- |
| Comms only, author kept recording | cursor resumes, nothing lost | gap cleared, backlog adopted |
| Author restarted | no cursor for this subscriber | gap stands, new records follow it |
| Author retains only the undelivered backlog | backlog flushes, nothing lost | gap cleared |
| Backlog overflowed | `lost` nonzero | gap stands |
| Author keeps no history | position not retained | gap stands |
| Constant element | cursor at head, nothing to send, nothing lost | gap cleared |
| Author had its own gap during the outage | gap replicates with the records | gap in mirror history at the right place |
| Write on the mirror while the author is down | request queued, applied on return | no gap in history; applied record at apply time |

## Wire changes

- `model_sub` carries the subscriber's resume intent; the author resumes each series from the
  delivery cursor it holds for that node, not from a time.
- Val blocks carry `follows_gap`; the mirror marks a gap before writing such a block. `lost`
  nonzero on the first block of a catch-up is the "something is missing" testimony; the sender must
  set it (sentinel for "unknown count") whenever its store does not reach the cursor position.
- A gap event travels as its own frame per handle so a provisional or authored gap reaches
  downstream mirrors without waiting for a record. Its revert travels the same way.
- The add frame carries the element's current gap state so a catch-up re-applies it.

## Mirror state machine

- Detach: `mark_gap` on every mirrored element with history from that peer.
- Reconnect, per element: if the first delivered block reports nothing lost, `clear_gap`; else the
  gap stands. Elements with no block: clear only if the author's latest value carries a timestamp
  at or before the mirror's tail (the same record, so the value held), else the gap stands. Then
  apply the author's current gap state from the add frame.
- `clear_gap` is the one new Element primitive: drop `gap_open`, and clear `follows_gap` on the
  tail bucket if a write already rolled it.

## Patch series

1. This note plus TODO entries.
2. Authorship enforcement: refuse a second source entry at attach; `detach_binding` gaps the
   element. Audit existing bindings for double attachment (TWC master and binding first).
3. Provisional gap at detach (principle 4). Conservative on its own: a gap persists across a
   clean reconnect until patch 6 lands, which is still more honest than a stale value asserted as
   live.
4. Write gate (principle 2): the existing `on_mirror_write` TODO. Mirror writes become forwarded
   requests with latest-wins queueing while the author is unreachable.
5. Wire structure: `follows_gap` on blocks, gap and revert frames, gap state in the add frame.
6. Delivery cursors: `_live_nodes` keyed by remote node and retained across sessions, advanced on
   ack; catch-up resumes from them; `lost` sentinel for unknown position; mirror resolution rule.

## Open

- Persisting delivery cursors on disk so a restarted author with persisted series can resume
  cleanly. Without it a restart is always a gap, which is honest but loses history the author
  still holds.
- A series restored from disk after a restart should treat the restore as a gap. Check whether
  the recorder's reload does this today.
- Whether TINY targets retain any backlog at all, and how large. Bounded backlog with `lost` on
  overflow is the intended shape.
