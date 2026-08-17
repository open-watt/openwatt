module manager.stats;

// The `system` device carries the runtime's telemetry about itself. Memory is the first
// tenant: per pool, the largest free block, and the interval watermarks the allocator
// collects between beats. A once-a-second reading of `used` sees neither the transient
// spike that nearly ran the pool out nor the floor creeping up underneath it, which are
// the two shapes that precede an out-of-memory death on a small target. CPU gets the same
// treatment from the load ring's individual buckets.

import urt.log;
import urt.string;
import urt.string.ascii : to_lower;
import urt.system;
import urt.time;

import manager;
import manager.component;
import manager.device;
import manager.element;

nothrow @nogc:


void create_system_device()
{
    DeviceBuilder builder = g_app.devices.create("system");
    Device system = builder.device;
    Component mem = builder.component("mem");

    SystemInfo info = get_sysinfo();
    FormatId bytes = register_value_format!ulong();
    foreach (i, ref p; info.pools)
    {
        if (p.total == 0)
            continue;

        char[16] lowered;
        assert(p.name.length <= lowered.length, "pool name too long");
        Component pool = builder.component(mem, p.name.to_lower(lowered[0 .. p.name.length]));

        builder.constant(pool, "total", p.total);
        _pools[i].used = builder.element(pool, "used", bytes);
        _pools[i].low = builder.element(pool, "low", bytes);
        _pools[i].high = builder.element(pool, "high", bytes);
        if (p.largest_free > 0)
            _pools[i].largest_free = builder.element(pool, "largest_free", bytes);
    }

    Component cpu = builder.component("cpu");

    FormatId percent = register_value_format!uint();
    _cpu.load = builder.element(cpu, "load", percent);
    _cpu.low = builder.element(cpu, "low", percent);
    _cpu.high = builder.element(cpu, "high", percent);

    builder.commit();
    system.notify(ComponentEvent.online);

    g_app.register_heartbeat_handler((MonoTime) { publish(); });
}


private:

struct PoolElements
{
    Element* used;
    Element* low;
    Element* high;
    Element* largest_free;
}

struct CpuElements
{
    Element* load;
    Element* low;
    Element* high;
}

__gshared PoolElements[MaxMemoryPools] _pools;
__gshared CpuElements _cpu;
version (Embedded)
    __gshared uint _beats;

void publish()
{
    SystemInfo info = get_sysinfo();
    sample_memory_watermarks(info);

    uint load = get_cpu_load();
    uint cpu_low, cpu_high;
    get_cpu_load_range(cpu_low, cpu_high);

    SysTime now = getSysTime();
    {
        auto beat = open_commit();
        _cpu.load.value(load, now);
        _cpu.low.value(cpu_low, now);
        _cpu.high.value(cpu_high, now);
        foreach (i, ref p; info.pools)
        {
            PoolElements* e = &_pools[i];
            if (!e.used)
                continue;
            e.used.value(p.used, now);
            e.low.value(p.low, now);
            e.high.value(p.high, now);
            if (e.largest_free)
                e.largest_free.value(p.largest_free, now);
        }
    }

    // The serial log is the only view into a board that has no console attached, so the same
    // figures go out there once a beat. Nothing here may allocate: a per-beat allocation would
    // land in the next interval's watermarks and pollute the measurement it is reporting.
    version (Embedded)
    {
        log_info("stats", "hb=", ++_beats, " cpu=", load, "% (", cpu_low, "-", cpu_high, ")");
        foreach (i, ref p; info.pools)
        {
            if (!_pools[i].used)
                continue;
            log_info("stats", p.name, " used=", p.used, " (", p.low, "-", p.high,
                     ") free-max=", p.largest_free);
        }
    }
}
