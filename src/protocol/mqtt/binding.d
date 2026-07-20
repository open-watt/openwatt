module protocol.mqtt.binding;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.profile;
private alias Access = manager.element.Access;
import manager.sample;
import manager.series;

import protocol.mqtt.broker;
import protocol.mqtt.client;
import protocol.mqtt.topic : PublishCallback;

//version = DebugMQTTBinding;

nothrow @nogc:

package __gshared uint mqtt_section_kind;
package __gshared uint mqtt_subscribe_kind;

struct ElementDesc_MQTT
{
    ushort read_topic;
    ushort write_topic;
    ushort desc = ushort.max;

pure nothrow @nogc:
    const(char)[] get_read_topic(ref const Profile profile) const pure
        => profile.get_section_string(read_topic);

    const(char)[] get_write_topic(ref const Profile profile) const pure
        => profile.get_section_string(write_topic);
}

private struct MQTTSubscriptionRange
{
    const(Profile)* profile;
    const(ushort)[] strings;

pure nothrow @nogc:
    bool empty() const pure
        => strings.length == 0;
    const(char)[] front() const pure
        => profile.get_section_string(strings[0]);
    void popFront() pure
    {
        strings = strings[1 .. $];
    }
}

private MQTTSubscriptionRange mqtt_subscriptions(ref const Profile profile) nothrow @nogc
{
    const(void)[] root = profile.get_root_section(mqtt_subscribe_kind);
    if (root.length < ushort.sizeof)
        return MQTTSubscriptionRange(&profile, null);
    const(ushort)[] words = cast(ushort[])root;
    size_t count = words[0];
    if (count + 1 > words.length)
        return MQTTSubscriptionRange(&profile, null);
    return MQTTSubscriptionRange(&profile, words[1 .. count + 1]);
}


class MQTTBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("broker",  broker),
                                 Prop!("client",  client),
                                 Prop!("profile", profile),
                                 Prop!("model",   model));
nothrow @nogc:

    enum type_name = "mqtt-binding";
    enum path = "/binding/mqtt";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!MQTTBinding, id, flags);
    }

    final inout(MQTTBroker) broker() inout pure
        => _broker.get;
    final void broker(MQTTBroker value)
    {
        if (_broker.get is value)
            return;
        detach_source();
        _broker = value;
        if (value)
            _client = null;             // mutually exclusive
        mark_set!(typeof(this), [ "broker", "client" ])();
        restart();
    }

    final inout(MQTTClient) client() inout pure
        => _client.get;
    final void client(MQTTClient value)
    {
        if (_client.get is value)
            return;
        detach_source();
        _client = value;
        if (value)
            _broker = null;             // mutually exclusive
        mark_set!(typeof(this), [ "broker", "client" ])();
        restart();
    }

    final ref const(String) profile() const pure
        => _profile_name;
    final void profile(String value)
    {
        if (value == _profile_name)
            return;
        _profile_name = value.move;
        mark_set!(typeof(this), "profile")();
        restart();
    }

    final ref const(String) model() const pure
        => _model_name;
    final void model(String value)
    {
        if (value == _model_name)
            return;
        _model_name = value.move;
        mark_set!(typeof(this), "model")();
        restart();
    }

    final override bool validate() const pure
    {
        bool has_source = _broker.get !is null || _client.get !is null;
        return has_source && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        ActiveObject src = active_source();
        if (!src || !src.running)
            return CompletionStatus.continue_;

        const(char)[] missing_param;
        const(char)[] get_substitute(size_t, const(char)[] param)
        {
            if (auto value = param in _params)
                return (*value)[];
            if (missing_param is null)
                missing_param = param;
            return null;
        }

        foreach (s; mqtt_subscriptions(*_profile_data))
        {
            bool unclosed_token;
            missing_param = null;
            String sub = String(s.substitute_parameters(&get_substitute, unclosed_token));
            if (missing_param !is null)
            {
                log.warning(name, ": MQTT subscription '", s, "' uses profile parameter '", missing_param, "', but it is not set");
                continue;
            }
            if (unclosed_token || !sub)
            {
                log.warning(name, ": invalid MQTT subscription '", s, "'");
                continue;
            }
            subscribe_filter(sub.move);
        }

        src.subscribe(&state_change);
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        detach_source();
        // Drop write-back delegates before super.shutdown releases the profile.
        foreach (ref se; _elements)
        {
            if (se.element.access & Access.write)
                se.element.remove_subscriber(&on_element_change);
        }
        _elements.clear();
        return super.shutdown();
    }

protected:
    final override const(char)[] profile_name() const pure
        => _profile_name[];
    final override const(char)[] model_name() const pure
        => _model_name[];

    final override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        if (desc.kind != mqtt_section_kind)
            return;
        ref const ElementDesc_MQTT mqtt = _profile_data.get_section!ElementDesc_MQTT(mqtt_section_kind, desc.element);
        SampleDesc sample_desc = desc_by_index(mqtt.desc);

        if (!e.series.format)
            e.series.format = sample_desc.fmt;

        const(char)[] missing_param;
        const(char)[] get_substitute(size_t, const(char)[] param)
        {
            if (auto value = param in _params)
                return (*value)[];
            if (missing_param is null)
                missing_param = param;
            return null;
        }

        String read_topic, write_topic;
        const(char)[] raw = mqtt.get_read_topic(*_profile_data);
        if (raw.length > 0)
        {
            bool unclosed_token;
            missing_param = null;
            read_topic = String(raw.substitute_parameters(&get_substitute, unclosed_token));
            if (missing_param !is null)
            {
                log.warning(name, ": MQTT read topic '", raw, "' uses profile parameter '", missing_param, "', but it is not set");
                return;
            }
            if (unclosed_token)
            {
                log.warning(name, ": unclosed placeholder token in MQTT read topic '", raw, "'");
                return;
            }
        }
        raw = mqtt.get_write_topic(*_profile_data);
        if (raw.length > 0)
        {
            bool unclosed_token;
            missing_param = null;
            write_topic = String(raw.substitute_parameters(&get_substitute, unclosed_token));
            if (missing_param !is null)
            {
                log.warning(name, ": MQTT write topic '", raw, "' uses profile parameter '", missing_param, "', but it is not set");
                return;
            }
            if (unclosed_token)
            {
                log.warning(name, ": unclosed placeholder token in MQTT write topic '", raw, "'");
                return;
            }
        }

        SampleElement* se = &_elements.pushBack();
        se.element = e;
        se.read_topic = read_topic.move;
        se.write_topic = write_topic.move;
        se.desc = sample_desc;

        if (e.access & Access.write)
            e.add_subscriber(&on_element_change);

        device.sample_elements ~= e; // TODO: remove this?
    }

private:

    ObjectRef!MQTTBroker _broker;
    ObjectRef!MQTTClient _client;
    String _profile_name;
    String _model_name;

    bool _subscribed;
    bool _self_write;

    Array!SampleElement _elements;

    struct SampleElement
    {
        Element* element;
        SampleDesc desc;
        String read_topic;
        String write_topic;
    }

    inout(ActiveObject) active_source() inout pure
    {
        if (auto b = _broker.get)
            return b;
        return _client.get;
    }

    void subscribe_filter(String filter)
    {
        if (auto b = _broker.get)
            b.subscribe(filter.move, &on_publish);
        else if (auto c = _client.get)
            c.subscribe(filter.move, &on_publish);
    }

    void publish_value(const(char)[] topic, const(ubyte)[] payload, MonoTime ts)
    {
        if (auto b = _broker.get)
            b.publish(null, 0, topic, payload, null, ts);
        else if (auto c = _client.get)
            c.publish(topic, payload);
    }

    void detach_source()
    {
        if (!_subscribed)
            return;
        if (auto b = _broker.get)
        {
            b.unsubscribe(&state_change);
            b.unsubscribe(&on_publish);
        }
        else if (auto c = _client.get)
        {
            c.unsubscribe(&state_change);
            c.unsubscribe(&on_publish);
        }
        _subscribed = false;
    }

    void state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void on_publish(const(char)[] sender, const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp)
    {
        if (payload.empty)
            return;

        foreach (ref e; _elements)
        {
            if (e.read_topic[] != topic)
                continue;

            const(char)[] payload_str = cast(const(char)[])payload;
            const(DataFormat)* fmt = e.desc.fmt;
            bool sampled;
            _self_write = true;
            scope(exit) _self_write = false;
            if (fmt.is_text)
            {
                e.element.observe_text(payload_str, cast(SysTime)timestamp);
                sampled = true;
            }
            else if (fmt.is_scalar)
            {
                Scalar scalar;
                sampled = parse_record(payload_str, e.desc, scalar.raw[0 .. fmt.stride]);
                if (sampled)
                    e.element.observe_record(scalar.raw[0 .. fmt.stride], cast(SysTime)timestamp);
            }

            if (sampled)
            {
                version (DebugMQTTBinding)
                    writeDebugf("mqtt: sample - topic: {0} value: {1} = {2} (raw: {3})", topic, e.element.id, e.element.value, payload_str);
            }
            else
                log.warning("failed to parse MQTT payload for topic ", topic, ": ", payload_str);
            return;
        }
    }

    void on_element_change(ref Element e, ref const Variant val, SysTime ts, ref const Variant prev, SysTime prev_ts)
    {
        if (_self_write)
            return;

        foreach (ref se; _elements)
        {
            if (se.element != &e)
                continue;
            if (!se.write_topic.empty)
            {
                const(DataFormat)* fmt = se.desc.fmt;
                if (fmt.is_text)
                {
                    if (val.isString)
                        publish_value(se.write_topic[], cast(const(ubyte)[])(val.asString[]), cast(MonoTime)ts);
                }
                else if (fmt.is_scalar)
                {
                    Scalar scalar;
                    char[256] buffer;
                    bool converted = unbox_scalar(val, *fmt, scalar);
                    if (!converted && val.isString)
                        converted = parse_record(val.asString[], se.desc, scalar.raw[0 .. fmt.stride]);
                    if (converted)
                    {
                        ptrdiff_t len = format_record(scalar.raw[0 .. fmt.stride], se.desc, buffer);
                        if (len > 0)
                            publish_value(se.write_topic[], cast(const(ubyte)[])buffer[0 .. len], cast(MonoTime)ts);
                    }
                }
            }
            return;
        }
    }
}
