module protocol.can;

import urt.endian;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.collection;
import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;
import manager.profile;
import manager.sampler;

import protocol.can;
import protocol.can.iface;
import protocol.can.sampler;

import router.iface;


class CANProtocolModule : Module
{
    mixin DeclareModule!"protocol.can";
nothrow @nogc:

    Collection!CANInterface can_interfaces;

    override void init()
    {
        g_app.register_enum!CANInterfaceProtocol();

        g_app.console.register_collection("/interface/can", can_interfaces);
        g_app.console.register_command!device_add("/protocol/can/device", this, "add");
    }

    override void update()
    {
        can_interfaces.update_all();
    }

    void device_add(Session session, const(char)[] id, BaseInterface _interface, Nullable!(const(char)[]) name, Nullable!(const(char)[]) _profile, Nullable!(const(char)[]) model)
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
        const(char)[] profile_name = _profile.value;

        void[] file = load_file(tconcat("conf/can_profiles/", profile_name, ".conf"), g_app.allocator);
        Profile* profile = parse_profile(cast(char[])file, g_app.allocator);

        // create a sampler for this can interface...
        CANSampler sampler = g_app.allocator.allocT!CANSampler(_interface);

        Device device = create_device_from_profile(*profile, model ? model.value : null, id, name ? name.value : null, (Device device, Element* e, ref const ElementDesc desc, ubyte) {
            assert(desc.type == ElementType.can);
            ref const ElementDesc_CAN can = profile.get_can(desc.element);

            // write a null value of the proper type
            ubyte[256] tmp = void;
            tmp[0 .. can.value_desc.data_length] = 0;
            e.value = sample_value(tmp.ptr, can.value_desc);

            // record samper data...
            sampler.add_element(e, desc, can);
            device.sample_elements ~= e; // TODO: remove this?
        });
        if (!device)
        {
            session.write_line("Failed to create device '", id, "'");
            return;
        }
        device.samplers ~= sampler;
    }
}
