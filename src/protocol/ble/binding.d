module protocol.ble.binding;

import urt.array;
import urt.log;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.uuid;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.profile;
import manager.sampler;

import protocol.ble.client;


nothrow @nogc:


class BLEClientBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("client", client),
                                 Prop!("profile", profile),
                                 Prop!("model", model));
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
            _client.unsubscribe(&state_change);
            clear_subscriptions();
            _subscribed = false;
        }
        _client = value;
        mark_set!(typeof(this), "client")();
        restart();
    }

    final ref const(String) profile() const pure
        => _profile_name;
    final void profile(String value)
    {
        if (value == _profile_name)
            return;
        _profile_name = value.move;
        mark_set!(typeof(this), "profile")();
        restart();
    }

    final ref const(String) model() const pure
        => _model_name;
    final void model(String value)
    {
        if (value == _model_name)
            return;
        _model_name = value.move;
        mark_set!(typeof(this), "model")();
        restart();
    }

    final override bool validate() const pure
    {
        return _client.get !is null && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        BLEClient c = _client.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        c.subscribe(&state_change);
        c.on_discovery_done(&resolve_handles);
        _subscribed = true;

        resolve_handles();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _client.unsubscribe(&state_change);
            clear_subscriptions();
            _subscribed = false;
        }
        _handles_resolved = false;
        elements.clear();
        return super.shutdown();
    }

protected:
    final override const(char)[] profile_dir() const pure
        => "conf/ble_profiles/";
    final override const(char)[] profile_name() const pure
        => _profile_name[];
    final override const(char)[] model_name() const pure
        => _model_name[];

    final override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        assert(desc.type == ElementType.ble);
        ref const ElementDesc_BLE ble = _profile_data.get_ble(desc.element);

        ubyte[256] tmp = void;
        tmp[0 .. ble.value_desc.data_length] = 0;
        e.value = sample_value(tmp.ptr, ble.value_desc);

        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.service_uuid = ble.service_uuid;
        se.char_uuid = ble.char_uuid;
        se.handle = ushort.max;
        se.offset = ble.offset;
        se.desc = ble.value_desc;

        device.sample_elements ~= e; // TODO: remove this?
    }

private:

    ObjectRef!BLEClient _client;
    String _profile_name;
    String _model_name;

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
        ValueDesc desc;
    }

    void state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
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
            if (value.length < e.offset + e.desc.data_length)
                continue;
            // HACK: Element.value defaults timestamp to getSysTime(); packet creation_time
            // no longer accessible here (BLEClient delivers value-only callbacks).
            // TODO: make the packet creation time available here?!
            e.element.value(sample_value(value.ptr + e.offset, e.desc));
        }
    }
}
