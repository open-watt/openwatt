module protocol.ezsp.client;

import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import router.stream;

import protocol.ezsp.ashv2;

public import protocol.ezsp.commands;

nothrow @nogc:


//
// EZSP (EmberZNet Serial Protocol) is a protocol used by EmberZNet to communicate with the radio chip.
// https://www.silabs.com/documents/public/user-guides/ug100-ezsp-reference-guide.pdf
//


class EZSPClient
{
nothrow @nogc:

    String name;

    this(String name, Stream stream)
    {
        this.ash = ASH(stream);
        this.name = name.move;
    }

    bool isConnected()
    {
        return knownVersion && ash.isConnected();
    }

    void reset()
    {
        ash.reset();
        knownVersion = 0;
        versionRequestSent = false;
        sequenceNumber = 0;
    }

    void update()
    {
        ash.update();

        const(ubyte)[] msg;
        while ((msg = ash.recv()) != null)
        {
            ubyte seq = msg[0];
            ushort control;
            ushort cmd;
            if (knownVersion >= 8)
            {
                assert(msg.length >= 5);

                if (msg[4] != 0) // high byte of cmd
                    assert(false);

                control = msg[1] | (msg[2] << 8);
                cmd = msg[3];// | (msg[4] << 8);
                msg = msg[5 .. $];
            }
            else
            {
                assert(msg.length >= 4);

                control = msg[1];

                if (msg.length >= 3 && msg[2] == 0xff)
                {
                    assert(false); // TODO: we don't understand this case!
                    if (msg.length < 4)
                        assert(false);
                    cmd = msg[4];
                    msg = msg[5..$];
                }
                else
                {
                    assert(msg.length >= 3);

                    cmd = msg[2];
                    msg = msg[3..$];
                }
            }

            assert(control & 0x80); // responses always have the high bit set

            bool overflow = (control & 0x1) != 0;
            bool truncated = (control & 0x2) != 0;
            bool callbackPending = (control & 0x4) != 0;
            ubyte callbackType = (control >> 3) & 0x3;
            ubyte networkIndex = (control >> 5) & 0x3;
            ubyte frameFormatVersion = (control >> 8) & 0x3;
            bool paddingEnabled = (control & 0x4000) != 0;
            bool securityEnabled = (control & 0x8000) != 0;

            lastEvent = getTime();

            dispatchCommand(cmd, msg);
        }

        if (!knownVersion)
        {
            if (ash.isConnected())
            {
                if (!versionRequestSent)
                {
                    writeDebug("EZSP: connecting...");

                    immutable ubyte[4] versionMsg = [ 0x00, 0x00, 0x00, 0x13 ];
                    ash.send(versionMsg);

                    lastEvent = getTime();
                }
                else if (getTime() - lastEvent > 10.seconds)
                    reset();
            }
            return;
        }
    }

    bool sendMessage(ushort cmd, const(ubyte)[] data)
    {
        ubyte[256] buffer = void;
        ubyte i = 0;

        buffer[i++] = sequenceNumber++;

        // the EZSP frame control byte (0x00)
        buffer[i++] = 0x00;
        if (knownVersion >= 8)
            buffer[i++] = 0x01;

        if (cmd != 0 && knownVersion < 8)
        {
            // For all EZSPv6 or EZSPv7 frames except 'version' frame, force an extended header 0xff 0x00
            buffer[i++] = 0xFF;
            buffer[i++] = 0x00;
        }

        buffer[i++] = cast(ubyte)cmd;
        if (knownVersion >= 8)
            buffer[i++] = 0x00;

        buffer[i .. i + data.length] = data[];
        i += data.length;

        if (!ash.send(buffer[0..i]))
        {
            // error?!
            return false;
        }
        return true;
    }


private:

    MonoTime lastEvent;

    bool versionRequestSent;
    ubyte knownVersion;

    ubyte sequenceNumber;

    ASH ash;

    void dispatchCommand(ushort command, const(ubyte)[] msg)
    {
        switch (command)
        {
            case 0x00: // version
                knownVersion = msg[0];
                ubyte stackType = msg[1];
                ushort stackVersion = msg[2..4].littleEndianToNative!ushort;
                versionRequestSent = false;
                writeInfo("EZSP: version response: ", knownVersion);
                break;

            default:
                writeInfo("EZSP: unknown command: ", command);
                break;
        }
    }
}

