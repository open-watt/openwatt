module protocol.mqtt.client;

import urt.array;
import urt.inet : InetAddress;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.string.format : tconcat;
import urt.time;
import urt.variant : Variant;

import manager;
import manager.base;
import manager.collection;
import manager.expression : NamedArgument;

import router.stream;
import protocol.ip.tcp_stream;

import protocol.mqtt.codec;
import protocol.mqtt.session;
import protocol.mqtt.topic;

nothrow @nogc:


class MQTTClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("host", host),
                                 Prop!("port", port),
                                 Prop!("protocol-version", protocol_version),
                                 Prop!("client-id", client_id),
                                 Prop!("clean-start", clean_start),
                                 Prop!("keep-alive", keep_alive),
                                 Prop!("username", username),
                                 Prop!("password", password),
                                 Prop!("will-topic", will_topic),
                                 Prop!("will-payload", will_payload),
                                 Prop!("will-qos", will_qos),
                                 Prop!("will-retain", will_retain));
nothrow @nogc:

    enum type_name = "mqtt-client";
    enum path = "/protocol/mqtt/client";
    enum collection_id = CollectionType.mqtt_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!MQTTClient, id, flags);
    }

    ref const(String) host() const pure
        => _host;
    void host(String value)
    {
        if (value == _host)
            return;
        _host = value.move;
        mark_set!(typeof(this), "host")();
        restart();
    }

    ushort port() const pure
        => _port;
    void port(ushort value)
    {
        if (_port == value)
            return;
        _port = value;
        mark_set!(typeof(this), "port")();
        restart();
    }

    ProtocolLevel protocol_version() const pure
        => _protocol_level;
    void protocol_version(ProtocolLevel value)
    {
        if (value == _protocol_level)
            return;
        _protocol_level = value;
        mark_set!(typeof(this), "protocol-version")();
        restart();
    }

    ref const(String) client_id() const pure
        => _client_id;
    void client_id(String value)
    {
        if (value == _client_id)
            return;
        _client_id = value.move;
        mark_set!(typeof(this), "client-id")();
        restart();
    }

    bool clean_start() const pure
        => _clean_start;
    void clean_start(bool value)
    {
        if (value == _clean_start)
            return;
        _clean_start = value;
        mark_set!(typeof(this), "clean-start")();
    }

    ushort keep_alive() const pure
        => _keep_alive;
    void keep_alive(ushort value)
    {
        if (value == _keep_alive)
            return;
        _keep_alive = value;
        mark_set!(typeof(this), "keep-alive")();
        restart();
    }

    ref const(String) username() const pure
        => _username;
    void username(String value)
    {
        if (value == _username)
            return;
        _username = value.move;
        mark_set!(typeof(this), "username")();
        restart();
    }

    const(ubyte)[] password() const pure
        => _password[];
    void password(const(ubyte)[] value)
    {
        if (value == _password[])
            return;
        _password = value;
        mark_set!(typeof(this), "password")();
        restart();
    }

    ref const(String) will_topic() const pure
        => _will_topic;
    void will_topic(String value)
    {
        if (value == _will_topic)
            return;
        _will_topic = value.move;
        mark_set!(typeof(this), "will-topic")();
        restart();
    }

    const(ubyte)[] will_payload() const pure
        => _will_payload[];
    void will_payload(const(ubyte)[] value)
    {
        if (value == _will_payload[])
            return;
        _will_payload = value;
        mark_set!(typeof(this), "will-payload")();
        restart();
    }

    ubyte will_qos() const pure
        => _will_qos;
    void will_qos(ubyte value)
    {
        if (value > 2)
            return;
        if (value == _will_qos)
            return;
        _will_qos = value;
        mark_set!(typeof(this), "will-qos")();
        restart();
    }

    bool will_retain() const pure
        => _will_retain;
    void will_retain(bool value)
    {
        if (value == _will_retain)
            return;
        _will_retain = value;
        mark_set!(typeof(this), "will-retain")();
        restart();
    }

    alias subscribe = ActiveObject.subscribe;
    alias unsubscribe = ActiveObject.unsubscribe;

    void subscribe(String filter, PublishCallback callback)
    {
        if (!validate_topic_filter(filter[]))
            return;

        // Track so we can replay on reconnect.
        bool fresh = true;
        foreach (ref s; _subscriptions)
        {
            if (s.filter[] == filter[] && s.callback == callback)
            {
                fresh = false;
                break;
            }
        }
        if (fresh)
            _subscriptions ~= ClientSubscription(filter.move, callback);

        if (_state == ClientState.active)
            send_subscribe(_subscriptions[$ - 1].filter[]);
    }

    void unsubscribe(PublishCallback callback)
    {
        for (size_t i = 0; i < _subscriptions.length; )
        {
            if (_subscriptions[i].callback == callback)
            {
                if (_state == ClientState.active)
                    send_unsubscribe(_subscriptions[i].filter[]);
                _subscriptions.remove(i);
            }
            else
                ++i;
        }
    }

    void publish(const(char)[] topic, const(ubyte)[] payload, ubyte qos = 0, bool retain = false)
    {
        if (_state != ClientState.active)
            return;
        if (qos > 0)
        {
            log.warning("publish QoS > 0 not yet supported on outbound client; dropping");
            return;
        }
        if (!validate_topic_name(topic))
            return;

        PublishPacket pkt;
        pkt.topic = topic;
        pkt.payload = payload;
        pkt.retain = retain;

        size_t sz = publish_size(pkt, _protocol_level);
        _out_buf.resize(sz);
        ubyte[] sink = _out_buf[];
        if (!encode_publish(sink, pkt, _protocol_level))
            return;
        _stream.write(_out_buf[]);
        _last_send = getTime();
    }


protected:

    override bool validate() const pure
        => (_host.length > 0 || _remote != InetAddress()) && _port != 0;

    override CompletionStatus startup()
    {
        if (!_stream)
        {
            if (!open_stream())
                return CompletionStatus.error;
        }

        if (!_stream.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            _stream.subscribe(&stream_state_change);
            _subscribed = true;
        }

        if (_state == ClientState.disconnected)
        {
            if (!send_connect())
                return CompletionStatus.error;
            _state = ClientState.awaiting_connack;
            _last_contact = getTime();
            _connect_deadline = _last_contact + connect_timeout_secs.seconds;
        }

        if (!pump_reads())
            return CompletionStatus.error;

        if (_state == ClientState.active)
        {
            // Replay subscriptions on the fresh session.
            foreach (ref s; _subscriptions)
                send_subscribe(s.filter[]);
            return CompletionStatus.complete;
        }

        if (getTime() >= _connect_deadline)
        {
            log.warning("CONNACK timed out");
            return CompletionStatus.error;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_state == ClientState.active && _stream && _stream.running)
            send_disconnect_packet();

        release_stream();
        _parse_buf.clear();
        _out_buf.clear();
        _state = ClientState.disconnected;
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (!_stream || !_stream.running)
        {
            restart();
            return;
        }

        if (!pump_reads())
        {
            restart();
            return;
        }

        MonoTime now = getTime();
        if (_keep_alive != 0)
        {
            // PINGREQ at 90% of keep-alive, give up after 150%.
            Duration limit = (_keep_alive * 9 / 10).seconds;
            if (now - _last_send >= limit)
                send_pingreq();
            Duration silent_limit = (_keep_alive * 3 / 2).seconds;
            if (now - _last_contact >= silent_limit)
            {
                log.warning("keep-alive timed out");
                restart();
            }
        }
    }


private:

    enum ClientState : ubyte
    {
        disconnected,
        awaiting_connack,
        active,
    }

    enum int connect_timeout_secs = 10;
    enum size_t read_chunk_size   = 4096;
    enum size_t max_packet_size   = 256 * 1024;

    struct ClientSubscription
    {
        String filter;
        PublishCallback callback;
    }

    String _host;
    InetAddress _remote;            // populated when host is a literal address
    ushort _port = 1883;
    ProtocolLevel _protocol_level = ProtocolLevel._3_1_1;
    String _client_id;
    bool _clean_start = true;
    ushort _keep_alive = 60;
    String _username;
    Array!ubyte _password;

    String _will_topic;
    Array!ubyte _will_payload;
    ubyte _will_qos;
    bool _will_retain;

    Stream _stream;
    bool _subscribed;

    ClientState _state;
    MonoTime _last_contact;
    MonoTime _last_send;
    MonoTime _connect_deadline;

    Array!ubyte _parse_buf;
    Array!ubyte _out_buf;

    Array!ClientSubscription _subscriptions;

    bool open_stream()
    {
        const(char)[] sname = Collection!TCPStream().generate_name(tconcat(name[], "_tcp"));
        Stream s = Collection!TCPStream().create(sname, ObjectFlags.dynamic,
            NamedArgument("remote", Variant(_host)),
            NamedArgument("port", Variant(_port)));
        if (!s)
        {
            log.error("failed to create outbound TCP stream");
            return false;
        }
        _stream = s;
        return true;
    }

    void release_stream()
    {
        if (_subscribed && _stream)
        {
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
        if (_stream)
        {
            _stream.destroy();
            _stream = null;
        }
    }

    void stream_state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline || signal == StateSignal.destroyed)
            restart();
    }

    bool pump_reads()
    {
        ubyte[read_chunk_size] scratch = void;
        for (;;)
        {
            ptrdiff_t n = _stream.read(scratch[]);
            if (n < 0)
                return false;
            if (n == 0)
                break;
            _parse_buf ~= scratch[0 .. n];
            _last_contact = getTime();
            if (_parse_buf.length > max_packet_size)
                return false;
        }

        const(ubyte)[] view = _parse_buf[];
        while (view.length > 0)
        {
            const(ubyte)[] before = view;
            FixedHeader hdr;
            if (!decode_header(view, hdr)) { view = before; break; }
            if (view.length < hdr.body_length) { view = before; break; }

            const(ubyte)[] body = view[0 .. hdr.body_length];
            view = view[hdr.body_length .. $];

            if (!dispatch(hdr, body))
                return false;
        }
        size_t consumed = _parse_buf.length - view.length;
        if (consumed > 0)
            _parse_buf.remove(0, consumed);
        return true;
    }

    bool dispatch(FixedHeader hdr, const(ubyte)[] body)
    {
        switch (hdr.type)
        {
            case PacketType.ConnAck:    return handle_connack(body, hdr.flags);
            case PacketType.Publish:    return handle_publish(body, hdr.flags);
            case PacketType.PubAck:     return handle_ack(body, hdr.flags, PacketType.PubAck);
            case PacketType.PubRec:     return handle_ack(body, hdr.flags, PacketType.PubRec);
            case PacketType.PubRel:     return handle_ack(body, hdr.flags, PacketType.PubRel);
            case PacketType.PubComp:    return handle_ack(body, hdr.flags, PacketType.PubComp);
            case PacketType.SubAck:     return handle_suback(body, hdr.flags);
            case PacketType.UnsubAck:   return handle_unsuback(body, hdr.flags);
            case PacketType.PingResp:   return decode_pingresp(body, hdr.flags);
            case PacketType.Disconnect: return handle_disconnect(body, hdr.flags);
            case PacketType.Connect: // server-only inbound
            case PacketType.Subscribe:
            case PacketType.Unsubscribe:
            case PacketType.PingReq:    return false;
            case PacketType.Auth:       return false; // TODO step 10: v5 enhanced auth
            default:                    return false;
        }
    }

    bool handle_connack(const(ubyte)[] body, ubyte flags)
    {
        if (_state != ClientState.awaiting_connack)
            return false;
        ConnAckPacket pkt;
        if (!decode_connack(body, flags, _protocol_level, pkt))
            return false;

        if (pkt.reason_code != 0)
        {
            log.warning("CONNACK rejected (reason=", pkt.reason_code, ")");
            return false;
        }
        _state = ClientState.active;
        log.notice("connected to ", _host[], ":", _port, " as '", _client_id[], "'");
        return true;
    }

    bool handle_publish(const(ubyte)[] body, ubyte flags)
    {
        PublishPacket pkt;
        if (!decode_publish(body, flags, _protocol_level, pkt))
            return false;
        if (!validate_topic_name(pkt.topic))
            return false;

        MonoTime now = getTime();
        foreach (ref s; _subscriptions)
        {
            if (topic_matches_filter(pkt.topic, s.filter[]))
                s.callback(_host[], pkt.topic, pkt.payload, now);
        }

        if (pkt.qos == 1)
        {
            AckPacket ack;
            ack.packet_id = pkt.packet_id;
            ack.reason_code = ReasonCode.Success;
            return send_ack(PacketType.PubAck, ack);
        }
        if (pkt.qos == 2)
        {
            // TODO step 10: real QoS 2 inbound dedupe; for now ack PUBREC and
            // accept whatever PUBREL shows up.
            AckPacket rec;
            rec.packet_id = pkt.packet_id;
            rec.reason_code = ReasonCode.Success;
            return send_ack(PacketType.PubRec, rec);
        }
        return true;
    }

    bool handle_ack(const(ubyte)[] body, ubyte flags, PacketType t)
    {
        AckPacket pkt;
        if (!decode_ack(body, flags, t, _protocol_level, pkt))
            return false;
        // TODO step 10: drive Session.pending_outbound transitions.
        if (t == PacketType.PubRel)
        {
            AckPacket comp;
            comp.packet_id = pkt.packet_id;
            comp.reason_code = ReasonCode.Success;
            return send_ack(PacketType.PubComp, comp);
        }
        return true;
    }

    bool handle_suback(const(ubyte)[] body, ubyte flags)
    {
        SubAckPacket pkt;
        if (!decode_suback(body, flags, _protocol_level, pkt))
            return false;
        foreach (code; pkt.reason_codes)
        {
            if (code >= 0x80)
                log.warning("SUBACK refused subscription (reason=", code, ")");
        }
        return true;
    }

    bool handle_unsuback(const(ubyte)[] body, ubyte flags)
    {
        UnsubAckPacket pkt;
        return decode_unsuback(body, flags, _protocol_level, pkt);
    }

    bool handle_disconnect(const(ubyte)[] body, ubyte flags)
    {
        DisconnectPacket pkt;
        decode_disconnect(body, flags, _protocol_level, pkt);
        log.notice("remote DISCONNECT (reason=", pkt.reason_code, ")");
        return false;
    }


    bool send_connect()
    {
        ConnectPacket pkt;
        pkt.protocol_level = _protocol_level;
        pkt.clean_start = _clean_start;
        pkt.keep_alive = _keep_alive;
        pkt.client_id = _client_id[];

        if (_will_topic.length > 0)
        {
            pkt.has_will = true;
            pkt.will_qos = _will_qos;
            pkt.will_retain = _will_retain;
            pkt.will_topic = _will_topic[];
            pkt.will_payload = _will_payload[];
        }

        if (_username.length > 0)
        {
            pkt.has_username = true;
            pkt.username = _username[];
        }
        if (_password.length > 0)
        {
            pkt.has_password = true;
            pkt.password = _password[];
        }

        size_t sz = connect_size(pkt);
        _out_buf.resize(sz);
        ubyte[] sink = _out_buf[];
        if (!encode_connect(sink, pkt))
            return false;
        if (_stream.write(_out_buf[]) <= 0)
            return false;
        _last_send = getTime();
        return true;
    }

    bool send_subscribe(const(char)[] filter)
    {
        ubyte[2 + 0xFFFF + 1] payload_buf = void;
        ubyte[] psink = payload_buf[];
        if (!put_string(psink, filter))
            return false;
        if (!put!ubyte(psink, 0))
            return false;  // QoS 0, no v5 options
        size_t plen = payload_buf.length - psink.length;

        SubscribePacket pkt;
        pkt.packet_id = next_packet_id();
        pkt.subscriptions = payload_buf[0 .. plen];

        size_t sz = subscribe_size(pkt, _protocol_level);
        _out_buf.resize(sz);
        ubyte[] sink = _out_buf[];
        if (!encode_subscribe(sink, pkt, _protocol_level))
            return false;
        if (_stream.write(_out_buf[]) <= 0)
            return false;
        _last_send = getTime();
        return true;
    }

    bool send_unsubscribe(const(char)[] filter)
    {
        ubyte[2 + 0xFFFF] payload_buf = void;
        ubyte[] psink = payload_buf[];
        if (!put_string(psink, filter))
            return false;
        size_t plen = payload_buf.length - psink.length;

        UnsubscribePacket pkt;
        pkt.packet_id = next_packet_id();
        pkt.topic_filters = payload_buf[0 .. plen];

        size_t sz = unsubscribe_size(pkt, _protocol_level);
        _out_buf.resize(sz);
        ubyte[] sink = _out_buf[];
        if (!encode_unsubscribe(sink, pkt, _protocol_level))
            return false;
        if (_stream.write(_out_buf[]) <= 0)
            return false;
        _last_send = getTime();
        return true;
    }

    bool send_pingreq()
    {
        ubyte[2] buf;
        ubyte[] sink = buf[];
        if (!encode_pingreq(sink))
            return false;
        if (_stream.write(buf[]) <= 0)
            return false;
        _last_send = getTime();
        return true;
    }

    bool send_disconnect_packet()
    {
        DisconnectPacket pkt;
        pkt.reason_code = ReasonCode.Success;
        size_t sz = disconnect_size(pkt, _protocol_level);
        _out_buf.resize(sz);
        ubyte[] sink = _out_buf[];
        if (!encode_disconnect(sink, pkt, _protocol_level))
            return false;
        return _stream.write(_out_buf[]) > 0;
    }

    bool send_ack(PacketType t, ref AckPacket pkt)
    {
        size_t sz = ack_size(pkt, _protocol_level);
        _out_buf.resize(sz);
        ubyte[] sink = _out_buf[];
        if (!encode_ack(sink, t, pkt, _protocol_level))
            return false;
        if (_stream.write(_out_buf[]) <= 0)
            return false;
        _last_send = getTime();
        return true;
    }

    ushort _next_packet_id = 1;
    ushort next_packet_id()
    {
        ushort r = _next_packet_id;
        _next_packet_id = (_next_packet_id == 0xFFFF) ? cast(ushort)1 : cast(ushort)(_next_packet_id + 1);
        return r;
    }
}
