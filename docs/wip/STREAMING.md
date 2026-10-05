# Bounded streaming: migration plan

Started 2026-10-05, restructured the same day after review. This document stages the work; it is
deleted when the last effort lands and whatever remains moves to [TODO.md](../../TODO.md).

Scope is both directions. Outbound, no producer renders a message before it is pulled; inbound,
no consumer holds a message before it is parsed; in between, no interface is handed a frame it
cannot carry. Three efforts, each justified and landable on its own, in dependency order:

- **A. Bounded streams.** Every byte producer is pulled, every sink is bounded, the producer
  lifecycle (idle, end, abort) is explicit, and receive is event-driven.
- **B. MTU-safe message delivery.** Sync sizes messages to a negotiated segment, fragments the
  rare message that cannot fit, and never hands an interface a frame it cannot carry.
- **C. Reliability and congestion.** The sublayer's fixed window and timers are replaced by
  packet-numbered acks, loss detection and a congestion window. Specified in its own document
  before any code; this file records only the decisions already taken.

Plus **D. Streaming parsers**, independent of the three.

## The fault

Senders build whole messages and push them into sinks that never refuse, and nothing above L2
reads the MTU. Both halves share one cause: the pull contract exists (`Stream.tx_handler`,
`BaseInterface.tx_handler`) but most producers do not use it and the sinks under it do not honour
it.

Three sinks absorb everything pushed at them:

- `TCPConnection.send()` (`src/protocol/ip/package.d:614`) copies any amount into pages with no
  bound. When the pool is capped, `page_alloc` falls through to the heap, so pool pressure
  surfaces as heap exhaustion, never as backpressure.
- WebSocket `_tx_pending` (`src/protocol/http/websocket.d:589`) holds 128 KB as one contiguous
  allocation, compacted on every drain.
- The sync encoders' `_buf` (`src/manager/sync/binary_encoder.d:1126`, `json_encoder.d:1350`)
  grows to the message; the sublayer then copies it twice more (`_rel_buf`, `SentFrame.bytes`).

Producers that already pull: fileserver downloads over 8 KB, `/api/schema`, the WebSocket drain
into TCP, and `/device/print` on PR #803. Everything else renders first: `/api/cli/execute`
(32 KB `MutableString` plus four copies), `/api/list` and `/get`, directory listings, PROPFIND,
MQTT retained replay (every retained message in one loop), HTTP client response bodies (no
limit), console output over telnet, `/system/fs/read`.

MTU: every interface declares a mostly correct `actual_mtu` (WPAN 125, CAN 8, CPC 256, BLE 247,
xram, Modbus 253) and nothing above L2 reads it. Sync advertises the constant
`max_frame_size = 65_536` in `hello`, parses the remote's value and discards it
(`src/manager/sync/package.d:1260`); `too_large` is never sent. The embedded IP stack refuses
datagrams over 1500 and never fragments. An oversized control frame over UDP or bare MAC is
retried eight times, the session restarts, the restart walks the same data and sends the same
frame: a permanent restart loop (`src/manager/sync/peer.d:211,240,545`). An oversized data frame
sits in the backlog until it ages out. Hosted builds hide all of this because the kernel
fragments IP.

Receive is in better shape: `rx_handler` delivers on arrival, the HTTP server and TCP use it, and
request bodies, MQTT packets and sync pre-start frames are capped. The deficiencies are narrower
and listed so they are not forgotten: six objects still poll `stream.read()` from `update()`,
the HTTP client accumulates whole response bodies with no cap, `parse_json` builds a full
`Variant` tree from them, and WebSocket reassembly is unbounded.

## Principles

- Migrate, never add beside. Each PR deletes what it replaces, in the same PR.
- No intermediate state is worse than the tree before it. A bound is enforced only after every
  writer it would truncate has been migrated; a size check is centralised only after the values
  it reads are clamped to hardware.
- The result reads as if designed this way; no compatibility shims, no `supports_x` probes.
- Binary size goes down. Each PR carries its ledger row and names its deletions.

## Copy budget

Bounding is not enough on its own; each path's copy count at the destination is a stated
property, and a copy that remains is named with its reason. This depends on the minimal-copy
packet work (urt #285 reference-counted pages, merged; #692 `Packet` as a view and #688
packet-sized pool categories, open; the page form of `RecvHandler` staged on #692) and extends it
to the byte path.

A page is a stream buffer: it carries bytes from where they are produced or received to where
they are consumed, and is recycled the moment it is spent. It is never a ring, a cache or a
store. A page is shared (reference-counted, cloned on write) only where the receive path forks:
a frame delivered to more than one subscriber, a bridge that forwards and delivers locally, a
tap. State that outlives the transfer (a retained MQTT payload, a series record, a held
configuration) is copied out of the page into its own storage and the page goes back to the
pool. A page is "in flight", and so legitimately held, until the receiver acknowledges it: TCP
and the sync sublayer retain the page until the ack, which is the one form of retention.

| path | copies at destination | in place | deliberate copy |
| --- | --- | --- | --- |
| producer into stream (print, file, API walkers, relayed page) | 0: the producer's page is the sink's page | chunked, WebSocket and Telnet framing in headroom and tailroom; `json_escape` tail-fill expansion | |
| stacked streams (Session, Telnet, TLS, TCP) | 0 except TLS | Telnet, Duplex, TLS on SChannel | TLS on mbedTLS: the record is built in mbedTLS's own buffer, so the bio send copies it back into the plaintext page, whose request reserved the record overhead; one copy, no extra page |
| TCP transmit | 0: the segment is sent from the page chain and the page is retained by reference until acked | | deletes the copy into `pcb.send_buf` (`tcp.d:465`) |
| sync submit | 0: the encoder writes into a segment-sized page, `raw_tx` wraps it as a `Packet` view, retention for retransmit is a page reference | bundling appends into the same page | |
| sync receive | 0 for whole and bundled messages, decoded from the received page | | fragments are copied into the one reassembly buffer; rare by B.3 |
| WebSocket | 0: frame header in headroom, payload page chained into TCP | | |
| drivers | 0 where the NIC gathers or DMAs from pages | | vendor paths that copy (ESP32 `esp_wifi_internal_tx`) are outside our control and noted per target |
| UART | 0: the interrupt feeds the FIFO from the lent page and releases it when done; RX lands in pages the interrupt allocates | short writes are packed into one fill page | the page pool is safe to take from and release to in an interrupt (urt #377) |
| receive into parsers | 0: readers tokenise the delivered slice; only a token cut by a boundary is carried | | |
| receive fork (tap, bridge plus local, several subscribers) | 0: the page is shared by reference, cloned only on write | | |
| sync reorder hold | 0: a held frame is still in flight and keeps its page until delivered | | |
| state that outlives the transfer (MQTT retained, series records) | 1, by design: copied into its own storage and the page recycled | | the copy is the point; a page is not a store |

A PR that adds a copy to any row names it in its description and in this table.

## A. Bounded streams

### A.1 Contracts

**Producer.**

```d
struct TxRequest { size_t bytes; size_t headroom; size_t tailroom; MonoTime deadline; }
enum TxStatus : ubyte { more, idle, yield, starved, end, abort }
alias SendHandler = Page* delegate(ref const TxRequest req, out TxStatus status) nothrow @nogc;
```

The sink asks for up to `bytes` of payload in a page carrying at least `headroom` and `tailroom`
free around it. The producer supplies the page: one it already owns (a received page being
relayed, the sync encoder's segment page, a file read straight into a page) or one it allocates
with `page_alloc(bytes, align, headroom, tailroom)`. The returned page transfers to the sink and
is exclusively the sink's: a producer handing over a page that is shared (a forked receive path)
first makes it unique with `page_unique`, which clones if needed, so every page below the
producer may be transformed in place. A held page that does not meet the request (over the
ceiling, short of the reserved room) is copied into a fresh page that does; zero-copy relay is
therefore conditional on fit, and the ingress case fits by construction (received pages are at
most one MTU with 128 B headroom, and a sink grants a whole page). `bytes` is a ceiling the
producer does not exceed; the sink over-asks when it wants to (a full page even when the driver
has less room) and retains what it cannot send yet, and never asks for fewer than
`min_tx_request` (64 B) since a smaller request cannot make progress through framing.

`status` qualifies every return, including a non-null one. With a page: `more` means further
pages follow and the producer stays armed, so the sink keeps pulling while it has room and time;
`idle` means this page and then nothing now, so the producer re-arms with `tx_handler()` when it
has more; `end` means this is the last page (below). Without a page: `idle`, nothing now, re-arm
as above; `yield`, the producer hit `deadline` before it had anything to hand over and is still
armed, so the sink re-pulls on its continuation (see Work bound);
`starved`: `page_alloc` failed; the sink parks on the
pool and re-pulls from `page_free`, so no producer carries a retry timer. `end`: the stream
is complete. A producer that knows a page is its last returns it with `end` set, and the sink
and filters finish their framing in that page's reserved room (FIN bit, terminating chunk). A
producer that only learns it is finished when asked again returns null with `end`, and the sink
or filter that owes a trailer makes one framing-only allocation from the smallest category; that
is the single exception to "filters never allocate", and it can `starve` like any other. `abort`
(no page): the producer failed. The sink disarms and adds no trailer; the producer's owner
terminates or restarts the stream, since only it knows whether the stream is a server session
(destroy) or a client link (restart), as the fileserver and schema endpoint already do. A
producer that wants out calls `release_tx_handler`, which detaches it without a trailer. A
producer learns of sink death through the stream's `StateSignal`, as the fileserver and schema
producers do today; the sink never calls a producer after `end` or `abort`. Every producer
allocates through `alloc_tx_page(req, bytes, status)`, which honours the request and reports
`starved`; `Session.provide_output_page` (#803) becomes a call to it.

**Sink.** A `Stream` owns a page queue bounded by a byte watermark. One producer per stream,
asserted. The sink pulls while headroom remains and the driver has space, passing a request
whose `headroom` and `tailroom` are what the sink's own framing needs; a page the driver accepts
only partly stays as the pending head (advance `Page.offset`) and is sent before the next pull,
so nothing a producer handed over is dropped. Drivers report drain from their completion event
(TCP ack or space, UART TX threshold, overlapped completion) and the base re-pumps.
`Stream.write()` goes: every writer, however small its output, owns its pending bytes and is
pulled, so there is no admission path that can refuse a byte.

**Filter.** A `SendHandler` that composes another and does not allocate, except the
framing-only trailer above. Its output, framing included, stays within the outer request's
`bytes`: it derives the inner request by subtracting its own framing from `bytes` and adding it
to `headroom` and `tailroom` (HTTP chunked: the length line in front, CRLF behind, and room for
the terminating chunk on every request so the last page can carry it; WebSocket: the frame header;
Telnet IAC and `json_escape`: tailroom proportional to the inner `bytes`, so they shrink it to
keep the sum within the outer ceiling), calls the inner producer, and transforms in place in the
page it gets back, writing framing into the reserved room and expanding escapes from the tail
forward. The terminal producer therefore makes the chain's one allocation, sized for everything
above it, and a chain holds exactly one page at any moment; exhaustion cannot deadlock it. A
filter that would need a second page is not a filter in this model; gzip was the only one and is
dropped. A filter propagates `end` on the page that carries it after adding its trailer, and
every other status unchanged.

**Pool.** Waiters are a FIFO; a waiter is removed when its stream shuts down. The pool keeps a
small reserve that only sublayer acks and connection teardown draw from, so acknowledgement and
close progress under exhaustion. Aggregate TX residency is the sum of the bounds that hold pages:
stream watermarks, TCP send windows (8 KB internal, 16 KB OS), and per-peer congestion windows in
C; the pool is sized per target from that sum and the figure is recorded in
[BINARY_SIZE.md](../BINARY_SIZE.md) alongside the image. TX pages are allocated without the heap
fallback once A.4 lands, so pool pressure is backpressure.

**Receive.** `rx_handler` is the only way bytes leave a stream.

**Work bound.** A sink that keeps up with its producer (loopback, a wide TCP window, a session
with no stream) would otherwise drain the whole producer in one event and hold the main thread
for it; #803's base `tx_request` does exactly that by design. The bound is a cooperative time
budget, and it is a contract both sides keep. A pump sets `deadline = now + tx_slice` (5 ms) once
per invocation and passes it in every request; it stops pulling when the deadline has passed. If
the producer is still armed and the sink still has room, the pump posts its own continuation
with `post_event(..., EventPriority.bulk)` and returns. Control events run before it, and every
other connection's continuation runs before its next turn because the bulk queue is FIFO, so
fast connections share the thread round-robin and none can monopolise it. A sink that is
genuinely paced (TCP window, UART threshold) seldom reaches the deadline, since its own grant
stops it first.

Continuations are bookkept so they cannot undermine that. A sink has at most one continuation
queued, tracked by a flag: while it is queued, a drain notification records nothing new and
leaves the pumping to the continuation, so a sink that is both draining fast and continuing does
not take two turns. `pump_tx` is not re-entrant (the existing `_pumping_tx` guard), so a drain
raised from inside a pump is absorbed by the running pump. The continuation is a timer scheduled
for the next loop pass (`g_app.schedule(getTime(), ...)`), so it runs after that pass's I/O, events
and timers; a bulk event that reposted itself would be dequeued again in the same pass and hold the
loop. A sink going offline cancels it with `g_app.cancel`.

Only the producer knows what a pull costs, so the producer enforces the deadline internally: it
checks the clock at its natural yield points (per row, per block, per file read) and bails out
when the deadline has passed, returning the partial page it has with `more` or, if it has nothing
yet, null with `yield`. The budget is cooperative: a check between rows cannot interrupt one
expensive row or one blocking read, so the longest a pump can hold the thread is `tx_slice` plus
the producer's longest indivisible step, and the contract is that no single step is unbounded. A
walker resumes by key, so a bail-out mid-walk costs nothing to resume; a pass over the whole
source that cannot be resumed is a contract violation. #803's `TablePrint.measure()` is one: it
walks every row in `start()` to fit column widths. It becomes resumable by the same key as the
print walk and runs as the producer's first pulls, returning `yield` until widths are known. S4
bounds it per top-level block (a device, an item), not per row: a large device is still one
step, `DevicePrint`'s filter rescans subtrees, and a resume re-walks the current device. Those
go with the walkers themselves, to the node/leaf model (TODO.md), whose row sources resume by key
and step per row. A filter passes the deadline through unchanged. The event loop's 50 ms `slow-bulk-event` warning
stays as the detector for a producer that breaks the contract.

Receive is not bounded by its input size: a bounded chunk can still trigger heavy processing or
fan-out. An `rx_handler` keeps the same cooperative budget. Fan-out is not done inline: a handler
that would deliver to many destinations (an MQTT publish to N subscribers, a sync change relayed
to several peers) enqueues into each destination's bounded producer queue (A.4) and returns, and
each destination's stream pulls under its own budget, so fan-out becomes TX work and is bounded
by the same machinery. Processing one message that can itself be large (applying a `bind` with
many properties, decoding a long JSON document in D) works in resumable steps and posts a bulk
continuation when it reaches the deadline, as a pump does.

One behaviour changes. #803 lets a print that completes during its own start finish in the same
call for `StringSession`, scripts and automation; with a work bound, a print longer than the
budget is latent for every sink. Context already polls latent children, so scripts and
automation still see it finish, a few events later instead of immediately.

**Traces.** The contract is checked against these sequences before it is implemented, and each
becomes a `Stream` unittest in A.2:

1. *Shared receive page through an escaping filter.* A frame arrives on a bridge with a tap
   attached, so its page is shared by two views. The relay producer is pulled through
   `json_escape` with `req = {1200, 0, 0}`; the filter asks it for `{200, 0, 1000}`. The producer
   calls `page_unique`, which clones because the tap still holds a reference, then finds the
   clone has no tailroom and copies into `page_alloc(200, 8, 0, 1000)`. One copy, by the
   conditions stated; the tap's view is untouched; the filter escapes in place.
2. *Oversized receive page under a small grant.* A 1400 B received page is relayed to a sink that
   grants `{352, 0, 0}` (its watermark is nearly full). The page does not meet the ceiling; the
   producer copies the first 352 B into a fresh page, returns it, and keeps the remainder as its
   own pending state for the next pull. The received page is released when the last byte is
   copied out. The sink retains the 352 B page as pending head if the driver takes less.
3. *Empty HTTP body.* The body producer is pulled once and returns null with `end`. The chunked
   filter owes the terminating chunk and has no page: it makes the framing-only allocation from
   the smallest category, writes `0\r\n\r\n`, and returns it with `end`. Had the allocation failed,
   it returns `starved`, the sink parks, and the same pull repeats from `page_free`.
4. *End after the previous page has drained.* A producer returned a page with `idle` (it was not
   sure it was done), the sink sent it and detached on the driver's drain, and the producer later
   re-arms, is pulled, and returns null with `end`. The sink has nothing pending; a filter owing
   a trailer takes the framing-only path as in trace 3; a sink owing nothing simply detaches. A
   producer that can know its last page is last (TablePrint does) avoids the extra round by
   returning it with `end`, which is why the status rides the non-null return.
5. *Two fast connections and a control event.* Two telnet sessions on loopback each start a
   37 KB print. Session A's producer spends its first pulls measuring and returns `yield` at the
   deadline; A's pump posts its continuation and returns, and B's does the same. An interface
   link-down posted as a control event in between runs before either continuation. A and B then
   alternate in turns of one `tx_slice` each until both end, and no single event exceeds the
   50 ms warning on the H7.

### A.2 The contract lands ahead of #803

#803 (`ow/print-tx-feed`) newly relies on the sink contract: its base `tx_request` grants 1600
unconditionally while running, so embedded serial accepts producers whose pages it writes short,
frees, and disarms; `TablePrint._done` is never set and the print hangs. Before #803 that case
truncated. Folding the fixes into #803 would make it five concerns at once, so they land first as
their own PRs (S1 to S3 in the execution sequence) and #803 rebases onto them as the console's
migration to the feed, dropping its own base `tx_request` change. The contract's parts:

1. `TxRequest`, `TxStatus` and the sink-less `SendHandler`; `alloc_tx_page` replaces
   `Session.provide_output_page`'s allocation; `TCPSendHandler` (`ip/package.d:335`) goes and
   `TCPStream.provide_tx_page` (`tcp_stream.d:289`) becomes a pass-through. `TablePrint` reports
   `end`.
2. The base sink keeps a short-written page as pending head and stays armed; `pump_tx` sends the
   pending head before pulling; drivers call `tx_drained()`. Serial is the first sink that
   short-writes, so this lands with it in S3.
3. `starved` and the pool waiter hook replace `Session.output_wake`, the WebSocket `produce_tx`
   20 ms retry (`websocket.d:720`) and the fileserver `Download` retry.
4. The work bound: `TxRequest.deadline`, `more` and `yield`; `pump_tx` stops at the deadline
   and schedules its continuation for the next loop pass, one per sink, cancelled when the sink
   goes offline; `TablePrint` checks the deadline per row, and its
   `measure()` becomes resumable and runs as the first pulls.
5. `SerialStream` is a sink on every platform: it lends its pages to the urt driver, which
   releases each as the line finishes it, Windows and Linux included. Settles "UART writes
   disagree on a full ring".

### A.3 Producers and filters

Each item replaces a whole-buffer path and deletes the buffer.

1. **HTTP body is a producer.** `HTTPMessage` carries a body `SendHandler`; `content` is the
   trivial one-page producer. `send_message` writes the head and arms the body; `format_message`
   (`message.d:928`, already marked TODO) goes. `Content-Length` when the producer declares a
   size, else a `chunked` filter (length line in headroom, CRLF in tailroom, terminator on `end`).
   `apply_response_encoding` goes: bodies are identity except one that fits a page, which may
   still be gzipped whole. Micro builds send `Accept-Encoding: identity` (streaming inflate needs
   a 32 KB window; `urt.zip` is whole-buffer).
2. **Fileserver.** `Download` is the file producer for every size; `buffer_threshold` goes.
   Listings and PROPFIND become resumable walkers over a directory cursor.
3. **API.** `SchemaTx`'s framing becomes the `chunked` filter. `StringSession` goes:
   `/cli/execute` runs a `Session` whose output is the response body through a `json_escape`
   filter (expansion 6x, so it pulls with hint = capacity / 6). `/list` and `/get` become
   resumable walkers keyed by device slot, as `DevicePrint` is.
4. **Console.** The remaining whole-table prints (14 `Table.render` sites) move onto
   `TablePrint`. `/system/fs/read` uses the file producer, removing the 2 KB `tconcat`
   truncation.
5. **WebSocket.** `_tx_pending` goes and the WebSocket is a sink like any other: its page queue
   is the `Stream`'s, a frame is a page with its header in headroom, and the page is freed as TCP
   takes it. An outgoing message is a producer framed by a `ws_frame` filter that sets FIN on
   `end`; a packet producer's page-backed `Packet` is queued as it stands. RX reassembly is
   capped at the session's advertised `max_message`; over it, close with 1009.
6. **MQTT.** Retained replay becomes a cursor over the topic trie pulled by the connection's
   drain; each replayed message is encoded from the trie's own storage into a fresh page. Packet
   encode stays per-packet; the 256 KB `parse_buf` cap stays.
7. **Sync encodes into pages**, once B.2 provides the segment: a frame is written directly into a
   page of segment size and `raw_tx` hands a page-backed `Packet`.

### A.4 Writer inventory, then the bound

`Stream.write()` is deleted, so before the bound lands every caller is listed and migrated to a
producer; there is no exempt class. A writer whose output is small still owns a pending queue
and is pulled: the console `Session` already is one (#803) and its prompt and echo join its
feed; an MQTT connection gets a per-connection packet queue pulled by the stream; the pcap
server (`pcap_server.d:562`) and the console relay become producers. SNMP and DNS send UDP
datagrams through `sendto`, not through a stream, and are outside this inventory.

Every pending queue a producer keeps has a byte or item bound and a stated overflow policy, and
the inventory records both; the pool bound does not bound these queues, since they hold the
writer's own state, not pages. The policies are the protocol's own: the console session drops
echo and redraws the prompt when its line queue is full, and a command's bulk output is already
pulled rather than queued; an MQTT connection whose queue is full drops QoS 0 publishes to that
subscriber and disconnects it when a QoS 1 or 2 message cannot be queued, as a broker does for a
slow consumer; the pcap server drops the frame and counts it; the console relay cuts the frame
and the receiver sees the existing lost-lines marker. A queue bound is a fixed count or byte
figure in the writer, never a proportion of free memory.

The inventory is a table in this document and is complete when `write()` has no callers; the
method is then removed, `TCPConnection.send()` is bounded at its watermark and TX pages lose the
heap fallback, in that PR.

### A.5 Event-driven receive

Migrate the pollers to `rx_handler`: `ModbusInterface.update` (`modbus/iface.d:453`),
`CANInterface.update` (`can/iface.d:406`), `Session.update` (`console/session.d:287`),
`DNSServer.update` (`dns/server.d:527`), `WebSocket.update` (`websocket.d:461`),
`HTTPMessage.update(Stream)` (`http/message.d:210`), `esphome.service_stream`
(`esphome/client.d:313`), the goodwe scanner. Then delete `Stream.read()`, `pending()`,
`flush()` and `_rx_buffer`. (`tx_backlog`, whose only readers are its own pass-through overrides
at `tcp_stream.d:274`, `telnet/stream.d:326`, `tls/stream.d:636`, `duplex.d:76` and
`ip/package.d:581`, goes earlier, with the contract in S1.)

### A.6 Verification

- `Stream` unittests: short-writing sink; exhausted pool with a parked stream freed by another
  stream's `page_free`; a chain of two expanding filters under a pool of exactly their output
  requirement; producer `abort` mid-body closes the connection; shutdown of a parked stream
  removes its waiter.
- `/device/print` and `/api/cli/execute` of a 37 KB tree under a 2 KB page budget on the H7 and
  RP2350 complete and are byte-identical to the unbounded output.
- Trace 5 on the H7 and on a hosted build: no `slow-bulk-event` warning from a pump or a print,
  including the measure pass of a 37 KB tree.
- A sink going offline with its continuation scheduled: the continuation never runs. A drain
  notification while a continuation is scheduled does not pump.
- An MQTT publish fanned out to 50 subscribers on a loopback broker: the publish handler returns
  within the budget and the subscribers drain in round-robin turns.
- Saturated bidirectional traffic (telnet print both ways over one link) makes progress on both
  sides.
- An ESP32 without PSRAM serving two stalled WebSocket readers stays within its budget and closes
  them with 1009 or by watermark, not by allocation failure.

## B. MTU-safe message delivery

### B.1 One size, checked once (#810, merged)

The interface size definitions (`l2mtu`, `l2_header`, `mtu`, `actual-mtu`, `max-l2mtu`, VLAN and
bridge) are in the interface properties of [CLI.md](../CLI.md); every `forward()` admits against
`actual-mtu`.

### B.2 Negotiated limits (#811, merged)

`hello` carries `max_frame`, the largest message the sender takes, and `segment`, the largest frame
it takes in one packet: the `actual-mtu` of the interface it sends on, less the carrier and less
the sublayer header where the sublayer is armed. A UDP endpoint takes the egress toward the peer's
own destination, or the IPv6 minimum link where a host stack names none. A producer reads the
limit from the interface it sends on and nothing below it: a VLAN's `actual-mtu` is already less
its tag, and a bridge's is the administrator's statement of the segment. Each side sends nothing
larger than its own segment and the remote's `segment` and `max_frame`; until fragmentation a
larger frame is refused before it is sequenced, which ended the restart loop. hello is fixed-size
(about 40 bytes; the names follow in `identity`) and is never fragmented; a peer that cannot fit
it fails to start. `max_frame` advertises a receive budget never below the advertised `segment`.

### B.3 Fit first

Producers size to the segment: `send_backfill` and `send_live_events` stop at the byte budget,
not at 256 records. The console relay sizes its frames to the segment and sends only while the
control window has room, keeping the rest in its stream's queue (#819, pulled forward from S10). The data plane's refold packs
the oldest unacked records that fit one segment and keeps the rest of the backlog for the frames
that follow; it never truncates the backlog to fit. Packing is not a guarantee, since a single
property, string value or `enum` can exceed the segment on its own, which is why B.4 lands first. Bundling several messages into one packet is Y3.

### B.4 Fragmentation, as a message

A message that does not fit the send limit is fragmented, on every carrier, as a message of its
own: the binary `fragment` verb, a flags byte (`more` set on every fragment but the last) and the
next slice of the encoded message. The verb and flags count toward `send_limit`. Fragmentation sits
above the carrier, so it works the same over a reliable transport and over the sublayer.

- **Ordering.** Reassembly relies on the control plane being ordered and free of duplicates for
  the whole session; the sublayer provides that on lossy links and the carrier on reliable ones,
  and C must preserve it when it replaces the reliability machinery. So a fragment needs no message
  id or offset: the receiver appends until the last.
- **Negotiation.** A peer fragments only toward a remote whose hello confirmed support
  (`model_protocol_version` 2). Until then, and toward a version-1 peer, Y1's refusal stands.
  hello itself is never fragmented. Mixed versions keep working without an incompatible state.
- **Budget.** The whole message is checked against the remote's `max_frame` before its first
  fragment is sent; a message over it is refused and logged, never started. `max_frame` is the
  receiver's reassembly budget: 64 KB, 8 KB on tiny targets.
- **Bounded, resumable sending.** A peer keeps at most one pending fragmented message, copied out
  of the encoder's buffer so the encoder can be reused. Fragments are submitted while the control
  plane has room (the sublayer's window, or the transport's `tx_ready`), and sending pauses on
  backpressure and resumes from the drain event; it is never a loop that pushes a 64 KB message
  past the window.
- **Serialisation.** Fragments of two messages never interleave. While a fragmented message is
  pending, other control messages are not sent: the bulk walks already pause when the control
  plane is blocked, and the peer counts a pending fragmented message as blocked. An event-driven
  control message encoded meanwhile is refused and logged like any other refusal (the encoders
  already report it); no unbounded queue builds behind the pending message.
- **Receiver.** Accepted fragments are kept until the last or until the session ends; there is no
  timeout that drops an acknowledged prefix. A reassembly that would exceed the advertised budget,
  a malformed fragment (a continuation with nothing open, or a first fragment while one is open) or
  a fragment inside a fragment resets the session. Other messages arriving mid-message are
  dispatched as usual: data frames may run between fragments, and the sender holds back control.
- **Data plane.** A val or log message that cannot fit one segment is sent on the control plane,
  where it can be fragmented.
- **JSON.** JSON runs over WebSocket, which carries whole messages, and does not fragment; it is
  still held to the remote's `max_frame` and refuses a message over it.
- `history` stays for JSON clients over WebSocket. Its removal is frontend-affecting and waits on
  a migration action in [UX_TODO.md](UX_TODO.md) moving clients to `model_sub from/to`.

### B.5 Versions

`model_protocol_version` 2 means the peer understands `fragment`. There is no envelope change: a
version-1 peer receiving a fragment would drop it as an unknown verb, which is why a peer only
fragments toward a version-2 remote. `docs/SYNC.md` records the version.

### B.6 Verification

- A message larger than the control window (a 64 KB message over a 125-byte segment) arrives
  intact, sent across several drain events.
- Backpressure halfway through a fragmented message pauses it and the next drain resumes it; no
  other control message interleaves.
- A lost and a duplicated fragment under the sublayer: retransmission fills the gap and the
  duplicate is discarded below reassembly; the message arrives once.
- A session reset during reassembly discards the partial message and the new session starts
  clean; a stray continuation resets the session.
- A message over the remote's `max_frame` is refused before its first fragment, and the session
  stays up.
- Mixed versions: toward a version-1 peer nothing is fragmented and oversized messages are refused
  as in Y1; two version-2 peers fragment.
- The refold packs what fits and keeps the rest; a backlog larger than one segment drains over
  several frames.
- Sync over `/interface/xram` (1856) and WPAN (125) on hardware.

## C. Reliability and congestion

Replaces the sublayer's fixed 64-frame window, 250 ms doubling retransmit timer, 8 retries, and
the data-plane refold, which re-sends the whole unacked backlog in every frame and so grows with
loss. This effort is specified in its own document before any code, with the invariants below as
its starting constraints; the review of this plan found the first sketch unsafe on packet-number
wrap and on fragment numbering, and those are now decisions, not assumptions.

Decisions taken, and the constraint the specification must discharge:

- **Packet numbers** are strictly increasing per session and never reused. Truncated wire
  encoding with reconstruction cannot by itself reject a duplicate delayed past half the encoding
  space, so the specification must state a packet lifetime bound (the carrier's maximum segment
  lifetime, 2 minutes for IP) and show that lifetime times the peak packet rate is below half the
  wire space, or carry a wider number. At 24 bits on the wire that bound is 70k packets per
  second, which no sync carrier approaches; at 16 bits it is 273, which a LAN exceeds. The width
  is chosen in the specification by that arithmetic, not here. In-flight packets are bounded at
  2^14 regardless of window, and a packet below the ack horizon (largest acked minus the bitmap
  width) that is still unacked is declared lost.
- **Version.** C changes the sublayer header, which precedes hello, so it needs a discriminator a
  version-2 receiver reads before hello; the specification settles it, with a version-2 peer's
  behaviour toward a version-3 one.
- **Fragments** are messages above the sublayer (B.4) and rely on an ordered, duplicate-free control
  plane, which C must preserve.
- **Loss handling per plane.** Control: re-queue in a new packet, deliver in order. Latest-value
  val: mark dirty, send the current value. Events and backfill: re-read the block by series index;
  if the block has been evicted, send an explicit `gap` message carrying the lost range, which is
  the discontinuity semantics epochs carry today, now addressed per range rather than per plane.
  Log: count and emit the lost-lines marker. A handle enters the val plane only after its `add`
  is acked. The backfill cursor advances on ack, not on submission, and tracks the lowest unacked
  block; out-of-order acks are fine because blocks are addressed by index.
- **Congestion window**, bytes per peer, NewReno as in RFC 9002 section 7, as the pull grant;
  strict priority control, live val, backfill, log; grows only while filled; resets after idle;
  pacing over the RTT. RTT per RFC 6298, loss per RFC 9002 (threshold 3, 9/8 RTT, probe timeout).
  Dead peer after N probe timeouts.
- **Deletes**, once landed: refold, `tx_epoch`/`rx_epoch`/`epoch_acked`, `backlog_max_*`,
  `backlog_ttl_ms`, `data_flush_ms`, `retransmit_ms`, `max_retries`, `control_horizon_ms`,
  `max_unacked`, `control_reserve`, `DataEntry.payload`, `_rel_buf`, `SentFrame.bytes`.

Verification the specification must include: packet-number wrap at 2^16 and at 2^32, delayed and
duplicate acks beyond the horizon, lost middle fragment with retransmit under new numbers, evicted
replay data producing `gap`, mixed-version peers rejecting cleanly, saturated bidirectional
traffic, a bridged ethernet-to-radio path shrinking the window.

## D. Streaming parsers

Independent of A to C.

1. `JsonReader`, a pull tokenizer shaped like `XmlReader`; `parse_json` is rebuilt on it so there
   is one tokenizer.
2. Both readers resume across chunks: `feed(chunk)` yields events until input runs out. A string
   is delivered incrementally as `text` events, so no token needs a carry larger than the longest
   escape (6 B) plus a number. Nesting is bounded at `max_json_depth`. A consumer that captures a
   string declares its cap; the HTTP binding caps at the element's text register size and marks
   longer values truncated.
3. The HTTP client delivers its body to a sink; `max_buffered_body` is set; `handle_encoding`'s
   whole-body inflate goes with the identity `Accept-Encoding`.
4. The HTTP binding compiles profile paths **and the paths `success_expr` references** into one
   segment matcher, captures as tokens arrive into staging bounded by the number of compiled
   paths, evaluates `success_expr` over the staging at end of document, and commits on success.
5. MQTT and HA discovery payloads decode through the reader without a tree.

Verification: fixtures split at every byte offset decode identically; a 1 MB string value in a
skipped path costs no memory; a captured string over the cap is truncated and flagged.

## Execution sequence

Each PR carries one or two concerns. It may be a broad refactor across many files, provided every
change in it serves those concerns. Each PR stands on its own: it builds and passes on every
platform, leaves no state worse than the tree before it, deletes what it replaces, and carries
its release ledger row, its doc updates and its TODO.md reductions. A urt change is never its own
PR; it rides as a submodule bump in the PR that needs it, with the urt PR landing first.

Tracking: when a PR lands, its row gains the PR number and the design text it consumed is deleted
from the sections above, in that PR. The document shrinks to what remains and is deleted with the
last PR; anything left over moves to TODO.md.

Five tracks. S is the spine and runs in order; the others start when their prerequisite lands
and can run in parallel with each other.

### Track S: stream contract and producers

| PR | concerns | needs | deletes |
| --- | --- | --- | --- |
| S1 (#807, merged) | producer/sink contract; allocation wait | | `TCPSendHandler`, the `Stream sink` parameter, the WebSocket and producer retry paths, `tx_backlog` |
| S1b | filters work in place | S1 | Telnet and TLS output page chains |
| S2 (#816, urt #376) | cooperative work bound | S1 | whole-producer drain in one event |
| S3 (#815, urt #377, #375) | serial is a sink on urt's UART driver, on every platform | S1 | short-write truncation on UART, `supports_tx_pages`, the UART rings, the polled serial RX path, the Windows and Linux serial code |
| S4 (#817, #803 rebased) | console print pulls | S2, S3 | `/device/print` and collection print whole-table renders |
| S5 | remaining console prints; `/system/fs/read` | S4 | 14 `Table.render` sites, the 2 KB `tconcat` truncation |
| S6 | HTTP response body is a producer; fileserver on it | S2 | `format_message`, `apply_response_encoding`, `buffer_threshold`, whole-buffer listings |
| S7 | API on producers | S4, S6 | `StringSession`, `SchemaTx` framing, the 32 KB limit, whole `/list` and `/get` |
| S8 | WebSocket is a plain sink | S2 | `_tx_pending`, unbounded RX reassembly |
| S9 | MQTT on the pull path | S2 | retained-replay burst, inline publish fan-out |
| S10 | `write()` removed; TCP bounded | S5 to S9 | `Stream.write()`, unbounded `send()`, TX heap fallback |

- **S1** (#807, urt #372) is the broadest. `TxRequest` (bytes only), `TxStatus` (without
  `yield`) and the new `SendHandler`; `pull_tx_page`, shared by `Stream` and `TCPConnection`;
  `alloc_tx_page`; `min_tx_request`; `starved` with the pool waiter (urt page-pool hook). Every
  existing producer and filter migrates mechanically in the same PR: the fileserver `Download`,
  `SchemaTx`, the WebSocket drain, Telnet, TLS, Duplex, TCP. `tx_backlog` goes here because it is
  dead contract surface. Serial keeps reporting no grant, as today, so nothing reaches the pull
  path that cannot drain, and pending-head retention waits for S3, its first user.
- **S1b** makes the filters work in place: `TxRequest` gains `headroom` and `tailroom`; Telnet
  reserves tailroom for IAC escaping and carries the rare overflow as its own pending bytes; TLS
  reserves the record overhead in the request and copies the ciphertext back into the plaintext
  page after mbedTLS has taken it (SChannel's `EncryptMessage` is in place already). Their page
  chains and output allocations go.
- **Order after S1.** S3, then S2 immediately before S4: `deadline` and `yield` have no consumer
  until `TablePrint` (S4) checks one and returns the other, and `TCPConnection` already bounds itself
  (#804). S1b can land any time after S1; its in-place saving covers the pull path, while TLS keeps
  its queue for `write()` until S10 removes `write()`.
- **S2** adds `deadline`, `yield` and the one-per-sink continuation on the next loop pass. `TCPConnection.service_tx` already bounds itself (#804: 64 KB or 2 ms, resuming on
  the next loop pass); S2 replaces that private bound with the general deadline, so there is one. It is separate because it changes how long a pump runs, a different question
  from what a pump carries.
- **S3** makes `SerialStream` a sink, and grew past the plan in review into two urt PRs. urt
  #377 makes the page pool safe to allocate from and release to in an ISR: a lock-free stack per
  size category in front of the slabs, which background maintenance tends. urt #375 is the whole
  UART driver shape on top of it. Every backend owns only its FIFO and moves every byte in
  pages. A send lends the driver a page chain, and the ISR releases each page as it finishes it,
  so there is no reclaim step; `uart_write` packs short writes into a fill page the ISR takes when
  it runs dry. RX fills pages the ISR allocates, sized to the line and adapting to its load, and
  tags each frame's end at the page's tail; `uart_burst` reads the bursts back with their times.
  Ports are found by name, take new settings while open, and report modem lines and counters.
  Windows and Linux become backends of the same driver on an I/O thread; they report no gap,
  since a USB adapter's blocking hides the line's quiet. MT7621 moves onto its interrupts, BK7231
  refills TX from a timer since its TX interrupt never fires, and ESP32 drops the IDF driver for an
  ISR on the shared core. The openwatt half: one `SerialStream` on the driver for every platform
  lends its pages and delivers bursts dated by their end, so the polled RX path, the serial retry
  and the per-OS serial code go; the base queue serves the other sinks.
  RS485 in the driver on the backends without hardware DE waits on a decision about timing DE
  where a part has no transmit-complete interrupt (TODO.md). Serial was the last stream that could not drain,
  so `supports_tx_pages` and its refusal branches go here, with TLS's `push_pending` (the branch
  that pushes ciphertext to a stream that cannot be pulled; S1 marks it with a TODO). Duplex has
  the same latent fault today: it accepts a producer over any `_tx` and registers on it without
  checking that `_tx` can be pulled, so a producer over a Duplex onto serial stalls; S3 removes
  the cause.
- **S4** is #803 rebased: `TablePrint` with per-row deadline checks and a `measure()` resumable
  between top-level blocks, `Session.feed_output` on `alloc_tx_page`. Bounding steps inside a
  block is left to the node/leaf model, which replaces the walkers; S4's aim is the output burst. Its base `tx_request` change and `supports_tx_pages`
  removal drop out, since S1 and S3 own them.
- **S6** and **S7** are split by consumer: S6 is the server-side body model and its first user,
  the fileserver; S7 is the API, which also needs S4's session feed for `/cli/execute`.
- **S10** begins with the writer inventory table in A.4 and lands only when the table has no
  unclassified caller. The pcap server migrates here as the last writer. The console relay's
  part (grant by control-window room, cut at the segment on code points, resume on the ack) was
  pulled forward as #819, since remote consoles between nodes lost output until it landed.

### Track R: receive is event-driven

| PR | concerns | needs | deletes |
| --- | --- | --- | --- |
| R1 (#814) | pollers on `rx_handler` | | `Stream.read()`, `pending()`, `flush()`, `_rx_buffer`, six `update()` read loops |
| R2 | every source raises its receive event; ISR posts never drop | R1, S3 | `Stream.poll_rx()`, `rx_poll_interval()`, the serial ISR-retry `update()` |

R1 is independent of S and can land first; it is large but one mechanical concern. It leaves the
sources with no receive event today polling themselves through `poll_rx()` while a consumer is
attached. R2 gives each one its event. A memory buffer delivers once when the consumer attaches. A
file replay delivers a turn at a time and continues on the next pass. Console input comes from a
reactor watch on Linux and a registered wait on Windows. The IDF USB drivers use their RX callback
or interrupt. Serial has its events already: S3 put every UART backend on its interrupts. An
ISR whose event post is refused links its own intrusive node onto an overflow list the reactor
wake drains, so a refused post is retried without a tick; that retires `SerialStream`'s retry
flag and ethernet's dropped wake.

### Track M: MTU sizes

| PR | concerns | needs | deletes |
| --- | --- | --- | --- |
| M1 (#810, merged) | size definition; central admission | | per-driver oversize checks, `l2mtu` setter, OS refresh writing `l2mtu` |

Independent. B.1 records the definitions #810 implements.

### Track Y: sync over a segment

| PR | concerns | needs | deletes |
| --- | --- | --- | --- |
| Y1 (#811, merged) | hello negotiates `segment` and `max_message`; frames over them refused, not looped | M1 | `max_frame_size`, the restart loop |
| Y2a (#812, merged) | fragmentation as a message, negotiated by protocol version 2 | Y1 | frames lost over the segment |
| Y2b (#813) | messages fit the segment: byte budgets and refold packing | Y2a | fixed record counts, the whole-backlog refold |
| Y3 | bundling | Y2b | |
| Y4 | sync encodes into pages | Y2b, S1 | encoder `_buf` growth, `_rel_buf`, `SentFrame.bytes` copies, the `_frag_tx` copy and `_frag_rx` buffer |
| Y5 | `history` retired | Y2b, UX migration | single-frame `history`, `max_history_points` |
| C0 | reliability and congestion specification (document only) | Y2b | |
| C1 onward | per the specification | C0 | refold, epochs, fixed timers |

- **Y1** only rides compatible hello tail fields: no wire break. Limits are stored and honoured
  for refusal before a frame is sequenced, which ends the restart loop; frames that cannot fit are
  lost until Y2a fragments them.
- **Y2a** lands fragmentation first, since without it one oversized value is still lost; until
  **Y2b** sizes the producers, large blocks fragment rather than fit. It is not a wire break: a
  `fragment` is a message, sent only toward a version-2 remote (B.5).
- **Y5** waits for the UX_TODO action that moves clients to `model_sub from/to`.

### Track D: streaming parsers

| PR | concerns | needs | deletes |
| --- | --- | --- | --- |
| D1 (urt #374) | `JsonReader`; `parse_json` rebuilt on it | | the second JSON parser |
| D2 | readers resume across chunks | D1 | whole-document precondition on `XmlReader` |
| D3 | HTTP client body is a sink; identity `Accept-Encoding` on micros | D2 | whole-body client accumulation, `handle_encoding` inflate |
| D4 | HTTP binding matches paths as tokens arrive | D3 | the `Variant` tree in the binding |
| D5 | MQTT and HA discovery payloads through the reader | D1 | trees for those payloads |

Independent of the other tracks throughout.

### Suggested first moves

S1, R1, M1 and D1 have no prerequisites and touch disjoint code, so they can be in review
together. S1 is the one everything in S waits on, so it goes first in your queue.

The TODO.md entries this plan reduces as it lands: "Bound the TCP push backlog" (S10), "The
websocket's 128 KB hard bound" and "WebSocket TX should retain frame descriptors" (S8), "Make
backpressure a channel property" (Y2b), "UART writes disagree on a full ring" (S3), "Move
WebSocket RX off the tick" (R1), "Fix `/device/print` on non-terminal sessions" (S7).

## Open decisions

- Whether `/cli/execute` is a `Session` over an HTTP body sink or the body producer pulls the
  session; the first keeps one session type.
- The hello floor, after measuring the current binary hello.
- **Atomic source views for resumable producers** are a future challenge, not part of this plan;
  the node/leaf model's point cursor (copy-on-write of a value changed after T) is the planned answer.
  A walker that resumes by key sees the source as it is at each pull, so a device or component
  changed between pulls tears across the output; a whole-message buffer gave a consistent view
  for free. #803 accepts tearing at block boundaries for prints. Producers whose consumers need
  one consistent view (a sync `bind` of all properties, a `/api/list` consumed as a document)
  would need the source to offer a snapshot or a generation check, and that belongs to the data
  model, not to the stream contract. Recorded in TODO.md.
- The pool reserve size and whether it is a category or a count within the smallest category.
- Streaming compression on the reliable plane and delta coding in `val_block` wait for C; the
  compressor must be a small-window LZ (heatshrink class), since `urt.zip` is whole-buffer and its
  hash table alone is 16 to 32 KB.
