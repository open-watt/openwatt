# DNS Subsystem TODO

State as of 2026-08-21: `protocol/dns` is listeners + a partial wire codec. Nothing answers, nothing
resolves, nothing caches. This is the plan to flesh it out, ordered by dependency.

## 0. Codec hardening (do first, standalone)

The parser is exposed to the LAN today; these are bugs, not features.

- [ ] `parse_name`: bound every read against the advancing offset (current checks test `msg.length`
      but index with `offset`); add a compression-pointer loop/depth guard (self-referencing pointer
      currently recurses to stack overflow). Remote-crash primitive; fix regardless of the rest.
- [ ] `parse_dns_message`: parse authority and additional sections (loops are empty and do not even
      advance the cursor, so trailing records corrupt the returned length).
- [ ] `formDNSMessage`: serialize authorities/additional; set nscount/arcount.
- [ ] `formDNSMessage`: bounds-check all writes; on overflow set TC and truncate at a record
      boundary instead of range-violating.
- [ ] RCODE enum (NoError, FormErr, ServFail, NXDomain, NotImp, Refused) and plumb through flags.
- [ ] Typed rdata encode/decode per record type (A, AAAA, PTR, CNAME, NS, SRV, TXT, SOA, MX, OPT).
      Names inside rdata must be decompressed at parse time (raw rdata snapshots detach compression
      pointers from the message they index into).
- [ ] Name compression on output (offset table while writing; at minimum compress repeated owner
      names, which mDNS responses are full of).
- [ ] EDNS0: parse OPT in queries (client bufsize), emit OPT in responses. Prereq for >512-byte UDP.
- [ ] Unittests: round-trip each record type, malformed-packet corpus (truncations, pointer loops,
      label overruns), compression round-trip.

## 1. Name cache / record store (the keystone)

One TTL-aware record table shared by resolver and server. Everything below depends on it.

- [ ] `RecordStore`: (name, type, class) -> records, each with TTL deadline (MonoTime) and origin
      (static, mdns-learned, resolved, llmnr, nbns).
- [ ] Expiry via `g_app.schedule` on the nearest deadline; no scan-every-frame.
- [ ] Static entries: `/protocol/dns/static add name=... address=...` (RouterOS-style), plus
      hosts-file-style bulk load.
- [ ] Authoritative flag per entry so the server knows what it may answer with AA set vs what is
      merely cached.
- [ ] Negative cache (NXDomain / NoData with SOA-derived TTL).
- [ ] Feeds: local interface addresses (own A/AAAA/PTR for mDNS), DHCP leases (lease name -> A),
      observed mDNS traffic (opportunistic cache).
- [ ] `/protocol/dns/cache print` and `flush`.

## 2. Resolver client

The embedded targets have no OS resolver; this is the highest-value feature.

- [ ] `DNSClient` over `udp_open` (event-driven; no polling): build query, random ID, retransmit
      with backoff, per-server timeout, fall through server list.
- [ ] Server list config; learn servers from DHCP/DHCPv6/RA (RDNSS) with static override.
- [ ] Answer path: populate RecordStore, chase CNAMEs, honour TC by retrying over TCP.
- [ ] Resolution policy chain: cache -> static -> DNS, `.local` -> mDNS query, then optional
      LLMNR/NBNS fallbacks per config.
- [ ] Public API: async `resolve(name, family, callback)` handle with cancellation (the CommandState
      dead-delegate problem in package.d needs the handle to own the callback registration).
- [ ] Wire `/protocol/dns lookup` to it (currently allocates a state that stays in_progress forever)
      and have IPClient/TCPStream use it when lowering onto the in-tree stack.
- [ ] mDNS one-shot query mode (QU bit, listen 5353) for `.local` lookups.

## 3. Server response engine

- [ ] Answer from RecordStore: match questions, build response, correct AA/RA/RCODE; FormErr on
      garbage, NXDomain/NoData with negative TTL.
- [ ] Forwarder mode: relay to upstream via the resolver, cache, answer from cache thereafter.
      (This is the "router as LAN DNS" use case.)
- [ ] DNS-over-TCP: 2-byte length prefix on rx framing and tx (currently fed raw to the parser, so
      all TCP queries misparse); DoT inherits the fix via the shared client path.
- [ ] Fix `create_listener` ignoring `ipv6_group` (mDNSv6/LLMNRv6 sockets never join their groups).
- [ ] Fix mDNS failure path setting the dns bit in `_failed` (copy-paste).
- [ ] Event-driven migration: rx handlers on the sockets instead of one recvfrom per frame in
      `update()`; timers for client timeouts. `update()` must go.

## 4. mDNS responder proper

- [ ] Probe/announce state machine (currently commented out pending local addresses; RecordStore
      interface-address feed unblocks it): 3 probes at 250ms, conflict rename with numeric suffix,
      2+ announcements, goodbye (TTL 0) on shutdown.
- [ ] Answer rules per RFC 6762: source port 5353 check, multicast vs unicast (QU/prefer-unicast)
      response, known-answer suppression, cache-flush bit, no forwarding off-link.
- [ ] DNS-SD (RFC 6763): service registration API (instance/service/domain -> PTR+SRV+TXT), so
      OpenWatt itself can advertise (console/telnet/http/sync). This is the actual payoff of mDNS.

## 5. Legacy responders (lower priority)

- [ ] LLMNR: answer single-label queries from RecordStore; conflict detection; sender checks.
- [ ] NBNS: first-level name *encoder* (only the decoder exists); answer NB queries for our own
      name; RELEASE on shutdown.
- [ ] WINS client mode: register/refresh/release with a configured server; probably never, but the
      resolver policy chain should leave the slot.

## 6. DoH / DoT

- [ ] DoH handler (currently `assert(false)`): POST `application/dns-message` and GET `?dns=`
      base64url, feed the same engine, set cache-control from min TTL.
- [ ] `doh_subscribe` unsubscribe half (handler currently leaks on the old HTTP server).
- [ ] DoT/DoH *upstream* in the resolver (privacy-conscious forwarder) once the engine works.

## Non-goals for now

Recursive iteration from the roots (forwarder only), DNSSEC validation, DoQ (no QUIC stack), zone
transfer, DNS Update server (revisit when DHCP integration wants it).

## CLI additions (docs/CLI.md in the same PRs)

`/protocol/dns lookup`, `/protocol/dns/static`, `/protocol/dns/cache print|flush`, server
forwarder/server-list properties, DNS-SD service registration.
