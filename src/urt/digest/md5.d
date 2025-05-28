module urt.digest.md5;

import urt.endian;

nothrow @nogc: // pure


struct MD5Context
{
    ulong size;         // size of input in bytes
    uint[4] buffer;     // current accumulation of hash
    ubyte[64] input;    // input to be used in the next step

    enum uint[4] initState = [ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 ];
}

void md5Init(ref MD5Context ctx)
{
    ctx.size = 0;
    ctx.buffer = MD5Context.initState;
}

void md5Update(ref MD5Context ctx, const void[] input)
{
    size_t offset = ctx.size % 64;
    ctx.size += input.length;

    size_t i = 64 - offset;
    if (input.length < i)
    {
        ctx.input[offset .. offset + input.length] = cast(ubyte[])input[];
        return;
    }

    ctx.input[offset .. 64] = cast(ubyte[])input[0 .. i];

    while (true)
    {
        // The local variable `tmp` our 512-bit chunk separated into 32-bit words
        // we can use in calculations
        uint[16] tmp = void;
        foreach (uint j; 0 .. 16)
            tmp[j] = loadLittleEndian(cast(uint*)ctx.input.ptr + j);
        md5Step(ctx.buffer, tmp);

        size_t tail = input.length - i;
        if (tail < 64)
        {
            ctx.input[0 .. tail] = (cast(ubyte*)input.ptr)[i .. input.length];
            break;
        }
        ctx.input[] = (cast(ubyte*)input.ptr)[i .. i + 64];
        i += 64;
    }
}

ubyte[16] md5Finalise(ref MD5Context ctx)
{
    uint[16] tmp = void;
    uint offset = ctx.size % 64;
    uint padding_length = offset < 56 ? 56 - offset : (56 + 64) - offset;

    // padding used to make the size (in bits) of the input congruent to 448 mod 512
    // TODO: on a large memory system, let's make this a global immutable?
    ubyte[64] PADDING = void;
    PADDING[0] = 0x80;
    PADDING[1 .. padding_length] = 0;

    // Fill in the padding and undo the changes to size that resulted from the update
    md5Update(ctx, PADDING[0 .. padding_length]);
    ctx.size -= cast(ulong)padding_length;

    // Do a final update (internal to this function)
    // Last two 32-bit words are the two halves of the size (converted from bytes to bits)
    foreach (uint j; 0 .. 14)
        tmp[j] = loadLittleEndian(cast(uint*)ctx.input.ptr + j);

    tmp[14] = cast(uint)(ctx.size*8);
    tmp[15] = (ctx.size*8) >> 32;

    md5Step(ctx.buffer, tmp);

    uint[4] digest = void;
    foreach (uint k; 0 .. 4)
        storeLittleEndian(digest.ptr + k, ctx.buffer.ptr[k]);
    return cast(ubyte[16])digest;
}

unittest
{
    import urt.encoding;

    MD5Context ctx;
    md5Init(ctx);
    auto digest = md5Finalise(ctx);
    assert(digest == Hex!"d41d8cd98f00b204e9800998ecf8427e");

    md5Init(ctx);
    md5Update(ctx, "Hello, World!");
    digest = md5Finalise(ctx);
    assert(digest == Hex!"65a8e27d8879283831b664bd8b7f0ad4");
}


private:

__gshared immutable ubyte[] S = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
];

__gshared immutable uint[] K = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
];

// rotates a 32-bit word left by n bits
uint rotateLeft(uint x, uint n)
    => (x << n) | (x >> (32 - n));

// step on 512 bits of input with the main MD5 algorithm
void md5Step(ref uint[4] buffer, ref const uint[16] input)
{
    uint AA = buffer[0];
    uint BB = buffer[1];
    uint CC = buffer[2];
    uint DD = buffer[3];

    uint E;

    uint j;

    foreach (uint i; 0 .. 64)
    {
        final switch(i / 16)
        {
            case 0:
                E = ((BB & CC) | (~BB & DD));   // F(BB, CC, DD); uint F(uint X, uint Y, uint Z) => ((X & Y) | (~X & Z));
                j = i;
                break;
            case 1:
                E = ((BB & DD) | (CC & ~DD));   // G(BB, CC, DD); uint G(uint X, uint Y, uint Z) => ((X & Z) | (Y & ~Z));
                j = ((i*5) + 1) % 16;
                break;
            case 2:
                E = (BB ^ CC ^ DD);             // H(BB, CC, DD); uint H(uint X, uint Y, uint Z) => (X ^ Y ^ Z);
                j = ((i*3) + 5) % 16;
                break;
            case 3:
                E = (CC ^ (BB | ~DD));          // I(BB, CC, DD); uint I(uint X, uint Y, uint Z) => (Y ^ (X | ~Z));
                j = (i*7) % 16;
                break;
        }

        uint temp = DD;
        DD = CC;
        CC = BB;
        BB = BB + rotateLeft(AA + E + K[i] + input[j], S[i]);
        AA = temp;
    }

    buffer[0] += AA;
    buffer[1] += BB;
    buffer[2] += CC;
    buffer[3] += DD;
}
