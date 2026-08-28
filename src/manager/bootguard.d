module manager.bootguard;

// Counted in NVS, not on the filesystem this may have to roll back. Cutting
// power a few times in a row is therefore also the manual factory reset.

import driver.system : reset_was_software;

import urt.driver.nvs;
import urt.log;
import urt.result : SizeResult;
import urt.time;

nothrow @nogc:


enum uint max_config_boot_failures = 3;
enum Duration healthy_uptime = 60.seconds;


// Call once, before loading any configuration.
bool boot_config_trusted()
{
    static if (!has_nvs)
        return true;
    else
    {
        uint failures = read_counter();
        if (failures >= max_config_boot_failures)
        {
            log_warning("system", "startup config ignored after ", failures,
                        " failed boots; falling back to default config");
            return false;
        }
        // Power cycles still count; cutting power repeatedly is the factory reset.
        if (!reset_was_software())
            write_counter(failures + 1);
        return true;
    }
}

// Renamed rather than deleted, so the operator can still see what broke.
void retire_config(const(char)[] path)
{
    static if (has_nvs)
    {
        import urt.file : file_exists, rename_file;
        import urt.mem.temp : tconcat;

        if (!file_exists(path))
            return;
        const(char)[] retired = tconcat(path, ".bad");
        if (rename_file(path, retired))
            log_warning("system", "moved '", path, "' aside as '", retired, "'");
        else
            log_warning("system", "could not move '", path, "' aside; it will be retried");
    }
}

// Safe to call every frame; touches NVS once.
void boot_guard_update()
{
    static if (has_nvs)
    {
        if (_cleared || getAppTime() < healthy_uptime)
            return;
        _cleared = true;
        uint failures = read_counter();
        if (failures != 0)
        {
            log_info("system", "boot succeeded; clearing ", failures, " recorded boot failure(s)");
            write_counter(0);
        }
    }
}


private:

static if (has_nvs)
{
    __gshared bool _cleared;

    enum const(char)[] nvs_namespace = "openwatt";
    enum const(char)[] nvs_key = "boot_fail";

    uint read_counter()
    {
        Nvs nvs;
        if (!nvs_open(nvs, nvs_namespace, NvsOpenMode.read_only))
            return 0;
        scope(exit) nvs_close(nvs);

        uint value = 0;
        SizeResult r = nvs_read(nvs, nvs_key, (&value)[0 .. 1]);
        return r ? value : 0;
    }

    void write_counter(uint value)
    {
        Nvs nvs;
        if (!nvs_open(nvs, nvs_namespace, NvsOpenMode.read_write))
            return;
        scope(exit) nvs_close(nvs);

        if (nvs_write(nvs, nvs_key, (&value)[0 .. 1]))
            nvs_commit(nvs);
    }
}
