module protocol.goodwe.binding;

import urt.array;
import urt.lifetime;
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

import protocol.goodwe.aa55;

//version = DebugGoodWeBinding;

nothrow @nogc:


struct ElementDesc_AA55
{
    ubyte function_code;
    ubyte offset;
    ubyte length;
    ushort desc = 0xFFFF;
}

class GoodWeBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("client", client),
                                 Prop!("profile", profile),
                                 Prop!("model", model));
nothrow @nogc:

    enum type_name = "goodwe-binding";
    enum path = "/binding/goodwe";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!GoodWeBinding, id, flags);
    }

    final inout(AA55Client) client() inout pure
        => _client.get;
    final void client(AA55Client value)
    {
        if (_client.get is value)
            return;
        if (_subscribed)
        {
            _client.unsubscribe(&state_change);
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

protected:

    final override bool validate() const pure
    {
        return _client.get !is null && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        AA55Client c = _client.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        c.subscribe(&state_change);
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _client.unsubscribe(&state_change);
            _subscribed = false;
        }
        elements.clear();
        return super.shutdown();
    }

    final override void update()
    {
        AA55Client c = _client.get;
        if (!c)
            return;

        MonoTime now = getTime();

        uint request_functions;

        foreach (ref e; elements)
        {
            if ((e.flags & 1) || e.control != GoodWeControlCode.read)
                continue;

            // skip any registers that shouldn't be sampled
            if ((e.flags & 3) || // if it's in flight or a constant has alrady been sampled
                e.sample_time_ms == ushort.max || // strictly on-demand
                now - e.last_update < msecs(e.sample_time_ms)) // if it's not yet time to sample again
                continue;

            // flag in-flight
            e.flags |= 1;
            request_functions |= (1 << e.fn);
        }

        foreach (i; 0..32)
        {
            if (request_functions & (1 << i))
            {
                GoodWeFunctionCode fn = cast(GoodWeFunctionCode)i;

                // if it's already in flight, we'll collect when the in-flight request responds
                if (c.read_in_flight(fn))
                    continue;

                bool success = c.send_request(GoodWeControlCode.read, fn, null, &response_handler);
                if (!success)
                {
                    // un-flag in-flight on failure
                    foreach (ref e; elements)
                    {
                        if (e.control == GoodWeControlCode.read && e.fn == fn)
                            e.flags &= 0xFE;
                    }
                    continue;
                }

                // TODO: add to pending requests; implement timeout, etc.
                //...

                version (DebugGoodWeBinding)
                    log.debug_("request sample - '", c.name, "' fn: ", fn);
            }
        }
    }

    final override const(char)[] profile_name() const pure
        => _profile_name[];

    final override const(char)[] model_name() const pure
        => _model_name[];

    final override FormatId add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        if (elements.length == 0)
            device.set_element("status.network.ip.address", _client.get_address());

        import protocol.goodwe : aa55_section_kind;

        assert(desc.kind == aa55_section_kind);
        ref const ElementDesc_AA55 aa55 = _profile_data.get_section!ElementDesc_AA55(aa55_section_kind, desc.element);
        if (aa55.desc == 0xFFFF)
            return FormatId.invalid;

        SampleDesc sd = desc_by_index(aa55.desc);
        const(DataFormat)* fmt = sd.fmt;
        if (fmt.is_scalar)
        {
            Scalar z;
            z.raw[] = 0;
            e.value = box_record(z.raw.ptr, *fmt);
        }

        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.control = GoodWeControlCode.read;
        se.fn = cast(GoodWeFunctionCode)aa55.function_code;
        se.offset = aa55.offset;
        se.length = aa55.length;
        se.desc = sd;
        switch (desc.update_frequency)
        {
            case Frequency.realtime:       se.sample_time_ms = 400;         break;
            case Frequency.high:           se.sample_time_ms = 1_000;       break;
            case Frequency.medium:         se.sample_time_ms = 10_000;      break;
            case Frequency.low:            se.sample_time_ms = 60_000;      break;
            case Frequency.constant:       se.sample_time_ms = 0;           break;
            case Frequency.configuration:  se.sample_time_ms = 0;           break;
            case Frequency.on_demand:      se.sample_time_ms = ushort.max;  break;
            default: assert(false);
        }

        return sd.format;
    }

private:

    ObjectRef!AA55Client _client;
    String _profile_name;
    String _model_name;

    bool _subscribed;

    Array!SampleElement elements;
    ushort retry_time = 500;

    struct SampleElement
    {
        MonoTime last_update;
        GoodWeControlCode control;
        GoodWeFunctionCode fn;
        ubyte offset;
        ubyte flags; // 1 - in-flight, 2 - constant-sampled, 4 - ...
        ushort sample_time_ms;
        Element* element;
        ubyte length;
        SampleDesc desc;
    }

    void state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void response_handler(bool success, ref const AA55Request request, MonoTime response_time, const(ubyte)[] response, void* user_data)
    {
        foreach (ref e; elements)
        {
            if (e.control == request.control_code && e.fn == request.function_code)
                e.flags &= 0xFE; // clear in-flight flag
        }
        if (!success)
        {
            version (DebugGoodWeBinding)
                log.debug_("sample FAILED after ", (response_time - request.request_time).as!"msecs", "ms - '", _client.name, "' fn: ", request.function_code);
            return;
        }

        version (DebugGoodWeBinding)
            log.debug_("sample response after ", (response_time - request.request_time).as!"msecs", "ms - '", _client.name, "' fn: ", request.function_code);

        // update all elements whose data is contained in this response
        foreach (ref e; elements)
        {
            if (e.control != request.control_code || e.fn != request.function_code)
                continue;

            // if the value is constant, and we received a valid response, then we won't ask again
            if (e.sample_time_ms == 0)
                e.flags |= 2;

            assert(e.offset + e.length <= response.length, "response too small for element data?!");
            const(void)[] wire = response[e.offset .. e.offset + e.length];
            SysTime t = cast(SysTime)response_time;

            Element* el = e.element;
            const(DataFormat)* fmt = e.desc.fmt;
            if (fmt.is_scalar)
            {
                Scalar s;
                s.raw[] = 0;
                if (!sample_record(wire, e.desc, s.raw[0 .. fmt.stride]))
                    continue;
                if (el.format == e.desc.format)
                    el.write_record(s.raw[0 .. fmt.stride], t);
                else
                    el.value(box_record(s.raw.ptr, *fmt), t);
            }
            else if (fmt.type == ValueType.char_)
            {
                char[256] buf = void;
                el.value(Variant(sample_text(wire, e.desc, buf)), t);
            }
            else
            {
                ubyte[256] rec = void;
                if (fmt.stride <= rec.length && sample_record(wire, e.desc, rec[0 .. fmt.stride]))
                    el.value(box_record(rec.ptr, *fmt), t);
            }

            version (DebugGoodWeBinding)
                log.debugf("sample - offset: {0} element: {1} = {2}", e.offset, el.id, el.value);
        }
    }
}
