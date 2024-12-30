module protocol.dns.message;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.string;
import urt.time;

nothrow @nogc:

enum DNSFlags : ushort
{
    QR = 0x8000,        // response flag
    OPCODE = 0x7800,    // kind of query
    AA = 0x0400,        // authoritative answer
    TC = 0x0200,        // truncated
    RD = 0x0100,        // recursion desired
    RA = 0x0080,        // recursion available
    Z = 0x0070,         // reserved
    RCODE = 0x000F      // response code
}

enum DNSType : ushort
{
    A = 1,
    NS = 2,
    CNAME = 5,
    SOA = 6,
    PTR = 12,
    MX = 15,
    TXT = 16,
    AAAA = 28,
    SRV = 33,
    NAPTR = 35,
    ANY = 255
}

enum DNSClass : ushort
{
    IN = 1,
    CS = 2,
    CH = 3,
    HS = 4,
    ANY = 255
}

struct DNSMessage
{
    ushort id;
    ushort flags;
    Array!DNSQuestion questions;
    Array!DNSAnswer answers;
}

struct DNSQuestion
{
    MutableString!0 name;
    DNSType type;
    DNSClass class_;
    bool preferUnicastResponse;
}

struct DNSAnswer
{
    MutableString!0 name;
    DNSType type;
    DNSClass class_;
    bool flushCache;
    Duration ttl;
    const(ubyte)[] data;
}

size_t formDNSMessage(ref DNSMessage message, ubyte[] buffer, bool response)
{
    if (buffer.length < mDNSHeader.sizeof)
        return 0;

    assert(message.questions.length <= ushort.max);
    assert(message.answers.length <= ushort.max);

    ubyte[] msg = buffer;

    mDNSHeader hdr;
    hdr.id = message.id;
    hdr.flags = response ? 0x80 : 0;
    hdr.qdcount = cast(ushort)message.questions.length;
    hdr.ancount = cast(ushort)message.answers.length;
    hdr.nscount = 0;
    hdr.arcount = 0;

    msg.takeFront!(mDNSHeader.sizeof) = nativeToBigEndian(hdr);

    foreach (q; message.questions)
    {
        q.name[].writeName(msg);
        msg.takeFront!2 = nativeToBigEndian(q.type);
        msg.takeFront!2 = nativeToBigEndian!ushort(q.class_ | (q.preferUnicastResponse ? 0x8000 : 0));
    }

    foreach (a; message.answers)
    {
        a.name[].writeName(msg);
        msg.takeFront!2 = nativeToBigEndian(a.type);
        msg.takeFront!2 = nativeToBigEndian!ushort(a.class_ | (a.flushCache ? 0x8000 : 0));
        msg.takeFront!4 = nativeToBigEndian(cast(uint)a.ttl.as!"seconds");
        assert(a.data.length <= ushort.max);
        msg.takeFront!2 = nativeToBigEndian(cast(ushort)a.data.length);
        msg[0 .. a.data.length] = a.data[];
        msg = msg[a.data.length .. $];
    }

    return msg.ptr - buffer.ptr;
}

bool parseDNSMessage(const(ubyte)[] data, out DNSMessage message)
{
    const(ubyte)[] msg = data;

    mDNSHeader header;
    if (msg.length < mDNSHeader.sizeof)
        return false;

    header = msg.takeFront!(mDNSHeader.sizeof).bigEndianToNative!mDNSHeader;

    // check this DNS header looks valid
    // TODO:...?

    message.id = header.id;
    message.flags = header.flags;

    char* ptr = cast(char*)msg.ptr;
    size_t nameEnd = 0;
    foreach (i; 0 .. header.qdcount)
    {
        MutableString!0 qname;
        if (!parseName(qname, msg, data) && msg.length >= 4)
            return false;

        DNSType qtype = msg.takeFront!2.bigEndianToNative!DNSType;
        DNSClass qclass = msg.takeFront!2.bigEndianToNative!DNSClass;
        bool preferUnicastResponse = (qclass & 0x8000) != 0;
        qclass &= 0x7FFF;

        message.questions ~= DNSQuestion(qname.move, qtype, qclass, preferUnicastResponse);
    }

    foreach (i; 0 .. header.ancount)
    {
        MutableString!0 name;
        if (!parseName(name, msg, data) && msg.length >= 10)
            return false;

        DNSType type = msg.takeFront!2.bigEndianToNative!DNSType;
        DNSClass cls = msg.takeFront!2.bigEndianToNative!DNSClass;
        bool flushCache = (cls & 0x8000) != 0;
        cls &= 0x7FFF;

        uint ttl = msg.takeFront!4.bigEndianToNative!uint;
        ushort rdlen = msg.takeFront!2.bigEndianToNative!ushort;

        if (msg.length < rdlen)
            return false;
        const(ubyte)[] rdata = msg.takeFront(rdlen);

        message.answers ~= DNSAnswer(name.move, type, cls, flushCache, ttl.seconds, rdata);
    }

    foreach (i; 0 .. header.nscount)
    {
    }

    foreach (i; 0 .. header.arcount)
    {
        // additional stuff

    }

    return true;
}


private:

struct mDNSHeader
{
    ushort id;
    ushort flags;
    ushort qdcount;
    ushort ancount;
    ushort nscount;
    ushort arcount;
}

bool parseName(ref MutableString!0 name, ref const(ubyte)[] msg, const(ubyte)[] buffer)
{
    while (true)
    {
        if (msg.length == 0)
            return false;
        ubyte qnameLen = msg.popFront;
        if (qnameLen == 0)
            return true;
        if (name.length > 0)
            name ~= '.';
        if ((qnameLen & 0xC0) == 0xC0)
        {
            if (msg.length == 0)
                return false;
            size_t offset = ((qnameLen & 0x3F) << 8) | msg.popFront;
            const(ubyte)[] prev = buffer[offset .. $];
            return parseName(name, prev, buffer);
        }
        else
        {
            if (msg.length <= qnameLen)
                return false;
            name ~= cast(char[])msg.takeFront(qnameLen);
        }
    }
}

bool writeName(const(char)[] name, ref ubyte[] buffer)
{
    size_t length = 0;
    while (true)
    {
        if (!buffer.length)
            return false;
        const(char)[] part = name.split!'.';
        if (!part.length)
        {
            buffer.popFront = 0;
            return true;
        }
        assert(part.length < 64);
        buffer.popFront = cast(ubyte)part.length;
        if (buffer.length < part.length)
            return false;
        buffer[0 .. part.length] = cast(ubyte[])part;
        buffer = buffer[part.length .. $];
    }
}
