module router.iface.can;

import urt.endian;
import urt.log;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.stream;

//version = DebugCANInterface;

nothrow @nogc:


enum CANInterfaceProtocol : byte
{
    unknown = -1,
    ebyte
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
    __gshared Property[2] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("protocol", protocol)() ];

nothrow @nogc:

    alias TypeName = StringLit!"can";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CANInterface, name.move, flags);

        // this is the proper value for canbus, irrespective of the L2 MTU
        // can jumbo's are theoretically possible if all hops support it... (fragmentation is not possible (?))
        _mtu = 8; // or 64 for FD-CAN...

        // this would be 8 or 64 for physical canbus, or larger if another carrier...?
        _max_l2mtu = _mtu;
        _l2mtu = _max_l2mtu;
    }


    // Properties...

    inout(Stream) stream() inout pure
        => _stream;
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (_stream is value)
            return null;
        _stream = value;

        if (!_stream || !_stream.running)
            restart();
        return null;
    }

    CANInterfaceProtocol protocol() const pure
        => _protocol;
    const(char)[] protocol(CANInterfaceProtocol value)
    {
        import urt.mem.temp;
        if (value != CANInterfaceProtocol.ebyte)
            return tconcat("Invalid CAN protocol '", protocol, "': expect 'ebyte|??'.");
        _protocol = value;
        return null;
    }


    // API...

    override bool validate() const
        => _stream !is null && _protocol == CANInterfaceProtocol.ebyte;

    override CompletionStatus validating()
    {
        _stream.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_stream)
            return CompletionStatus.error;
        if (_stream.running)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    override void update()
    {
        if (!_stream || !_stream.running)
            return restart();

        super.update();

        SysTime now = getSysTime();

        enum LargestProtocolFrame = 13; // EBYTE proto has 13byte frames

        // check for data
        ubyte[1024] buffer = void;
        buffer[0 .. _tail_bytes] = _tail[0 .. _tail_bytes];
        ptrdiff_t readOffset = _tail_bytes;
        ptrdiff_t length = _tail_bytes;
        _tail_bytes = 0;
        read_loop: while (true)
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
                // if there were no extra bytes available, stash the _tail until later
                _tail[0 .. length] = buffer[0 .. length];
                _tail_bytes = cast(ushort)length;
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
                    case CANInterfaceProtocol.ebyte:
                        enum EbyteFrameSize = 13;

                        if (length - offset >= EbyteFrameSize)
                        {
                            // TODO: how can we even do any packet validation?
                            //       there's basically no error detection data available
                            //       I guess we could confirm assumed zero bits in the header and _tail?

                            const ubyte[] ebyteFrame = buffer[offset .. offset + EbyteFrameSize];

                            frame.control = ebyteFrame[0];
                            assert((frame.control & 0xF) <= 8, "TODO: bad CAN frame; did we fall off the rails? bad data? skip this message? how do we resync?");

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

                incoming_packet(frame, now);
            }

            // we've eaten the whole buffer...
            length = 0;
        }
    }

    protected override bool transmit(ref const Packet packet)
    {
        // can only handle can packets
        if (packet.eth.ether_type != EtherType.ow || packet.eth.ow_sub_type != OW_SubType.can)
        {
            ++_status.send_dropped;
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
            case CANInterfaceProtocol.ebyte:
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
                writeDebug("CAN packet sent on interface '", name, "': id=", (cast(ubyte[4])packet.data[0 .. 4]).bigEndianToNative!uint & 0x1FFFFFFF, " (", packet.data.length - 4, ")[ ", packet.data[4 .. $], " - ", packet.data[4 .. $].bin_to_ascii(), " ]");
        }

        if (written <= 0)
        {
            // what could have gone wrong here?
            // TODO: proper error handling?

            // if the stream disconnected, maybe we should buffer the message incase it reconnects promptly?

            // just drop it for now...
            ++_status.send_dropped;
            return false;
        }

        ++_status.send_packets;
        _status.send_bytes += length;
        // TODO: or should we record `length`? payload bytes, or full protocol bytes?
        return true;
    }

    override ushort pcap_type() const
        => 227; // CAN_SOCKETCAN

    override void pcap_write(ref const Packet packet, PacketDirection dir, scope void delegate(const void[] packetData) nothrow @nogc sink) const
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
    ObjectRef!Stream _stream;
    CANInterfaceProtocol _protocol;
    ubyte[13] _tail; // EBYTE proto has 13byte frames
    ushort _tail_bytes;

    final void incoming_packet(ref const CANFrame frame, SysTime recvTime)
    {
        debug assert(running, "Shouldn't receive packets while not running...?");

        version (DebugCANInterface)
            writeDebug("CAN packet received from interface '", name, "': id=", frame.id, " (", frame.data.length , ")[ ", cast(void[])frame.data[], " - ", frame.data.bin_to_ascii(), " ]");

        ubyte[12] packet;
        packet[0 .. 4] = nativeToBigEndian(frame.id | ((frame.control & 0xC0) << 24));
        packet[4 .. 4 + frame.data.length] = frame.data[];

        Packet p;
        p.init!Ethernet(packet[0 .. 4 + frame.data.length]);
        p.creation_time = recvTime;
        p.vlan = _pvid;
        p.eth.ether_type = EtherType.ow;
        p.eth.ow_sub_type = OW_SubType.can;

        // all CAN messages are broadcasts...
        p.eth.dst = MACAddress.broadcast;
        p.eth.src = mac; // TODO: feels a bit odd, since it didn't come from us; but we don't want switches sending it back to us...

        dispatch(p);
    }
}


class CANInterfaceModule : Module
{
    mixin DeclareModule!"interface.can";
nothrow @nogc:

    Collection!CANInterface can_interfaces;

    override void init()
    {
        g_app.console.register_collection("/interface/can", can_interfaces);
    }

    override void update()
    {
        can_interfaces.update_all();
    }
}


version (DebugCANInterface)
{
    // TODO: maybe this function is cool in other palces where we log binary?
    char[] bin_to_ascii(const void[] bin)
    {
        import urt.mem.temp : talloc;
        char[] t = cast(char[])talloc(bin.length);
        t[] = cast(char[])bin[];
        foreach (ref c; t)
            c = is_control_char(c) ? '.' : c;
        return t;
    }
}
