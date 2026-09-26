module router.iface.sff8472;

nothrow @nogc:

enum ubyte sfp_id_address = 0x50;
enum ubyte sfp_diag_address = 0x51;
enum size_t id_length = 96;
enum ubyte diag_offset = 96;
enum size_t diag_length = 10;

struct ModuleId
{
nothrow @nogc:
    char[16] vendor;
    char[16] part;
    char[4] revision;
    char[16] serial;
    char[8] date;
    ushort wavelength_nm;
    ushort nominal_mbaud;
    ubyte identifier;
    ubyte connector;
    ubyte ethernet;
    bool diagnostics;
    bool external_calibration;

    const(char)[] vendor_name() const return
        => trimmed(vendor[]);

    const(char)[] part_number() const return
        => trimmed(part[]);

    const(char)[] revision_code() const return
        => trimmed(revision[]);

    const(char)[] serial_number() const return
        => trimmed(serial[]);

    const(char)[] standard() const
        => ethernet_standard(ethernet);
}

struct Diagnostics
{
    float temperature_c;
    float supply_v;
    float tx_bias_ma;
    float tx_power_mw;
    float rx_power_mw;
}

bool decode_id(const(ubyte)[] a0, out ModuleId id)
{
    if (a0.length < id_length || checksum(a0[0 .. 63]) != a0[63] || checksum(a0[64 .. 95]) != a0[95])
        return false;
    id.identifier = a0[0];
    id.connector = a0[2];
    id.ethernet = a0[6];
    id.nominal_mbaud = cast(ushort)(a0[12] * 100);
    id.vendor[] = cast(const(char)[])a0[20 .. 36];
    id.part[] = cast(const(char)[])a0[40 .. 56];
    id.revision[] = cast(const(char)[])a0[56 .. 60];
    id.wavelength_nm = cast(ushort)(a0[60] << 8 | a0[61]);
    id.serial[] = cast(const(char)[])a0[68 .. 84];
    id.date[] = cast(const(char)[])a0[84 .. 92];
    id.diagnostics = (a0[92] & diag_implemented) != 0;
    id.external_calibration = (a0[92] & diag_external) != 0;
    return true;
}

// TODO: externally calibrated modules need the A2h 56..95 slopes and offsets applied.
void decode_diagnostics(const(ubyte)[] a2, out Diagnostics d)
{
    assert(a2.length >= diag_length);
    d.temperature_c = cast(short)(a2[0] << 8 | a2[1]) / 256.0f;
    d.supply_v = (a2[2] << 8 | a2[3]) * 100e-6f;
    d.tx_bias_ma = (a2[4] << 8 | a2[5]) * 2e-3f;
    d.tx_power_mw = (a2[6] << 8 | a2[7]) * 1e-4f;
    d.rx_power_mw = (a2[8] << 8 | a2[9]) * 1e-4f;
}

// SFF-8472 byte 6, most capable first.
const(char)[] ethernet_standard(ubyte compliance)
{
    static immutable string[8] names = ["1000BASE-SX", "1000BASE-LX", "1000BASE-CX", "1000BASE-T", "100BASE-LX10", "100BASE-FX", "BASE-BX10", "BASE-PX"];
    foreach (i, name; names)
    {
        if (compliance & (1 << i))
            return name;
    }
    return null;
}


private:

enum ubyte diag_implemented = 1 << 6;
enum ubyte diag_external = 1 << 4;

ubyte checksum(const(ubyte)[] bytes)
{
    uint sum;
    foreach (b; bytes)
        sum += b;
    return cast(ubyte)sum;
}

const(char)[] trimmed(const(char)[] s)
{
    size_t n = s.length;
    while (n && (s[n - 1] == ' ' || s[n - 1] == 0))
        --n;
    return s[0 .. n];
}


unittest
{
    // An OEM SFP-GE35-LD10 (1000BASE-BX10, 1310 nm) as read from a hEX S cage.
    static immutable ubyte[96] a0 = [
        0x03, 0x04, 0x07, 0x00, 0x00, 0x00, 0x40, 0x12, 0x00, 0x01, 0x01, 0x01, 0x0d, 0x00, 0x0a, 0x64,
        0x00, 0x00, 0x00, 0x00, 0x4f, 0x45, 0x4d, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
        0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x53, 0x46, 0x50, 0x2d, 0x47, 0x45, 0x33, 0x35,
        0x2d, 0x4c, 0x44, 0x31, 0x30, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x05, 0x1e, 0x00, 0x8a,
        0x00, 0x1a, 0x00, 0x00, 0x53, 0x31, 0x32, 0x33, 0x35, 0x31, 0x32, 0x31, 0x30, 0x36, 0x34, 0x30,
        0x30, 0x30, 0x36, 0x20, 0x32, 0x31, 0x30, 0x36, 0x32, 0x36, 0x20, 0x20, 0x68, 0x90, 0x01, 0xb6,
    ];
    ModuleId id;
    assert(decode_id(a0[], id));
    assert(id.vendor_name == "OEM" && id.part_number == "SFP-GE35-LD10" && id.serial_number == "S12351210640006");
    assert(id.identifier == 3 && id.connector == 7 && id.wavelength_nm == 1310 && id.nominal_mbaud == 1300);
    assert(id.standard == "BASE-BX10" && id.diagnostics && !id.external_calibration);

    ubyte[96] corrupt = a0;
    corrupt[30] ^= 1;
    assert(!decode_id(corrupt[], id));

    // The same module with its laser on.
    static immutable ubyte[10] a2 = [0x2c, 0xe0, 0x7e, 0x68, 0x24, 0x09, 0x0a, 0xab, 0x00, 0x01];
    Diagnostics d;
    decode_diagnostics(a2[], d);
    assert(d.temperature_c == 44.875f && d.supply_v > 3.2359f && d.supply_v < 3.2361f);
    assert(d.tx_bias_ma > 18.449f && d.tx_bias_ma < 18.451f && d.tx_power_mw > 0.2730f && d.tx_power_mw < 0.2732f);
}
