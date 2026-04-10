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

    override void init()
    {
        g_app.console.register_collection!ESPHomeClient("/protocol/esphome/client");
        g_app.console.register_command!device_add("/protocol/esphome/device", this, "add");
    }

    override void update()
    {
        Collection!ESPHomeClient().update_all();
    }

    void device_add(Session session, const(char)[] id, ESPHomeClient client, Nullable!(const(char)[]) _profile, Nullable!(const(char)[]) name)
    {
        import manager.device;
        import manager.element;
        import manager.profile;
        import urt.file;
        import urt.mem.temp : tconcat;

        Device device;

        if (_profile)
        {
            void[] file = load_file(tconcat("conf/ha_profiles/", _profile.value, ".conf"), g_app.allocator);
            if (!file)
            {
                session.write_line("Failed to load profile '", _profile.value, "'");
                return;
            }
            Profile* profile = parse_profile(cast(char[])file, g_app.allocator);
            if (!profile)
            {
                session.write_line("Failed to parse profile '", _profile.value, "'");
                return;
            }

            device = create_device_from_profile(*profile, null, id, name ? name.value : null, (Device, Element*, ref const ElementDesc, ubyte) {
                assert(false, "Should not have map elements");
            });
            if (!device)
            {
                session.write_line("Failed to create device '", id, "'");
                g_app.allocator.freeT(profile);
                return;
            }
            device.profile = profile;
        }
        else
        {
            device = g_app.allocator.allocT!Device(id.makeString(g_app.allocator));
            if (name)
                device.name = name.value.makeString(g_app.allocator);
            g_app.devices.insert(device.id[], device);
        }

        ESPHomeSampler sampler = g_app.allocator.allocT!ESPHomeSampler(device, client);
        device.samplers ~= sampler;
    }
}
