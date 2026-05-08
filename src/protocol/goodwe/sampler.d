module protocol.goodwe.sampler;

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
import manager.sampler;

import protocol.goodwe.aa55;

//version = DebugGoodWeBinding;

nothrow @nogc:


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

protected:
    final override const(char)[] profile_dir() const pure
        => "conf/goodwe_profiles/";
    final override const(char)[] profile_name() const pure
        => _profile_name[];
    final override const(char)[] model_name() const pure
        => _model_name[];

    final override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        assert(desc.type == ElementType.aa55);
        ref const ElementDesc_AA55 aa55 = _profile_data.get_aa55(desc.element);

        ubyte[256] tmp = void;
        tmp[0 .. aa55.value_desc.data_length] = 0;
        e.value = sample_value(tmp.ptr, aa55.value_desc);

        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.control = GoodWeControlCode.read;
        se.fn = cast(GoodWeFunctionCode)aa55.function_code;
        se.offset = aa55.offset;
        se.desc = aa55.value_desc;
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

        device.sample_elements ~= e; // TODO: remove this?
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
        SysTime last_update;
        GoodWeControlCode control;
        GoodWeFunctionCode fn;
        ubyte offset;
        ubyte flags; // 1 - in-flight, 2 - constant-sampled, 4 - ...
        ushort sample_time_ms;
        Element* element;
        ValueDesc desc;
    }

    void state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void response_handler(bool success, ref const AA55Request request, SysTime response_time, const(ubyte)[] response, void* user_data)
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

            assert(e.offset + e.desc.data_length <= response.length, "response too small for element data?!");

            Variant sample = sample_value(response.ptr + e.offset, e.desc);
            e.element.value(sample.move, response_time);

            version (DebugGoodWeBinding)
            {
                ValueDesc raw_desc = ValueDesc(e.desc.data_type);
                Variant raw = sample_value(response.ptr + e.offset, raw_desc);
                log.debugf("sample - offset: {0} value: {1} = {2} (raw: {3} - 0x{4,x})", e.offset, e.element.id, e.element.value, raw, raw.isLong() ? cast(uint)cast(ulong)raw.asLong() : 0);
            }
        }
    }
}
