module protocol.matter.pase;

import urt.crypto.p256 : U256;
import urt.crypto.random;
import urt.crypto.spake2p;
import urt.digest.sha;

import protocol.matter.session;
import protocol.matter.tlv;

nothrow @nogc:


enum pase_min_iterations = 1000;
enum pase_max_iterations = 100000;
enum pase_min_salt = 16;
enum pase_max_salt = 32;

struct PbkdfParams
{
    uint iterations;
    ubyte salt_length;
    ubyte[pase_max_salt] salt;

nothrow @nogc:
    const(ubyte)[] salt_bytes() const pure
        => salt[0 .. salt_length];

    bool valid() const pure
        => iterations >= pase_min_iterations && iterations <= pase_max_iterations &&
           salt_length >= pase_min_salt && salt_length <= pase_max_salt;
}

enum PaseState : ubyte
{
    idle,
    awaiting_param_response,
    awaiting_pake1,
    awaiting_pake2,
    awaiting_pake3,
    complete,
    failed,
}


struct PaseInitiator
{
nothrow @nogc:
    PaseState state() const pure
        => _state;

    ushort local_session_id() const pure
        => _local_session;

    ushort peer_session_id() const pure
        => _peer_session;

    ref const(SessionKeys) keys() const pure
        => _keys;

    // Emits PBKDFParamRequest.
    ptrdiff_t begin(uint passcode, ushort local_session_id, ubyte[] output)
    {
        _passcode = passcode;
        _local_session = local_session_id;
        if (crypto_random_bytes(_initiator_random[]).failed)
            return fail();

        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), _initiator_random[]);
        w.put(TLVTag.context(2), cast(uint)local_session_id);
        w.put(TLVTag.context(3), cast(uint)0);
        w.put(TLVTag.context(4), false);
        if (!w.end_container() || w.overflow)
            return fail();

        _hash_start(w.data);
        _state = PaseState.awaiting_param_response;
        return w.length;
    }

    // Consumes PBKDFParamResponse, emits Pake1.
    ptrdiff_t on_param_response(const(ubyte)[] message, ubyte[] output)
    {
        if (_state != PaseState.awaiting_param_response)
            return fail();

        ubyte[32] initiator_random = void, responder_random = void;
        bool have_ir, have_rr, have_session, have_params;
        PbkdfParams params;

        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
            return fail();
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.kind != TLVTagKind.context)
            {
                if (!r.skip())
                    return fail();
                continue;
            }
            switch (r.tag.number)
            {
                case 1:
                    if (r.as_bytes.length != 32)
                        return fail();
                    initiator_random[] = r.as_bytes[];
                    have_ir = true;
                    break;
                case 2:
                    if (r.as_bytes.length != 32)
                        return fail();
                    responder_random[] = r.as_bytes[];
                    have_rr = true;
                    break;
                case 3:
                    if (!r.get(_peer_session))
                        return fail();
                    have_session = true;
                    break;
                case 4:
                    if (!parse_pbkdf_params(r, params))
                        return fail();
                    have_params = true;
                    break;
                default:
                    if (!r.skip())
                        return fail();
                    break;
            }
        }
        if (!have_ir || !have_rr || !have_session || !have_params || initiator_random != _initiator_random)
            return fail();
        if (!params.valid)
            return fail();

        sha_update(_context, message);
        ubyte[32] context = sha_finalise(_context);

        U256 w0, w1;
        if (!spake2p_derive_w0_w1(_passcode, params.salt_bytes, params.iterations, w0, w1))
            return fail();
        if (!_spake.begin_prover(w0, w1, context[]))
            return fail();

        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), _spake.share);
        if (!w.end_container() || w.overflow)
            return fail();
        _state = PaseState.awaiting_pake2;
        return w.length;
    }

    // Consumes Pake2, emits Pake3.
    ptrdiff_t on_pake2(const(ubyte)[] message, ubyte[] output)
    {
        if (_state != PaseState.awaiting_pake2)
            return fail();

        const(ubyte)[] pb, cb;
        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
            return fail();
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.is_context(1))
                pb = r.as_bytes;
            else if (r.tag.is_context(2))
                cb = r.as_bytes;
            else if (!r.skip())
                return fail();
        }
        if (pb.length != spake2p_share_length || cb.length != spake2p_confirm_length)
            return fail();
        if (!_spake.finish(pb) || !_spake.verify(cb))
            return fail();
        if (!_keys.from_pase(_spake.ke[]))
            return fail();

        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), _spake.confirm);
        if (!w.end_container() || w.overflow)
            return fail();
        _state = PaseState.awaiting_pake3;
        return w.length;
    }

    // Called on the StatusReport that acknowledges Pake3.
    bool on_status(bool success)
    {
        if (_state != PaseState.awaiting_pake3 || !success)
        {
            fail();
            return false;
        }
        _state = PaseState.complete;
        return true;
    }

private:
    PaseState _state;
    ushort _local_session;
    ushort _peer_session;
    uint _passcode;
    ubyte[32] _initiator_random;
    SHA256Context _context;
    Spake2p _spake;
    SessionKeys _keys;

    void _hash_start(const(ubyte)[] request)
    {
        sha_init(_context);
        sha_update(_context, "CHIP PAKE V1 Commissioning");
        sha_update(_context, request);
    }

    ptrdiff_t fail()
    {
        _state = PaseState.failed;
        return -1;
    }
}


struct PaseResponder
{
nothrow @nogc:
    PaseState state() const pure
        => _state;

    ushort local_session_id() const pure
        => _local_session;

    ushort peer_session_id() const pure
        => _peer_session;

    ref const(SessionKeys) keys() const pure
        => _keys;

    void begin(ref const Spake2pVerifier verifier, ref const PbkdfParams params, ushort local_session_id)
    {
        _verifier = verifier;
        _params = params;
        _local_session = local_session_id;
        _state = PaseState.awaiting_param_response;
    }

    // Consumes PBKDFParamRequest, emits PBKDFParamResponse.
    ptrdiff_t on_param_request(const(ubyte)[] message, ubyte[] output)
    {
        if (_state != PaseState.awaiting_param_response)
            return fail();

        ubyte[32] initiator_random = void;
        bool have_ir, have_session;
        bool has_params;
        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
            return fail();
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.is_context(1))
            {
                if (r.as_bytes.length != 32)
                    return fail();
                initiator_random[] = r.as_bytes[];
                have_ir = true;
            }
            else if (r.tag.is_context(2))
            {
                if (!r.get(_peer_session))
                    return fail();
                have_session = true;
            }
            else if (r.tag.is_context(3))
            {
                ushort passcode_id;
                if (!r.get(passcode_id) || passcode_id != 0)
                    return fail();
            }
            else if (r.tag.is_context(4))
            {
                if (!r.get(has_params))
                    return fail();
            }
            else if (!r.skip())
                return fail();
        }
        if (!have_ir || !have_session)
            return fail();

        ubyte[32] responder_random = void;
        if (crypto_random_bytes(responder_random[]).failed)
            return fail();

        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), initiator_random[]);
        w.put(TLVTag.context(2), responder_random[]);
        w.put(TLVTag.context(3), cast(uint)_local_session);
        if (!has_params)
        {
            w.start_structure(TLVTag.context(4));
            w.put(TLVTag.context(1), _params.iterations);
            w.put(TLVTag.context(2), _params.salt_bytes);
            w.end_container();
        }
        if (!w.end_container() || w.overflow)
            return fail();

        sha_init(_context);
        sha_update(_context, "CHIP PAKE V1 Commissioning");
        sha_update(_context, message);
        sha_update(_context, w.data);
        _state = PaseState.awaiting_pake1;
        return w.length;
    }

    // Consumes Pake1, emits Pake2.
    ptrdiff_t on_pake1(const(ubyte)[] message, ubyte[] output)
    {
        if (_state != PaseState.awaiting_pake1)
            return fail();

        const(ubyte)[] pa;
        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
            return fail();
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.is_context(1))
                pa = r.as_bytes;
            else if (!r.skip())
                return fail();
        }
        if (pa.length != spake2p_share_length)
            return fail();

        ubyte[32] context = sha_finalise(_context);
        if (!_spake.begin_verifier(_verifier, context[]))
            return fail();
        if (!_spake.finish(pa))
            return fail();

        TLVWriter w = TLVWriter(output);
        w.start_structure();
        w.put(TLVTag.context(1), _spake.share);
        w.put(TLVTag.context(2), _spake.confirm);
        if (!w.end_container() || w.overflow)
            return fail();
        _state = PaseState.awaiting_pake3;
        return w.length;
    }

    // Consumes Pake3; the caller sends a StatusReport with the result.
    bool on_pake3(const(ubyte)[] message)
    {
        if (_state != PaseState.awaiting_pake3)
        {
            fail();
            return false;
        }

        const(ubyte)[] ca;
        TLVReader r = TLVReader(message);
        if (!r.next() || r.type != TLVType.structure)
        {
            fail();
            return false;
        }
        while (r.next() && r.type != TLVType.end_of_container)
        {
            if (r.tag.is_context(1))
                ca = r.as_bytes;
            else if (!r.skip())
            {
                fail();
                return false;
            }
        }
        if (!_spake.verify(ca) || !_keys.from_pase(_spake.ke[]))
        {
            fail();
            return false;
        }
        _state = PaseState.complete;
        return true;
    }

private:
    PaseState _state;
    ushort _local_session;
    ushort _peer_session;
    Spake2pVerifier _verifier;
    PbkdfParams _params;
    SHA256Context _context;
    Spake2p _spake;
    SessionKeys _keys;

    ptrdiff_t fail()
    {
        _state = PaseState.failed;
        return -1;
    }
}


private:

bool parse_pbkdf_params(ref TLVReader r, out PbkdfParams params)
{
    if (r.type != TLVType.structure)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(1))
        {
            if (!r.get(params.iterations))
                return false;
        }
        else if (r.tag.is_context(2))
        {
            const(ubyte)[] salt = r.as_bytes;
            if (!is_bytes(r.type) || salt.length > pase_max_salt)
                return false;
            params.salt[0 .. salt.length] = salt[];
            params.salt_length = cast(ubyte)salt.length;
        }
        else if (!r.skip())
            return false;
    }
    return true;
}


unittest
{
    PbkdfParams params;
    params.iterations = 1000;
    params.salt_length = 16;
    params.salt[0 .. 16] = cast(const(ubyte)[])"SPAKE2P Key Salt";
    assert(params.valid);

    Spake2pVerifier verifier;
    assert(spake2p_derive_verifier(20202021, params.salt_bytes, params.iterations, verifier));

    PaseInitiator client;
    PaseResponder device;
    device.begin(verifier, params, 0x2222);

    ubyte[256] a, b;
    ptrdiff_t alen = client.begin(20202021, 0x1111, a[]);
    assert(alen > 0 && client.state == PaseState.awaiting_param_response);

    ptrdiff_t blen = device.on_param_request(a[0 .. alen], b[]);
    assert(blen > 0 && device.state == PaseState.awaiting_pake1);
    assert(device.peer_session_id == 0x1111);

    alen = client.on_param_response(b[0 .. blen], a[]);
    assert(alen > 0 && client.state == PaseState.awaiting_pake2);
    assert(client.peer_session_id == 0x2222);

    blen = device.on_pake1(a[0 .. alen], b[]);
    assert(blen > 0 && device.state == PaseState.awaiting_pake3);

    alen = client.on_pake2(b[0 .. blen], a[]);
    assert(alen > 0 && client.state == PaseState.awaiting_pake3);

    assert(device.on_pake3(a[0 .. alen]));
    assert(device.state == PaseState.complete);
    assert(client.on_status(true));
    assert(client.state == PaseState.complete);

    assert(client.keys.i2r == device.keys.i2r);
    assert(client.keys.r2i == device.keys.r2i);
    assert(client.keys.attestation_challenge == device.keys.attestation_challenge);

    // wrong passcode is rejected at Pake2
    PaseInitiator bad;
    PaseResponder device2;
    device2.begin(verifier, params, 0x3333);
    alen = bad.begin(12121212, 0x4444, a[]);
    blen = device2.on_param_request(a[0 .. alen], b[]);
    alen = bad.on_param_response(b[0 .. blen], a[]);
    blen = device2.on_pake1(a[0 .. alen], b[]);
    assert(bad.on_pake2(b[0 .. blen], a[]) == -1);
    assert(bad.state == PaseState.failed);
}
