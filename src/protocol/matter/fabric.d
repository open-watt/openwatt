module protocol.matter.fabric;

import urt.crypto.hkdf;
import urt.digest.hmac;
import urt.digest.sha;

import protocol.matter.cert;
import protocol.matter.discovery : compressed_fabric_id;

nothrow @nogc:


enum matter_ipk_length = 16;

// One fabric membership: our operational identity and the credentials that prove it.
struct FabricInfo
{
    ulong fabric_id;
    ulong node_id;
    ubyte fabric_index;
    ubyte[8] compressed_id;
    ubyte[65] root_public_key;
    ubyte[matter_ipk_length] ipk;
    ubyte[32] operational_private_key;
    ubyte[65] operational_public_key;
    const(ubyte)[] noc;
    const(ubyte)[] icac;
    const(ubyte)[] rcac;

nothrow @nogc:
    bool valid() const pure
        => fabric_id != 0 && node_id != 0 && noc.length != 0 && root_public_key[0] == 0x04;

    // Spec 4.15.2: IPK is the operational group key derived from the epoch key with the compressed fabric id.
    bool set_epoch_key(const(ubyte)[] epoch_key)
    {
        if (epoch_key.length != matter_ipk_length)
            return false;
        return hkdf_sha256(compressed_id[], epoch_key, "GroupKey v1.0", ipk[]);
    }

    bool derive_compressed_id()
        => compressed_fabric_id(root_public_key[], fabric_id, compressed_id);

    // Spec 4.14.2.3: destination identifier used in Sigma1.
    ubyte[32] destination_id(const(ubyte)[] initiator_random, ulong peer_node_id) const
    {
        HMACContext!SHA256Context h;
        hmac_init(h, ipk[]);
        hmac_update(h, initiator_random);
        hmac_update(h, root_public_key[]);
        ubyte[8] le = void;
        put_le64(fabric_id, le);
        hmac_update(h, le[]);
        put_le64(peer_node_id, le);
        hmac_update(h, le[]);
        return hmac_finalise(h);
    }

    // Loads identity fields from our NOC and root certificate.
    bool load_from_certs()
    {
        MatterCert n, r;
        if (!decode_matter_cert(noc, n) || n.type != MatterCertType.noc)
            return false;
        if (!decode_matter_cert(rcac, r) || r.type != MatterCertType.rcac)
            return false;
        fabric_id = n.subject.fabric_id;
        node_id = n.subject.node_id;
        root_public_key[] = r.public_key[];
        operational_public_key[] = n.public_key[];
        return derive_compressed_id();
    }
}


private:

void put_le64(ulong value, ref ubyte[8] output) pure
{
    foreach (i; 0 .. 8)
        output[i] = cast(ubyte)(value >> (8*i));
}


unittest
{
    FabricInfo f;
    f.fabric_id = 0x2906C908D115D362;
    f.node_id = 0x8FC7772401CD0696;
    static immutable ubyte[65] root_key = [
        0x04, 0x4a, 0x9f, 0x42, 0xb1, 0xca, 0x48, 0x40, 0xd3, 0x72, 0x92, 0xbb, 0xc7, 0xf6, 0xa7, 0xe1,
        0x1e, 0x22, 0x20, 0x0c, 0x97, 0x6f, 0xc9, 0x00, 0xdb, 0xc9, 0x8a, 0x7a, 0x38, 0x3a, 0x64, 0x1c,
        0xb8, 0x25, 0x4a, 0x2e, 0x56, 0xd4, 0xe2, 0x95, 0xa8, 0x47, 0x94, 0x3b, 0x4e, 0x38, 0x97, 0xc4,
        0xa7, 0x73, 0xe9, 0x30, 0x27, 0x7b, 0x4d, 0x9f, 0xbe, 0xde, 0x8a, 0x05, 0x26, 0x86, 0xbf, 0xac,
        0xfa,
    ];
    f.root_public_key = root_key;
    assert(f.derive_compressed_id());
    assert(f.compressed_id[] == [0x87, 0xe1, 0xb0, 0x04, 0xe2, 0x35, 0xa1, 0x30]);

    static immutable ubyte[16] epoch = 0x77;
    assert(f.set_epoch_key(epoch[]));
    assert(f.ipk != ubyte[16].init);

    // spec 4.14.2.3 worked example: IPK and the resulting destination id
    static immutable ubyte[16] ipk = [0x9b, 0xc6, 0x1c, 0xd9, 0xc6, 0x2a, 0x2d, 0xf6, 0xd6, 0x4d, 0xfc, 0xaa, 0x9d, 0xc4, 0x72, 0xd4];
    f.ipk = ipk;

    static immutable ubyte[32] random = [
        0x7e, 0x17, 0x12, 0x31, 0x56, 0x8d, 0xfa, 0x17, 0x20, 0x6b, 0x3a, 0xcc, 0xf8, 0xfa, 0xec, 0x2f,
        0x4d, 0x21, 0xb5, 0x80, 0x11, 0x31, 0x96, 0xf4, 0x7c, 0x7c, 0x4d, 0xeb, 0x81, 0x0a, 0x73, 0xdc,
    ];
    ubyte[32] dest = f.destination_id(random[], 0xCD5544AA7B13EF14);
    assert(dest[] == [
        0xdc, 0x35, 0xdd, 0x5f, 0xc9, 0x13, 0x4c, 0xc5, 0x54, 0x45, 0x38, 0xc9, 0xc3, 0xfc, 0x42, 0x97,
        0xc1, 0xec, 0x33, 0x70, 0xc8, 0x39, 0x13, 0x6a, 0x80, 0xe1, 0x07, 0x96, 0x45, 0x1d, 0x4c, 0x53,
    ]);
}
