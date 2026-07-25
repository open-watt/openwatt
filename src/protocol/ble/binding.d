module protocol.ble.binding;

import urt.array;
import urt.log;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.uuid;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.profile;
import manager.sample;
import manager.series;

import protocol.ble.client;


nothrow @nogc:


struct ElementDesc_BLE
{
    GUID service_uuid;
    GUID char_uuid;
    ubyte offset;
    ubyte length;
    ushort desc = 0xFFFF;
}

class BLEClientBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("client", client));
nothrow @nogc:

    enum type_name = "ble-client-binding";
    enum path = "/binding/ble/client";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BLEClientBinding, id, flags);
    }

    final inout(BLEClient) client() inout pure
        => _client.get;
    final void client(BLEClient value)
    {
        if (_client.get is value)
            return;
        if (_subscribed)
        {
            _client.unsubscribe(&restart_on_offline);
            clear_subscriptions();
            _subscribed = false;
        }
        _client = value;
        mark_set!(typeof(this), "client")();
        restart();
    }


    final override bool validate() const pure
    {
        return super.validate() && _client.get !is null;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        BLEClient c = _client.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        c.subscribe(&restart_on_offline);
        c.on_discovery_done(&resolve_handles);
        _subscribed = true;

        resolve_handles();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _client.unsubscribe(&restart_on_offline);
            clear_subscriptions();
            _subscribed = false;
        }
        _handles_resolved = false;
        elements.clear();
        return super.shutdown();
    }

protected:
    final override FormatId add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        import protocol.ble : ble_section_kind;

        if (desc.kind != ble_section_kind)
            return FormatId.invalid;
        ref const ElementDesc_BLE ble = _profile_data.get_section!ElementDesc_BLE(ble_section_kind, desc.element);
        SampleDesc sd = init_element_sample(e, ble.desc);
        if (!sd.valid)
            return FormatId.invalid;


        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.service_uuid = ble.service_uuid;
        se.char_uuid = ble.char_uuid;
        se.handle = ushort.max;
        se.offset = ble.offset;
        se.length = ble.length;
        se.desc = sd;

        return sd.format;
    }

private:

    ObjectRef!BLEClient _client;

    bool _subscribed;
    bool _handles_resolved;

    Array!SampleElement elements;
    Array!ushort _subscribed_handles;

    struct SampleElement
    {
        Element* element;
        GUID service_uuid;
        GUID char_uuid;
        ushort handle;
        ubyte offset;
        ubyte length;
        SampleDesc desc;
    }


    void clear_subscriptions()
    {
        if (BLEClient c = _client.get)
        {
            c.clear_discovery_done(&resolve_handles);
            foreach (h; _subscribed_handles[])
                c.clear_notify(h);
        }
        _subscribed_handles.clear();
    }

    void resolve_handles()
    {
        if (_handles_resolved)
            return;

        BLEClient c = _client.get;
        if (c is null || !c.discovery_complete())
            return;

        bool all_resolved = true;
        foreach (ref e; elements)
        {
            if (e.handle != ushort.max)
                continue;

            ushort h = c.find_characteristic(e.service_uuid, e.char_uuid);
            if (h == 0)
            {
                all_resolved = false;
                continue;
            }
            e.handle = h;
        }

        if (!all_resolved)
            return;

        foreach (ref e; elements)
        {
            bool already = false;
            foreach (h; _subscribed_handles[])
            {
                if (h == e.handle)
                {
                    already = true;
                    break;
                }
            }
            if (!already)
            {
                c.on_notify(e.handle, &on_value);
                _subscribed_handles ~= e.handle;
            }
        }

        _handles_resolved = true;
    }

    void on_value(ushort handle, const(ubyte)[] value)
    {
        foreach (ref e; elements)
        {
            if (e.handle != handle)
                continue;
            if (value.length < e.offset + e.length)
                continue;
            const(void)[] wire = value[e.offset .. e.offset + e.length];
            // HACK: the write timestamp defaults to getSysTime(); packet creation_time
            // no longer accessible here (BLEClient delivers value-only callbacks).
            // TODO: make the packet creation time available here?!
            write_wire_sample(e.element, wire, e.desc);
        }
    }
}
