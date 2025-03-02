module urt.hash;

version = SmallSize;
version = BranchIsFasterThanMod;

nothrow @nogc:


alias fnv1aHash = fnv1Hash!(uint, true);
alias fnv1aHash64 = fnv1Hash!(ulong, true);

T fnv1Hash(T, bool alternate)(const ubyte[] s) pure nothrow @nogc
    if (is(T == ushort) || is(T == uint) || is(T == ulong))
{
    static if (is(T == ushort))
    {
        enum T prime = 0x0101; // 16-bit FNV prime
        T hash = 0x811C; // 16-bit FNV offset basis
    }
    else static if (is(T == uint))
    {
        enum T prime = 0x01000193; // 32-bit FNV prime
        T hash = 0x811C9DC5; // 32-bit FNV offset basis
    }
    else static if (is(T == ulong))
    {
        enum T prime = 0x100000001B3; // 64-bit FNV prime
        T hash = 0XCBF29CE484222325; // 64-bit FNV offset basis
    }

    const ubyte* p = s.ptr;
    for (size_t i = 0; i < s.length; ++i)
    {
        static if (alternate)
        {
            hash ^= p[i];
            hash *= prime;
        }
        else
        {
            hash *= prime;
            hash ^= p[i];
        }
    }
    return hash;
}

unittest
{
    enum hash = fnv1aHash(cast(ubyte[])"hello world");
    static assert(hash == 0xD58B3FA7);
}


uint adler32(const void[] data)
{
    enum A32_BASE = 65521;

    assert(data.length <= int.max, "Data length must be less than or equal to int.max");

    uint s1 = 1;
    uint s2 = 0;

    version (SmallSize)
    {
        foreach (ubyte b; cast(ubyte[])data)
        {
            version (BranchIsFasterThanMod)
            {
                s1 += b;
                s2 += s1;
                if (s1 >= A32_BASE)
                    s1 -= A32_BASE;
                if (s2 >= A32_BASE)
                    s2 -= A32_BASE;
            }
            else
            {
                s1 = (s1 + b) % A32_BASE;
                s2 = (s2 + s1) % A32_BASE;
            }
        }
    }
    else
    {
        enum A32_NMAX = 5552;

        const(ubyte)* buf = cast(const ubyte*)data.ptr;
        int length = cast(int)data.length;

        while (length > 0)
        {
            int k = length < A32_NMAX ? length : A32_NMAX;
            int i;

            for (i = k / 16; i; --i, buf += 16)
            {
                s1 += buf[0];
                s2 += s1;
                s1 += buf[1];
                s2 += s1;
                s1 += buf[2];
                s2 += s1;
                s1 += buf[3];
                s2 += s1;
                s1 += buf[4];
                s2 += s1;
                s1 += buf[5];
                s2 += s1;
                s1 += buf[6];
                s2 += s1;
                s1 += buf[7];
                s2 += s1;

                s1 += buf[8];
                s2 += s1;
                s1 += buf[9];
                s2 += s1;
                s1 += buf[10];
                s2 += s1;
                s1 += buf[11];
                s2 += s1;
                s1 += buf[12];
                s2 += s1;
                s1 += buf[13];
                s2 += s1;
                s1 += buf[14];
                s2 += s1;
                s1 += buf[15];
                s2 += s1;
            }

            for (i = k & 0xF; i; --i)
            {
                s1 += *buf++;
                s2 += s1;
            }

            s1 %= A32_BASE;
            s2 %= A32_BASE;

            length -= k;
        }
    }

    return (s2 << 16) | s1;
}


ushort internet_checksum(const void[] data, ushort initial = 0xFFFF)
{
    auto bytes = cast(const(const ubyte)[])data;

    uint sum = ~initial;
    while (bytes.length > 1)
    {
        sum += (bytes.ptr[0] << 8) | bytes.ptr[1];
        bytes = bytes[2 .. $];
    }
    if (bytes.length > 0)
        sum += bytes.ptr[0] << 8;

    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);

    return cast(ushort)~sum;
}
