module manager.bootguard;

// Counted in NVS, independently of the configuration filesystem.

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
            log_warning("system", "configuration failed ", failures, " boots; requesting previous saved revision");
            return false;
        }
        if (!reset_was_software())
            write_counter(failures + 1);
        return true;
    }
}

void boot_config_recovered()
{
    static if (has_nvs)
        write_counter(1);
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
