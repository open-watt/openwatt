module protocol.esphome;

import urt.meta.nullable;
import urt.string;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;

import protocol.esphome.client;
import protocol.esphome.protobuf;
import protocol.esphome.sampler;

nothrow @nogc:


mixin LoadProtobuf!"protocol/esphome/api.proto";


class ESPHomeModule : Module
{
    mixin DeclareModule!"protocol.esphome";
nothrow @nogc:

    Collection!ESPHomeClient clients;

    override void init()
    {
        g_app.console.register_collection("/protocol/esphome/client", clients);
        g_app.console.register_command!device_add("/protocol/esphome/device", this, "add");
    }

    override void update()
    {
        clients.update_all();
    }

    void device_add(Session session, const(char)[] id, ESPHomeClient client, Nullable!(const(char)[]) _profile, Nullable!(const(char)[]) name)
    {
        import manager.component;
        import manager.device;
        import manager.element;
        import urt.file;
        import urt.si;
        import urt.string.format;

//        if (!_profile)
//        {
//            session.write_line("No profile specified");
//            return;
//        }
//
//        void[] file = load_file(tconcat("conf/ha_profiles/", _profile, ".conf"), g_app.allocator);
//        Profile* profile = parse_profile(cast(char[])file, g_app.allocator);

        Device device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
        if (name)
            device.name = name.value.makeString(g_app.allocator);

        // create a sampler for this can interface...
        ESPHomeSampler sampler = g_app.allocator.allocT!ESPHomeSampler(device, client);
        device.samplers ~= sampler;

//        Device device = create_device_from_profile(*profile, model ? model.value : null, id, name ? name.value : null, (Device device, Element* e, ref const ElementDesc desc, ubyte) {
//            assert(desc.type == ElementType.mqtt);
//            ref const ElementDesc_MQTT mqtt = profile.get_mqtt(desc.element);
//
//            // substitute variable names for their given values
//            String read_topic, write_topic;
//            const(char)[] raw_topic = mqtt.get_read_topic(*profile);
//            if (raw_topic.length > 0)
//            {
//                read_topic = raw_topic.substitute_variables(var_names, var_values);
//                if (!read_topic)
//                {
//                    session.write_line("Failed to substitute variables in topic '", raw_topic, '\'');
//                    return;
//                }
//            }
//
//            raw_topic = mqtt.get_write_topic(*profile);
//            if (raw_topic.length > 0)
//            {
//                write_topic = raw_topic.substitute_variables(var_names, var_values);
//                if (!write_topic)
//                {
//                    session.write_line("Failed to substitute variables in topic '", raw_topic, '\'');
//                    return;
//                }
//            }
//
////            // write a null value of the proper type
////            ubyte[256] tmp = void;
////            tmp[0 .. can.value_desc.data_length] = 0;
////            e.value = sample_value(tmp.ptr, mqtt.value_desc);
//
//            // record samper data...
//            sampler.add_element(e, desc, read_topic.move, write_topic.move, mqtt.value_desc);
//            device.sample_elements ~= e; // TODO: remove this?
//        });
        if (!device)
        {
            session.write_line("Failed to create device '", id, "'");
//            g_app.allocator.freeT(profile);
            g_app.allocator.freeT(sampler);
            return;
        }
        // TODO: HACK - this should have an API around it!
        g_app.devices.insert(device.id[], device);

        device.samplers ~= sampler;
    }
}
