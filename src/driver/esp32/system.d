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

bool reboot_pending() => false;

// Why the chip came up. A restart that never reached the panic handler leaves no
// core dump, so without this a brownout and a clean reboot look identical.
const(char)[] reset_reason()
{
    switch (esp_reset_reason())
    {
        case 1:  return "power-on";
        case 2:  return "external pin";
        case 3:  return "software";
        case 4:  return "panic";
        case 5:  return "interrupt watchdog";
        case 6:  return "task watchdog";
        case 7:  return "other watchdog";
        case 8:  return "deep sleep wake";
        case 9:  return "brownout";
        case 10: return "sdio";
        case 11: return "usb";
        case 12: return "jtag";
        default: return "unknown";
    }
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
    int esp_reset_reason();
    int esp_efuse_mac_get_default(ubyte* mac);
    const(esp_partition_t)* esp_ota_get_next_update_partition(const(esp_partition_t)* start);
    int esp_ota_begin(const(esp_partition_t)* p, size_t image_size, ref uint handle);
    int esp_ota_write(uint handle, const(void)* data, size_t len);
    int esp_ota_end(uint handle);
    int esp_ota_abort(uint handle);
    int esp_ota_set_boot_partition(const(esp_partition_t)* p);
    int esp_ota_mark_app_valid_cancel_rollback();
}
