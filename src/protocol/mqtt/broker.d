module protocol.mqtt.broker;

import urt.array;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console.session : ConsoleSession = Session;
import manager.console.table : Table;
import manager.expression : NamedArgument;

import router.stream;
import protocol.ip.tcp_stream;
import protocol.tls : Certificate, TLSServer;

import protocol.mqtt.codec;
import protocol.mqtt.connection;
import protocol.mqtt.session;
import protocol.mqtt.topic;

nothrow @nogc:


class MQTTBroker : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("port", port),
                                 Prop!("tls-port", tls_port),
                                 Prop!("certificates", certificates),
                                 Prop!("allow-anonymous", allow_anonymous),
                                 Prop!("client-timeout", _client_timeout));
nothrow @nogc:

    enum type_name = "mqtt-broker";
    enum path = "/protocol/mqtt/broker";
    enum collection_id = CollectionType.mqtt_broker;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!MQTTBroker, id, flags);
    }

    ushort port() const pure
        => _port;
    void port(ushort value)
    {
        if (_port == value)
            return;
        _port = value;
        if (_server)
            _server.port = _port;
    }

    ushort tls_port() const pure
        => _tls_port;
    void tls_port(ushort value)
    {
        if (_tls_port == value)
            return;
        _tls_port = value;
        if (_tls_server)
            _tls_server.port = _tls_port;
    }

    void certificates(Certificate[] value)
    {
        if (_cert_subscribed)
        {
            foreach (ref c; _certificates)
                if (c)
                    c.unsubscribe(&cert_state_change);
            _cert_subscribed = false;
        }
        _certificates.clear();
        _certificates.reserve(value.length);
        foreach (c; value)
            _certificates.emplaceBack(c);
        restart();
    }

    bool allow_anonymous() const pure => _allow_anonymous;
    void allow_anonymous(bool value) { _allow_anonymous = value; }

    alias subscribe = ActiveObject.subscribe;
    alias unsubscribe = ActiveObject.unsubscribe;

    void subscribe(String topic_filter, PublishCallback callback)
    {
        Subscription sub;
        sub.subscriber = callback.ptr;
        sub.callback = callback;
        _trie.register(topic_filter[], sub);

        const(char)[] filter_slice = topic_filter[];
        _trie.match_retained(filter_slice, (ref const RetainedMessage rm) nothrow @nogc {
            callback(null, rm.topic[], rm.payload[], getTime());
        });
    }

    void unsubscribe(PublishCallback callback)
    {
        _trie.unregister_all(callback.ptr);
    }

    void publish(const(char)[] client_id, ubyte flags, const(char)[] topic,
                 const(ubyte)[] payload, const(ubyte)[] properties = null,
                 MonoTime timestamp = MonoTime.init)
    {
        if (timestamp == MonoTime.init)
            timestamp = getTime();
        bool retain = (flags & 0x01) != 0;
        publish_internal(null, client_id, topic, payload, properties, retain, timestamp);
    }

    void print_retained(ConsoleSession session, const(char)[] filter = "#")
    {
        import urt.mem.temp : tconcat;

        if (!filter)
            filter = "#";
        if (!validate_topic_filter(filter))
        {
            session.write_line("Invalid MQTT topic filter");
            return;
        }

        Table table;
        table.add_column("broker");
        table.add_column("topic");
        table.add_column("bytes", Table.TextAlign.right);
        table.add_column("props", Table.TextAlign.right);
        table.add_column("payload");

        uint count;
        _trie.match_retained(filter, (ref const RetainedMessage rm) nothrow @nogc {
            table.add_row();
            table.cell(name[]);
            table.cell(rm.topic[]);
            table.cell(tconcat(rm.payload.length));
            table.cell(tconcat(rm.properties.length));
            add_payload_cell(table, rm.payload[]);
            ++count;
        });

        if (count == 0)
        {
            session.write_line("No retained MQTT messages");
            return;
        }
        table.render(session);
    }

    void print_sessions(ConsoleSession session)
    {
        import urt.mem.temp : tconcat;

        if (_sessions.empty)
        {
            session.write_line("No MQTT sessions");
            return;
        }

        Table table;
        table.add_column("broker");
        table.add_column("client");
        table.add_column("state");
        table.add_column("stream");
        table.add_column("proto");
        table.add_column("expiry");
        table.add_column("subs", Table.TextAlign.right);
        table.add_column("in", Table.TextAlign.right);
        table.add_column("out", Table.TextAlign.right);
        table.add_column("will");

        MonoTime now = getTime();
        foreach (kvp; _sessions)
        {
            Session* s = kvp.value;
            Connection* c = s.connection ? cast(Connection*)s.connection : null;
            table.add_row();
            table.cell(name[]);
            table.cell(s.client_id[]);
            table.cell(c ? "connected" : "detached");
            table.cell(c ? c.stream_name() : "-");
            table.cell(protocol_level_name(s.protocol_level));
            table.cell(session_expiry_cell(s, now));
            table.cell(tconcat(s.subscriptions.length));
            table.cell(tconcat(s.pending_inbound.length));
            table.cell(tconcat(s.pending_outbound.length));
            table.cell(s.will.present ? (s.will.sent ? "sent" : "pending") : "-");
        }
        table.render(session);
    }

    void print_subscriptions(ConsoleSession session)
    {
        import urt.mem.temp : tconcat;

        Table table;
        table.add_column("broker");
        table.add_column("client");
        table.add_column("state");
        table.add_column("filter");
        table.add_column("qos", Table.TextAlign.right);
        table.add_column("no-local");
        table.add_column("rap");
        table.add_column("retain");
        table.add_column("sub-id", Table.TextAlign.right);

        uint count;
        foreach (kvp; _sessions)
        {
            Session* s = kvp.value;
            foreach (ref sub; s.subscriptions)
            {
                table.add_row();
                table.cell(name[]);
                table.cell(s.client_id[]);
                table.cell(s.connection ? "connected" : "detached");
                table.cell(sub.filter[]);
                table.cell(tconcat(sub.qos));
                table.cell(sub.no_local ? "yes" : "no");
                table.cell(sub.retain_as_published ? "yes" : "no");
                table.cell(retain_handling_name(sub.retain_handling));
                table.cell(sub.subscription_id == 0 ? "-" : tconcat(sub.subscription_id));
                ++count;
            }
        }

        if (count == 0)
        {
            session.write_line("No MQTT session subscriptions");
            return;
        }
        table.render(session);
    }

    package Session* claim_or_create_session(const(char)[] client_id, bool clean_start, ProtocolLevel level, ref bool present)
    {
        Session** existing = client_id in _sessions;
        if (existing)
        {
            Session* s = *existing;
            if (s.connection !is null)
            {
                Connection* old = cast(Connection*)s.connection;
                old.clear_session();
                old.disconnect(ReasonCode.SessionTakenOver);
                s.connection = null;
            }
            if (clean_start)
            {
                clear_session_subs(s);
                s.reset();
                s.protocol_level = level;
                present = false;
            }
            else
            {
                present = true;
            }
            return s;
        }

        String id = client_id.makeString(defaultAllocator());
        Session* s = defaultAllocator().allocT!Session(id, level);
        _sessions.insert(s.client_id[], s);
        present = false;
        return s;
    }

    package ubyte subscribe_session(Session* s, const(char)[] filter, ubyte requested_qos, bool no_local,
                                    bool retain_as_published, ubyte retain_handling, uint subscription_id)
    {
        // Cap granted QoS until outbound QoS 1/2 ships.
        ubyte granted = 0;

        String filter_str = filter.makeString(defaultAllocator());
        bool was_new = s.record_subscription(filter_str, granted, no_local,
                                             retain_as_published, retain_handling,
                                             subscription_id);

        Subscription sub;
        sub.subscriber = s;
        sub.callback = null;
        sub.qos = granted;
        sub.no_local = no_local;
        sub.retain_as_published = retain_as_published;
        sub.retain_handling = retain_handling;
        sub.subscription_id = subscription_id;
        _trie.register(filter, sub);

        // retain_handling: 0=always, 1=only-if-new-subscription, 2=never (MQTT v5 §3.8.3.1).
        bool send_retained = (retain_handling == 0) || (retain_handling == 1 && was_new);
        if (send_retained && s.connection !is null)
        {
            Connection* conn = cast(Connection*)s.connection;
            _trie.match_retained(filter, (ref const RetainedMessage rm) nothrow @nogc {
                conn.send_publish_to_subscriber(rm.topic[], rm.payload[], rm.properties[], granted, true);
            });
        }
        return granted;
    }

    package bool unsubscribe_session(Session* s, const(char)[] filter)
    {
        bool removed_from_trie = _trie.unregister(filter, s);
        bool removed_from_session = s.drop_subscription(filter);
        return removed_from_trie || removed_from_session;
    }

    package void publish(Session* publisher, const(char)[] topic, const(ubyte)[] payload,
                         const(ubyte)[] properties, bool retain, MonoTime timestamp)
    {
        const(char)[] sender_id = publisher ? publisher.client_id[] : null;
        publish_internal(publisher, sender_id, topic, payload, properties, retain, timestamp);
    }


protected:

    override bool validate() const pure
        => _port != 0 || _tls_port != 0;

    override CompletionStatus startup()
    {
        if (_port != 0 && !_server)
        {
            if (!try_start_tcp())
                return CompletionStatus.error;
        }
        if (_tls_port != 0 && !_tls_server)
            try_start_tls();

        if (!_cert_subscribed && _certificates.length > 0)
        {
            foreach (ref c; _certificates)
                if (c)
                    c.subscribe(&cert_state_change);
            _cert_subscribed = true;
        }

        // Running = at least one configured listener is actually accepting.
        bool tcp_up = (_port != 0) && _server && _server.running;
        bool tls_up = (_tls_port != 0) && _tls_server && _tls_server.running;
        return (tcp_up || tls_up) ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_cert_subscribed)
        {
            foreach (ref c; _certificates)
                if (c)
                    c.unsubscribe(&cert_state_change);
            _cert_subscribed = false;
        }

        if (_tls_server)
        {
            _tls_server.unsubscribe(&server_state_change);
            _tls_server.destroy();
            _tls_server = null;
        }
        if (_server)
        {
            _server.unsubscribe(&server_state_change);
            _server.destroy();
            _server = null;
        }

        foreach (c; _connections)
        {
            c.disconnect(ReasonCode.ServerShuttingDown);
            defaultAllocator().freeT(c);
        }
        _connections.clear();

        foreach (kvp; _sessions)
            defaultAllocator().freeT(kvp.value);
        _sessions.clear();

        _trie.clear();
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (_server && _server.running)
            _server.update();
        if (_tls_server && _tls_server.running)
            _tls_server.update();

        MonoTime now = getTime();

        for (size_t i = 0; i < _connections.length; )
        {
            Connection* c = _connections[i];
            if (!c.update())
            {
                detach_and_close(c, now);
                defaultAllocator().freeT(c);
                _connections.removeSwapLast(i);
            }
            else
                ++i;
        }

        Session*[16] to_evict = void;
        size_t evict_count = 0;
        foreach (kvp; _sessions)
        {
            if (evict_count == to_evict.length)
                break;
            if (kvp.value.expired(now))
                to_evict[evict_count++] = kvp.value;
        }
        foreach (i; 0 .. evict_count)
            drop_session(to_evict[i]);
    }

private:
    ushort _port;
    ushort _tls_port;
    bool _allow_anonymous;
    bool _cert_subscribed;
    Duration _client_timeout;

    TCPServer _server;
    TCPServer _tls_server;
    Array!(ObjectRef!Certificate) _certificates;
    Map!(const(char)[], Session*) _sessions;
    Array!(Connection*) _connections;
    TopicTrie _trie;
    static void add_payload_cell(ref Table table, const(ubyte)[] payload)
    {
        enum max_preview = 80;

        if (payload.length == 0)
        {
            table.cell("");
            return;
        }

        size_t n = payload.length < max_preview ? payload.length : max_preview;
        bool text = true;
        foreach (b; payload[0 .. n])
        {
            if (b < 0x20 || b > 0x7e)
            {
                text = false;
                break;
            }
        }

        MutableString!0 buf;
        if (text)
        {
            buf.append(cast(const(char)[])payload[0 .. n]);
            if (payload.length > n)
                buf.append("...");
            table.cell(buf[]);
            return;
        }

        foreach (i, b; payload[0 .. n])
        {
            if (i > 0)
                buf.append(' ');
            buf.append(hex_digit(b >> 4), hex_digit(b & 0x0f));
        }
        if (payload.length > n)
            buf.append(" ...");
        table.cell(buf[]);
    }

    static char hex_digit(uint value) pure
        => cast(char)(value < 10 ? '0' + value : 'a' + value - 10);

    static const(char)[] protocol_level_name(ProtocolLevel level)
    {
        final switch (level) with (ProtocolLevel)
        {
            case _3_1:   return "3.1";
            case _3_1_1: return "3.1.1";
            case _5:     return "5";
        }
    }

    static const(char)[] retain_handling_name(ubyte value)
    {
        switch (value)
        {
            case 0:  return "always";
            case 1:  return "new";
            case 2:  return "never";
            default: return "?";
        }
    }

    static const(char)[] session_expiry_cell(Session* s, MonoTime now)
    {
        import urt.mem.temp : tconcat;

        if (s.connection)
            return "-";
        if (s.expiry_interval == expiry_never)
            return "never";
        if (s.expiry_interval == 0)
            return "now";

        Duration limit = s.expiry_interval.seconds;
        Duration elapsed = now - s.disconnect_time;
        if (elapsed >= limit)
            return "expired";
        return tconcat((limit - elapsed).as!"seconds", "s");
    }

    void publish_internal(Session* publisher, const(char)[] sender_id, const(char)[] topic,
                          const(ubyte)[] payload, const(ubyte)[] properties, bool retain, MonoTime timestamp)
    {
        if (retain)
            _trie.store_retained(topic, payload, properties, 0x01);

        _trie.match_subscribers(topic, (ref const Subscription sub) nothrow @nogc {
            if (sub.no_local && sub.subscriber is publisher)
                return;
            if (sub.callback !is null)
            {
                sub.callback(sender_id, topic, payload, timestamp);
                return;
            }
            Session* s = cast(Session*)sub.subscriber;
            if (!s || s.connection is null)
                return; // detached -- drop (TODO: queue for QoS > 0)
            Connection* conn = cast(Connection*)s.connection;
            conn.send_publish_to_subscriber(topic, payload, properties, sub.qos, false);
        });
    }

    void detach_and_close(Connection* c, MonoTime now)
    {
        Session* s = c.attached_session;
        if (s)
        {
            s.detach(now);
            // Graceful DISCONNECT clears will.present before we get here, so this only fires for abnormal disconnect. TODO: WillDelayInterval.
            if (s.will.present && !s.will.sent)
            {
                publish_internal(s, s.client_id[], s.will.topic[], s.will.payload[], s.will.properties[], s.will.retain, now);
                s.will.sent = true;
            }
        }
        c.terminate();
    }

    void drop_session(Session* s)
    {
        if (s.connection !is null)
        {
            Connection* c = cast(Connection*)s.connection;
            c.terminate();
            s.connection = null;
        }
        clear_session_subs(s);
        _sessions.remove(s.client_id[]);
        defaultAllocator().freeT(s);
    }

    void clear_session_subs(Session* s)
    {
        foreach (ref sub; s.subscriptions)
            _trie.unregister(sub.filter[], s);
    }

    bool try_start_tcp()
    {
        const(char)[] tcp_name = Collection!TCPServer().generate_name(tconcat(name[], "_tcp"));
        _server = Collection!TCPServer().create(tcp_name, ObjectFlags.dynamic, NamedArgument("port", _port));
        if (!_server)
        {
            log.error("failed to create MQTT TCP listener");
            return false;
        }
        _server.set_connection_callback(&new_connection, null);
        _server.subscribe(&server_state_change);
        log.notice("listening on MQTT port ", _port);
        return true;
    }

    void try_start_tls()
    {
        if (!any_cert_valid())
            return;

        BaseObject[32] certs;
        size_t num_certs = 0;
        foreach (ref c; _certificates)
            if (auto cert = c.get())
                certs[num_certs++] = cert;

        const(char)[] tls_name = Collection!TLSServer().generate_name(tconcat(name[], "_tls"));
        _tls_server = Collection!TLSServer().create(tls_name, ObjectFlags.dynamic,
            NamedArgument("port", _tls_port), NamedArgument("certificates", certs[0 .. num_certs]));
        if (!_tls_server)
        {
            log.error("failed to create MQTTS listener");
            return;
        }
        _tls_server.set_connection_callback(&new_connection, null);
        _tls_server.subscribe(&server_state_change);
        log.notice("listening on MQTTS port ", _tls_port);
    }

    bool any_cert_valid()
    {
        foreach (ref c; _certificates)
            if (auto cert = cast(Certificate)c.get())
                if (cert.is_valid)
                    return true;
        return false;
    }

    // TLSServer's cert set is bound at creation; updating it means destroying and recreating the listener -- what cert_state_change does on any transition.
    void restart_tls()
    {
        if (_tls_server)
        {
            _tls_server.unsubscribe(&server_state_change);
            _tls_server.destroy();
            _tls_server = null;
        }
        if (_tls_port != 0 && any_cert_valid())
            try_start_tls();
    }

    void server_state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.destroyed)
        {
            if (obj is _server)
            {
                log.warning("MQTT listener destroyed externally, recreating");
                _server = null;
                if (running && _port != 0)
                    try_start_tcp();
            }
            else if (obj is _tls_server)
            {
                log.warning("MQTTS listener destroyed externally, recreating");
                _tls_server = null;
                if (running && _tls_port != 0)
                    try_start_tls();
            }
        }
    }

    void cert_state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.online || signal == StateSignal.offline)
            restart_tls();
    }

    void new_connection(Stream client, ref const InetAddress remote, void* user_data)
    {
        Connection* c = defaultAllocator().allocT!Connection(this, client);
        _connections ~= c;
        log.info("MQTT client connected: ", remote);
    }
}
