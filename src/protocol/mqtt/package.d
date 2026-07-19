module protocol.mqtt;

import urt.meta.nullable;
import urt.mem.allocator;
import urt.string;

import manager;
import manager.collection;
import manager.config : ConfItem;
import manager.console;
import manager.plugin;
import manager.profile;
import manager.spec : stream_le_context;

import protocol.mqtt.binding;
import protocol.mqtt.broker;
import protocol.mqtt.client;
import protocol.mqtt.codec;
import protocol.mqtt.topic : validate_topic_name;

nothrow @nogc:


class MQTTModule : Module, ProfileSections, ProfileRootSections
{
    mixin DeclareModule!"protocol.mqtt";
nothrow @nogc:

    override void init()
    {
        register_profile_handlers(this);

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

    uint element_size(uint)
        => cast(uint)ElementDesc_MQTT.sizeof;

    void count_element(uint, ref const ConfItem item, ref ProfileCosts costs)
    {
        const(char)[] tail = item.value;
        costs.add_string(tail.split!','.unQuote);
        foreach (ref sub; item.sub_items)
        {
            if (sub.name == "write")
            {
                tail = sub.value;
                costs.add_string(tail.split!','.unQuote);
                break;
            }
        }
    }

    bool parse_element(uint, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        ElementDesc_MQTT* mqtt = cast(ElementDesc_MQTT*)slot.ptr;
        *mqtt = ElementDesc_MQTT.init;

        const(char)[] tail = item.value;
        const(char)[] topic = tail.split!','.unQuote;
        const(char)[] type = tail.split!','.unQuote;
        const(char)[] following = tail.split!','.unQuote;
        mqtt.read_topic = b.intern(topic);

        foreach (ref sub; item.sub_items)
        {
            if (sub.name != "write")
                continue;
            const(char)[] write_tail = sub.value;
            mqtt.write_topic = b.intern(write_tail.split!','.unQuote);
            break;
        }

        const(char)[] access = type;
        const(char)[] value_type = access.split!('/', false);
        switch (value_type)
        {
            case "num":      value_type = "f64"; break;
            case "enum":     value_type = "enum64"; break;
            case "bf":       value_type = "bf64"; break;
            case "macaddr":  value_type = "mac"; break;
            case "ipaddr":   value_type = "ipv4"; break;
            case "ip6addr":  value_type = "ipv6"; break;
            default: break;
        }

        ubyte ignored_span;
        if (!b.compile_value(value_type, following, stream_le_context, mqtt.desc, ignored_span))
            return false;

        bool following_access = following == "R" || following == "W" || following == "RW";
        if (!access.empty)
        {
            if (access == "RW")
                b.access(Access.read_write);
            else if (access == "W")
                b.access(Access.write);
            else
                b.access(Access.read);
        }
        else if (!following_access && mqtt.write_topic)
            b.access(mqtt.read_topic ? Access.read_write : Access.write);
        return true;
    }

    uint root_size(uint, ref const ConfItem item)
    {
        uint count;
        const(char)[] tail = item.value;
        while (!tail.empty)
            if (!tail.split!','.unQuote.empty)
                ++count;
        return cast(uint)((count + 1) * ushort.sizeof);
    }

    void count_root(uint, ref const ConfItem item, ref ProfileCosts costs)
    {
        const(char)[] tail = item.value;
        while (!tail.empty)
            costs.add_string(tail.split!','.unQuote);
    }

    bool parse_root(uint, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        ushort[] words = (cast(ushort*)slot.ptr)[0 .. slot.length / ushort.sizeof];
        words[0] = 0;
        const(char)[] tail = item.value;
        while (!tail.empty)
        {
            const(char)[] subscription = tail.split!','.unQuote;
            if (subscription.empty)
                continue;
            words[++words[0]] = b.intern(subscription);
        }
        return true;
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

unittest
{
    import manager.sample : desc_by_index;
    import manager.series : ValueType;

    MQTTModule module_ = defaultAllocator().allocT!MQTTModule(null);
    register_profile_handlers(module_);

    static immutable string conf =
        "parameters: device_id\n" ~
        "mqtt-subscribe: \"#\"\n" ~
        "elements:\n" ~
        "\tmqtt: {device_id}/state/get, bool, RW\tdesc: state\n" ~
        "\t\twrite: {device_id}/state/set\n" ~
        "device-template:\n" ~
        "\tcomponent:\n" ~
        "\t\tid: status\n" ~
        "\t\telement-map: state, @state\n";

    Profile* profile = parse_profile(conf, "mqtt-test");
    assert(profile !is null && profile.find_element("state") == 0);

    DeviceTemplate* device = profile.get_model_template(null);
    assert(device !is null);
    auto components = device.components(*profile);
    assert(!components.empty);
    auto elements = components.front().elements(*profile);
    assert(!elements.empty);
    ref ElementTemplate element = elements.front();
    assert(element.access == manager.profile.Access.read_write);
    assert(element.get_element_desc(*profile).kind == mqtt_section_kind);

    ref const ElementDesc_MQTT mqtt = profile.get_section!ElementDesc_MQTT(mqtt_section_kind, 0);
    assert(mqtt.get_read_topic(*profile) == "{device_id}/state/get");
    assert(mqtt.get_write_topic(*profile) == "{device_id}/state/set");
    assert(desc_by_index(mqtt.desc).fmt.type == ValueType.bool_);

    const(void)[] root = profile.get_root_section(mqtt_subscribe_kind);
    assert(root.length == ushort.sizeof * 2);
    const(ushort)[] words = (cast(const(ushort)*)root.ptr)[0 .. 2];
    assert(words[0] == 1);
    assert(profile.get_section_string(words[1]) == "#");
}

private:

void register_profile_handlers(MQTTModule module_)
{
    if (!mqtt_section_kind)
        mqtt_section_kind = register_profile_section("mqtt", module_);
    if (!mqtt_subscribe_kind)
        mqtt_subscribe_kind = register_profile_root_section("mqtt-subscribe", module_);
}
