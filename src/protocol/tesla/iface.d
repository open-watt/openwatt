module protocol.tesla.iface;

import urt.log;
import urt.map;
import urt.mem;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.tesla;
import protocol.tesla.twc;

import router.iface;
import router.iface.packet;
import router.stream;

//version = DebugTeslaInterface;

nothrow @nogc:


// the TWC RS485 bus is 9600 8N1 by design; there is nothing to negotiate
enum twc_baud = 9_600;


struct TWCFrame
{
    enum Type = PacketType.tesla_twc;

    enum ushort broadcast = 0xFFFF;

    ushort src;
    ushort dst;

    static ulong extract_src(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!TWCFrame().src;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.tesla_twc) << 60;
        return addr;
    }

    static ulong extract_dst(ref const Packet p) pure nothrow @nogc
    {
        ulong addr = p.hdr!TWCFrame().dst;
        addr |= ulong(p.vlan & 0xFFF) << 48;
        addr |= ulong(PacketType.tesla_twc) << 60;
        return addr;
    }

    static bool is_multicast(ulong address) pure nothrow @nogc
        => (address & 0xFFFF) == broadcast;

    // OW encapsulation wire codec: [src:2 BE][dst:2 BE]
    static ptrdiff_t encode_ow_header(ref const Packet p, ubyte[] buffer) nothrow @nogc
    {
        import urt.endian : nativeToBigEndian;
        if (buffer.length < 4)
            return -1;
        ref const f = p.hdr!TWCFrame;
        buffer[0 .. 2] = f.src.nativeToBigEndian;
        buffer[2 .. 4] = f.dst.nativeToBigEndian;
        return 4;
    }

    static ptrdiff_t decode_ow_header(ref Packet p, const(ubyte)[] header) nothrow @nogc
    {
        import urt.endian : bigEndianToNative;
        if (header.length < 4)
            return -1;
        p.type = PacketType.tesla_twc;
        ref f = p.hdr!TWCFrame;
        f.src = header[0 .. 2].bigEndianToNative!ushort;
        f.dst = header[2 .. 4].bigEndianToNative!ushort;
        return 4;
    }
}

final class TeslaInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream));
nothrow @nogc:

    ~this() {}

    enum type_name = "tesla-twc";
    enum path = "/interface/tesla-twc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaInterface, id, flags);
        set_l2mtu(max_message);
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
        if (Stream old = _stream)
            old.release_rx_handler(&stream_rx);
        _stream = value;
        mark_set!(typeof(this), "stream")();

        restart();
        return null;
    }

    // API...

protected:

    override bool validate() const
        => _stream !is null;

    override CompletionStatus startup()
    {
        if (!_stream)
            return CompletionStatus.error;
        if (!_stream.running)
            return CompletionStatus.continue_;
        _stream.rx_handler(&stream_rx);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (Stream s = _stream)
            s.release_rx_handler(&stream_rx);
        _rx_length = 0;
        return CompletionStatus.complete;
    }

    override void online()
    {
        super.online();

        // reached over an RS485-to-TCP bridge the bus still runs at the TWC rate whatever the transport
        // does, so only a local serial port gets to state the rate itself
        import router.stream.serial : SerialStream;
        auto serial = dyn_cast!SerialStream(_stream.get);
        set_link_speed(serial ? serial.baud_rate : twc_baud);
    }

    override void update()
    {
        super.update();

        if (!_stream || !_stream.running)
            return restart();
    }

    override int transmit(ref const Packet packet, MessageCallback, const(QueuePolicy)*) nothrow @nogc
    {
        if (packet.type != PacketType.tesla_twc)
        {
            add_tx_drop();
            return -1;
        }

        const(ubyte)[] msg = cast(ubyte[])packet.data;

        ubyte[1 + 2 * max_message + 3] t = void;
        size_t offset = 1;
        ubyte checksum = 0;

        t[0] = 0xC0;
        for (size_t i = 0; i < msg.length; i++)
        {
            if (i > 0)
                checksum += msg.ptr[i];
            if (msg.ptr[i] == 0xC0)
            {
                t[offset++] = 0xDB;
                t[offset++] = 0xDC;
            }
            else if (msg.ptr[i] == 0xDB)
            {
                t[offset++] = 0xDB;
                t[offset++] = 0xDD;
            }
            else
                t[offset++] = msg.ptr[i];
        }
        t[offset++] = checksum;
        t[offset++] = 0xC0;

        // It works without this byte, but I always receive it from a real device!
        t[offset++] = 0xFD;

        size_t written = _stream.write(t[0..offset]);
        if (written != offset)
        {
            debug writeDebug("Failed to write to stream '", _stream.name, "'");
            add_tx_drop();
            return -1;
        }

        version (DebugTeslaInterface) {
            import urt.io;
            writef("{4} - {0}: TWC packet sent {1,04x}-->{2,04x} [{3}]\n", name, packet.hdr!TWCFrame.src, packet.hdr!TWCFrame.dst, packet.data, packet.creation_time);
        }

        add_tx_frame(packet.data.length); // TODO: but should we record the ACTUAL protocol packet?
        return 0;
    }

private:
    // a message SLIP-escaped with its start, checksum and end bytes fills the 64-byte transmit buffer
    enum ushort max_message = 30;

    ObjectRef!Stream _stream;
    ubyte[2 * max_message + 2] _rx;   // the escaped bytes since the last frame byte
    ubyte _rx_length;

    // every 0xC0 ends what came before it; whatever is not a valid message is dropped
    void stream_rx(Stream, const(void)[] data, MonoTime rx_time)
    {
        foreach (b; cast(const(ubyte)[])data)
        {
            if (b == 0xC0)
            {
                if (_rx_length)
                    frame_received(_rx[0 .. _rx_length], rx_time);
                _rx_length = 0;
            }
            else if (_rx_length < _rx.length)
                _rx[_rx_length++] = b;
        }
    }

    void frame_received(ubyte[] msg, MonoTime rx_time)
    {
        // let's check if the message looks valid...
        if (msg.length < 13)
            return;
        msg = unescape_msg(msg);
        if (!msg)
            return;
        ubyte checksum = 0;
        for (size_t i = 1; i < msg.length - 1; i++)
            checksum += msg[i];
        if (checksum != msg[$ - 1])
            return;
        msg = msg[0 .. $-1];

        incoming_frame(msg, rx_time);
    }

    void incoming_frame(const(ubyte)[] msg, MonoTime recv_time)
    {
        debug assert(running, "Shouldn't receive packets while not running...?");

        // we need to extract the sender/receiver addresses...
        TWCMessage message;
        bool r = msg.parse_twc_message(message);
        if (!r)
            return;

        Packet p;
        ref TWCFrame twc = p.init!TWCFrame(msg, recv_time);
        twc.src = message.sender;
        twc.dst = message.receiver ? message.receiver : TWCFrame.broadcast;

        incoming_packet(p);
    }
}


private:

ubyte[] unescape_msg(ubyte[] msg) nothrow @nogc
{
    size_t offset = 0;
    for (size_t i = 0; i < msg.length; i++)
    {
        if (msg[i] == 0xDB)
        {
            if (++i >= msg.length)
                return null;
            else if (msg[i] == 0xDC)
                msg[offset++] = 0xC0;
            else if (msg[i] == 0xDD)
                msg[offset++] = 0xDB;
            else
                return null;
        }
        else
        {
            if (offset < i)
                msg[offset] = msg[i];
            offset++;
        }
    }
    return msg[0 .. offset];
}
