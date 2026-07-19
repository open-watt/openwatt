# TODO

Design-level work items. Inline TODO/HACK comments track point fixes; this file tracks
cross-cutting issues that need a design decision or touch multiple systems.

## Energy

- **Topology publisher bind is O(paths x siblings)**: `TopologyPublisher.bind()` re-runs
  `find_or_create_element` for every field of every record (~3000 dotted-path lookups, each a
  linear sibling scan per segment, plus a tconcat/makeString per field) - ~106ms per rebuild on
  the Pi. Rebuilds are rare again so it's latency noise, but it should be microseconds: reuse
  cache entries whose ids didn't change and only resolve new/removed records (diff-based rebind),
  or give Component a keyed child/element lookup.

- **Session-delta SOC floor, remaining work**: v1 landed (session.d: incremental accumulation of
  the delivering EVSE's import counter, soc_floor = delivered * 0.88 / capacity, published on
  the vehicle and picked up as the soc(N) witness). Remaining: persist the session across
  OpenWatt restarts (currently re-seeds at 0 - conservative but loses progress); VIN-less cars
  with a STATIC pairing (mg_zs via car=mg_zs) can key sessions by appliance name instead of VIN
  (the binding asserts identity that VIN-discovery would have provided; needs a vehicle-store
  entry keyed by appliance name to carry soc_floor); truly unknown cars get EVSE-scoped policies
  only (surplus soak / duty goals - soc is meaningless without identity); real SOC via Tesla BLE
  supersedes the estimate when it lands; feed (delivered, soc-delta) samples into the capacity
  estimator once real SOC exists.

- **Integrated import/export counters (stateful meter completion)**: nodes without cumulative
  energy counters should get them by integrating active power. Unlike the existing stateless
  per-sample synthesis in `get_meter_data`, this needs persistent per-port accumulators and a
  MonoTime timebase, updated where port meter data is refreshed; results feed back in as
  total_import/export_active with a new `Provenance.integrated` and publish onto the node as
  elements (the "artificial energy meter"). Semantics: counters restart at 0 on boot (consumers
  must anchor-delta, never read absolute), skip integration across stale samples (gap
  threshold), keep them out of the recorder by default.

- **Surplus-tracking, remaining work**: v1 landed (opportunistic policies capped at
  draw + signed grid surplus at the path's source bus, consumed from a per-bus pool in rank
  order; setpoints step-quantized against meter jitter). Remaining: VERIFY the grid-port sign
  convention live (a flipped meter sign reads export as import and opportunistic never drives);
  floor/essential still drive flat-out - modulate from planner required_kwh/slack; hysteresis is
  only step-quantization + dwell guards, watch for churn under fast-moving clouds; the
  `pressure_modifier` gate on opportunistic marginal value is now redundant with the hard
  surplus cap - remove it.

- **Stale allocation reasons**: `record_decision` only runs for policies that made the queue, so
  a policy whose marginal value drops to 0 keeps displaying its last recorded reason forever
  (misleading during debugging). Record an explicit "satisfied"/"idle" reason for non-queued
  policies each tick, or expire the elements.

## Tesla TWC

- **Release semantics, remaining work**: landed - master floors delivered current at 5A
  (charge_current getter), binding publishes can_disable=false, allocator actuates a separate
  enable_e on drive/release (release: setpoint=min then enable=false). Remaining: the car-side
  BLE `charging` element that becomes enable_e via pick_enable_element - until it lands,
  "satisfied" trickles at 5A (~1.25kW), so satisfied night-time rules still draw grid.
  Appliance/master disable remains an explicit hard-off only (see recovery below).

- **Recovery reworked, verify on hardware**: link flaps no longer reset chargers - the master
  just resumes heartbeating with all latched state intact. First bring-up plays the ~4s announce
  ceremony once, then optimistically adopts all configured chargers (specified_max_current is
  the clamp until SlaveLinkReady refines device_max); a stalled slave re-arms its heartbeat
  counters and keeps being polled instead of de-adopting into the minutes-long LinkReady wait.
  UNVERIFIED protocol assumption: slaves answer master heartbeats without having seen our
  announce (believed true from TWCManager lore); if wrong, the failure mode is just unanswered
  heartbeats until the slave re-announces on its own timeout - same as the old behaviour.

## Zigbee latency and robustness

1. [ ] **Validation metrics**: expose queue wait by PCP, deadline promotions and expiries,
    queue rejection and DEI eviction counts, reserved-slot dispatches, user-command
    submission-to-completion latency, and reactive receive-to-dispatch latency.

## Automation

The as-built record lives in [docs/AUTOMATION.draft.md](docs/AUTOMATION.draft.md) (implementation
status block). Remaining legs, roughly in order:

1. [ ] **Execution policy**: `overrun=skip|queue|restart|coalesce`, `catch_up=skip|once|all`
   (+ grace window), `on_error=ignore|retry|disable`. Today concurrent runs simply stack in
   `_running_commands` (inherited accidental cron behaviour), and the only catch-up semantic is
   cron's hard-coded fire-once clamp on a missed deadline plus wall-clock re-anchoring - neither
   suppressible nor multipliable.

2. [ ] **Typed `$trigger.*` context**: only the flat `$value` exists. Decide flat locals ($prev,
   $topic, ...) vs a `$trigger` object local (expression getMember walk already supports it) when
   the first provider with rich payloads (mqtt) lands.

3. [ ] **More providers**: mqtt (filtered publish), zigbee (attribute report), sun
   (sunset/sunrise with offsets - needs an astronomical calc), http. Each is a module-registered
   ISignalProvider; the engine needs no changes.

4. [ ] **`on=` completer**: 5th `Prop!` param + `Property.completer` + the collection_commands
   hook; ISignalProvider gains a complete/suggest capability (scheme completed from the registry,
   body and param values by the provider). Deliberately last.

5. [ ] **Event-driven element attach**: a rule referencing a not-yet-created element parks in
   Starting re-running startup() each frame until subscribe succeeds - observable and correct,
   but true event attach means notify_element_created revisits signal subscriptions instead of
   frame polling.

6. [ ] **Re-entrancy / loop guard**: automations both subscribe to and write elements; only
   value-change damping breaks cycles today. The `who` cookie exists on `Element.value()` but no
   caller passes it and the OnChangeCallback subscriber list never filters by it (element.d has
   the TODO). Design doc wants writes tagged with the originating rule plus a bounded re-entrancy
   guard. Related: `/element/set` silently updates the local value of a read-only element - it
   should surface "target is not writable".

7. [ ] **`?deadband=` trigger param**: the automation surface of the element deadband design -
   see Data model below.

8. [ ] **Energy pivot**: the propose/dispose action surface - rules express intent to a
   `Control`'s request surface and the allocator arbitrates contended outputs; energy `Policy`
   goals then migrate onto automations while the allocator keeps ownership of contended
   setpoints.

## Data model

- **Unit model gaps exposed by profile normalization (2026-07-19)**: decide how the type/unit
  language represents logarithmic reference-relative quantities such as dBm. dBm is power
  relative to 1 mW with a logarithmic encoding, not an ordinary milliwatt scale prefix, so it
  needs an explicit conversion and arithmetic story rather than being accepted as a cosmetic
  unit string. Also support distinct arbitrary units for counters so unrelated counts cannot
  mathematically combine merely because both are dimensionless. Bytes (`B`) are an important
  first case: settle byte versus bit identity and SI decimal prefixes (1000) versus IEC binary
  prefixes (1024), including unambiguous spellings such as kB versus KiB, before folding these
  units into normalized profile type descriptors.

- **Audit binding sampling strategies; consolidate value handling into ONE module (noted
  2026-07-17)**: every protocol grew its own decode/convert/apply machinery and the sprawl is
  now countable: `sample_value(void*, ValueDesc)` (modbus/can/goodwe/ble), `sample_value(char[],
  TextValueDesc)` + `format_value` + `apply_value` (mqtt/http), `get_zcl_value` + `adjust_value`
  (zigbee's parallel decoder), `sample_sunspec_value` (sunspec), ESPHome's typed proto decode,
  Tesla TWC's direct field push, expression `evaluate` -> Variant, and now `box_record` /
  `unbox_scalar` at the series edge. Review ALL bindings' sampling strategies (batching/timing
  policy too, not just decode) and converge the value path on a single value-handling module:
  wire shape descriptor in, native record out, one boxing edge, one write/format inverse
  (encode/decode symmetry in one place instead of eight). The type registry design (see
  DATA_MODEL.draft.md section 6) already points here - two description LANGUAGES (binary vs
  text profiles) may remain, but the runtime TARGETS converge on wire-desc + DataFormat with a
  Variant-free `sample_record(wire, desc, out_bytes, DataFormat)` path; this entry widens that
  to an explicit audit of every binding so per-protocol special cases (zigbee's adjust_value,
  sunspec's decoder, HTTP's apply_value) either justify themselves or dissolve into the one
  module. Natural sequencing: fold in as the per-protocol native-producer migration completes
  (text protocols + modbus are the remaining producers; do the consolidation as/after they
  migrate rather than bolting a ninth machine alongside the eight).
  SETTLED SHAPE 2026-07-18 (scrutinised to fixpoint with Manu; supersedes the earlier axes
  sketch). MODEL: value = atom x extent. atoms = machine scalars (bool, u8..s64, f32, f64,
  char_) + user (registered type; identity via TypeDetails* in the format's descriptor slot,
  which becomes the enum_info|TypeDetails* union). extent = one | fixed N | dynamic; count
  lives in DataFormat (stride = count x atom), dynamic extent's length rides IN the record.
  ValueType.variant and string_ DELETE: string = char[] (char_ x dynamic), blob = u8[]
  dynamic with opaque display - grammar spellings, not atoms; vectors are format-count, not
  atoms. FACTORING PRINCIPLE (becomes series.d's header): a series factors each value into
  the constant part (DataFormat) and the per-sample part (record bytes); records are
  context-free, boxing is the REUNION (box_record marries bytes back to their format -> self-
  describing Variant). f32 voltage = f32 atom + unit-in-format; Quantity/enum names
  materialise only at edges; a dynamic-unit quantity would be user (no customer). STORAGE
  RULE: a record is memcpy iff its record type is trivial, else copy_emplace/destroy hooks -
  dynamic records hold immutable refcounted handles (String for text: decode mints ONCE,
  series record + boxed mirror + observers + sync all share refs; compare-before-mint so
  steady-state repeats never allocate; blob's RC-buffer twin waits for a customer). Scalar =
  <=8-byte fast-path register only; the gateway currency is (const DataFormat*, void[])
  record views; RecordBlock stays storage furniture. series.d REORGANISED in the same pass,
  reading order: principle header -> ValueType + storage rules -> interpretation vocab
  (Semantics/ClockDomain/Constraint) -> DataFormat -> Scalar -> RecordBlock -> retention ->
  Variant edge last. TYPEREG: stringify is already bidirectional (do_format flag) - no parse
  slot needed; ADD a variant-marshal override slot (one slot, both directions), default null
  = structural boxing ((type_id, payload) via copy_emplace, which Variant already does);
  override for types whose Variant surface differs from their payload - CID/EID box as the
  object/element NAME string and unbox by hashing it back (keeps ids off Variant-visible
  surfaces); handlers registered by manager code may reach collection context. JSON stays
  derived (numbers/bools raw, else stringified+quoted, arrays structural); no per-type slot
  until the RPC consolidation forces one. ALSO ADD byte_swap (member-recursive endian flip;
  urt.endian's endianToNative/nativeToEndian ALREADY synthesise this for arbitrary pod T -
  tupleof recursion, static arrays element-wise, pointers/classes static-assert - so the
  slot is a thin per-T instantiation, no new reflection; null for non-pods/serialise-
  overriders = "type owns its encoding", _be on those is a grammar error; union-bearing
  pods should static-assert into declaring a serialise pair rather than flat-flipping the
  union blob). This is the endian axis's
  SECOND EXECUTOR: scalar atoms byte-reverse via the flat swizzle, user atoms via td.
  byte_swap (flat reverse would scramble member boundaries) - one grammar axis, two
  executors picked by atom kind; composes AFTER transport swizzle (wire_image -> memcpy ->
  flip), since register presentation and member endianness are physically independent
  vendor behaviours. wire.d stays bytes-only and closed. NO LE-HOST ASSUMPTION: the flip
  condition is wire-member-endianness XOR host-endianness (not "_be present"); wire.d is
  value-space via loadLittleEndian/store so arch-neutral; gateway + pod-serialise sites
  pick memcpy vs byte_swap with a static version branch (byte_swap fuses copy+reverse, so
  BE hosts pay one op either way). ENCODINGS: named codec registry
  per wire class,
  seeded by registered types (pod LE image / serialise pair; stringify pair for text),
  extended by bespoke encodings that output values of REAL types - dt48_yymmddhhmmss decodes
  to a genuine timestamp; encoding names live only in grammar + compiled desc, never produce
  shim types in Scalar/Variant. Kills CustomSample's Variant signature, DateFormat-as-
  mechanism, and TextType's macaddr/inetaddr/ipaddr/ip6addr arms (registered urt.inet types).
  WIRE LAYOUT: mechanical, closed, BIT-GRANULAR. Compiled word (as built in wire.d):
  {kind(3), bit_width-1(6), bit_offset(6, container-relative so 64 caps it), flags(3:
  swap_words/swap_word_bytes/reverse, all involutions sharing one index mapping),
  word_shift(2), container(4)} + count(u16) + pre_scale(f32) + DataFormat* + codec ref
  beside it (~20-24B/point: profiles with thousands of elements pay no strings, no
  re-parse). Any width 1..64 (u3@5 legal, s12@4 sign-extends); pipeline = context+overrides
  swizzle to canonical LE image FIRST, then extract [offset, offset+width),
  so bit numbering is LSB=0 of the logical value, datasheet-style. Subsumes low_byte/
  high_byte (u8@8/u8@0), coils (bool@n), DBC-style signals. CONTAINER (discovered by T3's
  first test failure): a bit slice's span does not reveal the storage unit it slices - bits
  5..7 of a BE register live in the SECOND wire byte, so reversed containers need explicit
  extent; WireLayout carries container_bytes (0 = derive minimal span, word-rounded when
  worded), and the grammar compiler defaults sliced fields to the context word. DECOMPOSED-REGISTER idiom:
  several elements each carry their own desc over the SAME wire window (batcher already reads
  once) - a status register is ONE bf element or decomposed bool@3/u3@5 elements, author's
  choice, same grammar. LayoutContext per protocol {byte order, word size, word order},
  profile-section overridable; grammar is type-first, deviation-only mods, with STRICT
  separator semantics: `_` = closed layout-mod vocabulary (mechanical, layer 1, never
  user-extended; mods are CONTEXT-GATED and name PHYSICAL device behaviours, not abstract
  endianness coordinates - WORDED contexts (modbus: payload = byte array of normally-BE
  words, multi-word order undefined per device) offer exactly _bs (byte-swap within word)
  and _wr (word order swapped vs context), so the quartet = u32/u32_wr/u32_bs/u32_bs_wr =
  ABCD/CDAB/BADC/DCBA and true-LE-value is honestly spelled _bs_wr (LE memory image,
  lo-word first); _le/_be are ILLEGAL in worded contexts. BYTE-STREAM contexts (CAN/BLE/
  flat) offer only _le/_be (value endianness vs context default); _bs/_wr illegal there.
  _sp (space-padded strings) valid anywhere; max one mod per axis, any parse order; decode
  = word order -> byte swap -> canonical LE image -> interpretation. str8_bs = the
  swapped-chars-in-words device (EHLL!O -> HELLO!, the old str8_r); str8_bs_sp /
  str8_bs_wr_sp compose), `:` = open registry-name reference (semantic: enum/bf
  sections, encodings, registered types, layer 2), `@` = bit position, [N] = count. Shape:
  <family><width>[_mods][@bit][:name][[N]] - s16, u32_wr, u32_bs_wr (modbus), u32_le
  (byte-stream), bool@3, u8@8, str8,
  enum16:mode, bf16:alarms, dt48:yymmddhhmmss (parallel to enum16:mode; dt48_wr:yymmddhhmmss
  composes), u8[8]; bare registered types sit in TYPE position (macaddr, macaddr_wr) since
  the type owns its wire form - `:` attaches interpretation to a raw field, absent when the
  type is the meaning; bless s* over i* (i* parses as alias until T9 sweep).
  value.d folds: struct_name_override deletes, type_for!T = registry-namespace projection,
  parse/format arms delegate to typereg via the gateway; residue = collection-context lookups
  + structural combinators (arrays, Nullable), renamed as the marshalling veneer it is.
  Sampling STRATEGY (batching/timing/poll) stays with bindings. Serialisation contract
  (landed in typereg): LE memory image default, serialise pair overrides, mandatory non-pod.
  TRANSFORMATION SEQUENCE (each shippable; T1-T4 parallel foundations; ALL FOUR LANDED
  2026-07-18, 98/98 unit tests): T1 typereg variant-marshal + byte_swap slots (byte_swap =
  fused copy-and-reverse via urt.endian reverse_endian(src,dst), aliasing-tolerant); T2
  series.d re-founding (atom x extent + reorg, above; ValueType.variant/string_ deleted,
  char_/user + descriptor union + count landed, box_record user arm dispatches td.variant,
  element/element2 scalar checks moved to fmt.is_scalar; DESCRIPTOR FOLD: unit joins the
  union - unit/enum_info/user_type are mutually exclusive - user_type selected by
  type==user (atom = storage truth, keeps type-driven predicates total), unit-vs-enum by a
  Desc kind byte {none,quantity,enum_}; count is ubyte (the 255-byte stride cap already bounds
  it) so type/semantics/desc/count/rate pack the first 8 bytes exactly: 48->32B, zero
  padding; ctors stamp the kind so construction is self-discriminating and dimensionless =
  none; typereg slot named byte_reverse); T3
  WireLayout+LayoutContext module (port sampler.d's test vectors); T4 codec registry
  (manager/codec.d: Encoding table {name, wire_bytes, DataFormat, binary decode/encode +
  text parse/format slots}; register_builtin_encodings() called once from Application
  startup before module init - no lazy flag, double-registration asserts by name;
  registered types get NO entries - grammar resolves bare names via typereg, the
  table holds only non-canonical wire forms; first customer yymmddhhmmss -> DateTime
  records as user atom, proving T1+T2 end-to-end; structural runtime user boxing still
  gateway work - Variant has no (td, payload) ctor yet); T5 gateway LANDED 2026-07-18
  (99/99): manager/sample.d - SampleDesc {WireLayout, mutable pre_scale, ushort format +
  encoding indices} = 12B/point (par with old ValueDesc); GLOBAL format mint (dedupe
  config-time-cold linear scan, runtime O(1) by index, formats' durable home - resolves
  the mount-outlives-binding note; profile mint delegates, per-profile format ownership
  deleted); sample_record/emit_record three arms (scalar hot path via wire_extract +
  pre_scale, encoding arm via wire_image + codec, user arm via fused
  memcpy-or-td.byte_reverse chosen by members_be XOR host), parse_record/format_record
  text mirrors (legacy semantics: bool true/1/on, enum name-or-number in / number out),
  sample_text transient view (padding strip, mount mints the String); WireFlags grew
  members_be + space_padded (flags 5 bits); wire_image generalised to shift/mask index
  map incl whole reverse (encodings need it; text still never does). REMAINING in-flight:
  Variant (td,payload) structural ctor; vectors return false pending first producer.
  T6 grammar compiler LANDED 2026-07-18 (100/100): manager/spec.d compile_spec(spec, ctx,
  unit, pre_scale, enum_info, resolver) -> SampleDesc; LayoutContext {word_bytes, word_be,
  words_hi_first, stream_be} with modbus/stream presets, context base flags via rev =
  word_be, sw = word_be XOR hi_first; families bool/u/s/f/enum/bf/enumf/str/dt/bare-name,
  slices, counts, legacy aliases (i* = s*, glued le/be = ABSOLUTE endianness, _r =
  word-swap on scalars but byte-swap-in-word on strings - old DataType.word_reverse meant
  DIFFERENT ops per kind). REFINEMENT discovered in the build: byte-image families
  (str/dt/user) have NO value endianness - reading order IS canonical for byte data, so
  encodings read fields at absolute positions (codec image convention flipped to reading
  order) and the context's BE-ness never touches them; enumf32 = float wire feeding
  integer records, gateway grew the cast branch. NEXT: T7 per-protocol cutover (bindings
  swap ValueDesc -> compile_spec/SampleDesc, easiest->deepest) ->
  compact descs, old spellings as aliases (no conf changes); T7 per-protocol cutover
  easiest->deepest: CAN -> GoodWe -> BLE -> zigbee (ZCL table -> compiled descs, adjust_value
  folds in) -> MQTT/HTTP (encode mirror absorbs format_value/apply_value) -> SunSpec (runtime
  pre_scale wrapper, f64 records) -> ESPHome (typed values: DataFormat + native observe, stub
  resolved) -> modbus client -> modbus serve; CAN LANDED 2026-07-18 (ElementDesc_CAN =
  SampleDesc + span byte - byte-stream maps carry the wire span the desc doesn't;
  legacy two-column spellings [enum name / dt format in the units column] translate to
  `:name` refs at the parse site; Element/Element2 grew the untemplated observe_record
  scalar path; packet path decodes via the gateway - native record when the mount is the
  binding's format, boxed otherwise). GoodWe LANDED 2026-07-19: GoodWeModule owns the
  registered `aa55` section,
  ElementDesc_AA55 lives with the binding, and the response path decodes through SampleDesc;
  the AA55 context is big-endian by default, so the normalized gwxx48es profile carries only
  deviations and folds units/enum/encoding names into the type token. The conf sweep exposed
  and fixed split_element_and_desc treating the first colon as `desc:` rather than recognizing
  the actual whitespace-delimited field. Legacy and normalized profiles both passed runtime
  materialisation; 101/101 unit tests. BLE LANDED 2026-07-19: BLEModule owns the registered
  `ble` section, UUID/offset parsing and ElementDesc_BLE moved into the protocol, and notification
  sampling runs through SampleDesc with the byte-stream little-endian default. Bare standard
  UUIDs (`180F`, `2A19`) now parse as hexadecimal, matching normal BLE profile spelling. Legacy
  two-column and normalized numeric profiles both passed runtime materialisation; the speculative
  Xiaomi profile is normalized, with its unsized variable GATT strings deferred until real `strN`
  bounds are known. Zigbee LANDED 2026-07-19: ZigbeeProtocolModule owns the registered `zb`
  section; ZCL compiles in the byte-stream little-endian context and Tuya datapoints in the
  big-endian context. Attribute reports and Tuya reads/writes now pass through SampleDesc, while
  the Tuya wire type remains in ElementDesc_Zigbee because an anonymous enum8 and u8 otherwise
  have the same DataFormat. Bare `str` is protocol-framed dynamic text with zero descriptor wire
  span: the ZCL/Tuya hook removes its framing and observes the character payload into the native
  String record. Fixed-layout CAN/GoodWe/BLE profiles reject bare strings and require `strN`.
  Both the legacy and normalized Zigbee profiles passed runtime materialisation. DT SETTLED
  2026-07-18: DateTime is a presentation face - no typereg
  entry, never serialises; Variant's user-ctor gate converts DateTime -> SysTime on entry
  and as!DateTime converts back at display; the "dt" registry name is solely SysTime's
  (was doubly claimed, order-dependent); SysTime grew a unix-ns LE serialise pair (tick
  image is platform-epoch: FILETIME on Windows) and a to_variant/from_variant marshal;
  the yymmddhhmmss codec outputs SysTime records; is_scalar widened to trivial user pods
  <= 8 bytes so dt elements mount and record natively through the Scalar register
  (unbox_scalar user arm via the marshal). Structural boxing RESOLVED 2026-07-19:
  TypeRecordFor synthesises the variant slot for value-pure payloads (ValidUserType,
  no indirections, copyable - the guard must not instantiate Variant machinery, records
  build from inside Variant's own ctor and an eager compiles-check collapses under the
  cycle), so no runtime (td, payload) ctor is needed and SysTime carries no hand-written
  marshal; to_variant/from_variant members remain the OVERRIDE for
  surface-differs-from-payload types (CID/EID); indirection-bearing types keep a null
  slot (they need the copy-hook story to ride records at all). Visible delta:
  dt values print the SysTime face
  (trailing Z). Bare-dtN rule (settled 2026-07-18, UNWIRED - no profile customer):
  width implies the unit - dt32 = unix seconds (only sane 32-bit reading), dt64 =
  unix-ns = SysTime's canonical image (serialise pair, no encoding entry); deviations
  are named encodings when customers arrive (dt64:unixms, 2000-epoch seconds e.g.
  Zigbee UTCTime); CAVEAT dt32 is value-shaped (seconds count takes context value
  endianness, scalar flags) unlike dt48's byte-image fields - Encoding grows a
  value/byte-image discriminator when wired. PROFILE EXTENSIBILITY CORE LANDED
  2026-07-18: three central type-spec tables - formats (T5), descs (mint_desc/
  desc_by_index: immutable 12-byte SampleDescs content-deduped, elements hold a ushort),
  enums (register_enum_info/find_enum_info: name-keyed `profilename.MyEnum`, registry
  OWNS allocations = the durable home; unchanged reload frees the duplicate via
  enum_info_size/enum_info_equal, changed content rebinds while the old block stays
  alive for mounts; g_app.enum_templates DELETED, D-native enums register owned=false,
  profile parse no longer touches g_app so enum profiles unittest). ProfileSections
  interface + register_profile_section(name, handler) -> kind (>= 16; ElementType lost
  `can`, `aa55` and `ble`, ElementDesc unpacked to kind/index fields), two-pass count_element/
  parse_element against ProfileBuilder {compile_value = the shared language incl the
  legacy two-column translation, find_enum, intern -> section_strings}; Profile grew
  SectionBlock storage + get_section!T; parse_profile takes the profile name (file
  basename) for qualified enum registration. Grammar grew unit-in-colon (`u16:0.1V` -
  the family selects the `:` namespace, so unit/enum collision is structurally
  impossible). CAN retrofitted as the first registered section (ElementDesc_CAN lives
  in protocol.can.binding, the module implements the interface, profile.d's arm
  deleted). REMAINING: mb/zb/http/mqtt arms move out as their T7 stops land;
  http `requests:` / mqtt subscribe lists need the root-section method pair when those
  two migrate; sampler.d EMPTIES at T7's end (sample_value x2,
  format_value, ValueDesc, TextValueDesc, DataType, DataKind, DateFormat, CustomSample,
  TextType, bool both-endian hack all delete). The column following type is repurposed as
  access (`R`/`W`/`RW`, omitted = read): ProfileBuilder recognizes those exact tokens first,
  otherwise temporarily translates the old units/enum meaning; after the final profile sweep,
  delete that translation and the legacy `/R`/`W`/`RW` suffix. T8 value.d fold + rename;
  T9 conf sweep + one grammar doc
  (the bitfield-index convention decision lands here). NOT in scope: boxed-
  mirror/consumer migration (separate track), retention tiers (build step 3), RecordBlock.
  Enum slice LANDED 2026-07-18: DataFormat carries the enum descriptor (one pointer, becomes
  the enum_/user_/string_ union with the registry), series_format maps enums/bitfields to
  their raw integer width (enumf32 casts at sample time), boxing goes through
  Variant(raw, enum_info) so names survive; text enum_/bf ride the same path (s64).
  Bitfields LANDED 2026-07-18: flag-ness is a property of the ENUMERATION, declared at the
  declaration site (@bitfield UDA for D enums, read by enum_info!E so Variant auto-boxing
  stays consistent; profile << shift syntax stamps it, explicit bitfield: keyword forces it;
  register_bitfield!E asserts the UDA). VoidEnumInfo.bitfield drives everything: shared
  parse_flags/format_flags (exact key wins so compound keys like all=0x7 print as
  themselves, then bitwise decomposition, hex residue for unknown bits; parse accepts
  key1|key2|0x8), Variant.toString now prints enum keys and flag combinations (console-only
  change - JSON wire keeps numbers), table.d's linear-scan HACK deleted, sampler's inline bf
  loop deleted. Usage kinds (bf16, TextType.bf) are no longer sources of truth. Deliberately
  NOT done: synthesising flag combinations for UNdeclared enums (an unknown scalar value 3
  printed as one|two would mislead; honest number instead).

- **Bitfield profile conventions (proposed 2026-07-18, Manu to resolve)**: survey found TWO
  authoring conventions in conf/ - mask-valued members (pylon, gwxx48es: `1 << n`, stamped
  correctly) and BIT-INDEXED members (pace_bms WarningFlags/ProtectionFlags/StatusFaultFlags/
  BalanceStatus, smartevse ErrorFlags: `cell_ov: 0, pack_ov: 2` = datasheet bit numbers). The
  indexed ones have been semantically dead all along: raw register values never match
  index-valued keys, so display always fell back to the bare number. Proposal: (1) `bitfield:`
  sections declare members BY BIT INDEX (plain integer = bit number, the datasheet
  transcription convention; parser converts to masks and sets the flag; `1 << n` inside a
  bitfield: section remains a literal mask for compound members); (2) `enum:` sections
  unchanged (values are values; shift syntax stamps); (3) migrate pace_bms + smartevse to
  `bitfield:` - CAVEAT: changes those members' VALUES (index -> mask), so grep profiles/conf/
  automations for key references before touching (expressions comparing against those keys
  would shift meaning); (4) parse-time warning when a bf-kind register references an enum not
  flagged bitfield (covers literal-mask-under-enum: declarations without value heuristics that
  would misfire on scalar power-of-two enums). Taste call to bless: bitfield: reading plain
  values as indices makes the two section types read values differently.

- **Element retention/recording profile grammar (proposed 2026-07-19, Manu to resolve token
  shape)**: the retention CORE is built (series.d/element2.d): min/max per axis - floors
  (min_records/min_age) keep records even after consumption, for rendering; PINNED cursors
  (open_cursor(from, pin=true)) extend retention until the consumer advances past (consumption
  IS the discard mark - a 433 signal processor just reads); ceilings (max_records/max_age)
  force eviction past stalled/undriven pins, lapped cursors report RecordBlock.lost.
  Element2.retention(min_records, max_records) + retention(min_age, max_age). Byte budgets
  TODO (== records * stride until variable-stride records land). DEFAULT RULE implemented in
  device.d apply_default_retention: every native-mounted element that is not constant/config
  sampling gets history (min 256 records, 1h window, 16k ceiling; named constants) unless a
  binding already configured it. REMAINING - profile agency: (1) element-level override tokens,
  proposal: named k=v trailer on the element line or desc, `keep=` floor / `cap=` ceiling,
  value type by suffix (bare int = records, duration suffix = age, repeatable for both axes),
  `record=none` opts out; (2) component/profile-level defaults inherited by children;
  (3) recorder tie-in: record-to-disk intent is a SEPARATE flag from RAM retention (recorder
  becomes a pinned cursor consumer at step-3 slice 4). Token shape should land with the T9
  grammar doc, not before (T7 agents own that grammar surface right now).

- **Commands / device logic in profiles (design 2026-07-16; the ancient "commands" TODO's
  answer)**: the missing write/control facet - how a state-element write becomes a transmitted/
  written protocol action, INCLUDING stateful logic (toggles: only fire if desired != current).
  Today this would live as per-device binding code. Proposal: **bring the automation/expression
  engine down into profiles** so device behaviour is data-driven. Invents almost nothing - reuses
  the expression evaluator (`@`-refs, arithmetic, funcs; expression.d), the automation `on/if/do`
  shape, and Element2 change events. Three layers:
  1. **Actions as generative expressions**, not static captures. An action computes its payload
     from managed state:
     `action light = ook(addr=df258, button=7, counter=$seq, check=$seq ^ 7 ^ 7)`
     `action speed = ook(addr=df258, button=$b, counter=$seq, check=$seq ^ $b ^ 7)`
     where `$seq` is a per-device managed counter the binding advances each emit (protocol-
     specific rolling counter), and the checksum is deterministic. Captures the whole protocol
     once; every transmission generated fresh (not replay).
  2. **Elements in the component template** = the state model (fan.speed, light.on, ...).
  3. **Element-change scripts carry the logic** - the automation `if/do` scoped to a device:
     `on fan.speed : play(speed[$value])`                         # absolute
     `on light.on  : if $value != @light.on then play(light)`     # toggle: fire only to change
     Solves the toggle problem (know current state before commanding a toggle) in two profile
     lines, no binding code.
  GENERALISES past RF: "on element change, invoke a named action with logic" is protocol-
  agnostic - the action is an OOK expression for RF, a topic-write for MQTT, a register-write for
  Modbus. So `action`/`play` IS the general commands primitive the write-binding/sink model lacks;
  profiles become where device control is authored regardless of transport. SYMMETRIC for RX:
  `on rx(button=7): @light.on = !@light.on` expresses decode->state (physical-remote-follows-us
  sync) in the profile too. Scope: profile parser grows an expression/script layer; define a
  DEVICE-SCRIPT EXECUTION CONTEXT (access to `@`-elements, the `play(action)` primitive, per-device
  managed state like `$seq`). Less "new subsystem" than "point the automation engine at the device
  layer". First customer: the RF433 fan (drafts conf/rf_profiles/brilliant_22034.conf +
  src/protocol/rf433/package.d; Brilliant 22034 protocol fully reverse-engineered - see
  memory/pi_433_wiring). Ties to: profile FUNCTIONS facet in the data-model redesign, automation
  Phase 3 ($trigger context / typed action surface), and the GpioBinding signal-generator (TX).

- **Data model / observation fabric redesign (settled 2026-07-15; full design in
  [docs/DATA_MODEL.draft.md](docs/DATA_MODEL.draft.md), identity in
  [src/manager/id.d](src/manager/id.d) header)**: typed element series (buckets, observers +
  cursors, retention tiers, clock domains), series contract module shared by elements and
  taps, operators absorbing Map/Sum/Alias (fixes accumulator integrating blind across gaps),
  property projection (every Prop! semantically an element, physically lazy), Event! and
  profile FUNCTIONS as the missing facets, Device-as-BaseObject via composition (kills
  is_device trap), mesh trajectory (config authority is the new subsystem). Build order in the
  doc; ID migration steps 0-2 LANDED 2026-07-17 (see Infrastructure entry below). Series
  contract module EXTRACTED 2026-07-17: manager/series.d holds the host-agnostic vocabulary
  (DataFormat/ValueType/Semantics, Constraint, ClockDomain, Scalar, RecordBlock, SeriesEvent,
  Bucket/SeriesStore), organised for all three facets (Event! payloads and device-function
  params/results will use the same DataFormat vocabulary); element2.d keeps the mount-point
  machinery (Element2, Observer/Subscription, Cursor, dirty list). Both build systems updated.
  Mount step LANDED 2026-07-17: Element embeds Element2 - the mount keeps identity/metadata
  (id/name/desc/display_unit/access/sampling_mode/parent) plus the boxed Variant mirror
  (latest/prev/recent/subscribers); a null or indirect format means legacy (bit-identical
  behaviour for every existing consumer), a scalar format makes the mount native: boxed
  writes unbox into the core (series.unbox_scalar), native observe!T/observe_block/mark_gap
  on Element feed the series then mirror the tail into the boxed path (legacy subscribers,
  prev pair, recent ring see the same timeline). Boxing edge implemented in series.d
  (box_record/unbox_scalar, RecordBlock.box, Element2.value; ints/floats wrap format.unit as
  Quantity). GpioBinding mounts its series on the device element (element= prop, default
  "state"; materialise() hangs it, shutdown marks a gap) - first native producer through the
  tree; binding still owns the DataFormat+ClockDomain (mount outlives binding destruction -
  formats need a durable home, noted inline). 92/92 unit tests (native-mount coverage added)
  + boot smoke. Protocol profile migration LANDED through Modbus 2026-07-19: CAN, GoodWe, BLE,
  Zigbee, MQTT, HTTP, SunSpec, Tesla TWC, ESPHome and Modbus now converge on SampleDesc and
  DataFormat. Modbus owns its registered `reg`/`mb` profile section, all repository Modbus
  profiles use the normalized type/access columns, and client reads, upstream writes, serving
  reads/writes and fixed strings pass through the record codec. Register span remains explicit
  map data, so `strN` is bytes rather than the legacy word count. Byte-exact tests cover the
  Modbus `_bs`/`_wr` quartet. Serve profiles still correctly avoid declaring the shape of
  elements produced elsewhere, converting only at their wire boundary. NEXT: delete the now
  unused ValueDesc profile-format bridge and the temporary legacy profile grammar after the
  remaining non-profile consumers are audited; recorder-as-cursor waits for retention tiers
  (build order step 3); the prev pair dies when operators absorb the accumulator (step 4).

- **Element deadband (settled design, build when needed)**: per-point change-event conditioning,
  standard SCADA/OPC report-by-exception. ONE mechanism, three surfaces: the filter itself lives in
  the element's subscription machinery - each subscriber record carries an effective band plus an
  anchor (last value DELIVERED to that subscriber); deliver when the move from the anchor meets the
  band, then re-anchor. Non-numeric values ignore the band. `Element.latest` always stores truth
  (live reads/`@path`/API stay exact); only event delivery is gated. Band selection: (1) element
  metadata (profile field `deadband: 5W`) is the DEFAULT, the "signal modelling plan" = noise floor;
  (2) any subscription may override - coarser, finer, or 0 for raw realtime; (3) the automation
  surface is just a trigger URI param (`on="@motor.power?deadband=100W"`) that the element provider
  passes through as the subscription override - no rule-side reimplementation, works on unmodeled
  elements. Default-following subscribers resolve the element default at DELIVERY time, so
  retrofitting a band onto a raw element immediately benefits them; explicit overriders are pinned.
  Composition rule for docs: element default = measurement noise floor, overrides = consumer intent
  (don't crank the element band "for the recorder"; that's the recorder's own override). Caveats:
  the recorder may capture inline rather than subscribe - it needs to consult the same band (ties
  into the record-flag follow-up); percent deadband (OPC-style) is a later variant, absolute first.
  KNOWN DEADBAND PATHOLOGY (Manu, 2026-07-12) + required companion: crossing-triggered delivery is
  selection-biased toward extremes - (1) a transient trips delivery at its peak and the anchor
  latches that extreme while the signal settles to nominal INSIDE the band (delivered value wrong
  by up to the band, indefinitely, always toward the extreme); (2) warble marginally wider than the
  band delivers ONLY alternating boundary crossings, never a central sample, so the delivered
  stream sits farther from the rolling mean than raw would. Fix (1) and bound staleness with the
  standard historian companion knob, a max-report interval (`refresh=<dur>`, cf. PI exception-max-
  time / OPC keep-alive): after a quiet refresh period, deliver the current CLOCK-sampled value and
  re-anchor (clock samples are excursion-uncorrelated, so the anchor migrates to nominal). Deadband
  without refresh is half a mechanism - ship them together. Fully killing (2) needs the band
  decision made on a cheap EMA of the signal (decide on smoothed, deliver raw-current so consumers
  never see synthetic values) - optional third param, adds a time-constant knob; swinging-door
  compression is the heavyweight endpoint we don't need. Damage is consumer-dependent: `latest` is
  truth, so use-time re-readers (live `@path`, encode-time sync reads) suffer only timing bias;
  delivered-sample ingesters (recorder, `$value`) latch extremes and are who `refresh=` is for.
  Motivation: makes analog debounce coherent (motor inrush exceeds band and re-arms the automation's
  settle window, steady-state ripple is quiet -> `on="@motor.power?deadband=100W" debounce=5s` fires
  once when the motor stabilises) and cuts sync/record traffic from jittery samples at the source.

## Infrastructure

- **ID strategy migration (settled 2026-07-15; full design in the header of
  [src/manager/id.d](src/manager/id.d))**: replace hash-derived EIDs/CIDs with permanent
  monotonic handles bound to objects, with names as the parking/rebind fallback. Ids are
  two-level: EID = (container id, element index) - the container level is ONE id space with
  per-type tables (CID type bits); Devices register as a type WITHOUT becoming BaseObjects
  (g_app.devices Map dissolves into it), the data plane shards per container, device rename is
  O(1) with no full-path interning, and property projections compute their EID as
  (obj CID, Prop! index) with no lookup or cache. Kills ALL rekey
  machinery: `rehash()`, `ElementTable.rekey`, `CollectionTable.rekey`, `do_rekey`,
  `broadcast_rekey`, `rekey_field` all delete - rename-following becomes intrinsic (ids don't
  move when objects rename) instead of repaired by reflection broadcast. Gains: forward
  references and recreation-rebind via a parked-id claim state machine in insert(); O(1) rename/
  death/claim regardless of ref count; no hash-collision concept; EID and CID unify on identical
  semantics (ObjectRef and element refs share one follow-forwards + self-heal deref helper).
  Rules that must hold system-wide: ids never persisted, never on the wire (sync exchanges names
  once per session, binds varint session handles), no blind `hash_id` of a name to fabricate an
  id. Prerequisite for the Element2/series work (element2.d draft holds `Element2*` in Cursor -
  becomes an EID under this scheme). STARTED 2026-07-17; execution order (full steps 0-5 in the
  id.d header): (0) ids off the wire FIRST - sync today ships raw CIDs and leans on cross-peer
  hash agreement (json_encoder rekey verbs + the rehash-divergence patch in sync/package.d), so
  session name/handle binding lands before ids change shape, making the cutover a pure internal
  refactor; (1) the park/claim/forward machine standalone + unit-tested (dense per-type slot
  arrays, next_slot++ allocator, separate name map holding parked ids); (2) container cutover
  (CollectionTable, delete ALL rekey machinery, then Devices as a container type); (3) element
  index tables + Cursor->EID; (4) deref on the handles; (5) holder audit.
  Steps 4+5 LANDED 2026-07-18, MIGRATION COMPLETE: deref/self-heal lives on the handles -
  CollectionTable.deref(ref CID) container-side, healing deref(ref EID) (device.d, UFCS)
  element-side (heals both levels through the holder's field; ElementCursor uses it).
  ObjectRef stays CID (a reference to a root, never an element) and was already thin table
  sugar; NO ElementRef type - element holders keep a bare EID (the reclamation extension's
  RAII wrapper is where counting would attach, both levels). Holder audit clean: hash_id
  gone, no raw id construction outside the tables (one documented test-mock dummy in
  ble/client.d), sync translates wire handles at the encoder seam, db keys by name.
  Remaining id work rides other entries: deterministic indices + destruction-parks
  (producer migration), reclamation (when churn metrics justify).
  Step 2 LANDED 2026-07-17 (both halves): (2a) CollectionTable reimplemented over
  IdMachine!BaseObject - CID = type bits + dense slot, name setter calls table.rename (the id
  never moves, held refs follow intrinsically), and ALL rekey machinery deleted (hash_id/rehash
  chains, the intern StringTable, broadcast_rekey/rekey_field/has_cid, the rekey virtual, the
  RekeyHandler mixin + its ~30 sites; net -240 lines). (2b) Devices register as a container
  type: g_app.devices Map dissolved into DeviceTable (device.d) over IdMachine!Device with a
  map-flavoured surface (in/insert/values/keys), CollectionType.device carries the type bits.
  Verified: 92/92 unit tests + runtime smoke via --config script (duplicate-name rejection,
  rename, old-name reuse, rename-onto-live rejection) + full dev-conf boot clean.
  Step 3 core LANDED 2026-07-17: IndexTable(T) in manager.id (the nameless element-level
  machine - same tagged-word encoding as IdMachine, no name map: relative paths resolve
  through the component tree, indices park positionally on release and rebind at the same
  mount); Device carries cid (stamped by DeviceTable.insert via make_cid, now
  package(manager)) + IndexTable!(Element*) element_ids; Element.ensure_eid() mints lazily on first
  demand (walk to device ancestor; unmounted elements have no identity);
  DeviceTable.resolve(EID) + resolve_element() free function; ElementCursor {EID, position,
  bit} in element.d is the durable cursor (resolves per call, delegates to the storage-level
  element2.Cursor, goes quiet on dead elements); Element.open_cursor returns it. Unit-tested
  (IndexTable cycle, lazy mint/resolve, stray-element refusal). Step 3 remainder rides later
  work: deterministic indices (profile template index / Prop! index) land with per-protocol
  producer migration; destruction-parks wiring lands when anything actually destroys
  elements. NEXT: step 4 (unified EID ref type) + step 5 (holder audit).
  Step 1 LANDED 2026-07-17: IdMachine(T) in manager.id - dense tagged slots (0 = dormant,
  bit0=0 = bound, bit0=1 = write-once forward), reserve/claim/rename/release/deref with
  self-healing forward chains, separate String-keyed name map; unit-tested through the full
  park/claim/rename-merge/resurrect cycle. En route: urt map.d heterogeneous remove was broken
  (search compare reinterpreted the search key as K - segfault on remove-by-slice from a
  String-keyed map); fixed in urt with a regression test.
  Step 0 LANDED 2026-07-17 (compiles, unit-green; sync end-to-end smoke test remains an open
  gap it already had): add_name = {handle, name, type} introducer, SyncPeer carries the
  session handle tables (_introduced objects / _adopted local CIDs; wire handle low bit =
  allocated-by-sender, flips crossing the wire; slots never rebind, object death voids them
  via the destroyed lifecycle hook), every other verb cites handles, translation confined to
  the encoder seam (package.d handlers still speak local CIDs). Deleted: the rekey verb both
  directions, the fan_out_rekey/on_object_rekeyed stubs, and #/$ raw-CID subscription
  patterns. Rename propagation (never wired) is now one {handle, new_name} verb + a global
  renamed hook, deliberately deferred.

- **Async I/O end-state: the main loop's wait primitive IS the reactor** (decided 2026-07-12;
  supersedes the earlier "fold the workers onto one shared worker-thread reactor" plan).
  Today there are three standing I/O thread backends: `SerialReader` (`router/stream/serial.d`,
  linux poll+eventfd / windows IOCP with one parked overlapped read per port), `SocketWorker` /
  `IOCPWorker` (`protocol/ip/package.d`), and the `fdwatch` readiness waiter
  (`driver/linux/fdwatch.d`). All of them exist for ONE reason: the main loop sleeps on
  `_wake_event` (futex / win32 event), which cannot be waited on together with I/O handles - so
  each subsystem runs a thread whose whole job is converting I/O readiness into a wake. The
  destination is to delete that layer entirely: make the main loop's sleep the I/O wait itself.
  - linux: `wait_for_wake` becomes `epoll_wait` (the wake is an eventfd in the set; `post_event`
    writes it, gated by an already-signaled atomic so it costs one syscall per sleep cycle).
    epoll, NOT poll: poll() re-does O(n) waitqueue setup/teardown on every call - fine for a
    parked worker, wrong for a loop waking at 20Hz+ - while epoll registration is persistent
    (`epoll_ctl` once per fd lifecycle = config-time churn) and `epoll_wait` is O(ready) with
    zero per-fd work on re-entry. Level-triggered, drain on main, same semantics as fdwatch's
    service hooks. (At our fd counts poll would actually survive - ~10us per wake for 50 fds -
    but epoll makes the concern structurally impossible; don't relitigate.)
  - windows: `wait_for_wake` becomes `GetQueuedCompletionStatus[Ex]` with the timer deadline as
    the timeout; the wake is `PostQueuedCompletionStatus`. IOCP registration is persistent by
    construction. Completions (serial reads, socket ops) are handled inline on main.
  - The single-threaded dataplane then needs NO SPSC rings, NO backpressure semaphores, NO
    generation/ABA tags, NO worker-owned closes - all of that machinery exists only because I/O
    currently happens off-main. Everything deletes rather than merges.
  - Public API stays completion-shaped ("here are your bytes" via `g_app.watch_io(key, handle,
    &on_data, &on_error)`), never readiness-shaped: readiness is unimplementable on IOCP, and a
    completion contract lets an io_uring backend slot in later without touching clients.
  - io_uring: considered and REJECTED for now - needs recent kernels, is commonly blocked by
    container seccomp defaults (Docker denies it; the RouterOS container target is directly at
    risk), would still require the epoll fallback, and its wins only appear at op rates far
    above ours. Revisit only if a workload demands it; the API above is already shaped for it.
  - Migration passes, each independently shippable:
    1. DONE (2026-07-12): wake-primitive swap - `manager/reactor.d` `Reactor` replaces the
       Application's `_wake_event` Event with the same latch semantics (set/reset/wait) on an
       eventfd (linux) / an IO completion port (windows); one kernel signal per latch cycle via
       an atomic gate. Embedded/other keep the Event arm. Unit-tested both platforms.
    2. DONE (2026-07-13): `g_app.watch_io(file, &on_data, &on_error)` - registration is
       `epoll_ctl` / `CreateIoCompletionPort` association; delivery happens inline on the main
       thread from inside `wait_for_wake` (`Reactor.wait` sweeps ready I/O before and after the
       sleep so it never starves behind a latched wake, and a busy loop still sweeps via a
       zero-timeout wait). Serial folded on; the whole `SerialReader` block is DELETED - no
       rings, no backpressure, no generation tags, owner closes its own handle after
       unwatch_io. Windows: one overlapped read parked per watch with an entry-embedded buffer
       (MAXDWORD/MAXDWORD/1000ms COMMTIMEOUTS = complete-on-first-bytes + 1s idle tick),
       cancelled reads reaped via entry retention until their completion drains;
       ERROR_OPERATION_ABORTED (a flush purge) re-arms quietly; serial's purge-before-close and
       low-bit-tagged write-event suppression carry over unchanged (see notes below). linux:
       level-triggered epoll, reads on main into a stack buffer; errored/hup'd fds are DEL'd
       from the set immediately so they can't spin the loop while the owner's restart works
       through the state machine.
    3. DONE (2026-07-13): OS sockets folded onto the reactor's layer-1 primitive and
       `SocketWorker` + `IOCPWorker` DELETED (~1140 lines out of `protocol/ip/package.d`). The
       layer under `watch_io` (see `manager/reactor.d`): linux exposes `watch_fd(fd, want_write,
       &on_ready)` / `modify_fd` (raw level-triggered readiness; the endpoint does its own
       recv/accept/send on the main thread and unwatches on error); windows exposes
       `associate(handle)` + a public `IoOp` struct (OVERLAPPED + an on_complete delegate) that
       callers park themselves (`WSARecv`/`WSASend`/`ConnectEx`/`AcceptEx`/`WSARecvFrom`), with
       completions delivered on the main thread from `Reactor.wait`. TCPConnection/TCPListener/
       UDPEndpoint each carry their own embedded ops; endpoints are freed by `pump_ip_endpoints`
       once `reclaimable` (windows: all cancelled overlapped ops drained; else immediately).
       Connect readiness = EPOLLOUT (linux) / ConnectEx completion (windows); accept re-arms
       itself. No SPSC rings, no wake socket, no `post_event` marshalling, no `EntryKind`/`Ev`/
       `Req` vocabulary. Verified: win 88/88 + linux 89/89 UT, full builds both platforms, and a
       live loopback that drove all four IOCP op types (ConnectEx outbound -> AcceptEx inbound ->
       WSASend banner -> WSARecv) plus rapid accept/close cycles with no leak.
    4. DONE (2026-07-13): fdwatch's waiter thread DELETED - the LAST standing I/O thread on linux.
       `driver/linux/fdwatch.d` is now a thread-free adapter: its watchers (BLE + 3 wifi) keep the
       collect/service API unchanged, and it registers their fds as a "pool" in the reactor's epoll
       set sharing ONE coalesced drain (`Reactor.set_pool_drain`/`set_pool_fds`, linux). All pool
       fds carry a single epoll data sentinel (`&_pool_tag`) - membership is reconciled by fd number
       (ADD/DEL/MOD diff), no per-fd allocation. When any pool fd is ready, dispatch() sets
       `_pool_pending` and runs the drain (= every watcher's service() + a re-collect) ONCE after
       the batch, at most once per wait() cycle - exactly the old "any readiness -> service all,
       then rebuild" semantics, minus the thread/semaphore/wake-eventfd. Adversarially reviewed
       (0 confirmed defects); unit-tested (coalesced multi-fd drain, drain-to-empty, mid-flight
       set shrink) + full builds both platforms. The whole 4-pass migration is COMPLETE: no
       standing I/O threads remain (SerialReader, SocketWorker, IOCPWorker, fdwatch waiter all
       deleted); the main loop's epoll (linux) / IOCP (windows) wait IS the reactor.
       Known contract (see reactor.d dispatch pool branch): a pool fd stuck in persistent
       EPOLLERR/EPOLLHUP that its watcher keeps collecting would keep the loop from idling (the
       shared sentinel gives the reactor no fd to DEL). Not a regression - the old poll() waiter
       burned a core on the same case - and the drain still runs so the watcher can react. The
       real gap is client-side: wifi `pump_raw_frames`/`pump_monitor` (`driver/linux/wifi.d`)
       `break` on a genuine (non-transient) `poll_ll` error WITHOUT clearing `_raw.fd` or
       restarting, so `collect_fds` keeps re-including the dead fd. Harden those to drop the fd /
       restart on persistent error (pre-existing; only made loop-visible by the single-thread fold).
  - Embedded is the same contract: UART rx-IRQ fills a ring and wakes the main loop (wire the
    already-declared-but-dropped `UartRxCallback`/`buf_size` through `uart_open` -> uart_hw).
    This design makes desktop/server behave like embedded, not the other way around.
  - Known refinements INSIDE the model, only when a real device makes them hurt: async serial
    writes (EPOLLOUT armed on demand / write completions through the port) to remove the bounded
    ~100-200ms main-thread stall a flow-control-blocked write can cause; and storage I/O, which
    epoll cannot async (regular files are always "ready") - recorder flushes to a stalled SD
    card remain the one legitimate helper-thread (or future io_uring) candidate.
  Until pass 2 lands: serial rx is event-driven on linux+windows via `SerialReader`;
  other-Posix/Embedded still drain in `update()` -> `incoming()` (kept so `rx_handler` works
  everywhere).
  Windows note: comm WRITE timeouts on the overlapped path complete with ERROR_SEM_TIMEOUT and a
  short count (the old sync path returned TRUE + short count); `write()` maps it back to the
  partial-write contract - don't "simplify" that check away.
  Note: the serial pass was data-path-only, so the genuine timers left in `update()` are
  intentional - ASH retransmit (250ms) + RST retry (`ashv2.d`), EZSP request timeout (200ms,
  `client.d`), and the Zigbee NCP counter poll (`iface.d`); moving those onto
  `g_app.schedule`/the 1s heartbeat is a separate cleanup.

- **GPIO sampler backend upgrades** (baseline landed 2026-07-15: urt gpio sampler API +
  posix cdev v2 backend + /binding/gpio (GpioBinding) populating an Element2 series):
  (1) pigpiod runtime detection on linux, preferred over cdev when present (decided: cdev
  stays the portable default; pigpio = DMA sample-clock timestamps + the only honest TX;
  no Pi 5 support, so detect, never assume) - same GpioSampler surface, mode tag inside;
  (2) map cdev `line_seqno` gaps to `mark_gap()` on the series so kernel event-buffer
  overflow marks the loss at the drop site; (3) bucket eviction is now LIVE-urgent: an open
  squelch on a 433 receiver grows the series unboundedly (~16 B/edge at hundreds-thousands
  edges/sec); (4) TX (waveform generator API) when 433 transmit lands - forces the pigpio
  backend.

- **Port discovery completeness and eventing**: /port is meant to be the unified hardware
  inventory, but discovery is still uneven. Ethernet and WiFi publish ports today; serial
  discovery needs to be event-driven instead of periodically rescanning; CAN devices are not
  published yet. Linux CAN should be discovered from SocketCAN netdevs via
  /sys/class/net/*/type (ARPHRD_CAN = 280) and reported as PortKind.can, while
  ethernet/wifi scans should only accept real ethernet netdevs (ARPHRD_ETHER = 1).
  Replace polling with OS events: route netlink for netdev classes, and kobject uevents
  or inotify-backed rescans for tty/serial devices.

- **HTTP client binding request-state wedge**: the SmartEVSE binding polled once at boot then
  froze (every device-sourced element stuck at timestamp 0) while binding and client both report
  Running and the device answers in <30ms. Suspected mechanism: request/response correlation is
  FIFO-by-assumption on both sides - the client times out requests at 5s and fires the handler
  with an empty message, so a late response then matches the wrong queued request; and
  `submit_request` silently drops when the binding's 16-deep in-flight queue is full while
  `rs.in_flight` stays true forever, permanently killing that request state. The constant
  `feed_currents` write traffic from the se_meter element links alongside the 400ms status poll
  gives plenty of opportunity to hit either. Verify with `version = DebugHTTPClientBinding`,
  then replace the FIFO assumption with a real request handle (existing TODO in binding.d:
  "HTTPClient NEEDS TO RETURN A HANDLE") and make in_flight self-recover.

- **API response truncation**: /api/get responses truncate around 140KB (seen querying
  `energy.*`); clients get invalid JSON with no error.

- **/device/print over /api/cli/execute CRASHES the instance** (found 2026-07-15, pre-existing):
  every invocation resets the connection (http 000 at ~1.4s), the child dies (defunct under the
  supervisor) and respawns. The same command over a piped --interactive console session prints
  NOTHING but survives. Suspect: DeviceTreeView (and live views generally) assume a terminal
  channel the API/pipe sessions don't have. Severity: any web/API user typing it restarts prod.
  Reproduce locally with the piped-console for the silent case; the crash case needs an API
  session against a populated tree. See console-session skill when investigating.

- **TLS server-mode transport ownership**: shutdown destroys the handed-in listener stream;
  if a server-side TCP ever takes multiple ticks to shut down after going offline, the same
  double-destroy shape fixed for client mode (b4005c88) exists there. Same scrutiny needed.

- **Profiles must never be freed** - things borrow into the profile's string caches, so if
  profile freeing is ever reintroduced, un-borrow these first:
  - accumulator `comp.source` path strings, pre-bind (device.d)
  - element name/desc/display_units metadata (served by /api/list)
  - conf-defined enum templates (profile.d)
  - per-binding retained `ElementDesc` refs from add_handler (aa55 copies by value; audit others)
  - Expressions used to, but now copy their strings at parse (expression.d) - immune.
