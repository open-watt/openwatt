module protocol.mqtt;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.string;

import manager.collection;
import manager.console;
import manager.plugin;
import manager.profile;

import protocol.mqtt.broker;
import protocol.mqtt.sampler;

nothrow @nogc:

class MQTTModule : Module
{
    mixin DeclareModule!"protocol.mqtt";
nothrow @nogc:

    Collection!MQTTBroker brokers;

    override void init()
    {
        g_app.console.register_collection("/protocol/mqtt/broker", brokers);
        g_app.console.register_command!device_add("/protocol/mqtt/device", this, "add");
    }

    override void update()
    {
        brokers.update_all();
    }

    void device_add(Session session, const(char)[] id, MQTTBroker broker, const(char)[] _profile, Nullable!(const(char)[]) name, Nullable!(const(char)[]) model, const(NamedArgument)[] named_args)
    {
        import manager.component;
        import manager.device;
        import manager.element;
        import urt.file;
        import urt.si;
        import urt.string.format;

        if (!_profile)
        {
            session.write_line("No profile specified");
            return;
        }

        void[] file = load_file(tconcat("conf/mqtt_profiles/", _profile, ".conf"), g_app.allocator);
        Profile* profile = parse_profile(cast(char[])file, g_app.allocator);

        // gather and match the variables with the given values...
        const(char)[][64] variables;
        size_t num_vars = profile.get_mqtt_vars.length;
        if (num_vars > variables.length / 2)
        {
            session.write_line("Too many variables for profile '", _profile, "'");
            g_app.allocator.freeT(profile);
            return;
        }

        size_t offset = 0;
        foreach (var; profile.get_mqtt_vars)
            variables[offset++] = var;
        outer: foreach (var; profile.get_mqtt_vars)
        {
            foreach (ref arg; named_args)
            {
                if (arg.name == var)
                {
                    variables[offset++] = arg.value.asString();
                    continue outer;
                }
            }
            session.write_line("Missing required variable '", var, "' for profile '", _profile, '\'');
            g_app.allocator.freeT(profile);
            return;
        }
        const(char)[][] var_names = variables[0 .. offset / 2];
        const(char)[][] var_values = variables[offset / 2 .. offset];

        auto subs = Array!String(Reserve, profile.get_mqtt_subs.length);
        foreach (s; profile.get_mqtt_subs)
        {
            String sub = s.substitute_variables(var_names, var_values);
            if (!sub)
            {
                session.write_line("Failed to substitute variables in subscription '", s, '\'');
                g_app.allocator.freeT(profile);
                return;
            }
            else
                subs ~= sub;
        }

        // create a sampler for this can interface...
        MQTTSampler sampler = g_app.allocator.allocT!MQTTSampler(broker, subs.move);

        Device device = create_device_from_profile(*profile, model ? model.value : null, id, name ? name.value : null, (Device device, Element* e, ref const ElementDesc desc, ubyte) {
            assert(desc.type == ElementType.mqtt);
            ref const ElementDesc_MQTT mqtt = profile.get_mqtt(desc.element);

            // substitute variable names for their given values
            String read_topic, write_topic;
            const(char)[] raw_topic = mqtt.get_read_topic(*profile);
            if (raw_topic.length > 0)
            {
                read_topic = raw_topic.substitute_variables(var_names, var_values);
                if (!read_topic)
                {
                    session.write_line("Failed to substitute variables in topic '", raw_topic, '\'');
                    return;
                }
            }

            raw_topic = mqtt.get_write_topic(*profile);
            if (raw_topic.length > 0)
            {
                write_topic = raw_topic.substitute_variables(var_names, var_values);
                if (!write_topic)
                {
                    session.write_line("Failed to substitute variables in topic '", raw_topic, '\'');
                    return;
                }
            }

//            // write a null value of the proper type
//            ubyte[256] tmp = void;
//            tmp[0 .. can.value_desc.data_length] = 0;
//            e.value = sample_value(tmp.ptr, mqtt.value_desc);

            // record samper data...
            sampler.add_element(e, desc, read_topic.move, write_topic.move, mqtt.value_desc);
            device.sample_elements ~= e; // TODO: remove this?
        });
        if (!device)
        {
            session.write_line("Failed to create device '", id, "'");
            g_app.allocator.freeT(profile);
            g_app.allocator.freeT(sampler);
            return;
        }

        device.samplers ~= sampler;
    }
}


private:

static String substitute_variables(const(char)[] pattern, const(char)[][] var_names, const(char)[][] var_values)
{
    char[256] buffer;
    size_t i, j;
    outer: while (i < pattern.length)
    {
        if (pattern[i] != '{')
        {
            if (j >= buffer.length)
                return String();
            buffer[j++] = pattern[i++];
            continue;
        }

        size_t tok_end = pattern[i .. $].findFirst('}');
        if (tok_end == pattern.length - i)
            return String(); // unclosed token
        const(char)[] var = pattern[i + 1 .. tok_end - i];

        // find var
        foreach (k, v; var_names)
        {
            if (v != var)
                continue;

            const(char)[] value = var_values[k];
            if (j + value.length >= buffer.length)
                return String(); // overflow
            buffer[j .. j + value.length] = value;
            i = tok_end + 1;
            j += value.length;
            continue outer;
        }
        return String(); // var not found
    }
    return buffer[0 .. j].makeString(defaultAllocator());
}
