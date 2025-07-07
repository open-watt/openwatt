module protocol.mqtt.broker;

import core.sync.mutex;

import std.range : empty;

import urt.string;
import urt.time;

import protocol.mqtt.client;

import router.stream;
import router.stream.tcp;


struct MQTTClientCredentials
{
    string username;
    string password;
    string[] whitelist;
    string[] blacklist;
}

struct MQTTBrokerOptions
{
    enum Flags
    {
        None = 0,
        AllowAnonymousLogin = 1 << 0,
    }

    ushort port = 1883;
    Flags flags = Flags.None;
    MQTTClientCredentials[] clientCredentials;
    uint clientTimeoutOverride = 0; // maximum time since last contact before client is presumed awol
}

struct Session
{
    struct Subscription
    {
        string topic;
        ubyte options;
    }

    string identifier;
    Client* client;

    uint sessionExpiryInterval = 0;

    MonoTime closeTime;

    Subscription[] subs;
    Subscription*[string] subsByFilter;

    // last will and testament
    string willTopic;
    immutable(ubyte)[] willMessage;
    immutable(ubyte)[] willProps;
    uint willDelay;
    ubyte willFlags;
    bool willSent;

    // publish state
    ushort packetId = 1;

    // TODO: pending messages...
    ubyte[] pendingMessages;
}

class MQTTBroker
{
    const MQTTBrokerOptions options;

//    TCPServer server;
    Stream[] newConnections;
    Client[] clients;
    Session[string] sessions;
    Mutex mutex;

    // local subs
    // network subs

    // retained values
    struct Value
    {
        Value[string] children;
        immutable(ubyte)[] data;
        immutable(ubyte)[] properties;
        ubyte flags;
    }
    Value root;

    this(ref MQTTBrokerOptions options = MQTTBrokerOptions())
    {
        this.options = options;
        mutex = new Mutex;
//        server = new TCPServer(options.port, &newConnection, cast(void*)this);
    }

    void start()
    {
//        server.start();
    }

    void stop()
    {
//        server.stop();
    }

    void update()
    {
        mutex.lock();
        while (!newConnections.empty)
        {
            clients ~= Client(this, newConnections[0]);
            newConnections = newConnections[1 .. $];
        }
        mutex.unlock();

        // update clients
        for (size_t i = 0; i < clients.length; ++i)
        {
            if (!clients[i].update())
            {
                // destroy client...
                clients[i].terminate();
                for (size_t j = i + 1; j < clients.length; ++j)
                    clients[j - 1] = clients[j];
                --clients.length;
            }
        }

        // update sessions
        MonoTime now = getTime();
        string[16] itemsToRemove;
        size_t numItemsToRemove = 0;
        foreach (ref session; sessions)
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
                child = &(val.children[level.idup] = Value());
            if (sep == 0)
                return child;
            return getRecord(child, topic);
        }

        void deleteRecord(Value* val, const(char)[] topic)
        {
            char sep;
            const(char)[] level = topic.split!'/'(sep);
            Value* child = level in val.children;
            if (sep == 0)
                child.data = null;
            else if(child)
                deleteRecord(child, topic);
            if (child.children.empty)
                val.children.remove(level.idup); // TODO: chech why this idup? seems unnecessary!
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
                value.data = payload.idup;
                value.properties = properties ? properties.idup : null;
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
    void destroySession(ref Session session)
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

    void sendLWT(ref Session session)
    {
        if (!session.willTopic || session.willSent)
            return;
        publish(session.identifier, session.willFlags, session.willTopic, session.willMessage, session.willProps);
        session.willSent = true;
    }

private:
    static void newConnection(TCPStream client, void* userData)
    {
        MQTTBroker _this = cast(MQTTBroker)userData;

        client.setOpts(StreamOptions.NonBlocking);

        _this.mutex.lock();
        _this.newConnections ~= client;
        _this.mutex.unlock();
    }
}
