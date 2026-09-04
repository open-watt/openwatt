module protocol.matter.session;

import urt.crypto.aes_ccm;
import urt.crypto.hkdf;

import protocol.matter.message;

nothrow @nogc:


enum matter_key_length = 16;
enum matter_tag_length = 16;
enum matter_nonce_length = 13;

struct SessionKeys
{
    ubyte[matter_key_length] i2r;
    ubyte[matter_key_length] r2i;
    ubyte[matter_key_length] attestation_challenge;

nothrow @nogc:
    bool from_pase(const(ubyte)[] ke)
    {
        ubyte[48] okm = void;
        if (!hkdf_sha256(null, ke, "SessionKeys", okm[]))
            return false;
        i2r[] = okm[0 .. 16];
        r2i[] = okm[16 .. 32];
        attestation_challenge[] = okm[32 .. 48];
        return true;
    }
}

void build_nonce(ref const MessageHeader hdr, ulong source_node, ref ubyte[matter_nonce_length] nonce) pure
{
    nonce[0] = hdr.security_flags;
    foreach (i; 0 .. 4)
        nonce[1 + i] = cast(ubyte)(hdr.counter >> (8*i));
    foreach (i; 0 .. 8)
        nonce[5 + i] = cast(ubyte)(source_node >> (8*i));
}

// header_bytes is the encoded message header, which is authenticated but not encrypted.
// Output is written as ciphertext followed by the 16-byte tag; returns the total length or -1.
ptrdiff_t encrypt_payload(const(ubyte)[] key, ref const MessageHeader hdr, ulong source_node,
                          const(ubyte)[] header_bytes, const(ubyte)[] payload, ubyte[] output)
{
    if (output.length < payload.length + matter_tag_length)
        return -1;
    ubyte[matter_nonce_length] nonce = void;
    build_nonce(hdr, source_node, nonce);
    if (aes_ccm_encrypt(key, nonce[], header_bytes, payload, output[0 .. payload.length],
                        output[payload.length .. payload.length + matter_tag_length]).failed)
        return -1;
    return payload.length + matter_tag_length;
}

ptrdiff_t decrypt_payload(const(ubyte)[] key, ref const MessageHeader hdr, ulong source_node,
                          const(ubyte)[] header_bytes, const(ubyte)[] input, ubyte[] output)
{
    if (input.length < matter_tag_length)
        return -1;
    size_t len = input.length - matter_tag_length;
    if (output.length < len)
        return -1;
    ubyte[matter_nonce_length] nonce = void;
    build_nonce(hdr, source_node, nonce);
    if (aes_ccm_decrypt(key, nonce[], header_bytes, input[0 .. len], input[len .. $], output[0 .. len]).failed)
        return -1;
    return len;
}


struct MessageCounterWindow
{
    enum window_size = 32;

nothrow @nogc:
    bool synchronised() const pure
        => _synchronised;

    void reset(uint counter)
    {
        _max = counter;
        _bitmap = 0;
        _synchronised = true;
    }

    bool accept(uint counter)
    {
        if (!_synchronised)
        {
            reset(counter);
            return true;
        }
        if (counter == _max)
            return false;
        if (counter > _max)
        {
            uint advance = counter - _max;
            _bitmap = advance >= window_size ? 0 : (_bitmap << advance) | (1u << (advance - 1));
            _max = counter;
            return true;
        }
        uint behind = _max - counter;
        if (behind > window_size)
            return false;
        uint bit = 1u << (behind - 1);
        if (_bitmap & bit)
            return false;
        _bitmap |= bit;
        return true;
    }

private:
    uint _max;
    uint _bitmap;
    bool _synchronised;
}


unittest
{
    static immutable ubyte[16] ke = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
    SessionKeys keys;
    assert(keys.from_pase(ke[]));
    assert(keys.i2r != keys.r2i && keys.r2i != keys.attestation_challenge);

    MessageHeader hdr;
    hdr.flags = MessageFlags.source_present;
    hdr.session_id = 1;
    hdr.counter = 0x01020304;
    hdr.source_node = 0x1122334455667788;
    ubyte[32] hbuf;
    ptrdiff_t hlen = encode_message_header(hdr, hbuf[]);
    assert(hlen == 16);

    ubyte[13] nonce;
    build_nonce(hdr, hdr.source_node, nonce);
    assert(nonce[] == [0x00, 0x04, 0x03, 0x02, 0x01, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]);

    static immutable ubyte[10] payload = [0x05, 0x02, 0x01, 0x00, 0x01, 0x00, 0x15, 0x24, 0x00, 0x18];
    ubyte[64] ct;
    ptrdiff_t clen = encrypt_payload(keys.i2r[], hdr, hdr.source_node, hbuf[0 .. hlen], payload[], ct[]);
    assert(clen == payload.length + 16);
    assert(ct[0 .. payload.length] != payload[]);

    ubyte[64] pt;
    ptrdiff_t plen = decrypt_payload(keys.i2r[], hdr, hdr.source_node, hbuf[0 .. hlen], ct[0 .. clen], pt[]);
    assert(plen == payload.length);
    assert(pt[0 .. plen] == payload[]);

    // wrong key, tampered header, and tampered tag all fail
    assert(decrypt_payload(keys.r2i[], hdr, hdr.source_node, hbuf[0 .. hlen], ct[0 .. clen], pt[]) == -1);
    hbuf[1] ^= 1;
    assert(decrypt_payload(keys.i2r[], hdr, hdr.source_node, hbuf[0 .. hlen], ct[0 .. clen], pt[]) == -1);
    hbuf[1] ^= 1;
    ct[clen - 1] ^= 1;
    assert(decrypt_payload(keys.i2r[], hdr, hdr.source_node, hbuf[0 .. hlen], ct[0 .. clen], pt[]) == -1);

    MessageCounterWindow w;
    assert(!w.synchronised);
    assert(w.accept(100));
    assert(!w.accept(100));
    assert(w.accept(101));
    assert(w.accept(99));
    assert(!w.accept(99));
    assert(w.accept(70));
    assert(!w.accept(68));
    assert(w.accept(200));
    assert(!w.accept(101));
    assert(w.accept(199));
    assert(!w.accept(199));
}
