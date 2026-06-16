module driver.baremetal.system;

import urt.log;

nothrow @nogc:


void system_reboot()
{
    log_notice("system", "system_reboot: not implemented on this platform");
}

bool   reboot_pending() => false;
bool   ota_supported() => false;
size_t ota_partition_size() => 0;
int    ota_begin(size_t image_size, ref uint handle) { handle = 0; return -1; }
int    ota_write(uint handle, const(ubyte)[] data) => -1;
int    ota_end(uint handle) => -1;
void   ota_abort(uint handle) {}
void   ota_commit() {}
void   ota_push_policy(uint commit_secs, uint watchdog_ms, uint max_fail) {}
