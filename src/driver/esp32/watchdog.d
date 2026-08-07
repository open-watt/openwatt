module driver.esp32.watchdog;

version (Espressif):

import urt.time : Duration;

nothrow @nogc:

private extern(C) void ow_watchdog_feed() nothrow @nogc;

void watchdog_init(Duration timeout) {} // hardware watchdog task is started by the C runtime

void watchdog_feed()
{
    ow_watchdog_feed();
}

void watchdog_stop() {}
