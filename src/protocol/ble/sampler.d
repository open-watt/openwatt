module protocol.ble.sampler;

import urt.array;
import urt.endian;
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
import protocol.ble.iface;

import router.iface;
import router.iface.packet;

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
            _iface.unsubscribe(&state_change);
            _iface.unsubscribe(&packet_handler);
            _subscribed = false;
        }
        _client = value;
        _iface = null;
        restart();
    }

    final ref const(String) profile() const pure
        => _profile_name;
    final void profile(String value)
    {
        if (value == _profile_name)
            return;
        _profile_name = value.move;
        restart();
    }

    final ref const(String) model() const pure
        => _model_name;
    final void model(String value)
    {
        if (value == _model_name)
            return;
        _model_name = value.move;
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

        BLEInterface iface = cast(BLEInterface)c.iface;
        if (!iface)
        {
            log.warning("client '", c.name, "' has no BLE interface");
            return CompletionStatus.error;
        }
        _iface = iface;

        c.subscribe(&state_change);
        iface.subscribe(&state_change);
        iface.subscribe(&packet_handler, PacketFilter(PacketType.unknown, PacketDirection.incoming));
        _subscribed = true;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _client.unsubscribe(&state_change);
            _iface.unsubscribe(&state_change);
            _iface.unsubscribe(&packet_handler);
            _subscribed = false;
        }
        _iface = null;
        _handles_resolved = false;
        elements.clear();
        return super.shutdown();
    }

    override void update()
    {
        if (!_handles_resolved)
            try_resolve_handles();
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

    BLEInterface _iface;
    bool _subscribed;
    bool _handles_resolved;

    Array!SampleElement elements;

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

    void try_resolve_handles()
    {
        if (!_client)
            return;

        auto session = _iface.find_session_by_peer(_client.peer);
        if (session is null || session.num_chars == 0)
            return;

        bool all_resolved = true;
        foreach (ref e; elements)
        {
            if (e.handle != ushort.max)
                continue;

            foreach (ref gc; session.chars[0 .. session.num_chars])
            {
                if (e.service_uuid == gc.service_uuid && e.char_uuid == gc.char_uuid)
                {
                    e.handle = gc.handle;
                    break;
                }
            }

            if (e.handle == ushort.max)
                all_resolved = false;
        }
        _handles_resolved = all_resolved;
    }

    void packet_handler(ref const Packet p, BaseInterface i, PacketDirection dir, void* u)
    {
        if (p.type != PacketType.ble_att)
            return;

        ref att = p.hdr!BLEATTFrame;
        BLEClient c = _client.get;
        if (!c || att.src != c.peer)
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
