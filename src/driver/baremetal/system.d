module driver.baremetal.system;

import urt.driver.reset : ResetMark, has_reset_record, has_system_reset, reset_record_mark, reset_record_take, system_reset;
import urt.log;

import driver.system : ResetClass, ImageId, OtaImage;

nothrow @nogc:


void system_reboot()
{
    reset_record_mark(ResetMark.deliberate);
    version (RP2350)
    {
        import urt.driver.rp2350.bootrom : rom_reboot, RebootType;
        rom_reboot(RebootType.normal);
    }
    else static if (has_system_reset)
        system_reset();
    else
        log_notice("system", "system_reboot: not implemented on this platform");
}

ulong unique_device_id()
{
    version (Beken)
    {
        import urt.driver.bk7231.identity : chip_unique_id;
        return chip_unique_id();
    }
    else version (Bouffalo)
    {
        import urt.driver.bl_common.identity : chip_unique_id;
        return chip_unique_id();
    }
    else version (RP2350)
    {
        import urt.driver.rp2350.identity : chip_unique_id;
        return chip_unique_id();
    }
    else
        return 0;
}

const(char)[] reset_reason()
{
    classify();
    return g_reason;
}

ResetClass reset_class()
{
    classify();
    return g_class;
}

version (RP2350)
{
    enum bool has_download_mode = true;

    // urt has no USB device stack, so ROM BOOTSEL is this part's only update path.
    void system_reboot_to_bootloader(uint)
    {
        import urt.driver.rp2350.bootrom : rom_reboot, RebootType;
        rom_reboot(RebootType.bootsel);
    }
}
else
    enum bool has_download_mode = false;

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


private:

__gshared ResetClass g_class;
__gshared const(char)[] g_reason;
__gshared bool g_classified;

// Read once: taking the record stamps this run as running.
void classify()
{
    if (g_classified)
        return;
    g_classified = true;
    ResetMark mark = reset_record_take();
    // RP2350's POWMAN.CHIP_RESET is no help: its HAD_* bits are sticky from power-on and a ROM
    // reboot sets nothing else, so the record decides there too.
    static if (!has_reset_record)
    {
        version (MT7621)
        {
            import urt.driver.mt7621.watchdog : reset_by_watchdog;
            if (reset_by_watchdog())
            {
                g_class = ResetClass.crash;
                g_reason = "watchdog";
                return;
            }
        }
        g_class = ResetClass.unknown;
        return;
    }
    else final switch (mark)
    {
        case ResetMark.none:       g_class = ResetClass.power;      g_reason = "power-on"; return;
        case ResetMark.deliberate: g_class = ResetClass.deliberate; g_reason = "software"; return;
        case ResetMark.crashed:    g_class = ResetClass.crash;      g_reason = "fault"; return;
        case ResetMark.running:    g_class = ResetClass.crash;      g_reason = "watchdog"; return;
    }
}
