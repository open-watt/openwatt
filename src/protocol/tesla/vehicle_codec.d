module protocol.tesla.vehicle_codec;

import urt.array;
import urt.crypto.aes : aes_gcm_decrypt;
import urt.digest.sha;
import urt.encoding : hex_decode;
import urt.endian;
import urt.result;
import urt.uuid;

import protocol.tesla.vehicle_crypto;

import tools.protobuf;

nothrow @nogc:

mixin LoadProtobuf!"protocol/tesla/commands.proto";
mixin LoadProtobuf!"protocol/tesla/messages.proto";

// TODO: the generated decoder copies `bytes` fields out of the receive buffer
//       (tools.protobuf decode_value allocates an Array!ubyte per field). The
//       response path is small and infrequent so the copies are affordable for
//       now, but tools.protobuf should grow borrowed const(ubyte)[] fields so
//       decoding is zero-copy; every proto consumer benefits.

private Array!ubyte encode(T)(ref const T msg)
{
    Array!ubyte buf;
    buf.resize(buffer_len(msg));
    size_t written = proto_serialise(buf[], msg);
    assert(written == buf.length);
    return buf;
}

private void set_bytes(ref ProtoOptional!(Array!ubyte) field, const(ubyte)[] value)
{
    field.ensure().extend(value.length)[] = value[];
}

// Tesla requires SEC1 uncompressed public keys: 0x04 || X || Y.
private void set_sec1(ref ProtoOptional!(Array!ubyte) field, const(ubyte)[] pubkey_xy)
{
    assert(pubkey_xy.length == 64);
    ubyte[] dst = field.ensure().extend(65);
    dst[0] = 0x04;
    dst[1 .. 65] = pubkey_xy[];
}

enum GUID TESLA_SERVICE_UUID = GUID(0x00000211, 0xb2d1, 0x43f0, [0x9b, 0x88, 0x96, 0x0c, 0xeb, 0xf8, 0xb9, 0x1e]);
enum GUID TESLA_TX_CHAR_UUID = GUID(0x00000212, 0xb2d1, 0x43f0, [0x9b, 0x88, 0x96, 0x0c, 0xeb, 0xf8, 0xb9, 0x1e]);
enum GUID TESLA_RX_CHAR_UUID = GUID(0x00000213, 0xb2d1, 0x43f0, [0x9b, 0x88, 0x96, 0x0c, 0xeb, 0xf8, 0xb9, 0x1e]);

// BLE advertisement local name format: 'S' + 16 hex chars + 'C'
// where the 16 hex chars are the lowercase hex of SHA1(VIN)[:8].
enum size_t TESLA_LOCAL_NAME_LEN = 18;

void tesla_vin_hash(const(char)[] vin, out ubyte[8] hash)
{
    SHA1Context ctx;
    sha_init(ctx);
    sha_update(ctx, cast(const(ubyte)[])vin);
    Array!ubyte digest = sha_finalise(ctx);
    hash[] = digest[0 .. 8];
}

bool parse_tesla_local_name(const(char)[] local_name, out ubyte[8] hash) pure
{
    if (local_name.length != TESLA_LOCAL_NAME_LEN)
        return false;
    if (local_name[0] != 'S' || local_name[17] != 'C')
        return false;
    return hex_decode(local_name[1 .. 17], hash[]) == 8;
}

// NFC authorises this otherwise unsigned pairing request.
Array!ubyte build_add_key_request(const(ubyte)[] pubkey_xy)
{
    assert(pubkey_xy.length == 64, "Tesla AddKey requires 64-byte raw public point");

    enum uint role_owner = 2;                  // Keys.Role.ROLE_OWNER
    enum uint form_factor_cloud_key = 9;       // vcsec.KeyFormFactor.KEY_FORM_FACTOR_CLOUD_KEY
    enum uint signature_type_present_key = 2;  // vcsec.SignatureType.SIGNATURE_TYPE_PRESENT_KEY

    TeslaUnsignedMessage unsigned;
    ref whitelist = unsigned.whitelist_operation.ensure();
    ref permission = whitelist.add_key_to_whitelist_and_add_permissions.ensure();
    set_sec1(permission.key.ensure().public_key_raw, pubkey_xy);
    permission.key_role.set(role_owner);
    whitelist.metadata_for_key.ensure().key_form_factor.set(form_factor_cloud_key);

    Array!ubyte unsigned_bytes = encode(unsigned);

    TeslaToVcsecMessage msg;
    ref signed = msg.signed_message.ensure();
    set_bytes(signed.protobuf_message_as_bytes, unsigned_bytes[]);
    signed.signature_type.set(signature_type_present_key);
    return encode(msg);
}

Array!ubyte build_session_info_request(TeslaDomain domain, const(ubyte)[] pubkey,
                                       const(ubyte)[] routing_address, const(ubyte)[] uuid)
{
    assert(pubkey.length == 65);
    assert(routing_address.length == 16);
    assert(uuid.length == 16);

    TeslaRoutableMessage msg;
    msg.to_destination.ensure().domain.set(cast(uint)domain);
    set_bytes(msg.from_destination.ensure().routing_address, routing_address);
    set_bytes(msg.session_info_request.ensure().public_key, pubkey);
    set_bytes(msg.uuid, uuid);
    return encode(msg);
}

// The payload is pre-encrypted against build_signed_command_metadata()'s AAD.
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
    assert(signer_pubkey_sec1.length == 65);
    assert(epoch.length == 16);
    assert(nonce.length == 12);
    assert(tag.length == 16);
    assert(routing_address.length == 16);
    assert(uuid.length == 16);

    TeslaRoutableMessage msg;
    msg.to_destination.ensure().domain.set(cast(uint)domain);
    set_bytes(msg.from_destination.ensure().routing_address, routing_address);
    set_bytes(msg.protobuf_message_as_bytes, ciphertext);

    ref signature = msg.signature_data.ensure();
    set_bytes(signature.signer_identity.ensure().public_key, signer_pubkey_sec1);
    ref gcm = signature.aes_gcm_personalized.ensure();
    set_bytes(gcm.epoch, epoch);
    set_bytes(gcm.nonce, nonce);
    gcm.counter.set(counter);
    gcm.expires_at.set(expires_at);
    set_bytes(gcm.tag, tag);

    set_bytes(msg.uuid, uuid);
    if (flags != 0)
        msg.flags.set(flags);
    return encode(msg);
}

Array!ubyte build_action_get_charge_state()
{
    TeslaAction action;
    action.vehicle_action.ensure()
          .get_vehicle_data.ensure()
          .get_charge_state.ensure();
    return encode(action);
}

// one category per request; the vehicle rejects a combined query with RESPONSE_MTU_EXCEEDED
Array!ubyte build_action_get_vehicle_category(uint category)
{
    TeslaAction action;
    ref request = action.vehicle_action.ensure().get_vehicle_data.ensure();
    switch (category)
    {
        case 0:  request.get_drive_state.ensure(); break;
        case 1:  request.get_location_state.ensure(); break;
        case 2:  request.get_closures_state.ensure(); break;
        default: request.get_tire_pressure_state.ensure(); break;
    }
    return encode(action);
}

Array!ubyte build_action_get_climate_state()
{
    TeslaAction action;
    action.vehicle_action.ensure()
          .get_vehicle_data.ensure()
          .get_climate_state.ensure();
    return encode(action);
}

Array!ubyte build_action_charging_start_stop(bool start)
{
    TeslaAction action;
    ref TeslaChargingStartStopAction command =
        action.vehicle_action.ensure().charging_start_stop.ensure();
    if (start)
        command.start.ensure();
    else
        command.stop.ensure();
    return encode(action);
}

Array!ubyte build_action_set_charging_amps(int amps)
{
    TeslaAction action;
    action.vehicle_action.ensure()
          .set_charging_amps.ensure()
          .charging_amps.set(amps);
    return encode(action);
}

Array!ubyte build_action_climate_power(bool enabled)
{
    TeslaAction action;
    action.vehicle_action.ensure()
          .hvac_auto.ensure()
          .power_on.set(enabled);
    return encode(action);
}

Array!ubyte build_action_climate_temperature(float driver_celsius, float passenger_celsius)
{
    TeslaAction action;
    ref TeslaHvacTemperatureAdjustmentAction command =
        action.vehicle_action.ensure().hvac_temperature.ensure();
    command.level.ensure().maximum.ensure();
    command.driver_temp_celsius.set(driver_celsius);
    command.passenger_temp_celsius.set(passenger_celsius);
    return encode(action);
}

Array!ubyte build_action_schedule_charging(bool enabled, int minutes_after_midnight)
{
    TeslaAction action;
    ref TeslaScheduledChargingAction command =
        action.vehicle_action.ensure().scheduled_charging.ensure();
    command.enabled.set(enabled);
    command.charging_time.set(minutes_after_midnight);
    return encode(action);
}

bool decode_carserver_response(const(ubyte)[] response_bytes, ref TeslaCommandResponse response)
    => proto_deserialise(response_bytes, response) == response_bytes.length;

int charging_state_kind(ref const TeslaChargingState state) pure
{
    if (state.unknown.present) return 1;
    if (state.disconnected.present) return 2;
    if (state.no_power.present) return 3;
    if (state.starting.present) return 4;
    if (state.charging.present) return 5;
    if (state.complete.present) return 6;
    if (state.stopped.present) return 7;
    if (state.calibrating.present) return 8;
    return 0;
}

int shift_state_kind(ref const TeslaShiftState state) pure
{
    if (state.invalid.present) return 1;
    if (state.park.present) return 2;
    if (state.reverse.present) return 3;
    if (state.neutral.present) return 4;
    if (state.drive.present) return 5;
    if (state.unavailable.present) return 6;
    return 0;
}

int climate_keeper_mode_kind(ref const TeslaClimateKeeperMode state) pure
{
    if (state.unknown.present) return 1;
    if (state.off.present) return 2;
    if (state.on.present) return 3;
    if (state.dog.present) return 4;
    if (state.party.present) return 5;
    return 0;
}

int defrost_mode_kind(ref const TeslaDefrostMode state) pure
{
    if (state.off.present) return 1;
    if (state.normal.present) return 2;
    if (state.maximum.present) return 3;
    return 0;
}

// Owns the decoded message behind its convenience accessors.
struct RoutableResponse
{
nothrow @nogc:

    TeslaRoutableMessage message;

    const(ubyte)[] session_info() const pure
        => message.session_info.present ? message.session_info.value[] : null;
    const(ubyte)[] protobuf_message() const pure
        => message.protobuf_message_as_bytes.present ? message.protobuf_message_as_bytes.value[] : null;
    const(ubyte)[] request_uuid() const pure
        => message.request_uuid.present ? message.request_uuid.value[] : null;
    uint flags() const pure
        => message.flags.present ? message.flags.value : 0;

    bool has_from_domain() const pure
        => message.from_destination.present && message.from_destination.value.domain.present;
    TeslaDomain from_domain() const pure
        => cast(TeslaDomain)(has_from_domain ? message.from_destination.value.domain.value : 0);

    bool addressed_to(const(ubyte)[] routing_address) const pure
    {
        if (!message.to_destination.present)
            return false;
        ref dest = message.to_destination.value;
        return dest.routing_address.present && dest.routing_address.value[] == routing_address;
    }

    bool has_status() const pure
        => message.signed_message_status.present;
    uint signed_message_fault() const pure
    {
        if (!has_status)
            return 0;
        ref status = message.signed_message_status.value;
        return status.signed_message_fault.present ? status.signed_message_fault.value : 0;
    }

    const(ubyte)[] session_info_tag() const pure
    {
        if (!message.signature_data.present)
            return null;
        ref signature = message.signature_data.value;
        if (!signature.session_info_tag.present || !signature.session_info_tag.value.tag.present)
            return null;
        return signature.session_info_tag.value.tag.value[];
    }

    bool has_response_signature() const pure
        => message.signature_data.present && message.signature_data.value.aes_gcm_response.present;
    const(ubyte)[] response_nonce() const pure
    {
        if (!has_response_signature)
            return null;
        ref gcm = message.signature_data.value.aes_gcm_response.value;
        return gcm.nonce.present ? gcm.nonce.value[] : null;
    }
    const(ubyte)[] response_tag() const pure
    {
        if (!has_response_signature)
            return null;
        ref gcm = message.signature_data.value.aes_gcm_response.value;
        return gcm.tag.present ? gcm.tag.value[] : null;
    }
    uint response_counter() const pure
    {
        if (!has_response_signature)
            return 0;
        ref gcm = message.signature_data.value.aes_gcm_response.value;
        return gcm.counter.present ? gcm.counter.value : 0;
    }
}

bool decode_routable_response(const(ubyte)[] buf, ref RoutableResponse r)
    => proto_deserialise(buf, r.message) == buf.length;

// The GCM tag authenticates the response metadata as AAD.
bool decrypt_routable_response(ref const RoutableResponse response,
                               const(ubyte)[] key, const(char)[] vin,
                               const(ubyte)[] request_tag,
                               ref Array!ubyte plaintext)
{
    if (!response.has_response_signature || !response.has_from_domain
        || response.response_nonce.length != 12 || response.response_tag.length != 16
        || request_tag.length != 16)
        return false;

    Array!ubyte metadata = build_response_metadata(response.from_domain, vin,
                                                   response.response_counter, response.flags,
                                                   request_tag, response.signed_message_fault);
    SHA256Context sha;
    sha_init(sha);
    sha_update(sha, metadata[]);
    ubyte[32] aad = sha_finalise(sha);

    const(ubyte)[] ciphertext = response.protobuf_message;
    plaintext.resize(ciphertext.length);
    Result result = aes_gcm_decrypt(key, response.response_nonce, aad[],
                                    ciphertext, response.response_tag, plaintext[]);
    if (result.failed)
    {
        plaintext.clear();
        return false;
    }
    return true;
}

struct SessionInfo
{
nothrow @nogc:

    TeslaSessionInfo message;

    uint counter() const pure
        => message.counter.present ? message.counter.value : 0;
    const(ubyte)[] public_key() const pure
        => message.public_key.present ? message.public_key.value[] : null;
    const(ubyte)[] epoch() const pure
        => message.epoch.present ? message.epoch.value[] : null;
    uint clock_time() const pure
        => message.clock_time.present ? message.clock_time.value : 0;
    // 0 = OK, 1 = KEY_NOT_ON_WHITELIST
    uint status() const pure
        => message.status.present ? message.status.value : 0;
    uint handle() const pure
        => message.handle.present ? message.handle.value : 0;
}

bool decode_session_info(const(ubyte)[] buf, ref SessionInfo info)
    => proto_deserialise(buf, info.message) == buf.length;

unittest
{
    import urt.crypto.aes : aes_gcm_encrypt;
    import urt.encoding : HexDecode;

    assert(build_action_get_charge_state()[] == HexDecode!"12040a021200");
    assert(build_action_get_climate_state()[] == HexDecode!"12040a021a00");
    assert(build_action_get_vehicle_category(0)[] == HexDecode!"12040a022200");
    assert(build_action_get_vehicle_category(1)[] == HexDecode!"12040a023a00");
    assert(build_action_get_vehicle_category(2)[] == HexDecode!"12040a024200");
    assert(build_action_get_vehicle_category(3)[] == HexDecode!"12040a027200");
    assert(build_action_charging_start_stop(true)[] == HexDecode!"120432021200");
    assert(build_action_charging_start_stop(false)[] == HexDecode!"120432022a00");
    assert(build_action_set_charging_amps(16)[] == HexDecode!"1205da02020810");
    assert(build_action_climate_power(true)[] == HexDecode!"120452020801");
    assert(build_action_climate_power(false)[] == HexDecode!"120452020800");
    assert(build_action_climate_temperature(21, 21)[] ==
        HexDecode!"1210720e2a021a00350000a8413d0000a841");
    assert(build_action_schedule_charging(true, 120)[] == HexDecode!"1207ca020408011078");

    TeslaCommandResponse accepted;
    static immutable ubyte[] accepted_response = HexDecode!"0a020800";
    assert(proto_deserialise(accepted_response, accepted) == accepted_response.length);
    assert(accepted.action_status.present);
    assert(accepted.action_status.value.result.present);
    assert(accepted.action_status.value.result.value == 0);

    TeslaCommandResponse rejected_command;
    static immutable ubyte[] rejected_response = HexDecode!"0a08080112040a026e6f";
    assert(proto_deserialise(rejected_response, rejected_command) == rejected_response.length);
    assert(rejected_command.action_status.value.result.value == 1);
    assert(rejected_command.action_status.value.result_reason.value.plain_text.value[] == "no");

    static immutable ubyte[] climate_response = HexDecode!"120b2209ad060000ac41f00601";
    TeslaCommandResponse climate;
    assert(decode_carserver_response(climate_response, climate));
    assert(climate.vehicle_data.value.climate_state.value.inside_temperature.value == 21.5f);
    assert(climate.vehicle_data.value.climate_state.value.climate_on.value);

    static immutable ubyte[] comfort_response = HexDecode!"120b2209880703d80802a00903";
    TeslaCommandResponse comfort;
    assert(decode_carserver_response(comfort_response, comfort));
    ref const comfort_state = comfort.vehicle_data.value.climate_state.value;
    assert(comfort_state.seat_front_left_heating.value == 3);
    assert(comfort_state.seat_front_left_cooling.value == 2);
    assert(comfort_state.steering_wheel_heat_level.value
        == TeslaSteeringWheelHeatLevel.TeslaSteeringWheelHeatHigh);

    static immutable ubyte[] closures_response = HexDecode!"12084a06a80601880701";
    TeslaCommandResponse closures;
    assert(decode_carserver_response(closures_response, closures));
    ref const closures_state = closures.vehicle_data.value.closures_state.value;
    assert(closures_state.driver_front_open.value);
    assert(closures_state.locked.value);

    static immutable ubyte[] drive_response = HexDecode!"120c2a0a0a021200d50600004841";
    TeslaCommandResponse drive;
    assert(decode_carserver_response(drive_response, drive));
    ref const drive_state = drive.vehicle_data.value.drive_state.value;
    assert(shift_state_kind(drive_state.gear.value) == 2);
    assert(drive_state.speed_float.value == 12.5f);

    static immutable ubyte[] location_response = HexDecode!"12084206ad0600002041";
    TeslaCommandResponse location;
    assert(decode_carserver_response(location_response, location));
    assert(location.vehicle_data.value.location_state.value.latitude.value == 10.0f);

    static immutable ubyte[] tyres_response = HexDecode!"12089a0105150000a040";
    TeslaCommandResponse tyres;
    assert(decode_carserver_response(tyres_response, tyres));
    assert(tyres.vehicle_data.value.tire_pressure_state.value.front_left_pressure.value == 5.0f);

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

    static immutable ubyte[] session_info_bytes = HexDecode!(
        "0806124104c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d971a104c463f9cc0d3d26906e982ed224adde6255a0a0000");

    SessionInfo info;
    assert(decode_session_info(session_info_bytes[], info));
    assert(info.counter == 6);
    assert(info.public_key.length == 65);
    assert(info.public_key[0] == 0x04);
    assert(info.epoch.length == 16);
    assert(info.clock_time == 2650);
    assert(info.status == 0);

    static immutable ubyte[16] K = HexDecode!"1b2fce19967b79db696f909cff89ea9a";
    static immutable ubyte[16] request_tag = HexDecode!"000102030405060708090a0b0c0d0e0f";
    static immutable ubyte[12] response_nonce = HexDecode!"101112131415161718191a1b";
    static immutable ubyte[16] response_uuid = HexDecode!"202122232425262728292a2b2c2d2e2f";
    static immutable ubyte[] response_plaintext = HexDecode!"12040a021200";
    enum uint response_counter = 23;
    enum uint response_flags = encrypt_response_mask;

    Array!ubyte response_meta = build_response_metadata(
        TeslaDomain.infotainment, "5YJ30123456789ABC",
        response_counter, response_flags, request_tag[], 0);
    SHA256Context sha_ctx;
    sha_init(sha_ctx);
    sha_update(sha_ctx, response_meta[]);
    ubyte[32] response_aad = sha_finalise(sha_ctx);

    Array!ubyte response_ciphertext;
    response_ciphertext.resize(response_plaintext.length);
    ubyte[16] response_tag = void;
    Result enc = aes_gcm_encrypt(K[], response_nonce[], response_aad[],
                                 response_plaintext, response_ciphertext[], response_tag[]);
    assert(enc.succeeded);

    Array!ubyte response_message;
    response_message ~= cast(ubyte)0x3A; // from_destination
    response_message ~= cast(ubyte)0x02;
    response_message ~= cast(ubyte)0x08;
    response_message ~= cast(ubyte)TeslaDomain.infotainment;
    response_message ~= cast(ubyte)0x52; // protobuf_message_as_bytes
    response_message ~= cast(ubyte)response_ciphertext.length;
    response_message ~= response_ciphertext[];
    response_message ~= cast(ubyte)0x6A; // signature_data
    response_message ~= cast(ubyte)0x24;
    response_message ~= cast(ubyte)0x4A; // AES_GCM_Response_data
    response_message ~= cast(ubyte)0x22;
    response_message ~= cast(ubyte)0x0A; // nonce
    response_message ~= cast(ubyte)response_nonce.length;
    response_message ~= response_nonce[];
    response_message ~= cast(ubyte)0x10; // counter
    response_message ~= cast(ubyte)response_counter;
    response_message ~= cast(ubyte)0x1A; // tag
    response_message ~= cast(ubyte)response_tag.length;
    response_message ~= response_tag[];
    response_message ~= cast(ubyte)0x92; // request_uuid, field 50
    response_message ~= cast(ubyte)0x03;
    response_message ~= cast(ubyte)response_uuid.length;
    response_message ~= response_uuid[];
    response_message ~= cast(ubyte)0xA0; // flags, field 52
    response_message ~= cast(ubyte)0x03;
    response_message ~= cast(ubyte)response_flags;

    RoutableResponse response;
    assert(decode_routable_response(response_message[], response));
    assert(response.has_from_domain);
    assert(response.from_domain == TeslaDomain.infotainment);
    assert(response.has_response_signature);
    assert(response.response_counter == response_counter);
    assert(response.flags == response_flags);
    assert(response.request_uuid == response_uuid[]);
    assert(response.response_nonce == response_nonce[]);
    assert(response.response_tag == response_tag[]);

    Array!ubyte decrypted;
    assert(decrypt_routable_response(response, K[], "5YJ30123456789ABC",
                                     request_tag[], decrypted));
    assert(decrypted[] == response_plaintext);

    RoutableResponse tampered;
    assert(decode_routable_response(response_message[], tampered));
    tampered.message.signature_data.value.aes_gcm_response.value.tag.value[0] ^= 1;
    Array!ubyte rejected;
    assert(!decrypt_routable_response(tampered, K[], "5YJ30123456789ABC",
                                      request_tag[], rejected));
}

// Envelope golden vectors pin the field order and the multi-byte
// varint cases (signature_data length > 127, counter > 127).
unittest
{
    import urt.encoding : HexDecode;

    static ubyte[64] pub_xy = () { ubyte[64] a; foreach (i; 0 .. 64) a[i] = cast(ubyte)i; return a; }();
    static ubyte[65] sec1 = () { ubyte[65] a; a[0] = 0x04; foreach (i; 0 .. 64) a[i+1] = cast(ubyte)i; return a; }();
    static ubyte[16] ra = () { ubyte[16] a; foreach (i; 0 .. 16) a[i] = cast(ubyte)(0x40 + i); return a; }();
    static ubyte[16] uu = () { ubyte[16] a; foreach (i; 0 .. 16) a[i] = cast(ubyte)(0x50 + i); return a; }();
    static ubyte[16] ep = () { ubyte[16] a; foreach (i; 0 .. 16) a[i] = cast(ubyte)(0x60 + i); return a; }();
    static ubyte[12] no = () { ubyte[12] a; foreach (i; 0 .. 12) a[i] = cast(ubyte)(0x70 + i); return a; }();
    static ubyte[16] tg = () { ubyte[16] a; foreach (i; 0 .. 16) a[i] = cast(ubyte)(0x80 + i); return a; }();
    static immutable ubyte[6] ct = [1,2,3,4,5,6];

    assert(build_add_key_request(pub_xy[])[] == HexDecode!(
        "0A54125082014D2A470A430A4104000102030405060708090A0B0C0D0E0F1011121314151617"
        ~ "18191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F"
        ~ "2002320208091802"));

    assert(build_session_info_request(TeslaDomain.vehicle_security, sec1[], ra[], uu[])[] == HexDecode!(
        "320208023A121210404142434445464748494A4B4C4D4E4F72430A4104000102030405060708"
        ~ "090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F"
        ~ "303132333435363738393A3B3C3D3E3F9A0310505152535455565758595A5B5C5D5E5F"));

    assert(build_session_info_request(TeslaDomain.infotainment, sec1[], ra[], uu[])[] == HexDecode!(
        "320208033A121210404142434445464748494A4B4C4D4E4F72430A4104000102030405060708"
        ~ "090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F"
        ~ "303132333435363738393A3B3C3D3E3F9A0310505152535455565758595A5B5C5D5E5F"));

    assert(build_signed_routable_message(TeslaDomain.infotainment, ct[], sec1[],
            ep[], no[], 7, 2655, tg[], ra[], uu[], 0)[] == HexDecode!(
        "320208033A121210404142434445464748494A4B4C4D4E4F52060102030405066A80010A430A"
        ~ "4104000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324"
        ~ "25262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F2A390A106061626364656667"
        ~ "68696A6B6C6D6E6F120C707172737475767778797A7B1807255F0A00002A1080818283848586"
        ~ "8788898A8B8C8D8E8F9A0310505152535455565758595A5B5C5D5E5F"));

    assert(build_signed_routable_message(TeslaDomain.infotainment, ct[], sec1[],
            ep[], no[], 300, 2655, tg[], ra[], uu[], encrypt_response_mask)[] == HexDecode!(
        "320208033A121210404142434445464748494A4B4C4D4E4F52060102030405066A81010A430A"
        ~ "4104000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324"
        ~ "25262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F2A3A0A106061626364656667"
        ~ "68696A6B6C6D6E6F120C707172737475767778797A7B18AC02255F0A00002A1080818283848586"
        ~ "8788898A8B8C8D8E8F9A0310505152535455565758595A5B5C5D5E5FA00302"));
}
