module protocol.matter.case_;

import urt.crypto.aes_ccm;
import urt.crypto.ecdsa;
import urt.crypto.hkdf;
import urt.crypto.p256;
import urt.crypto.random;
import urt.digest.sha;

import protocol.matter.cert;
import protocol.matter.fabric;
import protocol.matter.session;
import protocol.matter.tlv;
import protocol.matter.x509;

nothrow @nogc:


enum CaseState : ubyte
{
    idle,
    awaiting_sigma1,
    awaiting_sigma2,
    awaiting_sigma3,
    awaiting_status,
    complete,
    failed,
}

enum case_max_message = 1024;

// Validates a peer's NOC (and optional ICAC) against our fabric's root and returns the peer identity.
bool validate_peer_chain(ref const FabricInfo fabric, const(ubyte)[] noc_bytes, const(ubyte)[] icac_bytes,
                         out ulong peer_node_id, out const(ubyte)[] peer_public_key)
{
    MatterCert noc, icac;
    if (!decode_matter_cert(noc_bytes, noc) || noc.type != MatterCertType.noc)
        return false;
    if (noc.subject.fabric_id != fabric.fabric_id)
        return false;

    MatterCert root;
    if (!decode_matter_cert(fabric.rcac, root) || root.type != MatterCertType.rcac)
        return false;
    if (root.public_key != fabric.root_public_key[])
        return false;

    if (icac_bytes.length)
    {
        if (!decode_matter_cert(icac_bytes, icac) || icac.type != MatterCertType.icac)
            return false;
        if (!issued_by(icac, root) || !verify_matter_cert(icac, root.public_key))
            return false;
        if (!issued_by(noc, icac) || !verify_matter_cert(noc, icac.public_key))
            return false;
    }
    else if (!issued_by(noc, root) || !verify_matter_cert(noc, root.public_key))
        return false;

    peer_node_id = noc.subject.node_id;
    peer_public_key = noc.public_key;
    return true;
}


struct CaseInitiator
{
nothrow @nogc:
    CaseState state() const pure
        => _state;

    ushort local_session_id() const pure
        => _local_session;

    ushort peer_session_id() const pure
        => _peer_session;

    ulong peer_node_id() const pure
        => _peer_node_id;

    ref const(SessionKeys) keys() const pure
        => _keys;

    // Emits Sigma1.
    ptrdiff_t begin(ref const FabricInfo fabric, ulong peer_node_id, ushort local_session_id, ubyte[] output)
    {
        _fabric = &fabric;
        _peer_node_id = peer_node_id;
        _local_session = local_session_id;
        if (crypto_random_bytes(_random[]).failed || !generate_ephemeral(_eph_private, _eph_public))
            return fail();

        ubyte[32] dest = fabric.destination_id(_random[], peer_node_id);
        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), _random[]);
        w.put(TLVTag.context(2), cast(uint)local_session_id);
        w.put(TLVTag.context(3), dest[]);
        w.put(TLVTag.context(4), _eph_public[]);
        if (!w.end_container() || w.overflow)
            return fail();

        sha_init(_transcript);
        sha_update(_transcript, w.data);
        _sigma1_hash = hash_of(w.data);
        _state = CaseState.awaiting_sigma2;
        return w.length;
    }

    // Consumes Sigma2, emits Sigma3.
    ptrdiff_t on_sigma2(const(ubyte)[] message, ubyte[] output)
    {
        if (_state != CaseState.awaiting_sigma2)
            return fail();

        const(ubyte)[] responder_random, responder_eph, encrypted;
        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
            return fail();
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.is_context(1))
                responder_random = r.as_bytes;
            else if (r.tag.is_context(2))
            {
                if (!r.get(_peer_session))
                    return fail();
            }
            else if (r.tag.is_context(3))
                responder_eph = r.as_bytes;
            else if (r.tag.is_context(4))
                encrypted = r.as_bytes;
            else if (!r.skip())
                return fail();
        }
        if (responder_random.length != 32 || responder_eph.length != 65 || encrypted.length < matter_tag_length)
            return fail();

        if (!ecdh(_eph_private, responder_eph, _shared))
            return fail();

        // S2K = HKDF(salt = IPK || responderRandom || responderEphPubKey || Hash(Sigma1), ikm = shared, info = "Sigma2")
        ubyte[16 + 32 + 65 + 32] salt = void;
        salt[0 .. 16] = _fabric.ipk[];
        salt[16 .. 48] = responder_random[];
        salt[48 .. 113] = responder_eph[];
        salt[113 .. 145] = _sigma1_hash[];
        ubyte[16] s2k = void;
        if (!hkdf_sha256(salt[], _shared[], "Sigma2", s2k[]))
            return fail();

        ubyte[case_max_message] plain = void;
        size_t plain_len = encrypted.length - matter_tag_length;
        if (plain_len > plain.length)
            return fail();
        if (aes_ccm_decrypt(s2k[], sigma2_nonce, null, encrypted[0 .. plain_len], encrypted[plain_len .. $], plain[0 .. plain_len]).failed)
            return fail();

        const(ubyte)[] peer_noc, peer_icac, signature;
        if (!decode_tbe(plain[0 .. plain_len], peer_noc, peer_icac, signature))
            return fail();

        const(ubyte)[] peer_key;
        ulong node;
        if (!validate_peer_chain(*_fabric, peer_noc, peer_icac, node, peer_key) || node != _peer_node_id)
            return fail();
        if (!verify_tbs(peer_key, peer_noc, peer_icac, responder_eph, _eph_public[], signature))
            return fail();

        sha_update(_transcript, message);

        // Sigma3: our NOC/ICAC and a signature over them and both ephemeral keys, encrypted with S3K
        ubyte[case_max_message] tbe = void;
        ubyte[64] sig = void;
        if (!sign_tbs(_fabric.operational_private_key[], _fabric.noc, _fabric.icac, _eph_public[], responder_eph, sig))
            return fail();
        ptrdiff_t tbe_len = encode_tbe(tbe[], _fabric.noc, _fabric.icac, sig[], null);
        if (tbe_len < 0)
            return fail();

        SHA256Context t = _transcript;
        ubyte[32] transcript_hash = sha_finalise(t);
        ubyte[16 + 32] salt3 = void;
        salt3[0 .. 16] = _fabric.ipk[];
        salt3[16 .. 48] = transcript_hash[];
        ubyte[16] s3k = void;
        if (!hkdf_sha256(salt3[], _shared[], "Sigma3", s3k[]))
            return fail();

        ubyte[case_max_message] enc = void;
        if (tbe_len + matter_tag_length > enc.length)
            return fail();
        if (aes_ccm_encrypt(s3k[], sigma3_nonce, null, tbe[0 .. tbe_len], enc[0 .. tbe_len], enc[tbe_len .. tbe_len + matter_tag_length]).failed)
            return fail();

        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), cast(const(ubyte)[])enc[0 .. tbe_len + matter_tag_length]);
        if (!w.end_container() || w.overflow)
            return fail();

        sha_update(_transcript, w.data);
        if (!derive_session_keys(_fabric.ipk, _transcript, _shared, _keys))
            return fail();
        _state = CaseState.awaiting_status;
        return w.length;
    }

    bool on_status(bool success)
    {
        if (_state != CaseState.awaiting_status || !success)
        {
            fail();
            return false;
        }
        _state = CaseState.complete;
        return true;
    }

private:
    CaseState _state;
    ushort _local_session;
    ushort _peer_session;
    ulong _peer_node_id;
    const(FabricInfo)* _fabric;
    ubyte[32] _random;
    ubyte[32] _eph_private;
    ubyte[65] _eph_public;
    ubyte[32] _shared;
    ubyte[32] _sigma1_hash;
    SHA256Context _transcript;
    SessionKeys _keys;

    ptrdiff_t fail()
    {
        _state = CaseState.failed;
        return -1;
    }
}


struct CaseResponder
{
nothrow @nogc:
    CaseState state() const pure
        => _state;

    ushort local_session_id() const pure
        => _local_session;

    ushort peer_session_id() const pure
        => _peer_session;

    ulong peer_node_id() const pure
        => _peer_node_id;

    ref const(SessionKeys) keys() const pure
        => _keys;

    void begin(ref const FabricInfo fabric, ushort local_session_id)
    {
        _fabric = &fabric;
        _local_session = local_session_id;
        _state = CaseState.awaiting_sigma1;
    }

    // Consumes Sigma1, emits Sigma2.
    ptrdiff_t on_sigma1(const(ubyte)[] message, ubyte[] output)
    {
        if (_state != CaseState.awaiting_sigma1)
            return fail();

        const(ubyte)[] initiator_random, dest, initiator_eph;
        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
            return fail();
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.is_context(1))
                initiator_random = r.as_bytes;
            else if (r.tag.is_context(2))
            {
                if (!r.get(_peer_session))
                    return fail();
            }
            else if (r.tag.is_context(3))
                dest = r.as_bytes;
            else if (r.tag.is_context(4))
                initiator_eph = r.as_bytes;
            else if (!r.skip())
                return fail();
        }
        if (initiator_random.length != 32 || dest.length != 32 || initiator_eph.length != 65)
            return fail();

        ubyte[32] expected = _fabric.destination_id(initiator_random, _fabric.node_id);
        if (expected != dest)
            return fail();
        _initiator_eph[] = initiator_eph[];

        if (crypto_random_bytes(_random[]).failed || !generate_ephemeral(_eph_private, _eph_public))
            return fail();
        if (!ecdh(_eph_private, initiator_eph, _shared))
            return fail();

        sha_init(_transcript);
        sha_update(_transcript, message);
        ubyte[32] sigma1_hash = hash_of(message);

        ubyte[case_max_message] tbe = void;
        ubyte[64] sig = void;
        if (!sign_tbs(_fabric.operational_private_key[], _fabric.noc, _fabric.icac, _eph_public[], initiator_eph, sig))
            return fail();
        ubyte[16] resumption_id = void;
        if (crypto_random_bytes(resumption_id[]).failed)
            return fail();
        ptrdiff_t tbe_len = encode_tbe(tbe[], _fabric.noc, _fabric.icac, sig[], resumption_id[]);
        if (tbe_len < 0)
            return fail();

        ubyte[16 + 32 + 65 + 32] salt = void;
        salt[0 .. 16] = _fabric.ipk[];
        salt[16 .. 48] = _random[];
        salt[48 .. 113] = _eph_public[];
        salt[113 .. 145] = sigma1_hash[];
        ubyte[16] s2k = void;
        if (!hkdf_sha256(salt[], _shared[], "Sigma2", s2k[]))
            return fail();

        ubyte[case_max_message] enc = void;
        if (tbe_len + matter_tag_length > enc.length)
            return fail();
        if (aes_ccm_encrypt(s2k[], sigma2_nonce, null, tbe[0 .. tbe_len], enc[0 .. tbe_len], enc[tbe_len .. tbe_len + matter_tag_length]).failed)
            return fail();

        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), _random[]);
        w.put(TLVTag.context(2), cast(uint)_local_session);
        w.put(TLVTag.context(3), _eph_public[]);
        w.put(TLVTag.context(4), cast(const(ubyte)[])enc[0 .. tbe_len + matter_tag_length]);
        if (!w.end_container() || w.overflow)
            return fail();

        sha_update(_transcript, w.data);
        _state = CaseState.awaiting_sigma3;
        return w.length;
    }

    // Consumes Sigma3; the caller sends the StatusReport.
    bool on_sigma3(const(ubyte)[] message)
    {
        if (_state != CaseState.awaiting_sigma3)
        {
            fail();
            return false;
        }

        const(ubyte)[] encrypted;
        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
        {
            fail();
            return false;
        }
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.is_context(1))
                encrypted = r.as_bytes;
            else if (!r.skip())
            {
                fail();
                return false;
            }
        }
        if (encrypted.length < matter_tag_length)
        {
            fail();
            return false;
        }

        SHA256Context t = _transcript;
        ubyte[32] transcript_hash = sha_finalise(t);
        ubyte[16 + 32] salt3 = void;
        salt3[0 .. 16] = _fabric.ipk[];
        salt3[16 .. 48] = transcript_hash[];
        ubyte[16] s3k = void;
        if (!hkdf_sha256(salt3[], _shared[], "Sigma3", s3k[]))
        {
            fail();
            return false;
        }

        ubyte[case_max_message] plain = void;
        size_t plain_len = encrypted.length - matter_tag_length;
        if (plain_len > plain.length ||
            aes_ccm_decrypt(s3k[], sigma3_nonce, null, encrypted[0 .. plain_len], encrypted[plain_len .. $], plain[0 .. plain_len]).failed)
        {
            fail();
            return false;
        }

        const(ubyte)[] peer_noc, peer_icac, signature;
        const(ubyte)[] peer_key;
        if (!decode_tbe(plain[0 .. plain_len], peer_noc, peer_icac, signature) ||
            !validate_peer_chain(*_fabric, peer_noc, peer_icac, _peer_node_id, peer_key) ||
            !verify_tbs(peer_key, peer_noc, peer_icac, _initiator_eph[], _eph_public[], signature))
        {
            fail();
            return false;
        }

        sha_update(_transcript, message);
        if (!derive_session_keys(_fabric.ipk, _transcript, _shared, _keys))
        {
            fail();
            return false;
        }
        _state = CaseState.complete;
        return true;
    }

private:
    CaseState _state;
    ushort _local_session;
    ushort _peer_session;
    ulong _peer_node_id;
    const(FabricInfo)* _fabric;
    ubyte[32] _random;
    ubyte[32] _eph_private;
    ubyte[65] _eph_public;
    ubyte[65] _initiator_eph;
    ubyte[32] _shared;
    SHA256Context _transcript;
    SessionKeys _keys;

    ptrdiff_t fail()
    {
        _state = CaseState.failed;
        return -1;
    }
}


private:

immutable ubyte[] sigma2_nonce = cast(immutable ubyte[])"NCASE_Sigma2N";
immutable ubyte[] sigma3_nonce = cast(immutable ubyte[])"NCASE_Sigma3N";

ubyte[32] hash_of(const(ubyte)[] data)
{
    SHA256Context ctx;
    sha_init(ctx);
    sha_update(ctx, data);
    return sha_finalise(ctx);
}

bool generate_ephemeral(ref ubyte[32] private_key, ref ubyte[65] public_key)
{
    foreach (attempt; 0 .. 8)
    {
        if (crypto_random_bytes(private_key[]).failed)
            return false;
        U256 d = U256.from_bytes(private_key[]);
        if (d.is_zero || !(d < p256_n))
            continue;
        if (ecdsa_p256_public_key(private_key[], public_key[]))
            return true;
    }
    return false;
}

bool ecdh(ref const ubyte[32] private_key, const(ubyte)[] peer_public, ref ubyte[32] shared)
{
    P256Point peer;
    if (!peer.from_bytes(peer_public))
        return false;
    U256 d = U256.from_bytes(private_key[]);
    P256Point p = point_mul(d, peer);
    if (p.infinity)
        return false;
    p.x.to_bytes(shared[]);
    return true;
}

// TBSData: {1: NOC, 2: ICAC?, 3: senderEphPubKey, 4: receiverEphPubKey}
ptrdiff_t encode_tbs(ubyte[] buffer, const(ubyte)[] noc, const(ubyte)[] icac, const(ubyte)[] sender_eph, const(ubyte)[] receiver_eph)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(1), noc);
    if (icac.length)
        w.put(TLVTag.context(2), icac);
    w.put(TLVTag.context(3), sender_eph);
    w.put(TLVTag.context(4), receiver_eph);
    if (!w.end_container() || w.overflow)
        return -1;
    return w.length;
}

bool sign_tbs(const(ubyte)[] private_key, const(ubyte)[] noc, const(ubyte)[] icac, const(ubyte)[] sender_eph, const(ubyte)[] receiver_eph, ref ubyte[64] signature)
{
    ubyte[case_max_message] tbs = void;
    ptrdiff_t len = encode_tbs(tbs[], noc, icac, sender_eph, receiver_eph);
    if (len < 0)
        return false;
    ubyte[32] hash = hash_of(tbs[0 .. len]);
    return ecdsa_p256_sign(private_key, hash[], signature[]);
}

bool verify_tbs(const(ubyte)[] public_key, const(ubyte)[] noc, const(ubyte)[] icac, const(ubyte)[] sender_eph, const(ubyte)[] receiver_eph, const(ubyte)[] signature)
{
    ubyte[case_max_message] tbs = void;
    ptrdiff_t len = encode_tbs(tbs[], noc, icac, sender_eph, receiver_eph);
    if (len < 0)
        return false;
    ubyte[32] hash = hash_of(tbs[0 .. len]);
    return ecdsa_p256_verify(public_key, hash[], signature);
}

// TBEData: {1: NOC, 2: ICAC?, 3: signature, 4: resumptionID?}
ptrdiff_t encode_tbe(ubyte[] buffer, const(ubyte)[] noc, const(ubyte)[] icac, const(ubyte)[] signature, const(ubyte)[] resumption_id)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(1), noc);
    if (icac.length)
        w.put(TLVTag.context(2), icac);
    w.put(TLVTag.context(3), signature);
    if (resumption_id.length)
        w.put(TLVTag.context(4), resumption_id);
    if (!w.end_container() || w.overflow)
        return -1;
    return w.length;
}

bool decode_tbe(const(ubyte)[] data, out const(ubyte)[] noc, out const(ubyte)[] icac, out const(ubyte)[] signature)
{
    TLVReader r = TLVReader(data);
    if (!r.next() || r.type != TLVType.structure)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(1))
            noc = r.as_bytes;
        else if (r.tag.is_context(2))
            icac = r.as_bytes;
        else if (r.tag.is_context(3))
            signature = r.as_bytes;
        else if (!r.skip())
            return false;
    }
    return noc.length != 0 && signature.length == 64;
}

bool derive_session_keys(ref const ubyte[16] ipk, ref const SHA256Context transcript, ref const ubyte[32] shared, ref SessionKeys keys)
{
    SHA256Context t = transcript;
    ubyte[32] transcript_hash = sha_finalise(t);
    ubyte[16 + 32] salt = void;
    salt[0 .. 16] = ipk[];
    salt[16 .. 48] = transcript_hash[];
    ubyte[48] okm = void;
    if (!hkdf_sha256(salt[], shared[], "SessionKeys", okm[]))
        return false;
    keys.i2r[] = okm[0 .. 16];
    keys.r2i[] = okm[16 .. 32];
    keys.attestation_challenge[] = okm[32 .. 48];
    return true;
}


unittest
{
    // Build a fabric: one root, two nodes with NOCs signed by the root, then run CASE between them.
    static immutable ubyte[32] root_priv = 0x11;
    static immutable ubyte[32] a_priv = 0x22;
    static immutable ubyte[32] b_priv = 0x33;
    static immutable ubyte[20] root_kid = 0x5A;
    static immutable ubyte[1] serial = [1];
    static immutable ubyte[16] epoch = 0x77;

    ubyte[65] root_pub, a_pub, b_pub;
    assert(ecdsa_p256_public_key(root_priv[], root_pub[]));
    assert(ecdsa_p256_public_key(a_priv[], a_pub[]));
    assert(ecdsa_p256_public_key(b_priv[], b_pub[]));

    ubyte[512] rcac_buf, a_noc_buf, b_noc_buf;
    size_t rcac_len = make_cert(rcac_buf[], serial[], 0xCAFE, 0, 0, root_pub[], root_kid[], root_kid[], true, root_priv[]);
    size_t a_len = make_cert(a_noc_buf[], serial[], 0xCAFE, 0x2906C908D115D362, 0xAAAA000000000001, a_pub[], root_kid[], root_kid[], false, root_priv[]);
    size_t b_len = make_cert(b_noc_buf[], serial[], 0xCAFE, 0x2906C908D115D362, 0xBBBB000000000002, b_pub[], root_kid[], root_kid[], false, root_priv[]);
    assert(rcac_len && a_len && b_len);

    FabricInfo fa, fb;
    fa.rcac = rcac_buf[0 .. rcac_len];
    fa.noc = a_noc_buf[0 .. a_len];
    fa.operational_private_key = a_priv;
    assert(fa.load_from_certs());
    assert(fa.set_epoch_key(epoch[]));
    fb.rcac = rcac_buf[0 .. rcac_len];
    fb.noc = b_noc_buf[0 .. b_len];
    fb.operational_private_key = b_priv;
    assert(fb.load_from_certs());
    assert(fb.set_epoch_key(epoch[]));
    assert(fa.compressed_id == fb.compressed_id && fa.ipk == fb.ipk);
    assert(fa.node_id == 0xAAAA000000000001 && fb.node_id == 0xBBBB000000000002);

    CaseInitiator a;
    CaseResponder b;
    b.begin(fb, 0x2222);
    ubyte[case_max_message] m1, m2;
    ptrdiff_t l1 = a.begin(fa, fb.node_id, 0x1111, m1[]);
    assert(l1 > 0 && a.state == CaseState.awaiting_sigma2);
    ptrdiff_t l2 = b.on_sigma1(m1[0 .. l1], m2[]);
    assert(l2 > 0 && b.state == CaseState.awaiting_sigma3 && b.peer_session_id == 0x1111);
    l1 = a.on_sigma2(m2[0 .. l2], m1[]);
    assert(l1 > 0 && a.state == CaseState.awaiting_status && a.peer_session_id == 0x2222);
    assert(b.on_sigma3(m1[0 .. l1]));
    assert(b.state == CaseState.complete && b.peer_node_id == fa.node_id);
    assert(a.on_status(true) && a.state == CaseState.complete);
    assert(a.keys.i2r == b.keys.i2r && a.keys.r2i == b.keys.r2i);
    assert(a.keys.attestation_challenge == b.keys.attestation_challenge);

    // a Sigma1 aimed at a different node id is rejected by the responder
    CaseInitiator wrong;
    CaseResponder b2;
    b2.begin(fb, 0x3333);
    l1 = wrong.begin(fa, 0x1234, 0x4444, m1[]);
    assert(l1 > 0);
    assert(b2.on_sigma1(m1[0 .. l1], m2[]) == -1 && b2.state == CaseState.failed);
}

version (unittest)
size_t make_cert(ubyte[] buffer, const(ubyte)[] serial, ulong rcac_id, ulong fabric_id, ulong node_id, const(ubyte)[] pub,
                 const(ubyte)[] skid, const(ubyte)[] akid, bool ca, const(ubyte)[] issuer_priv)
{
    MatterCert c;
    c.serial = serial;
    c.issuer.rcac_id = rcac_id;
    c.issuer.has_rcac_id = true;
    if (ca)
        c.subject = c.issuer;
    else
    {
        c.subject.fabric_id = fabric_id;
        c.subject.has_fabric_id = true;
        c.subject.node_id = node_id;
        c.subject.has_node_id = true;
    }
    c.not_before = 0x28D08480;
    c.not_after = 0;
    c.public_key = pub;
    c.has_basic_constraints = true;
    c.is_ca = ca;
    c.has_key_usage = true;
    c.key_usage = ca ? 0x60 : 0x01;
    if (!ca)
    {
        c.extended_key_usage[0] = 2;
        c.extended_key_usage[1] = 1;
        c.extended_key_usage_count = 2;
    }
    c.subject_key_id = skid;
    c.authority_key_id = akid;
    ubyte[64] sig;
    if (!sign_matter_cert(c, issuer_priv, sig[]))
        return 0;

    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(MatterCertTag.serial), serial);
    w.put(TLVTag.context(MatterCertTag.signature_algorithm), cast(ubyte)1);
    w.start_list(TLVTag.context(MatterCertTag.issuer));
    w.put(TLVTag.context(MatterDnTag.rcac_id), rcac_id);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.not_before), c.not_before);
    w.put(TLVTag.context(MatterCertTag.not_after), c.not_after);
    w.start_list(TLVTag.context(MatterCertTag.subject));
    if (ca)
        w.put(TLVTag.context(MatterDnTag.rcac_id), rcac_id);
    else
    {
        w.put(TLVTag.context(MatterDnTag.fabric_id), fabric_id);
        w.put(TLVTag.context(MatterDnTag.node_id), node_id);
    }
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.public_key_algorithm), cast(ubyte)1);
    w.put(TLVTag.context(MatterCertTag.curve), cast(ubyte)1);
    w.put(TLVTag.context(MatterCertTag.public_key), pub);
    w.start_list(TLVTag.context(MatterCertTag.extensions));
    w.start_structure(TLVTag.context(MatterExtensionTag.basic_constraints));
    w.put(TLVTag.context(1), ca);
    w.end_container();
    w.put(TLVTag.context(MatterExtensionTag.key_usage), cast(ubyte)c.key_usage);
    if (!ca)
    {
        w.start_array(TLVTag.context(MatterExtensionTag.extended_key_usage));
        w.put(TLVTag.anonymous, cast(ubyte)2);
        w.put(TLVTag.anonymous, cast(ubyte)1);
        w.end_container();
    }
    w.put(TLVTag.context(MatterExtensionTag.subject_key_id), skid);
    w.put(TLVTag.context(MatterExtensionTag.authority_key_id), akid);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.signature), cast(const(ubyte)[])sig[]);
    if (!w.end_container() || w.overflow)
        return 0;
    return w.length;
}
