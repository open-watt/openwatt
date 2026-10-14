module protocol.mqtt.connection;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.page : Page;
import urt.string;
import urt.time;

import manager;
import manager.base;

import router.stream;

import protocol.mqtt.broker;
import protocol.mqtt.codec;
import protocol.mqtt.session;
import protocol.mqtt.topic;

nothrow @nogc:


// One wire-side peer. The broker keeps stable heap pointers; Session also holds one in Session.connection once CONNECT lands.
enum ConnectionState : ubyte
{
    waiting_connect,
    active,
    closing,
}

enum int    connect_timeout_secs = 10;
enum size_t max_packet_size      = 256 * 1024;

struct Connection
{
nothrow @nogc:
    @disable this(this);

    this(MQTTBroker broker, Stream stream)
    {
        this.broker = broker;
        this.stream = stream;
        this.state = ConnectionState.waiting_connect;
        this.last_contact = getTime();
        this.connect_deadline = this.last_contact + connect_timeout_secs.seconds;
        if (stream)
        {
            stream.subscribe(&stream_state_change);
            stream.rx_handler(&stream_rx);
        }
    }

    ~this()
    {
        release_stream();
        parse_buf.clear();
    }

    // Returns false when the broker should reap this connection.
    bool update()
    {
        if (!stream || !stream.running)
            return false;

        MonoTime now = getTime();
        if (state == ConnectionState.waiting_connect)
        {
            if (now >= connect_deadline)
                return false;
        }
        else if (keep_alive_secs != 0)
        {
            // Spec: disconnect after 1.5x keep-alive of silence.
            Duration limit = (keep_alive_secs * 3 / 2).seconds;
            if (now - last_contact >= limit)
                return false;
        }

        return true;
    }

    void disconnect(ubyte reason)
    {
        if (!stream || !stream.running)
        {
            terminate();
            return;
        }
        if (state == ConnectionState.active)
        {
            DisconnectPacket d;
            d.reason_code = reason;
            send_disconnect(d);
        }
        terminate();
    }

    void terminate()
    {
        state = ConnectionState.closing;
        release_stream();
    }

    // a subscriber whose queue is full misses QoS 0 publishes until it catches up
    void send_publish_to_subscriber(const(char)[] topic, const(ubyte)[] payload, const(ubyte)[] orig_properties, ubyte qos)
    {
        if (!stream || !stream.running || state != ConnectionState.active)
            return;
        PublishPacket pkt = publish_packet(topic, payload, orig_properties, qos, false);
        if (send_packet(publish_size(pkt, protocol_level), (ref ubyte[] s) => encode_publish(s, pkt, protocol_level), true) || dropping)
            return;
        dropping = true;
        writeWarning("MQTT client on ", stream_name(), " is not keeping up; dropping publishes until it does");
    }

    // the SUBACK queued after this arms the pull, so the retained messages follow it, one at a time
    void replay_retained(String filter, ubyte qos)
    {
        cancel_replay(filter[]);
        replays ~= Replay(filter, String(), qos);
    }

    void cancel_replay(const(char)[] filter)
    {
        foreach (i, ref r; replays)
        {
            if (r.filter[] == filter)
                return replays.remove(i);
        }
    }

    Session* attached_session() => session;
    const(char)[] stream_name() => stream ? stream.name[] : null;

    package void clear_session() { session = null; }

private:
    MQTTBroker broker;
    Stream stream;
    Session* session;

    ConnectionState state;
    ProtocolLevel protocol_level;
    ushort keep_alive_secs;
    bool dropping;
    MonoTime last_contact;
    MonoTime connect_deadline;

    Array!ubyte parse_buf;
    PacketQueue tx;
    Array!Replay replays;

    struct Replay
    {
        String filter;
        String after;
        ubyte qos;
    }

    void release_stream()
    {
        tx.clear();
        replays.clear();
        if (!stream)
            return;
        stream.release_rx_handler(&stream_rx);
        stream.release_tx_handler(&produce);
        stream.destroy();
        stream = null;
    }

    // a packet the queue cannot take ends the connection, unless it is a publish the subscriber can miss
    bool send_packet(size_t size, scope PacketEncoder encode, bool droppable = false)
    {
        if (!stream)
            return false;
        if (tx.push(size, encode))
        {
            stream.tx_handler(&produce);
            return true;
        }
        if (droppable)
            return false;
        writeWarning("MQTT client on ", stream_name(), " is not taking what is sent; dropping it");
        terminate();
        return false;
    }

    PublishPacket publish_packet(const(char)[] topic, const(ubyte)[] payload, const(ubyte)[] orig_properties, ubyte qos, bool retain)
    {
        PublishPacket pkt;
        pkt.topic = topic;
        pkt.payload = payload;
        pkt.qos = qos;
        pkt.retain = retain;
        // QoS > 0 would need a packet-id; broker caps sub.qos for now.
        if (protocol_level >= ProtocolLevel._5)
            pkt.properties = orig_properties;
        return pkt;
    }

    Page* produce(ref const TxRequest req, out TxStatus status)
    {
        if (tx.empty)
        {
            dropping = false;
            if (!replay_next())
            {
                status = TxStatus.starved;
                return null;
            }
        }
        Page* page = tx.take(req, status);
        if (status == TxStatus.idle && !replays.empty)
            status = TxStatus.more;
        return page;
    }

    // false when the next retained message found no page; the cursor stays on it for the next pull
    bool replay_next()
    {
        while (!replays.empty)
        {
            Replay* r = &replays[0];
            RetainedMessage* m = broker.next_retained(r.filter[], r.after[]);
            if (!m)
            {
                replays.remove(0);
                continue;
            }
            PublishPacket pkt = publish_packet(m.topic[], m.payload[], m.properties[], r.qos, true);
            if (!tx.push(publish_size(pkt, protocol_level), (ref ubyte[] s) => encode_publish(s, pkt, protocol_level)))
                return false;
            r.after = m.topic;
            return true;
        }
        return true;
    }

    // a failure terminates the connection; the broker reaps it on its next update
    void stream_rx(Stream, const(void)[] data, MonoTime rx_time)
    {
        parse_buf ~= cast(const(ubyte)[])data;
        last_contact = rx_time;
        if (parse_buf.length > max_packet_size)
            return terminate();

        const(ubyte)[] view = parse_buf[];
        while (view.length > 0 && stream)
        {
            const(ubyte)[] before = view;
            FixedHeader hdr;
            if (!decode_header(view, hdr))
            {
                view = before;
                break;
            }
            if (view.length < hdr.body_length)
            {
                view = before;
                break;
            }

            const(ubyte)[] body = view[0 .. hdr.body_length];
            view = view[hdr.body_length .. $];

            if (!dispatch(hdr, body))
                return terminate();
        }
        size_t consumed = parse_buf.length - view.length;
        if (consumed > 0)
            parse_buf.remove(0, consumed);
    }

    void stream_state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
        {
            stream.unsubscribe(&stream_state_change);
            stream.release_tx_handler(&produce);
            stream = null;
        }
    }

    bool dispatch(FixedHeader hdr, const(ubyte)[] body)
    {
        if (state == ConnectionState.waiting_connect && hdr.type != PacketType.Connect)
            return false;
        if (state == ConnectionState.closing)
            return false;

        switch (hdr.type)
        {
            case PacketType.Connect:     return handle_connect(body, hdr.flags);
            case PacketType.Publish:     return handle_publish(body, hdr.flags);
            case PacketType.PubAck:      return handle_ack(body, hdr.flags, PacketType.PubAck);
            case PacketType.PubRec:      return handle_ack(body, hdr.flags, PacketType.PubRec);
            case PacketType.PubRel:      return handle_pubrel(body, hdr.flags);
            case PacketType.PubComp:     return handle_ack(body, hdr.flags, PacketType.PubComp);
            case PacketType.Subscribe:   return handle_subscribe(body, hdr.flags);
            case PacketType.Unsubscribe: return handle_unsubscribe(body, hdr.flags);
            case PacketType.PingReq:     return handle_pingreq(body, hdr.flags);
            case PacketType.Disconnect:  return handle_disconnect(body, hdr.flags);
            case PacketType.ConnAck:     // client->server only
            case PacketType.SubAck:
            case PacketType.UnsubAck:
            case PacketType.PingResp:    return false;
            case PacketType.Auth:        return false;  // TODO: v5 enhanced auth
            default:                     return false;
        }
    }


    bool handle_connect(const(ubyte)[] body, ubyte flags)
    {
        ConnectPacket pkt;
        if (!decode_connect(body, flags, pkt))
            return send_connack_reject(ProtocolLevel._3_1_1, ReasonCode.MalformedPacket, false);

        protocol_level = pkt.protocol_level;

        bool authorised = false;
        if (pkt.has_username || pkt.has_password)
        {
            void result(AuthResult r, const(char)[] profile)
            {
                authorised = r == AuthResult.accepted;
            }
            const(char)[] u = pkt.has_username ? pkt.username : null;
            const(char)[] p = pkt.has_password ? cast(const(char)[])pkt.password : null;
            if (!g_app.validate_login(u, p, "mqtt", &result) || !authorised)
                return send_connack_reject(protocol_level, ReasonCode.BadUsernameOrPassword, false);
        }
        else
        {
            if (!broker.allow_anonymous)
                return send_connack_reject(protocol_level, ReasonCode.NotAuthorized, false);
        }

        const(char)[] client_id = pkt.client_id;
        bool generated_id = false;
        char[64] gen_buf = void;
        if (client_id.length == 0)
        {
            if (!pkt.clean_start)
                return send_connack_reject(protocol_level, ReasonCode.ClientIdentifierNotValid, false);
            client_id = generate_client_id(gen_buf[]);
            generated_id = true;
        }

        uint session_expiry = 0;
        const(ubyte)[] cprops = pkt.properties;
        if (protocol_level >= ProtocolLevel._5 && !decode_connect_props(cprops, session_expiry))
            return send_connack_reject(protocol_level, ReasonCode.MalformedPacket, false);

        bool present;
        session = broker.claim_or_create_session(client_id, pkt.clean_start, protocol_level, present);
        if (!session)
            return send_connack_reject(protocol_level, ReasonCode.UnspecifiedError, false);
        session.attach(&this);
        session.expiry_interval = (protocol_level >= ProtocolLevel._5) ? session_expiry
                                : (pkt.clean_start ? 0 : expiry_never);

        keep_alive_secs = pkt.keep_alive;

        if (pkt.has_will)
        {
            session.will.present = true;
            session.will.sent = false;
            session.will.qos = pkt.will_qos;
            session.will.retain = pkt.will_retain;
            session.will.topic = pkt.will_topic.make_string();
            session.will.payload = pkt.will_payload;
            session.will.properties = pkt.will_properties;
            session.will.delay_interval = 0;   // TODO: parse WillDelayInterval from will props
        }

        ConnAckPacket ack;
        ack.session_present = present && !pkt.clean_start;
        ack.reason_code = ReasonCode.Success;
        // TODO: emit AssignedClientIdentifier + server caps as v5 properties
        cast(void)generated_id;
        if (!send_connack(ack))
            return false;

        state = ConnectionState.active;
        writeInfo("MQTT CONNECT on ", stream_name(), " as '", client_id, "' (v",
                  cast(int)protocol_level, ")");

        // TODO: resend in-flight outbound from a resumed session

        return true;
    }

    static bool decode_connect_props(const(ubyte)[] props, ref uint session_expiry)
    {
        alias P = protocol.mqtt.codec.Property;
        while (props.length > 0)
        {
            ubyte id;
            if (!take!ubyte(props, id))
                return false;
            switch (id)
            {
                case P.SessionExpiryInterval:
                    if (!take!uint(props, session_expiry))
                        return false;
                    break;
                case P.ReceiveMaximum:
                    ushort dummy_us;
                    if (!take!ushort(props, dummy_us))
                        return false;
                    break;
                case P.MaximumPacketSize:
                    uint dummy_u;
                    if (!take!uint(props, dummy_u))
                        return false;
                    break;
                case P.TopicAliasMaximum:
                    ushort dummy2;
                    if (!take!ushort(props, dummy2))
                        return false;
                    break;
                case P.RequestResponseInformation:
                case P.RequestProblemInformation:
                    ubyte dummy_b;
                    if (!take!ubyte(props, dummy_b))
                        return false;
                    break;
                case P.UserProperty:
                {
                    const(char)[] k, v;
                    if (!take_string(props, k))
                        return false;
                    if (!take_string(props, v))
                        return false;
                    break;
                }
                case P.AuthenticationMethod:
                {
                    const(char)[] s;
                    if (!take_string(props, s))
                        return false;
                    break;
                }
                case P.AuthenticationData:
                {
                    const(ubyte)[] d;
                    if (!take_binary(props, d))
                        return false;
                    break;
                }
                default:
                    return false;
            }
        }
        return true;
    }

    static const(char)[] generate_client_id(char[] buf)
    {
        import urt.rand : rand;
        size_t n = 0;
        static immutable string prefix = "ow_";
        foreach (c; prefix)
            buf[n++] = c;
        ulong r = rand();
        foreach (i; 0 .. 12)
        {
            uint v = cast(uint)(r & 0x1F);
            r >>= 5;
            buf[n++] = cast(char)('a' + v % 26);
        }
        return buf[0 .. n];
    }

    bool send_connack(ref ConnAckPacket pkt)
        => send_packet(connack_size(pkt, protocol_level), (ref ubyte[] s) => encode_connack(s, pkt, protocol_level));

    bool send_connack_reject(ProtocolLevel level, ubyte reason, bool session_present)
    {
        ubyte v3 = (reason == ReasonCode.UnsupportedProtocolVersion) ? 0x01
                : (reason == ReasonCode.ClientIdentifierNotValid)    ? 0x02
                : (reason == ReasonCode.ServerUnavailable)           ? 0x03
                : (reason == ReasonCode.BadUsernameOrPassword)       ? 0x04
                : 0x05;
        ConnAckPacket ack;
        ack.session_present = false;
        ack.reason_code = (level >= ProtocolLevel._5) ? reason : v3;
        protocol_level = level;
        send_connack(ack);
        return false;   // always drop the connection after a reject CONNACK
    }

    bool handle_publish(const(ubyte)[] body, ubyte flags)
    {
        PublishPacket pkt;
        if (!decode_publish(body, flags, protocol_level, pkt))
            return false;
        if (!validate_topic_name(pkt.topic))
            return false;

        MonoTime now = getTime();

        if (pkt.qos == 0)
        {
            broker.publish(session, pkt.topic, pkt.payload, pkt.properties, pkt.retain, now);
            return true;
        }

        if (pkt.qos == 1)
        {
            broker.publish(session, pkt.topic, pkt.payload, pkt.properties, pkt.retain, now);
            AckPacket ack;
            ack.packet_id = pkt.packet_id;
            ack.reason_code = ReasonCode.Success;
            return send_ack(PacketType.PubAck, ack);
        }

        // QoS 2: hold publish until PUBREL; duplicate PUBLISH must NOT redeliver.
        InboundMessage* held = session.find_inbound(pkt.packet_id);
        if (held)
        {
            AckPacket rec;
            rec.packet_id = pkt.packet_id;
            rec.reason_code = ReasonCode.Success;
            return send_ack(PacketType.PubRec, rec);
        }

        InboundMessage* m = &session.pending_inbound.pushBack();
        m.packet_id = pkt.packet_id;
        m.flags = cast(ubyte)((pkt.retain ? 0x01 : 0) | (pkt.qos << 1));
        m.topic = pkt.topic.make_string();
        m.payload = pkt.payload;
        m.properties = pkt.properties;

        AckPacket rec;
        rec.packet_id = pkt.packet_id;
        rec.reason_code = ReasonCode.Success;
        return send_ack(PacketType.PubRec, rec);
    }

    bool handle_pubrel(const(ubyte)[] body, ubyte flags)
    {
        AckPacket pkt;
        if (!decode_ack(body, flags, PacketType.PubRel, protocol_level, pkt))
            return false;

        InboundMessage* held = session.find_inbound(pkt.packet_id);
        if (held)
        {
            bool retain = (held.flags & 0x01) != 0;
            broker.publish(session, held.topic[], held.payload[], held.properties[], retain, getTime());
            session.remove_inbound(pkt.packet_id);
        }
        // Spec: respond PUBCOMP even when nothing was held; v5 uses PacketIdentifierNotFound for that case.
        AckPacket comp;
        comp.packet_id = pkt.packet_id;
        comp.reason_code = held ? ReasonCode.Success : ReasonCode.PacketIdentifierNotFound;
        return send_ack(PacketType.PubComp, comp);
    }

    // PUBACK / PUBREC / PUBCOMP. While we only grant QoS 0 to subscribers these should not arrive; we accept them quietly.
    // TODO: drive Session.pending_outbound when outbound QoS 1/2 ships.
    bool handle_ack(const(ubyte)[] body, ubyte flags, PacketType t)
    {
        AckPacket pkt;
        if (!decode_ack(body, flags, t, protocol_level, pkt))
            return false;
        return true;
    }

    bool send_ack(PacketType t, ref AckPacket pkt)
        => send_packet(ack_size(pkt, protocol_level), (ref ubyte[] s) => encode_ack(s, t, pkt, protocol_level));

    bool handle_subscribe(const(ubyte)[] body, ubyte flags)
    {
        SubscribePacket pkt;
        if (!decode_subscribe(body, flags, protocol_level, pkt))
            return false;

        ubyte[256] codes_buf = void;
        size_t code_count = 0;

        const(ubyte)[] p = pkt.subscriptions;
        while (p.length > 0)
        {
            const(char)[] filter;
            ubyte opts;
            if (!take_string(p, filter))
                return false;
            if (!take!ubyte(p, opts))
                return false;

            ubyte code;
            if (!validate_topic_filter(filter))
                code = ReasonCode.TopicFilterInvalid;
            else
            {
                ubyte sub_qos = cast(ubyte)(opts & SubscribeOption.qos_mask);
                bool no_local = (opts & SubscribeOption.no_local) != 0;
                bool rap = (opts & SubscribeOption.retain_as_published) != 0;
                ubyte rh = cast(ubyte)((opts & SubscribeOption.retain_handling_mask)
                                       >> SubscribeOption.retain_handling_shift);
                // Cap granted QoS until outbound QoS 1/2 ships.
                ubyte granted = 0;
                broker.subscribe_session(session, filter, granted, no_local, rap, rh,
                                         0 /*subscription_id*/);
                code = granted;     // GrantedQoSn reason code = granted QoS byte
            }

            if (code_count == codes_buf.length)
                return false;
            codes_buf[code_count++] = code;
        }

        SubAckPacket ack;
        ack.packet_id = pkt.packet_id;
        ack.reason_codes = codes_buf[0 .. code_count];
        return send_packet(suback_size(ack, protocol_level), (ref ubyte[] s) => encode_suback(s, ack, protocol_level));
    }

    bool handle_unsubscribe(const(ubyte)[] body, ubyte flags)
    {
        UnsubscribePacket pkt;
        if (!decode_unsubscribe(body, flags, protocol_level, pkt))
            return false;

        ubyte[256] codes_buf = void;
        size_t code_count = 0;

        const(ubyte)[] p = pkt.topic_filters;
        while (p.length > 0)
        {
            const(char)[] filter;
            if (!take_string(p, filter))
                return false;
            bool removed = broker.unsubscribe_session(session, filter);
            cancel_replay(filter);
            if (code_count == codes_buf.length)
                return false;
            codes_buf[code_count++] = removed ? ReasonCode.Success : ReasonCode.NoSubscriptionExisted;
        }

        UnsubAckPacket ack;
        ack.packet_id = pkt.packet_id;
        if (protocol_level >= ProtocolLevel._5)
            ack.reason_codes = codes_buf[0 .. code_count];
        return send_packet(unsuback_size(ack, protocol_level), (ref ubyte[] s) => encode_unsuback(s, ack, protocol_level));
    }

    bool handle_pingreq(const(ubyte)[] body, ubyte flags)
    {
        if (!decode_pingreq(body, flags))
            return false;
        return send_packet(2, (ref ubyte[] s) => encode_pingresp(s));
    }

    bool handle_disconnect(const(ubyte)[] body, ubyte flags)
    {
        DisconnectPacket pkt;
        if (!decode_disconnect(body, flags, protocol_level, pkt))
            return false;
        // Spec: reason 0 clears the will; v5 reason DisconnectWithWill (0x04) keeps it.
        if (pkt.reason_code == 0 || pkt.reason_code == ReasonCode.Success)
        {
            if (session)
                session.will.present = false;
        }
        return false;
    }

    bool send_disconnect(ref DisconnectPacket pkt)
        => send_packet(disconnect_size(pkt, protocol_level), (ref ubyte[] s) => encode_disconnect(s, pkt, protocol_level));
}


unittest
{
    import manager.collection;
    import urt.mem.pagepool : page_pool_deinit, page_pool_init;

    static class Line : Stream
    {
    nothrow @nogc:
        ~this() {}
        enum type_name = "mqtt-test-line";
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Line, id, flags);
        }
        override ptrdiff_t transmit(const(void)[] data)
        {
            size_t n = data.length < room ? data.length : room;
            output ~= (cast(const(ubyte)[])data)[0 .. n];
            room -= n;
            return n;
        }
        Array!ubyte output;
        size_t room = size_t.max;
    protected:
        override Duration tx_retry_interval() const
            => Duration.zero;
    }

    static FixedHeader next_packet(ref const(ubyte)[] wire, out const(ubyte)[] body)
    {
        FixedHeader h;
        assert(decode_header(wire, h) && wire.length >= h.body_length);
        body = wire[0 .. h.body_length];
        wire = wire[h.body_length .. $];
        return h;
    }

    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();
    MQTTBroker broker = alloc!MQTTBroker(CID(1));
    scope (exit) free(broker);
    static immutable ubyte[] payload = [7];
    foreach (topic; ["a/b", "b", "a"])
        broker.publish(null, topic, payload, null, true, MonoTime());

    Line line = Collection!Line().create("mqtt-test-line");
    foreach (_; 0 .. 4)
        Collection!Stream().update_all();
    assert(line.running);

    Connection c = Connection(broker, line);
    c.state = ConnectionState.active;
    c.protocol_level = ProtocolLevel._3_1_1;
    static immutable ubyte[2] suback = [0x90, 0];
    bool send_raw(const(ubyte)[] bytes, bool droppable = false)
        => c.send_packet(bytes.length, (ref ubyte[] sink) { sink[0 .. bytes.length] = bytes[]; return true; }, droppable);
    c.replay_retained("#".make_string(), 0);
    assert(send_raw(suback[]));
    const(ubyte)[] wire = line.output[];
    const(ubyte)[] body;
    assert(next_packet(wire, body).type == PacketType.SubAck, "the SUBACK goes out ahead of the retained messages");
    foreach (topic; ["a", "a/b", "b"])
    {
        FixedHeader h = next_packet(wire, body);
        PublishPacket pkt;
        assert(h.type == PacketType.Publish && decode_publish(body, h.flags, c.protocol_level, pkt));
        assert(pkt.topic == topic && pkt.retain, "the retained messages follow in the trie's order");
    }
    assert(wire.length == 0 && c.replays.empty);

    c.replay_retained("a/#".make_string(), 0);
    c.replay_retained("a/#".make_string(), 0);
    assert(c.replays.length == 1, "subscribing again restarts the filter's replay rather than running it twice");
    c.cancel_replay("a/#");
    assert(c.replays.empty, "an unsubscribed filter replays nothing more");

    line.room = 0;
    ubyte[1000] big;
    big[0] = 0x30;
    big[1] = 0xE6;
    big[2] = 0x07;
    size_t taken;
    while (send_raw(big[], true))
        ++taken;
    assert(taken > max_tx_queue / big.length && c.stream is line, "a full queue drops a publish and keeps the subscriber");
    while (send_raw(suback[]))
    {
    }
    assert(c.stream is null && c.state == ConnectionState.closing, "a full queue ends the connection rather than lose anything else");
    foreach (_; 0 .. 4)
        Collection!Stream().update_all();
}
