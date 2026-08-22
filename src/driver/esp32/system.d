module driver.esp32.system;

version (Espressif):

nothrow @nogc:


void system_reboot()
{
    esp_restart();
}

// Chip-burned identity: the eFuse factory MAC is unique per chip and survives reflash,
// so it is the node identity on this platform; storage never enters into it.
ulong unique_device_id()
{
    ubyte[8] mac = 0;
    if (esp_efuse_mac_get_default(mac.ptr) != 0)
        return 0;
    ulong id = 0;
    foreach (b; mac[0 .. 6])
        id = (id << 8) | b;
    return id;
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

bool reboot_pending() => false;

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

void ota_commit()
{
    esp_ota_mark_app_valid_cancel_rollback();
}

void ota_push_policy(uint commit_secs, uint watchdog_ms, uint max_fail) {}


private:

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
    int esp_efuse_mac_get_default(ubyte* mac);
    int rtc_gpio_init(int gpio);
    int rtc_gpio_set_direction(int gpio, int mode);
    int rtc_gpio_set_level(int gpio, uint level);
    int rtc_gpio_hold_en(int gpio);
    const(esp_partition_t)* esp_ota_get_next_update_partition(const(esp_partition_t)* start);
    int esp_ota_begin(const(esp_partition_t)* p, size_t image_size, ref uint handle);
    int esp_ota_write(uint handle, const(void)* data, size_t len);
    int esp_ota_end(uint handle);
    int esp_ota_abort(uint handle);
    int esp_ota_set_boot_partition(const(esp_partition_t)* p);
    int esp_ota_mark_app_valid_cancel_rollback();
}
