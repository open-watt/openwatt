module protocol.mqtt.codec;

import urt.string;

nothrow @nogc:


enum ProtocolLevel : ubyte
{
    _3_1   = 3,
    _3_1_1 = 4,
    _5     = 5,
}

// High nibble of fixed-header byte.
enum PacketType : ubyte
{
    Connect     = 1,
    ConnAck     = 2,
    Publish     = 3,
    PubAck      = 4,
    PubRec      = 5,
    PubRel      = 6,
    PubComp     = 7,
    Subscribe   = 8,
    SubAck      = 9,
    Unsubscribe = 10,
    UnsubAck    = 11,
    PingReq     = 12,
    PingResp    = 13,
    Disconnect  = 14,
    Auth        = 15,
}

// v5 property identifiers.
enum Property : ubyte
{
    PayloadFormatIndicator          = 0x01, // ubyte         PUBLISH, Will
    MessageExpiryInterval           = 0x02, // uint          PUBLISH, Will
    ContentType                     = 0x03, // utf8          PUBLISH, Will
    ResponseTopic                   = 0x08, // utf8          PUBLISH, Will
    CorrelationData                 = 0x09, // binary        PUBLISH, Will
    SubscriptionIdentifier          = 0x0B, // vbi           PUBLISH, SUBSCRIBE
    SessionExpiryInterval           = 0x11, // uint          CONNECT, CONNACK, DISCONNECT
    AssignedClientIdentifier        = 0x12, // utf8          CONNACK
    ServerKeepAlive                 = 0x13, // ushort        CONNACK
    AuthenticationMethod            = 0x15, // utf8          CONNECT, CONNACK, AUTH
    AuthenticationData              = 0x16, // binary        CONNECT, CONNACK, AUTH
    RequestProblemInformation       = 0x17, // ubyte         CONNECT
    WillDelayInterval               = 0x18, // uint          Will
    RequestResponseInformation      = 0x19, // ubyte         CONNECT
    ResponseInformation             = 0x1A, // utf8          CONNACK
    ServerReference                 = 0x1C, // utf8          CONNACK, DISCONNECT
    ReasonString                    = 0x1F, // utf8          most ack/disconnect packets
    ReceiveMaximum                  = 0x21, // ushort        CONNECT, CONNACK
    TopicAliasMaximum               = 0x22, // ushort        CONNECT, CONNACK
    TopicAlias                      = 0x23, // ushort        PUBLISH
    MaximumQoS                      = 0x24, // ubyte         CONNACK
    RetainAvailable                 = 0x25, // ubyte         CONNACK
    UserProperty                    = 0x26, // utf8 pair     anywhere; may repeat
    MaximumPacketSize               = 0x27, // uint          CONNECT, CONNACK
    WildcardSubscriptionAvailable   = 0x28, // ubyte         CONNACK
    SubscriptionIdentifierAvailable = 0x29, // ubyte         CONNACK
    SharedSubscriptionAvailable     = 0x2A, // ubyte         CONNACK
}

// 0x00 means "Success" in some packets and "Normal..." in others; we use Success everywhere and rely on context at the call site.
enum ReasonCode : ubyte
{
    Success                              = 0x00,
    GrantedQoS1                          = 0x01,
    GrantedQoS2                          = 0x02,
    DisconnectWithWill                   = 0x04,
    NoMatchingSubscribers                = 0x10,
    NoSubscriptionExisted                = 0x11,
    ContinueAuthentication               = 0x18,
    ReAuthenticate                       = 0x19,
    UnspecifiedError                     = 0x80,
    MalformedPacket                      = 0x81,
    ProtocolError                        = 0x82,
    ImplementationSpecificError          = 0x83,
    UnsupportedProtocolVersion           = 0x84,
    ClientIdentifierNotValid             = 0x85,
    BadUsernameOrPassword                = 0x86,
    NotAuthorized                        = 0x87,
    ServerUnavailable                    = 0x88,
    ServerBusy                           = 0x89,
    Banned                               = 0x8A,
    ServerShuttingDown                   = 0x8B,
    BadAuthenticationMethod              = 0x8C,
    KeepAliveTimeout                     = 0x8D,
    SessionTakenOver                     = 0x8E,
    TopicFilterInvalid                   = 0x8F,
    TopicNameInvalid                     = 0x90,
    PacketIdentifierInUse                = 0x91,
    PacketIdentifierNotFound             = 0x92,
    ReceiveMaximumExceeded               = 0x93,
    TopicAliasInvalid                    = 0x94,
    PacketTooLarge                       = 0x95,
    MessageRateTooHigh                   = 0x96,
    QuotaExceeded                        = 0x97,
    AdministrativeAction                 = 0x98,
    PayloadFormatInvalid                 = 0x99,
    RetainNotSupported                   = 0x9A,
    QoSNotSupported                      = 0x9B,
    UseAnotherServer                     = 0x9C,
    ServerMoved                          = 0x9D,
    SharedSubscriptionsNotSupported      = 0x9E,
    ConnectionRateExceeded               = 0x9F,
    MaximumConnectTime                   = 0xA0,
    SubscriptionIdentifiersNotSupported  = 0xA1,
    WildcardSubscriptionsNotSupported    = 0xA2,
}


struct FixedHeader
{
    PacketType type;
    ubyte flags;        // low nibble of header byte; per-type semantics
    uint body_length;
}

bool decode_header(ref const(ubyte)[] buffer, ref FixedHeader hdr)
{
    if (buffer.length < 2)
        return false;
    ubyte b = buffer[0];
    ubyte t = b >> 4;
    if (t < PacketType.Connect || t > PacketType.Auth)
        return false;
    hdr.type = cast(PacketType)t;
    hdr.flags = b & 0x0F;

    const(ubyte)[] tail = buffer[1 .. $];
    if (!take_vbi(tail, hdr.body_length))
        return false;
    buffer = tail;
    return true;
}

bool encode_header(ref ubyte[] sink, PacketType type, ubyte flags, uint body_length)
{
    if (sink.length < 1 + vbi_size(body_length))
        return false;
    sink[0] = cast(ubyte)((cast(ubyte)type << 4) | (flags & 0x0F));
    sink = sink[1 .. $];
    return put_vbi(sink, body_length);
}

size_t header_size(uint body_length) pure
{
    return 1 + vbi_size(body_length);
}


// take/put helpers return false on under/over-flow; on failure the out value is not modified and the slice does not advance past the failure point.
bool take(T)(ref const(ubyte)[] buf, ref T v) if (is(T == ubyte) || is(T == ushort) || is(T == uint))
{
    static if (is(T == ubyte))
    {
        if (buf.length < 1)
            return false;
        v = buf[0];
        buf = buf[1 .. $];
    }
    else static if (is(T == ushort))
    {
        if (buf.length < 2)
            return false;
        v = cast(ushort)((buf[0] << 8) | buf[1]);
        buf = buf[2 .. $];
    }
    else
    {
        if (buf.length < 4)
            return false;
        v = (cast(uint)buf[0] << 24) | (cast(uint)buf[1] << 16) | (cast(uint)buf[2] << 8) | buf[3];
        buf = buf[4 .. $];
    }
    return true;
}

bool take_vbi(ref const(ubyte)[] buf, ref uint v)
{
    uint result = 0;
    uint shift = 0;
    foreach (i; 0 .. 4)
    {
        if (buf.length < 1)
            return false;
        ubyte b = buf[0];
        buf = buf[1 .. $];
        result |= cast(uint)(b & 0x7F) << shift;
        if ((b & 0x80) == 0)
        {
            v = result;
            return true;
        }
        shift += 7;
    }
    return false; // VBI longer than 4 bytes is malformed
}

bool take_string(ref const(ubyte)[] buf, ref const(char)[] s)
{
    if (buf.length < 2)
        return false;
    ushort len = cast(ushort)((buf[0] << 8) | buf[1]);
    if (buf.length < 2 + len)
        return false;
    s = cast(const(char)[])buf[2 .. 2 + len];
    buf = buf[2 + len .. $];
    return true;
}

bool take_binary(ref const(ubyte)[] buf, ref const(ubyte)[] b)
{
    if (buf.length < 2)
        return false;
    ushort len = cast(ushort)((buf[0] << 8) | buf[1]);
    if (buf.length < 2 + len)
        return false;
    b = buf[2 .. 2 + len];
    buf = buf[2 + len .. $];
    return true;
}

bool put(T)(ref ubyte[] sink, T v) if (is(T == ubyte) || is(T == ushort) || is(T == uint))
{
    static if (is(T == ubyte))
    {
        if (sink.length < 1)
            return false;
        sink[0] = v;
        sink = sink[1 .. $];
    }
    else static if (is(T == ushort))
    {
        if (sink.length < 2)
            return false;
        sink[0] = cast(ubyte)(v >> 8);
        sink[1] = cast(ubyte)(v & 0xFF);
        sink = sink[2 .. $];
    }
    else
    {
        if (sink.length < 4)
            return false;
        sink[0] = cast(ubyte)(v >> 24);
        sink[1] = cast(ubyte)((v >> 16) & 0xFF);
        sink[2] = cast(ubyte)((v >> 8) & 0xFF);
        sink[3] = cast(ubyte)(v & 0xFF);
        sink = sink[4 .. $];
    }
    return true;
}

bool put_vbi(ref ubyte[] sink, uint v)
{
    if (v >= (1u << 28))
        return false;
    foreach (i; 0 .. 4)
    {
        if (sink.length < 1)
            return false;
        ubyte b = cast(ubyte)(v & 0x7F);
        v >>= 7;
        if (v != 0)
            b |= 0x80;
        sink[0] = b;
        sink = sink[1 .. $];
        if (v == 0)
            return true;
    }
    return false;
}

bool put_string(ref ubyte[] sink, const(char)[] s)
{
    if (s.length > 0xFFFF)
        return false;
    if (sink.length < 2 + s.length)
        return false;
    sink[0] = cast(ubyte)(s.length >> 8);
    sink[1] = cast(ubyte)(s.length & 0xFF);
    sink[2 .. 2 + s.length] = cast(ubyte[])s;
    sink = sink[2 + s.length .. $];
    return true;
}

bool put_binary(ref ubyte[] sink, const(ubyte)[] b)
{
    if (b.length > 0xFFFF)
        return false;
    if (sink.length < 2 + b.length)
        return false;
    sink[0] = cast(ubyte)(b.length >> 8);
    sink[1] = cast(ubyte)(b.length & 0xFF);
    sink[2 .. 2 + b.length] = b;
    sink = sink[2 + b.length .. $];
    return true;
}

size_t vbi_size(uint v) pure
{
    if (v < 128)
        return 1;
    if (v < 16384)
        return 2;
    if (v < 2097152)
        return 3;
    if (v < 268435456)
        return 4;
    return 0; // invalid
}

size_t string_size(const(char)[] s) pure { return 2 + s.length; }
size_t binary_size(const(ubyte)[] b) pure { return 2 + b.length; }


// v5 property blocks are sliced out on decode and copied verbatim on encode. Callers parse contents on demand using take_*/put_* against pkt.properties.
bool take_property_block(ref const(ubyte)[] body, ref const(ubyte)[] props)
{
    uint prop_len;
    if (!take_vbi(body, prop_len))
        return false;
    if (body.length < prop_len)
        return false;
    props = body[0 .. prop_len];
    body = body[prop_len .. $];
    return true;
}

bool put_property_block(ref ubyte[] sink, const(ubyte)[] props)
{
    if (!put_vbi(sink, cast(uint)props.length))
        return false;
    if (sink.length < props.length)
        return false;
    sink[0 .. props.length] = props;
    sink = sink[props.length .. $];
    return true;
}

size_t property_block_size(const(ubyte)[] props) pure
{
    return vbi_size(cast(uint)props.length) + props.length;
}


struct PublishPacket
{
    bool dup;
    ubyte qos;                   // 0..2
    bool retain;
    const(char)[] topic;
    ushort packet_id;            // present only when qos > 0
    const(ubyte)[] properties;   // v5 raw property block; empty in v3
    const(ubyte)[] payload;
}

bool decode_publish(ref const(ubyte)[] body, ubyte flags, ProtocolLevel level, ref PublishPacket pkt)
{
    pkt.dup    = (flags & 0x08) != 0;
    pkt.qos    = (flags >> 1) & 0x03;
    pkt.retain = (flags & 0x01) != 0;

    if (pkt.qos > 2)
        return false;
    if (pkt.dup && pkt.qos == 0) return false;     // DUP requires QoS > 0

    if (!take_string(body, pkt.topic))
        return false;

    if (pkt.qos > 0)
    {
        if (!take!ushort(body, pkt.packet_id))
            return false;
        if (pkt.packet_id == 0) return false;       // zero packet-id is invalid
    }

    if (level >= ProtocolLevel._5)
        if (!take_property_block(body, pkt.properties))
            return false;

    pkt.payload = body[];
    body = body[$ .. $];
    return true;
}

private size_t publish_body_size(ref const PublishPacket pkt, ProtocolLevel level)
{
    size_t s = string_size(pkt.topic);
    if (pkt.qos > 0)
        s += 2;
    if (level >= ProtocolLevel._5)
        s += property_block_size(pkt.properties);
    s += pkt.payload.length;
    return s;
}

size_t publish_size(ref const PublishPacket pkt, ProtocolLevel level)
{
    size_t body = publish_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_publish(ref ubyte[] sink, ref const PublishPacket pkt, ProtocolLevel level)
{
    if (pkt.qos > 2)
        return false;
    if (pkt.dup && pkt.qos == 0)
        return false;

    size_t body = publish_body_size(pkt, level);
    ubyte flags = cast(ubyte)((pkt.dup ? 0x08 : 0) | (pkt.qos << 1) | (pkt.retain ? 0x01 : 0));
    if (!encode_header(sink, PacketType.Publish, flags, cast(uint)body))
        return false;

    if (!put_string(sink, pkt.topic))
        return false;
    if (pkt.qos > 0)
        if (!put!ushort(sink, pkt.packet_id))
            return false;
    if (level >= ProtocolLevel._5)
        if (!put_property_block(sink, pkt.properties))
            return false;
    if (sink.length < pkt.payload.length)
        return false;
    sink[0 .. pkt.payload.length] = pkt.payload;
    sink = sink[pkt.payload.length .. $];
    return true;
}


enum ConnectFlag : ubyte
{
    none          = 0,
    clean_start   = 1 << 1,     // CleanSession in v3
    will          = 1 << 2,
    will_qos_mask = 0x18,       // bits 4-3
    will_retain   = 1 << 5,
    password      = 1 << 6,
    username      = 1 << 7,
}

struct ConnectPacket
{
    ProtocolLevel protocol_level;
    bool clean_start;
    ushort keep_alive;
    const(ubyte)[] properties;       // v5 raw property block; empty in v3

    const(char)[] client_id;

    bool has_will;
    bool will_retain;
    ubyte will_qos;                  // 0..2 (must be 0 if !has_will)
    const(ubyte)[] will_properties;  // v5 raw will-property block; empty in v3
    const(char)[] will_topic;
    const(ubyte)[] will_payload;

    bool has_username;
    const(char)[] username;
    bool has_password;
    const(ubyte)[] password;
}

bool decode_connect(ref const(ubyte)[] body, ubyte flags, ref ConnectPacket pkt)
{
    if (flags != 0) return false;        // reserved flag bits must be zero

    const(char)[] name;
    if (!take_string(body, name))
        return false;

    ubyte level;
    if (!take!ubyte(body, level))
        return false;
    if (level != ProtocolLevel._3_1 && level != ProtocolLevel._3_1_1 && level != ProtocolLevel._5)
        return false;

    if (level == ProtocolLevel._3_1)
    {
        if (name != "MQIsdp")
            return false;
    }
    else
    {
        if (name != "MQTT")
            return false;
    }
    pkt.protocol_level = cast(ProtocolLevel)level;

    ubyte cflags;
    if (!take!ubyte(body, cflags))
        return false;
    if (cflags & 0x01) return false;     // reserved bit must be zero

    pkt.clean_start  = (cflags & ConnectFlag.clean_start) != 0;
    pkt.has_will     = (cflags & ConnectFlag.will) != 0;
    pkt.will_qos     = (cflags >> 3) & 0x03;
    pkt.will_retain  = (cflags & ConnectFlag.will_retain) != 0;
    pkt.has_password = (cflags & ConnectFlag.password) != 0;
    pkt.has_username = (cflags & ConnectFlag.username) != 0;

    if (pkt.will_qos > 2)
        return false;
    if (!pkt.has_will && (pkt.will_qos != 0 || pkt.will_retain))
        return false;

    // v3.1.1 forbids password without username; v5 allows it
    if (pkt.protocol_level < ProtocolLevel._5)
        if (pkt.has_password && !pkt.has_username)
            return false;

    if (!take!ushort(body, pkt.keep_alive))
        return false;

    if (pkt.protocol_level >= ProtocolLevel._5)
        if (!take_property_block(body, pkt.properties))
            return false;

    if (!take_string(body, pkt.client_id))
        return false;

    if (pkt.has_will)
    {
        if (pkt.protocol_level >= ProtocolLevel._5)
            if (!take_property_block(body, pkt.will_properties))
                return false;
        if (!take_string(body, pkt.will_topic))
            return false;
        if (!take_binary(body, pkt.will_payload))
            return false;
    }

    if (pkt.has_username)
        if (!take_string(body, pkt.username))
            return false;

    if (pkt.has_password)
        if (!take_binary(body, pkt.password))
            return false;

    return body.length == 0;
}

private size_t connect_body_size(ref const ConnectPacket pkt)
{
    const(char)[] name = (pkt.protocol_level == ProtocolLevel._3_1) ? "MQIsdp" : "MQTT";
    size_t s = string_size(name);
    s += 1;                         // protocol level
    s += 1;                         // connect flags
    s += 2;                         // keep alive
    if (pkt.protocol_level >= ProtocolLevel._5)
        s += property_block_size(pkt.properties);
    s += string_size(pkt.client_id);
    if (pkt.has_will)
    {
        if (pkt.protocol_level >= ProtocolLevel._5)
            s += property_block_size(pkt.will_properties);
        s += string_size(pkt.will_topic);
        s += binary_size(pkt.will_payload);
    }
    if (pkt.has_username)
        s += string_size(pkt.username);
    if (pkt.has_password)
        s += binary_size(pkt.password);
    return s;
}

size_t connect_size(ref const ConnectPacket pkt)
{
    size_t body = connect_body_size(pkt);
    return header_size(cast(uint)body) + body;
}

bool encode_connect(ref ubyte[] sink, ref const ConnectPacket pkt)
{
    if (pkt.will_qos > 2)
        return false;
    if (!pkt.has_will && (pkt.will_qos != 0 || pkt.will_retain))
        return false;
    if (pkt.protocol_level < ProtocolLevel._5 && pkt.has_password && !pkt.has_username)
        return false;

    size_t body = connect_body_size(pkt);
    if (!encode_header(sink, PacketType.Connect, 0, cast(uint)body))
        return false;

    const(char)[] name = (pkt.protocol_level == ProtocolLevel._3_1) ? "MQIsdp" : "MQTT";
    if (!put_string(sink, name))
        return false;
    if (!put!ubyte(sink, pkt.protocol_level))
        return false;

    ubyte cflags;
    if (pkt.clean_start)
        cflags |= ConnectFlag.clean_start;
    if (pkt.has_will)
        cflags |= ConnectFlag.will;
    cflags |= cast(ubyte)((pkt.will_qos & 0x03) << 3);
    if (pkt.will_retain)
        cflags |= ConnectFlag.will_retain;
    if (pkt.has_password)
        cflags |= ConnectFlag.password;
    if (pkt.has_username)
        cflags |= ConnectFlag.username;
    if (!put!ubyte(sink, cflags))
        return false;

    if (!put!ushort(sink, pkt.keep_alive))
        return false;

    if (pkt.protocol_level >= ProtocolLevel._5)
        if (!put_property_block(sink, pkt.properties))
            return false;

    if (!put_string(sink, pkt.client_id))
        return false;

    if (pkt.has_will)
    {
        if (pkt.protocol_level >= ProtocolLevel._5)
            if (!put_property_block(sink, pkt.will_properties))
                return false;
        if (!put_string(sink, pkt.will_topic))
            return false;
        if (!put_binary(sink, pkt.will_payload))
            return false;
    }

    if (pkt.has_username)
        if (!put_string(sink, pkt.username))
            return false;

    if (pkt.has_password)
        if (!put_binary(sink, pkt.password))
            return false;

    return true;
}


struct ConnAckPacket
{
    bool session_present;
    ubyte reason_code;            // v3 return codes (0-5) or v5 ReasonCode
    const(ubyte)[] properties;     // v5 raw property block; empty in v3
}

bool decode_connack(ref const(ubyte)[] body, ubyte flags, ProtocolLevel level, ref ConnAckPacket pkt)
{
    if (flags != 0)
        return false;

    ubyte ack_flags;
    if (!take!ubyte(body, ack_flags))
        return false;
    if (ack_flags & 0xFE) return false;        // bits 1-7 reserved
    pkt.session_present = (ack_flags & 0x01) != 0;

    if (!take!ubyte(body, pkt.reason_code))
        return false;

    if (level >= ProtocolLevel._5)
        if (!take_property_block(body, pkt.properties))
            return false;

    return body.length == 0;
}

private size_t connack_body_size(ref const ConnAckPacket pkt, ProtocolLevel level)
{
    size_t s = 2;
    if (level >= ProtocolLevel._5)
        s += property_block_size(pkt.properties);
    return s;
}

size_t connack_size(ref const ConnAckPacket pkt, ProtocolLevel level)
{
    size_t body = connack_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_connack(ref ubyte[] sink, ref const ConnAckPacket pkt, ProtocolLevel level)
{
    size_t body = connack_body_size(pkt, level);
    if (!encode_header(sink, PacketType.ConnAck, 0, cast(uint)body))
        return false;
    if (!put!ubyte(sink, pkt.session_present ? 0x01 : 0x00))
        return false;
    if (!put!ubyte(sink, pkt.reason_code))
        return false;
    if (level >= ProtocolLevel._5)
        if (!put_property_block(sink, pkt.properties))
            return false;
    return true;
}


// PUBACK / PUBREC / PUBREL / PUBCOMP share a wire shape; only the fixed-header type byte and PUBREL's reserved flag bits differ.
struct AckPacket
{
    ushort packet_id;
    ubyte reason_code;             // v5 only; 0 (Success) implied in v3
    const(ubyte)[] properties;     // v5 raw property block; empty in v3
}

alias PubAckPacket  = AckPacket;
alias PubRecPacket  = AckPacket;
alias PubRelPacket  = AckPacket;
alias PubCompPacket = AckPacket;

bool decode_ack(ref const(ubyte)[] body, ubyte flags, PacketType type, ProtocolLevel level, ref AckPacket pkt)
{
    ubyte expected_flags = (type == PacketType.PubRel) ? 0x02 : 0x00;
    if (flags != expected_flags)
        return false;

    if (!take!ushort(body, pkt.packet_id))
        return false;
    if (pkt.packet_id == 0)
        return false;

    // v5 short form: if remaining length is 2 (just packet_id), reason code defaults to Success and properties are absent.
    // Properties may also be omitted even when a reason code is present.
    if (level >= ProtocolLevel._5 && body.length > 0)
    {
        if (!take!ubyte(body, pkt.reason_code))
            return false;
        if (body.length > 0)
            if (!take_property_block(body, pkt.properties))
                return false;
    }

    return body.length == 0;
}

private bool ack_has_v5_tail(ref const AckPacket pkt)
{
    return pkt.reason_code != 0 || pkt.properties.length > 0;
}

private size_t ack_body_size(ref const AckPacket pkt, ProtocolLevel level)
{
    size_t s = 2;
    if (level >= ProtocolLevel._5 && ack_has_v5_tail(pkt))
    {
        s += 1;                                // reason code
        s += property_block_size(pkt.properties);
    }
    return s;
}

size_t ack_size(ref const AckPacket pkt, ProtocolLevel level)
{
    size_t body = ack_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_ack(ref ubyte[] sink, PacketType type, ref const AckPacket pkt, ProtocolLevel level)
{
    if (type != PacketType.PubAck && type != PacketType.PubRec
        && type != PacketType.PubRel && type != PacketType.PubComp)
        return false;

    ubyte flags = (type == PacketType.PubRel) ? 0x02 : 0x00;
    size_t body = ack_body_size(pkt, level);
    if (!encode_header(sink, type, flags, cast(uint)body))
        return false;
    if (!put!ushort(sink, pkt.packet_id))
        return false;
    if (level >= ProtocolLevel._5 && ack_has_v5_tail(pkt))
    {
        if (!put!ubyte(sink, pkt.reason_code))
            return false;
        if (!put_property_block(sink, pkt.properties))
            return false;
    }
    return true;
}


// SUBSCRIBE options byte: [bits 1-0: QoS] [bit 2: NoLocal*] [bit 3: RetainAsPublished*] [bits 5-4: RetainHandling*] [bits 7-6: reserved].
// Starred fields are v5-only and must be zero in v3.
enum SubscribeOption : ubyte
{
    qos_mask                = 0x03,
    no_local                = 1 << 2,
    retain_as_published     = 1 << 3,
    retain_handling_mask    = 0x30,
    retain_handling_shift   = 4,
}

struct SubscribePacket
{
    ushort packet_id;
    const(ubyte)[] properties;       // v5 raw property block; empty in v3
    const(ubyte)[] subscriptions;    // payload: sequence of (string filter, ubyte options)
}

bool decode_subscribe(ref const(ubyte)[] body, ubyte flags, ProtocolLevel level, ref SubscribePacket pkt)
{
    if (flags != 0x02) return false;     // reserved flags must be 0010

    if (!take!ushort(body, pkt.packet_id))
        return false;
    if (pkt.packet_id == 0)
        return false;

    if (level >= ProtocolLevel._5)
        if (!take_property_block(body, pkt.properties))
            return false;

    if (body.length == 0) return false;  // must contain at least one subscription
    pkt.subscriptions = body[];
    body = body[$ .. $];

    const(ubyte)[] p = pkt.subscriptions;
    ubyte opts_mask = (level >= ProtocolLevel._5) ? 0xC0 : 0xFC;
    while (p.length > 0)
    {
        const(char)[] filter;
        if (!take_string(p, filter))
            return false;
        if (filter.length == 0)
            return false;
        ubyte opts;
        if (!take!ubyte(p, opts))
            return false;
        if (opts & opts_mask) return false;          // reserved bits set
        if ((opts & SubscribeOption.qos_mask) > 2)
            return false;
        ubyte rh = (opts & SubscribeOption.retain_handling_mask) >> SubscribeOption.retain_handling_shift;
        if (rh > 2)
            return false;
    }
    return true;
}

private size_t subscribe_body_size(ref const SubscribePacket pkt, ProtocolLevel level)
{
    size_t s = 2;
    if (level >= ProtocolLevel._5)
        s += property_block_size(pkt.properties);
    s += pkt.subscriptions.length;
    return s;
}

size_t subscribe_size(ref const SubscribePacket pkt, ProtocolLevel level)
{
    size_t body = subscribe_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_subscribe(ref ubyte[] sink, ref const SubscribePacket pkt, ProtocolLevel level)
{
    if (pkt.subscriptions.length == 0)
        return false;

    size_t body = subscribe_body_size(pkt, level);
    if (!encode_header(sink, PacketType.Subscribe, 0x02, cast(uint)body))
        return false;
    if (!put!ushort(sink, pkt.packet_id))
        return false;
    if (level >= ProtocolLevel._5)
        if (!put_property_block(sink, pkt.properties))
            return false;
    if (sink.length < pkt.subscriptions.length)
        return false;
    sink[0 .. pkt.subscriptions.length] = pkt.subscriptions;
    sink = sink[pkt.subscriptions.length .. $];
    return true;
}


struct SubAckPacket
{
    ushort packet_id;
    const(ubyte)[] properties;     // v5 raw property block; empty in v3
    const(ubyte)[] reason_codes;   // one per subscription
}

bool decode_suback(ref const(ubyte)[] body, ubyte flags, ProtocolLevel level, ref SubAckPacket pkt)
{
    if (flags != 0)
        return false;
    if (!take!ushort(body, pkt.packet_id))
        return false;
    if (level >= ProtocolLevel._5)
        if (!take_property_block(body, pkt.properties))
            return false;
    if (body.length == 0) return false;  // must contain at least one reason code
    pkt.reason_codes = body[];
    body = body[$ .. $];
    return true;
}

private size_t suback_body_size(ref const SubAckPacket pkt, ProtocolLevel level)
{
    size_t s = 2;
    if (level >= ProtocolLevel._5)
        s += property_block_size(pkt.properties);
    s += pkt.reason_codes.length;
    return s;
}

size_t suback_size(ref const SubAckPacket pkt, ProtocolLevel level)
{
    size_t body = suback_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_suback(ref ubyte[] sink, ref const SubAckPacket pkt, ProtocolLevel level)
{
    if (pkt.reason_codes.length == 0)
        return false;
    size_t body = suback_body_size(pkt, level);
    if (!encode_header(sink, PacketType.SubAck, 0, cast(uint)body))
        return false;
    if (!put!ushort(sink, pkt.packet_id))
        return false;
    if (level >= ProtocolLevel._5)
        if (!put_property_block(sink, pkt.properties))
            return false;
    if (sink.length < pkt.reason_codes.length)
        return false;
    sink[0 .. pkt.reason_codes.length] = pkt.reason_codes;
    sink = sink[pkt.reason_codes.length .. $];
    return true;
}


struct UnsubscribePacket
{
    ushort packet_id;
    const(ubyte)[] properties;       // v5 raw property block; empty in v3
    const(ubyte)[] topic_filters;    // payload: sequence of length-prefixed strings
}

bool decode_unsubscribe(ref const(ubyte)[] body, ubyte flags, ProtocolLevel level, ref UnsubscribePacket pkt)
{
    if (flags != 0x02)
        return false;
    if (!take!ushort(body, pkt.packet_id))
        return false;
    if (pkt.packet_id == 0)
        return false;
    if (level >= ProtocolLevel._5)
        if (!take_property_block(body, pkt.properties))
            return false;
    if (body.length == 0) return false;  // must contain at least one filter
    pkt.topic_filters = body[];
    body = body[$ .. $];

    const(ubyte)[] p = pkt.topic_filters;
    while (p.length > 0)
    {
        const(char)[] filter;
        if (!take_string(p, filter))
            return false;
        if (filter.length == 0)
            return false;
    }
    return true;
}

private size_t unsubscribe_body_size(ref const UnsubscribePacket pkt, ProtocolLevel level)
{
    size_t s = 2;
    if (level >= ProtocolLevel._5)
        s += property_block_size(pkt.properties);
    s += pkt.topic_filters.length;
    return s;
}

size_t unsubscribe_size(ref const UnsubscribePacket pkt, ProtocolLevel level)
{
    size_t body = unsubscribe_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_unsubscribe(ref ubyte[] sink, ref const UnsubscribePacket pkt, ProtocolLevel level)
{
    if (pkt.topic_filters.length == 0)
        return false;
    size_t body = unsubscribe_body_size(pkt, level);
    if (!encode_header(sink, PacketType.Unsubscribe, 0x02, cast(uint)body))
        return false;
    if (!put!ushort(sink, pkt.packet_id))
        return false;
    if (level >= ProtocolLevel._5)
        if (!put_property_block(sink, pkt.properties))
            return false;
    if (sink.length < pkt.topic_filters.length)
        return false;
    sink[0 .. pkt.topic_filters.length] = pkt.topic_filters;
    sink = sink[pkt.topic_filters.length .. $];
    return true;
}



struct UnsubAckPacket
{
    ushort packet_id;
    const(ubyte)[] properties;     // v5 raw property block; empty in v3
    const(ubyte)[] reason_codes;   // one per topic filter (v5 only; absent in v3)
}

bool decode_unsuback(ref const(ubyte)[] body, ubyte flags, ProtocolLevel level, ref UnsubAckPacket pkt)
{
    if (flags != 0)
        return false;
    if (!take!ushort(body, pkt.packet_id))
        return false;
    if (level >= ProtocolLevel._5)
    {
        if (!take_property_block(body, pkt.properties))
            return false;
        if (body.length == 0) return false;     // v5 must contain reason codes
        pkt.reason_codes = body[];
        body = body[$ .. $];
    }
    return body.length == 0;
}

private size_t unsuback_body_size(ref const UnsubAckPacket pkt, ProtocolLevel level)
{
    size_t s = 2;
    if (level >= ProtocolLevel._5)
    {
        s += property_block_size(pkt.properties);
        s += pkt.reason_codes.length;
    }
    return s;
}

size_t unsuback_size(ref const UnsubAckPacket pkt, ProtocolLevel level)
{
    size_t body = unsuback_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_unsuback(ref ubyte[] sink, ref const UnsubAckPacket pkt, ProtocolLevel level)
{
    if (level >= ProtocolLevel._5 && pkt.reason_codes.length == 0)
        return false;
    size_t body = unsuback_body_size(pkt, level);
    if (!encode_header(sink, PacketType.UnsubAck, 0, cast(uint)body))
        return false;
    if (!put!ushort(sink, pkt.packet_id))
        return false;
    if (level >= ProtocolLevel._5)
    {
        if (!put_property_block(sink, pkt.properties))
            return false;
        if (sink.length < pkt.reason_codes.length)
            return false;
        sink[0 .. pkt.reason_codes.length] = pkt.reason_codes;
        sink = sink[pkt.reason_codes.length .. $];
    }
    return true;
}


// PINGREQ / PINGRESP carry no body.
bool decode_pingreq(ref const(ubyte)[] body, ubyte flags)
{
    return flags == 0 && body.length == 0;
}

bool decode_pingresp(ref const(ubyte)[] body, ubyte flags)
{
    return flags == 0 && body.length == 0;
}

size_t pingreq_size()  pure { return 2; }
size_t pingresp_size() pure { return 2; }

bool encode_pingreq(ref ubyte[] sink)
{
    return encode_header(sink, PacketType.PingReq, 0, 0);
}

bool encode_pingresp(ref ubyte[] sink)
{
    return encode_header(sink, PacketType.PingResp, 0, 0);
}


struct DisconnectPacket
{
    ubyte reason_code;             // v5 only; 0 (NormalDisconnection) implied in v3
    const(ubyte)[] properties;     // v5 raw property block; empty in v3
}

bool decode_disconnect(ref const(ubyte)[] body, ubyte flags, ProtocolLevel level, ref DisconnectPacket pkt)
{
    if (flags != 0)
        return false;
    if (level < ProtocolLevel._5)
        return body.length == 0;

    // v5: reason code and properties both optional (Success implied if absent).
    if (body.length == 0)
        return true;
    if (!take!ubyte(body, pkt.reason_code))
        return false;
    if (body.length > 0)
        if (!take_property_block(body, pkt.properties))
            return false;
    return body.length == 0;
}

private bool disconnect_has_v5_tail(ref const DisconnectPacket pkt)
{
    return pkt.reason_code != 0 || pkt.properties.length > 0;
}

private size_t disconnect_body_size(ref const DisconnectPacket pkt, ProtocolLevel level)
{
    if (level < ProtocolLevel._5)
        return 0;
    if (!disconnect_has_v5_tail(pkt))
        return 0;
    return 1 + property_block_size(pkt.properties);
}

size_t disconnect_size(ref const DisconnectPacket pkt, ProtocolLevel level)
{
    size_t body = disconnect_body_size(pkt, level);
    return header_size(cast(uint)body) + body;
}

bool encode_disconnect(ref ubyte[] sink, ref const DisconnectPacket pkt, ProtocolLevel level)
{
    size_t body = disconnect_body_size(pkt, level);
    if (!encode_header(sink, PacketType.Disconnect, 0, cast(uint)body))
        return false;
    if (level >= ProtocolLevel._5 && disconnect_has_v5_tail(pkt))
    {
        if (!put!ubyte(sink, pkt.reason_code))
            return false;
        if (!put_property_block(sink, pkt.properties))
            return false;
    }
    return true;
}


// AUTH is v5-only.
struct AuthPacket
{
    ubyte reason_code;
    const(ubyte)[] properties;
}

bool decode_auth(ref const(ubyte)[] body, ubyte flags, ref AuthPacket pkt)
{
    if (flags != 0)
        return false;

    // Both fields optional; absent means Success and no properties.
    if (body.length == 0)
        return true;
    if (!take!ubyte(body, pkt.reason_code))
        return false;
    if (body.length > 0)
        if (!take_property_block(body, pkt.properties))
            return false;
    return body.length == 0;
}

private bool auth_has_tail(ref const AuthPacket pkt)
{
    return pkt.reason_code != 0 || pkt.properties.length > 0;
}

private size_t auth_body_size(ref const AuthPacket pkt)
{
    if (!auth_has_tail(pkt))
        return 0;
    return 1 + property_block_size(pkt.properties);
}

size_t auth_size(ref const AuthPacket pkt)
{
    size_t body = auth_body_size(pkt);
    return header_size(cast(uint)body) + body;
}

bool encode_auth(ref ubyte[] sink, ref const AuthPacket pkt)
{
    size_t body = auth_body_size(pkt);
    if (!encode_header(sink, PacketType.Auth, 0, cast(uint)body))
        return false;
    if (auth_has_tail(pkt))
    {
        if (!put!ubyte(sink, pkt.reason_code))
            return false;
        if (!put_property_block(sink, pkt.properties))
            return false;
    }
    return true;
}


version (unittest)
{
    private FixedHeader decode_one_header(ref const(ubyte)[] data)
    {
        FixedHeader hdr;
        assert(decode_header(data, hdr));
        return hdr;
    }
}

unittest
{
    {
        // VBI round trip across boundaries
        static immutable uint[8] cases = [0, 1, 127, 128, 16383, 16384, 2097151, 268435455];
        static immutable size_t[8] expected = [1, 1, 1, 2, 2, 3, 3, 4];
        foreach (i, v; cases)
        {
            ubyte[5] buf;
            ubyte[] sink = buf[];
            assert(put_vbi(sink, v));
            size_t written = buf.length - sink.length;
            assert(written == expected[i]);
            assert(vbi_size(v) == expected[i]);

            const(ubyte)[] read = buf[0 .. written];
            uint got;
            assert(take_vbi(read, got));
            assert(read.length == 0);
            assert(got == v);
        }

        ubyte[5] buf;
        ubyte[] sink = buf[];
        assert(!put_vbi(sink, 268435456));

        // malformed: 5-byte VBI (the 5th byte would push the value past 28 bits)
        static immutable ubyte[5] bad = [0x80, 0x80, 0x80, 0x80, 0x01];
        const(ubyte)[] read = bad[];
        uint got;
        assert(!take_vbi(read, got));
    }

    {
        // string and binary length-prefix round trip
        static immutable ubyte[4] bin = [1, 2, 3, 4];
        ubyte[64] buf;
        ubyte[] sink = buf[];
        assert(put_string(sink, "hello"));
        assert(put_binary(sink, bin[]));
        size_t written = buf.length - sink.length;
        assert(written == 2 + 5 + 2 + 4);

        const(ubyte)[] read = buf[0 .. written];
        const(char)[] s;
        const(ubyte)[] b;
        assert(take_string(read, s));
        assert(s == "hello");
        assert(take_binary(read, b));
        assert(b == bin[]);
        assert(read.length == 0);

        static immutable ubyte[4] trunc = [0x00, 0x05, 'h', 'i'];   // claims 5 bytes, only 2 present
        const(ubyte)[] trunc_slice = trunc[];
        const(char)[] s2;
        assert(!take_string(trunc_slice, s2));
    }

    {
        // fixed header round trip
        ubyte[8] buf;
        ubyte[] sink = buf[];
        assert(encode_header(sink, PacketType.Publish, 0x03, 100));
        assert(buf[0] == 0x33);                         // (3<<4)|0x03
        assert(buf[1] == 100);                           // VBI(100) == single byte

        const(ubyte)[] data = buf[];
        FixedHeader hdr;
        assert(decode_header(data, hdr));
        assert(hdr.type == PacketType.Publish);
        assert(hdr.flags == 0x03);
        assert(hdr.body_length == 100);

        static immutable ubyte[2] zero_bytes = [0x00, 0x00];
        const(ubyte)[] zero = zero_bytes[];
        FixedHeader h2;
        assert(!decode_header(zero, h2));
    }

    {
        // PINGREQ / PINGRESP
        ubyte[4] buf;
        ubyte[] sink = buf[0 .. 2];
        assert(encode_pingreq(sink));
        assert(buf[0] == 0xC0 && buf[1] == 0x00);

        const(ubyte)[] data = buf[0 .. 2];
        FixedHeader hdr = decode_one_header(data);
        assert(hdr.type == PacketType.PingReq);
        assert(hdr.body_length == 0);
        assert(decode_pingreq(data, hdr.flags));

        sink = buf[0 .. 2];
        assert(encode_pingresp(sink));
        assert(buf[0] == 0xD0 && buf[1] == 0x00);
    }

    {
        // PUBLISH QoS 0 v3
        PublishPacket pkt;
        pkt.topic = "sensor/temp";
        pkt.payload = cast(const(ubyte)[])"23.5";

        size_t sz = publish_size(pkt, ProtocolLevel._3_1_1);
        ubyte[64] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_publish(sink, pkt, ProtocolLevel._3_1_1));
        assert(sink.length == 0);

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        assert(hdr.type == PacketType.Publish);
        const(ubyte)[] body = data[0 .. hdr.body_length];

        PublishPacket got;
        assert(decode_publish(body, hdr.flags, ProtocolLevel._3_1_1, got));
        assert(body.length == 0);
        assert(got.topic == pkt.topic);
        assert(got.qos == 0);
        assert(!got.dup);
        assert(!got.retain);
        assert(got.payload == pkt.payload);
    }

    {
        // PUBLISH QoS 2 retain+dup v5 with properties
        static immutable ubyte[] props = [
            Property.TopicAlias, 0x00, 0x05,                          // alias = 5
            Property.MessageExpiryInterval, 0, 0, 0, 60,              // expiry = 60s
        ];
        PublishPacket pkt;
        pkt.topic = "x";
        pkt.qos = 2;
        pkt.retain = true;
        pkt.dup = true;
        pkt.packet_id = 42;
        pkt.properties = props;
        pkt.payload = cast(const(ubyte)[])"payload bytes";

        size_t sz = publish_size(pkt, ProtocolLevel._5);
        ubyte[128] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_publish(sink, pkt, ProtocolLevel._5));
        assert(sink.length == 0);

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        const(ubyte)[] body = data[0 .. hdr.body_length];

        PublishPacket got;
        assert(decode_publish(body, hdr.flags, ProtocolLevel._5, got));
        assert(got.qos == 2);
        assert(got.dup);
        assert(got.retain);
        assert(got.packet_id == 42);
        assert(got.properties == props);
        assert(got.payload == pkt.payload);

        // PUBLISH with DUP and qos 0 is malformed
        pkt.qos = 0;
        sink = buf[];
        assert(!encode_publish(sink, pkt, ProtocolLevel._5));
    }

    {
        // CONNECT v3.1.1 minimal
        ConnectPacket pkt;
        pkt.protocol_level = ProtocolLevel._3_1_1;
        pkt.clean_start = true;
        pkt.keep_alive = 60;
        pkt.client_id = "client-1";

        size_t sz = connect_size(pkt);
        ubyte[64] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_connect(sink, pkt));
        assert(sink.length == 0);

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        const(ubyte)[] body = data[0 .. hdr.body_length];

        ConnectPacket got;
        assert(decode_connect(body, hdr.flags, got));
        assert(got.protocol_level == ProtocolLevel._3_1_1);
        assert(got.clean_start);
        assert(got.keep_alive == 60);
        assert(got.client_id == "client-1");
        assert(!got.has_will);
        assert(!got.has_username);
        assert(!got.has_password);
    }

    {
        // CONNECT v3.1.1 with will + credentials
        ConnectPacket pkt;
        pkt.protocol_level = ProtocolLevel._3_1_1;
        pkt.clean_start = false;
        pkt.keep_alive = 30;
        pkt.client_id = "c";
        pkt.has_will = true;
        pkt.will_qos = 1;
        pkt.will_retain = true;
        pkt.will_topic = "lwt";
        pkt.will_payload = cast(const(ubyte)[])"down";
        pkt.has_username = true;
        pkt.username = "user";
        pkt.has_password = true;
        pkt.password = cast(const(ubyte)[])"pass";

        size_t sz = connect_size(pkt);
        ubyte[128] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_connect(sink, pkt));

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        const(ubyte)[] body = data[0 .. hdr.body_length];

        ConnectPacket got;
        assert(decode_connect(body, hdr.flags, got));
        assert(got.has_will);
        assert(got.will_qos == 1);
        assert(got.will_retain);
        assert(got.will_topic == "lwt");
        assert(got.will_payload == cast(const(ubyte)[])"down");
        assert(got.username == "user");
        assert(got.password == cast(const(ubyte)[])"pass");

        // v3.1.1 rejects password without username
        pkt.has_username = false;
        sink = buf[];
        assert(!encode_connect(sink, pkt));
    }

    {
        // CONNECT v5 with properties
        static immutable ubyte[] props = [
            Property.SessionExpiryInterval, 0, 0, 0x01, 0x2C,         // 300s
            Property.ReceiveMaximum, 0x00, 0x10,                       // 16
        ];
        ConnectPacket pkt;
        pkt.protocol_level = ProtocolLevel._5;
        pkt.clean_start = true;
        pkt.keep_alive = 60;
        pkt.properties = props;
        pkt.client_id = "v5-client";

        size_t sz = connect_size(pkt);
        ubyte[128] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_connect(sink, pkt));

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        const(ubyte)[] body = data[0 .. hdr.body_length];

        ConnectPacket got;
        assert(decode_connect(body, hdr.flags, got));
        assert(got.protocol_level == ProtocolLevel._5);
        assert(got.properties == props);
        assert(got.client_id == "v5-client");
    }

    {
        // CONNACK v3.1.1 and v5
        ubyte[64] buf;
        {
            ConnAckPacket pkt;
            pkt.session_present = true;
            pkt.reason_code = 0;
            size_t sz = connack_size(pkt, ProtocolLevel._3_1_1);
            ubyte[] sink = buf[0 .. sz];
            assert(encode_connack(sink, pkt, ProtocolLevel._3_1_1));

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            ConnAckPacket got;
            assert(decode_connack(body, hdr.flags, ProtocolLevel._3_1_1, got));
            assert(got.session_present);
            assert(got.reason_code == 0);
        }
        {
            static immutable ubyte[] props = [Property.MaximumQoS, 0x01];
            ConnAckPacket pkt;
            pkt.session_present = false;
            pkt.reason_code = ReasonCode.Success;
            pkt.properties = props;
            size_t sz = connack_size(pkt, ProtocolLevel._5);
            ubyte[] sink = buf[0 .. sz];
            assert(encode_connack(sink, pkt, ProtocolLevel._5));

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            ConnAckPacket got;
            assert(decode_connack(body, hdr.flags, ProtocolLevel._5, got));
            assert(!got.session_present);
            assert(got.properties == props);
        }
    }

    {
        // ACK family v3 minimal and v5 abbreviated and v5 full
        ubyte[32] buf;

        {
            // v3.1.1 PUBACK is just packet_id (4 bytes total: 2 header + 2 body)
            AckPacket pkt;
            pkt.packet_id = 7;
            size_t sz = ack_size(pkt, ProtocolLevel._3_1_1);
            assert(sz == 4);
            ubyte[] sink = buf[0 .. sz];
            assert(encode_ack(sink, PacketType.PubAck, pkt, ProtocolLevel._3_1_1));

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            AckPacket got;
            assert(decode_ack(body, hdr.flags, PacketType.PubAck, ProtocolLevel._3_1_1, got));
            assert(got.packet_id == 7);
            assert(got.reason_code == 0);
        }

        {
            // v5 PUBACK with Success + no properties must use the short form (packet_id only).
            AckPacket pkt;
            pkt.packet_id = 7;
            size_t sz = ack_size(pkt, ProtocolLevel._5);
            assert(sz == 4);
            ubyte[] sink = buf[0 .. sz];
            assert(encode_ack(sink, PacketType.PubAck, pkt, ProtocolLevel._5));

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            AckPacket got;
            assert(decode_ack(body, hdr.flags, PacketType.PubAck, ProtocolLevel._5, got));
            assert(got.packet_id == 7);
            assert(got.reason_code == 0);
        }

        {
            // v5 PUBREL with reason + properties; PUBREL fixed-header flags must be 0b0010.
            static immutable ubyte[] props = [];
            AckPacket pkt;
            pkt.packet_id = 9;
            pkt.reason_code = ReasonCode.PacketIdentifierNotFound;
            pkt.properties = props;
            size_t sz = ack_size(pkt, ProtocolLevel._5);
            ubyte[] sink = buf[0 .. sz];
            assert(encode_ack(sink, PacketType.PubRel, pkt, ProtocolLevel._5));
            assert((buf[0] & 0x0F) == 0x02);

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            assert(hdr.flags == 0x02);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            AckPacket got;
            assert(decode_ack(body, hdr.flags, PacketType.PubRel, ProtocolLevel._5, got));
            assert(got.packet_id == 9);
            assert(got.reason_code == ReasonCode.PacketIdentifierNotFound);
        }
    }

    {
        // SUBSCRIBE round trip
        // filter "a/+" with qos=1; filter "b/#" with qos=0 + NoLocal
        static immutable ubyte[] subs = [
            0x00, 0x03, 'a', '/', '+', 0x01,
            0x00, 0x03, 'b', '/', '#', 0x04,
        ];
        SubscribePacket pkt;
        pkt.packet_id = 100;
        pkt.subscriptions = subs;

        size_t sz = subscribe_size(pkt, ProtocolLevel._5);
        ubyte[64] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_subscribe(sink, pkt, ProtocolLevel._5));

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        assert(hdr.type == PacketType.Subscribe);
        assert(hdr.flags == 0x02);
        const(ubyte)[] body = data[0 .. hdr.body_length];
        SubscribePacket got;
        assert(decode_subscribe(body, hdr.flags, ProtocolLevel._5, got));
        assert(got.packet_id == 100);
        assert(got.subscriptions == subs);

        // reserved subscribe-option bits set: decode must reject
        static immutable ubyte[] bad = [
            0x00, 0x01, 'x', 0xC0,
        ];
        SubscribePacket bp;
        bp.packet_id = 1;
        bp.subscriptions = bad;
        sink = buf[];
        assert(encode_subscribe(sink, bp, ProtocolLevel._5));   // encoder doesn't peek at payload bytes
        const(ubyte)[] bdata = buf[0 .. subscribe_size(bp, ProtocolLevel._5)];
        FixedHeader bhdr = decode_one_header(bdata);
        const(ubyte)[] bbody = bdata[0 .. bhdr.body_length];
        SubscribePacket bgot;
        assert(!decode_subscribe(bbody, bhdr.flags, ProtocolLevel._5, bgot));
    }

    {
        // SUBACK round trip
        static immutable ubyte[] codes = [0x00, 0x01, 0x80];
        SubAckPacket pkt;
        pkt.packet_id = 100;
        pkt.reason_codes = codes;

        size_t sz = suback_size(pkt, ProtocolLevel._3_1_1);
        ubyte[32] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_suback(sink, pkt, ProtocolLevel._3_1_1));

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        const(ubyte)[] body = data[0 .. hdr.body_length];
        SubAckPacket got;
        assert(decode_suback(body, hdr.flags, ProtocolLevel._3_1_1, got));
        assert(got.packet_id == 100);
        assert(got.reason_codes == codes);
    }

    {
        // UNSUBSCRIBE round trip
        static immutable ubyte[] filters = [
            0x00, 0x03, 'a', '/', 'b',
            0x00, 0x01, 'c',
        ];
        UnsubscribePacket pkt;
        pkt.packet_id = 200;
        pkt.topic_filters = filters;

        size_t sz = unsubscribe_size(pkt, ProtocolLevel._3_1_1);
        ubyte[32] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_unsubscribe(sink, pkt, ProtocolLevel._3_1_1));

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        assert(hdr.flags == 0x02);
        const(ubyte)[] body = data[0 .. hdr.body_length];
        UnsubscribePacket got;
        assert(decode_unsubscribe(body, hdr.flags, ProtocolLevel._3_1_1, got));
        assert(got.packet_id == 200);
        assert(got.topic_filters == filters);
    }

    {
        // UNSUBACK round trip
        {
            // v3.1.1: no reason codes
            UnsubAckPacket pkt;
            pkt.packet_id = 200;
            size_t sz = unsuback_size(pkt, ProtocolLevel._3_1_1);
            assert(sz == 4);
            ubyte[8] buf;
            ubyte[] sink = buf[0 .. sz];
            assert(encode_unsuback(sink, pkt, ProtocolLevel._3_1_1));

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            UnsubAckPacket got;
            assert(decode_unsuback(body, hdr.flags, ProtocolLevel._3_1_1, got));
            assert(got.packet_id == 200);
            assert(got.reason_codes.length == 0);
        }
        {
            // v5: reason codes required
            static immutable ubyte[] codes = [0x00, 0x11];
            UnsubAckPacket pkt;
            pkt.packet_id = 200;
            pkt.reason_codes = codes;
            size_t sz = unsuback_size(pkt, ProtocolLevel._5);
            ubyte[16] buf;
            ubyte[] sink = buf[0 .. sz];
            assert(encode_unsuback(sink, pkt, ProtocolLevel._5));

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            UnsubAckPacket got;
            assert(decode_unsuback(body, hdr.flags, ProtocolLevel._5, got));
            assert(got.reason_codes == codes);
        }
    }

    {
        // DISCONNECT -- v3 has no body, v5 may omit reason if Success
        ubyte[16] buf;
        {
            // v3.1.1 empty body
            DisconnectPacket pkt;
            size_t sz = disconnect_size(pkt, ProtocolLevel._3_1_1);
            assert(sz == 2);
            ubyte[] sink = buf[0 .. sz];
            assert(encode_disconnect(sink, pkt, ProtocolLevel._3_1_1));
            assert(buf[0] == 0xE0 && buf[1] == 0x00);

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            DisconnectPacket got;
            assert(decode_disconnect(body, hdr.flags, ProtocolLevel._3_1_1, got));
        }
        {
            // v5 with reason and empty props
            DisconnectPacket pkt;
            pkt.reason_code = ReasonCode.AdministrativeAction;
            size_t sz = disconnect_size(pkt, ProtocolLevel._5);
            ubyte[] sink = buf[0 .. sz];
            assert(encode_disconnect(sink, pkt, ProtocolLevel._5));

            const(ubyte)[] data = buf[0 .. sz];
            FixedHeader hdr = decode_one_header(data);
            const(ubyte)[] body = data[0 .. hdr.body_length];
            DisconnectPacket got;
            assert(decode_disconnect(body, hdr.flags, ProtocolLevel._5, got));
            assert(got.reason_code == ReasonCode.AdministrativeAction);
        }
    }

    {
        // AUTH
        static immutable ubyte[] props = [
            Property.AuthenticationMethod, 0x00, 0x05, 'S', 'C', 'R', 'A', 'M',
        ];
        AuthPacket pkt;
        pkt.reason_code = ReasonCode.ContinueAuthentication;
        pkt.properties = props;
        size_t sz = auth_size(pkt);
        ubyte[32] buf;
        ubyte[] sink = buf[0 .. sz];
        assert(encode_auth(sink, pkt));

        const(ubyte)[] data = buf[0 .. sz];
        FixedHeader hdr = decode_one_header(data);
        const(ubyte)[] body = data[0 .. hdr.body_length];
        AuthPacket got;
        assert(decode_auth(body, hdr.flags, got));
        assert(got.reason_code == ReasonCode.ContinueAuthentication);
        assert(got.properties == props);
    }
}
