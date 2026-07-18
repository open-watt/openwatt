module protocol.can.binding;

import urt.array;
import urt.log;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
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

import protocol.can.iface;

import router.iface;
import router.iface.packet;

//version = DebugCANBinding;

nothrow @nogc:


struct ElementDesc_CAN
{
    uint message_id;
    ubyte offset;
    ubyte length;       // wire byte span at offset; the map carries it, the desc doesn't
    ushort desc = 0xFFFF;
}

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
        import protocol.can : can_section_kind;

        assert(desc.kind == can_section_kind);
        ref const ElementDesc_CAN can = _profile_data.get_section!ElementDesc_CAN(can_section_kind, desc.element);
        if (can.desc == 0xFFFF)
            return; // spelling didn't compile; the profile load already warned

        SampleDesc sd = desc_by_index(can.desc);
        const(DataFormat)* fmt = sd.fmt;
        if (!e.series.format && fmt.is_scalar)
            e.series.format = fmt;

        // typed zero until the first frame arrives
        if (fmt.is_scalar)
        {
            Scalar z;
            z.raw[] = 0;
            e.value = box_record(z.raw.ptr, *fmt);
        }

        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.id = can.message_id;
        se.offset = can.offset;
        se.length = can.length;
        se.desc = sd;

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
        Element* element;
        uint id;
        ubyte offset;
        ubyte length;
        SampleDesc desc;
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

            assert(e.offset + e.length <= p.length, "message too small for element data?!");
            const(void)[] wire = p.data[e.offset .. e.offset + e.length];
            SysTime t = cast(SysTime)p.creation_time;

            Element* el = e.element;
            const(DataFormat)* fmt = e.desc.fmt;
            if (fmt.is_scalar)
            {
                Scalar s;
                s.raw[] = 0;
                if (!sample_record(wire, e.desc, s.raw[0 .. fmt.stride]))
                    continue;
                if (el.series.format is fmt)
                    el.observe_record(s.raw[0 .. fmt.stride], t);
                else
                    el.value(box_record(s.raw.ptr, *fmt), t);
            }
            else if (fmt.type == ValueType.char_)
            {
                char[64] buf = void;
                el.value(Variant(sample_text(wire, e.desc, buf)), t);
            }
            else
            {
                // user records box at the mount until a native wide path exists
                ubyte[64] rec = void;
                if (fmt.stride <= rec.length && sample_record(wire, e.desc, rec[0 .. fmt.stride]))
                    el.value(box_record(rec.ptr, *fmt), t);
            }

            version (DebugCANBinding)
                log.debugf("sample - offset: {0} element: {1} = {2}", e.offset, el.id, el.value);
        }
    }
}
