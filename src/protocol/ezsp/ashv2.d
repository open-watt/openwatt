module protocol.ezsp.ashv2;

import urt.endian;
import urt.log;
import urt.time;

import router.stream;

nothrow @nogc:


//
// EZSP over UART wraps the command stream in a carrier protocol called "Asynchronous Serial Host" described here:
// https://www.silabs.com/documents/public/user-guides/ug101-uart-gateway-protocol-reference.pdf
//


struct ASH
{
nothrow @nogc:

    enum T_RSTACK_MAX           = 3200;

    enum ASH_CANCEL_BYTE        = 0x1A;
    enum ASH_FLAG_BYTE          = 0x7E;
    enum ASH_SUBSTITUTE_BYTE    = 0x18;
    enum ASH_XON_BYTE           = 0x11;
    enum ASH_OFF_BYTE           = 0x13;
    enum ASH_TIMEOUT            = -1;
    enum ASH_MAX_LENGTH         = 131;

    struct SendReq
    {
        enum State { Available, ReadyToSend, PendingAck }
        ushort offset;
        ubyte length;
        State state;
    }

    Stream stream;

    ubyte[128] rxBuffer;
    ubyte[1024] transmitBuffer;
    SendReq[8] sendQueue;
    MonoTime lastEvent;

    ushort transmitOffset;
    ushort recvOffset;
    ubyte rxOffset;

    ubyte txSeq;
    ubyte rxSeq;
    ubyte txAck;

    bool connecting = true;
    bool connected;

    ubyte ashVersion;

    void delegate(const(ubyte)[] packet) nothrow @nogc packetCallback;


    this (Stream stream)
    {
        this.stream = stream;
    }

    bool isConnected()
        => connected;

    void setPacketCallback(void delegate(const(ubyte)[]) nothrow @nogc callback)
    {
        packetCallback = callback;
    }

    void reset(bool reconnect = true)
    {
        writeDebug("ASHv2: connection reset");

        connecting = reconnect;
        connected = false;

        // clear all the queues...
        txSeq = rxSeq = 0;
        rxOffset = 0;
        transmitOffset = recvOffset = 0;
        sendQueue[] = SendReq();

        lastEvent = MonoTime();
    }

    void update()
    {
        MonoTime now = getTime();

        if (!stream.connected)
            reset();

        if (connecting && !connected && now - lastEvent > T_RSTACK_MAX.msecs && stream.connected)
        {
            writeDebug("ASHv2: connecting...");
            ashRst();
            lastEvent = now;
        }

        do
        {
            ptrdiff_t r = stream.read(rxBuffer[rxOffset..$]);
            if (r <= 0)
                break;

            // skip any XON/OFF bytes
            ubyte rxLen = rxOffset;
            for (ubyte i = rxOffset; i < rxOffset + r; ++i)
            {
                if (rxBuffer[i] == ASH_XON_BYTE || rxBuffer[i] == ASH_OFF_BYTE)
                    continue;
                rxBuffer[rxLen++] = rxBuffer[i];
            }

            // parse frames from stream
            ubyte start = 0;
            ubyte end = 0;
            bool inputError = false;
            outer: for (; end < rxLen; ++end)
            {
                if (rxBuffer[end] == ASH_SUBSTITUTE_BYTE)
                    inputError = true;
                else if (rxBuffer[end] == ASH_CANCEL_BYTE)
                    start = cast(ubyte)(end + 1);
                if (rxBuffer[end] != ASH_FLAG_BYTE)
                    continue;

                // if we encountered an input error in the stream
                if (inputError)
                {
                    inputError = false;
                    start = cast(ubyte)(end + 1);
                    continue;
                }

                // remove byte-stuffing
                ubyte frameLen = 0;
                for (ubyte i = start; i < end; ++i)
                {
                    ubyte b = rxBuffer[i];
                    if (b == 0x7D)
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

                int dataEnd = start + frameLen - 2;
                ubyte[] frame = rxBuffer[start .. dataEnd];

                start = cast(ubyte)(end + 1);

                // validate the frame
                if (frameLen < 3)
                    continue;

                // check the crc
                ushort crc = crcCCITT(frame);
                if (rxBuffer[dataEnd .. dataEnd + 2][0..2].bigEndianToNative!ushort != crc)
                {
                    // corrupt frame!
                    // TODO: but maybe we should send a NAK?
                    continue;
                }

                ubyte control = frame[0];
                frame = frame[1..$];

                // handle the frame...
                if (control == 0xC1)
                {
                    // RSTACK
                    if (frame.length == 2)
                    {
                        ashVersion = frame[0];
                        ubyte code = frame[1];

                        connecting = false; // unsupported version, stop trying to connect!
                        if (ashVersion == 2)
                            connected = true;

                        writeDebug(connected ? "ASHv2: connected! code: " : "ASHv2: connection failed; unsupported version! code: ", code);
                        continue;
                    }
                }

                // we can't accept any frames before we receive RSTACK
                if (!connected)
                    continue;

                if (control == 0xC2)
                {
                    // ERROR
                    if (frame.length == 2)
                    {
                        ubyte ver = frame[0];
                        ubyte code = frame[1];

                        writeDebug("ASHv2: connection error! code: ", code);

                        // TODO: ...what to do?
                        reset();
                    }
                }
                else if (control & 0x80)
                {
                    if ((control & 0x60) == 0)
                    {
                        // ACK
                        ubyte ackNum = control & 7;
                        while (txAck != ackNum)
                        {
                            // remote acknowledges some frames we've sent
                            if (sendQueue[txAck].state == SendReq.State.PendingAck)
                                sendQueue[txAck].state = SendReq.State.Available;
                            txAck = (txAck + 1) & 7;
                        }

                        writeDebug("ASHv2: ACK ", ackNum);
                    }
                    else if ((control & 0x60) == 0x20)
                    {
                        // NAK
                        writeDebug("ASHv2: NAK ", control & 7);

                        // TODO: I'm meant to retransmit a buffered message
                        //       ...but it's not clear from the control byte which message(/s) I should retransmit
                    }
                    else
                    {
                        // Invalid frame!
                        // ...just ignore it?
                        debug assert(false);
                    }
                }
                else
                {
                    // DATA
                    ubyte ackNum = control & 7;
                    while (txAck != ackNum)
                    {
                        // remote acknowledges some frames we've sent
                        if (sendQueue[txAck].state == SendReq.State.PendingAck)
                            sendQueue[txAck].state = SendReq.State.Available;
                        txAck = (txAck + 1) & 7;
                    }

                    ubyte frmNum = control >> 4;
                    bool retransmit = (control & 0x08) != 0;

                    if (retransmit)
                    {
                        // we dispatch ACK's immediately, so if we receive a retransmit, either we missed the first message, or the ack wasn't received
                        // TODO: if we missed it the first time, we must dispatch it now... how do we know?!
                        int x = 0;
                    }
                    else
                    {
                        while (rxSeq != frmNum)
                        {
                            // we missed a frame, we should request a retransmit
                            ashNak(rxSeq, true);
                            rxSeq = (rxSeq + 1) & 7;
                        }
                        rxSeq = (rxSeq + 1) & 7;
                    }

                    ubyte[ASH_MAX_LENGTH] unrandom = void;
                    randomise(frame, unrandom[0 .. frame.length]);

                    writeDebug("ASHv2: received data frame ", frmNum, ": ", cast(void[])unrandom[0 .. frame.length]);

                    ubyte curTxSeq = txSeq;
                    packetCallback(unrandom[0 .. frame.length]);

                    // if the message receive handler didn't send a response, then we should acknowledge the message
                    if (txSeq == curTxSeq)
                        ashAck(rxSeq, false);
                }
            }

            if (start > 0)
                for (size_t i = start; i < rxLen; ++i)
                    rxBuffer[i - start] = rxBuffer[i];
            rxOffset = cast(ubyte)(rxLen - start);
        }
        while(true);

        // TODO: handle timeouts...
        // re-send any failed frames...
        //...
    }

    bool send(const(ubyte)[] message)
    {
        // TODO: what is the maximum length of an EZSP message?
        assert(message.length <= 128);

        SendReq* req = &sendQueue[txSeq];
        if (req.state != SendReq.State.Available)
        {
            // TODO: we'll discard the existing message...
            // but the problem is; what if we receive an ack now for the replaced message?
            // maybe we should try and retransmit?
            assert(false);
        }

        if (transmitOffset + message.length > transmitBuffer.length)
            transmitOffset = 0;

        *req = SendReq(transmitOffset, cast(ubyte)message.length, SendReq.State.ReadyToSend);

        transmitBuffer[transmitOffset .. transmitOffset + message.length] = message[];
        transmitOffset += cast(ushort)message.length;

        if (!connected || !ashSend(message, txSeq, rxSeq, false))
            return false;

        writeDebug("ASHv2: sent data frame ", txSeq, ": ", cast(void[])message);

        req.state = SendReq.State.PendingAck;
        txSeq = (txSeq + 1) & 7;

        return true;
    }

private:
    bool ashRst()
    {
        immutable ubyte[5] RST = [ ASH_CANCEL_BYTE, 0xC0, 0x38, 0xBC, ASH_FLAG_BYTE ];
        return stream.write(RST) == 5;
    }

    bool ashAck(ubyte ack, bool ready, bool nak = false)
    {
        ubyte[4] ackMsg = [ 0x80 | (nak ? 0x20 : 0) | (ready << 3) | (ack & 7), 0, 0, ASH_FLAG_BYTE ];
        ackMsg[1..3] = crcCCITT(ackMsg[0..1]).nativeToBigEndian;
        return stream.write(ackMsg) == 4;
    }

    bool ashNak(ubyte ack, bool ready)
        => ashAck(ack, ready, true);

    bool ashSend(const(ubyte)[] msg, ubyte seq, ubyte ack, bool retransmit)
    {
        // TODO: what is the maximum frame len?
        ubyte[256] frame = void;

        // add the control byte
        frame[0] = ((seq & 7) << 4) | (ack & 7) | (retransmit << 3);

        // randomise the data
        randomise(msg, frame[1..$]);

        // add the crc
        ushort crc = crcCCITT(frame[0 .. 1 + msg.length]);
        frame[1 + msg.length .. 3 + msg.length][0..2] = crc.nativeToBigEndian;

        // byte-stuffing
        ubyte[256] stuffed = void;
        size_t len = 0;
        foreach (i, b; frame[0 .. msg.length + 3])
        {
            if (b == 0x7E || b == 0x7D || b == 0x11 || b == 0x13 || b == 0x18 || b == 0x1A)
            {
                stuffed[len++] = 0x7D;
                stuffed[len++] = b ^ 0x20;
            }
            else
                stuffed[len++] = b;
        }

        // add flag byte
        stuffed[len++] = 0x7E;

        ptrdiff_t r = stream.write(stuffed[0..len]);
        if (r == len)
            return true;
        return false;
    }

    static void randomise(const(ubyte)[] data, ubyte[] buffer)
    {
        ubyte rand = 0x42;
        foreach (i, b; data)
        {
            buffer[i] = b ^ rand;

            // which solution is actually better?

            ubyte b1 = cast(ubyte)-(rand & 1) & 0xB8;
            rand = (rand >> 1) ^ b1;

//            ubyte b1 = rand & 1;
//            rand >>= 1;
//            if (b1)
//                rand ^= 0xB8;
        }
    }
}


private:

__gshared immutable ushort[256] crcTable = [
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7, 0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52B5, 0x4294, 0x72F7, 0x62D6, 0x9339, 0x8318, 0xB37B, 0xA35A, 0xD3BD, 0xC39C, 0xF3FF, 0xE3DE,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64E6, 0x74C7, 0x44A4, 0x5485, 0xA56A, 0xB54B, 0x8528, 0x9509, 0xE5EE, 0xF5CF, 0xC5AC, 0xD58D,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76D7, 0x66F6, 0x5695, 0x46B4, 0xB75B, 0xA77A, 0x9719, 0x8738, 0xF7DF, 0xE7FE, 0xD79D, 0xC7BC,
    0x48C4, 0x58E5, 0x6886, 0x78A7, 0x0840, 0x1861, 0x2802, 0x3823, 0xC9CC, 0xD9ED, 0xE98E, 0xF9AF, 0x8948, 0x9969, 0xA90A, 0xB92B,
    0x5AF5, 0x4AD4, 0x7AB7, 0x6A96, 0x1A71, 0x0A50, 0x3A33, 0x2A12, 0xDBFD, 0xCBDC, 0xFBBF, 0xEB9E, 0x9B79, 0x8B58, 0xBB3B, 0xAB1A,
    0x6CA6, 0x7C87, 0x4CE4, 0x5CC5, 0x2C22, 0x3C03, 0x0C60, 0x1C41, 0xEDAE, 0xFD8F, 0xCDEC, 0xDDCD, 0xAD2A, 0xBD0B, 0x8D68, 0x9D49,
    0x7E97, 0x6EB6, 0x5ED5, 0x4EF4, 0x3E13, 0x2E32, 0x1E51, 0x0E70, 0xFF9F, 0xEFBE, 0xDFDD, 0xCFFC, 0xBF1B, 0xAF3A, 0x9F59, 0x8F78,
    0x9188, 0x81A9, 0xB1CA, 0xA1EB, 0xD10C, 0xC12D, 0xF14E, 0xE16F, 0x1080, 0x00A1, 0x30C2, 0x20E3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83B9, 0x9398, 0xA3FB, 0xB3DA, 0xC33D, 0xD31C, 0xE37F, 0xF35E, 0x02B1, 0x1290, 0x22F3, 0x32D2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xB5EA, 0xA5CB, 0x95A8, 0x8589, 0xF56E, 0xE54F, 0xD52C, 0xC50D, 0x34E2, 0x24C3, 0x14A0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xA7DB, 0xB7FA, 0x8799, 0x97B8, 0xE75F, 0xF77E, 0xC71D, 0xD73C, 0x26D3, 0x36F2, 0x0691, 0x16B0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xD94C, 0xC96D, 0xF90E, 0xE92F, 0x99C8, 0x89E9, 0xB98A, 0xA9AB, 0x5844, 0x4865, 0x7806, 0x6827, 0x18C0, 0x08E1, 0x3882, 0x28A3,
    0xCB7D, 0xDB5C, 0xEB3F, 0xFB1E, 0x8BF9, 0x9BD8, 0xABBB, 0xBB9A, 0x4A75, 0x5A54, 0x6A37, 0x7A16, 0x0AF1, 0x1AD0, 0x2AB3, 0x3A92,
    0xFD2E, 0xED0F, 0xDD6C, 0xCD4D, 0xBDAA, 0xAD8B, 0x9DE8, 0x8DC9, 0x7C26, 0x6C07, 0x5C64, 0x4C45, 0x3CA2, 0x2C83, 0x1CE0, 0x0CC1,
    0xEF1F, 0xFF3E, 0xCF5D, 0xDF7C, 0xAF9B, 0xBFBA, 0x8FD9, 0x9FF8, 0x6E17, 0x7E36, 0x4E55, 0x5E74, 0x2E93, 0x3EB2, 0x0ED1, 0x1EF0
];

static ushort crcCCITT(const(ubyte)[] data)
{
    ushort crc = 0xFFFF;
    foreach (b; data)
        crc = cast(ushort)((crc << 8) ^ crcTable[(crc >> 8) ^ b]);
    return crc;
}
