module protocol.can.binding;

import urt.array;
import urt.endian;
import urt.log;
import urt.meta : AliasSeq;
import urt.si;
import urt.string;
import urt.time;
import urt.util : align_up;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.profile;
import manager.sampler;

import protocol.can.iface;

import router.iface;
import router.iface.packet;

//version = DebugCANBinding;

nothrow @nogc:


class CANBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("profile", profile),
                                 Prop!("model", model));
nothrow @nogc:

    enum type_name = "can-binding";
    enum path = "/binding/can";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CANBinding, id, flags);
    }

    final inout(CANInterface) iface() inout pure
        => _iface.get;
    final void iface(CANInterface value)
    {
        if (_iface.get is value)
            return;
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&packet_handler);
            _subscribed = false;
        }
        _iface = value;
        mark_set!(typeof(this), "interface")();
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
        return _iface.get !is null && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        CANInterface i = _iface.get;
        if (!i || !i.running)
            return CompletionStatus.continue_;

        i.subscribe(&packet_handler, PacketFilter(type: PacketType.unknown, direction: PacketDirection.incoming));
        i.subscribe(&iface_state_change);
        _subscribed = true;

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&packet_handler);
            _subscribed = false;
        }
        elements.clear();
        return super.shutdown();
    }

protected:
    final override const(char)[] profile_dir() const pure
        => "conf/can_profiles/";
    final override const(char)[] profile_name() const pure
        => _profile_name[];
    final override const(char)[] model_name() const pure
        => _model_name[];

    final override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        assert(desc.type == ElementType.can);
        ref const ElementDesc_CAN can = _profile_data.get_can(desc.element);

        if (!e.series.format)
            e.series.format = _profile_data.series_format(can.value_desc);

        ubyte[256] tmp = void;
        tmp[0 .. can.value_desc.data_length] = 0;
        e.value = sample_value(tmp.ptr, can.value_desc);

        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.id = can.message_id;
        se.offset = can.offset;
        se.desc = can.value_desc;

        device.sample_elements ~= e; // TODO: remove this?
    }

private:

    ObjectRef!CANInterface _iface;
    String _profile_name;
    String _model_name;

    bool _subscribed;

    Array!SampleElement elements;

    struct SampleElement
    {
        SysTime last_update;
        uint id;
        ubyte offset;
        Element* element;
        ValueDesc desc;
    }

    void iface_state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void packet_handler(ref const Packet p, BaseInterface i, PacketDirection dir, void* u)
    {
        if (p.type != PacketType.can)
            return;

        ref can = p.hdr!CANFrame;
        foreach (ref e; elements)
        {
            if (e.id != can.id)
                continue;

            assert(e.offset + e.desc.data_length <= p.length, "message too small for element data?!");

            e.element.value(sample_value(p.data.ptr + e.offset, e.desc), cast(SysTime)p.creation_time);

            version (DebugCANBinding)
            {
                import urt.variant;
                ValueDesc raw_desc = ValueDesc(e.desc.data_type);
                Variant raw = sample_value(p.data.ptr + e.offset, raw_desc);
                log.debugf("sample - offset: {0} value: {1} = {2} (raw: {3} - 0x{4,x})", e.offset, e.element.id, e.element.latest, raw, raw.isLong() ? cast(uint)cast(ulong)raw.asLong() : 0);
            }
        }
    }
}
