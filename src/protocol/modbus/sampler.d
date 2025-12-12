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

//version = DebugModbusSampler;

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

    // TODO: this may be insifficient, but it's what we already model...
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
            client.setSnoopHandler(&snoopHandler);
    }

    final override void update()
    {
        import protocol.modbus.message;

        if (needsSort)
        {
            import urt.lifetime : move;

            // TODO: D lib has sort, we don't have this in urt...
            import std.algorithm : copy;
            import std.algorithm.sorting;
            import std.algorithm.mutation : SwapStrategy;

            Array!SampleElement sorted;
            sorted.resize(elements.length);
            elements[].multiSort!("a.regKind < b.regKind", "a.register < b.register", SwapStrategy.unstable).copy(sorted[]);
            elements = sorted.move;
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

            // scan for a stripe of registers to sample
            size_t j = i + 1;
            for (; j < elements.length; ++j)
            {
                // skip any registers that shouldn't be sampled
                if ((elements[j].flags & 3) || // if it's in flight or a constant has alrady been sampled
                    elements[i].sampleTimeMs == ushort.max || // strictly on-demand
                    now - elements[j].lastUpdate < msecs(elements[j].sampleTimeMs)) // if it's not yet time to sample again
                {
                    ++j;
                    continue;
                }

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

                // flag in-flight
                elements[j].flags |= 1;
            }

            // send request
            ModbusPDU pdu = createMessage_Read(cast(RegisterType)elements[i].regKind, firstReg, count);
            client.sendRequest(server, pdu, &responseHandler, &errorHandler, 0, retryTime);

            version (DebugModbusSampler)
                writeDebugf("Request: {0} [{1}{2,04x}:{3}]", server, elements[i].regKind, firstReg, count);

            i = j;
        }
    }

    final void addElement(Element* element, ref const ElementDesc desc, ref const ElementDesc_Modbus reg_info)
    {
        SampleElement* e = &elements.pushBack();
        e.element = element;
        e.register = reg_info.reg;
        e.regKind = reg_info.reg_type;
        e.desc = reg_info.value_desc;
        switch (desc.update_frequency)
        {
            case Frequency.realtime:       e.sampleTimeMs = 400;         break; // as fast as possible
            case Frequency.high:           e.sampleTimeMs = 1_000;       break; // seconds
            case Frequency.medium:         e.sampleTimeMs = 10_000;      break; // 10s seconds
            case Frequency.low:            e.sampleTimeMs = 60_000;      break; // minutes
            case Frequency.constant:       e.sampleTimeMs = 0;           break; // just once
            case Frequency.configuration:  e.sampleTimeMs = 0;           break; // HACK: sample config items once
            case Frequency.on_demand:      e.sampleTimeMs = ushort.max;  break; // only explicit
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

    struct SampleElement
    {
        SysTime lastUpdate;
        ushort register;
        ubyte regKind;
        ubyte flags; // 1 - in-flight, 2 - constant-sampled, 4 - ...
        ushort sampleTimeMs;
        Element* element;
        ValueDesc desc;
        ubyte seqLen() const pure nothrow @nogc
            => cast(ubyte)(desc.data_length / 2);
    }

    void responseHandler(ref const ModbusPDU request, ref ModbusPDU response, SysTime requestTime, SysTime responseTime)
    {
        ubyte kind = request.functionCode == FunctionCode.ReadHoldingRegisters ? 4 :
                     request.functionCode == FunctionCode.ReadInputRegisters ? 3 :
                     request.functionCode == FunctionCode.ReadDiscreteInputs ? 1 :
                     request.functionCode == FunctionCode.ReadCoils ? 0 : ubyte.max;
        ushort first = request.data[0..2].bigEndianToNative!ushort;
        ushort count = request.data[2..4].bigEndianToNative!ushort;

        // do some integrity validation...
        ushort responseBytes = response.data[0];
        if (responseBytes + 1 > response.data.length)
        {
            writeWarning("Incomplete or corrupt modbus response from ", server);
            return;
        }
        if (response.functionCode != request.functionCode)
        {
            // should be an exception? ...or some other corruption.
            return;
        }

        // I don't think it's valid for a response length to not match the request?
        // if this happens, it must be a response to a different request
        if (kind < 2 && responseBytes * 8 != count.align_up(8))
            return;
        else if (kind > 2 && responseBytes / 2 != count)
            return;

        version (DebugModbusSampler)
            writeDebugf("Response: {0}, [{1}{2,04x}:{3}] - {4}", server, kind, first, count, responseTime - requestTime);

        ubyte[] data = response.data[1 .. 1 + responseBytes];

        foreach (ref e; elements)
        {
            if (e.regKind != kind || e.register < first || e.register >= first + count)
                continue;

            e.lastUpdate = responseTime;

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
                e.element.latest = sample_value(data.ptr + byteOffset, e.desc);

            version (DebugModbusSampler)
                writeDebugf("Got reg {0, 04x}: {1} = {2}", e.register, e.element.id, e.element.value);
        }
    }

    void errorHandler(ModbusErrorType errorType, ref const ModbusPDU request, SysTime requestTime)
    {
        ubyte kind = request.functionCode == FunctionCode.ReadHoldingRegisters ? 4 :
                     request.functionCode == FunctionCode.ReadInputRegisters ? 3 :
                     request.functionCode == FunctionCode.ReadDiscreteInputs ? 1 :
                     request.functionCode == FunctionCode.ReadCoils ? 0 : ubyte.max;
        ushort first = request.data[0..2].bigEndianToNative!ushort;
        ushort count = request.data[2..4].bigEndianToNative!ushort;

        version (DebugModbusSampler)
            writeDebugf("Timeout: [{0}{1,04x}:{2}] - {3}", kind, first, count, getTime()-requestTime);

        // release all the in-flight flags...
        foreach (ref e; elements)
        {
            if (e.regKind != kind || e.register < first || e.register >= first + count)
                continue;

//            assert(e.flags & 1, "How did we get a response for a register not marked as in-flight?");
            e.flags &= 0xFE;
        }

        if (errorType == ModbusErrorType.Timeout)
        {
            // TODO: we might adjust the timeout threshold so that actual data failures happen sooner and don't block up the queue...
        }
    }

    void snoopHandler(ref const MACAddress server, ref const ModbusPDU request, ref ModbusPDU response, SysTime requestTime, SysTime responseTime)
    {
        // check it's a response from the server we're interested in
        if (server != this.server)
            return;

        responseHandler(request, response, requestTime, responseTime);
    }
}
