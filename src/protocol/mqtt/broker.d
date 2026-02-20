module protocol.mqtt.broker;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.string;
import urt.time;

import manager;
import manager.base;

import protocol.mqtt.client;

import router.stream.tcp;

nothrow @nogc:

alias PublishCallback = void delegate(const(char)[] sender, const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp) nothrow @nogc;

class MQTTBroker : BaseObject
{
    __gshared Property[3] Properties = [ Property.create!("port", port)(),
                                         Property.create!("allow-anonymous", allow_anonymous)(),
                                         Property.create!("client-timeout", _client_timeout)() ];
nothrow @nogc:

    enum type_name = "mqqt-broker";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!MQTTBroker, name.move, flags);
    }

    // Properties...
    ushort port() const pure
        => _port;
    void port(ushort value)
    {
        _port = value ? value : 1883;
        if (_server)
        {
            // TODO: this will cause a restart of the server, we need to check this doesn't cascade a reset of the whole broker...
            _server.port = _port;
        }
    }

    bool allow_anonymous() const pure
        => (_flags & MQTTFlags.allow_anonymous_login) != 0;
    void allow_anonymous(bool value)
    {
        _flags = cast(MQTTFlags)((_flags & ~MQTTFlags.allow_anonymous_login) | (value ? MQTTFlags.allow_anonymous_login : 0));
    }

    // API...

    void publish(const(char)[] client_id, ubyte flags, const(char)[] topic, const(ubyte)[] payload, const(ubyte)[] properties = null, MonoTime timestamp = getTime())
    {
        Value* get_record(Value* val, const(char)[] topic)
        {
            char sep;
            const(char)[] level = topic.split!'/'(sep);
            Value* child = level in val.children;
            if (!child)
                child = val.children.insert(level.makeString(defaultAllocator()), Value());
            if (sep == 0)
                return child;
            return get_record(child, topic);
        }

        void delete_record(Value* val, const(char)[] topic) nothrow @nogc
        {
            char sep;
            const(char)[] level = topic.split!'/'(sep);
            Value* child = level in val.children;
            if (sep == 0)
                child.data = null;
            else if(child)
                delete_record(child, topic);
            if (child.children.empty)
                val.children.remove(level);
        }

        // retain message and/or push to subscribers...
        ubyte qos = (flags >> 1) & 3;
        bool retain = (flags & 1) != 0;
        bool dup = (flags & 8) != 0;

        if (payload.empty)
        {
            delete_record(&_root, topic);
            return;
        }

        if (retain)
        {
            Value* value = get_record(&_root, topic);
            if (value)
            {
                value.data = payload[];
                if (properties)
                    value.properties = properties[];
                else
                    value.properties = null;
                value.flags = flags;
            }
        }

        foreach (ref sub; _subs)
        {
            if (topic_matches_filter(topic, sub.topic_filter[]))
                sub.callback(client_id, topic, payload, timestamp);
        }
    }

    void subscribe(String topic_filter, PublishCallback callback)
    {
        Subscription* sub = &_subs.pushBack();
        sub.topic_filter = topic_filter;
        sub.callback = callback;
    }

    void unsubscribe(PublishCallback callback)
    {
        for (size_t i = 0; i < _subs.length; )
        {
            if (_subs[i].callback == callback)
                _subs.removeSwapLast(i);
            else
                ++i;
        }
    }

protected:

    override CompletionStatus startup()
    {
        if (!_server)
            _server = create_server();
        if (_server.running)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        _server.destroy();
        _server = null;

        foreach (ref client; _clients)
            client.disconnect(0x98);
        _clients.clear();

        _sessions.clear();
        _subs.clear();

        return CompletionStatus.complete;
    }

    override void update()
    {
        if (_server.running)
            _server.update();

        // update clients
        for (size_t i = 0; i < _clients.length; )
        {
            if (!_clients[i].update())
            {
                // destroy client...
                _clients[i].terminate();
                _clients.removeSwapLast(i);
            }
            else
                ++i;
        }

        // update sessions
        MonoTime now = getTime();
        const(char)[][16] items_to_remove;
        size_t num_items_to_remove = 0;
        foreach (ref session; _sessions.values)
        {
            if (session.client)
                continue;

            if (session.session_expiry_interval != 0xFFFFFFFF)
            {
                if (now - session.close_time >= session.session_expiry_interval.seconds)
                {
                    // session expired
                    if (num_items_to_remove == 16)
                        break;
                    items_to_remove[num_items_to_remove++] = session.identifier;
                }
            }
        }
        foreach (i; 0 .. num_items_to_remove)
            _sessions.remove(items_to_remove[i]);
    }

package:
    MQTTSession* create_or_claim_session(const(char)[] id, ubyte clean_session, out bool exists)
    {
        MQTTSession* s = id in _sessions;
        if (s)
        {
            if (clean_session)
                destroy_session(*s);
            else
            {
                exists = true;
                if (s.client)
                {
                    s.client.disconnect(0x8E); // 8E = session taken over
                    s.client = null;
                }
            }
        }
        else
        {
            String id_str = id.makeString(defaultAllocator());
            s = _sessions.insert(id_str[], MQTTSession(id_str.move));
        }
        return s;
    }

    void destroy_session(ref MQTTSession session)
    {
        send_lwt(session);

        unsubscribe(&session.publish_callback);

        if (session.client)
        {
            session.client.disconnect(0);
            session.client = null;
        }

        session.subs.clear();
        session.subs_by_filter.clear();
        session.will_topic = null;
        session.will_message = null;
        session.will_props = null;
        session.will_delay = 0;
        session.will_flags = 0;
        session.packet_id = 1;
    }

    void send_lwt(ref MQTTSession session)
    {
        if (!session.will_topic || session.will_sent)
            return;
        publish(session.identifier, session.will_flags, session.will_topic, session.will_message[], session.will_props[]);
        session.will_sent = true;
    }

private:

    struct Value
    {
        Map!(String, Value) children;
        Array!ubyte data;
        Array!ubyte properties;
        ubyte flags;
    }

    struct Subscription
    {
        String topic_filter;    // Can include wildcards: +, #
        PublishCallback callback;
    }

    TCPServer _server;
    ushort _port = 1883;
    MQTTFlags _flags;
    Duration _client_timeout;

    Map!(const(char)[], MQTTSession) _sessions;
    Array!MQTTClient _clients;
    Array!Subscription _subs;

    // retained values
    Value _root;

    final TCPServer create_server()
    {
        import manager.expression : NamedArgument;

        TCPServer s = get_module!TCPStreamModule.tcp_servers.create(name[], ObjectFlags.dynamic, NamedArgument("port", _port ? _port : 1883));
        s.subscribe(&server_signal);
        s.set_connection_callback(&new_connection, null);
        return s;
    }

    final void server_signal(BaseObject object, StateSignal signal)
    {
        final switch (signal)
        {
            case StateSignal.online:
                writeInfo(type, ": listening on port ", _server.port, "...");
                break;

            case StateSignal.offline:
                writeInfo(type, ": stopped listening");
                break;

            case StateSignal.destroyed:
                debug assert(object is _server);
                object.unsubscribe(&server_signal);

                if (running) // if we're still running, we'll recreate a new server
                    _server = create_server();
                break;
        }
    }

    final void new_connection(Stream client, void* user_data)
    {
        _clients ~= MQTTClient(this, client);

        writeInfo("MQTT client connected: ", client.remote_name());
    }
}


private:

enum MQTTFlags
{
    none = 0,
    allow_anonymous_login = 1 << 0,
}

package struct MQTTSession
{
    this(this) @disable;

    struct Subscription
    {
        String topic;
        ubyte options;
    }

    String identifier;
    MQTTClient* client;

    uint session_expiry_interval = 0;

    MonoTime close_time;

    Array!Subscription subs;
    Map!(const(char)[], Subscription*) subs_by_filter;

    // last will and testament
    String will_topic;
    Array!ubyte will_message;
    Array!ubyte will_props;
    uint will_delay;
    ubyte will_flags;
    bool will_sent;

    // publish state
    ushort packet_id = 1;

    // TODO: pending messages...
    ubyte[] pending_messages;

nothrow @nogc:
    void publish_callback(const(char)[] sender, const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp)
    {
        if (sender[] == identifier[])
            return; // don't echo back to sender

        if (client)
            client.publish(topic[], payload); // TODO: handle qos/retain/etc
    }
}

bool topic_matches_filter(const(char)[] topic, const(char)[] filter) pure
{
    size_t topic_pos = 0;
    size_t filter_pos = 0;

    while (filter_pos < filter.length)
    {
        if (filter[filter_pos] == '#')
        {
            // Multi-level wildcard - matches everything remaining
            return true;
        }
        else if (filter[filter_pos] == '+')
        {
            // Single-level wildcard - skip to next '/' in topic
            while (topic_pos < topic.length && topic[topic_pos] != '/')
                ++topic_pos;

            // Skip the wildcard in filter
            ++filter_pos;

            // Both should either be at '/' or at end
            if (filter_pos < filter.length && filter[filter_pos] == '/')
            {
                if (topic_pos >= topic.length || topic[topic_pos] != '/')
                    return false;
                ++filter_pos;
                ++topic_pos;
            }
        }
        else
        {
            // Literal character - must match exactly
            if (topic_pos >= topic.length || topic[topic_pos] != filter[filter_pos])
                return false;

            ++topic_pos;
            ++filter_pos;
        }
    }

    // Both must be fully consumed
    return topic_pos == topic.length && filter_pos == filter.length;
}
