module protocol.tesla.vehicle;

import urt.array;
import urt.crypto.aes : aes_gcm_encrypt;
import urt.crypto.random : crypto_random_bytes;
import urt.digest.hmac;
import urt.digest.sha;
import urt.encoding : hex_decode;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.result;
import urt.string;
import urt.time;
import urt.uuid;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.element;
import manager.secret;

import protocol.ble;
import protocol.ble.client;
import protocol.ble.device;
import protocol.ble.iface;

import router.iface;
import router.iface.mac;
import router.iface.packet;

nothrow @nogc:


// Tesla's custom GATT service for vehicle BLE control.
// Service:   00000211-b2d1-43f0-9b88-960cebf8b91e
// TX (write, client -> vehicle command):    00000212-b2d1-43f0-9b88-960cebf8b91e
// RX (notify, vehicle -> client response):  00000213-b2d1-43f0-9b88-960cebf8b91e
enum GUID TESLA_SERVICE_UUID = GUID(0x00000211, 0xb2d1, 0x43f0, [0x9b, 0x88, 0x96, 0x0c, 0xeb, 0xf8, 0xb9, 0x1e]);
enum GUID TESLA_TX_CHAR_UUID = GUID(0x00000212, 0xb2d1, 0x43f0, [0x9b, 0x88, 0x96, 0x0c, 0xeb, 0xf8, 0xb9, 0x1e]);
enum GUID TESLA_RX_CHAR_UUID = GUID(0x00000213, 0xb2d1, 0x43f0, [0x9b, 0x88, 0x96, 0x0c, 0xeb, 0xf8, 0xb9, 0x1e]);

// BLE advertisement local name format: 'S' + 16 hex chars + 'C'
// where the 16 hex chars are the lowercase hex of SHA1(VIN)[:8].
enum size_t TESLA_LOCAL_NAME_LEN = 18;

// Hash VIN to the 8-byte digest used in Tesla BLE advertisement local names.
void tesla_vin_hash(const(char)[] vin, out ubyte[8] hash)
{
    SHA1Context ctx;
    sha_init(ctx);
    sha_update(ctx, cast(const(ubyte)[])vin);
    Array!ubyte digest = sha_finalise(ctx);
    hash[] = digest[0 .. 8];
}

// Parse a Tesla BLE local name and extract its embedded 8-byte hash.
// Returns false if the name doesn't match the Tesla 'S<16-hex>C' shape.
bool parse_tesla_local_name(const(char)[] local_name, out ubyte[8] hash) pure
{
    if (local_name.length != TESLA_LOCAL_NAME_LEN)
        return false;
    if (local_name[0] != 'S' || local_name[17] != 'C')
        return false;
    return hex_decode(local_name[1 .. 17], hash[]) == 8;
}


// Build an unsigned AddKey-via-NFC-tap message for the bootstrap pairing flow.
// pubkey_xy is the 64-byte raw uncompressed public point (no leading 0x04 byte);
// we prepend the 0x04 to form the SEC1 uncompressed encoding the vehicle expects.
// Output is wrapped in vcsec.ToVCSECMessage with SignatureType=PRESENT_KEY.
// The vehicle will prompt the user to tap an NFC card to authorize the request.
Array!ubyte build_add_key_request(const(ubyte)[] pubkey_xy)
{
    import tools.protobuf : put_varint, varint_len;

    assert(pubkey_xy.length == 64, "Tesla AddKey requires 64-byte raw public point");

    // ROLE_OWNER = 2 (Keys.Role enum, keys.proto)
    enum ubyte ROLE_OWNER = 2;
    // KEY_FORM_FACTOR_CLOUD_KEY = 9 (vcsec.KeyFormFactor)
    enum ubyte FORM_FACTOR_CLOUD_KEY = 9;
    // SIGNATURE_TYPE_PRESENT_KEY = 2 (vcsec.SignatureType — bootstrap, no crypto)
    enum ubyte SIG_TYPE_PRESENT_KEY = 2;

    // The vehicle expects SEC1 uncompressed encoding: 0x04 || X || Y, 65 bytes total.
    enum size_t SEC1_LEN = 65;

    // Innermost: PublicKey { PublicKeyRaw (1, bytes) }
    // tag = (1 << 3) | 2 = 0x0A
    enum size_t PUBLIC_KEY_LEN = 1 + 1 + SEC1_LEN; // tag + varint-len(65) + bytes

    // PermissionChange { key (1, message), keyRole (4, varint) }
    // tag for key = 0x0A; tag for keyRole = (4 << 3) | 0 = 0x20
    enum size_t PERM_CHANGE_LEN = 1 + 1 + PUBLIC_KEY_LEN + 1 + 1; // key + keyRole

    // KeyMetadata { keyFormFactor (1, varint) }
    enum size_t KEY_METADATA_LEN = 1 + 1; // tag(0x08) + varint enum

    // WhitelistOperation { addKeyToWhitelistAndAddPermissions (5, message), metadataForKey (6, message) }
    // tag for sub_message field 5 = (5 << 3) | 2 = 0x2A
    // tag for metadataForKey field 6 = (6 << 3) | 2 = 0x32
    enum size_t WHITELIST_OP_LEN = 1 + 1 + PERM_CHANGE_LEN + 1 + 1 + KEY_METADATA_LEN;

    // UnsignedMessage { WhitelistOperation (16, message) }
    // tag for field 16 wire 2 = (16 << 3) | 2 = 130 → varint encoding = 0x82 0x01 (2 bytes)
    enum size_t UNSIGNED_MSG_LEN = 2 + 1 + WHITELIST_OP_LEN;  // tag(2B) + len(1B) + body

    // SignedMessage { protobufMessageAsBytes (2, bytes), signatureType (3, varint) }
    // tag for field 2 wire 2 = 0x12, tag for field 3 wire 0 = 0x18
    enum size_t SIGNED_MSG_LEN = 1 + varint_len(UNSIGNED_MSG_LEN) + UNSIGNED_MSG_LEN + 1 + 1;

    // ToVCSECMessage { signedMessage (1, message) }
    enum size_t TO_VCSEC_LEN = 1 + 1 + SIGNED_MSG_LEN;

    Array!ubyte buf;
    buf.resize(TO_VCSEC_LEN);
    ubyte[] out_ = buf[];
    size_t off = 0;

    // ToVCSECMessage.signedMessage tag+len
    out_[off++] = 0x0A;
    off += put_varint(out_[off .. $], SIGNED_MSG_LEN);

    // SignedMessage.protobufMessageAsBytes tag+len+body
    out_[off++] = 0x12;
    off += put_varint(out_[off .. $], UNSIGNED_MSG_LEN);

    // UnsignedMessage.WhitelistOperation tag (2-byte varint for field 16) + len
    out_[off++] = 0x82;
    out_[off++] = 0x01;
    off += put_varint(out_[off .. $], WHITELIST_OP_LEN);

    // WhitelistOperation.addKeyToWhitelistAndAddPermissions tag+len
    out_[off++] = 0x2A;
    off += put_varint(out_[off .. $], PERM_CHANGE_LEN);

    // PermissionChange.key tag+len
    out_[off++] = 0x0A;
    off += put_varint(out_[off .. $], PUBLIC_KEY_LEN);

    // PublicKey.PublicKeyRaw tag+len+body (0x04 || X || Y)
    out_[off++] = 0x0A;
    off += put_varint(out_[off .. $], SEC1_LEN);
    out_[off++] = 0x04;
    out_[off .. off + 64] = pubkey_xy[];
    off += 64;

    // PermissionChange.keyRole tag+value
    out_[off++] = 0x20;
    out_[off++] = ROLE_OWNER;

    // WhitelistOperation.metadataForKey tag+len
    out_[off++] = 0x32;
    off += put_varint(out_[off .. $], KEY_METADATA_LEN);

    // KeyMetadata.keyFormFactor tag+value
    out_[off++] = 0x08;
    out_[off++] = FORM_FACTOR_CLOUD_KEY;

    // SignedMessage.signatureType tag+value
    out_[off++] = 0x18;
    out_[off++] = SIG_TYPE_PRESENT_KEY;

    assert(off == TO_VCSEC_LEN);
    return buf;
}


// Tesla signature metadata tags. Sub-set we actually use; full set is in signatures.proto Tag enum.
enum SigTag : ubyte
{
    signature_type  = 0,
    domain          = 1,
    personalization = 2,
    epoch           = 3,
    expires_at      = 4,
    counter         = 5,
    challenge       = 6,
    flags           = 7,
    request_hash    = 8,
    fault           = 9,
    end             = 0xFF,
}

enum SigType : ubyte
{
    aes_gcm                 = 0,
    aes_gcm_personalized    = 5,
    hmac                    = 6,
    hmac_personalized       = 8,
    aes_gcm_response        = 9,
}

enum TeslaDomain : ubyte
{
    broadcast        = 0,
    vehicle_security = 2,
    infotainment     = 3,
}

// Append a TLV record (tag | len | value) to buf. Caller must add records in
// ascending tag order; metadata is serialised this way to make HMAC inputs
// canonical. The terminator 0xFF byte is appended separately by the caller.
void append_tlv(ref Array!ubyte buf, SigTag tag, const(ubyte)[] value)
{
    assert(value.length <= 255, "metadata field too long");
    buf ~= cast(ubyte)tag;
    buf ~= cast(ubyte)value.length;
    buf ~= value;
}


// Build a RoutableMessage carrying a SessionInfoRequest for `domain`.
// pubkey is the SEC1 (0x04 || X || Y) 65-byte uncompressed public point.
// routing_address and uuid must each be 16 random bytes.
Array!ubyte build_session_info_request(TeslaDomain domain, const(ubyte)[] pubkey,
                                       const(ubyte)[] routing_address, const(ubyte)[] uuid)
{
    import tools.protobuf : put_varint, varint_len;

    assert(pubkey.length == 65);
    assert(routing_address.length == 16);
    assert(uuid.length == 16);

    // Destination { domain (1, varint enum): vehicle_security }  → 2 bytes
    // Destination { routing_address (2, bytes): 16 } → 1 + 1 + 16 = 18 bytes
    enum size_t TO_DEST_LEN = 1 + 1;
    enum size_t FROM_DEST_LEN = 1 + 1 + 16;

    // SessionInfoRequest { public_key (1, bytes): 65 } → 1 + 1 + 65 = 67 bytes
    enum size_t SIR_LEN = 1 + 1 + 65;

    // RoutableMessage fields we write (in field order):
    //   to_destination (6, message)         : tag=0x32
    //   from_destination (7, message)       : tag=0x3A
    //   session_info_request (14, message)  : tag=0x72
    //   uuid (51, bytes)                    : tag=0x9A,0x03 (varint 410)
    enum size_t MSG_LEN = 1 + 1 + TO_DEST_LEN
                        + 1 + 1 + FROM_DEST_LEN
                        + 1 + 1 + SIR_LEN
                        + 2 + 1 + 16;

    Array!ubyte buf;
    buf.resize(MSG_LEN);
    ubyte[] out_ = buf[];
    size_t off = 0;

    // to_destination { domain: vehicle_security }
    out_[off++] = 0x32;
    out_[off++] = cast(ubyte)TO_DEST_LEN;
    out_[off++] = 0x08;  // field 1 wire 0
    out_[off++] = cast(ubyte)domain;

    // from_destination { routing_address: 16 bytes }
    out_[off++] = 0x3A;
    out_[off++] = cast(ubyte)FROM_DEST_LEN;
    out_[off++] = 0x12;  // field 2 wire 2
    out_[off++] = 16;
    out_[off .. off + 16] = routing_address[];
    off += 16;

    // session_info_request { public_key: SEC1 pubkey }
    out_[off++] = 0x72;  // field 14 wire 2
    out_[off++] = cast(ubyte)SIR_LEN;
    out_[off++] = 0x0A;  // field 1 wire 2
    out_[off++] = 65;
    out_[off .. off + 65] = pubkey[];
    off += 65;

    // uuid: 16 bytes (field 51 wire 2 → 2-byte tag varint 0x9A 0x03)
    out_[off++] = 0x9A;
    out_[off++] = 0x03;
    out_[off++] = 16;
    out_[off .. off + 16] = uuid[];
    off += 16;

    assert(off == MSG_LEN);
    return buf;
}


// Build the AAD metadata-TLV string for an AES-GCM-PERSONALIZED command. The
// caller passes the SHA256 of this buffer to aes_gcm_encrypt as AAD; the vehicle
// rebuilds the same bytes from the signature_data fields and SHA256s independently.
// Field order (ascending tag, per spec):
//   TAG_SIGNATURE_TYPE = AES_GCM_PERSONALIZED
//   TAG_DOMAIN
//   TAG_PERSONALIZATION = VIN
//   TAG_EPOCH = 16 bytes
//   TAG_EXPIRES_AT = 4 bytes BE u32
//   TAG_COUNTER = 4 bytes BE u32
//   TAG_FLAGS = 4 bytes BE u32 (omitted if zero)
//   0xFF terminator
Array!ubyte build_signed_command_metadata(TeslaDomain domain, const(char)[] vin,
                                          const(ubyte)[] epoch, uint expires_at,
                                          uint counter, uint flags)
{
    assert(epoch.length == 16);

    Array!ubyte meta;
    ubyte[1] sig_type = [cast(ubyte)SigType.aes_gcm_personalized];
    append_tlv(meta, SigTag.signature_type, sig_type[]);
    ubyte[1] dom = [cast(ubyte)domain];
    append_tlv(meta, SigTag.domain, dom[]);
    append_tlv(meta, SigTag.personalization, cast(const(ubyte)[])vin);
    append_tlv(meta, SigTag.epoch, epoch);
    ubyte[4] exp_be = [
        cast(ubyte)(expires_at >> 24), cast(ubyte)(expires_at >> 16),
        cast(ubyte)(expires_at >> 8), cast(ubyte)expires_at
    ];
    append_tlv(meta, SigTag.expires_at, exp_be[]);
    ubyte[4] ctr_be = [
        cast(ubyte)(counter >> 24), cast(ubyte)(counter >> 16),
        cast(ubyte)(counter >> 8), cast(ubyte)counter
    ];
    append_tlv(meta, SigTag.counter, ctr_be[]);
    if (flags != 0)
    {
        ubyte[4] flg_be = [
            cast(ubyte)(flags >> 24), cast(ubyte)(flags >> 16),
            cast(ubyte)(flags >> 8), cast(ubyte)flags
        ];
        append_tlv(meta, SigTag.flags, flg_be[]);
    }
    meta ~= cast(ubyte)SigTag.end;
    return meta;
}


// Build an AES-GCM-PERSONALIZED signed RoutableMessage envelope around a
// pre-encrypted ciphertext + tag. Caller has already computed the AAD via
// build_signed_command_metadata, encrypted plaintext with that AAD's SHA256,
// and obtained the 16-byte tag.
Array!ubyte build_signed_routable_message(TeslaDomain domain,
                                          const(ubyte)[] ciphertext,
                                          const(ubyte)[] signer_pubkey_sec1,
                                          const(ubyte)[] epoch,
                                          const(ubyte)[] nonce,
                                          uint counter, uint expires_at,
                                          const(ubyte)[] tag,
                                          const(ubyte)[] routing_address,
                                          const(ubyte)[] uuid, uint flags)
{
    import tools.protobuf : put_varint, varint_len;

    assert(signer_pubkey_sec1.length == 65);
    assert(epoch.length == 16);
    assert(nonce.length == 12);
    assert(tag.length == 16);
    assert(routing_address.length == 16);
    assert(uuid.length == 16);

    // Destination { domain } — 2 bytes, Destination { routing_address } — 18 bytes
    enum size_t TO_DEST_LEN = 2;
    enum size_t FROM_DEST_LEN = 1 + 1 + 16;

    // KeyIdentity { public_key (1, bytes 65) }
    enum size_t KEY_IDENTITY_LEN = 1 + 1 + 65;

    // AES_GCM_Personalized_Signature_Data:
    //   epoch (1, bytes 16)       : 1 + 1 + 16 = 18
    //   nonce (2, bytes 12)       : 1 + 1 + 12 = 14
    //   counter (3, varint)       : 1 + varint_len(counter)
    //   expires_at (4, fixed32)   : 1 + 4 = 5
    //   tag (5, bytes 16)         : 1 + 1 + 16 = 18
    size_t gcm_len = 18 + 14 + 1 + varint_len(counter) + 5 + 18;

    // SignatureData:
    //   signer_identity (1, message) : 1 + 1 + KEY_IDENTITY_LEN
    //   AES_GCM_Personalized_data (5, message) : 1 + varint_len(gcm_len) + gcm_len
    size_t sig_data_len = 1 + 1 + KEY_IDENTITY_LEN + 1 + varint_len(gcm_len) + gcm_len;

    // RoutableMessage fields:
    //   to_destination (6, message)              tag 0x32 + 1 + TO_DEST_LEN
    //   from_destination (7, message)            tag 0x3A + 1 + FROM_DEST_LEN
    //   protobuf_message_as_bytes (10, bytes)    tag 0x52 + varint_len(ciphertext.length) + ciphertext
    //   signedMessageStatus skipped (response only)
    //   signature_data (13, message)             tag 0x6A + varint_len(sig_data_len) + sig_data_len
    //   uuid (51, bytes 16)                      tag 0x9A 0x03 + 1 + 16
    //   flags (52, varint)                       tag 0xA0 0x03 + varint_len(flags), only if non-zero
    size_t msg_len = 1 + 1 + TO_DEST_LEN
                   + 1 + 1 + FROM_DEST_LEN
                   + 1 + varint_len(ciphertext.length) + ciphertext.length
                   + 1 + varint_len(sig_data_len) + sig_data_len
                   + 2 + 1 + 16;
    if (flags != 0)
        msg_len += 2 + varint_len(flags);

    Array!ubyte buf;
    buf.resize(msg_len);
    ubyte[] out_ = buf[];
    size_t off = 0;

    // to_destination { domain }
    out_[off++] = 0x32;
    out_[off++] = cast(ubyte)TO_DEST_LEN;
    out_[off++] = 0x08;  // field 1 wire 0
    out_[off++] = cast(ubyte)domain;

    // from_destination { routing_address }
    out_[off++] = 0x3A;
    out_[off++] = cast(ubyte)FROM_DEST_LEN;
    out_[off++] = 0x12;  // field 2 wire 2
    out_[off++] = 16;
    out_[off .. off + 16] = routing_address[];
    off += 16;

    // protobuf_message_as_bytes
    out_[off++] = 0x52;  // field 10 wire 2
    off += put_varint(out_[off .. $], ciphertext.length);
    out_[off .. off + ciphertext.length] = ciphertext[];
    off += ciphertext.length;

    // signature_data
    out_[off++] = 0x6A;  // field 13 wire 2
    off += put_varint(out_[off .. $], sig_data_len);

    // signer_identity { public_key }
    out_[off++] = 0x0A;  // field 1 wire 2
    out_[off++] = cast(ubyte)KEY_IDENTITY_LEN;
    out_[off++] = 0x0A;  // field 1 wire 2 (KeyIdentity.public_key)
    out_[off++] = 65;
    out_[off .. off + 65] = signer_pubkey_sec1[];
    off += 65;

    // AES_GCM_Personalized_data
    out_[off++] = 0x2A;  // field 5 wire 2
    off += put_varint(out_[off .. $], gcm_len);

    // epoch (1, bytes 16)
    out_[off++] = 0x0A;
    out_[off++] = 16;
    out_[off .. off + 16] = epoch[];
    off += 16;
    // nonce (2, bytes 12)
    out_[off++] = 0x12;
    out_[off++] = 12;
    out_[off .. off + 12] = nonce[];
    off += 12;
    // counter (3, varint)
    out_[off++] = 0x18;
    off += put_varint(out_[off .. $], counter);
    // expires_at (4, fixed32)
    out_[off++] = 0x25;
    out_[off++] = cast(ubyte)expires_at;
    out_[off++] = cast(ubyte)(expires_at >> 8);
    out_[off++] = cast(ubyte)(expires_at >> 16);
    out_[off++] = cast(ubyte)(expires_at >> 24);
    // tag (5, bytes 16)
    out_[off++] = 0x2A;
    out_[off++] = 16;
    out_[off .. off + 16] = tag[];
    off += 16;

    // uuid
    out_[off++] = 0x9A;
    out_[off++] = 0x03;
    out_[off++] = 16;
    out_[off .. off + 16] = uuid[];
    off += 16;

    // flags (optional)
    if (flags != 0)
    {
        out_[off++] = 0xA0;
        out_[off++] = 0x03;
        off += put_varint(out_[off .. $], flags);
    }

    assert(off == msg_len);
    return buf;
}


// ---- CarServer.Action plaintext encoders (sent through INFOTAINMENT) ----

// CarServer.Action{ VehicleAction{ getVehicleData{ getChargeState{} } } }
Array!ubyte build_action_get_charge_state()
{
    // GetChargeState {} = 0 bytes
    // GetVehicleData { getChargeState (2, message): 0 } = 2 bytes (tag 0x12 + len 0)
    // VehicleAction { getVehicleData (1, message): 2 } = 4 bytes (tag 0x0A + len 2 + body)
    // Action { vehicleAction (2, message): 4 } = 6 bytes (tag 0x12 + len 4 + body)
    static immutable ubyte[6] action = [0x12, 0x04, 0x0A, 0x02, 0x12, 0x00];
    Array!ubyte buf;
    buf.resize(6);
    buf[][] = action[];
    return buf;
}

// CarServer.Action{ VehicleAction{ chargingStartStopAction{ start | stop } } }
Array!ubyte build_action_charging_start_stop(bool start)
{
    // ChargingStartStopAction { start (2) | stop (5) : Void {} } = 2 bytes (tag + len 0)
    //   tag for field 2 wire 2 = 0x12; tag for field 5 wire 2 = 0x2A
    // VehicleAction { chargingStartStopAction (6, message): 2 } = 4 bytes (tag 0x32 + len 2 + body)
    //   tag for field 6 wire 2 = 0x32
    // Action { vehicleAction (2, message): 4 } = 6 bytes (tag 0x12 + len 4 + body)
    ubyte[6] action;
    action[0] = 0x12;
    action[1] = 0x04;
    action[2] = 0x32;
    action[3] = 0x02;
    action[4] = start ? 0x12 : 0x2A;
    action[5] = 0x00;
    Array!ubyte buf;
    buf.resize(6);
    buf[][] = action[];
    return buf;
}

// CarServer.Action{ VehicleAction{ setChargingAmpsAction{ charging_amps: N } } }
Array!ubyte build_action_set_charging_amps(int amps)
{
    import tools.protobuf : put_varint, varint_len;

    // SetChargingAmpsAction { charging_amps (1, varint int32): N }
    //   amps encoded as varint (negative values would be 10 bytes; clamp non-negative range)
    size_t amps_varint = varint_len(cast(ulong)amps);
    size_t scaa_len = 1 + amps_varint;  // tag 0x08 + varint

    // VehicleAction { setChargingAmpsAction (43, message): scaa_len }
    //   tag for field 43 wire 2 = (43 << 3) | 2 = 346 → varint 0xDA 0x02
    size_t va_len = 2 + 1 + scaa_len;  // tag(2B) + len + body

    // Action { vehicleAction (2, message): va_len }
    size_t action_len = 1 + 1 + va_len;  // tag 0x12 + len + body

    Array!ubyte buf;
    buf.resize(action_len);
    ubyte[] out_ = buf[];
    size_t off = 0;

    out_[off++] = 0x12;
    out_[off++] = cast(ubyte)va_len;
    out_[off++] = 0xDA;
    out_[off++] = 0x02;
    out_[off++] = cast(ubyte)scaa_len;
    out_[off++] = 0x08;
    off += put_varint(out_[off .. $], cast(ulong)amps);

    assert(off == action_len);
    return buf;
}


// ---- CarServer.Response decoder for charge state ----

struct ChargeState
{
    bool valid;
    bool has_battery_level;
    int battery_level;          // %
    bool has_usable_battery_level;
    int usable_battery_level;   // %
    bool has_charging_state;
    int charging_state;         // 1=Unknown, 2=Disconnected, 3=NoPower, 4=Starting, 5=Charging, 6=Complete, 7=Stopped, 8=Calibrating
    bool has_charging_amps;
    int charging_amps;
    bool has_charger_voltage;
    int charger_voltage;
    bool has_charger_actual_current;
    int charger_actual_current;
    bool has_charger_power;
    int charger_power;
    bool has_charge_energy_added;
    float charge_energy_added;
    bool has_charge_current_request;
    int charge_current_request;
    bool has_charge_current_request_max;
    int charge_current_request_max;
    bool has_minutes_to_full_charge;
    int minutes_to_full_charge;
}

// Decode a CarServer.Response → VehicleData → ChargeState into our flat struct.
bool decode_carserver_charge_state(const(ubyte)[] response_bytes, ref ChargeState s)
{
    import tools.protobuf : get_varint;

    // CarServer.Response { vehicleData (2, message) }
    const(ubyte)[] vehicle_data;
    if (!find_subfield(response_bytes, 2, vehicle_data))
        return false;
    // VehicleData { charge_state (3, message) }
    const(ubyte)[] cs_bytes;
    if (!find_subfield(vehicle_data, 3, cs_bytes))
        return false;
    s.valid = true;

    size_t off = 0;
    while (off < cs_bytes.length)
    {
        ulong tag;
        size_t n = get_varint(cs_bytes[off .. $], tag);
        if (n == 0) return false;
        off += n;
        uint field = cast(uint)(tag >> 3);
        uint wire = cast(uint)(tag & 7);

        switch (field)
        {
            case 1:  // charging_state (message — ChargingState oneof)
                if (wire != 2) goto Lskip;
                ulong sl;
                n = get_varint(cs_bytes[off .. $], sl);
                if (n == 0 || off + n + sl > cs_bytes.length) return false;
                off += n;
                // ChargingState has a single oneof field; read its tag field number.
                {
                    ulong inner_tag;
                    size_t m = get_varint(cs_bytes[off .. $], inner_tag);
                    if (m > 0)
                    {
                        s.has_charging_state = true;
                        s.charging_state = cast(int)(inner_tag >> 3);
                    }
                }
                off += cast(size_t)sl;
                break;

            case 114: s.has_battery_level = read_varint_field(cs_bytes, off, wire, s.battery_level); break;
            case 115: s.has_usable_battery_level = read_varint_field(cs_bytes, off, wire, s.usable_battery_level); break;
            case 116: s.has_charge_energy_added = read_fixed32f_field(cs_bytes, off, wire, s.charge_energy_added); break;
            case 119: s.has_charger_voltage = read_varint_field(cs_bytes, off, wire, s.charger_voltage); break;
            case 121: s.has_charger_actual_current = read_varint_field(cs_bytes, off, wire, s.charger_actual_current); break;
            case 122: s.has_charger_power = read_varint_field(cs_bytes, off, wire, s.charger_power); break;
            case 123: s.has_minutes_to_full_charge = read_varint_field(cs_bytes, off, wire, s.minutes_to_full_charge); break;
            case 137: s.has_charge_current_request = read_varint_field(cs_bytes, off, wire, s.charge_current_request); break;
            case 138: s.has_charge_current_request_max = read_varint_field(cs_bytes, off, wire, s.charge_current_request_max); break;
            case 149: s.has_charging_amps = read_varint_field(cs_bytes, off, wire, s.charging_amps); break;

            default:
            Lskip:
                if (!skip_field(cs_bytes, off, wire))
                    return false;
                break;
        }
        if (off > cs_bytes.length) return false;
    }
    return true;
}

private bool find_subfield(const(ubyte)[] buf, uint target_field, ref const(ubyte)[] out_)
{
    import tools.protobuf : get_varint;
    size_t off = 0;
    while (off < buf.length)
    {
        ulong tag;
        size_t n = get_varint(buf[off .. $], tag);
        if (n == 0) return false;
        off += n;
        uint field = cast(uint)(tag >> 3);
        uint wire = cast(uint)(tag & 7);
        if (field == target_field && wire == 2)
        {
            ulong len;
            n = get_varint(buf[off .. $], len);
            if (n == 0 || off + n + len > buf.length) return false;
            off += n;
            out_ = buf[off .. off + cast(size_t)len];
            return true;
        }
        if (!skip_field(buf, off, wire))
            return false;
    }
    return false;
}

private bool read_varint_field(const(ubyte)[] buf, ref size_t off, uint wire, ref int dst)
{
    import tools.protobuf : get_varint;
    if (wire != 0) return false;
    ulong v;
    size_t n = get_varint(buf[off .. $], v);
    if (n == 0) return false;
    dst = cast(int)v;
    off += n;
    return true;
}

private bool read_fixed32f_field(const(ubyte)[] buf, ref size_t off, uint wire, ref float dst)
{
    if (wire != 5 || off + 4 > buf.length) return false;
    uint bits = uint(buf[off]) | (uint(buf[off+1]) << 8) | (uint(buf[off+2]) << 16) | (uint(buf[off+3]) << 24);
    dst = *cast(float*)&bits;
    off += 4;
    return true;
}


// Outputs from decoding an inbound RoutableMessage that we care about.
// All slices point into the input buffer — copy out before the buffer goes away.
struct RoutableResponse
{
    const(ubyte)[] session_info;       // payload oneof field 15, if present
    const(ubyte)[] protobuf_message;   // payload oneof field 10, if present
    const(ubyte)[] session_info_tag;   // signature_data.session_info_tag.tag, if present
    const(ubyte)[] request_uuid;       // field 50
    bool has_status;
    uint signed_message_fault;          // MessageStatus.signed_message_fault (field 2 varint)
}

// Decode a RoutableMessage looking for the fields trust verification needs.
// Returns true on a syntactically valid parse (even if our fields of interest
// are absent — the caller decides what's missing).
bool decode_routable_response(const(ubyte)[] buf, ref RoutableResponse r)
{
    import tools.protobuf : get_varint;

    size_t off = 0;
    while (off < buf.length)
    {
        ulong tag;
        size_t n = get_varint(buf[off .. $], tag);
        if (n == 0)
            return false;
        off += n;
        uint field = cast(uint)(tag >> 3);
        uint wire = cast(uint)(tag & 7);

        // For each known field, decode; for everything else, skip.
        switch (field)
        {
            case 10:  // payload.protobuf_message_as_bytes
            case 15:  // payload.session_info
            case 50:  // request_uuid
                if (wire != 2) return false;
                ulong len;
                n = get_varint(buf[off .. $], len);
                if (n == 0 || off + n + len > buf.length) return false;
                off += n;
                if (field == 10)
                    r.protobuf_message = buf[off .. off + cast(size_t)len];
                else if (field == 15)
                    r.session_info = buf[off .. off + cast(size_t)len];
                else
                    r.request_uuid = buf[off .. off + cast(size_t)len];
                off += cast(size_t)len;
                break;

            case 12:  // signedMessageStatus (MessageStatus message)
                if (wire != 2) return false;
                ulong slen;
                n = get_varint(buf[off .. $], slen);
                if (n == 0 || off + n + slen > buf.length) return false;
                off += n;
                if (!decode_message_status(buf[off .. off + cast(size_t)slen], r))
                    return false;
                off += cast(size_t)slen;
                break;

            case 13:  // signature_data (SignatureData message)
                if (wire != 2) return false;
                ulong dlen;
                n = get_varint(buf[off .. $], dlen);
                if (n == 0 || off + n + dlen > buf.length) return false;
                off += n;
                if (!decode_signature_data(buf[off .. off + cast(size_t)dlen], r))
                    return false;
                off += cast(size_t)dlen;
                break;

            default:
                if (!skip_field(buf, off, wire))
                    return false;
                break;
        }
    }
    return true;
}

private bool decode_message_status(const(ubyte)[] buf, ref RoutableResponse r)
{
    import tools.protobuf : get_varint;
    size_t off = 0;
    while (off < buf.length)
    {
        ulong tag;
        size_t n = get_varint(buf[off .. $], tag);
        if (n == 0) return false;
        off += n;
        uint field = cast(uint)(tag >> 3);
        uint wire = cast(uint)(tag & 7);
        if (field == 2 && wire == 0)
        {
            ulong v;
            n = get_varint(buf[off .. $], v);
            if (n == 0) return false;
            r.signed_message_fault = cast(uint)v;
            r.has_status = true;
            off += n;
        }
        else if (!skip_field(buf, off, wire))
            return false;
    }
    return true;
}

private bool decode_signature_data(const(ubyte)[] buf, ref RoutableResponse r)
{
    import tools.protobuf : get_varint;
    size_t off = 0;
    while (off < buf.length)
    {
        ulong tag;
        size_t n = get_varint(buf[off .. $], tag);
        if (n == 0) return false;
        off += n;
        uint field = cast(uint)(tag >> 3);
        uint wire = cast(uint)(tag & 7);
        // Only session_info_tag (field 6, HMAC_Signature_Data) matters here.
        if (field == 6 && wire == 2)
        {
            ulong slen;
            n = get_varint(buf[off .. $], slen);
            if (n == 0 || off + n + slen > buf.length) return false;
            off += n;
            // HMAC_Signature_Data { tag (1, bytes) }
            const(ubyte)[] inner = buf[off .. off + cast(size_t)slen];
            off += cast(size_t)slen;
            size_t io = 0;
            while (io < inner.length)
            {
                ulong itag;
                size_t m = get_varint(inner[io .. $], itag);
                if (m == 0) return false;
                io += m;
                uint ifield = cast(uint)(itag >> 3);
                uint iwire = cast(uint)(itag & 7);
                if (ifield == 1 && iwire == 2)
                {
                    ulong tlen;
                    m = get_varint(inner[io .. $], tlen);
                    if (m == 0 || io + m + tlen > inner.length) return false;
                    io += m;
                    r.session_info_tag = inner[io .. io + cast(size_t)tlen];
                    io += cast(size_t)tlen;
                }
                else if (!skip_field(inner, io, iwire))
                    return false;
            }
        }
        else if (!skip_field(buf, off, wire))
            return false;
    }
    return true;
}

private bool skip_field(const(ubyte)[] buf, ref size_t off, uint wire)
{
    import tools.protobuf : get_varint;
    final switch (wire)
    {
        case 0:  // varint
            ulong v;
            size_t n = get_varint(buf[off .. $], v);
            if (n == 0) return false;
            off += n;
            return true;
        case 1:  // fixed64
            if (off + 8 > buf.length) return false;
            off += 8;
            return true;
        case 2:  // length-delimited
            ulong len;
            size_t n2 = get_varint(buf[off .. $], len);
            if (n2 == 0 || off + n2 + len > buf.length) return false;
            off += n2 + cast(size_t)len;
            return true;
        case 3:
        case 4:
            return false;  // deprecated groups
        case 5:  // fixed32
            if (off + 4 > buf.length) return false;
            off += 4;
            return true;
        case 6:
        case 7:
            return false;
    }
}


// Decoded SessionInfo fields we use.
struct SessionInfo
{
    uint counter;
    const(ubyte)[] public_key;   // SEC1 uncompressed (0x04 || X || Y) of vehicle's session pubkey
    const(ubyte)[] epoch;        // 16 bytes
    uint clock_time;
    uint status;                 // 0 = OK, 1 = KEY_NOT_ON_WHITELIST
    uint handle;
}

bool decode_session_info(const(ubyte)[] buf, ref SessionInfo info)
{
    import tools.protobuf : get_varint;
    import urt.endian : littleEndianToNative;

    size_t off = 0;
    while (off < buf.length)
    {
        ulong tag;
        size_t n = get_varint(buf[off .. $], tag);
        if (n == 0) return false;
        off += n;
        uint field = cast(uint)(tag >> 3);
        uint wire = cast(uint)(tag & 7);

        switch (field)
        {
            case 1:  // counter (varint)
                if (wire != 0) return false;
                ulong c;
                n = get_varint(buf[off .. $], c);
                if (n == 0) return false;
                info.counter = cast(uint)c;
                off += n;
                break;
            case 2:  // publicKey (bytes)
            case 3:  // epoch (bytes)
                if (wire != 2) return false;
                ulong len;
                n = get_varint(buf[off .. $], len);
                if (n == 0 || off + n + len > buf.length) return false;
                off += n;
                if (field == 2)
                    info.public_key = buf[off .. off + cast(size_t)len];
                else
                    info.epoch = buf[off .. off + cast(size_t)len];
                off += cast(size_t)len;
                break;
            case 4:  // clock_time (fixed32)
                if (wire != 5 || off + 4 > buf.length) return false;
                info.clock_time = uint(buf[off]) | (uint(buf[off + 1]) << 8)
                                | (uint(buf[off + 2]) << 16) | (uint(buf[off + 3]) << 24);
                off += 4;
                break;
            case 5:  // status (varint)
                if (wire != 0) return false;
                ulong s;
                n = get_varint(buf[off .. $], s);
                if (n == 0) return false;
                info.status = cast(uint)s;
                off += n;
                break;
            case 6:  // handle (varint)
                if (wire != 0) return false;
                ulong h;
                n = get_varint(buf[off .. $], h);
                if (n == 0) return false;
                info.handle = cast(uint)h;
                off += n;
                break;
            default:
                if (!skip_field(buf, off, wire))
                    return false;
                break;
        }
    }
    return true;
}


// ---------------------------------------------------------------------------
// TeslaVehicleScanner — the "server-like" protocol object.
//
// One per install (typically). User-configured (Collection-managed). Owns the
// shared identity Secret and the BLE interface used to scan for vehicles.
// Discovers known-VIN cars via BLE adverts and dynamically spawns
// TeslaVehicleSession entries (registered with ObjectFlags.dynamic|temporary)
// for each active vehicle, the way TCPServer spawns TCPStream instances.
//
// Config shape:
//   /secret/add  name=tesla  kind=ec_p256  key_file=/etc/openwatt/tesla.pem
//   /protocol/tesla/vehicle-scanner/add  name=tesla  iface=ble1  identity=tesla
// ---------------------------------------------------------------------------
class TeslaVehicleScanner : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("iface", iface),
                                 Prop!("identity", identity),
                                 Prop!("vins", vins));
nothrow @nogc:

    enum type_name = "tesla-vehicle-scanner";
    enum path = "/protocol/tesla/vehicle-scanner";
    enum collection_id = CollectionType.tesla_vehicle_scanner;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaVehicleScanner, id, flags);
    }

    // Properties

    inout(BaseInterface) iface() inout pure
        => _iface;
    void iface(BaseInterface value)
    {
        if (_iface is value)
            return;
        _iface = value;
        restart();
    }

    inout(Secret) identity() inout pure
        => _identity.get;
    void identity(Secret value)
    {
        if (_identity.get is value)
            return;
        _identity = value;
        restart();
    }

    // Comma-separated list of known VINs. Adverts whose hashed local name
    // matches any registered VIN trigger a session spawn.
    String vins() const
    {
        MutableString!0 r;
        foreach (i, ref e; _vins[])
            r.concat(i > 0 ? "," : "", e.vin[]);
        return r[].makeString(defaultAllocator());
    }
    void vins(String value)
    {
        import apps.energy.vehicle : vehicle_for;

        _vins.clear();
        const(char)[] rest = value[];
        while (rest.length)
        {
            const(char)[] vin = rest.split!','.trim;
            if (vin.length == 0)
                continue;
            VinEntry e;
            e.vin = vin.makeString(defaultAllocator());
            tesla_vin_hash(vin, e.hash);
            e.component = vehicle_for(e.vin[]);
            _vins ~= e.move;
        }
    }

protected:
    override bool validate() const
    {
        const Secret s = _identity.get;
        return _iface !is null
            && (cast(const(BLEInterface))_iface.get) !is null
            && s !is null
            && s.kind == SecretKind.ec_p256;
    }

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            PacketFilter filter;
            filter.type = PacketType.ble_ll;
            _iface.subscribe(&incoming_packet, filter);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        // TODO: tear down all TeslaVehicleSession instances we created.
        //       iterate Collection!TeslaVehicleSession, find ones whose
        //       _scanner is this, destroy them.

        return CompletionStatus.complete;
    }

    override void update()
    {
        // TODO: periodic housekeeping — out-of-range timeouts, retry backoff.
    }

package:
    // Create a new TeslaVehicleSession for the given vehicle. Allocates and
    // starts the underlying BLEClient first, then wraps it in a session.
    // Returns null if either allocation fails (typically a name collision).
    TeslaVehicleSession spawn_session(const(char)[] vin, MACAddress peer)
    {
        const(char)[] client_name = Collection!BLEClient().generate_name(vin);
        BLEClient c = Collection!BLEClient().create(client_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
                                                    NamedArgument("interface", _iface.get), NamedArgument("peer", peer));
        if (!c)
        {
            log.error("could not allocate BLEClient for VIN '", vin, "'");
            return null;
        }

        TeslaVehicleSession s = Collection!TeslaVehicleSession().alloc(vin, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary));
        if (!s)
        {
            log.error("could not spawn session for VIN '", vin, "' (name collision?)");
            c.destroy();
            return null;
        }
        s._scanner = this;
        s.client = c;
        Collection!TeslaVehicleSession().add(s);
        return s;
    }

private:
    struct VinEntry
    {
        String vin;
        ubyte[8] hash;
        Component component;  // Vehicle Component in the global vehicles Device
    }

    ObjectRef!BaseInterface _iface;
    ObjectRef!Secret _identity;
    Array!VinEntry _vins;
    bool _subscribed;

    void incoming_packet(ref const Packet p, BaseInterface, PacketDirection, void*)
    {
        if (p.type != PacketType.ble_ll)
            return;
        ref ll = p.hdr!BLELLFrame;
        switch (ll.pdu_type)
        {
            case BLELLType.adv_ind:
            case BLELLType.adv_nonconn_ind:
            case BLELLType.adv_scan_ind:
            case BLELLType.adv_direct_ind:
            case BLELLType.scan_rsp:
                break;
            default:
                return;
        }

        if (_vins.empty)
            return;

        // BLEModule already parsed the AD payload and updated devices map by
        // the time this packet fans out — reuse the parsed local name rather
        // than re-walking AD records here.
        BLEAdvEntry** ppe = ll.src in get_module!BLEModule.devices;
        if (!ppe || !*ppe || (*ppe).name.length != TESLA_LOCAL_NAME_LEN)
            return;

        ubyte[8] hash;
        if (!parse_tesla_local_name((*ppe).name[], hash))
            return;

        foreach (ref e; _vins[])
        {
            if (e.hash[] != hash[])
                continue;

            // Already have a session for this VIN? skip.
            if (Collection!TeslaVehicleSession().get(e.vin[]) !is null)
                return;

            log.info("Tesla vehicle '", e.vin[], "' seen at ", ll.src, " — spawning session");
            spawn_session(e.vin[], ll.src);
            return;
        }
    }

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }
}


// ---------------------------------------------------------------------------
// TeslaVehicleSession — the per-active-vehicle runtime.
//
// Collection-managed but server-spawned (ObjectFlags.dynamic|temporary).
// Created by TeslaVehicleScanner when a known VIN appears in BLE range, destroyed
// when the vehicle leaves range or the corresponding Car appliance is
// removed. NAME IS THE VIN — direct lookup via
// Collection!TeslaVehicleSession().get_by_name(vin).
//
// Owns:
//   - A dynamic BLEClient (also dynamic|temporary) for the BLE/GATT transport
//   - The Tesla session crypto state (ECDH-derived AES-GCM key, anti-replay
//     counter, vehicle's session pubkey)
//   - The auto-pair / trust-check state machine
//   - Multi-notification reassembly buffer for RoutableMessage decoding
//
// Consumed by Car appliances via session_for(vin) lookup. Status reflected
// out to subscribers via the standard Element subscriber mechanism.
// ---------------------------------------------------------------------------
class TeslaVehicleSession : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("client", client));
nothrow @nogc:

    enum type_name = "tesla-vehicle-session";
    enum path = "/protocol/tesla/session";
    enum collection_id = CollectionType.tesla_vehicle_session;

    enum State : ubyte
    {
        connecting,         // BLE link establishing
        gatt_ready,         // BLE connected, GATT discovery done, TX/RX handles known
        session_info_xchg,  // session_info_request sent, awaiting session_info from vehicle
        trust_check,        // session_info received, doing a signed query to verify whitelist status
        awaiting_approval,  // trust check failed → AddKey sent, waiting for user tap on car screen
        ready,              // trusted, session established, signed commands flow
        failed,             // unrecoverable error (rejected, timeout, etc.)
    }

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaVehicleSession, id, flags);
    }

    // VIN is the object name — no separate property needed.
    const(char)[] vin() const pure
        => name[];

    MACAddress peer() const pure
        => _client ? _client.peer : MACAddress();

    inout(BLEClient) client() inout pure
        => _client;
    void client(BLEClient value)
    {
        if (_client is value)
            return;
        _client = value;
        restart();
    }

    State session_state() const pure
        => _state;

    inout(TeslaVehicleScanner) scanner() inout pure
        => _scanner;

    // ---- User-facing command API (post-Ready state) ----

    bool is_ready() const pure => _state == State.ready;

    // Latest decoded ChargeState (populated by response to refresh_charge_state).
    // The `valid` field is true once any response has been parsed.
    ref const(ChargeState) charge_state() const pure => _charge_state;

    // Ask the vehicle for current ChargeState. The response arrives asynchronously
    // via on_notification and updates the cached charge_state(). Returns false
    // if the session isn't ready or the BLE write fails.
    bool refresh_charge_state()
        => send_signed_action(TeslaDomain.infotainment, build_action_get_charge_state()[]);

    // Start / stop charging via INFOTAINMENT domain.
    bool charging_start()
        => send_signed_action(TeslaDomain.infotainment, build_action_charging_start_stop(true)[]);
    bool charging_stop()
        => send_signed_action(TeslaDomain.infotainment, build_action_charging_start_stop(false)[]);

    // Set the AC charge current limit (per phase). Tesla supports integer amps.
    bool set_charging_amps(int amps)
        => send_signed_action(TeslaDomain.infotainment, build_action_set_charging_amps(amps)[]);

protected:
    override bool validate() const
        => _scanner !is null && _client !is null;

    override CompletionStatus startup()
    {
        if (!_client.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _client.subscribe(&client_state_change);
            _subscribed = true;
        }

        _state = State.connecting;
        _rx_buffer.clear();
        _counter = 0;
        _routing_seeded = false;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _client.unsubscribe(&client_state_change);
            _subscribed = false;
        }
        if (_client !is null && _rx_handle != 0)
            _client.clear_notify(_rx_handle);
        _tx_handle = 0;
        _rx_handle = 0;
        _rx_buffer.clear();
        _aes_key[] = 0;
        _vehicle_pubkey[] = 0;
        _epoch[] = 0;
        _routing_address[] = 0;
        _request_uuid[] = 0;
        _counter = 0;
        _charge_state = ChargeState.init;
        _cap = CapacitySamplerState.init;
        _last_poll_time = MonoTime.init;

        // Mark the published Vehicle Component as disconnected so consumers
        // can see the car is no longer reachable (last_seen stays at its
        // last value for stale-detection).
        foreach (ref e; _scanner._vins[])
        {
            if (e.vin[] == name[] && e.component !is null)
            {
                e.component.find_or_create_element("connected").value(false);
                break;
            }
        }
        _routing_seeded = false;
        _state = State.connecting;
        if (_client !is null)
        {
            _client.destroy();
            _client = null;
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        final switch (_state)
        {
            case State.connecting:
                if (!_client.discovery_complete())
                    break;
                _tx_handle = _client.find_characteristic(TESLA_SERVICE_UUID, TESLA_TX_CHAR_UUID);
                _rx_handle = _client.find_characteristic(TESLA_SERVICE_UUID, TESLA_RX_CHAR_UUID);
                if (_tx_handle == 0 || _rx_handle == 0)
                {
                    log.error("Tesla GATT characteristics not found on peer ", _client.peer);
                    _state = State.failed;
                    break;
                }
                _client.on_notify(_rx_handle, &on_notification);
                _state = State.gatt_ready;
                break;

            case State.gatt_ready:
                if (send_session_info_request())
                    _state = State.session_info_xchg;
                else
                    _state = State.failed;
                break;

            case State.session_info_xchg:
            case State.awaiting_approval:
                // No response yet — re-send SessionInfoRequest periodically.
                // In awaiting_approval we are polling to detect when the user
                // taps the NFC card and the vehicle starts returning OK status.
                if (getTime() - _last_request_time > retry_interval)
                {
                    if (!send_session_info_request())
                        _state = State.failed;
                }
                break;

            case State.trust_check:
                // Reserved for the AES-GCM signed command flow (next milestone).
                break;

            case State.ready:
                // Adaptive polling: faster while actively charging (need realtime
                // power for energy app), slower when idle (just want SOC drift and
                // plug-state changes).
                Duration interval = poll_interval_for_state();
                if (getTime() - _last_poll_time >= interval)
                {
                    _last_poll_time = getTime();
                    refresh_charge_state();
                }
                break;

            case State.failed:
                // Stay here until externally restarted (out-of-range BLE drop
                // triggers shutdown which will destroy the session).
                break;
        }
    }

private:
    enum Duration retry_interval = 5.seconds;
    enum Duration poll_charging  = 2.seconds;   // active-charging cadence
    enum Duration poll_idle      = 30.seconds;  // connected but not charging

    TeslaVehicleScanner _scanner;       // back-ref to spawning server (for identity + iface)
    BLEClient _client;           // GATT transport (dynamic|temporary), set at spawn time
    bool _subscribed;
    ushort _tx_handle;           // resolved after gatt discovery
    ushort _rx_handle;
    State _state = State.connecting;

    // ---- Session-establishment state ----
    ubyte[16] _routing_address;   // our random local routing id (stable per session lifetime)
    ubyte[16] _request_uuid;      // last SessionInfoRequest uuid; also used as HMAC challenge
    MonoTime _last_request_time;
    MonoTime _last_poll_time;
    bool _routing_seeded;

    // Charging-state-aware poll cadence: ramp up while actively charging so the
    // energy app sees realtime power; coast when idle to keep BLE traffic low.
    Duration poll_interval_for_state() const pure
    {
        // ChargingState_E: 5 = Charging, 4 = Starting
        if (_charge_state.valid && _charge_state.has_charging_state
            && (_charge_state.charging_state == 5 || _charge_state.charging_state == 4))
            return poll_charging;
        return poll_idle;
    }

    // ---- Crypto session state (filled when SessionInfo is validated) ----
    ubyte[16] _aes_key;          // K = SHA1(ECDH(our_priv, vehicle_session_pub).x)[:16]
    ubyte[65] _vehicle_pubkey;   // SEC1 uncompressed; saved from SessionInfo.publicKey
    ubyte[16] _epoch;            // session epoch from vehicle
    uint _counter;               // anti-replay counter (incremented per signed command)
    MonoTime _epoch_start;       // local time we observed clock_time=0 of the epoch

    // ---- Cached vehicle state ----
    ChargeState _charge_state;

    // ---- Capacity-estimator ephemeral state (per-charging-session) ----
    struct CapacitySamplerState
    {
        bool anchored;
        int soc_anchor;
        float energy_anchor;  // kWh
    }
    CapacitySamplerState _cap;

    // ---- Multi-notification reassembly ----
    Array!ubyte _rx_buffer;

    void client_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    // Bootstrap pairing: send vcsec.ToVCSECMessage{SignedMessage{AddKey, PRESENT_KEY}}.
    // The vehicle will prompt the user to tap their NFC card on the centre console
    // to authorize the new key. No client-side signing required.
    bool send_add_key_request()
    {
        const(ubyte)[] pub = _scanner.identity.public_key_raw;
        if (pub.length != 64)
        {
            log.error("identity public key not available (Secret kind != ec_p256 or not loaded)");
            return false;
        }

        Array!ubyte msg = build_add_key_request(pub);
        return write_tesla_frame(msg[]);
    }

    // Tesla BLE wire framing: 2-byte big-endian length prefix, then payload.
    // Chunk across BLE writes if payload > MTU (245 byte ATT MTU - 2 for handle).
    bool write_tesla_frame(const(ubyte)[] payload)
    {
        if (payload.length > 0xFFFF)
        {
            log.error("Tesla message too large: ", payload.length, " bytes");
            return false;
        }

        Array!ubyte framed;
        framed.reserve(2 + payload.length);
        framed ~= cast(ubyte)(payload.length >> 8);
        framed ~= cast(ubyte)(payload.length & 0xFF);
        framed ~= payload;

        enum size_t MAX_WRITE = 245;
        const(ubyte)[] rem = framed[];
        while (rem.length)
        {
            size_t n = rem.length > MAX_WRITE ? MAX_WRITE : rem.length;
            int tag = _client.write(_tx_handle, rem[0 .. n], true);
            if (tag < 0)
            {
                log.error("BLE write failed at offset ", framed.length - rem.length);
                return false;
            }
            rem = rem[n .. $];
        }
        return true;
    }

    // Build + send a SessionInfoRequest RoutableMessage for VEHICLE_SECURITY.
    // Generates a fresh request_uuid (used as HMAC challenge on the response).
    bool send_session_info_request()
    {
        const(ubyte)[] pub_xy = _scanner.identity.public_key_raw;
        if (pub_xy.length != 64)
        {
            log.error("identity public key not available (Secret kind != ec_p256 or not loaded)");
            return false;
        }

        // SEC1 uncompressed: 0x04 || X || Y
        ubyte[65] sec1 = void;
        sec1[0] = 0x04;
        sec1[1 .. 65] = pub_xy[];

        if (!_routing_seeded)
        {
            crypto_random_bytes(_routing_address[]);
            _routing_seeded = true;
        }
        crypto_random_bytes(_request_uuid[]);

        Array!ubyte msg = build_session_info_request(TeslaDomain.vehicle_security, sec1[],
                                                    _routing_address[], _request_uuid[]);
        _last_request_time = getTime();
        return write_tesla_frame(msg[]);
    }

    // Notification reassembly. Tesla wire frames responses with a 2-byte
    // big-endian length prefix, possibly spanning multiple ATT notifications.
    void on_notification(ushort, const(ubyte)[] value)
    {
        _rx_buffer ~= value[];

        while (_rx_buffer.length >= 2)
        {
            size_t msg_len = (size_t(_rx_buffer[0]) << 8) | _rx_buffer[1];
            if (_rx_buffer.length < 2 + msg_len)
                return;  // need more chunks

            const(ubyte)[] msg = _rx_buffer[2 .. 2 + msg_len];
            dispatch_response(msg);
            _rx_buffer.remove(0, 2 + msg_len);
        }
    }

    void dispatch_response(const(ubyte)[] msg)
    {
        RoutableResponse r;
        if (!decode_routable_response(msg, r))
        {
            log.warning("failed to decode RoutableMessage from vehicle");
            return;
        }

        if (_state == State.session_info_xchg || _state == State.awaiting_approval)
        {
            handle_session_info_response(r);
            return;
        }

        if (_state == State.ready)
        {
            handle_command_response(r);
            return;
        }
    }

    void handle_session_info_response(ref const RoutableResponse r)
    {
        if (r.request_uuid.length == 16 && r.request_uuid[] != _request_uuid[])
            return;

        if (!r.session_info.length || !r.session_info_tag.length)
        {
            if (r.has_status)
                log.warning("vehicle returned protocol error ", r.signed_message_fault);
            return;
        }

        SessionInfo info;
        if (!decode_session_info(r.session_info, info))
        {
            log.warning("failed to decode SessionInfo from vehicle");
            return;
        }

        if (info.status == 1)  // SESSION_INFO_STATUS_KEY_NOT_ON_WHITELIST
        {
            if (_state != State.awaiting_approval)
            {
                log.info("key not enrolled for VIN '", name[], "' — sending AddKey, please tap NFC card");
                if (send_add_key_request())
                    _state = State.awaiting_approval;
                else
                    _state = State.failed;
            }
            return;
        }

        if (!verify_session_info_tag(info, r))
        {
            log.error("SessionInfo HMAC tag mismatch for VIN '", name[], "' — discarding");
            return;
        }

        if (info.public_key.length != 65)
        {
            log.error("vehicle SessionInfo has malformed public key length ", info.public_key.length);
            return;
        }

        _vehicle_pubkey[] = info.public_key[];
        _epoch[] = info.epoch[];
        _counter = info.counter;
        _epoch_start = getTime() - info.clock_time.seconds;
        _state = State.ready;
        log.info("trust verified for VIN '", name[], "' — session ready");
    }

    void handle_command_response(ref const RoutableResponse r)
    {
        if (r.has_status && r.signed_message_fault != 0)
        {
            log.warning("vehicle command error ", r.signed_message_fault, " for VIN '", name[], "'");
            return;
        }
        if (r.protobuf_message.length == 0)
            return;

        // Try to decode as a CarServer.Response with charge state.
        ChargeState cs;
        if (decode_carserver_charge_state(r.protobuf_message, cs) && cs.valid)
        {
            _charge_state = cs;
            publish_charge_state(cs);
            return;
        }
        // Otherwise it's a command ack with no payload of interest.
    }

    // Push the decoded ChargeState into the Vehicle Component published in
    // the global vehicles Device. Looks up the component via the scanner's
    // VIN registration (cached on first vins= parse).
    void publish_charge_state(ref const ChargeState cs)
    {
        Component v = null;
        foreach (ref e; _scanner._vins[])
        {
            if (e.vin[] == name[])
            {
                v = e.component;
                break;
            }
        }
        if (v is null)
            return;

        SysTime now = getSysTime();
        v.find_or_create_element("connected").value(true, now);
        v.find_or_create_element("last_seen").value(now, now);

        if (cs.has_battery_level)
            v.find_or_create_element("battery.soc").value(cs.battery_level, now);
        if (cs.has_usable_battery_level)
            v.find_or_create_element("battery.usable_soc").value(cs.usable_battery_level, now);

        if (cs.has_charging_state)
        {
            // Map vcsec ChargingState enum (1..8) to our charging_state strings.
            static immutable string[9] names = [
                "unknown", "unknown", "disconnected", "no_power", "starting",
                "charging", "complete", "stopped", "calibrating"
            ];
            uint idx = cs.charging_state >= 0 && cs.charging_state < names.length ? cs.charging_state : 0;
            v.find_or_create_element("charging_state").value(names[idx], now);
        }
        if (cs.has_minutes_to_full_charge)
            v.find_or_create_element("minutes_to_full").value(cs.minutes_to_full_charge, now);

        if (cs.has_charger_voltage)
            v.find_or_create_element("meter.voltage").value(cs.charger_voltage, now);
        if (cs.has_charger_actual_current)
            v.find_or_create_element("meter.current").value(cs.charger_actual_current, now);
        if (cs.has_charger_power)
            v.find_or_create_element("meter.power").value(cs.charger_power * 1000, now);  // kW → W
        if (cs.has_charge_energy_added)
            v.find_or_create_element("meter.import").value(cs.charge_energy_added, now);

        if (cs.has_charge_current_request_max)
            v.find_or_create_element("control.max").value(cs.charge_current_request_max, now);
        if (cs.has_charging_amps)
            v.find_or_create_element("control.setpoint").value(cs.charging_amps, now);

        // Feed the capacity estimator with this sample. The estimator filters
        // for the linear-BMS region (15..85%) and emits a new running-mean
        // capacity when each 5%-SOC window completes.
        if (cs.has_battery_level && cs.has_charge_energy_added)
            capacity_sample(cs.battery_level, cs.charge_energy_added);
    }

    // Battery capacity estimator: each time SOC crosses a 5% threshold inside
    // the BMS's linear range, emit one (energy/soc-delta) sample to the
    // persistent per-VIN estimator. The anchor advances after each emit so
    // consecutive windows produce independent measurements.
    void capacity_sample(int soc, float energy_added)
    {
        import apps.energy.vehicle : add_capacity_sample;

        // Tesla resets charge_energy_added at the start of each session. When
        // we see it decrease, a new session began — drop our anchor and let
        // the next valid SOC re-anchor.
        if (_cap.anchored && energy_added < _cap.energy_anchor)
            _cap.anchored = false;

        if (!_cap.anchored)
        {
            // Only anchor inside the BMS linear region; the buffer zones at
            // top/bottom give noisy energy-per-percent.
            if (soc >= 15 && soc <= 85)
            {
                _cap.soc_anchor = soc;
                _cap.energy_anchor = energy_added;
                _cap.anchored = true;
            }
            return;
        }

        // Out of the linear region — close this window without emitting,
        // re-anchor whenever we're back inside.
        if (soc > 85)
        {
            _cap.anchored = false;
            return;
        }

        int delta_soc = soc - _cap.soc_anchor;
        if (delta_soc < 5)
            return;  // wait for a meaningful window

        float delta_energy = energy_added - _cap.energy_anchor;
        if (delta_energy <= 0)
            return;  // wonky reading, ignore

        float estimate_kwh = delta_energy / (delta_soc / 100.0f);
        add_capacity_sample(name[], estimate_kwh, cast(float)delta_soc);

        // Advance the anchor so the next 5% window is an independent sample.
        _cap.soc_anchor = soc;
        _cap.energy_anchor = energy_added;
    }

    // Send a signed AES-GCM-PERSONALIZED command. Plaintext is the encoded
    // CarServer.Action protobuf (or VCSEC.UnsignedMessage for VEHICLE_SECURITY).
    bool send_signed_action(TeslaDomain domain, const(ubyte)[] plaintext)
    {
        if (_state != State.ready)
        {
            log.warning("session not ready — command refused");
            return false;
        }

        const(ubyte)[] pub_xy = _scanner.identity.public_key_raw;
        if (pub_xy.length != 64)
            return false;
        ubyte[65] signer_sec1 = void;
        signer_sec1[0] = 0x04;
        signer_sec1[1 .. 65] = pub_xy[];

        ++_counter;

        // Express expiration in seconds since epoch start (vehicle clock).
        long elapsed = (getTime() - _epoch_start).as!"seconds";
        if (elapsed < 0) elapsed = 0;
        uint expires_at = cast(uint)elapsed + 5;  // 5-second TTL

        enum uint flags = 0;  // FLAG_ENCRYPT_RESPONSE deferred for now

        Array!ubyte meta = build_signed_command_metadata(domain, name[], _epoch[],
                                                         expires_at, _counter, flags);

        // AAD = SHA256(metadata TLV)
        SHA256Context sha;
        sha_init(sha);
        sha_update(sha, meta[]);
        ubyte[32] aad = sha_finalise(sha);

        ubyte[12] nonce = void;
        crypto_random_bytes(nonce[]);

        Array!ubyte ciphertext;
        ciphertext.resize(plaintext.length);
        ubyte[16] tag = void;
        Result enc = aes_gcm_encrypt(_aes_key[], nonce[], aad[], plaintext, ciphertext[], tag[]);
        if (enc.failed)
        {
            log.error("AES-GCM encrypt failed: ", enc.system_code);
            return false;
        }

        if (!_routing_seeded)
        {
            crypto_random_bytes(_routing_address[]);
            _routing_seeded = true;
        }
        ubyte[16] uuid = void;
        crypto_random_bytes(uuid[]);

        Array!ubyte msg = build_signed_routable_message(domain, ciphertext[], signer_sec1[],
                                                        _epoch[], nonce[], _counter, expires_at,
                                                        tag[], _routing_address[], uuid[], flags);
        return write_tesla_frame(msg[]);
    }

    // Verify the HMAC tag the vehicle attached to its SessionInfo response.
    // K = SHA1(ECDH(our_priv, vehicle_session_pub).X)[:16]
    // SESSION_INFO_KEY = HMAC-SHA256(K, "session info")
    // expected_tag = HMAC-SHA256(SESSION_INFO_KEY,
    //                            TLV(SIG_TYPE_HMAC) || TLV(VIN) || TLV(challenge_uuid) || 0xFF
    //                            || session_info_bytes)
    bool verify_session_info_tag(ref const SessionInfo info, ref const RoutableResponse r)
    {
        if (info.public_key.length != 65 || info.public_key[0] != 0x04)
            return false;

        // Vehicle's session pubkey is SEC1 (0x04 || X || Y); ecdh wants raw XY.
        const(ubyte)[] vehicle_xy = info.public_key[1 .. 65];

        ubyte[32] shared_x = void;
        if (_scanner.identity.ecdh_compute_shared(vehicle_xy, shared_x[]).failed)
            return false;

        SHA1Context sha;
        sha_init(sha);
        sha_update(sha, shared_x[]);
        Array!ubyte sha1_out = sha_finalise(sha);
        _aes_key[] = sha1_out[0 .. 16];

        // SESSION_INFO_KEY
        HMACContext!SHA256Context kdf;
        hmac_init(kdf, _aes_key[]);
        hmac_update(kdf, cast(const(ubyte)[])"session info");
        ubyte[32] session_info_key = hmac_finalise(kdf);

        // Compute expected HMAC over (metadata || session_info_bytes).
        // Metadata order: SIGNATURE_TYPE, PERSONALIZATION, CHALLENGE (ascending tag).
        ubyte[1] sig_hmac = [cast(ubyte)SigType.hmac];

        Array!ubyte meta;
        append_tlv(meta, SigTag.signature_type, sig_hmac[]);
        append_tlv(meta, SigTag.personalization, cast(const(ubyte)[])name[]);
        append_tlv(meta, SigTag.challenge, _request_uuid[]);
        meta ~= cast(ubyte)SigTag.end;

        HMACContext!SHA256Context tag_ctx;
        hmac_init(tag_ctx, session_info_key[]);
        hmac_update(tag_ctx, meta[]);
        hmac_update(tag_ctx, r.session_info);
        ubyte[32] expected = hmac_finalise(tag_ctx);

        // Constant-time compare.
        if (r.session_info_tag.length != expected.length)
            return false;
        ubyte diff = 0;
        foreach (i, b; expected[])
            diff |= b ^ r.session_info_tag[i];
        return diff == 0;
    }
}


// Test vectors from teslamotors/vehicle-command protocol.md.
unittest
{
    import urt.encoding : HexDecode;

    // ---- Advert local name <-> VIN hash ----
    // From protocol.md: VIN "5YJS0000000000000" -> local name "S1a87a5a75f3df858C"
    ubyte[8] hash;
    tesla_vin_hash("5YJS0000000000000", hash);
    static immutable ubyte[8] expected_hash = HexDecode!"1a87a5a75f3df858";
    assert(hash == expected_hash);

    ubyte[8] parsed;
    assert(parse_tesla_local_name("S1a87a5a75f3df858C", parsed));
    assert(parsed == expected_hash);

    assert(!parse_tesla_local_name("S1a87a5a75f3df858X", parsed));  // wrong terminator
    assert(!parse_tesla_local_name("T1a87a5a75f3df858C", parsed));  // wrong prefix
    assert(!parse_tesla_local_name("S1a87a5a75f3df85", parsed));    // too short
    assert(!parse_tesla_local_name("S1a87a5a75f3dz858C", parsed));  // non-hex


    // ---- Metadata TLV layout ----
    // From protocol.md example:
    // METADATA = TLV(SIG_TYPE_HMAC) || TLV(VIN) || TLV(CHALLENGE) || 0xFF
    // metadata layout from protocol.md:
    //   00 01 06                              TAG_SIG_TYPE=0, len=1, SIG_TYPE_HMAC=6
    //   02 11 35594a3330313233343536373839414243   TAG_PERS=2, len=17, "5YJ30123456789ABC"
    //   06 10 1588d5a30eabc6f8fc9a951b11f6fd11     TAG_CHALLENGE=6, len=16, uuid
    //   ff                                         terminator
    static immutable ubyte[] expected_metadata = HexDecode!(
        "000106021135594a333031323334353637383941424306101588d5a30eabc6f8fc9a951b11f6fd11ff");

    Array!ubyte meta;
    ubyte[1] sig_type_hmac = [cast(ubyte)SigType.hmac];
    append_tlv(meta, SigTag.signature_type, sig_type_hmac[]);
    append_tlv(meta, SigTag.personalization, cast(const(ubyte)[])"5YJ30123456789ABC");
    static immutable ubyte[16] challenge = HexDecode!"1588d5a30eabc6f8fc9a951b11f6fd11";
    append_tlv(meta, SigTag.challenge, challenge[]);
    meta ~= cast(ubyte)SigTag.end;
    assert(meta[] == expected_metadata);


    // ---- SESSION_INFO_KEY = HMAC-SHA256(K, "session info") ----
    static immutable ubyte[16] K = HexDecode!"1b2fce19967b79db696f909cff89ea9a";
    static immutable ubyte[32] expected_session_key = HexDecode!(
        "fceb679ee7bca756fcd441bf238bf2f338629b41d9eb9c67be1b32c9672ce300");

    auto session_key = hmac!SHA256Context(K[], cast(const(ubyte)[])"session info");
    assert(session_key == expected_session_key);


    // ---- Full session info HMAC tag ----
    // SESSION_INFO bytes (the `session_info` payload field bytes) — from protocol.md.
    //   08 06                          counter = 6
    //   12 41 <65 bytes>               publicKey (SEC1)
    //   1a 10 <16 bytes>               epoch
    //   25 <4 bytes LE>                clock_time = 2650
    static immutable ubyte[] session_info_bytes = HexDecode!(
        "0806124104c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d971a104c463f9cc0d3d26906e982ed224adde6255a0a0000");

    static immutable ubyte[32] expected_tag = HexDecode!(
        "996c1fe38331be138f8039c194b14db2198846ed7d8251e6749284d7b32ea002");

    HMACContext!SHA256Context ctx;
    hmac_init(ctx, session_key[]);
    hmac_update(ctx, meta[]);
    hmac_update(ctx, session_info_bytes[]);
    auto computed_tag = hmac_finalise(ctx);
    assert(computed_tag == expected_tag);


    // ---- SessionInfo decoder ----
    SessionInfo info;
    assert(decode_session_info(session_info_bytes[], info));
    assert(info.counter == 6);
    assert(info.public_key.length == 65);
    assert(info.public_key[0] == 0x04);
    assert(info.epoch.length == 16);
    assert(info.clock_time == 2650);
    assert(info.status == 0);


    // ---- AES-GCM-PERSONALIZED metadata + encryption ----
    // From protocol.md "Turn HVAC on" example:
    //   VIN = 5YJ30123456789ABC
    //   domain = INFOTAINMENT (3)
    //   epoch = 4c463f9cc0d3d26906e982ed224adde6
    //   expires_at = 2655 (0x00000a5f)
    //   counter = 7
    //   plaintext = 120452020801 (CarServer.Action {vehicleAction {hvacAutoAction {power_on:true}}})
    //   nonce = dbf79447fa156674dae1caed
    //   expected ciphertext = 38038e8c0f2e
    //   expected tag = 8e128da165f162f4d7d2c8da866cf82a
    static immutable ubyte[16] hvac_epoch = HexDecode!"4c463f9cc0d3d26906e982ed224adde6";
    Array!ubyte hvac_meta = build_signed_command_metadata(TeslaDomain.infotainment,
                                                          "5YJ30123456789ABC", hvac_epoch[],
                                                          2655, 7, 0);
    static immutable ubyte[] hvac_expected_meta = HexDecode!(
        "000105010103021135594a333031323334353637383941424303104c463f9cc0d3d26906e982ed224adde6040400000a5f050400000007ff");
    assert(hvac_meta[] == hvac_expected_meta);

    // AAD for AES-GCM = SHA256(metadata)
    SHA256Context sha_ctx;
    sha_init(sha_ctx);
    sha_update(sha_ctx, hvac_meta[]);
    ubyte[32] hvac_aad = sha_finalise(sha_ctx);

    static immutable ubyte[6] hvac_plaintext = HexDecode!"120452020801";
    static immutable ubyte[12] hvac_nonce = HexDecode!"dbf79447fa156674dae1caed";
    static immutable ubyte[6] hvac_expected_ct = HexDecode!"38038e8c0f2e";
    static immutable ubyte[16] hvac_expected_tag = HexDecode!"8e128da165f162f4d7d2c8da866cf82a";

    ubyte[6] hvac_ct = void;
    ubyte[16] hvac_tag = void;
    Result enc = aes_gcm_encrypt(K[], hvac_nonce[], hvac_aad[],
                                 hvac_plaintext[], hvac_ct[], hvac_tag[]);
    assert(enc.succeeded);
    assert(hvac_ct == hvac_expected_ct);
    assert(hvac_tag == hvac_expected_tag);
}
