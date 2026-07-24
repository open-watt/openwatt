module protocol.can;

import urt.conv;
import urt.endian;
import urt.map;
import urt.mem;
import urt.string;
import urt.time;

import manager;
import manager.collection;
import manager.config : ConfItem;
import manager.plugin;
import manager.profile;
import manager.sample.spec : stream_le_context;

import protocol.can.iface;
import protocol.can.binding;

import router.iface;
import router.iface.packet;

nothrow @nogc:


package __gshared uint can_section_kind;

class CANProtocolModule : Module, ProfileSections
{
    mixin DeclareModule!"protocol.can";
nothrow @nogc:

    override void init()
    {
        register_packet_codec!CANFrame();

        g_app.register_enum!CANInterfaceProtocol();

        can_section_kind = register_profile_section("can", this);

        g_app.console.register_collection!CANInterface();
        g_app.console.register_collection!CANBinding();
    }

    uint element_size(uint)
        => cast(uint)ElementDesc_CAN.sizeof;

    void count_element(uint, ref const ConfItem, ref ProfileSize) {}

    bool parse_element(uint kind, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        import urt.log : writeWarning;

        const(char)[] tail = item.value;

        ElementDesc_CAN* can = cast(ElementDesc_CAN*)slot.ptr;
        *can = ElementDesc_CAN.init;

        const(char)[] msg_id = tail.split!',';
        const(char)[] offset = tail.split!',';
        const(char)[] type = tail.split!','.unQuote;
        const(char)[] units = tail.split!','.unQuote;

        size_t taken;
        ulong ti = msg_id.parse_uint_with_base(&taken);
        if (taken != msg_id.length || ti > 0x1FFFFFFF) // 29 bits for CAN2.0B
        {
            writeWarning("Invalid CAN message id: ", msg_id);
            return false;
        }
        can.message_id = cast(uint)ti;
        ti = offset.parse_uint_with_base(&taken);
        if (taken != offset.length || ti >= 64)
        {
            writeWarning("Invalid CAN message offset: ", offset);
            return false;
        }
        can.offset = cast(ubyte)ti;

        if (!b.compile_value(type, units, stream_le_context, can.desc, can.length))
            return false;
        if (can.length == 0)
        {
            writeWarning("Unsized string requires a framed CAN profile hook: ", b.element_id);
            can.desc = ushort.max;
            return false;
        }
        return true;
    }
}
