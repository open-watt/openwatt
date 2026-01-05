module router.iface.tesla;

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

import protocol.tesla.twc;

import router.iface;
import router.iface.packet;
import router.stream;

//version = DebugTeslaInterface;

nothrow @nogc:


struct DeviceMap
{
    String name;
    MACAddress mac;
    ushort address;
    TeslaInterface iface;
}

class TeslaInterface : BaseInterface
{
    __gshared Property[1] Properties = [ Property.create!("stream", stream)() ];
nothrow @nogc:

    alias TypeName = StringLit!"tesla-twc";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TeslaInterface, name.move, flags);
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

    override bool validate() const
        => _stream !is null;

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

        SysTime now = getSysTime();

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
            incoming_packet(msg, now);
        }
    }

    protected override bool transmit(ref const Packet packet) nothrow @nogc
    {
        if (packet.eth.ether_type != EtherType.ow || packet.eth.ow_sub_type != OW_SubType.tesla_twc)
        {
            ++_status.send_dropped;
            return false;
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
            ++_status.send_dropped;
            return false;
        }

        version (DebugTeslaInterface) {
            import urt.io;
            writef("{4} - {0}: TWC packet sent {1}-->{2} [{3}]\n", name, packet.src, packet.dst, packet.data, packet.creation_time);
        }

        ++_status.send_packets;
        _status.send_bytes += packet.data.length;
        // TODO: but should we record the ACTUAL protocol packet?
        return true;
    }

private:
    ObjectRef!Stream _stream;

    final void incoming_packet(const(ubyte)[] msg, SysTime recv_time)
    {
        debug assert(running, "Shouldn't receive packets while not running...?");

        // we need to extract the sender/receiver addresses...
        TWCMessage message;
        bool r = msg.parse_twc_message(message);
        if (!r)
            return;

        Packet p;
        p.init!Ethernet(msg);
        p.creation_time = recv_time;
        p.vlan = _pvid;
        p.eth.ether_type = EtherType.ow;
        p.eth.ow_sub_type = OW_SubType.tesla_twc;

        auto mod_tesla = get_module!TeslaInterfaceModule();

        DeviceMap* map = mod_tesla.find_server_by_address(message.sender);
        if (!map)
            map = mod_tesla.add_device(null, this, message.sender);
        p.eth.src = map.mac;

        if (!message.receiver)
            p.eth.dst = MACAddress.broadcast;
        else
        {
            // find receiver... do we have a global device registry?
            map = mod_tesla.find_server_by_address(message.receiver);
            if (!map)
            {
                // we haven't seen the other guy, so we can't assign a dst address
                return;
            }
            p.eth.dst = map.mac;
        }

        if (p.eth.dst)
            dispatch(p);
    }
}


class TeslaInterfaceModule : Module
{
    mixin DeclareModule!"interface.tesla-twc";
nothrow @nogc:

    Collection!TeslaInterface twc_interfaces;
    Map!(ushort, DeviceMap) devices;

    override void init()
    {
        g_app.console.register_collection("/interface/tesla-twc", twc_interfaces);
    }

    override void update()
    {
        twc_interfaces.update_all();
    }

    DeviceMap* find_server_by_name(const(char)[] name)
    {
        foreach (ref map; devices.values)
        {
            if (map.name[] == name[])
                return &map;
        }
        return null;
    }

    DeviceMap* find_server_by_mac(MACAddress mac)
    {
        foreach (ref map; devices.values)
        {
            if (map.mac == mac)
                return &map;
        }
        return null;
    }

    DeviceMap* find_server_by_address(ushort address)
    {
        return address in devices;
    }

    DeviceMap* add_device(const(char)[] name, TeslaInterface iface, ushort address)
    {
        if (!name)
            name = tformat("{0}.{1,04X}", iface.name[], address);

        DeviceMap map;
        map.name = name.makeString(defaultAllocator());
        map.address = address;
        map.mac = iface.generate_mac_address();
        map.mac.b[4] = address >> 8;
        map.mac.b[5] = address & 0xFF;
//        while (find_mac_address(map.mac) !is null)
//            ++map.mac.b[5];
        map.iface = iface;

        iface.add_address(map.mac, iface);
        return devices.insert(address, map);
    }

    DeviceMap* add_server(const(char)[] name, BaseInterface iface, ushort address)
    {
        DeviceMap map;
        map.name = name.makeString(defaultAllocator());
        map.address = address;
        map.mac = iface.mac;
//        map.iface = iface;
        return devices.insert(address, map);
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
