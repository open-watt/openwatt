module driver.esp32.system;

version (Espressif):

nothrow @nogc:


void system_reboot()
{
    esp_restart();
}

bool reboot_pending() => false;

bool ota_supported() => true;

size_t ota_partition_size()
{
    auto p = esp_ota_get_next_update_partition(null);
    return p ? p.size : 0;
}

int ota_begin(size_t image_size, ref uint handle)
{
    auto p = esp_ota_get_next_update_partition(null);
    return p ? esp_ota_begin(p, image_size, handle) : -1;
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
    const(esp_partition_t)* esp_ota_get_next_update_partition(const(esp_partition_t)* start);
    int esp_ota_begin(const(esp_partition_t)* p, size_t image_size, ref uint handle);
    int esp_ota_write(uint handle, const(void)* data, size_t len);
    int esp_ota_end(uint handle);
    int esp_ota_abort(uint handle);
    int esp_ota_set_boot_partition(const(esp_partition_t)* p);
    int esp_ota_mark_app_valid_cancel_rollback();
}
