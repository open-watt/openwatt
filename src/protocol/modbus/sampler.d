module protocol.modbus.sampler;

import urt.array;
import urt.endian;
import urt.log;
import urt.time;
import urt.util : alignUp;

import manager.element;
import manager.sampler;
import manager.value;

import protocol.modbus.client;

import router.iface.mac;
import router.modbus.message;
import router.modbus.profile;

nothrow @nogc:


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
        import router.modbus.message;

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

            debug writeDebugf("Request: {0} [{1}{2,04x}:{3}]", server, elements[i].regKind, firstReg, count);

            i = j;
        }
    }

    final void addElement(Element* element, ref const ModbusRegInfo regInfo)
    {
        SampleElement* e = &elements.pushBack();
        e.element = element;
        e.register = regInfo.reg;
        e.regKind = regInfo.regType;
        e.type = encodeType(regInfo.type, regInfo.seqLen);
        e.seqLen = regInfo.seqLen;
        switch (regInfo.desc.updateFrequency)
        {
            case Frequency.Realtime:       e.sampleTimeMs = 400;         break; // as fast as possible
            case Frequency.High:           e.sampleTimeMs = 1_000;       break; // seconds
            case Frequency.Medium:         e.sampleTimeMs = 10_000;      break; // 10s seconds
            case Frequency.Low:            e.sampleTimeMs = 60_000;      break; // minutes
            case Frequency.Constant:       e.sampleTimeMs = 0;           break; // just once
            case Frequency.Configuration:  e.sampleTimeMs = 0;           break; // HACK: sample config items once
            case Frequency.OnDemand:       e.sampleTimeMs = ushort.max;  break; // only explicit
            default: assert(false);
        }

        // we need to re-sort the regs after adding any new ones...
        needsSort = true;
    }

    final override void removeElement(Element* element)
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
        Element* element;
        ushort register;
        ubyte regKind;
        ubyte seqLen;
        ubyte type;
        ubyte flags; // 1 - in-flight, 2 - constant-sampled, 4 - ...
        ushort sampleTimeMs;
        MonoTime lastUpdate;
    }

    void responseHandler(ref const ModbusPDU request, ref ModbusPDU response, MonoTime requestTime, MonoTime responseTime)
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
        if (kind < 2 && responseBytes * 8 != count.alignUp(8))
            return;
        else if (kind > 2 && responseBytes / 2 != count)
            return;

        debug writeDebugf("Response: {0}, [{1}{2,04x}:{3}] - {4}", server, kind, first, count, responseTime - requestTime);

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
//            else
//                debug writeDebugf("Got reg {0, 04x}: {1} ", e.register, e.element.id);

            // parse value from the response...
            ushort offset = cast(ushort)(e.register - first);
            uint byteOffset = offset*2;
            if (kind <= 1)
            {
                bool value = ((data[offset >> 3] >> (offset & 7)) & 1) != 0;
                assert(false, "TODO: test this and store the value...");
            }
            else
            {
                Type type;
                ubyte arrayLen;
                Endian endian;

                if (!e.type.decodeType(type, arrayLen, endian))
                    continue;

                final switch (type)
                {
                    case Type.U8_L:
                    case Type.S8_L:
                        ++byteOffset;
                        goto case;
                    case Type.U8_H:
                    case Type.S8_H:
                        e.element.latest = Value((type & 1) ? cast(byte)data[byteOffset] : data[byteOffset]);
                        break;

                    case Type.YM_DH_MS:
                    case Type.YY_MD_HM:
                        assert(false, "TODO");

                    case Type.U16:
                    case Type.S16:
                        ushort val;
                        if (endian < Endian.LE_BE)
                            val = data[byteOffset..byteOffset+2][0..2].bigEndianToNative!ushort;
                        else
                            val = data[byteOffset..byteOffset+2][0..2].littleEndianToNative!ushort;
                        e.element.latest = Value(type == Type.U16 ? val : cast(short)val);
                        break;

                    case Type.U32:
                    case Type.S32:
                    case Type.F32:
                        uint val;
                        final switch (endian)
                        {
                            case Endian.BE_BE:
                                val = data[byteOffset..byteOffset+4][0..4].bigEndianToNative!uint;
                                break;
                            case Endian.LE_LE:
                                val = data[byteOffset..byteOffset+4][0..4].littleEndianToNative!uint;
                                break;
                            case Endian.BE_LE:
                                val = data[byteOffset..byteOffset+2][0..2].bigEndianToNative!ushort |
                                      (data[byteOffset+2..byteOffset+4][0..2].bigEndianToNative!ushort << 16);
                                break;
                            case Endian.LE_BE:
                                val = (data[byteOffset..byteOffset+2][0..2].littleEndianToNative!ushort << 16) |
                                      data[byteOffset+2..byteOffset+4][0..2].littleEndianToNative!ushort;
                                break;
                        }
                        if (type == Type.F32)
                            e.element.latest = Value(*cast(float*)&val);
                        else if (type == Type.U32)
                            e.element.latest = Value(val);
                        else
                            e.element.latest = Value(cast(int)val);
                        break;

                    case Type.U64:
                    case Type.S64:
                    case Type.F64:
                        assert(false, "TODO: our value only has int!");

                    case Type.U128:
                    case Type.S128:
                        assert(false, "TODO: our value only has int!");

                    case Type.String:
                        size_t len = 0;
                        while (len < arrayLen*2 && data[len] != '\0')
                            ++len;
                        const(char)[] string = cast(char[])data[0..len];
                        // TODO: NEED TO ALLOCATE STRINGS!!!
                        e.element.latest = Value(string);
                        break;
                }
            }
        }
    }

    void errorHandler(ModbusErrorType errorType, ref const ModbusPDU request, MonoTime requestTime)
    {
        ubyte kind = request.functionCode == FunctionCode.ReadHoldingRegisters ? 4 :
                     request.functionCode == FunctionCode.ReadInputRegisters ? 3 :
                     request.functionCode == FunctionCode.ReadDiscreteInputs ? 1 :
                     request.functionCode == FunctionCode.ReadCoils ? 0 : ubyte.max;
        ushort first = request.data[0..2].bigEndianToNative!ushort;
        ushort count = request.data[2..4].bigEndianToNative!ushort;

        debug writeDebugf("Timeout: [{0}{1,04x}:{2}] - {3}", kind, first, count, getTime()-requestTime);

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

    void snoopHandler(ref const MACAddress server, ref const ModbusPDU request, ref ModbusPDU response, MonoTime requestTime, MonoTime responseTime)
    {
        // check it's a response from the server we're interested in
        if (server != this.server)
            return;

        responseHandler(request, response, requestTime, responseTime);
    }
}


/+
// value TYPE encoding into 1 byte...

000xxxxx  // u/hb, u/lb, date/date, u/s_be, u/s_le (22 remaining)
001eettt  // u/i, u/l, u/c, f/d
01        // 64 unassigned values (this could be used for arrays of int,uint,float,double up to max length 16
10strlen
110uslen
111sslen
// 86 values remaining!

+/

enum Type : ubyte
{
    U8_H,
    S8_H,
    U8_L,
    S8_L,
    YM_DH_MS,
    YY_MD_HM,
    U16,
    S16,
    U32,
    S32,
    U64,
    S64,
    U128,
    S128,
    F32,
    F64,
    String
}
enum Endian : ubyte
{
    BE_BE, // words are big endian, sequence of words are high-word-first
    BE_LE, // words are big endian, sequence of words are low-word-first
    LE_BE, // words are little endian, sequence of words are high-word-first
    LE_LE, // words are little endian, sequence of words are low-word-first
}
enum Access : ubyte
{
    RO, // read-only
    WO, // write-only
    RW, // read-write
}


ubyte encodeType(const(char)[] s)
{
    assert(false);
}

ubyte encodeType(RecordType rt, ubyte seqLen)
{
    struct RecEnd
    {
        Type ty;
        Endian en;
        ubyte words;
    }
    __gshared immutable RecEnd[RecordType.str] rtMap = [
        RecEnd(Type.U16, Endian.BE_BE, 1),
        RecEnd(Type.S16, Endian.BE_BE, 1),
        RecEnd(Type.U32, Endian.LE_LE, 2),
        RecEnd(Type.U32, Endian.BE_BE, 2),
        RecEnd(Type.S32, Endian.LE_LE, 2),
        RecEnd(Type.S32, Endian.BE_BE, 2),
        RecEnd(Type.U64, Endian.LE_LE, 4),
        RecEnd(Type.U64, Endian.BE_BE, 4),
        RecEnd(Type.S64, Endian.LE_LE, 4),
        RecEnd(Type.S64, Endian.BE_BE, 4),
        RecEnd(Type.U8_H, Endian.BE_BE, 1),
        RecEnd(Type.U8_L, Endian.BE_BE, 1),
        RecEnd(Type.S8_H, Endian.BE_BE, 1),
        RecEnd(Type.S8_L, Endian.BE_BE, 1),
        RecEnd(Type.U16, Endian.BE_BE, 1),
        RecEnd(Type.F32, Endian.LE_LE, 2),
        RecEnd(Type.F32, Endian.BE_BE, 2),
        RecEnd(Type.F64, Endian.LE_LE, 4),
        RecEnd(Type.F64, Endian.BE_BE, 4),
        RecEnd(Type.U16, Endian.BE_BE, 1),
        RecEnd(Type.U32, Endian.BE_BE, 2),
        RecEnd(Type.U64, Endian.BE_BE, 4),
        RecEnd(Type.U16, Endian.BE_BE, 1),
        RecEnd(Type.U32, Endian.BE_BE, 2),
        RecEnd(Type.F32, Endian.BE_BE, 2),
    ];

    assert(rt != RecordType.exp10, "TODO: support me!");
    if (rt >= RecordType.str)
    {
        assert(seqLen > 0 && seqLen <= 64);
        return cast(ubyte)(0x80 | (seqLen - 1));
    }
    assert(rtMap[rt].words == seqLen);
    return encodeType(rtMap[rt].ty, 0, rtMap[rt].en);
}

ubyte encodeType(Type type, ubyte arrayLen, Endian endian = Endian.BE_BE)
{
    if (type == Type.String)
    {
        assert(arrayLen > 0 && arrayLen <= 64);
        return cast(ubyte)(0x80 | (arrayLen - 1));
    }
    else if (arrayLen > 0)
    {
        assert(type == Type.U16 || type == Type.S16);
        assert(arrayLen <= 32);
        return cast(ubyte)((type == Type.U16 ? 0xC0 : 0xE0) | (arrayLen - 1));
    }
    else if (type >= Type.U32 && type <= Type.F64)
        return cast(ubyte)(0x20 | (endian << 3) | (type - Type.U32));
    else if (type >= Type.U16 && type <= Type.S16 && endian >= Endian.LE_BE)
        return cast(ubyte)(type + 2);
    else
        return type;
}

bool decodeType(ubyte encoded, out Type type, out ubyte arrayLen, out Endian endian)
{
    final switch (encoded >> 5)
    {
        case 0:
            type = cast(Type)(encoded & 0x1F);
            if (type >= Type.U32)
            {
                if (type >= Type.U32 + 2)
                    return false;
                type -= 2;
                endian = Endian.LE_BE;
            }
            break;
        case 1:
            type = cast(Type)(Type.U32 + (encoded & 0x7));
            endian = cast(Endian)((encoded >> 3) & 0x3);
            break;
        case 2:
        case 3:
            // 64 reserved values...
            return false;
        case 4:
        case 5:
            type = Type.String;
            arrayLen = (encoded & 0x3F) + 1;
            break;
        case 6:
            type = Type.U16;
            arrayLen = (encoded & 0x1F) + 1;
            break;
        case 7:
            type = Type.S16;
            arrayLen = (encoded & 0x1F) + 1;
            break;
    }
    return true;
}
