module urt.hash;

nothrow @nogc:

version = SmallSize;
version = BranchIsFasterThanMod;


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
