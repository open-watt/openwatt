module protocol.mqtt.sampler;

import urt.array;
import urt.conv;
import urt.lifetime;
import urt.log;
import urt.mem.string;
import urt.string;
import urt.time;
import urt.variant;

import manager.device;
import manager.element;
import manager.profile;
import manager.sampler;
import manager.subscriber;

import protocol.mqtt.broker;
import protocol.mqtt.client;

//version = DebugMQTTSampler;

nothrow @nogc:


class MQTTSampler : Sampler
{
nothrow @nogc:

    this(MQTTBroker broker, ref Array!String subs)
    {
        import urt.mem.allocator : defaultAllocator;
        this.broker = broker;

        foreach (ref s; subs)
            broker.subscribe(s.move, &on_publish);
    }

    ~this()
    {
        if (broker)
            broker.unsubscribe(&on_publish);
    }

    final void add_element(Element* element, ref const ElementDesc desc, String read_topic, String write_topic, TextValueDesc value_desc)
    {
        SampleElement* e = &elements.pushBack();
        e.element = element;
        e.read_topic = read_topic.move;
        e.write_topic = write_topic.move;
        e.desc = value_desc;

        if (element.access & manager.element.Access.write)
            element.add_subscriber(this);
    }

    final override void remove_element(Element* element)
    {
        for (size_t i = 0; i < elements.length; ++i)
        {
            if (elements[i].element == element)
            {
                // TODO: Unsubscribe from topic if no other elements use it
                elements.removeSwapLast(i);
                return;
            }
        }
    }

    final void on_change(Element* e, ref const Variant val, SysTime timestamp, Subscriber who)
    {
        if (who is this)
            return;

        foreach (ref se; elements)
        {
            if (se.element != e)
                continue;
            if (!se.write_topic.empty)
            {
                const(char)[] text = format_value(val, se.desc);
                broker.publish(null, 0, se.write_topic[], cast(const(ubyte)[])text, null, cast(MonoTime)timestamp);
            }
            return;
        }
    }

    final void on_publish(const(char)[] sender, const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp)
    {
        // empty payload is generally a request for data...
        if (payload.empty)
            return;

        foreach (ref e; elements)
        {
            if (e.read_topic[] != topic)
                continue;

            // Parse payload as UTF-8 text and convert to Variant
            const(char)[] payload_str = cast(const(char)[])payload;
            Variant value = sample_value(payload_str, e.desc);

            if (value != Variant())
            {
                e.element.value(value, cast(SysTime)timestamp, this);

                version (DebugMQTTSampler)
                    writeDebugf("mqtt: sample - topic: {0} value: {1} = {2} (raw: {3})", topic, e.element.id, e.element.value, cast(const(char)[])payload);
            }
            else
                writeWarning("Failed to parse MQTT payload for topic ", topic, ": ", payload_str);
            break;
        }
    }

private:

    MQTTBroker broker;
    Array!SampleElement elements;

    struct SampleElement
    {
        MonoTime last_update;
        Element* element;
        TextValueDesc desc;
        String read_topic;
        String write_topic;
    }
}
