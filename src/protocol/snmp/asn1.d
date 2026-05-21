module protocol.snmp.asn1;

nothrow @nogc:


enum UniversalTag : ubyte
{
    integer         = 0x02,
    octet_string    = 0x04,
    null_           = 0x05,
    oid             = 0x06,
    sequence        = 0x30,
}

enum AppTag : ubyte
{
    ip_address      = 0x40,
    counter32       = 0x41,
    gauge32         = 0x42,
    time_ticks      = 0x43,
    opaque          = 0x44,
    counter64       = 0x46,
}

enum ContextTag : ubyte
{
    no_such_object   = 0x80,
    no_such_instance = 0x81,
    end_of_mib_view  = 0x82,
}

enum PDUTag : ubyte
{
    get_request      = 0xa0,
    get_next_request = 0xa1,
    response         = 0xa2,
    set_request      = 0xa3,
    trap_v1          = 0xa4,
    get_bulk_request = 0xa5,
    inform_request   = 0xa6,
    trap_v2          = 0xa7,
    report           = 0xa8,
}


struct BEREncoder
{
nothrow @nogc:
    ubyte[] buffer;
    size_t pos;

    bool write(ubyte b)
    {
        if (pos >= buffer.length)
            return false;
        buffer[pos++] = b;
        return true;
    }

    bool write(const(ubyte)[] data)
    {
        if (pos + data.length > buffer.length)
            return false;
        buffer[pos .. pos + data.length] = data[];
        pos += data.length;
        return true;
    }

    bool put_header(ubyte tag, size_t length)
    {
        if (!write(tag))
            return false;
        if (length < 0x80)
            return write(cast(ubyte)length);
        if (length < 0x100)
        {
            if (pos + 2 > buffer.length)
                return false;
            buffer[pos++] = 0x81;
            buffer[pos++] = cast(ubyte)length;
            return true;
        }
        if (length < 0x10000)
        {
            if (pos + 3 > buffer.length)
                return false;
            buffer[pos++] = 0x82;
            buffer[pos++] = cast(ubyte)(length >> 8);
            buffer[pos++] = cast(ubyte)length;
            return true;
        }
        return false;
    }

    bool put_null(ubyte tag = UniversalTag.null_)
        => put_header(tag, 0);

    bool put_integer(ubyte tag, long value)
    {
        ubyte[9] tmp;
        size_t len = encode_signed_minimal(value, tmp);
        if (!put_header(tag, len))
            return false;
        return write(tmp[0 .. len]);
    }

    bool put_unsigned(ubyte tag, ulong value)
    {
        ubyte[9] tmp;
        size_t len = encode_unsigned_minimal(value, tmp);
        if (!put_header(tag, len))
            return false;
        return write(tmp[0 .. len]);
    }

    bool put_octet_string(const(void)[] data, ubyte tag = UniversalTag.octet_string)
    {
        if (!put_header(tag, data.length))
            return false;
        return write(cast(const(ubyte)[])data);
    }

    bool put_ip_address(ubyte[4] addr)
    {
        if (!put_header(AppTag.ip_address, 4))
            return false;
        return write(addr[]);
    }

    // reserves 3 bytes of length placeholder; returns marker (size_t.max on overflow)
    size_t begin_constructed(ubyte tag)
    {
        if (pos + 4 > buffer.length)
            return size_t.max;
        buffer[pos++] = tag;
        size_t marker = pos;
        buffer[pos++] = 0;
        buffer[pos++] = 0;
        buffer[pos++] = 0;
        return marker;
    }

    bool end_constructed(size_t marker)
    {
        if (marker == size_t.max)
            return false;
        size_t content_start = marker + 3;
        size_t content_len = pos - content_start;
        if (content_len < 0x80)
        {
            buffer[marker] = cast(ubyte)content_len;
            foreach (i; 0 .. content_len)
                buffer[marker + 1 + i] = buffer[content_start + i];
            pos -= 2;
        }
        else if (content_len < 0x100)
        {
            buffer[marker] = 0x81;
            buffer[marker + 1] = cast(ubyte)content_len;
            foreach (i; 0 .. content_len)
                buffer[marker + 2 + i] = buffer[content_start + i];
            pos -= 1;
        }
        else if (content_len < 0x10000)
        {
            buffer[marker] = 0x82;
            buffer[marker + 1] = cast(ubyte)(content_len >> 8);
            buffer[marker + 2] = cast(ubyte)content_len;
        }
        else
            return false;
        return true;
    }
}


struct BERDecoder
{
nothrow @nogc:
    const(ubyte)[] data;

    bool empty() const pure
        => data.length == 0;

    bool peek_tag(out ubyte tag) const pure
    {
        if (data.length == 0)
            return false;
        tag = data[0];
        return true;
    }

    bool read_header(out ubyte tag, out size_t length)
    {
        if (data.length < 2)
            return false;
        tag = data[0];
        ubyte b = data[1];
        if (b < 0x80)
        {
            length = b;
            data = data[2 .. $];
            return true;
        }
        if (b == 0x80)
            return false;
        size_t n = b & 0x7f;
        if (n > size_t.sizeof || data.length < 2 + n)
            return false;
        length = 0;
        foreach (i; 0 .. n)
            length = (length << 8) | data[2 + i];
        data = data[2 + n .. $];
        return true;
    }

    bool read_value(ubyte expected_tag, out const(ubyte)[] value)
    {
        ubyte tag;
        size_t len;
        if (!read_header(tag, len) || tag != expected_tag || data.length < len)
            return false;
        value = data[0 .. len];
        data = data[len .. $];
        return true;
    }

    bool read_integer(ubyte expected_tag, out long value)
    {
        const(ubyte)[] v;
        if (!read_value(expected_tag, v) || v.length == 0 || v.length > 8)
            return false;
        long r = cast(byte)v[0];
        foreach (b; v[1 .. $])
            r = (r << 8) | b;
        value = r;
        return true;
    }

    bool read_unsigned(ubyte expected_tag, out ulong value)
    {
        const(ubyte)[] v;
        if (!read_value(expected_tag, v) || v.length == 0 || v.length > 9)
            return false;
        size_t off = 0;
        if (v[0] == 0 && v.length > 1)
            off = 1;
        if (v.length - off > 8)
            return false;
        ulong r = 0;
        foreach (b; v[off .. $])
            r = (r << 8) | b;
        value = r;
        return true;
    }

    bool read_null(ubyte expected_tag = UniversalTag.null_)
    {
        const(ubyte)[] v;
        if (!read_value(expected_tag, v))
            return false;
        return v.length == 0;
    }

    bool enter(ubyte expected_tag, out BERDecoder sub)
    {
        const(ubyte)[] v;
        if (!read_value(expected_tag, v))
            return false;
        sub.data = v;
        return true;
    }

    bool skip()
    {
        ubyte tag;
        size_t len;
        if (!read_header(tag, len) || data.length < len)
            return false;
        data = data[len .. $];
        return true;
    }
}


size_t encode_signed_minimal(long value, ref ubyte[9] buffer) pure
{
    ubyte[8] tmp;
    foreach (i; 0 .. 8)
        tmp[7 - i] = cast(ubyte)(value >> (i * 8));

    size_t start = 0;
    if (value >= 0)
    {
        while (start < 7 && tmp[start] == 0x00 && (tmp[start + 1] & 0x80) == 0)
            ++start;
    }
    else
    {
        while (start < 7 && tmp[start] == 0xff && (tmp[start + 1] & 0x80) != 0)
            ++start;
    }

    size_t len = 8 - start;
    foreach (i; 0 .. len)
        buffer[i] = tmp[start + i];
    return len;
}

size_t encode_unsigned_minimal(ulong value, ref ubyte[9] buffer) pure
{
    if (value == 0)
    {
        buffer[0] = 0;
        return 1;
    }
    ubyte[8] tmp;
    foreach (i; 0 .. 8)
        tmp[7 - i] = cast(ubyte)(value >> (i * 8));
    size_t start = 0;
    while (start < 7 && tmp[start] == 0)
        ++start;
    bool pad = (tmp[start] & 0x80) != 0;
    size_t off = 0;
    if (pad)
        buffer[off++] = 0;
    foreach (i; start .. 8)
        buffer[off++] = tmp[i];
    return off;
}


unittest
{
    ubyte[9] tmp;

    assert(encode_signed_minimal(0, tmp) == 1 && tmp[0] == 0);
    assert(encode_signed_minimal(127, tmp) == 1 && tmp[0] == 0x7f);
    assert(encode_signed_minimal(128, tmp) == 2 && tmp[0] == 0 && tmp[1] == 0x80);
    assert(encode_signed_minimal(-1, tmp) == 1 && tmp[0] == 0xff);
    assert(encode_signed_minimal(-128, tmp) == 1 && tmp[0] == 0x80);
    assert(encode_signed_minimal(-129, tmp) == 2 && tmp[0] == 0xff && tmp[1] == 0x7f);

    assert(encode_unsigned_minimal(0, tmp) == 1 && tmp[0] == 0);
    assert(encode_unsigned_minimal(127, tmp) == 1 && tmp[0] == 0x7f);
    assert(encode_unsigned_minimal(128, tmp) == 2 && tmp[0] == 0 && tmp[1] == 0x80);
    assert(encode_unsigned_minimal(255, tmp) == 2 && tmp[0] == 0 && tmp[1] == 0xff);
    assert(encode_unsigned_minimal(256, tmp) == 2 && tmp[0] == 0x01 && tmp[1] == 0x00);
    assert(encode_unsigned_minimal(0xffff_ffff, tmp) == 5 && tmp[0] == 0 && tmp[1 .. 5] == cast(ubyte[])[0xff, 0xff, 0xff, 0xff]);

    ubyte[64] buf;
    BEREncoder enc;
    enc.buffer = buf[];

    size_t outer = enc.begin_constructed(UniversalTag.sequence);
    assert(enc.put_integer(UniversalTag.integer, 42));
    assert(enc.put_octet_string(cast(const(ubyte)[])"hi"));
    assert(enc.put_null());
    assert(enc.end_constructed(outer));

    BERDecoder dec;
    dec.data = buf[0 .. enc.pos];
    BERDecoder sub;
    assert(dec.enter(UniversalTag.sequence, sub));
    long v;
    assert(sub.read_integer(UniversalTag.integer, v) && v == 42);
    const(ubyte)[] s;
    assert(sub.read_value(UniversalTag.octet_string, s) && cast(const(char)[])s == "hi");
    assert(sub.read_null());
    assert(sub.empty);
    assert(dec.empty);
}
