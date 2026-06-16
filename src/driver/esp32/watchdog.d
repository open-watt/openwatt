module driver.esp32.watchdog;

version (Espressif):

import urt.time : Duration;

nothrow @nogc:

version (ESP32_S3)
    private extern(C) void ow_watchdog_feed() nothrow @nogc;

void watchdog_init(Duration timeout) {} // hardware watchdog task is started by the C runtime

void watchdog_feed()
{
    version (ESP32_S3)
        ow_watchdog_feed();
}

void watchdog_stop() {}
