module protocol.http.sampler;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import manager.element;
import manager.sampler;
import manager.value;

import protocol.http.client;

//version = DebugHTTPSampler;

nothrow @nogc:


enum ResponseProtocol
{
    PlainText,
    Json
}

class HTTPSampler : Sampler
{
nothrow @nogc:

    struct Request
    {
        this(this) @disable;

        HTTPMethod method;
        String uri;
        String username, password;
        Array!ubyte content;
        Array!HTTPParam queryParams;
        Duration frequency;
    }

    this(HTTPClient client, ResponseProtocol protocol)
    {
        this.client = client;
        this.protocol = protocol;
    }

    final override void update()
    {
/+
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
+/
    }

    final size_t addRequest(Request request)
    {
        requests.emplaceBack(request.move, MonoTime());
        return requests.length - 1;
    }

    final void addElement(size_t requestHandle, Element* element, String parseResponse)
    {
        SampleElement* e = &elements.pushBack();
        e.request = requestHandle;
        e.element = element;
        e.parseResponse = parseResponse.move;
    }

    final override void removeElement(Element* element)
    {
        // TODO: find the element in the list and remove it...
    }

private:

    HTTPClient client;
    ResponseProtocol protocol;

    ushort retryTime = 5000;

    Array!RequestData requests;
    Array!SampleElement elements;

    struct RequestData
    {
        Request r;
        MonoTime lastPoll;
    }

    struct SampleElement
    {
        size_t request;
        Element* element;
        String parseResponse; // plain text format, json lookup, etc...
    }

    void responseHandler(ref HTTPResponse response) nothrow @nogc
    {
/+
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
                        ulong val;
                        final switch (endian)
                        {
                            case Endian.BE_BE:
                                val = data[byteOffset..byteOffset+8][0..8].bigEndianToNative!ulong;
                                break;
                            case Endian.LE_LE:
                                val = data[byteOffset..byteOffset+8][0..8].littleEndianToNative!ulong;
                                break;
                            case Endian.BE_LE:
                                val = data[byteOffset..byteOffset+2][0..2].bigEndianToNative!ushort |
                                    (data[byteOffset+2..byteOffset+4][0..2].bigEndianToNative!ushort << 16) |
                                    (cast(ulong)data[byteOffset+4..byteOffset+6][0..2].bigEndianToNative!ushort << 32) |
                                    (cast(ulong)data[byteOffset+6..byteOffset+8][0..2].bigEndianToNative!ushort << 48);
                                break;
                            case Endian.LE_BE:
                                val = (cast(ulong)data[byteOffset..byteOffset+2][0..2].littleEndianToNative!ushort << 48) |
                                    (cast(ulong)data[byteOffset+2..byteOffset+4][0..2].littleEndianToNative!ushort << 32) |
                                    (data[byteOffset+4..byteOffset+6][0..2].littleEndianToNative!ushort << 16) |
                                    data[byteOffset+6..byteOffset+8][0..2].littleEndianToNative!ushort;
                                break;
                        }
                        if (type == Type.F64)
                            e.element.latest = Value(cast(float) *cast(double*)&val);
                        else if (type == Type.U64)
                            e.element.latest = Value(cast(uint) val);
                        else
                            e.element.latest = Value(cast(int) cast(long)val);
//                        assert(false, "TODO: our value only has int!");
                        break;

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

            version (DebugModbusSampler)
                writeDebugf("Got reg {0, 04x}: {1} = {2}", e.register, e.element.id, e.element.value);
        }
+/
    }
}
