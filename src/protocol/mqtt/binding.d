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
import manager.sampler;

import protocol.mqtt.broker;
import protocol.mqtt.client;
import protocol.mqtt.topic : PublishCallback;

//version = DebugMQTTBinding;

nothrow @nogc:


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

        bool sub_failed;
        const(char)[] get_substitute(size_t, const(char)[] param)
        {
            const(char)[] v = get_param(param);
            if (v is null)
                sub_failed = true;
            return v;
        }

        foreach (s; _profile_data.get_mqtt_subs)
        {
            sub_failed = false;
            String sub = String(s.substitute_parameters(&get_substitute, sub_failed));
            if (sub_failed || !sub)
            {
                log.warning("failed to substitute variables in subscription '", s, "'");
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
    final override const(char)[] profile_dir() const pure
        => "conf/mqtt_profiles/";
    final override const(char)[] profile_name() const pure
        => _profile_name[];
    final override const(char)[] model_name() const pure
        => _model_name[];

    final override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        assert(desc.type == ElementType.mqtt);
        ref const ElementDesc_MQTT mqtt = _profile_data.get_mqtt(desc.element);

        bool sub_failed;
        const(char)[] get_substitute(size_t, const(char)[] param)
        {
            const(char)[] v = get_param(param);
            if (v is null)
                sub_failed = true;
            return v;
        }

        String read_topic, write_topic;
        const(char)[] raw = mqtt.get_read_topic(*_profile_data);
        if (raw.length > 0)
        {
            sub_failed = false;
            read_topic = String(raw.substitute_parameters(&get_substitute, sub_failed));
            if (sub_failed)
            {
                log.warning("failed to substitute variables in topic '", raw, "'");
                return;
            }
        }
        raw = mqtt.get_write_topic(*_profile_data);
        if (raw.length > 0)
        {
            sub_failed = false;
            write_topic = String(raw.substitute_parameters(&get_substitute, sub_failed));
            if (sub_failed)
            {
                log.warning("failed to substitute variables in topic '", raw, "'");
                return;
            }
        }

        SampleElement* se = &_elements.pushBack();
        se.element = e;
        se.read_topic = read_topic.move;
        se.write_topic = write_topic.move;
        se.desc = mqtt.value_desc;

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
        TextValueDesc desc;
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
            Variant value = sample_value(payload_str, e.desc);

            if (value != Variant())
            {
                _self_write = true;
                scope(exit) _self_write = false;
                e.element.value(value, cast(SysTime)timestamp);

                version (DebugMQTTBinding)
                    writeDebugf("mqtt: sample - topic: {0} value: {1} = {2} (raw: {3})", topic, e.element.id, e.element.value, cast(const(char)[])payload);
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
                const(char)[] text = format_value(val, se.desc);
                publish_value(se.write_topic[], cast(const(ubyte)[])text, cast(MonoTime)ts);
            }
            return;
        }
    }
}
