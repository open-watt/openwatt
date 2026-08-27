# Sync Protocol

Status: in build. The object-mirror verb set is built and running; this document designs its
successor: one small verb set that synchronises the entire data-model space -- devices, elements,
events, callables, and (at convergence) the BaseObject world itself. The built verbs keep working
during the transition and dissolve at the end.

## Build progress (2026-07-31, second pass)

Build-order items 1-8 are implemented except methods/`call` (no callable node exists anywhere
yet; the verb lands with its first callee) and pinned-cursor paced backfill (backfill serves
synchronously within the burst, which is gapless because nothing interleaves; cursors return
when transports grow backpressure). The `detach_peer` defect below is fixed. Deviations and
deferrals are recorded in the commit messages on the way past; the notable ones:

- Formats failing `ows.container_serialisable` (including text) are skipped from the model
  surface with a log, not answered with `err` -- per-node errors inside a glob burst were
  unresolved.
- Constraint min/max/step do not ride the `type` format block yet; the element write path does
  not enforce Constraint either, so they land together.
- Echo suppression for `set` writers is not implemented; the writer receives its own change
  back through the feed in addition to the `res` ack (benign under mode `latest`).
- Peer-contributed elements are served to peers other than their contributor (hub fan-out);
  element binding membership identifies the contributor. Star topologies only, as before.

## Implementation status (2026-07-31, first pass)

**Built** ([src/manager/sync/](../src/manager/sync/)): peer/transport objects, the encoder
abstraction with a JSON implementation, and 23 verbs: the object mirror (`add_name`, `bind`,
`unbind`, `create`, `destroy`, `state`, `set`, `reset`), console (`cmd`, `result`, `error`,
`suggest`, `suggestions`),
subscription (`sub`, `unsub`), enums (`enum_req`, `enum`), element history (`history_req`,
`history`), log tap (`log_sub`, `log`), and time discipline (`time_req`, `time_resp`,
`time_push`).

**Not built**: everything below except where marked.

**Substrate that exists and is waiting:**

- [`EID`](../src/manager/id.d): two-level handle `(container CID, element index)`, rename-stable,
  write-once forward chains, deref that rewrites the holder's id. Unit-tested. id.d:24 already
  plans property projections as elements: `EID = (obj CID, Prop! index)`, a compile-time literal.
- [`g_formats`](../src/manager/series.d#L62): dense process-local registry of interned
  `DataFormat`s. Wire format-interning mirrors it directly.
- [`SeriesKind.point`](../src/manager/series.d#L190): declared, used nowhere. The event slot.
- [`g_dirty_elements` + `sweep_dirty()`](../src/manager/element.d#L998): per-tick dirty-element
  sweep, populated by every write, drained by nothing.
- [`CommandState`](../src/manager/console/command.d): async execution with `request_cancel()`.
- [`CollectionTypeInfo.syncable`](../src/manager/collection.d#L161), honoured in four places.
- Session handles ([`SyncPeer.introduce`/`adopt`](../src/manager/sync/peer.d#L103)): parity-bit
  direction encoding, never reused, session-scoped. Exactly what id.d:55 specifies.

**Known defect to fix on the way past:** [`detach_peer`](../src/manager/sync/package.d) destroys
the session and drops `PendingInboundCmd` entries without calling `request_cancel()` on the held
`CommandState`, leaving a latent command running against a destroyed session. AGENTS.md's command
lifecycle pattern applies: request cancel, then `Continue` until finished.

## Principles

1. **Identity is the name. Ids never travel.** CIDs, EIDs, FormatIds and `collection_id` ordinals
   are process-local and build-sensitive. The wire carries names, paths, and session handles.
   (Sibling peers sharing physical memory are the deliberate exception -- see *Transport classes*.)
2. **Every read is a subscription; a one-off is a subscription that closes itself.** Get, list,
   tree-walk, history query, event replay and live feed are one mechanism with two knobs: does it
   backfill (`from`), does it stay live (`once`).
3. **Knowledge is interned and pushed, never requested.** Names bind to handles once; formats,
   named types and signatures bind to session ids once, pushed *before first use*. There are no
   `*_req` verbs for schema: if you hold a reference, you were already sent its definition.
4. **The introduction frame answers every question it provokes.** Path, schema reference, access
   and current value travel together, because each omission stimulates the follow-up request
   principle 3 forbids.
5. **Every verb family is optional and negotiated.** An unsupported verb is `err
   {code:"unsupported"}`, never a dropped frame.

## The node model

The data-model space is one tree. Only nodes with **local identity** are addressable; structure
without identity is carried by paths alone.

| node class | identity | schema | interaction |
|---|---|---|---|
| device | `CID` | -- | `add`, `move`, `gone`; subtree prefix owner |
| element | `EID` | format | `val` feed, `set` |
| event | `EID`, format kind `point` | format | `val` feed (`mode:all`), replay via `from` |
| method | `EID` (element index) | signature | `call` |
| **component** | **none** | -- | **path structure only; never handle-bound** |

**Components are implied by paths.** A client reconstructs the tree by splitting
`device:inv.battery.voltage`; there are no container frames for components, no component class on
the wire, and no index allocated per component. This mirrors the substrate exactly: `Component` is
a plain class with an `id` and a parent pointer and has no identity to bind, whereas `Device` has
a `CID` and elements have `EID`s.

Consequences, both accepted: a component rename emits `move` for each element beneath it (component
renames are approximately never), while a *device* rename is O(1) because the device is
handle-bound and its `move` implies a subtree prefix rewrite. A component with nothing beneath it
is invisible; if that ever matters, `meta` replies can carry a `dirs:[]` list.

**Events are not a new mechanism**: an event is an element whose format kind is `point` -- no
retained value, no coalescing, deadband meaningless, and event-log replay via `from` works
identically to value history because point series live in the same `SeriesStore`.

**Methods** occupy element indices in their container's EID table, exactly as id.d:24 does for
property projections. No value, no history; their schema is a signature.

## Address model

### Session handles

Allocated by the introducer, low bit = who allocated relative to the frame's sender, never reused,
session-scoped. The tables retype from `BaseObject`/`CID` to **EID**; element index 0 denotes the
container itself (id.d:11), so device handles are `EID(cid, 0)` and one handle space covers
everything addressable.

**Handle resolution is a peer responsibility, never an encoder one.** Encoders call
`peer.handle_of(...)` / `peer.node_of(handle)` and never touch the handle tables. This is already
true of the built code and must stay true -- it is the seam that lets sibling transports exist
(below).

### Path grammar (normative for every addressing and pattern field)

```
address  := ns ':' name ( '.' segment )*
ns       := ident | '=' ident | '*'      ; '=' = exact type, no descendants
name     := ident | glob
segment  := ident | glob
glob     := '*' | '**' | ident-with-'*'
```

`*` matches one segment, `**` matches zero or more. The built `sub` grammar `[=]<type>:<name>` is
this grammar with zero segments, so existing patterns stay valid. `history_req`'s bare dotted path
is the one legacy form; new verbs do not accept it.

Namespaces are the root level of the pattern space: `sub {patterns:["*:"], once, meta, depth:0}`
*is* namespace enumeration. There is no dedicated namespace verb.

## Transport classes

Two classes, differing in **whether identity is shared** -- an axis orthogonal to encoding
(JSON vs binary).

- **foreign** (build now): independent processes. Names bind to session handles, formats intern
  per session, `hello` negotiates capability. Everything in this document.
- **sibling** (accommodate now, build later): peers sharing physical memory -- the BL808 D0/M0
  shmem ring is the motivating case. Both binaries build from one tree, so `CollectionType`
  ordinals agree; if the id and format tables live in shared memory, **EIDs and FormatIds are
  common currency** and introduction is pure overhead. This does not violate principle 1: that
  invariant governs serialising into an independent process, not two cores indexing one table.

Sibling is **not built**. The design must merely not preclude it, which means five structural
rules that cost nothing today:

1. **Never bypass the peer's resolve methods.** Encoders ask the peer to map handle to node and
   back. A sibling peer implements those as identity.
2. **Introduction is a peer policy, not a protocol phase.** Subscription-match code asks the peer
   whether a node needs introducing rather than unconditionally emitting `add`. A sibling answers
   "never".
3. **Interning is a peer policy.** "Have I sent this format?" lives on the peer. A sibling answers
   "always", and emits no `type` frames at all.
4. **Do not assume handles are `uint`.** Foreign handles are small dense session ints; sibling
   handles are 64-bit EIDs. The handle type must be wide enough or abstracted. The built code's
   `uint` + `invalid_handle = uint.max` is the thing that would need retrofitting, so widen it
   when the tables retype to EID.
5. **Do not assume names ever travelled.** Nothing downstream may require having seen a name.

Two things to verify before ever building sibling: `IdAllocator` and `g_formats` both allocate
through `defaultAllocator`, so shared-memory residency is a real constraint needing a
writer/reader ownership rule; and M0 builds `FEATURES=switch HEADLESS=1`, so it has no devices or
protocols -- validate what payload actually needs syncing before designing for it.

## The verb set

Conventions: verb in `kind`; `seq` correlates and is omitted when zero; `h`/`target` is a session
handle; `err` answers any `seq`-bearing request.

Unchanged orthogonal planes: console text (`cmd`, plus `suggest {seq, text}` answered by
`suggestions {seq, complete, suggestions[]}` for remote tab-completion), log tap (`log_sub`/`log`), time discipline
(`time_req`/`time_resp`/`time_push`). The `elements` capability implies `time`: `val` timestamps
are meaningless across nodes without clock discipline.

### 1. `hello` -- `{ver, host, caps, encoders, max_frame}`

Both directions, first frame. Capability is a build-time property here (`FEATURES`, `HEADLESS`,
`has_http`, the record/db module), so it is negotiated, not probed. `caps` names served families:
`objects` (legacy mirror), `model`, `history`, `console`, `logs`, `time`. `max_frame` bounds every
response; history already caps at 2000 points to fit one 64KB raw packet, and `meta` walks have no
natural bound.

### 2. `sub` -- `{seq, patterns[], once?, from?, to?, depth?, meta?, rate?, deadband?, mode?}`

The whole read surface. List-valued. The parameter combinations are the old verbs:

| combination | is |
|---|---|
| `once, meta, depth` | structure browse (list / tree walk / namespace enumeration) |
| `once` | a get: `add` for unbound matches, `val`, close |
| `once, from, to` | history / event-log query |
| `from`, live | backfill-then-follow, gapless |
| live | steady-state feed |

Reply order: `type` frames for unseen schema, `add` per match not yet bound, `val` payloads, then
(if live) the feed. `res {seq}` closes the initial burst. A live pattern stays armed: a node
created later that matches receives its `add` when it appears -- **that is the creation
notification**, and needs no verb.

`meta` = introduce, don't stream. `depth` bounds recursion. `rate` = min interval per node;
`deadband` = the per-subscriber band stubbed on
[`Subscription`](../src/manager/element.d#L102); `mode` = `latest` (coalesce per flush, default)
or `all` (forced for events).

**Overlapping patterns arm a node once.** Several patterns may match one node, within a single
`sub` or across successive ones, and a client asking for both a broad sweep and a specific subtree
is the normal case rather than an error. A node carries one handle and one feed; the second and
later matches are no-ops, and re-arming must never rewind the node's cursor or records arriving
between the two arms would go unsent.

Effective-parameter merge stays open only because there are no parameters yet: `rate`, `deadband`
and `mode` are unimplemented, so an armed node holds nothing but its cursor and there is nothing to
reconcile. That question returns with the first of those knobs, and `tightest wins` (min interval,
min band, `all` beats `latest`) is the presumptive answer.

### 3. `unsub` -- `{patterns[]}`

### 4. `type` -- three forms, push-only

```json
{"kind":"type", "ft":5, "format":{"type":"f64","count":1,"series":"held","rate":0,
                                  "unit":"kW","min":0,"max":25,"step":0.5,"default":0}}
{"kind":"type", "name":"InverterMode", "members":{"off":0,"standby":1,"run":2}}
{"kind":"type", "sig":3, "args":[{"name":"level","ft":5},{"name":"ramp","ft":7,"default":0}],
                "returns":9}
```

Form 1 interns a format under a session format id (`ft`), mirroring `g_formats`. Form 2 delivers a
named type's dictionary (enum / bitfield members, user-type layout) the first time a format cites
it. Form 3 interns a method signature; argument and return types cite `ft`s.

Sent lazily, deduped per session, always before the frame that first cites the id. No request
form, by principle 3.

`default` is **advisory UI metadata only** -- see `set`/reset below. Constraint min/max/step ride
the format block; their source comment already declares the intent
([series.d:277](../src/manager/series.d#L277)).

Formats with no wire representation (user types pending name binding, domain-clocked series
pending clock anchors) are declined with `err {code:"unserialisable"}` -- shared verdict with
[`ows.container_serialisable()`](../src/manager/ows.d#L50), not a second opinion.

### 5. `add` -- `{h, path, class, peer?, ft|sig, access?, v?, t?}`

Four jobs in one: binds handle to path, announces existence, cites schema (`ft` for
elements/events, `sig` for methods), and carries current value + timestamp. Each omission would
stimulate the follow-up principle 4 forbids. `class` is `device` / `element` / `event` / `method`;
components never appear. `peer` is the hexadecimal owner of a peer-local device and is omitted for
the global namespace.

Under a `from` subscription, `add` binds the handle without a value, chronological backfill follows,
and the latest value closes the burst. This keeps last-write conflict handling from rejecting the
older records before they enter the mirror.

### 6. `move` -- `{h, path}`

Rename or reparent; the handle survives because EIDs are rename-stable. Covers the built mirror's
known rename gap ([package.d:16](../src/manager/sync/package.d#L16)). On a device handle it
implies a subtree prefix rewrite (O(1)); a component rename instead emits one `move` per element
beneath it, since components hold no identity.

### 7. `gone` -- `{h}`

Terminal; handles are never reused, so no ABA hazard.

### 8. `val` -- `{h, s:[[t,v],...], lost?}`

Deliberately dumb: it is ~all the bytes on a mature link and every field multiplies by sample
count. `lost` (from `RecordBlock.lost`) reports overrun rather than hiding it -- the difference
between a mirror that is wrong and one that knows where it is wrong.

**No quality/staleness field.** Staleness is the *absence* of frames, so no per-frame flag can
express it; `t` plus a disciplined clock lets the client compute age itself (exactly what
apps/api's server-side `age` does today). Source health belongs to the device as an event node.
Deferred until a consumer demands more.

Batching shape is the encoder's choice (per the `tick_dirty` precedent): JSON favours per-element
frames, binary packs many handles per tick.

### 9. `set` -- `{seq, h|path, value}` or `{seq, h|path, reset:true}`

One verb for element writes and object property writes, because id.d erases that distinction
(properties are element projections). Path form serves one-shot writers with no session binding.
Honours `Access` and `Constraint` at the authority.

**`reset:true` replaces the built `reset` verb**, and carries no value -- `value:null` cannot mean
"restore default" because null is a legitimate value here ([`from_variant` for
BaseObject](../src/manager/value.d#L510) nulls a reference to detach it).

**The receiver does not infer the post-reset value.** The built contract ("receiver knows init from
the type's properties") is fragile by its own admission -- `init_val` is synthesised from the
getter's return *type's* `.init`, not what the constructor assigned, which is why
`assert_reset_matches_init` exists and warns that divergence "would silently desync mirrors". Worse,
property setters call `restart()`, so a reset's consequences exceed its value. Instead: `res {seq,
value}` carries the authority's **applied** value, and any other consequence flows back through the
ordinary feed and `state`. Same shape as an ordinary `set` ack, no special path.

### 10. `call` -- `{seq, h|path, args:{...}}`

Typed invocation of a method node. Cannot collapse into `set`: calls have argument lists, return
values, and no idempotent-value semantics. Args are named and validated against the signature at
the authority. `res` carries the return value when execution completes -- latent commands
(`CommandState`) simply answer late; `seq` stays open until then.

Remote cancellation is **deferred, name reserved**: `cancel {seq}` becomes verb 12 when the first
long-running remote call lands (OTA the likely candidate). `err code:"cancelled"` is expressible
now. Disconnect-cancel is local, not a wire concern -- see the `detach_peer` defect above.

### 11. `res` / `err` -- `{seq, value?, text}` / `{seq, text, code}`

`err` codes: `unsupported`, `unknown_path`, `unknown_handle`, `access_denied`, `bad_value`,
`not_authoritative`, `too_large`, `unserialisable`, `busy`, `cancelled`.

## Write authority and echo

A `set`/`call` arriving at a mirror routes to the authority; the ack reflects the authority's
*applied* value, not the mirror's optimistic one. Echo suppression uses
[`SampleUpdate.who`](../src/manager/element.d#L31) -- the subscriber that caused the write -- the
same split-horizon role `g_log_reinject_source` plays in the log tap. Multi-hop loop defense
inherits the built mirror's posture (star topologies defended, arbitrary graphs not) until a hop
count is added.

## Flow control

Feeds emit at end of commit scope, never per write; the commit machinery already guarantees
subscribers see fully applied frames, so per-tick flush is aligned by construction.

Peers ride the (currently unused) global `sweep_dirty()` with a per-peer pending-EID set drained
each tick. Real `ElementCursor`s are reserved for `from`-subscriptions needing gap-free replay:
[`pin_mask` is 16 bits](../src/manager/series.d#L516), a hard ceiling of 16 pinned cursors per
element, which rules out cursor-per-peer as the steady-state design. When a pending set overflows
or a ring evicts past an unpinned reader, the next `val` carries `lost` -- honesty over buffering.

## Convergence: the BaseObject world moves in

Decided direction: the D-code BaseObject model migrates into the data-model space. The verb set is
shaped so the object mirror *dissolves* rather than coexisting indefinitely:

| built mirror verb | becomes |
|---|---|
| `add_name` / `bind` / `unbind` | `add` / `sub` / `unsub` on object subtrees |
| property `set` | `set` on property-projected elements |
| `reset` | `set {reset:true}` |
| `state` | a built-in **event** node on every object (`StateSignal` payload) |
| `create` / `destroy` | **`call`** on collection-node methods (`add` / `remove`) |
| `enum_req` / `enum` | `type` form 2, push-only |
| `history_req` / `history` | `sub {once, from, to}` |

Collections become container nodes whose methods mirror the console's auto-generated commands, so
the CLI and the wire converge on the same signatures -- the same unification
`register_collection` already performs for humans.

Sequencing: the built mirror stays wire-compatible while `model` comes up beside it; peers
negotiate via `caps`; the mirror verbs retire when both ends speak `model`.

## Build order

1. **Register `device` as a namespace.** It owns a `CollectionType` slot and an
   `IdAllocator!Device` but sits in neither `g_app.types` nor `g_item_tables`, so
   `get_id`/`get_item` on a device CID index an unpopulated table -- a live hazard once EIDs enter
   the handle tables. A `RegisteredType` with null `create` is legal (`is_abstract` ==
   `create is null`), making devices visible to schema, discovery and pattern matching without
   making Device a BaseObject, which id.d:6-10 already calls for. Check nothing iterating
   `g_app.types` assumes every entry is instantiable.
2. **Fix `detach_peer`** to `request_cancel()` pending commands before dropping them.
3. **Element lifecycle hook** mirroring `register_object_lifecycle_handler`, carrying the element
   (`ComponentEvent.tree_changed` doesn't say which). The object equivalent is already hooked.
4. **Retype peer handle tables to EID**, widening the handle type past `uint` (sibling rule 4).
   No wire change; unlocks element addressing.
5. **Shared path parser + matcher**, absorbing `pattern_matches` and apps/api's
   `collect_with_wildcard`.
6. `hello` + `type` interning + `add`/`val` with `sub {once}` -- the read-only model surface.
7. Live feeds (`sweep_dirty` + pending sets), then `from` backfill (cursors), then `set`.
8. Events (`SeriesKind.point` end-to-end), then methods + `call`.
9. Convergence, gated on the property-projection work in id.d.

## Open questions

- **Overlapping subscription parameters** -- returns with the first of `rate`/`deadband`/`mode`;
  arming itself is settled (see `sub`).
- **Per-sample quality** -- deferred with staleness; if ever needed it belongs in the format (a
  quality-tagged type), not as a universal frame field.
- **Empty components** invisible under path-implied structure. `dirs:[]` in `meta` replies if it
  matters.
- **Binary encoder frame shapes** -- shares the verb space and the peer-resolve seam; packing is
  its own decision, taken when the BL808 work starts.
