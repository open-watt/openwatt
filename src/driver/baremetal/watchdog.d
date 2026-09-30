module driver.baremetal.watchdog;

import urt.time;

version (BL808)
{
    import urt.atomic : atomicLoad, atomicOp;
    import urt.driver.bl808.ipc : ipc_handle, ipc_send;
    import driver.bl808.ipc_ids : IpcId;
}

nothrow @nogc:

version (BL808_M0)
{
    import urt.driver.bl808.watchdog : wdt_feed, wdt_start, wdt_stop;
    version = HardwareWatchdog;
}
else version (MT7621)
{
    import urt.driver.mt7621.watchdog : wdt_feed, wdt_start, wdt_stop;
    version = HardwareWatchdog;
}
else version (RP2350)
{
    import urt.driver.rp2350.watchdog : wdt_feed, wdt_start, wdt_stop;
    version = HardwareWatchdog;
}
else version (STM32)
{
    import urt.driver.stm32.watchdog : wdt_feed, wdt_start, wdt_stop;
    version = HardwareWatchdog;
}

// Elsewhere the hardware watchdog is configured by the platform runtime.
void watchdog_init(Duration timeout)
{
    version (BL808_M0)
        ipc_handle(IpcId.d0_heartbeat, &d0_beat);
    version (HardwareWatchdog)
        wdt_start(cast(uint)timeout.as!"msecs");
}

void watchdog_feed()
{
    version (BL808_M0)
    {
        if (!d0_alive())
            return;
    }
    version (HardwareWatchdog)
        wdt_feed();
    else version (BL808)
        beat();
}

void watchdog_stop()
{
    version (HardwareWatchdog)
        wdt_stop();
}


private:

// M0's watchdog stands for D0 too: once D0 has beaten, a D0 that falls silent stops the feed, and the
// chip reset restarts both cores together.
version (BL808_M0)
{
    enum d0_silence = 3.seconds;

    shared uint _d0_beats;
    __gshared uint _d0_beat;
    __gshared MonoTime _d0_seen;

    void d0_beat(ubyte, const(void)[])
    {
        atomicOp!"+="(_d0_beats, 1);
    }

    bool d0_alive()
    {
        uint beat = atomicLoad(_d0_beats);
        MonoTime now = getTime();
        if (beat != _d0_beat)
        {
            _d0_beat = beat;
            _d0_seen = now;
        }
        return beat == 0 || now - _d0_seen < d0_silence;
    }
}
else version (BL808)
{
    enum beat_interval = 500.msecs;

    __gshared MonoTime _last_beat;

    void beat()
    {
        MonoTime now = getTime();
        if (now - _last_beat >= beat_interval && ipc_send(IpcId.d0_heartbeat, null))
            _last_beat = now;
    }
}
