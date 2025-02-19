module urt.crc;

import urt.meta : intForWidth;
import urt.traits : isUnsignedInt;

nothrow @nogc:


enum Algorithm : ubyte
{
  CRC16_USB,
  CRC16_MODBUS,
  CRC16_KERMIT,
  CRC16_XMODEM,
  CRC16_CCITT_FALSE,
  CRC16_ISO_HDLC,
  CRC16_DNP,
  CRC32_ISO_HDLC,
  CRC32_CASTAGNOLI,

  CRC16_Default_ShortPacket = CRC16_KERMIT, // good default choice for small packets
  CRC32_Default = CRC32_CASTAGNOLI, // has SSE4.2 hardware implementation

  // aliases
  CRC16_BLUETOOTH   = CRC16_KERMIT,
  CRC16_CCITT_TRUE  = CRC16_KERMIT,
  CRC16_CCITT       = CRC16_KERMIT,
  CRC16_EZSP        = CRC16_CCITT_FALSE,
  CRC16_IBM_SDLC    = CRC16_ISO_HDLC,
  CRC32_NVME        = CRC32_CASTAGNOLI,
}

struct CRCParams
{
    ubyte width;
    bool reflect;
    uint poly;
    uint initial;
    uint finalXor;
    uint check;
}

alias CRCTable(Algorithm algo) = CRCTable!(paramTable[algo].width, paramTable[algo].poly, paramTable[algo].reflect);
alias CRCType(Algorithm algo) = intForWidth!(paramTable[algo].width);

// compute a CRC with runtime parameters
T calculateCRC(T = uint)(const void[] data, ref const CRCParams params, ref const T[256] table) pure
    if (isUnsignedInt!T)
{
    assert(params.width <= T.sizeof*8, "T is too small for the CRC width");

    const ubyte[] bytes = cast(ubyte[])data;

    T crc = cast(T)params.initial;

    if (params.reflect)
    {
        foreach (b; bytes)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ b];
    }
    else
    {
        foreach (b; bytes)
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ b]);
    }

    return crc ^ cast(T)params.finalXor;
}

// compute a CRC with hard-coded parameters
T calculateCRC(Algorithm algo, T = CRCType!algo)(const void[] data, T initial = cast(T)paramTable[algo].initial^paramTable[algo].finalXor) pure
    if (isUnsignedInt!T)
{
    enum CRCParams params = paramTable[algo];
    static assert(params.width <= T.sizeof*8, "T is too small for the CRC width");

    alias table = CRCTable!algo;

    const ubyte[] bytes = cast(ubyte[])data;

    static if (params.finalXor)
        T crc = initial ^ params.finalXor;
    else
        T crc = initial;

    foreach (b; bytes)
    {
        static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ b];
        else
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ b]);
    }

    static if (params.finalXor)
        return T(crc ^ params.finalXor);
    else
        return crc;
}

// computes 2 CRC's for 2 points in the data stream...
T calculateCRC_2(Algorithm algo, T = intForWidth!(paramTable[algo].width*2))(const void[] data, uint earlyOffset) pure
    if (isUnsignedInt!T)
{
    enum CRCParams params = paramTable[algo];
    static assert(params.width * 2 <= T.sizeof*8, "T is too small for the CRC width");

    alias table = CRCTable!algo;

    const ubyte[] bytes = cast(ubyte[])data;

    T highCRC = 0;
    T crc = cast(T)params.initial;

    size_t i = 0;
    for (; i < bytes.length; ++i)
    {
        if (i == earlyOffset)
        {
            highCRC = crc;
            goto fast_loop; // skips a redundant loop entry check
        }
        static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ bytes[i]];
        else
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ bytes[i]]);
    }
    goto done; // skip over the fast loop entry check (which will fail)

    for (; i < bytes.length; ++i)
    {
    fast_loop:
        static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ bytes[i]];
        else
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ bytes[i]]);
    }

done:
    static if (params.finalXor)
    {
        crc ^= cast(T)params.finalXor;
        highCRC ^= cast(T)params.finalXor;
    }

    static if (params.width <= 8)
        return ushort(crc | highCRC << 8);
    else static if (params.width <= 16)
        return uint(crc | highCRC << 16);
    else if (params.width <= 32)
        return ulong(crc | highCRC << 32);
}


T[256] generateCRCTable(T)(ref const CRCParams params) pure
    if (isUnsignedInt!T)
{
    enum typeWidth = T.sizeof * 8;
    assert(params.width <= typeWidth && params.width > typeWidth/2, "CRC width must match the size of the type");
    T topBit = cast(T)(1 << (params.width - 1));

    T[256] table = void;

    foreach (T i; 0..256)
    {
        T crc = i;
        if (params.reflect)
            crc = reflect(crc, 8);

        crc <<= (params.width - 8);  // Shift to align with the polynomial width
        foreach (_; 0..8)
        {
            if ((crc & topBit) != 0)
                crc = cast(T)((crc << 1) ^ params.poly);
            else
                crc <<= 1;
        }

        if (params.reflect)
            crc = reflect(crc, params.width);

        table[i] = crc;
    }

    return table;
}


unittest
{
    immutable ubyte[9] checkData = ['1','2','3','4','5','6','7','8','9'];

    assert(calculateCRC!(Algorithm.CRC16_MODBUS)(checkData[]) == paramTable[Algorithm.CRC16_MODBUS].check);
    assert(calculateCRC!(Algorithm.CRC16_EZSP)(checkData[]) == paramTable[Algorithm.CRC16_EZSP].check);
    assert(calculateCRC!(Algorithm.CRC16_KERMIT)(checkData[]) == paramTable[Algorithm.CRC16_KERMIT].check);
    assert(calculateCRC!(Algorithm.CRC16_USB)(checkData[]) == paramTable[Algorithm.CRC16_USB].check);
    assert(calculateCRC!(Algorithm.CRC16_XMODEM)(checkData[]) == paramTable[Algorithm.CRC16_XMODEM].check);
    assert(calculateCRC!(Algorithm.CRC16_ISO_HDLC)(checkData[]) == paramTable[Algorithm.CRC16_ISO_HDLC].check);
    assert(calculateCRC!(Algorithm.CRC16_DNP)(checkData[]) == paramTable[Algorithm.CRC16_DNP].check);
    assert(calculateCRC!(Algorithm.CRC32_ISO_HDLC)(checkData[]) == paramTable[Algorithm.CRC32_ISO_HDLC].check);
    assert(calculateCRC!(Algorithm.CRC32_CASTAGNOLI)(checkData[]) == paramTable[Algorithm.CRC32_CASTAGNOLI].check);

    // check that rolling CRC works...
    ushort crc = calculateCRC!(Algorithm.CRC16_MODBUS)(checkData[0 .. 5]);
    assert(calculateCRC!(Algorithm.CRC16_MODBUS)(checkData[5 .. 9], crc) == paramTable[Algorithm.CRC16_MODBUS].check);
           crc = calculateCRC!(Algorithm.CRC16_ISO_HDLC)(checkData[0 .. 5]);
    assert(calculateCRC!(Algorithm.CRC16_ISO_HDLC)(checkData[5 .. 9], crc) == paramTable[Algorithm.CRC16_ISO_HDLC].check);
    uint crc32 = calculateCRC!(Algorithm.CRC32_ISO_HDLC)(checkData[0 .. 5]);
    assert(calculateCRC!(Algorithm.CRC32_ISO_HDLC)(checkData[5 .. 9], crc32) == paramTable[Algorithm.CRC32_ISO_HDLC].check);
}


private:

enum CRCParams[] paramTable = [
    CRCParams(16, true,  0x8005, 0xFFFF, 0xFFFF, 0xB4C8), // CRC16_USB
    CRCParams(16, true,  0x8005, 0xFFFF, 0x0000, 0x4B37), // CRC16_MODBUS
    CRCParams(16, true,  0x1021, 0x0000, 0x0000, 0x2189), // CRC16_KERMIT
    CRCParams(16, false, 0x1021, 0x0000, 0x0000, 0x31C3), // CRC16_XMODEM
    CRCParams(16, false, 0x1021, 0xFFFF, 0x0000, 0x29B1), // CRC16_CCITT_FALSE
    CRCParams(16, true,  0x1021, 0xFFFF, 0xFFFF, 0x906E), // CRC16_ISO_HDLC
    CRCParams(16, true,  0x3D65, 0x0000, 0xFFFF, 0xEA82), // CRC16_DNP
    CRCParams(32, true,  0x04C11DB7, 0xFFFFFFFF, 0xFFFFFFFF, 0xCBF43926), // CRC32_ISO_HDLC
    CRCParams(32, true,  0x1EDC6F41, 0xFFFFFFFF, 0xFFFFFFFF, 0xE3069283), // CRC32_CASTAGNOLI
];

// helper function to reflect bits (reverse bit order)
T reflect(T)(T value, ubyte bits)
{
    T result = 0;
    foreach (i; 0..bits)
    {
        if (value & (1 << i))
            result |= 1 << (bits - 1 - i);
    }
    return result;
}

// this minimises the number of table instantiations
template CRCTable(uint width, uint poly, bool reflect)
{
    __gshared immutable CRCTable = generateCRCTable!(intForWidth!width)(CRCParams(width, reflect, poly, 0, 0, 0));
}
