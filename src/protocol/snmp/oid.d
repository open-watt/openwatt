module protocol.snmp.oid;

import urt.array;
import urt.conv : format_uint, parse_uint;
import urt.lifetime : move;
import urt.string.format : FormatArg;

import protocol.snmp.asn1;

nothrow @nogc:


struct OID
{
nothrow @nogc:

    Array!uint arcs;

    this(const(uint)[] arcs)
    {
        this.arcs ~= arcs;
    }

    static bool parse(const(char)[] text, out OID oid)
    {
        if (text.length > 0 && text[0] == '.')
            text = text[1 .. $];
        while (text.length > 0)
        {
            size_t consumed;
            ulong v = text.parse_uint(&consumed);
            if (consumed == 0 || v > uint.max)
                return false;
            oid.arcs ~= cast(uint)v;
            text = text[consumed .. $];
            if (text.length == 0)
                break;
            if (text[0] != '.')
                return false;
            text = text[1 .. $];
        }
        return oid.arcs.length >= 2;
    }

    ptrdiff_t toString(char[] buffer, const(char)[], const(FormatArg)[]) const
    {
        size_t offset;
        foreach (i, a; arcs)
        {
            if (i > 0)
            {
                if (offset >= buffer.length)
                    return -1;
                buffer[offset++] = '.';
            }
            ptrdiff_t n = format_uint(a, buffer[offset .. $]);
            if (n < 0)
                return -1;
            offset += n;
        }
        return offset;
    }

    int opCmp(ref const OID rhs) const pure
    {
        size_t n = arcs.length < rhs.arcs.length ? arcs.length : rhs.arcs.length;
        foreach (i; 0 .. n)
        {
            if (arcs[i] < rhs.arcs[i])
                return -1;
            if (arcs[i] > rhs.arcs[i])
                return 1;
        }
        if (arcs.length < rhs.arcs.length)
            return -1;
        if (arcs.length > rhs.arcs.length)
            return 1;
        return 0;
    }

    bool opEquals(ref const OID rhs) const pure
        => opCmp(rhs) == 0;

    size_t toHash() const pure
    {
        size_t h = 0xcbf29ce484222325UL & size_t.max;
        foreach (a; arcs)
        {
            h ^= a;
            h *= 0x100000001b3UL & size_t.max;
        }
        return h;
    }

    bool starts_with(ref const OID prefix) const pure
    {
        if (arcs.length < prefix.arcs.length)
            return false;
        foreach (i, a; prefix.arcs)
            if (arcs[i] != a)
                return false;
        return true;
    }

    void append(uint arc)
    {
        arcs ~= arc;
    }

    bool encode(ref BEREncoder enc) const
    {
        if (arcs.length < 2 || arcs[0] > 2 || (arcs[0] < 2 && arcs[1] > 39))
            return false;

        uint combined = 40 * arcs[0] + arcs[1];
        size_t len = encoded_arc_size(combined);
        foreach (a; arcs[2 .. $])
            len += encoded_arc_size(a);

        if (!enc.put_header(UniversalTag.oid, len))
            return false;

        ubyte[5] tmp;
        size_t n = write_arc(combined, tmp);
        if (!enc.write(tmp[0 .. n]))
            return false;
        foreach (a; arcs[2 .. $])
        {
            n = write_arc(a, tmp);
            if (!enc.write(tmp[0 .. n]))
                return false;
        }
        return true;
    }

    static bool decode(ref BERDecoder dec, out OID oid)
    {
        const(ubyte)[] v;
        if (!dec.read_value(UniversalTag.oid, v) || v.length == 0)
            return false;

        uint accum = 0;
        bool first = true;
        foreach (b; v)
        {
            if (accum >= (uint.max >> 7))
                return false;
            accum = (accum << 7) | (b & 0x7f);
            if ((b & 0x80) == 0)
            {
                if (first)
                {
                    uint a1, a2;
                    if (accum < 80)
                    {
                        a1 = accum / 40;
                        a2 = accum - 40 * a1;
                    }
                    else
                    {
                        a1 = 2;
                        a2 = accum - 80;
                    }
                    oid.arcs ~= a1;
                    oid.arcs ~= a2;
                    first = false;
                }
                else
                    oid.arcs ~= accum;
                accum = 0;
            }
        }
        // last byte must terminate the current arc
        return accum == 0;
    }
}


private:

size_t encoded_arc_size(uint arc) pure
{
    size_t n = 1;
    while (arc >= 0x80)
    {
        arc >>= 7;
        ++n;
    }
    return n;
}

size_t write_arc(uint arc, ref ubyte[5] buffer) pure
{
    size_t n = encoded_arc_size(arc);
    foreach_reverse (i; 0 .. n)
    {
        ubyte b = cast(ubyte)(arc & 0x7f);
        if (i != n - 1)
            b |= 0x80;
        buffer[i] = b;
        arc >>= 7;
    }
    return n;
}


unittest
{
    OID a;
    assert(OID.parse("1.3.6.1.2.1", a));
    assert(a.arcs[] == cast(uint[])[1, 3, 6, 1, 2, 1]);

    OID b;
    assert(OID.parse(".1.3.6", b));
    assert(b.arcs[] == cast(uint[])[1, 3, 6]);

    OID c;
    assert(!OID.parse("1", c));
    assert(!OID.parse("1.", c));
    assert(!OID.parse("a.b", c));

    char[64] buf;
    ptrdiff_t n = a.toString(buf[], null, null);
    assert(n > 0 && buf[0 .. n] == "1.3.6.1.2.1");

    static immutable uint[13] big_arcs = [1, 3, 6, 1, 4, 1, 2680u, 1, 2, 7, 3, 2, 0];
    OID big = OID(big_arcs[]);
    ubyte[64] enc_buf;
    BEREncoder enc;
    enc.buffer = enc_buf[];
    assert(big.encode(enc));

    BERDecoder dec;
    dec.data = enc_buf[0 .. enc.pos];
    OID parsed;
    assert(OID.decode(dec, parsed));
    assert(parsed == big);

    static immutable uint[4] p1_arcs = [1, 3, 6, 1];
    static immutable uint[5] p2_arcs = [1, 3, 6, 1, 2];
    OID p1 = OID(p1_arcs[]);
    OID p2 = OID(p2_arcs[]);
    assert(p2.starts_with(p1));
    assert(!p1.starts_with(p2));
    assert(p1 < p2);
}
