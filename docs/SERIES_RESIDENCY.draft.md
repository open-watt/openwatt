# Series residency: one block chain, three residencies

Design spec drafted 2026-08-05. Not implemented. Supersedes the RAM/disk split described
in [manager/record.d](../src/manager/record.d)'s header and the two-tier merge in `query_local`.

The thesis: **RAM and disk are not two tiers of a series, they are two residencies of the same
block.** Today they are separate structures with separate owners, separate readers, and
separate history depth, and every consumer has to know which one it is talking to. Unifying
them deletes the two-tier merge, makes cursors reach disk, ends the backfill truncation, and
turns retention from "how much history exists" into "how much stays resident".

## 1. Where we are

Both tiers are already an ordered array of block descriptors:

- **RAM**: `SeriesStore.buckets` is `Array!(Bucket*)`, ordered by `first_index`, binary-searched
  by index or time.
- **Disk**: ows is a doubly-linked chain *in the file*, but `SeriesContainer.open_()` walks it
  once and builds `Array!BlockEntry`. The chain is a file-layout detail, not a data structure.

The differences that matter are ownership and reach:

| | RAM | Disk |
|---|---|---|
| Owner | `Element._history` | `RecordStream.container` (recorder-owned) |
| Format | element-global, from the caller | per block, format runs with anchors |
| Reachable from | `Cursor`, `read_records`, `index_for_time` | `query_local` only |
| Eviction | destroys records, advances `first_index` | never pruned |

`Element` holds no container reference, so everything reached through an Element API is
RAM-only by construction. Only code holding a `RecordStream` can see disk.

### Consequences we are living with

- **`send_backfill` does not honour its range.** It takes `from_ms` but resolves it through
  `index_for_time`, which clamps to `buckets[0].first_index`. A peer asking for 24h of a 1h-retained
  element silently receives 1h, with no truncation marker on the wire. The forward edge is exact
  (`track_live` records `record_count`, backfill runs to head, one synchronous burst, gap-free);
  only the backward edge is undefined. This is documented as deliberate at
  [sync/package.d:1668](../src/manager/sync/package.d#L1668) - deep recall was routed to
  `history_req` "until cursor-paced draining lands".
- **`history_req` is therefore load-bearing, not legacy.** It is the only path that reads disk.
  It cannot be deleted before a tier-spanning reader exists.
- **Format changes silently reinterpret retained history.** `Bucket` carries no `FormatId`;
  `SeriesStore.read` takes it from the caller, which passes `element.format` - i.e. whatever it
  is *now*. `writable_bucket` rolls on capacity, gap and tick overflow, never on format.
  `SeriesEvent.format_change` is declared and never fired. Same stride gives wrong values; a
  different stride misaligns reads and makes `drop_raw` free a wrong-sized allocation.
  `set_format` was elided from the original design pass and never built. ows got this right
  from day one (anchor blocks, `format_block`, per-block `load`); the RAM store never caught up.
- **Deep reads block the main loop.** `container.load()` is a synchronous `read_at` per block.
  A 24h window on a fast element is ~845 blocking SD reads inside a console command or a sync
  request. The async machinery that once covered this belonged to the deleted db engine.
- **No open-fd cap.** The db engine had an LRU (`max_open = 2048`); `SeriesContainer` opens its
  file on first flush and holds it for the life of the stream. One permanently-open fd per
  recorded element, uncapped.

## 2. Target model

`Bucket` becomes the single entry, with residency as a property rather than a location:

| `raw` | `packed` | backing | meaning |
|---|---|---|---|
| set | null | - | open tail, or sealed and never packed |
| set | set | - | packed, raw retained as a cache (a reader holds it, or budget allows) |
| null | set | - | packed, resident |
| null | null | file offset | flushed and evicted; recoverable |
| null | null | none | gone (unrecorded element, or no container) |

`reconstitute()` gains a disk arm beside its unpack arm. Everything downstream is untouched:
same refcount, same `drop_raw` on the 0-edge, same sharing of one decoded image through the entry.

### What this buys

- **Cursors span tiers with no new API.** `SeriesStore.read()` already calls `reconstitute(b)`
  when `!b.samples`. A cursor pulling 256 records touches one block, so reads are *naturally
  paced* by consumption - this is the "cursor-paced draining" the sync comment defers to, and it
  bounds per-tick work in a way `query_local`'s 845-block walk never did.
- **`query_local`'s two-tier merge deletes entirely** - the container walk, the `ram_start`
  splice, the ordering logic. It becomes "seek by time, read blocks".
- **`send_backfill` stops lying** without being touched, because `index_for_time` and
  `read_records` reach disk.
- **Retention changes axis, correctly.** Evicting a flushed bucket drops its bytes and keeps its
  descriptor; `first_index` does not advance. Retention becomes a memory budget, not a statement
  about what history exists.

## 3. Required changes

1. **`Bucket` carries `FormatId`.** Stamped at creation from the element's current format.
   `writable_bucket` adds a format-mismatch roll. `read`/`try_pack`/`reconstitute`/`drop_raw`/
   `seal`/`free_bucket`/`tail_record`/`text_value` take the format from the bucket, not the caller.
   `SeriesEvent.format_change` gets fired. **This is a live bug fix and stands on its own** - do it
   first, independently of the rest.

   This is also the field that makes the two descriptors converge: ows's `BlockEntry` already
   carries its format (`BlockFormatHeader fmt`, resolved per entry at walk time), and `Bucket`
   does not. With it, a bucket is fully self-describing - format, span, and one residency - which
   is the precondition for interpreting a packed or disk-resident block without asking the element.

2. **Raw becomes one `void[]` when sealed.** Today `raw` is three independent allocations
   (`samples`, `offsets`, `heap`, each with its own capacity) *or* one combined allocation, with
   `raw_combined` discriminating - two memory layouts for the same state. Split it by lifecycle
   instead: an **open** bucket is a builder whose planes grow independently; a **sealed** bucket is
   one immutable image in `[offsets | records | heap]` order. `raw_combined` then disappears,
   because sealed implies combined, and `raw`/`packed` become symmetric `void[]` alternatives.
   Three things fall out: `try_pack` loses its scratch copy (it currently memcpys three planes into
   an image that `seal` could have left behind), `SeriesContainer.put` loses its marshalling
   (the image order is already byte-identical to the ows payload, so a flush becomes a straight
   write of `b.raw`), and the residency states end up on equal footing rather than one of them
   needing a shape flag.

3. **`Bucket` carries its file offset.** One `ulong file_offset` (0 = never flushed; 0 is the
   `FileHeader` position and never a block start, which is the sentinel ows already uses for
   `next`/`prev`/`format_block`). The read size is `packed_bytes`, which needs no new field:
   `packed` and `file_offset` are two *locations of the same encoded image*, so the size describes
   it in either place. Nothing else is needed - the chain links (`next`/`prev`) exist so the file
   can be walked without an index, and the RAM array is that index; the format-anchor pointer is
   resolved at open and collapses into the bucket's own `FormatId`. That leaves `Bucket` and
   `BlockEntry` differing only by the file-walk artifacts RAM doesn't need.

4. **Ownership inverts.** The store gains the backing handle; the recorder demotes from owner of
   the file to the thing that drives flushing. A series becomes RAM-and-disk rather than RAM plus
   a separate recorder-owned file.
5. **Index continuity.** On open, `head` resumes from the container's `last_index + 1`. Today RAM
   restarts at 0 while the file holds 0..N, which is harmless only because `query_local` seeks by
   time. Under one sequence it is mandatory, and it makes the file's index space meaningful again.
6. **Eviction distinguishes flushed from gone.** With a container, eviction drops bytes and keeps
   the descriptor. Without one, it destroys as today.
7. **Reconstituted blocks may predate a format change** - which is why (1) is a prerequisite, not a
   consequence.

### Restart is not a special case

On open, walk the chain and build one `Bucket` per block in the fully-evicted state
(`raw == packed == null`, `file_offset` set). Everything but the residency pointers comes from
the headers: `first_index`/`count` from the index span, `first_tick`/`last_offset` from the tick
span, `heap_used` from `heap_bytes`, `codec` and `packed_bytes` directly, offsets-plane presence
from `flags.irregular`, and `FormatId` from the resolved anchor run. `capacity` is meaningless
until something reconstitutes and fills in there. `head` resumes at the last block's
`last_index + 1`.

There is then no load path and no restart branch - a cursor opened at index 0 walks all of
recorded history through the same `reconstitute` that serves a packed block.

**`SeriesContainer.dir` deletes with it.** Headers are unpacked into buckets at open and the
`Array!BlockEntry` never exists; the bucket array *is* the directory. `find_by_time` collapses
into the store's existing one, and `load(i)` becomes a byte read at an offset. What remains of
the container is the write side and nothing else: the `File`, the append position, the tail offset
for patching `next`, and the current format-run anchor - and even the anchor is derivable from the
previous bucket's format, so caching it is an optimisation rather than state. The container demotes
from an indexed store to a block reader/writer over a file, and indexing lives in exactly one place.

Note this does not change the descriptor *count*: today the container's directory already covers
every block in the file while the RAM buckets cover only the retained window, and the two sets are
disjoint. Unification spans both with one array of the same total size - neutral on memory, but see
the limit below.

### Known limit: the directory is O(blocks in file)

This merges two directories into one rather than adding a third - ows already builds a
`BlockEntry` (104 bytes) per block for the whole file at open, so the cost exists today. But it
is not free, and it becomes the binding constraint as files age: a 1s element is ~337 blocks/day,
so ~123k blocks and ~12MB of descriptors per element-year. Thousands of recorded elements on a Pi
will not hold. Mitigations, when it bites: index every Nth block and chain-walk within a span, or
write a footer index so open does not walk at all. Worth deciding before long-lived files exist
rather than after.

## 4. Retention: existence vs residency

Today `SeriesStore`'s `min_records`/`max_records`/`min_age`/`max_age` conflate two questions,
because with one copy of the data they were the same question. With a backing store they split:

- **Existence (disk retention)**: how far back history goes. Currently unimplemented - ows files
  grow forever.
- **Residency (memory retention)**: how much is decoded in RAM. This is what the current fields
  become.

Buckets fall into three classes, and only the third is a cache:

| class | evictable | why |
|---|---|---|
| open tail | never | appended to; `latest`/`tail_record` read from it |
| sealed, unflushed | no - eviction *destroys* | the only copy; the recorder's pin holds it until flushed |
| flushed (`file_offset != 0`) | yes, whenever `refs == 0` | recoverable with one read |

So **retention policy only matters where there is no backing store.** For a recorded element,
residency becomes a global budget rather than a per-element policy - which is the better model,
since per-element record counts are a poor proxy for a shared resource. (`SeriesStore`'s
`// TODO: byte budgets` says as much; note its `== records * stride` parenthetical went stale when
the text heap landed - a byte budget must count heap bytes too.) For an unrecorded element the
existing floors and ceilings still govern existence, unchanged.

Pins keep their meaning but narrow to two jobs: protecting a raw-side borrow (memory safety) and
holding unflushed data until the recorder consumes it (durability). They stop being a statement
about how much history exists.

**Disk retention needs a decision, not just an implementation.** The doubly-linked chain supports
front-pruning - repoint the new head's `prev` and the `FileHeader`'s first-block offset - but that
orphans space and needs a free-space story. File rotation by time span, deleting whole files, is
the simpler answer and composes with the file-per-device direction. Recommend rotation, but it is
a genuine fork.

## 5. What falls out afterwards

Sequenced, because order matters:

1. Bucket-local format (above) - independent, do now.
2. Unified residency + paced cursor reads.
3. `send_backfill` serves deep recall through it, and reports its served range so truncation is
   never silent.
4. `history_req` and `encode_history` die. `Sample`, `QueryMode`, `SampleAggregator` and
   `GraphIntervalSampler` **demote** rather than disappear - `/record/graph` renders to a fixed
   terminal width and legitimately needs doubles and bucketing, so they become private types of
   the console chart renderer instead of a query/protocol boundary.

Note step 4 is client-visible: it needs a `docs/UX_TODO.md` entry and coordinated web/droid
updates.

## 6. Deliberately out of scope

- **Decimation ladder.** Server-side reduction that reads a *coarse tier* rather than reducing
  raw. Note what today's path does and does not do: `query_local` reads every raw record in the
  window and *then* buckets, so it bounds the wire, never the read. It is a response cap, not
  decimation, and it reserves nothing for the ladder.
- **fd cap.** ~40 lines when wanted: `SeriesContainer.close_file()` dropping `_file` while keeping
  `dir`/`_tail`/`_end`/`_fmt_anchor`, plus a cap and an intrusive LRU on the recorder, which
  already owns every stream centrally. Held off because file-per-device would change the shape.
- **File-per-device and multi-channel series.** Two separable wins that are easy to conflate.
  File-per-device is a *container* concern (a series id in `BlockHeader`, per-series directories
  within one chain) and buys fds only. Shared timestamp planes and cross-channel predictive coding
  are a *series* concern, and the model already has the vocabulary for it - the value-shapes table's
  "composite / multi-channel" row, one series with a compound record and columnar planes. The
  distinction: genuinely simultaneous observation (one Modbus response, one CAN frame, one ADC
  conversion) should be one multi-channel series, because the timestamp is shared for a physical
  reason. Merely co-located elements may share a *file* but sharing a timestamp plane would be a
  lie. Multi-channel is the bigger win but needs `Element` to become a `(series, channel)`
  projection rather than the owner of `_history`.
- **Element destruction.** Durable holders keep raw `Element*`; see the
  [manager/element.d](../src/manager/element.d) header for the constraint.
