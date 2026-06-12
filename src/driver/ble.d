module driver.ble;

// Platform-selected BLE driver backend(s). manager.plugin registers
// `driver.ble` and the conditional aliases here resolve to the right
// concrete *Module class.
//
// The builtin backend covers any platform whose BLE is provided by the
// urt driver layer (windows WinRT, esp32 NimBLE). A linux kernel
// (MGMT/L2CAP) backend will slot in here as driver/linux/ble.d.

import manager.features : has_all;
import urt.driver.ble : num_ble;

version (linux)
{
    static if (has_all)
    {
        import driver.linux.ble;
        alias BLEDriverModule = LinuxBLEModule;
    }
}
else static if (has_all && num_ble > 0)
{
    import driver.baremetal.ble;
    alias BLEDriverModule = BuiltinBLEModule;
}
