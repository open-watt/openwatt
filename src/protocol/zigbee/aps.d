module protocol.zigbee.aps;

import urt.endian;

import router.iface.packet;

nothrow @nogc:

//
// APS spec here: https://zigbeealliance.org/wp-content/uploads/2019/11/docs-05-3474-21-0csg-zigbee-specification.pdf
//

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

enum APSFlags : ushort
{
    none = 0x0000,
    zdo_response_required = 0x4000
}


struct APSFrame
{
    enum Type = PacketType.ZigbeeAPS;

    APSFrameType type;
    APSDeliveryMode delivery_mode;

    APSFlags flags; // we can trim this if we need more bytes

    ushort pan_id;

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

ptrdiff_t parse_aps_frame(const void[] packet, out APSFrame frame) pure
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

ptrdiff_t format_aps_frame(ref const APSFrame frame, void[] buffer) pure
{
    if (buffer.length < 2)
        return -1;

    auto p = cast(ubyte[])buffer;
    size_t i = 0;

    ubyte control = cast(ubyte)frame.type;
    control |= (cast(ubyte)frame.delivery_mode) << 2;
    control |= frame.security ? 0x20 : 0;
    control |= frame.ack_request ? 0x40 : 0;
    control |= frame.fragmentation != APSFragmentation.none ? 0x80 : 0;
    p[i++] = control;

    if ((frame.delivery_mode & 1) == 0) // APSDeliveryMode == Unicast or Broadcast
        p[i++] = frame.dst_endpoint;
    else if (frame.delivery_mode == APSDeliveryMode.group)
    {
        if (buffer.length < 3)
            return -1;
        p[1..3] = frame.dst.nativeToLittleEndian;
        i += 2;
    }

    if ((frame.type & 1) == 0) // data or ack
    {
        if (buffer.length < i + 4)
            return -1;
        p[i..i+2][0..2] = frame.cluster_id.nativeToLittleEndian;
        p[i+2..i+4][0..2] = frame.profile_id.nativeToLittleEndian;
        i += 4;
    }

    if (buffer.length < i + 2)
        return -1;
    p[i++] = frame.src_endpoint; // TODO: isn't this field optional??
    p[i++] = frame.counter;

    // extended header
    if (control & 0x80)
    {
        if (buffer.length < i + 1)
            return -1;
        ubyte ext = cast(ubyte)frame.fragmentation;
        p[i++] = ext;

        if (frame.fragmentation != APSFragmentation.none)
        {
            if (buffer.length < i + 1)
                return -1;
            p[i++] = frame.block_number;

            if (frame.type == APSFrameType.ack)
            {
                if (buffer.length < i + 1)
                    return -1;
                p[i++] = frame.ack_bitfield;
            }
        }
    }

    return i;
}

const(char)[] profile_name(ushort profile)
{
    import urt.mem.temp : tformat;

    switch (profile)
    {
        case 0x0000: return "zdo";
        case 0x0101: return "ipm";  // industrial plant monitoring
        case 0x0104: return "ha";   // home assistant
        case 0x0105: return "ba";   // building automation
        case 0x0107: return "ta";   // telco automation
        case 0x0108: return "hc";   // health care
        case 0x0109: return "se";   // smart energy
        case 0xA1E0: return "gp";   // green power
        case 0xC05E: return "zll";  // zigbee light link
        default:
            return tformat("{0, 04x}", profile);
    }
}
