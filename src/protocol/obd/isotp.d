module protocol.obd.isotp;

nothrow @nogc:


enum isotp_max_message = 512;

enum IsoTpResult : ubyte
{
    none,           // frame consumed, message incomplete
    complete,       // message reassembled
    need_fc,        // first frame accepted; receiver must send a flow-control frame to the sender
    flow_control,   // frame is a flow-control frame for a transmit in progress
    error,
}

size_t isotp_single(const(ubyte)[] payload, ref ubyte[8] frame)
    in (payload.length <= 7)
{
    frame[0] = cast(ubyte)payload.length;
    frame[1 .. 1 + payload.length] = payload[];
    frame[1 + payload.length .. 8] = 0;
    return 8;
}

size_t isotp_flow_control(ref ubyte[8] frame)
{
    frame[0] = 0x30; // continue-to-send, BS=0 (no limit), STmin=0
    frame[1 .. 8] = 0;
    return 8;
}

struct IsoTpReassembler
{
nothrow @nogc:

    IsoTpResult feed(uint id, const(ubyte)[] frame, out const(ubyte)[] message)
    {
        if (frame.length == 0)
            return IsoTpResult.error;

        ubyte pci = frame[0] >> 4;
        switch (pci)
        {
            case 0: // single frame
                ubyte len = frame[0] & 0xF;
                if (len == 0 || frame.length < 1 + len)
                    return IsoTpResult.error;
                Slot* s = find_slot(id);
                if (s)
                    s.id = 0;
                _single[0 .. len] = frame[1 .. 1 + len];
                message = _single[0 .. len];
                return IsoTpResult.complete;

            case 1: // first frame
                if (frame.length < 8)
                    return IsoTpResult.error;
                ushort len = ((frame[0] & 0xF) << 8) | frame[1];
                if (len <= 7 || len > isotp_max_message)
                    return IsoTpResult.error;
                Slot* s = claim_slot(id);
                s.expected = len;
                s.received = 6;
                s.sn = 1;
                s.buf[0 .. 6] = frame[2 .. 8];
                return IsoTpResult.need_fc;

            case 2: // consecutive frame
                Slot* s = find_slot(id);
                if (s is null)
                    return IsoTpResult.error;
                if ((frame[0] & 0xF) != s.sn)
                {
                    s.id = 0;
                    return IsoTpResult.error;
                }
                s.sn = (s.sn + 1) & 0xF;
                size_t take = s.expected - s.received;
                if (take > frame.length - 1)
                    take = frame.length - 1;
                s.buf[s.received .. s.received + take] = frame[1 .. 1 + take];
                s.received += take;
                if (s.received < s.expected)
                    return IsoTpResult.none;
                s.id = 0;
                message = s.buf[0 .. s.expected];
                return IsoTpResult.complete;

            case 3:
                return IsoTpResult.flow_control;

            default:
                return IsoTpResult.error;
        }
    }

    void reset()
    {
        foreach (ref s; _slots)
            s.id = 0;
    }

private:
    enum num_slots = 4;

    struct Slot
    {
        uint id;
        ushort expected;
        ushort received;
        ubyte sn;
        ubyte age;
        ubyte[isotp_max_message] buf = void;
    }

    Slot[num_slots] _slots;
    ubyte[7] _single = void;

    Slot* find_slot(uint id)
    {
        foreach (ref s; _slots)
        {
            if (s.id == id)
                return &s;
        }
        return null;
    }

    Slot* claim_slot(uint id)
    {
        Slot* victim = &_slots[0];
        foreach (ref s; _slots)
        {
            if (s.id == id)
                return &s;
            if (s.id == 0)
                victim = &s;
            else
            {
                if (s.age < 255)
                    ++s.age;
                if (victim.id != 0 && s.age > victim.age)
                    victim = &s;
            }
        }
        victim.id = id;
        victim.age = 0;
        return victim;
    }
}


// ====================================================================
// Tests
// ====================================================================

unittest
{
    IsoTpReassembler r;
    const(ubyte)[] msg;

    // single frame
    static immutable ubyte[8] sf = [0x03, 0x41, 0x0C, 0x1A, 0, 0, 0, 0];
    assert(r.feed(0x7E8, sf[], msg) == IsoTpResult.complete);
    assert(msg == [0x41, 0x0C, 0x1A]);

    // multi-frame: 20 bytes (VIN-style)
    static immutable ubyte[8] ff = [0x10, 20, 0x49, 0x02, 0x01, 'W', '0', 'L'];
    assert(r.feed(0x7E8, ff[], msg) == IsoTpResult.need_fc);
    static immutable ubyte[8] cf1 = [0x21, '0', '0', '0', '0', '4', '3', 'M'];
    assert(r.feed(0x7E8, cf1[], msg) == IsoTpResult.none);
    static immutable ubyte[8] cf2 = [0x22, 'B', '5', '4', '1', '3', '2', '6'];
    assert(r.feed(0x7E8, cf2[], msg) == IsoTpResult.complete);
    assert(msg.length == 20);
    assert(msg[0 .. 3] == [0x49, 0x02, 0x01]);
    assert(msg[3 .. 20] == cast(const(ubyte)[])"W0L000043MB541326");

    // interleaved conversations on different ids
    static immutable ubyte[8] ff_a = [0x10, 10, 1, 2, 3, 4, 5, 6];
    static immutable ubyte[8] ff_b = [0x10, 9, 11, 12, 13, 14, 15, 16];
    assert(r.feed(0x7E8, ff_a[], msg) == IsoTpResult.need_fc);
    assert(r.feed(0x7E9, ff_b[], msg) == IsoTpResult.need_fc);
    static immutable ubyte[8] cf_b = [0x21, 17, 18, 19, 0, 0, 0, 0];
    assert(r.feed(0x7E9, cf_b[], msg) == IsoTpResult.complete);
    assert(msg == [11, 12, 13, 14, 15, 16, 17, 18, 19]);
    static immutable ubyte[8] cf_a = [0x21, 7, 8, 9, 10, 0, 0, 0];
    assert(r.feed(0x7E8, cf_a[], msg) == IsoTpResult.complete);
    assert(msg == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

    // sequence number mismatch kills the conversation
    assert(r.feed(0x7E8, ff_a[], msg) == IsoTpResult.need_fc);
    static immutable ubyte[8] bad_sn = [0x23, 7, 8, 9, 10, 0, 0, 0];
    assert(r.feed(0x7E8, bad_sn[], msg) == IsoTpResult.error);
    assert(r.feed(0x7E8, cf_a[], msg) == IsoTpResult.error);

    // orphan CF with no conversation
    assert(r.feed(0x7EA, cf_a[], msg) == IsoTpResult.error);

    // flow control frame identified
    static immutable ubyte[8] fc = [0x30, 0, 0, 0, 0, 0, 0, 0];
    assert(r.feed(0x7E0, fc[], msg) == IsoTpResult.flow_control);

    // tx helpers
    ubyte[8] frame = void;
    static immutable ubyte[2] req = [0x01, 0x0C];
    assert(isotp_single(req[], frame) == 8);
    assert(frame[0 .. 3] == [0x02, 0x01, 0x0C] && frame[3 .. 8] == [0, 0, 0, 0, 0]);
    assert(isotp_flow_control(frame) == 8);
    assert(frame[0] == 0x30);
}
