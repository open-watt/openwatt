module protocol.mqtt.client;

import urt.array : duplicate, empty;
import urt.log;
import urt.mem;
import urt.string;
import urt.time;

import protocol.mqtt.broker;
import protocol.mqtt.util;

import router.stream;

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

struct Client
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

    MonoTime lastContactTime;
    ConnectionState state = ConnectionState.WaitingIntroduction;
    ubyte protocolLevel;
    ubyte connFlags;
    ushort keepAliveTime;
    string identifier;
    const(MQTTClientCredentials)* credentials;

    this(MQTTBroker broker, Stream stream)
    {
        this.broker = broker;
        this.stream = stream;
        lastContactTime = getTime();
    }

    void terminate()
    {
        // close the stream
        stream.disconnect();

        if (session.willDelay == 0)
            broker.sendLWT(*session);
        if (session.sessionExpiryInterval == 0)
            broker.destroySession(*session);

        state = ConnectionState.Terminated;
    }

    void publish(string topic, const ubyte[] payload, ubyte qos = 0, bool retain = false, bool dup = false)
    {
        assert(qos <= 2);

        ubyte[258] buffer;
        buffer[0] = (MQTTPacketType.Publish << 4) | (dup ? 8 : 0) | cast(ubyte)(qos << 1) | (retain ? 1 : 0);
        ubyte[] msg = buffer[2..$];
        msg.put(topic);
        if (qos > 0)
        {
            msg.put(session.packetId);
            session.packetId += 2;
        }
        msg.put(payload);
        buffer[1] = cast(ubyte)(buffer.length - msg.length - 2);
        stream.write(buffer[0 .. buffer.length - msg.length]);

        // TODO: retain message for qos 1,2...

        writeInfo("MQTT - Sent PUBLISH to ", identifier ,": ", qos > 0 ? session.packetId : 0, ", ", topic, " = ", cast(char[])payload, " (qos: ", qos, dup ? " DUP" : "", retain ? " RET" : "", ")");
    }

    void subscribe(ubyte requestedQos, string[] topics...)
    {
        assert(requestedQos <= 2);

        ubyte[258] buffer;
        buffer[0] = (MQTTPacketType.Subscribe << 4) | 2; // always QoS 1
        ubyte[] msg = buffer[2..$];
        msg.put(session.packetId); session.packetId += 2;
        foreach (topic; topics)
        {
            msg.put(topic);
            msg.put(requestedQos);
        }
        buffer[1] = cast(ubyte)(buffer.length - msg.length - 2);
        stream.write(buffer[0 .. buffer.length - msg.length]);

        // TODO: retain message for qos 1...
        writeInfo("MQTT - Sent SUBSCRIBE to ", identifier ,": ", session.packetId, ", ", topics, " (req qos: ", requestedQos ,")");
    }

    bool update()
    {
        if (!stream.running)
            return false;

        if (state == ConnectionState.Active)
        {
            static bool b = false;
            if (!b)
            {
//                subscribe(0, "obk125DAED5/0/get");
                b = true;
            }

//            static int x = 0;
//            if ((++x % 30) == 0)
//                publish("tele/obk125DAED5/SENSOR", null, 0, false, false);
        }

        MonoTime now = getTime();

        // read data from the client stream
        ubyte[1024] buffer;
        ptrdiff_t bytes = stream.read(buffer);
        if (bytes < 0)
            return false; // connection error?

        const(ubyte)[] packet = buffer[0 .. bytes];
        if (bytes == 0)
        {
            if (state == ConnectionState.WaitingIntroduction && now - lastContactTime >= 1000.msecs)
            {
                // if no introduction was offered in reasonable time, assume this isn't an mqtt client and terminate
                return false;
            }
            else if (keepAliveTime != 0 && now - lastContactTime >= (keepAliveTime*3/2).seconds) // x*3/2 == x*1.5
            {
                // if keepAlive is enabled and we haven't received a control packet in the allotted time
                return false;
            }
            return true;
        }
        lastContactTime = now;

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
            uint messageLen = packet.takeVarInt;
            if (messageLen == -1)
                return false;

            // take the message
            const(ubyte)[] message;
            if (messageLen <= packet.length)
                message = packet.take(messageLen);
            else
            {
                // if the message is small enough to fit into the stack buffer, well just shuffle the data back to the start of the buffer, otherwise allocate
                assert(messageLen <= buffer.length && packet.ptr >= buffer.ptr + buffer.sizeof/2, "TODO: implement grow-able buffer!");
//                ubyte[] t = (messageLen <= buffer.length && packet.ptr >= buffer.ptr + buffer.sizeof/2) ? buffer[0 .. messageLen] : new ubyte[messageLen];
                ubyte[] t = buffer[0 .. messageLen];
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

                    protocolLevel = message.take!ubyte;
                    connFlags = message.take!ubyte;

                    // validate connFlags
                    if (connFlags & 1) // bit 0 must be zero
                        return false;
                    // TODO: validate last will & testament...
                    if ((connFlags & 4) == 0 && (connFlags & 0x38) != 0)
                        return false; // will retain/qof flags must be 0 is will is 0
                    if ((connFlags & 0x80) == 0 && (connFlags & 0x40) != 0)
                        return false; // password must not be present if username is not present

                    keepAliveTime = message.take!ushort;

                    const(char)[] id, username, password, willTopic;
                    const(ubyte)[] properties, willMessage, willProps;
                    bool sessionPresent;

                    if (protocolLevel >= 5)
                    {
                        uint propLen = message.takeVarInt;
                        properties = message.take(propLen);
                    }

                    id = message.take!(char[]);
                    if (connFlags & 4)
                    {
                        if (protocolLevel >= 5)
                        {
                            uint propLen = message.takeVarInt;
                            willProps = message.take(propLen);
                        }
                        willTopic = message.take!(char[]);
                        willMessage = message.take!(ubyte[]);
                    }
                    if (connFlags & 0x80)
                        username = message.take!(char[]);
                    if (connFlags & 0x40)
                        password = message.take!(char[]);

                    if (!id.validateString || !willTopic.validateString || !username.validateString || !password.validateString)
                        return false;

                    // we have parsed the message, now we can begin formatting a reply; we'll reuse buffer[]
                    buffer[0] = MQTTPacketType.ConnAck << 4;
                    buffer[3] = 0; // accepted

                    ubyte[] response = buffer[4 .. $];
                    if (protocolLevel >= 5)
                    {
                        // write properties...
                        response.putVarInt(0);
                    }

                    // having reached here, the CONNECT packet is valid and we should confirm the protocol level
                    if (protocolLevel < 3 && protocolLevel > 5)
                    {
                        buffer[3] = 0x01; // unacceptable protocol level
                        goto sendConnAck;
                    }
                    if (protocolLevel == 3 || protocolLevel == 5)
                        writeWarning("MQTT protocol level has never been tested... implementation may or may not work!");

                    // check username and password
                    {
//                        bool authenticated = false;
//                        foreach (ref cred; broker.options.clientCredentials)
//                        {
//                            if (cred.username[] == username[] && cred.password[] == password[])
//                            {
//                                credentials = &cred;
//                                authenticated = true;
//                                break;
//                            }
//                        }
//                        if (!authenticated && !(broker.options.flags & MQTTBrokerOptions.Flags.AllowAnonymousLogin))
//                        {
//                            buffer[3] = 0x04;
//                            goto sendConnAck;
//                        }
                        // HACK: just accept it for now!
                        buffer[3] = 0x04;
                        goto sendConnAck;
                    }

                    // if client has not supplied an ID, and we should generate one
                    if (id.empty)
                    {
                        if ((connFlags & 2) == 0)
                        {
                            // unspecified client id requires clean session
                            buffer[3] = 0x02;
                            goto sendConnAck;
                        }

                        // TODO: the mac address would be a better identifier...
                        //       like `anon_mac`
                        id = stream.remoteName;
                        // the name should be a valid identifier
                        // replace '.' with '_', truncate port
                        assert(0);
                    }
//                    if (unacceptable id)
//                    {
//                        buffer[3] = 0x02;
//                        goto sendConnAck;
//                    }

                    // if client is not authorised to connect, for any reason
//                    if (client not authorised)
//                    {
//                        buffer[3] = 0x05;
//                        goto sendConnAck;
//                    }

                    {
                        // dig up the session or create a new one
                        session = id in broker.sessions;
                        sessionPresent = session !is null;
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
                            disconnect[1] = protocolLevel < 5 ? 0 : 2;
                            if (protocolLevel >= 5)
                            {
                                disconnect[2] = 0x8E; // session taken over
                                disconnect[3] = 0; // no props
                            }
                            session.client.stream.write(disconnect[0 .. protocolLevel < 5 ? 2 : 4]);

                            // termiante the client
                            session.client.terminate();
                        }
                        

                        // if clean session was requested...
                        if (connFlags & 2)
                        {
                            if (sessionPresent)
                                broker.destroySession(*session);
                            sessionPresent = false;
                        }
                        session.client = &this;

                        // record last will and testament
                        if (connFlags & 4)
                        {
                            session.willTopic = willTopic.makeString(defaultAllocator());
                            session.willMessage = willMessage.duplicate(defaultAllocator());
                            session.willProps = willProps.duplicate(defaultAllocator());
                            session.willFlags = ((connFlags >> 2) & 0x6) | ((connFlags & 0x20) ? 1 : 0);

                            // process the will properties...
                            while (!willProps.empty)
                            {
                                ubyte propId = willProps.take!ubyte;
                                switch (propId)
                                {
                                    case MQTTProperties.WillDelayInterval:
                                        session.willDelay = willProps.take!uint;
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
                        ubyte propId = message.take!ubyte;
                        switch (propId)
                        {
                            case MQTTProperties.SessionExpiryInterval:
                                session.sessionExpiryInterval = properties.take!uint;
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

                sendConnAck:
                    // send CONNACK
                    buffer[1] = cast(ubyte)(buffer.length - response.length - 2); // write length
                    buffer[2] = sessionPresent && buffer[3] == 0 ? 1 : 0;
                    stream.write(buffer[0 .. buffer.length - response.length]);
                    if (buffer[3] != 0)
                    {
                        // if we rejected the connection, terminate the connection
                        return false;
                    }

                    state = ConnectionState.Active;

                    writeInfo("MQTT - Accept CONNECT from '", stream.remoteName, "' as '", identifier ,"', login: ", username);
                    writeDebug("MQTT - Sent CONNACK to ", identifier);

                    if (sessionPresent)
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

                    if (protocolLevel >= 5)
                    {
                        uint propertyLen = message.takeVarInt;
                        const(ubyte)[] properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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

                    const(char)[] topicName = message.take!(char[]);
                    if (!topicName.validateString)
                        return false;

                    ushort packetIdentifier;
                    if (qos > 0)
                        packetIdentifier = message.take!ushort;

                    const(ubyte)[] properties;
                    if (protocolLevel >= 5)
                    {
                        uint propertyLen = message.takeVarInt;
                        properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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

                    broker.publish(identifier, control & 0xF, topicName, message, properties);

                    if (qos > 0)
                    {
                        buffer[0] = (qos == 1 ? MQTTPacketType.PubAck : MQTTPacketType.PubRec) << 4;
                        buffer[1] = 2;
                        buffer[2..4].put(packetIdentifier);
                        stream.write(buffer[0 .. 4]);
                    }

                    writeInfo("MQTT - Received PUBLISH from ", identifier,": ", packetIdentifier, ", ", topicName, " = ", cast(const(char)[])message, " (qos: ", qos, dup ? " DUP" : "", retain ? " RET" : "", ")");
                    if (qos > 0)
                        writeDebug("MQTT - Sent ", qos == 1 ? "PUBACK" : "PUBREC" ," to ", identifier,": ", packetIdentifier);
                    break;

                case MQTTPacketType.PubAck:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 0)
                        return false;

                    ushort packetIdentifier = message.take!ushort;

                    if (protocolLevel >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint propertyLen = message.takeVarInt;
                        const(ubyte)[] properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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
                    writeDebug("MQTT - Received PUBACK from ", identifier, ": ", packetIdentifier);
                    break;

                case MQTTPacketType.PubRec:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 0)
                        return false;

                    ushort packetIdentifier = message.take!ushort;

                    if (protocolLevel >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint propertyLen = message.takeVarInt;
                        const(ubyte)[] properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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
                    buffer[2..4].put(packetIdentifier);
                    stream.write(buffer[0 .. 4]);

                    writeDebug("MQTT - Received PUBREC from ", identifier, ": ", packetIdentifier);
                    writeDebug("MQTT - Sent PUBREL to ", identifier, ": ", packetIdentifier);
                    break;

                case MQTTPacketType.PubRel:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 2)
                        return false;

                    ushort packetIdentifier = message.take!ushort;

                    if (protocolLevel >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint propertyLen = message.takeVarInt;
                        const(ubyte)[] properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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
                    buffer[2..4].put(packetIdentifier);
                    stream.write(buffer[0 .. 4]);

                    writeDebug("MQTT - Received PUBREL from ", identifier, ": ", packetIdentifier);
                    writeDebug("MQTT - Sent PUBCOMP to ", identifier, ": ", packetIdentifier);
                    break;

                case MQTTPacketType.PubComp:
                    if (state != ConnectionState.Active || message.length != 2 || (control & 0xF) != 0)
                        return false;

                    ushort packetIdentifier = message.take!ushort;

                    if (protocolLevel >= 5 && !message.empty)
                    {
                        ubyte reason = message.take!ubyte;

                        uint propertyLen = message.takeVarInt;
                        const(ubyte)[] properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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

                    writeDebug("MQTT - Received PUBCOMP from ", identifier, ": ", packetIdentifier);
                    break;

                case MQTTPacketType.Subscribe:
                    if (state != ConnectionState.Active || (control & 0xF) != 2)
                        return false;

                    ushort packetIdentifier = message.take!ushort;

                    if (protocolLevel >= 5)
                    {
                        uint propertyLen = message.takeVarInt;
                        const(ubyte)[] properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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
                    response.put(packetIdentifier);
                    if (protocolLevel >= 5)
                    {
                        response.putVarInt(0);
                    }

                    while (!message.empty)
                    {
                        const(char)[] topic = message.take!(char[]);
                        ubyte opts = message.take!ubyte;
                        if (!topic.validateString || (opts & (protocolLevel < 5 ? 0xFC : 0xC0)) != 0) // upper bits must be zero
                            return false;

                        ubyte maxQos = opts & 3;
//                        bool noLocal = protocolLevel >= 5 && (opts & 4) != 0;
//                        bool retainAsPublished = protocolLevel >= 5 && (opts & 8) != 0;
                        ubyte retainHandling = (opts >> 4) & 3;

                        MQTTSession.Subscription** sub = topic in session.subsByFilter;
                        if (!sub)
                        {
                            MQTTSession.Subscription* newSub = &session.subs.emplaceBack(topic.makeString(defaultAllocator()), opts);
                            session.subsByFilter[newSub.topic] = newSub;
                        }
                        else
                            **sub = MQTTSession.Subscription((**sub).topic, opts);

                        if (retainHandling == 0 || (retainHandling == 1 && !sub))
                        {
                            // send retained message for this topic
                            // TODO:
                        }

                        ubyte code = maxQos; // grant whatever qos was requested...
//                        if (failed)
//                            code = 0x80;
                        response.put(code);

                        writeInfo("MQTT - Received SUBSCRIBE from ", identifier ,": ", packetIdentifier, ", ", topic," (", opts & 3, ")");
                    }

                    // respond with suback
                    buffer[1] = cast(ubyte)(buffer.length - response.length - 2); // write length
                    stream.write(buffer[0 .. buffer.length - response.length]);
                    writeDebug("MQTT - Sent SUBACK to ", identifier,": ", packetIdentifier);
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
                    if (protocolLevel >= 5)
                    {
                        reason = message.take!ubyte;

                        uint propertyLen = message.takeVarInt;
                        const(ubyte)[] properties = message.take(propertyLen);
                        while (!properties.empty)
                        {
                            ubyte propId = message.take!ubyte;
                            switch (propId)
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
                        session.willTopic = null;
                        session.willMessage = null;
                        session.willProps = null;
                        session.willFlags = 0;
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
}


bool validateString(const char[] s)
{
    foreach (c; s)
    {
        if ((c >= 0 && c <= 0x1F) || (c >= 0x7F && c <= 0x9F))
            return false;
    }
    return true;
}
