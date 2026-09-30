module driver.baremetal.watchdog;

import urt.time : Duration;

version (BL808_M0)
{
    version = WatchdogDriver;
    import urt.driver.bl_common.watchdog : wdt_feed, wdt_start, wdt_stop;
}
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
    version (WatchdogDriver)
        wdt_feed();
}

void watchdog_stop()
{
    version (WatchdogDriver)
        wdt_stop();
}
