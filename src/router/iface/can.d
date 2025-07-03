module router.iface.can;

import urt.endian;
import urt.log;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.console;
import manager.plugin;

import router.iface;
import router.stream;

//version = DebugCANInterface;

nothrow @nogc:


enum CANInterfaceProtocol : byte
{
    Unknown = -1,
    EBYTE
}

struct CANFrame
{
    uint id;
    ubyte control; // IDE, RTR, _, _, LEN[0..4]
    const(ubyte)* ptr;

nothrow @nogc:
    bool extended() const
        => (control & 0x80) != 0;
    const(ubyte)[] data() const
        => ptr[0 .. (control & 0xF)];
}

class CANInterface : BaseInterface
{
nothrow @nogc:

    alias TypeName = StringLit!"can";

    Stream stream;

    CANInterfaceProtocol protocol;

    this(String name, Stream stream, CANInterfaceProtocol protocol) nothrow @nogc
    {
        super(name.move, TypeName);
        this.stream = stream;
        this.protocol = protocol;

        // this is the proper value for canbus, irrespective of the L2 MTU
        // can jumbo's are theoretically possible if all hops support it... (fragmentation is not possible (?))
        _mtu = 8; // or 64 for FD-CAN...

        // this would be 8 or 64 for physical canbus, or larger if another carrier...?
        _max_l2mtu = _mtu;
        _l2mtu = _max_l2mtu;

        _status.linkStatusChangeTime = getSysTime();
        _status.linkStatus = stream.status.linkStatus;
    }

    override void update()
    {
        SysTime now = getSysTime();

        // check the link status
        Status.Link streamStatus = stream.status.linkStatus;
        if (streamStatus != status.linkStatus)
        {
            _status.linkStatus = streamStatus;
            _status.linkStatusChangeTime = now;
            if (streamStatus != Status.Link.Up)
                ++_status.linkDowns;
        }
        if (streamStatus != Status.Link.Up)
            return;

        enum LargestProtocolFrame = 13; // EBYTE proto has 13byte frames

        // check for data
        ubyte[1024] buffer = void;
        buffer[0 .. tailBytes] = tail[0 .. tailBytes];
        ptrdiff_t readOffset = tailBytes;
        ptrdiff_t length = tailBytes;
        tailBytes = 0;
        read_loop: do
        {
            assert(length < LargestProtocolFrame);

            ptrdiff_t r = stream.read(buffer[readOffset .. $]);
            if (r < 0)
            {
                assert(false, "TODO: what causes read to fail?");
                break read_loop;
            }
            if (r == 0)
            {
                // if there were no extra bytes available, stash the tail until later
                tail[0 .. length] = buffer[0 .. length];
                tailBytes = cast(ushort)length;
                break read_loop;
            }
            length += r;
            assert(length <= buffer.sizeof);

            // TODO: implement stream dump...
//            if (connParams.logDataStream)
//                logStream.rawWrite(buffer[0 .. length]);

            CANFrame frame;

            size_t offset = 0;
            while (offset < length)
            {
                // parse packets from the stream...
                size_t taken = 0;
                switch (protocol)
                {
                    case CANInterfaceProtocol.EBYTE:
                        enum EbyteFrameSize = 13;

                        if (length - offset >= EbyteFrameSize)
                        {
                            // TODO: how can we even do any packet validation?
                            //       there's basically no error detection data available
                            //       I guess we could confirm assumed zero bits in the header and tail?

                            const ubyte[] ebyteFrame = buffer[offset .. offset + EbyteFrameSize];

                            frame.control = ebyteFrame[0];

                            frame.id = ebyteFrame[1 .. 5].bigEndianToNative!uint;
                            frame.id &= (frame.extended ? 0x1FFFFFFF : 0x7FF);

                            frame.ptr = ebyteFrame.ptr + 5;

                            taken = EbyteFrameSize;
                        }
                        break;

                    default:
                        assert(false);
                }

                if (taken == 0)
                {
                    import urt.util : min;

                    // we didn't parse any packets
                    // we might have a split packet, so we'll shuffle unread data to the front of the buffer
                    // ...but we'll only keep at most one message worth!
                    size_t remain = length - offset;
                    size_t keepBytes = min(remain, LargestProtocolFrame - 1);
                    size_t trunc = remain - keepBytes;
                    memmove(buffer.ptr, buffer.ptr + offset + trunc, keepBytes);
                    length = keepBytes;
                    readOffset = keepBytes;
                    offset = 0;
                    continue read_loop;
                }
                offset += taken;

                incomingPacket(frame, now);
            }

            // we've eaten the whole buffer...
            length = 0;
        }
        while (true);
    }

    protected override bool transmit(ref const Packet packet) nothrow @nogc
    {
        // can only handle can packets
        if (packet.etherType != EtherType.ENMS || packet.etherSubType != ENMS_SubType.CAN)
        {
            ++_status.sendDropped;
            return false;
        }

        if (packet.data.length < 4 || packet.data.length > 12)
        {
            version (DebugCANInterface)
                writeDebug("CAN packet dropped on interface '", name, "': invalid frame");
            return false;
        }

        // frame it up and send...
        ubyte[13] buffer = void;
        size_t length = 0;

        switch (protocol)
        {
            case CANInterfaceProtocol.EBYTE:
                ubyte[] data = cast(ubyte[])packet.data;
                ubyte dataLen = cast(ubyte)(packet.data.length - 4);

                buffer[0] = (data[0] & 0xC0) | dataLen;
                buffer[1 .. 5] = data[0 .. 4];
                buffer[1] &= 0x1F; // clear the flags
                buffer[5 .. 5 + dataLen] = data[4 .. $];
                buffer[5 + dataLen .. 13] = 0;
                length = 13;
                break;

            default:
                assert(false);
        }

        ptrdiff_t written = stream.write(buffer[0 .. length]);

        version (DebugCANInterface)
        {
            if (written <= 0)
                writeDebug("CAN packet send failed on interface '", name, "'");
            else
                writeDebug("CAN packet sent on interface '", name, "': id=", (cast(ubyte[4])packet.data[0 .. 4]).bigEndianToNative!uint & 0x1FFFFFFF, " (", packet.data.length - 4, ")[ ", packet.data[4 .. $], " - ", packet.data[4 .. $].binToAscii(), " ]");
        }

        if (written <= 0)
        {
            // what could have gone wrong here?
            // TODO: proper error handling?

            // if the stream disconnected, maybe we should buffer the message incase it reconnects promptly?

            // just drop it for now...
            ++_status.sendDropped;
            return false;
        }

        ++_status.sendPackets;
        _status.sendBytes += length;
        // TODO: or should we record `length`? payload bytes, or full protocol bytes?
        return true;
    }

    override ushort pcapType() const
        => 227; // CAN_SOCKETCAN

    override void pcapWrite(ref const Packet packet, PacketDirection dir, scope void delegate(const void[] packetData) nothrow @nogc sink) const
    {
        // write socket_can struct...
        struct socket_can
        {
            ubyte[4] id;
            ubyte len;
            ubyte __pad;
            ubyte __res0;
            ubyte len8_dlc; // optional DLC for 8 byte payload length (9 .. 15) (????)
            ubyte[8] data;
        }
        static assert(socket_can.sizeof == 16);

        socket_can f;
        f.id = (cast(const ubyte[])packet.data)[0..4];
        f.len = cast(ubyte)(packet.data.length - 4);
        f.data[0 .. f.len] = cast(const ubyte[])packet.data[4 .. $];

        // TODO: what's the go with the error bit (bit 29 of ID)???

        sink((cast(ubyte*)&f)[0 .. socket_can.sizeof]);
    }

private:
    ubyte[13] tail; // EBYTE proto has 13byte frames
    ushort tailBytes;

    final void incomingPacket(ref const CANFrame frame, SysTime recvTime)
    {
        version (DebugCANInterface)
            writeDebug("CAN packet received from interface '", name, "': id=", frame.id, " (", frame.data.length , ")[ ", cast(void[])frame.data[], " - ", frame.data.binToAscii(), " ]");

        ubyte[12] packet;
        packet[0 .. 4] = nativeToBigEndian(frame.id | ((frame.control & 0xC0) << 24));
        packet[4 .. 4 + frame.data.length] = frame.data[];

        Packet p = Packet(packet[0 .. 4 + frame.data.length]);
        p.creationTime = recvTime;
        p.etherType = EtherType.ENMS;
        p.etherSubType = ENMS_SubType.CAN;

        // all CAN messages are broadcasts...
        p.dst = MACAddress.broadcast;
        p.src = mac; // TODO: feels a bit odd, since it didn't come from us; but we don't want switches sending it back to us...

        dispatch(p);
    }
}


class CANInterfaceModule : Module
{
    mixin DeclareModule!"interface.can";
nothrow @nogc:

    override void init()
    {
        g_app.console.registerCommand!add("/interface/can", this);
    }

    // /interface/can/add command
    // TODO: protocol enum!
    void add(Session session, const(char)[] name, Stream stream, const(char)[] protocol, Nullable!(const(char)[]) pcap)
    {
        CANInterfaceProtocol p = CANInterfaceProtocol.Unknown;
        switch (protocol)
        {
            case "ebyte":
                p = CANInterfaceProtocol.EBYTE;
                break;
            default:
                session.writeLine("Invalid CAN protocol '", protocol, "', expect 'ebyte|??'.");
                return;
        }

        auto mod_if = getModule!InterfaceModule;
        String n = mod_if.addInterfaceName(session, name, CANInterface.TypeName);
        if (!n)
            return;

        CANInterface iface = defaultAllocator.allocT!CANInterface(n.move, stream, p);

        mod_if.addInterface(session, iface, pcap ? pcap.value : null);
    }
}


version (DebugCANInterface)
{
    // TODO: maybe this function is cool in other palces where we log binary?
    char[] binToAscii(const void[] bin)
    {
        import urt.mem.temp : talloc;
        char[] t = cast(char[])talloc(bin.length);
        t[] = cast(char[])bin[];
        foreach (ref c; t)
            c = isControlChar(c) ? '.' : c;
        return t;
    }
}
