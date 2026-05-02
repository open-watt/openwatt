module driver.wifi;

import urt.driver.wifi : num_wifi;

// Platform-selected wifi driver backend(s). manager.plugin registers
// `driver.wifi` and the conditional aliases here resolve to the right
// concrete *Module class. Add entries below as new backends land
// (driver/posix/wifi.d, ...).
//
// NB: the wifi-side hierarchy is more complicated than ethernet because
// of the existing WiFiInterface (radio) / WLANInterface (station) /
// APInterface (AP) layering. See SHELVED notes at the top of
// driver/windows/wifi.d for the full design plan.

version (Windows)
{
    import driver.windows.wifi;
    alias WifiModule = WindowsWlanModule;
}
else static if (num_wifi > 0)
{
    import driver.baremetal.wifi;
    alias WifiModule = BuiltinWifiModule;
}
