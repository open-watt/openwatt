# Taps and Tunnels: remote interfaces and capture views

Status: design exploration on ow/dm-props. Companion to SYNC_PROTOCOL.draft.md (the model plane)
and PROP_ELEMENTS.draft.md (properties as elements). Nothing here is built.

Two demands look like one ("remote interfaces should be accessible as if they were our own") but
have opposite requirements, and forcing one mechanism to serve both would wreck it for each:

| | participation (bind to a remote port) | observation (capture view) |
|---|---|---|
| direction | bidirectional | rx-only |
| loss | unacceptable (transactions) | acceptable, must be HONEST |
| latency | per-frame, low | per-tick flush is fine |
| consumer | a protocol binding / the fabric | a passive UI, read-only |
| natural home | packet fabric | model plane |

## Taps: capture is a point-series element

Every Stream and BaseInterface grows a built-in element (`tap`), `SeriesKind.point`, whose records
are the frames (interfaces) or read/write chunks (streams). This is the series contract's declared
direction ("waveform/byte/packet taps host the same formats without becoming elements") taken one
step further: the tap IS an element, because then the whole built model surface serves capture
with no new verbs:

- `sub {mode:all}` -- live follow (`mode:all` is already forced for point series; no coalescing).
- `sub {once, from, to}` -- historical capture query over whatever retention holds.
- `retention` -- the capture window, set per tap, zero when nobody asked.
- `lost` -- overrun honesty; a capture that skipped frames says so instead of lying.
- Access -- taps are `Access.read`; a passive UX is just a subscriber, no participant machinery.
- Remote -- a satellite's tap mirrors through the hub like any element; the UX cannot tell.

The existing producers converge instead of multiplying: serial's `has_tap`/`write_to_log` sites
and the PCAP tap/server become writers (or consumers) of the same element. One capture spine,
three faces: wireshark via pcap_server, UX via sync, recorder via db.

Costs: one Element per stream/interface (~100 bytes today, ~48 after the descriptor split), zero
series storage until someone sets retention or subscribes. Record writes only happen while a
subscriber or cursor exists (the `_subs`/cursor checks already gate this shape cheaply).

### Substrate gaps (the actual work)

1. **Dynamic blob records.** Text records exist (TextRecord: embed or String handle); the
   equivalent dynamic `u8` blob record (count=0) is declared in the format vocabulary but not
   implemented in the store. Packet payloads need it. Same embed-or-handle shape as text.
2. **The tap record format.** Bytes plus a small fixed prefix: direction (rx/tx) and, for
   interfaces, enough framing identity to decode (the interface's PacketType plays the role of
   pcap's linktype, cited by the tap's DataFormat so a viewer knows how to parse). Keep it
   opaque bytes past the prefix; protocol-aware decode is a viewer concern, not a store concern.
3. **Wire form for blobs.** `owsig.container_serialisable` must pass the blob format; the JSON
   encoder needs a bytes encoding (hex or base64); the binary encoder carries them raw.
4. **Rate bounding.** A busy CAN bus is thousands of frames/s; `rate`/`deadband` do not apply to
   point series by design. The protections are retention ceilings plus `lost` -- same posture as
   flow control in the sync draft: honesty over buffering. A JSON/websocket viewer that cannot
   keep up sees `lost`, not silent gaps.

## Tunnels: participation is a packet-fabric interface

The load-bearing case: a switch-tier satellite (`FEATURES=switch`, the BL808 M0 shape) has the
niche port but NO protocol modules by design; the master has the protocols but not the port.
"Run the binding where the port is" is not available on that tier, so the master must reach the
remote port -- and a protocol transaction cannot ride a feed that flushes at end of commit each
tick (up to one tick of latency per hop per direction, and model feeds may coalesce or report
loss; both are wrong for request/response).

So participation does not touch the model plane at all. The shape is a **proxy interface** on
the master plus a **dataplane channel** on the peer link, and most of it already exists:

**The proxy is the is_remote mirror.** Remote objects already suppress their entire backend:
`do_update()` and `restart()` early-out on `is_remote`, so startup/shutdown/update never run,
and lifecycle state arrives via `set_remote_state`. With element-backed properties the property
half dissolves into ordinary element sync: a proxy's property elements ARE mirrored elements. A
write at the proxy routes to the authority and the element updates when the applied value echoes
back (the sync draft's non-optimistic `set` contract); side effects are authority-only -- the
proxy's `prop_element_changed` skips `on_change` hooks on remotes (built), so an echo never runs
reconfigure-in-place handlers against hardware that is not there.

**One connection, two prioritized channels.** Control verbs and dataplane frames interleave on
one foreign transport: one socket to authenticate and reconnect, dataplane frames as their own
frame kind that jumps the sender's queue. Head-of-line blocking is bounded by `max_frame`, which
`hello` already negotiates -- a peer carrying a tunnel negotiates it down. On the sibling
transport the answer inverts: no interleaving, a separate packet-sized SPSC ring beside the
control ring. "Two channels per peer" is the abstraction; whether they share a pipe is the
transport's decision.

**Forwarding is subscription-driven, and the machinery lives in the tunnel endpoint, not in
Stream/Interface.** `BaseInterface.subscribe(handler, PacketFilter)` already is the dispatch. A
consumer binding to the proxy causes a subscribe control message upstream; the satellite's
tunnel endpoint then registers an ordinary local subscriber on the real interface whose handler
encodes onto the dataplane channel (and unregisters on unsubscribe or peer loss, the standard
subscribe/unsubscribe discipline). The fabric classes stay completely unaware of remoteness.
Consequences: the `PacketFilter` travels with the subscription, so filtering happens satellite-
side and the tunnel carries only matching packets; traffic is demand-driven, so an unbound proxy
costs zero bytes (better than an always-on L2 bridge). TX mirrors it: the proxy's `send()`
encodes onto the dataplane channel, the satellite endpoint injects into the real interface.

- The master-side proxy presents as a local interface: MAC, MTU, PacketType of the remote (all
  mirrored properties). A Modbus/CAN/whatever binding attaches to it by name, with sequence
  correlation, address translation, and PCP priority working unchanged. Zero new binding
  concepts.
- Transport classes per the sync draft: foreign (TCP/websocket = reliable, adds RTT) and sibling
  (the D0/M0 shmem rings from the tickless-queue plan = the fast path). Same abstraction at
  every class; only the pipe underneath changes.

Configuration shape (sketch): the master drives it -- `/interface/tunnel add name=sat-can
peer=sat0 remote=can1` -- or the proxy simply materializes when the peer's interface mirrors in,
and binding to it arms the forwarding subscription. Explicit satellite-side config is only
needed until collection-method `call` lands.

**Stream tunnels** are the same concept one layer down: a Stream subclass over the peer link, the
satellite piping its serial port into its end, the master seeing an ordinary local Stream that a
ModbusInterface (or anything stream-backed) attaches to. Simpler than the interface tunnel (a
byte pipe, no packet framing), and probably the first one to build; the choice of layer is the
operator's -- tunnel the port (stream) when the master should own framing, tunnel the interface
when the satellite already frames.

What tunnels deliberately do NOT promise: distributed clock-perfect timestamping (tap records on
the satellite carry satellite time, disciplined by the existing time verbs), or multi-hop mesh
routing (star topologies, same posture as the mirror).

## Link classes: the tunnel protocol

The peer contract is "N prioritized channels"; what makes that stand up on a given medium is the
link adaptor underneath, and the media split three ways:

- **Stream transports** (TCP, websocket, TLS): already reliable and ordered. Channels are frame
  kinds multiplexed on the stream; NO link protocol is added. Running an ARQ over a reliable
  stream is the classic TCP-over-TCP pathology: the outer retransmit timer fires against the
  inner one's stalls and latency melts down. If it is a stream, mux and nothing else.
- **Sibling rings** (BL808 D0/M0 shmem): lossless by construction; one SPSC ring per channel.
- **Lossy media** (UART/RS485, UDP, raw 802.15.4): this is where the tunnel protocol lives, and
  the established protocol is already in the tree: **CPC** (protocol/cpc, 1.7k lines, live).
  Numbered endpoints each with their own seq/ack window, a system endpoint, CRC-16 framing that
  assumes only an 8-bit-clean pipe, and PCP-priority scheduling ACROSS endpoints with strict
  FIFO within one -- which is precisely the "two prioritized channels" contract. Endpoint 1 =
  sync verbs (reliable), endpoints 2..n = dataplane channels. It does ASH's job but multiplexes;
  ashv2 stays where it is (EZSP-specific) and does not generalise.

**Reliability is asymmetric by design.** The control channel needs ARQ: verbs are stateful and
loss is corruption. The dataplane mostly does NOT want it: a retransmitted CAN frame arrives
late and stale, real buses drop frames, and every protocol above already owns its loss story
(Modbus retries on timeout, CAN bindings are event-shaped, taps report `lost`). So dataplane
channels are **sequenced but unreliable**: loss is detected and counted -- feeding the same
`lost` honesty the model plane uses -- not repaired. CPC's frame vocabulary already splits this
way (numbered i-frames vs unnumbered u-frames); the in-tree implementation currently exercises
the reliable class only.

Per-medium mapping:

| medium | adaptor |
|---|---|
| TCP / websocket / TLS | channel mux on the stream, nothing else |
| shmem ring | ring per channel |
| UART / RS485 | CPC frames on the byte pipe (native habitat) |
| UDP | one CPC frame per datagram; ARQ covers datagram loss, no reassembly |
| raw 802.15.4 | one CPC frame per MPDU; MAC acks assist, CPC ARQ finishes |
| Thread proper | that IS an IPv6/UDP network: use the UDP adaptor |

(Raw-15.4 has a pleasing recursion: the radio co-processor link itself speaks CPC, so a leaf
tunnelled over 15.4 is CPC framed inside a radio driven via CPC.)

**Multi-drop and datagram lowering.** Media split along two axes: byte-pipe vs datagram, and
point-to-point vs shared. That factoring localises both extensions:

- **Byte-pipe multidrop (RS485/RS422)** is the ONLY case needing an address byte -- 15.4 has MAC
  addresses and CAN's ID space is the addressing, so only a shared byte pipe has nowhere to say
  who a frame is for (the reason HDLC grew its address byte). The extension: one station-address
  byte in the frame header on multidrop links, absent (stock CPC wire format) on point-to-point.
  ARQ state becomes per (station, endpoint). The larger need is media access: 485 is half-duplex,
  so the bus runs HDLC-NRM style -- the primary polls, secondaries speak only when addressed,
  acks piggyback on poll responses. CPC's primary/secondary asymmetry, a liability on symmetric
  point-to-point links, is an asset here: a multidrop bus wants exactly one master. Costs to
  record: poll cadence bounds leaf-originated (dataplane/event) latency, and turnaround uses the
  de-gpio machinery SerialStream already carries.
- **Datagram media (CAN, 802.15.4, UDP) shed the byte framing.** Flag/length/HCS exist to
  delimit a byte pipe; a datagram medium delimits and CRCs itself. CPC-the-frame-model
  (endpoints, numbered vs unnumbered classes, seq/ack where wanted) survives; addressing moves
  into the medium's own header.
- **CAN specifically wants LESS protocol.** The controller already does CRC, per-frame ack, and
  automatic retransmission -- keep sequence numbers to DETECT silent rx-overrun drops, but
  retransmission logic nearly vanishes (the ARQ-over-reliable rule in softened form). Encode
  (priority, station, channel) into the CAN ID, priority in the high bits: bus arbitration then
  IS the cross-channel priority scheduler, in hardware. Segmentation past 8/64-byte payloads is
  the one real need; ISO-TP (ISO 15765-2) per (station, channel) is the established answer.

**Alternatives considered.** Everything credible here is HDLC-descended; the choice is which
descendant. Raw HDLC supplies the I/U-frame vocabulary (CPC's numbered/unnumbered split IS that
split) but no channel mux -- its address byte is multidrop polling -- and its 0x7E byte-stuffing
is strictly worse than CPC's length-prefixed frames. LAPB is the prior art for symmetric roles
(the one delta CPC needs) but has no mux and no ecosystem. PPP (in tree) is the OTHER
architecture: no link reliability by design, because its answer is "run IP and use sockets" --
correct if a leaf carries the IP stack anyway, unavailable on switch-tier leaves and heavy on a
slow wire. L2TP, QUIC, and SCTP are all too big for a leaf but are convergent evolution for the
asymmetry chosen above: reliable control beside sequenced-lossy data (L2TP's channel split,
QUIC's datagrams-beside-streams, PR-SCTP). COBS is noted as a framing primitive should a
non-CPC path ever need stuffing-free framing.

Deltas the in-tree CPC needs to serve OpenWatt-to-OpenWatt links, all on its existing TODO
trajectory or small: symmetric roles (today it is host-primary to Silabs-secondary; two OpenWatt
peers need a role negotiation or one end adopting the secondary's system-endpoint protocol),
u-frame support for the unreliable dataplane class, and tx window > 1 for media with real
latency (window is 1 today, matching Silabs host libraries; fine for UART, poor for UDP RTTs).

## Where they meet

- A tap on the master-side tunnel endpoint captures remote traffic through the local model plane.
- Or the UX subscribes to the satellite's own tap through hub fan-out, and never touches the
  tunnel. Both work; the second keeps capture traffic off the master when the viewer connects to
  the hub anyway.
- A binding on a tunnel plus a tap on the same tunnel is the "confirm the niche protocol makes
  sense" workflow: watch the exact bytes the binding is transacting, live, from the UX.

## Build order

1. Dynamic blob records in the series store (tap-independent; the recorder wants them too).
2. Tap element on Stream + BaseInterface, fed from the existing tap/log sites; local UX capture
   via the already-built `sub`/`val` surface. This alone delivers the capture view for local
   interfaces end to end.
3. Blob wire encoding + serialisability verdicts; remote capture falls out via mirroring.
4. Tunnel interface over a foreign peer link (TCP first); satellite attach via explicit config.
5. Sibling-ring tunnel backend when the BL808 dataplane work lands ([[tickless_event_queue_packet_batching]]).
6. PCAP server and recorder re-plumb onto tap elements (deleting their private capture paths).
