module driver.windows.system;

version (Windows):

import urt.log;

import driver.system : ResetClass, ImageId, OtaImage;

nothrow @nogc:


void system_reboot()
{
    import core.stdc.stdlib : exit;
    log_notice("system", "system_reboot: exiting process");
    exit(0);
}

// computers carry a software identity (persisted node.id); no chip-burned id here
ulong unique_device_id() => 0;
enum bool has_download_mode = false;

// no reset-reason source on this platform
const(char)[] reset_reason() => null;
ResetClass reset_class() => ResetClass.unknown;

bool   reboot_pending() => false;
bool   ota_supported() => false;
size_t ota_partition_size() => 0;
int    ota_begin(size_t image_size, ref uint handle) { handle = 0; return -1; }
int    ota_write(uint handle, const(ubyte)[] data) => -1;
int    ota_end(uint handle) => -1;
void   ota_abort(uint handle) {}
bool ota_running_image(out OtaImage image) => false;
bool ota_accept_image() => false;
bool ota_previous_image(out ImageId image) => false;
bool ota_revert(ref const ImageId image) => false;
void   ota_push_policy(uint commit_secs, uint watchdog_ms, uint max_fail) {}
