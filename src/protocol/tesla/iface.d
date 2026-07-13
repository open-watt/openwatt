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

class TeslaInterface : BaseInterface
{
    alias Properties = AliasSeq!(Prop!("stream", stream));
nothrow @nogc:

    enum type_name = "tesla-twc";
    enum path = "/interface/tesla-twc";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaInterface, id, flags);
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

        restart();
        return null;
    }

    // API...

protected:
    mixin RekeyHandler;

    override bool validate() const
        => _stream !is null;

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
        super.update();

        if (!_stream || !_stream.running)
            return restart();

        MonoTime now = getTime();

        // check for data
        ubyte[1024] buffer = void;
        ptrdiff_t bytes = _stream.read(buffer);
        if (bytes < 0)
        {
            assert(false, "what causes read to fail?");
            // TODO...
        }
        if (bytes == 0)
            return;

        size_t offset = 0;
        while (offset < bytes)
        {
            // scan for start of message
            while (offset < bytes && buffer[offset] != 0xC0)
                ++offset;
            size_t end = offset + 1;
            for (; end < bytes; ++end)
            {
                if (buffer[end] == 0xC0)
                    break;
            }

            if (offset == bytes || end == bytes)
            {
                if (bytes != buffer.length || offset == 0)
                    break;
                for (size_t i = offset; i < bytes; ++i)
                    buffer[i - offset] = buffer[i];
                bytes = bytes - offset;
                offset = 0;
                bytes += _stream.read(buffer[bytes .. $]);
                continue;
            }

            ubyte[] msg = buffer[offset + 1 .. end];
            offset = end;

            // let's check if the message looks valid...
            if (msg.length < 13)
                continue;
            msg = unescape_msg(msg);
            if (!msg)
                continue;
            ubyte checksum = 0;
            for (size_t i = 1; i < msg.length - 1; i++)
                checksum += msg[i];
            if (checksum != msg[$ - 1])
                continue;
            msg = msg[0 .. $-1];

            // we seem to have a valid packet...
            incoming_frame(msg, now);
        }
    }

    override int transmit(ref const Packet packet, MessageCallback, const(QueuePolicy)*) nothrow @nogc
    {
        if (packet.type != PacketType.tesla_twc)
        {
            add_tx_drop();
            return -1;
        }

        const(ubyte)[] msg = cast(ubyte[])packet.data;

        ubyte[64] t = void;
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
    ObjectRef!Stream _stream;

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
