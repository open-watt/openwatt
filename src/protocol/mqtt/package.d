module protocol.mqtt;

import urt.meta.nullable;
import urt.string;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.mqtt.binding;
import protocol.mqtt.broker;
import protocol.mqtt.client;
import protocol.mqtt.codec;
import protocol.mqtt.topic : validate_topic_name;

nothrow @nogc:


class MQTTModule : Module
{
    mixin DeclareModule!"protocol.mqtt";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!ProtocolLevel();

        g_app.console.register_collection!MQTTBroker();
        g_app.console.register_collection!MQTTClient();
        g_app.console.register_collection!MQTTBinding();

        g_app.console.register_command!retained("/protocol/mqtt/broker", this, "retained");
        g_app.console.register_command!cache("/protocol/mqtt/broker", this, "cache");
        g_app.console.register_command!read("/protocol/mqtt/broker", this, "read");
        g_app.console.register_command!sessions("/protocol/mqtt/broker", this, "sessions");
        g_app.console.register_command!subscriptions("/protocol/mqtt/broker", this, "subscriptions");
        g_app.console.register_command!local_publish("/protocol/mqtt/broker", this, "publish");

        g_app.console.register_command!client_publish("/protocol/mqtt/client", this, "publish");
    }

    void retained(Session session, Nullable!MQTTBroker broker, Nullable!String filter)
    {
        MQTTBroker b = resolve_broker(session, broker);
        if (!b)
            return;

        b.print_retained(session, filter ? filter.value[] : "#");
    }

    void cache(Session session, Nullable!MQTTBroker broker, Nullable!String filter)
    {
        MQTTBroker b = resolve_broker(session, broker);
        if (!b)
            return;

        b.print_cache(session, filter ? filter.value[] : "#");
    }

    void read(Session session, String topic, Nullable!MQTTBroker broker)
    {
        MQTTBroker b = resolve_broker(session, broker);
        if (!b)
            return;

        b.print_cache(session, topic[]);
    }

    void sessions(Session session, Nullable!MQTTBroker broker)
    {
        MQTTBroker b = resolve_broker(session, broker);
        if (b)
            b.print_sessions(session);
    }

    void subscriptions(Session session, Nullable!MQTTBroker broker)
    {
        MQTTBroker b = resolve_broker(session, broker);
        if (b)
            b.print_subscriptions(session);
    }

    void local_publish(Session session, String topic, String payload, Nullable!MQTTBroker broker, Nullable!bool retain, Nullable!String client_id)
    {
        MQTTBroker b = resolve_broker(session, broker);
        if (!b)
            return;
        if (!validate_topic_name(topic[]))
        {
            session.write_line("Invalid MQTT topic name");
            return;
        }

        bool retain_value = retain ? retain.value : false;
        const(char)[] publisher = client_id ? client_id.value[] : "console";
        b.publish(publisher, retain_value ? 0x01 : 0x00, topic[], cast(const(ubyte)[])(payload[]));
        session.write_line(retain_value ? "Published retained MQTT message" : "Published MQTT message");
    }

    void client_publish(Session session, String topic, String payload, Nullable!MQTTClient client, Nullable!bool retain)
    {
        MQTTClient c = resolve_client(session, client);
        if (!c)
            return;
        if (!c.running)
        {
            session.write_line("MQTT client is not running");
            return;
        }
        if (!validate_topic_name(topic[]))
        {
            session.write_line("Invalid MQTT topic name");
            return;
        }

        bool retain_value = retain ? retain.value : false;
        c.publish(topic[], cast(const(ubyte)[])(payload[]), 0, retain_value);
        session.write_line(retain_value ? "Published retained MQTT message via client" : "Published MQTT message via client");
    }

    override void update()
    {
        Collection!MQTTBroker().update_all();
        Collection!MQTTClient().update_all();
    }

private:
    MQTTBroker resolve_broker(Session session, Nullable!MQTTBroker broker)
    {
        if (broker)
            return broker.value;

        MQTTBroker found;
        uint count;
        foreach (obj; Collection!MQTTBroker().values)
        {
            found = cast(MQTTBroker)obj;
            ++count;
            if (count > 1)
                break;
        }

        if (count == 0)
            session.write_line("No MQTT brokers exist");
        else if (count > 1)
            session.write_line("Multiple MQTT brokers exist; pass broker=<broker>");
        return count == 1 ? found : null;
    }

    MQTTClient resolve_client(Session session, Nullable!MQTTClient client)
    {
        if (client)
            return client.value;

        MQTTClient found;
        uint count;
        foreach (obj; Collection!MQTTClient().values)
        {
            found = cast(MQTTClient)obj;
            ++count;
            if (count > 1)
                break;
        }

        if (count == 0)
            session.write_line("No MQTT clients exist");
        else if (count > 1)
            session.write_line("Multiple MQTT clients exist; pass client=<client>");
        return count == 1 ? found : null;
    }
}
