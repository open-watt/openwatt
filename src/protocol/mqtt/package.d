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

        // Resolve profile parameters from named args
        const(char)[][32] names = void, values = void;
        auto profile_params = profile.get_parameters;
        if (profile_params.length > names.length)
        {
            session.write_line("Too many variables for profile '", _profile, "'");
            g_app.allocator.freeT(profile);
            return;
        }

        size_t n;
        outer: foreach (ref var; profile_params)
        {
            names[n] = var;
            foreach (ref arg; named_args)
            {
                if (arg.name == var)
                {
                    values[n++] = arg.value.asString();
                    continue outer;
                }
            }
            session.write_line("Missing required variable '", var, "' for profile '", _profile, '\'');
            g_app.allocator.freeT(profile);
            return;
        }
        const(char)[][] var_names = names[0 .. n];
        const(char)[][] var_values = values[0 .. n];

        bool sub_failed = false;
        const(char)[] get_substitute(size_t, const(char)[] param)
        {
            foreach (i, v; var_names)
            {
                if (v[] != param[])
                    continue;
                return var_values[i];
            }
            sub_failed = true;
            return null;
        }

        auto subs = Array!String(Reserve, profile.get_mqtt_subs.length);
        foreach (s; profile.get_mqtt_subs)
        {
            String sub = s.substitute_parameters(&get_substitute, sub_failed);
            if (sub_failed || !sub)
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
                read_topic = String(raw_topic.substitute_parameters(&get_substitute, sub_failed));
                if (sub_failed || !read_topic)
                {
                    session.write_line("Failed to substitute variables in topic '", raw_topic, '\'');
                    return;
                }
            }

            raw_topic = mqtt.get_write_topic(*profile);
            if (raw_topic.length > 0)
            {
                write_topic = String(raw_topic.substitute_parameters(&get_substitute, sub_failed));
                if (sub_failed || !write_topic)
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
