module urt.digest.sha;

import urt.endian;

nothrow @nogc: // pure


struct SHA1Context
{
    enum DigestBits = 160;

    enum DigestLen = DigestBits / 8;
    enum DigestElements = DigestBits / 32;

    ubyte[64] data;
    ulong bitlen;
    uint datalen;
    uint[DigestElements] state;

    alias transform = sha1Transform;

    enum uint[DigestElements] initState = [ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 ];

    __gshared immutable uint[4] K = [ 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xca62c1d6 ];
}

struct SHA256Context
{
    enum DigestBits = 256;

    enum DigestLen = DigestBits / 8;
    enum DigestElements = DigestBits / 32;

    ubyte[64] data;
    ulong bitlen;
    uint datalen;
    uint[DigestElements] state;

    alias transform = sha256Transform;

    enum uint[DigestElements] initState = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ];

    __gshared immutable uint[64] K = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
}


void shaInit(Context)(ref Context ctx)
{
    ctx.datalen = 0;
    ctx.bitlen = 0;
    ctx.state = Context.initState;
}

void shaUpdate(Context)(ref Context ctx, const void[] input)
{
    const(ubyte)[] data = cast(ubyte[])input;

    while (data.length > 0)
    {
        if (ctx.datalen + data.length < 64)
        {
            ctx.data[ctx.datalen .. ctx.datalen + data.length] = data[];
            ctx.datalen += cast(uint)data.length;
            break;
        }

        ctx.data[ctx.datalen .. 64] = data[0 .. 64 - ctx.datalen];
        data = data[64 - ctx.datalen .. $];
        ctx.bitlen += 512;
        ctx.datalen = 0;
        Context.transform(ctx, ctx.data);
    }
}

ubyte[Context.DigestLen] shaFinalise(Context)(ref Context ctx)
{
    uint i = ctx.datalen;

    // Pad whatever data is left in the buffer.
    ctx.data[i++] = 0x80;
    if (ctx.datalen > 56)
    {
        ctx.data[i .. 64] = 0x00;
        Context.transform(ctx, ctx.data);
        i = 0;
    }
    ctx.data[i .. 56] = 0x00;

    // Append to the padding the total message's length in bits and transform.
    ctx.bitlen += ctx.datalen * 8;
    ctx.data[56..64] = ctx.bitlen.nativeToBigEndian;
    Context.transform(ctx, ctx.data);

    // Since this implementation uses little endian byte ordering and SHA uses big endian,
    // reverse all the bytes when copying the final state to the output hash.
    uint[Context.DigestElements] digest = void;
    foreach (uint j; 0 .. Context.DigestElements)
        digest[j] = byteReverse(ctx.state[j]);

    return cast(ubyte[Context.DigestLen])digest;
}

unittest
{
    import urt.encoding;

    SHA1Context ctx;
    shaInit(ctx);
    auto digest = shaFinalise(ctx);
    assert(digest == Hex!"da39a3ee5e6b4b0d3255bfef95601890afd80709");

    shaInit(ctx);
    shaUpdate(ctx, "Hello, World!");
    digest = shaFinalise(ctx);
    assert(digest == Hex!"0a0a9f2a6772942557ab5355d76af442f8f65e01");

    SHA256Context ctx2;
    shaInit(ctx2);
    auto digest2 = shaFinalise(ctx2);
    assert(digest2 == Hex!"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    shaInit(ctx2);
    shaUpdate(ctx2, "Hello, World!");
    digest2 = shaFinalise(ctx2);
    assert(digest2 == Hex!"dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f");
}


private:

uint ROTLEFT(uint a, uint b) => (a << b) | (a >> (32 - b));
uint ROTRIGHT(uint a, uint b) => (a >> b) | (a << (32 - b));

void sha1Transform(ref SHA1Context ctx, const ubyte[] data)
{
    uint a, b, c, d, e, i, j, t;
    uint[80] m = void;

    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = (data[j] << 24) + (data[j + 1] << 16) + (data[j + 2] << 8) + (data[j + 3]);
    for (; i < 80; ++i)
    {
        m[i] = (m[i - 3] ^ m[i - 8] ^ m[i - 14] ^ m[i - 16]);
        m[i] = (m[i] << 1) | (m[i] >> 31);
    }

    a = ctx.state[0];
    b = ctx.state[1];
    c = ctx.state[2];
    d = ctx.state[3];
    e = ctx.state[4];

    for (i = 0; i < 20; ++i)
    {
        t = ROTLEFT(a, 5) + ((b & c) ^ (~b & d)) + e + SHA1Context.K[0] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }
    for (; i < 40; ++i)
    {
        t = ROTLEFT(a, 5) + (b ^ c ^ d) + e + SHA1Context.K[1] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }
    for (; i < 60; ++i)
    {
        t = ROTLEFT(a, 5) + ((b & c) ^ (b & d) ^ (c & d))  + e + SHA1Context.K[2] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }
    for (; i < 80; ++i)
    {
        t = ROTLEFT(a, 5) + (b ^ c ^ d) + e + SHA1Context.K[3] + m[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = t;
    }

    ctx.state[0] += a;
    ctx.state[1] += b;
    ctx.state[2] += c;
    ctx.state[3] += d;
    ctx.state[4] += e;
}

void sha256Transform(ref SHA256Context ctx, const ubyte[] data)
{
    static uint CH(uint x, uint y, uint z) => (x & y) ^ (~x & z);
    static uint MAJ(uint x, uint y, uint z) => (x & y) ^ (x & z) ^ (y & z);
    static uint EP0(uint x) => ROTRIGHT(x, 2) ^ ROTRIGHT(x, 13) ^ ROTRIGHT(x, 22);
    static uint EP1(uint x) => ROTRIGHT(x, 6) ^ ROTRIGHT(x, 11) ^ ROTRIGHT(x, 25);
    static uint SIG0(uint x) => ROTRIGHT(x, 7) ^ ROTRIGHT(x, 18) ^ ((x) >> 3);
    static uint SIG1(uint x) => ROTRIGHT(x, 17) ^ ROTRIGHT(x, 19) ^ ((x) >> 10);

    uint a, b, c, d, e, f, g, h, i, j, t1, t2;
    uint[64] m = void;

    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | (data[j + 3]);
    for (; i < 64; ++i)
        m[i] = SIG1(m[i - 2]) + m[i - 7] + SIG0(m[i - 15]) + m[i - 16];

    a = ctx.state[0];
    b = ctx.state[1];
    c = ctx.state[2];
    d = ctx.state[3];
    e = ctx.state[4];
    f = ctx.state[5];
    g = ctx.state[6];
    h = ctx.state[7];

    for (i = 0; i < 64; ++i)
    {
        t1 = h + EP1(e) + CH(e,f,g) + SHA256Context.K[i] + m[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    ctx.state[0] += a;
    ctx.state[1] += b;
    ctx.state[2] += c;
    ctx.state[3] += d;
    ctx.state[4] += e;
    ctx.state[5] += f;
    ctx.state[6] += g;
    ctx.state[7] += h;
}
