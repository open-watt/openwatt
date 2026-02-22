module router.status;

import urt.time;

nothrow @nogc:


enum ConnectionStatus : byte
{
    unknown = -1,
    disconnected = 0,
    connected
}

enum LinkStatus : byte
{
    unknown = -1,
    down = 0,
    up
}

struct Status
{
nothrow @nogc:
    SysTime link_status_change_time;
    ConnectionStatus connected = ConnectionStatus.unknown;
    LinkStatus link_status = LinkStatus.down;
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
