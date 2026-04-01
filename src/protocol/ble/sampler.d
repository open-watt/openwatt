module protocol.ble.sampler;

import urt.array;
import urt.endian;
import urt.time;
import urt.uuid;

import manager.element;
import manager.profile;
import manager.sampler;

import protocol.ble.client;
import protocol.ble.iface;

import router.iface;
import router.iface.packet;

nothrow @nogc:


class BLESampler : Sampler
{
nothrow @nogc:

    this(BLEInterface iface, BLEClient client)
    {
        this.iface = iface;
        this.client = client;

        (cast(BaseInterface)iface).subscribe(&packet_handler,
            PacketFilter(type: PacketType.unknown, direction: PacketDirection.incoming));
    }

    final void add_element(Element* element, ref const ElementDesc desc, ref const ElementDesc_BLE ble_info)
    {
        SampleElement* e = &elements.pushBack();
        e.element = element;
        e.service_uuid = ble_info.service_uuid;
        e.char_uuid = ble_info.char_uuid;
        e.handle = ushort.max;
        e.offset = ble_info.offset;
        e.desc = ble_info.value_desc;
    }

    final override void remove_element(Element* element)
    {
    }

    final override void update()
    {
        if (!handles_resolved)
            try_resolve_handles();
    }

private:

    BLEInterface iface;
    BLEClient client;
    Array!SampleElement elements;
    bool handles_resolved;

    struct SampleElement
    {
        Element* element;
        GUID service_uuid;
        GUID char_uuid;
        ushort handle;
        ubyte offset;
        ValueDesc desc;
    }

    void try_resolve_handles()
    {
        if (!client.running)
            return;

        auto session = iface.find_session_by_peer(client.peer);
        if (session is null || session.num_chars == 0)
            return;

        bool all_resolved = true;
        foreach (ref e; elements)
        {
            if (e.handle != ushort.max)
                continue;

            foreach (ref c; session.chars[0 .. session.num_chars])
            {
                if (e.service_uuid == c.service_uuid && e.char_uuid == c.char_uuid)
                {
                    e.handle = c.handle;
                    break;
                }
            }

            if (e.handle == ushort.max)
                all_resolved = false;
        }
        handles_resolved = all_resolved;
    }

    void packet_handler(ref const Packet p, BaseInterface i, PacketDirection dir, void* u)
    {
        if (p.type != PacketType.ble_att)
            return;

        ref att = p.hdr!BLEATTFrame;
        if (att.src != client.peer)
            return;

        if (att.opcode != ATTOpcode.notification && att.opcode != ATTOpcode.indication)
            return;

        const(ubyte)[] payload = cast(const(ubyte)[])p.data;
        if (payload.length < 2)
            return;

        ushort handle = payload.ptr[0 .. 2].littleEndianToNative!ushort;
        const(ubyte)[] value = payload.length > 2 ? payload[2 .. $] : null;

        foreach (ref e; elements)
        {
            if (e.handle != handle)
                continue;
            if (value.length < e.offset + e.desc.data_length)
                continue;
            e.element.value(sample_value(value.ptr + e.offset, e.desc), p.creation_time);
        }
    }
}
