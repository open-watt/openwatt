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

struct StreamStatus
{
nothrow @nogc:
    SysTime link_status_change_time;
    LinkStatus link_status = LinkStatus.down;
    int link_downs;

    ulong tx_bytes;
    ulong rx_bytes;

    ulong tx_rate;         // bytes-per-second
    ulong rx_rate;
    ulong tx_rate_max;
    ulong rx_rate_max;
}

struct IfStatus
{
nothrow @nogc:
    SysTime link_status_change_time;
    ConnectionStatus connected = ConnectionStatus.unknown;
    LinkStatus link_status = LinkStatus.down;
    int link_downs;

    ulong tx_bytes;
    ulong rx_bytes;
    ulong tx_packets;
    ulong rx_packets;
    ulong tx_dropped;
    ulong rx_dropped;

    ulong tx_link_speed;
    ulong rx_link_speed;

    ulong tx_rate;         // bytes-per-second
    ulong rx_rate;
    ulong tx_rate_max;
    ulong rx_rate_max;

    uint avg_queue_us;    // the average amount of time packets spend in the transmit queue
    uint avg_service_us;  // the average amount of time the router takes to process/deliver (excluding queue time)
    uint max_service_us;  // the maximum amount of time the router takes to process/deliver (excluding queue time)
}
