# Matter over IP (no Thread): implementation plan

Status: draft. Branch `ow/matter`, based on the IPv6 line (`ow/ipv6-icmp` -> `ow/ipv6-slaac` -> `ow/ipv6-ra`).

Goal: OpenWatt as a Matter **controller/commissioner** first (bringing Matter devices into the
Device/Component/Element model), then a Matter **bridge** exposing existing devices (Zigbee, Modbus,
CAN...) as Matter endpoints. Transport is IPv6 UDP on WiFi/Ethernet only; Thread comes later behind
the same session layer. BLE commissioning needs a GATT peripheral and is out of scope for the first
cut: commission over IP (on-network, using the QR/manual pairing code) instead.

## What the tree already provides

- IPv6 stack with ND, ICMPv6, SLAAC, RA (this branch). UDP sockets. Link-local addressing.
- DNS message codec with PTR/SRV/TXT record types (`protocol/dns/message.d`), and a DNS server.
  No mDNS responder/querier or DNS-SD registration API yet.
- Crypto (in `urt.crypto` / `urt.digest`): SHA-256, HMAC (generic), AES-ECB software, AES-GCM (backend
  only), AES key wrap, PBKDF2-SHA1, ECDH P-256 and ECDSA P-256 (mbedTLS / BCrypt backends), DER
  writer, X.509 parse via backend, CSPRNG, ChaCha20.
- Zigbee: full ZCL attribute/cluster/endpoint node model, attribute reporting, profile-driven element
  mapping (`zb: cluster, attr, type`), controller interview loop.
- Profile/sample descriptor system for mapping wire values to elements.

## Gaps, in build order

### 1. Codecs (no dependencies, fully unit-testable)
- [x] Matter TLV reader/writer (`protocol/matter/tlv.d`).
- [ ] Message header + payload header codec (session id, message counter, exchange id, protocol
      id/opcode, flags), message counter window.
- [ ] Pairing code / onboarding payload decode (manual 11/21-digit code, QR base-38).

### 2. Crypto primitives (add to urt, in-tree D so bare-metal targets work)
- [ ] HKDF-SHA256 (trivial over existing HMAC).
- [ ] PBKDF2-SHA256 (generalise `pbkdf2.d` over the digest template like HMAC).
- [ ] AES-128-CCM (build on `aes_ecb_encrypt`; CTR + CBC-MAC, ~150 lines). Also needed by WPA2 CCMP.
- [ ] P-256 point arithmetic in D, or accept backend-only for now. SPAKE2+ needs scalar mult and
      point add/sub on arbitrary points, which the mbedTLS shim does not expose; extend the shim first
      (`mbedtls_ecp_muladd`) and add a software fallback later.
- [ ] SPAKE2+ (P-256, SHA-256), the PASE handshake core. Includes the M/N constants.
- [ ] Sigma (CASE) needs ECDSA verify (backend has sign only; add verify) and X.509 chain validation
      against the Matter PAA/PAI/DAC and operational CA structure.

### 3. Discovery
- [ ] mDNS responder + querier as a `protocol/dns` service on UDP 5353, IPv6 ff02::fb.
- [ ] DNS-SD service registration/browse API: `_matterc._udp` (commissionable), `_matter._tcp`
      (operational), `_matterd._udp` (commissioner). TXT records: D, CM, VP, DN, SII, SAI, T.
- [ ] Commissioner side: browse `_matter._tcp` for operational node `<fabric-id>-<node-id>`.

### 4. Session layer (`protocol/matter/session.d`, `exchange.d`)
- [ ] Unsecured session (PASE/CASE handshake carriage) and secured session (AES-CCM with nonce from
      security flags + counter + source node id).
- [ ] Exchange manager: exchange ids, initiator/responder, reliable messaging (MRP) with ack, retry
      backoff, standalone ack. Timers via `g_app.schedule`.
- [ ] PASE: SPAKE2+ over PBKDFParamRequest/Response, Pake1/2/3.
- [ ] CASE: Sigma1/2/3 with fabric, NOC, IPK. Session resumption optional.

### 5. Interaction Model (`protocol/matter/im.d`)
- [ ] Read/Subscribe/Report/Write/Invoke request and response TLV structures.
- [ ] Attribute path, event path, data version, status codes.
- [ ] Subscription keep-alive and priming report.

### 6. Data model: shared cluster layer with Zigbee
Matter's Data Model is ZCL's successor: endpoint -> cluster -> attribute/command, same cluster ids
for the classic clusters (OnOff 0x0006, LevelControl 0x0008, ColorControl 0x0300, ...). Proposal:

- Lift `NodeMap.Endpoint/Cluster/Attribute` out of `protocol/zigbee/package.d` into a transport-neutral
  `manager/cluster.d` (or `protocol/cluster/`): endpoint id, cluster id, attribute id, value as
  `Variant`, data version, access. Zigbee keeps ZCL wire typing (`ZCLDataType`) as its encoding layer;
  Matter keeps TLV typing. The profile section syntax `zb: cluster, attr, type` becomes a generic
  `cluster: cluster, attr, type` shared by both, with `zb:` kept as an alias.
- The `create_device_from_profile` + `add_sample_element` path in `zigbee/controller.d` becomes
  the shared "cluster node -> Device" materialiser. Matter nodes and Zigbee nodes both feed it.
- Element write-back (Subscriber) maps to ZCL Write Attributes / Matter IM Write or Invoke.
- Bridge direction (later): a Matter server presenting OpenWatt Devices as Bridged Device endpoints
  (Descriptor, BridgedDeviceBasicInformation, plus mapped clusters).

### 7. Fabric and operational credentials
- [ ] Fabric table (fabric id, node id, root CA, IPK, NOC) persisted through the existing config
      persistence. Commissioner needs a root CA keypair and NOC issuance (DER builder already exists).
- [ ] Commissioning flow: ArmFailSafe, CSRRequest, AddTrustedRootCertificate, AddNOC,
      CommissioningComplete, then switch to CASE.

### 8. Runtime objects
- `/protocol/matter/controller` (fabric owner, commissioner), `/protocol/matter/node`
  (commissioned node, ActiveObject like `ZigbeeNode`), `/binding/matter` (device materialisation).
- Commands: `/protocol/matter/commission code=... [address=...]`, `nodes`, `read`, `write`, `invoke`.

## Suggested first milestone
TLV + message codec + AES-CCM/HKDF/PBKDF2 + mDNS + PASE against a real device on the LAN
(chip-tool or an ESP32 Matter light) to prove the session layer end to end, before CASE and IM.
