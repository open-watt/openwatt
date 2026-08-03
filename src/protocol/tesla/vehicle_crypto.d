module protocol.tesla.vehicle_crypto;

import urt.array;

nothrow @nogc:


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

enum RoutableFlag : uint
{
    encrypt_response = 1,
}

enum uint encrypt_response_mask = 1u << cast(uint)RoutableFlag.encrypt_response;

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

Array!ubyte build_response_metadata(TeslaDomain domain, const(char)[] vin,
                                    uint counter, uint flags,
                                    const(ubyte)[] request_tag, uint fault)
{
    assert(request_tag.length == 16);

    Array!ubyte meta;
    ubyte[1] sig_type = [cast(ubyte)SigType.aes_gcm_response];
    append_tlv(meta, SigTag.signature_type, sig_type[]);
    ubyte[1] dom = [cast(ubyte)domain];
    append_tlv(meta, SigTag.domain, dom[]);
    append_tlv(meta, SigTag.personalization, cast(const(ubyte)[])vin);

    ubyte[4] ctr_be = [
        cast(ubyte)(counter >> 24), cast(ubyte)(counter >> 16),
        cast(ubyte)(counter >> 8), cast(ubyte)counter
    ];
    append_tlv(meta, SigTag.counter, ctr_be[]);

    ubyte[4] flg_be = [
        cast(ubyte)(flags >> 24), cast(ubyte)(flags >> 16),
        cast(ubyte)(flags >> 8), cast(ubyte)flags
    ];
    append_tlv(meta, SigTag.flags, flg_be[]);

    ubyte[17] request_hash = void;
    request_hash[0] = cast(ubyte)SigType.aes_gcm_personalized;
    request_hash[1 .. $] = request_tag[];
    append_tlv(meta, SigTag.request_hash, request_hash[]);

    ubyte[4] fault_be = [
        cast(ubyte)(fault >> 24), cast(ubyte)(fault >> 16),
        cast(ubyte)(fault >> 8), cast(ubyte)fault
    ];
    append_tlv(meta, SigTag.fault, fault_be[]);
    meta ~= cast(ubyte)SigTag.end;
    return meta;
}

struct ResponseReplayWindow
{
nothrow @nogc:

    bool accept(uint counter)
    {
        if (!_initialised)
        {
            _highest = counter;
            _seen = 1;
            _initialised = true;
            return true;
        }

        if (counter > _highest)
        {
            uint shift = counter - _highest;
            _seen = shift >= 64 ? 1 : (_seen << shift) | 1;
            _highest = counter;
            return true;
        }

        uint age = _highest - counter;
        if (age >= 64)
            return false;
        ulong bit = ulong(1) << age;
        if (_seen & bit)
            return false;
        _seen |= bit;
        return true;
    }

private:
    uint _highest;
    ulong _seen;
    bool _initialised;
}


// Test vectors from teslamotors/vehicle-command protocol.md.
unittest
{
    import urt.crypto.aes : aes_gcm_encrypt;
    import urt.digest.hmac;
    import urt.digest.sha;
    import urt.encoding : HexDecode;
    import urt.result;

    static assert(encrypt_response_mask == 2);

    // ---- Metadata TLV layout ----
    // METADATA = TLV(SIG_TYPE_HMAC) || TLV(VIN) || TLV(CHALLENGE) || 0xFF
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
    // SESSION_INFO bytes (the `session_info` payload field bytes) from protocol.md:
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


    // ---- AES-GCM-PERSONALIZED metadata + encryption ----
    // protocol.md "Turn HVAC on": VIN 5YJ30123456789ABC, domain INFOTAINMENT,
    // expires_at 2655, counter 7, plaintext = CarServer.Action{hvacAutoAction{power_on:true}}
    static immutable ubyte[16] hvac_epoch = HexDecode!"4c463f9cc0d3d26906e982ed224adde6";
    Array!ubyte hvac_meta = build_signed_command_metadata(TeslaDomain.infotainment,
                                                          "5YJ30123456789ABC", hvac_epoch[],
                                                          2655, 7, 0);
    static immutable ubyte[] hvac_expected_meta = HexDecode!(
        "000105010103021135594a333031323334353637383941424303104c463f9cc0d3d26906e982ed224adde6040400000a5f050400000007ff");
    assert(hvac_meta[] == hvac_expected_meta);

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


    // ---- Response metadata layout ----
    static immutable ubyte[16] request_tag = HexDecode!"000102030405060708090a0b0c0d0e0f";
    Array!ubyte response_meta = build_response_metadata(
        TeslaDomain.infotainment, "5YJ30123456789ABC",
        0x01020304, encrypt_response_mask, request_tag[], 28);
    static immutable ubyte[] expected_response_meta = HexDecode!(
        "000109010103021135594a3330313233343536373839414243"
        ~ "050401020304070400000002081105000102030405060708090a0b0c0d0e0f"
        ~ "09040000001cff");
    assert(response_meta[] == expected_response_meta);


    // ---- Response replay window ----
    ResponseReplayWindow replay;
    assert(replay.accept(100));
    assert(replay.accept(102));
    assert(replay.accept(101));
    assert(!replay.accept(101));
    assert(!replay.accept(102));
    assert(!replay.accept(37));
}
