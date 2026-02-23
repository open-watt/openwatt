module protocol.mqtt.client;

import urt.array : duplicate, empty;
import urt.log;
import urt.mem;
import urt.string;
import urt.time;

import manager;
import manager.base;

import protocol.mqtt.broker;
import protocol.mqtt.util;

import router.stream;

//version = DebugMQTTClient;

nothrow @nogc:


enum MQTTPacketType : byte
{
    Unknown = -1,
    Connect = 1,
    ConnAck = 2,
    Publish = 3,
    PubAck = 4,
    PubRec = 5,
    PubRel = 6,
    PubComp = 7,
    Subscribe = 8,
    SubAck = 9,
    Unsubscribe = 10,
    UnsubAck = 11,
    PingReq = 12,
    PingResp = 13,
    Disconnect = 14,
    Auth = 15
}

enum MQTTProperties : ubyte
{
    PayloadFormatIndicator          = 0x01, // Byte - PUBLISH, Will Properties
    MessageExpiryInterval           = 0x02, // Four Byte Integer - PUBLISH, Will Properties
    ContentType                     = 0x03, // UTF-8 Encoded String - PUBLISH, Will Properties
    ResponseTopic                   = 0x08, // UTF-8 Encoded String - PUBLISH, Will Properties
    CorrelationData                 = 0x09, // Binary Data - PUBLISH, Will Properties
    SubscriptionIdentifier          = 0x0B, // Variable Byte Integer - PUBLISH, SUBSCRIBE
    SessionExpiryInterval           = 0x11, // Four Byte Integer - CONNECT, CONNACK, DISCONNECT
    AssignedClientIdentifier        = 0x12, // UTF-8 Encoded String - CONNACK
    AuthenticationMethod            = 0x15, // UTF-8 Encoded String - CONNECT, CONNACK, AUTH
    ServerKeepAlive                 = 0x13, // Two Byte Integer - CONNACK
    AuthenticationData              = 0x16, // Binary Data - CONNECT, CONNACK, AUTH
    RequestProblemInformation       = 0x17, // Byte - CONNECT
    WillDelayInterval               = 0x18, // Four Byte Integer - Will Properties
    RequestResponseInformation      = 0x19, // Byte - CONNECT
    ResponseInformation             = 0x1A, // UTF-8 Encoded String - CONNACK
    ServerReference                 = 0x1C, // UTF-8 Encoded String - CONNACK, DISCONNECT
    ReasonString                    = 0x1F, // UTF-8 Encoded String - CONNACK, PUBACK, PUBREC, PUBREL, PUBCOMP, SUBACK, UNSUBACK, DISCONNECT, AUTH
    ReceiveMaximum                  = 0x21, // Two Byte Integer - CONNECT, CONNACK
    TopicAliasMaximum               = 0x22, // Two Byte Integer - CONNECT, CONNACK
    TopicAlias                      = 0x23, // Two Byte Integer - PUBLISH
    MaximumQoS                      = 0x24, // Byte - CONNACK
    RetainAvailable                 = 0x25, // Byte - CONNACK
    UserProperty                    = 0x26, // UTF-8 String Pair - CONNECT, CONNACK, PUBLISH, Will Properties, PUBACK, PUBREC, PUBREL, PUBCOMP, SUBSCRIBE, SUBACK, UNSUBSCRIBE, UNSUBACK, DISCONNECT, AUTH
    MaximumPacketSize               = 0x27, // Four Byte Integer - CONNECT, CONNACK
    WildcardSubscriptionAvailable   = 0x28, // Byte - CONNACK
    SubscriptionIdentifierAvailable = 0x29, // Byte - CONNACK
    SharedSubscriptionAvailable     = 0x2A, // Byte - CONNACK
}

struct MQTTClient
{
nothrow @nogc:

    enum ConnectionState
    {
        WaitingIntroduction = 0,
        WaitingIntroductionAck,
        Active,
        Terminated
    }

    MQTTBroker broker;
    Stream stream;
    MQTTSession* session;

    MonoTime last_contact_time;
    ConnectionState state = ConnectionState.WaitingIntroduction;
    ubyte protocol_level;
    ubyte conn_flags;
    ushort keep_alive_time;

    this(MQTTBroker broker, Stream stream)
    {
        this.broker = broker;
        this.stream = stream;
        stream.subscribe(&stream_signal);
        last_contact_time = getTime();
    }

    void terminate()
    {
        // close the stream
        if (stream)
        {
            stream.unsubscribe(&stream_signal);
            stream.destroy();
            stream = null;
        }

        if (session.will_delay == 0)
            broker.send_lwt(*session);
        if (session.session_expiry_interval == 0)
            broker.destroy_session(*session);
        session.client = null;

        state = ConnectionState.Terminated;
    }

    void publish(const char[] topic, const ubyte[] payload, ubyte qos = 0, bool retain = false, bool dup = false)
    {
        assert(qos <= 2);

        ubyte[258] buffer;
        buffer[0] = (MQTTPacketType.Publish << 4) | (dup ? 8 : 0) | cast(ubyte)(qos << 1) | (retain ? 1 : 0);
        ubyte[] msg = buffer[2..$];
        msg.put(topic);
        if (qos > 0)
        {
            msg.put(session.packet_id);
            session.packet_id += 2;
        }
        msg.put(payload);
        buffer[1] = cast(ubyte)(buffer.length - msg.length - 2);
        stream.write(buffer[0 .. buffer.length - msg.length]);

        // TODO: retain message for qos 1,2...

        version (DebugMQTTClient)
            writeInfo("MQTT - Sent PUBLISH to ", session.identifier[] ,": ", qos > 0 ? session.packet_id : 0, ", ", topic, " = ", cast(char[])payload, " (qos: ", qos, dup ? " DUP" : "", retain ? " RET" : "", ")");
    }

    void subscribe(ubyte requested_qos, string[] topics...)
    {
        assert(requested_qos <= 2);

        ubyte[258] buffer;
        buffer[0] = (MQTTPacketType.Subscribe << 4) | 2; // always QoS 1
        ubyte[] msg = buffer[2..$];
        msg.put(session.packet_id); session.packet_id += 2;
        foreach (topic; topics)
        {
            msg.put(topic);
            msg.put(requested_qos);
        }
        buffer[1] = cast(ubyte)(buffer.length - msg.length - 2);
        stream.write(buffer[0 .. buffer.length - msg.length]);

        // TODO: retain message for qos 1...
        version (DebugMQTTClient)
            writeInfo("MQTT - Sent SUBSCRIBE to ", session.identifier[] ,": ", session.packet_id, ", ", topics, " (req qos: ", requested_qos ,")");
    }

    bool update()
    {
        if (!stream || !stream.running)
            return false;

        MonoTime now = getTime();

        // read data from the client stream
        ubyte[1024] buffer;
        ptrdiff_t bytes = stream.read(buffer);
        if (bytes < 0)
            return false; // connection error?

        const(ubyte)[] packet = buffer[0 .. bytes];
        if (bytes == 0)
        {
            if (state == ConnectionState.WaitingIntroduction && now - last_contact_time >= 1000.msecs)
            {
                // if no introduction was offered in reasonable time, assume this isn't an mqtt client and terminate
                return false;
            }
            else if (keep_alive_time != 0 && now - last_contact_time >= (keep_alive_time*3/2).seconds) // x*3/2 == x*1.5
            {
                // if keepAlive is enabled and we haven't received a control packet in the allotted time
                return false;
            }
            return true;
        }
        last_contact_time = now;

        while (!packet.empty)
        {
            // assure we have enough data to read the packet header
            if (packet.length < 5 &&
                (packet.length < 2 ||
                (packet.ptr[1] >= 128 && (packet.length < 3 ||
                (packet.ptr[2] >= 128 && (packet.length < 4 ||
                 packet.ptr[3] >= 128))))))
            {
                buffer[0 .. packet.length] = packet[];
                ptrdiff_t r = stream.read(buffer[packet.length .. $]);
                if (r < 0)
                    return false; // connection error?
                packet = buffer[0 .. packet.length + r];
            }

            // parse and validate the packet header
            ubyte control = packet.take!ubyte;
            uint message_len = packet.take_var_int;
            if (message_len == -1)
                return false;

            // take the message
            const(ubyte)[] message;
            if (message_len <= packet.length)
                message = packet.take(message_len);
            else
            {
                // if the message is small enough to fit into the stack buffer, well just shuffle the data back to the start of the buffer, otherwise allocate
                assert(message_len <= buffer.length && packet.ptr >= buffer.ptr + buffer.sizeof/2, "TODO: implement grow-able buffer!");
                ubyte[] t = buffer[0 .. message_len];
                t[0 .. packet.length] = packet[];
                ubyte[] remain = t[packet.length .. $];
                packet = null;

                // fetch the remainder of the message...
                while (remain.length > 0)
                {
                    ptrdiff_t r = stream.read(remain[]);
                    if (r < 0)
                        return false; // connection error?
                    remain = remain[r .. $];
                }
                message = t;
            }

            // process the message...
            MQTTPacketType type = cast(MQTTPacketType)(control >> 4);
            switch (type)
            {
                case MQTTPacketType.Connect:
                    if (state != ConnectionState.WaitingIntroduction)
                        return false;

                    const(char)[] name = message.take!(char[]);
                    if (name[] != "MQTT" && name[] != "MQIsdp")
                        return false;

                    protocol_level = message.take!ubyte;
                    conn_flags = message.take!ubyte;

                    // validate conn_flags
                    if (conn_flags & 1) // bit 0 must be zero
                        return false;
                    // TODO: validate last will & testament...
                    if ((conn_flags & 4) == 0 && (conn_flags & 0x38) != 0)
                        return false; // will retain/qof flags must be 0 is will is 0
                    if (protocol_level < 5)
                    {
                        if ((conn_flags & 0x80) == 0 && (conn_flags & 0x40) != 0)
                            return false; // password must not be present if username is not present
                    }

                    keep_alive_time = message.take!ushort;

                    const(char)[] id, username, will_topic;
                    const(ubyte)[] password, properties, will_message, will_props;
                    bool session_present;

                    if (protocol_level >= 5)
                    {
                        uint propLen = message.take_var_int;
                        properties = message.take(propLen);
                    }

                    id = message.take!(char[]);
                    if (conn_flags & 4)
                    {
                        if (protocol_level >= 5)
                        {
                            uint propLen = message.take_var_int;
                            will_props = message.take(propLen);
                        }
                        will_topic = message.take!(char[]);
                        will_message = message.take!(ubyte[]);
                    }
                    if (conn_flags & 0x80)
                        username = message.take!(char[]);
                    if (conn_flags & 0x40)
                        password = message.take!(ubyte[]);

                    if (!id.validate_string || !will_topic.validate_string || !username.validate_string)
                        return false;

                    // we have parsed the message, now we can begin formatting a reply; we'll reuse buffer[]
                    buffer[0] = MQTTPacketType.ConnAck << 4;
                    buffer[3] = 0; // accepted

                    ubyte[] response = buffer[4 .. $];
                    if (protocol_level >= 5)
                    {
                        // write properties...
                        response.put_var_int(0);
                    }

                    // having reached here, the CONNECT packet is valid and we should confirm the protocol level
                    if (protocol_level < 3 && protocol_level > 5)
                    {
                        buffer[3] = protocol_level < 5 ? 0x01 : 0x84; // unacceptable protocol level
                        goto send_conn_ack;
                    }
                    if (protocol_level == 3 || protocol_level == 5)
                        writeWarning("MQTT protocol level has never been tested... implementation may or may not work!");

                    // check username and password
                    if (username.empty && password.empty)
                    {
                        if (!broker.allow_anonymous)
                        {
                            buffer[3] = protocol_level < 5 ? 0x05 : 0x87; // not authorised
                            goto send_conn_ack;
                        }
                    }
                    else
                    {
                        if (username.empty)
                        {
                            // TODO: MQTT allows a password without a username; but what does it mean?
                            //       we could take it as a public key and auth like ssh?
                            buffer[3] = protocol_level < 5 ? 0x05 : 0x87; // not authorised
                            goto send_conn_ack;
                        }
                        else
                        {
                            bool authorised = false;
                            void login_response(AuthResult result, const(char)[] profile)
                            {
                                authorised = result == AuthResult.accepted;
                            }

                            if (!g_app.validate_login(username, cast(const(char)[])password, "mqtt", &login_response) || !authorised)
                            {
                                buffer[3] = protocol_level < 5 ? 0x04 : 0x86;
                                goto send_conn_ack;

                                // TODO: anything to do with the profile?
                                //       MQTT user profiles often have whitelist/blacklist stuff...
                            }
                        }
                    }

                    // if client has not supplied an ID, and we should generate one
                    if (id.empty)
                    {
                        if ((conn_flags & 2) == 0)
                        {
                            // unspecified client id requires clean session
                            buffer[3] = protocol_level < 5 ? 0x02 : 0x85;
                            goto send_conn_ack;
                        }

                        // do we know a hostname for the remote?
                        id = stream.remote_name;
                        // the name should be a valid identifier
                        // replace '.' with '_', truncate port
                        assert(0);
                    }
                    // TODO: ...
//                    if (unacceptable id)
//                    {
//                        buffer[3] = protocol_level < 5 ? 0x02 : 0x85;
//                        goto send_conn_ack;
//                    }

                    // if client is not authorised to connect, for any reason
//                    if (client not authorised)
//                    {
//                        buffer[3] = protocol_level < 5 ? 0x05 : 0x87;
//                        goto send_conn_ack;
//                    }

                    {
                        // dig up the session or create a new one
                        session = id in broker.sessions;
                        session_present = session !is null;
                        if (!session)
                        {
                            String identifier = id.makeString(defaultAllocator());
                            session = broker.sessions.insert(identifier[], MQTTSession(identifier.move));
                        }

                        // if session already has a live client
                        if (session.client)
                        {
                            // send DISCONNECT with reason 0x8E to the existing client and terminate
                            ubyte[4] disconnect;
                            disconnect[0] = MQTTPacketType.Disconnect;
                            disconnect[1] = protocol_level < 5 ? 0 : 2;
                            if (protocol_level >= 5)
                            {
                                disconnect[2] = 0x8E; // session taken over
                                disconnect[3] = 0; // no props
                            }
                            session.client.stream.write(disconnect[0 .. protocol_level < 5 ? 2 : 4]);

                            // termiante the client
                            session.client.terminate();
                        }

                        // if clean session was requested...
                        if (conn_flags & 2)
                        {
                            if (session_present)
                                broker.destroy_session(*session);
                            session_present = false;
                        }
                        session.client = &this;

                        // record last will and testament
                        if (conn_flags & 4)
                        {
                            session.will_topic = will_topic.makeString(defaultAllocator());
                            session.will_message = will_message.duplicate(defaultAllocator());
                            session.will_props = will_props.duplicate(defaultAllocator());
                            session.will_flags = ((conn_flags >> 2) & 0x6) | ((conn_flags & 0x20) ? 1 : 0);

                            // process the will properties...
                            while (!will_props.empty)
                            {
                                ubyte prop_id = will_props.take!ubyte;
                                switch (prop_id)
                                {
                                    case MQTTProperties.WillDelayInterval:
                                        session.will_delay = will_props.take!uint;
                                        break;

                                    case MQTTProperties.PayloadFormatIndicator:
                                    case MQTTProperties.MessageExpiryInterval:
                                    case MQTTProperties.ContentType:
                                    case MQTTProperties.ResponseTopic:
                                    case MQTTProperties.CorrelationData:
                                    case MQTTProperties.UserProperty:
                                        assert(0);
                                        break;

                                    default:
                                        // unknown property...?
                                        return false;
                                }
                            }
                        }
                    }

                    // process the properties...
                    while (!properties.empty)
                    {
                        ubyte prop_id = message.take!ubyte;
                        switch (prop_id)
                        {
                            case MQTTProperties.SessionExpiryInterval:
                                session.session_expiry_interval = properties.take!uint;
                                break;

                            case MQTTProperties.AuthenticationMethod:
                            case MQTTProperties.AuthenticationData:
                            case MQTTProperties.RequestProblemInformation:
                            case MQTTProperties.RequestResponseInformation:
                            case MQTTProperties.ReceiveMaximum:
                            case MQTTProperties.TopicAliasMaximum:
                            case MQTTProperties.UserProperty:
                            case MQTTProperties.MaximumPacketSize:
                                assert(0);
                                break;

                            default:
                                // unknown property...?
                                return false;
                        }
                    }

                send_conn_ack:
                    // send CONNACK
                    buffer[1] = cast(ubyte)(buffer.length - response.length - 2); // write length
                    buffer[2] = session_present && buffer[3] == 0 ? 1 : 0;
                    stream.write(buffer[0 .. buffer.length - response.length]);
                    if (buffer[3] != 0)
                    {
                        // if we rejected the connection, terminate the connection
                        return false;
                    }

                    state = ConnectionState.Active;

                    writeInfo("MQTT - Accept CONNECT from '", stream.remote_name, "' as '", session.identifier[] ,"', login: ", username);
                    version (DebugMQTTClient)
                        writeDebug("MQTT - Sent CONNACK to ", session.identifier[]);

                    if (session_present)
                    {
                        // if we picked up an old session, we need to resend pending messages...
                        // TODO...
                    }

                    break;

                case MQTTPacketType.ConnAck:
                    assert(false);
                    if (state != ConnectionState.WaitingIntroductionAck)
                        return false;

                    //...

                    if (protocol_level >= 5)
                    {
                        uint property_len = message.take_var_int;
                        const(ubyte)[] properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.SessionExpiryInterval:
                                case MQTTProperties.AssignedClientIdentifier:
                                case MQTTProperties.AuthenticationMethod:
                                case MQTTProperties.ServerKeepAlive:
                                case MQTTProperties.AuthenticationData:
                                case MQTTProperties.ResponseInformation:
                                case MQTTProperties.ServerReference:
                                case MQTTProperties.ReasonString:
                                case MQTTProperties.ReceiveMaximum:
                                case MQTTProperties.TopicAliasMaximum:
                                case MQTTProperties.MaximumQoS:
                                case MQTTProperties.RetainAvailable:
                                case MQTTProperties.UserProperty:
                                case MQTTProperties.MaximumPacketSize:
                                case MQTTProperties.WildcardSubscriptionAvailable:
                                case MQTTProperties.SubscriptionIdentifierAvailable:
                                case MQTTProperties.SharedSubscriptionAvailable:
                                    assert(0);
                                    break;

                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }

                    //...

                    state = ConnectionState.Active;
                    break;

                case MQTTPacketType.Publish:
                    if (state != ConnectionState.Active)
                        return false;

                    bool retain = !!(control & 1);
                    bool dup = !!(control & 8);
                    ubyte qos = (control >> 1) & 3;
                    if (qos > 2)
                        return false;

                    const(char)[] topic_name = message.take!(char[]);
                    if (!topic_name.validate_string)
                        return false;

                    ushort packet_identifier;
                    if (qos > 0)
                        packet_identifier = message.take!ushort;

                    const(ubyte)[] properties;
                    if (protocol_level >= 5)
                    {
                        uint property_len = message.take_var_int;
                        properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.PayloadFormatIndicator:
                                case MQTTProperties.MessageExpiryInterval:
                                case MQTTProperties.ContentType:
                                case MQTTProperties.ResponseTopic:
                                case MQTTProperties.CorrelationData:
                                case MQTTProperties.SubscriptionIdentifier:
                                case MQTTProperties.TopicAlias:
                                case MQTTProperties.UserProperty:
                                    assert(0);
                                    break;

                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }

                    broker.publish(session.identifier[], control & 0xF, topic_name, message, properties);

                    if (qos > 0)
                    {
                        buffer[0] = (qos == 1 ? MQTTPacketType.PubAck : MQTTPacketType.PubRec) << 4;
                        buffer[1] = 2;
                        buffer[2..4].put(packet_identifier);
                        stream.write(buffer[0 .. 4]);
                    }

                    version (DebugMQTTClient)
                    {
                        writeInfo("MQTT - Received PUBLISH from ", session.identifier[], ": ", packet_identifier, ", ", topic_name, " = ", cast(const(char)[])message, " (qos: ", qos, dup ? " DUP" : "", retain ? " RET" : "", ")");
                        if (qos > 0)
                            writeDebug("MQTT - Sent ", qos == 1 ? "PUBACK" : "PUBREC" ," to ", session.identifier[], ": ", packet_identifier);
                    }
                    break;

                case MQTTPacketType.PubAck:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 0)
                        return false;

                    ushort packet_identifier = message.take!ushort;

                    if (protocol_level >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint property_len = message.take_var_int;
                        const(ubyte)[] properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.ReasonString:
                                case MQTTProperties.UserProperty:
                                    assert(0);
                                    break;
                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }

                    // TODO: delete the pending message...
                    version (DebugMQTTClient)
                        writeDebug("MQTT - Received PUBACK from ", session.identifier[], ": ", packet_identifier);
                    break;

                case MQTTPacketType.PubRec:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 0)
                        return false;

                    ushort packet_identifier = message.take!ushort;

                    if (protocol_level >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint property_len = message.take_var_int;
                        const(ubyte)[] properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.ReasonString:
                                case MQTTProperties.UserProperty:
                                    assert(0);
                                    break;
                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }

                    buffer[0] = MQTTPacketType.PubRel << 4;
                    buffer[1] = 2;
                    buffer[2..4].put(packet_identifier);
                    stream.write(buffer[0 .. 4]);

                    version (DebugMQTTClient)
                    {
                        writeDebug("MQTT - Received PUBREC from ", session.identifier[], ": ", packet_identifier);
                        writeDebug("MQTT - Sent PUBREL to ", session.identifier[], ": ", packet_identifier);
                    }
                    break;

                case MQTTPacketType.PubRel:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 2)
                        return false;

                    ushort packet_identifier = message.take!ushort;

                    if (protocol_level >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint property_len = message.take_var_int;
                        const(ubyte)[] properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.ReasonString:
                                case MQTTProperties.UserProperty:
                                    assert(0);
                                    break;
                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }

                    buffer[0] = MQTTPacketType.PubComp << 4;
                    buffer[1] = 2;
                    buffer[2..4].put(packet_identifier);
                    stream.write(buffer[0 .. 4]);

                    version (DebugMQTTClient)
                    {
                        writeDebug("MQTT - Received PUBREL from ", session.identifier[], ": ", packet_identifier);
                        writeDebug("MQTT - Sent PUBCOMP to ", session.identifier[], ": ", packet_identifier);
                    }
                    break;

                case MQTTPacketType.PubComp:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 0)
                        return false;

                    ushort packet_identifier = message.take!ushort;

                    if (protocol_level >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint property_len = message.take_var_int;
                        const(ubyte)[] properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.ReasonString:
                                case MQTTProperties.UserProperty:
                                    assert(0);
                                    break;
                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }

                    version (DebugMQTTClient)
                        writeDebug("MQTT - Received PUBCOMP from ", session.identifier[], ": ", packet_identifier);
                    break;

                case MQTTPacketType.Subscribe:
                    if (state != ConnectionState.Active || (control & 0xF) != 2)
                        return false;

                    ushort packet_identifier = message.take!ushort;

                    if (protocol_level >= 5)
                    {
                        uint property_len = message.take_var_int;
                        const(ubyte)[] properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.SubscriptionIdentifier:
                                case MQTTProperties.UserProperty:
                                    assert(0);
                                    break;
                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }

                    // format the response
                    buffer[0] = MQTTPacketType.SubAck << 4;
                    ubyte[] response = buffer[2 .. $];
                    response.put(packet_identifier);
                    if (protocol_level >= 5)
                    {
                        response.put_var_int(0);
                    }

                    while (!message.empty)
                    {
                        const(char)[] topic = message.take!(char[]);
                        ubyte opts = message.take!ubyte;
                        if (!topic.validate_string || (opts & (protocol_level < 5 ? 0xFC : 0xC0)) != 0) // upper bits must be zero
                            return false;

                        ubyte max_qos = opts & 3;
//                        bool no_local = protocol_level >= 5 && (opts & 4) != 0;
//                        bool retain_as_published = protocol_level >= 5 && (opts & 8) != 0;
                        ubyte retain_handling = (opts >> 4) & 3;

                        MQTTSession.Subscription** sub = topic in session.subs_by_filter;
                        if (!sub)
                        {
                            MQTTSession.Subscription* newSub = &session.subs.emplaceBack(topic.makeString(defaultAllocator()), opts);
                            session.subs_by_filter[newSub.topic] = newSub;

                            broker.subscribe(newSub.topic, &session.publish_callback);
                        }
                        else
                            **sub = MQTTSession.Subscription((**sub).topic.move, opts);

                        if (retain_handling == 0 || (retain_handling == 1 && !sub))
                        {
                            // send retained message for this topic
                            // TODO:
                        }

                        ubyte code = max_qos; // grant whatever qos was requested...
//                        if (failed)
//                            code = 0x80;
                        response.put(code);

                        version (DebugMQTTClient)
                            writeInfo("MQTT - Received SUBSCRIBE from ", session.identifier[], ": ", packet_identifier, ", ", topic," (", opts & 3, ")");
                    }

                    // respond with suback
                    buffer[1] = cast(ubyte)(buffer.length - response.length - 2); // write length
                    stream.write(buffer[0 .. buffer.length - response.length]);

                    version (DebugMQTTClient)
                        writeDebug("MQTT - Sent SUBACK to ", session.identifier[], ": ", packet_identifier);
                    break;

                case MQTTPacketType.SubAck:
                    assert(false);
                    break;

                case MQTTPacketType.Unsubscribe:
                    assert(false);
                    break;

                case MQTTPacketType.UnsubAck:
                    assert(false);
                    break;

                case MQTTPacketType.PingReq:
                    if (state != ConnectionState.Active || (control & 0xF) != 0)
                        return false;

                    buffer[0] = MQTTPacketType.PingResp << 4;
                    buffer[1] = 0;
                    stream.write(buffer[0 .. 2]);
                    break;

                case MQTTPacketType.PingResp:
                    if (state != ConnectionState.Active || (control & 0xF) != 0)
                        return false;
                    break;

                case MQTTPacketType.Disconnect:
                    if (state != ConnectionState.Active || (control & 0xF) != 0)
                        return false;

                    ubyte reason = 0;
                    if (protocol_level >= 5)
                    {
                        reason = message.take!ubyte;

                        uint property_len = message.take_var_int;
                        const(ubyte)[] properties = message.take(property_len);
                        while (!properties.empty)
                        {
                            ubyte prop_id = message.take!ubyte;
                            switch (prop_id)
                            {
                                case MQTTProperties.SessionExpiryInterval:
                                case MQTTProperties.ServerReference:
                                case MQTTProperties.ReceiveMaximum:
                                case MQTTProperties.UserProperty:
                                    assert(0);
                                    break;
                                default:
                                    // unknown property...?
                                    return false;
                            }
                        }
                    }
                    else if (message.length != 0)
                        return false;

                    // clear last will and testament
                    if (reason == 0)
                    {
                        session.will_topic = null;
                        session.will_message = null;
                        session.will_props = null;
                        session.will_flags = 0;
                    }

                    // signal to terminate connection
                    return false;

                case MQTTPacketType.Auth:
                    assert(false);
                    return false;

                default:
                    // bad packet type, probably not an MQTT client...
                    assert(0);
                    return false;
            }
        }
        return true;
    }

    void stream_signal(BaseObject object, StateSignal signal)
    {
        if (signal != StateSignal.online)
        {
            stream.unsubscribe(&stream_signal);
            stream.destroy();
            stream = null;
        }
    }
}


bool validate_string(const char[] s)
{
    foreach (c; s)
    {
        if ((c >= 0 && c <= 0x1F) || (c >= 0x7F && c <= 0x9F))
            return false;
    }
    return true;
}
