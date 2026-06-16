module driver.baremetal.watchdog;

import urt.time : Duration;

nothrow @nogc:

version (BL808_M0)
    private extern(C) void ow_hang_watchdog_feed() nothrow @nogc;

void watchdog_init(Duration timeout) {} // hardware watchdog is configured by the platform runtime

void watchdog_feed()
{
    version (BL808_M0)
        ow_hang_watchdog_feed();
}

void watchdog_stop() {}
