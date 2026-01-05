module router.status;

import urt.time;

nothrow @nogc:


struct Status
{
nothrow @nogc:
    enum Connection : byte
    {
        unknown = -1,
        disconnected = 0,
        connected
    }

    enum Link : byte
    {
        unknown = -1,
        down = 0,
        up
    }

    SysTime link_status_change_time;
    Connection connected = Connection.unknown;
    Link link_status = Link.down;
    int link_downs;

    ulong send_bytes;
    ulong recv_bytes;
    ulong send_packets;
    ulong recv_packets;
    ulong send_dropped;
    ulong recv_dropped;

    ulong tx_link_speed;
    ulong rx_link_speed;
}
