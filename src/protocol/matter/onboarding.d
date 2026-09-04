module protocol.matter.onboarding;

nothrow @nogc:


enum DiscoveryCapability : ubyte
{
    soft_ap = 0x01,
    ble = 0x02,
    on_network = 0x04,
}

struct OnboardingPayload
{
    ubyte version_;
    ubyte flow;
    ubyte discovery;
    bool short_discriminator;
    ushort vendor_id;
    ushort product_id;
    ushort discriminator;
    uint passcode;

nothrow @nogc:
    bool matches_discriminator(ushort full) const pure
        => short_discriminator ? (full >> 8) == discriminator : full == discriminator;
}

bool parse_manual_code(const(char)[] code, out OnboardingPayload payload)
{
    ubyte[21] digits = void;
    size_t n = 0;
    foreach (char c; code)
    {
        if (c == '-' || c == ' ')
            continue;
        if (c < '0' || c > '9' || n == digits.length)
            return false;
        digits[n++] = cast(ubyte)(c - '0');
    }
    if (n != 11 && n != 21)
        return false;
    if (!verhoeff_valid(digits[0 .. n]))
        return false;

    ubyte d1 = digits[0];
    if (d1 > 7)
        return false;
    uint chunk2 = decimal(digits[1 .. 6]);
    uint chunk3 = decimal(digits[6 .. 10]);
    if (chunk2 > 0xFFFF || chunk3 > 0x1FFF)
        return false;

    payload.short_discriminator = true;
    payload.discriminator = cast(ushort)(((d1 & 0x3) << 2) | (chunk2 >> 14));
    payload.passcode = (chunk2 & 0x3FFF) | (chunk3 << 14);
    if (!passcode_valid(payload.passcode))
        return false;

    bool vid_pid = (d1 & 0x4) != 0;
    if (vid_pid != (n == 21))
        return false;
    if (vid_pid)
    {
        uint vid = decimal(digits[10 .. 15]);
        uint pid = decimal(digits[15 .. 20]);
        if (vid > 0xFFFF || pid > 0xFFFF)
            return false;
        payload.vendor_id = cast(ushort)vid;
        payload.product_id = cast(ushort)pid;
        payload.flow = 2;
    }
    return true;
}

bool parse_qr_code(const(char)[] code, out OnboardingPayload payload)
{
    if (code.length < 3 || code[0 .. 3] != "MT:")
        return false;
    code = code[3 .. $];

    ubyte[32] bytes = void;
    size_t len = 0;
    while (code.length)
    {
        size_t chunk = code.length >= 5 ? 5 : code.length;
        if (chunk == 3 || chunk == 1)
            return false;
        uint value = 0;
        foreach_reverse (char c; code[0 .. chunk])
        {
            int v = base38_value(c);
            if (v < 0)
                return false;
            value = value * 38 + v;
        }
        size_t out_bytes = chunk == 5 ? 3 : chunk == 4 ? 2 : 1;
        if (len + out_bytes > bytes.length)
            return false;
        foreach (i; 0 .. out_bytes)
            bytes[len + i] = cast(ubyte)(value >> (8*i));
        len += out_bytes;
        code = code[chunk .. $];
    }
    if (len < 11)
        return false;

    BitReader r = BitReader(bytes[0 .. len]);
    payload.version_ = cast(ubyte)r.read(3);
    payload.vendor_id = cast(ushort)r.read(16);
    payload.product_id = cast(ushort)r.read(16);
    payload.flow = cast(ubyte)r.read(2);
    payload.discovery = cast(ubyte)r.read(8);
    payload.discriminator = cast(ushort)r.read(12);
    payload.passcode = r.read(27);
    payload.short_discriminator = false;
    if (payload.version_ != 0 || r.read(4) != 0)
        return false;
    return passcode_valid(payload.passcode);
}

bool passcode_valid(uint passcode) pure
{
    if (passcode == 0 || passcode > 99999998)
        return false;
    switch (passcode)
    {
        case 11111111, 22222222, 33333333, 44444444, 55555555, 66666666, 77777777, 88888888, 12345678, 87654321:
            return false;
        default:
            return true;
    }
}


private:

struct BitReader
{
    const(ubyte)[] data;
    size_t bit;

nothrow @nogc:
    uint read(uint count)
    {
        uint r = 0;
        foreach (i; 0 .. count)
        {
            size_t b = bit + i;
            if (b / 8 < data.length && (data[b / 8] >> (b & 7)) & 1)
                r |= 1u << i;
        }
        bit += count;
        return r;
    }
}

uint decimal(const(ubyte)[] digits) pure
{
    uint r = 0;
    foreach (d; digits)
        r = r * 10 + d;
    return r;
}

int base38_value(char c) pure
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'A' && c <= 'Z')
        return c - 'A' + 10;
    if (c == '-')
        return 36;
    if (c == '.')
        return 37;
    return -1;
}

immutable ubyte[10][10] verhoeff_d = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
    [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
    [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
    [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
    [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
    [6, 5, 9, 8, 7, 1, 0, 4, 3, 2],
    [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
    [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
    [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
];

immutable ubyte[10][8] verhoeff_p = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
    [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
    [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
    [9, 4, 5, 3, 1, 2, 6, 8, 7, 0],
    [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
    [2, 7, 9, 3, 8, 0, 6, 4, 1, 5],
    [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
];

bool verhoeff_valid(const(ubyte)[] digits) pure
{
    ubyte c = 0;
    foreach (i; 0 .. digits.length)
        c = verhoeff_d[c][verhoeff_p[i & 7][digits[digits.length - 1 - i]]];
    return c == 0;
}


unittest
{
    OnboardingPayload p;

    // chip-tool sample device: passcode 20202021, discriminator 3840
    assert(parse_manual_code("34970112332", p));
    assert(p.passcode == 20202021);
    assert(p.short_discriminator && p.discriminator == 15);
    assert(p.matches_discriminator(3840));
    assert(!p.matches_discriminator(0xE00));
    assert(parse_manual_code("3497-011-2332", p));
    assert(!parse_manual_code("34970112331", p));
    assert(!parse_manual_code("3497011233", p));

    assert(parse_qr_code("MT:Y.K9042C00KA0648G00", p));
    assert(p.vendor_id == 0xFFF1);
    assert(p.product_id == 0x8000);
    assert(p.discriminator == 3840);
    assert(p.passcode == 20202021);
    assert(!p.short_discriminator);
    assert(!parse_qr_code("MT:Y.K9042C00KA0648G0", p));
    assert(!parse_qr_code("XX:Y.K9042C00KA0648G00", p));

    assert(!passcode_valid(0));
    assert(!passcode_valid(12345678));
    assert(passcode_valid(20202021));
}
