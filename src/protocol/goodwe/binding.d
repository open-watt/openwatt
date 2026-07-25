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
    alias Properties = AliasSeq!(Prop!("client", client));
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
            _client.unsubscribe(&restart_on_offline);
            _subscribed = false;
        }
        _client = value;
        mark_set!(typeof(this), "client")();
        restart();
    }


protected:

    final override bool validate() const pure
    {
        return super.validate() && _client.get !is null;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        AA55Client c = _client.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        c.subscribe(&restart_on_offline);
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _client.unsubscribe(&restart_on_offline);
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
            if ((e.flags & 3) || // if it's in flight or a constant has already been sampled
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

    final override FormatId add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        if (elements.length == 0)
        {
            if (AA55Client c = _client.get)
                device.set_element("status.network.ip.address", c.get_address());
        }

        import protocol.goodwe : aa55_section_kind;

        if (desc.kind != aa55_section_kind)
            return FormatId.invalid;
        ref const ElementDesc_AA55 aa55 = _profile_data.get_section!ElementDesc_AA55(aa55_section_kind, desc.element);
        SampleDesc sd = init_element_sample(e, aa55.desc);
        if (!sd.valid)
            return FormatId.invalid;


        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.control = GoodWeControlCode.read;
        se.fn = cast(GoodWeFunctionCode)aa55.function_code;
        se.offset = aa55.offset;
        se.length = aa55.length;
        se.desc = sd;
        se.sample_time_ms = freq_to_sample_ms(desc.update_frequency);

        return sd.format;
    }

private:

    ObjectRef!AA55Client _client;

    bool _subscribed;

    Array!SampleElement elements;

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
        CommitScope frame = open_commit();
        foreach (ref e; elements)
        {
            if (e.control != request.control_code || e.fn != request.function_code)
                continue;

            // if the value is constant, and we received a valid response, then we won't ask again
            if (e.sample_time_ms == 0)
                e.flags |= 2;

            assert(e.offset + e.length <= response.length, "response too small for element data?!");
            const(void)[] wire = response[e.offset .. e.offset + e.length];

            write_wire_sample(e.element, wire, e.desc, cast(SysTime)response_time);

            version (DebugGoodWeBinding)
                log.debugf("sample - offset: {0} element: {1} = {2}", e.offset, e.element.id, e.element.value);
        }
    }
}
