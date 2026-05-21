module protocol.snmp.pdu;

import urt.array;
import urt.lifetime : move;
import urt.mem.allocator;
import urt.string;

import protocol.snmp.asn1;
import protocol.snmp.oid;

nothrow @nogc:


enum SNMPVersion : ubyte
{
    v1 = 0,
    v2c = 1,
    v3 = 3,
}

enum PDUType : ubyte
{
    get_request      = PDUTag.get_request,
    get_next_request = PDUTag.get_next_request,
    response         = PDUTag.response,
    set_request      = PDUTag.set_request,
    trap_v1          = PDUTag.trap_v1,
    get_bulk_request = PDUTag.get_bulk_request,
    inform_request   = PDUTag.inform_request,
    trap_v2          = PDUTag.trap_v2,
    report           = PDUTag.report,
}

enum SNMPError : int
{
    no_error                = 0,
    too_big                 = 1,
    no_such_name            = 2,
    bad_value               = 3,
    read_only               = 4,
    gen_err                 = 5,
    no_access               = 6,
    wrong_type              = 7,
    wrong_length            = 8,
    wrong_encoding          = 9,
    wrong_value             = 10,
    no_creation             = 11,
    inconsistent_value      = 12,
    resource_unavailable    = 13,
    commit_failed           = 14,
    undo_failed             = 15,
    authorization_error     = 16,
    not_writable            = 17,
    inconsistent_name       = 18,
}

enum VarBindType : ubyte
{
    integer,
    octet_string,
    null_,
    oid,
    ip_address,
    counter32,
    gauge32,
    time_ticks,
    opaque,
    counter64,
    no_such_object,
    no_such_instance,
    end_of_mib_view,
}


struct VarBindValue
{
nothrow @nogc:

    VarBindType type;
    long int_val;
    ulong uint_val;
    ubyte[4] ip_val;
    Array!ubyte octets;
    OID oid_val;

    static VarBindValue make_null()
    {
        return VarBindValue(VarBindType.null_);
    }

    static VarBindValue make_integer(int v)
    {
        VarBindValue r;
        r.type = VarBindType.integer;
        r.int_val = v;
        return r;
    }

    static VarBindValue make_counter32(uint v)
    {
        VarBindValue r;
        r.type = VarBindType.counter32;
        r.uint_val = v;
        return r;
    }

    static VarBindValue make_gauge32(uint v)
    {
        VarBindValue r;
        r.type = VarBindType.gauge32;
        r.uint_val = v;
        return r;
    }

    static VarBindValue make_time_ticks(uint v)
    {
        VarBindValue r;
        r.type = VarBindType.time_ticks;
        r.uint_val = v;
        return r;
    }

    static VarBindValue make_counter64(ulong v)
    {
        VarBindValue r;
        r.type = VarBindType.counter64;
        r.uint_val = v;
        return r;
    }

    static VarBindValue make_ip(ubyte[4] addr)
    {
        VarBindValue r;
        r.type = VarBindType.ip_address;
        r.ip_val = addr;
        return r;
    }

    static VarBindValue make_octet_string(const(void)[] data)
    {
        VarBindValue r;
        r.type = VarBindType.octet_string;
        r.octets ~= cast(const(ubyte)[])data;
        return r;
    }

    static VarBindValue make_oid(OID o)
    {
        VarBindValue r;
        r.type = VarBindType.oid;
        r.oid_val = o.move;
        return r;
    }
}

struct VarBind
{
nothrow @nogc:

    OID name;
    VarBindValue value;
}

struct PDU
{
nothrow @nogc:

    PDUType type;
    int request_id;
    int error_status;
    int error_index;
    Array!VarBind varbinds;

    int non_repeaters() const pure
        => error_status;
    int max_repetitions() const pure
        => error_index;
    void non_repeaters(int v) pure
    {
        error_status = v;
    }
    void max_repetitions(int v) pure
    {
        error_index = v;
    }
}

struct SNMPMessage
{
nothrow @nogc:
    this(this) @disable;

    SNMPVersion version_;
    String community;
    PDU pdu;
}


bool encode_message(ref const SNMPMessage msg, ubyte[] buffer, out size_t length)
    => encode_message(msg.version_, msg.community[], msg.pdu, buffer, length);

bool encode_message(SNMPVersion version_, const(char)[] community, ref const PDU pdu, ubyte[] buffer, out size_t length)
{
    BEREncoder enc;
    enc.buffer = buffer;

    size_t outer = enc.begin_constructed(UniversalTag.sequence);
    if (outer == size_t.max)
        return false;
    if (!enc.put_integer(UniversalTag.integer, version_))
        return false;
    if (!enc.put_octet_string(community))
        return false;
    if (!encode_pdu(pdu, enc))
        return false;
    if (!enc.end_constructed(outer))
        return false;
    length = enc.pos;
    return true;
}

bool encode_pdu(ref const PDU pdu, ref BEREncoder enc)
{
    size_t pdu_marker = enc.begin_constructed(pdu.type);
    if (pdu_marker == size_t.max)
        return false;
    if (!enc.put_integer(UniversalTag.integer, pdu.request_id))
        return false;
    if (!enc.put_integer(UniversalTag.integer, pdu.error_status))
        return false;
    if (!enc.put_integer(UniversalTag.integer, pdu.error_index))
        return false;

    size_t vb_list = enc.begin_constructed(UniversalTag.sequence);
    if (vb_list == size_t.max)
        return false;
    foreach (ref vb; pdu.varbinds)
        if (!encode_varbind(vb, enc))
            return false;
    if (!enc.end_constructed(vb_list))
        return false;

    return enc.end_constructed(pdu_marker);
}

bool encode_varbind(ref const VarBind vb, ref BEREncoder enc)
{
    size_t marker = enc.begin_constructed(UniversalTag.sequence);
    if (marker == size_t.max)
        return false;
    if (!vb.name.encode(enc))
        return false;
    if (!encode_value(vb.value, enc))
        return false;
    return enc.end_constructed(marker);
}

bool encode_value(ref const VarBindValue v, ref BEREncoder enc)
{
    final switch (v.type)
    {
        case VarBindType.integer:
            return enc.put_integer(UniversalTag.integer, v.int_val);
        case VarBindType.octet_string:
            return enc.put_octet_string(v.octets[]);
        case VarBindType.null_:
            return enc.put_null();
        case VarBindType.oid:
            return v.oid_val.encode(enc);
        case VarBindType.ip_address:
            return enc.put_ip_address(v.ip_val);
        case VarBindType.counter32:
            return enc.put_unsigned(AppTag.counter32, v.uint_val);
        case VarBindType.gauge32:
            return enc.put_unsigned(AppTag.gauge32, v.uint_val);
        case VarBindType.time_ticks:
            return enc.put_unsigned(AppTag.time_ticks, v.uint_val);
        case VarBindType.opaque:
            return enc.put_octet_string(v.octets[], AppTag.opaque);
        case VarBindType.counter64:
            return enc.put_unsigned(AppTag.counter64, v.uint_val);
        case VarBindType.no_such_object:
            return enc.put_null(ContextTag.no_such_object);
        case VarBindType.no_such_instance:
            return enc.put_null(ContextTag.no_such_instance);
        case VarBindType.end_of_mib_view:
            return enc.put_null(ContextTag.end_of_mib_view);
    }
}


bool decode_message(const(ubyte)[] data, out SNMPMessage msg)
{
    BERDecoder dec;
    dec.data = data;

    BERDecoder body_;
    if (!dec.enter(UniversalTag.sequence, body_))
        return false;

    long ver;
    if (!body_.read_integer(UniversalTag.integer, ver))
        return false;
    if (ver != SNMPVersion.v1 && ver != SNMPVersion.v2c)
        return false;
    msg.version_ = cast(SNMPVersion)ver;

    const(ubyte)[] community_bytes;
    if (!body_.read_value(UniversalTag.octet_string, community_bytes))
        return false;
    msg.community = (cast(const(char)[])community_bytes).makeString(defaultAllocator());

    return decode_pdu(body_, msg.pdu);
}

bool decode_pdu(ref BERDecoder dec, out PDU pdu)
{
    ubyte tag;
    if (!dec.peek_tag(tag))
        return false;
    if (tag < PDUTag.get_request || tag > PDUTag.report)
        return false;
    pdu.type = cast(PDUType)tag;

    BERDecoder body_;
    if (!dec.enter(tag, body_))
        return false;

    long request_id, error_status, error_index;
    if (!body_.read_integer(UniversalTag.integer, request_id))
        return false;
    if (!body_.read_integer(UniversalTag.integer, error_status))
        return false;
    if (!body_.read_integer(UniversalTag.integer, error_index))
        return false;
    pdu.request_id = cast(int)request_id;
    pdu.error_status = cast(int)error_status;
    pdu.error_index = cast(int)error_index;

    BERDecoder vb_list;
    if (!body_.enter(UniversalTag.sequence, vb_list))
        return false;
    while (!vb_list.empty)
    {
        VarBind vb;
        if (!decode_varbind(vb_list, vb))
            return false;
        pdu.varbinds ~= vb.move;
    }
    return true;
}

bool decode_varbind(ref BERDecoder dec, out VarBind vb)
{
    BERDecoder body_;
    if (!dec.enter(UniversalTag.sequence, body_))
        return false;
    if (!OID.decode(body_, vb.name))
        return false;
    return decode_value(body_, vb.value);
}

bool decode_value(ref BERDecoder dec, out VarBindValue v)
{
    ubyte tag;
    if (!dec.peek_tag(tag))
        return false;

    const(ubyte)[] raw;
    switch (tag)
    {
        case UniversalTag.integer:
            v.type = VarBindType.integer;
            return dec.read_integer(tag, v.int_val);
        case UniversalTag.octet_string:
            if (!dec.read_value(tag, raw))
                return false;
            v.type = VarBindType.octet_string;
            v.octets ~= raw;
            return true;
        case UniversalTag.null_:
            v.type = VarBindType.null_;
            return dec.read_null();
        case UniversalTag.oid:
            v.type = VarBindType.oid;
            return OID.decode(dec, v.oid_val);
        case AppTag.ip_address:
            if (!dec.read_value(tag, raw) || raw.length != 4)
                return false;
            v.type = VarBindType.ip_address;
            v.ip_val[0] = raw[0];
            v.ip_val[1] = raw[1];
            v.ip_val[2] = raw[2];
            v.ip_val[3] = raw[3];
            return true;
        case AppTag.counter32:
            v.type = VarBindType.counter32;
            return dec.read_unsigned(tag, v.uint_val);
        case AppTag.gauge32:
            v.type = VarBindType.gauge32;
            return dec.read_unsigned(tag, v.uint_val);
        case AppTag.time_ticks:
            v.type = VarBindType.time_ticks;
            return dec.read_unsigned(tag, v.uint_val);
        case AppTag.opaque:
            if (!dec.read_value(tag, raw))
                return false;
            v.type = VarBindType.opaque;
            v.octets ~= raw;
            return true;
        case AppTag.counter64:
            v.type = VarBindType.counter64;
            return dec.read_unsigned(tag, v.uint_val);
        case ContextTag.no_such_object:
            v.type = VarBindType.no_such_object;
            return dec.read_null(tag);
        case ContextTag.no_such_instance:
            v.type = VarBindType.no_such_instance;
            return dec.read_null(tag);
        case ContextTag.end_of_mib_view:
            v.type = VarBindType.end_of_mib_view;
            return dec.read_null(tag);
        default:
            return false;
    }
}


unittest
{
    SNMPMessage msg;
    msg.version_ = SNMPVersion.v2c;
    msg.community = StringLit!"public";
    msg.pdu.type = PDUType.get_request;
    msg.pdu.request_id = 0x1234;

    VarBind vb;
    assert(OID.parse("1.3.6.1.2.1.1.1.0", vb.name));
    vb.value = VarBindValue.make_null();
    msg.pdu.varbinds ~= vb.move;

    ubyte[256] buffer;
    size_t len;
    assert(encode_message(msg, buffer[], len));
    assert(len > 0);

    SNMPMessage parsed;
    assert(decode_message(buffer[0 .. len], parsed));
    assert(parsed.version_ == SNMPVersion.v2c);
    assert(parsed.community[] == "public");
    assert(parsed.pdu.type == PDUType.get_request);
    assert(parsed.pdu.request_id == 0x1234);
    assert(parsed.pdu.varbinds.length == 1);
    assert(parsed.pdu.varbinds[0].value.type == VarBindType.null_);
}
