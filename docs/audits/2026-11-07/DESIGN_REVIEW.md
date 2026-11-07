# OpenWatt overall design review — 2026-11-07

This is a bounded architectural assessment, not an exhaustive correctness audit.
The initial report overstated completion: its inventory and broad pattern sweep
did not establish comprehensive coverage. A second pass followed more complete
ownership and execution paths, challenged the original findings, and found D17–D22
below. Those additional findings are material evidence of the first pass's limits.
The third pass followed reduced-board composition, streamed request cancellation,
outbound connection configuration, profile compilation and binding attachment,
fleet identity persistence and Linux update recovery. Its contributions are the
board-specific evidence in D04 and findings D23–D28. The coverage table records
the extent of the review.

The largest simplification opportunity is to finish transitions that have already
changed the architecture. The project now has typed records, stable identities,
push I/O, and a model sync plane, but substantial behavior still lives in the
older property, polling, and protocol-specific paths. Those paths carry their own
ownership, conversion, serialization, and recovery machinery.

The recommended work is a sequence of deletions with explicit end states. Adding
another general framework alongside the existing paths would make this worse.

## Follow-up status on the publication base

The findings below preserve the reviewed snapshot. The code cited from local
modifications is identified as such. The report is an evidence record and
[TODO.md](../../../TODO.md) carries the work list.

- D17's unsafe value-copy path has been superseded on master. The packet storage
  and holder changes prohibit copying Packet and migrate the callers.
  [Packet flags PR](https://github.com/open-watt/openwatt/pull/868),
  [packet holders PR](https://github.com/open-watt/openwatt/pull/873)
- D24 is implemented for review in [PR #879](https://github.com/open-watt/openwatt/pull/879).
  The PR base has a fifth occurrence in GoodWe.
- [PR #880](https://github.com/open-watt/openwatt/pull/880) implements the first
  part of D26 by consolidating root section and string sizing.
- The next low-risk candidates on master at `7dafa5e61` are eight adjacent
  dirty-mark pairs, the identical sync dirty-flush bodies, the redundant
  console schema copies and empty filter, and the three IPv4 pseudo-header
  checksum builders. The MTU setters already combine their masks on master.

## Code to delete or share first

These are local changes a reviewer can assess one function at a time. The
counts below are source counts from the working tree. Ordering favors common
runtime code, clear removable work, and small changes. Basic Tiny automation
and its light-timer acceptance case remain part of D04.

1. **Resolve a property name once.** BaseObject has five walks comparing the
   same property names across get, set, sync_apply, reset and sync_reset.
   sync_reset finds the property and then calls reset by name, starting again.
   Inbound sync set and reset have four more copies of the index search across
   their local and authority-echo branches. Both set branches also copy the
   incoming Variant to pass it to a function already taking ref const Variant.
   Return a schema index from one lookup, apply/reset by index, and keep that
   index for echo. Set and sync_apply can share the setter call and tracking
   tail with the read-only policy chosen at entry. Preserve unknown-property
   handling for binding parameters. This deletes name comparisons and copies
   without adding an index table to every type.
   [Property operations](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L484), [sync callers](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/package.d#L883)

2. **Mark two dirty properties in one walk.** Ten places have two consecutive
   mark_set calls with no intervening work. They occur twice in base, twice in
   interface MTU setters, twice in IP address and four times in IP route. Each
   call ORs a mask and walks the object's list of sync slots. For example, use
   `mark_set!(typeof(this), ["mtu", "actual-mtu"])();` in the MTU setter.
   The existing overload computes the combined mask at compile time. This
   deletes the second walk at each site with no new helper or state.
   [Mask and walk](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L634), MTU setters (`src/router/iface/package.d:255` in the reviewed working tree)

3. **Remove a phantom filter from collection printing.** populate_collection_table
   declares a 16-entry list of string slices, never fills it, and passes it to
   prop_visible for the header and again for every property of every item.
   Properties without display flags fall through to a scan of 16 empty names.
   These are the only two callers. For the schema's nonempty names the predicate
   reduces to `(flags & 4) == 0 && (flags & 3) != 0`. Delete the list and its
   name argument. Select columns once while making the header, then visit those
   getters for each row. This also removes the repeated "flags" name comparison
   from the row loop. [Table builder and predicate](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/collection_commands.d#L477)

4. **Borrow the schema during completion.** Both collection completion functions
   assign item.properties() into a fresh owning Array and immediately take its
   slice. properties() already returns the type's persistent slice. uRT's
   assignment clears, reserves and copies every pointer. Replace each temporary
   and its branch with `auto props = item ? item.properties() : collection.type_info.properties;`.
   Then share candidate selection between completion and suggestion, retaining
   the separate suffix editing and list output. Check separator handling before
   sharing tokenization. [First copy](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/collection_commands.d#L613),
   [second copy](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/collection_commands.d#L719),
   [schema lifetime](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L430), array assignment (`third_party/urt/src/urt/array.d:484` in the reviewed working tree)

5. **Share the slot cursor for collection keys and values.** The two range structs
   have the same table pointer, filter, slot, termination test, popFront and
   advance loop. Only front differs. Put slot advancement in one ordinary cursor
   with key and object projections. item_count also repeats the same filtering
   loop and can count the shared cursor. Keep update_all's deliberately live
   traversal for objects created mid-update. [Collection traversal](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/collection.d#L243)

6. **Delete two IPv4 checksum builders.** DHCP, native UDP and TCP each build the
   same 12 bytes on the stack and call internet_checksum. Source and destination
   fill eight bytes, then zero, protocol, and the big-endian transport length.
   They differ only in how they spell the last store. Use one leaf function
   accessible to all three with a slice-safe length store. The IPv6 and Ethernet
   pseudo-headers have different layouts. [DHCP](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/dhcp/message.d#L380),
   [UDP](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/udp.d#L680), [TCP](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/tcp.d#L2012)

7. **Stop assembling a second contiguous HTTP response.** The API module alone
   has 18 `stream.write(response.format_message()[])` sites. For a nonempty
   response create_response first copies the supplied body into an owning Array.
   format_message then appends that body to the formatted header in another
   Array. Existing send_message already writes the head and content as two slices.
   First use that path for buffered replies with the existing encoding policy,
   then factor the common JSON status/body/CORS sequence used by the error exits.
   Keep OPTIONS headers, streamed replies and short-write handling explicit.
   This first cut removes one body copy even before tackling the original owned
   content. [API examples](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/api/package.d#L579),
   [body construction](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/message.d#L689),
   [two-slice writer](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/message.d#L784),
   [concatenation](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/message.d#L928)

8. **Use the port operation already on InetAddress.** TCPStream and ESPHomeClient
   each carry a private update_port with the same two family tests, two writes
   and boolean return. Their callers ignore the return. IPClient also opens the
   address union to read and write the port when preparing child streams. Use the
   existing accessor after resolving the accepted address families at entry.
   It also supports ether, so preserve each caller's Ethernet policy. This is
   a smaller first patch than D25's transport construction changes.
   [TCP](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/tcp_stream.d#L336), [ESPHome](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/esphome/client.d#L272),
   [IPClient](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/client.d#L115), uRT accessor (`third_party/urt/src/urt/inet.d:743` in the reviewed working tree)

9. **Move the repeated profile/model properties up one level.** Seven bindings
   (BLE, CAN, ESPHome, GoodWe client, HTTP, MQTT and OBD) own two Strings, expose
   getter/setter pairs and override profile_name/model_name to hand the same
   slices back to ProfileBinding. The ordinary setters compare, move, mark and
   restart. Share storage, descriptors and bodies for the explicit-name case.
   Preserve object-specific property indices/dirty bits and derived-name policies
   such as Modbus. Avoid a mixin that emits the seven bodies again.
   [HTTP properties](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/binding.d#L100),
   [HTTP overrides](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/binding.d#L171),
   [base consumer](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/binding.d#L215)

10. **Store the common SunSpec field records once.** Inverter models 101/102/103
    each end with the same 14 FieldDef initializers. Models 111/112/113 repeat
    a different common tail of 14. The six literal arrays encode 56 redundant
    record occurrences across the two trios. FieldDef contains two string slices
    as well as register metadata, so sharing literal strings alone leaves the
    containing records. Let each mapping visit its phase-specific prefix and
    its shared immutable tail in order. Compile-time concatenation into six
    arrays would recreate the duplication. Check generated field order and
    offsets against the existing mappings. [Tables](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/modbus/sunspec.d#L213),
    [mapping use](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/modbus/sunspec.d#L1135)

The earlier sync dirty-flush duplication (D06) and stream/interface bitrate
calculation (D14) also belong on this list. The latter repeats two 64-bit rate
calculations per heartbeat on constrained targets. Sharing one body removes a
copy of the arithmetic from source while each active transport still needs its
own samples. Conversely, the six visually similar branches in function_adapter
are selected by D's static if. Counting all six as emitted branches per command
would give a misleading priority. [Command adapter](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/function_command.d#L67)

## Scope and evidence

Reviewed the working tree, including its existing modifications and untracked
source files. The root commit was `66a70910d998bef0dd5c156fd5f5649406743e37` and
the uRT commit was `9310345d85c7ebec70a6b31844b3b8aa8edbbfe7`. Links to unchanged
source are pinned to the root commit. References to modified source give the
path and line in the reviewed working tree.

The inventory contained 280 application D files and 170,714 lines, including
comments and tests. The focused areas were manager (55 files, 41,467 lines),
router (25, 13,532), IP (20, 14,279), and HTTP (7, 6,148). Inventory and
duplicate-block searches covered the application tree; the findings below came
from following the relevant implementations and callers, not from file size.

Focused traces covered object identity and lifecycle, collections and property
synthesis, device materialisation and computations, elements/series/recording,
console execution, module assembly and feature flags, sync encoders and peer
ownership, streams and packet routing, native and socket IP entry points, DHCP,
and HTTP client/server/binding/fileserver/WebSocket paths. Other protocols,
energy, automation, platform drivers, and uRT containers/pages were sampled for
the same patterns. This is not a line-by-line audit of every protocol, vendor
SDK, hardware backend, or cryptographic implementation.

Validation was primarily static: source/call-path inspection, searches for consumers and
alternate implementations, a normalized duplicate-block scan, and a literal
comparison of the two sync dirty-flush methods. An isolated debug probe build was
attempted in the second pass, but existing root/uRT/compiler incompatibilities
blocked compilation before the witnesses could execute. The host compiler
rejected the TypeInfo override signatures and the checkout lacked an imported
uRT symbol. This review used source evidence. The two
implementation PRs ran their own tests on master. Binary savings remain unmeasured.

Earlier work was reconciled against `TODO.md`, the September subsystem audits,
`docs/DATA_MODEL.md`, and `SYNC_CONVERGENCE.draft.md`. Existing plans are not
treated as completed implementations. Several findings strengthen existing
work items; the unchecked typed reference, moving computation callbacks,
connection-name retention chain, inert headless flag, exact encoder duplication,
and exhausted collection tag space are particularly concrete current evidence.

## Ranked findings

P1 identifies a correctness/ownership problem worth fixing before further
extension. P2 identifies a structural simplification. Ordering within P2 favors
the core and constrained builds. A smaller source implementation is desirable,
but acceptance also requires bounded memory and preservation of real behavior.

| ID | Priority | Finding | Reach |
|---|---|---|---|
| D01 | P1 | Typed ObjectRef does not preserve its type invariant on rebinding | Core, all interface consumers |
| D02 | P1 | Computation callbacks point into movable array storage | Data model, all tiers carrying it |
| D03 | P1 | Ephemeral connections allocate permanent names and slots | Core identity, UDP/WS sync |
| D04 | P2 | Application assembles a full management product inside the common kernel | Every tier, especially Tiny |
| D05 | P2 | Property and model convergence has no sufficiently cheap final representation | Core, API, sync |
| D06 | P2 | Sync serializers own identical replication policy | Every sync build |
| D07 | P1 | Transactions have several partial owners and callback-before-retirement paths | Queues, Modbus, HTTP, other clients |
| D08 | P1 | A value update doubles as a command to hardware or a remote authority | Elements, bindings, sync |
| D09 | P2 | Event-driven operation still depends on a second polling/lifecycle engine | Core, streams, IP, HTTP |
| D10 | P2 | The shared sample gateway stops one layer short of its consumers | Most bindings |
| D11 | P2 | HTTP applications each implement response transport ownership | API, fileserver, server |
| D12 | P2 | Native IP has two independently managed application entry paths | Internal IP stack |
| D13 | P2 | DHCP repeats lower-layer packet parsing outside the common IP path | IP/DHCP, including small nodes |
| D14 | P2 | Stream and interface telemetry duplicate the same rate engine | Every switch build |
| D15 | P2 | Device/profile lifetime is currently implemented by retaining everything | Core model, recorder, sync |
| D16 | P2 | The generic bridge still knows the Modbus control-plane registry | Fabric and reduced builds |
| D17 | P1, historical | Packet became address-dependent without losing its old copy contract | Packet fabric and page-backed packets |
| D18 | P1 | Mutation outcomes are presentation text; construction is repeated at its adapters | Config, CLI, API, automation, sync |
| D19 | P1 | Fresh defaults, schema defaults, and reset are different contracts | Legacy properties throughout the core |
| D20 | P1 | Format admission permits semantics the disk representation drops | Series, recording and format boundaries |
| D21 | P1 | Cooperative execution has no common bounded-turn contract | Core timers, scripts and propagation |
| D22 | P1 | Callback registration has several incompatible mutation/lifetime rules | Core state, components, Elements and packets |
| D23 | P1 | A streaming HTTP request has a completion callback but no cancellation callback | HTTP server, fileserver, OTA |
| D24 | P1 | Binding attachment publishes a made-up first observation | CAN, BLE, OBD, Modbus and model consumers |
| D25 | P2 | Creating an outbound connection repeatedly encodes and parses its configuration | IP clients, TCP, HTTP and TLS |
| D26 | P2 | Profile storage layout has become a second implementation of the grammar | Manager and profile sections |
| D27 | P1 | Fleet adoption and reset acknowledge volatile state as durable | Peering on nodes with persistent allegiance |
| D28 | P1 | Staging and accepting a Linux image span independently committed files | Linux OTA and supervisor |

### D01 — ObjectRef's type proof expires when a slot rebinds

Evidence: [ObjectRef.get](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L1204) casts through
`void*` to `Type` without checking the current object's dynamic type.
[CollectionRoot](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/collection.d#L467) deliberately places
subclasses in the same collection identity table. Allocation at an absent name
reuses its dormant identity. A reference originally constructed from a
`WiFiInterface` can therefore resolve to a bridge or another interface subtype
created under the same name. A real narrower reference exists in
[WiFi interface state](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/router/iface/wifi.d#L560).

This is an invalidated structural assumption, not a missing null guard. Being
type-correct when assigned does not prove the type of a later claimant. The
newer [prop_read reference path](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L449) already uses
`dyn_cast!T` for exactly this case, so the two reference representations disagree.

**End state:** one typed-resolution contract shared by ObjectRef and projected
reference properties. An incompatible claimant is unresolved for the typed
holder; a compatible later claimant can bind. Keep root collection identity
separate from concrete subtype compatibility. Do not add subtype checks to every
consumer. Verify deletion, sibling replacement, compatible replacement, and rename
onto a reserved identity.

### D02 — Computation is a callback owner stored by value in a growable array

Evidence: Device.computations (`src/manager/device.d:435` in the reviewed working tree) is
`Array!Computation`. try_bind_pending (`src/manager/device.d:595` in the reviewed working tree)
subscribes delegates to `&c.element_updated`, where `c` is an array element.
Profile materialisation (`src/manager/device.d:742` in the reviewed working tree) opens existing
devices and appends computations at lines 887, 929, and 941. There is no
unsubscribe/rebind of existing delegates around array relocation.

If a later materialisation relocates the array while growing it, existing
subscribers retain old struct addresses. Merely reserving more capacity would
leave the invariant dependent on a guessed maximum. The union also represents an
unbound accumulator's source path as an `Element*`, then changes its meaning once
bound. These are signs that an active operator outgrew a passive record.

**End state:** address-stable operator owners with explicit pending/bound source
state, subscription lifetime, batch/gap behavior, and timer ownership. This gives
the existing operator migration a correctness prerequisite, rather than making
it an optional cleanup. Delete `Device.update()`'s integration supervision and
the computation union once operators own their work. Verify adding a new profile
to an already bound device while forcing storage growth, then updating and
destroying sources. The relocation failure was established statically, not run.

### D03 — Connection generations are being paid for as permanent identities

Evidence: [IdAllocator.release](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/id.d#L221) nulls the value;
the name map, slot name, and slot remain. Slots are explicitly immortal.
[WebSocket sync](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/ws_server.d#L133) and
[UDP sync](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/udp_server.d#L193) generate a new peer name
with `++_next_conn_id` for each accepted session. Destroying the peer does not
remove that identity. [Collection.update_all](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/collection.d#L256)
also scans through the permanent slot high-water mark, including dead slots.

The causal result is retained identity storage and increasing scan work across
reconnects, even if live-peer admission limits work correctly. A cap on concurrent
peers does not bound cumulative names. This matters on long-running small nodes.

**End state:** distinguish configured/name-rebindable identities from ephemeral
connection generations. Either give ephemeral sessions a reclaimable handle
domain, or use bounded reusable session identities with explicit generation and
reference invalidation semantics. Do not silently recycle a name if old ObjectRefs
would thereby acquire an unrelated session. Verify repeated connect/disconnect
with bounded live sessions and stable retained storage/iteration cost.

### D04 — The assembly root is also the mandatory kernel

Evidence: [Application construction](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/package.d#L390)
unconditionally registers general math, trigonometry, energy intrinsics, device
commands, profile-backed device creation, secrets, and bindings.
[register_modules](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/plugin.d#L77) unconditionally installs
recording and the whole sync/discovery/peering subsystem.
[RecordModule.init](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/record.d#L851) registers filesystem
recording, query, and terminal graph commands without a filesystem/headless gate.
[SyncModule.init](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/package.d#L142) creates both JSON and
binary encoders. The advertised [sync capability mask](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/peer.d#L55)
also enables every family unconditionally.

`FEATURES=switch` still includes all of manager. `HEADLESS` becomes a D version
and `is_headless`, but the source search found no consumer beyond its declaration;
the existing `ExcludeHelpText`/`ExcludeAutocomplete` switches are independent and
are not connected to it. This is stronger evidence than an unused import: the
registrations take addresses of the implementations and make them reachable.

The SmartEVSE v3.0 profile gives a small first cut. Evaluating its board.mk with
features.mk produced `switch-http`, `TINY=1`, `HEADLESS=1`, `NoHTTPClient`,
`NoHTTPFileServer` and `HasOTA`. The selected directories include apps/automation.
On that branch the module registry explicitly installs Automation with OTA. The
only production caller of schedule_oneshot wants a delayed reboot. It builds a
script and creates a temporary Automation with a formatted cron URI. The CLI
command ultimately calls system_reboot. Give the committed reboot deadline to a
system-owned timer so it survives updater teardown. Select basic user-authored
Automation as a capability of Tiny itself. Board defaults (`platforms/esp32/boards/smartevse-v30/board.mk:6` in the reviewed working tree),
[registration](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/plugin.d#L243), [caller](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/ota/package.d#L272),
[script construction](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/automation/package.d#L33).

**Tiny acceptance case.** With HTTP, OTA and the interactive terminal absent, a
startup command should be able to arm a timer and turn off a bound light. For
example, on a board exposing a writable `hall.light` element:

```text
/automation/add name=lights-out on="every:5m?repeat=false" do={ /element/set element=hall.light value=false }
```

Evaluating features.mk for BK7231N selected switch and for BL808 e907 selected
switch-ip. Both selected headless and omitted apps/automation, even though cron
and the element-set command are already registered in the common runtime. Select
the existing automation language and timer provider directly on these builds.
The output binding remains board-specific. Verify one write to a test output,
cancellation before expiry, and operation with the network disconnected.
[Preset directories](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/features.mk#L100), [cron registration](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/plugin.d#L80),
[element write](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/package.d#L1328).

There is a separate cost inside the action path. Each fire creates a named,
collection-managed Session, executes the stored Script, and requests session
destruction on completion. The command needs local variables, result handling
and possibly a continuation. Move that execution state below the human Session
so a headless action can use it directly. Keep concurrent asynchronous actions
isolated, retain the existing action syntax, and compare allocations per fire.
Session names can be reused here, so this demonstrates per-fire churn rather
than the monotonic connection naming in D03. [Action execution](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/automation/automation.d#L678),
[session creation](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/console.d#L173),
[name selection](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/collection.d#L366).

In the same configuration HTTPModule still registers the HTTP client binding's
profile grammars and the FileServerAccess enum. Move those registrations to their
owning optional features. Preserve deliberate support for mixed-protocol profiles
by checking how an omitted section is skipped. Verify remaining registrations and
link-map reachability on this board and the full host. The Make evaluation
establishes feature selection only. [HTTP initialization](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/package.d#L210)

The issue is who owns assembly. Cutting a few strings cannot make a transport
coprocessor independent of the recorder, device catalogue, or rich console.

The second pass also inspected source dependency structure. A lexical import graph
over the 280 application modules had 1,969 edges and a largest strongly connected
component of 219 modules. This is the union of conditional imports, not a claim
that every build links all of them. Concrete reverse dependencies are more useful
than the aggregate: base imports console argument conversion, which imports
router interfaces/streams; series imports the filesystem container implementation;
HTTP message code imports the HTTP package/assembly and TCPStream. Core types,
conversion adapters, transport services and registration are not independently
testable boundaries today. Move assembly to its owner and replace umbrella imports
with narrow contracts; another runtime dependency-injection framework is unnecessary.

**End state:** a small kernel for lifecycle/identity/events/config execution, with
product services registered by the selected composition. Make human console
facilities, recording/graphs, device/profile services, and sync verb/encoding
families express their actual dependencies. Keep command execution available for
startup configuration. Move energy intrinsics and domain template catalogues to
their owners. Derive advertised capabilities from included services. Use a single
feature definition to drive sources, registration, and capabilities; avoid growing
an unrelated switch for every class. This extends the existing deferred minimal
tier work with concrete deletion boundaries.

One adjacent limit is already reached: `CID = ID!6` and `CollectionType` currently
has exactly 64 collection-kind entries, numbered 0–63. The next entry cannot fit the
identity layout; `make_cid` checks the slot but not this namespace bound. Resolve
the capacity contract before adding another collection. This is a present design
limit, not a claim that current valid IDs already collide.

### D05 — There are still several management surfaces for the same state

Evidence: [Property synthesis](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L150) supports both
legacy getter/setter thunks and element-backed declarations. Legacy mutations
mark `_props_set` and per-channel dirty masks; element mutations also signal
subscribers. Sync has separate object-mirror and model-plane verb families;
[APIManager](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/api/package.d#L36) independently exposes commands,
schema, enums, devices, and values. Existing convergence plans correctly identify
much of this overlap.

The current replacement is not cheap enough to apply indiscriminately:
[build_prop_elements](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L705) allocates
`properties.length * Element.sizeof` if even one property is element-backed,
including storage for legacy property positions that are not Elements. Every
ActiveObject inherits element-backed status/running, so this cost is broad.
The lexical inventory found 529 `Prop!` and 20 `Elem!` occurrences before ordinary
top-level unittest blocks; these are source counts, not instantiation counts.
Most declarations still need the old machinery.

**End state:** one addressable management shape, with cheap views of ordinary
properties and real stored Elements only where storage/subscription behavior is
needed. Separate stable property/EID index from physical Element allocation.
Use one schema for lookup, mutation, sync and API adapters. Then retire legacy
mirror verbs, repeated schema traversal, and obsolete property adapters. Do not
mass-convert every property into a full Element as a shortcut. Preserve unset
versus explicit-default semantics, read-only authority echoes, validation, and
reference types during the cutover. Client migration belongs in UX_TODO when
implemented; this review changes no client contract.

### D06 — Serialization classes duplicate replication policy literally

Evidence: [BinaryEncoder.tick_dirty](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/binary_encoder.d#L1080)
and [JsonEncoder.tick_dirty](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/json_encoder.d#L1298)
are literally identical 45-line methods. They choose objects, inspect authority,
find sync slots, calculate set/reset bits, enforce reset assertions, manage burst
generation and refusal, and clear successful dirty bits.

None of those decisions concerns JSON or binary representation. This creates two
copies of important retry/authority logic in the mandatory sync path, and every
policy change needs two correct edits.

**End state:** the hub owns one dirty traversal and calls encoding operations.
Keep format-specific parsing and serialization separate. Share this as an ordinary
implementation, not a template instantiated once per encoder. It can land before
the larger mirror retirement and then disappear with that family. Verify partial
burst refusal, restart during emit, set/reset, and identical retry state across
both encodings. The two wire encodings themselves are useful alternatives, not
duplicate features that should automatically be deleted.

### D07 — Request lifetime is distributed across queues, maps, and callers

Evidence: PriorityPacketQueue.complete/abort (`src/router/iface/priority_queue.d:174` in the reviewed working tree)
call the frame callback while it remains in the in-flight container. Reentering
abort/teardown can find the same terminal frame again.
[ModbusInterface](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/modbus/iface.d#L549) additionally keeps
pending callback/correlation metadata; ModbusNode (`src/protocol/modbus/node.d:112` in the reviewed working tree)
keeps another pending request array, retry deadline and a backstop timeout.
Node response handling calls the consumer before removing its pending entry.

[HTTPClient](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/client.d#L103) has another request queue,
five-second timeout loop, and callback-before-removal response path. Its shutdown
only stops the connection; it does not settle/reset the request queue or parser.
[HTTPOneShot](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/package.d#L520) adds submitted/fired
bookkeeping and state-driven failure delivery around it. These are concrete
examples of the ownership problem identified in September, still present now.

**End state:** one owner of each accepted transaction, with a stable handle,
owner-scoped cancellation, retirement before external callback, and exactly one
terminal result. Separate queue patience, physical delivery, response deadline,
and retry policy explicitly; remove overlapping backstops once the responsible
owner guarantees progress. Share only this bookkeeping where it deletes code.
Modbus framing, HTTP FIFO semantics, Zigbee delivery grace, and device-specific
retry policy do not belong in one universal protocol state machine. Verify inline
completion, callback-triggered shutdown/cancel, late replies and reconnection.

### D08 — Observing a value and requesting a write are the same operation

Evidence: bindings subscribe to Element changes to perform writes and suppress
their own feedback with `who`, `_self_write`, or `_writing_from_poll`.
[Sync on_mirror_write](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/package.d#L2485) is explicit
that the local series already contains the proposed value before authority
acceptance, and refusal cannot undo it correctly. GoodWe has additional pending
write/readback state; physical acceptance is not equivalent to changing a local
value.

This forces every consumer to distinguish observation from intent after the fact.
It accumulates echo flags, provisional history, dirty markers, repeated write
queues, and ad hoc confirmation/status behavior. It is a design failure with
observable correctness consequences, not just excess code.

**End state:** distinguish an observation committed by its source from a write
request routed to its writable binding/authority. Keep a pending desired value
outside observed history until the relevant acknowledgement/readback contract
allows commitment. Share the authority gate and write-result vocabulary; preserve
protocol-specific physical verification. Delete the post-store interception and
redundant echo/pending mechanisms as their responsibilities move. This is already
tracked in sync/device and GoodWe TODOs; it should be a cross-project prerequisite.

### D09 — The event migration still carries the full polling architecture

Evidence: [Application.tick/update](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/package.d#L1010)
walks module pre/update/post hooks, async tasks, every device, and the binding
collection. Modules manually drive other collection roots.
[ActiveObject.do_update](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L1121) combines lifecycle
progress, failure retry, and running-object polling.
[Collection.create](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/collection.d#L229) and the CLI add path
also synchronously advance that machine to compensate for startup ordering.
HTTP server sessions use push input but still call `parser.update()` in their
sweep; the client and BridgeStream retain read polling.

Scheduling itself is a pair of arrays plus raw delegate identity. Callers repeat
armed/scheduled flags, cancellation, and shutdown bookkeeping across DHCP, binding
liveness, cron, API/fileserver cleanup, Zigbee and automation. Subscriptions have
similar repeated attachment bookkeeping. Such state is necessary under today's
API, but much of it restates membership the scheduler/registration already knows.

**End state:** explicitly scheduled lifecycle work, dependency wakeups and owned
timer registrations, then migrate actual periodic work to timers and completion
events. Keep the coarse heartbeat. Remove eager construction ticks only after
forward references and asynchronous startup no longer rely on execution order.
Delete collection/module running polls as their last users migrate; retaining a
global tick only to repair callback cleanup should not become the endpoint.
Do not start by substituting a heap for the timer arrays: ownership and duplicated
execution mechanisms are the larger problem. Verify backoff, disabled/destroyed
objects, async startup/shutdown, callback teardown, and idle behavior per tier.

The second pass found a specific reason that removing ticks piecemeal is not
enough: the Stream contract does not state whether RX push is actually supported.
Serial routes arrivals through `incoming()`, while DuplexStream forwards reads but
does not forward RX-handler registration, TLS still decrypts through update/read,
and file/USB streams are pull sources. TX already has an explicit page capability.
Define RX readiness/demand/push semantics for each transport and wrapper before
removing the compatibility reads. Files need a bounded demand-driven source, not
an artificial periodic reader. This refines the existing stream composition work.

### D10 — Bindings repeat the final decode-to-Element adapter

Evidence: [CAN](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/can/binding.d#L206),
[BLE](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ble/binding.d#L267),
GoodWe (`src/protocol/goodwe/binding.d:584` in the reviewed working tree), and
[Modbus](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/modbus/binding.d#L599) each branch on scalar/text/user
format, choose a scratch buffer, invoke the shared decoder, compare output format,
and either write records or box a Variant. They use different 64/256-byte limits,
timestamps, and feedback-suppression paths. HTTP and MQTT repeat corresponding
text/record publication mechanics. The shared gateway successfully consolidated
the codec, but stopped before the common observation boundary.

**End state:** one bounded binary observation adapter and one text observation
adapter beside the sample layer, with explicit source time, sender, output-format
conversion and failure result. Bindings retain wire field selection, sentinel
semantics, batching and protocol cadence. Delete their copied scalar/text/wide
dispatches. Do not introduce a templated binding superclass per protocol.

There is a smaller shared policy opportunity in frequency-to-cadence conversion,
but preserve genuine differences: Modbus realtime currently means opportunistic
1ms eligibility with PCP/DEI policy, whereas HTTP/GoodWe use 400ms. A single hard
coded frequency table would change behavior. Profile grammar compatibility is
another existing deletion target; migrate the external catalogue before removing
legacy access/unit/endian spellings.

### D11 — HTTP handlers have become miniature response transports

Evidence: [API SchemaTx](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/api/package.d#L113) and
[FileServer.Download](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/fileserver.d#L289) each own a
stream, header cursor, page producer, completion flags, offline subscription,
deferred cleanup scheduling, TX callback release, and HTTP resume-or-close logic.
Compare [cleanup_schema](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/api/package.d#L477) with
[cleanup_download](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/fileserver.d#L1095).
Small API/redirect/error responses still use whole-message `stream.write()`.

The HTTP server owns parsing, but applications own the transport half of a
response. Every new response shape must implement backpressure and lifetime
correctly. The recent streaming work makes the missing boundary especially clear.

**End state:** an HTTP-owned response operation takes status/headers, a bounded
body producer (or buffer/file source), framing mode and completion policy. It owns
header progress, accepted output, stream hooks, deferred parser resume, and
cleanup. Share those mechanics between buffered and streaming replies; keep file
I/O, schema iteration and chunked versus known-length framing explicit. Verify
partial grants, refusal, disconnect in header/body, owner shutdown, and pipelined
requests. Count generated pages as accepted output, not as proof of network drain.
If API retirement lands first, delete SchemaTx rather than first building an
abstraction solely to preserve it.

### D12 — Native IP's compatibility adapter independently owns transport state

Evidence: [IPModule.pre_init](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/package.d#L2091) installs
the socket backend. [socket.d](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/socket.d#L22) creates and
owns PCB slots, accept handling, close/free transitions, receive queues and
poll semantics. The event endpoint API in
[protocol.ip](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/package.d#L339) separately creates PCBs,
listeners and connection owners, with its own lifetime sweeps and port counter.
`TcpPcb` knows about both socket handles and event connection/listener owners.

These are two APIs to one engine, but currently also two places implementing
parts of engine admission/lifetime policy. The separate TCP ephemeral allocators
in socket.d:80 and package.d:2693 are a clear example. They each advance a counter;
there is no shared allocation authority between those entry points.

**End state:** put shared endpoint admission, port reservation and PCB retirement
at the engine boundary; make the socket facade a compatibility adapter over it.
Select compatibility services only when a consumer needs them. Preserve blocking/
poll behavior where exposed. Avoid wrapping every compatibility socket in a
managed Stream or adding an allocation chain to the native fast path. Windows
IOCP, POSIX readiness and native TCP are real backend differences; common code
should be their ownership contract, not a forced identical I/O implementation.

The IPv4/IPv6 address and route classes also repeat nearly identical property,
dirty-marking and route-generation code. Share that management policy where it
actually yields one body. Do not generalize the IPv4 bitmap pool and IPv6 prefix
delegation tree together: their allocation problems are materially different.

### D13 — DHCP's raw packet path duplicates IP/UDP extraction

Evidence: [DHCP client incoming_packet](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/dhcp/client.d#L444)
and [server incoming_packet](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/dhcp/server.d#L240) both parse
IPv4 version/IHL/total length, UDP protocol/ports/length, then DHCP framing.
These are long near-identical blocks. IP/UDP already has parsing/delivery paths,
and newer endpoint users receive ingress/destination metadata directly.

DHCP does require pre-address/broadcast/interface behavior. That justifies its
admission rules, not separate implementations of checked IPv4/UDP slicing. The
current duplication makes lower-layer validation fixes easy to apply unevenly.

**End state:** provide the required interface-bound, pre-address datagram receive
contract, or share a checked datagram view below the two DHCP consumers first.
Keep BOOTP/DHCP validation and client/server state machines separate. Delete the
copied extraction paths after validating initial broadcast acquisition, unicast
renewal, rebinding, relays and interface changes. Do not assume ordinary routed
UDP binding is sufficient for DHCP.

### D14 — Rate/counter policy is copied into both transport bases

Evidence: [Stream.heartbeat](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/router/stream/package.d#L127) and
BaseInterface.heartbeat (`src/router/iface/package.d:347` in the reviewed working tree) repeat the
same baseline, elapsed-time calculation, byte deltas, maximum tracking, and dirty
mask computation. Both also repeat link-up/down/reset behavior. A normalized
duplicate scan found the shared rate calculation directly.

**End state:** a small shared traffic meter owns rate arithmetic and sampling
state; each host maps changed fields into its property indices and adds its
packet/queue metrics. It should produce one non-templated arithmetic body when
both hosts are linked. Do not merge Stream and BaseInterface into one inheritance
tree: bytes versus packets, acceptance and completion are real distinctions.
Verify first sample, long pauses, reset, offline transitions and zero traffic.

### D15 — Device lifetime and profile lifetime are unresolved together

Evidence: Device destructor (`src/manager/device.d:422` in the reviewed working tree) clears
computations but does not own recursive component/Element destruction.
DeviceTable has create/open but no corresponding complete removal operation.
[ProfileBinding.shutdown](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/binding.d#L275) releases its
profile reference; [Application.release_profile](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/package.d#L1128)
only decrements a count. Zero-reference parses remain because surviving model
metadata/computations borrow their strings. Recorder cursors and links hold raw
Element pointers. Element-backed properties now do call teardown, so the broad
comment in element.d that there are no production callers is also stale.

Retaining everything currently avoids some dangling references, but prevents
profile unloading/replacement and complete device removal. It also spreads
immortal-lifetime assumptions into consumers that otherwise appear independently
managed. This is a resource/ownership design issue rather than a proposal to add
reference counts everywhere.

**End state:** define who owns a materialised tree and its profile-backed metadata,
how multiple bindings share it, and the order of removal notification, durable
handle invalidation, operator/subscriber teardown and storage reclamation. Use
EIDs for durable external holders; retain raw borrows inside explicit scopes.
Then remove fake release bookkeeping or make it release the final real borrower.
Replace the recorder's discovery scan with lifecycle notifications once those
notifications cover every creation/removal path. Verify repeated materialise/
detach/remove/recreate with active recording, links and sync subscriptions.

### D16 — Bridge and Modbus still carry each other's responsibilities

Evidence: [BridgeInterface.add_member](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/router/iface/bridge.d#L158)
casts members to ModbusInterface, looks up ModbusProtocolModule, and reads
`remote_servers` to seed its address table. `features.mk` explicitly includes
protocol/modbus in the switch source tier pending a fabric/control split.
The Modbus module mixes frame registration, interface creation, node/binding/
SunSpec registration, profile parsing, and remote-server identity management.

This is an inversion in the most reusable fabric: a bridge should learn a
protocol-neutral destination reachability relation. It should not know a
particular protocol module's control registry. Keeping the old exception also
keeps the Modbus separation harder than it needs to be.

**End state:** the interface/fabric boundary publishes destination reachability
(including initial/static entries and withdrawal); the bridge consumes it. Move
Modbus mapping ownership and changes to the Modbus side. Split fabric registration
from clients/bindings/profile services, then delete the bridge's Modbus imports
and the switch-tier dependency on the full Modbus directory. Verify mapping
addition/removal and member lifetime, not just seeding at attachment.
Bridge member removal currently asserts after mutating the member list; the
reachability/port-identity contract must cover removal before it is exposed as a
working operation. This is already part of the older bridge cleanup debt.

### D17 — A Packet is sometimes a self-relative owner and sometimes a value view

Evidence: [Packet.data and clone](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/router/iface/packet.d#L214)
use the page flag to choose a representation. The page-backed representation
[finds its Page](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/router/iface/packet.d#L424) by reading a ushort
immediately before `this`, then subtracting that offset from its own address.
`attach_packet` constructs that external backlink. Packet has no copy restriction
or copy-to-view conversion.

Existing consumers still make ordinary value copies:
[bridge flooding](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/router/iface/bridge.d#L782), tracked flooding at
line 945, [BLE transmit](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ble/iface.d#L306), Modbus transmit
and Zigbee transmit. A stack copy retains the page flag but has no corresponding
backlink before its new address. Its next data/length/clone operation therefore
interprets unrelated memory as its backing page. A real page-backed ingress
producer is the bare-metal BLE emulator's queued response at ble.d:667; it enters
the ordinary interface/bridge path through `on_incoming`.

This is a stronger instance of the requested architectural concern than a missed
copy optimization: a formerly ordinary packet value acquired an address-dependent
ownership representation while retaining the old value API. Several copies only
change headers and never inspect payloads, so they must be classified individually;
the existence of an assignment alone is not enough to claim that call site fails.
The transmit copies do invoke enqueue/clone, which reads the copied payload.

**End state:** separate a relocatable borrowed packet view from its owning page/
allocation handle, or otherwise make ownership and explicit view construction
enforced by the type/API. Keep independent per-egress header/VLAN views over shared
bytes; deleting every copy would incorrectly share those mutations between ports.
Remove the now-redundant const-to-mutable enqueue copies. The attempted probe copies
between two valid page allocations to expose the wrong-page resolution without
dereferencing arbitrary stack metadata. It is uncompiled because of the baseline
build failures. Verify owned/view assignment, cloning, queue admission, multicast
egress and page release, not just allocation and in-place prefix edits.

### D18 — Command presentation is carrying the mutation result contract

Evidence: [function_command_exec](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/function_command.d#L212)
prints a returned error string and returns the same null state used for synchronous
success. Collection add/set handlers similarly print failures. In
[Context.dispatch_current](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/command.d#L345), an unknown
command prints an error and returns normal statement completion.
[execute_script](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/console.d#L245) rejects parse errors,
but completed command failures do not become a script failure. HTTP command
execution and automation consume the same ambiguous result path.

Mutation mechanics are also repeated: CLI collection add allocates, checks the
name, applies setters, binds and eagerly ticks; BaseCollection.create implements
another version; sync inbound_create extracts/rewrites the argument list and
delegates to that version. Their name validation and error reporting differ.
This makes the CLI simultaneously an operator presentation and a configuration
engine whose callers cannot reliably interpret its result.

**End state:** one operation result containing success/error and any value or
asynchronous continuation, with textual output independent of it. CLI, API, sync
and automation adapt that result; scripts explicitly choose continue/stop behavior.
Use one construct/apply/validate/bind operation underneath the adapters, preserving
specific setter errors instead of collapsing creation to null. Define partial
multi-set behavior explicitly; do not promise rollback of physical side effects.
Delete adapter-specific construction and error reinterpretation. Validate a bad
name, bad property, missing dependency, unknown command, and asynchronous failure
through every entry point, including startup's final reported outcome.

### D19 — A schema default is inferred from the type instead of the declaration

Evidence: legacy [Property.create](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L187) assigns
`SynthDefault!(ReturnType!Getter)`, and
[SynthDefault](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L1639) returns the value type's `.init`.
This is independent of the object's field/constructor initialization.
[reset](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/base.d#L548) invokes that value's setter, ignores the
setter result, clears the assignment bit, and marks the property dirty.

Two current examples establish the mismatch. HTTPServer's fresh
`max-request-body` is 64 KiB, but its schema default is size_t.init (zero) and reset
sets zero, which removes the parser's buffering limit. RAService initializes its
interval to 600 seconds, but schema reset supplies zero; the interval setter
rejects values below four seconds, so reset reports completion while leaving the
old interval in place and clearing its explicit-assignment bit. Sync's reset
contract assumes the metadata default is the real value.

**End state:** a property declaration owns its default, storage initialization,
validation and unset/reset meaning. Constructor fields must not be an independent
source of the same default. Make reset a fallible operation and clear tracking
only after its chosen semantics succeed. The newer Elem/Default machinery provides
part of this structure, but D05's allocation issue must be fixed before a blanket
migration. Verify fresh construction, schema reporting, reset and remote echo agree
for nonzero, constrained, nullable and reference defaults.

### D20 — Format admission and actual serialization disagree

Evidence: [container_serialisable](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/ows.d#L39) accepts all
wall-clock formats except `ValueType.user`. Enum formats have an ordinary integer
ValueType plus `Desc.enum_`, so they pass. However,
[SeriesContainer.append](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/ows.d#L222) writes only primitive
type, kind, count, rate, stride and quantity unit into the format anchor.
[register_block_format](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/ows.d#L318) reconstructs that
primitive/quantity format without enum identity; `same_format` likewise cannot
distinguish those semantic descriptors. This is silent loss, not an explicit
unsupported-format refusal. The older TODO account that such series simply stay
in RAM does not describe this path accurately.

**End state:** a small shared semantic format projection/admission contract says
which descriptor information a boundary must preserve and whether it can do so.
Disk anchors need enum/name identity or an explicit refusal until implemented;
other process-local descriptors, codecs and reference kinds need the same admission
discipline. Keep disk and wire framing separate. Delete their divergent eligibility
rules and ad hoc metadata omissions as their supported projections converge.
Verify round trips with two different enums over the same primitive, changed
format runs, quantities, vectors and unsupported descriptors. Do not interpret
the fact that records are raw bytes as proof that their meaning survives transfer.

### D21 — Cooperative work has multiple unbounded run-to-quiescence engines

Evidence: [WhileLoopState.update](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/console/builtin_commands.d#L399)
loops until a child yields or the condition finishes. A true condition with an
immediate body never returns to input processing, so normal cancellation cannot
be consumed. `Context.update` similarly drains immediate statements without a
turn budget. Application.process_due drains due timers against its captured time;
[cron parsing](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/cron.d#L223) accepts a zero repeating duration,
whose callback schedules the same deadline again. Element.flush_pending drains
all cascading notification waves synchronously. Bulk posted events have a slice
budget, but this is not a common execution contract.

The system is cooperative while individual subsystems independently decide how
much work a turn may perform. That defeats the reactor's responsiveness despite
having event-driven sources, and encourages local throttles/backstops elsewhere.

**End state:** explicit bounded progress and cancellation for executable commands,
timer dispatch and propagation. Reject invalid repeating intervals at admission;
that is necessary but does not solve an immediate script loop. Share the turn/
continuation model so long finite scripts also yield. Preserve committed-frame
coherence when scheduling propagation, and detect/reject nonconverging operator
cycles instead of silently dropping updates. Delete local busy-drain workarounds
only when this contract covers them. Validate cancellation and network/heartbeat
progress under zero-duration configuration, large scripts and cascading updates.

### D22 — Observer lists do not share a mutation/lifetime contract

Evidence: [Element.deliver](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/element.d#L1541) saves `s.next`
before invoking a callback, while unsubscribe immediately frees the matching node.
Self-removal works, but removing the next subscriber leaves the saved pointer
dangling. BaseObject state and Component notifications use an array/swap-removal
iteration rule with different behavior when an earlier subscriber is removed.
The BaseObject source already acknowledges the skipped-handler case. Packet
subscribers use another fixed-array traversal, and individual consumers maintain
their own attachment flags and teardown routines.

These are repeated implementations of a core semantic question: what may a
callback remove or destroy, and which callbacks may still run afterward? Keeping
the rule implicit in container choice makes safe shutdown depend on the order
and details of unrelated subscribers.

**End state:** one explicit registration/dispatch contract, with removal during
dispatch preventing future delivery and storage retirement deferred until no
dispatch frame can reach it. Apply the tested mechanics to each required callback
shape; preserve bounded inline storage where useful. Avoid one template instance
per subscriber owner and avoid a heavyweight event bus. Keep existing explicit
subscription bookkeeping until the replacement API guarantees its lifecycle.
Verify self-removal, removing the next/previous subscriber, adding during dispatch,
nested notification and owner destruction across the event families.

### D23 — Streaming request teardown belongs to the HTTP session

After accepting headers, the parser keeps a chunk delegate. Successful end of
body delivers a final call. On peer loss the session drops the stream. The OTA
handler acquired a partition handle at begin and releases it on final, write
error or updater shutdown. An ordinary disconnect halfway through a PUT leaves
the updater running with its handle set. The next PUT gets 503. The fileserver
implements its own upload list, offline subscription and mount-shutdown stream
destruction to compensate for the same missing lifetime contract.
[Parser](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/message.d#L387), [disconnect](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/server.d#L797),
[OTA admission](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/ota/package.d#L201), [file cleanup](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/fileserver.d#L182).

Give each accepted body one consumer with chunk, finish and abort operations.
Session loss, parser failure and handler removal must end it exactly once before
its owner is freed. Keep file-path conflict checks and partition exclusivity in
their sinks. Verify mid-body disconnect followed immediately by another upload,
and handler removal followed by more input. This is the receive-side counterpart
of D11. The operation owns resource cleanup even when no response can be sent.

The OTA sink has a second, local progress defect. An accepted length of 1–9
bytes sets the reporting increment to zero. On Linux begin opens the staging
file before image validation, so a successful first write enters a progress
loop that cannot advance. Derive reporting from bytes received or skip reporting
for short bodies. Exercise these lengths alongside cancellation.
[Progress loop](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/ota/package.d#L249), [Linux begin](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/driver/linux/system.d#L58).

### D24 — Binding a scalar manufactures its first observation

CAN, BLE, OBD and the primary Modbus binding set the format, then box zero and
call Element.value when record_update is unset. For an ordinary numeric element
the setter supplies the current time and commits a record. A newly bound sensor
can therefore report a measured-looking zero before its first frame. For held
data the first real zero can then take the repeat path. The model already exposes
format independently of the last observation. [CAN](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/can/binding.d#L146),
[BLE](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ble/binding.d#L145), [OBD](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/obd/package.d#L271),
[Modbus](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/modbus/binding.d#L379), [value setter](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/element.d#L357),
[record presence](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/element.d#L522).

Delete the four seed writes. Declare any real command default separately. Check
that clients and computations accept a typed, unseen element, the first wire zero
is observable, and reattaching a binding preserves a prior genuine sample. This
extends D08/D10 to initialization. Sharing the four seed blocks in a helper would
preserve the wrong behavior.

### D25 — An outbound endpoint is repeatedly converted back into configuration

IPClient accepts a numeric address or hostname, splits an embedded port, applies
precedence, then assembles NamedArguments to create a managed TCP or TLS stream.
For TLS it formats the endpoint back into a string. TLSStream feeds that string
to another IPClient, which resolves precedence again to create the inner TCP
stream. TLSStream.remote returns the host field, which IPClient clears after
accepting a numeric literal. A successfully configured numeric TLS remote can
thus read back empty. Its TLS setup separately splits the hostname for SNI.
[IPClient.start](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/client.d#L102), [TLS property](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/tls/stream.d#L114),
[inner connection](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/tls/stream.d#L193), [SNI](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/tls/stream.d#L919).

Parse into a configured endpoint at the property boundary, retain the DNS name
where present, and apply the port override once. Pass the typed result to the
transport constructor behind the existing managed-object lifecycle. Keep the
resolved address as connection state. Delete the format/reparse leg and the
parallel NamedArgument branches. Verify DNS, IPv4, scoped IPv6, explicit and
default ports, numeric property readback, and TLS server-name selection on
supported backends. The resolver clearing its cached address on shutdown is
intentional. [TCP shutdown](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/ip/tcp_stream.d#L198)

### D26 — Profile sizing and parsing each express the grammar

The loader walks the config to size packed tables and string pools, then walks
it again to populate them. HTTP sections have separate count and parse methods
that split request lines and switch over the same subfields. The manager assigns
element kind/index before calling the section parser and ignores its boolean
result. CAN consequently checks a protocol-private invalid descriptor sentinel
again at binding time. The lookup builder also writes a block-local index into
a global table. A second elements/registers block starts indexing at zero even
though its descriptors were appended after the first block. The repository
profiles surveyed each had at most one such top-level block.
[Sizing](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/profile.d#L947), [lookup construction](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/profile.d#L1317),
[section dispatch](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/profile.d#L1363), [HTTP walks](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/http/package.d#L310),
[CAN admission](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/protocol/can/binding.d#L138).

Keep compact persistent tables. Use one grammar walk per section with a counting
or writing sink, or compact validated descriptors after parsing if scratch RAM
permits. Publish only successful descriptors, assign global indices once, and
define how unavailable protocols in a shared profile are skipped. Test two
blocks with distinct IDs, malformed fields, alias fallback and peak parse RAM on
a constrained target before choosing the compiler representation.

### D27 — Fleet membership has no durable transition result

On adoption the member updates its secret and cluster, calls a void save routine,
logs persistence, then acknowledges the claim. The save routine can return early
for length or only warn on write failure. Reset ignores deletion failure before
announcing factory state. A reboot can undo either reported transition. On the
authority, key minting calls the same save routine before offering that key to a
member. Losing it after a successful handover can strand a persistently adopted
member. [Member handover](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/peering.d#L376),
[reset](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/peering.d#L407), [authority handover](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/peering.d#L177),
[key storage](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/manager/sync/peering.d#L581).

Give fleet identity one load/replace/clear owner with a result. Commit durable
identity before advertising, handing over or acknowledging it. Distinguish an
explicitly ephemeral claim from durable adoption and make already-absent reset
idempotent. Exercise write and delete failures on each role across restart. The
existing NVS follow-up then adds a backend with the same semantics.

### D28 — Linux OTA success precedes the durable slot handoff

ota_end renames the image into place, then tries to create and write
openwatt.next. Even an open failure falls through to success. OTA sends 200 and
schedules reboot, while the supervisor selects a staged slot from that marker.
On promotion the supervisor clears the marker before persisting good/fail state
through a void writer. Interruption in that gap can select the previous good
slot again. The monitor also marks the slot good on elapsed time before handling
a watchdog timeout returned by the same poll. A timeout that crosses the soak
deadline can therefore promote and then kill the same child.
[Staging](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/driver/linux/system.d#L97), [HTTP completion](https://github.com/open-watt/openwatt/blob/66a70910d998bef0dd5c156fd5f5649406743e37/src/apps/ota/package.d#L261),
selection (`src/driver/linux/supervisor.d:76` in the reviewed working tree), promotion (`src/driver/linux/supervisor.d:212` in the reviewed working tree),
state writer (`src/driver/linux/supervisor.d:352` in the reviewed working tree).

Make stage and promote recoverable transitions with checked persistent results.
Preserve the Linux supervisor's independent watchdog. Evaluate child health
before promotion, and acknowledge staging only once a restart can discover the
new slot. Exercise failed marker creation, short writes, interruption on either
side of promotion, and heartbeat expiry crossing the soak deadline.

## Coverage and remaining confidence limits

Here, **traced** means implementation and relevant callers/lifecycle transitions
were followed for the stated question. It does not mean every line or malformed
input branch in those files was audited. **Sampled** means representative code was
read and tree-wide searches were used to look for the pattern. Neither means a
runtime or hardware pass.

| Area | Coverage | Questions followed |
|---|---|---|
| Assembly/build features | Traced | Constructor registrations, module phases, feature source lists, headless consumers, capability claims, import cycles |
| Identity/collections | Traced | Reserve/claim/rename/release, subtype resolution, root/subtype sharing, ephemeral names, iteration high-water marks |
| Object/property lifecycle | Traced | Create/set/reset paths, defaults, explicit tracking, state transitions, shutdown and callback order |
| Bootstrap/config/commands | Traced | Startup layers through parse/execute/completion, add/set adapters, sync create, automation/API result use, while/cancel |
| Console presentation | Sampled | Session lifecycle, Stream/terminal coupling, render/history ownership; line editor and graphics were not exhaustively reviewed |
| Model/operators | Traced | Existing-device extension, computation registration/relocation, binding detach, links, online sources, durable-holder lifetime |
| Typed data/sample layer | Traced | Descriptor compilation, scalar/text/user adapters, format identity and conversion boundaries; bespoke codec mathematics sampled |
| Series/recording | Traced | Bucket seal/borrow/reconstitution, retention/recording ownership, format anchors, adoption and recall; corruption/codec combinations not exhaustively tested |
| Logs/signals/cron | Traced | Fan-out retention/ack, subscription ownership, wall/monotonic scheduling, provider admission and cancellation |
| Sync | Traced | Legacy/model surfaces, encoder policy, handles, control/value/log queue ownership, startup/refusal/teardown and model writes; loss/reorder state space remains untested |
| Packet/bridge/VLAN | Traced | Borrowed versus page-backed representation, copies, queue completion, multicast views, membership and reachability seams |
| Streams | Traced | RX/TX contracts across base, serial, TCP, duplex, bridge, file, USB, Telnet and TLS; hardware backends and TLS cryptographic correctness sampled/excluded |
| Native IP | Traced | Endpoint/socket PCB ownership, TX queues, routing/source selection, ingress/demux, neighbor caches and address lifecycles; full TCP conformance excluded |
| IPv6/DHCP | Traced | Address/route/pool management, ND/SLAAC owner records, client/server raw receive and pre-address semantics; complete lease/prefix state space excluded |
| HTTP/API/fileserver/WS | Traced | Message/parser role, client FIFO and completion, server defer/resume, response producers, upgrade/session ownership; full HTTP/WebDAV conformance excluded |
| Other protocol bindings | Sampled | Modbus, BLE, CAN, GoodWe, MQTT, EZSP/Zigbee, ESPHome, OBD and PPP as consumers of the common mechanisms |
| Energy/automation apps | Sampled | Model/control references, domain metadata and command/signal execution dependencies; allocation/planning algorithms excluded |
| uRT/platform/vendor code | Sampled | Erased container cores, array relocation, pages, allocator/driver boundary and build cohesion; broad runtime/platform audit excluded |

Challenged concerns that did not become findings:

- Deferred HTTP input is not simply discarded: defer_response removes the RX
  handler, the base Stream buffers subsequent bytes, and resume reattaches it.
  Capacity policy still belongs to the response/stream contract, but the suspected
  immediate drop was rejected.
- IPClient dropping its temporary stream reference on offline is not by itself
  proof of a leak: ActiveObject destroys temporary objects when they leave Running.
- Clearing a cached TCP egress does not permanently suppress route refresh:
  refresh_route checks for a live egress/local delivery as well as generation.
- Similar IPv4/IPv6 pool names do not establish duplicate allocation algorithms;
  the bitmap address pool and delegated-prefix tree solve different problems.
- The current Makefile checks a flag stamp; the older blanket advice that feature
  flag changes cannot trigger rebuilding is not a reliable account of this tree.

The P1 failure chains above are source traces with explicit triggers. The
review probes did not execute. A full
protocol conformance audit, hardware matrix, malformed-input campaign and exhaustive
line review would be separate work. Confidence is high that the listed structural
issues deserve action; confidence that all major issues have been found is limited.

## Useful abstractions to retain

- The shared SampleDesc/record gateway is the right center. Complete its adoption
  before inventing another value-conversion system.
- Identity separated from wire handles is useful. Fix typed rebinding and
  ephemeral lifetime without making remote peers share raw process-local IDs.
- Page ownership, bounded producers and push I/O are useful foundations. Let
  them replace whole-message output and polling paths rather than coexist forever.
- Separate codecs are appropriate for genuinely different wire formats. Sharing
  their traversal/ownership policy is different from forcing one binary format.
- NeighborCache already shares family-independent mechanics. IPv6 ND/SLAAC,
  DHCPv4/v6, TCP/UDP, kernel mirroring and radio delivery each have real semantics
  that should remain explicit. A single giant networking state machine would
  increase complexity.
- Automation's provider URI interface and thin time shorthands demonstrate a
  useful pattern: lower alternate syntax to one representation early.
- uRT's Array/Map already have shared erased implementation cores. Do not infer
  that every template occurrence implies a full duplicate implementation or
  replace all containers on the basis of source counts.

Some architecture references also lag the implementation: the older CID/hash
description predates the monotonic allocator, and the Phase 2 list in features.mk
still names moved certificate code and protocol coupling that profile section
registration has already removed. Reconcile those references during the owning
migrations; do not rebuild a plan from their old paths. The current code, including
the new typed reference property path, is the evidence used above.

## Suggested execution order and deletion tests

1. **Repair owner/type invariants:** D01, D02, D03, D07, D22 and D23. Establish
   typed rebinding, stable callback owners, bounded ephemeral identity, terminal
   retirement and safe subscriber mutation. Those are
   prerequisites for safely deleting fallback machinery.
2. **Repair boundary contracts:** D18–D21, D24, D27 and D28. Give configuration a reliable result,
   make defaults/reset agree, preserve or reject semantic formats, and bound
   cooperative work. Fix the concrete reset, zero-interval and format-admission
   failures without waiting for the larger management/event migrations.
3. **Take bounded, core-wide consolidations:** D06, D10 and D14. Each has existing
   near-identical callers and an explicit implementation to remove. Avoid a
   framework whose first benefit depends on future adoption.
4. **Make composition honest:** D04 and D16. Make basic timed control available
   on Tiny independently of HTTP and OTA. Separate service registration and
   fabric/control ownership, connect headless to real capabilities, and build
   reduced tiers from declared dependencies. Retain necessary config execution.
5. **Finish transport ownership:** D11–D13, D25 and the HTTP client part of D07.
   Centralize HTTP output and native IP admission; preserve DHCP pre-address
   semantics. Migrate old read/write consumers as part of this work.
6. **Finish management convergence:** D05, D08, D15 and D26. Establish cheap
   property views, write intent/authority, and tree lifetime; migrate clients;
   delete object-mirror/API duplication and abandoned property machinery.
7. **Remove the legacy execution engine:** D09, incrementally as each owner
   migrates. This starts in earlier steps, but ends only when running-object,
   device and module sweeps can actually be deleted.

For each change, specify the functions/state/registrations that disappear in the
same series, preserve the behavioral contracts above, and compare deployable
representative builds after the change: small switch/headless, constrained
switch-IP, HTTP without TLS, and full host. Record actual release size rows under
the repository's normal ledger rule. A successful abstraction should reduce
independent ownership or policy implementations; shorter call sites alone are
not evidence of simplification.

`TODO.md` remains the work accumulator. This report is the evidence and rationale;
it does not create a second status checklist or implement the proposed changes.
