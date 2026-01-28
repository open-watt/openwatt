module protocol.can.sampler;

import urt.array;
import urt.endian;
import urt.log;
import urt.si;
import urt.time;
import urt.util : align_up;

import manager.element;
import manager.profile;
import manager.sampler;

import protocol.can;

import router.iface;
import router.iface.can;

//version = DebugCANSampler;

nothrow @nogc:


class CANSampler : Sampler
{
nothrow @nogc:

    this(BaseInterface iface)
    {
        this.iface = iface;

        iface.subscribe(&packet_handler, PacketFilter(type: PacketType.unknown, direction: PacketDirection.incoming));
    }

    final void add_element(Element* element, ref const ElementDesc desc, ref const ElementDesc_CAN reg_info)
    {
        SampleElement* e = &elements.pushBack();
        e.element = element;
        e.id = reg_info.message_id;
        e.offset = reg_info.offset;
        e.desc = reg_info.value_desc;
    }

    final override void remove_element(Element* element)
    {
        // TODO: anything to do?
    }

private:

    BaseInterface iface;
    Array!SampleElement elements;

    struct SampleElement
    {
        SysTime last_update;
        uint id;
        ubyte offset;
        Element* element;
        ValueDesc desc;
    }

    void packet_handler(ref const Packet p, BaseInterface i, PacketDirection dir, void* u)
    {
        if (p.type != PacketType.can)
        {
            if (p.type == PacketType.ethernet && p.eth.ether_type == EtherType.ow && p.eth.ow_sub_type == OW_SubType.can)
            {
                // de-frame CANoE...
                assert(false, "TODO");
            }
            return;
        }

        ref can = p.hdr!CANFrame;
        foreach (ref e; elements)
        {
            if (e.id != can.id)
                continue;

            assert(e.offset + e.desc.data_length <= p.length, "message too small for element data?!");

            e.last_update = p.creation_time;
            e.element.value = sample_value(p.data.ptr + e.offset, e.desc);

            version (DebugCANSampler)
            {
                import urt.variant;
                ValueDesc raw_desc = ValueDesc(e.desc.data_type);
                Variant raw = sample_value(p.data.ptr + e.offset, raw_desc);
                writeDebugf("can: sample - offset: {0} value: {1} = {2} (raw: {3} - 0x{4,x})", e.offset, e.element.id, e.element.latest, raw, raw.isLong() ? cast(uint)cast(ulong)raw.asLong() : 0);
            }
        }
    }
}
