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
        e.write_topic =write_topic.move;
        e.desc = value_desc;
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
            Variant value = parse_mqtt_payload(payload_str, e.desc);

            if (value != Variant())
            {
                e.element.value = value;

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

Variant parse_mqtt_payload(const(char)[] payload, ref const TextValueDesc desc)
{
    import urt.inet;

    final switch (desc.type) with (TextType)
    {
        case bool_:
            if (payload.ieq("true") || payload.ieq("1") || payload.ieq("on"))
                return Variant(true);
//            if (payload.ieq("false") || payload.ieq("0") || payload.ieq("off"))
//                return Variant(false);
            return Variant(false); // ...or should we record a null? (probable downstream errors...)

        case num:
            import urt.si.quantity;

            size_t taken;
            int e;
            uint base;
            long raw_value = parse_int_with_exponent_and_base(payload, e, base, &taken);
            if (taken == 0)
                return Variant(0); // ...or should we record a null? (probable downstream errors...)

            if (e == 0 && desc.pre_scale == 1)
                return Variant(Quantity!long(raw_value, desc.unit));

            // TODO: handle this better; split the int and float cases...
            double value = raw_value * double(base)^^e;

            if (desc.pre_scale != 1)
                return Variant(Quantity!double(value * desc.pre_scale, desc.unit));

            return Variant(Quantity!double(value, desc.unit));

        case str:
            // Return string as-is (just use the slice, no allocation needed)
            return Variant(payload);

        case dt:
            SysTime t;
            if (t.fromString(payload) <= 0)
                return Variant(SysTime());
            return Variant(t);

        case ipaddr:
            IPAddr ip;
            if (ip.fromString(payload) <= 0)
                return Variant(IPAddr());
            return Variant(ip);

        case ip6addr:
            IPv6Addr ip6;
            if (ip6.fromString(payload) <= 0)
                return Variant(IPv6Addr());
            return Variant(ip6);
    }
}
