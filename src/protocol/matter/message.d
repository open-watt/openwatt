module protocol.matter.message;

nothrow @nogc:


enum MessageFlags : ubyte
{
    version_mask = 0xF0,
    source_present = 0x04,
    dest_mask = 0x03,
    dest_none = 0x00,
    dest_node = 0x01,
    dest_group = 0x02,
}

enum SecurityFlags : ubyte
{
    privacy = 0x80,
    control = 0x40,
    extensions = 0x20,
    session_type_mask = 0x03,
    session_unicast = 0x00,
    session_group = 0x01,
}

enum ExchangeFlags : ubyte
{
    initiator = 0x01,
    ack = 0x02,
    reliable = 0x04,
    secured_extensions = 0x08,
    vendor = 0x10,
}

enum ProtocolId : ushort
{
    secure_channel = 0x0000,
    interaction_model = 0x0001,
    bdx = 0x0002,
    user_directed_commissioning = 0x0003,
    echo = 0x0004,
}

enum SecureChannelOpcode : ubyte
{
    msg_counter_sync_req = 0x00,
    msg_counter_sync_rsp = 0x01,
    mrp_standalone_ack = 0x10,
    pbkdf_param_request = 0x20,
    pbkdf_param_response = 0x21,
    pase_pake1 = 0x22,
    pase_pake2 = 0x23,
    pase_pake3 = 0x24,
    case_sigma1 = 0x30,
    case_sigma2 = 0x31,
    case_sigma3 = 0x32,
    case_sigma2_resume = 0x33,
    status_report = 0x40,
}

enum InteractionModelOpcode : ubyte
{
    status_response = 0x01,
    read_request = 0x02,
    subscribe_request = 0x03,
    subscribe_response = 0x04,
    report_data = 0x05,
    write_request = 0x06,
    write_response = 0x07,
    invoke_request = 0x08,
    invoke_response = 0x09,
    timed_request = 0x0A,
}

struct MessageHeader
{
    enum min_length = 8;

    ubyte flags;
    ushort session_id;
    ubyte security_flags;
    uint counter;
    ulong source_node;
    ulong dest_node;
    ushort dest_group;

nothrow @nogc:
    bool has_source() const pure
        => (flags & MessageFlags.source_present) != 0;

    ubyte dest_kind() const pure
        => flags & MessageFlags.dest_mask;

    bool unsecured() const pure
        => session_id == 0;

    bool group_session() const pure
        => (security_flags & SecurityFlags.session_type_mask) == SecurityFlags.session_group;
}

struct ExchangeHeader
{
    enum min_length = 6;

    ubyte flags;
    ubyte opcode;
    ushort exchange_id;
    ushort protocol_id;
    ushort vendor_id;
    uint ack_counter;

nothrow @nogc:
    bool initiator() const pure
        => (flags & ExchangeFlags.initiator) != 0;

    bool has_ack() const pure
        => (flags & ExchangeFlags.ack) != 0;

    bool reliable() const pure
        => (flags & ExchangeFlags.reliable) != 0;
}

ptrdiff_t decode_message_header(const(void)[] data, out MessageHeader hdr)
{
    auto bytes = cast(const ubyte[])data;
    if (bytes.length < MessageHeader.min_length)
        return -1;

    hdr.flags = bytes[0];
    if ((hdr.flags & MessageFlags.version_mask) != 0 || hdr.dest_kind == 3)
        return -1;
    hdr.session_id = read_le!ushort(bytes[1 .. 3]);
    hdr.security_flags = bytes[3];
    hdr.counter = read_le!uint(bytes[4 .. 8]);
    size_t pos = 8;

    if (hdr.has_source)
    {
        if (bytes.length < pos + 8)
            return -1;
        hdr.source_node = read_le!ulong(bytes[pos .. pos + 8]);
        pos += 8;
    }
    if (hdr.dest_kind == MessageFlags.dest_node)
    {
        if (bytes.length < pos + 8)
            return -1;
        hdr.dest_node = read_le!ulong(bytes[pos .. pos + 8]);
        pos += 8;
    }
    else if (hdr.dest_kind == MessageFlags.dest_group)
    {
        if (bytes.length < pos + 2)
            return -1;
        hdr.dest_group = read_le!ushort(bytes[pos .. pos + 2]);
        pos += 2;
    }
    if (hdr.security_flags & SecurityFlags.extensions)
    {
        if (bytes.length < pos + 2)
            return -1;
        ushort ext_len = read_le!ushort(bytes[pos .. pos + 2]);
        pos += 2;
        if (bytes.length < pos + ext_len)
            return -1;
        pos += ext_len;
    }
    return pos;
}

ptrdiff_t encode_message_header(ref const MessageHeader hdr, void[] buffer)
{
    auto bytes = cast(ubyte[])buffer;
    size_t len = MessageHeader.min_length + (hdr.has_source ? 8 : 0) +
                 (hdr.dest_kind == MessageFlags.dest_node ? 8 : hdr.dest_kind == MessageFlags.dest_group ? 2 : 0);
    if (bytes.length < len)
        return -1;

    bytes[0] = hdr.flags & ~MessageFlags.version_mask;
    write_le(bytes[1 .. 3], hdr.session_id);
    bytes[3] = hdr.security_flags & ~SecurityFlags.extensions;
    write_le(bytes[4 .. 8], hdr.counter);
    size_t pos = 8;
    if (hdr.has_source)
    {
        write_le(bytes[pos .. pos + 8], hdr.source_node);
        pos += 8;
    }
    if (hdr.dest_kind == MessageFlags.dest_node)
    {
        write_le(bytes[pos .. pos + 8], hdr.dest_node);
        pos += 8;
    }
    else if (hdr.dest_kind == MessageFlags.dest_group)
    {
        write_le(bytes[pos .. pos + 2], hdr.dest_group);
        pos += 2;
    }
    return pos;
}

ptrdiff_t decode_exchange_header(const(void)[] data, out ExchangeHeader hdr)
{
    auto bytes = cast(const ubyte[])data;
    if (bytes.length < ExchangeHeader.min_length)
        return -1;

    hdr.flags = bytes[0];
    hdr.opcode = bytes[1];
    hdr.exchange_id = read_le!ushort(bytes[2 .. 4]);
    hdr.protocol_id = read_le!ushort(bytes[4 .. 6]);
    size_t pos = 6;
    if (hdr.flags & ExchangeFlags.vendor)
    {
        if (bytes.length < pos + 2)
            return -1;
        hdr.vendor_id = read_le!ushort(bytes[pos .. pos + 2]);
        pos += 2;
    }
    if (hdr.flags & ExchangeFlags.ack)
    {
        if (bytes.length < pos + 4)
            return -1;
        hdr.ack_counter = read_le!uint(bytes[pos .. pos + 4]);
        pos += 4;
    }
    if (hdr.flags & ExchangeFlags.secured_extensions)
    {
        if (bytes.length < pos + 2)
            return -1;
        ushort ext_len = read_le!ushort(bytes[pos .. pos + 2]);
        pos += 2;
        if (bytes.length < pos + ext_len)
            return -1;
        pos += ext_len;
    }
    return pos;
}

ptrdiff_t encode_exchange_header(ref const ExchangeHeader hdr, void[] buffer)
{
    auto bytes = cast(ubyte[])buffer;
    size_t len = ExchangeHeader.min_length + (hdr.flags & ExchangeFlags.vendor ? 2 : 0) + (hdr.has_ack ? 4 : 0);
    if (bytes.length < len)
        return -1;

    bytes[0] = hdr.flags & ~ExchangeFlags.secured_extensions;
    bytes[1] = hdr.opcode;
    write_le(bytes[2 .. 4], hdr.exchange_id);
    write_le(bytes[4 .. 6], hdr.protocol_id);
    size_t pos = 6;
    if (hdr.flags & ExchangeFlags.vendor)
    {
        write_le(bytes[pos .. pos + 2], hdr.vendor_id);
        pos += 2;
    }
    if (hdr.has_ack)
    {
        write_le(bytes[pos .. pos + 4], hdr.ack_counter);
        pos += 4;
    }
    return pos;
}


private:

T read_le(T)(const(ubyte)[] bytes) pure
{
    T r = 0;
    foreach (i; 0 .. T.sizeof)
        r |= cast(T)bytes[i] << (8*i);
    return r;
}

void write_le(T)(ubyte[] bytes, T value) pure
{
    foreach (i; 0 .. T.sizeof)
        bytes[i] = cast(ubyte)(value >> (8*i));
}


unittest
{
    ubyte[64] buf;

    MessageHeader m;
    m.flags = MessageFlags.source_present | MessageFlags.dest_node;
    m.session_id = 0x1234;
    m.security_flags = SecurityFlags.session_unicast;
    m.counter = 0xDEADBEEF;
    m.source_node = 0x0102030405060708;
    m.dest_node = 0x1112131415161718;
    ptrdiff_t len = encode_message_header(m, buf[]);
    assert(len == 24);
    assert(buf[0 .. 8] == [0x05, 0x34, 0x12, 0x00, 0xEF, 0xBE, 0xAD, 0xDE]);
    assert(buf[8 .. 16] == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]);

    MessageHeader d;
    assert(decode_message_header(buf[0 .. len], d) == len);
    assert(d.session_id == 0x1234 && d.counter == 0xDEADBEEF && d.source_node == m.source_node && d.dest_node == m.dest_node);
    assert(decode_message_header(buf[0 .. len - 1], d) == -1);

    // unsecured session with group destination and a message extension block to skip
    ubyte[] ext = [0x02, 0x00, 0x00, 0x21, 0x01, 0x00, 0x00, 0x00, 0xAA, 0xAA, 0x03, 0x00, 0xBB, 0xBB, 0xBB];
    assert(decode_message_header(ext, d) == ext.length);
    assert(d.unsecured && d.group_session && d.dest_group == 0xAAAA);
    assert(decode_message_header(ext[0 .. $ - 1], d) == -1);

    ExchangeHeader x;
    x.flags = ExchangeFlags.initiator | ExchangeFlags.reliable | ExchangeFlags.ack;
    x.opcode = SecureChannelOpcode.pbkdf_param_request;
    x.exchange_id = 0xBEEF;
    x.protocol_id = ProtocolId.secure_channel;
    x.ack_counter = 0x01020304;
    len = encode_exchange_header(x, buf[]);
    assert(len == 10);
    assert(buf[0 .. 10] == [0x07, 0x20, 0xEF, 0xBE, 0x00, 0x00, 0x04, 0x03, 0x02, 0x01]);

    ExchangeHeader y;
    assert(decode_exchange_header(buf[0 .. len], y) == len);
    assert(y.initiator && y.reliable && y.has_ack && y.ack_counter == 0x01020304 && y.exchange_id == 0xBEEF);
    assert(decode_exchange_header(buf[0 .. 8], y) == -1);
}
