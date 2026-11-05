module protocol.goodwe.codec;

import manager.sample.codec : Encoding, register_encoding;
import manager.series : DataFormat, SeriesKind, ValueType;
import urt.si.unit : ScaledUnit, Second;

nothrow @nogc:

void register_goodwe_encodings()
{
    register_encoding(Encoding("goodwe-response-time", 2,
        DataFormat(ValueType.f64, SeriesKind.held, ScaledUnit(Second)), &response_time_decode, &response_time_encode));
    register_encoding(Encoding("goodwe-native-power-factor", 2,
        DataFormat(ValueType.f64, SeriesKind.held, ScaledUnit()), &native_pf_decode, &native_pf_encode));
    register_encoding(Encoding("goodwe-modbus-baud", 4,
        DataFormat(ValueType.u32, SeriesKind.held, ScaledUnit()), &modbus_baud_decode, &modbus_baud_encode));
}

private bool modbus_baud_decode(const(void)[] image, void[] record)
{
    if (image.length != 4 || record.length < uint.sizeof)
        return false;
    const(ubyte)[] bytes = cast(const(ubyte)[])image;
    *cast(uint*)record.ptr = uint(bytes[0]) << 24 | uint(bytes[1]) << 16 | uint(bytes[2]) << 8 | bytes[3];
    return true;
}

private bool modbus_baud_encode(const(void)[] record, void[] image)
{
    if (image.length != 4 || record.length < uint.sizeof)
        return false;
    uint value = *cast(const(uint)*)record.ptr;
    if (value != 9600 && value != 19200 && value != 38400 && value != 57600 && value != 115200)
        return false;
    ubyte[] bytes = cast(ubyte[])image;
    foreach (i; 0 .. 4)
        bytes[i] = cast(ubyte)(value >> (24 - i * 8));
    return true;
}

private bool native_pf_decode(const(void)[] image, void[] record)
{
    if (image.length != 2 || record.length < double.sizeof)
        return false;
    const(ubyte)[] bytes = cast(const(ubyte)[])image;
    uint raw = uint(bytes[0]) << 8 | bytes[1];
    *cast(double*)record.ptr = raw >= 80 && raw <= 100 ? raw / 100.0 :
        raw >= 1 && raw <= 20 ? (cast(int)raw - 100) / 100.0 : double.nan;
    return true;
}

private bool native_pf_encode(const(void)[] record, void[] image)
{
    if (image.length != 2 || record.length < double.sizeof)
        return false;
    double value = *cast(const(double)*)record.ptr;
    double magnitude = value < 0 ? -value : value;
    if (!(magnitude >= 0.8 && magnitude <= 1) || (value < 0 && magnitude > 0.99))
        return false;
    uint hundredths = cast(uint)(magnitude * 100 + 0.5);
    if (magnitude * 100 - hundredths > 0.000001 || hundredths - magnitude * 100 > 0.000001)
        return false;
    uint raw = value < 0 ? 100 - hundredths : hundredths;
    ubyte[] bytes = cast(ubyte[])image;
    bytes[0] = cast(ubyte)(raw >> 8);
    bytes[1] = cast(ubyte)raw;
    return true;
}

unittest
{
    align(8) double value;
    ubyte[2] image;
    ubyte[2] encoded;
    foreach (raw; 0 .. 101)
    {
        image[0] = 0;
        image[1] = cast(ubyte)raw;
        assert(native_pf_decode(image, (cast(void*)&value)[0 .. double.sizeof]));
        bool valid = raw >= 1 && raw <= 20 || raw >= 80;
        assert(native_pf_encode((cast(const(void)*)&value)[0 .. double.sizeof], encoded) == valid);
        if (valid)
            assert(encoded == image);
    }
    value = -0.925;
    assert(!native_pf_encode((cast(const(void)*)&value)[0 .. double.sizeof], encoded));
}

private bool response_time_decode(const(void)[] image, void[] record)
{
    if (image.length != 2 || record.length < double.sizeof)
        return false;
    const(ubyte)[] bytes = cast(const(ubyte)[])image;
    uint coefficient = uint(bytes[0]) << 8 | bytes[1];
    *cast(double*)record.ptr = coefficient && coefficient <= 4096 ? 0.6 * (4096.0 / coefficient - 1) : double.nan;
    return true;
}

private bool response_time_encode(const(void)[] record, void[] image)
{
    if (image.length != 2 || record.length < double.sizeof)
        return false;
    double seconds = *cast(const(double)*)record.ptr;
    if (!(seconds >= 0 && seconds <= 60))
        return false;
    // SolarGo formats the coefficient to two decimals, parses a float, then truncates.
    double scaled = (0.2 / (seconds / 3 + 0.2)) * 409600;
    uint hundredths = cast(uint)scaled;
    if (scaled - hundredths > 0.5 || (scaled - hundredths == 0.5 && (hundredths & 1)))
        ++hundredths;
    uint coefficient = cast(uint)cast(float)(hundredths / 100.0);
    ubyte[] bytes = cast(ubyte[])image;
    bytes[0] = cast(ubyte)(coefficient >> 8);
    bytes[1] = cast(ubyte)coefficient;
    return true;
}

unittest
{
    align(8) double seconds;
    ubyte[2] image = [0x08, 0x00];
    assert(response_time_decode(image, (cast(void*)&seconds)[0 .. double.sizeof]));
    assert(seconds > 0.599999 && seconds < 0.600001);
    ubyte[2] emitted;
    assert(response_time_encode((cast(const(void)*)&seconds)[0 .. double.sizeof], emitted));
    assert(emitted == image);
    seconds = 0.6 * (4096.0 / 1000.999 - 1);
    assert(response_time_encode((cast(const(void)*)&seconds)[0 .. double.sizeof], emitted));
    assert(emitted == [0x03, 0xE9]);
    seconds = 0;
    assert(response_time_encode((cast(const(void)*)&seconds)[0 .. double.sizeof], emitted));
    assert(emitted == [0x10, 0]);
    image = [0, 0];
    assert(response_time_decode(image, (cast(void*)&seconds)[0 .. double.sizeof]));
    assert(seconds != seconds);
    assert(!response_time_encode((cast(const(void)*)&seconds)[0 .. double.sizeof], emitted));
    seconds = 61;
    assert(!response_time_encode((cast(const(void)*)&seconds)[0 .. double.sizeof], emitted));
}
