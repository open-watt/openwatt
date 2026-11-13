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

enum Duplex : byte
{
    unknown = -1,
    half = 0,
    full
}

struct RateMeter
{
nothrow @nogc:
    ulong tx;   // bytes-per-second
    ulong rx;
    ulong tx_max;
    ulong rx_max;

    // returns the changed fields as bits in declaration order: tx, rx, tx_max, rx_max
    uint sample(MonoTime now, ulong tx_bytes, ulong rx_bytes)
    {
        if (_last_sample == MonoTime.init)
        {
            // first tick after link-up: anchor the baseline at a grid point; defer the
            // rate to the next tick so we never report it over a short partial interval.
            _last_sample = now;
            _last_tx_bytes = tx_bytes;
            _last_rx_bytes = rx_bytes;
            return 0;
        }

        ulong elapsed_us = (now - _last_sample).as!"usecs";
        if (elapsed_us == 0)
            return 0;

        ulong last_tx = tx, last_rx = rx;
        tx = (tx_bytes - _last_tx_bytes) * 1_000_000 / elapsed_us;
        rx = (rx_bytes - _last_rx_bytes) * 1_000_000 / elapsed_us;

        uint changed = (tx != last_tx) | (rx != last_rx) << 1;
        if (tx > tx_max)
        {
            tx_max = tx;
            changed |= 4;
        }
        if (rx > rx_max)
        {
            rx_max = rx;
            changed |= 8;
        }

        _last_tx_bytes = tx_bytes;
        _last_rx_bytes = rx_bytes;
        _last_sample = now;
        return changed;
    }

    // the next sample establishes the baseline
    void rebase()
    {
        _last_sample = MonoTime.init;
    }

    void reset()
    {
        tx = rx = tx_max = rx_max = 0;
        rebase();
    }

private:
    MonoTime _last_sample;
    ulong _last_tx_bytes;
    ulong _last_rx_bytes;
}

struct StreamStatus
{
nothrow @nogc:
    SysTime link_status_change_time;
    LinkStatus link_status = LinkStatus.down;
    int link_downs;

    ulong tx_bytes;
    ulong rx_bytes;

    RateMeter rate;
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

    RateMeter rate;

    uint avg_queue_us;    // the average amount of time packets spend in the transmit queue
    uint avg_service_us;  // the average amount of time the router takes to process/deliver (excluding queue time)
    uint max_service_us;  // the maximum amount of time the router takes to process/deliver (excluding queue time)
}
