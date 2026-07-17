# UX client TODO - staying in sync with the instance

Running task list for the WEB and DROID client agents. The data-model / identity migration
(docs/DATA_MODEL.draft.md, src/manager/id.d header) changes the sync wire and client-visible
APIs in steps; each dated section below is one instance-side change set, appended as it lands,
with the concrete tasks a client must implement to keep working. Sections marked "no client
impact" exist so you can see the epic move without diffing the instance.

Context that holds for everything below: web/droid clients attach as sync peers over WebSocket
(JSON frames, `{"kind":"<verb>", ...}`) as CONSUMERS - they subscribe and mirror, they do not
announce objects of their own. There is no protocol version negotiation; client updates deploy
together with the instance update they track.

## 2026-07-17 - ids off the sync wire: session handles (BREAKING)

The instance no longer sends CIDs (numeric object ids) in any frame, and no longer understands
them inbound. Objects are introduced by name once per session and cited by a session handle
thereafter. Until these tasks are done, a client built against the old wire will not resolve
any object.

- [ ] **`add_name` reshaped**: was `{cid, name}`, now `{h, name, type}`. `h` is the session
      handle (uint), `type` is the concrete type name string (same vocabulary as the old
      `bind.type`). Build your object registry keyed by handle at add_name time; you now know
      the type before bind arrives.
- [ ] **All object-citing verbs carry handles**: `bind`, `unbind`, `destroy`, `state`, `set`,
      `reset` - the `target` field is a session handle, not a CID.
- [ ] **Handle parity rule**: a handle's LOW BIT says who allocated it relative to the frame it
      appears in: 0 = the frame's sender, 1 = the receiver. Consequences for a consumer client:
      - Handles arrive from the instance with bit 0 clear. Store `h` as your key.
      - When YOU cite an object in an outbound frame (`set`, `reset`, `destroy`), send `h | 1`
        (you are citing something the receiver allocated).
      - Since you announce nothing, every target you ever send is odd. If you ever DO announce
        (future producer role), you allocate even handles dense from 0 in your own space.
- [ ] **Session scope**: handles are valid for one attach. On disconnect, drop your entire
      registry; on reconnect the instance eagerly re-announces everything and handle values
      restart from 0. Never persist a handle.
- [ ] **Handles never rebind**: within a session, a handle whose object is destroyed is dead
      forever - you will never see it reused for a different object. Safe to key caches on it.
- [ ] **`rekey` verb deleted**: the instance never emits it and warns on receipt. Delete any
      client handling. (Renames currently do not propagate at all; when they do it will be a
      new `rename` verb `{target, name}` - a future entry here.)
- [ ] **`#<decimal>` / `$<hex>` subscription patterns deleted**: raw-id subscribe filters are
      gone. Use the name patterns only: `[=]<type>:<name>`, both halves wildcard-capable,
      `=` prefix for exact-type match (no ancestor walk).

Unchanged by this step: `create` (props carry the name), `cmd`/`result`/`error` (seq-correlated
text), `sub`/`unsub` (pattern string), `enum_req`/`enum`, `history_req`/`history` (path string),
`log_sub`/`log`, `time_req`/`time_resp`/`time_push`, and the per-property `set` flush shape.

## Upcoming instance work with NO client impact (for orientation)

- ID migration step 1 (park/claim/forward id machine) LANDED 2026-07-17 - in-process only,
  no wire change. Step 2 (container CID cutover, Devices as a container type) is next and
  equally invisible: the wire already speaks names + handles. Entries will appear here only
  if a verb or field moves.
- Heads-up for later steps (will get their own dated sections when they land): typed element
  series (Element2) will eventually reshape element value delivery and history recall
  (cursors/record blocks instead of `history` sample pairs), and device functions / Event!
  will add new verbs.
