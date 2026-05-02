module driver.system;

// Platform-selected system driver. Exposes free functions for system-level
// capabilities (reboot, OTA) that have platform-specific implementations.
// Add entries below as new backends land.

version (Windows)        public import driver.windows.system;
else version (linux)     public import driver.linux.system;
else version (Espressif) public import driver.esp32.system;
else                     public import driver.baremetal.system;
