module protocol.can.iface;

import urt.endian;
import urt.log;
import urt.mem;
import urt.mem.string;
import urt.meta.nullable;
import urt.string;
import urt.time;

import manager.collection;
import manager.console;
import manager.plugin;

import router.iface;
import router.stream;

import sys.baremetal.can;

version(Espressif)
    version = HasGPIO;

//version = DebugCANInterface;

nothrow @nogc:


enum CANInterfaceProtocol : byte
{
    unknown = -1,
    ebyte
}

struct CANFrame
{
    enum Type = PacketType.can;

    uint id;
    bool remote_transmission_request;
    bool extended;

    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!CANFrame().id;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.can) << 60;
        return addr; // TODO: should we set the broadcast bit?
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.can) << 60;
        addr |= ulong(1) << 63; // CAN is always broadcast
        return addr;
    }
}


class CANInterface : BaseInterface
{
    version(HasGPIO)
        __gshared Property[6] Properties = [
            Property.create!("stream", stream)(),
            Property.create!("protocol", protocol)(),
            Property.create!("device", device)(),
            Property.create!("baud-rate", baud_rate)(),
            Property.create!("tx-gpio", tx_gpio)(),
            Property.create!("rx-gpio", rx_gpio)(),
        ];
    else
        __gshared Property[4] Properties = [
            Property.create!("stream", stream)(),
            Property.create!("protocol", protocol)(),
            Property.create!("device", device)(),
            Property.create!("baud-rate", baud_rate)(),
        ];

nothrow @nogc:

    enum type_name = "can";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!CANInterface, id, flags);

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
        _device = String();
        return null;
    }

    final const(char)[] device() const pure
        => _device[];
    final void device(const(char)[] value)
    {
        _device = value.makeString(defaultAllocator);
        if (!value.empty)
        {
            _stream = null;
            _protocol = CANInterfaceProtocol.unknown;
        }
    }

    final uint baud_rate() const pure
        => _baud_rate;
    final void baud_rate(uint value)
    {
        _baud_rate = value;
    }

    version(HasGPIO)
    {
        final ubyte tx_gpio() const pure
            => _tx_gpio;
        final void tx_gpio(ubyte value)
        {
            _tx_gpio = value;
        }

        final ubyte rx_gpio() const pure
            => _rx_gpio;
        final void rx_gpio(ubyte value)
        {
            _rx_gpio = value;
        }
    }


    // API...

    override bool validate() const
    {
        if (!_device.empty)
        {
            static if (num_can > 0)
                return _baud_rate > 0;
            else
                return false;
        }
        return _stream !is null && _protocol == CANInterfaceProtocol.ebyte;
    }

    override CompletionStatus startup()
    {
        if (!_device.empty)
        {
            static if (num_can > 0)
            {
                can_init();
                CanConfig cfg;
                cfg.bitrate = _baud_rate;
                version(HasGPIO)
                {
                    cfg.tx_gpio = _tx_gpio;
                    cfg.rx_gpio = _rx_gpio;
                }
                auto result = can_open(_can, 0, cfg);
                if (!result)
                {
                    can_deinit();
                    writeError("CAN init failed for '", name, "'");
                    return CompletionStatus.error;
                }
            }
            return CompletionStatus.complete;
        }

        if (!_stream)
            return CompletionStatus.error;
        if (_stream.running)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    override void update()
    {
        if (_can.is_open)
        {
            super.update();
            poll_native();
            return;
        }

        if (!_stream || !_stream.running)
            return restart();

        super.update();

        SysTime now = getSysTime();

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

            Packet packet;

            size_t offset = 0;
            while (offset < length)
            {
                // parse packets from the stream...
                ref CANFrame can = packet.init!CANFrame(null, now);

                size_t taken = 0;
                switch (protocol)
                {
                    case CANInterfaceProtocol.ebyte:

                        if (length - offset >= EbyteFrameSize)
                        {
                            // TODO: how can we even do any packet validation?
                            //       there's basically no error detection data available
                            //       I guess we could confirm assumed zero bits in the header and _tail?

                            const ubyte[] ebyteFrame = buffer[offset .. offset + EbyteFrameSize];

                            uint len = ebyteFrame[0] & 0xF;
                            if (len > 8)
                            {
                                debug assert(len <= 8, "TODO: bad CAN frame; did we fall off the rails? bad data? skip this message? how do we resync?");
                                break;
                            }

                            can.remote_transmission_request = (ebyteFrame[0] & 0x40) != 0;
                            can.extended = (ebyteFrame[0] & 0x80) != 0;

                            can.id = ebyteFrame[1 .. 5].bigEndianToNative!uint;

                            packet.data = ebyteFrame[5 .. 5 + len];

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

                if (can.id > (can.extended ? 0x1FFFFFFF : 0x7FF))
                {
                    version (DebugCANInterface)
                        writeDebug("CAN packet dropped on interface '", name, "': invalid frame - bad ID");
                    ++_status.rx_dropped;
                    continue;
                }

                version (DebugCANInterface)
                    writeDebug("CAN packet received from interface '", name, "': id=", can.id, " (", packet.length , ")[ ", packet.data, " - ", packet.data.bin_to_ascii(), " ]");

                packet.vlan = _pvid;

                dispatch(packet);
            }

            // we've eaten the whole buffer...
            length = 0;
        }
    }

    protected override int transmit(ref const Packet packet, MessageCallback)
    {
        // can only handle can packets
        if (packet.type != PacketType.can)
        {
            if (packet.type == PacketType.ethernet && packet.eth.ether_type == EtherType.ow && packet.eth.ow_sub_type == OW_SubType.can)
            {
                // de-frame CANoE...
                assert(false, "TODO");
            }
            ++_status.tx_dropped;
            return -1;
        }

        if (packet.data.length > 8)
        {
            version (DebugCANInterface)
                writeDebug("CAN packet dropped on interface '", name, "': invalid frame - data too long");
            ++_status.tx_dropped;
            return false;
        }

        ref can = packet.hdr!CANFrame;

        if (_can.is_open)
        {
            CanFrame hw = void;
            hw.id = can.id;
            hw.extended = can.extended;
            hw.rtr = can.remote_transmission_request;
            hw.dlc = cast(ubyte)packet.data.length;
            hw.data[0 .. hw.dlc] = cast(const ubyte[])packet.data[];
            if (!can_transmit(_can, hw))
            {
                ++_status.tx_dropped;
                return -1;
            }
            ++_status.tx_packets;
            _status.tx_bytes += packet.data.length;
            return 0;
        }

        // frame it up and send via stream...
        ubyte[LargestProtocolFrame] buffer = void;
        size_t length = 0;

        switch (protocol)
        {
            case CANInterfaceProtocol.ebyte:
                ubyte dataLen = cast(ubyte)packet.length;
                buffer[0] = (can.extended << 7) | (can.remote_transmission_request << 6) | dataLen;
                buffer[1 .. 5] = can.id.nativeToBigEndian;
                buffer[5 .. 5 + packet.length] = cast(ubyte[])packet.data[];
                buffer[5 + packet.length .. EbyteFrameSize] = 0;
                length = EbyteFrameSize;
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
                writeDebug("CAN packet sent on interface '", name, "': id=", can.id, " (", packet.length, ")[ ", packet.data, " - ", packet.data.bin_to_ascii(), " ]");
        }

        if (written <= 0)
        {
            ++_status.tx_dropped;
            return -1;
        }

        ++_status.tx_packets;
        _status.tx_bytes += length;
        return 0;
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

        ref can = packet.hdr!CANFrame;

        socket_can f;
        f.id = can.id.nativeToBigEndian;
        f.id[0] |= can.extended << 7;
        f.id[0] |= can.remote_transmission_request << 6;
        f.len = cast(ubyte)packet.length;
        f.data[0 .. f.len] = cast(const ubyte[])packet.data[];

        // TODO: what's the go with the error bit (bit 29 of ID)???

        sink((cast(ubyte*)&f)[0 .. socket_can.sizeof]);
    }

    override CompletionStatus shutdown()
    {
        if (_can.is_open)
        {
            can_close(_can);
            can_deinit();
        }
        return CompletionStatus.complete;
    }

private:
    ObjectRef!Stream _stream;
    CANInterfaceProtocol _protocol;
    String _device;
    uint _baud_rate = 500_000;
    ubyte[LargestProtocolFrame] _tail;
    ushort _tail_bytes;

    version(HasGPIO)
    {
        ubyte _tx_gpio;
        ubyte _rx_gpio;
    }

    Can _can;

    void poll_native()
    {
        SysTime now = getSysTime();
        CanFrame hw = void;

        while (can_receive(_can, hw))
        {
            Packet packet;
            ref CANFrame can = packet.init!CANFrame(hw.data[0 .. hw.dlc], now);
            can.id = hw.id;
            can.extended = hw.extended;
            can.remote_transmission_request = hw.rtr;
            packet.vlan = _pvid;
            dispatch(packet);
        }
    }
}


private:

enum EbyteFrameSize = 13;
enum LargestProtocolFrame = EbyteFrameSize;

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
