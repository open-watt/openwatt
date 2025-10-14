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


class MQTTBroker : BaseObject
{
    __gshared Property[3] Properties = [ Property.create!("port", port)(),
                                         Property.create!("allow-anonymous", allow_anonymous)(),
                                         Property.create!("client-timeout", _client_timeout)() ];
nothrow @nogc:

    alias TypeName = StringLit!"mqqt-broker";

    this(String name, ObjectFlags flags = ObjectFlags.None)
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
        => (_flags & MQTTFlags.AllowAnonymousLogin) != 0;
    void allow_anonymous(bool value)
    {
        _flags = cast(MQTTFlags)((_flags & ~MQTTFlags.AllowAnonymousLogin) | (value ? MQTTFlags.AllowAnonymousLogin : 0));
    }

    // API...

    override bool validate() const pure
        => true;

    override CompletionStatus startup()
    {
        if (!_server)
        {
            _server = get_module!TCPStreamModule.tcp_servers.create(name, ObjectFlags.Dynamic);
            _server.port = _port ? _port : 1883;
            _server.setConnectionCallback(&new_connection, null);
        }

        if (_server.running)
        {
            writeInfo("MQTT broker listening on port ", _server.port);
            return CompletionStatus.Complete;
        }
        return CompletionStatus.Continue;
    }

    override CompletionStatus shutdown()
    {
        if (_server)
        {
            _server.destroy();
            _server = null;
        }
        return CompletionStatus.Complete;
    }

    override void update()
    {
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
        foreach (ref session; sessions.values)
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
            sessions.remove(items_to_remove[i]);
    }

    void publish(const(char)[] client, ubyte flags, const(char)[] topic, const(ubyte)[] payload, const(ubyte)[] properties = null)
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

        // now notify all the other dubscribers...
        // TODO: scan subscriptions and send...

    }

    void subscribe(ref MQTTClient client, const(char)[] topic)
    {
        // add subscription...
    }

package:
    void destroy_session(ref MQTTSession session)
    {
        send_lwt(session);

        session.client = null;
        session.subs = null;
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

    Map!(const(char)[], MQTTSession) sessions;

private:
    TCPServer _server;
    ushort _port = 1883;
    MQTTFlags _flags;
    Duration _client_timeout;

    Array!MQTTClient _clients;

    // local subs
    // network subs

    // retained values
    struct Value
    {
        Map!(String, Value) children;
        Array!ubyte data;
        Array!ubyte properties;
        ubyte flags;
    }
    Value _root;

    void new_connection(Stream client, void* user_data)
    {
        _clients ~= MQTTClient(this, client);

        writeInfo("MQTT client connected: ", client.remoteName());
    }
}


private:

enum MQTTFlags
{
    None = 0,
    AllowAnonymousLogin = 1 << 0,
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
}
