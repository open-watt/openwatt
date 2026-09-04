module protocol.matter.x509;

import urt.crypto.der;
import urt.crypto.ecdsa;
import urt.digest.sha;
import urt.time;

import protocol.matter.cert;

nothrow @nogc:


// Spec 6.5.11: the DER TBSCertificate that a Matter TLV certificate's signature covers.
ptrdiff_t encode_tbs_certificate(ref const MatterCert cert, ubyte[] output)
{
    return wrap(output, 0x30, (ubyte[] b) {
        size_t pos = 0;
        ptrdiff_t n = wrap(b[pos .. $], 0xA0, (ubyte[] v) => der_integer_small(v, 2));
        if (n < 0)
            return n;
        pos += n;
        n = der_integer(b[pos .. $], cert.serial);
        if (n < 0)
            return n;
        pos += n;
        n = der_sig_alg(b[pos .. $]);
        if (n < 0)
            return n;
        pos += n;
        n = encode_name(cert.issuer, b[pos .. $]);
        if (n < 0)
            return n;
        pos += n;
        n = wrap(b[pos .. $], 0x30, (ubyte[] v) {
            ptrdiff_t a = encode_time(cert.not_before, v);
            if (a < 0)
                return a;
            ptrdiff_t c = encode_time(cert.not_after, v[a .. $]);
            return c < 0 ? c : a + c;
        });
        if (n < 0)
            return n;
        pos += n;
        n = encode_name(cert.subject, b[pos .. $]);
        if (n < 0)
            return n;
        pos += n;
        n = der_ec_pubkey_info(b[pos .. $], cert.public_key[1 .. 33], cert.public_key[33 .. 65]);
        if (n < 0)
            return n;
        pos += n;
        n = wrap(b[pos .. $], 0xA3, (ubyte[] v) => encode_extensions(cert, v));
        if (n < 0)
            return n;
        return cast(ptrdiff_t)(pos + n);
    });
}

// Full DER certificate: TBSCertificate, signature algorithm, signature.
ptrdiff_t encode_x509_certificate(ref const MatterCert cert, ubyte[] output)
{
    return wrap(output, 0x30, (ubyte[] b) {
        ptrdiff_t n = encode_tbs_certificate(cert, b);
        if (n < 0)
            return n;
        size_t pos = n;
        n = der_sig_alg(b[pos .. $]);
        if (n < 0)
            return n;
        pos += n;
        n = wrap(b[pos .. $], 0x03, (ubyte[] v) {
            if (v.length < 1)
                return cast(ptrdiff_t)-1;
            v[0] = 0;
            ptrdiff_t s = der_ecdsa_sig(v[1 .. $], cert.signature);
            return s < 0 ? s : s + 1;
        });
        if (n < 0)
            return n;
        return cast(ptrdiff_t)(pos + n);
    });
}

bool verify_matter_cert(ref const MatterCert cert, const(ubyte)[] issuer_public_key)
{
    ubyte[1024] tbs = void;
    ptrdiff_t len = encode_tbs_certificate(cert, tbs[]);
    if (len < 0)
        return false;
    SHA256Context ctx;
    sha_init(ctx);
    sha_update(ctx, tbs[0 .. len]);
    ubyte[32] hash = sha_finalise(ctx);
    return ecdsa_p256_verify(issuer_public_key, hash[], cert.signature);
}

bool sign_matter_cert(ref const MatterCert cert, const(ubyte)[] issuer_private_key, ubyte[] signature)
{
    ubyte[1024] tbs = void;
    ptrdiff_t len = encode_tbs_certificate(cert, tbs[]);
    if (len < 0)
        return false;
    SHA256Context ctx;
    sha_init(ctx);
    sha_update(ctx, tbs[0 .. len]);
    ubyte[32] hash = sha_finalise(ctx);
    return ecdsa_p256_sign(issuer_private_key, hash[], signature);
}


private:

enum matter_epoch_unix = 946684800;

immutable ubyte[3] oid_common_name = [0x55, 0x04, 0x03];
immutable ubyte[10] oid_matter_base = [0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0xA2, 0x7C, 0x01, 0x00];
immutable ubyte[3] oid_basic_constraints = [0x55, 0x1D, 0x13];
immutable ubyte[3] oid_key_usage = [0x55, 0x1D, 0x0F];
immutable ubyte[3] oid_extended_key_usage = [0x55, 0x1D, 0x25];
immutable ubyte[3] oid_subject_key_id = [0x55, 0x1D, 0x0E];
immutable ubyte[3] oid_authority_key_id = [0x55, 0x1D, 0x23];
immutable ubyte[8] oid_kp_base = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x00];
immutable ubyte[6] kp_suffix = [1, 2, 3, 4, 8, 9];

alias Body = ptrdiff_t delegate(ubyte[]) nothrow @nogc;

// Writes body after the largest possible header, then slides it back behind the real one.
ptrdiff_t wrap(ubyte[] output, ubyte tag, scope Body fill)
{
    enum max_header = 4;
    if (output.length < max_header)
        return -1;
    ptrdiff_t len = fill(output[max_header .. $]);
    if (len < 0)
        return len;
    ptrdiff_t header = der_header(output, tag, len);
    if (header < 0)
        return header;
    if (header != max_header)
    {
        foreach (i; 0 .. cast(size_t)len)
            output[header + i] = output[max_header + i];
    }
    return header + len;
}

ptrdiff_t encode_name(ref const MatterDn dn, ubyte[] output)
{
    return wrap(output, 0x30, (ubyte[] b) {
        size_t pos = 0;
        ptrdiff_t n;
        if (dn.common_name.length)
        {
            n = encode_rdn(b[pos .. $], oid_common_name[], cast(const(ubyte)[])dn.common_name);
            if (n < 0)
                return n;
            pos += n;
        }
        static immutable ubyte[4] order = [MatterDnTag.node_id, MatterDnTag.icac_id, MatterDnTag.rcac_id, MatterDnTag.fabric_id];
        foreach (tag; order)
        {
            ulong value;
            bool present;
            switch (tag)
            {
                case MatterDnTag.node_id: value = dn.node_id; present = dn.has_node_id; break;
                case MatterDnTag.icac_id: value = dn.icac_id; present = dn.has_icac_id; break;
                case MatterDnTag.rcac_id: value = dn.rcac_id; present = dn.has_rcac_id; break;
                case MatterDnTag.fabric_id: value = dn.fabric_id; present = dn.has_fabric_id; break;
                default: break;
            }
            if (!present)
                continue;
            char[16] hex = void;
            hex_upper(value, hex[]);
            ubyte[10] oid = oid_matter_base;
            oid[9] = cast(ubyte)(tag - MatterDnTag.node_id + 1);
            n = encode_rdn(b[pos .. $], oid[], cast(const(ubyte)[])hex[]);
            if (n < 0)
                return n;
            pos += n;
        }
        foreach (i; 0 .. dn.noc_cat_count)
        {
            char[16] hex = void;
            hex_upper(dn.noc_cats[i], hex[]);
            ubyte[10] oid = oid_matter_base;
            oid[9] = 6;
            n = encode_rdn(b[pos .. $], oid[], cast(const(ubyte)[])hex[8 .. 16]);
            if (n < 0)
                return n;
            pos += n;
        }
        return cast(ptrdiff_t)pos;
    });
}

ptrdiff_t encode_rdn(ubyte[] output, const(ubyte)[] oid, const(ubyte)[] utf8)
{
    return wrap(output, 0x31, (ubyte[] set) => wrap(set, 0x30, (ubyte[] atv) {
        ptrdiff_t a = der_tlv(atv, 0x06, oid);
        if (a < 0)
            return a;
        ptrdiff_t b = der_tlv(atv[a .. $], 0x0C, utf8);
        return b < 0 ? b : a + b;
    }));
}

ptrdiff_t encode_time(uint matter_seconds, ubyte[] output)
{
    if (matter_seconds == 0)
    {
        static immutable ubyte[] forever = cast(immutable ubyte[])"99991231235959Z";
        return der_tlv(output, 0x18, forever);
    }
    ulong unix = cast(ulong)matter_epoch_unix + matter_seconds;
    DateTime dt = unix_ns_to_datetime(unix * 1_000_000_000);
    if (dt.year < 2050)
        return der_utctime(output, dt);

    ubyte[15] gt = void;
    uint year = cast(uint)dt.year;
    gt[0] = cast(ubyte)('0' + year / 1000 % 10);
    gt[1] = cast(ubyte)('0' + year / 100 % 10);
    gt[2] = cast(ubyte)('0' + year / 10 % 10);
    gt[3] = cast(ubyte)('0' + year % 10);
    ubyte mo = cast(ubyte)dt.month;
    gt[4] = cast(ubyte)('0' + mo / 10);
    gt[5] = cast(ubyte)('0' + mo % 10);
    gt[6] = cast(ubyte)('0' + dt.day / 10);
    gt[7] = cast(ubyte)('0' + dt.day % 10);
    gt[8] = cast(ubyte)('0' + dt.hour / 10);
    gt[9] = cast(ubyte)('0' + dt.hour % 10);
    gt[10] = cast(ubyte)('0' + dt.minute / 10);
    gt[11] = cast(ubyte)('0' + dt.minute % 10);
    gt[12] = cast(ubyte)('0' + dt.second / 10);
    gt[13] = cast(ubyte)('0' + dt.second % 10);
    gt[14] = 'Z';
    return der_tlv(output, 0x18, gt[]);
}

ptrdiff_t encode_extensions(ref const MatterCert cert, ubyte[] output)
{
    return wrap(output, 0x30, (ubyte[] b) {
        size_t pos = 0;
        ptrdiff_t n;
        if (cert.has_basic_constraints)
        {
            n = encode_extension(b[pos .. $], oid_basic_constraints[], true, (ubyte[] v) => wrap(v, 0x30, (ubyte[] s) {
                size_t p = 0;
                if (cert.is_ca)
                {
                    static immutable ubyte[1] yes = [0xFF];
                    ptrdiff_t a = der_tlv(s, 0x01, yes[]);
                    if (a < 0)
                        return a;
                    p += a;
                }
                if (cert.has_path_len)
                {
                    ptrdiff_t a = der_integer_small(s[p .. $], cert.path_len);
                    if (a < 0)
                        return a;
                    p += a;
                }
                return cast(ptrdiff_t)p;
            }));
            if (n < 0)
                return n;
            pos += n;
        }
        if (cert.has_key_usage)
        {
            n = encode_extension(b[pos .. $], oid_key_usage[], true, (ubyte[] v) {
                ubyte[3] bits = void;
                size_t len = key_usage_bits(cert.key_usage, bits);
                return der_tlv(v, 0x03, bits[0 .. len]);
            });
            if (n < 0)
                return n;
            pos += n;
        }
        if (cert.extended_key_usage_count)
        {
            n = encode_extension(b[pos .. $], oid_extended_key_usage[], true, (ubyte[] v) => wrap(v, 0x30, (ubyte[] s) {
                size_t p = 0;
                foreach (i; 0 .. cert.extended_key_usage_count)
                {
                    ubyte[8] oid = oid_kp_base;
                    oid[7] = kp_suffix[cert.extended_key_usage[i] - 1];
                    ptrdiff_t a = der_tlv(s[p .. $], 0x06, oid[]);
                    if (a < 0)
                        return a;
                    p += a;
                }
                return cast(ptrdiff_t)p;
            }));
            if (n < 0)
                return n;
            pos += n;
        }
        if (cert.subject_key_id.length)
        {
            n = encode_extension(b[pos .. $], oid_subject_key_id[], false, (ubyte[] v) => der_tlv(v, 0x04, cert.subject_key_id));
            if (n < 0)
                return n;
            pos += n;
        }
        if (cert.authority_key_id.length)
        {
            n = encode_extension(b[pos .. $], oid_authority_key_id[], false,
                                 (ubyte[] v) => wrap(v, 0x30, (ubyte[] s) => der_tlv(s, 0x80, cert.authority_key_id)));
            if (n < 0)
                return n;
            pos += n;
        }
        return cast(ptrdiff_t)pos;
    });
}

ptrdiff_t encode_extension(ubyte[] output, const(ubyte)[] oid, bool critical, scope Body value)
{
    return wrap(output, 0x30, (ubyte[] b) {
        size_t pos = 0;
        ptrdiff_t n = der_tlv(b, 0x06, oid);
        if (n < 0)
            return n;
        pos += n;
        if (critical)
        {
            static immutable ubyte[1] yes = [0xFF];
            n = der_tlv(b[pos .. $], 0x01, yes[]);
            if (n < 0)
                return n;
            pos += n;
        }
        n = wrap(b[pos .. $], 0x04, value);
        if (n < 0)
            return n;
        return cast(ptrdiff_t)(pos + n);
    });
}

// X.509 KeyUsage BIT STRING: bit i of the Matter bitmap is bit i of the string, MSB first.
size_t key_usage_bits(ushort usage, ref ubyte[3] output)
{
    ubyte b0, b1;
    foreach (i; 0 .. 8)
    {
        if (usage & (1 << i))
            b0 |= 0x80 >> i;
        if (usage & (1 << (i + 8)))
            b1 |= 0x80 >> i;
    }
    size_t bytes = b1 ? 2 : 1;
    ubyte last = b1 ? b1 : b0;
    ubyte unused = 0;
    if (last)
    {
        while (!(last & 1))
        {
            last >>= 1;
            ++unused;
        }
    }
    output[0] = unused;
    output[1] = b0;
    output[2] = b1;
    return 1 + bytes;
}

void hex_upper(ulong value, char[] output)
{
    foreach (i; 0 .. 16)
    {
        uint nibble = (value >> (4*(15 - i))) & 0xF;
        output[i] = cast(char)(nibble < 10 ? '0' + nibble : 'A' + nibble - 10);
    }
}


unittest
{
    import protocol.matter.tlv;

    ubyte[3] ku;
    assert(key_usage_bits(0x0001, ku) == 2 && ku[0 .. 2] == [0x07, 0x80]);
    assert(key_usage_bits(0x0060, ku) == 2 && ku[0 .. 2] == [0x01, 0x06]);
    assert(key_usage_bits(0x0100, ku) == 3 && ku[0 .. 3] == [0x07, 0x00, 0x80]);

    ubyte[64] tbuf;
    assert(encode_time(0, tbuf[]) == 17 && tbuf[0] == 0x18 && tbuf[1] == 15);
    // Matter seconds 0x28D08480 is 2021-09-03T16:00:00Z
    ptrdiff_t tl = encode_time(0x28D08480, tbuf[]);
    assert(tl == 15 && tbuf[0] == 0x17 && tbuf[2 .. 15] == cast(const(ubyte)[])"210903160000Z");

    // self-signed root built from a fixed private key must verify with its own public key
    static immutable ubyte[32] priv = [
        0xC9, 0xAF, 0xA9, 0xD8, 0x45, 0xBA, 0x75, 0x16, 0x6B, 0x5C, 0x21, 0x57, 0x67, 0xB1, 0xD6, 0x93,
        0x4E, 0x50, 0xC3, 0xDB, 0x36, 0xE8, 0x9B, 0x12, 0x7B, 0x8A, 0x62, 0x2B, 0x12, 0x0F, 0x67, 0x21,
    ];
    ubyte[65] pub;
    assert(ecdsa_p256_public_key(priv[], pub[]));
    static immutable ubyte[20] kid = 0x5A;
    static immutable ubyte[1] serial = [0x01];

    MatterCert root;
    root.serial = serial[];
    root.issuer.rcac_id = 0xCACACACA00000001;
    root.issuer.has_rcac_id = true;
    root.subject = root.issuer;
    root.not_before = 0x28D08480;
    root.not_after = 0;
    root.public_key = pub[];
    root.has_basic_constraints = true;
    root.is_ca = true;
    root.has_key_usage = true;
    root.key_usage = 0x60;
    root.subject_key_id = kid[];
    root.authority_key_id = kid[];

    ubyte[64] sig;
    assert(sign_matter_cert(root, priv[], sig[]));
    root.signature = sig[];
    assert(verify_matter_cert(root, pub[]));

    ubyte[1024] der;
    ptrdiff_t len = encode_x509_certificate(root, der[]);
    assert(len > 0 && der[0] == 0x30);

    ptrdiff_t tbs = encode_tbs_certificate(root, der[]);
    assert(tbs > 0 && der[0] == 0x30);
    // version [0] { INTEGER 2 } then serial INTEGER 1
    size_t hdr = der[1] & 0x80 ? 2 + (der[1] & 0x7F) : 2;
    assert(der[hdr .. hdr + 8] == [0xA0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x01, 0x01]);

    root.not_after = 1;
    assert(!verify_matter_cert(root, pub[]));

    // a NOC signed by the root verifies against the root key, not its own
    ubyte[65] noc_pub;
    static immutable ubyte[32] noc_priv = 0x42;
    assert(ecdsa_p256_public_key(noc_priv[], noc_pub[]));
    MatterCert noc;
    noc.serial = serial[];
    noc.issuer = root.issuer;
    noc.subject.fabric_id = 0x2906C908D115D362;
    noc.subject.has_fabric_id = true;
    noc.subject.node_id = 0xDEDEDEDE00010001;
    noc.subject.has_node_id = true;
    noc.subject.noc_cats[0] = 0xABCD0002;
    noc.subject.noc_cat_count = 1;
    noc.not_before = 0x28D08480;
    noc.not_after = 0x3A4D2580;
    noc.public_key = noc_pub[];
    noc.has_basic_constraints = true;
    noc.has_key_usage = true;
    noc.key_usage = 1;
    noc.extended_key_usage[0] = 2;
    noc.extended_key_usage[1] = 1;
    noc.extended_key_usage_count = 2;
    noc.subject_key_id = kid[];
    noc.authority_key_id = kid[];
    ubyte[64] noc_sig;
    assert(sign_matter_cert(noc, priv[], noc_sig[]));
    noc.signature = noc_sig[];
    assert(verify_matter_cert(noc, pub[]));
    assert(!verify_matter_cert(noc, noc_pub[]));
    assert(issued_by(noc, root));
}
