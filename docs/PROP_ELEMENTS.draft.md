# Property Projection: BaseObject properties as data-model elements

Status: partially built. This is the design for the convergence step the sync protocol draft
defers to ("gated on the property-projection work in id.d"): object properties stop being ad-hoc
getter/setter pairs with hand-rolled dedup and dirty tracking, and become elements in the
data-model space.

Built: the `Elem!` declaration form, the per-object element block, synthesized get/set/reset with
Default/Min/Max/Check/OnChange, the proxy side-effect gate, and SerialStream's framing properties
as the first migration. Not built: the descriptor split, reference properties, state-machine
properties, and the retirement of the per-object sync delta machinery. Deviations from this
document where it describes the built part are called out inline.

## What exists that this stands on

- id.d:24 already specifies the identity: property projections COMPUTE their EID as
  `(obj CID, Prop! index)` -- a compile-time literal, no lookup, no cache. Element index 0 is the
  container, so properties claim indices 1..N and dynamic/profile elements allocate above.
- `Constraint` (series.d) already carries min/max/step plus a `check_fn` escape hatch, hangs off
  `DataFormat`, and is enforced nowhere. The sync draft notes constraint enforcement and the
  min/max/step `type`-frame fields "land together".
- `register_value_format!T` already maps the property-type vocabulary: bool, integers, floats,
  enums (with `enum_info` so the wire gets the dictionary), String/text, Duration (s64
  nanoseconds), Quantity, and registered user pods.
- The Element write path already provides everything setters hand-roll today: held-series dedup
  (`held_repeat`), timestamping, subscriber delivery with previous+new value, commit-scope frame
  coherence, the per-tick dirty sweep, and (via the sync branch) per-peer pending-EID feeds.
- The sync `set` verb is already specified to serve "element writes and object property writes"
  as one thing, with `res {seq, value}` carrying the authority's applied value.

## The shape

### Storage: the element IS the store

A migrated property has no member field. `BaseObject` gains one pointer to an
`Element[num_props]` block, allocated in one piece at construction and sized from the type's
static property table; a property is reached by indexing it with `prop_index!(T, "baud")` -- a
compile-time literal. Reads and writes go through Element's typed door (`read!T` / `try_write!T`),
which is the counterpart of the boxed `value`/`try_set` pair: same records, same constraint gate,
no Variant. Nothing outside Element reinterprets a record, so the type check lives once, where the
format is (`scalar_type!T == data_format.type`, which sees through an enum to its base -- a
size-based check would alias `u32` with `f32`).
Prop index == element index, so `eid` is `_id.element(prop_index!(T, "baud") + 1)`
(index 0 being the container), also a constant. A small block header (the owning object) would let
an `Element*` recover its owner and index by arithmetic, which is what makes `parent`/`_eid`
derivable rather than stored.

As built, property elements mint their EID at construction and `resolve_element(EID)` (manager
package) dispatches on the container's type bits: device containers resolve through the
DeviceTable as before, any other container resolves through `get_item(cid)` and indexes the
object's property block (`find_prop_element`, null for the container index, legacy properties,
and out-of-range). The sync inbound paths resolve through the dispatcher, so a property EID on
the wire reaches its element. One known gap: a write landing directly on a property element
(`try_set` from the model surface) enforces the constraint and access gates but bypasses the
declared `Check!` function, which lives in the by-name path (`elem_apply`); route model-surface
property writes through `BaseObject.set` when property elements become addressable by path. The
change handler recovers its index by subtracting the block base, so the block header is not
needed yet.

Also as built, the block is sized by the type's TOTAL property count, not its element-backed
count, because the prop index is the slot index. SerialStream has 22 properties of which 5 are
element-backed, so it allocates 2288 bytes to use 520. The waste shrinks as migration proceeds
and vanishes when a class is fully migrated, but a per-type prop-index -> slot map (a byte per
property in `CollectionTypeInfo`, one extra indirection per access) removes it now if the
transitional cost bites.

Per-type metadata moves into `CollectionTypeInfo` (computed once at type registration, when
formats can be interned): per-property `FormatId`, `Constraint*`, declared default, and hooks.
Property elements never allocate a `SeriesStore` unless someone asks for retention.

### Element layout: the descriptor split

Element is ~104 bytes on x86-64, but only ~48 of that is per-instance value state:

| field | bytes | class |
|---|---|---|
| `id` `name` `desc` `display_unit` (4x String) | 32 | identity / schema |
| `_eid`, `parent` | 16 | identity |
| `access` `sampling_mode` `format` (+pad) | 8 | schema |
| `last_update`, `_latest`, `_last_update` | 24 | value state |
| `_subs`, `_history` | 16 | value state |
| `_dirty` `_flags` (+pad) | 8 | value state |

For a property projection every identity/schema byte is shared per collection type: `id` is the
property name (an interned StringLit), desc/display_unit/format/access/sampling are declaration
constants, `_eid` is computable (id.d:24 -- that is its point), and `parent` is derivable when the
cells sit in one per-object block with a small header (owner + arithmetic recovers the index).

So the layout move is a descriptor split: `Element` becomes
`{ const ElementDesc* desc; ...value state... }` with `ElementDesc` carrying
id/name/desc/display_unit/format/access/sampling. Property cells land around 48-56 bytes, and the
same split compresses profile-created device elements -- N devices materialized from one profile
currently duplicate identical schema Strings per element; with the split they share one descriptor
table per profile version, which id.d already plans ("profile elements take their template index,
deterministic per profile version") and component.d's `FieldTemplate` stub half-starts. On a busy
instance the profile-element savings likely exceed what property migration adds.

Also audit the `last_update` / `_last_update` pair (they diverge only through held-repeat and
`force_update` stamping); if one can derive from the other, that is 8 more bytes per element.

### Declaration

Two forms coexist in one `Properties` list so migration is per-property, not per-class:

```d
alias Properties = AliasSeq!(
    // element-backed: no member function pair, no member field
    Elem!("baud", uint, Default!9600, Min!300, Max!921600, OnChange!restart),
    Elem!("protocol", ModbusProtocol, Check!protocol_check, OnChange!restart),

    // legacy form: hand-written getter/setter, unchanged, not element-backed (yet)
    Prop!("stream", stream),
);
```

`Elem!` carries: name, type, optional `Default!`, optional `Min!`/`Max!` (folded into the
format's `Constraint`), optional `Check!` function, optional `OnChange!` member function,
optional `ReadOnly`, and the `Category!`/`PropFlags!` presentation metadata the legacy form takes
positionally.

`ReadOnly` means read-only *to the outside*, not immutable: the owning object still pokes the
value in. That asymmetry is the whole point for derived state -- link status, counters, and
eventually `running`/`status` -- so the two directions take different doors. The external entries
(`BaseObject.set`, `reset`, and therefore the console, sync inbound, and collection create)
refuse with the same "is read-only" message a getter-only legacy property produces; the owner
writes through `prop_write`, which calls the property's setter directly and does not consult the
flag. The element's `Access` follows the declaration (`read` vs `read_write`), so the model
surface serves the truth once property elements are exposed on it.

Owner writes still mark `_props_set`, deliberately: that bit is what makes a mirror receive the
value, and a proxy cannot recompute derived state (the same reason the encoders emit set
read-only properties).

No `Step!`: `Constraint.check` honours min/max and `check_fn` only, so a declared step would not
validate. `Constraint.step` remains for profile-driven formats, where it is wire/UI metadata
rather than a promise.

Typed accessors are hand-written one-liners over `prop_read!(Type, name)` /
`prop_write!(Type, name)` rather than generated by a mixin, so internal call sites keep reading
`baud()` and assigning `baud = x`. Both resolve the declaration at compile time, so the accessor
never restates the property's type: `ElemType!(Type, name)` is the declaration's. A mixin would
remove the remaining two lines per property but has to invent accessor names (`"baud-rate"` ->
`baud_rate`) and their const-ness; that is the only reason it is not done here.

### Validation: two layers, both before commit

Every writer lands on one typed function, `elem_apply!T`, holding the declared type. It runs:

1. **Per-prop check function**: `const(char)[] function(ref T value)` -- static, typed, may
   normalise (rewrite the value through the ref) or reject (return the error). It sees
   `Parity.mark`, not a Variant. Instance-dependent validation does not belong here; that is
   `validate()`'s job, unchanged.
2. **Universal constraint**, inside `Element.try_write` -- min/max from the declaration, enforced
   in the data model for every writer (console, sync `set`, automation, internal code). This is
   the same enforcement point the element write path needs anyway for remote `set` on ordinary
   elements; property projection inherits it. Constraint also rides the `type` frame as UI/schema
   metadata, so remote UIs can range-check before sending.

**Variant is not part of that path.** It appears at exactly one place, and only because a Variant
is what genuinely arrives there: the by-name entry (`BaseObject.set`, hence the console, sync
inbound, and collection create) converts once to the declared type and joins the typed function.
The owner's `prop_write!(Type, name)` resolves its declaration at compile time and calls straight
in. Element's type-erased value currency is `Scalar`, not `Variant` -- `Constraint.check` already
takes a `Scalar`, and `Scalar.of(v)` stores a typed value into one -- so nothing in the
enforcement chain ever wanted boxing.

**And the machinery instantiates per value type, never per property.** Everything
property-specific -- element slot, check, on_change, format, read-only -- is data in the
`Property` table, and the get/set function pointers receive the `Property` they were reached
through (every call site was already iterating `properties()`, so the metadata pointer was
already in hand). Ten `uint` properties across ten classes share one `elem_set!uint`; the getter
is one function for the whole program, because boxing follows the element's runtime format. The
optional hooks are exactly the per-declaration residue: a `Check!` costs one thin shim restoring
the declared type from the erased pointer, an `OnChange!` target costs one trampoline shared by
every property that names it, and the one-shot format interner stays per-declaration because it
caches its `FormatId`.

Only then does the value commit to the element. A rejected write never touches the store and the
error string flows back exactly as setter error strings do today.

### Dedup, dirty, notify: free, and better

The element write path replaces, per setter, the hand-written:

- `if (_x == value) return;`      -> held-series dedup (equal write advances timestamps only,
                                     fires nothing)
- `mark_set!(T, "prop")()`        -> element dirty sweep + per-peer pending-EID sets
- per-channel `SyncState` bitmask -> dissolves entirely; the object mirror's
                                     `attach_delta_slot`/`props_dirty` machinery retires with it
- subscriber notification         -> `SampleUpdate` delivery with previous+new value and
                                     commit-scope coherence

A behavioural improvement becomes *available*, but is not free: because side effects are
subscriber deliveries, wrapping a multi-property command in a commit scope would coalesce them,
so `/interface/modbus/set inv baud=19200 protocol=rtu` would restart once after both apply
rather than once per property. Nothing collects that today -- the only `open_commit()` in the
tree is `ComponentLink.populate()`, and the console opens no scope around command execution, so
each set still delivers immediately and restarts independently, exactly as the old setters did.
Claim it by opening a scope around console command execution (and around the named-argument loop
in collection create), not by anything in the property machinery.

### Side effects: the real migration surface

Today's setters interleave three concerns; validation and commit are covered above. What remains
is side effects, and they become one of:

- **`OnChange!"restart"`** -- by far the dominant pattern; a declared hook the property table
  stores as a member-function pointer, invoked on actual change (dedup'd writes skip it, exactly
  as the early-return does today).
- **Self-subscription** -- the object subscribes to its own property element for anything richer
  (derived state like `_support_simultaneous_requests`, reference-swap teardown). The handler
  sees previous and new value in the update, which is more than today's setters get.

Deliberately NOT provided: an arbitrary imperative body in the write path. If a property needs
one, it stays on the legacy `Prop!` form until it can be decomposed.

### The special properties

- **`name`** -- identity, lives in the IdAllocator; rename is structural, not a value write.
  Never migrates.
- **`disabled`** -- drives the state machine bits directly; stays bespoke.
- **`type`** -- a per-type constant; schema, not state.
- **ObjectRef properties** (`stream=`, `iface=`) -- migrate early, not late. Storage is trivial:
  `EID(cid, 0)` in the 8-byte Scalar; the typed accessor wraps it back into `ObjectRef!T`
  semantics (table deref, null when tombstoned) and held-dedup is a raw compare. What is missing
  is edge vocabulary only: a fourth member of the DataFormat descriptor union
  (`const(CollectionTypeInfo)*` beside unit/enum_info/user_type) meaning "reference to collection
  type X", so `from_variant` converts name -> id at the console/sync edge, the wire carries the
  name (principle 1), and the write path type-checks the target's CID type bits. Bonus:
  `IdAllocator.reserve` means assigning a name that does not exist yet stores a reserved id that
  auto-binds on claim -- the structural fix the startup-latency TODO (base.d:33) asks for falls
  out of element-backed refs for free. The subscription-lifecycle pattern (unsubscribe old /
  subscribe new / restart) maps onto a change handler that receives previous+new.

### Derived state-machine views: the hard part

`running`, `status`, and `flags` are not stored values with dirty bits; they are pull-computed
views over the state-machine bits, and `mark_set` on them means "tell mirrors to re-read the
getter". An element is a push model: something must WRITE the value at the moment it changes.
The change sites are uneven:

- **`running`** is clean: `set_online`/`set_offline` are exactly the transition points; they
  become ordinary element writes.
- **`status`** is nearly clean: `status_message` is a pure function of `_state` (plus
  `_fail_reason`, which is always assigned before the transition that exposes it), so one write
  in `set_state` after the transition covers every site. Held dedup then makes the "probably
  over-dirty's" HACK comment precise instead of apologetic: redundant writes cost nothing and
  notify nobody. The state-transition *event* additionally lands as a `point` element, per the
  sync draft ("`state` becomes a built-in event node on every object"); `StateSignal`
  subscription becomes element subscription for consumers that only want online/offline.
- **`flags` does not migrate.** It folds in `validate()`, a live pull that can flip with no
  local event at all -- a referenced dependency comes into existence and nothing on this object
  runs. Note today's mirror is ALREADY stale in that case (no `mark_set` fires when a dependency
  materializes elsewhere), so a push element would lose nothing, but it cannot be made correct
  either without a write site that does not exist. `flags` is a presentation aggregate for
  `print`; it stays a legacy computed property and peers compose it from
  `status`/`running`/`disabled`.
- The constructor's `mark_set(name/type/flags)` seeding is initial-sync knowledge; it becomes
  configured-bit seeding, with the wrinkle that construction runs before collection insertion.

And one pre-existing sharp edge this migration steps on directly: **element teardown vs deferred
machinery**. `g_dirty_elements` and the pending-update queue hold raw `Element*`, and
`teardown()` purges neither. Today object death with elements is rare; property cells embedded in
every object make it routine, and an object destroyed inside a commit scope would leave freed
pointers in both lists. Either teardown unlinks from both, or property-element memory reaps on
the same deferred schedule as the object (`defer_free` already exists for exactly this ordering
problem). This is a prerequisite build item, not a footnote.

### `_props_set`, defaults, reset

`_props_set` conflates "explicitly configured" (config export, schema) with "changed" (sync
dirty). The dirty half dissolves into the element sweep. The configured half becomes one bit per
element ("written by a configurer" vs "holding its declared default") -- config export lists
exactly the configured set, as today.

Declared `Default!` replaces the synthesised `init_val` (which derives from the getter's return
TYPE's `.init` and is fragile by its own admission -- `assert_reset_matches_init` exists because
divergence "would silently desync mirrors"). Reset writes the declared default through the normal
write path: constraint-checked, dedup'd, change-hooked, and the sync `res` carries the applied
value, per the sync draft's authority-side reset semantics. The whole "receiver infers post-reset
value" fragility is deleted rather than fixed.

### Console and paths

`get`/`set`/`print`/`gather` walk the same `Property` table; for element-backed entries the
GetFun/SetFun are synthesized against the element instead of member functions. Names, categories,
suggest-completion, and the CLI surface are unchanged.

In the model space, properties appear under the object's node: `interface.modbus:inv.baud`.
Collections become namespaces (per the sync draft's convergence table), so the pattern grammar,
`sub`, `set`, and automation triggers (`on="@..."` element URIs) all apply to configuration for
free -- an automation can watch a config property with the same mechanism it watches a battery
voltage. This is an emergent capability, not extra work.

One wrinkle: `Element.parent` is a `Component`, and property elements have no component tree.
Path derivation for a property element must root at the owning object (container name from the
CID, segment from the property name). Either `Element.parent` generalises to an EID (id.d's
"paths resolve by composition" direction) or property elements carry a null parent and path
logic branches on container class. Decide when building; the former is the structural fix.

## Migration order

1. **Constraint enforcement in the element write path** + min/max/step/default on the `type`
   frame. Standalone, already a declared pending item on the sync branch, benefits ordinary
   elements immediately.
2. **Per-type property metadata**: `CollectionTypeInfo` gains FormatId/Constraint/default/hooks
   per property; formats interned at type registration.
3. **The element block on BaseObject** + `Elem!` declaration form + `mixin ElemAccessors` +
   synthesized element-backed GetFun/SetFun. Legacy `Prop!` untouched beside it.
4. **Element teardown unlinks from the dirty list and pending-update queue** (or reaps on the
   `defer_free` schedule) -- prerequisite for objects that die carrying elements.
5. **Migrate leaf value properties** class by class (baud, mtu, timeouts, booleans, enums,
   comment). Delete member fields, delete `mark_set` calls, declare `OnChange`/checks. Each class
   is a small, verifiable diff.
6. **The reference descriptor** (`CollectionTypeInfo*` slot in the DataFormat union + name<->id
   edge conversion), then ObjectRef properties; pending references via `IdAllocator.reserve`
   retire the synchronous-tick HACK.
7. **State machine writes `running`/`status`/state-event as elements** (see the derived-views
   section; `flags` deliberately stays behind). Last of the migrations because the change sites
   are lifecycle-entangled. These are the first real `ReadOnly` users: the state machine pokes,
   the operator reads.
8. **Retire the per-object property sync machinery**: `SyncState`, `attach_delta_slot`,
   `props_dirty`, `_props_set` dirty half; the object mirror's property verbs dissolve per the
   sync draft's convergence table.

## Costs and open questions

- **RAM on TINY targets.** The descriptor split (above) is the answer to Element's ~104-byte
  weight: property cells land near 48 bytes and profile elements shrink too, so a modest object
  population costs ~25KB rather than ~50KB, partially repaid by deleted member fields and the
  retired `SyncState` array. Still worth a real measurement on the BL808 profile before step 5
  proceeds far -- sibling sync is precisely the BL808 case, so compiling property elements out
  under TINY forfeits the point.
- **Getter cost.** A field read becomes an indexed load + Scalar reinterpret. Irrelevant at 20Hz
  control rates; only worth thought if a property read lands on a packet path (none do today).
- **Startup ordering.** Writes apply eagerly and deliver lazily, so `validate()` reading freshly
  set properties inside the startup-script synchronous tick still sees applied values. But
  OnChange-by-subscription defers `restart()` to end of commit; the interaction with the
  synchronous-tick HACK in collection_commands.d (base.d:33 TODO) needs a test the moment the
  first migrated class lands.
- **Normalising checks vs wire acks.** The check lambda may rewrite the value; sync `set` must
  ack the APPLIED value. The sync draft already specifies exactly this (`res {seq, value}`), so
  the two designs agree; just do not ack before the check runs.
- **Property categories/flags** (`*`, `d`, `h`) carry over to the `Elem!` form unchanged; they
  are presentation metadata and orthogonal to storage.
