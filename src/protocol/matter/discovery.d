module protocol.matter.discovery;

import urt.crypto.hkdf;

nothrow @nogc:


enum operational_service = "_matter._tcp";
enum commissionable_service = "_matterc._udp";
enum commissioner_service = "_matterd._udp";
enum matter_port = 5540;

enum CommissioningMode : ubyte
{
    none = 0,
    basic = 1,
    enhanced = 2,
}

struct CommissionableRecord
{
    ushort discriminator;
    ushort vendor_id;
    ushort product_id;
    uint session_idle_interval;
    uint session_active_interval;
    ushort session_active_threshold;
    uint device_type;
    CommissioningMode commissioning_mode;
    ubyte pairing_hint;
    bool tcp;
    bool has_discriminator;
    bool has_vendor;
    bool has_device_type;

nothrow @nogc:
    bool parse_txt(const(ubyte)[] rdata)
    {
        while (rdata.length)
        {
            size_t len = rdata[0];
            rdata = rdata[1 .. $];
            if (len > rdata.length)
                return false;
            const(char)[] entry = cast(const(char)[])rdata[0 .. len];
            rdata = rdata[len .. $];
            const(char)[] key = entry;
            const(char)[] value;
            foreach (i, c; entry)
            {
                if (c == '=')
                {
                    key = entry[0 .. i];
                    value = entry[i + 1 .. $];
                    break;
                }
            }
            apply(key, value);
        }
        return true;
    }

    // Matches the DNS-SD subtype labels _L<long>, _S<short>, _V<vid>, _CM, _T<devtype>.
    bool matches_subtype(const(char)[] label) const pure
    {
        if (label.length < 2 || label[0] != '_')
            return false;
        ulong value;
        switch (label[1])
        {
            case 'L':
                return has_discriminator && parse_decimal(label[2 .. $], value) && value == discriminator;
            case 'S':
                return has_discriminator && parse_decimal(label[2 .. $], value) && value == (discriminator >> 8);
            case 'V':
                return has_vendor && parse_decimal(label[2 .. $], value) && value == vendor_id;
            case 'C':
                return label == "_CM" && commissioning_mode != CommissioningMode.none;
            case 'T':
                return has_device_type && parse_decimal(label[2 .. $], value) && value == device_type;
            default:
                return false;
        }
    }

private:
    void apply(const(char)[] key, const(char)[] value)
    {
        ulong v;
        switch (key)
        {
            case "D":
                if (parse_decimal(value, v) && v <= 0xFFF)
                {
                    discriminator = cast(ushort)v;
                    has_discriminator = true;
                }
                break;
            case "CM":
                if (parse_decimal(value, v) && v <= 2)
                    commissioning_mode = cast(CommissioningMode)v;
                break;
            case "VP":
                size_t plus = value.length;
                foreach (i, c; value)
                {
                    if (c == '+')
                    {
                        plus = i;
                        break;
                    }
                }
                if (parse_decimal(value[0 .. plus], v) && v <= 0xFFFF)
                {
                    vendor_id = cast(ushort)v;
                    has_vendor = true;
                }
                if (plus < value.length && parse_decimal(value[plus + 1 .. $], v) && v <= 0xFFFF)
                    product_id = cast(ushort)v;
                break;
            case "DT":
                if (parse_decimal(value, v) && v <= uint.max)
                {
                    device_type = cast(uint)v;
                    has_device_type = true;
                }
                break;
            case "PH":
                if (parse_decimal(value, v) && v <= 0xFF)
                    pairing_hint = cast(ubyte)v;
                break;
            case "SII":
                if (parse_decimal(value, v) && v <= uint.max)
                    session_idle_interval = cast(uint)v;
                break;
            case "SAI":
                if (parse_decimal(value, v) && v <= uint.max)
                    session_active_interval = cast(uint)v;
                break;
            case "SAT":
                if (parse_decimal(value, v) && v <= 0xFFFF)
                    session_active_threshold = cast(ushort)v;
                break;
            case "T":
                if (parse_decimal(value, v))
                    tcp = (v & 1) != 0;
                break;
            default:
                break;
        }
    }
}


// Spec 4.3.2.5: HKDF-SHA256(salt = fabric id BE, ikm = root public key without the 0x04 prefix, info = "CompressedFabric").
bool compressed_fabric_id(const(ubyte)[] root_public_key, ulong fabric_id, ref ubyte[8] output)
{
    if (root_public_key.length == 65 && root_public_key[0] == 0x04)
        root_public_key = root_public_key[1 .. $];
    if (root_public_key.length != 64)
        return false;
    ubyte[8] salt = void;
    foreach (i; 0 .. 8)
        salt[i] = cast(ubyte)(fabric_id >> (8*(7 - i)));
    return hkdf_sha256(salt[], root_public_key, "CompressedFabric", output[]);
}

ulong compressed_fabric_id_value(ref const ubyte[8] id) pure
{
    ulong r;
    foreach (b; id)
        r = (r << 8) | b;
    return r;
}

// "<compressed fabric id>-<node id>" as 16+1+16 upper-case hex characters.
size_t format_operational_instance(ulong compressed_fabric, ulong node_id, char[] output) pure
{
    if (output.length < 33)
        return 0;
    hex16(compressed_fabric, output[0 .. 16]);
    output[16] = '-';
    hex16(node_id, output[17 .. 33]);
    return 33;
}

bool parse_operational_instance(const(char)[] name, out ulong compressed_fabric, out ulong node_id) pure
{
    if (name.length != 33 || name[16] != '-')
        return false;
    return parse_hex16(name[0 .. 16], compressed_fabric) && parse_hex16(name[17 .. 33], node_id);
}

// Short and long discriminator subtype labels for commissionable browsing.
size_t format_discriminator_subtype(ushort discriminator, bool long_form, char[] output) pure
{
    if (output.length < 6)
        return 0;
    output[0] = '_';
    output[1] = long_form ? 'L' : 'S';
    return 2 + format_decimal(long_form ? discriminator : discriminator >> 8, output[2 .. $]);
}


private:

void hex16(ulong value, char[] output) pure
{
    foreach (i; 0 .. 16)
        output[i] = hex_digit((value >> (4*(15 - i))) & 0xF);
}

char hex_digit(ulong nibble) pure
    => cast(char)(nibble < 10 ? '0' + nibble : 'A' + nibble - 10);

bool parse_hex16(const(char)[] text, out ulong value) pure
{
    if (text.length != 16)
        return false;
    foreach (c; text)
    {
        uint d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'A' && c <= 'F')
            d = c - 'A' + 10;
        else if (c >= 'a' && c <= 'f')
            d = c - 'a' + 10;
        else
            return false;
        value = (value << 4) | d;
    }
    return true;
}

bool parse_decimal(const(char)[] text, out ulong value) pure
{
    if (text.length == 0 || text.length > 20)
        return false;
    foreach (c; text)
    {
        if (c < '0' || c > '9')
            return false;
        value = value * 10 + (c - '0');
    }
    return true;
}

size_t format_decimal(ulong value, char[] output) pure
{
    char[20] tmp = void;
    size_t n = 0;
    do
    {
        tmp[n++] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    if (output.length < n)
        return 0;
    foreach (i; 0 .. n)
        output[i] = tmp[n - 1 - i];
    return n;
}


unittest
{
    // spec 4.3.2.5 worked example
    static immutable ubyte[65] root = [
        0x04, 0x4a, 0x9f, 0x42, 0xb1, 0xca, 0x48, 0x40, 0xd3, 0x72, 0x92, 0xbb, 0xc7, 0xf6, 0xa7, 0xe1,
        0x1e, 0x22, 0x20, 0x0c, 0x97, 0x6f, 0xc9, 0x00, 0xdb, 0xc9, 0x8a, 0x7a, 0x38, 0x3a, 0x64, 0x1c,
        0xb8, 0x25, 0x4a, 0x2e, 0x56, 0xd4, 0xe2, 0x95, 0xa8, 0x47, 0x94, 0x3b, 0x4e, 0x38, 0x97, 0xc4,
        0xa7, 0x73, 0xe9, 0x30, 0x27, 0x7b, 0x4d, 0x9f, 0xbe, 0xde, 0x8a, 0x05, 0x26, 0x86, 0xbf, 0xac,
        0xfa,
    ];
    ubyte[8] cfid;
    assert(compressed_fabric_id(root[], 0x2906C908D115D362, cfid));
    assert(compressed_fabric_id_value(cfid) == 0x87E1B004E235A130);

    char[40] name;
    size_t n = format_operational_instance(0x87E1B004E235A130, 0x8FC7772401CD0696, name[]);
    assert(name[0 .. n] == "87E1B004E235A130-8FC7772401CD0696");
    ulong f, node;
    assert(parse_operational_instance(name[0 .. n], f, node));
    assert(f == 0x87E1B004E235A130 && node == 0x8FC7772401CD0696);
    assert(!parse_operational_instance("87E1B004E235A130_8FC7772401CD0696", f, node));

    static immutable ubyte[] txt = cast(immutable ubyte[])"\x06D=3840\x04CM=1\x0eVP=65521+32768\x08SII=5000\x07SAI=300\x03T=0";
    CommissionableRecord rec;
    assert(rec.parse_txt(txt));
    assert(rec.has_discriminator && rec.discriminator == 3840);
    assert(rec.commissioning_mode == CommissioningMode.basic);
    assert(rec.vendor_id == 0xFFF1 && rec.product_id == 0x8000);
    assert(rec.session_idle_interval == 5000 && rec.session_active_interval == 300 && !rec.tcp);
    assert(rec.matches_subtype("_L3840"));
    assert(rec.matches_subtype("_S15"));
    assert(rec.matches_subtype("_V65521"));
    assert(rec.matches_subtype("_CM"));
    assert(!rec.matches_subtype("_L3841"));
    assert(!rec.matches_subtype("_T1"));

    n = format_discriminator_subtype(3840, true, name[]);
    assert(name[0 .. n] == "_L3840");
    n = format_discriminator_subtype(3840, false, name[]);
    assert(name[0 .. n] == "_S15");

    static immutable ubyte[] bad = [0x05, 'D', '=', '1'];
    assert(!rec.parse_txt(bad));
}
