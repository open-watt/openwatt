module protocol.dns.message;

import urt.array;
import urt.endian;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;
import urt.time;

nothrow @nogc:

enum DNSFlags : ushort
{
    QR = 0x8000,        // Response flag
    OPCODE = 0x7800,    // Kind of query
    AA = 0x0400,        // Authoritative answer
    TC = 0x0200,        // Truncated
    RD = 0x0100,        // Recursion desired
    RA = 0x0080,        // Recursion available
    Z = 0x0070,         // Reserved
    RCODE = 0x000F      // Response code
}

enum DNSType : ushort
{
    A = 1,          // IPv4 address
    NS = 2,         // Authoritative name server
    MD = 3,         // Mail destination
    MF = 4,         // Mail forwarder
    CNAME = 5,      // Canonical name
    SOA = 6,        // Start of authority
    MB = 7,         // Mailbox domain name
    MG = 8,         // Mail group member
    MR = 9,         // Mail rename domain name
    NULL = 10,      // Null record
    WKS = 11,       // Well-known services
    PTR = 12,       // Pointer record
    HINFO = 13,     // Host information
    MINFO = 14,     // Mailbox information
    MX = 15,        // Mail exchange
    TXT = 16,       // Text record
    RP = 17,        // Responsible person
    AFSDB = 18,     // AFS database
    X25 = 19,       // X.25 address
    ISDN = 20,      // ISDN address
    RT = 21,        // Route through
    NSAP = 22,      // NSAP address
    NSAP_PTR = 23,  // NSAP pointer
    SIG = 24,       // Signature
    KEY = 25,       // Key
    PX = 26,        // X.400 mail mapping
    GPOS = 27,      // Geographical position
    AAAA = 28,      // IPv6 address
    LOC = 29,       // Location
    NXT = 30,       // Next valid name
    EID = 31,       // Endpoint identifier
    NIMLOC = 32,    // Nimrod locator
    SRV = 33,       // Service locator
    ATMA = 34,      // ATM address
    NAPTR = 35,     // Naming authority pointer
    KX = 36,        // Key exchange
    CERT = 37,      // Certificate
    A6 = 38,        // IPv6 address (obsolete, use AAAA)
    DNAME = 39,     // Non-terminal name redirection
    SINK = 40,      // Sink
    OPT = 41,       // EDNS0 option
    APL = 42,       // Address prefix list
    DS = 43,        // Delegation signer
    SSHFP = 44,     // SSH fingerprint
    IPSECKEY = 45,  // IPSEC key
    RRSIG = 46,     // Resource record signature
    NSEC = 47,      // Next secure
    DNSKEY = 48,    // DNS key
    DHCID = 49,     // DHCP identifier
    NSEC3 = 50,     // Next secure version 3
    NSEC3PARAM = 51,   // NSEC3 parameters
    TLSA = 52,      // TLSA certificate association
    SMIMEA = 53,    // S/MIME cert association
    HIP = 55,       // Host identity protocol
    NINFO = 56,     // NINFO
    RK = 57,        // Resource key
    TALINK = 58,    // Trust anchor link
    CDS = 59,       // Child DS
    CDNSKEY = 60,   // DNSKEY(s) the child wants reflected in DS
    OPENPGPKEY = 61,    // OpenPGP key
    CSYNC = 62,     // Child-to-parent synchronization
    ZONEMD = 63,    // Message digest for DNS zone
    SVCB = 64,      // Service binding
    HTTPS = 65,     // HTTPS binding
    SPF = 99,       // Sender policy framework
    NID = 104,      // Node identifier
    L32 = 105,      // 32-bit locator
    L64 = 106,      // 64-bit locator
    LP = 107,       // Locator pointer
    EUI48 = 108,    // EUI-48 address
    EUI64 = 109,    // EUI-64 address
    ANY = 255,      // Any type
    URI = 256,      // URI
}

enum DNSClass : ushort
{
    IN = 1,     // Internet
    CS = 2,     // CSNET
    CH = 3,     // CHAOS
    HS = 4,     // Hesiod
    ANY = 255   // Any class
}

enum NBNSType : ubyte
{
    workstation = 0x00,
    master_browser = 0x1b,
    domain_controller = 0x1c,
    server = 0x20,
    unknown = 0xFF
}

struct DNSMessage
{
    ushort id;
    ushort flags;
    Array!DNSQuestion questions;
    Array!DNSRecord answers;
    Array!DNSRecord authorities;
    Array!DNSRecord additional;
}

struct DNSQuestion
{
    this(this) @disable;

    String name;
    DNSType type;
    DNSClass class_;
    NBNSType netbios_type = NBNSType.unknown;
    bool prefer_unicast_response;
}

struct DNSRecord
{
    this(this) @disable;

    String name;
    DNSType type;
    DNSClass class_;
    NBNSType netbios_type = NBNSType.unknown;
    bool flush_cache;
    Duration ttl;
    Array!ubyte data;
}

size_t formDNSMessage(ref DNSMessage message, ubyte[] buffer, bool response)
{
    if (buffer.length < DNSHeader.sizeof)
        return 0;

    assert(message.questions.length <= ushort.max);
    assert(message.answers.length <= ushort.max);

    ubyte[] msg = buffer;

    DNSHeader hdr;
    hdr.id = message.id;
    hdr.flags = message.flags | (response ? 0x80 : 0);
    hdr.qdcount = cast(ushort)message.questions.length;
    hdr.ancount = cast(ushort)message.answers.length;
    hdr.nscount = 0;
    hdr.arcount = 0;

    msg.takeFront!(DNSHeader.sizeof) = nativeToBigEndian(hdr);

    foreach (q; message.questions)
    {
        q.name[].writeName(msg);
        msg.takeFront!2 = nativeToBigEndian(q.type);
        msg.takeFront!2 = nativeToBigEndian!ushort(q.class_ | (q.prefer_unicast_response ? 0x8000 : 0));
    }

    foreach (a; message.answers)
    {
        a.name[].writeName(msg);
        msg.takeFront!2 = nativeToBigEndian(a.type);
        msg.takeFront!2 = nativeToBigEndian!ushort(a.class_ | (a.flush_cache ? 0x8000 : 0));
        msg.takeFront!4 = nativeToBigEndian(cast(uint)a.ttl.as!"seconds");
        assert(a.data.length <= ushort.max);
        msg.takeFront!2 = nativeToBigEndian(cast(ushort)a.data.length);
        msg[0 .. a.data.length] = a.data[];
        msg = msg[a.data.length .. $];
    }

    return msg.ptr - buffer.ptr;
}

ptrdiff_t parse_dns_message(const(void)[] data, out DNSMessage message)
{
    auto msg = cast(const(ubyte)[])data;
    const ubyte* start = msg.ptr;

    if (msg.length < DNSHeader.sizeof)
        return -1;
    DNSHeader header = msg.takeFront!(DNSHeader.sizeof).bigEndianToNative!DNSHeader;

    // check this DNS header looks valid
    // TODO:...?

    message.id = header.id;
    message.flags = header.flags;

    char* ptr = cast(char*)msg.ptr;
    size_t nameEnd = 0;
    foreach (i; 0 .. header.qdcount)
    {
        MutableString!0 qname;
        ptrdiff_t taken = parse_name(qname, msg, data);
        if (taken < 0 || msg.length < taken + 4)
            return -1;
        msg = msg[taken .. $];

        DNSType qtype = msg.takeFront!2.bigEndianToNative!DNSType;
        DNSClass qclass = msg.takeFront!2.bigEndianToNative!DNSClass;
        bool prefer_unicast_response = (qclass & 0x8000) != 0;
        qclass &= 0x7FFF;

        message.questions.emplaceBack(qname[].makeString(defaultAllocator()), qtype, qclass, NBNSType.unknown, prefer_unicast_response);
    }

    foreach (i; 0 .. header.ancount)
    {
        MutableString!0 name;
        ptrdiff_t taken = parse_name(name, msg, data);
        if (taken < 0 || msg.length < taken + 10)
            return -1;
        msg = msg[taken .. $];

        DNSType type = msg.takeFront!2.bigEndianToNative!DNSType;
        DNSClass cls = msg.takeFront!2.bigEndianToNative!DNSClass;
        bool flush_cache = (cls & 0x8000) != 0;
        cls &= 0x7FFF;

        uint ttl = msg.takeFront!4.bigEndianToNative!uint;
        ushort rdlen = msg.takeFront!2.bigEndianToNative!ushort;

        if (msg.length < rdlen)
            return 0;
        Array!ubyte rdata = msg.takeFront(rdlen);

        message.answers.emplaceBack(name[].makeString(defaultAllocator()), type, cls, NBNSType.unknown, flush_cache, ttl.seconds, rdata.move);
    }

    foreach (i; 0 .. header.nscount)
    {
    }

    foreach (i; 0 .. header.arcount)
    {
        // additional stuff

    }

    return msg.ptr - start;
}


package:

struct DNSHeader
{
    ushort id;
    ushort flags;
    ushort qdcount;
    ushort ancount;
    ushort nscount;
    ushort arcount;
}

ptrdiff_t parse_name(ref MutableString!0 name, const(ubyte)[] msg, const(void)[] buffer)
{
    size_t offset = 0;
    while (true)
    {
        if (msg.length == 0)
            return -1;
        ubyte qname_len = msg[offset++];
        if (qname_len == 0)
            return offset;

        if (name.length > 0)
            name ~= '.';

        if ((qname_len & 0xC0) == 0xC0)
        {
            if (msg.length == 0)
                return -1;
            size_t indirect = ((qname_len & 0x3F) << 8) | msg[offset++];
            if (parse_name(name, cast(ubyte[])buffer[indirect .. $], buffer) < 0)
                return -1;
            return offset;
        }

        if (msg.length <= qname_len)
            return -1;
        name ~= cast(char[])msg[offset .. offset + qname_len];
        offset += qname_len;
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
