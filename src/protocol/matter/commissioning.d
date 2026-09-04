module protocol.matter.commissioning;

import urt.crypto.random;

import protocol.matter.cert;
import protocol.matter.im;
import protocol.matter.tlv;
import protocol.matter.x509;

nothrow @nogc:


enum root_endpoint = 0;

enum GeneralCommissioningCluster : uint
{
    id = 0x0030,
    arm_fail_safe = 0x00,
    arm_fail_safe_response = 0x01,
    set_regulatory_config = 0x02,
    commissioning_complete = 0x04,
    commissioning_complete_response = 0x05,
}

enum OperationalCredentialsCluster : uint
{
    id = 0x003E,
    attestation_request = 0x00,
    attestation_response = 0x01,
    certificate_chain_request = 0x02,
    certificate_chain_response = 0x03,
    csr_request = 0x04,
    csr_response = 0x05,
    add_noc = 0x06,
    update_noc = 0x07,
    noc_response = 0x08,
    update_fabric_label = 0x09,
    remove_fabric = 0x0A,
    add_trusted_root_certificate = 0x0B,
}

enum NocStatus : ubyte
{
    ok = 0,
    invalid_public_key = 1,
    invalid_node_op_id = 2,
    invalid_noc = 3,
    missing_csr = 4,
    table_full = 5,
    invalid_admin_subject = 6,
    fabric_conflict = 9,
    label_conflict = 10,
    invalid_fabric_index = 11,
}


ptrdiff_t encode_arm_fail_safe(ubyte[] buffer, ushort expiry_seconds, ulong breadcrumb = 0)
{
    CommandPath path = CommandPath(root_endpoint, GeneralCommissioningCluster.id, GeneralCommissioningCluster.arm_fail_safe);
    return encode_invoke_request(buffer, path, (ref TLVWriter w) {
        w.put(TLVTag.context(0), expiry_seconds);
        w.put(TLVTag.context(1), breadcrumb);
        return true;
    });
}

ptrdiff_t encode_commissioning_complete(ubyte[] buffer)
{
    CommandPath path = CommandPath(root_endpoint, GeneralCommissioningCluster.id, GeneralCommissioningCluster.commissioning_complete);
    return encode_invoke_request(buffer, path, null);
}

ptrdiff_t encode_csr_request(ubyte[] buffer, ref const ubyte[32] nonce, bool for_update = false)
{
    CommandPath path = CommandPath(root_endpoint, OperationalCredentialsCluster.id, OperationalCredentialsCluster.csr_request);
    return encode_invoke_request(buffer, path, (ref TLVWriter w) {
        w.put(TLVTag.context(0), nonce[]);
        w.put(TLVTag.context(1), for_update);
        return true;
    });
}

ptrdiff_t encode_add_trusted_root(ubyte[] buffer, const(ubyte)[] rcac)
{
    CommandPath path = CommandPath(root_endpoint, OperationalCredentialsCluster.id, OperationalCredentialsCluster.add_trusted_root_certificate);
    return encode_invoke_request(buffer, path, (ref TLVWriter w) {
        w.put(TLVTag.context(0), rcac);
        return true;
    });
}

ptrdiff_t encode_add_noc(ubyte[] buffer, const(ubyte)[] noc, const(ubyte)[] icac, const(ubyte)[] ipk_epoch_key, ulong admin_node_id, ushort admin_vendor_id)
{
    CommandPath path = CommandPath(root_endpoint, OperationalCredentialsCluster.id, OperationalCredentialsCluster.add_noc);
    return encode_invoke_request(buffer, path, (ref TLVWriter w) {
        w.put(TLVTag.context(0), noc);
        if (icac.length)
            w.put(TLVTag.context(1), icac);
        w.put(TLVTag.context(2), ipk_epoch_key);
        w.put(TLVTag.context(3), admin_node_id);
        w.put(TLVTag.context(4), admin_vendor_id);
        return true;
    });
}

// ArmFailSafeResponse / CommissioningCompleteResponse: {0: errorCode, 1: debugText}
bool decode_commissioning_error(ref TLVReader fields, out ubyte error_code)
{
    if (fields.type != TLVType.structure)
        return false;
    bool found;
    while (fields.next() && fields.type != TLVType.end_of_container)
    {
        if (fields.tag.is_context(0))
        {
            if (!fields.get(error_code))
                return false;
            found = true;
        }
        else if (!fields.skip())
            return false;
    }
    return found;
}

// CSRResponse: {0: NOCSRElements, 1: attestationSignature}. NOCSRElements is TLV {1: csr, 2: CSRNonce, ...}.
bool decode_csr_response(ref TLVReader fields, out const(ubyte)[] csr, out const(ubyte)[] csr_nonce, out const(ubyte)[] attestation_signature)
{
    if (fields.type != TLVType.structure)
        return false;
    const(ubyte)[] elements;
    while (fields.next() && fields.type != TLVType.end_of_container)
    {
        if (fields.tag.is_context(0))
            elements = fields.as_bytes;
        else if (fields.tag.is_context(1))
            attestation_signature = fields.as_bytes;
        else if (!fields.skip())
            return false;
    }
    if (!elements.length)
        return false;

    TLVReader r = TLVReader(elements);
    if (!r.next() || r.type != TLVType.structure)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(1))
            csr = r.as_bytes;
        else if (r.tag.is_context(2))
            csr_nonce = r.as_bytes;
        else if (!r.skip())
            return false;
    }
    return csr.length != 0 && csr_nonce.length == 32;
}

// NOCResponse: {0: statusCode, 1: fabricIndex, 2: debugText}
bool decode_noc_response(ref TLVReader fields, out NocStatus status, out ubyte fabric_index)
{
    if (fields.type != TLVType.structure)
        return false;
    bool found;
    while (fields.next() && fields.type != TLVType.end_of_container)
    {
        if (fields.tag.is_context(0))
        {
            ubyte s;
            if (!fields.get(s))
                return false;
            status = cast(NocStatus)s;
            found = true;
        }
        else if (fields.tag.is_context(1))
        {
            if (!fields.get(fabric_index))
                return false;
        }
        else if (!fields.skip())
            return false;
    }
    return found;
}

// Pulls the P-256 public key out of a PKCS#10 CSR without validating its self-signature.
bool csr_public_key(const(ubyte)[] csr, out const(ubyte)[] public_key)
{
    const(ubyte)[] request;
    if (!der_enter(csr, 0x30, request))
        return false;
    const(ubyte)[] info;
    if (!der_enter(request, 0x30, info))
        return false;
    const(ubyte)[] element;
    if (!der_take(info, 0x02, element) || !der_take(info, 0x30, element))
        return false;
    const(ubyte)[] spki;
    if (!der_enter(info, 0x30, spki))
        return false;
    if (!der_take(spki, 0x30, element))
        return false;
    const(ubyte)[] bits;
    if (!der_take(spki, 0x03, bits))
        return false;
    if (bits.length != 66 || bits[0] != 0 || bits[1] != 0x04)
        return false;
    public_key = bits[1 .. 66];
    return true;
}


// Issues a NOC for a commissionee from the CSR public key, signed by the fabric root.
struct NocIssuer
{
    ulong fabric_id;
    ulong rcac_id;
    const(ubyte)[] root_private_key;
    const(ubyte)[] root_subject_key_id;

nothrow @nogc:
    ptrdiff_t issue(ulong node_id, const(ubyte)[] public_key, uint not_before, uint not_after, ubyte[] buffer)
    {
        MatterCert cert;
        ubyte[8] serial = void;
        if (crypto_random_bytes(serial[]).failed)
            return -1;
        serial[0] &= 0x7F;
        cert.serial = serial[];
        cert.issuer.rcac_id = rcac_id;
        cert.issuer.has_rcac_id = true;
        cert.subject.fabric_id = fabric_id;
        cert.subject.has_fabric_id = true;
        cert.subject.node_id = node_id;
        cert.subject.has_node_id = true;
        cert.not_before = not_before;
        cert.not_after = not_after;
        cert.public_key = public_key;
        cert.has_basic_constraints = true;
        cert.is_ca = false;
        cert.has_key_usage = true;
        cert.key_usage = 0x01;
        cert.extended_key_usage[0] = 2;
        cert.extended_key_usage[1] = 1;
        cert.extended_key_usage_count = 2;
        ubyte[20] skid = void;
        subject_key_id(public_key, skid);
        cert.subject_key_id = skid[];
        cert.authority_key_id = root_subject_key_id;

        ubyte[64] sig = void;
        if (!sign_matter_cert(cert, root_private_key, sig[]))
            return -1;
        cert.signature = sig[];
        return encode_matter_cert(cert, buffer);
    }

    // A self-signed root for a new fabric.
    ptrdiff_t issue_root(const(ubyte)[] root_public_key, uint not_before, ubyte[] buffer)
    {
        MatterCert cert;
        ubyte[8] serial = void;
        if (crypto_random_bytes(serial[]).failed)
            return -1;
        serial[0] &= 0x7F;
        cert.serial = serial[];
        cert.issuer.rcac_id = rcac_id;
        cert.issuer.has_rcac_id = true;
        cert.subject = cert.issuer;
        cert.not_before = not_before;
        cert.not_after = 0;
        cert.public_key = root_public_key;
        cert.has_basic_constraints = true;
        cert.is_ca = true;
        cert.has_key_usage = true;
        cert.key_usage = 0x60;
        ubyte[20] skid = void;
        subject_key_id(root_public_key, skid);
        cert.subject_key_id = skid[];
        cert.authority_key_id = skid[];

        ubyte[64] sig = void;
        if (!sign_matter_cert(cert, root_private_key, sig[]))
            return -1;
        cert.signature = sig[];
        return encode_matter_cert(cert, buffer);
    }
}

// RFC 7093 method 1 truncated as Matter does: the leading 20 bytes of SHA-1 over the public key.
void subject_key_id(const(ubyte)[] public_key, ref ubyte[20] output)
{
    import urt.digest.sha : SHA1Context, sha_init, sha_update, sha_finalise;
    SHA1Context ctx;
    sha_init(ctx);
    sha_update(ctx, public_key);
    output = sha_finalise(ctx);
}


private:

bool der_enter(ref const(ubyte)[] data, ubyte tag, out const(ubyte)[] content)
{
    size_t len, header;
    if (!der_read_header(data, tag, len, header))
        return false;
    content = data[header .. header + len];
    data = data[header + len .. $];
    return true;
}

bool der_take(ref const(ubyte)[] data, ubyte tag, out const(ubyte)[] content)
    => der_enter(data, tag, content);

bool der_read_header(const(ubyte)[] data, ubyte tag, out size_t len, out size_t header)
{
    if (data.length < 2 || data[0] != tag)
        return false;
    ubyte first = data[1];
    if (first < 0x80)
    {
        len = first;
        header = 2;
    }
    else
    {
        size_t n = first & 0x7F;
        if (n == 0 || n > 4 || data.length < 2 + n)
            return false;
        foreach (i; 0 .. n)
            len = (len << 8) | data[2 + i];
        header = 2 + n;
    }
    return header + len <= data.length;
}


unittest
{
    import urt.crypto.ecdsa;
    import protocol.matter.fabric;

    ubyte[256] buf;
    ptrdiff_t len = encode_arm_fail_safe(buf[], 60, 1);
    assert(len > 0);
    len = encode_commissioning_complete(buf[]);
    assert(len > 0);
    ubyte[32] nonce = 0x5C;
    len = encode_csr_request(buf[], nonce);
    assert(len > 0);

    // a CSRResponse carrying a hand-built PKCS#10 with a known key
    static immutable ubyte[32] node_priv = 0x42;
    ubyte[65] node_pub;
    assert(ecdsa_p256_public_key(node_priv[], node_pub[]));
    ubyte[256] csr;
    size_t csr_len = fake_csr(csr[], node_pub[]);
    const(ubyte)[] key;
    assert(csr_public_key(csr[0 .. csr_len], key));
    assert(key == node_pub[]);
    assert(!csr_public_key(csr[0 .. csr_len - 1], key));

    ubyte[512] elements;
    TLVWriter ew = TLVWriter(elements[]);
    ew.start_structure();
    ew.put(TLVTag.context(1), cast(const(ubyte)[])csr[0 .. csr_len]);
    ew.put(TLVTag.context(2), nonce[]);
    assert(ew.end_container());
    ubyte[1024] rsp;
    TLVWriter rw = TLVWriter(rsp[]);
    rw.start_structure();
    rw.put(TLVTag.context(0), cast(const(ubyte)[])ew.data);
    rw.put(TLVTag.context(1), cast(const(ubyte)[])nonce[]);
    assert(rw.end_container());
    TLVReader fields = TLVReader(rw.data);
    assert(fields.next());
    const(ubyte)[] got_csr, got_nonce, got_sig;
    assert(decode_csr_response(fields, got_csr, got_nonce, got_sig));
    assert(got_csr == csr[0 .. csr_len] && got_nonce == nonce[] && got_sig.length == 32);

    // issue a root and a NOC, then the NOC must validate against the root through FabricInfo
    static immutable ubyte[32] root_priv = 0x11;
    ubyte[65] root_pub;
    assert(ecdsa_p256_public_key(root_priv[], root_pub[]));
    ubyte[20] root_kid;
    subject_key_id(root_pub[], root_kid);
    NocIssuer issuer = NocIssuer(0x2906C908D115D362, 0xCACACACA00000001, root_priv[], root_kid[]);
    ubyte[512] rcac_buf, noc_buf;
    ptrdiff_t rcac_len = issuer.issue_root(root_pub[], 0x28D08480, rcac_buf[]);
    ptrdiff_t noc_len = issuer.issue(0xDEDEDEDE00010001, node_pub[], 0x28D08480, 0, noc_buf[]);
    assert(rcac_len > 0 && noc_len > 0);

    MatterCert rcac, noc;
    assert(decode_matter_cert(rcac_buf[0 .. rcac_len], rcac) && rcac.type == MatterCertType.rcac);
    assert(decode_matter_cert(noc_buf[0 .. noc_len], noc) && noc.type == MatterCertType.noc);
    assert(issued_by(noc, rcac));
    assert(verify_matter_cert(rcac, root_pub[]));
    assert(verify_matter_cert(noc, root_pub[]));

    FabricInfo f;
    f.rcac = rcac_buf[0 .. rcac_len];
    f.noc = noc_buf[0 .. noc_len];
    assert(f.load_from_certs());
    assert(f.node_id == 0xDEDEDEDE00010001 && f.fabric_id == 0x2906C908D115D362);

    len = encode_add_trusted_root(buf[], f.rcac);
    assert(len > 0);
    ubyte[16] epoch = 0x77;
    len = encode_add_noc(buf[], f.noc, null, epoch[], 0x0000000000000001, 0xFFF1);
    assert(len > 0);

    ubyte[64] nr;
    TLVWriter nw = TLVWriter(nr[]);
    nw.start_structure();
    nw.put(TLVTag.context(0), cast(ubyte)NocStatus.ok);
    nw.put(TLVTag.context(1), cast(ubyte)1);
    assert(nw.end_container());
    TLVReader nf = TLVReader(nw.data);
    assert(nf.next());
    NocStatus status;
    ubyte index;
    assert(decode_noc_response(nf, status, index) && status == NocStatus.ok && index == 1);
}

version (unittest)
size_t fake_csr(ubyte[] buffer, const(ubyte)[] public_key)
{
    import urt.crypto.der;
    ubyte[128] info = void;
    size_t pos = 0;
    pos += der_integer_small(info[pos .. $], 0);
    static immutable ubyte[2] empty_name = [0x30, 0x00];
    info[pos .. pos + 2] = empty_name[];
    pos += 2;
    pos += der_ec_pubkey_info(info[pos .. $], public_key[1 .. 33], public_key[33 .. 65]);
    static immutable ubyte[2] empty_attrs = [0xA0, 0x00];
    info[pos .. pos + 2] = empty_attrs[];
    pos += 2;

    ubyte[160] info_tlv = void;
    ptrdiff_t info_len = der_tlv(info_tlv[], 0x30, info[0 .. pos]);
    ubyte[200] body = void;
    size_t blen = info_len;
    body[0 .. blen] = info_tlv[0 .. info_len];
    blen += der_sig_alg(body[blen .. $]);
    static immutable ubyte[3] empty_sig = [0x03, 0x01, 0x00];
    body[blen .. blen + 3] = empty_sig[];
    blen += 3;
    ptrdiff_t total = der_tlv(buffer, 0x30, body[0 .. blen]);
    return total > 0 ? total : 0;
}
