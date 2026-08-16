# Tesla vehicle BLE: the one recorded successful enrolment

This is a forensic record of the **only** known successful key enrolment and session
establishment against a real vehicle (2026-07-28). It was reconstructed from the live logs of
that session, plus verification against Tesla's published protobuf definitions. Everything in
the "Verified" sections is byte-level evidence from the wire; the "Inferred" notes are marked
as such.

Vehicle: VIN `LRW3F7EKXMC392131`, BLE peer `B0:B9:50:CB:22:4E`.
Platform: Windows desktop, WinRT BLE backend (`urt.driver.windows.ble`). Nothing here has ever
been demonstrated on the ESP32-S3 backend.

## 1. Where the working code lives

The successful run predates the current branch. Its nearest committed snapshot is the tip of
branch **`tesla_scanner`**:

| commit | date | note |
|---|---|---|
| `c788266` | 2026-07-28 20:37 | Fix BLE client failure lifecycle |
| `2bdf8b3` | 2026-07-28 20:37 | Harden EC P-256 secret key lifecycle |
| `705d216` | 2026-07-28 20:38 | protobuf: optional fields and large tags |
| `ead0c6b` | 2026-07-28 20:38 | Add authenticated Tesla vehicle controls |
| `f626fec` | 2026-07-28 20:38 | Refresh Visual Studio project inputs |
| `63e1ec4` | 2026-07-28 20:39 | Stop enabling TLS trace logs by default |
| `99cd7ef` | 2026-07-28 21:06 | test conf |
| **`ebb2325`** | **2026-07-28 21:06** | **tesla key (branch tip; contains the enrolled private key)** |

`ebb2325` is **not** an ancestor of `ow/tesla-ble-s3`. It is a separate line, so the working
code is preserved unmodified. To inspect it without disturbing the current branch:

```sh
git show ebb2325:src/protocol/tesla/vehicle.d      # the whole session implementation
git worktree add ../ow-enrolment-ref ebb2325       # or check it out beside the repo
```

At that revision the Tesla session lived in a single file, `src/protocol/tesla/vehicle.d`
(since split into `vehicle_session.d` / `vehicle_codec.d` / `vehicle_crypto.d` / `vehicle_scanner.d`).

## 2. The identity key (critical)

**Enrolment is permanent and is bound to the identity public key.** The car stores the public
key in its whitelist. It survives disconnects, sleep and reboots. It is *not* re-negotiated per
session. If the key file changes, the enrolment is silently void and the car returns
KEY_NOT_ON_WHITELIST forever, which is indistinguishable from never having enrolled.

The enrolled keypair is committed at **`ebb2325:conf/tesla.pem`** (121 byte SEC1 P-256 DER).
Recover it with:

```sh
git cat-file blob ebb2325:conf/tesla.pem > conf/tesla.pem
```

**This commit is the only durable copy.** `conf/tesla.pem` is listed in `.gitignore` (line 39),
so the working-tree file is untracked and will never be committed again. To stop the commit from
being lost if branch `tesla_scanner` is ever deleted and gc runs, it is tagged:

```
tesla-enrolment-ref -> ebb2325
```

so `git cat-file blob tesla-enrolment-ref:conf/tesla.pem` also works. Push that tag, or keep an
off-repo copy of the key, or both. If both the tag and the working file are lost, the enrolment
is unrecoverable and the whole card-tap process must be repeated on the vehicle.

Its public point (SEC1, `0x04 || X || Y`), which is what the car has whitelisted:

```
04 2B DC 0D DC 9C E3 7E 93 2E 8F 60 35 0A 72 94 6F 84 DA 84 86 95 6C 69 E5 7C 63 A3 44 A5 6E 2A
8D 18 69 30 59 4B 72 4A 85 4F EB 6C 5F CD 92 06 35 AB CA 94 9B 1D 44 4B ED 36 75 40 8E 93 A7 42 68
```

Verify any candidate key file with: `tail -c 65 conf/tesla.pem | od -An -tx1`

**How the enrolment was lost (2026-08-16 14:04):** `Secret.maybe_load_key()` generates and saves
a brand new keypair when the key file is *missing*. The file went missing, a new identity was
minted silently, and every subsequent handshake was rejected. Three days were spent bisecting
code for what was a lost credential. The code now refuses to overwrite a key file that exists
but cannot be read, but a **missing** file still silently regenerates. Keep this key backed up.

## 3. Vehicle discovery

- VIN hash: `SHA1("LRW3F7EKXMC392131")[:8]` = `193e93912bbe1572`
- Advertised local name: `S193e93912bbe1572C` (format `S` + 16 lowercase hex + `C`)
- The VIN must be uppercase before hashing. Lowercase or mixed case yields a completely
  different digest and never matches.

GATT (Tesla vehicle service):

| role | UUID | handle in the recorded run |
|---|---|---|
| service | `00000211-b2d1-43f0-9b88-960cebf8b91e` | |
| TX (client writes commands) | `00000212-b2d1-43f0-9b88-960cebf8b91e` | 7 |
| RX (vehicle notifies) | `00000213-b2d1-43f0-9b88-960cebf8b91e` | 10 |

Wire framing: every Tesla message is prefixed with a 2 byte big-endian length, then chunked
across ATT writes. Responses may span multiple notifications and must be reassembled.

## 4. Transport configuration that worked (Verified)

These are the exact conditions at `ebb2325`. They differ from the current branch, and the
differences are the prime suspects for the later regression:

| aspect | working (`ebb2325`) | current branch |
|---|---|---|
| ATT write type | **Write Request** (op `0x12`), `_client.write(..., true)` | Write Command (op `0x52`), `..., false` |
| delivery confirmation | **yes**, `write_rsp` (op `0x13`) observed for every frame | none, unacknowledged |
| chunk size | **fixed `MAX_WRITE = 245`** | `att_mtu - 3` |
| AddKey envelope | **bare `ToVCSECMessage`** | selectable, and `alternate` mode toggles per retry |

The acknowledged writes are what made the successful run debuggable: each frame's arrival was
provable. With unacknowledged writes, a failed write and a car that ignores you look identical.

## 5. The wire messages (Verified, captured from the successful run)

### 5a. SessionInfoRequest, the per-connection auth handshake (112 bytes)

Sent to VCSEC on every connection. This is **not** an enrolment; it asks the car for session
info, and the reply states whether our key is whitelisted.

```
32 02 08 02                       to_destination   { domain: 2 (VEHICLE_SECURITY) }
3A 12 12 10 <16 byte routing>     from_destination { routing_address }
72 43 0A 41 04 <64 byte pubkey>   session_info_request { public_key: SEC1 65 bytes }
9A 03 10 <16 byte uuid>           uuid  (also the HMAC challenge for the reply)
```

Concrete recorded instance (payload after the `00 70` length prefix):

```
320208023A12121075F8D285E6F092E140661DF3E39111DB72430A41042BDC0DDC9CE37E932E8F60350A72946F
84DA8486956C69E57C63A344A56E2A8D186930594B724A854FEB6C5FCD920635ABCA949B1D444BED3675408E93
A742689A03102B26092CD2684B589ECC2CA4E5C17EBB
```
(routing_address `75f8d285e6f092e140661df3e39111db`, uuid `2b26092cd2684b589ecc2ca4e5c17ebb`)

Replaying these exact bytes on 2026-08-16 with the recovered key reached `session ready`, and
the current codec rebuilds this frame **byte for byte identically**. The codec is exonerated.

### 5b. AddKey, the one-time enrolment request (86 bytes)

Sent only when the handshake reports KEY_NOT_ON_WHITELIST. Unsigned: authorisation comes from
the physical card tap, not from crypto.

```
0A 54 12 50 82 01 4D 2A 47 0A 43 0A 41 04 <64 byte pubkey> 20 02 32 02 08 09 18 02
```

Structure: `ToVCSECMessage { signedMessage { protobufMessage: UnsignedMessage {
WhitelistOperation { addKeyToWhitelistAndAddPermissions { key { publicKeyRaw }, keyRole: 2 },
metadataForKey { keyFormFactor: 9 } } }, signatureType: 2 (PRESENT_KEY) } }`

Constants: `ROLE_OWNER = 2`, `KEY_FORM_FACTOR_CLOUD_KEY = 9`, `SIGNATURE_TYPE_PRESENT_KEY = 2`.

### 5c. Responses seen

**Not whitelisted (49 bytes).** The car heard us and is refusing:
```
32 12 12 10 <our routing> 3A 02 08 02 7A 02 28 01 92 03 10 <uuid>
                                      ^^^^^^^^^^^ session_info { status: 1 }
```

**Enrolled (large, spans two notifications).** Contains the car's session public key and epoch,
and is what produces `trust verified`:
```
32 12 12 10 <our routing> 3A 02 08 03 7A 5E 12 41 04 <65 byte vehicle pubkey> 1A 10 <16 byte epoch> ...
```

**VCSEC status broadcast (31 bytes), unsolicited, roughly 1/second.** Easy to mistake for a
reply. It carries a rotating 20 byte blob and is addressed to no one:
```
1A 1D 12 16 0A 14 <20 bytes> 18 02 22 01 01
```
Critically, the car emits these **before** you send anything, so their presence proves the link
is alive but proves nothing about your requests being received.

## 6. The successful sequence

1. Scanner matches the advert local-name hash against a configured VIN, spawns a session.
2. BLE connect, GATT discovery, resolve TX/RX handles, subscribe to notifications.
3. Send SessionInfoRequest to **VEHICLE_SECURITY (domain 2)**.
4. Reply `status: 1` (KEY_NOT_ON_WHITELIST) so send the AddKey, then keep polling.
5. **User taps an already-enrolled physical Tesla key card on the centre console reader.**
   There is no on-screen prompt to wait for. A phone key or fob will not do.
6. Next SessionInfoRequest returns `status: 0` with the vehicle's session pubkey plus epoch.
7. Derive the session key, verify the HMAC tag, reach `session ready`.

Session key derivation (both sides compute it locally, it is never transmitted):
```
shared = ECDH(our_private, vehicle_session_public)
K      = SHA1(shared.X)[:16]                        // AES-GCM / HMAC session key
SESSION_INFO_KEY = HMAC-SHA256(K, "session info")
```

## 7. Prerequisite bugs that had to be fixed first

Any of these silently blocks the whole flow. All were found the hard way:

1. **BCrypt curve magic.** `import_private_key` built the key blob with `0x34534345` ("ECS4",
   the **P384** magic) while using a P256 provider. BCrypt returned `STATUS_INVALID_PARAMETER`
   (`0xC000000D`) and the EC key never loaded, so no handshake was possible. Correct value is
   `0x32534345` ("ECS2"). See `third_party/urt/src/urt/crypto/pki.d`.
2. **WinRT buffer marshalling.** `WriteValueAsync` must be given a genuine
   `Windows.Storage.Streams.Buffer` (`IBufferFactory`, IID `71af914d-c10f-484b-bc50-14bc623b3a27`).
   A hand-rolled `IBuffer` has no marshaler, so the call faults with `AsyncStatus.error` and
   **not one byte reaches the air**, silently.
3. **The session object must actually be ticked.** Runtime-spawned collection objects get no
   `do_update()` kick, so the module's `update()` must call `Collection!T().update_all()`.
   Without it the session sits inert after spawning.
4. **Per-domain sessions.** VCSEC (2) and INFOTAINMENT (3) have *separate* session keys, epochs
   and counters. Signing an infotainment command with the VCSEC session key yields
   `MESSAGEFAULT_ERROR_INVALID_SIGNATURE` (5).
5. **Response encryption.** Firmware 2024.38+ refuses to answer vehicle-data queries in
   plaintext, returning `MESSAGEFAULT_ERROR_REQUIRES_RESPONSE_ENCRYPTION` (28). Clients must set
   `FLAG_ENCRYPT_RESPONSE` (bit position 1, so `flags = 2`) and decrypt the reply.

## 8. Fault codes (from Tesla `universal_message.proto`, `MessageFault_E`)

Values encountered, and their neighbours, verified against the published proto rather than
recalled:

```
 0 NONE                     5 INVALID_SIGNATURE          7 INSUFFICIENT_PRIVILEGES
 1 BUSY                     6 INVALID_TOKEN_OR_COUNTER    8 INVALID_DOMAINS
 2 TIMEOUT                 15 INCORRECT_EPOCH            26 REPEATED_COUNTER
 3 UNKNOWN_KEY_ID          17 TIME_EXPIRED               27 INVALID_KEY_HANDLE
 4 INACTIVE_KEY            24 REQUEST_MTU_EXCEEDED       28 REQUIRES_RESPONSE_ENCRYPTION
```

Note the ordering the vehicle applies: the **signature is checked before permissions**. So a
signature fault (5) means it never even evaluated whether the key was allowed to do the thing,
and is not evidence of a permissions problem.

## 9. What has never worked

**No SOC or charge-state reading has ever been obtained from the vehicle.** The furthest any run
reached is `session ready` followed by a rejected command. Do not treat a missing SOC as a
regression; it has no known-good baseline.

Status as of 2026-08-16, with the recovered key on `ow/tesla-ble-s3`: the handshake succeeds and
reaches `session ready`, then every reply is dropped with `discarding unauthenticated vehicle
response`, because the response carries a `protobuf_message` but no response signature.
That is the open bug.

## 10. Reproducing the known-good handshake

1. Restore the enrolled key: `git cat-file blob ebb2325:conf/tesla.pem > conf/tesla.pem`
2. Config (see `conf/startup.conf`):
   ```
   /secret/add name=tesla kind=ec_p256 key_file="conf/tesla.pem"
   /protocol/tesla/vehicle-scanner/add name=tesla iface=ble1 secret=tesla vins=LRW3F7EKXMC392131
   ```
3. Run and expect `trust verified` then `session ready`, with **no card tap**, because the key
   is already whitelisted.

If instead you see "key not enrolled", check the wire before believing it: that message is
emitted after 3 *silent* retries, so a broken transmit path produces the identical message as a
genuine rejection. A received 49 byte `7A 02 28 01` reply is a real verdict; silence is not.
