module driver.baremetal.watchdog;

import urt.time : Duration;

nothrow @nogc:

version (BL808_M0)
    private extern(C) void ow_hang_watchdog_feed() nothrow @nogc;
else version (MT7621)
    import urt.driver.mt7621.watchdog : wdt_feed, wdt_start, wdt_stop;

// Elsewhere the hardware watchdog is configured by the platform runtime.
void watchdog_init(Duration timeout)
{
    version (MT7621)
        wdt_start(cast(uint)timeout.as!"msecs");
}

void watchdog_feed()
{
    version (BL808_M0)
        ow_hang_watchdog_feed();
    else version (MT7621)
        wdt_feed();
}

void watchdog_stop()
{
    version (MT7621)
        wdt_stop();
}
