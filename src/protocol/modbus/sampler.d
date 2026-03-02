module protocol.modbus.sampler;

import urt.array;
import urt.endian;
import urt.log;
import urt.si;
import urt.time;
import urt.util : align_up;

import manager.element;
import manager.profile;
import manager.sampler;

import protocol.modbus.client;
import protocol.modbus.message;

import router.iface.mac;
import router.iface.packet : PCP, pcp_priority_map;

version = DebugModbusSampler;

nothrow @nogc:


template modbus_data_type(const(char)[] str)
{
    private enum DataType value = parse_modbus_data_type(str);
    static assert(value != DataType.invalid, "invalid modbus data type: " ~ str);
    alias modbus_data_type = value;
}

DataType parse_modbus_data_type(const(char)[] desc)
{
    if (desc.length == 3 && desc[1] == '8')
    {
        uint flags;
        if (desc[0] == 'i')
            flags |= DataType.signed;
        else if (desc[0] != 'u')
            return DataType.invalid;
        if (desc[2] == 'h')
            return make_data_type(flags, DataKind.high_byte);
        else if (desc[2] == 'l')
            return make_data_type(flags, DataKind.low_byte);
        return DataType.invalid;
    }

    // TODO: this may be insufficient, but it's what we already model...
    DataType r = parse_data_type(desc);
    if (r == DataType.invalid)
        return DataType.invalid;

    if ((r & DataType.little_endian) != 0)
    {
        r &= ~DataType.little_endian;
        r |= DataType.big_endian | DataType.word_reverse;
    }
    else
        r |= DataType.big_endian;

    // modbus strings are (normally?) space-padded, and the length is in words
    if (r.data_kind == DataKind.string_z || r.data_kind == DataKind.string_sp)
        r = make_data_type(DataType.u16 | DataType.array, DataKind.string_sp, r.data_count);

    return r;
}


class ModbusSampler : Sampler
{
nothrow @nogc:

    this(ModbusClient client, ref MACAddress server)
    {
        this.client = client;
        this.server = server;

        snooping = client.isSnooping;
        if (snooping)
            client.setSnoopHandler(&snoop_handler);
    }

    final override void update()
    {
        import protocol.modbus.message;

        if (needsSort)
        {
            import urt.algorithm : qsort;

            qsort!((ref a, ref b) => a.regKind != b.regKind
                ? (a.regKind < b.regKind ? -1 : 1)
                : (a.register < b.register ? -1 : a.register > b.register ? 1 : 0)
            )(elements[]);
            needsSort = false;
        }

        if (snooping)
            return;

        enum MaxRegs = 128;
        enum MaxGapSize = 16;

        MonoTime now = getTime();

        size_t i = 0;
        for (; i < elements.length; )
        {
            ushort firstReg = elements[i].register;
            ushort count = elements[i].seqLen;

            // skip any registers that shouldn't be sampled
            if ((elements[i].flags & 3) || // if it's in flight or a constant has alrady been sampled
                elements[i].sampleTimeMs == ushort.max || // strictly on-demand
                now - elements[i].lastUpdate < msecs(elements[i].sampleTimeMs)) // if it's not yet time to sample again
            {
                ++i;
                continue;
            }

            // flag in-flight
            elements[i].flags |= 1;

            // batch priority: highest PCP in the batch, DEI=false if any element is non-droppable
            PCP batch_pcp = elements[i].pcp;
            bool batch_dei = elements[i].dei;
            ubyte batch_rank = pcp_priority_map[batch_pcp];

            // scan for a stripe of registers to sample
            size_t j = i + 1;
            for (; j < elements.length; ++j)
            {
                // skip any registers that shouldn't be sampled
                if ((elements[j].flags & 3) || // if it's in flight or a constant has alrady been sampled
                    elements[j].sampleTimeMs == ushort.max || // strictly on-demand
                    now - elements[j].lastUpdate < msecs(elements[j].sampleTimeMs)) // if it's not yet time to sample again
                    continue;

                ushort nextReg = elements[j].register;
                int last = nextReg + elements[j].seqLen;

                // break the reqiest strip if:
                //   registers change kind
                //   request is too long
                //   the gap between elements is too large
                if ((elements[j].regKind != elements[i].regKind) ||
                    (last - firstReg > MaxRegs) ||
                    (nextReg >= firstReg + count + MaxGapSize))
                    break;

                count = cast(ushort)(last - firstReg);

                // promote batch priority if this element is more critical
                ubyte j_rank = pcp_priority_map[elements[j].pcp];
                if (j_rank > batch_rank)
                {
                    batch_rank = j_rank;
                    batch_pcp = elements[j].pcp;
                }
                if (!elements[j].dei)
                    batch_dei = false;

                // flag in-flight
                elements[j].flags |= 1;
            }

            // send request
            ModbusPDU pdu = createMessage_Read(cast(RegisterType)elements[i].regKind, firstReg, count);
            if (!client.sendRequest(server, pdu, &response_handler, &error_handler, 0, retryTime, batch_pcp, batch_dei))
            {
                // queue rejected — release in-flight flags for this batch
                // continue scanning: later batches (possibly higher priority) may still be accepted
                for (size_t k = i; k < j; ++k)
                    elements[k].flags &= 0xFE;
                i = j;
                continue;
            }

            version (DebugModbusSampler)
                client.log.tracef("Request: {0} [{1}{2,04x}:{3}]", server, elements[i].regKind, firstReg, count);

            i = j;
        }

        version (DebugModbusSampler)
        {
            if (++_diag_counter >= 100)
            {
                _diag_counter = 0;
                uint n_in_flight, n_const;
                foreach (ref e; elements)
                {
                    if (e.flags & 2) ++n_const;
                    else if (e.flags & 1) ++n_in_flight;
                }
                client.log.debugf("Sampler {0}: {1} elements, {2} in-flight, {3} const-done",
                    server, elements.length, n_in_flight, n_const);
            }
        }
    }

    final void add_element(Element* element, ref const ElementDesc desc, ref const ElementDesc_Modbus reg_info)
    {
        SampleElement* e = &elements.pushBack();
        e.element = element;
        e.register = reg_info.reg;
        e.regKind = reg_info.reg_type;
        e.desc = reg_info.value_desc;
        switch (desc.update_frequency)
        {
            case Frequency.realtime:       e.sampleTimeMs = 1;           e.pcp = PCP.bk; e.dei = true;  break;
            case Frequency.high:           e.sampleTimeMs = 1_000;       e.pcp = PCP.bk; e.dei = false; break;
            case Frequency.medium:         e.sampleTimeMs = 10_000;      e.pcp = PCP.be; e.dei = false; break;
            case Frequency.low:            e.sampleTimeMs = 60_000;      e.pcp = PCP.ee; e.dei = false; break;
            case Frequency.constant:       e.sampleTimeMs = 0;           e.pcp = PCP.ca; e.dei = false; break;
            case Frequency.configuration:  e.sampleTimeMs = 0;           e.pcp = PCP.ca; e.dei = false; break;
            case Frequency.on_demand:      e.sampleTimeMs = ushort.max;  e.pcp = PCP.ca; e.dei = false; break;
            default: assert(false);
        }

        // we need to re-sort the regs after adding any new ones...
        needsSort = true;
    }

    final override void remove_element(Element* element)
    {
        // TODO: find the element in the list and remove it...
    }

private:

    ModbusClient client;
    MACAddress server;
    Array!SampleElement elements;
    ushort retryTime = 500;
    bool needsSort = true;
    bool snooping;
    version (DebugModbusSampler)
        ubyte _diag_counter;

    struct SampleElement
    {
        SysTime lastUpdate;
        ushort register;
        ubyte regKind;
        ubyte flags; // 1 - in-flight, 2 - constant-sampled, 4 - ...
        ushort sampleTimeMs;
        PCP pcp;
        bool dei;
        Element* element;
        ValueDesc desc;
        ubyte seqLen() const pure nothrow @nogc
            => cast(ubyte)(desc.data_length / 2);
    }

    void response_handler(ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time)
    {
        ubyte kind = request.function_code == FunctionCode.read_holding_registers ? 4 :
                     request.function_code == FunctionCode.read_input_registers ? 3 :
                     request.function_code == FunctionCode.read_discrete_inputs ? 1 :
                     request.function_code == FunctionCode.read_coils ? 0 : ubyte.max;
        ushort first = request.data[0..2].bigEndianToNative!ushort;
        ushort count = request.data[2..4].bigEndianToNative!ushort;

        // do some integrity validation...
        ushort responseBytes = response.data[0];
        if (responseBytes + 1 > response.data.length)
        {
            client.log.warning("incomplete response from ", server);
            release_in_flight(kind, first, count);
            return;
        }
        if (response.function_code != request.function_code)
        {
            client.log.warning("function code mismatch from ", server,
                " expected=", cast(ubyte)request.function_code, " got=", cast(ubyte)response.function_code);
            release_in_flight(kind, first, count);
            return;
        }

        if ((kind < 2 && responseBytes * 8 != count.align_up(8)) ||
            (kind > 2 && responseBytes / 2 != count))
        {
            client.log.warning("response length mismatch from ", server,
                " bytes=", responseBytes, " expected=", count * 2);
            release_in_flight(kind, first, count);
            return;
        }

        version (DebugModbusSampler)
            client.log.tracef("Response: {0}, [{1}{2,04x}:{3}] - {4}", server, kind, first, count, response_time - request_time);

        ubyte[] data = response.data[1 .. 1 + responseBytes];

        foreach (ref e; elements)
        {
            if (e.regKind != kind || e.register < first || e.register >= first + count)
                continue;

            e.lastUpdate = response_time;

            if (!snooping)
            {
                // release the in-flight flag
                e.flags &= 0xFE;

                // if the value is constant, and we received a valid response, then we won't ask again
                if (e.sampleTimeMs == 0)
                    e.flags |= 2;
            }

            // parse value from the response...
            ushort offset = cast(ushort)(e.register - first);
            uint byteOffset = offset*2;
            if (kind <= 1)
            {
                bool value = ((data[offset >> 3] >> (offset & 7)) & 1) != 0;
                assert(false, "TODO: test this and store the value...");
            }
            else
                e.element.value(sample_value(data.ptr + byteOffset, e.desc), response_time);

            version (DebugModbusSampler)
                client.log.tracef("Got reg {0,04x}: {1} = {2}", e.register, e.element.id, e.element.value);
        }
    }

    void error_handler(ModbusErrorType errorType, ref const ModbusPDU request, SysTime request_time)
    {
        ubyte kind = request.function_code == FunctionCode.read_holding_registers ? 4 :
                     request.function_code == FunctionCode.read_input_registers ? 3 :
                     request.function_code == FunctionCode.read_discrete_inputs ? 1 :
                     request.function_code == FunctionCode.read_coils ? 0 : ubyte.max;
        ushort first = request.data[0..2].bigEndianToNative!ushort;
        ushort count = request.data[2..4].bigEndianToNative!ushort;

        version (DebugModbusSampler)
            client.log.debugf("Timeout: [{0}{1,04x}:{2}] - {3}", kind, first, count, getTime()-request_time);

        release_in_flight(kind, first, count);
    }

    void release_in_flight(ubyte kind, ushort first, ushort count)
    {
        if (snooping)
            return;
        foreach (ref e; elements)
        {
            if (e.regKind != kind || e.register < first || e.register >= first + count)
                continue;
            e.flags &= 0xFE;
        }
    }

    void snoop_handler(ref const MACAddress server, ref const ModbusPDU request, ref ModbusPDU response, SysTime request_time, SysTime response_time)
    {
        // check it's a response from the server we're interested in
        if (server != this.server)
            return;

        response_handler(request, response, request_time, response_time);
    }
}
