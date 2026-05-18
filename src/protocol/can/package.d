module protocol.can;

import urt.endian;
import urt.map;
import urt.mem;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.plugin;

import protocol.can.iface;
import protocol.can.binding;

import router.iface;
import router.iface.packet;

nothrow @nogc:


class CANProtocolModule : Module
{
    mixin DeclareModule!"protocol.can";
nothrow @nogc:

    override void init()
    {
        register_address_extractor(PacketType.can, &CANFrame.extract_src, &CANFrame.extract_dst);

        g_app.register_enum!CANInterfaceProtocol();

        g_app.console.register_collection!CANInterface();
        g_app.console.register_collection!CANBinding();
    }
}
