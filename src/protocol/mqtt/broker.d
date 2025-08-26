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


struct MQTTClientCredentials
{
    this(this) @disable;

    String username;
    String password;
    Array!String whitelist;
    Array!String blacklist;
}

struct MQTTBrokerOptions
{
nothrow @nogc:
    this(this) @disable;
    this(ref MQTTBrokerOptions rh)
    {
        this.port = rh.port;
        this.flags = rh.flags;
        this.clientCredentials = rh.clientCredentials;
        this.clientTimeoutOverride = rh.clientTimeoutOverride;
    }

    enum Flags
    {
        None = 0,
        AllowAnonymousLogin = 1 << 0,
    }

    ushort port = 1883;
    Flags flags = Flags.None;
    Array!MQTTClientCredentials clientCredentials;
    uint clientTimeoutOverride = 0; // maximum time since last contact before client is presumed awol
}

struct MQTTSession
{
    this(this) @disable;

    struct Subscription
    {
        String topic;
        ubyte options;
    }

    String identifier;
    Client* client;

    uint sessionExpiryInterval = 0;

    MonoTime closeTime;

    Array!Subscription subs;
    Map!(const(char)[], Subscription*) subsByFilter;

    // last will and testament
    String willTopic;
    Array!ubyte willMessage;
    Array!ubyte willProps;
    uint willDelay;
    ubyte willFlags;
    bool willSent;

    // publish state
    ushort packetId = 1;

    // TODO: pending messages...
    ubyte[] pendingMessages;
}

class MQTTBroker : BaseObject
{
    __gshared Property[3] Properties = [ Property.create!("port", port)(),
                                         Property.create!("allow-anonymous", allow_anonymous)(),
                                         Property.create!("client-timeout", _client_timeout)() ];
nothrow @nogc:

    alias TypeName = StringLit!"mqqt-broker";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collectionTypeInfo!MQTTBroker, name.move, flags);
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
        => (_flags & MQTTBrokerOptions.Flags.AllowAnonymousLogin) != 0;
    void allow_anonymous(bool value)
    {
        _flags = cast(MQTTBrokerOptions.Flags)((_flags & ~MQTTBrokerOptions.Flags.AllowAnonymousLogin) | (value ? MQTTBrokerOptions.Flags.AllowAnonymousLogin : 0));
    }

    // API...

    override bool validate() const pure
        => true;

    override CompletionStatus startup()
    {
        if (!_server)
        {
            _server = getModule!TCPStreamModule.tcp_servers.create(name, ObjectFlags.Dynamic);
            _server.port = _port ? _port : 1883;
            _server.setConnectionCallback(&newConnection, null);
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
        const(char)[][16] itemsToRemove;
        size_t numItemsToRemove = 0;
        foreach (ref session; sessions.values)
        {
            if (session.client)
                continue;

            if (session.sessionExpiryInterval != 0xFFFFFFFF)
            {
                if (now - session.closeTime >= session.sessionExpiryInterval.seconds)
                {
                    // session expired
                    if (numItemsToRemove == 16)
                        break;
                    itemsToRemove[numItemsToRemove++] = session.identifier;
                }
            }
        }
        foreach (i; 0 .. numItemsToRemove)
            sessions.remove(itemsToRemove[i]);
    }

    void publish(const(char)[] client, ubyte flags, const(char)[] topic, const(ubyte)[] payload, const(ubyte)[] properties = null)
    {
        Value* getRecord(Value* val, const(char)[] topic)
        {
            char sep;
            const(char)[] level = topic.split!'/'(sep);
            Value* child = level in val.children;
            if (!child)
                child = val.children.insert(level.makeString(defaultAllocator()), Value());
            if (sep == 0)
                return child;
            return getRecord(child, topic);
        }

        void deleteRecord(Value* val, const(char)[] topic) nothrow @nogc
        {
            char sep;
            const(char)[] level = topic.split!'/'(sep);
            Value* child = level in val.children;
            if (sep == 0)
                child.data = null;
            else if(child)
                deleteRecord(child, topic);
            if (child.children.empty)
                val.children.remove(level);
        }

        // retain message and/or push to subscribers...
        ubyte qos = (flags >> 1) & 3;
        bool retain = (flags & 1) != 0;
        bool dup = (flags & 8) != 0;

        if (payload.empty)
        {
            deleteRecord(&root, topic);
            return;
        }

        if (retain)
        {
            Value* value = getRecord(&root, topic);
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

    void subscribe(Client client, const(char)[] topic)
    {
        // add subscription...
    }

package:
    void destroySession(ref MQTTSession session)
    {
        sendLWT(session);

        session.client = null;
        session.subs = null;
        session.subsByFilter.clear();
        session.willTopic = null;
        session.willMessage = null;
        session.willProps = null;
        session.willDelay = 0;
        session.willFlags = 0;
        session.packetId = 1;
    }

    void sendLWT(ref MQTTSession session)
    {
        if (!session.willTopic || session.willSent)
            return;
        publish(session.identifier, session.willFlags, session.willTopic, session.willMessage[], session.willProps[]);
        session.willSent = true;
    }

    Map!(const(char)[], MQTTSession) sessions;

private:
    TCPServer _server;
    ushort _port = 1883;
    MQTTBrokerOptions.Flags _flags;
    Duration _client_timeout;

//    const MQTTBrokerOptions options; // TODO: reinstate options!

    Array!Client _clients;

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
    Value root;

    void newConnection(TCPStream client, void* userData)
    {
        _clients ~= Client(this, client);

        writeInfo("MQTT client connected: ", client.remoteName());
    }
}
