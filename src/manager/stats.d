module manager.stats;

// The `system` device carries the runtime's telemetry about itself. Memory is the first
// tenant: per pool, the largest free block, and the interval watermarks the allocator
// collects between beats. A once-a-second reading of `used` sees neither the transient
// spike that nearly ran the pool out nor the floor creeping up underneath it, which are
// the two shapes that precede an out-of-memory death on a small target. CPU gets the same
// treatment from the load ring's individual buckets.

import urt.log;
import urt.mem.allocator;
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
    Device system = g_app.allocator.allocT!Device("system".makeString(g_app.allocator));
    Component mem = g_app.allocator.allocT!Component("mem".makeString(g_app.allocator));
    system.add_component(mem);

    SystemInfo info = get_sysinfo();
    FormatId bytes = register_value_format!ulong();
    foreach (i, ref p; info.pools)
    {
        if (p.total == 0)
            continue;

        char[16] lowered;
        assert(p.name.length <= lowered.length, "pool name too long");
        Component pool = g_app.allocator.allocT!Component(
            p.name.to_lower(lowered[0 .. p.name.length]).makeString(g_app.allocator));
        mem.add_component(pool);

        pool.find_or_create_element("total", bytes).value(p.total);
        _pools[i].used = pool.find_or_create_element("used", bytes);
        _pools[i].low = pool.find_or_create_element("low", bytes);
        _pools[i].high = pool.find_or_create_element("high", bytes);
        if (p.largest_free > 0)
            _pools[i].largest_free = pool.find_or_create_element("largest_free", bytes);
    }

    Component cpu = g_app.allocator.allocT!Component("cpu".makeString(g_app.allocator));
    system.add_component(cpu);

    FormatId percent = register_value_format!uint();
    _cpu.load = cpu.find_or_create_element("load", percent);
    _cpu.low = cpu.find_or_create_element("low", percent);
    _cpu.high = cpu.find_or_create_element("high", percent);

    g_app.devices.insert(system.id[], system);
    system.notify(ComponentEvent.tree_changed);
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
