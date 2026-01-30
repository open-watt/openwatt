module protocol.goodwe.sampler;

import urt.array;
import urt.log;
import urt.time;

import manager.element;
import manager.profile;
import manager.sampler;

import protocol.goodwe.aa55;

//version = DebugGoodWeSampler;

nothrow @nogc:


class GoodWeSampler : Sampler
{
nothrow @nogc:

    this(AA55Client client)
    {
        this.client = client;
    }

    final override void update()
    {
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
                if (client.read_in_flight(fn))
                    continue;

                bool success = client.send_request(GoodWeControlCode.read, fn, null, &response_handler);
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

                version (DebugGoodWeSampler)
                    writeDebug("aa55: request sample - '", client.name, "' fn: ", fn);
            }
        }
    }

    final void add_element(Element* element, ref const ElementDesc desc, ref const ElementDesc_AA55 reg_info)
    {
        SampleElement* e = &elements.pushBack();
        e.element = element;
        e.control = GoodWeControlCode.read;
        e.fn = cast(GoodWeFunctionCode)reg_info.function_code;
        e.offset = reg_info.offset;
        e.desc = reg_info.value_desc;
        switch (desc.update_frequency)
        {
            case Frequency.realtime:       e.sample_time_ms = 400;         break; // as fast as possible
            case Frequency.high:           e.sample_time_ms = 1_000;       break; // seconds
            case Frequency.medium:         e.sample_time_ms = 10_000;      break; // 10s seconds
            case Frequency.low:            e.sample_time_ms = 60_000;      break; // minutes
            case Frequency.constant:       e.sample_time_ms = 0;           break; // just once
            case Frequency.configuration:  e.sample_time_ms = 0;           break; // HACK: sample config items once
            case Frequency.on_demand:      e.sample_time_ms = ushort.max;  break; // only explicit
            default: assert(false);
        }
    }

    final override void remove_element(Element* element)
    {
        // TODO: find the element in the list and remove it...
    }

private:
    AA55Client client;
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

    void response_handler(bool success, ref const AA55Request request, SysTime response_time, const(ubyte)[] response, void* user_data)
    {
        foreach (ref e; elements)
        {
            if (e.control == request.control_code && e.fn == request.function_code)
                e.flags &= 0xFE; // clear in-flight flag
        }
        if (!success)
        {
            version (DebugGoodWeSampler)
                writeDebug("aa55: sample FAILED after ", (response_time - request.request_time).as!"msecs", "ms - ''", client.name, "' fn: ", request.function_code);
            return;
        }

        version (DebugGoodWeSampler)
            writeDebug("aa55: sample response after ", (response_time - request.request_time).as!"msecs", "ms - '", client.name, "' fn: ", request.function_code);

        // update all elements whose data is contained in this response
        foreach (ref e; elements)
        {
            if (e.control != request.control_code || e.fn != request.function_code)
                continue;

            // if the value is constant, and we received a valid response, then we won't ask again
            if (e.sample_time_ms == 0)
                e.flags |= 2;

            assert(e.offset + e.desc.data_length <= response.length, "response too small for element data?!");

            e.last_update = response_time;
            e.element.latest = sample_value(response.ptr + e.offset, e.desc);

            version (DebugGoodWeSampler)
            {
                import urt.variant;
                ValueDesc raw_desc = ValueDesc(e.desc.data_type);
                Variant raw = sample_value(response.ptr + e.offset, raw_desc);
                writeDebugf("aa55: sample - offset: {0} value: {1} = {2} (raw: {3} - 0x{4,x})", e.offset, e.element.id, e.element.latest, raw, raw.isLong() ? cast(uint)cast(ulong)raw.asLong() : 0);
            }
        }
    }
}


private:

