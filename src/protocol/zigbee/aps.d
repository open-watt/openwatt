module protocol.zigbee.aps;

import urt.endian;

import router.iface.packet;

pure nothrow @nogc:


enum APSFrameType : ubyte
{
    data      = 0,
    command   = 1,
    ack       = 2,
    inter_pan = 3,
}

enum APSDeliveryMode : ubyte
{
    unicast   = 0,
    reserved  = 1,
    broadcast = 2,
    group     = 3,
}

enum APSFragmentation : ubyte
{
    none      = 0,
    first     = 1,
    fragment  = 2,
    reserved  = 3,
}

struct APSFrame
{
    enum Type = PacketType.ZigbeeAPS;

    APSFrameType type;
    APSDeliveryMode delivery_mode;

    ushort dst;
    ushort src;

    bool security;
    bool ack_request;

    ubyte dst_endpoint;
    ubyte src_endpoint;
    ushort cluster_id;
    ushort profile_id;
    ubyte counter;

    // extended header items
    APSFragmentation fragmentation;
    ubyte block_number;
    ubyte ack_bitfield;

    // TODO: should we keep these? it's not really APS data, but it's interesting incoming packet knowledge...
    ubyte last_hop_lqi;
    byte last_hop_rssi;
}

ptrdiff_t parse_aps_frame(const void[] packet, out APSFrame frame)
{
    if (packet.length < 8)
        return -1;

    auto p = cast(const(ubyte)[])packet;

    ubyte control = p[0];
    frame.type = cast(APSFrameType)(control & 3);
    frame.delivery_mode = cast(APSDeliveryMode)((control >> 2) & 3);
    frame.security = (control >> 5) & 1;
    frame.ack_request = (control >> 5) & 1;

    size_t i = 1;
    if ((frame.delivery_mode & 1) == 0) // APSDeliveryMode == Unicast or Broadcast
    {
        frame.dst_endpoint = p[i++];
        if (frame.delivery_mode == APSDeliveryMode.broadcast)
            frame.dst = 0xFFFF;
        else
        {
            // TODO: unicast dst is from NWK frame... :/
        }
    }
    if (frame.delivery_mode == APSDeliveryMode.group)
    {
        frame.dst = *cast(ushort*)(p.ptr + i);
        i += 2;
    }
    if ((frame.type & 1) == 0) // APSFrameType == Data or Ack
    {
        frame.cluster_id = *cast(ushort*)(p.ptr + i);
        frame.profile_id = *cast(ushort*)(p.ptr + i + 2);
        i += 4;
    }
    frame.src_endpoint = p[i++]; // TODO: isn't this field optional??
    frame.counter = p[i++];

    // TODO: frame.src is from NWK frame... :/

    // parse extended header items
    if (control & 0x80)
    {
        ubyte ext = p[i++];
        frame.fragmentation = cast(APSFragmentation)(ext & 3);
        if (frame.fragmentation != APSFragmentation.none)
        {
            frame.block_number = p[i++];
            if (frame.type == APSFrameType.ack)
                frame.ack_bitfield = p[i++];
        }
    }

    return i;
}
