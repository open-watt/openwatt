module protocol.ezsp.ashv2;

import urt.array;
import urt.crc;
import urt.endian;
import urt.log;
import urt.mem.allocator;
import urt.time;

import router.stream;

//version = DebugASHMessageFlow;

alias ezsp_crc = calculate_crc!(Algorithm.crc16_ezsp);

nothrow @nogc:


//
// EZSP over UART wraps the command stream in a carrier protocol called "Asynchronous Serial Host" described here:
// https://www.silabs.com/documents/public/user-guides/ug101-uart-gateway-protocol-reference.pdf
//


struct ASH
{
nothrow @nogc:

    enum Event
    {
        Reset
    }

    this (Stream stream) pure
    {
        this.stream = stream;
    }

    ~this()
    {
        reset();

        while (freeList)
        {
            auto next = freeList.next;
            defaultAllocator.freeT!Message(freeList);
            freeList = next;
        }
    }

    bool isConnected() const pure
        => connected;

    void setEventCallback(void delegate(Event event) nothrow @nogc callback) pure
    {
        eventCallback = callback;
    }

    void setPacketCallback(void delegate(const(ubyte)[]) nothrow @nogc callback) pure
    {
        packetCallback = callback;
    }

    void reset(bool reconnect = true)
    {
        connecting = reconnect;

        if (!connected)
            return;
        connected = false;

        writeDebug("ASHv2: connection reset");

        // clear all the queues...
        txSeq = rxSeq = 0;
        txAck = 0;
        rxOffset = 0;

        // shift all the in-flight packets to the free-list
        Message* next;
        while (txInFlight)
        {
            next = txInFlight.next;
            freeMessage(txInFlight);
            txInFlight = next;
        }
        while (txQueue)
        {
            next = txQueue.next;
            freeMessage(txQueue);
            txQueue = next;
        }

        lastEvent = MonoTime();

        eventCallback(Event.Reset);
    }

    void update()
    {
        MonoTime now = getTime();

        if (!stream.running)
            reset();

        if (connecting && !connected && now - lastEvent > T_RSTACK_MAX.msecs && stream.running)
        {
            writeDebug("ASHv2: connecting on '", stream.name, "'...");
            ashRst();
            lastEvent = now;
        }

        do
        {
            ptrdiff_t r = stream.read(rxBuffer[rxOffset..$]);
            if (r <= 0)
                break;

            // should we record raw bytes, or protocol bytes?
            rxBytes += r;

            // skip any XON/XOFF bytes
            ubyte rxLen = rxOffset;
            for (ubyte i = rxOffset; i < rxOffset + r; ++i)
            {
                if (rxBuffer[i] == ASH_XON_BYTE || rxBuffer[i] == ASH_XOFF_BYTE)
                    continue;
                rxBuffer[rxLen++] = rxBuffer[i];
            }

            // parse frames from stream delimited by 0x7E bytes
            ubyte start = 0;
            ubyte end = 0;
            bool inputError = false;
            outer: for (; end < rxLen; ++end)
            {
                if (rxBuffer[end] == ASH_SUBSTITUTE_BYTE)
                {
                    // the 'substitution byte' is inserted by the UART in the event of a stream error
                    // if we receive this byte, we should discard this frame
                    inputError = true;
                }
                else if (rxBuffer[end] == ASH_CANCEL_BYTE)
                {
                    // the 'cancel byte' is used to cancel the current frame and start over from the next byte
                    // used to discard any preceeding bytes, for example; rogue bytes emit during system startup, or dangling bytes sent prior to system reset
                    start = cast(ubyte)(end + 1);
                }
                if (rxBuffer[end] != ASH_FLAG_BYTE)
                    continue;

                // if we encountered an input error in the stream (result of a substitution byte), we'll discard this frame
                if (inputError)
                {
                    inputError = false;
                    start = cast(ubyte)(end + 1);
                    ++rxErrors;
                    continue;
                }

                // remove byte-stuffing from the frame
                ubyte frameLen = 0;
                for (ubyte i = start; i < end; ++i)
                {
                    ubyte b = rxBuffer[i];
                    if (b == ASH_ESCAPE_BYTE)
                    {
                        if (++i == end)
                        {
                            start = cast(ubyte)(end + 1);
                            continue outer;
                        }
                        rxBuffer[start + frameLen++] = rxBuffer[i] ^ 0x20;
                    }
                    else
                        rxBuffer[start + frameLen++] = b;
                }

                ubyte frameStart = start;
                start = cast(ubyte)(end + 1);

                if (frameLen < 2)
                {
                    if (frameLen != 0)
                        ++rxErrors;
                    continue;
                }

                // validate the frame
                int frameEnd = frameStart + frameLen - 2;
                ubyte[] frame = rxBuffer[frameStart .. frameEnd];

                // check the crc
                const ushort crc = frame.ezsp_crc();
                if (rxBuffer[frameEnd .. frameEnd + 2][0..2].bigEndianToNative!ushort != crc)
                {
                    // corrupt frame!
                    // TODO: but maybe we should send a NAK?
                    ++rxErrors;
                    continue;
                }

                ++rxPackets;

                // submit the frame for processing
                processFrame(frame);
            }

            // shuffle any tail bytes (incomplete frames) to the start of the buffer...
            rxOffset = cast(ubyte)(rxLen - start);
            if (start > 0)
            {
                import urt.mem : memmove;
                memmove(rxBuffer.ptr, rxBuffer.ptr + start, rxOffset);
            }
        }
        while(true);

        // do we just try and resend the first in the queue?
        if (txInFlight && now - txInFlight.sendTime >= 250.msecs)
        {
            ashNak(txInFlight.seq, false);
            txInFlight.sendTime = now;
        }
    }

    void processFrame(ubyte[] frame)
    {
        ubyte control = frame.popFront;

        // check for RSTACK
        if (control == 0xC1)
        {
            if (frame.length == 2)
            {
                ashVersion = frame[0];
                ubyte code = frame[1];

                connecting = false; // unsupported version, stop trying to connect!
                if (ashVersion == 2)
                    connected = true;

                writeDebug(connected ? "ASHv2: connected! code=" : "ASHv2: connection failed; unsupported version! code=", code);
                return;
            }
        }
        // we can't accept any frames before we receive RSTACK
        if (!connected)
            return;

        // check for ERROR
        if (control == 0xC2)
        {
            // ERROR
            if (frame.length == 2)
            {
                ubyte ver = frame[0];
                ubyte code = frame[1];

                writeDebug("ASHv2: <-- ERROR. code=", code);
            }

            // TODO: ...what to do when receiving an error frame?
            reset();
            return;
        }

        ubyte ackNum = control & 7;
        int ackAhead = ackNum >= txAck ? ackNum - txAck : ackNum - txAck + 8;
        if (ackAhead > txAhead())
            return; // discard frames with invalid ackNum

        // check for other control codes
        if (control & 0x80)
        {
            if ((control & 0x60) == 0)
            {
                // ACK
                version (DebugASHMessageFlow)
                    writeDebugf("ASHv2: <-- ACK [{0,02x}]", control);

                ackInFlight(ackNum);
            }
            else if ((control & 0x60) == 0x20)
            {
                // NAK
                version (DebugASHMessageFlow)
                    writeDebugf("ASHv2: <-- NAK [{0,02x}]", control);

                // TODO: we're meant to retransmit a buffered message
                //       ...but it's not clear from the control byte which message(/s) I should retransmit?
                //       I guess we retransmit all messages from ackNum -> txSeq?
                //       I guess it should also be the case that ackNum must be the FIRST message in send queue?
            }
            else
            {
                // Invalid frame!
                // ...just ignore it?
                debug assert(false, "TODO: should we do anything here, or just return?");
            }

            return;
        }

        // DATA frame
        ubyte frmNum = control >> 4;
        bool retransmit = (control & 0x08) != 0;

        // acknowledge frame
        if (frmNum != rxSeq)
        {
            // not the frame we expected; request a retransmit and discard this frame
            ashNak(rxSeq, false);
            return;
        }

        // get data buffer
        ubyte[] data = void;
        ubyte[ASH_MAX_LENGTH] tmp = void;
        data = tmp[0 .. frame.length];

        // de-randomise the frame data
        randomise(frame, data);

        version (DebugASHMessageFlow)
            writeDebugf("ASHv2: <-- [x{0, 02x}]: {1}", control, cast(void[])data);

        rxSeq = (rxSeq + 1) & 7;
        ashAck(rxSeq, false);

        packetCallback(data);

        ackInFlight(ackNum);
    }

    void ackInFlight(ubyte ackNum)
    {
        while (txAck != ackNum)
        {
            if (!txInFlight || txInFlight.seq != txAck)
            {
                // TODO: what is the proper recovery strategy in this case? reset the connection?
                assert(false, "We've gone off the rails!");
            }

            Message* msg = txInFlight;
            txInFlight = txInFlight.next;
            freeMessage(msg);

            txAck = (txAck + 1) & 7;
        }

        // we can send any queued frames here...
        while (txQueue && txAhead < maxInFlight)
        {
            Message* next = txQueue.next;
            if (!send(txQueue))
                break;
            txQueue = next;
        }
    }

    bool send(const(ubyte)[] message)
    {
        assert(message.length <= ASH_MAX_MSG_LENGTH);

        // TODO: this would be a little nicer if we had a list container...

        Message* msg = allocMessage();
        msg.length = cast(ubyte)message.length;
        msg.buffer[0..message.length] = message[];
        if (txAhead >= maxInFlight || !send(msg))
        {
            // couldn't send immediately; add to send queue
            if (!txQueue)
                txQueue = msg;
            else
            {
                Message* m = txQueue;
                while (m.next)
                    m = m.next;
                m.next = msg;
                msg.next = null;
            }
        }
        return true;
    }

private:

    enum T_RSTACK_MAX           = 3200;

    enum ASH_CANCEL_BYTE        = 0x1A;
    enum ASH_FLAG_BYTE          = 0x7E;
    enum ASH_ESCAPE_BYTE        = 0x7D;
    enum ASH_SUBSTITUTE_BYTE    = 0x18;
    enum ASH_XON_BYTE           = 0x11;
    enum ASH_XOFF_BYTE          = 0x13;
    enum ASH_TIMEOUT            = -1;
    enum ASH_MAX_LENGTH         = 131;
    enum ASH_MAX_MSG_LENGTH     = 128;

    struct Message
    {
        Message* next;
        MonoTime sendTime;
        ubyte seq;
        ubyte length;
        ubyte[ASH_MAX_MSG_LENGTH] buffer;

        ubyte[] payload() pure nothrow @nogc
            => buffer[0 .. length];
    }

    void delegate(Event event) nothrow @nogc eventCallback;
    void delegate(const(ubyte)[] packet) nothrow @nogc packetCallback;

    package Stream stream;
    MonoTime lastEvent;

    bool connecting = true;
    bool connected;
    ubyte ashVersion;

    ubyte maxInFlight = 1; // how many frames we will send without being ack-ed (1-7)

    ubyte txSeq; // the next frame to be sent
    ubyte txAck = 0; // the next frame we expect an ack for
    ubyte txAhead() => txSeq >= txAck ? cast(ubyte)(txSeq - txAck) : cast(ubyte)(txSeq - txAck + 8);

    ubyte rxSeq = 0; // the next frame we expect to receive

    uint rxBytes, txBytes;
    uint rxPackets, txPackets;
    uint rxErrors, txErrors;

    // TODO: received frames pending delivery because we missed one and sent a NAK
    Message* txInFlight; // frames that have been sent but not yet ack-ed
    Message* txQueue;    // frames waiting to be sent
    Message* freeList;

    ubyte rxOffset;
    ubyte[128] rxBuffer;

    Message* allocMessage()
    {
        Message* msg;
        if (freeList)
        {
            msg = freeList;
            freeList = freeList.next;
            msg.seq = 0;
            msg.next = null;
        }
        else
            msg = defaultAllocator.allocT!Message();
        msg.sendTime = MonoTime();
        return msg;
    }
    void freeMessage(Message* message)
    {
        message.next = freeList;
        freeList = message;
    }

    bool send(Message* msg)
    {
        if (!connected || !ashSend(msg.payload(), txSeq, rxSeq, false))
            return false;

        // add to in-flight list
        msg.next = null;
        msg.sendTime = getTime();
        msg.seq = txSeq;
        if (!txInFlight)
            txInFlight = msg;
        else
        {
            Message* m = txInFlight;
            while (m.next)
                m = m.next;
            m.next = msg;
        }
        txSeq = (txSeq + 1) & 7;

        return true;
    }

    bool ashRst()
    {
        version (DebugASHMessageFlow)
            writeDebug("ASHv2: --> RST");

        immutable ubyte[5] RST = [ ASH_CANCEL_BYTE, 0xC0, 0x38, 0xBC, ASH_FLAG_BYTE ];
        if (stream.write(RST) != 5)
        {
            ++txErrors;
            return false;
        }
        ++txPackets;
        txBytes += 5;
        return true;
    }

    bool ashAck(ubyte ack, bool ready, bool nak = false)
    {
        ubyte control = 0x80 | (nak ? 0x20 : 0) | (ready << 3) | (ack & 7);

        version (DebugASHMessageFlow)
            writeDebugf("ASHv2: --> {0} [x{1, 02x}]", nak ? "NAK" : "ACK", control);

        ubyte[4] ackMsg = [ control, 0, 0, ASH_FLAG_BYTE ];
        ackMsg[1..3] = ackMsg[0..1].ezsp_crc().nativeToBigEndian;
        if (stream.write(ackMsg) != 4)
        {
            ++txErrors;
            return false;
        }
        ++txPackets;
        txBytes += 4;
        return true;
    }

    bool ashNak(ubyte ack, bool ready)
        => ashAck(ack, ready, true);

    bool ashSend(const(ubyte)[] msg, ubyte seq, ubyte ack, bool retransmit)
    {
        // TODO: what is the maximum frame len?
        ubyte[256] frame = void;

        // add the control byte
        ubyte control = ((seq & 7) << 4) | (ack & 7) | (retransmit << 3);
        frame[0] = control;

        // randomise the data
        randomise(msg, frame[1..$]);

        // add the crc
        ushort crc = frame[0 .. 1 + msg.length].ezsp_crc();
        frame[1 + msg.length .. 3 + msg.length][0..2] = crc.nativeToBigEndian;

        // byte-stuffing
        ubyte[256] stuffed = void;
        size_t len = 0;
        foreach (i, b; frame[0 .. 1 + msg.length + 2])
        {
            if (b == 0x7E || b == 0x7D || b == 0x11 || b == 0x13 || b == 0x18 || b == 0x1A)
            {
                stuffed[len++] = ASH_ESCAPE_BYTE;
                stuffed[len++] = b ^ 0x20;
            }
            else
                stuffed[len++] = b;
        }

        // add flag byte
        stuffed[len++] = 0x7E;

        version (DebugASHMessageFlow)
            writeDebugf("ASHv2: --> [x{0, 02x}]: {1}", control, cast(void[])msg);

        ptrdiff_t r = stream.write(stuffed[0..len]);
        if (r != len)
        {
            version (DebugASHMessageFlow)
                writeDebug("ASHv2: stream write failed!");
            ++txErrors;
            return false;
        }

        ++txPackets;
        txBytes += r;
        return true;
    }

    static void randomise(const(ubyte)[] data, ubyte[] buffer) pure
    {
        ubyte rand = 0x42;
        foreach (i, b; data)
        {
            buffer[i] = b ^ rand;

            // TODO: which solution is actually better?

            ubyte b1 = cast(ubyte)-(rand & 1) & 0xB8;
            rand = (rand >> 1) ^ b1;

//            ubyte b1 = rand & 1;
//            rand >>= 1;
//            if (b1)
//                rand ^= 0xB8;
        }
    }
}
