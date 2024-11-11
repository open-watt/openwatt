module protocol.spinel.client;

import urt.crc;
import urt.endian;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.string;
import urt.time;
import urt.traits;

import router.stream;

import protocol.spinel;

version = DebugMessageFlow;

alias hdlcCRC = calculateCRC!(Algorithm.CRC16_ISO_HDLC);

nothrow @nogc:


//
// Spinel serial protocol is a protocol used to communicate with radio chips.
// https://datatracker.ietf.org/doc/html/draft-rquattle-spinel-unified-00
//


class SpinelClient
{
nothrow @nogc:

    String name;

    this(String name, Stream stream)
    {
        this.name = name.move;
        this.stream = stream;
    }

    final bool isConnected()
    {
        return connected;
    }

    final void reset()
    {
        connected = false;
    }

    final void setMessageHandler(void delegate(ubyte, ushort, const(ubyte)[]) nothrow @nogc callback)
    {
//        messageHandler = callback;
    }

    bool sendMessage(Command cmd)(SpinelTypeTuple!(spinelCommands[cmd]) args)
    {
        enum string fmt = 'i' ~ spinelCommands[cmd];

        ubyte[128] msg = void;
        msg[0] = 0x80 | 0x00 | txId;

        size_t len = 1 + SpinelTuple!fmt(cmd, args).spinelSerialise!fmt(msg[1..$]);

        version (DebugMessageFlow)
        {
            static if (args.length == 0)
                writeDebug("SPINEL: --> ", cmd);
            else
                writeDebug("SPINEL: --> ", cmd, " - ", SpinelTuple!fmt(args));
        }

        bool r = sendFrame(msg[0..len]);
        if (r)
            txId = txId == 0xF ? 1 : cast(ubyte)(txId + 1);
        return r;
    }

    final bool sendMessage(uint message, const void[] data = null)
    {
        ubyte[128] msg = void;
        msg[0] = 0x80 | 0x00 | txId;

        size_t len = 1 + SpinelTuple!"i"(message).spinelSerialise!"i"(msg[1..$]);
        if (data.length > 0)
        {
            msg[len .. len + data.length] = cast(ubyte[])data[];
            len += data.length;
        }

        bool r = sendFrame(msg[0..len]);
        if (r)
            txId = txId == 0xF ? 1 : cast(ubyte)(txId + 1);
        return r;
    }

    final void update()
    {
        MonoTime now = getTime();

        if (!stream.connected)
        {
            reset();
            return;
        }

        if (!connected && now - lastEvent > 3.seconds && stream.connected)
        {
            writeDebug("SPINEL: connecting on '", stream.name, "'...");
            lastEvent = now;
            // send PING or something to see if we're alive?
            sendMessage!(Command.RESET)();
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
                if (rxBuffer[i] == HDLC_XON_BYTE || rxBuffer[i] == HDLC_XOFF_BYTE)
                    continue;
                rxBuffer[rxLen++] = rxBuffer[i];
            }

            // parse frames from stream delimited by 0x7E bytes
            ubyte start = 0;
            ubyte end = 0;
            outer: for (; end < rxLen; ++end)
            {
                if (rxBuffer[end] == HDLC_ESCAPE_BYTE && end < rxLen - 1 && rxBuffer[end + 1] == HDLC_FLAG_BYTE)
                {
                    // this is a frame termination sequence, we'll discard this frame
                    start = cast(ubyte)(++end + 1);
                    continue;
                }
                if (rxBuffer[end] != HDLC_FLAG_BYTE)
                    continue;

                // remove byte-stuffing from the frame
                ubyte frameLen = 0;
                for (ubyte i = start; i < end; ++i)
                {
                    ubyte b = rxBuffer[i];
                    if (b == HDLC_ESCAPE_BYTE)
                        rxBuffer[start + frameLen++] = rxBuffer[++i] ^ 0x20;
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
                ushort crc = frame.hdlcCRC();
                if (rxBuffer[frameEnd .. frameEnd + 2][0..2].littleEndianToNative!ushort != crc)
                {
                    // corrupt frame!
                    // TODO: but maybe we should send a NAK?
                    ++rxErrors;
                    continue;
                }

                ++rxPackets;

                // submit the frame for processing
                incomingPacket(frame);
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
    }

private:

    enum HDLC_FLAG_BYTE     = 0x7E;
    enum HDLC_ESCAPE_BYTE   = 0x7D;
    enum HDLC_XON_BYTE      = 0x11;
    enum HDLC_XOFF_BYTE     = 0x13;
    enum HDLC_VENDOR_BYTE   = 0xF8;

    static bool isSpecialByte(ubyte b) pure
        => b == HDLC_ESCAPE_BYTE || b == HDLC_FLAG_BYTE || b == HDLC_XON_BYTE || b == HDLC_XOFF_BYTE || b == HDLC_VENDOR_BYTE;

    Stream stream;
    MonoTime lastEvent;

    bool connected;
    ubyte rxOffset;
    ubyte txId = 0;

    uint rxBytes, txBytes;
    uint rxPackets, txPackets;
    uint rxErrors, txErrors;

    ubyte[128] rxBuffer;

    void incomingPacket(const(ubyte)[] msg)
    {

    }

    bool sendFrame(const(ubyte)[] msg)
    {
        ubyte[256] frame = void;

        // escape the message, stick a CRC on it, and write the flags...
        size_t len = 0;
        frame[len++] = HDLC_FLAG_BYTE;

        // byte-stuffing
        foreach (i, b; msg)
        {
            if (isSpecialByte(b))
            {
                frame[len++] = HDLC_ESCAPE_BYTE;
                frame[len++] = b ^ 0x20;
            }
            else
                frame[len++] = b;
        }

        // add the crc (this is pretty yuck!)
        ushort crc = msg.hdlcCRC();
        if (isSpecialByte(cast(ubyte)crc))
        {
            frame[len++] = HDLC_ESCAPE_BYTE;
            frame[len++] = cast(ubyte)crc ^ 0x20;
        }
        else
            frame[len++] = cast(ubyte)crc;
        if (isSpecialByte(cast(ubyte)(crc >> 8)))
        {
            frame[len++] = HDLC_ESCAPE_BYTE;
            frame[len++] = cast(ubyte)(crc >> 8) ^ 0x20;
        }
        else
            frame[len++] = cast(ubyte)(crc >> 8);

        frame[len++] = HDLC_FLAG_BYTE;

        version (DebugMessageFlow)
            writeDebug("HDLC: --> ", cast(void[])msg);

        ptrdiff_t r = stream.write(frame[0..len]);
        if (r != len)
        {
            version (DebugMessageFlow)
                writeDebug("HDLC: stream write failed!");
            ++txErrors;
            return false;
        }

        ++txPackets;
        txBytes += r;
        return true;
    }
}
