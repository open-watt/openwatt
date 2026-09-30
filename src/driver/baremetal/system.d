module driver.baremetal.system;

import urt.driver.reset : ResetCause, ResetMark, has_reset_record, has_system_reset, has_watchdog_cause, reset_cause, reset_record_mark,
    reset_record_take, system_reset;
import urt.log;

import driver.system : ResetClass, ImageId, OtaImage;

nothrow @nogc:


void system_reboot()
{
    reset_record_mark(ResetMark.deliberate);
    static if (has_system_reset)
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
    else version (RouterBoot)
    {
        import urt.driver.routerboot : board_unique_id;
        return board_unique_id();
    }
    else version (STM32)
    {
        import urt.driver.stm32.identity : chip_unique_id;
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
    bool system_reboot_to_bootloader(uint)
    {
        import urt.driver.rp2350.bootrom : rom_reboot, RebootType;
        return rom_reboot(RebootType.bootsel);
    }
}
else version (STM32)
{
    enum bool has_download_mode = true;

    // The ROM bootloader speaks USB DFU; urt has no USB device stack of its own yet.
    bool system_reboot_to_bootloader(uint)
    {
        import urt.driver.reset : ResetMark, reset_record_mark;
        import urt.driver.stm32 : reboot_to_bootloader;
        reset_record_mark(ResetMark.deliberate);
        return reboot_to_bootloader();
    }
}
else version (BL808)
{
    enum bool has_download_mode = true;

    // The boot ROM's UART/USB download mode, the one the vendor flash tools speak.
    bool system_reboot_to_bootloader(uint)
    {
        import urt.driver.bl_common.reset : por_reset;
        reset_record_mark(ResetMark.deliberate);
        por_reset(true);
    }
}
else version (RouterBoot)
{
    enum bool has_download_mode = true;

    // RouterBOOT asks BOOTP/TFTP for an image once and boots flash when nobody answers.
    bool system_reboot_to_bootloader(uint)
    {
        import urt.driver.routerboot : netboot_once;
        if (!netboot_once())
            return false;
        system_reboot();
        return true;
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
    immutable ResetCause cause = reset_cause();
    // a watchdog bite is a hang, whatever the run before it managed to record
    if (cause == ResetCause.watchdog)
        return set_class(ResetClass.crash, "watchdog");
    static if (has_reset_record) final switch (mark)
    {
        case ResetMark.none:       return set_class(ResetClass.power, "power-on");
        case ResetMark.deliberate: return set_class(ResetClass.deliberate, "software");
        case ResetMark.crashed:    return set_class(ResetClass.crash, "fault");
        case ResetMark.updated:    return set_class(ResetClass.deliberate, "firmware update");
        case ResetMark.running:
            // a reset line pressed by hand counts as a power cycle does; a debugger's reset is deliberate
            if (cause == ResetCause.unknown)
                return set_class(ResetClass.crash, has_watchdog_cause ? "unknown" : "watchdog");
            break;
    }
    set_class(by_cause[cause].cls, by_cause[cause].reason);
}

struct Classified
{
    ResetClass cls;
    string reason;
}

static immutable Classified[ResetCause.max + 1] by_cause = [
    Classified(ResetClass.unknown, null), Classified(ResetClass.power, "power-on"), Classified(ResetClass.power, "reset pin"),
    Classified(ResetClass.deliberate, "software"), Classified(ResetClass.crash, "watchdog"),
];

void set_class(ResetClass cls, const(char)[] reason)
{
    g_class = cls;
    g_reason = reason;
}
