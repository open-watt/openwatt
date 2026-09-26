module driver.esp32.system;

version (Espressif):

import driver.system : ResetClass, ImageId, OtaImage;

nothrow @nogc:


void system_reboot()
{
    import urt.driver.reset : ResetMark, reset_record_mark;
    reset_record_mark(ResetMark.deliberate);
    esp_restart();
}

ulong unique_device_id()
{
    ubyte[8] mac = 0;
    if (esp_efuse_mac_get_default(mac.ptr) != 0)
        return 0;
    ulong id = 0;
    foreach (b; mac[0 .. 6])
        id = (id << 8) | b;

    import urt.hash : fnv1a64;
    ulong folded = fnv1a64(cast(const(ubyte)[])(&id)[0 .. 1]);
    return folded ? folded : id;
}
version (ESP32)
{
    enum bool has_download_mode = true;

    void system_reboot_to_bootloader(uint)
    {
        enum int rtc_gpio_mode_output_only = 1;
        rtc_gpio_init(0);
        rtc_gpio_set_direction(0, rtc_gpio_mode_output_only);
        rtc_gpio_set_level(0, 0);
        rtc_gpio_hold_en(0);
        esp_restart();
    }
}
else
    enum bool has_download_mode = false;

enum bool has_recovery_boot = false;

bool reboot_pending() => false;

// Why the chip came up. A restart that never reached the panic handler leaves no
// core dump, so without this a brownout and a clean reboot look identical.
const(char)[] reset_reason() => reset_table[reset_index()].name;

ResetClass reset_class()
{
    import urt.driver.reset : reset_record_take;
    reset_record_take();
    return reset_table[reset_index()].cls;
}

bool ota_supported() => true;

size_t ota_partition_size()
{
    auto p = esp_ota_get_next_update_partition(null);
    return p ? p.size : 0;
}

int ota_begin(size_t, ref uint handle)
{
    // Whole-partition erase blocks the main-thread IP stack for several seconds.
    enum size_t OTA_WITH_SEQUENTIAL_WRITES = 0xffff_fffe;
    auto p = esp_ota_get_next_update_partition(null);
    return p ? esp_ota_begin(p, OTA_WITH_SEQUENTIAL_WRITES, handle) : -1;
}

int ota_write(uint handle, const(ubyte)[] data)
    => esp_ota_write(handle, data.ptr, data.length);

int ota_end(uint handle)
{
    int err = esp_ota_end(handle);
    if (err)
        return err;
    auto p = esp_ota_get_next_update_partition(null);
    return p ? esp_ota_set_boot_partition(p) : -1;
}

void ota_abort(uint handle)
{
    esp_ota_abort(handle);
}

bool ota_running_image(out OtaImage image)
{
    auto p = esp_ota_get_running_partition();
    if (!p || esp_partition_get_sha256(p, image.id.ptr) != 0)
        return false;
    uint state;
    // Factory and USB-flashed images need not have an OTA state entry.
    image.pending = esp_ota_get_state_partition(p, &state) == 0 && state == 1;
    return true;
}

bool ota_accept_image() => esp_ota_mark_app_valid_cancel_rollback() == 0;

bool ota_previous_image(out ImageId image)
{
    auto p = esp_ota_get_next_update_partition(null);
    return p && esp_partition_get_sha256(p, image.ptr) == 0;
}

bool ota_revert(ref const ImageId image)
{
    auto p = esp_ota_get_next_update_partition(null);
    ImageId candidate;
    if (!p || esp_partition_get_sha256(p, candidate.ptr) != 0 || candidate != image)
        return false;
    return esp_ota_set_boot_partition(p) == 0;
}

void ota_push_policy(uint commit_secs, uint watchdog_ms, uint max_fail) {}


private:

struct ResetEntry
{
    string name;
    ResetClass cls;
}

immutable ResetEntry[16] reset_table = [
    { "unknown",            ResetClass.unknown },
    { "power-on",           ResetClass.power },
    { "external pin",       ResetClass.deliberate },
    { "software",           ResetClass.deliberate },
    { "panic",              ResetClass.crash },
    { "interrupt watchdog", ResetClass.crash },
    { "task watchdog",      ResetClass.crash },
    { "other watchdog",     ResetClass.crash },
    { "deep sleep wake",    ResetClass.deliberate },
    { "brownout",           ResetClass.power },
    { "sdio",               ResetClass.deliberate },
    { "usb",                ResetClass.deliberate },
    { "jtag",               ResetClass.deliberate },
    { "efuse error",        ResetClass.crash },
    { "power glitch",       ResetClass.power },
    { "cpu lockup",         ResetClass.crash },
];

size_t reset_index()
{
    int r = esp_reset_reason();
    return r > 0 && r < reset_table.length ? r : 0;
}

private struct esp_partition_t
{
    void* flash_chip;
    int type;
    int subtype;
    uint address;
    uint size;
    uint erase_size;
    char[17] label;
    bool encrypted;
    bool readonly;
}

private extern (C)
{
    void esp_restart();
    int esp_reset_reason();
    int esp_efuse_mac_get_default(ubyte* mac);
    int rtc_gpio_init(int gpio);
    int rtc_gpio_set_direction(int gpio, int mode);
    int rtc_gpio_set_level(int gpio, uint level);
    int rtc_gpio_hold_en(int gpio);
    const(esp_partition_t)* esp_ota_get_next_update_partition(const(esp_partition_t)* start);
    const(esp_partition_t)* esp_ota_get_running_partition();
    int esp_ota_get_state_partition(const(esp_partition_t)* p, uint* state);
    int esp_partition_get_sha256(const(esp_partition_t)* p, ubyte* hash);
    int esp_ota_begin(const(esp_partition_t)* p, size_t image_size, ref uint handle);
    int esp_ota_write(uint handle, const(void)* data, size_t len);
    int esp_ota_end(uint handle);
    int esp_ota_abort(uint handle);
    int esp_ota_set_boot_partition(const(esp_partition_t)* p);
    int esp_ota_mark_app_valid_cancel_rollback();
}
