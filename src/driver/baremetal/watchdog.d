module driver.baremetal.watchdog;

import urt.time : Duration;

nothrow @nogc:

version (BL808_M0)
    private extern(C) void ow_hang_watchdog_feed() nothrow @nogc;
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
    version (HardwareWatchdog)
        wdt_start(cast(uint)timeout.as!"msecs");
}

void watchdog_feed()
{
    version (BL808_M0)
        ow_hang_watchdog_feed();
    else version (HardwareWatchdog)
        wdt_feed();
}

void watchdog_stop()
{
    version (HardwareWatchdog)
        wdt_stop();
}
