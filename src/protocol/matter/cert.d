module protocol.matter.cert;

import protocol.matter.tlv;

nothrow @nogc:


// Matter operational certificates (spec 6.5): a compact TLV encoding of an X.509 certificate.

enum MatterCertTag : ubyte
{
    serial = 1,
    signature_algorithm = 2,
    issuer = 3,
    not_before = 4,
    not_after = 5,
    subject = 6,
    public_key_algorithm = 7,
    curve = 8,
    public_key = 9,
    extensions = 10,
    signature = 11,
}

enum MatterDnTag : ubyte
{
    common_name = 1,
    node_id = 17,
    firmware_signing_id = 18,
    icac_id = 19,
    rcac_id = 20,
    fabric_id = 21,
    noc_cat = 22,
}

enum MatterExtensionTag : ubyte
{
    basic_constraints = 1,
    key_usage = 2,
    extended_key_usage = 3,
    subject_key_id = 4,
    authority_key_id = 5,
    future = 6,
}

enum MatterCertType : ubyte
{
    unknown,
    rcac,
    icac,
    noc,
}

struct MatterDn
{
    ulong node_id;
    ulong fabric_id;
    ulong rcac_id;
    ulong icac_id;
    uint[3] noc_cats;
    ubyte noc_cat_count;
    bool has_node_id;
    bool has_fabric_id;
    bool has_rcac_id;
    bool has_icac_id;
    const(char)[] common_name;
}

struct MatterCert
{
    const(ubyte)[] serial;
    MatterDn issuer;
    MatterDn subject;
    uint not_before;
    uint not_after;
    const(ubyte)[] public_key;
    const(ubyte)[] subject_key_id;
    const(ubyte)[] authority_key_id;
    const(ubyte)[] signature;
    ushort key_usage;
    ubyte[6] extended_key_usage;
    ubyte extended_key_usage_count;
    bool is_ca;
    bool has_basic_constraints;
    bool has_key_usage;
    bool has_path_len;
    ubyte path_len;

nothrow @nogc:
    MatterCertType type() const pure
    {
        if (subject.has_rcac_id)
            return MatterCertType.rcac;
        if (subject.has_icac_id)
            return MatterCertType.icac;
        if (subject.has_node_id && subject.has_fabric_id)
            return MatterCertType.noc;
        return MatterCertType.unknown;
    }

    bool self_signed() const pure
        => subject_key_id.length && authority_key_id.length && subject_key_id == authority_key_id;
}

bool decode_matter_cert(const(ubyte)[] data, out MatterCert cert)
{
    TLVReader r = TLVReader(data);
    if (!r.next() || r.type != TLVType.structure)
        return false;

    bool have_key, have_sig, have_subject, have_issuer;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.kind != TLVTagKind.context)
        {
            if (!r.skip())
                return false;
            continue;
        }
        switch (r.tag.number) with (MatterCertTag)
        {
            case serial:
                if (!is_bytes(r.type))
                    return false;
                cert.serial = r.as_bytes;
                break;
            case signature_algorithm:
                if (!is_unsigned(r.type) || r.as_uint != 1)
                    return false;
                break;
            case issuer:
                if (!decode_dn(r, cert.issuer))
                    return false;
                have_issuer = true;
                break;
            case not_before:
                if (!r.get(cert.not_before))
                    return false;
                break;
            case not_after:
                if (!r.get(cert.not_after))
                    return false;
                break;
            case subject:
                if (!decode_dn(r, cert.subject))
                    return false;
                have_subject = true;
                break;
            case public_key_algorithm:
                if (!is_unsigned(r.type) || r.as_uint != 1)
                    return false;
                break;
            case curve:
                if (!is_unsigned(r.type) || r.as_uint != 1)
                    return false;
                break;
            case public_key:
                if (!is_bytes(r.type) || r.as_bytes.length != 65 || r.as_bytes[0] != 0x04)
                    return false;
                cert.public_key = r.as_bytes;
                have_key = true;
                break;
            case extensions:
                if (!decode_extensions(r, cert))
                    return false;
                break;
            case signature:
                if (!is_bytes(r.type) || r.as_bytes.length != 64)
                    return false;
                cert.signature = r.as_bytes;
                have_sig = true;
                break;
            default:
                if (!r.skip())
                    return false;
                break;
        }
    }
    return r.type == TLVType.end_of_container && have_key && have_sig && have_subject && have_issuer;
}

// Chain rule: a NOC is issued by an ICAC or RCAC, an ICAC by an RCAC, an RCAC by itself.
bool issued_by(ref const MatterCert cert, ref const MatterCert issuer)
{
    if (!issuer.is_ca || issuer.public_key.length != 65)
        return false;
    if (cert.authority_key_id.length && issuer.subject_key_id.length && cert.authority_key_id != issuer.subject_key_id)
        return false;
    final switch (cert.type)
    {
        case MatterCertType.noc:
            if (issuer.type != MatterCertType.icac && issuer.type != MatterCertType.rcac)
                return false;
            break;
        case MatterCertType.icac:
            if (issuer.type != MatterCertType.rcac)
                return false;
            break;
        case MatterCertType.rcac:
            if (issuer.type != MatterCertType.rcac)
                return false;
            break;
        case MatterCertType.unknown:
            return false;
    }
    if (cert.issuer.has_fabric_id && issuer.subject.has_fabric_id && cert.issuer.fabric_id != issuer.subject.fabric_id)
        return false;
    return true;
}


private:

bool decode_dn(ref TLVReader r, out MatterDn dn)
{
    if (r.type != TLVType.list)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.kind != TLVTagKind.context)
        {
            if (!r.skip())
                return false;
            continue;
        }
        switch (r.tag.number) with (MatterDnTag)
        {
            case common_name:
                if (!is_utf8(r.type))
                    return false;
                dn.common_name = r.as_utf8;
                break;
            case node_id:
                if (!r.get(dn.node_id))
                    return false;
                dn.has_node_id = true;
                break;
            case icac_id:
                if (!r.get(dn.icac_id))
                    return false;
                dn.has_icac_id = true;
                break;
            case rcac_id:
                if (!r.get(dn.rcac_id))
                    return false;
                dn.has_rcac_id = true;
                break;
            case fabric_id:
                if (!r.get(dn.fabric_id))
                    return false;
                dn.has_fabric_id = true;
                break;
            case noc_cat:
                uint cat;
                if (!r.get(cat) || dn.noc_cat_count >= dn.noc_cats.length)
                    return false;
                dn.noc_cats[dn.noc_cat_count++] = cat;
                break;
            default:
                if (!r.skip())
                    return false;
                break;
        }
    }
    return r.type == TLVType.end_of_container;
}

bool decode_extensions(ref TLVReader r, ref MatterCert cert)
{
    if (r.type != TLVType.list)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.kind != TLVTagKind.context)
        {
            if (!r.skip())
                return false;
            continue;
        }
        switch (r.tag.number) with (MatterExtensionTag)
        {
            case basic_constraints:
                if (r.type != TLVType.structure)
                    return false;
                cert.has_basic_constraints = true;
                while (r.next() && r.type != TLVType.end_of_container)
                {
                    if (r.tag.is_context(1))
                    {
                        if (!r.get(cert.is_ca))
                            return false;
                    }
                    else if (r.tag.is_context(2))
                    {
                        if (!r.get(cert.path_len))
                            return false;
                        cert.has_path_len = true;
                    }
                    else if (!r.skip())
                        return false;
                }
                break;
            case key_usage:
                if (!r.get(cert.key_usage))
                    return false;
                cert.has_key_usage = true;
                break;
            case extended_key_usage:
                if (r.type != TLVType.array)
                    return false;
                while (r.next() && r.type != TLVType.end_of_container)
                {
                    ubyte purpose;
                    if (!r.get(purpose) || purpose == 0 || purpose > 6 || cert.extended_key_usage_count >= cert.extended_key_usage.length)
                        return false;
                    cert.extended_key_usage[cert.extended_key_usage_count++] = purpose;
                }
                break;
            case subject_key_id:
                if (!is_bytes(r.type) || r.as_bytes.length != 20)
                    return false;
                cert.subject_key_id = r.as_bytes;
                break;
            case authority_key_id:
                if (!is_bytes(r.type) || r.as_bytes.length != 20)
                    return false;
                cert.authority_key_id = r.as_bytes;
                break;
            default:
                if (!r.skip())
                    return false;
                break;
        }
    }
    return r.type == TLVType.end_of_container;
}


unittest
{
    ubyte[512] buf;
    static immutable ubyte[65] key = 0x04;
    static immutable ubyte[64] sig = 0x11;
    static immutable ubyte[20] skid = 0x22;
    static immutable ubyte[20] akid = 0x33;
    static immutable ubyte[8] serial = [1, 2, 3, 4, 5, 6, 7, 8];

    TLVWriter w = TLVWriter(buf[]);
    w.start_structure();
    w.put(TLVTag.context(MatterCertTag.serial), serial[]);
    w.put(TLVTag.context(MatterCertTag.signature_algorithm), cast(ubyte)1);
    w.start_list(TLVTag.context(MatterCertTag.issuer));
    w.put(TLVTag.context(MatterDnTag.rcac_id), 0xCACACACA00000001UL);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.not_before), 0x27812280u);
    w.put(TLVTag.context(MatterCertTag.not_after), 0x3A4D2580u);
    w.start_list(TLVTag.context(MatterCertTag.subject));
    w.put(TLVTag.context(MatterDnTag.fabric_id), 0x2906C908D115D362UL);
    w.put(TLVTag.context(MatterDnTag.node_id), 0xDEDEDEDE00010001UL);
    w.put(TLVTag.context(MatterDnTag.noc_cat), 0xABCD0002u);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.public_key_algorithm), cast(ubyte)1);
    w.put(TLVTag.context(MatterCertTag.curve), cast(ubyte)1);
    w.put(TLVTag.context(MatterCertTag.public_key), key[]);
    w.start_list(TLVTag.context(MatterCertTag.extensions));
    w.start_structure(TLVTag.context(MatterExtensionTag.basic_constraints));
    w.put(TLVTag.context(1), false);
    w.end_container();
    w.put(TLVTag.context(MatterExtensionTag.key_usage), cast(ubyte)1);
    w.start_array(TLVTag.context(MatterExtensionTag.extended_key_usage));
    w.put(TLVTag.anonymous, cast(ubyte)2);
    w.put(TLVTag.anonymous, cast(ubyte)1);
    w.end_container();
    w.put(TLVTag.context(MatterExtensionTag.subject_key_id), skid[]);
    w.put(TLVTag.context(MatterExtensionTag.authority_key_id), akid[]);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.signature), sig[]);
    assert(w.end_container() && !w.overflow);

    MatterCert noc;
    assert(decode_matter_cert(w.data, noc));
    assert(noc.type == MatterCertType.noc);
    assert(noc.subject.fabric_id == 0x2906C908D115D362 && noc.subject.node_id == 0xDEDEDEDE00010001);
    assert(noc.subject.noc_cat_count == 1 && noc.subject.noc_cats[0] == 0xABCD0002);
    assert(noc.issuer.has_rcac_id && noc.issuer.rcac_id == 0xCACACACA00000001);
    assert(!noc.is_ca && noc.has_basic_constraints && noc.has_key_usage && noc.key_usage == 1);
    assert(noc.extended_key_usage_count == 2 && noc.extended_key_usage[0] == 2 && noc.extended_key_usage[1] == 1);
    assert(noc.serial == serial[] && noc.public_key == key[] && noc.signature == sig[]);
    assert(noc.subject_key_id == skid[] && noc.authority_key_id == akid[]);
    assert(!noc.self_signed);

    // a root that could have issued it
    w = TLVWriter(buf[]);
    w.start_structure();
    w.put(TLVTag.context(MatterCertTag.serial), serial[]);
    w.put(TLVTag.context(MatterCertTag.signature_algorithm), cast(ubyte)1);
    w.start_list(TLVTag.context(MatterCertTag.issuer));
    w.put(TLVTag.context(MatterDnTag.rcac_id), 0xCACACACA00000001UL);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.not_before), 1u);
    w.put(TLVTag.context(MatterCertTag.not_after), 2u);
    w.start_list(TLVTag.context(MatterCertTag.subject));
    w.put(TLVTag.context(MatterDnTag.rcac_id), 0xCACACACA00000001UL);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.public_key_algorithm), cast(ubyte)1);
    w.put(TLVTag.context(MatterCertTag.curve), cast(ubyte)1);
    w.put(TLVTag.context(MatterCertTag.public_key), key[]);
    w.start_list(TLVTag.context(MatterCertTag.extensions));
    w.start_structure(TLVTag.context(MatterExtensionTag.basic_constraints));
    w.put(TLVTag.context(1), true);
    w.end_container();
    w.put(TLVTag.context(MatterExtensionTag.subject_key_id), akid[]);
    w.put(TLVTag.context(MatterExtensionTag.authority_key_id), akid[]);
    w.end_container();
    w.put(TLVTag.context(MatterCertTag.signature), sig[]);
    assert(w.end_container());

    MatterCert rcac;
    assert(decode_matter_cert(w.data, rcac));
    assert(rcac.type == MatterCertType.rcac && rcac.is_ca && rcac.self_signed);
    assert(issued_by(noc, rcac));
    assert(issued_by(rcac, rcac));
    assert(!issued_by(rcac, noc));

    // truncated input and a missing signature are rejected
    MatterCert bad;
    assert(!decode_matter_cert(w.data[0 .. $ - 1], bad));
    assert(!decode_matter_cert(w.data[0 .. $ - 67], bad));
}
