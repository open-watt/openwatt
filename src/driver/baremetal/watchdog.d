module driver.baremetal.watchdog;

import urt.time;

version (BL808_M0)
{
    version = WatchdogDriver;
    import urt.driver.bl_common.watchdog : wdt_feed, wdt_start, wdt_stop;
    import urt.driver.bl_common.xram : xram_d0_heartbeat;
}
else version (BL808)
    import urt.driver.bl_common.xram : xram_d0_heartbeat_beat;
else version (MT7621)
{
    version = WatchdogDriver;
    import urt.driver.mt7621.watchdog : wdt_feed, wdt_start, wdt_stop;
}

nothrow @nogc:

// Elsewhere the hardware watchdog is configured by the platform runtime.
void watchdog_init(Duration timeout)
{
    version (WatchdogDriver)
        wdt_start(cast(uint)timeout.as!"msecs");
}

void watchdog_feed()
{
    version (BL808_M0)
    {
        if (!d0_alive())
            return;
    }
    version (WatchdogDriver)
        wdt_feed();
    else version (BL808)
        xram_d0_heartbeat_beat();
}

void watchdog_stop()
{
    version (WatchdogDriver)
        wdt_stop();
}


private:

// M0's watchdog stands for D0 too: once D0 has beaten, a D0 that falls silent stops the feed, and the
// chip reset restarts both cores together.
version (BL808_M0)
{
    enum d0_silence = 3.seconds;

    __gshared uint _d0_beat;
    __gshared MonoTime _d0_seen;

    bool d0_alive()
    {
        uint beat = xram_d0_heartbeat();
        MonoTime now = getTime();
        if (beat != _d0_beat)
        {
            _d0_beat = beat;
            _d0_seen = now;
        }
        return beat == 0 || now - _d0_seen < d0_silence;
    }
}
